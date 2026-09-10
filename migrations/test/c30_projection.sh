#!/usr/bin/env bash
# ============================================================================
# C-30 — the audit projection is writable, and the chain that matters is not
#         weakened by making it so.
#
# Migration 036 drops prev_hash/row_hash from obs.response_audit, which had made
# the row unwritable by any means HP-RB-001 permits: NOT NULL, nothing computing
# them, and the runbook forbidding the application to supply them.
#
# A change that removes columns from an audit-adjacent table has to prove BOTH
# directions, because only one of them is the point:
#
#   §1  the projection can now be written the way the application writes it
#   §2  the projection is still NOT chained, and the chain has not migrated here
#   §3  public.response_audit_event still is chained, and still computes it
#       ITSELF — a caller cannot supply or override a chain value
#   §4  the event log is still append-only
#
# §3 and §4 are what a reader of the changelog will actually worry about, so
# they are asserted here rather than assumed from the fact that 036 does not
# mention them.
#
# Env: standard PG* vars, as the owner. Re-runnable: fixtures dropped in a trap.
# ============================================================================
set -euo pipefail
PGDATABASE="${PGDATABASE:-healthplus}"
export PGDATABASE
fail() { echo "C-30 FAIL: $*" >&2; exit 1; }
count() { psql -qtAc "$1" | tr -d '[:space:]'; }

MARK="c30-ci-$$"
cleanup() {
  psql -qtA -c "DELETE FROM obs.response_audit WHERE classifier_version = '$MARK';" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The region this gate's fixture belongs to. Taken from the table that states
# this gate's precondition rather than from region_registry ordered by
# active_from — three gates have been bitten by a neighbouring fixture's region
# sorting first.
REGION=$(psql -qtAc "SELECT data_region FROM public.residency_admission
                      WHERE admission_state = 'ADMITTED' ORDER BY residency_country LIMIT 1" | tr -d '[:space:]')
[ -n "$REGION" ] || fail "no ADMITTED residency exists; cannot place this fixture in a region."

# THE REGION GOES ON THE CONNECTION, not into the INSERT. Since migration 047,
# public.response_audit_event derives data_region from `app.current_region()` in
# its BEFORE INSERT trigger and REFUSES an append when the GUC is unset — the
# same rule obs.record_response_audit has carried since 044. §3 below appends to
# that log, so without this the gate fails at the append with
# "HP-ADR-004 §2: app.data_region is not set on this connection".
#
# Setting it here rather than passing a column is the point: the application
# never supplies this value either (src/lib/db.ts sets it once per connection),
# so a fixture that supplied it would be testing a path no deployment takes.
export PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c app.data_region=$REGION"

# ---------------------------------------------------------------------------
# 1. THE ROW IS WRITABLE, WITH EXACTLY THE COLUMNS auditLog.ts SUPPLIES.
#
#    Deliberately the application's own column list — not a minimal one that
#    would pass while the real insert still failed.
#
#    data_region joined that list in migration 044 (SEC-2). It is NOT NULL, so
#    this insert began failing the moment the column landed — which is the
#    correct consequence of adding one and is why this gate names the
#    application's columns rather than a convenient subset.
# ---------------------------------------------------------------------------
echo "1. obs.response_audit accepts the insert the application actually issues"
psql -v ON_ERROR_STOP=1 -q -c "
  INSERT INTO obs.response_audit
    (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
     template_id, agg_confidence, policy_version, model_version, prompt_version,
     cited_claim_ids, review_state, clinical_domain, data_region)
  VALUES (gen_random_uuid(), gen_random_bytes(8), now(), 'DECISION_SUPPORT',
          '$MARK', 'NORMAL', NULL, 0.82, 'p1', 'm1', 'pr1', '{}',
          'NOT_REQUIRED', NULL, '$REGION')" \
  || fail "obs.response_audit still refuses the application's insert. Migration 036
dropped prev_hash/row_hash precisely so this would work; if it is still failing,
either 036 did not apply or something else on this table is NOT NULL with no
default and no trigger to fill it."
[ "$(count "SELECT count(*) FROM obs.response_audit WHERE classifier_version='$MARK'")" = "1" ] \
  || fail "the insert reported success and the row is not there"
echo "  written, with no hash supplied by the caller"

# ---------------------------------------------------------------------------
# 2. AND THE CHAIN DID NOT QUIETLY MOVE HERE.
#
#    The failure this guards against is somebody "restoring" the columns later
#    with a trigger, which reinstates the contradiction C-30 resolved: this row
#    is mutable, so a chain over it breaks at the first review decision.
# ---------------------------------------------------------------------------
echo "2. the projection is not chained, and is still mutable"
for c in prev_hash row_hash; do
  [ "$(count "SELECT count(*) FROM information_schema.columns
               WHERE table_schema='obs' AND table_name='response_audit' AND column_name='$c'")" = "0" ] \
    || fail "obs.response_audit still has $c. C-30 makes this table a projection of
public.response_audit_event; a hash chain over a row whose review_state moves
PENDING -> APPROVED attests to nothing anyone reads."
done
psql -v ON_ERROR_STOP=1 -q -c "
  UPDATE obs.response_audit SET review_state = 'PENDING'
   WHERE classifier_version = '$MARK'" \
  || fail "the projection is not updatable. review_state MUST move after the row is
written — that mutability is the whole reason it cannot be the chained record."
echo "  no chain columns; review_state still moves"

# ---------------------------------------------------------------------------
# 3. THE CHAIN THAT MATTERS IS UNTOUCHED — AND STILL COMPUTED BY THE DATABASE.
#
#    HP-RB-001 §4's claim is not "there are hash columns"; it is "the
#    application cannot supply them". So the assertion is that a caller who
#    TRIES to set a chain value is overridden, not merely that the columns
#    exist. Anything less would pass on a table whose trigger had been dropped.
# ---------------------------------------------------------------------------
echo "3. response_audit_event is still chained, and the caller cannot forge it"
for c in prev_hash row_hash; do
  [ "$(count "SELECT count(*) FROM information_schema.columns
               WHERE table_schema='public' AND table_name='response_audit_event'
                 AND column_name='$c' AND is_nullable='NO'")" = "1" ] \
    || fail "public.response_audit_event lost its NOT NULL $c. Migration 036 was
supposed to touch the PROJECTION only; the event log is the record of truth."
done

forged=$(psql -qtAc "
  WITH ins AS (
    INSERT INTO response_audit_event (audit_id, kind, actor, payload, prev_hash, row_hash)
    VALUES (gen_random_uuid(), 'PUBLISHED', 'system', '{\"c30_ci\": true}'::jsonb,
            '\\xdeadbeef'::bytea, '\\xdeadbeef'::bytea)
    RETURNING row_hash, prev_hash
  ) SELECT encode(row_hash,'hex') FROM ins" | tr -d '[:space:]')
[ -n "$forged" ] || fail "could not append to response_audit_event at all"
[ "$forged" != "deadbeef" ] \
  || fail "response_audit_event STORED the caller's row_hash. trg_audit_event_chain is
not firing, so the application can forge a chain — which is the one property
HP-RB-001 §4 exists to provide."
echo "  caller's hash discarded; the trigger computed ${forged:0:12}…"

# ---------------------------------------------------------------------------
# 4. AND IT IS STILL APPEND-ONLY.
# ---------------------------------------------------------------------------
echo "4. the event log is still append-only"
mut=$(psql -qtA -c "UPDATE response_audit_event SET actor='tampered'
                     WHERE payload ? 'c30_ci'" 2>&1 || true)
echo "$mut" | grep -qiE "permission denied|forbid|immutable|cannot" \
  || fail "response_audit_event accepted an UPDATE. Got: $mut"
echo "  UPDATE refused"

psql -qtA -c "DELETE FROM response_audit_event WHERE payload ? 'c30_ci'" >/dev/null 2>&1 || true

echo "C-30: the projection is writable and unchained; the event log is chained, self-computed and append-only."
