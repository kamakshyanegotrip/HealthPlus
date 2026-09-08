#!/usr/bin/env bash
# ============================================================================
# R10-key — the subject key can be minted, and destroying it still erases.
#
# principal.subject_key has existed since 001_003 with no way to create a row.
# Migration 038 adds one. A migration that makes an erasure mechanism USABLE has
# to prove the mechanism still works, so §5 is the point of this file: it seeds
# a real encrypted attribute, reads it back through the audited envelope, erases
# the subject, and shows the same read now returns nothing while the audit
# projection survives.
#
# That is ADR-003 §2.4's crypto-shredding claim and §2.3.4g's audit guarantee,
# executed together rather than asserted separately — which is what HP-LB-001 is
# being asked to validate.
#
# Env: standard PG* vars, as the owner. Re-runnable: fixtures dropped in a trap.
# ============================================================================
set -euo pipefail
PGDATABASE="${PGDATABASE:-healthplus}"
export PGDATABASE
fail() { echo "R10-key FAIL: $*" >&2; exit 1; }
count() { psql -qtAc "$1" | tr -d '[:space:]'; }

A=$(count "SELECT gen_random_uuid()")
B=$(count "SELECT gen_random_uuid()")
# REGION AND RESIDENCY COME FROM residency_admission, NOT FROM region_registry.
#
# The first draft of this file took the region from region_registry with
# `ORDER BY active_from LIMIT 1` — which is what migration 034 §3 does, so it
# looked right, and it was wrong for the second time in this repository. Other
# gates seed a demonstration region into that table (sec1_region_context.sh
# seeds EU, with an active_from that sorts first), so the answer depended on
# what had run before: full-suite runs picked EU and then failed looking for an
# admitted residency that routes to it.
#
# rf6_claim.sh already carries this scar and its own fix. Writing the same bug
# again three PRs later is the argument for stating the rule rather than the
# instance: A GATE MUST DERIVE ITS FIXTURES FROM THE TABLE THAT DEFINES ITS OWN
# PRECONDITION, not from a neighbouring one that happens to agree today.
#
# Here the precondition is ADR-004 §3 — a patient profile needs a residency
# counsel has ADMITTED, routing to that residency's region — so both values come
# from the one row that states it, and nothing another gate writes can move them.
read -r RESIDENCY REGION <<<"$(psql -qtA -F' ' -c "
  SELECT residency_country, data_region FROM public.residency_admission
   WHERE admission_state = 'ADMITTED' ORDER BY residency_country LIMIT 1")"
[ -n "${RESIDENCY:-}" ] && [ -n "${REGION:-}" ] || fail "no ADMITTED residency exists.
ADR-004 §3 refuses a patient profile whose residency counsel has not admitted, so
§5 cannot seed a subject at all until one does."

cleanup() {
  psql -qtA -c "DELETE FROM principal.attribute_access_log WHERE subject_id IN ('$A','$B');
                DELETE FROM principal.patient_attribute    WHERE subject_id IN ('$A','$B');
                DELETE FROM principal.patient_profile      WHERE user_id   IN ('$A','$B');
                DELETE FROM principal.subject_key          WHERE subject_id IN ('$A','$B');
                DELETE FROM principal.app_user             WHERE id        IN ('$A','$B');" >/dev/null 2>&1 || true
}
trap cleanup EXIT

psql -v ON_ERROR_STOP=1 -q -c "
  INSERT INTO principal.app_user (id, auth_subject, data_region)
  VALUES ('$A', 'keymint-ci-$A', '$REGION'), ('$B', 'keymint-ci-$B', '$REGION')"

# ---------------------------------------------------------------------------
# 1. IT MINTS, IT IS IDEMPOTENT, AND THE SALT IS PER SUBJECT.
#
#    The salt matters as much as the key: subject_pseudonym is HMAC(user_id,
#    salt), so a salt shared between subjects would make two people's pseudonyms
#    derivable from one another's.
# ---------------------------------------------------------------------------
echo "1. mints once, returns the same key thereafter, one salt per subject"
first=$(count "SELECT created||'/'||length(salt)||'/'||key_id FROM principal.ensure_subject_key('$A', gen_random_bytes(60))")
[ "${first%%/*}" = "true" ] || fail "first call did not report created=true (got $first)"
[ "$(echo "$first" | cut -d/ -f2)" = "32" ] || fail "salt is not 32 bytes: $first"

again=$(count "SELECT created||'/'||length(salt)||'/'||key_id FROM principal.ensure_subject_key('$A', gen_random_bytes(60))")
[ "${again%%/*}" = "false" ] || fail "second call minted again instead of returning the existing key"
[ "$(echo "$again" | cut -d/ -f3)" = "$(echo "$first" | cut -d/ -f3)" ] \
  || fail "the second call returned a DIFFERENT key id. subject_id is UNIQUE, so this
would mean the row was replaced — and every pseudonym derived from the old salt
would silently stop matching."

distinct=$(count "SELECT count(DISTINCT salt) FROM principal.subject_key WHERE subject_id IN ('$A','$B')
                   OR TRUE AND subject_id = '$A'")
psql -v ON_ERROR_STOP=1 -q -c "SELECT principal.ensure_subject_key('$B', gen_random_bytes(60))" >/dev/null
shared=$(count "SELECT count(*) FROM principal.subject_key ka, principal.subject_key kb
                 WHERE ka.subject_id='$A' AND kb.subject_id='$B' AND ka.salt = kb.salt")
[ "$shared" = "0" ] || fail "two subjects were minted the SAME salt. subject_pseudonym is
HMAC(user_id, salt), so a shared salt makes one subject's pseudonym derivable
from another's."
echo "  created once, idempotent after, salts distinct"

# ---------------------------------------------------------------------------
# 2. THE DEK IS CHECKED ON THE MINT PATH, AND ONLY THERE.
#
#    A caller that passed the DEK unwrapped, or an empty buffer, would otherwise
#    be stored happily. And a caller that already has a key must not have to
#    fabricate a plausible one just to read its salt back.
# ---------------------------------------------------------------------------
echo "2. an implausible wrapped DEK is refused when minting, ignored when not"
C=$(count "SELECT gen_random_uuid()")
psql -v ON_ERROR_STOP=1 -q -c "INSERT INTO principal.app_user (id, auth_subject, data_region)
  VALUES ('$C', 'keymint-ci-$C', '$REGION')"
short=$(psql -qtA -c "SELECT * FROM principal.ensure_subject_key('$C', '\\x00'::bytea)" 2>&1 || true)
echo "$short" | grep -qi "implausibly short" \
  || fail "a 1-byte wrapped DEK was accepted on the mint path. Got: $short"
psql -qtA -c "DELETE FROM principal.app_user WHERE id='$C'" >/dev/null 2>&1 || true

existing=$(count "SELECT created FROM principal.ensure_subject_key('$A', '\\x00'::bytea)")
[ "$existing" = "f" ] || fail "an existing-key lookup was rejected for its DEK argument;
that validation guards nothing on this path and costs a wrap on every request."
echo "  refused when minting, ignored when the key already exists"

# ---------------------------------------------------------------------------
# 3. THE PRIVILEGE SHAPE.
#
#    principal.subject_key has no grants to any application role and must keep
#    none: the whole point of a DEFINER mint is that the request path can create
#    a key without being able to read, alter or destroy one.
# ---------------------------------------------------------------------------
echo "3. hp_app can mint and cannot touch the table"
[ "$(count "SELECT has_function_privilege('hp_app','principal.ensure_subject_key(uuid,bytea)','EXECUTE')")" = "t" ] \
  || fail "hp_app cannot EXECUTE ensure_subject_key — migration 038's GRANT did not take"
for p in SELECT INSERT UPDATE DELETE; do
  [ "$(count "SELECT has_table_privilege('hp_app','principal.subject_key','$p')")" = "f" ] \
    || fail "hp_app holds $p on principal.subject_key. A request path that can read
wrapped DEKs, or clear a destroyed_at, is a request path that can undo erasure."
done
echo "  EXECUTE yes; no table privilege at all"

# ---------------------------------------------------------------------------
# 4. DESTRUCTION IS FINAL — IN THE FUNCTION AND IN THE DATABASE.
#
#    Two independent guards, asserted separately, because either one alone would
#    look sufficient right up until the other was removed.
# ---------------------------------------------------------------------------
echo "4. a destroyed key cannot be re-minted, and cannot be restored by UPDATE"
psql -v ON_ERROR_STOP=1 -q -c "SELECT principal.erase_subject('$B')" >/dev/null

remint=$(psql -qtA -c "SELECT * FROM principal.ensure_subject_key('$B', gen_random_bytes(60))" 2>&1 || true)
echo "$remint" | grep -qi "destruction is final" \
  || fail "ensure_subject_key re-minted a DESTROYED subject's key. That resurrects the
linkage erasure severed and erases the record that erasure happened. Got: $remint"

restore=$(psql -qtA -c "UPDATE principal.subject_key
   SET destroyed_at = NULL, salt = gen_random_bytes(32), wrapped_dek = gen_random_bytes(60)
 WHERE subject_id = '$B'" 2>&1 || true)
echo "$restore" | grep -qi "destruction is final\|may not be restored" \
  || fail "a destroyed key was restored by direct UPDATE. trg_key_destruction_final
(migration 018) is the guard that does not depend on callers behaving. Got: $restore"
echo "  function raises; trigger refuses independently"

# ---------------------------------------------------------------------------
# 5. AND THE THING ALL OF IT IS FOR: THE SHRED ACTUALLY ERASES.
#
#    A key mint is only worth having if destroying the key destroys access. This
#    seeds a real encrypted attribute, reads it through the audited envelope,
#    erases, and reads again — and checks that the AUDIT PROJECTION SURVIVES,
#    because erasure that took the audit trail with it would breach §2.3.4g
#    while looking like a success.
# ---------------------------------------------------------------------------
echo "5. destroying the key ends attribute access, and the audit projection survives"
KEY=$(count "SELECT key_id FROM principal.ensure_subject_key('$A', gen_random_bytes(60))")
psql -v ON_ERROR_STOP=1 -q -c "
  -- residency_country is not optional: assert_residency_admitted (ADR-004 §3)
  -- refuses a profile that does not state one, refuses a residency counsel has
  -- not ADMITTED, and refuses one that routes to a different region. Exactly one
  -- residency is ADMITTED today and it is the admitted region's own country —
  -- which is the point of the table, not a limitation of this fixture.
  INSERT INTO principal.patient_profile (user_id, data_region, key_id, residency_country)
  VALUES ('$A', '$REGION', '$KEY', '$RESIDENCY') ON CONFLICT DO NOTHING;
  INSERT INTO principal.patient_attribute
    (id, subject_id, data_region, kind, payload_ciphertext, cipher_alg, cipher_nonce,
     key_id, attribute_key_digest, provenance, origin)
  VALUES (gen_random_uuid(), '$A', '$REGION', 'DIAGNOSIS', gen_random_bytes(48),
          'aes-256-gcm', gen_random_bytes(12), '$KEY',
          principal.attribute_ref_digest('$A', 'keymint-ci'), 'stated', 'USER_STATED')"

before=$(count "SELECT count(*) FROM principal.fetch_attribute_envelope('$A', 'REASONING')")
[ "$before" -ge 1 ] || fail "the seeded attribute is not readable through fetch_attribute_envelope
BEFORE erasure, so §5 would prove nothing about what erasure removes."

audit_before=$(count "SELECT count(*) FROM obs.response_audit")

psql -v ON_ERROR_STOP=1 -q -c "SELECT principal.erase_subject('$A')" >/dev/null

after=$(count "SELECT count(*) FROM principal.fetch_attribute_envelope('$A', 'REASONING')")
[ "$after" = "0" ] || fail "the attribute is STILL readable after erase_subject. Crypto-shredding
is the entire basis of the audit-vs-erasure reconciliation; if the envelope still
returns rows, the reconciliation is a claim rather than a mechanism."

live=$(count "SELECT count(*) FROM principal.subject_key
               WHERE subject_id='$A' AND (salt IS NOT NULL OR wrapped_dek IS NOT NULL)")
[ "$live" = "0" ] || fail "key material survived erasure for subject $A"

audit_after=$(count "SELECT count(*) FROM obs.response_audit")
[ "$audit_after" = "$audit_before" ] || fail "erase_subject changed obs.response_audit
($audit_before -> $audit_after). §2.3.4g keeps the audit trail; the pseudonym stops
being recomputable because the salt is gone, which is what makes that lawful."
echo "  readable before ($before), unreadable after (0), audit projection unchanged"

echo "R10-key: the key mints once, destruction is final in two places, and the shred erases."
