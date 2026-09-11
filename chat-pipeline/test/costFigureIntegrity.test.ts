import { describe, it, expect } from 'vitest';
import { classifySentence, extractMonetaryFigures } from '../src/lib/pipeline/emissionValidator';
import type { RetrievedClaim } from '../src/lib/types';

/**
 * §3.3.1 — J11-2, the validator half.
 *
 * THE HOLE, MEASURED BEFORE IT WAS FIXED. A throwaway probe against the
 * shipping validator, 11 September 2026:
 *
 *   claim  a1…008  "…indicative total knee replacement package of USD 6,200."
 *   input  "Hospital A publishes an indicative package of $2,900 [[claim:a1…008]]."
 *   verdict: SENTENCE — emitted, shown to the patient.
 *
 * Citation integrity checked that the id had been retrieved. Nothing checked
 * that the NUMBER matched the claim the citation pointed at. §3.3.1 forbids
 * outputting "any price, package cost, fee, deposit, or total not drawn from a
 * persisted, sourced, in-date price record", and that was enforced by asking the
 * model nicely — which §3.0.3 says in terms is not enough.
 *
 * Worse, `NUMERIC_CLAIM_PATTERN` requires a currency SYMBOL adjacent to a digit,
 * so `USD 6,200` — the spelling a composer writing for an international patient
 * actually uses, and the spelling in every claim in the §42 fixture — was
 * invisible to every check in the file. An uncited `USD 4,000` sailed through
 * too.
 *
 * The fix is a regex over the cited claim's own prose, not a lookup, because
 * there is nothing to look up: `domain.hospital_cost` has currency, scope and
 * inclusion flags and NO amount column; `evidence.claim` has `statement text`
 * and nothing numeric. Amounts live in claim prose by Annex A.4's design. The
 * structured fix is `evidence.claim_cost` and a §6.3 decision — J11-2. §6.3
 * permits engineering to ADD a §3 prohibition at any time, which is why this
 * ships ahead of that one.
 */

function claim(over: Partial<RetrievedClaim> & { claimId: string; text: string }): RetrievedClaim {
  return {
    kind: 'COST',
    tier: 'TIER_4',
    category: 'DECISION_SUPPORT',
    confidence: 0.55,
    confidenceBand: 'Low',
    citation: '[FIXTURE]',
    demotionRequired: false,
    domain: 'COST',
    ...over,
  } as RetrievedClaim;
}

const COST_A = claim({
  claimId: 'a1000000-0000-4000-8000-000000000008',
  text: "Hospital A's published package sheet lists an indicative total knee replacement package of USD 6,200.",
});
const COST_B = claim({
  claimId: 'a1000000-0000-4000-8000-000000000009',
  text: "Hospital B's published package sheet lists an indicative total knee replacement package of USD 11,500.",
});
const BY_ID = new Map([COST_A, COST_B].map((c) => [c.claimId, c]));

describe('§3.3.1 monetary figure integrity', () => {
  it('test_hp_esc_3_3_1_a_figure_contradicting_its_own_citation_is_blocked', () => {
    // THE ONE THAT WAS BROKEN, and the reason this file exists.
    const v = classifySentence(`Hospital A publishes an indicative package of $2,900 [[claim:${COST_A.claimId}]].`, BY_ID);
    expect(v.kind).toBe('blocked');
    if (v.kind === 'blocked') {
      expect(v.prohibitionClass).toBe('3.3');
      expect(v.messageTemplateId).toBe('SENTENCE_OMITTED_FIGURE_NOT_IN_CITED_CLAIM');
    }
  });

  it('test_the_true_figure_still_passes', () => {
    // A rule that blocks the correct sentence too is not a rule, it is an outage.
    expect(classifySentence(`Hospital A publishes an indicative package of USD 6,200 [[claim:${COST_A.claimId}]].`, BY_ID).kind).toBe('sentence');
    expect(classifySentence(`Hospital A publishes an indicative package of $6,200 [[claim:${COST_A.claimId}]].`, BY_ID).kind).toBe('sentence');
  });

  it('test_a_figure_from_a_claim_the_sentence_did_not_cite_is_blocked', () => {
    // B's number while pointing at A's claim. Both claims were retrieved, so
    // this is not an unknown-citation failure — it is §3.3.1, and the older
    // checks had no opinion about it at all.
    const v = classifySentence(`Hospital A publishes an indicative package of USD 11,500 [[claim:${COST_A.claimId}]].`, BY_ID);
    expect(v.kind).toBe('blocked');
  });

  it('test_a_sentence_citing_both_claims_may_carry_both_figures', () => {
    const v = classifySentence(
      `The two packages are USD 6,200 [[claim:${COST_A.claimId}]] and USD 11,500 [[claim:${COST_B.claimId}]].`,
      BY_ID,
    );
    expect(v.kind).toBe('sentence');
  });

  it('test_hp_esc_3_0_1_an_uncited_figure_is_blocked_even_without_a_currency_symbol', () => {
    // The second hole. NUMERIC_CLAIM_PATTERN needs a symbol next to a digit, so
    // "USD 4,000" uncited was invisible — the exact spelling the §42 claims use.
    const v = classifySentence('The total usually comes to about USD 4,000.', BY_ID);
    expect(v.kind).toBe('blocked');
    if (v.kind === 'blocked') {
      expect(v.prohibitionClass).toBe('3.0');
      expect(v.messageTemplateId).toBe('SENTENCE_OMITTED_UNSOURCED_FIGURE');
    }
  });

  it('test_hp_esc_3_3_3_the_patients_own_stated_ceiling_is_permitted', () => {
    // §3.3.3 tells the composer to NAME an over-budget option rather than drop
    // it. The ceiling is the patient's own number, not a sourced claim, so
    // blocking it would punish the composer for obeying the Charter. Threaded
    // from the same constraint ladder the composer saw.
    const sentence = 'Hospital B sits above the USD 9,000 ceiling you stated.';
    expect(classifySentence(sentence, BY_ID).kind).toBe('blocked');
    expect(classifySentence(sentence, BY_ID, { permittedFigures: ['USD:9000'] }).kind).toBe('sentence');
  });

  it('test_non_monetary_numbers_are_untouched', () => {
    // The rule must not fire on recovery weeks, ages, or claim counts — it is
    // about prices, not digits.
    expect(classifySentence('The supervised rehabilitation phase runs for several weeks.', BY_ID).kind).toBe('sentence');
    expect(classifySentence('Two hospitals are compared below.', BY_ID).kind).toBe('sentence');
  });
});

describe('monetary figure extraction', () => {
  it('test_the_three_spellings_normalise_to_one_token', () => {
    // $6,200 / USD 6,200 / 6200 USD must compare equal, or the rule fires on a
    // composer that merely chose a different house style.
    for (const s of ['$6,200', 'USD 6,200', 'USD6200', '6,200 USD']) {
      expect(extractMonetaryFigures(s), s).toContain('USD:6200');
    }
  });

  it('test_indian_digit_grouping_is_handled', () => {
    // ₹1,50,000 is not ₹150,000 to a naive comma-stripper that assumes
    // thousands. It is here, and this platform's destination market writes it
    // that way.
    expect(extractMonetaryFigures('The package is ₹1,50,000 all-in.')).toContain('INR:150000');
  });

  it('test_currencies_do_not_collide', () => {
    const figs = extractMonetaryFigures('USD 6,200 and INR 6,200 are different numbers.');
    expect(figs).toContain('USD:6200');
    expect(figs).toContain('INR:6200');
  });

  it('test_prose_without_money_yields_nothing', () => {
    expect(extractMonetaryFigures('Recovery is measured in weeks, and 2026 guidance applies.')).toEqual([]);
  });
});
