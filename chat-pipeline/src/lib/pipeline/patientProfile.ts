import { runAsUser } from '../db';
import type { PatientProfile, PipelineContext } from '../types';

/**
 * Direct DB read, no LLM. Reads the `patient_profile` stand-in table
 * (HP-SEC-001 §2 — DDL not yet committed for the real migration;
 * reconcile column names when it lands). RLS does the real access control
 * here: this query runs inside runAsUser(ctx.authClaims, ...) (db.ts), which
 * sets `request.jwt.claims` as a per-transaction GUC on the `hp_app`
 * connection before this SELECT runs — db/020_rls.sql's
 * patient_profile_own_row policy (HP-SEC-001 §1/§4) then gates which rows
 * are actually visible, keyed off that GUC's `sub` claim.
 *
 * This function still filters `WHERE p.user_id = $1` too — that is
 * intentionally the SAME id the JWT claims carry (ctx.userId ===
 * ctx.authClaims.sub, both set from the one verified token in route.ts),
 * not a second, independent access-control decision. The point of the
 * redundancy: if a future bug ever made those two disagree (e.g. someone
 * passes a different id into ctx.userId without updating authClaims), RLS —
 * not this WHERE clause — is what actually stops the read, since RLS is
 * what's enforced at the database boundary rather than trusted from the
 * application layer up.
 *
 * §3.8.2 (via HP-SCHEMA-001 §17.1): a patient-supplied attribute is stored
 * with its provenance ('stated' | 'inferred') and an inferred one is never
 * treated as equivalent to a stated one downstream — that distinction is
 * preserved here rather than collapsed into a flat list.
 */
export async function lookupPatientProfile(ctx: PipelineContext): Promise<PatientProfile | null> {
  const { rows } = await runAsUser(ctx.authClaims, (client) =>
    client.query(
      `SELECT p.user_id, p.data_region, p.age_band, p.preferences, p.is_minor,
              COALESCE(
                jsonb_agg(jsonb_build_object('label', a.label, 'provenance', a.provenance))
                  FILTER (WHERE a.label IS NOT NULL),
                '[]'::jsonb
              ) AS stated_conditions
         FROM patient_profile p
         LEFT JOIN patient_attribute a ON a.user_id = p.user_id AND a.kind = 'condition'
        WHERE p.user_id = $1
        GROUP BY p.user_id, p.data_region, p.age_band, p.preferences, p.is_minor`,
      [ctx.userId],
    ),
  );

  const row = rows[0];
  if (!row) return null;

  return {
    userId: row.user_id,
    dataRegion: row.data_region,
    ageBand: row.age_band,
    preferences: row.preferences,
    // §2.4.3. Preserved as three-valued rather than coerced: `null` here means
    // the column holds no answer, which `minorGateRequiresReview` treats as
    // "not established", not as "adult". `?? null` is deliberate — `??` leaves
    // `false` alone, where `||` would collapse it into the unknown case and
    // force review on every confirmed adult.
    isMinor: row.is_minor ?? null,
    statedConditions: row.stated_conditions,
  };
}


/**
 * §2.4.3's gate, in one named, testable place rather than inline at the call
 * site — because the interesting cases are the ones a `?.` chain hides.
 *
 * Returns true unless minority has been POSITIVELY ESTABLISHED AS FALSE. Three
 * inputs resolve to "force review":
 *
 *   profile === null      no profile row exists, or none is visible under RLS
 *   isMinor === null      a row exists and does not answer the question
 *   isMinor === true      the subject is a minor
 *
 * This was previously `profile?.isMinor === true` at the call site, which
 * resolved the first two to "adult" — HP-SR-001 §4. The stub schema agreed with
 * the code (`is_minor boolean NOT NULL DEFAULT false`), so a patient whose age
 * nobody had ever established was recorded as not a minor, by default, in the
 * column itself.
 *
 * §3.0.3 is the governing clause: enforcement is structural, and the absence of
 * an establishing fact is a prohibition rather than a permission. An unknown age
 * is therefore handled as a minor for review purposes. That is deliberately the
 * expensive direction — it costs reviewer time (CL8's capacity model), and
 * reviewer time is the thing §2.4.3 exists to spend.
 *
 * WHAT THIS DOES NOT FIX, deliberately, and both are recorded in HP-SR-001:
 *
 *  - §2.4.3 is scoped to "the subject of a clinical question"; this still reads
 *    the AUTHENTICATED USER's own flag, so a parent asking about a child does
 *    not trigger it (SR-3). Establishing the subject from a message is a
 *    clinical-lead question, not an engineering one.
 *  - The Charter scopes this obligation to Decision Support. The caller applies
 *    it to Informational responses too. That is over-inclusive rather than
 *    unsafe, and NARROWING a safety gate should be a recorded decision, not a
 *    side effect of a fix that widens one — so it is left alone here.
 */
export function minorGateRequiresReview(profile: PatientProfile | null): boolean {
  return profile?.isMinor !== false;
}
