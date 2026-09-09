import { db, DATA_REGION } from '../db';
import { subjectPseudonym, sessionPseudonym } from '../pseudonymize';
import { encryptForSubject } from '../subjectKey';
import type { PipelineContext, RedFlagSeverity, ResponseCategory } from '../types';

/**
 * HP-RB-001's correction to Charter Annex A.5/A.6: `response_audit` as
 * originally specified needs both mutable fields (review_state moves
 * PENDING -> APPROVED later) and full immutability (UPDATE/DELETE revoked)
 * — contradictory as written. The fix (logged as amendment C-30): an
 * append-only, hash-chained `response_audit_event` log is the record of
 * truth; `response_audit` is a mutable projection derived from it, carrying
 * the Charter's CHECK constraints, rebuildable at any time. This module
 * writes events; a separate scheduled job (not built here — see README)
 * maintains the projection, OR the projection can be upserted inline as
 * done in `upsertProjection` below for the common case of "we have the
 * whole picture at end of turn." Either is valid per RB-001; the log is
 * what actually matters for tamper-evidence.
 *
 * payload MUST carry only IDs, enums, version strings, numeric scores and
 * hashes — never user text or health attributes (RB-001 §3
 * payload_no_pii CHECK, enforced again here so a bug surfaces in code
 * review, not just at insert time).
 */

const BANNED_PAYLOAD_KEYS = ['user_text', 'message', 'name', 'email', 'phone', 'dob', 'symptoms', 'conditions', 'health_flags', 'free_text'];

function assertPayloadClean(payload: Record<string, unknown>) {
  for (const key of Object.keys(payload)) {
    if (BANNED_PAYLOAD_KEYS.includes(key)) {
      throw new Error(`auditLog: payload key "${key}" is banned by RB-001 payload_no_pii — this would fail the DB constraint anyway, caught here first`);
    }
  }
}

export type AuditEventKind =
  | 'RESPONSE_DRAFTED'
  | 'CATEGORY_ASSIGNED'
  | 'SEVERITY_ASSIGNED'
  | 'VALIDATOR_BLOCK'
  | 'TEMPLATE_RENDERED'
  | 'REVIEW_REQUESTED'
  | 'REVIEW_DECIDED'
  | 'PUBLISHED'
  | 'FLAG_RAISED';

export async function recordAuditEvent(
  ctx: Pick<PipelineContext, 'auditId'>,
  kind: AuditEventKind,
  actor: 'system' | `clinician:${string}` | `job:${string}`,
  payload: Record<string, unknown>,
  subjectRef?: string,
) {
  assertPayloadClean(payload);
  await db().query(
    `INSERT INTO response_audit_event (audit_id, kind, occurred_at, actor, subject_ref, payload)
     VALUES ($1, $2, now(), $3, $4, $5::jsonb)`,
    [ctx.auditId, kind, actor, subjectRef ?? null, JSON.stringify(payload)],
  );
  // prev_hash/row_hash are computed by the trg_audit_event_chain trigger —
  // the application never supplies them (HP-RB-001 §4: "that is what stops
  // a compromised application from forging a chain").
}

export interface FinalAuditFields {
  ctx: PipelineContext;
  category: ResponseCategory;
  classifierVersion: string;
  severity: RedFlagSeverity;
  ruleId: string | null;
  /**
   * REQUIRED, and required for a reason that is not tidiness.
   * obs.response_audit carries COMPOSITE foreign keys — (rule_id, rule_version)
   * -> safety.red_flag_rule and (template_id, template_version) ->
   * safety.safety_template. Under MATCH SIMPLE (PostgreSQL's default) a
   * composite FK with ANY null column is NOT CHECKED AT ALL. Passing the id
   * without the version therefore does not produce a partial check; it produces
   * no check, and the audit row could name a template that has never existed.
   *
   * RedFlagOutcome has carried both versions the whole time. They were dropped
   * on the floor here, which is why nothing complained.
   */
  ruleVersion: number | null;
  templateId: string | null;
  templateVersion: number | null;
  aggConfidence: number;
  modelVersion: string;
  promptVersion: string;
  citedClaimIds: string[];
  clinicalDomain?: string | null;
  reviewRequired: boolean;
}

/**
 * Writes the C-30 PROJECTION row (obs.response_audit) — the one-row-per-response
 * summary the Annex A.5 CHECK constraints apply to. Distinct from the
 * `response_audit_event` log above: that is the append-only, hash-chained record
 * of truth, this is derived from it and rebuildable. Migration 036 dropped
 * prev_hash/row_hash from this table for exactly that reason — a projection that
 * carried a chain invited the belief that the chain meant something here.
 *
 * ---------------------------------------------------------------------------
 * WHY THIS IS A FUNCTION CALL AND NOT AN INSERT
 *
 * hp_app holds no table privilege anywhere in `obs`. Against the real schema
 * this INSERT was not a policy gap that CREATE POLICY closes — obs.response_audit
 * had RLS off and no grants to any application role, so there was simply no way
 * for the request path to write its own audit trail (HP-RECON-004 §3). Migration
 * 039 gives it six SECURITY DEFINER verbs instead, following the idiom the schema
 * already used for metrics_role and safety.raise_alert.
 *
 * THE BACKFILL LIVES HERE, not at the four call sites in route.ts. Every exit
 * point writes this row and every exit point has pending telemetry to attach, so
 * attaching it anywhere else is four chances to forget one — and the one you
 * forget is the branch nobody exercises. The audit row and the re-parenting of
 * its telemetry are one act; this is where that act is.
 */
export async function upsertResponseAudit(f: FinalAuditFields) {
  // c_category_c_disabled_v1 / c_no_clinical_when_flagged / c_min_conf are
  // real DB constraints — this insert will fail loudly (not silently) if
  // any upstream stage let a CLINICAL_DECISION category or an
  // under-confidence response get this far. That's intentional defence in
  // depth: the application should never reach here with those states
  // (route.ts short-circuits first), but if it somehow does, the database
  // is the backstop, not this code.
  await db().query(
    `SELECT obs.record_response_audit(
       $1, $2, $3::response_category, $4, $5::red_flag_severity,
       $6, $7, $8, $9, $10,
       $11, $12, $13, $14, $15::review_state, $16, $17)`,
    [
      f.ctx.auditId,
      subjectPseudonym(f.ctx.userId, f.ctx.subjectKey.salt),
      f.category,
      f.classifierVersion,
      f.severity,
      f.ruleId,
      f.ruleVersion,
      f.templateId,
      f.templateVersion,
      f.aggConfidence.toFixed(2),
      process.env.POLICY_VERSION ?? 'unspecified',
      f.modelVersion,
      f.promptVersion,
      f.citedClaimIds,
      f.reviewRequired ? 'PENDING' : 'NOT_REQUIRED',
      f.clinicalDomain ?? null,
      // SEC-2 / migration 044. obs.response_audit was the one obs table carrying
      // a subject pseudonym with no data_region, no RLS and no policy, while
      // metrics_role held SELECT on it.
      //
      // DATA_REGION, not ctx.dataRegion, and the difference is the point: the
      // region is a property of the DEPLOYMENT (HP-ADR-004 §2), and taking it
      // from a request-scoped object is how a request comes to name its own
      // region. It is the same value db() puts in the connection's startup
      // packet, and the function REFUSES the row if the two disagree — a check
      // written in the function body rather than as a WITH CHECK policy because
      // record_response_audit is SECURITY DEFINER and a policy would not bind
      // inside it (migration 035 hit the same wall).
      DATA_REGION,
    ],
  );

  await attachPendingTelemetry(f.ctx);
}

/**
 * obs.attach_pending, and the only caller of it.
 *
 * The arrays are CLEARED whether or not the attach succeeded. Retrying an attach
 * cannot help: `AND audit_id IS NULL` in the function means a row attaches
 * exactly once, so a second pass over the same ids reports zero attached and
 * would look like the failure it is not.
 *
 * A short count is reported and not thrown. The response has already been
 * streamed to the user by the time this runs; telemetry that ended up
 * unattributed is a data-quality problem to see in the logs, not a reason to
 * turn a delivered answer into an error. Those rows remain findable in the
 * database with `WHERE audit_id IS NULL`, which is what migration 039 §5 traded
 * for keeping the foreign key.
 */
async function attachPendingTelemetry(ctx: PipelineContext) {
  const { aiCalls, blocks } = ctx.pending;
  const expected = aiCalls.length + blocks.length;
  if (expected === 0) return;

  try {
    const { rows } = await db().query<{ attach_pending: number }>(
      'SELECT obs.attach_pending($1, $2, $3) AS attach_pending',
      [ctx.auditId, aiCalls, blocks],
    );
    const attached = rows[0]?.attach_pending ?? 0;
    if (attached !== expected) {
      // Not "nothing to do" — the ids were collected during THIS request. A
      // short count means some of them were already parented to a different
      // audit row, which is either a context reused across turns or a bug in
      // how the ids are collected.
      console.error('CRITICAL: attach_pending attached %d of %d rows', attached, expected, {
        auditId: ctx.auditId,
        aiCalls: aiCalls.length,
        blocks: blocks.length,
      });
    }
  } catch (err) {
    console.error('CRITICAL: attach_pending failed; telemetry stays unattributed', {
      auditId: ctx.auditId,
      err,
    });
  } finally {
    aiCalls.length = 0;
    blocks.length = 0;
  }
}

/**
 * LAYER 2 (Phase_1.1_Migration_Pack_ADR-003 §2.3): the actual response
 * text IS personal data and is encrypted per-subject, keyed through
 * `subject_key` (LAYER 3) so erasure is a key-destruction operation, not a
 * row-deletion one, per HP-LB-001's audit-vs-erasure reconciliation.
 *
 * ---------------------------------------------------------------------------
 * THE PLACEHOLDER IS GONE, AND IT COULD NOT HAVE SHIPPED ANYWAY.
 *
 * This function used to derive its AES key from SUBJECT_HMAC_KEY and pass
 * `key_id: null`, with its own comment saying "do not ship this derivation as
 * the production key path." Against the real schema that write is not merely
 * inadvisable, it is impossible: obs.response_content.key_id is NOT NULL with an
 * FK to principal.subject_key, and until migration 038 there was no way to
 * create a row in that table at all. The placeholder survived because the stub
 * schema (db/000) made key_id nullable — which is the exact class of divergence
 * R10g deletes the stub to end.
 *
 * The key now comes from ctx.subjectKey, resolved once per request, and the row
 * names the key it was actually encrypted under. That is what makes erasure
 * work: principal.erase_subject nulls the wrapped DEK, and this ciphertext
 * becomes permanently unreadable while the row itself — and the audit trail
 * around it — survives.
 */
export async function persistResponseContent(ctx: PipelineContext, plaintext: string) {
  const ciphertext = encryptForSubject(ctx.subjectKey, plaintext);

  await db().query(
    'SELECT obs.record_response_content($1, $2, $3, $4, $5)',
    [ctx.auditId, ctx.userId, DATA_REGION, ciphertext, ctx.subjectKey.keyId],
  );
}

export { sessionPseudonym };
