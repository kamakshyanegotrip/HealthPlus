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
