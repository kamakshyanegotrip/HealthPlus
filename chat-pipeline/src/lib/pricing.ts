import type { AiCallPurpose } from './types';

/**
 * Per-MTok pricing, USD. Source: HP-ADR-001 §3.6 "Model layer".
 *
 * obs.ai_call (HP-SCHEMA-001-Annex-A migration 005) has input_tokens,
 * output_tokens and latency_ms columns but deliberately no cost column —
 * cost is a derived quantity, not a fact about the call, and §6.3 change
 * control gates schema additions rather than a code constant unilaterally
 * deciding the number.
 *
 * DURABLE COST NOW EXISTS: db/010_chat_pipeline_support.sql adds
 * `obs.model_pricing` (a §6.3-style reference table — versioned,
 * `adopted_by`/`effective_from`, PROVISIONAL until signed off, same pattern
 * as `claim_policy`) and `obs.ai_call_cost`, a view joining every ai_call
 * row to the pricing row in effect at `occurred_at`. Query THAT for durable,
 * queryable per-call or aggregate cost — it was verified against a real
 * Postgres instance in scripts/smoke-test.mjs.
 *
 * This module's `MODEL_PRICING_USD_PER_MTOK` constant and
 * `estimateCostUsd()` still exist for the structured console log line
 * `anthropic.ts` emits alongside every DB write — a same-process estimate
 * for local debugging/dashboards that don't want a DB round trip, not the
 * system of record. Keep the two in sync manually until obs.model_pricing
 * is adopted and this constant can be deleted in favour of reading the
 * table directly.
 */
export const MODEL_PRICING_USD_PER_MTOK: Record<string, { input: number; output: number }> = {
  'claude-haiku-4-5': { input: 1, output: 5 },
  'claude-sonnet-5': { input: 2, output: 10 },
  'claude-opus-5': { input: 5, output: 25 },
};

export function estimateCostUsd(model: string, inputTokens: number, outputTokens: number): number {
  const rate = MODEL_PRICING_USD_PER_MTOK[model];
  if (!rate) return NaN;
  return (inputTokens / 1_000_000) * rate.input + (outputTokens / 1_000_000) * rate.output;
}

/**
 * Model tiering per HP-ADR-001 §3.6: "Haiku 4.5 for the §2.0.1 category
 * classifier and cheap extraction; Sonnet 5 for user-facing generation;
 * Opus 5 for offline claim extraction and conflict resolution."
 *
 * DEVIATION FLAGGED: the pipeline spec this module implements asks for Opus
 * on the live, user-facing PERSONALIZED RECOMMENDATION SYNTHESIS step, and
 * for Sonnet-escalating-to-Opus on CLINICAL & DIAGNOSTIC REASONING when the
 * complexity score is high. HP-ADR-001 reserves Opus for *offline* work only
 * (claim extraction / conflict resolution) specifically because that ADR is
 * "reversal cost: LOW" and was written before this pipeline's complexity
 * requirements were specified. This constant is therefore intentionally
 * configurable rather than hard-coded to the ADR's letter — set
 * ALLOW_OPUS_ON_LIVE_PATH=false to fall back strictly to Sonnet-only
 * user-facing generation and stay literally inside HP-ADR-001 §3.6 until
 * that ADR is amended or the founder confirms the deviation. Either way,
 * every ai_call row records which model actually ran, so the deviation
 * (if taken) is auditable, not silent.
 */
export const ALLOW_OPUS_ON_LIVE_PATH = process.env.ALLOW_OPUS_ON_LIVE_PATH !== 'false';

export const MODELS = {
  HAIKU: 'claude-haiku-4-5',
  SONNET: 'claude-sonnet-5',
  OPUS: 'claude-opus-5',
} as const;

/**
 * MODELS THAT REJECT `temperature`, and the defect that found them.
 *
 * The Anthropic API returns `400 invalid_request_error: "temperature is
 * deprecated for this model."` for the newer models. Sending it is not ignored
 * and not warned about — the whole request is refused.
 *
 * `anthropic.ts` sent `temperature` on EVERY call (`?? 0` for callClaude,
 * `?? 0.3` for streamClaude). Against the tiering HP-ADR-001 §3.6 sets, that
 * means the composer could not make a single successful call: every COMPOSE
 * request to Opus 5 died with a 400 before a token was generated. So did the
 * reasoning brief whenever `intentComplexity` said HIGH, or whenever
 * ALLOW_OPUS_ON_LIVE_PATH was false and it ran on Sonnet 5.
 *
 * NOTHING IN THE REPOSITORY COULD HAVE CAUGHT THIS. Every test stubs the
 * Anthropic client through `__setAnthropicClientForTesting`, and a stub accepts
 * any arguments it is handed. The §6.4 eval gate is pure functions. The
 * integration suite drives real Postgres but a mocked model. The defect lives
 * exactly in the gap the live composer eval was written to cover, and that eval
 * is what surfaced it, on its first genuine run (11 Sep 2026, on the founder's
 * machine — the first real Anthropic call this pipeline has ever made).
 *
 * DENY-LIST RATHER THAN OMIT-ALWAYS, deliberately. `temperature: 0` is worth
 * keeping where it is still accepted: the category classifier and the red-flag
 * propose channel are safety-adjacent, and determinism in their sampling is a
 * property worth having rather than surrendering for tidiness. Haiku 4.5 still
 * accepts it and is what both of those run on.
 *
 * WHEN THIS LIST IS WRONG: a 400 naming `temperature` means the model in the
 * error belongs here. Add it. Do not "fix" it by deleting the parameter
 * everywhere — that silently drops determinism from the classifiers, which is
 * a safety property, to work around a billing-tier API change.
 */
const TEMPERATURE_REJECTED_BY: readonly string[] = [MODELS.SONNET, MODELS.OPUS];

export function supportsTemperature(model: string): boolean {
  return !TEMPERATURE_REJECTED_BY.includes(model);
}

export function purposeDefaultModel(purpose: AiCallPurpose): string {
  switch (purpose) {
    case 'CATEGORY_CLASSIFY':
    case 'RED_FLAG_PROPOSE':
    case 'EXTRACT':
    case 'RERANK':
    case 'TRANSLATE': // never for safety-critical text, §4.3.4 — caller enforces
      return MODELS.HAIKU;
    case 'COMPOSE':
      return MODELS.SONNET;
    default:
      return MODELS.SONNET;
  }
}
