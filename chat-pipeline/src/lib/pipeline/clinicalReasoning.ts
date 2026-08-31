import { callClaude } from '../anthropic';
import { ALLOW_OPUS_ON_LIVE_PATH, MODELS } from '../pricing';
import { ANNEX_B1_SOURCING, ANNEX_B3_PROHIBITIONS } from '../prompts/annexB';
import { loadPrompt } from '../prompts/registry';
import type { IntentComplexityResult, PipelineContext, ResponseCategory, RetrievedClaim } from '../types';

/**
 * "CLINICAL & DIAGNOSTIC REASONING" — reframed to what DR-001 / Charter
 * §2.3.2 actually permit in v1.
 *
 * DR-001 §2 retires `Arch.docx` §5 (Diagnostic Intelligence) and §7
 * (Severity Engine) from "interpret this person" to "population-level,
 * disease-level reference content ... always with citation, never applied
 * to the person asking." This function is that: it reasons ONLY over the
 * RetrievedClaim set (published criteria, guideline content, disease
 * reference data) to build an internal reasoning brief — never over the
 * patient profile's stated/inferred conditions as inputs to a determination
 * about that patient. The patient profile is used later, in synthesis, only
 * to select which population-level content is relevant and to personalise
 * logistics/preferences (Category B's "partially individualised" row in
 * §2.5) — never to reason about this person's diagnosis, severity, or
 * eligibility, which stays structurally unreachable while
 * safety.response_category_state.CLINICAL_DECISION.enabled = false.
 *
 * This step never runs at all when category resolved to CLINICAL_DECISION —
 * the orchestrator short-circuits before calling it (see route.ts).
 */

export interface ReasoningBrief {
  text: string;
  modelUsed: string;
}

export async function buildReasoningBrief(
  ctx: PipelineContext,
  intent: IntentComplexityResult,
  category: Exclude<ResponseCategory, 'CLINICAL_DECISION'>,
  claims: RetrievedClaim[],
): Promise<ReasoningBrief> {
  // Escalate to Opus only when the intent/complexity classifier flagged HIGH
  // complexity — per the pipeline spec this module implements. See
  // pricing.ts for why this is a flagged deviation from HP-ADR-001 §3.6
  // rather than a silent one, and how to turn it off.
  const model = intent.complexity === 'HIGH' && ALLOW_OPUS_ON_LIVE_PATH ? MODELS.OPUS : MODELS.SONNET;
  const prompt = loadPrompt('CLINICAL_REASONING');
  const system = [prompt.text, ANNEX_B1_SOURCING, ANNEX_B3_PROHIBITIONS].join('\n\n---\n\n');

  const retrievedSourcesBlock = claims.length
    ? claims.map((c) => `[claim:${c.claimId}] (${c.domain}, ${c.tier}, ${c.confidenceBand}) ${c.text}${c.population ? ` [population: ${c.population}]` : ''}`).join('\n')
    : '(none retrieved)';

  const { text } = await callClaude({
    meta: { auditId: ctx.auditId, purpose: 'COMPOSE', model, promptVersion: prompt.version, retrievedClaimIds: claims.map((c) => c.claimId) },
    system,
    messages: [
      {
        role: 'user',
        content: `USER_INTENT: ${intent.intent}\nRESPONSE_CATEGORY: ${category}\n\nRETRIEVED_SOURCES:\n${retrievedSourcesBlock}\n\nUSER_MESSAGE:\n${ctx.message}`,
      },
    ],
    maxTokens: 1200,
    temperature: 0,
  });

  return { text, modelUsed: model };
}
