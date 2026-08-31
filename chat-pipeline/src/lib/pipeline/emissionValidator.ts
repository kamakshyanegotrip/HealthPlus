import { db } from '../db';
import { DATA_REGION } from '../db';
import { queryHash } from '../pseudonymize';
import type { PipelineContext, ResponseCategory, RetrievedClaim } from '../types';

/**
 * Response Emission Validator — Charter §3.0.3, the structural control:
 * "Every class MUST be backed by (a) a typed field that is nullable and
 * (b) a response-time validator that blocks emission of a value in that
 * field with no linked source ID. Prompt instructions alone are
 * insufficient and MUST NOT be relied upon as the sole control."
 *
 * This is NOT a restatement of the Annex B prompt blocks (those are "the
 * last line of defence, not the first"). This buffers the composer's token
 * stream into complete sentences and, before each sentence is allowed to
 * reach the client, checks it against THIS RESPONSE's own RETRIEVED_SOURCES
 * set — the exact claim_ids that were actually retrieved and handed to the
 * composer for this turn, not the corpus at large. A citation to a real
 * claim_id that simply wasn't retrieved for this response is treated the
 * same as a citation to a claim_id that doesn't exist anywhere: fabricated,
 * from this response's point of view.
 *
 * DESIGN NOTE — token-by-token vs sentence-by-sentence, resolved in favour
 * of the validator. The pipeline spec asks for both "stream Opus token by
 * token to the client" and "checks the stream sentence-by-sentence ...
 * before each sentence reaches the client." Those two are in tension by
 * construction: you cannot know whether a sentence's claim is supported
 * until the sentence is complete, so a true per-token validator is not
 * possible. This implementation buffers to sentence granularity — the
 * client still receives genuinely incremental output (each sentence is
 * pushed the moment it's validated, not held for the whole response), it
 * just isn't sub-sentence granular. That is the correct trade-off for a
 * health-safety control and is called out here rather than silently
 * resolved.
 */

export interface ValidatedChunk {
  kind: 'sentence' | 'blocked';
  text: string; // for 'sentence': the visible text, citation markers stripped
  citedClaimIds: string[]; // claim_ids this sentence actually cited (for 'sentence')
}

// Broad marker pattern — matches ANY [[claim:...]] span regardless of what's
// inside, so a malformed marker still gets stripped from the visible text
// (never leaked to the user as raw "[[claim:...]]" syntax) and still gets
// caught by the unknown-citation check below rather than silently passing
// through as uncited prose. STRICT_ID validates the captured content
// separately. Splitting these two was a fix, not the original design: a
// unit test (`test_citation_marker_...` in test/emissionValidator.test.ts)
// using a non-UUID placeholder id in a marker exposed that the old single
// regex simply failed to match malformed markers at all, leaving the raw
// bracket text visible in the response instead of blocking it.
const MARKER = /\[\[claim:([^\]]*)\]\]/g;
const STRICT_ID = /^[0-9a-fA-F-]{8,}$/;

// §3.10.3 — reassurance language is prohibited in EVERY category regardless
// of sourcing. This is a hard block, not a sourcing check.
const REASSURANCE_PATTERNS = [
  /nothing to worry about/i,
  /that'?s normal/i,
  /you'?ll be fine/i,
  /routine procedure with no risk/i,
  /no need to (worry|be concerned)/i,
];

// Heuristic surface for "this sentence asserts a fact that needs a
// citation": numbers that look like prices, percentages, rates, dosages, or
// dates, OR absolutist clinical language. A reference implementation's
// heuristic, not a substitute for the claim_policy-driven check above it —
// see Annex A.2's own framing of §3.x validators as an application-layer
// gate that needs unit tests, not a finished NLP system.
const NUMERIC_CLAIM_PATTERN = /(\$|₹|€|£)\s?\d|\d+(\.\d+)?\s?%|\bmg\b|\bmcg\b|\b\d{4}\b.*(guideline|study|approv)/i;
const ELIGIBILITY_LANGUAGE = /\b(you are|you'?re) (eligible|not eligible|cleared|contraindicated|suitable|not suitable)\b/i;

export function splitIntoSentences(buffer: string): { complete: string[]; rest: string } {
  // Naive sentence splitter: split on ./!/? followed by whitespace, but not
  // after a single capital letter + period (crude abbreviation guard) or
  // inside a decimal number. Good enough for a reference implementation;
  // swap for a proper sentence tokenizer before production.
  const sentenceEnd = /([.!?])\s+(?=[A-Z0-9"'\[])/g;
  const parts: string[] = [];
  let lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = sentenceEnd.exec(buffer)) !== null) {
    const isDecimal = /\d\.$/.test(buffer.slice(0, match.index + 1)) && /^\d/.test(buffer.slice(match.index + 2));
    if (isDecimal) continue;
    parts.push(buffer.slice(lastIndex, match.index + 1).trim());
    lastIndex = match.index + match[0].length;
  }
  return { complete: parts.filter(Boolean), rest: buffer.slice(lastIndex) };
}

export type SentenceVerdict =
  | { kind: 'sentence'; text: string; citedClaimIds: string[] }
  | { kind: 'blocked'; text: string; prohibitionClass: string; claimKind: string | null; tier: string | null; messageTemplateId: string };

/**
 * The actual §3.0.3 decision, as a pure function with no DB/network access —
 * split out specifically so it's unit-testable. See
 * test/emissionValidator.test.ts for the clause-referenced cases
 * (`test_hp_esc_3_10_3_reassurance_blocked_regardless_of_citation`,
 * `test_hp_esc_3_9_2_unknown_citation_blocked`,
 * `test_hp_esc_1_9_7_population_missing_blocked`, etc.). `validateStream`
 * below is the thin, DB-touching wrapper around this.
 */
export function classifySentence(raw: string, retrievedClaims: Map<string, RetrievedClaim>): SentenceVerdict {
  const rawMarkerContents = Array.from(raw.matchAll(MARKER)).map((m) => m[1] ?? '');
  const citedIds = rawMarkerContents.filter((id) => STRICT_ID.test(id));
  const malformedMarkerCount = rawMarkerContents.length - citedIds.length;
  // Strip every [[claim:...]] span from the visible text regardless of
  // whether its content was well-formed — a malformed marker must never
  // reach the user as raw bracket syntax, and it's still handled (blocked)
  // by the unknown-citation check below rather than silently vanishing.
  const visible = raw.replace(MARKER, '').replace(/\s{2,}/g, ' ').trim();

  if (REASSURANCE_PATTERNS.some((p) => p.test(visible))) {
    return { kind: 'blocked', text: visible, prohibitionClass: '3.10', claimKind: null, tier: null, messageTemplateId: 'SENTENCE_OMITTED_REASSURANCE' };
  }

  if (ELIGIBILITY_LANGUAGE.test(visible)) {
    return {
      kind: 'blocked',
      text: visible,
      prohibitionClass: '3.2', // eligibility/contraindication determination for this person
      claimKind: null,
      tier: null,
      messageTemplateId: 'SENTENCE_OMITTED_ELIGIBILITY',
    };
  }

  // Citation integrity: every cited id must be in THIS response's retrieved
  // set, and every marker must have been well-formed. A citation to an
  // unknown or malformed id is treated as fabricated (§1.9.5 / §3.9.2), full
  // stop — it does not matter whether a claim with that id exists elsewhere
  // in the corpus.
  const unknownCitations = citedIds.filter((id) => !retrievedClaims.has(id));
  if (unknownCitations.length > 0 || malformedMarkerCount > 0) {
    return { kind: 'blocked', text: visible, prohibitionClass: '3.9', claimKind: null, tier: null, messageTemplateId: 'SENTENCE_OMITTED_UNKNOWN_CITATION' };
  }

  // Uncited numeric/factual assertion -> block (§3.0.1/§3.0.3: no source, no
  // publication, full stop — "state that it does not have the information"
  // is the composer's job via the prompt; the validator's job is to make
  // sure that instruction actually held).
  if (citedIds.length === 0 && (NUMERIC_CLAIM_PATTERN.test(visible) || /\bguideline(s)? (says?|recommends?|states?)\b/i.test(visible))) {
    return { kind: 'blocked', text: visible, prohibitionClass: '3.0', claimKind: null, tier: null, messageTemplateId: 'SENTENCE_OMITTED_UNSOURCED' };
  }

  // §1.9.7 — a claim citing a population-dependent range/statistic with a
  // null population on the underlying claim is blocked.
  for (const id of citedIds) {
    const claim = retrievedClaims.get(id);
    if (claim && NUMERIC_CLAIM_PATTERN.test(visible) && !claim.population && claim.kind !== 'COST') {
      return {
        kind: 'blocked',
        text: visible,
        prohibitionClass: '1.9.7',
        claimKind: claim.kind,
        tier: claim.tier,
        messageTemplateId: 'SENTENCE_OMITTED_NO_POPULATION',
      };
    }
  }

  return { kind: 'sentence', text: visible, citedClaimIds: citedIds };
}

async function logFabricationBlock(opts: {
  ctx: PipelineContext;
  category: ResponseCategory;
  prohibitionClass: string;
  claimKind: string | null;
  tier: string | null;
  policyRow: { tier: string; kind: string; category: string; effectiveFrom: string } | null;
  retrievedClaimIds: string[];
  messageTemplateId: string;
}) {
  try {
    await db().query(
      `INSERT INTO obs.fabrication_block
         (id, occurred_at, audit_id, prohibition_class, claim_kind, tier, category,
          policy_tier, policy_kind, policy_category, policy_effective_from,
          query_hash, retrieved_source_state, message_template_id, data_region)
       VALUES (gen_random_uuid(), now(), $1, $2, $3, $4, $5,
               $6, $7, $8, $9,
               $10, $11, $12, $13)`,
      [
        opts.ctx.auditId,
        opts.prohibitionClass,
        opts.claimKind,
        opts.tier,
        opts.category,
        opts.policyRow?.tier ?? null,
        opts.policyRow?.kind ?? null,
        opts.policyRow?.category ?? null,
        opts.policyRow?.effectiveFrom ?? null,
        queryHash(opts.ctx.message),
        JSON.stringify({ retrievedClaimIds: opts.retrievedClaimIds }),
        opts.messageTemplateId,
        DATA_REGION,
      ],
    );
  } catch (err) {
    // §3.13.1 requires blocks to be logged — a logging failure must not
    // silently disappear. Surface it loudly even though we still block the
    // sentence either way (fail-closed on the content decision regardless
    // of whether the audit write succeeded).
    console.error('CRITICAL: failed to log fabrication_block', err);
  }
}

/**
 * Consumes the composer's raw text deltas, yields ValidatedChunk in order.
 * `retrievedClaims` is THIS response's own set (from the knowledge lookup
 * layer) keyed by claim_id — the source of truth for "was this actually
 * retrieved for this turn."
 */
export async function* validateStream(
  ctx: PipelineContext,
  category: ResponseCategory,
  retrievedClaims: Map<string, RetrievedClaim>,
  textDeltas: AsyncIterable<string>,
): AsyncGenerator<ValidatedChunk> {
  let buffer = '';
  const retrievedIds = Array.from(retrievedClaims.keys());

  async function processSentence(raw: string): Promise<ValidatedChunk> {
    const verdict = classifySentence(raw, retrievedClaims);
    if (verdict.kind === 'blocked') {
      await logFabricationBlock({
        ctx,
        category,
        prohibitionClass: verdict.prohibitionClass,
        claimKind: verdict.claimKind,
        tier: verdict.tier,
        policyRow: null,
        retrievedClaimIds: retrievedIds,
        messageTemplateId: verdict.messageTemplateId,
      });
    }
    return { kind: verdict.kind, text: verdict.text, citedClaimIds: verdict.kind === 'sentence' ? verdict.citedClaimIds : [] };
  }

  for await (const delta of textDeltas) {
    buffer += delta;
    const { complete, rest } = splitIntoSentences(buffer);
    buffer = rest;
    for (const s of complete) {
      yield await processSentence(s);
    }
  }
  if (buffer.trim().length > 0) {
    yield await processSentence(buffer);
  }
}
