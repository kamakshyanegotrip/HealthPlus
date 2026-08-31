import { describe, it, expect } from 'vitest';
import { classifySentence, splitIntoSentences } from '../src/lib/pipeline/emissionValidator';
import type { RetrievedClaim } from '../src/lib/types';

const CLAIM_ID = '33333333-3333-3333-3333-333333333333';

function claim(overrides: Partial<RetrievedClaim> = {}): RetrievedClaim {
  return {
    claimId: CLAIM_ID,
    kind: 'GUIDELINE',
    tier: 'TIER_2',
    category: 'DECISION_SUPPORT',
    confidence: 0.8,
    confidenceBand: 'Medium',
    citation: 'ADA 2026 Standards of Care',
    text: 'ADA 2026 guidance recommends HbA1c target below 7% for most non-pregnant adults with type 2 diabetes.',
    population: 'non-pregnant adults with type 2 diabetes',
    domain: 'GUIDELINE',
    ...overrides,
  };
}

describe('emissionValidator.classifySentence', () => {
  it('test_hp_esc_3_10_3_reassurance_blocked_regardless_of_citation', () => {
    const claims = new Map([[CLAIM_ID, claim()]]);
    const v = classifySentence(`Nothing to worry about here. [[claim:${CLAIM_ID}]]`, claims);
    expect(v.kind).toBe('blocked');
    if (v.kind === 'blocked') expect(v.prohibitionClass).toBe('3.10');
  });

  it('test_hp_esc_3_2_eligibility_language_blocked', () => {
    const v = classifySentence("You are eligible for this procedure.", new Map());
    expect(v.kind).toBe('blocked');
    if (v.kind === 'blocked') expect(v.prohibitionClass).toBe('3.2');
  });

  it('test_hp_esc_3_9_2_unknown_citation_blocked_even_if_claim_id_looks_valid', () => {
    // a well-formed UUID, but NOT in the retrieved set for THIS response
    const otherId = '55555555-5555-5555-5555-555555555555';
    const v = classifySentence(`HbA1c should be below 7%. [[claim:${otherId}]]`, new Map());
    expect(v.kind).toBe('blocked');
    if (v.kind === 'blocked') expect(v.prohibitionClass).toBe('3.9');
  });

  it('test_hp_esc_3_9_2_malformed_marker_is_blocked_and_never_leaks_raw_bracket_syntax', () => {
    // Regression test for a bug this suite caught: a marker whose content
    // isn't a well-formed id used to fail to match at all, leaving the raw
    // "[[claim:...]]" text visible to the user instead of being blocked.
    const v = classifySentence('The guideline says this. [[claim:not-a-real-id]]', new Map());
    expect(v.kind).toBe('blocked');
    if (v.kind === 'blocked') {
      expect(v.prohibitionClass).toBe('3.9');
      expect(v.text).not.toContain('[[claim:');
    }
  });

  it('test_hp_esc_3_0_3_uncited_numeric_claim_blocked', () => {
    const v = classifySentence("A hip replacement typically costs ₹350000 in Chennai.", new Map());
    expect(v.kind).toBe('blocked');
    if (v.kind === 'blocked') expect(v.prohibitionClass).toBe('3.0');
  });

  it('test_hp_esc_1_9_7_population_missing_blocked', () => {
    const claims = new Map([[CLAIM_ID, claim({ population: undefined, kind: 'GUIDELINE' })]]);
    const v = classifySentence(`The reference range is below 7%. [[claim:${CLAIM_ID}]]`, claims);
    expect(v.kind).toBe('blocked');
    if (v.kind === 'blocked') expect(v.prohibitionClass).toBe('1.9.7');
  });

  it('test_hp_esc_1_9_7_cost_kind_is_exempt_from_the_population_check', () => {
    const claims = new Map([[CLAIM_ID, claim({ population: undefined, kind: 'COST', text: 'Indicative package cost.' })]]);
    const v = classifySentence(`The package costs ₹350000. [[claim:${CLAIM_ID}]]`, claims);
    expect(v.kind).toBe('sentence');
  });

  it('test_hp_esc_3_0_3_properly_cited_sentence_with_population_passes', () => {
    const claims = new Map([[CLAIM_ID, claim()]]);
    const v = classifySentence(`ADA 2026 guidance recommends a target below 7% for this population. [[claim:${CLAIM_ID}]]`, claims);
    expect(v.kind).toBe('sentence');
    if (v.kind === 'sentence') {
      expect(v.citedClaimIds).toEqual([CLAIM_ID]);
      expect(v.text).not.toContain('[[claim:');
    }
  });

  it('test_hp_esc_3_0_3_plain_prose_with_no_claim_passes_through', () => {
    const v = classifySentence("Here's how these two hospitals compare on the criteria you asked about.", new Map());
    expect(v.kind).toBe('sentence');
  });

  it('test_citation_marker_is_stripped_from_visible_text', () => {
    const claims = new Map([[CLAIM_ID, claim()]]);
    const v = classifySentence(`Guideline recommends this. [[claim:${CLAIM_ID}]]`, claims);
    if (v.kind === 'sentence') expect(v.text).toBe('Guideline recommends this.');
  });
});

describe('emissionValidator.splitIntoSentences', () => {
  it('splits on sentence boundaries and holds back an incomplete tail', () => {
    const { complete, rest } = splitIntoSentences('First sentence. Second sentence. Third is incomp');
    expect(complete).toEqual(['First sentence.', 'Second sentence.']);
    expect(rest).toBe('Third is incomp');
  });

  it('does not split a decimal number', () => {
    const { complete, rest } = splitIntoSentences('The rate is 7.5 percent in most cases. Next sentence');
    expect(complete).toEqual(['The rate is 7.5 percent in most cases.']);
    expect(rest).toBe('Next sentence');
  });

  it('returns everything as rest when no boundary is complete yet', () => {
    const { complete, rest } = splitIntoSentences('Still typing this sentence out');
    expect(complete).toEqual([]);
    expect(rest).toBe('Still typing this sentence out');
  });
});
