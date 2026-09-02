#!/usr/bin/env -S npx tsx
/**
 * GAP: "No live Anthropic API call — everything still uses mocks / no real
 * model traffic." This script is the fix that could actually be built in
 * this sandbox: it calls the pipeline's REAL functions (not reimplemented
 * request bodies) against the REAL Anthropic API, using a REAL API key.
 *
 * IT HAS NOT BEEN RUN — there is no ANTHROPIC_API_KEY available to this
 * sandbox for the HealthPlus app. This was checked directly, not assumed:
 * `curl -X POST https://api.anthropic.com/v1/messages ...` with no key from
 * this exact sandbox returns a real HTTP 401 `{"type":"authentication_error",
 * "message":"x-api-key header is required"}` — proving the network path to
 * api.anthropic.com is open (it's on this sandbox's egress allowlist) and
 * the ONLY missing piece is a credential, not connectivity. Set
 * ANTHROPIC_API_KEY and DATABASE_URL (this script also needs a real
 * Postgres — every real call logs to obs.ai_call via callClaude/
 * streamClaude, same as the app itself) and run it for the first genuine
 * end-to-end validation against the live model.
 *
 * Usage:
 *   ANTHROPIC_API_KEY=sk-ant-... DATABASE_URL=postgres://hp_app:...@host/db \
 *     npm run smoke:live                    # CATEGORY_CLASSIFY + RED_FLAG_PROPOSE only (cheap, Haiku)
 *   ... npm run smoke:live -- --full        # also runs CLINICAL_REASONING + COMPOSE (Sonnet/Opus, streamed) — costs more
 *
 * DATABASE_URL must point at a database with db/000+010+020+999 already
 * applied (npm run db:migrate:stub) — this script inserts real obs.ai_call
 * rows via the app's own logging path, exactly like a real request would.
 */
import { randomUUID } from 'node:crypto';
import { classifyCategory } from '../src/lib/pipeline/categoryClassifier';
import { scanRedFlags } from '../src/lib/pipeline/redFlagEngine';
import { buildReasoningBrief } from '../src/lib/pipeline/clinicalReasoning';
import { beginSynthesis } from '../src/lib/pipeline/synthesis';
import type { PipelineContext } from '../src/lib/types';

const FULL = process.argv.includes('--full');

if (!process.env.ANTHROPIC_API_KEY) {
  console.error('live-anthropic-smoke: ANTHROPIC_API_KEY is not set. This script makes REAL, BILLED calls to the Anthropic API — set it explicitly, never hard-code it here.');
  process.exit(1);
}
if (!process.env.DATABASE_URL) {
  console.error('live-anthropic-smoke: DATABASE_URL is not set. Every real call this script makes logs to obs.ai_call (same as the app itself) — point this at a database with db/000+010+020+999 applied.');
  process.exit(1);
}

function newCtx(message: string): PipelineContext {
  const now = new Date().toISOString();
  const userId = randomUUID();
  return {
    sessionId: randomUUID(),
    userId,
    message,
    dataRegion: process.env.DATA_REGION ?? 'IN',
    auditId: randomUUID(),
    receivedAt: now,
    authClaims: { sub: userId, user_role: 'patient', hospital_id: null, admin_scopes: [] },
  };
}

async function main() {
  console.log(`live-anthropic-smoke: starting${FULL ? ' (--full: includes CLINICAL_REASONING + COMPOSE)' : ' (CATEGORY_CLASSIFY + RED_FLAG_PROPOSE only — pass --full for the whole chain)'}\n`);

  // ---- CATEGORY_CLASSIFY (Haiku) -----------------------------------------
  const ctx = newCtx('What is a typical recovery timeline after a knee replacement, generally speaking?');
  console.log('--- classifyCategory (real Haiku call) ---');
  const classification = await classifyCategory(ctx);
  console.log(JSON.stringify(classification, null, 2));
  if (!['INFORMATIONAL', 'DECISION_SUPPORT', 'CLINICAL_DECISION'].includes(classification.category)) {
    throw new Error(`unexpected category from a real model call: ${classification.category}`);
  }

  // ---- RED_FLAG_PROPOSE (Haiku, via the real scanRedFlags — also touches
  // the DB for the deterministic rule match half) -------------------------
  const ctx2 = newCtx('I have a mild headache, nothing serious.');
  console.log('\n--- scanRedFlags (real deterministic-rule DB query + real Haiku propose call) ---');
  const redFlag = await scanRedFlags(ctx2);
  console.log(JSON.stringify({ severity: redFlag.severity, ruleId: redFlag.ruleId, proposedSeverityByModel: redFlag.proposedSeverityByModel }, null, 2));

  if (!FULL) {
    console.log('\nDone (cheap path only). Re-run with --full to also exercise CLINICAL_REASONING and COMPOSE (Sonnet/Opus, real spend).');
    return;
  }

  // ---- CLINICAL_REASONING + COMPOSE (Sonnet, possibly Opus) --------------
  // No real retrieved claims here (this script doesn't stand up a full
  // seeded DB query) — beginSynthesis's own prompt explicitly handles an
  // empty claim set ("(none retrieved — say so; do not fill the gap)"), so
  // this still exercises the real prompt/model/streaming path honestly,
  // just with nothing to cite. See test/runPipeline.integration.test.ts for
  // the version of this that DOES retrieve real seeded claims (with the
  // model mocked, not live).
  const ctx3 = newCtx('How much does a hip replacement typically cost in Chennai, roughly?');
  const intent = { intent: 'cost inquiry', complexity: 'LOW' as const, requiresKnowledgeDomains: [], rationale: 'live-anthropic-smoke.ts hardcoded test intent' };
  console.log('\n--- buildReasoningBrief (real Sonnet/Opus call) ---');
  const reasoning = await buildReasoningBrief(ctx3, intent, 'DECISION_SUPPORT', []);
  console.log(`modelUsed=${reasoning.modelUsed}, text (first 300 chars):\n${reasoning.text.slice(0, 300)}`);

  console.log('\n--- beginSynthesis (real streamed Opus/Sonnet call) ---');
  const { stream, finalize } = beginSynthesis(ctx3, intent, 'DECISION_SUPPORT', null, [], reasoning);
  let fullText = '';
  for await (const chunk of stream) {
    if (chunk.type === 'content_block_delta' && chunk.delta.type === 'text_delta') {
      fullText += chunk.delta.text;
      process.stdout.write(chunk.delta.text);
    }
  }
  await finalize('OK');
  console.log(`\n\n(${fullText.length} chars streamed, logged to obs.ai_call as COMPOSE)`);

  console.log('\nDone (--full path). Every call above is now a real row in obs.ai_call — query it to see the actual cost.');
}

main().catch((err) => {
  console.error('live-anthropic-smoke: failed', err);
  process.exit(1);
});
