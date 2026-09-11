import Anthropic from '@anthropic-ai/sdk';
import { db, DATA_REGION } from './db';
import { estimateCostUsd, supportsTemperature } from './pricing';
import type { AiCallOutcome, AiCallPurpose, PipelineContext, RedFlagSeverity } from './types';

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
  /**
   * Was a bare `auditId: string`. It carries the context now because
   * obs.record_ai_call no longer TAKES an audit id: the row is written with
   * audit_id NULL and its id collected on ctx.pending for upsertResponseAudit to
   * backfill (migration 039 §3). The audit id is still here — through the ctx —
   * because the structured cost log below is keyed on it, and that log is
   * written before the audit row exists.
   */
  ctx: Pick<PipelineContext, 'auditId' | 'pending'>;
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
  // AUDIT_ID IS NOT PASSED, and its absence is the fix rather than an omission.
  // obs.ai_call.audit_id is a real FK to obs.response_audit(id), and that row is
  // written at the END of the turn — so every one of these inserts named a
  // parent that did not exist yet and would have failed with
  // `ai_call_audit_id_fkey` the first time it ran against the real schema. The
  // row is written unattached and re-parented by obs.attach_pending once the
  // audit row lands (migration 039's header states the trade in full).
  const { rows } = await db().query<{ record_ai_call: string }>(
    `SELECT obs.record_ai_call(
       $1::ai_call_purpose, $2, $3, $4, $5, $6, $7, $8::ai_call_outcome,
       $9, $10::red_flag_severity, $11::red_flag_severity, $12) AS record_ai_call`,
    [
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
  const id = rows[0]?.record_ai_call;
  if (id) meta.ctx.pending.aiCalls.push(id);
  // Cost isn't a DB column (see pricing.ts) — surface it in structured logs
  // so it's still visible to whatever log-based cost dashboard exists.
  console.log(
    JSON.stringify({
      event: 'ai_call',
      auditId: meta.ctx.auditId,
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
      // §HP-JOB-011.6 — the KEY must be ABSENT, not undefined, for a model that
      // rejects it. `temperature: undefined` still serialises out of the SDK's
      // request body on some paths, and the API refuses the request outright
      // rather than ignoring the field. See supportsTemperature() in pricing.ts
      // for which models and how this was found.
      ...(supportsTemperature(opts.meta.model) ? { temperature: opts.temperature ?? 0 } : {}),
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
    // Same as callClaude above. This is the path the composer takes, and it is
    // the one that was 400ing on every single request — Opus 5 is the default
    // composer model, and it rejects `temperature`.
    ...(supportsTemperature(opts.meta.model) ? { temperature: opts.temperature ?? 0.3 } : {}),
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
