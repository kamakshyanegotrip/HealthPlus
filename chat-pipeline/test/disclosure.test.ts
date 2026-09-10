import { createHash } from 'node:crypto';
import { describe, it, expect } from 'vitest';
import {
  DISCLAIMER_INFORMATIONAL,
  DISCLAIMER_DECISION_SUPPORT,
  COST_STRING_TEMPLATE,
  costString,
  disclosureFor,
} from '../src/lib/pipeline/disclosure';

/**
 * The disclaimers are Charter text, quoted. A test that only checked they were
 * "non-empty strings" would pass a paraphrase, and a paraphrase is what §4.3.2
 * calls softening when it happens to a safety template — the same failure one
 * clause earlier.
 *
 * So each is pinned by SHA-256. If you are here because CI went red on one of
 * these: the fix is not to update the hash. The fix is to check whether the
 * string still matches Charter v1.0 §2.1.5 / §2.2.4 / §3.3.9 verbatim. If the
 * CHARTER changed, that is a §6.3 amendment with a version increment and a
 * migration note, and the hash moves with it deliberately.
 */
function sha(s: string): string {
  return createHash('sha256').update(s).digest('hex');
}

/** Charter v1.0, 29 August 2026. Move one of these only with a §6.3 amendment. */
const PINNED = {
  '2.1.5': '5dda331f272618e7fc1b6e57a1d6bec96911aef22550fe7774732b411463bdef',
  '2.2.4': 'b073d81c3f6cee396ded9ca64c68075386536a37173b85be0523f0ff8ada0326',
  '3.3.9': '193eeefbe244d468932b2b46690ae4b250a5c0de6dbd4507ba43f7db94e0f7c0',
} as const;

describe('Charter-mandated disclosure strings', () => {
  it('test_hp_esc_2_1_5_short_form_disclaimer_is_verbatim', () => {
    expect(DISCLAIMER_INFORMATIONAL).toBe(
      'General information only. This is not medical advice and is not specific to your ' +
        'situation. Talk to a qualified healthcare professional about your own care.',
    );
    expect(sha(DISCLAIMER_INFORMATIONAL)).toBe(PINNED['2.1.5']);
  });

  it('test_hp_esc_2_2_4_and_3_3_9_are_pinned_by_hash', () => {
    expect(sha(DISCLAIMER_DECISION_SUPPORT)).toBe(PINNED['2.2.4']);
    expect(sha(COST_STRING_TEMPLATE)).toBe(PINNED['3.3.9']);
  });

  it('test_hp_esc_2_2_4_long_form_disclaimer_is_verbatim', () => {
    // The four sentences §2.2.4 actually requires, checked individually so a
    // dropped clause fails with a message naming which one.
    expect(DISCLAIMER_DECISION_SUPPORT).toContain('This comparison is decision support, not medical advice.');
    expect(DISCLAIMER_DECISION_SUPPORT).toContain('Costs shown are indicative estimates, not quotations.');
    expect(DISCLAIMER_DECISION_SUPPORT).toContain(
      'can only be determined by a qualified clinician who has assessed you',
    );
    expect(DISCLAIMER_DECISION_SUPPORT).toContain(
      'Confirm all clinical, cost, legal and visa details directly with the provider and the relevant authorities before making arrangements.',
    );
  });

  it('test_hp_esc_3_3_9_cost_string_fills_only_the_declared_slots', () => {
    const filled = costString('Hospital A package sheet', '2026-08-01');
    expect(filled).toBe(
      'Indicative estimate only, based on Hospital A package sheet as of 2026-08-01. Not a quotation. ' +
        'Final cost is set by the provider after assessment and may differ.',
    );
    // The surrounding sentence is untouched: only [source] and [date] move.
    expect(COST_STRING_TEMPLATE.replace('[source]', 'X').replace('[date]', 'Y')).toBe(costString('X', 'Y'));
    expect(filled).toContain('Not a quotation.');
  });

  it('test_hp_esc_2_2_4_decision_support_gets_the_long_form_and_names_its_clause', () => {
    const d = disclosureFor('DECISION_SUPPORT', { firstContact: false });
    expect(d.clause).toBe('2.2.4');
    expect(d.disclaimer).toBe(DISCLAIMER_DECISION_SUPPORT);
  });

  it('test_hp_esc_2_1_5_informational_gets_the_short_form_and_names_its_clause', () => {
    const d = disclosureFor('INFORMATIONAL', { firstContact: false });
    expect(d.clause).toBe('2.1.5');
    expect(d.disclaimer).toBe(DISCLAIMER_INFORMATIONAL);
  });

  it('test_hp_esc_2_0_5_human_contact_offer_rides_with_every_disclosure', () => {
    // "presented at first contact AND REMAINS AVAILABLE IN EVERY SESSION" —
    // so it is not gated on firstContact, unlike the §3.11.4 notice below.
    for (const first of [true, false]) {
      for (const cat of ['INFORMATIONAL', 'DECISION_SUPPORT'] as const) {
        expect(disclosureFor(cat, { firstContact: first }).humanContactOffer).toMatch(/put in touch with a person/i);
      }
    }
  });

  it('test_hp_esc_3_11_4_automated_system_notice_is_gated_on_first_contact', () => {
    expect(disclosureFor('INFORMATIONAL', { firstContact: true }).automatedSystemNotice).toMatch(/automated system/i);
    expect(disclosureFor('INFORMATIONAL', { firstContact: false }).automatedSystemNotice).toBeNull();
  });
});
