import { createHash } from 'node:crypto';

/**
 * Prompt pack registry — the fix for "the worked prompts you referenced
 * were never included."
 *
 * Two components in this pipeline are actually driven by a swappable LLM
 * prompt written to match a specific external spec: the RESPONSE CATEGORY
 * CLASSIFIER and the SAFETY/RED-FLAG ENGINE's propose-only channel. Both
 * were originally described as "see worked prompt below" — no such prompt
 * arrived, so `PROMPTS` below holds Charter-grounded placeholders authored
 * directly from Evidence & Safety Charter v1.0 §2 and §4, clearly marked as
 * such.
 *
 * The other two components the spec pointed at worked prompts don't
 * actually have one to swap:
 * - The RESPONSE EMISSION VALIDATOR is deliberately NOT prompt-driven — its
 *   own doc comment (emissionValidator.ts) says so directly: "this is the
 *   structural §3.0.3 control, not a paraphrase of the Annex B prompt
 *   instructions." Its tunable surface is the regex heuristics
 *   (NUMERIC_CLAIM_PATTERN, REASSURANCE_PATTERNS, ELIGIBILITY_LANGUAGE),
 *   not a prompt — there's nothing here for a "worked prompt" to replace.
 * - The SIDE-EFFECT DISPATCHER makes no LLM call at all (it's a
 *   transactional enqueue + an HTTP ping); same story.
 * If either of those was actually meant to be an LLM-driven component with
 * its own prompt, that's a different, larger change than swapping text
 * here — flag it rather than assume it.
 *
 * TO SWAP IN THE REAL PROMPTS: replace `text` (and bump `version`) for the
 * relevant key below. Every LLM-facing pipeline module reads its prompt
 * through `loadPrompt()`, never as an inline string, so this file is the
 * only place that needs to change. `sha256` is computed automatically and
 * logged wherever the prompt is used (via callClaude's promptVersion field
 * indirectly, and directly in test/promptRegistry.test.ts) — §6.4 requires
 * "prompts, classifiers and retrieval config are versioned artefacts with
 * an eval suite gating release"; this registry is the versioning half of
 * that. The eval suite itself still doesn't exist (see README).
 */

export type PromptKey = 'CATEGORY_CLASSIFIER' | 'RED_FLAG_PROPOSE' | 'INTENT_COMPLEXITY' | 'CLINICAL_REASONING';

interface PromptEntry {
  version: string;
  source: 'claude-authored-placeholder' | 'worked-prompt';
  text: string;
}

export const PROMPTS: Record<PromptKey, PromptEntry> = {
  CATEGORY_CLASSIFIER: {
    version: 'cat-clf-2026.08.1',
    source: 'claude-authored-placeholder',
    text: `You classify a health/medical-tourism chat message into exactly one Charter
category. Output strict JSON only: {"category": "INFORMATIONAL"|"DECISION_SUPPORT"|
"CLINICAL_DECISION", "confidence": number 0-1, "ambiguousBetween": string[] }

INFORMATIONAL (§2.1.1): general education, population-level, does not address the
individual's own clinical situation and does not steer a specific choice.

DECISION_SUPPORT (§2.2.1): helps the user compare, weigh, shortlist, budget, or plan
across providers/procedures/destinations/timing — but does not itself interpret
their clinical data or determine what's clinically right for them.

CLINICAL_DECISION (§2.3.1): interprets an individual's clinical data, states or
implies a diagnosis, asserts eligibility/contraindication for a treatment for THIS
person, recommends or discourages a specific treatment for THIS person, classifies
THIS person's disease severity, determines THIS person's fitness to travel,
interprets THIS person's test results, or advises on medication for THIS person.
The moment the user supplies personal clinical facts (symptoms, results, diagnosis,
medications) AND the answer would be shaped by them, this is at minimum
CLINICAL_DECISION-adjacent — classify it CLINICAL_DECISION, never guess it down.

If genuinely unsure between two categories, put both in ambiguousBetween; the
pipeline resolves upward regardless of what you put in "category" when
ambiguousBetween is non-empty (§2.0.3), so pick your best single guess for
"category" but be honest in ambiguousBetween rather than forcing false certainty.`,
  },

  RED_FLAG_PROPOSE: {
    version: 'rf-rules-2026.08.1',
    source: 'claude-authored-placeholder',
    text: `You are a propose-only safety signal, not a decision-maker. A deterministic,
clinician-authored rule set has already scanned this message and assigned a base
severity. Your only job is to say whether you believe the TRUE severity is HIGHER
than the base severity given to you — you are never allowed to suggest lowering it,
and any suggestion to lower is ignored by the system that reads your output.

Severity scale, low to high: NORMAL, MONITOR, WARNING, URGENT, CRITICAL, EMERGENCY.

Output strict JSON only: {"proposedSeverity": one of the six levels, "reason": string}.
If you see nothing that warrants raising the base severity, propose the same base
severity back.`,
  },

  INTENT_COMPLEXITY: {
    version: 'intent-complexity-2026.08.1',
    source: 'claude-authored-placeholder',
    text: `You classify a single user chat message for an internal routing pipeline. You do
not answer the user. Output strict JSON only, no prose, matching this shape:
{"intent": string, "complexity": "LOW"|"MEDIUM"|"HIGH",
 "requiresKnowledgeDomains": string[], "rationale": string}

requiresKnowledgeDomains is a subset of:
NUTRITION, EXERCISE, LIFESTYLE, MONITORING, COST, HOSPITAL, VISA, ENVIRONMENT, GUIDELINE.
Only include a domain the message plausibly needs data from; an empty array is valid.

complexity reflects how much clinical/comparative reasoning the eventual answer will
need — HIGH for multi-condition, multi-option, or safety-adjacent questions; LOW for
a single factual lookup. This score routes later model selection; it does not gate
safety (a separate deterministic red-flag scan runs regardless of this score).`,
  },

  CLINICAL_REASONING: {
    version: 'clinical-reasoning-2026.08.1',
    source: 'claude-authored-placeholder',
    text: `You produce an internal reasoning brief for a downstream composer. You are not
writing the user-facing response. Reason ONLY over the RETRIEVED_SOURCES claims
given to you — population-level disease/treatment/guideline content, never any
individual's symptoms, results, or diagnosis (none are given to you for this
reason). Identify: which retrieved claims are relevant and why; where sources
disagree (state the disagreement, do not resolve it silently — Charter §1.8.2);
what is NOT covered by any retrieved claim (name the gap explicitly rather than
filling it — Charter §3.0.1). Cite every point you make with the claim_id it comes
from, using [[claim:<id>]]. Output plain text, not JSON — this brief is read by
another model, not parsed by code.`,
  },
};

export function loadPrompt(key: PromptKey): { version: string; text: string } {
  const entry = PROMPTS[key];
  return { version: entry.version, text: entry.text };
}

export function promptChecksum(key: PromptKey): string {
  return createHash('sha256').update(PROMPTS[key].text).digest('hex').slice(0, 16);
}
