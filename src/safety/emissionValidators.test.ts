/**
 * Clause-named tests for `emissionValidators.ts` (HP-OIR build item "B6").
 *
 * Per Annex A.8: "Each MUST have unit tests naming the clause they enforce,
 * e.g. `test_hp_esc_1_5_3_tier5_blocked_for_efficacy_claims`." That exact
 * example is implemented verbatim below as the first suite. Every other
 * suite follows the same naming convention for the clause it covers, and
 * each suite carries at minimum a violation case and a passing case, so a
 * validator that always blocks (or never blocks) fails its own tests.
 */
import { describe, it, expect } from 'vitest';
import {
  validateHpEsc_1_5_3_TierClaimKindMatrix,
  validateHpEsc_3_0_1_NoSourcelessEmission,
  validateHpEsc_3_3_8_CostPastHardExpiryUnavailable,
  validateHpEsc_3_4_2_NoProviderSpecificAttributionFromGenericSource,
  validateHpEsc_3_5_2_ReferenceRangeRequiresPopulation,
  validateHpEsc_1_4_4_Tier4ClinicalCapAndMarker,
  validateHpEsc_3_10_3_NoReassuranceLanguage,
  validateHpEsc_4_0_6_NoCommercialContentAtElevatedSeverity,
  validateHpEsc_4_0_9_FailSafeOnScannerError,
  runEmissionGate,
  type ClaimForEmission,
  type CandidateResponse,
  type EmissionSource,
} from './emissionValidators';
import { SELF_REPORT_MARKER } from '../lib/claimKindPolicy';

function source(overrides: Partial<EmissionSource> = {}): EmissionSource {
  return { id: 'src-1', tier: 'TIER_1', isProviderSpecific: false, ...overrides };
}

function claim(overrides: Partial<ClaimForEmission> = {}): ClaimForEmission {
  return {
    id: 'claim-1',
    kind: 'GENERAL_EDUCATION',
    statement: 'A coronary angioplasty widens a narrowed or blocked coronary artery.',
    population: null,
    expiresAt: null,
    confidence: 0.8,
    attributedToNamedProvider: false,
    sources: [source()],
    ...overrides,
  };
}

function response(overrides: Partial<CandidateResponse> = {}): CandidateResponse {
  return {
    claims: [claim()],
    severity: 'NORMAL',
    includesCommercialContent: false,
    outputText: 'General information only.',
    severityScanStatus: 'OK',
    ...overrides,
  };
}

describe('test_hp_esc_1_5_3_tier5_blocked_for_efficacy_claims', () => {
  it('blocks a CLINICAL_EFFICACY claim that cites a TIER_5 source', () => {
    const c = claim({ kind: 'CLINICAL_EFFICACY', sources: [source({ tier: 'TIER_5' })] });
    const violations = validateHpEsc_1_5_3_TierClaimKindMatrix(c);
    expect(violations).toHaveLength(1);
    expect(violations[0].clause).toBe('HP-ESC 1.5.3');
  });

  it('also blocks the other §1.5.3-named kinds (COST, PROVIDER_OUTCOME, ELIGIBILITY, ...) on a TIER_5 source', () => {
    for (const kind of ['COST', 'PROVIDER_OUTCOME', 'ELIGIBILITY', 'TEST_INTERPRETATION', 'REFERENCE_RANGE', 'LEGAL_REGULATORY'] as const) {
      const c = claim({ kind, sources: [source({ tier: 'TIER_5' })] });
      expect(validateHpEsc_1_5_3_TierClaimKindMatrix(c)).toHaveLength(1);
    }
  });

  it('passes a CLINICAL_EFFICACY claim sourced from TIER_1/2/3', () => {
    const c = claim({ kind: 'CLINICAL_EFFICACY', sources: [source({ tier: 'TIER_2' })] });
    expect(validateHpEsc_1_5_3_TierClaimKindMatrix(c)).toHaveLength(0);
  });

  it('does not apply to claim kinds §1.5.3 does not name (e.g. GENERAL_EDUCATION, SENTIMENT)', () => {
    const c = claim({ kind: 'SENTIMENT', sources: [source({ tier: 'TIER_5' })] });
    expect(validateHpEsc_1_5_3_TierClaimKindMatrix(c)).toHaveLength(0);
  });
});

describe('test_hp_esc_3_0_1_no_source_no_emission', () => {
  it('blocks a claim with zero resolved sources', () => {
    const c = claim({ sources: [] });
    const violations = validateHpEsc_3_0_1_NoSourcelessEmission(c);
    expect(violations).toHaveLength(1);
    expect(violations[0].clause).toBe('HP-ESC 3.0.1');
  });

  it('passes a claim with at least one resolved source', () => {
    const c = claim({ sources: [source()] });
    expect(validateHpEsc_3_0_1_NoSourcelessEmission(c)).toHaveLength(0);
  });
});

describe('test_hp_esc_3_3_8_expired_cost_is_unavailable_not_approximate', () => {
  const now = new Date('2026-08-30T00:00:00Z');

  it('blocks a COST claim past its recorded expiry', () => {
    const c = claim({ kind: 'COST', expiresAt: '2026-01-01T00:00:00Z' });
    const violations = validateHpEsc_3_3_8_CostPastHardExpiryUnavailable(c, now);
    expect(violations).toHaveLength(1);
    expect(violations[0].clause).toBe('HP-ESC 3.3.8');
  });

  it('blocks a COST claim with no recorded expiry at all — never treated as evergreen', () => {
    const c = claim({ kind: 'COST', expiresAt: null });
    expect(validateHpEsc_3_3_8_CostPastHardExpiryUnavailable(c, now)).toHaveLength(1);
  });

  it('passes a COST claim not yet past its expiry', () => {
    const c = claim({ kind: 'COST', expiresAt: '2026-12-31T00:00:00Z' });
    expect(validateHpEsc_3_3_8_CostPastHardExpiryUnavailable(c, now)).toHaveLength(0);
  });

  it('does not apply to non-COST claims regardless of expiry', () => {
    const c = claim({ kind: 'PROVIDER_OUTCOME', expiresAt: null });
    expect(validateHpEsc_3_3_8_CostPastHardExpiryUnavailable(c, now)).toHaveLength(0);
  });
});

describe('test_hp_esc_3_4_2_no_literature_outcome_attributed_to_named_provider', () => {
  it('blocks a PROVIDER_OUTCOME claim attributed to a named provider but backed only by a generic literature source', () => {
    const c = claim({
      kind: 'PROVIDER_OUTCOME',
      attributedToNamedProvider: true,
      sources: [source({ tier: 'TIER_3', isProviderSpecific: false })],
    });
    const violations = validateHpEsc_3_4_2_NoProviderSpecificAttributionFromGenericSource(c);
    expect(violations).toHaveLength(1);
    expect(violations[0].clause).toBe('HP-ESC 3.4.2');
  });

  it('passes when at least one bound source is itself about the named provider', () => {
    const c = claim({
      kind: 'PROVIDER_OUTCOME',
      attributedToNamedProvider: true,
      sources: [source({ tier: 'TIER_3', isProviderSpecific: false }), source({ tier: 'TIER_4', isProviderSpecific: true })],
    });
    expect(validateHpEsc_3_4_2_NoProviderSpecificAttributionFromGenericSource(c)).toHaveLength(0);
  });

  it('does not apply to a population-level claim not attributed to a named provider', () => {
    const c = claim({ kind: 'PROVIDER_OUTCOME', attributedToNamedProvider: false, sources: [source({ isProviderSpecific: false })] });
    expect(validateHpEsc_3_4_2_NoProviderSpecificAttributionFromGenericSource(c)).toHaveLength(0);
  });
});

describe('test_hp_esc_3_5_2_reference_range_requires_population', () => {
  it('blocks a REFERENCE_RANGE claim with no population', () => {
    const c = claim({ kind: 'REFERENCE_RANGE', population: null });
    const violations = validateHpEsc_3_5_2_ReferenceRangeRequiresPopulation(c);
    expect(violations).toHaveLength(1);
    expect(violations[0].clause).toBe('HP-ESC 3.5.2');
  });

  it('passes a REFERENCE_RANGE claim that names its population', () => {
    const c = claim({ kind: 'REFERENCE_RANGE', population: 'non-pregnant adults, 18-65' });
    expect(validateHpEsc_3_5_2_ReferenceRangeRequiresPopulation(c)).toHaveLength(0);
  });
});

describe('test_hp_esc_1_4_4_tier4_outcome_capped_and_marked', () => {
  it('blocks a Tier-4-only PROVIDER_OUTCOME claim above the 0.40 cap', () => {
    const c = claim({
      kind: 'PROVIDER_OUTCOME',
      confidence: 0.55,
      statement: `Success rate is high. ${SELF_REPORT_MARKER}`,
      sources: [source({ tier: 'TIER_4' })],
    });
    const violations = validateHpEsc_1_4_4_Tier4ClinicalCapAndMarker(c);
    expect(violations).toHaveLength(1);
    expect(violations[0].message).toContain('confidence');
  });

  it('blocks a Tier-4-only PROVIDER_OUTCOME claim missing the mandatory self-report marker', () => {
    const c = claim({
      kind: 'PROVIDER_OUTCOME',
      confidence: 0.4,
      statement: 'Success rate is high.',
      sources: [source({ tier: 'TIER_4' })],
    });
    const violations = validateHpEsc_1_4_4_Tier4ClinicalCapAndMarker(c);
    expect(violations).toHaveLength(1);
    expect(violations[0].message).toContain('self-report marker');
  });

  it('passes a Tier-4-only PROVIDER_OUTCOME claim at or below the cap and carrying the marker', () => {
    const c = claim({
      kind: 'PROVIDER_OUTCOME',
      confidence: 0.4,
      statement: `Success rate is high. ${SELF_REPORT_MARKER}`,
      sources: [source({ tier: 'TIER_4' })],
    });
    expect(validateHpEsc_1_4_4_Tier4ClinicalCapAndMarker(c)).toHaveLength(0);
  });

  it('does not apply once a Tier 1-3 source also backs the claim', () => {
    const c = claim({
      kind: 'PROVIDER_OUTCOME',
      confidence: 0.8,
      statement: 'Success rate is high.',
      sources: [source({ tier: 'TIER_4' }), source({ tier: 'TIER_2' })],
    });
    expect(validateHpEsc_1_4_4_Tier4ClinicalCapAndMarker(c)).toHaveLength(0);
  });
});

describe('test_hp_esc_3_10_3_no_reassurance_language', () => {
  it('blocks output text containing a reassurance phrase', () => {
    const r = response({ outputText: "Don't worry, you'll be fine after the procedure." });
    const violations = validateHpEsc_3_10_3_NoReassuranceLanguage(r);
    expect(violations).toHaveLength(1);
    expect(violations[0].clause).toBe('HP-ESC 3.10.3');
  });

  it('passes neutral, non-reassuring output text', () => {
    const r = response({ outputText: 'Here is what published guidelines say about this procedure.' });
    expect(validateHpEsc_3_10_3_NoReassuranceLanguage(r)).toHaveLength(0);
  });
});

describe('test_hp_esc_4_0_6_commercial_content_suppressed_at_warning_and_above', () => {
  it('blocks a WARNING-severity response that still carries commercial content', () => {
    const r = response({ severity: 'WARNING', includesCommercialContent: true });
    const violations = validateHpEsc_4_0_6_NoCommercialContentAtElevatedSeverity(r);
    expect(violations).toHaveLength(1);
    expect(violations[0].clause).toBe('HP-ESC 4.0.6');
  });

  it('blocks at EMERGENCY too, not only the WARNING floor', () => {
    const r = response({ severity: 'EMERGENCY', includesCommercialContent: true });
    expect(validateHpEsc_4_0_6_NoCommercialContentAtElevatedSeverity(r)).toHaveLength(1);
  });

  it('passes a WARNING-severity response with no commercial content', () => {
    const r = response({ severity: 'WARNING', includesCommercialContent: false });
    expect(validateHpEsc_4_0_6_NoCommercialContentAtElevatedSeverity(r)).toHaveLength(0);
  });

  it('passes commercial content below the WARNING floor (NORMAL, MONITOR)', () => {
    const r = response({ severity: 'MONITOR', includesCommercialContent: true });
    expect(validateHpEsc_4_0_6_NoCommercialContentAtElevatedSeverity(r)).toHaveLength(0);
  });
});

describe('test_hp_esc_4_0_9_scanner_failure_fails_to_highest_severity', () => {
  it('blocks emission when the severity scan errored', () => {
    const r = response({ severityScanStatus: 'ERROR' });
    const violations = validateHpEsc_4_0_9_FailSafeOnScannerError(r);
    expect(violations).toHaveLength(1);
    expect(violations[0].clause).toBe('HP-ESC 4.0.9');
  });

  it('blocks emission when the severity scan never ran (MISSING)', () => {
    const r = response({ severityScanStatus: 'MISSING' });
    expect(validateHpEsc_4_0_9_FailSafeOnScannerError(r)).toHaveLength(1);
  });

  it('passes when the severity scan completed cleanly', () => {
    const r = response({ severityScanStatus: 'OK' });
    expect(validateHpEsc_4_0_9_FailSafeOnScannerError(r)).toHaveLength(0);
  });
});

describe('runEmissionGate (aggregate checkpoint)', () => {
  it('passes a clean, fully-sourced, low-severity response with no commercial content', () => {
    const result = runEmissionGate(response());
    expect(result.blocked).toBe(false);
    expect(result.violations).toHaveLength(0);
  });

  it('blocks and reports every violation across multiple claims and response-level checks at once', () => {
    const bad = response({
      severity: 'URGENT',
      includesCommercialContent: true,
      outputText: "You'll be fine.",
      severityScanStatus: 'OK',
      claims: [
        claim({ id: 'c-sourceless', sources: [] }),
        claim({ id: 'c-expired-cost', kind: 'COST', expiresAt: '2020-01-01T00:00:00Z' }),
      ],
    });
    const result = runEmissionGate(bad, new Date('2026-08-30T00:00:00Z'));
    expect(result.blocked).toBe(true);
    const clauses = result.violations.map((v) => v.clause).sort();
    expect(clauses).toEqual(
      ['HP-ESC 3.0.1', 'HP-ESC 3.10.3', 'HP-ESC 3.3.8', 'HP-ESC 4.0.6'].sort(),
    );
  });
});
