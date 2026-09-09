#!/usr/bin/env bash
# ============================================================================
# R10d-attr — THE PROFILE READ PATH, as the role that will actually walk it.
#
# Migration 041 grants reasoner_role the two reads §2.4.3 and the composer need,
# and deliberately withholds a third. This exercises all of that as the role
# rather than as the owner, and then does the thing no other gate in this
# repository does: it runs the attribute read under a NON-SUPERUSER OWNER, which
# is the only way the production row boundary can be observed here at all.
#
#   1  reasoner_role reads its own profile and risk flags, and only its own
#   2  the roles that must NOT be able to read them still cannot
#   3  patient_attribute keeps no direct grant — envelope access only
#   4  FORCE ROW LEVEL SECURITY inside the DEFINER function, three directions
#   5  §3.8.2 — every read is logged, and the audit_id ordering trap that
#      would otherwise kill every turn
#   6  §3.8.2 — an inferred attribute is refused outside CONFIRMATION_UI
#
# Env: standard PG* vars, as the owner. Re-runnable: fixtures dropped in a trap.
# ============================================================================
set -euo pipefail
PGDATABASE="${PGDATABASE:-healthplus}"
export PGDATABASE
fail() { echo "R10d-attr FAIL: $*" >&2; exit 1; }
count() { psql -qtAc "$1" | tr -d '[:space:]'; }

# THE FIXTURE'S REGION COMES FROM residency_admission, the table that states this
# gate's own precondition — ADR-004 §3 refuses a patient profile whose residency
# counsel has not admitted. Not from region_registry: three gates have now been
# bitten by ORDER BY active_from picking up a neighbouring gate's demonstration
# region, and the rule that came out of it is that a gate derives its fixtures
# from the table defining its precondition.
read -r RESIDENCY REGION <<<"$(psql -qtA -F' ' -c "
  SELECT residency_country, data_region FROM public.residency_admission
   WHERE admission_state = 'ADMITTED' ORDER BY residency_country LIMIT 1")"
[ -n "${RESIDENCY:-}" ] && [ -n "${REGION:-}" ] || fail "no ADMITTED residency exists.
ADR-004 §3 refuses a patient profile without one, so this gate cannot seed a subject."

S=$(count "SELECT gen_random_uuid()")   # the subject under test
O=$(count "SELECT gen_random_uuid()")   # somebody else, to prove the boundary

cleanup() {
  psql -qtA -c "
    DELETE FROM principal.attribute_access_log WHERE subject_id IN ('$S','$O');
    DELETE FROM principal.patient_risk_flag    WHERE subject_id IN ('$S','$O');
    DELETE FROM principal.patient_attribute    WHERE subject_id IN ('$S','$O');
    DELETE FROM principal.patient_profile      WHERE user_id   IN ('$S','$O');
    DELETE FROM principal.subject_key          WHERE subject_id IN ('$S','$O');
    DELETE FROM principal.app_user             WHERE id        IN ('$S','$O');
    DROP ROLE IF EXISTS hp_force_rls_probe;" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

seed_subject () {  # $1 = subject uuid, $2 = 'minor' | 'adult' | 'unknown'
  psql -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$
DECLARE v_key uuid; v_attr uuid := gen_random_uuid();
BEGIN
  INSERT INTO principal.app_user (id, auth_subject, data_region)
  VALUES ('$1', 'r10dattr-ci-$1', '$REGION');

  SELECT key_id INTO v_key FROM principal.ensure_subject_key('$1', gen_random_bytes(60));

  INSERT INTO principal.patient_profile (user_id, data_region, key_id, residency_country)
  VALUES ('$1', '$REGION', v_key, '$RESIDENCY');

  -- A stated attribute. The payload is opaque to this gate — the application
  -- owns the cipher — so the bytes are arbitrary; what matters here is the
  -- envelope's visibility, not what decrypts out of it.
  INSERT INTO principal.patient_attribute
    (id, subject_id, data_region, kind, payload_ciphertext, cipher_alg, cipher_nonce,
     key_id, attribute_key_digest, provenance, origin)
  VALUES (v_attr, '$1', '$REGION', 'DEMOGRAPHIC', gen_random_bytes(48), 'AES-256-GCM',
          gen_random_bytes(12), v_key, principal.attribute_ref_digest('$1','age_band'),
          'stated', 'USER_STATED');

  -- The risk flag is what §2.4.3 actually reads. trg_risk_flag_stated_only
  -- refuses to set one from an inferred attribute (§4.6.2), which is why the
  -- attribute above is 'stated'.
  IF '$2' = 'minor' THEN
    INSERT INTO principal.patient_risk_flag (id, subject_id, flag_key, source_attribute_id, data_region)
    VALUES (gen_random_uuid(), '$1', 'AGE_UNDER_18', v_attr, '$REGION');
  ELSIF '$2' = 'adult' THEN
    INSERT INTO principal.patient_risk_flag (id, subject_id, flag_key, source_attribute_id, data_region)
    VALUES (gen_random_uuid(), '$1', 'AGE_75_PLUS', v_attr, '$REGION');
  END IF;
END \$\$;
SQL
}

seed_subject "$S" minor
seed_subject "$O" adult

# `as_reasoner <app.user_id> <sql>` — the shape the application actually uses:
# reasoner_role, with app.user_id set transaction-scoped exactly as runAsUser
# sets it from the verified JWT subject.
as_reasoner () {
  psql -qtA -c "BEGIN;
    SET SESSION AUTHORIZATION reasoner_role;
    SELECT set_config('app.user_id', '$1', true);
    $2;
  ROLLBACK;" 2>&1 | tail -1 | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
echo "1. reasoner_role reads its own profile and risk flags — and only its own"
# ---------------------------------------------------------------------------
[ "$(as_reasoner "$S" "SELECT count(*) FROM principal.patient_profile")" = "1" ] \
  || fail "reasoner_role cannot read its own principal.patient_profile row.
Migration 041 §1 grants SELECT and creates p_pp_own; before it the table had RLS
enabled and NO policy at all, so every read denied."

[ "$(as_reasoner "$S" "SELECT count(*) FROM principal.patient_risk_flag WHERE cleared_at IS NULL")" = "1" ] \
  || fail "reasoner_role cannot read its own principal.patient_risk_flag rows.
This is §2.4.3's actual source — p_prf_own has existed since migration 018 with
the right predicate and no role holding SELECT, so it had never once evaluated."

# The negative direction, which is the half that makes the positive mean anything.
[ "$(as_reasoner "$O" "SELECT count(*) FROM principal.patient_profile WHERE user_id = '$S'")" = "0" ] \
  || fail "a reasoner_role session acting for subject $O could read $S's profile.
p_pp_own is USING (user_id = app.current_user_id()); if this returns a row the
policy is not being applied."

[ "$(as_reasoner "$O" "SELECT count(*) FROM principal.patient_risk_flag WHERE subject_id = '$S'")" = "0" ] \
  || fail "one subject's session could read ANOTHER subject's §2.4.3 risk flags."

# And with no app.user_id at all — the shape a bare pooled query would produce.
noguc=$(psql -qtA -c "BEGIN; SET SESSION AUTHORIZATION reasoner_role;
  SELECT count(*) FROM principal.patient_risk_flag; ROLLBACK;" | tail -1 | tr -d '[:space:]')
[ "$noguc" = "0" ] || fail "risk flags were readable with app.user_id UNSET (got $noguc).
That is the failure mode runAsUser exists to prevent: a query outside it reads
whatever the policy lets NULL through."
echo "  own rows yes, another subject's no, no GUC no"

# ---------------------------------------------------------------------------
echo "2. the roles that must not reach these tables still cannot"
# ---------------------------------------------------------------------------
for role in hp_app redflag_role dqe_role; do
  for tbl in patient_profile patient_risk_flag patient_attribute; do
    [ "$(count "SELECT has_table_privilege('$role','principal.$tbl','SELECT')")" = "f" ] \
      || fail "$role holds SELECT on principal.$tbl. Migration 041 grants the profile
read to reasoner_role ALONE — hp_app is the role that handles untrusted request
input, and widening it to reach health attributes is the thing the per-role
connection model (R13-conn) exists to prevent."
  done
done
echo "  hp_app, redflag_role and dqe_role hold nothing on any of the three"

# ---------------------------------------------------------------------------
echo "3. patient_attribute has no direct grant to anyone — envelope access only"
# ---------------------------------------------------------------------------
direct=$(count "SELECT count(*) FROM information_schema.role_table_grants
                 WHERE table_schema='principal' AND table_name='patient_attribute'
                   AND grantee <> 'postgres'")
[ "$direct" = "0" ] || fail "principal.patient_attribute has $direct direct grant(s).
It must be readable only through principal.fetch_attribute_envelope, which writes
the §3.8.2 access log on every read and enforces the inferred/CONFIRMATION_UI
rule. A direct SELECT bypasses both — see migration 041's header."

[ "$(count "SELECT has_function_privilege('reasoner_role','principal.fetch_attribute_envelope(uuid,text,uuid,boolean)','EXECUTE')")" = "t" ] \
  || fail "reasoner_role cannot EXECUTE fetch_attribute_envelope, so it has no way
to read attributes at all. Migration 040 revoked PUBLIC and re-granted the two
intended roles; this checks the re-grant took."
echo "  no direct grant, and the envelope is executable by reasoner_role"

# ---------------------------------------------------------------------------
echo "4. FORCE ROW LEVEL SECURITY inside the DEFINER function — the production shape"
#
# ⚠ THE ONE CHECK IN THIS REPOSITORY THAT DOES NOT RUN AS A SUPERUSER OWNER.
#
# principal.patient_attribute is FORCE ROW LEVEL SECURITY, which means p_pa_own
# applies to the table OWNER too — and therefore inside fetch_attribute_envelope,
# a SECURITY DEFINER function running as that owner. So the envelope is itself
# subject-scoped and returns rows only when app.user_id names the subject.
#
# EXCEPT that a superuser bypasses RLS entirely, FORCE or not. Every migration
# and every gate here runs as `postgres`, a superuser, so that boundary has never
# applied in any test this project has ever run. On a deployment whose owner is
# not a superuser — the normal Supabase shape — it applies in full.
#
# So this section rents the production shape for one transaction: it reassigns
# the three objects the function touches, plus the function, to a non-superuser
# role. ALTER ... OWNER is transactional, so ROLLBACK restores every owner with
# no trap to get wrong. All three objects must move together — reassigning the
# function alone leaves it unable to read subject_key or write the access log,
# which looks like a policy failure and is not.
# ---------------------------------------------------------------------------
psql -v ON_ERROR_STOP=1 -q -c "CREATE ROLE hp_force_rls_probe NOLOGIN"
force=$(psql -qtA <<SQL
BEGIN;
  ALTER TABLE principal.patient_attribute    OWNER TO hp_force_rls_probe;
  ALTER TABLE principal.attribute_access_log OWNER TO hp_force_rls_probe;
  ALTER TABLE principal.subject_key          OWNER TO hp_force_rls_probe;
  ALTER FUNCTION principal.fetch_attribute_envelope(uuid,text,uuid,boolean)
    OWNER TO hp_force_rls_probe;
  GRANT USAGE ON SCHEMA principal, app, public TO hp_force_rls_probe;
  SET SESSION AUTHORIZATION reasoner_role;
  SELECT 'unset='  || count(*) FROM principal.fetch_attribute_envelope('$S','REASONING');
  SELECT set_config('app.user_id','$S',true) IS NOT NULL;
  SELECT 'self='   || count(*) FROM principal.fetch_attribute_envelope('$S','REASONING');
  SELECT set_config('app.user_id','$O',true) IS NOT NULL;
  SELECT 'other='  || count(*) FROM principal.fetch_attribute_envelope('$S','REASONING');
  RESET SESSION AUTHORIZATION;
ROLLBACK;
SQL
)
echo "$force" | grep -q "unset=0" || fail "under a non-superuser owner, the envelope returned
rows with app.user_id UNSET. FORCE RLS on patient_attribute is what makes the
DEFINER function subject-scoped; without it any caller can read any subject.
Got: $(echo "$force" | tr '\n' ' ')"
echo "$force" | grep -q "self=1" || fail "under a non-superuser owner, the envelope returned
NOTHING for the subject's own session. This is the production failure mode the
application must not hit: an empty profile means §2.4.3's age is unestablished,
which forces review on every response ever generated — silently, and only in
production. Got: $(echo "$force" | tr '\n' ' ')"
echo "$force" | grep -q "other=0" || fail "under a non-superuser owner, a session acting for
$O read $S's attributes through the envelope. Got: $(echo "$force" | tr '\n' ' ')"

owner_after=$(count "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE relname='patient_attribute'")
[ "$owner_after" = "postgres" ] || fail "ROLLBACK did not restore patient_attribute's owner
(now $owner_after). ALTER ... OWNER is transactional; if this ever fails the gate
has left the schema modified."
psql -q -c "DROP ROLE IF EXISTS hp_force_rls_probe" >/dev/null 2>&1 || true
echo "  unset=0, self=1, other=0 — and every owner restored by ROLLBACK"

# ---------------------------------------------------------------------------
echo "5. §3.8.2 — every envelope read is logged, and the audit_id ordering trap"
#
# FOURTH FINDING OF THIS WORK, and the one that would have broken every turn.
#
# principal.attribute_access_log.audit_id carries an FK to obs.response_audit(id)
# — the C-30 projection, which route.ts writes at the END of a turn, once
# category, confidence and review state are known. The profile read happens near
# the START. So passing ctx.auditId to the envelope names a parent that does not
# exist yet:
#
#     ERROR: insert or update on table "attribute_access_log" violates foreign
#            key constraint "attribute_access_log_audit_id_fkey"
#
# This is the same ordering inversion migration 039 found for obs.ai_call and
# obs.fabrication_block, in a third place nobody had looked, and it is fatal
# rather than cosmetic: the exception comes from inside the DEFINER function, so
# the profile read fails outright and the turn dies.
#
# audit_id is NULLABLE, so the request path passes NULL and the §3.8.2 record is
# complete without it — attribute_id, subject_id, accessed_at, accessor_role,
# accessor_id, purpose and data_region all land. What defers is only the JOIN
# from a read to the response that caused it. Restoring that link needs the
# backfill shape 039 uses, and the envelope does not return its log row ids, so
# it is a register item rather than something invented here.
#
# Both directions are pinned because the trap is silent in one of them: NULL
# works, so a reviewer sees a passing gate; a real-looking audit id fails, and
# that is what stops someone "improving" the caller by threading ctx.auditId
# through it.
# ---------------------------------------------------------------------------
before=$(count "SELECT count(*) FROM principal.attribute_access_log WHERE subject_id='$S'")
psql -q -c "SELECT count(*) FROM principal.fetch_attribute_envelope('$S','REASONING',NULL)" >/dev/null
after=$(count "SELECT count(*) FROM principal.attribute_access_log WHERE subject_id='$S'")
[ "$after" -gt "$before" ] \
  || fail "reading the envelope wrote no attribute_access_log row. §3.8.2's audit of
who read a subject's attributes is the entire reason attribute access is
function-mediated rather than a SELECT grant."

[ "$(count "SELECT count(*) FROM principal.attribute_access_log
             WHERE subject_id='$S' AND purpose='REASONING' AND accessor_role='postgres'
               AND audit_id IS NULL")" -ge 1 ] \
  || fail "the access-log row does not carry the purpose and accessor it was called with."

# The trap itself. An audit id that is not yet in obs.response_audit — which is
# every audit id, at the moment the profile is read — must be refused.
UNKNOWN=$(count "SELECT gen_random_uuid()")
trap_out=$(psql -qtA -c "SELECT count(*) FROM principal.fetch_attribute_envelope('$S','REASONING','$UNKNOWN'::uuid)" 2>&1 || true)
echo "$trap_out" | grep -q "attribute_access_log_audit_id_fkey" \
  || fail "passing an audit id absent from obs.response_audit was NOT refused.
If this ever starts succeeding the FK has been dropped, and the cutover's
decision to pass NULL — recorded in patientProfile.ts — needs revisiting rather
than silently keeping a workaround for a constraint that no longer exists.
Got: $trap_out"
echo "  logged with purpose and accessor; a not-yet-written audit id is refused"

# ---------------------------------------------------------------------------
echo "6. §3.8.2 — an inferred attribute is unreachable outside CONFIRMATION_UI"
# ---------------------------------------------------------------------------
refused=$(psql -qtA -c "SELECT count(*) FROM principal.fetch_attribute_envelope('$S','REASONING',NULL,true)" 2>&1 || true)
echo "$refused" | grep -qi "HP-ESC 3.8.2" \
  || fail "asking for inferred attributes under purpose REASONING was NOT refused.
An inferred attribute is a model's guess about a person's health; §3.8.2 makes it
reachable only by the confirmation path that asks them. Got: $refused"

ok_ui=$(psql -qtA -c "SELECT count(*) FROM principal.fetch_attribute_envelope('$S','CONFIRMATION_UI',NULL,true)" 2>&1 || true)
echo "$ok_ui" | grep -qi "HP-ESC 3.8.2" \
  && fail "CONFIRMATION_UI was refused too, so the check is refusing everything rather
than refusing the wrong purpose — a rule scoped to nothing passes a one-sided test."
echo "  REASONING refused, CONFIRMATION_UI permitted"

echo "R10d-attr: the profile read path holds as the role, and under a non-superuser owner."
