#!/usr/bin/env bash
# ============================================================================
# R10f — the constraint assertions rescued from scripts/smoke-test.mjs.
#
# WHY THIS FILE EXISTS AT ALL. The cutover retires
# `chat-pipeline/scripts/smoke-test.mjs`, 743 lines of raw-SQL checks against
# the stub schema. Most of it is now covered better by the gates already in this
# directory, which run against the real schema and as the real roles. Five
# assertions were NOT covered anywhere, and they are the valuable kind — each
# one drives a CHECK constraint to its REFUSAL, proving the constraint does its
# job rather than that a happy-path row fits through it:
#
#   1  obs.ai_call            c_model_may_not_lower       §4.0.3
#   2  obs.response_audit     c_category_c_disabled_v1    §2.3.2
#   3  obs.response_audit     c_min_conf                  §1.9.4 / §2.2
#   4  safety.red_flag_event  c_event_at_least_monitor    §4.0.2
#   5  public.response_audit_event  immutability          HP-RB-001 §4
#
# Deleting the stub without porting these would have quietly removed five
# safety constraints from CI while every remaining gate stayed green — which is
# precisely the failure mode a cutover is most likely to produce.
#
# ONE ASSERTION WAS DELIBERATELY NOT PORTED: smoke-test's `obs.ai_call_cost`
# view check. That view does not exist in the real schema and is not missing —
# cost estimation moved into the application (chat-pipeline/src/lib/pricing.ts)
# because it is a rate card, not a fact about a row. Recorded here rather than
# silently dropped.
#
# EVERY CHECK IS A REFUSAL. A constraint that accepts what it should accept is
# already exercised by every other gate that inserts a row; a constraint that
# fails to REJECT is invisible until production. So each section below inserts a
# row that must fail, and the gate fails if the insert SUCCEEDS.
#
# Env: standard PG* vars, as the owner. Re-runnable: fixtures dropped in a trap.
# ============================================================================
set -euo pipefail
PGDATABASE="${PGDATABASE:-healthplus}"
export PGDATABASE
fail() { echo "R10f FAIL: $*" >&2; exit 1; }
count() { psql -qtAc "$1" | tr -d '[:space:]'; }

# Runs SQL that MUST raise. Prints nothing on the expected failure; fails the
# gate if the statement is accepted, and names the constraint that let it
# through so the message points at the object rather than at this script.
#
# The `psql -v ON_ERROR_STOP=1` exit status is the signal, not the stderr text:
# matching on a message would break the day PostgreSQL rewords it, and would
# also pass for the WRONG error (a typo'd column name raises too, and would look
# exactly like a constraint doing its job).
must_reject() {  # $1 = human name, $2 = constraint name expected, $3 = SQL
  local out
  if out=$(psql -v ON_ERROR_STOP=1 -q -c "BEGIN; $3; ROLLBACK;" 2>&1); then
    fail "$1: the insert was ACCEPTED. $2 did not refuse it."
  fi
  grep -q "$2" <<<"$out" || fail "$1: refused, but not by $2 — got: $(head -3 <<<"$out" | tr '\n' ' ')"
  echo "  ok  $1 (refused by $2)"
}

# --- the region, from the table that states this gate's precondition ---------
read -r RESIDENCY REGION <<<"$(psql -qtA -F' ' -c "
  SELECT residency_country, data_region FROM public.residency_admission
   WHERE admission_state = 'ADMITTED' ORDER BY residency_country LIMIT 1")"
[ -n "${REGION:-}" ] || fail "no ADMITTED residency exists; cannot seed a subject."

# NO SUBJECT FIXTURE. Nothing below needs one: obs.response_audit and
# safety.red_flag_event carry PSEUDONYMS (bytea, no foreign key), and obs.ai_call
# carries no subject at all. An app_user row was seeded here at first and made
# the gate un-re-runnable — app_user.auth_subject is UNIQUE, and a fixed
# auth_subject with a fresh uuid each run leaves an orphan the cleanup cannot
# find. The fix is not a cleverer cleanup; it is not seeding what nothing reads.
A=$(count "SELECT gen_random_uuid()")   # an audit id the fixtures hang from

# THE CLEANUP DELETED NOTHING, AND HAD NOT SINCE THIS FILE WAS WRITTEN.
#
# It used to run all six DELETEs in ONE `psql -c`, which is one transaction —
# and the fifth of them, `DELETE FROM public.response_audit_event`, is refused
# by forbid_mutation() because that log is append-only. The refusal aborted the
# transaction, so the other five rolled back too, and `2>&1 || true` swallowed
# the message. Every run of this gate left its whole fixture behind while
# reporting a clean cleanup.
#
# The event row genuinely cannot be deleted — that is the property §5 exists to
# prove — so it is not attempted. The rest are separate statements, and the one
# that is expected to be impossible is named rather than hidden in an `|| true`.
cleanup() {
  psql -qtA \
    -c "DELETE FROM safety.clinician_alert WHERE event_id IN (SELECT id FROM safety.red_flag_event WHERE audit_id = '$A');" \
    -c "DELETE FROM safety.red_flag_event  WHERE audit_id = '$A';" \
    -c "DELETE FROM obs.ai_call            WHERE audit_id = '$A';" \
    -c "DELETE FROM obs.response_content   WHERE audit_id = '$A';" \
    -c "DELETE FROM obs.response_audit     WHERE id = '$A';" >/dev/null 2>&1 || true
  # public.response_audit_event is deliberately NOT cleaned: it is append-only
  # and $A is a fresh uuid per run, so the rows are inert rather than in the way.
}
trap cleanup EXIT
cleanup

# THE REGION GOES ON THE CONNECTION. Since migration 047 the append-only log
# derives data_region from `app.current_region()` and refuses an append when the
# GUC is unset, exactly as obs.record_response_audit has since 044. §5 appends
# to it, so without this the gate dies at the fixture rather than at an
# assertion. $REGION was read above from residency_admission.
export PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c app.data_region=$REGION"

echo "R10f: constraint refusals against the real schema"

# ---------------------------------------------------------------------------
# §1. §4.0.3 — the model may RAISE a severity and may never LOWER one.
#
# obs.ai_call records what the model proposed and what was applied. A row whose
# applied severity is BELOW the proposed one on the RED_FLAG_PROPOSE channel is
# the model having talked the system down, which is the one direction §4.0.3
# forbids. clampSeverity enforces it in the application; this is the database
# refusing to store the result if it ever stops.
# ---------------------------------------------------------------------------
must_reject "§4.0.3 a model-lowered severity" "c_model_may_not_lower" "
  INSERT INTO obs.ai_call
    (id, audit_id, occurred_at, purpose, provider, model_version, prompt_version,
     input_tokens, output_tokens, latency_ms, outcome,
     proposed_severity, applied_severity, data_region)
  VALUES (gen_random_uuid(), NULL, now(), 'RED_FLAG_PROPOSE', 'anthropic',
          'test-model', 'v1', 1, 1, 1, 'OK', 'CRITICAL', 'MONITOR', '$REGION')"

# ---------------------------------------------------------------------------
# §2. §2.3.2 — Category C is disabled in v1, and 'disabled' means unstorable.
#
# The classifier must be able to NAME CLINICAL_DECISION (that is how §2.3.6
# catches it), so it exists in the enum. What it must never be is PERSISTED as
# the category of a response that went out.
# ---------------------------------------------------------------------------
must_reject "§2.3.2 a persisted CLINICAL_DECISION response" "c_category_c_disabled_v1" "
  INSERT INTO obs.response_audit
    (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
     agg_confidence, policy_version, model_version, prompt_version,
     cited_claim_ids, review_state, data_region)
  VALUES ('$A', sha256('x'::bytea), now(), 'CLINICAL_DECISION', 'c', 'NORMAL', 0.99,
          'pv', 'm', 'p', '{}', 'NOT_REQUIRED', '$REGION')"

# ---------------------------------------------------------------------------
# §3. §1.9.4 — the per-category confidence floors.
#
# INFORMATIONAL 0.65, DECISION_SUPPORT 0.70, CLINICAL_DECISION 0.85. A response
# published below its category's floor is an assertion made on evidence the DQE
# scored as insufficient. 0.50 is below every floor, so this row fails whichever
# category it claims — the test does not depend on which floor is which, only on
# the floors existing.
# ---------------------------------------------------------------------------
must_reject "§1.9.4 a DECISION_SUPPORT response below the confidence floor" "c_min_conf" "
  INSERT INTO obs.response_audit
    (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
     agg_confidence, policy_version, model_version, prompt_version,
     cited_claim_ids, review_state, data_region)
  VALUES ('$A', sha256('x'::bytea), now(), 'DECISION_SUPPORT', 'c', 'NORMAL', 0.50,
          'pv', 'm', 'p', '{}', 'NOT_REQUIRED', '$REGION')"

# ---------------------------------------------------------------------------
# §4. §4.0.2 — a red-flag EVENT is a thing that happened, not a thing that
#     didn't.
#
# NORMAL is the absence of a finding. Storing it as an event would fill the
# safety record with non-events and make every rate computed from that table
# (J3-4's metrics, RF6's SLA) meaningless. recordRedFlagEvent no-ops below
# MONITOR; this is the database saying the same thing.
# ---------------------------------------------------------------------------
must_reject "§4.0.2 a NORMAL-severity red-flag event" "c_event_at_least_monitor" "
  INSERT INTO safety.red_flag_event
    (id, audit_id, subject_pseudonym, session_pseudonym, occurred_at, severity,
     trigger_detail, action_taken, commercial_suppressed, first_byte_at, data_region)
  VALUES (gen_random_uuid(), NULL, sha256('u'::bytea), sha256('s'::bytea), now(),
          'NORMAL', '{}'::jsonb, 'NONE', false, now(), '$REGION')"

# ---------------------------------------------------------------------------
# §5. HP-RB-001 §4 — the append-only log is append-only.
#
# response_audit_event is the record of truth; obs.response_audit is a mutable
# projection derived from it (auditLog.ts's header). An UPDATE here is the one
# operation that would let a response's history be rewritten after the fact.
#
# TWO controls, and they fail differently: the GRANT stops the application role,
# and the trigger stops everyone the grant does not — including the owner, which
# is who this gate runs as.
#
# THIS COMMENT USED TO SAY "and both are checked". Only one was. Everything
# below §5 ran as the owner, so it exercised the trigger and never the grant,
# and HP-RB-001 §10's item 10 asks for the other one in as many words: "the test
# asserting UPDATE/DELETE on response_audit_event fail AS hp_app". §6 is that
# test. The comment claiming coverage it did not have is this repository's
# second recurring pattern — a control that reports success it did not achieve —
# in the one place nobody looks for it, a test's own header.
# ---------------------------------------------------------------------------
psql -v ON_ERROR_STOP=1 -q <<SQL
INSERT INTO obs.response_audit
  (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
   agg_confidence, policy_version, model_version, prompt_version, cited_claim_ids,
   review_state, data_region)
VALUES ('$A', sha256('r10f'::bytea), now(), 'INFORMATIONAL', 'c', 'NORMAL', 0.90,
        'pv', 'm', 'p', '{}', 'NOT_REQUIRED', '$REGION');
INSERT INTO public.response_audit_event (audit_id, kind, occurred_at, actor, payload)
VALUES ('$A', 'PUBLISHED', now(), 'system', '{"path":"r10f"}'::jsonb);
SQL

must_reject "HP-RB-001 §4 an UPDATE of the append-only log" "forbid_mutation" "
  UPDATE public.response_audit_event SET payload = '{\"path\":\"rewritten\"}'::jsonb
   WHERE audit_id = '$A'"

must_reject "HP-RB-001 §4 a DELETE from the append-only log" "forbid_mutation" "
  DELETE FROM public.response_audit_event WHERE audit_id = '$A'"

# The hash chain was populated by the trigger rather than by the insert above —
# an unchained row would make the log rewritable by replacement even with
# UPDATE and DELETE refused.
CHAINED=$(count "SELECT count(*) FROM public.response_audit_event
                  WHERE audit_id = '$A' AND row_hash IS NOT NULL")
[ "$CHAINED" = "1" ] || fail "the audit event has no row_hash; trg_audit_event_chain did not fire."
echo "  ok  HP-RB-001 §4 the row is hash-chained (row_hash present)"

# ---------------------------------------------------------------------------
# §6. The same two operations AS hp_app — HP-RB-001 §10, item 10.
#
# SET SESSION AUTHORIZATION rather than a second connection string, for the
# reason migrations-ci gives for every gate in this directory: migration 034
# gives these roles no password ("a password in a migration is a password in
# git"), so a gate that needed one could not run here at all.
#
# The refusal must be `permission denied`, NOT forbid_mutation. If hp_app's
# UPDATE were refused by the trigger, that would mean the grant had been widened
# and only the belt was holding — so this checks the braces specifically, and
# would fail if the two swapped places.
# ---------------------------------------------------------------------------
must_reject_as() {  # $1 = role, $2 = human name, $3 = expected text, $4 = SQL
  local out
  if out=$(psql -v ON_ERROR_STOP=1 -q -c "BEGIN; SET LOCAL SESSION AUTHORIZATION $1; $4; ROLLBACK;" 2>&1); then
    fail "$2: ACCEPTED as $1."
  fi
  grep -qi "$3" <<<"$out" || fail "$2: refused as $1, but not by '$3' — got: $(head -3 <<<"$out" | tr '\n' ' ')"
  echo "  ok  $2 (as $1: $3)"
}

must_reject_as hp_app "HP-RB-001 §10.10 an UPDATE of the log by the application role" \
  "permission denied" "
  UPDATE public.response_audit_event SET actor = 'tampered' WHERE audit_id = '$A'"

must_reject_as hp_app "HP-RB-001 §10.10 a DELETE from the log by the application role" \
  "permission denied" "
  DELETE FROM public.response_audit_event WHERE audit_id = '$A'"

# And the payload discipline, which is a CHECK and therefore belongs in this
# file. HP-RB-001 §3 forbids user text on the immutable log; the constraint is
# the last of the three controls that say so (the others are auditLog.ts's
# guard and migrations/test/rb001_payload_keys.mjs, which checks the whitelist
# the other two do not have). Driven to its refusal AS hp_app, because a
# constraint that only refuses the owner refuses nobody who matters.
must_reject_as hp_app "HP-RB-001 §3 a payload carrying user text" \
  "payload_no_pii" "
  INSERT INTO public.response_audit_event (audit_id, kind, occurred_at, actor, payload)
  VALUES ('$A', 'PUBLISHED', now(), 'system', '{\"user_text\":\"my chest hurts\"}'::jsonb)"

echo "R10f: all constraint refusals held."
