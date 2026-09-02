import Anthropic from '@anthropic-ai/sdk';
import { db, DATA_REGION } from './db';
import { estimateCostUsd } from './pricing';
import type { AiCallOutcome, AiCallPurpose, RedFlagSeverity } from './types';

// The subset of the Anthropic SDK surface this module actually calls —
// narrow enough that a test double doesn't need to satisfy the full
// Anthropic client shape (auth, base URL plumbing, etc.), just these two
// methods with the same signatures `callClaude`/`streamClaude` use below.
export type AnthropicLike = Pick<Anthropic, 'messages'>;

let client: Anthropic | null = null;
let clientOverride: AnthropicLike | null = null;

/**
 * GAP RESOLVED (Turn 5 punch list — "Anthropic client is constructed at
 * module scope, not injectable — blocks integration/mock testing"): the
 * real client is now built lazily on first use rather than at import time,
 * and `__setAnthropicClientForTesting` lets a test substitute a mock/stub
 * that implements just `.messages.create` / `.messages.stream` — see
 * test/runPipeline.integration.test.ts, which drives the full route.ts
 * orchestration against a real local Postgres with the model calls stubbed
 * out this way (no live Anthropic call is made by that test; a real
 * network call against the live API remains untested — see README).
 */
export function __setAnthropicClientForTesting(mock: AnthropicLike | null): void {
  clientOverride = mock;
}

function getClient(): AnthropicLike {
  if (clientOverride) return clientOverride;
  if (!client) client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
  return client;
}

export interface LoggedCallMeta {
  auditId: string;
  purpose: AiCallPurpose;
  model: string;
  promptVersion: string;
  retrievalVersion?: string;
  retrievedClaimIds?: string[];
  proposedSeverity?: RedFlagSeverity | null;
  appliedSeverity?: RedFlagSeverity | null;
}

/**
 * Fast local write to obs.ai_call. Deliberately NOT a network call to n8n —
 * HP-ADR-001 §3.2 rejects n8n on exactly this path (§4.0.5 needs synchronous
 * in-request timing; a queued workflow run is the wrong shape; §6.4 needs
 * prompts/classifiers versioned in git, which n8n doesn't support). One
 * INSERT, same connection pool as everything else in the request.
 */
async function logAiCall(meta: LoggedCallMeta, outcome: AiCallOutcome, inputTokens: number, outputTokens: number, latencyMs: number) {
  const cost = estimateCostUsd(meta.model, inputTokens, outputTokens);
  await db().query(
    `INSERT INTO obs.ai_call
       (id, audit_id, occurred_at, purpose, provider, model_version, prompt_version,
        retrieval_version, input_tokens, output_tokens, latency_ms, outcome,
        retrieved_claim_ids, proposed_severity, applied_severity, data_region)
     VALUES (gen_random_uuid(), $1, now(), $2, 'anthropic', $3, $4,
             $5, $6, $7, $8, $9,
             $10, $11, $12, $13)`,
    [
      meta.auditId,
      meta.purpose,
      meta.model,
      meta.promptVersion,
      meta.retrievalVersion ?? null,
      inputTokens,
      outputTokens,
      latencyMs,
      outcome,
      meta.retrievedClaimIds ?? [],
      meta.proposedSeverity ?? null,
      meta.appliedSeverity ?? null,
      DATA_REGION,
    ],
  );
  // Cost isn't a DB column (see pricing.ts) — surface it in structured logs
  // so it's still visible to whatever log-based cost dashboard exists.
  console.log(
    JSON.stringify({
      event: 'ai_call',
      auditId: meta.auditId,
      purpose: meta.purpose,
      model: meta.model,
      inputTokens,
      outputTokens,
      latencyMs,
      outcome,
      estCostUsd: Number.isFinite(cost) ? Number(cost.toFixed(6)) : null,
    }),
  );
}

/**
 * Non-streaming call (classifiers, red-flag propose-only channel). Always
 * logs to obs.ai_call before returning or throwing, so a model timeout still
 * leaves an audit trail (§3.13.1 requires blocks to be logged; an unlogged
 * failure is worse than a logged one).
 */
export async function callClaude(opts: {
  meta: LoggedCallMeta;
  system: string;
  messages: Anthropic.MessageParam[];
  maxTokens: number;
  temperature?: number;
}): Promise<{ text: string; inputTokens: number; outputTokens: number }> {
  const start = Date.now();
  try {
    const resp = await getClient().messages.create({
      model: opts.meta.model,
      max_tokens: opts.maxTokens,
      temperature: opts.temperature ?? 0,
      system: opts.system,
      messages: opts.messages,
    });
    const latency = Date.now() - start;
    const text = resp.content.filter((b) => b.type === 'text').map((b) => (b as Anthropic.TextBlock).text).join('');
    await logAiCall(opts.meta, 'OK', resp.usage.input_tokens, resp.usage.output_tokens, latency);
    return { text, inputTokens: resp.usage.input_tokens, outputTokens: resp.usage.output_tokens };
  } catch (err) {
    const latency = Date.now() - start;
    const timedOut = err instanceof Anthropic.APIError && err.status === 408;
    await logAiCall(opts.meta, timedOut ? 'TIMEOUT' : 'ERROR', 0, 0, latency);
    throw err;
  }
}

/**
 * Streaming call for the synthesis step. Returns the raw Anthropic stream —
 * the caller (emissionValidator) consumes it token by token, buffers into
 * sentences, and is responsible for calling `finalize()` once the stream
 * ends so the ai_call row (with real usage numbers) is still written.
 */
export function streamClaude(opts: {
  meta: LoggedCallMeta;
  system: string;
  messages: Anthropic.MessageParam[];
  maxTokens: number;
  temperature?: number;
}) {
  const start = Date.now();
  const stream = getClient().messages.stream({
    model: opts.meta.model,
    max_tokens: opts.maxTokens,
    temperature: opts.temperature ?? 0.3,
    system: opts.system,
    messages: opts.messages,
  });

  async function finalize(outcome: AiCallOutcome) {
    const latency = Date.now() - start;
    try {
      const final = await stream.finalMessage();
      await logAiCall(opts.meta, outcome, final.usage.input_tokens, final.usage.output_tokens, latency);
    } catch {
      await logAiCall(opts.meta, outcome === 'OK' ? 'ERROR' : outcome, 0, 0, latency);
    }
  }

  return { stream, finalize };
}
