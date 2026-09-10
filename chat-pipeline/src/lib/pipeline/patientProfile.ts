import { runAsUser } from '../db';
import { decryptAttribute } from '../subjectKey';
import type { PatientProfile, PipelineContext, RiskFlagKey } from '../types';

/**
 * The profile read, rebuilt around the real schema (register item R10d-attr).
 *
 * ---------------------------------------------------------------------------
 * WHAT THE PREVIOUS VERSION READ, AND WHY NONE OF IT EXISTED
 *
 * It selected `age_band`, `preferences` and `is_minor` from `patient_profile`,
 * and joined `patient_attribute` on a `label` column with `kind = 'condition'`.
 * The real `principal.patient_profile` has five columns — user_id, data_region,
 * created_at, key_id, residency_country — and not one of those four. Every name
 * in that query came from the stub (db/000), which is what R10g deletes.
 *
 * The real shape splits the same information three ways, and the split is the
 * design rather than an inconvenience:
 *
 *   patient_profile     the non-sensitive frame: which region, which residency.
 *   patient_attribute   the health data, ENCRYPTED per subject, reachable only
 *                       through principal.fetch_attribute_envelope so that every
 *                       read writes principal.attribute_access_log (§3.8.2).
 *   patient_risk_flag   ten clinician-meaningful flags derived from *stated*
 *                       attributes, enforced by trg_risk_flag_stated_only
 *                       (§4.6.2). This is where §2.4.3's minor gate actually
 *                       lives, and HP-SR-001 recorded that nothing read it.
 *
 * ---------------------------------------------------------------------------
 * THE PROPERTY WORTH KEEPING: THE SAFETY GATE DOES NOT DEPEND ON DECRYPTION
 *
 * `isMinor` comes from patient_risk_flag, which is plaintext flag keys. The
 * encrypted attributes feed only the composer's preferences block and the
 * stated-condition list. So a subject whose attributes cannot be decrypted —
 * wrong key, corrupt row, an algorithm this build does not know — still gets a
 * correct §2.4.3 decision, and still gets one in the fail-closed direction if
 * even the flags cannot be read. The expensive failure mode is bounded.
 *
 * ---------------------------------------------------------------------------
 * ⚠ WHY THIS RUNS INSIDE runAsUser, AND WHY THAT IS NOT OPTIONAL
 *
 * Every read below is gated on `app.current_user_id()`:
 *   patient_profile    p_pp_own      (migration 041)
 *   patient_risk_flag  p_prf_own     (migration 018, granted a reader by 041)
 *   patient_attribute  p_pa_own, and the table is FORCE ROW LEVEL SECURITY, so
 *                      the policy applies to the owner too — which means it
 *                      applies INSIDE fetch_attribute_envelope, a SECURITY
 *                      DEFINER function running as that owner.
 *
 * A superuser bypasses RLS entirely, and in this repository every migration and
 * gate runs as `postgres`, which is one. So none of those boundaries apply
 * locally and all of them apply on a deployment whose owner is not a superuser —
 * the normal Supabase shape. Verified on a throwaway non-superuser-owned table:
 * app.user_id unset -> 0 rows, set to the subject -> 1 row, set to anyone else
 * -> 0 rows.
 *
 * runAsUser sets app.user_id transaction-scoped from the verified JWT subject.
 * A bare pooled query here would pass CI and return an empty profile in
 * production — and an empty profile means `isMinor` is null, which means §3.0.3
 * forces review on every response ever generated. Silent, expensive, and
 * indistinguishable from correct behaviour without reading this comment.
 */

/** The two flags that speak to §2.4.3. See `deriveIsMinor`. */
const UNDER_18: RiskFlagKey = 'AGE_UNDER_18';
const OVER_75: RiskFlagKey = 'AGE_75_PLUS';

interface ProfileRow {
  user_id: string;
  data_region: string;
  residency_country: string | null;
}

interface EnvelopeRow {
  attribute_id: string;
  kind: string;
  provenance: 'stated' | 'inferred';
  payload_ciphertext: Buffer;
  cipher_alg: string;
  cipher_nonce: Buffer;
  key_id: string;
}

export async function lookupPatientProfile(ctx: PipelineContext): Promise<PatientProfile | null> {
  return runAsUser(
    ctx.authClaims,
    async (client) => {
      const { rows: profileRows } = await client.query<ProfileRow>(
        `SELECT user_id, data_region, residency_country
           FROM principal.patient_profile
          WHERE user_id = $1`,
        [ctx.userId],
      );
      const profile = profileRows[0];
      // No row, or no row VISIBLE under RLS. Deliberately the same answer: the
      // caller must not be able to tell "this subject does not exist" from
      // "this subject is not yours to read", and §3.0.3 resolves both closed.
      if (!profile) return null;

      const { rows: flagRows } = await client.query<{ flag_key: RiskFlagKey }>(
        `SELECT flag_key
           FROM principal.patient_risk_flag
          WHERE subject_id = $1 AND cleared_at IS NULL`,
        [ctx.userId],
      );
      const riskFlags = flagRows.map((r) => r.flag_key);

      // §3.8.2: purpose REASONING, and include_inferred FALSE. An inferred
      // attribute is reachable only for CONFIRMATION_UI — the function RAISES
      // otherwise — so this call cannot accidentally feed an unconfirmed
      // model-inferred condition into the composer.
      //
      // THE AUDIT ID IS DELIBERATELY NOT PASSED, and this is the one place that
      // decision is visible. principal.attribute_access_log.audit_id carries an
      // FK to obs.response_audit(id), which route.ts writes at the END of the
      // turn — so passing ctx.auditId here names a parent that does not exist
      // yet and the read dies inside the DEFINER function:
      //
      //   ERROR: insert or update on table "attribute_access_log" violates
      //          foreign key constraint "attribute_access_log_audit_id_fkey"
      //
      // Same ordering inversion migration 039 fixed for obs.ai_call and
      // obs.fabrication_block, in a third place. Here it is fatal rather than
      // cosmetic: the exception surfaces from inside the function, so the whole
      // profile read fails and the turn with it.
      //
      // audit_id is nullable, so the §3.8.2 record still lands complete —
      // attribute, subject, time, accessor role, accessor id, purpose, region.
      // What is deferred is only the JOIN from a read back to the response that
      // caused it. Restoring it needs 039's backfill shape, and the envelope
      // does not return its log-row ids, so that is a register item and not
      // something to improvise here.
      //
      // migrations/test/r10d_attr.sh §5 pins BOTH directions, so nobody
      // "improves" this by threading ctx.auditId through it.
      const { rows: envelopes } = await client.query<EnvelopeRow>(
        `SELECT attribute_id, kind, provenance, payload_ciphertext, cipher_alg, cipher_nonce, key_id
           FROM principal.fetch_attribute_envelope($1, 'REASONING', NULL, false)`,
        [ctx.userId],
      );

      const statedConditions: PatientProfile['statedConditions'] = [];
      let preferences: Record<string, unknown> | null = null;

      for (const e of envelopes) {
        let payload: unknown;
        try {
          // The key that encrypted the row, not merely the subject's current
          // key. They are the same today — nothing rotates — but reading
          // e.key_id and asserting it keeps a future rotation from silently
          // producing garbage instead of an error.
          if (e.key_id !== ctx.subjectKey.keyId) {
            throw new Error(
              `attribute ${e.attribute_id} was encrypted under key ${e.key_id}, ` +
                `subject's current key is ${ctx.subjectKey.keyId}`,
            );
          }
          payload = decryptAttribute(ctx.subjectKey, e.payload_ciphertext, e.cipher_nonce, e.cipher_alg);
        } catch (err) {
          // Loud, and not fatal. An unreadable attribute must not take down a
          // turn whose safety decisions do not depend on it — see the header —
          // but it is a data-integrity event and must never be silent.
          console.error('CRITICAL: patient attribute could not be decrypted', {
            attributeId: e.attribute_id,
            kind: e.kind,
            auditId: ctx.auditId,
            err,
          });
          continue;
        }

        if (e.kind === 'PREFERENCE') {
          preferences = { ...(preferences ?? {}), ...(payload as Record<string, unknown>) };
          continue;
        }
        // DIAGNOSIS / HISTORY / ALLERGY / MEDICATION / PRIOR_PROCEDURE all
        // describe the patient clinically. They are carried with their
        // provenance rather than flattened, because §3.8.2 forbids treating an
        // inferred attribute as equivalent to a stated one — even though this
        // call can only return `stated` rows today, the distinction survives
        // the day CONFIRMATION_UI starts promoting them.
        const label = (payload as { label?: unknown })?.label;
        if (typeof label === 'string' && label.length > 0) {
          statedConditions.push({ label, provenance: e.provenance });
        }
      }

      return {
        userId: profile.user_id,
        dataRegion: profile.data_region,
        residencyCountry: profile.residency_country,
        riskFlags,
        isMinor: deriveIsMinor(riskFlags),
        statedConditions,
        preferences,
      };
    },
    // reasoner_role. See runAsUser's own doc comment for why this is not hp_app.
    'reasoner',
  );
}

/**
 * §2.4.3, derived from the flags the schema actually keeps.
 *
 * THREE-VALUED, and the third value carries the weight. `null` means minority
 * was never ESTABLISHED for this subject — which is not "adult", and under
 * §3.0.3 resolves the gate closed.
 *
 *   AGE_UNDER_18 active                 -> true
 *   AGE_75_PLUS active, UNDER_18 not    -> false
 *   neither                             -> null
 *   BOTH active                         -> true
 *
 * The AGE_75_PLUS arm is arithmetic, not clinical judgment: a subject flagged
 * 75-or-over is not under 18. It is here because without it `isMinor` is null
 * for every subject who has ever used the system — nothing writes these flags
 * yet — and a gate that fires on everyone stops distinguishing anything. It
 * changes no outcome today and becomes load-bearing the moment CL6's
 * safeguarding work starts populating flags.
 *
 * BOTH resolves to `true` because the two are contradictory and contradictory
 * data about a subject's age is precisely the case §3.0.3 says to resolve
 * closed. It is also the cheap direction: it costs reviewer time, which is what
 * §2.4.3 exists to spend.
 *
 * WHAT THIS STILL DOES NOT FIX, unchanged from HP-SR-001 and deliberately not
 * smuggled into a schema migration:
 *
 *  - §2.4.3 is scoped to "the subject of a clinical question"; these flags
 *    belong to the AUTHENTICATED USER, so a parent asking about a child does
 *    not trigger it (SR-3). Establishing the subject from a message is the
 *    clinical lead's question.
 *  - The Charter scopes the obligation to Decision Support; the caller applies
 *    it to Informational responses too. Over-inclusive rather than unsafe, and
 *    narrowing a safety gate should be a recorded decision.
 */
export function deriveIsMinor(riskFlags: readonly RiskFlagKey[]): boolean | null {
  if (riskFlags.includes(UNDER_18)) return true;
  if (riskFlags.includes(OVER_75)) return false;
  return null;
}

/**
 * §2.4.3's gate, in one named, testable place rather than inline at the call
 * site — because the interesting cases are the ones a `?.` chain hides.
 *
 * Returns true unless minority has been POSITIVELY ESTABLISHED AS FALSE. Three
 * inputs resolve to "force review":
 *
 *   profile === null      no profile row exists, or none is visible under RLS
 *   isMinor === null      nothing establishes the subject's age either way
 *   isMinor === true      the subject is a minor
 *
 * This was previously `profile?.isMinor === true` at the call site, which
 * resolved the first two to "adult" — HP-SR-001 §4. The stub schema agreed with
 * the code (`is_minor boolean NOT NULL DEFAULT false`), so a patient whose age
 * nobody had ever established was recorded as not a minor, by default, in the
 * column itself. The real schema cannot express that mistake: there is no
 * column, only a flag that is present or absent.
 */
export function minorGateRequiresReview(profile: PatientProfile | null): boolean {
  return profile?.isMinor !== false;
}

/**
 * §2.2.5b TRIGGER 1 — "the user carries a flagged high-risk profile (§4.6)".
 *
 * HP-SR-001 recorded this as having "no implementation anywhere", and it was
 * right in effect if not in cause: the flags reach this module and then nine of
 * the ten are thrown away. `deriveIsMinor` reads AGE_UNDER_18 and AGE_75_PLUS
 * and the caller uses only the minor gate, so PREGNANCY, IMMUNOSUPPRESSION,
 * ACTIVE_MALIGNANCY, ANTICOAGULATION, TRANSPLANT_RECIPIENT, POST_OP_UNDER_30D,
 * DIALYSIS and ANAPHYLAXIS_HISTORY have never influenced anything.
 *
 * ANY ACTIVE FLAG EXCEPT THE TWO AGE FLAGS, and the exception is a NARROWING
 * that had to be argued for rather than assumed. §2.2.5b names no subset and
 * §3.0.3 makes the absence of a narrowing decision a prohibition on narrowing,
 * so the literal reading was implemented first — and then disproved by running
 * it:
 *
 *   `deriveIsMinor` returns FALSE only when AGE_75_PLUS is active. It returns
 *   NULL when neither age flag is present, and §3.0.3 resolves NULL closed.
 *   So every subject is in exactly one of three states:
 *
 *     AGE_UNDER_18 active  -> minor gate fires
 *     AGE_75_PLUS  active  -> minor gate clears... and trigger 1 fires
 *     neither active       -> minor gate fires (age unestablished)
 *
 *   Under the literal reading NO SUBJECT CAN EVER PUBLISH. Not "few" — none, by
 *   construction, because the schema has no way to say "age established, and it
 *   is between 18 and 74". The integration suite proved it in one run: the
 *   publish branch of the pipeline became unreachable and untestable.
 *
 * A review gate that fires on every response is not a stricter gate, it is the
 * absence of one — the same argument `deriveIsMinor`'s own comment makes about
 * a null-everywhere isMinor ("a gate that fires on everyone stops
 * distinguishing anything"), and with no reviewer console (CGP-001 §8.3) a
 * hundred-percent PENDING queue is a queue nobody triages.
 *
 * So the two AGE flags are left to the clause the Charter gives age — §2.4.3,
 * via `minorGateRequiresReview` above, which already reads exactly those two —
 * and trigger 1 governs the eight CLINICAL flags. Note also that §4.6.1's own
 * stated effect is "raises the floor severity by one level for symptom-related
 * messages", not "forces review": what §2.2.5b trigger 1 inherits from §4.6 is
 * the flag LIST, and the Charter does not say the age entries carry the same
 * meaning in both clauses.
 *
 * THIS IS RECORDED AS A DECISION, NOT SMUGGLED. Sheet E of the review pack
 * (HP-CGP-004) asks the clinical lead for each flag's effect, and sheet G now
 * asks this question directly. The real fix is upstream and is neither
 * engineering's nor a narrowing: age belongs in a DEMOGRAPHIC attribute
 * (HP-SR-001 §4), and `deriveIsMinor` reads AGE_75_PLUS as a proxy for "not a
 * minor" only because nothing else in the schema can say so.
 *
 * THE VOLUME CONSEQUENCE IS REAL AND SHOULD NOT BE DISCOVERED IN PRODUCTION.
 * POST_OP_UNDER_30D describes most of this platform's population by
 * construction — a medical-travel patient within thirty days of a procedure is
 * the ordinary case, not the exception — so this trigger will fire on a large
 * fraction of Decision Support responses. Reviewer capacity is CL8 and is
 * unmodelled. HP-SR-001's caution about SR-4 applies unchanged: the safe
 * default is still the right default, and the volume should reach the clinical
 * lead in the same message rather than after.
 *
 * A NULL PROFILE DOES NOT FIRE THIS, deliberately. "No flags are known" is not
 * "a flag is present", and the unknown case is already forced closed by
 * `minorGateRequiresReview` above. Keeping the two distinct is what lets the
 * audit row say WHICH trigger fired instead of only THAT one did.
 */
const AGE_FLAGS: readonly RiskFlagKey[] = [UNDER_18, OVER_75];

export function highRiskProfileRequiresReview(profile: PatientProfile | null): boolean {
  return (profile?.riskFlags ?? []).some((f) => !AGE_FLAGS.includes(f));
}
