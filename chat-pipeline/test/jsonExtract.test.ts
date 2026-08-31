import { describe, expect, it } from 'vitest';
import { extractJsonObject } from '../src/lib/jsonExtract';

/**
 * extractJsonObject exists because a real live call to CATEGORY_CLASSIFIER
 * (npm run smoke:live) returned a ```json-fenced object followed by a
 * "**Reasoning:**" paragraph — see src/lib/jsonExtract.ts's header comment
 * for the exact raw text. Every case below is either that real shape, a
 * plausible variant of it, or a guard that the fast path for already-clean
 * JSON (what every other test in this repo's fixtures use) is untouched.
 */
describe('jsonExtract.extractJsonObject', () => {
  it('test_json_extract_clean_json_passes_through_unchanged', () => {
    const input = '{"category":"INFORMATIONAL","confidence":0.95,"ambiguousBetween":[]}';
    expect(extractJsonObject(input)).toBe(input);
  });

  it('test_json_extract_clean_json_with_surrounding_whitespace_is_trimmed', () => {
    const input = '\n  {"a": 1}  \n';
    expect(JSON.parse(extractJsonObject(input))).toEqual({ a: 1 });
  });

  it('test_json_extract_strips_json_tagged_fence_and_trailing_prose', () => {
    // The exact real shape returned by a live Haiku call to CATEGORY_CLASSIFIER.
    const input = [
      '```json',
      '{',
      '  "category": "INFORMATIONAL",',
      '  "confidence": 0.95,',
      '  "ambiguousBetween": []',
      '}',
      '```',
      '',
      '**Reasoning:**  ',
      'This is a straightforward request for general, population-level education.',
    ].join('\n');
    const extracted = extractJsonObject(input);
    expect(JSON.parse(extracted)).toEqual({ category: 'INFORMATIONAL', confidence: 0.95, ambiguousBetween: [] });
  });

  it('test_json_extract_strips_untagged_fence', () => {
    const input = '```\n{"proposedSeverity":"NORMAL"}\n```';
    expect(JSON.parse(extractJsonObject(input))).toEqual({ proposedSeverity: 'NORMAL' });
  });

  it('test_json_extract_strips_leading_prose_with_no_fence_at_all', () => {
    const input = 'Sure, here is the classification:\n{"category":"DECISION_SUPPORT","confidence":0.7,"ambiguousBetween":[]}';
    expect(JSON.parse(extractJsonObject(input))).toEqual({ category: 'DECISION_SUPPORT', confidence: 0.7, ambiguousBetween: [] });
  });

  it('test_json_extract_handles_fenced_object_with_leading_prose_before_the_fence', () => {
    const input = 'Here you go:\n```json\n{"complexity":"HIGH"}\n```';
    expect(JSON.parse(extractJsonObject(input))).toEqual({ complexity: 'HIGH' });
  });

  it('test_json_extract_completely_unparsable_input_returns_original_text_unchanged', () => {
    // Callers rely on JSON.parse still throwing on this, so their existing
    // fail-closed/fail-safe catch block still fires exactly as before.
    const input = 'I cannot classify this — the message is empty.';
    expect(extractJsonObject(input)).toBe(input);
    expect(() => JSON.parse(extractJsonObject(input))).toThrow();
  });

  it('test_json_extract_empty_string_returns_original_and_still_throws', () => {
    expect(extractJsonObject('')).toBe('');
    expect(() => JSON.parse(extractJsonObject(''))).toThrow();
  });

  it('test_json_extract_nested_braces_inside_the_json_object_are_preserved', () => {
    const input = '```json\n{"outcome": {"nested": true, "count": 2}}\n```\nDone.';
    expect(JSON.parse(extractJsonObject(input))).toEqual({ outcome: { nested: true, count: 2 } });
  });
});
