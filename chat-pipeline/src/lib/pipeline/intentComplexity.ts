import { callClaude } from '../anthropic';
import { extractJsonObject } from '../jsonExtract';
import { MODELS } from '../pricing';
import { loadPrompt } from '../prompts/registry';
import type { IntentComplexityResult, KnowledgeDomain, PipelineContext } from '../types';

export async function classifyIntentComplexity(ctx: PipelineContext): Promise<IntentComplexityResult> {
  const prompt = loadPrompt('INTENT_COMPLEXITY');
  const { text } = await callClaude({
    meta: { auditId: ctx.auditId, purpose: 'CATEGORY_CLASSIFY', model: MODELS.HAIKU, promptVersion: prompt.version },
    system: prompt.text,
    messages: [{ role: 'user', content: ctx.message }],
    maxTokens: 400,
  });

  try {
    // extractJsonObject: see src/lib/jsonExtract.ts's header comment — same
    // markdown-fence-wrapping behavior confirmed against a real live model
    // call to CATEGORY_CLASSIFIER; this call site parses raw model text the
    // same way and was equally vulnerable, just not yet caught live.
    const parsed = JSON.parse(extractJsonObject(text));
    const domains: KnowledgeDomain[] = Array.isArray(parsed.requiresKnowledgeDomains) ? parsed.requiresKnowledgeDomains : [];
    return {
      intent: String(parsed.intent ?? 'unknown'),
      complexity: ['LOW', 'MEDIUM', 'HIGH'].includes(parsed.complexity) ? parsed.complexity : 'MEDIUM',
      requiresKnowledgeDomains: domains,
      rationale: String(parsed.rationale ?? ''),
    };
  } catch {
    // Fail toward doing more work, not less — an unparsed classifier response
    // must never silently narrow retrieval or downgrade complexity, mirroring
    // §2.0.3's "ambiguity resolves toward more safeguards" posture even
    // though this particular classifier isn't the category classifier.
    return {
      intent: 'unknown',
      complexity: 'HIGH',
      requiresKnowledgeDomains: ['NUTRITION', 'EXERCISE', 'LIFESTYLE', 'MONITORING', 'COST', 'HOSPITAL', 'VISA', 'ENVIRONMENT', 'GUIDELINE'],
      rationale: 'classifier output unparsable; defaulted to full retrieval + high complexity',
    };
  }
}
