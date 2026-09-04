import { describe, it, expect } from 'vitest';
import { clampSeverity, deriveActionTaken, applySessionFloor, resolveAdoptionGate } from '../src/lib/pipeline/redFlagEngine';

describe('redFlagEngine', () => {
  it('test_hp_esc_4_0_3_model_may_raise_never_lower_raises', () => {
    expect(clampSeverity('WARNING', 'URGENT')).toBe('URGENT');
    expect(clampSeverity('NORMAL', 'EMERGENCY')).toBe('EMERGENCY');
  });

  it('test_hp_esc_4_0_3_model_may_raise_never_lower_ignores_a_lower_proposal', () => {
    expect(clampSeverity('URGENT', 'WARNING')).toBe('URGENT');
    expect(clampSeverity('EMERGENCY', 'NORMAL')).toBe('EMERGENCY');
  });

  it('test_hp_esc_4_0_3_model_may_raise_never_lower_equal_is_a_no_op', () => {
    expect(clampSeverity('URGENT', 'URGENT')).toBe('URGENT');
  });

  it('test_hp_esc_4_0_7_derive_action_taken_emergency_template_wins_regardless_of_severity_argument', () => {
    expect(deriveActionTaken('MONITOR', true)).toBe('TEMPLATE_SHOWN');
    expect(deriveActionTaken('EMERGENCY', true)).toBe('TEMPLATE_SHOWN');
  });

  it('test_hp_esc_4_0_7_derive_action_taken_warning_and_above_escalates_when_no_template_shown', () => {
    expect(deriveActionTaken('WARNING', false)).toBe('ESCALATED');
    expect(deriveActionTaken('URGENT', false)).toBe('ESCALATED');
    expect(deriveActionTaken('CRITICAL', false)).toBe('ESCALATED');
  });

  it('test_hp_esc_4_0_7_derive_action_taken_monitor_alone_is_logged_but_takes_no_action', () => {
    expect(deriveActionTaken('MONITOR', false)).toBe('NONE');
  });

  it('test_hp_esc_4_0_8_apply_session_floor_raises_a_lower_message_severity', () => {
    expect(applySessionFloor('NORMAL', { floorSeverity: 'WARNING', active: true })).toBe('WARNING');
    expect(applySessionFloor('MONITOR', { floorSeverity: 'URGENT', active: true })).toBe('URGENT');
  });

  it('test_hp_esc_4_0_8_apply_session_floor_never_lowers_a_higher_message_severity', () => {
    expect(applySessionFloor('CRITICAL', { floorSeverity: 'WARNING', active: true })).toBe('CRITICAL');
  });

  it('test_hp_esc_4_0_8_apply_session_floor_ignores_a_cleared_floor', () => {
    expect(applySessionFloor('NORMAL', { floorSeverity: 'URGENT', active: false })).toBe('NORMAL');
  });

  it('test_hp_esc_4_0_8_apply_session_floor_no_floor_is_a_no_op', () => {
    expect(applySessionFloor('MONITOR', null)).toBe('MONITOR');
  });

  // ---- §0.6 / AMB-17 adoption gate (HP-JOB-004) ----------------------------

  it('test_hp_esc_0_6_no_adopted_rule_fails_closed_rather_than_returning_normal', () => {
    // The failure this gate exists to prevent: with CL2 unsigned, every rule
    // has clinically_adopted = false, the WHERE clause matches nothing, and a
    // scanner without this gate reports NORMAL for every message ever sent —
    // an unsigned deployment looking perfectly healthy while detecting zero.
    expect(resolveAdoptionGate({ adoptedRuleCount: 0, lookupFailed: false })).toBe('FAIL_CLOSED');
  });

  it('test_hp_esc_0_6_at_least_one_adopted_rule_opens_the_gate', () => {
    expect(resolveAdoptionGate({ adoptedRuleCount: 1, lookupFailed: false })).toBe('OPEN');
    expect(resolveAdoptionGate({ adoptedRuleCount: 42, lookupFailed: false })).toBe('OPEN');
  });

  it('test_hp_esc_4_0_9_a_failed_rule_lookup_fails_closed_not_open', () => {
    // Even with rules on file: if we could not read them, we did not scan.
    expect(resolveAdoptionGate({ adoptedRuleCount: 7, lookupFailed: true })).toBe('FAIL_CLOSED');
  });
});
