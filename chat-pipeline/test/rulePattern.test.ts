import { describe, it, expect } from 'vitest';
import {
  parseRulePattern,
  matchPattern,
  containsTerm,
  MalformedRulePatternError,
  type RulePattern,
} from '@/lib/pipeline/rulePattern';

/**
 * R3. The committed schema stores red_flag_rule.pattern as jsonb; this pipeline
 * used to store a regex string and evaluate it with `new RegExp`. These tests
 * pin the behaviours a regex could not express, which is the whole reason for
 * the change.
 */

describe('R3 pattern parsing (§4.0.3)', () => {
  it('test_hp_esc_4_0_3_a_malformed_pattern_is_rejected_not_ignored', () => {
    // Silently not-matching is failing open with extra steps: the rule was
    // never evaluated, and §4.0.9 forbids treating that as a clean scan.
    expect(() => parseRulePattern({ kind: 'NOPE' }, 'r1')).toThrow(MalformedRulePatternError);
    expect(() => parseRulePattern('a regex string', 'r1')).toThrow(MalformedRulePatternError);
    expect(() => parseRulePattern(null, 'r1')).toThrow(MalformedRulePatternError);
    expect(() => parseRulePattern({ kind: 'KEYWORD_ANY', terms: [] }, 'r1')).toThrow(MalformedRulePatternError);
  });

  it('test_hp_esc_3_5_3_a_threshold_without_a_unit_is_rejected', () => {
    // 38 means one thing in Celsius and another in Fahrenheit. §3.5.3 forbids
    // converting without a sourced factor, so a unitless threshold is not
    // under-specified — it is unsafe.
    expect(() =>
      parseRulePattern({ kind: 'THRESHOLD', source: 'VITAL', code: 'TEMP_C', op: 'GTE', value: 38 }, 'r1'),
    ).toThrow(/unit is required/);
  });

  it('test_r3_nested_all_of_parses', () => {
    const p = parseRulePattern({
      kind: 'ALL_OF',
      children: [
        { kind: 'SYMPTOM_ANY', codes: ['CALF_PAIN'] },
        { kind: 'TRAVEL_CONTEXT', predicate: 'RECENT_FLIGHT' },
      ],
    }, 'r1');
    expect(p.kind).toBe('ALL_OF');
  });
});

describe('R3 pattern evaluation', () => {
  const kw = (terms: string[]): RulePattern => ({ kind: 'KEYWORD_ANY', terms });

  it('test_hp_esc_4_0_4_keyword_matching_is_whole_word', () => {
    expect(containsTerm('I have chest pain today', 'chest pain')).toBe(true);
    // The false positive a naive substring match produces — and a false
    // positive at EMERGENCY takes over the user's screen.
    expect(containsTerm('chest painting class', 'chest pain')).toBe(false);
    expect(containsTerm('CHEST PAIN', 'chest pain')).toBe(true);
  });

  it('test_hp_esc_4_0_4_negation_does_not_suppress_a_match', () => {
    // §4.0.4 resolves ambiguity upward, and a scanner that reasons about
    // negation is one that can talk itself out of a red flag.
    expect(matchPattern(kw(['chest pain']), { message: 'no chest pain at all' })).not.toBeNull();
  });

  it('test_hp_esc_3_5_3_threshold_does_not_fire_across_a_unit_mismatch', () => {
    const p = parseRulePattern(
      { kind: 'THRESHOLD', source: 'VITAL', code: 'TEMP_C', op: 'GTE', value: 38, unit: 'C' }, 'r1');
    // 100 degF is not >= 38 degC by coincidence of the number.
    expect(matchPattern(p, { message: '', vitals: [{ code: 'TEMP_C', value: 100, unit: 'F' }] })).toBeNull();
    expect(matchPattern(p, { message: '', vitals: [{ code: 'TEMP_C', value: 38.4, unit: 'C' }] })).not.toBeNull();
  });

  it('test_r3_structured_rules_abstain_when_the_data_is_absent', () => {
    // The pipeline does not yet carry symptoms or vitals. A rule that cannot
    // be evaluated must not fire — and must not be recorded as evaluated.
    const p = parseRulePattern({ kind: 'SYMPTOM_ALL', codes: ['FACE_DROOP'] }, 'r1');
    expect(matchPattern(p, { message: 'my face feels odd' })).toBeNull();
  });

  it('test_hp_esc_4_5_travel_context_is_expressible_at_all', () => {
    // A regex over the message could not see this, so §4.5's medical-tourism
    // triggers had no way to fire before R3.
    const p = parseRulePattern({
      kind: 'ALL_OF',
      children: [
        { kind: 'SYMPTOM_ANY', codes: ['CALF_PAIN'] },
        { kind: 'TRAVEL_CONTEXT', predicate: 'RECENT_FLIGHT' },
      ],
    }, 'r1');
    expect(matchPattern(p, {
      message: 'my calf hurts',
      symptoms: [{ code: 'CALF_PAIN', present: true }],
      travel: { recentFlightHours: 9 },
    })).not.toBeNull();
    expect(matchPattern(p, {
      message: 'my calf hurts',
      symptoms: [{ code: 'CALF_PAIN', present: true }],
    })).toBeNull();
  });

  it('test_hp_esc_4_0_7_trigger_detail_records_the_pattern_not_the_message', () => {
    const detail = matchPattern(kw(['chest pain']), { message: 'I have chest pain and I am scared about my HbA1c' });
    expect(JSON.stringify(detail)).not.toContain('HbA1c');
    expect(JSON.stringify(detail)).not.toContain('scared');
    expect(detail).toEqual({ kind: 'KEYWORD_ANY', matched: 'chest pain' });
  });
});
