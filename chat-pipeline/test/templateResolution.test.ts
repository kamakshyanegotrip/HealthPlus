import { describe, it, expect } from 'vitest';
import { selectTemplate, type SafetyTemplateRow } from '@/lib/pipeline/templateResolution';
import type { RedFlagSeverity } from '@/lib/types';

/**
 * R2. §4.3.3/§4.3.4's fallback ladder, tested as a pure function against a
 * fake lookup — no database. The property that matters most is that the ladder
 * only ever climbs.
 */

const row = (
  severity: RedFlagSeverity,
  jurisdiction: string,
  language: string,
  over: Partial<SafetyTemplateRow> = {},
): SafetyTemplateRow => ({
  id: `${severity}-${jurisdiction}-${language}`,
  version: 1,
  severity, jurisdiction, language,
  body: `${severity} body`,
  slots: [],
  is_fallback: false,
  machine_translated: false,
  ...over,
});

const lookupOver = (rows: SafetyTemplateRow[]) =>
  async (a: { severity: RedFlagSeverity; jurisdiction: string; language: string }) =>
    rows.find((r) => r.severity === a.severity && r.jurisdiction === a.jurisdiction && r.language === a.language) ?? null;

describe('R2 template ladder (§4.3.3 / §4.3.4)', () => {
  it('test_hp_esc_4_3_3_exact_match_is_not_a_fallback', async () => {
    const sel = await selectTemplate('WARNING', 'IN', 'en', lookupOver([row('WARNING', 'IN', 'en')]));
    expect(sel!.resolvedSeverity).toBe('WARNING');
    expect(sel!.isFallback).toBe(false);
    expect(sel!.fallbackReason).toBeNull();
  });

  it('test_hp_esc_4_0_9_a_missing_level_escalates_upward_never_downward', async () => {
    // No URGENT row. CRITICAL and WARNING both exist. It must take CRITICAL.
    const sel = await selectTemplate('URGENT', 'IN', 'en',
      lookupOver([row('WARNING', 'IN', 'en'), row('CRITICAL', 'IN', 'en')]));
    expect(sel!.resolvedSeverity).toBe('CRITICAL');
    expect(sel!.isFallback).toBe(true);
    expect(sel!.fallbackReason).toMatch(/escalated to CRITICAL/);
  });

  it('test_hp_esc_4_3_4_untranslated_falls_back_to_approved_english', async () => {
    const sel = await selectTemplate('CRITICAL', 'IN', 'hi',
      lookupOver([row('CRITICAL', 'IN', 'en')]));
    expect(sel!.template.language).toBe('en');
    expect(sel!.fallbackReason).toMatch(/approved English/);
  });

  it('test_hp_esc_4_3_4_machine_translated_text_is_never_rendered', async () => {
    // Even as the only match at its rung. The schema says the same thing with
    // c_no_mt_safety_text; this is the runtime half.
    const sel = await selectTemplate('CRITICAL', 'IN', 'hi', lookupOver([
      row('CRITICAL', 'IN', 'hi', { machine_translated: true }),
      row('CRITICAL', 'IN', 'en'),
    ]));
    expect(sel!.template.language).toBe('en');
    expect(sel!.template.machine_translated).toBe(false);
  });

  it('test_hp_esc_4_3_3_global_jurisdiction_is_the_third_rung', async () => {
    const sel = await selectTemplate('CRITICAL', 'IN', 'en',
      lookupOver([row('CRITICAL', 'GLOBAL', 'en')]));
    expect(sel!.template.jurisdiction).toBe('GLOBAL');
    expect(sel!.fallbackReason).toMatch(/generic/);
  });

  it('test_hp_esc_4_0_9_nothing_at_or_above_returns_null_so_the_caller_fails_closed', async () => {
    // Only a LOWER level exists. The ladder must not reach down for it.
    const sel = await selectTemplate('CRITICAL', 'IN', 'en', lookupOver([row('WARNING', 'IN', 'en')]));
    expect(sel).toBeNull();
  });

  it('test_r2_emergency_never_resolves_to_a_lower_level', async () => {
    const rows = (['NORMAL', 'MONITOR', 'WARNING', 'URGENT', 'CRITICAL'] as RedFlagSeverity[])
      .map((sv) => row(sv, 'IN', 'en'));
    expect(await selectTemplate('EMERGENCY', 'IN', 'en', lookupOver(rows))).toBeNull();
  });
});
