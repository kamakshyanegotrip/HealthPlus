import { randomUUID } from 'node:crypto';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { PipelineContext, ResponseCategory, RedFlagSeverity } from '../src/lib/types';
import { newPendingTelemetry } from '../src/lib/types';
import { loadPrompt } from '../src/lib/prompts/registry';
import { CLINICAL_DECISION_REFUSAL } from '../src/lib/prompts/annexB';
import { __setAnthropicClientForTesting, type AnthropicLike } from '../src/lib/anthropic';
import { db } from '../src/lib/db';
import { sessionPseudonym } from '../src/lib/pseudonymize';
import type { SubjectKey } from '../src/lib/subjectKey';
import {
  seedRealSchema,
  endSeedPool,
  seedQuery,
  SEED,
  SEEDED_CRITICAL_TEMPLATE_BODY,
} from '../scripts/seed-real';

/**
 * The orchestration test, moved off the stub schema (R10f).
 *
 * It drives the ACTUAL `runPipeline` (exported from src/app/api/chat/route.ts)
 * against a real Postgres with `migrations/` applied and `scripts/seed-real.ts`
 * run, with the Anthropic client swapped for a scripted mock. No live Anthropic
 * call is made anywhere in this file. What it exercises that nothing else does
 * is the BRANCHING inside `runPipeline` — which of its exit points a given
 * combination of category, severity and retrieval actually reaches — rather
 * than each step's SQL or each step's pure logic in isolation.
 *
 * ---------------------------------------------------------------------------
 * WHAT CHANGED IN THE MOVE, BEYOND TABLE NAMES
 *
 * Three things, and none of them is cosmetic:
 *
 * 1. THE FIXTURE IS BUILT BY THE CODE UNDER TEST. `db/999_seed_smoke_test.sql`
 *    wrote rows by hand; `seed-real.ts` mints subject keys and encrypts
 *    attributes through `subjectKey.ts` itself. A hand-written fixture is how
 *    the stub came to disagree with the schema in twelve places.
 *
 * 2. EVERY TURN NEEDS A SUBJECT KEY. `PipelineContext.subjectKey` is required,
 *    because every pseudonym written in one turn must derive from one salt.
 *    `newCtx` below takes the key from the seed rather than minting its own,
 *    so a test asserting on a pseudonym is asserting on the same namespace the
 *    seed wrote under.
 *
 * 3. THE §2.0.2 BRANCH TEST IS GONE, AND ITS REPLACEMENT ASSERTS WHY. See
 *    `test_2_0_2_post_retrieval_reconciliation_is_unreachable` below. This is
 *    the one substantive finding of the move and it is not a table rename.
 *
 * ---------------------------------------------------------------------------
 * NOT HERE: the RLS block. `lookupPatientProfile`'s behaviour under
 * `principal.*` row-level security lives in `test/patientProfile.db.test.ts`,
 * which also states what a passing run there cannot prove (superuser-owned
 * objects make FORCE RLS inert locally) and which gate covers that instead.
 * Duplicating a weaker version of it here would be worse than not having it.
 *
 * Requires RUN_PIPELINE_INTEGRATION=1, a database with `migrations/` applied,
 * and both DATABASE_URL (the application role) and SEED_DATABASE_URL (an owner
 * role) set. `npm run test:integration` does the first.
 */

const RUN = process.env.RUN_PIPELINE_INTEGRATION === '1';

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
 * `LoggedCallMeta.purpose` (that's an application-level field, logged but never
 * sent to the API) — so this mock, like the real API, only sees {model, system,
 * messages, ...}. It distinguishes which of the pipeline's four LLM-facing
 * steps is calling by matching `system` against the exact prompt text each step
 * loads from the registry.
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

/**
 * The seeded fixtures, resolved once in beforeAll. Module-level so `newCtx` can
 * reach the keys without every call site threading them.
 */
let keys: Record<'adult' | 'unknownAge' | 'other', SubjectKey>;
let seededRegion: string;

type Who = 'adult' | 'unknownAge' | 'other';
const USER_ID: Record<Who, string> = {
  adult: SEED.adultUser,
  unknownAge: SEED.unknownAgeUser,
  other: SEED.otherUser,
};

function newCtx(message: string, sessionId: string = randomUUID(), who: Who = 'adult'): PipelineContext {
  const userId = USER_ID[who];
  return {
    sessionId,
    userId,
    message,
    dataRegion: seededRegion,
    auditId: randomUUID(),
    receivedAt: new Date().toISOString(),
    authClaims: { sub: userId, user_role: 'patient', hospital_id: null, admin_scopes: [] },
    // Resolved once per turn and carried, exactly as route.ts does it. Taken
    // from the seed rather than minted here so that a pseudonym asserted below
    // is derived from the same salt the seeded rows were written under.
    subjectKey: keys[who],
    pending: newPendingTelemetry(),
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
  // design — see sideEffectDispatcher.ts). Give it a moment to finish before
  // the next assertion or cleanup runs, so it can never race db().end().
  await new Promise((resolve) => setTimeout(resolve, 50));
  return events;
}

describe.skipIf(!RUN)('runPipeline integration (real schema — migrations/ + scripts/seed-real.ts; see README)', () => {
  beforeAll(async () => {
    process.env.POLICY_VERSION ??= 'HP-SCHEMA-001-v0.4';
    process.env.PROMPT_VERSION_COMPOSE ??= 'compose-2026.08.1';
    const seeded = await seedRealSchema();
    keys = seeded.keys;
    seededRegion = seeded.region.region;
  }, 60_000);

  afterAll(async () => {
    await endSeedPool().catch(() => {});
    await db().end().catch(() => {});
    await db('reasoner').end().catch(() => {});
    await db('redflag').end().catch(() => {});
  });

  it('test_branch_1_emergency_short_circuit: a model-raised severity to CRITICAL renders the static template and never reaches synthesis', async () => {
    const ctx = newCtx("I'm having crushing chest pain and can't breathe");
    // Base severity from the seeded chest-pain rule is URGENT; the mocked
    // RED_FLAG_PROPOSE raise to CRITICAL is what actually triggers the §4.0.5
    // short-circuit (clampSeverity('URGENT','CRITICAL') -> CRITICAL).
    const events = await drive(ctx, {
      intentDomains: [],
      intentComplexity: 'LOW',
      category: 'DECISION_SUPPORT', // irrelevant here — severity wins regardless of category
      proposedSeverity: 'CRITICAL',
    });

    expect(events.find((e) => e.event === 'severity')).toMatchObject({ data: { severity: 'CRITICAL' } });
    const sentences = events.filter((e) => e.event === 'sentence');
    expect(sentences).toHaveLength(1);
    // The seeded CRITICAL template's own body, verbatim — §4.4's time-to-care
    // language differs per level, which is why one catch-all template was the
    // wrong shape.
    expect((sentences[0]!.data as { text: string }).text).toBe(SEEDED_CRITICAL_TEMPLATE_BODY);
    // Knowledge lookup must never have run on this path.
    expect(events.find((e) => e.event === 'sources')).toBeUndefined();

    const audit = await seedQuery(
      'SELECT category, review_state, agg_confidence FROM obs.response_audit WHERE id = $1',
      [ctx.auditId],
    );
    expect(audit).toHaveLength(1);
    expect(audit[0].category).toBe('INFORMATIONAL');
    // NOT 'PENDING', which is what this asserted under the stub.
    // `c_emergency_not_gated` refuses a CRITICAL/EMERGENCY row in PENDING —
    // §4.0.5 forbids an emergency display being gated on review, and a row
    // that is both is a contradiction the schema will not store. The review
    // obligation travels on the clinician alert the red_flag_event trigger
    // raises; the assertion below is that it actually did.
    expect(audit[0].review_state).toBe('NOT_REQUIRED');

    const rfe = await seedQuery(
      `SELECT severity, action_taken, template_id, template_displayed_at
         FROM safety.red_flag_event WHERE audit_id = $1`,
      [ctx.auditId],
    );
    expect(rfe).toHaveLength(1);
    expect(rfe[0].severity).toBe('CRITICAL');
    expect(rfe[0].action_taken).toBe('TEMPLATE_SHOWN');
    // Resolved by the §4.3.3 ladder on (severity, jurisdiction, language) —
    // not by an FK on the rule row.
    expect(rfe[0].template_id).toBe(SEED.criticalTemplate);
    expect(rfe[0].template_displayed_at).not.toBeNull(); // c_emergency_display_not_gated

    // Where the §4.0.5 review obligation actually lives now. `red_flag_event`
    // carries trg_raise_alert_for_event (raises it) and trg_event_requires_alert
    // (refuses the event row without one), so this is the database's guarantee
    // rather than the application's — but it is asserted because the audit row
    // above no longer records the obligation and something must.
    const alerts = await seedQuery(
      `SELECT a.id FROM safety.clinician_alert a
         JOIN safety.red_flag_event e ON e.id = a.event_id
        WHERE e.audit_id = $1`,
      [ctx.auditId],
    );
    expect(alerts.length).toBeGreaterThanOrEqual(1);

    const published = await seedQuery(
      `SELECT payload FROM response_audit_event WHERE audit_id = $1 AND kind = 'PUBLISHED'`,
      [ctx.auditId],
    );
    expect(published).toHaveLength(1);
    expect(published[0].payload.path).toBe('emergency_template');
  });

  it('test_branch_2_clinical_decision_short_circuit: the category classifier alone routes to the static §2.3.6 refusal', async () => {
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

    const audit = await seedQuery(
      'SELECT category, review_state FROM obs.response_audit WHERE id = $1',
      [ctx.auditId],
    );
    expect(audit).toHaveLength(1);
    expect(audit[0].category).toBe('INFORMATIONAL');
    expect(audit[0].review_state).toBe('NOT_REQUIRED');

    // NORMAL never crosses the §4.0.2 MONITOR floor — recordRedFlagEvent is a no-op.
    const rfe = await seedQuery('SELECT id FROM safety.red_flag_event WHERE audit_id = $1', [ctx.auditId]);
    expect(rfe).toHaveLength(0);
  });

  /**
   * WHAT USED TO BE `test_branch_4_post_retrieval_reconciliation`.
   *
   * The stub-era test drove a message that retrieved a TEST_INTERPRETATION
   * claim and asserted that route.ts's §2.0.2 re-check upgraded the response to
   * CLINICAL_DECISION and refused. It passed. It cannot be ported, and the
   * reason is the finding rather than an inconvenience:
   *
   *   `db/999_seed_smoke_test.sql` inserted its own `evidence.claim_policy` row
   *   making (TIER_2, TEST_INTERPRETATION, DECISION_SUPPORT) PERMITTED. That row
   *   is labelled 'SMOKE-TEST' in the fixture itself. The adopted policy in
   *   `migrations/` says PROHIBITED — at every one of the fifteen (tier,
   *   category) pairs, which is §3.1/§3.1.7's position that TEST_INTERPRETATION
   *   is a deny-only kind.
   *
   * So the branch at route.ts's `claims.some(c => c.kind === 'TEST_INTERPRETATION')`
   * is unreachable against the real schema, and it is unreachable twice over:
   *
   *   (a) a TEST_INTERPRETATION claim cannot be BOUND to the retrieval registry
   *       at all — no `domain_attribute_kind` row expects that kind, and
   *       `evidence.assert_attribute_claim_kind()` raises HP-ESC 1.5.3 on the
   *       attempt. Unbound means `claim_search`'s scoped CTE never sees it.
   *   (b) even bound, `knowledgeLookup` filters `pol.disposition <> 'PROHIBITED'`
   *       before the claim reaches route.ts.
   *
   * This test asserts BOTH walls rather than deleting the case. The logic of
   * `reconcileAfterRetrieval` is already covered as a pure function in
   * test/categoryClassifier.test.ts, so nothing is lost there; what this adds is
   * that the walls are monitored. If someone registers a slot for the kind, or
   * flips a policy row to make one retrievable, this goes red and the §2.0.2
   * branch becomes live code again — which is a decision for the clinical lead
   * (HP-SR-001 §2.2.5), not a silent consequence of a data change.
   *
   * OPEN, AND RECORDED RATHER THAN RESOLVED HERE: §2.0.2 wants a question that
   * turns out to hinge on test interpretation to be REFUSED. What the real
   * schema does instead is drop the prohibited claim from retrieval and answer
   * from whatever else was retrieved. Nothing unsourced is emitted, so this is
   * not a §3.0.3 hole — but the refusal §2.0.2 asks for does not happen, and
   * whether that is acceptable is a Charter question.
   */
  it('test_2_0_2_post_retrieval_reconciliation_is_unreachable: TEST_INTERPRETATION can be neither bound nor retrieved', async () => {
    // Wall (a): no registry slot expects the kind.
    const slots = await seedQuery<{ n: string }>(
      `SELECT count(*) AS n FROM evidence.domain_attribute_kind
        WHERE expected_claim_kind = 'TEST_INTERPRETATION'`,
    );
    expect(Number(slots[0].n)).toBe(0);

    // Wall (b): every policy row for the kind is PROHIBITED, and there is at
    // least one — an EMPTY policy set would also make the disposition filter
    // drop the claim, but for the opposite reason (§3.0.3's default-deny), and
    // the two must not be confused.
    const policy = await seedQuery<{ disposition: string; n: string }>(
      `SELECT disposition, count(*) AS n FROM evidence.claim_policy
        WHERE kind = 'TEST_INTERPRETATION' GROUP BY disposition`,
    );
    expect(policy).toHaveLength(1);
    expect(policy[0].disposition).toBe('PROHIBITED');
    expect(Number(policy[0].n)).toBeGreaterThan(0);

    // And no fixture has quietly re-introduced the stub's override.
    const permitted = await seedQuery<{ n: string }>(
      `SELECT count(*) AS n FROM evidence.claim_policy
        WHERE kind = 'TEST_INTERPRETATION' AND disposition <> 'PROHIBITED'`,
    );
    expect(Number(permitted[0].n)).toBe(0);
  });

  it('test_branch_normal_completion: a properly cited GUIDELINE claim streams through, gets published, and is fully audited', async () => {
    // `evidence.retrieval_chunk.tsv` is `to_tsvector('simple', body)` — SIMPLE,
    // so there is no stemming and a query word must appear in the body
    // verbatim. websearch_to_tsquery ANDs the terms, so one absent word makes
    // the whole match fail and retrieval returns zero rows silently. All three
    // words below are in the seeded chunk.
    const ctx = newCtx('light walking recovery');
    const events = await drive(ctx, {
      intentDomains: ['GUIDELINE'],
      intentComplexity: 'LOW',
      category: 'DECISION_SUPPORT',
      proposedSeverity: 'NORMAL',
      reasoningText: `Relevant: [[claim:${SEED.guidelineClaim}]] covers early mobilisation after an uncomplicated procedure.`,
      // The citation marker must land BEFORE the sentence-ending punctuation:
      // splitIntoSentences splits on `[.!?]\s+` followed by uppercase/digit/
      // quote/`[`, so a marker after a trailing period becomes its own
      // "sentence" and leaves the numeric claim uncited — and therefore
      // blocked. That is emissionValidator's documented sentence-boundary
      // trade-off, not a bug.
      synthesisText: `Guidance commonly suggests resuming light walking within 24 to 48 hours after an uncomplicated procedure [[claim:${SEED.guidelineClaim}]].`,
    });

    const sources = events.find((e) => e.event === 'sources');
    expect(sources).toBeDefined();
    expect((sources!.data as { count: number }).count).toBe(1);
    expect((sources!.data as { domains: string[] }).domains).toEqual(['GUIDELINE']);

    const sentences = events.filter((e) => e.event === 'sentence');
    expect(sentences.length).toBeGreaterThanOrEqual(1);
    const combined = sentences.map((s) => (s.data as { text: string }).text).join(' ');
    expect(combined).toContain('light walking');
    expect(combined).not.toContain('[[claim:'); // the marker must never leak into visible text
    const citedIds = sentences.flatMap((s) => (s.data as { citedClaimIds: string[] }).citedClaimIds);
    expect(citedIds).toContain(SEED.guidelineClaim);

    const audit = await seedQuery(
      'SELECT category, review_state, agg_confidence, cited_claim_ids FROM obs.response_audit WHERE id = $1',
      [ctx.auditId],
    );
    expect(audit).toHaveLength(1);
    expect(audit[0].category).toBe('DECISION_SUPPORT');
    expect(audit[0].review_state).toBe('NOT_REQUIRED');
    expect(Number(audit[0].agg_confidence)).toBeCloseTo(0.86, 2); // the seeded claim_source confidence
    expect(audit[0].cited_claim_ids).toContain(SEED.guidelineClaim);

    const content = await seedQuery('SELECT audit_id, key_id FROM obs.response_content WHERE audit_id = $1', [ctx.auditId]);
    expect(content).toHaveLength(1);
    // obs.response_content.key_id is NOT NULL with an FK to principal.subject_key.
    // Under the stub this column did not exist and the content was encrypted
    // under a process-wide placeholder; the row now names the subject's key,
    // which is what makes erasure reach the stored response.
    expect(content[0].key_id).toBe(keys.adult.keyId);

    const published = await seedQuery(
      `SELECT seq FROM response_audit_event WHERE audit_id = $1 AND kind = 'PUBLISHED'`,
      [ctx.auditId],
    );
    expect(published).toHaveLength(1);

    const rfe = await seedQuery('SELECT id FROM safety.red_flag_event WHERE audit_id = $1', [ctx.auditId]);
    expect(rfe).toHaveLength(0);
  });

  it('test_unknown_age_forces_review: the SAME response that publishes for a confirmed adult is held for review when age was never established (§2.4.3 / §3.0.3)', async () => {
    // Deliberately a twin of the test above: identical message, identical
    // scenario, identical claim. The ONLY difference is which patient asks, so
    // a divergence in review_state is attributable to §2.4.3's gate and to
    // nothing else. The contrast is the test; the value alone is not.
    //
    // This is the case HP-SR-001 §4 found. Under `profile?.isMinor === true`
    // this user resolved to "adult" and the response published. Against the
    // real schema the subject has no age risk flag at all, `deriveIsMinor`
    // returns null, and §3.0.3 resolves that closed.
    const ctx = newCtx('light walking recovery', randomUUID(), 'unknownAge');

    const events = await drive(ctx, {
      intentDomains: ['GUIDELINE'],
      intentComplexity: 'LOW',
      category: 'DECISION_SUPPORT',
      proposedSeverity: 'NORMAL',
      reasoningText: `Relevant: [[claim:${SEED.guidelineClaim}]] covers early mobilisation after an uncomplicated procedure.`,
      synthesisText: `Guidance commonly suggests resuming light walking within 24 to 48 hours after an uncomplicated procedure [[claim:${SEED.guidelineClaim}]].`,
    });

    // Retrieval and synthesis are unaffected — the gate changes disposition,
    // not content. A divergence here would mean the fix is doing something it
    // was not meant to do.
    expect((events.find((e) => e.event === 'sources')!.data as { count: number }).count).toBe(1);
    const sentences = events.filter((e) => e.event === 'sentence');
    expect(sentences.map((x) => (x.data as { text: string }).text).join(' ')).toContain('light walking');

    const audit = await seedQuery(
      'SELECT category, review_state FROM obs.response_audit WHERE id = $1',
      [ctx.auditId],
    );
    expect(audit).toHaveLength(1);
    expect(audit[0].category).toBe('DECISION_SUPPORT');
    expect(audit[0].review_state).toBe('PENDING'); // the twin asserts NOT_REQUIRED on these exact inputs

    // §2.2.5b's disposition is REVIEW_REQUESTED, not PUBLISHED.
    const published = await seedQuery(
      `SELECT seq FROM response_audit_event WHERE audit_id = $1 AND kind = 'PUBLISHED'`,
      [ctx.auditId],
    );
    expect(published).toHaveLength(0);
    const requested = await seedQuery(
      `SELECT payload FROM response_audit_event WHERE audit_id = $1 AND kind = 'REVIEW_REQUESTED'`,
      [ctx.auditId],
    );
    expect(requested).toHaveLength(1);
    expect(requested[0].payload.review_required).toBe(true);

    // WHICH triggers, end to end. Before SR-1 closed, the audit row said only
    // THAT review was required — which reads identically whether five triggers
    // were evaluated or three were never implemented.
    const triggers: string[] = requested[0].payload.review_triggers;
    expect(triggers).toContain('MINOR_GATE');

    // And §2.2.5b trigger 2 is CLEAR here, not merely quiet. The seed adopts
    // topic 6 with terms this message does not contain, so the topic gate ran
    // and found nothing — which is the state that CANNOT be reached if the
    // topic list is unadopted, and is therefore the assertion that proves the
    // fixture is doing its job.
    expect(triggers).not.toContain('ELEVATED_TOPIC');
    expect(triggers).not.toContain('ELEVATED_TOPIC_UNEVALUABLE');
  });

  it('test_elevated_topic_forces_review: a message on an adopted §2.4.1 topic is held for review (§2.2.5b trigger 2)', async () => {
    // The third twin of the pair above: same claim, same scenario, same ADULT
    // subject whose age IS established — so the minor gate does NOT fire and a
    // review disposition is attributable to the topic gate alone.
    //
    // HP-SR-001 recorded this trigger as having "no implementation anywhere:
    // no topic classifier, no list, no lookup". This is the end-to-end proof
    // that a message touching one of the Charter's fourteen topics now reaches
    // the review queue rather than publishing.
    // THE MESSAGE IS THE TWIN'S, UNCHANGED. Adding a topic word to it was tried
    // first and is the wrong instrument: `evidence.claim_search` stops matching
    // the seeded claim, retrieval returns nothing, and the response is held for
    // review because it is UNCITED — so PENDING would prove nothing about the
    // topic gate. The fixture moves instead of the message.
    //
    // Topic 7 is adopted here rather than in seed-real.ts, with a term this
    // message contains, and retired again below. Seeding it would make every
    // other test's topic check MATCHED and destroy the contrast the suite is
    // built on.
    await seedQuery(
      `UPDATE safety.elevated_risk_topic
          SET terms = ARRAY['walking'], clinically_adopted = true,
              adopted_by = $1, adopted_at = now()
        WHERE ordinal = 7 AND language = 'en'`,
      [SEED.clinician],
    );
    const ctx = newCtx('light walking recovery');

    try {
    const events = await drive(ctx, {
      intentDomains: ['GUIDELINE'],
      intentComplexity: 'LOW',
      category: 'DECISION_SUPPORT',
      proposedSeverity: 'NORMAL',
      reasoningText: `Relevant: [[claim:${SEED.guidelineClaim}]] covers early mobilisation after an uncomplicated procedure.`,
      synthesisText: `Guidance commonly suggests resuming light walking within 24 to 48 hours after an uncomplicated procedure [[claim:${SEED.guidelineClaim}]].`,
    });

    // Content is unaffected — the gate changes disposition, not what is said.
    const sentences = events.filter((e) => e.event === 'sentence');
    expect(sentences.map((x) => (x.data as { text: string }).text).join(' ')).toContain('light walking');

    const audit = await seedQuery(
      'SELECT review_state FROM obs.response_audit WHERE id = $1',
      [ctx.auditId],
    );
    expect(audit[0].review_state).toBe('PENDING');

    const requested = await seedQuery(
      `SELECT payload FROM response_audit_event WHERE audit_id = $1 AND kind = 'REVIEW_REQUESTED'`,
      [ctx.auditId],
    );
    expect(requested).toHaveLength(1);
    const triggers: string[] = requested[0].payload.review_triggers;
    expect(triggers).toContain('ELEVATED_TOPIC');
    // NOT the minor gate (this subject's age is established as adult), NOT
    // uncited (the claim was retrieved), NOT below the floor. Asserted so the
    // test cannot pass for any reason except the one it is named after — the
    // twin publishes on these exact inputs.
    expect(triggers).not.toContain('MINOR_GATE');
    expect(triggers).not.toContain('UNCITED');
    expect(triggers).toEqual(['ELEVATED_TOPIC']);
    } finally {
      await seedQuery(
        `UPDATE safety.elevated_risk_topic
            SET terms = '{}', clinically_adopted = false, adopted_by = NULL, adopted_at = NULL
          WHERE ordinal = 7 AND language = 'en'`,
      );
    }
  });

  it('test_session_severity_floor_sticks_across_turns_in_the_same_session (§4.0.8)', async () => {
    const sessionId = randomUUID();
    // Every pseudonym in this test derives from the ADULT subject's salt,
    // because §4.0.8's floor is keyed on a session pseudonym salted with the
    // subject's own key — not a process-wide secret. That is what makes
    // erasure sever the session linkage too (pseudonymize.ts's header).
    const pseudo = sessionPseudonym(sessionId, keys.adult.salt);

    // Turn 1: matches the seeded chest-pain rule -> base URGENT. The model
    // proposes no raise, so URGENT comes from the rule alone — not high enough
    // for the CRITICAL+ emergency short-circuit.
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

    const floor1 = await seedQuery(
      'SELECT floor_severity, cleared_at FROM safety.session_severity_floor WHERE session_pseudonym = $1',
      [pseudo],
    );
    expect(floor1).toHaveLength(1);
    expect(floor1[0].floor_severity).toBe('URGENT');
    expect(floor1[0].cleared_at).toBeNull();

    // Turn 2: same session, a message that on its own matches no rule and gets
    // no model raise. Without §4.0.8 this is NORMAL; with it, the session's
    // still-active URGENT floor raises this turn too.
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

    const severityAssigned = await seedQuery(
      `SELECT payload FROM response_audit_event WHERE audit_id = $1 AND kind = 'SEVERITY_ASSIGNED'`,
      [ctx2.auditId],
    );
    expect(severityAssigned).toHaveLength(1);
    expect(severityAssigned[0].payload.session_floor_applied).toBe(true);

    const rfeRows = await seedQuery(
      'SELECT audit_id, severity FROM safety.red_flag_event WHERE session_pseudonym = $1 ORDER BY occurred_at',
      [pseudo],
    );
    expect(rfeRows).toHaveLength(2);
    expect(rfeRows.map((r) => r.audit_id)).toEqual([ctx1.auditId, ctx2.auditId]);
    expect(rfeRows.every((r) => r.severity === 'URGENT')).toBe(true);

    const floor2 = await seedQuery(
      'SELECT floor_severity FROM safety.session_severity_floor WHERE session_pseudonym = $1',
      [pseudo],
    );
    expect(floor2).toHaveLength(1);
    expect(floor2[0].floor_severity).toBe('URGENT');
  });
});
