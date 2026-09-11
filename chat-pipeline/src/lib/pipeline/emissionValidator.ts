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

/**
 * DEFECT FIXED HERE — HP-JOB-011 §5, found by running the composer against the
 * §42 fixture rather than by reading this function.
 *
 * The old pattern was `/([.!?])\s+(?=[A-Z0-9"'\[])/g`. That lookahead includes
 * `\[`, so a period followed by a citation marker was a sentence boundary and
 * THE MARKER STARTED THE NEXT SENTENCE. Annex B.1 instructs the composer to
 * "tag it inline IMMEDIATELY AFTER THE SENTENCE", which is exactly the shape
 * that broke:
 *
 *   "Hospital A is accredited. [[claim:X]] Hospital B is too. [[claim:Y]]"
 *
 *   old -> ["Hospital A is accredited.",          <- cites NOTHING
 *           "[[claim:X]] Hospital B is too."]     <- cites X, which is about A
 *
 * Two consequences, both live on every response this pipeline has produced:
 *
 *   * The sentence carrying the claim arrives uncited. If it contains a figure,
 *     NUMERIC_CLAIM_PATTERN blocks it as unsourced — the composer did source it,
 *     and the split threw the source away.
 *   * The following sentence is credited with a citation that does not support
 *     it, which is §3.9.2 ("MUST NOT attach a real citation to a claim that
 *     citation does not support") arriving through the tokenizer rather than
 *     through the model. It also feeds `citedClaimIds`, so the audit record and
 *     `aggConfidence` are both computed over the wrong set.
 *
 * The fix absorbs any run of trailing markers into the sentence they follow,
 * and stops treating `[[claim:` as a sentence opener while still allowing a
 * genuine bracket to start one. Both marker placements — trailing (what Annex
 * B.1 asks for) and inline-before-the-period — now attribute correctly, which
 * matters because a live model does both.
 *
 * Still a naive splitter otherwise: crude abbreviation and decimal guards, no
 * real tokenizer. That part of the original comment stands.
 */
export function splitIntoSentences(buffer: string): { complete: string[]; rest: string } {
  const sentenceEnd = /([.!?])((?:\s*\[\[claim:[^\]]*\]\])*)\s+(?=[A-Z0-9"']|\[(?!\[claim:))/g;
  const parts: string[] = [];
  let lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = sentenceEnd.exec(buffer)) !== null) {
    const isDecimal = /\d\.$/.test(buffer.slice(0, match.index + 1)) && /^\d/.test(buffer.slice(match.index + 2));
    if (isDecimal) continue;
    // End of the sentence = the terminator plus any trailing marker run.
    const sentenceEndIndex = match.index + (match[1]?.length ?? 0) + (match[2]?.length ?? 0);
    parts.push(buffer.slice(lastIndex, sentenceEndIndex).trim());
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
/**
 * §3.3.1 — MONETARY FIGURES MUST APPEAR IN A CLAIM THAT THE SENTENCE CITES.
 *
 * THE HOLE THIS CLOSES, demonstrated before it was written rather than argued:
 *
 *   claim  a1…008  "…indicative total knee replacement package of USD 6,200."
 *   output "Hospital A publishes an indicative package of $2,900 [[claim:a1…008]]."
 *   verdict: SENTENCE. Emitted. Shown to the patient.
 *
 * Citation integrity checked that the id was retrieved. Nothing checked that the
 * NUMBER matched the claim the citation points at. §3.3.1 says the system "MUST
 * NOT output any price, package cost, fee, deposit, or total not drawn from a
 * persisted, sourced, in-date price record" — and until now that was enforced
 * only by asking the model nicely, which §3.0.3 explicitly says is not enough:
 * "Prompt instructions alone are insufficient and MUST NOT be relied upon as
 * the sole control."
 *
 * `NUMERIC_CLAIM_PATTERN` did not cover it either. It matches a currency SYMBOL
 * followed by a digit, so `$6,200` needs a citation — but `USD 6,200`, which is
 * how a composer writing for an international audience actually renders it, was
 * invisible to every check in this file.
 *
 * WHY A REGEX OVER CLAIM TEXT RATHER THAN A STORED NUMBER. There is no stored
 * number. `domain.hospital_cost` carries currency, scope and inclusion flags and
 * NO amount; `evidence.claim` carries `statement text` and nothing numeric —
 * every numeric column in the `evidence` schema is a confidence figure. Amounts
 * live in claim prose by Annex A.4's design ("Layer 2 references claims, never
 * stores facts"). A structured `evidence.claim_cost` is the better control and
 * is a §6.3 schema decision, recorded as J11-2. §6.3 permits engineering to ADD
 * a §3 prohibition at any time, so this ships now and that supersedes it later.
 *
 * `permittedFigures` exists because not every figure in a good answer comes from
 * a claim. The patient's own stated budget ceiling is the standing case: "above
 * your stated USD 9,000 ceiling" is their number, not a sourced one, and
 * blocking it would punish the composer for obeying §3.3.3's instruction to name
 * an over-budget option rather than drop it.
 */
const CURRENCY_SYMBOL: Record<string, string> = { $: 'USD', '₹': 'INR', '€': 'EUR', '£': 'GBP' };
const FIGURE_SYMBOL_FIRST = /([$₹€£])\s?([\d][\d,]*(?:\.\d+)?)/g;
const FIGURE_CODE_FIRST = /\b(USD|INR|EUR|GBP|AED|SGD|THB|TRY)\s?([\d][\d,]*(?:\.\d+)?)/gi;
const FIGURE_CODE_LAST = /([\d][\d,]*(?:\.\d+)?)\s?\b(USD|INR|EUR|GBP|AED|SGD|THB|TRY)\b/gi;

/** Normalised `CUR:amount` tokens, so `$6,200`, `USD 6,200` and `6200 USD` compare equal. */
export function extractMonetaryFigures(text: string): string[] {
  const out = new Set<string>();
  const add = (cur: string, num: string) => {
    const n = Number(num.replace(/,/g, ''));
    if (Number.isFinite(n)) out.add(`${cur.toUpperCase()}:${n}`);
  };
  for (const m of text.matchAll(FIGURE_SYMBOL_FIRST)) add(CURRENCY_SYMBOL[m[1]!] ?? m[1]!, m[2]!);
  for (const m of text.matchAll(FIGURE_CODE_FIRST)) add(m[1]!, m[2]!);
  for (const m of text.matchAll(FIGURE_CODE_LAST)) add(m[2]!, m[1]!);
  return [...out];
}

export interface ClassifyOptions {
  /**
   * Figures legitimately present without a claim behind them — in practice the
   * patient's own stated budget ceiling, threaded from the constraint ladder.
   * Format matches `extractMonetaryFigures`: `USD:9000`.
   */
  permittedFigures?: readonly string[];
}

export function classifySentence(
  raw: string,
  retrievedClaims: Map<string, RetrievedClaim>,
  opts: ClassifyOptions = {},
): SentenceVerdict {
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

  // §3.3.1 — every monetary figure must appear in a claim this sentence cites,
  // or be one the patient themselves stated. See the header above for the
  // demonstrated hole this closes and why it is a regex rather than a lookup.
  const sentenceFigures = extractMonetaryFigures(visible);
  if (sentenceFigures.length > 0) {
    const allowed = new Set<string>(opts.permittedFigures ?? []);
    for (const id of citedIds) {
      const claim = retrievedClaims.get(id);
      if (claim) for (const f of extractMonetaryFigures(claim.text)) allowed.add(f);
    }
    const unsupported = sentenceFigures.filter((f) => !allowed.has(f));
    if (unsupported.length > 0) {
      // Two classes, because the failures are different acts. With a citation
      // present the model contradicted the source it pointed at (§3.3.1 — a
      // figure not drawn from the record). With none, it produced a price from
      // nowhere (§3.0.1). The audit should be able to tell them apart.
      const cited = citedIds.length > 0;
      const claim = cited ? retrievedClaims.get(citedIds[0]!) : undefined;
      return {
        kind: 'blocked',
        text: visible,
        prohibitionClass: cited ? '3.3' : '3.0',
        claimKind: claim?.kind ?? null,
        tier: claim?.tier ?? null,
        messageTemplateId: cited ? 'SENTENCE_OMITTED_FIGURE_NOT_IN_CITED_CLAIM' : 'SENTENCE_OMITTED_UNSOURCED_FIGURE',
      };
    }
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
    // Written with audit_id NULL and collected for backfill, for the same
    // reason obs.ai_call is: a block happens DURING validation, and the audit
    // row it would reference is written after the stream completes. §3.13.1
    // requires a block to be logged, and an unattached record of it is strictly
    // better than a foreign-key violation instead of one.
    const { rows } = await db().query<{ record_fabrication_block: string }>(
      `SELECT obs.record_fabrication_block(
         $1, $2::claim_kind, $3::source_tier, $4::response_category,
         $5::source_tier, $6::claim_kind, $7::response_category, $8,
         $9, $10::jsonb, $11, $12) AS record_fabrication_block`,
      [
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
    const id = rows[0]?.record_fabrication_block;
    if (id) opts.ctx.pending.blocks.push(id);
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
  opts: ClassifyOptions = {},
): AsyncGenerator<ValidatedChunk> {
  let buffer = '';
  const retrievedIds = Array.from(retrievedClaims.keys());

  async function processSentence(raw: string): Promise<ValidatedChunk> {
    const verdict = classifySentence(raw, retrievedClaims, opts);
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
