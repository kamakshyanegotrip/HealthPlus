import { randomBytes, createCipheriv } from 'node:crypto';
import { db, DATA_REGION } from '../db';
import { subjectPseudonym, sessionPseudonym } from '../pseudonymize';
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
  templateId: string | null;
  aggConfidence: number;
  modelVersion: string;
  promptVersion: string;
  citedClaimIds: string[];
  clinicalDomain?: string | null;
  reviewRequired: boolean;
}

/**
 * Upserts the LAYER 1 immutable trace row (Phase_1.1_Migration_Pack_ADR-003
 * §2.3/§2.4 naming — no personal data, pseudonymous subject reference only,
 * hash-chained by its own trigger). This is distinct from the
 * `response_audit_event` log above: that's the append-only per-step event
 * stream, this is the one-row-per-response summary the Annex A.5 CHECK
 * constraints actually apply to.
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
    `INSERT INTO response_audit
       (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
        template_id, agg_confidence, policy_version, model_version, prompt_version,
        cited_claim_ids, review_state, clinical_domain)
     VALUES ($1, $2, now(), $3, $4, $5,
             $6, $7, $8, $9, $10,
             $11, $12, $13)
     ON CONFLICT (id) DO NOTHING`, // the immutable trace is written once, at publication
    [
      f.ctx.auditId,
      subjectPseudonym(f.ctx.userId),
      f.category,
      f.classifierVersion,
      f.severity,
      f.templateId,
      f.aggConfidence.toFixed(2),
      process.env.POLICY_VERSION ?? 'unspecified',
      f.modelVersion,
      f.promptVersion,
      f.citedClaimIds,
      f.reviewRequired ? 'PENDING' : 'NOT_REQUIRED',
      f.clinicalDomain ?? null,
    ],
  );
}

/**
 * LAYER 2 (Phase_1.1_Migration_Pack_ADR-003 §2.3): the actual response
 * text IS personal data and is encrypted per-subject, keyed through
 * `subject_key` (LAYER 3) so erasure is a key-destruction operation, not a
 * row-deletion one, per HP-LB-001's audit-vs-erasure reconciliation.
 *
 * The AES-256-GCM here is a working placeholder for that per-subject key
 * lookup — it derives a key from SUBJECT_HMAC_KEY rather than reading
 * `subject_key`, which doesn't have committed DDL in this project yet. Wire
 * this to the real per-subject key + rotation once §17 lands; do not ship
 * this derivation as the production key path.
 */
export async function persistResponseContent(ctx: PipelineContext, plaintext: string) {
  const key = subjectPseudonym(ctx.userId).subarray(0, 32); // placeholder — see doc comment
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const enc = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const authTag = cipher.getAuthTag();
  const ciphertext = Buffer.concat([iv, authTag, enc]);

  await db().query(
    `INSERT INTO response_content (audit_id, subject_id, data_region, ciphertext, key_id)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (audit_id) DO NOTHING`,
    [ctx.auditId, ctx.userId, DATA_REGION, ciphertext, null],
  );
}

export { sessionPseudonym };
