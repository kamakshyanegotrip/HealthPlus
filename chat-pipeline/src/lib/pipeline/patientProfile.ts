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
    isMinor: row.is_minor, // §2.4.3: if true, caller must force mandatory review and keep Category C impossible regardless of §2.3.2
    statedConditions: row.stated_conditions,
  };
}
