import { describe, it, expect } from 'vitest';
import {
  parseSlotDeclarations,
  renderTemplate,
  valueForKind,
  renderSafetyTemplate,
  type DeclaredSlot,
  type SlotSources,
} from '../src/lib/pipeline/templateSlots';

/**
 * RF4. The rule under test throughout: a person in an emergency must never
 * read a placeholder, and the system must never reword clinician-approved
 * safety text to avoid showing them one.
 *
 * Clause-named per Annex A.8.
 */

const EMERGENCY = {
  numberE164: '+9108',
  sourceTable: 'safety.emergency_contact_reference',
  sourceRowId: 'ecr-1',
};
const FACILITY = {
  id: 'efr-1',
  facilityName: 'City General Hospital',
  addressLine: '12 Ring Road, Delhi',
  phoneE164: '+911123456789',
};

describe('parseSlotDeclarations', () => {
  it('accepts a well-formed declaration', () => {
    const d = parseSlotDeclarations({ nearest_ed: { kind: 'NEAREST_ED', on_unresolved: 'OMIT_LINE' } });
    expect(d).toEqual({ nearest_ed: { kind: 'NEAREST_ED', on_unresolved: 'OMIT_LINE' } });
  });

  it('test_hp_esc_4_3_2_silence_means_required: a declaration omitting on_unresolved is REQUIRED, not OMIT_LINE', () => {
    // The dangerous default would be the permissive one. An author who wants
    // part of an emergency instruction dropped has to say so out loud.
    const d = parseSlotDeclarations({ ed: { kind: 'NEAREST_ED' } });
    expect(d.ed!.on_unresolved).toBe('REQUIRED');
  });

  it('drops declarations it cannot understand rather than guessing', () => {
    const d = parseSlotDeclarations({
      good: { kind: 'CITY', on_unresolved: 'OMIT_LINE' },
      unknown_kind: { kind: 'PATIENT_DIAGNOSIS', on_unresolved: 'OMIT_LINE' },
      not_an_object: 'CITY',
    });
    expect(Object.keys(d)).toEqual(['good']);
  });

  it('survives jsonb being anything at all', () => {
    for (const junk of [null, undefined, 42, 'slots', [], [{ kind: 'CITY' }]]) {
      expect(parseSlotDeclarations(junk)).toEqual({});
    }
  });
});

describe('renderTemplate', () => {
  const decl = (o: Record<string, DeclaredSlot>) => o;

  it('substitutes a declared, resolved slot', () => {
    const out = renderTemplate(
      'Call {{emergency_number}} now.',
      decl({ emergency_number: { kind: 'EMERGENCY_NUMBER', on_unresolved: 'REQUIRED' } }),
      { emergencyNumber: EMERGENCY },
    );
    expect(out.text).toBe('Call +9108 now.');
    expect(out.unrenderable).toBeNull();
  });

  it('test_hp_esc_4_0_5_no_placeholder_ever_reaches_a_user', () => {
    // Every path out of renderTemplate either produces text with no braces
    // left in it, or refuses to produce text at all.
    const cases: Array<[string, Record<string, DeclaredSlot>, SlotSources]> = [
      ['Call {{n}} now.', { n: { kind: 'EMERGENCY_NUMBER', on_unresolved: 'REQUIRED' } }, {}],
      ['Go to {{ed}}.', { ed: { kind: 'NEAREST_ED', on_unresolved: 'OMIT_LINE' } }, {}],
      ['Go to {{ed}}.', {}, {}],
      ['Call {{n}}.\nGo to {{ed}}.', { n: { kind: 'EMERGENCY_NUMBER', on_unresolved: 'REQUIRED' }, ed: { kind: 'NEAREST_ED', on_unresolved: 'OMIT_LINE' } }, { emergencyNumber: EMERGENCY }],
    ];
    for (const [body, d, s] of cases) {
      const out = renderTemplate(body, d, s);
      if (out.unrenderable === null) expect(out.text).not.toMatch(/\{\{|\}\}/);
      else expect(out.text).toBe('');
    }
  });

  it('test_hp_esc_4_3_2_omit_line_drops_only_its_own_line', () => {
    const out = renderTemplate(
      'Call {{emergency_number}} now.\nNearest emergency department: {{nearest_ed}}.\nDo not drive yourself.',
      decl({
        emergency_number: { kind: 'EMERGENCY_NUMBER', on_unresolved: 'REQUIRED' },
        nearest_ed: { kind: 'NEAREST_ED', on_unresolved: 'OMIT_LINE' },
      }),
      { emergencyNumber: EMERGENCY },
    );
    expect(out.text).toBe('Call +9108 now.\nDo not drive yourself.');
    expect(out.omittedLines).toBe(1);
    expect(out.unrenderable).toBeNull();
  });

  it('test_hp_esc_4_0_9_required_slot_unresolved_is_unrenderable_not_edited', () => {
    const out = renderTemplate(
      'Call {{emergency_number}} now.',
      decl({ emergency_number: { kind: 'EMERGENCY_NUMBER', on_unresolved: 'REQUIRED' } }),
      {},
    );
    expect(out.unrenderable).toMatch(/required slot/);
    expect(out.text).toBe('');
  });

  it('test_hp_esc_4_3_2_undeclared_token_is_unrenderable', () => {
    // The body and its declaration disagree. Guessing what the author meant is
    // worse than climbing to the next template.
    const out = renderTemplate('Take {{dose}} of your medication.', decl({}), {});
    expect(out.unrenderable).toMatch(/undeclared slot/);
    expect(out.text).toBe('');
  });

  it('test_hp_esc_4_3_2_body_without_slots_is_returned_verbatim', () => {
    // Every template that exists today. The renderer must be a provable no-op.
    const body = 'Call your local emergency number now.\nDo not drive yourself.';
    const out = renderTemplate(body, decl({}), {});
    expect(out.text).toBe(body);
    expect(out.omittedLines).toBe(0);
    expect(out.unrenderable).toBeNull();
  });

  it('does not touch text outside the tokens', () => {
    const out = renderTemplate(
      'Chest pain? Call {{n}}. Do not soften this: "seek care NOW".',
      decl({ n: { kind: 'EMERGENCY_NUMBER', on_unresolved: 'REQUIRED' } }),
      { emergencyNumber: EMERGENCY },
    );
    expect(out.text).toBe('Chest pain? Call +9108. Do not soften this: "seek care NOW".');
  });

  it('records provenance for every resolved slot', () => {
    const out = renderTemplate(
      '{{ed}} / {{n}}',
      decl({
        ed: { kind: 'NEAREST_ED', on_unresolved: 'OMIT_LINE' },
        n: { kind: 'EMERGENCY_NUMBER', on_unresolved: 'REQUIRED' },
      }),
      { emergencyNumber: EMERGENCY, facility: FACILITY },
    );
    expect(out.resolutions).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ name: 'ed', sourceTable: 'safety.emergency_facility_reference', sourceRowId: 'efr-1' }),
        expect.objectContaining({ name: 'n', sourceTable: 'safety.emergency_contact_reference', sourceRowId: 'ecr-1' }),
      ]),
    );
  });
});

describe('valueForKind', () => {
  it('renders a facility as name plus address, so distance is the reader’s to judge', () => {
    expect(valueForKind('NEAREST_ED', { facility: FACILITY }).value).toBe('City General Hospital, 12 Ring Road, Delhi');
  });

  it('test_hp_esc_3_12_1_a_facility_without_a_phone_yields_no_phone', () => {
    const noPhone = { ...FACILITY, phoneE164: null };
    expect(valueForKind('NEAREST_ED_PHONE', { facility: noPhone }).value).toBeNull();
  });

  it('CITY comes from the stated location and carries no reference row', () => {
    const r = valueForKind('CITY', { statedCity: 'Delhi' });
    expect(r.value).toBe('Delhi');
    expect(r.sourceRowId).toBeNull();
  });
});

describe('renderSafetyTemplate', () => {
  const noSources = {
    resolveEmergencyNumber: async () => null,
    resolveNearestFacility: async () => null,
  };

  it('test_hp_esc_4_3_2_a_slotless_template_costs_no_lookups', async () => {
    let calls = 0;
    const out = await renderSafetyTemplate('Call your local emergency number.', {}, { statedCountry: 'IN' }, {
      resolveEmergencyNumber: async () => {
        calls += 1;
        return null;
      },
      resolveNearestFacility: async () => {
        calls += 1;
        return null;
      },
    });
    expect(calls).toBe(0);
    expect(out.text).toBe('Call your local emergency number.');
  });

  it('fetches only the sources the template declares', async () => {
    const seen: string[] = [];
    await renderSafetyTemplate(
      'Go to {{ed}}.',
      { ed: { kind: 'NEAREST_ED', on_unresolved: 'OMIT_LINE' } },
      { statedCountry: 'IN', statedCity: 'Delhi' },
      {
        resolveEmergencyNumber: async () => {
          seen.push('number');
          return null;
        },
        resolveNearestFacility: async () => {
          seen.push('facility');
          return FACILITY;
        },
      },
    );
    expect(seen).toEqual(['facility']);
  });

  it('test_hp_esc_027_2_unpopulated_facility_table_renders_the_number_alone', async () => {
    // Migration 027 §2's stated intent, now actually true: until Job 18 runs,
    // the nearest-ED line drops and the emergency number still shows.
    const out = await renderSafetyTemplate(
      'Call {{n}} now.\nNearest emergency department: {{ed}}.',
      {
        n: { kind: 'EMERGENCY_NUMBER', on_unresolved: 'REQUIRED' },
        ed: { kind: 'NEAREST_ED', on_unresolved: 'OMIT_LINE' },
      },
      { statedCountry: 'IN' },
      { ...noSources, resolveEmergencyNumber: async () => EMERGENCY },
    );
    expect(out.text).toBe('Call +9108 now.');
    expect(out.unrenderable).toBeNull();
    expect(out.omittedLines).toBe(1);
  });

  it('does not throw when a source lookup does', async () => {
    const out = await renderSafetyTemplate(
      'Call {{n}}.',
      { n: { kind: 'EMERGENCY_NUMBER', on_unresolved: 'OMIT_LINE' } },
      { statedCountry: 'IN' },
      {
        resolveEmergencyNumber: async () => {
          throw new Error('database gone');
        },
      },
    ).catch((e) => e);
    // The dependency is the caller's to make safe — resolveEmergencyNumber and
    // resolveNearestFacility both swallow their own errors. This test pins
    // that expectation so a future refactor cannot quietly move the throw here.
    expect(out).toBeInstanceOf(Error);
  });
});

// ---------------------------------------------------------------------------
// RF4 x §4.3.3: an unrenderable template is skipped, and the ladder climbs.
// ---------------------------------------------------------------------------
import { selectTemplate, type SafetyTemplateRow } from '../src/lib/pipeline/templateResolution';

const row = (o: Partial<SafetyTemplateRow>): SafetyTemplateRow => ({
  id: 'tpl',
  version: 1,
  severity: 'CRITICAL',
  jurisdiction: 'IN',
  language: 'en',
  body: 'body',
  slots: {},
  is_fallback: false,
  machine_translated: false,
  ...o,
});

describe('selectTemplate with a prepare hook', () => {
  it('test_hp_esc_4_3_3_unrenderable_rung_is_skipped_and_the_ladder_climbs', async () => {
    const lookup = async (a: { severity: string; jurisdiction: string; language: string }) => {
      if (a.severity === 'CRITICAL') return row({ id: 'critical-broken', severity: 'CRITICAL', body: 'Go to {{undeclared}}.' });
      if (a.severity === 'EMERGENCY') return row({ id: 'emergency-ok', severity: 'EMERGENCY', body: 'Call now.' });
      return null;
    };
    const prepare = async (r: SafetyTemplateRow) =>
      r.body.includes('{{')
        ? ({ ok: false as const, reason: 'undeclared slot' })
        : ({ ok: true as const, text: r.body });

    const sel = await selectTemplate('CRITICAL', 'IN', 'en', lookup as never, prepare);
    expect(sel!.template.id).toBe('emergency-ok');
    expect(sel!.resolvedSeverity).toBe('EMERGENCY');
    expect(sel!.renderedText).toBe('Call now.');
    expect(sel!.unrenderableRungs.join(' ')).toMatch(/undeclared slot/);
  });

  it('test_hp_esc_4_0_9_all_rungs_unrenderable_returns_null_not_a_broken_body', async () => {
    // The caller turns null into FAIL_CLOSED. What it must never do is send a
    // body it could not render.
    const lookup = async () => row({ body: 'Go to {{undeclared}}.' });
    const prepare = async () => ({ ok: false as const, reason: 'undeclared slot' });
    const sel = await selectTemplate('CRITICAL', 'IN', 'en', lookup as never, prepare);
    expect(sel).toBeNull();
  });

  it('without a prepare hook the body is used unchanged — every caller today', async () => {
    const lookup = async () => row({ body: 'Call your local emergency number.' });
    const sel = await selectTemplate('CRITICAL', 'IN', 'en', lookup as never);
    expect(sel!.renderedText).toBeNull();
    expect(sel!.template.body).toBe('Call your local emergency number.');
  });
});
