#!/usr/bin/env bash
# ============================================================================
# J3-4 — §6.5 safety metrics, exercised end to end against the real schema.
#
# Two things are being proved, and the second is the one that matters:
#
#   1. The four computable metrics actually compute, from real rows, to the
#      numbers a hand calculation gives. A metrics module nobody has run
#      against real tables is how "we have metrics" becomes a claim rather
#      than a fact — which is what J3-4 was.
#
#   2. The two release-gating metrics are recorded UNCOMPUTABLE and the gate
#      says BLOCK. §6.4 makes a red-flag recall regression a release blocker;
#      a gate that only blocks on a MEASURED regression passes when recall is
#      unmeasured, which is today. The less it knows, the more confident it
#      would be.
#
# Env: standard PG* vars. Run after migrations have been applied.
# ============================================================================
set -euo pipefail

PGDATABASE="${PGDATABASE:-healthplus}"
export PGDATABASE
DB_URL="postgresql://${PGUSER:-postgres}:${PGPASSWORD:-postgres}@${PGHOST:-localhost}:${PGPORT:-5432}/${PGDATABASE}"

fail() { echo "J3-4 FAIL: $*" >&2; exit 1; }
count () { psql -qtAc "$1" | tr -d '[:space:]'; }

# ----------------------------------------------------------------------------
# Fixture. One day's worth of traffic, with numbers chosen so every expected
# value is checkable by hand:
#
#   10 audited responses  = 7 plain + the 3 that carry a review queue item.
#                            (The first draft made this 10 + 3 and expected a
#                            denominator of 10; the view was right and the
#                            arithmetic was wrong. Kept at 10 so every expected
#                            value below is checkable in your head.)
#    3 fabrication blocks, all class 3.1   -> block_rate 3.1 = 3/10 = 0.3
#    2 abstention events, reason NO_SOURCE -> abstention_rate NO_SOURCE = 0.2
#    3 decided reviews at 1h, 2h, 6h       -> median turnaround = 2h
#    3 EMERGENCY scans at 100/200/900 ms   -> p95 (discrete) = 900
# ----------------------------------------------------------------------------
DAY=$(psql -qtAc "SELECT to_char(date_trunc('day', now()) - interval '1 day', 'YYYY-MM-DD')" | tr -d '[:space:]')
echo "J3-4 fixture: seeding one day of traffic ($DAY)"

psql -v ON_ERROR_STOP=1 -q <<'SQL'
DO $$
DECLARE
  v_region char(2);
  v_user   uuid := gen_random_uuid();
  v_day    timestamptz := date_trunc('day', now()) - interval '1 day';
  v_audit  uuid;
  v_domain text;
  v_tmpl   uuid := gen_random_uuid();
  v_event  uuid;
  v_v      int;
  i int;
  ms int[] := ARRAY[100, 200, 900];
  hrs int[] := ARRAY[1, 2, 6];
BEGIN
  SELECT code INTO v_region FROM public.region_registry LIMIT 1;
  SELECT code INTO v_domain FROM safety.clinical_domain LIMIT 1;

  INSERT INTO principal.app_user (id, auth_subject, data_region)
  VALUES (v_user, 'j34-' || v_user::text, v_region);
  INSERT INTO principal.clinician (user_id, full_name, primary_jurisdiction)
  VALUES (v_user, 'J3-4 fixture clinician', v_region);

  -- 7 plain audited responses. With the 3 review-carrying ones below, the
  -- denominator for both ratio metrics is 10.
  FOR i IN 1..7 LOOP
    INSERT INTO obs.response_audit
      (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
       agg_confidence, policy_version, model_version, prompt_version,
       cited_claim_ids, review_state, row_hash)
    VALUES (gen_random_uuid(), gen_random_bytes(8), v_day + (i || ' minutes')::interval,
            'INFORMATIONAL', 'j34-fixture', 'NORMAL',
            0.70, 'p1', 'm1', 'pr1', '{}', 'NOT_REQUIRED', gen_random_bytes(8));
  END LOOP;

  -- 3 blocks, all §3.1 -> 3/10
  FOR i IN 1..3 LOOP
    INSERT INTO obs.fabrication_block
      (id, occurred_at, prohibition_class, category, query_hash,
       retrieved_source_state, data_region)
    VALUES (gen_random_uuid(), v_day + (i || ' minutes')::interval, '3.1',
            'INFORMATIONAL', gen_random_bytes(8), '{}'::jsonb, v_region);
  END LOOP;

  -- 2 abstentions, reason NO_SOURCE -> 2/10
  FOR i IN 1..2 LOOP
    INSERT INTO obs.abstention_event
      (id, occurred_at, reason, category, data_region)
    VALUES (gen_random_uuid(), v_day + (i || ' minutes')::interval, 'NO_SOURCE',
            'INFORMATIONAL', v_region);
  END LOOP;

  -- 3 decided reviews at 1h, 2h, 6h -> median 2h
  FOR i IN 1..3 LOOP
    INSERT INTO obs.response_audit
      (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
       agg_confidence, policy_version, model_version, prompt_version,
       cited_claim_ids, review_state, row_hash)
    VALUES (gen_random_uuid(), gen_random_bytes(8), v_day, 'INFORMATIONAL',
            -- NOT_REQUIRED, not APPROVED: §2.3.4b's assert_reviewer_in_scope()
            -- refuses an approval without a named, registered reviewer, and
            -- this fixture is measuring queue turnaround, not review validity.
            'j34-fixture', 'NORMAL', 0.70, 'p1', 'm1', 'pr1', '{}', 'NOT_REQUIRED',
            gen_random_bytes(8))
    RETURNING id INTO v_audit;

    INSERT INTO obs.review_queue_item
      (id, audit_id, reason, clinical_domain, enqueued_at, claimed_by, claimed_at,
       decided_at, decision, data_region)
    VALUES (gen_random_uuid(), v_audit, 'j34-fixture', v_domain,
            v_day, v_user, v_day,
            v_day + (hrs[i] || ' hours')::interval, 'APPROVED', v_region);
  END LOOP;

  -- 3 EMERGENCY scans at 100/200/900 ms -> discrete p95 = 900.
  --
  -- c_monitor_has_event requires every MONITOR+ log row to name a real
  -- red_flag_event, and (since migration 029) each of those raises a
  -- clinician_alert. So this fixture necessarily exercises the RF6 path too,
  -- which is correct: an EMERGENCY that produced no event and no alert is not
  -- a latency sample worth having.
  SELECT coalesce(max(version), 0) + 1 INTO v_v
    FROM safety.safety_template
   WHERE severity = 'EMERGENCY' AND jurisdiction = v_region AND language = 'en';
  INSERT INTO safety.safety_template
    (id, version, severity, jurisdiction, language, body, slots, approved_by, approved_at)
  VALUES (v_tmpl, v_v, 'EMERGENCY', v_region, 'en', 'J3-4 fixture', '{}'::jsonb, v_user, now());

  FOR i IN 1..3 LOOP
    v_event := gen_random_uuid();
    INSERT INTO safety.red_flag_event
      (id, subject_pseudonym, session_pseudonym, occurred_at, severity, trigger_detail,
       template_id, template_version, action_taken, commercial_suppressed,
       first_byte_at, template_displayed_at, data_region)
    VALUES (v_event, gen_random_bytes(8), gen_random_bytes(8),
            v_day + (i || ' minutes')::interval, 'EMERGENCY', '{}'::jsonb,
            v_tmpl, v_v, 'TEMPLATE', true, v_day, v_day, v_region);

    INSERT INTO safety.red_flag_log
      (id, event_id, subject_pseudonym, session_pseudonym, occurred_at,
       rule_derived_severity, applied_severity, context_escalation,
       matched_rule_ids, trigger_detail, query_hash, branch,
       commercial_suppressed, generation_blocked, needs_review, shadow_mode,
       first_byte_at, scanner_started_at, scanner_completed_at,
       template_id, template_version,
       template_displayed_at, display_latency_ms, scanner_version, data_region)
    VALUES (gen_random_uuid(), v_event, gen_random_bytes(8), gen_random_bytes(8),
            v_day + (i || ' minutes')::interval,
            'EMERGENCY', 'EMERGENCY', '{}', '{}', '{}'::jsonb,
            gen_random_bytes(8), 'TEMPLATE_TAKEOVER',
            true, true, false, false,
            v_day, v_day, v_day,
            v_tmpl, v_v,
            v_day, ms[i], 'j34-fixture', v_region);
  END LOOP;
END $$;

-- A QUIET DAY: audited traffic, zero blocks, zero abstentions. Two days back,
-- so it does not disturb the hand-checked numbers above. This is the case the
-- first version of these views could not express at all — an inner join
-- produced no row, and "no row" reads the same as "the job did not run".
DO $$
DECLARE v_region char(2); v_quiet timestamptz := date_trunc('day', now()) - interval '2 days'; i int;
BEGIN
  SELECT code INTO v_region FROM public.region_registry LIMIT 1;
  FOR i IN 1..5 LOOP
    INSERT INTO obs.response_audit
      (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
       agg_confidence, policy_version, model_version, prompt_version,
       cited_claim_ids, review_state, row_hash)
    VALUES (gen_random_uuid(), gen_random_bytes(8), v_quiet + (i || ' minutes')::interval,
            'INFORMATIONAL', 'j34-fixture', 'NORMAL',
            0.70, 'p1', 'm1', 'pr1', '{}', 'NOT_REQUIRED', gen_random_bytes(8));
  END LOOP;
END $$;
SQL

# ----------------------------------------------------------------------------
# Run the job.
# ----------------------------------------------------------------------------
set +e
DATABASE_URL="$DB_URL" node src/jobs/computeSafetyMetrics.mjs --days 3
rc=$?
set -e

# Exit 2 is the CORRECT outcome: two release-gating metrics are unmeasurable.
# Exit 0 here would mean the gate believes recall is known.
[ "$rc" -eq 2 ] || fail "metrics job exited $rc; expected 2. \
Two of the six §6.5 metrics gate a release under §6.4 and neither can be \
measured — a job that exits 0 is claiming otherwise."

# ----------------------------------------------------------------------------
# The four computable metrics produced the numbers a hand calculation gives.
# ----------------------------------------------------------------------------
check () {  # $1 metric_key, $2 dimension-or-NULL, $3 expected value, $4 label
  local dimpred
  if [ "$2" = "NULL" ]; then dimpred="dimension IS NULL"; else dimpred="dimension = '$2'"; fi
  local got
  got=$(count "SELECT value FROM obs.safety_metric_sample
                WHERE metric_key='$1' AND $dimpred AND status='COMPUTED'
                ORDER BY window_end DESC LIMIT 1")
  [ -n "$got" ] || fail "$4: no COMPUTED sample for $1${2:+ / $2}"
  local ok
  ok=$(count "SELECT abs($got::numeric - $3::numeric) < 0.0001")
  [ "$ok" = "t" ] || fail "$4: expected $3, got $got"
  echo "  $4: $got"
}

check block_rate                       3.1        0.3   "block rate §3.1 = 3 blocks / 10 responses"
check abstention_rate                  NO_SOURCE  0.2   "abstention rate NO_SOURCE = 2 / 10"
check review_turnaround_h              NULL       2.0   "review turnaround median = 2h of 1/2/6"
check emergency_display_latency_ms_p95 EMERGENCY  900   "emergency display latency p95 = 900ms"

# ----------------------------------------------------------------------------
# THE QUIET DAY. Five audited responses, no blocks, no abstentions.
#
# Both must be a COMPUTED 0.0 over a denominator of 5 — not a missing row, and
# not NO_DATA. §3.0.4 makes abstention a positive metric; a positive metric
# that vanishes when it hits zero cannot tell you the system has stopped
# saying "I don't know".
# ----------------------------------------------------------------------------
quiet_start=$(psql -qtAc "SELECT to_char(date_trunc('day', now()) - interval '2 days', 'YYYY-MM-DD')" | tr -d '[:space:]')
for m in block_rate abstention_rate; do
  row=$(count "SELECT status||'/'||coalesce(value::text,'-')||'/'||coalesce(denominator::text,'-')
                 FROM obs.safety_metric_sample
                WHERE metric_key='$m' AND dimension IS NULL
                  AND window_start = '$quiet_start'::timestamptz")
  [ "$row" = "COMPUTED/0.000000/5" ] \
    || fail "quiet day: $m totals should be COMPUTED 0.000000 over 5, got '${row:-<no row>}'. \
A day with real traffic and zero events is a measurement of zero, not an absence."
done
echo "  quiet day: block_rate and abstention_rate both COMPUTED 0.0 over 5 responses"

# ----------------------------------------------------------------------------
# The two blocked metrics: recorded, UNCOMPUTABLE, with a reason, and NOT zero.
# ----------------------------------------------------------------------------
for m in red_flag_recall fabrication_rate_adversarial; do
  n=$(count "SELECT count(*) FROM obs.safety_metric_sample
              WHERE metric_key='$m' AND status='UNCOMPUTABLE'
                AND uncomputable_reason IS NOT NULL")
  [ "$n" -ge 1 ] || fail "$m was not recorded UNCOMPUTABLE with a reason"

  bad=$(count "SELECT count(*) FROM obs.safety_metric_sample
                WHERE metric_key='$m' AND value IS NOT NULL")
  [ "$bad" -eq 0 ] \
    || fail "$m carries a numeric value. There is no gold set and no adversarial \
suite; any number here is invented, and a recall of 1.0 is the most dangerous \
number in this system."
done
echo "  red_flag_recall / fabrication_rate_adversarial: UNCOMPUTABLE, reasoned, no number"

# ----------------------------------------------------------------------------
# §6.4 — the gate blocks, and blocks for the right reason.
# ----------------------------------------------------------------------------
blocking=$(count "SELECT count(*) FROM obs.v_release_gate WHERE verdict='BLOCK'")
[ "$blocking" -eq 2 ] \
  || fail "expected 2 release-gating metrics to BLOCK, got $blocking. \
A passing gate is a claim that red-flag recall is known."

passing=$(count "SELECT count(*) FROM obs.v_release_gate WHERE verdict='PASS'")
[ "$passing" -eq 0 ] || fail "$passing release-gating metric(s) PASS with no gold set"

echo "  release gate (§6.4): BLOCK on both gating metrics, as it must"

# ----------------------------------------------------------------------------
# Idempotence. The job runs on a schedule; a second run over the same window
# must update the series, not duplicate it.
# ----------------------------------------------------------------------------
before=$(count "SELECT count(*) FROM obs.safety_metric_sample")
set +e; DATABASE_URL="$DB_URL" node src/jobs/computeSafetyMetrics.mjs --days 3 >/dev/null 2>&1; set -e
after=$(count "SELECT count(*) FROM obs.safety_metric_sample")
[ "$before" -eq "$after" ] \
  || fail "a second run over the same window added $((after-before)) row(s); the series must be idempotent"
echo "  second run over the same window: $after samples, unchanged"

echo "J3-4: four metrics computed from real rows; two recorded unmeasurable; gate blocks."
