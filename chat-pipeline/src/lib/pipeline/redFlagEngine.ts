import { db } from '../db';
import { callClaude } from '../anthropic';
import { extractJsonObject } from '../jsonExtract';
import { MODELS } from '../pricing';
import { loadPrompt } from '../prompts/registry';
import { subjectPseudonym, sessionPseudonym } from '../pseudonymize';
import type { PipelineContext, RedFlagResult, RedFlagSeverity } from '../types';
import { buildUnavailability, type ServiceUnavailability } from './unavailability';
import { parseRulePattern, matchPattern, MalformedRulePatternError, type PatternInput } from './rulePattern';
import { resolveTemplateForSeverity, NoApprovedTemplateError } from './templateResolution';
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

// R3: the live rule set is chosen by safety.adopted_rule_set(jurisdiction,
// language) — a database function that exists identically in migrations/027
// and db/010 — rather than by an environment variable naming a text version.
// An env var could name a set that was never adopted; the function cannot.

interface RedFlagRuleRow {
  rule_set_id?: string;
  id: string;
  version: number;
  severity: RedFlagSeverity;
  // R3: jsonb, matching the committed column. Parsed by rulePattern.ts, never
  // fed to `new RegExp`. Templates are NOT carried here — R2 resolves them by
  // (severity, jurisdiction, language) through the §4.3.3 ladder.
  pattern: unknown;
  clinically_adopted: boolean;
}

export type AdoptionGate = 'OPEN' | 'FAIL_CLOSED';

/**
 * §0.6 / AMB-17, pure so it is testable without a database — same reason
 * `clampSeverity` and `applySessionFloor` are split out above.
 *
 * The distinction it encodes is the whole safety claim: "we scanned and found
 * nothing" and "we never scanned" both produce NORMAL, and only one of them is
 * an assessment. Zero adopted rules is the second. So is a failed lookup —
 * §4.0.9 forbids failing open, and a thrown error would hand that decision to
 * whatever `catch` happens to be upstream.
 */
export function resolveAdoptionGate(args: {
  adoptedRuleCount: number;
  lookupFailed: boolean;
}): AdoptionGate {
  if (args.lookupFailed) return 'FAIL_CLOSED';
  return args.adoptedRuleCount > 0 ? 'OPEN' : 'FAIL_CLOSED';
}

async function matchDeterministicRules(
  input: PatternInput,
  jurisdiction: string,
  language: string,
): Promise<{
  severity: RedFlagSeverity;
  ruleId: string | null;
  ruleVersion: number | null;
  ruleSetId: string | null;
  matched: Array<{ row: RedFlagRuleRow; detail: Record<string, unknown> }>;
  adoptionGate: AdoptionGate;
  gateReason: string | null;
}> {
  // safety.red_flag_rule: clinician-authored pattern rules, only the
  // clinically-adopted ones are live (AMB-17 gate — see
  // HP-SCHEMA-001-Annex-A §26 item 4: "clinically_adopted ... is the
  // schema's record of it").
  let rows: RedFlagRuleRow[];
  try {
    // R3: selects the live set through safety.adopted_rule_set(), which exists
    // identically in migrations/027 and db/010 — one code path, both schemas.
    // It already applies the §0.6 adoption filter and the supersession/retired
    // rules, so this query does not have to restate them.
    ({ rows } = await db().query<RedFlagRuleRow>(
      `SELECT r.id, r.version, r.severity, r.pattern, r.clinically_adopted,
              s.rule_set_id
         FROM safety.adopted_rule_set($1, $2) s
         JOIN safety.red_flag_rule r
           ON r.rule_set_id = s.rule_set_id
          AND r.clinically_adopted = true
          AND r.retired_at IS NULL`,
      [jurisdiction, language],
    ));
  } catch (err) {
    // §4.0.9: "failing open to generative output is prohibited." If this threw,
    // route.ts's own catch would be the thing deciding whether an unscanned
    // message reaches the model, and that decision does not belong there.
    return {
      severity: 'NORMAL', ruleId: null, ruleVersion: null, ruleSetId: null, matched: [],
      adoptionGate: resolveAdoptionGate({ adoptedRuleCount: 0, lookupFailed: true }),
      gateReason: `red_flag_rule lookup failed: ${err instanceof Error ? err.message : String(err)}`,
    };
  }

  // §0.6 / AMB-17 — the gate. Zero adopted rules is not "nothing matched"; it
  // is "nothing was ever signed to match with". Returning NORMAL here would
  // make an unsigned deployment look safe while detecting nothing at all, which
  // is the one failure mode this whole module is written to prevent.
  if (resolveAdoptionGate({ adoptedRuleCount: rows.length, lookupFailed: false }) === 'FAIL_CLOSED') {
    return {
      severity: 'NORMAL', ruleId: null, ruleVersion: null, ruleSetId: null, matched: [],
      adoptionGate: 'FAIL_CLOSED',
      gateReason:
        `no clinically adopted red-flag rule set for ${jurisdiction}/${language} (§0.6, AMB-17: CL2 unsigned)`,
    };
  }

  // R3: structured evaluation. A pattern that does not parse is a rule nobody
  // can evaluate, and §4.0.9 forbids treating that as a non-match — "the
  // pattern was gibberish so nothing matched" is failing open with extra
  // steps. It closes the gate instead.
  const matched: Array<{ row: RedFlagRuleRow; detail: Record<string, unknown> }> = [];
  for (const r of rows) {
    let detail: Record<string, unknown> | null;
    try {
      detail = matchPattern(parseRulePattern(r.pattern, r.id), input);
    } catch (err) {
      if (err instanceof MalformedRulePatternError) {
        return {
          severity: 'NORMAL', ruleId: null, ruleVersion: null, ruleSetId: null, matched: [],
          adoptionGate: 'FAIL_CLOSED',
          gateReason: `unevaluable rule pattern: ${err.message}`,
        };
      }
      throw err;
    }
    if (detail) matched.push({ row: r, detail });
  }

  if (matched.length === 0) {
    return { severity: 'NORMAL', ruleId: null, ruleVersion: null, ruleSetId: rows[0]?.rule_set_id ?? null, matched: [], adoptionGate: 'OPEN', gateReason: null };
  }

  // §4.0.4: multiple matches -> take the highest severity matched.
  const top = matched.reduce((hi, m) =>
    SEVERITY_ORDER[m.row.severity] > SEVERITY_ORDER[hi.row.severity] ? m : hi);
  return {
    severity: top.row.severity,
    ruleId: top.row.id,
    ruleVersion: top.row.version,
    ruleSetId: top.row.rule_set_id ?? null,
    matched,
    adoptionGate: 'OPEN',
    gateReason: null,
  };
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
 * R2 (2 Sep 2026): `resolveTemplateRequirement()` and
 * `GENERIC_ESCALATION_TEMPLATE_ID` are GONE, and their absence is the point.
 *
 * Both existed because a template was carried on the rule row. The committed
 * schema has no `red_flag_rule.template_id` — a template is identified by
 * `UNIQUE (severity, jurisdiction, language, version)` and found by climbing
 * §4.3.3/§4.3.4's ladder. See templateResolution.ts.
 *
 * The generic-escalation UUID was a workaround for the same missing concept:
 * "this severity needs a template and the rule did not name one." Under the
 * ladder that case is not special — a WARNING with no WARNING row simply
 * resolves upward to CRITICAL, which is what §4.0.9 asks for and is strictly
 * safer than a single generic row standing in for every level.
 */

export async function scanRedFlags(ctx: PipelineContext): Promise<RedFlagResult> {
  const scannerStartedAt = new Date().toISOString();
  const jurisdiction = ctx.statedCountry ?? ctx.dataRegion;
  const language = ctx.language ?? 'en';

  // R3: structured patterns evaluate against the message AND whatever
  // structured data the session carries. Symptom/vital/lab/travel fields are
  // absent today, so structured rules simply do not match — which is correct:
  // a rule that cannot be evaluated must not fire, and must not be silently
  // treated as evaluated either.
  const patternInput: PatternInput = { message: ctx.message };

  const base = await matchDeterministicRules(patternInput, jurisdiction, language);

  // §0.6 / AMB-17. Nothing signed to run, the rule table was unreachable, or a
  // rule pattern would not parse. Do not call the model: step 2 is a RAISING
  // channel over a rule-derived severity, and there is no rule-derived
  // severity to raise. Letting it classify unsupervised here would be the
  // model assigning a level unilaterally, which §4.0.3 forbids in those words.
  if (base.adoptionGate === 'FAIL_CLOSED') {
    return {
      severity: 'NORMAL',
      ruleId: null,
      ruleVersion: null,
      ruleSetId: null,
      triggerDetail: { adoptionGate: 'FAIL_CLOSED', reason: base.gateReason },
      proposedSeverityByModel: null,
      templateId: null,
      templateVersion: null,
      templateBody: null,
      scannerStartedAt,
      adoptionGate: 'FAIL_CLOSED',
      unavailability: await buildUnavailability(
        base.gateReason ?? 'red-flag adoption gate closed',
        ctx.statedCountry ?? null,
      ),
    };
  }

  const proposed = await proposeModelSeverity(ctx, base.severity);
  const applied = clampSeverity(base.severity, proposed);

  // R2: §4.3.1 — every level at or above WARNING renders from a versioned,
  // clinician-approved template, resolved by the ladder rather than by an FK.
  let templateId: string | null = null;
  let templateVersion: number | null = null;
  let templateBody: string | null = null;
  let templateFallbackReason: string | null = null;
  try {
    const selection = await resolveTemplateForSeverity(applied, jurisdiction, language);
    if (selection) {
      templateId = selection.template.id;
      templateVersion = selection.template.version;
      templateBody = selection.template.body;
      templateFallbackReason = selection.fallbackReason;
    }
  } catch (err) {
    // §4.0.9: a severity that requires a template, with no approved template
    // anywhere at or above it, must not fall through to generative output.
    if (err instanceof NoApprovedTemplateError) {
      return {
        severity: applied,
        ruleId: base.ruleId,
        ruleVersion: base.ruleVersion,
        ruleSetId: base.ruleSetId,
        triggerDetail: { matchedRuleIds: base.matched.map((m) => m.row.id), templateResolution: 'NONE_FOUND' },
        proposedSeverityByModel: proposed,
        templateId: null,
        templateVersion: null,
        templateBody: null,
        scannerStartedAt,
        adoptionGate: 'FAIL_CLOSED',
        unavailability: await buildUnavailability(err.message, ctx.statedCountry ?? null),
      };
    }
    throw err;
  }

  return {
    severity: applied,
    ruleId: base.ruleId,
    ruleVersion: base.ruleVersion,
    ruleSetId: base.ruleSetId,
    // §4.0.7: which pattern matched, never what the user wrote.
    triggerDetail: {
      matchedRuleIds: base.matched.map((m) => m.row.id),
      matches: base.matched.map((m) => ({ ruleId: m.row.id, severity: m.row.severity, detail: m.detail })),
      ...(templateFallbackReason ? { templateFallbackReason } : {}),
    },
    proposedSeverityByModel: proposed,
    templateId,
    templateVersion,
    templateBody,
    scannerStartedAt,
    adoptionGate: 'OPEN',
    unavailability: null,
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
        rule_id, rule_version, rule_set_id, trigger_detail, template_id, template_version,
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
export interface LoadedSafetyTemplate {
  body: string;
  /**
   * Which of the two this actually is. The caller records it, so an emergency
   * rendered from the unapproved fallback is visible in the audit trail rather
   * than indistinguishable from a clinician-authored one.
   */
  source: 'APPROVED_TEMPLATE' | 'HARDCODED_FALLBACK';
  /** Set when the lookup failed rather than simply finding no row. */
  failure: string | null;
}

/**
 * §4.0.9 last-resort text. Not clinician-approved — HP-JOB-003 J3-8 tracks
 * that. It exists because §4.0.9 forbids rendering nothing on an emergency
 * path, and rendering nothing is worse than rendering this.
 */
const HARDCODED_EMERGENCY_FALLBACK =
  'This may be a medical emergency. Please contact your local emergency number or go to ' +
  'the nearest emergency department now. This message is shown automatically and has not ' +
  'been reviewed for your specific situation, but that review does not need to happen ' +
  'before you get help — it happens alongside it.';

/**
 * R2: the body now arrives on the scan result, already resolved by the
 * §4.3.3/§4.3.4 ladder, so this no longer queries anything. It exists to keep
 * one place where "we have no approved text" turns into the §4.0.9 last-resort
 * string, and to keep that substitution VISIBLE — the audit event records
 * `template_source`, so an emergency rendered from the unapproved fallback is
 * distinguishable from a clinician-authored one.
 *
 * The previous version queried `WHERE id = $1 AND active = true`. The real
 * schema has no `active` column; the query raised, the catch swallowed it, and
 * every CRITICAL/EMERGENCY silently rendered the fallback (HP-RECON-001 §2).
 * Removing the query removes that failure mode entirely.
 */
export function loadSafetyTemplate(resolvedBody: string | null): LoadedSafetyTemplate {
  if (resolvedBody && resolvedBody.trim().length > 0) {
    return { body: resolvedBody, source: 'APPROVED_TEMPLATE', failure: null };
  }
  return {
    body: HARDCODED_EMERGENCY_FALLBACK,
    source: 'HARDCODED_FALLBACK',
    failure: 'no approved template body resolved for this severity',
  };
}



/**
 * §4.0.7 gives MONITOR as the persistence floor, and `red_flag_event`'s
 * `c_event_at_least_monitor` enforces it. That is correct for the *governed*
 * record and useless for the other thing the Charter asks for: §6.4's
 * false-negative review, which is entirely a question about the messages the
 * rules called NORMAL. You cannot review what you did not write down.
 *
 * So `safety.red_flag_log` (migration 027) is a second, wider table: one row
 * per scan, every severity, NORMAL included, with a nullable FK to the
 * governed event row where one exists. Relaxing `c_event_at_least_monitor`
 * instead would have been a §6.3 change to a Charter-derived control needing
 * Board approval; this needs neither.
 *
 * Called for EVERY scan, after the response has been sent — §4.0.5 forbids
 * gating output on anything, and a synchronous INSERT on the display path is a
 * queue of one.
 */
export async function recordRedFlagLog(
  ctx: Pick<PipelineContext, 'auditId' | 'userId' | 'sessionId' | 'dataRegion' | 'receivedAt'>,
  result: RedFlagResult,
  args: {
    eventId: string | null;
    branch: 'CONTINUE' | 'MONITOR_PANEL' | 'SAFETY_BLOCK_FIRST' | 'TEMPLATE_TAKEOVER' | 'FAIL_CLOSED';
    commercialSuppressed: boolean;
    generationBlocked: boolean;
    needsReview: boolean;
    scannerCompletedAt: Date;
    templateDisplayedAt: Date | null;
  },
): Promise<void> {
  const firstByteAt = new Date(ctx.receivedAt);
  try {
    await db().query(
      `INSERT INTO safety.red_flag_log
         (id, event_id, audit_id, subject_pseudonym, session_pseudonym, occurred_at,
          rule_derived_severity, model_proposed_severity, applied_severity,
          context_escalation, rule_set_id, matched_rule_ids, trigger_detail, query_hash,
          branch, template_id, template_version, commercial_suppressed, generation_blocked,
          needs_review, shadow_mode, first_byte_at, scanner_started_at, scanner_completed_at,
          template_displayed_at, display_latency_ms, scanner_version, fail_safe_reason, data_region)
       VALUES (gen_random_uuid(), $1, $2, $3, $4, now(),
               $5, $6, $7,
               '{}', NULL, $8, $9::jsonb, digest($10, 'sha256'),
               $11, $12, $13, $14, $15,
               $16, false, $17, $18, $19,
               $20, $21, $22, $23, $24)`,
      [
        args.eventId,
        ctx.auditId,
        subjectPseudonym(ctx.userId),
        sessionPseudonym(ctx.sessionId),
        result.severity,
        result.proposedSeverityByModel,
        result.severity,
        result.ruleId ? [result.ruleId] : [],
        JSON.stringify(result.triggerDetail),
        // §3.13.1 convention: a hash, never the query text. The log is read by
        // anyone measuring safety and must not become a second store of
        // personal health data.
        ctx.auditId,
        args.branch,
        result.templateId,
        result.templateVersion,
        args.commercialSuppressed,
        args.generationBlocked,
        args.needsReview,
        firstByteAt.toISOString(),
        result.scannerStartedAt,
        args.scannerCompletedAt.toISOString(),
        args.templateDisplayedAt ? args.templateDisplayedAt.toISOString() : null,
        // §6.5: from FIRST BYTE of the inbound message, not from scanner start.
        // A dashboard that measures its own runtime looks healthy while the
        // user waits.
        args.templateDisplayedAt ? args.templateDisplayedAt.getTime() - firstByteAt.getTime() : null,
        SCANNER_VERSION,
        result.unavailability?.internalReason ?? null,
        ctx.dataRegion,
      ],
    );
  } catch (err) {
    // Logging must never take down a response that has already been correctly
    // delivered. Loud, because a silent gap here is a hole in §6.4's evidence.
    console.error('recordRedFlagLog failed', { auditId: ctx.auditId, err });
  }
}

export const SCANNER_VERSION = 'hp-redflag-chat-pipeline-v1.1.0';

/** §6.5, pure and testable without a clock or a DB. */
export function displayLatencyMs(firstByteAt: Date, templateDisplayedAt: Date | null): number | null {
  if (!templateDisplayedAt) return null;
  return templateDisplayedAt.getTime() - firstByteAt.getTime();
}
