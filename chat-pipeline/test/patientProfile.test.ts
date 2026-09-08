import { describe, it, expect } from 'vitest';
import { minorGateRequiresReview } from '../src/lib/pipeline/patientProfile';
import type { PatientProfile } from '../src/lib/types';

/**
 * HP-SR-001 §4 — §2.4.3's minor gate, and the two cases it used to get wrong.
 *
 * The clause under test: Decision Support for a minor requires pre-publication
 * clinician review. The gate therefore has to answer "may this be published
 * without review?", NOT "is this definitely a minor?" — the two differ on
 * exactly the inputs where nothing has been established, and §3.0.3 resolves an
 * unestablished fact closed.
 *
 * The superseded expression was `profile?.isMinor === true`.
 */

const adult: PatientProfile = {
  userId: '11111111-1111-1111-1111-111111111111',
  dataRegion: 'IN',
  ageBand: '30-39',
  statedConditions: [],
  preferences: null,
  isMinor: false,
};

/** What the old expression computed, kept verbatim so the tests can show the
 *  divergence rather than assert it in prose. */
const supersededGate = (p: PatientProfile | null) => p?.isMinor === true;

describe('minorGateRequiresReview — §2.4.3 / §3.0.3', () => {
  it('does not require review for a subject positively established as an adult', () => {
    expect(minorGateRequiresReview(adult)).toBe(false);
  });

  it('requires review for a subject established as a minor', () => {
    expect(minorGateRequiresReview({ ...adult, isMinor: true })).toBe(true);
  });

  // The two regressions. Both passed the old gate.
  it('requires review when a profile row exists but does not establish age', () => {
    expect(minorGateRequiresReview({ ...adult, isMinor: null })).toBe(true);
  });

  it('requires review when no profile row is visible at all', () => {
    // null is what lookupPatientProfile returns both when no row exists AND
    // when RLS hides one — indistinguishable to this function, and both are
    // "not established".
    expect(minorGateRequiresReview(null)).toBe(true);
  });

  it('differs from the superseded gate on precisely the two unknown cases', () => {
    const inputs: Array<PatientProfile | null> = [
      adult,
      { ...adult, isMinor: true },
      { ...adult, isMinor: null },
      null,
    ];
    const now = inputs.map(minorGateRequiresReview);
    const before = inputs.map(supersededGate);

    expect(before).toEqual([false, true, false, false]);
    expect(now).toEqual([false, true, true, true]);

    // Agreement on the established cases, divergence only on the unknown ones —
    // i.e. this widened the gate and did not redefine it.
    expect(now.slice(0, 2)).toEqual(before.slice(0, 2));
  });

  it('never narrows the gate: nothing the old expression caught is now missed', () => {
    const cases: Array<PatientProfile | null> = [
      null,
      adult,
      { ...adult, isMinor: true },
      { ...adult, isMinor: null },
    ];
    for (const c of cases) {
      if (supersededGate(c)) expect(minorGateRequiresReview(c)).toBe(true);
    }
  });
});
