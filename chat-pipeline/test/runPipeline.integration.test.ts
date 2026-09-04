import { randomUUID } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { PipelineContext, ResponseCategory, RedFlagSeverity } from '../src/lib/types';
import { loadPrompt } from '../src/lib/prompts/registry';
import { CLINICAL_DECISION_REFUSAL } from '../src/lib/prompts/annexB';
import { __setAnthropicClientForTesting, type AnthropicLike } from '../src/lib/anthropic';
import { db } from '../src/lib/db';
import { sessionPseudonym } from '../src/lib/pseudonymize';
import { lookupPatientProfile } from '../src/lib/pipeline/patientProfile';

/**
 * GAP RESOLVED (Turn 5 punch list — "orchestration layer never actually
 * run/tested end-to-end"): this drives the ACTUAL `runPipeline` (exported
 * from src/app/api/chat/route.ts) against a real local Postgres (same
 * db/000 + db/010 + db/999 this repo's other DB tooling uses — see README
 * "Running"), with the Anthropic client swapped for a scripted mock via
 * anthropic.ts's `__setAnthropicClientForTesting`. No live Anthropic call is
 * made anywhere in this file.
 *
 * What this exercises that nothing else in the repo did before: the actual
 * branching inside `runPipeline` — which of its four exit points a given
 * combination of category/severity/retrieval actually reaches — not just
 * each step's SQL in isolation (scripts/smoke-test.mjs) or each step's pure
 * logic in isolation (test/*.test.ts). `auth.ts`'s `requireAuth` is NOT
 * exercised here (it's tested separately, and `runPipeline` itself never
 * calls it — only `POST` does) — this is intentionally the orchestration
 * layer alone.
 *
 * Requires a running local Postgres with db/000 + db/010 + db/999 applied
 * (see README's "Running" section) and RUN_PIPELINE_INTEGRATION=1 set —
 * `npm run test:integration` does both. Skipped by default so `npm test`
 * stays green with no DB running, matching this repo's existing split
 * between `test` (pure/unit) and `test:db` (needs Postgres).
 */

const RUN = process.env.RUN_PIPELINE_INTEGRATION === '1';

// Seeded in db/999_seed_smoke_test.sql.
const SEEDED_USER_ID = '11111111-1111-1111-1111-111111111111';
// A second, unrelated patient — seeded purely to prove HP-SEC-001 RLS
// isolation (db/020_rls.sql) below; never referenced by any non-RLS test.
const SEEDED_USER_ID_B = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const SEEDED_GUIDELINE_CLAIM_ID = '33333333-3333-3333-3333-333333333333';
// R2: templates are resolved by (severity, jurisdiction, language) through the
// §4.3.3 ladder, not by an FK on the rule row, so there is no longer a generic
// stand-in. newCtx() below is dataRegion 'IN' with no statedCountry and no
// language, i.e. jurisdiction 'IN' / language 'en' — which is an exact match
// on the seeded CRITICAL template in db/999_seed_smoke_test.sql.
const SEEDED_CRITICAL_TEMPLATE_ID = '44444444-4444-4444-4444-444444444402';
const SEEDED_CRITICAL_TEMPLATE_BODY =
  'This may be a medical emergency. Contact your local emergency number now.';

interface SseEvent {
  event: string;
  data: unknown;
}

interface Scenario {
  intentDomains: string[];
  intentComplexity: 'LOW' | 'MEDIUM' | 'HIGH';
  category: ResponseCategory;
  proposedSeverity: RedFlagSeverity;
  reasoningText?: string;
  synthesisText?: string;
}

function textResponse(text: string) {
  return { content: [{ type: 'text', text }], usage: { input_tokens: 42, output_tokens: 12 } };
}

// A minimal stand-in for the Anthropic SDK's streaming MessageStream: async
// iterable of content_block_delta text events (what route.ts's textDeltas()
// generator actually reads), plus finalMessage() (what streamClaude's
// finalize() awaits for usage numbers).
function makeMockStream(text: string) {
  const chunks = text.match(/\S+\s*/g) ?? [text];
  return {
    async *[Symbol.asyncIterator]() {
      for (const chunk of chunks) {
        yield { type: 'content_block_delta', delta: { type: 'text_delta', text: chunk } };
      }
    },
    finalMessage: async () => ({ usage: { input_tokens: 200, output_tokens: 80 } }),
  };
}

/**
 * The Anthropic SDK's `.messages.create()` signature doesn't carry
 * `LoggedCallMeta.purpose` (that's an application-level field, logged but
 * never sent to the API) — so this mock, like the real API, only sees
 * {model, system, messages, ...}. It distinguishes which of the pipeline's
 * four LLM-facing steps is calling by matching `system` against the exact
 * prompt text each step loads from the registry (INTENT_COMPLEXITY /
 * CATEGORY_CLASSIFIER / RED_FLAG_PROPOSE are matched exactly;
 * CLINICAL_REASONING's system is that prompt plus two Annex B blocks
 * appended, so it's matched by prefix).
 */
function buildMockClient(scenario: Scenario): AnthropicLike {
  const INTENT_PROMPT = loadPrompt('INTENT_COMPLEXITY').text;
  const CATEGORY_PROMPT = loadPrompt('CATEGORY_CLASSIFIER').text;
  const REDFLAG_PROMPT = loadPrompt('RED_FLAG_PROPOSE').text;
  const REASONING_PROMPT = loadPrompt('CLINICAL_REASONING').text;

  return {
    messages: {
      create: (async (opts: { system: string }) => {
        const { system } = opts;
        if (system === INTENT_PROMPT) {
          return textResponse(
            JSON.stringify({
              intent: 'test_intent',
              complexity: scenario.intentComplexity,
              requiresKnowledgeDomains: scenario.intentDomains,
              rationale: 'mocked for test/runPipeline.integration.test.ts',
            }),
          );
        }
        if (system === CATEGORY_PROMPT) {
          return textResponse(JSON.stringify({ category: scenario.category, confidence: 0.9, ambiguousBetween: [] }));
        }
        if (system === REDFLAG_PROMPT) {
          return textResponse(JSON.stringify({ proposedSeverity: scenario.proposedSeverity, reason: 'mocked' }));
        }
        if (system.startsWith(REASONING_PROMPT)) {
          return textResponse(scenario.reasoningText ?? 'Mocked reasoning brief: nothing further to add.');
        }
        throw new Error(`buildMockClient: unrecognized system prompt (first 80 chars: ${system.slice(0, 80)})`);
      }) as unknown as AnthropicLike['messages']['create'],
      stream: ((_opts: unknown) => makeMockStream(scenario.synthesisText ?? 'Mocked synthesis output.')) as unknown as AnthropicLike['messages']['stream'],
    },
  } as unknown as AnthropicLike;
}

function newCtx(message: string, sessionId: string = randomUUID(), userId: string = SEEDED_USER_ID): PipelineContext {
  const now = new Date().toISOString();
  return {
    sessionId,
    userId,
    message,
    dataRegion: 'IN',
    auditId: randomUUID(),
    receivedAt: now,
    // HP-SEC-001 RLS (db/020_rls.sql): matches userId above, same as
    // route.ts always sets it (both come from the one verified JWT) —
    // see the dedicated "HP-SEC-001 RLS" describe block below for tests
    // that deliberately mismatch these two to prove RLS, not this field
    // alone, is what gates patient_profile visibility.
    authClaims: { sub: userId, user_role: 'patient', hospital_id: null, admin_scopes: [] },
  };
}

async function drive(ctx: PipelineContext, scenario: Scenario): Promise<SseEvent[]> {
  const events: SseEvent[] = [];
  const send = (event: string, data: unknown) => events.push({ event, data });
  __setAnthropicClientForTesting(buildMockClient(scenario));
  try {
    const { runPipeline } = await import('../src/app/api/chat/route');
    await runPipeline(ctx, send);
  } finally {
    __setAnthropicClientForTesting(null);
  }
  // dispatchSideEffects is fired without being awaited by runPipeline (by
  // design — see sideEffectDispatcher.ts). Give its one fast local INSERT a
  // moment to land before the next assertion/cleanup runs, so it can never
  // race db().end() in afterAll.
  await new Promise((resolve) => setTimeout(resolve, 50));
  return events;
}

describe.skipIf(!RUN)('runPipeline integration (requires a local Postgres with db/000+010+999 applied — see README, or run `npm run test:integration`)', () => {
  beforeAll(() => {
    process.env.DATABASE_URL ??= 'postgres://hp_app:hp_app_pw@127.0.0.1:5432/hp_test';
    process.env.DATA_REGION ??= 'IN';
    process.env.SUBJECT_HMAC_KEY ??= 'base64:dGVzdC1vbmx5LXNlY3JldC1kby1ub3QtdXNlLWluLXByb2R1Y3Rpb24=';
    process.env.POLICY_VERSION ??= 'HP-SCHEMA-001-v0.4';
    process.env.RED_FLAG_RULESET_VERSION ??= 'rf-rules-2026.08.1';
    process.env.PROMPT_VERSION_COMPOSE ??= 'compose-2026.08.1';
  });

  afterAll(async () => {
    await db().end();
  });

  it('test_branch_1_emergency_short_circuit: a model-raised severity to CRITICAL renders the static template and never reaches synthesis', async () => {
    const ctx = newCtx("I'm having crushing chest pain and can't breathe");
    // Base severity from the seeded chest-pain rule is URGENT; the mocked
    // RED_FLAG_PROPOSE raise to CRITICAL is what actually triggers the
    // §4.0.5 short-circuit (clampSeverity('URGENT','CRITICAL') -> CRITICAL).
    const events = await drive(ctx, {
      intentDomains: [],
      intentComplexity: 'LOW',
      category: 'DECISION_SUPPORT', // irrelevant here — severity wins regardless of category
      proposedSeverity: 'CRITICAL',
    });

    expect(events.find((e) => e.event === 'severity')).toMatchObject({ data: { severity: 'CRITICAL' } });
    const sentences = events.filter((e) => e.event === 'sentence');
    expect(sentences).toHaveLength(1);
    // R2: what is rendered is the seeded CRITICAL template's own body, verbatim
    // — not the generic escalation copy that used to stand in for every level.
    // §4.4's time-to-care language differs per level by design, which is the
    // reason one catch-all template was the wrong shape in the first place.
    expect((sentences[0]!.data as { text: string }).text).toBe(SEEDED_CRITICAL_TEMPLATE_BODY);
    // §3.0.4-adjacent sanity: knowledge lookup must never have run on this path.
    expect(events.find((e) => e.event === 'sources')).toBeUndefined();

    const audit = await db().query('SELECT category, review_state, agg_confidence FROM response_audit WHERE id = $1', [ctx.auditId]);
    expect(audit.rows).toHaveLength(1);
    expect(audit.rows[0].category).toBe('INFORMATIONAL');
    expect(audit.rows[0].review_state).toBe('PENDING'); // §4.0.5: review required, but concurrent, not a precondition

    const rfe = await db().query('SELECT severity, action_taken, template_id, template_displayed_at, first_byte_at FROM safety.red_flag_event WHERE audit_id = $1', [ctx.auditId]);
    expect(rfe.rows).toHaveLength(1);
    expect(rfe.rows[0].severity).toBe('CRITICAL');
    expect(rfe.rows[0].action_taken).toBe('TEMPLATE_SHOWN');
    expect(rfe.rows[0].template_id).toBe(SEEDED_CRITICAL_TEMPLATE_ID); // resolved by severity+jurisdiction+language, not by the rule
    expect(rfe.rows[0].template_displayed_at).not.toBeNull(); // c_emergency_display_not_gated requires this at CRITICAL+

    const published = await db().query(`SELECT payload FROM response_audit_event WHERE audit_id = $1 AND kind = 'PUBLISHED'`, [ctx.auditId]);
    expect(published.rows).toHaveLength(1);
    expect(published.rows[0].payload.path).toBe('emergency_template');
  });

  it('test_branch_2_clinical_decision_short_circuit: category classifier alone routes to the static §2.3.6 refusal', async () => {
    const ctx = newCtx('Given my test results, do I need this surgery?');
    const events = await drive(ctx, {
      intentDomains: [],
      intentComplexity: 'LOW',
      category: 'CLINICAL_DECISION',
      proposedSeverity: 'NORMAL', // no rule matches this message, and the model doesn't raise
    });

    expect(events.find((e) => e.event === 'severity')).toMatchObject({ data: { severity: 'NORMAL' } });
    const sentences = events.filter((e) => e.event === 'sentence');
    expect(sentences).toHaveLength(1);
    expect((sentences[0]!.data as { text: string }).text).toBe(CLINICAL_DECISION_REFUSAL);
    expect(events.find((e) => e.event === 'sources')).toBeUndefined();

    const audit = await db().query('SELECT category, review_state FROM response_audit WHERE id = $1', [ctx.auditId]);
    expect(audit.rows).toHaveLength(1);
    expect(audit.rows[0].category).toBe('INFORMATIONAL');
    expect(audit.rows[0].review_state).toBe('NOT_REQUIRED');

    // NORMAL severity never crosses the §4.0.2 MONITOR floor — recordRedFlagEvent must be a no-op here.
    const rfe = await db().query('SELECT id FROM safety.red_flag_event WHERE audit_id = $1', [ctx.auditId]);
    expect(rfe.rows).toHaveLength(0);
  });

  it('test_branch_4_post_retrieval_reconciliation: a retrieved TEST_INTERPRETATION claim upgrades DECISION_SUPPORT to the refusal (§2.0.2)', async () => {
    // Matches ONLY the TEST_INTERPRETATION claim seeded in
    // db/999_seed_smoke_test.sql's MONITORING-domain row (id ...0005) via
    // websearch_to_tsquery AND-matching — the same query string
    // scripts/smoke-test.mjs already verified surfaces exactly that claim.
    const ctx = newCtx('fasting glucose reading interpretation diagnosis correlation');
    const events = await drive(ctx, {
      intentDomains: ['MONITORING'],
      intentComplexity: 'LOW',
      category: 'DECISION_SUPPORT', // the INITIAL classification — retrieval is what upgrades it
      proposedSeverity: 'NORMAL',
    });

    // Retrieval DID run on this path (unlike branches 1/2) — that's the point.
    const sources = events.find((e) => e.event === 'sources');
    expect(sources).toBeDefined();
    expect((sources!.data as { count: number; domains: string[] }).count).toBeGreaterThanOrEqual(1);
    expect((sources!.data as { domains: string[] }).domains).toContain('MONITORING');

    const sentences = events.filter((e) => e.event === 'sentence');
    expect(sentences).toHaveLength(1);
    expect((sentences[0]!.data as { text: string }).text).toBe(CLINICAL_DECISION_REFUSAL);

    const audit = await db().query('SELECT category, review_state FROM response_audit WHERE id = $1', [ctx.auditId]);
    expect(audit.rows).toHaveLength(1);
    expect(audit.rows[0].category).toBe('INFORMATIONAL');

    const published = await db().query(`SELECT payload FROM response_audit_event WHERE audit_id = $1 AND kind = 'PUBLISHED'`, [ctx.auditId]);
    expect(published.rows).toHaveLength(1);
    expect(published.rows[0].payload.path).toBe('clinical_decision_refusal_post_retrieval');
  });

  it('test_branch_normal_completion: a properly cited GUIDELINE claim streams through, gets published, and is fully audited', async () => {
    // Exact phrase already verified (scripts/smoke-test.mjs) to AND-match the
    // seeded GUIDELINE claim's tsvector via websearch_to_tsquery — extra
    // words not present in that tsvector (e.g. "recommend") make the AND
    // match fail entirely and knowledgeLookup silently returns zero rows,
    // which is exactly the kind of failure this test exists to catch, not
    // trip over by accident.
    const ctx = newCtx('HbA1c target diabetes guideline');
    const events = await drive(ctx, {
      intentDomains: ['GUIDELINE'],
      intentComplexity: 'LOW',
      category: 'DECISION_SUPPORT',
      proposedSeverity: 'NORMAL',
      reasoningText: `Relevant: [[claim:${SEEDED_GUIDELINE_CLAIM_ID}]] gives the ADA HbA1c target for this population.`,
      // The citation marker must land BEFORE the sentence-ending punctuation:
      // splitIntoSentences (emissionValidator.ts) splits on `[.!?]\s+` followed
      // by an uppercase/digit/quote/`[` — a marker placed after a trailing
      // period gets split into its own "sentence" with no numeric claim of its
      // own attached to it, leaving the actual numeric-claim sentence uncited
      // and blocked. (Found by running this test the first time — exactly the
      // §3.0.3 sentence-boundary trade-off emissionValidator.ts's own header
      // comment calls out, not a bug in that module.)
      synthesisText: `For most non-pregnant adults with type 2 diabetes, guidance commonly targets an HbA1c below 7% [[claim:${SEEDED_GUIDELINE_CLAIM_ID}]].`,
    });

    const sources = events.find((e) => e.event === 'sources');
    expect(sources).toBeDefined();
    expect((sources!.data as { count: number; domains: string[] }).count).toBe(1);
    expect((sources!.data as { domains: string[] }).domains).toEqual(['GUIDELINE']);

    const sentences = events.filter((e) => e.event === 'sentence');
    expect(sentences.length).toBeGreaterThanOrEqual(1);
    const combined = sentences.map((s) => (s.data as { text: string }).text).join(' ');
    expect(combined).toContain('HbA1c');
    expect(combined).not.toContain('[[claim:'); // marker must never leak to the visible text
    const citedIds = sentences.flatMap((s) => (s.data as { citedClaimIds: string[] }).citedClaimIds);
    expect(citedIds).toContain(SEEDED_GUIDELINE_CLAIM_ID);

    const audit = await db().query('SELECT category, review_state, agg_confidence, cited_claim_ids FROM response_audit WHERE id = $1', [ctx.auditId]);
    expect(audit.rows).toHaveLength(1);
    expect(audit.rows[0].category).toBe('DECISION_SUPPORT');
    expect(audit.rows[0].review_state).toBe('NOT_REQUIRED');
    expect(Number(audit.rows[0].agg_confidence)).toBeCloseTo(0.82, 2); // the seeded claim_source confidence
    expect(audit.rows[0].cited_claim_ids).toContain(SEEDED_GUIDELINE_CLAIM_ID);

    const content = await db().query('SELECT audit_id FROM response_content WHERE audit_id = $1', [ctx.auditId]);
    expect(content.rows).toHaveLength(1);

    const published = await db().query(`SELECT seq FROM response_audit_event WHERE audit_id = $1 AND kind = 'PUBLISHED'`, [ctx.auditId]);
    expect(published.rows).toHaveLength(1);

    // NORMAL severity — no red_flag_event row expected on the happy path either.
    const rfe = await db().query('SELECT id FROM safety.red_flag_event WHERE audit_id = $1', [ctx.auditId]);
    expect(rfe.rows).toHaveLength(0);
  });

  it('test_session_severity_floor_sticks_across_turns_in_the_same_session (§4.0.8)', async () => {
    const sessionId = randomUUID();

    // Turn 1: matches the seeded chest-pain rule -> base URGENT. Model
    // proposes no raise, so the applied severity is URGENT from the rule
    // alone (not high enough to hit the CRITICAL+ emergency short-circuit).
    const ctx1 = newCtx("I'm having crushing chest pain and can't breathe", sessionId);
    const events1 = await drive(ctx1, {
      intentDomains: [],
      intentComplexity: 'LOW',
      category: 'DECISION_SUPPORT',
      proposedSeverity: 'NORMAL',
      reasoningText: 'Mocked reasoning brief: nothing further to add.',
      synthesisText: "I don't have specific guidance to add here.",
    });
    expect(events1.find((e) => e.event === 'severity')).toMatchObject({ data: { severity: 'URGENT' } });

    const floorAfterTurn1 = await db().query('SELECT floor_severity, cleared_at FROM safety.session_severity_floor WHERE session_pseudonym = $1', [sessionPseudonym(sessionId)]);
    expect(floorAfterTurn1.rows).toHaveLength(1);
    expect(floorAfterTurn1.rows[0].floor_severity).toBe('URGENT');
    expect(floorAfterTurn1.rows[0].cleared_at).toBeNull();

    // Turn 2: same session, a message that on its own matches no rule and
    // gets no model raise (base + proposed both NORMAL). Without §4.0.8 this
    // would be NORMAL. With it, the session's still-active URGENT floor from
    // turn 1 must raise this turn to URGENT too.
    const ctx2 = newCtx('How much does a hip replacement typically cost in Chennai?', sessionId);
    const events2 = await drive(ctx2, {
      intentDomains: [],
      intentComplexity: 'LOW',
      category: 'DECISION_SUPPORT',
      proposedSeverity: 'NORMAL',
      reasoningText: 'Mocked reasoning brief: nothing further to add.',
      synthesisText: "I don't have specific guidance to add here.",
    });
    expect(events2.find((e) => e.event === 'severity')).toMatchObject({ data: { severity: 'URGENT' } });

    const severityAssigned = await db().query(
      `SELECT payload FROM response_audit_event WHERE audit_id = $1 AND kind = 'SEVERITY_ASSIGNED'`,
      [ctx2.auditId],
    );
    expect(severityAssigned.rows).toHaveLength(1);
    expect(severityAssigned.rows[0].payload.session_floor_applied).toBe(true);

    // Both turns' red_flag_event rows exist, same session_pseudonym, both URGENT.
    const events_rfe = await db().query(
      'SELECT audit_id, severity FROM safety.red_flag_event WHERE session_pseudonym = $1 ORDER BY occurred_at',
      [sessionPseudonym(sessionId)],
    );
    expect(events_rfe.rows).toHaveLength(2);
    expect(events_rfe.rows.map((r) => r.audit_id)).toEqual([ctx1.auditId, ctx2.auditId]);
    expect(events_rfe.rows.every((r) => r.severity === 'URGENT')).toBe(true);

    // The floor itself is unchanged (still URGENT, not re-lowered or duplicated).
    const floorAfterTurn2 = await db().query('SELECT floor_severity FROM safety.session_severity_floor WHERE session_pseudonym = $1', [sessionPseudonym(sessionId)]);
    expect(floorAfterTurn2.rows).toHaveLength(1);
    expect(floorAfterTurn2.rows[0].floor_severity).toBe('URGENT');
  });

  // ---------------------------------------------------------------------
  // GAP RESOLVED: "RLS policies never applied — HP-SEC-001 row-level
  // security was never installed or tested against the route (stub skips
  // RLS entirely)." db/020_rls.sql now installs it; these tests drive it
  // through the ACTUAL lookupPatientProfile function (patientProfile.ts),
  // not raw SQL — scripts/smoke-test.mjs covers the raw-SQL/multi-role
  // angle (including the hospital_profile/hospital_cost marketplace
  // pattern, which no app route touches yet). This block is specifically
  // about proving the one claim patientProfile.ts's own header comment
  // makes: that RLS, not the function's WHERE clause, is what's actually
  // deciding visibility.
  // ---------------------------------------------------------------------
  describe('HP-SEC-001 row-level security, exercised through the real lookupPatientProfile', () => {
    it('test_hp_sec_001_rls_a_patient_reading_their_own_profile_succeeds', async () => {
      const ctx = newCtx('irrelevant for this test', randomUUID(), SEEDED_USER_ID);
      const profile = await lookupPatientProfile(ctx);
      expect(profile).not.toBeNull();
      expect(profile!.userId).toBe(SEEDED_USER_ID);
      expect(profile!.statedConditions.some((c) => c.label === 'type 2 diabetes')).toBe(true);
    });

    it('test_hp_sec_001_rls_blocks_a_row_even_when_the_apps_own_where_clause_would_have_matched_it', async () => {
      // The scenario patientProfile.ts's header comment exists to guard
      // against: ctx.userId (and so the query's WHERE p.user_id = $1) points
      // at a REAL row — patient B — but ctx.authClaims.sub (what RLS
      // actually keys off) is patient A. If this function were silently
      // relying on its own WHERE clause instead of RLS, this would return
      // patient B's profile to someone authenticated as patient A. It must
      // return null instead.
      const ctx = newCtx('irrelevant for this test', randomUUID(), SEEDED_USER_ID_B);
      ctx.authClaims = { sub: SEEDED_USER_ID, user_role: 'patient', hospital_id: null, admin_scopes: [] };
      const profile = await lookupPatientProfile(ctx);
      expect(profile).toBeNull();
    });

    it('test_hp_sec_001_rls_patient_profile_own_row_keys_on_sub_not_on_role', async () => {
      // patient_profile_own_row (db/020_rls.sql) checks user_id = auth.uid()
      // only — it does not additionally require user_role = 'patient'. This
      // is deliberate (see that file's comment on why real clinician/
      // hospital_admin scope-matching isn't implemented against this stub
      // schema) but worth pinning down explicitly rather than leaving it
      // implicit: a token whose `sub` matches a real patient_profile row
      // can read that row regardless of its user_role claim, and a token
      // whose `sub` matches no row gets nothing no matter what role it
      // claims. This test is the second half — a random, unseeded sub.
      const ctx = newCtx('irrelevant for this test', randomUUID(), SEEDED_USER_ID);
      ctx.authClaims = { sub: randomUUID(), user_role: 'clinician', hospital_id: null, admin_scopes: [] };
      const profile = await lookupPatientProfile(ctx);
      expect(profile).toBeNull();
    });
  });
});
