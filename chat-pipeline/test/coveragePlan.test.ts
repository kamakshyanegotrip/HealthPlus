import { describe, it, expect } from 'vitest';
import { detectDimensions, planCoverage, DEFERRABLE_DIMENSIONS, CROSS_REFERENCES, ALL_DIMENSIONS } from '../src/lib/pipeline/coveragePlan';
import type { KnowledgeDomain, RetrievedClaim } from '../src/lib/types';

function claim(claimId: string, domain: KnowledgeDomain): RetrievedClaim {
  return {
    claimId,
    domain,
    kind: 'GENERAL_EDUCATION',
    tier: 'TIER_2',
    category: 'DECISION_SUPPORT',
    confidence: 0.8,
    confidenceBand: 'Medium',
    citation: '[FIXTURE]',
    text: 'fixture',
    demotionRequired: false,
  } as RetrievedClaim;
}

describe('coverage plan', () => {
  it('test_the_four_deferrable_dimensions_are_the_four_the_charter_names', () => {
    // §2.4.1a's table, for the dimensions this pipeline surfaces: §11 diet,
    // §15 exercise contraindication, §25 travel fitness, plus §3.2.1/§3.2.5
    // eligibility as CLINICAL_READINESS.
    expect([...DEFERRABLE_DIMENSIONS].sort()).toEqual(['CLINICAL_READINESS', 'DIET', 'EXERCISE', 'TRAVEL_FITNESS']);
  });

  it('test_cross_reference_graph_only_names_real_dimensions', () => {
    for (const x of CROSS_REFERENCES) {
      expect(ALL_DIMENSIONS).toContain(x.from);
      expect(ALL_DIMENSIONS).toContain(x.to);
      // A connection without a stated reason produces a sentence naming both
      // dimensions and connecting nothing. The reason is what the prompt uses.
      expect(x.because.length).toBeGreaterThan(40);
    }
  });

  it('test_intent_domains_recover_a_dimension_the_keywords_miss', () => {
    const found = detectDimensions('I need help planning this trip', ['VISA']);
    expect(found).toContain('VISA');
  });

  it('test_no_deferral_applies_when_the_classifier_did_not_say_clinical_decision', () => {
    // An ordinary Decision Support turn must not become defensive. Readiness
    // and travel fitness carry their published-criteria content like anything
    // else — the deferral machinery stays off this path entirely.
    const plan = planCoverage({
      message: 'What are the published pre-op criteria and typical recovery for knee replacement?',
      intentDomains: ['GUIDELINE'],
      admittedClaims: [claim('g1', 'GUIDELINE')],
      categoryWasClinicalDecision: false,
    });
    expect(plan.deferredDimensions).toHaveLength(0);
    expect(plan.dimensions.every((d) => d.deferral === null)).toBe(true);
    expect(plan.publishable).toBe(true);
  });

  it('test_deferred_dimension_with_published_criteria_is_answerable_with_deferral', () => {
    const plan = planCoverage({
      message: 'Am I fit to fly after knee surgery, and how long is recovery?',
      intentDomains: ['GUIDELINE'],
      admittedClaims: [claim('g1', 'GUIDELINE')],
      categoryWasClinicalDecision: true,
    });
    const tf = plan.dimensions.find((d) => d.key === 'TRAVEL_FITNESS');
    expect(tf?.disposition).toBe('ANSWERABLE_WITH_DEFERRAL');
    expect(tf?.deferral?.clause).toContain('3.2.3');
    // §2.3.6(c) — the adjacent help and the clinician question are both present,
    // because a deferral that offers neither is just a refusal in longer form.
    expect(tf?.deferral?.adjacentHelp).toMatch(/published fitness-to-travel criteria/i);
    expect(tf?.deferral?.clinicianQuestion).toMatch(/Ask your treating doctor/i);
  });

  it('test_deferred_dimension_with_no_evidence_says_both_things', () => {
    const plan = planCoverage({
      message: 'Am I fit to fly?',
      intentDomains: [],
      admittedClaims: [],
      categoryWasClinicalDecision: true,
    });
    expect(plan.dimensions.find((d) => d.key === 'TRAVEL_FITNESS')?.disposition).toBe('DEFERRED');
    expect(plan.publishable).toBe(false);
  });

  it('test_a_pure_category_c_question_is_not_publishable', () => {
    // "What does my HbA1c mean" asks for nothing but an interpretation. Nothing
    // is answerable, so route.ts takes the flat §2.3.6 refusal, unchanged.
    const plan = planCoverage({
      message: 'My HbA1c is 9.4. Am I ready for surgery?',
      intentDomains: [],
      admittedClaims: [],
      categoryWasClinicalDecision: true,
    });
    expect(plan.publishable).toBe(false);
    expect(plan.dimensions.every((d) => d.disposition === 'DEFERRED' || d.disposition === 'NO_EVIDENCE')).toBe(true);
  });

  it('test_one_answerable_dimension_makes_a_mixed_turn_publishable', () => {
    const plan = planCoverage({
      message: 'Am I ready for surgery, and which hospitals should I compare?',
      intentDomains: ['HOSPITAL'],
      admittedClaims: [claim('h1', 'HOSPITAL')],
      categoryWasClinicalDecision: true,
    });
    expect(plan.publishable).toBe(true);
    expect(plan.deferredDimensions).toContain('CLINICAL_READINESS');
    expect(plan.dimensions.find((d) => d.key === 'HOSPITAL_COMPARISON')?.disposition).toBe('ANSWERABLE');
  });

  it('test_hp_esc_3_0_1_requested_but_unsourced_dimension_becomes_no_evidence', () => {
    const plan = planCoverage({
      message: 'What visa do I need, and which hospitals should I compare?',
      intentDomains: [],
      admittedClaims: [claim('h1', 'HOSPITAL')],
      categoryWasClinicalDecision: false,
    });
    // Named, not silently dropped: §3.0.1 requires saying we do not have it.
    expect(plan.dimensions.find((d) => d.key === 'VISA')?.disposition).toBe('NO_EVIDENCE');
  });

  it('test_cross_references_are_filtered_to_the_dimensions_actually_present', () => {
    const plan = planCoverage({
      message: 'Which hospitals should I compare and how much does it cost?',
      intentDomains: [],
      admittedClaims: [claim('h1', 'HOSPITAL'), claim('c1', 'COST')],
      categoryWasClinicalDecision: false,
    });
    expect(plan.crossReferences.length).toBeGreaterThan(0);
    for (const x of plan.crossReferences) {
      expect(plan.dimensions.map((d) => d.key)).toContain(x.from);
      expect(plan.dimensions.map((d) => d.key)).toContain(x.to);
    }
  });
});
