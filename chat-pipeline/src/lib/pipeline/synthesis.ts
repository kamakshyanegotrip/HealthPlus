import type Anthropic from '@anthropic-ai/sdk';
import { streamClaude } from '../anthropic';
import { ALLOW_OPUS_ON_LIVE_PATH, MODELS } from '../pricing';
import { buildSystemPrompt } from '../prompts/annexB';
import type { IntentComplexityResult, PatientProfile, PipelineContext, ResponseCategory, RetrievedClaim } from '../types';
import type { ReasoningBrief } from './clinicalReasoning';

const PROMPT_VERSION = process.env.PROMPT_VERSION_COMPOSE ?? 'compose-2026.08.1';

/**
 * PERSONALIZED RECOMMENDATION SYNTHESIS — the user-facing composer, streamed
 * token by token. "Personalized" here means logistics/preferences/budget
 * (Category B, §2.5: "partially individualised — preferences, logistics,
 * budget"), never a clinical determination about the person — the prompt
 * (Annex B.2/B.3, baked into buildSystemPrompt) and the fact that
 * clinicalReasoning.ts never saw the patient's stated conditions are what
 * keep that boundary real rather than aspirational.
 *
 * Model: Opus by default per this pipeline's spec (PERSONALIZED
 * RECOMMENDATION SYNTHESIS -> Opus). See pricing.ts — this is a flagged
 * deviation from HP-ADR-001 §3.6, which reserves Opus for offline work and
 * puts Sonnet on the user-facing path. Toggle ALLOW_OPUS_ON_LIVE_PATH=false
 * to run this on Sonnet only and stay literally inside that ADR.
 *
 * Returns the raw Anthropic stream + a finalize() callback — the caller
 * (emissionValidator) is responsible for consuming stream text, buffering
 * into sentences, validating each one, and only then writing to the SSE
 * response. This function does not write to the client directly, by design:
 * §3.0.3 requires the validator to sit between generation and emission, not
 * beside it.
 */
export function beginSynthesis(
  ctx: PipelineContext,
  intent: IntentComplexityResult,
  category: Exclude<ResponseCategory, 'CLINICAL_DECISION'>,
  profile: PatientProfile | null,
  claims: RetrievedClaim[],
  reasoning: ReasoningBrief,
) {
  const model = ALLOW_OPUS_ON_LIVE_PATH ? MODELS.OPUS : MODELS.SONNET;
  const system = buildSystemPrompt(category);

  const retrievedSourcesBlock = claims.length
    ? claims
        .map(
          (c) =>
            `claim_id=${c.claimId} kind=${c.kind} tier=${c.tier} band=${c.confidenceBand}${c.population ? ` population="${c.population}"` : ''}\nCITATION: ${c.citation}\nTEXT: ${c.text}`,
        )
        .join('\n\n')
    : '(none retrieved — say so; do not fill the gap)';

  // Only preferences/logistics cross into the composer, never stated or
  // inferred conditions — see clinicalReasoning.ts's header comment for why.
  const profileBlock = profile
    ? `PATIENT_PREFERENCES (logistics/budget/comparison criteria ONLY — never a clinical fact): ${JSON.stringify(profile.preferences ?? {})}\nDATA_REGION: ${profile.dataRegion}`
    : 'PATIENT_PREFERENCES: (none on file)';

  const userContent = [
    `RESPONSE_CATEGORY: ${category}`,
    `USER_INTENT: ${intent.intent}`,
    profileBlock,
    `\nRETRIEVED_SOURCES:\n${retrievedSourcesBlock}`,
    `\nREASONING_BRIEF (internal, population-level only — do not quote verbatim, use it to decide what to say):\n${reasoning.text}`,
    `\nUSER_MESSAGE:\n${ctx.message}`,
  ].join('\n');

  const messages: Anthropic.MessageParam[] = [{ role: 'user', content: userContent }];

  return streamClaude({
    meta: { auditId: ctx.auditId, purpose: 'COMPOSE', model, promptVersion: PROMPT_VERSION, retrievedClaimIds: claims.map((c) => c.claimId) },
    system,
    messages,
    maxTokens: 2000,
    temperature: 0.3,
  });
}
