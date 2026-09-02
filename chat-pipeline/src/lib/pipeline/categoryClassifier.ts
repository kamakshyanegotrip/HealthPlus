import { createHash } from 'node:crypto';
import { callClaude } from '../anthropic';
import { extractJsonObject } from '../jsonExtract';
import { MODELS } from '../pricing';
import { loadPrompt } from '../prompts/registry';
import type { CategoryClassification, PipelineContext, ResponseCategory } from '../types';

/**
 * Charter §2.0 — RESPONSE_CATEGORY classifier.
 *
 * §2.0.1: runs before generation, not after, on the user's request plus
 *   retrieved context. (This pipeline classifies before the knowledge lookup
 *   layer even runs — retrieval hasn't happened yet at this point in the
 *   pipeline, which is fine: §2.0.1 says the classifier *may* use retrieved
 *   context, not that it must wait for it. Re-classification after retrieval
 *   would only ever push the category up per §2.0.2, never down, so
 *   classifying early and monotonic-upward-checking again after retrieval —
 *   see `reconcileAfterRetrieval` below — satisfies both clauses without
 *   serialising the whole pipeline behind retrieval.)
 * §2.0.2: monotonic upward — a multi-part answer takes its highest-category
 *   component's safeguards.
 * §2.0.3: uncertain -> select the higher category.
 * §2.0.4: category, classifier version, inputs, and resulting safeguards
 *   MUST be persisted with the response for audit — done by the caller via
 *   auditLog.recordCategoryAssigned, which this function does not call
 *   itself so that classification stays a pure, testable function.
 */

const CATEGORY_ORDER: Record<ResponseCategory, number> = {
  INFORMATIONAL: 0,
  DECISION_SUPPORT: 1,
  CLINICAL_DECISION: 2,
};

/**
 * Pure parse+resolve step, split out from classifyCategory so §2.0.3's
 * "ambiguity resolves upward" rule is unit-testable without a network call
 * or a mocked Anthropic client — see test/categoryClassifier.test.ts, in
 * particular `test_hp_esc_2_0_3_ambiguity_resolves_upward` and
 * `test_hp_esc_2_0_3_unparsable_output_fails_closed`.
 */
export function parseAndResolveCategory(rawText: string): { category: ResponseCategory; confidence: number; ambiguous: boolean } {
  let category: ResponseCategory = 'CLINICAL_DECISION'; // fail-closed default: highest safeguards
  let confidence = 0;
  let ambiguousBetween: string[] = [];
  try {
    // extractJsonObject: see src/lib/jsonExtract.ts's header comment — a
    // real live model call wraps this in a ```json fence plus trailing
    // prose despite the "strict JSON only" instruction; a bare
    // JSON.parse(rawText) silently fails closed on every real call without
    // this. Already-clean text (every existing mocked test fixture) is
    // returned unchanged, so this is additive, not a behavior change for
    // anything previously tested.
    const parsed = JSON.parse(extractJsonObject(rawText));
    if (['INFORMATIONAL', 'DECISION_SUPPORT', 'CLINICAL_DECISION'].includes(parsed.category)) {
      category = parsed.category;
    }
    confidence = typeof parsed.confidence === 'number' ? parsed.confidence : 0;
    ambiguousBetween = Array.isArray(parsed.ambiguousBetween) ? parsed.ambiguousBetween : [];
  } catch {
    // Unparsable classifier output is treated as maximal ambiguity: §2.0.3
    // resolves upward, and CLINICAL_DECISION is already the fail-closed
    // default set above.
  }

  // §2.0.3: ambiguity resolves to the HIGHER of the candidates named.
  const ambiguous = ambiguousBetween.length > 0;
  if (ambiguous) {
    const candidates = [category, ...ambiguousBetween].filter(
      (c): c is ResponseCategory => c === 'INFORMATIONAL' || c === 'DECISION_SUPPORT' || c === 'CLINICAL_DECISION',
    );
    category = candidates.reduce((hi, c) => (CATEGORY_ORDER[c] > CATEGORY_ORDER[hi] ? c : hi), category);
  }

  return { category, confidence, ambiguous };
}

export async function classifyCategory(ctx: PipelineContext): Promise<CategoryClassification> {
  const prompt = loadPrompt('CATEGORY_CLASSIFIER');
  const { text } = await callClaude({
    meta: { auditId: ctx.auditId, purpose: 'CATEGORY_CLASSIFY', model: MODELS.HAIKU, promptVersion: prompt.version },
    system: prompt.text,
    messages: [{ role: 'user', content: ctx.message }],
    maxTokens: 300,
  });

  const inputsDigest = createHash('sha256').update(ctx.message).digest('hex');
  const { category, confidence, ambiguous } = parseAndResolveCategory(text);
  return { category, classifierVersion: prompt.version, confidence, ambiguous, inputsDigest };
}

/**
 * §2.0.2 monotonic-upward check, applied again once the knowledge lookup
 * layer has actually run. If any retrieved claim needed to answer belongs to
 * a component that is itself CLINICAL_DECISION-shaped (e.g. the user's
 * question turned out to hinge on a TEST_INTERPRETATION-kind claim), the
 * category can only move up from here, never down.
 */
export function reconcileAfterRetrieval(initial: ResponseCategory, retrievalImpliesClinical: boolean): ResponseCategory {
  if (retrievalImpliesClinical && CATEGORY_ORDER['CLINICAL_DECISION'] > CATEGORY_ORDER[initial]) {
    return 'CLINICAL_DECISION';
  }
  return initial;
}
