import { describe, it, expect } from 'vitest';
import { parseAndResolveCategory, reconcileAfterRetrieval } from '../src/lib/pipeline/categoryClassifier';

describe('categoryClassifier', () => {
  it('test_hp_esc_2_0_1_clean_informational_output_is_respected', () => {
    const r = parseAndResolveCategory(JSON.stringify({ category: 'INFORMATIONAL', confidence: 0.9, ambiguousBetween: [] }));
    expect(r.category).toBe('INFORMATIONAL');
    expect(r.ambiguous).toBe(false);
  });

  it('test_hp_esc_2_0_3_ambiguity_resolves_upward_decision_support_vs_clinical', () => {
    const r = parseAndResolveCategory(
      JSON.stringify({ category: 'DECISION_SUPPORT', confidence: 0.4, ambiguousBetween: ['DECISION_SUPPORT', 'CLINICAL_DECISION'] }),
    );
    expect(r.category).toBe('CLINICAL_DECISION');
    expect(r.ambiguous).toBe(true);
  });

  it('test_hp_esc_2_0_3_ambiguity_resolves_upward_informational_vs_decision_support', () => {
    const r = parseAndResolveCategory(
      JSON.stringify({ category: 'INFORMATIONAL', confidence: 0.5, ambiguousBetween: ['INFORMATIONAL', 'DECISION_SUPPORT'] }),
    );
    expect(r.category).toBe('DECISION_SUPPORT');
  });

  it('test_hp_esc_2_0_3_unparsable_output_fails_closed_to_clinical_decision', () => {
    const r = parseAndResolveCategory('not json at all');
    expect(r.category).toBe('CLINICAL_DECISION');
  });

  it('test_hp_esc_2_0_3_unknown_category_string_fails_closed', () => {
    const r = parseAndResolveCategory(JSON.stringify({ category: 'SOMETHING_ELSE', confidence: 0.9, ambiguousBetween: [] }));
    expect(r.category).toBe('CLINICAL_DECISION');
  });

  it('test_hp_esc_2_0_2_reconcile_after_retrieval_raises_on_test_interpretation', () => {
    expect(reconcileAfterRetrieval('DECISION_SUPPORT', true)).toBe('CLINICAL_DECISION');
    expect(reconcileAfterRetrieval('INFORMATIONAL', true)).toBe('CLINICAL_DECISION');
  });

  it('test_hp_esc_2_0_2_reconcile_after_retrieval_never_lowers', () => {
    expect(reconcileAfterRetrieval('DECISION_SUPPORT', false)).toBe('DECISION_SUPPORT');
    // Already CLINICAL_DECISION with no retrieval signal -> stays put, never downgraded.
    expect(reconcileAfterRetrieval('CLINICAL_DECISION', false)).toBe('CLINICAL_DECISION');
  });
});
