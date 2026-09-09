import { describe, it, expect, beforeAll, afterAll, vi } from 'vitest';
import { randomUUID } from 'node:crypto';
import { seedRealSchema, endSeedPool, seedQuery, SEED } from '../scripts/seed-real';
import { lookupPatientProfile } from '../src/lib/pipeline/patientProfile';
import { newPendingTelemetry, type PipelineContext } from '../src/lib/types';
import { db, DATA_REGION } from '../src/lib/db';
import type { SubjectKey } from '../src/lib/subjectKey';

/**
 * R10e — does the application actually read back what the seed wrote?
 *
 * This is the narrowest DB-backed test in the suite and it exists because
 * `scripts/seed-real.ts` running without error proves almost nothing. The seed
 * encrypts with the application's own key and writes ciphertext; a seed that
 * wrote garbage, or wrote under a key the pipeline cannot unwrap, or wrote to
 * columns nothing reads, would still print "seeded" and still leave
 * lookupPatientProfile returning an empty profile. The failure mode is silent
 * in exactly the way §3.0.3 makes expensive: no decryptable attributes and no
 * risk flags means `isMinor` is null, which forces clinician review on every
 * response the system ever generates. That looks like a policy decision, not a
 * broken fixture.
 *
 * So this asserts the round trip end to end, through the real read path:
 *
 *   seed-real.ts  --encrypt-->  principal.patient_attribute
 *                                       |
 *                     principal.fetch_attribute_envelope (SECURITY DEFINER)
 *                                       |
 *                 lookupPatientProfile --decrypt--> PatientProfile
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS TEST CANNOT SEE, STATED SO NOBODY READS MORE INTO A PASS
 *
 * `principal.patient_attribute` is FORCE ROW LEVEL SECURITY, and that is what
 * scopes an attribute read to its own subject — the function above takes the
 * subject as a PARAMETER and applies no filter of its own. FORCE RLS binds the
 * table's owner, which is how the policy reaches inside a SECURITY DEFINER
 * function. But a SUPERUSER bypasses RLS entirely, FORCE or not, and in this
 * repository every migration runs as `postgres`, so locally and in CI these
 * objects are superuser-owned and the attribute scoping is INERT. A
 * cross-subject attribute read would succeed here and fail in production, which
 * is the wrong way round for a test to be wrong.
 *
 * That gap is covered, and is covered elsewhere on purpose:
 * `migrations/test/r10d_attr.sh` §4 rents the production shape by reassigning
 * the three tables and the function to a non-superuser role inside a
 * transaction it rolls back, and asserts unset=0 / self=1 / other=0. This test
 * deliberately does not duplicate that with a weaker version of it.
 *
 * What this test DOES pin, because `principal.patient_profile` and
 * `principal.patient_risk_flag` are read DIRECTLY as `reasoner_role` — a
 * non-owner, non-superuser — is that `p_pp_own` and the reader grants from
 * migration 041 evaluate for real. Case 3 below is that assertion.
 */

const RUN = process.env.RUN_PIPELINE_INTEGRATION === '1';
const d = RUN ? describe : describe.skip;

/**
 * A context sufficient for the profile read and no more. Everything
 * lookupPatientProfile touches is here; nothing else is invented, so a future
 * field it starts reading fails to compile rather than silently defaulting.
 */
function ctxFor(userId: string, key: SubjectKey, actingAs = userId): PipelineContext {
  return {
    sessionId: randomUUID(),
    userId,
    message: 'unused by the profile read',
    dataRegion: DATA_REGION,
    auditId: randomUUID(),
    receivedAt: new Date().toISOString(),
    statedCountry: null,
    authClaims: {
      // `actingAs` is separated from `userId` for case 3 only. Everywhere else
      // they are the same value, because everywhere else they must be.
      sub: actingAs,
      user_role: 'patient',
      hospital_id: null,
      admin_scopes: [],
    },
    subjectKey: key,
    pending: newPendingTelemetry(),
  };
}

d('lookupPatientProfile against the real schema (R10e seed)', () => {
  let keys: Record<'adult' | 'unknownAge' | 'other', SubjectKey>;

  beforeAll(async () => {
    ({ keys } = await seedRealSchema());
  }, 60_000);

  afterAll(async () => {
    await endSeedPool().catch(() => {});
    await db().end().catch(() => {});
    await db('reasoner').end().catch(() => {});
  });

  it('returns the seeded adult profile, with the attributes decrypted', async () => {
    // Decryption failures are logged and swallowed by design — an unreadable
    // attribute must not take down a turn whose safety decisions do not depend
    // on it. That design makes a broken key INVISIBLE to an assertion on the
    // returned object alone, so the log is watched too.
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {});
    try {
      const profile = await lookupPatientProfile(ctxFor(SEED.adultUser, keys.adult));

      expect(profile).not.toBeNull();
      expect(profile!.userId).toBe(SEED.adultUser);
      expect(profile!.dataRegion).toBe(DATA_REGION);
      expect(profile!.residencyCountry).not.toBeNull();

      // The plaintext the seed encrypted, recovered through the read path.
      expect(profile!.preferences).toEqual({ budget_band: 'mid', preferred_city: 'Chennai' });
      expect(profile!.statedConditions).toEqual([
        { label: 'age band recorded at registration', provenance: 'stated' },
      ]);

      // Not one attribute fell into the catch.
      const decryptFailures = errors.mock.calls.filter((c) =>
        String(c[0]).includes('could not be decrypted'),
      );
      expect(decryptFailures).toEqual([]);
    } finally {
      errors.mockRestore();
    }
  });

  it('derives isMinor from the risk flags, three-valued', async () => {
    const adult = await lookupPatientProfile(ctxFor(SEED.adultUser, keys.adult));
    expect(adult!.riskFlags).toContain('AGE_75_PLUS');
    expect(adult!.isMinor).toBe(false);

    // The fixture the stub schema could not express at all: `is_minor` was
    // NOT NULL DEFAULT false there, so "never established" was recorded as
    // "adult" — the one value that makes §2.4.3 skip review.
    const unknown = await lookupPatientProfile(ctxFor(SEED.unknownAgeUser, keys.unknownAge));
    expect(unknown).not.toBeNull();
    expect(unknown!.riskFlags).toEqual([]);
    expect(unknown!.isMinor).toBeNull();
  });

  it('p_pp_own actually evaluates: another subject sees no profile', async () => {
    // Same query, same role, same row — only `app.user_id` differs. If the
    // policy is missing, unreadable, or the grant was made without one, this
    // returns the adult's profile and the assertion is the only thing between
    // that and production.
    const asOther = await lookupPatientProfile(
      ctxFor(SEED.adultUser, keys.adult, SEED.otherUser),
    );
    expect(asOther).toBeNull();
  });

  it('the attributes are stored as ciphertext, not as readable JSON', async () => {
    // Guards the seed itself. A future "simplification" that writes plaintext
    // into payload_ciphertext would leave every assertion above passing.
    //
    // On the SEED's connection, not `db()`: hp_app holds no SELECT on
    // patient_attribute and must not be given one to make a test pass.
    const rows = await seedQuery<{ n: string }>(
      `SELECT count(*) AS n
         FROM principal.patient_attribute
        WHERE subject_id = $1
          AND active
          AND position('Chennai' in encode(payload_ciphertext, 'escape')) > 0`,
      [SEED.adultUser],
    );
    expect(Number(rows[0].n)).toBe(0);
  });

  it('§3.8.2: every attribute read left an access-log row', async () => {
    const rows = await seedQuery<{ n: string }>(
      `SELECT count(*) AS n
         FROM principal.attribute_access_log
        WHERE subject_id = $1 AND purpose = 'REASONING'`,
      [SEED.adultUser],
    );
    // The reads above are the only REASONING reads of this subject in this run.
    expect(Number(rows[0].n)).toBeGreaterThan(0);
  });
});
