import { db } from '../db';
import { callClaude } from '../anthropic';
import { extractJsonObject } from '../jsonExtract';
import { MODELS } from '../pricing';
import { loadPrompt } from '../prompts/registry';
import { subjectPseudonym, sessionPseudonym } from '../pseudonymize';
import type { PipelineContext, RedFlagResult, RedFlagSeverity } from '../types';
import { SEVERITY_ORDER } from '../types';

/**
 * Charter §4 — Red-Flag Severity and Escalation.
 *
 * §4.0.1: runs on EVERY inbound message, synchronous, in the request path —
 *   not a queued job. Called unconditionally by the orchestrator, before any
 *   category-based short-circuit, and independent of it.
 * §4.0.3: severity is assigned by a deterministic rule set maintained by
 *   clinicians (`safety.red_flag_rule` — pattern/keyword/structured-symptom
 *   rules). The model is used only to *propose* candidates; it may RAISE a
 *   rule-derived severity, never lower it. That's enforced twice here: once
 *   in application code (`Math.max` by ordinal) and again by the DB
 *   constraint obs.ai_call.c_model_may_not_lower on the logged row.
 * §4.0.4: ambiguity resolves upward (URGENT-or-WARNING -> URGENT).
 * §4.0.5: at CRITICAL/EMERGENCY the safety instruction is a pre-approved,
 *   clinician-authored static template, shown immediately, no model
 *   rewriting, no waiting on review. The orchestrator (route.ts) is what
 *   actually short-circuits on this; this module only classifies.
 */

const RULESET_VERSION = process.env.RED_FLAG_RULESET_VERSION ?? 'rf-rules-2026.08.1';

interface RedFlagRuleRow {
  id: string;
  version: number;
  severity: RedFlagSeverity;
  pattern: string; // stored as a Postgres regex; clinician-authored, not user input
  template_id: string | null;
  template_version: number | null;
  clinically_adopted: boolean;
}

async function matchDeterministicRules(message: string): Promise<{
  severity: RedFlagSeverity;
  ruleId: string | null;
  templateId: string | null;
  templateVersion: number | null;
  matched: RedFlagRuleRow[];
}> {
  // safety.red_flag_rule: clinician-authored pattern rules, only the
  // clinically-adopted ones are live (AMB-17 gate — see
  // HP-SCHEMA-001-Annex-A §26 item 4: "clinically_adopted ... is the
  // schema's record of it").
  const { rows } = await db().query<RedFlagRuleRow>(
    `SELECT id, version, severity, pattern, template_id, template_version, clinically_adopted
       FROM safety.red_flag_rule
      WHERE clinically_adopted = true
        AND ruleset_version = $1`,
    [RULESET_VERSION],
  );

  const matched = rows.filter((r) => {
    try {
      return new RegExp(r.pattern, 'i').test(message);
    } catch {
      return false; // a malformed rule must never crash the safety path
    }
  });

  if (matched.length === 0) {
    return { severity: 'NORMAL', ruleId: null, templateId: null, templateVersion: null, matched: [] };
  }

  // §4.0.4: multiple matches -> take the highest severity matched.
  const top = matched.reduce((hi, r) => (SEVERITY_ORDER[r.severity] > SEVERITY_ORDER[hi.severity] ? r : hi));
  return { severity: top.severity, ruleId: top.id, templateId: top.template_id, templateVersion: top.template_version, matched };
}

async function proposeModelSeverity(ctx: PipelineContext, baseSeverity: RedFlagSeverity): Promise<RedFlagSeverity> {
  const prompt = loadPrompt('RED_FLAG_PROPOSE');
  try {
    const { text } = await callClaude({
      meta: {
        auditId: ctx.auditId,
        purpose: 'RED_FLAG_PROPOSE',
        model: MODELS.HAIKU,
        promptVersion: prompt.version,
        proposedSeverity: null, // filled in below once we know it
        appliedSeverity: baseSeverity,
      },
      system: prompt.text,
      messages: [{ role: 'user', content: `Base severity from deterministic rules: ${baseSeverity}\n\nMessage:\n${ctx.message}` }],
      maxTokens: 150,
    });
    // extractJsonObject: see src/lib/jsonExtract.ts's header comment — same
    // markdown-fence-wrapping behavior confirmed against a real live model
    // call to CATEGORY_CLASSIFIER; this call site parses raw model text the
    // same way and was equally vulnerable, just not yet caught live.
    const parsed = JSON.parse(extractJsonObject(text));
    const proposed: RedFlagSeverity = SEVERITY_ORDER[parsed.proposedSeverity as RedFlagSeverity] !== undefined ? parsed.proposedSeverity : baseSeverity;
    return proposed;
  } catch {
    // A failed/unparsable propose-only call must never suppress a raise —
    // but it also must never fabricate one. Fall back to the deterministic
    // base severity untouched.
    return baseSeverity;
  }
}

/**
 * §4.0.3, in one pure function: "the model may raise a rule-derived
 * severity, never lower it." Split out so this exact clamp is
 * unit-testable without a network call or a DB — see
 * test/redFlagEngine.test.ts's `test_hp_esc_4_0_3_model_may_raise_never_lower`.
 */
export function clampSeverity(base: RedFlagSeverity, proposed: RedFlagSeverity): RedFlagSeverity {
  return SEVERITY_ORDER[proposed] > SEVERITY_ORDER[base] ? proposed : base;
}

/**
 * §4.0.2 / c_urgent_template_only, also pure: WARNING and above needs a
 * template_id, and a raise past WARNING with no rule-supplied template
 * falls back to the generic escalation template rather than publishing a
 * null template_id that would fail the DB constraint. See
 * `test_hp_esc_4_0_2_urgent_and_above_always_carries_a_template`.
 */
/**
 * Fallback template id used when a severity is high enough to require a
 * template (WARNING+) but the deterministic rule that fired carries none.
 *
 * BUG FIXED: this used to be the bare string 'GENERIC_ESCALATION_TEMPLATE' —
 * not a UUID. That string flowed into `loadSafetyTemplate()` (§4.0.5), whose
 * try/catch around an invalid-uuid query error silently swallowed it and
 * fell back to the hard-coded emergency message, so the bug was invisible
 * there. It stopped being invisible the moment `safety.red_flag_event.
 * template_id` (a real `uuid` FK column, added below) tried to store it —
 * `recordRedFlagEvent` would have thrown on every WARNING+ event with no
 * rule-supplied template. Fixed by making the fallback a real, fixed UUID
 * that db/999_seed_smoke_test.sql seeds a row for, so both call sites
 * (loadSafetyTemplate and recordRedFlagEvent) resolve it to something real
 * instead of one of them quietly eating the failure.
 */
export const GENERIC_ESCALATION_TEMPLATE_ID = '55555555-5555-5555-5555-555555555555';

export function resolveTemplateRequirement(
  applied: RedFlagSeverity,
  ruleTemplateId: string | null,
  ruleTemplateVersion: number | null,
): { templateId: string | null; templateVersion: number | null } {
  const needsTemplate = SEVERITY_ORDER[applied] >= SEVERITY_ORDER['WARNING'];
  if (!needsTemplate) return { templateId: null, templateVersion: null };
  return {
    templateId: ruleTemplateId ?? GENERIC_ESCALATION_TEMPLATE_ID,
    templateVersion: ruleTemplateVersion ?? 1,
  };
}

export async function scanRedFlags(ctx: PipelineContext): Promise<RedFlagResult> {
  const scannerStartedAt = new Date().toISOString();
  const base = await matchDeterministicRules(ctx.message);
  const proposed = await proposeModelSeverity(ctx, base.severity);

  const applied = clampSeverity(base.severity, proposed);
  const { templateId, templateVersion } = resolveTemplateRequirement(applied, base.templateId, base.templateVersion);

  return {
    severity: applied,
    ruleId: base.ruleId,
    ruleVersion: base.matched.find((m) => m.id === base.ruleId)?.version ?? null,
    ruleSetId: RULESET_VERSION,
    triggerDetail: { matchedRuleIds: base.matched.map((m) => m.id) }, // no free user text, §4.0.7
    proposedSeverityByModel: proposed,
    templateId,
    templateVersion,
    scannerStartedAt,
  };
}

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

export type RedFlagActionTaken = 'TEMPLATE_SHOWN' | 'INTERSTITIAL' | 'TAKEOVER' | 'PANEL_ADDED' | 'ESCALATED' | 'NONE';

/**
 * §4.0.7, pure: what `action_taken` this pipeline actually records for a
 * given severity outcome. Only two of the doc's five UI affordances are
 * wired up end to end here — TEMPLATE_SHOWN for the §4.0.5 static-template
 * short-circuit (route.ts's CRITICAL/EMERGENCY branch), and ESCALATED for
 * anything WARNING+ that isn't that branch (this pipeline's only other
 * concrete action: `sideEffectDispatcher` enqueues a review-queue job
 * whenever a response is `reviewRequired`, and WARNING+ severity is one of
 * the inputs to that flag — see route.ts). INTERSTITIAL/TAKEOVER/PANEL_ADDED
 * are conversational UI affordances this pipeline doesn't render; wire them
 * up here once the frontend actually implements them. 'NONE' is this
 * pipeline's own addition to the doc's action_taken vocabulary (see the
 * red_flag_event DDL's comment in db/010) for a MONITOR-only event, which
 * §4.0.2 still requires to be persisted even though nothing else happens.
 */
export function deriveActionTaken(severity: RedFlagSeverity, emergencyTemplateShown: boolean): RedFlagActionTaken {
  if (emergencyTemplateShown) return 'TEMPLATE_SHOWN';
  if (SEVERITY_ORDER[severity] >= SEVERITY_ORDER['WARNING']) return 'ESCALATED';
  return 'NONE';
}

export interface RedFlagEventTiming {
  firstByteAt: Date;
  scannerStartedAt: Date;
  templateDisplayedAt?: Date | null;
}

/**
 * §4.0.7 — "every flag at MONITOR and above, persisted with its full
 * context." Writes `safety.red_flag_event` (db/010_chat_pipeline_support.sql
 * §7; adapted from the verbatim block quoted in HP-SCHEMA-001 Annex A
 * Extension). Must be called AFTER `upsertResponseAudit()` for this
 * audit_id — `audit_id` here is a real FK into `response_audit(id)`, and the
 * row it points to doesn't exist until that call runs; route.ts's four exit
 * points all call this immediately after their `upsertResponseAudit()`.
 *
 * Below MONITOR (i.e. NORMAL) this is a deliberate no-op (returns null): the
 * DB's own `c_event_at_least_monitor` CHECK would reject the row anyway, and
 * skipping the call avoids a guaranteed-fail round trip on the overwhelming
 * majority of ordinary, unflagged messages.
 *
 * Also upserts `safety.session_severity_floor` (§4.0.8) with this event —
 * see that table's own doc comment in db/010. This keeps the floor update
 * atomic with the event that justifies it: there is never a red_flag_event
 * row without a corresponding floor raise (or no-op if the floor is already
 * at or above this severity), and never a floor change with no event backing
 * it (`set_by_event_id` is `NOT NULL`).
 *
 * Returns the new row's id (for `set_by_event_id`), or null when it no-oped.
 */
export async function recordRedFlagEvent(
  ctx: Pick<PipelineContext, 'auditId' | 'userId' | 'sessionId' | 'dataRegion'>,
  result: RedFlagResult,
  actionTaken: RedFlagActionTaken,
  timing: RedFlagEventTiming,
): Promise<string | null> {
  if (SEVERITY_ORDER[result.severity] < SEVERITY_ORDER['MONITOR']) return null;

  let templateId = result.templateId;
  if (templateId && !UUID_RE.test(templateId)) {
    // Defensive only — should not trigger post the GENERIC_ESCALATION_
    // TEMPLATE_ID fix above, kept in case a future rule row's template_id
    // is ever malformed. A non-UUID must never reach a `uuid` FK column.
    console.warn('recordRedFlagEvent: dropping non-UUID templateId', { templateId });
    templateId = null;
  }

  // §4.0.6: this pipeline has no commercial-content path yet to selectively
  // suppress (no sponsored hospital placements, no affiliate links in the
  // synthesis step) — every MONITOR+ event suppresses conservatively, which
  // is the safe direction of error until there's something real to gate.
  const commercialSuppressed = true;
  const sessionPseudo = sessionPseudonym(ctx.sessionId);

  const { rows } = await db().query<{ id: string }>(
    `INSERT INTO safety.red_flag_event
       (id, audit_id, subject_pseudonym, session_pseudonym, occurred_at, severity,
        rule_id, rule_version, ruleset_version, trigger_detail, template_id, template_version,
        action_taken, commercial_suppressed, first_byte_at, scanner_started_at,
        template_displayed_at, data_region)
     VALUES (gen_random_uuid(), $1, $2, $3, now(), $4,
             $5, $6, $7, $8::jsonb, $9, $10,
             $11, $12, $13, $14,
             $15, $16)
     RETURNING id`,
    [
      ctx.auditId,
      subjectPseudonym(ctx.userId),
      sessionPseudo,
      result.severity,
      result.ruleId,
      result.ruleVersion,
      result.ruleSetId,
      JSON.stringify(result.triggerDetail),
      templateId,
      result.templateVersion,
      actionTaken,
      commercialSuppressed,
      timing.firstByteAt.toISOString(),
      timing.scannerStartedAt.toISOString(),
      timing.templateDisplayedAt ? timing.templateDisplayedAt.toISOString() : null,
      ctx.dataRegion,
    ],
  );
  const eventId = rows[0]!.id;

  // §4.0.8: raise the floor to this event's severity, UNLESS the existing
  // floor is active (not cleared) and already >= this severity — a sticky
  // floor never moves down while it's still in force. A previously CLEARED
  // floor is not a floor to respect: this event restarts it fresh at
  // whatever severity it carries, which can be lower than the old cleared
  // value — clearing means "this session is no longer flagged," not "never
  // flag it below X again."
  await db().query(
    `INSERT INTO safety.session_severity_floor
       (session_pseudonym, floor_severity, set_by_event_id, set_at, cleared_at, cleared_by)
     VALUES ($1, $2, $3, now(), NULL, NULL)
     ON CONFLICT (session_pseudonym) DO UPDATE SET
       floor_severity = EXCLUDED.floor_severity,
       set_by_event_id = EXCLUDED.set_by_event_id,
       set_at = now(),
       cleared_at = NULL,
       cleared_by = NULL
     WHERE safety.session_severity_floor.cleared_at IS NOT NULL
        OR EXCLUDED.floor_severity > safety.session_severity_floor.floor_severity`,
    [sessionPseudo, result.severity, eventId],
  );

  return eventId;
}

export interface SessionFloor {
  floorSeverity: RedFlagSeverity;
  active: boolean; // false when cleared_at is set — a cleared floor exerts no pull on future messages
}

/**
 * §4.0.8 read side. Called once, at the top of route.ts's `runPipeline`,
 * before any severity-based branching — a session already sitting at
 * WARNING+ must not be treated as NORMAL again just because one later
 * message in it happens to look ordinary on its own.
 */
export async function getSessionFloor(ctx: Pick<PipelineContext, 'sessionId'>): Promise<SessionFloor | null> {
  const { rows } = await db().query<{ floor_severity: RedFlagSeverity; cleared_at: string | null }>(
    `SELECT floor_severity, cleared_at FROM safety.session_severity_floor WHERE session_pseudonym = $1`,
    [sessionPseudonym(ctx.sessionId)],
  );
  const row = rows[0];
  if (!row) return null;
  return { floorSeverity: row.floor_severity, active: row.cleared_at === null };
}

/**
 * Pure, and deliberately named apart from `clampSeverity` above — same
 * "raise, never lower" shape, but a different clause (§4.0.8 vs §4.0.3) and
 * a different input (a session's sticky floor vs. one model's propose-only
 * suggestion). An inactive (cleared) floor exerts no pull.
 */
export function applySessionFloor(severity: RedFlagSeverity, floor: SessionFloor | null): RedFlagSeverity {
  if (!floor || !floor.active) return severity;
  return SEVERITY_ORDER[floor.floorSeverity] > SEVERITY_ORDER[severity] ? floor.floorSeverity : severity;
}

/**
 * §4.0.8's other half: "until a clinician ... clears them." Not called from
 * anywhere in this repo — there is no clinician-facing review tool here for
 * it to be wired to (see README) — but implemented and tested directly
 * against the DB so that tool has a real function to call rather than a gap
 * to rediscover. `clinicianId` has no FK target in this stub (no
 * `principal.clinician` table — see db/000's header); c_clear_attributed
 * still enforces that a clearance is never anonymous.
 */
export async function clearSessionSeverityFloor(sessionId: string, clinicianId: string): Promise<void> {
  await db().query(
    `UPDATE safety.session_severity_floor
        SET cleared_at = now(), cleared_by = $2
      WHERE session_pseudonym = $1 AND cleared_at IS NULL`,
    [sessionPseudonym(sessionId), clinicianId],
  );
}

/**
 * §4.0.5 — pre-approved, clinician-authored, static templates only. Loaded
 * from `safety.safety_template` by id; never composed or paraphrased by a
 * model. Falls back to a hard-coded, maximally conservative message if the
 * template table is unreachable, because an emergency response must never
 * simply fail to render.
 */
export async function loadSafetyTemplate(templateId: string): Promise<string> {
  try {
    const { rows } = await db().query<{ body: string }>(
      `SELECT body FROM safety.safety_template WHERE id = $1 AND active = true LIMIT 1`,
      [templateId],
    );
    if (rows[0]) return rows[0].body;
  } catch {
    // fall through to the hard-coded fallback below
  }
  return (
    'This may be a medical emergency. Please contact your local emergency number or go to ' +
    'the nearest emergency department now. This message is shown automatically and has not ' +
    'been reviewed for your specific situation, but that review does not need to happen ' +
    'before you get help — it happens alongside it.'
  );
}
