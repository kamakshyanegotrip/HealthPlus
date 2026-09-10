import { describe, it, expect } from 'vitest';
import { resolveConstraints, applyConstraints } from '../src/lib/pipeline/constraintSet';
import type { KnowledgeDomain, PatientProfile, RetrievedClaim } from '../src/lib/types';

function claim(over: Partial<RetrievedClaim> & { claimId: string; domain: KnowledgeDomain; text: string }): RetrievedClaim {
  return {
    kind: 'GENERAL_EDUCATION',
    tier: 'TIER_2',
    category: 'DECISION_SUPPORT',
    confidence: 0.8,
    confidenceBand: 'Medium',
    citation: '[FIXTURE]',
    demotionRequired: false,
    ...over,
  } as RetrievedClaim;
}

function profileWith(preferences: Record<string, unknown> | null): PatientProfile {
  return {
    userId: 'u',
    dataRegion: 'IN',
    residencyCountry: 'NG',
    riskFlags: [],
    statedConditions: [],
    preferences,
    isMinor: null,
  };
}

const NO_FLAG = { redFlagSeverityAtLeastWarning: false };

describe('constraint ladder', () => {
  it('test_precedence_is_rank_ordered_highest_first', () => {
    const set = resolveConstraints(
      profileWith({ dietary_pattern: 'vegetarian', mobility: 'limited', budget_ceiling_amount: 9000, budget_ceiling_currency: 'usd', preferred_language: 'english' }),
      { redFlagSeverityAtLeastWarning: true },
    );
    expect(set.constraints.map((c) => c.rank)).toEqual([
      'SAFETY_SUPPRESSION',
      'DIETARY_EXCLUSION',
      'ACTIVITY_PRECAUTION_PRIORITY',
      'BUDGET_CEILING',
      'MOBILITY_BOUND',
      'PREFERENCE',
    ]);
  });

  it('test_hp_esc_4_0_6_safety_suppression_outranks_and_removes_commercial_content', () => {
    const set = resolveConstraints(profileWith({ budget_ceiling_amount: 9000, budget_ceiling_currency: 'usd' }), {
      redFlagSeverityAtLeastWarning: true,
    });
    const { admitted, suppressed } = applyConstraints(set, [
      claim({ claimId: 'c1', domain: 'COST', kind: 'COST', text: 'Indicative package USD 6,200.' }),
      claim({ claimId: 'c2', domain: 'HOSPITAL', text: 'Hospital A holds current accreditation.' }),
      claim({ claimId: 'c3', domain: 'GUIDELINE', text: 'Published recovery course.' }),
    ]);
    // Commercial domains gone; the clinical reference content stays.
    expect(admitted.map((c) => c.claimId)).toEqual(['c3']);
    expect(suppressed.every((s) => s.byConstraint === 'safety.commercial_suppressed')).toBe(true);
  });

  it('test_dietary_exclusion_overrides_generic_nutrition_content', () => {
    const set = resolveConstraints(profileWith({ dietary_pattern: 'vegetarian' }), NO_FLAG);
    const { admitted, suppressed } = applyConstraints(set, [
      claim({ claimId: 'veg', domain: 'NUTRITION', text: 'A vegetarian pattern built on pulses, whole grains and nuts.' }),
      claim({ claimId: 'meat', domain: 'NUTRITION', text: 'A pattern in which oily fish twice weekly and lean poultry provide the protein.' }),
    ]);
    expect(admitted.map((c) => c.claimId)).toEqual(['veg']);
    expect(suppressed).toHaveLength(1);
    expect(suppressed[0]?.claim.claimId).toBe('meat');
    // §2.2.3d — the reason travels with the suppression so the composer can say it.
    expect(suppressed[0]?.statement).toMatch(/vegetarian/i);
  });

  it('test_hp_esc_3_3_3_budget_ceiling_bounds_but_never_drops_a_cost_claim', () => {
    const set = resolveConstraints(profileWith({ budget_ceiling_amount: 9000, budget_ceiling_currency: 'usd' }), NO_FLAG);
    const { admitted, bounded, suppressed } = applyConstraints(set, [
      claim({ claimId: 'under', domain: 'COST', kind: 'COST', text: 'Indicative package of USD 6,200 covering surgery and implant.' }),
      claim({ claimId: 'over', domain: 'COST', kind: 'COST', text: 'Indicative package of USD 11,500 covering surgery and a private room.' }),
    ]);
    // Both survive. An indicative estimate is not a price (§3.3.3), so a
    // silent drop on a threshold would treat it as one.
    expect(admitted.map((c) => c.claimId).sort()).toEqual(['over', 'under']);
    expect(suppressed).toHaveLength(0);
    expect(bounded.map((b) => b.claim.claimId)).toEqual(['over']);
  });

  it('test_unreadable_cost_figure_is_not_marked_over_budget', () => {
    // extractCostAmount returns null rather than guessing. Under-marking costs
    // a sentence; over-marking tells the patient something false about a price.
    const set = resolveConstraints(profileWith({ budget_ceiling_amount: 100, budget_ceiling_currency: 'usd' }), NO_FLAG);
    const { bounded } = applyConstraints(set, [
      claim({ claimId: 'vague', domain: 'COST', kind: 'COST', text: 'Costs vary considerably between providers.' }),
    ]);
    expect(bounded).toHaveLength(0);
  });

  it('test_limited_mobility_raises_precautions_above_general_recommendations', () => {
    const set = resolveConstraints(profileWith({ mobility: 'limited' }), NO_FLAG);
    const { admitted } = applyConstraints(set, [
      claim({ claimId: 'general', domain: 'EXERCISE', text: 'Accumulate moderate aerobic activity across the week.' }),
      claim({ claimId: 'precaution', domain: 'EXERCISE', text: 'Precautions caution against high-impact loading and unsupervised progression.' }),
    ]);
    expect(admitted.map((c) => c.claimId)).toEqual(['precaution', 'general']);
  });

  it('test_no_profile_yields_an_empty_set_not_an_unrestricted_one', () => {
    const set = resolveConstraints(null, NO_FLAG);
    expect(set.empty).toBe(true);
    expect(set.constraints).toHaveLength(0);
    // Everything is admitted, and the composer is separately instructed to say
    // "we hold none" rather than "you have none" — see synthesis.ts's
    // constraintsBlock. §3.8.1 forbids inventing the second.
    const { admitted } = applyConstraints(set, [claim({ claimId: 'x', domain: 'NUTRITION', text: 'anything' })]);
    expect(admitted).toHaveLength(1);
  });

  it('test_unknown_preference_keys_are_ignored_not_guessed', () => {
    const set = resolveConstraints(profileWith({ diet: 'vegetarian', mobilityLevel: 'limited' }), NO_FLAG);
    expect(set.empty).toBe(true);
  });

  it('test_hp_esc_3_8_2_stated_conditions_never_become_constraints', () => {
    const p = profileWith(null);
    p.statedConditions = [
      { label: 'type 2 diabetes', provenance: 'stated' },
      { label: 'hypertension', provenance: 'stated' },
    ];
    const set = resolveConstraints(p, NO_FLAG);
    // A constraint derived from a diagnosis is a determination about the
    // patient's clinical situation — §2.3.1 Category C. The ladder reads
    // PREFERENCE attributes only, and this asserts it stays that way.
    expect(set.empty).toBe(true);
    expect(JSON.stringify(set)).not.toMatch(/diabetes|hypertension/i);
  });

  it('test_explicit_food_exclusions_work_without_a_named_pattern', () => {
    const set = resolveConstraints(profileWith({ food_exclusions: ['peanut'] }), NO_FLAG);
    const { suppressed } = applyConstraints(set, [
      claim({ claimId: 'nuts', domain: 'NUTRITION', text: 'Peanut-based snacks are a common protein source in this pattern.' }),
    ]);
    expect(suppressed).toHaveLength(1);
  });
});
