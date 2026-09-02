import { describe, it, expect } from 'vitest';
import { clampSeverity, resolveTemplateRequirement, deriveActionTaken, applySessionFloor, GENERIC_ESCALATION_TEMPLATE_ID } from '../src/lib/pipeline/redFlagEngine';

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

  it('test_hp_esc_4_0_2_below_warning_needs_no_template', () => {
    expect(resolveTemplateRequirement('NORMAL', null, null)).toEqual({ templateId: null, templateVersion: null });
    expect(resolveTemplateRequirement('MONITOR', 'some-id', 3)).toEqual({ templateId: null, templateVersion: null });
  });

  it('test_hp_esc_4_0_2_urgent_and_above_always_carries_a_template', () => {
    expect(resolveTemplateRequirement('WARNING', 'rule-supplied-template', 2)).toEqual({ templateId: 'rule-supplied-template', templateVersion: 2 });
    expect(resolveTemplateRequirement('EMERGENCY', null, null)).toEqual({ templateId: GENERIC_ESCALATION_TEMPLATE_ID, templateVersion: 1 });
  });

  it('test_hp_esc_4_0_2_model_raised_severity_past_warning_with_no_rule_template_still_gets_one', () => {
    // The scenario this guards: the deterministic rule that fired was only
    // WARNING-tier (so it carried no template), but the model's propose-only
    // raise pushed the applied severity to URGENT. c_urgent_template_only
    // would reject a null template_id here.
    const applied = clampSeverity('WARNING', 'URGENT');
    const { templateId } = resolveTemplateRequirement(applied, null, null);
    expect(templateId).not.toBeNull();
  });

  it('test_hp_esc_4_0_2_generic_escalation_fallback_is_a_real_uuid', () => {
    // Regression test for the bug documented on GENERIC_ESCALATION_TEMPLATE_ID:
    // this constant used to be the bare string 'GENERIC_ESCALATION_TEMPLATE',
    // which silently broke the moment anything tried to store it in a uuid
    // FK column (safety.red_flag_event.template_id). Guard the shape here so
    // that regression can't come back unnoticed.
    expect(GENERIC_ESCALATION_TEMPLATE_ID).toMatch(/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/);
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
});
