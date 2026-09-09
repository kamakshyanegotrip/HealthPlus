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

cleanup() {
  psql -qtA -c "
    DELETE FROM safety.clinician_alert    WHERE event_id IN (SELECT id FROM safety.red_flag_event WHERE audit_id = '$A');
    DELETE FROM safety.red_flag_event     WHERE audit_id = '$A';
    DELETE FROM obs.ai_call               WHERE audit_id = '$A';
    DELETE FROM public.response_audit_event WHERE audit_id = '$A';
    DELETE FROM obs.response_content      WHERE audit_id = '$A';
    DELETE FROM obs.response_audit        WHERE id = '$A';" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

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
     cited_claim_ids, review_state)
  VALUES ('$A', sha256('x'::bytea), now(), 'CLINICAL_DECISION', 'c', 'NORMAL', 0.99,
          'pv', 'm', 'p', '{}', 'NOT_REQUIRED')"

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
     cited_claim_ids, review_state)
  VALUES ('$A', sha256('x'::bytea), now(), 'DECISION_SUPPORT', 'c', 'NORMAL', 0.50,
          'pv', 'm', 'p', '{}', 'NOT_REQUIRED')"

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
# TWO controls, and both are checked, because they fail differently: the GRANT
# stops the application role, and the trigger stops everyone the grant does not
# — including the owner, which is who this gate runs as. Checking only the grant
# would leave the owner path untested, and the owner path is the one a
# migration or an operator uses.
# ---------------------------------------------------------------------------
psql -v ON_ERROR_STOP=1 -q <<SQL
INSERT INTO obs.response_audit
  (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
   agg_confidence, policy_version, model_version, prompt_version, cited_claim_ids, review_state)
VALUES ('$A', sha256('r10f'::bytea), now(), 'INFORMATIONAL', 'c', 'NORMAL', 0.90,
        'pv', 'm', 'p', '{}', 'NOT_REQUIRED');
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

echo "R10f: all constraint refusals held."
