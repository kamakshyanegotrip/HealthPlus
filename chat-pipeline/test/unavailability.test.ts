import { describe, it, expect } from 'vitest';
import {
  assertNoProhibitedPhrases,
  PROHIBITED_UNAVAILABILITY_PHRASES,
  UNAVAILABILITY_COPY_VERSION,
  surfaceGate,
} from '@/lib/pipeline/unavailability';
import { displayLatencyMs } from '@/lib/pipeline/redFlagEngine';
import { SEVERITY_ORDER } from '@/lib/types';

/**
 * HP-JOB-004 RF1. The whole risk of the FAIL_CLOSED screen is that it says
 * something, so most of these assert what it must NOT say — "the copy
 * accidentally reassured someone" is not a failure any type system catches.
 *
 * Pure functions only, matching redFlagEngine.test.ts's existing pattern: no
 * DB, no network. The DB-touching half (buildUnavailability's reference-table
 * lookup) is exercised by runPipeline.integration.test.ts.
 */

describe('RF1 unavailability copy', () => {
  it('test_hp_esc_3_10_3_guard_catches_reassurance', () => {
    expect(() => assertNoProhibitedPhrases('Nothing to worry about.')).toThrow(/3\.10\.3/);
    expect(() => assertNoProhibitedPhrases('You’ll be fine.')).toThrow();
  });

  it('test_hp_esc_3_11_3_guard_catches_implied_clinical_review', () => {
    expect(() => assertNoProhibitedPhrases('Our clinicians have looked at this.')).toThrow();
    expect(() => assertNoProhibitedPhrases('This has been reviewed.')).toThrow();
  });

  it('test_hp_esc_3_11_3_guard_catches_an_asserted_triage_outcome', () => {
    // The dangerous one: a message nobody read, described as clean.
    expect(() => assertNoProhibitedPhrases('We found no red flag in your message.')).toThrow();
    expect(() => assertNoProhibitedPhrases('Nothing concerning here.')).toThrow();
  });

  it('test_rf1_guard_is_curly_apostrophe_safe', () => {
    // The shipped copy is written with curly apostrophes; a guard that only
    // knows straight ones would pass everything it is meant to catch.
    expect(() => assertNoProhibitedPhrases('you’ll be fine')).toThrow();
  });

  it('test_rf1_guard_does_not_fire_on_legitimate_copy', () => {
    expect(() =>
      assertNoProhibitedPhrases(
        'This part of HealthPlus is unavailable at the moment. We have not reviewed what you wrote.',
      ),
    ).not.toThrow();
  });

  it('test_rf1_copy_version_is_pinned', () => {
    // Pinned so red_flag_log.fail_safe_reason can be correlated with what the
    // user actually read. Changing the wording without bumping this breaks that.
    expect(UNAVAILABILITY_COPY_VERSION).toBe('hp-redflag-unavailable-v1.0.0');
    expect(PROHIBITED_UNAVAILABILITY_PHRASES.length).toBeGreaterThan(10);
  });
});

describe('RF1 surfaceGate (§4.0.6)', () => {
  const gateFor = (severity: Parameters<typeof surfaceGate>[0]['severity']) =>
    surfaceGate({ unavailability: null, severity, severityOrder: SEVERITY_ORDER });

  it('test_hp_esc_4_0_6_normal_suppresses_nothing', () => {
    expect(gateFor('NORMAL').suppressed).toEqual([]);
    expect(gateFor('NORMAL').allows('PRICING')).toBe(true);
  });

  it('test_hp_esc_4_0_6_warning_suppresses_commercial_but_not_generation', () => {
    const g = gateFor('WARNING');
    expect(g.allows('PRICING')).toBe(false);
    expect(g.allows('BOOKING')).toBe(false);
    expect(g.allows('PROMOTIONAL')).toBe(false);
    // §4.1: Decision Support may still follow the safety block at WARNING.
    expect(g.allows('GENERATIVE_HEALTH')).toBe(true);
  });

  it('test_hp_esc_4_1_urgent_also_blocks_generative_health', () => {
    expect(gateFor('URGENT').allows('GENERATIVE_HEALTH')).toBe(false);
    expect(gateFor('EMERGENCY').allows('GENERATIVE_HEALTH')).toBe(false);
  });

  it('test_rf1_fail_closed_states_its_own_contract_rather_than_deriving_it', () => {
    const g = surfaceGate({
      unavailability: {
        copyVersion: 'x',
        internalReason: 'test',
        suppressed: ['GENERATIVE_HEALTH', 'PRICING', 'BOOKING', 'PROMOTIONAL', 'PROVIDER_RECOMMENDATION'],
        permitted: ['ACCOUNT', 'EXISTING_ITINERARY', 'NAVIGATION', 'HUMAN_CONTACT'],
        heading: 'x',
        body: [],
        emergencyNumber: null,
        humanContact: { label: 'Talk to a person', action: 'OPEN_HUMAN_CONTACT' },
      },
      // Severity is NORMAL and yet everything commercial is off. That is the
      // point: the gate must not be derived from a severity nobody assigned.
      severity: 'NORMAL',
      severityOrder: SEVERITY_ORDER,
    });
    expect(g.allows('PRICING')).toBe(false);
    expect(g.allows('GENERATIVE_HEALTH')).toBe(false);
    // A rule-set config gap must not become a total product outage.
    expect(g.allows('ACCOUNT')).toBe(true);
    expect(g.allows('EXISTING_ITINERARY')).toBe(true);
  });
});

describe('§6.5 display latency', () => {
  it('test_hp_esc_6_5_latency_is_measured_from_first_byte', () => {
    const firstByte = new Date('2026-09-02T10:00:00.000Z');
    const displayed = new Date('2026-09-02T10:00:00.184Z');
    expect(displayLatencyMs(firstByte, displayed)).toBe(184);
  });

  it('test_hp_esc_6_5_no_template_shown_means_no_latency', () => {
    expect(displayLatencyMs(new Date(), null)).toBeNull();
  });
});
