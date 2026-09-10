import { describe, it, expect } from 'vitest';
import { highRiskProfileRequiresReview, minorGateRequiresReview } from '../src/lib/pipeline/patientProfile';
import { topicGateRequiresReview, topicAuditTrigger, type TopicCheck } from '../src/lib/pipeline/elevatedTopic';
import type { PatientProfile, RiskFlagKey } from '../src/lib/types';

/**
 * §2.2.5b's five pre-publication review triggers — the pure half.
 *
 * migrations/test/sr1_review_triggers.sh covers what the DATABASE decides.
 * These are the two helpers that turn what it returns into "review or not", and
 * both of them are three-valued questions squeezed into a boolean at the call
 * site — which is exactly where HP-SR-001 found the original defect
 * (`profile?.isMinor === true` answering "is this definitely a minor?" when the
 * clause asks "may this be published without review?").
 */

function profile(riskFlags: RiskFlagKey[], isMinor: boolean | null = null): PatientProfile {
  return {
    userId: '00000000-0000-4000-8000-000000000001',
    dataRegion: 'IN',
    residencyCountry: 'IN',
    riskFlags,
    statedConditions: [],
    preferences: null,
    isMinor,
  } as PatientProfile;
}

describe('§2.2.5b trigger 1 — a flagged high-risk profile (§4.6)', () => {
  it('test_hp_esc_2_2_5b_1_any_single_clinical_flag_forces_review', () => {
    // Every one of the eight CLINICAL flags fires it, individually. Written as a
    // loop rather than one representative case: a helper that special-cased
    // AGE_UNDER_18 would pass a single-flag test, and that is the exact bug this
    // closes — nine of the ten flags were being read and discarded.
    const clinical: RiskFlagKey[] = [
      'PREGNANCY', 'IMMUNOSUPPRESSION', 'ACTIVE_MALIGNANCY', 'ANTICOAGULATION',
      'TRANSPLANT_RECIPIENT', 'POST_OP_UNDER_30D', 'DIALYSIS', 'ANAPHYLAXIS_HISTORY',
    ];
    for (const flag of clinical) {
      expect(highRiskProfileRequiresReview(profile([flag])), flag).toBe(true);
    }
  });

  it('test_hp_esc_2_2_5b_1_age_flags_are_left_to_2_4_3', () => {
    // A NARROWING, and the reasoning is on the helper. Under the literal reading
    // no subject could ever publish: deriveIsMinor returns false ONLY via
    // AGE_75_PLUS, so an established adult always carried a flag and an
    // unestablished one always failed the minor gate. This asserts the narrowing
    // stays exactly two keys wide — a third name added here would be a silent
    // hole rather than a recorded decision.
    expect(highRiskProfileRequiresReview(profile(['AGE_75_PLUS']))).toBe(false);
    expect(highRiskProfileRequiresReview(profile(['AGE_UNDER_18']))).toBe(false);
    // …and an age flag does not mask a clinical one sitting beside it.
    expect(highRiskProfileRequiresReview(profile(['AGE_75_PLUS', 'DIALYSIS']))).toBe(true);
    // The minor gate is what governs the age flags, and still does.
    expect(minorGateRequiresReview(profile(['AGE_UNDER_18'], true))).toBe(true);
    expect(minorGateRequiresReview(profile(['AGE_75_PLUS'], false))).toBe(false);
  });

  it('test_hp_esc_2_2_5b_1_no_flags_does_not_fire_this_trigger', () => {
    // CLEAR for this trigger specifically. The response may still be reviewed
    // for one of the other four, and keeping them separable is what lets the
    // audit row say WHICH fired.
    expect(highRiskProfileRequiresReview(profile([]))).toBe(false);
  });

  it('test_hp_esc_2_2_5b_1_absent_profile_is_not_a_flag', () => {
    // Deliberately false, and the reasoning is on the helper: "no flags are
    // known" is not "a flag is present". The unknown case is forced closed by
    // the minor gate instead, which is asserted here so the pair cannot drift.
    expect(highRiskProfileRequiresReview(null)).toBe(false);
    expect(minorGateRequiresReview(null)).toBe(true);
  });
});

describe('§2.2.5b trigger 2 — the Elevated-Risk Topic List (§2.4.1)', () => {
  it('test_hp_esc_2_2_5b_2_unevaluable_forces_review', () => {
    // THE ONE THAT MATTERS. No adopted list means the question cannot be
    // answered, and §3.0.3 answers an unestablished fact closed. A boolean
    // check would have collapsed this into "no match" and published
    // paediatric-oncology content unreviewed the day §4 adopts.
    const check: TopicCheck = { state: 'UNEVALUABLE' };
    expect(topicGateRequiresReview(check)).toBe(true);
    expect(topicAuditTrigger(check)).toBe('ELEVATED_TOPIC_UNEVALUABLE');
  });

  it('test_hp_esc_2_2_5b_2_match_forces_review_and_is_named_differently', () => {
    const check: TopicCheck = { state: 'MATCHED', ordinals: [5, 10], terms: ['my son', 'self harm'] };
    expect(topicGateRequiresReview(check)).toBe(true);
    // Distinct from UNEVALUABLE on purpose: an audit trail that recorded only
    // "review required" could not later answer whether the topic list was
    // checked or whether there was none.
    expect(topicAuditTrigger(check)).toBe('ELEVATED_TOPIC');
  });

  it('test_hp_esc_2_2_5b_2_clear_is_the_only_state_that_does_not_force_review', () => {
    const check: TopicCheck = { state: 'CLEAR' };
    expect(topicGateRequiresReview(check)).toBe(false);
    expect(topicAuditTrigger(check)).toBeNull();
  });
});
