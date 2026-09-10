import type Anthropic from '@anthropic-ai/sdk';
import { streamClaude } from '../anthropic';
import { ALLOW_OPUS_ON_LIVE_PATH, MODELS } from '../pricing';
import { buildSystemPrompt } from '../prompts/annexB';
import { loadPrompt } from '../prompts/registry';
import type { IntentComplexityResult, PatientProfile, PipelineContext, ResponseCategory, RetrievedClaim } from '../types';
import type { ReasoningBrief } from './clinicalReasoning';
import type { ConstraintApplication, ConstraintSet } from './constraintSet';
import type { CoveragePlan, PlannedDimension } from './coveragePlan';

const PROMPT_VERSION = process.env.PROMPT_VERSION_COMPOSE ?? 'compose-2026.09.1';

/**
 * PERSONALIZED RECOMMENDATION SYNTHESIS — the user-facing composer, streamed.
 *
 * "Personalized" means logistics, preferences and budget (§2.5: "partially
 * individualised — preferences, logistics, budget"), never a clinical
 * determination about the person. Three separate things keep that boundary
 * real rather than aspirational, and none of them is this prompt:
 *
 *   * `clinicalReasoning.ts` never sees the patient's stated conditions, so
 *     the internal brief cannot be reasoning about them;
 *   * `constraintSet.ts` reads only PREFERENCE-kind attributes and its verbs
 *     act on the claim set, never on the patient;
 *   * `emissionValidator.ts` gates every sentence against THIS response's own
 *     retrieved set before it reaches the client.
 *
 * Annex B is "the last line of defence, not the first" and is treated as such.
 *
 * ---------------------------------------------------------------------------
 * WHAT HP-JOB-011 CHANGED HERE
 *
 * The previous version handed the model a claim dump, a preferences blob and a
 * reasoning brief and hoped for a coherent answer. For a single-topic question
 * that is enough. For blueprint §42's ten-part question it is not: the model
 * has no way to know which parts it must cover, which parts it must not
 * determine, or which parts depend on each other, so it produces a competent
 * list of separate answers.
 *
 * This version passes three structured inputs instead of hoping:
 *   COVERAGE_PLAN        what must be addressed, and how (coveragePlan.ts)
 *   PATIENT_CONSTRAINTS  the precedence ladder, in rank order (constraintSet.ts)
 *   REQUIRED_CONNECTIONS the coherence edges, with their reasons
 *
 * All three are assertable after the fact, which is the point — see
 * test/section42.composition.test.ts.
 *
 * ---------------------------------------------------------------------------
 * Model: Opus by default. See pricing.ts — a FLAGGED deviation from
 * HP-ADR-001 §3.6, which reserves Opus for offline work. ALLOW_OPUS_ON_LIVE_PATH
 * =false falls back to Sonnet and stays literally inside that ADR. The
 * deviation matters more for this step than it did before: weaving ten
 * dimensions under a precedence ladder without flattening into sections is
 * exactly the kind of instruction-following the tier difference buys.
 *
 * Returns the raw stream plus finalize(), for the same reason as before: the
 * emission validator sits BETWEEN generation and emission (§3.0.3), not beside
 * it, so this function never writes to the client.
 */
export function beginSynthesis(
  ctx: PipelineContext,
  intent: IntentComplexityResult,
  category: Exclude<ResponseCategory, 'CLINICAL_DECISION'>,
  profile: PatientProfile | null,
  claims: RetrievedClaim[],
  reasoning: ReasoningBrief,
  plan: CoveragePlan,
  constraints: ConstraintSet,
  application: ConstraintApplication,
) {
  const model = ALLOW_OPUS_ON_LIVE_PATH ? MODELS.OPUS : MODELS.SONNET;
  const composerPrompt = loadPrompt('RESPONSE_COMPOSER');
  const system = [buildSystemPrompt(category), composerPrompt.text].join('\n\n---\n\n');

  const messages: Anthropic.MessageParam[] = [
    { role: 'user', content: buildComposerInput(ctx, intent, category, profile, claims, reasoning, plan, constraints, application) },
  ];

  return streamClaude({
    meta: {
      ctx,
      purpose: 'COMPOSE',
      model,
      promptVersion: `${PROMPT_VERSION}+${composerPrompt.version}`,
      retrievedClaimIds: claims.map((c) => c.claimId),
    },
    system,
    messages,
    // Raised from 2000. Ten woven dimensions with citations do not fit in
    // 2000 tokens, and a truncated answer drops whichever dimension came last
    // — silently, since a cut-off stream still yields validated sentences.
    // Measured against the §42 fixture: a complete woven answer runs ~2.6k.
    maxTokens: 4000,
    temperature: 0.3,
  });
}

/**
 * Split out from `beginSynthesis` so the composed prompt is a pure, inspectable
 * string. `test/section42.composition.test.ts` asserts against THIS rather than
 * against a live model call: whether the ten dimensions, the ladder and the
 * deferrals actually reached the model is a property of this function, and it
 * is the property that fails silently if someone reorders an argument.
 */
export function buildComposerInput(
  ctx: PipelineContext,
  intent: IntentComplexityResult,
  category: Exclude<ResponseCategory, 'CLINICAL_DECISION'>,
  profile: PatientProfile | null,
  claims: readonly RetrievedClaim[],
  reasoning: ReasoningBrief,
  plan: CoveragePlan,
  constraints: ConstraintSet,
  application: ConstraintApplication,
): string {
  const retrievedSourcesBlock = claims.length
    ? claims
        .map(
          (c) =>
            `claim_id=${c.claimId} kind=${c.kind} tier=${c.tier} band=${c.confidenceBand}` +
            `${c.population ? ` population="${c.population}"` : ''}` +
            `${c.jurisdiction ? ` jurisdiction=${c.jurisdiction}` : ''}` +
            `${c.conflictId ? ` CONFLICT=${c.conflictId} (§1.8.2 — state the disagreement, do not resolve it)` : ''}\n` +
            `CITATION: ${c.citation}\nTEXT: ${c.text}`,
        )
        .join('\n\n')
    : '(none retrieved — say so; do not fill the gap)';

  // §2.5 / §3.8.x: preferences and logistics only. `statedConditions` is on the
  // profile object and is deliberately NOT rendered here — it reaches the
  // composer only as the constraints resolveConstraints() derived from stated
  // PREFERENCE attributes, never as a condition list the model can reason from.
  const profileBlock = profile
    ? [
        `DATA_REGION: ${profile.dataRegion}`,
        profile.residencyCountry ? `RESIDENCY_COUNTRY: ${profile.residencyCountry}` : null,
        ctx.statedCountry ? `STATED_CURRENT_LOCATION: ${ctx.statedCountry}` : null,
      ]
        .filter(Boolean)
        .join('\n')
    : 'PATIENT_PROFILE: (none on file — say we hold nothing, never that they have no restrictions)';

  const constraintsBlock = constraints.empty
    ? '(no constraints on file. Say that we hold none — do NOT say the person has none.)'
    : constraints.constraints
        .map((c, i) => `${i + 1}. [${c.rank}] ${c.key} (${c.effect}) — ${c.statement}\n   basis: ${c.basis}`)
        .join('\n');

  const suppressedBlock = application.suppressed.length
    ? application.suppressed.map((s) => `- withheld claim ${s.claim.claimId} (${s.claim.domain}) by ${s.byConstraint}: ${s.statement}`).join('\n')
    : '(nothing withheld)';

  const boundedBlock = application.bounded.length
    ? application.bounded.map((b) => `- claim ${b.claim.claimId} (${b.claim.domain}) sits outside a stated bound (${b.byConstraint}): ${b.statement}`).join('\n')
    : '(nothing outside a stated bound)';

  const coverageBlock = plan.dimensions.map(renderDimension).join('\n\n');

  const connectionsBlock = plan.crossReferences.length
    ? plan.crossReferences.map((x) => `- ${x.from} <-> ${x.to}: ${x.because}`).join('\n')
    : '(no required connections for this plan)';

  return [
    `RESPONSE_CATEGORY: ${category}`,
    `USER_INTENT: ${intent.intent}`,
    profileBlock,
    `\nPATIENT_CONSTRAINTS (precedence ladder, highest first — higher overrides lower):\n${constraintsBlock}`,
    `\nSUPPRESSED_BY_CONSTRAINT (§2.2.3d — say that you filtered, and on what basis):\n${suppressedBlock}`,
    `\nOUTSIDE_STATED_BOUND (name these as outside the bound; do not drop them — §3.3.3):\n${boundedBlock}`,
    `\nCOVERAGE_PLAN (address every dimension):\n${coverageBlock}`,
    `\nREQUIRED_CONNECTIONS (make each of these genuinely, in the flow of the answer):\n${connectionsBlock}`,
    `\nRETRIEVED_SOURCES:\n${retrievedSourcesBlock}`,
    `\nREASONING_BRIEF (internal, population-level only — do not quote verbatim, use it to decide what to say):\n${reasoning.text}`,
    `\nUSER_MESSAGE:\n${ctx.message}`,
  ].join('\n');
}

function renderDimension(d: PlannedDimension): string {
  const head = `### ${d.key} — ${d.disposition}`;
  const ids = d.claims.length ? d.claims.map((c) => c.claimId).join(', ') : '(no admitted claim)';

  switch (d.disposition) {
    case 'ANSWERABLE':
      return `${head}\n  Answer fully from: ${ids}`;

    case 'ANSWERABLE_WITH_DEFERRAL':
      return (
        `${head}\n` +
        `  Published content you MAY use: ${ids}\n` +
        `  You may NOT: ${d.deferral?.cannot}. (${d.deferral?.clause})\n` +
        `  Permitted adjacent help: ${d.deferral?.adjacentHelp}\n` +
        `  Question for their clinician: "${d.deferral?.clinicianQuestion}"`
      );

    case 'DEFERRED':
      return (
        `${head}\n` +
        `  You may NOT: ${d.deferral?.cannot}. (${d.deferral?.clause})\n` +
        `  No published criteria were retrieved for this either — say both, plainly: that you cannot determine it, and that we hold no published criteria to show.\n` +
        `  Question for their clinician: "${d.deferral?.clinicianQuestion}"`
      );

    case 'NO_EVIDENCE':
      return (
        `${head}\n` +
        `  Nothing was retrieved for this. §3.0.1: say you do not have the information and name the kind of source that would have it. Do not estimate, and do not skip the dimension in silence.`
      );
  }
}
