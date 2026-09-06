#!/usr/bin/env bash
# ============================================================================
# RF6 — clinician alert delivery, exercised end to end against the real schema.
#
# The schema contract tests (schema_contract.test.sql) prove the database
# refuses to record a delivery that did not happen. This script proves the
# other half: that the worker actually walks both paths, and that the honest
# outcome is reported rather than swallowed.
#
# It exists as a separate file rather than as CI yaml because a check that
# lives only in a workflow cannot be run locally, and the bug this closes was
# one where nobody had ever run the thing.
#
#   run 1  no roster        -> UNDELIVERABLE, worker exits 2, nothing stamped
#   run 2  roster + adapter -> DELIVERED,     worker exits 0, §4.0.7 stamped
#
# Env: the standard PG* vars (as migrations-ci sets them). Run after migrations
# have been applied.
# ============================================================================
set -euo pipefail

PGDATABASE="${PGDATABASE:-healthplus}"
export PGDATABASE
DB_URL="postgresql://${PGUSER:-postgres}:${PGPASSWORD:-postgres}@${PGHOST:-localhost}:${PGPORT:-5432}/${PGDATABASE}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "RF6 FAIL: $*" >&2; exit 1; }

# Every assertion below is scoped to alerts raised after this moment. A global
# assertion would be stricter, but one bad row left in a long-lived database —
# by an earlier experiment, a partial run, a negative control — would make this
# permanently red, and a check that is red for reasons nobody caused is a check
# somebody eventually deletes. The invariants themselves are enforced by
# migration 029's constraints, which ARE global and cannot be worked around;
# this script tests the worker's behaviour, so it scopes to the worker's own run.
# ISO-8601 with no spaces: a plain now() would be split by the whitespace
# trimming below into an unparseable literal that silently matches nothing.
RUN_FROM=$(psql -qtAc "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.USZ')" | tr -d '[:space:]')
SCOPE="a.raised_at >= '$RUN_FROM'::timestamptz"

# --- fixture -----------------------------------------------------------------
# A distinct region-local template version each time so this is re-runnable
# against a database a previous run already touched.
seed_event () {  # $1 = severity, $2 = 'roster' | 'noroster'
  psql -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$
DECLARE
  v_user uuid := gen_random_uuid();
  v_region char(2);
  v_tmpl uuid := gen_random_uuid();
  v_v int;
BEGIN
  SELECT code INTO v_region FROM public.region_registry LIMIT 1;
  SELECT coalesce(max(version), 0) + 1 INTO v_v
    FROM safety.safety_template
   WHERE severity = '$1' AND jurisdiction = v_region AND language = 'en';

  INSERT INTO principal.app_user (id, auth_subject, data_region)
  VALUES (v_user, 'rf6-ci-' || v_user::text, v_region);
  INSERT INTO principal.clinician (user_id, full_name, primary_jurisdiction)
  VALUES (v_user, 'RF6 CI clinician', v_region);
  INSERT INTO safety.safety_template
    (id, version, severity, jurisdiction, language, body, slots, approved_by, approved_at)
  VALUES (v_tmpl, v_v, '$1', v_region, 'en', 'RF6 CI fixture', '{}'::jsonb, v_user, now());

  IF '$2' = 'roster' THEN
    INSERT INTO safety.on_call_roster
      (id, clinician_id, data_region, min_severity, channel, address, effective_from)
    VALUES (gen_random_uuid(), v_user, v_region, 'URGENT', 'SMS',
            '+10000000000', now() - interval '1 day');
  END IF;

  INSERT INTO safety.red_flag_event
    (id, subject_pseudonym, session_pseudonym, occurred_at, severity, trigger_detail,
     template_id, template_version, action_taken, commercial_suppressed,
     first_byte_at, template_displayed_at, data_region)
  VALUES (gen_random_uuid(), gen_random_bytes(8), gen_random_bytes(8), now(), '$1',
          '{}'::jsonb, v_tmpl, v_v, 'TEMPLATE', true, now(), now(), v_region);
END \$\$;
SQL
}

count () { psql -qtAc "$1" | tr -d '[:space:]'; }

# ============================================================================
# RUN 1 — nobody on call. Today's real state.
# ============================================================================
echo "RF6 run 1: no roster entry"
psql -v ON_ERROR_STOP=1 -q -c "DELETE FROM safety.on_call_roster;"
seed_event EMERGENCY noroster

# The alert must already exist, raised by the trigger, before the worker runs.
[ "$(count "SELECT count(*) FROM safety.clinician_alert a WHERE a.state='PENDING' AND $SCOPE")" -ge 1 ] \
  || fail "the EMERGENCY event did not auto-raise a PENDING alert"

set +e
DATABASE_URL="$DB_URL" node chat-pipeline/worker/alert-worker.mjs --once
rc1=$?
set -e

[ "$rc1" -eq 2 ] || fail "worker exited $rc1 with nobody on call; expected 2. \
An alert that reached no one must not look like success — that is the exact \
defect RF6 closed (the old handler logged and marked the job DONE)."

[ "$(count "SELECT count(*) FROM safety.clinician_alert a WHERE a.state='UNDELIVERABLE' AND a.undeliverable_reason='NO_ROSTER_ENTRY' AND $SCOPE")" -ge 1 ] \
  || fail "no alert was recorded UNDELIVERABLE/NO_ROSTER_ENTRY"

stamped=$(count "SELECT count(*) FROM safety.red_flag_event e
                   JOIN safety.clinician_alert a ON a.event_id = e.id
                  WHERE a.state NOT IN ('DELIVERED','ACKNOWLEDGED')
                    AND e.clinician_notified_at IS NOT NULL AND $SCOPE")
[ "$stamped" -eq 0 ] \
  || fail "$stamped event(s) carry clinician_notified_at with no delivered alert"

echo "RF6 run 1 OK — undeliverable, reported, nothing falsely stamped"

# ============================================================================
# RUN 2 — someone on call, and a channel that works.
# ============================================================================
echo "RF6 run 2: roster entry on a delivering channel"
cat > "$TMP/adapter.mjs" <<'ADAPTER'
// Stands in for a real provider SDK. It only has to resolve; the database
// re-checks that SMS is a delivering channel before anything is recorded.
export default { SMS: async ({ address }) => { console.log('  [CI adapter] delivered to', address); } };
ADAPTER

before=$(count "SELECT count(*) FROM safety.clinician_alert a WHERE a.state='DELIVERED' AND $SCOPE")
seed_event EMERGENCY roster

set +e
DATABASE_URL="$DB_URL" ALERT_CHANNEL_MODULE="$TMP/adapter.mjs" \
  node chat-pipeline/worker/alert-worker.mjs --once
rc2=$?
set -e

[ "$rc2" -eq 0 ] || fail "worker exited $rc2 with a working channel; expected 0"

after=$(count "SELECT count(*) FROM safety.clinician_alert a WHERE a.state='DELIVERED' AND $SCOPE")
[ "$after" -gt "$before" ] || fail "no alert moved to DELIVERED"

unstamped=$(count "SELECT count(*) FROM safety.clinician_alert a
                     JOIN safety.red_flag_event e ON e.id = a.event_id
                    WHERE a.state = 'DELIVERED' AND e.clinician_notified_at IS NULL AND $SCOPE")
[ "$unstamped" -eq 0 ] \
  || fail "$unstamped DELIVERED alert(s) did not stamp red_flag_event.clinician_notified_at. \
RF6 has traded a false positive for a false negative: a real page would now go unrecorded."

noid=$(count "SELECT count(*) FROM safety.clinician_alert a
                JOIN safety.red_flag_event e ON e.id = a.event_id
               WHERE a.state = 'DELIVERED' AND e.clinician_id IS NULL AND $SCOPE")
[ "$noid" -eq 0 ] || fail "§4.0.7 clinician identity was not recorded on delivery"

echo "RF6 run 2 OK — delivered, §4.0.7 stamped with clinician identity"
echo "RF6: both outcomes verified against the real schema."
