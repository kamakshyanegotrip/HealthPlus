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

# RUN 3 SEEDS TWO PERMANENT BREACHES, and they must not outlive this process.
# Both are alerts deliberately aged past their deadlines, so a leftover one is a
# breach for ever — and the next run's run 2, which asserts the worker exits 0,
# would fail on a condition the previous run created. Found by running this gate
# twice against one database, which is the thing its own header promises works.
#
# In the trap rather than at the end of run 3: a failure between seeding and
# cleanup is exactly when the next run must not inherit them.
AGED_ALERTS=""
ALT_REGION=""
cleanup() {
  rm -rf "$TMP"
  [ -n "$AGED_ALERTS" ] && psql -qtA -c "
    DELETE FROM safety.clinician_alert WHERE id IN ($AGED_ALERTS)" >/dev/null 2>&1
  # AND THE FOREIGN REGION ITSELF, in FK order.
  #
  # Leaving it behind would not be untidy, it would be a regression: three other
  # gates and migrations 034/037 still pick a region with
  # ORDER BY active_from LIMIT 1, and a permanent extra region dated before IN's
  # 2026-08-29 changes what they select. j34_metrics.sh runs after this gate in
  # CI and would start seeding into it. So run 3's region lives exactly as long
  # as run 3 does.
  if [ -n "$ALT_REGION" ]; then
    psql -qtA -c "
      DELETE FROM safety.clinician_alert  WHERE data_region = '$ALT_REGION';
      DELETE FROM safety.red_flag_event   WHERE data_region = '$ALT_REGION';
      DELETE FROM safety.on_call_roster   WHERE data_region = '$ALT_REGION';
      DELETE FROM safety.safety_template  WHERE jurisdiction = '$ALT_REGION';
      DELETE FROM principal.clinician     WHERE primary_jurisdiction = '$ALT_REGION';
      DELETE FROM principal.app_user      WHERE data_region = '$ALT_REGION';
      DELETE FROM public.region_registry  WHERE code = '$ALT_REGION';" >/dev/null 2>&1
  fi
  return 0
}
trap cleanup EXIT

fail() { echo "RF6 FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# THE REGION COMES FROM THE WORKER, NOT FROM region_registry.
#
# THIRD OCCURRENCE OF ONE BUG. rf6_claim.sh carried it, key_mint.sh was written
# with it three PRs later, and both were fixed by stating the rule: A GATE MUST
# DERIVE ITS FIXTURES FROM THE TABLE THAT DEFINES ITS OWN PRECONDITION. This
# file kept it, and the reason it kept it is worth more than the fix: IT IS
# CORRECT IN CI'S CURRENT STEP ORDER AND ONLY IN THAT ORDER. This gate runs at
# step 5; sec1_region_context.sh, which seeds the region it collides with, runs
# at step 11. Nothing declares that dependency, nothing enforces it, and
# reordering two steps in a YAML file would have broken the §4.1 alert gate for
# a reason nobody would have looked for in a workflow diff.
#
# The collision, in any other order: sec1_region_context.sh seeds region EU with
# active_from = 2026-01-01 and leaves it there deliberately — a region-isolation
# test needs a second region to be isolated from. IN's active_from is
# 2026-08-29. So `ORDER BY active_from LIMIT 1` returns EU, this gate seeds its
# alert into EU, and the worker — started with DATA_REGION=IN — claims nothing:
#
#     alert-worker: drained 0 alert(s) — 0 delivered, 0 undeliverable
#     RF6 FAIL: no alert was recorded UNDELIVERABLE/NO_ROSTER_ENTRY
#
# THIS GATE'S PRECONDITION IS THE WORKER'S OWN REGION. The whole subject is
# "does the worker claim and deliver", migration 035 made claim_alert_batch
# region-scoped, and the worker's region is DATA_REGION. So that is where the
# fixture region comes from, and a mismatch is now impossible rather than
# ordering-dependent.
#
# sec1's EU row is deliberately NOT cleaned up in response to this. Making the
# producer tidy would hide the class and leave the next consumer to rediscover
# it; making each consumer name its own precondition is the fix that holds.
# ---------------------------------------------------------------------------
REGION="${DATA_REGION:-}"
[ -n "$REGION" ] || fail "DATA_REGION is not set. The worker refuses to start without it
(migration 035 scopes claim_alert_batch by region), so this gate cannot seed an
alert the worker would claim. Set it to the region the worker will run in."

ok=$(psql -qtAc "SELECT count(*) FROM public.region_registry
                  WHERE code = '$REGION' AND code <> 'ZZ' AND active_to IS NULL" | tr -d '[:space:]')
[ "$ok" = "1" ] || fail "DATA_REGION=$REGION is not an active region in region_registry.
An alert seeded there could never be claimed, and the gate would fail for a
reason that has nothing to do with the worker."

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
seed_event () {  # $1 = severity, $2 = 'roster'|'noroster', $3 = region (default: the worker's)
  local SEED_REGION="${3:-$REGION}"
  psql -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$
DECLARE
  v_user uuid := gen_random_uuid();
  v_region char(2);
  v_tmpl uuid := gen_random_uuid();
  v_v int;
BEGIN
  -- THE WORKER'S REGION, passed in from the shell. See the block above the
  -- fixture for why this is not a region_registry lookup: it was
  -- ORDER BY active_from LIMIT 1, which is correct alone and picks up
  -- sec1_region_context.sh's EU fixture the moment the gates run together.
  --
  -- (An earlier fix here removed the ZZ sentinel — migration 019's "reference
  -- data, no data subject" region — which physical order had been returning
  -- first. Taking the region from DATA_REGION supersedes that too: ZZ is never
  -- a region a worker runs in.)
  v_region := '$SEED_REGION';
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

# ============================================================================
# RUN 3 — THE SLA BREACH REPORT STOPS AT THE REGION BOUNDARY.
#
# This section exists because the fix it guards made the worker report LESS,
# and a change that narrows what a safety worker reports is exactly the change
# that must be pinned in both directions. reportBreaches() used to read
# safety.v_alert_sla_breach unfiltered while claim_alert_batch was
# region-scoped, so a worker deployed for one region paged on — and exited 2
# for — every other region's breaches, and printed their alert and event ids
# into its operator's log.
#
# Both directions, because "scoped correctly" and "scoped to nothing" produce
# the same output on a one-sided test:
#
#   a foreign-region breach  ->  NOT reported, and does not force exit 2
#   an own-region breach     ->  reported, and DOES force exit 2
#
# The second is the one that matters. A worker that silently stopped reporting
# its own breaches would be the original RF6 defect restored — an alert that
# reached nobody looking like success.
# ============================================================================
echo "RF6 run 3: SLA breach reporting is region-scoped, in both directions"

# BOTH FIXTURES ARE UNCLAIMABLE BY THIS RUN, deliberately, so the exit code
# below can only be about the breach report:
#
#   the foreign one  PENDING in region $ALT — claim_alert_batch is region-scoped
#                    (migration 035) so a $REGION worker cannot touch it
#   the own one      the alert run 2 already DELIVERED, with its ack_deadline
#                    pushed into the past: NOT_ACKNOWLEDGED, and nothing left to
#                    claim
#
# If either were claimable, the worker would resolve it in the same pass and the
# exit code would be about delivery rather than about reporting.
ALT=XC   # this gate's own; rf6_claim.sh owns XA, sec1_region_context.sh owns EU

# active_from IS DELIBERATELY FAR IN THE FUTURE. The cleanup trap removes this
# region, but a run killed between here and the trap would leave it behind, and
# a region dated before IN's 2026-08-29 would then change what every
# ORDER BY active_from LIMIT 1 consumer selects. Dated 2099 it can never win
# that ordering, so the worst case of a failed cleanup is a stray row rather
# than another gate quietly seeding into the wrong region.
psql -v ON_ERROR_STOP=1 -q -c "
  INSERT INTO region_registry (code, legal_basis, primary_regime, active_from)
  VALUES ('$ALT', 'RF6 fixture — a foreign region whose breaches must stay foreign',
          'NONE', date '2099-01-01')
  ON CONFLICT (code) DO NOTHING"
ALT_REGION="$ALT"

seed_event EMERGENCY noroster "$ALT"
# AGED, not just deadline-moved: c_deadlines_ordered requires
# raised_at <= notify_deadline <= ack_deadline, so a breach has to be a whole
# alert shifted into the past rather than a deadline dragged behind its own
# alert. The id is captured through $SCOPE first, because aging raised_at is
# precisely what takes the row back out of that scope.
foreign_alert=$(count "SELECT a.id FROM safety.clinician_alert a
                        WHERE a.data_region = '$ALT' AND a.state = 'PENDING' AND $SCOPE
                        ORDER BY a.raised_at DESC LIMIT 1")
[ -n "$foreign_alert" ] || fail "seed_event did not raise a PENDING alert in region $ALT"
psql -v ON_ERROR_STOP=1 -q -c "
  UPDATE safety.clinician_alert
     SET raised_at       = now() - interval '3 days',
         notify_deadline = now() - interval '2 days',
         ack_deadline    = now() - interval '1 day'
   WHERE id = '$foreign_alert'"
AGED_ALERTS="'$foreign_alert'"
set +e
out3=$(DATABASE_URL="$DB_URL" ALERT_CHANNEL_MODULE="$TMP/adapter.mjs" \
         node chat-pipeline/worker/alert-worker.mjs --once 2>&1)
rc3=$?
set -e

echo "$out3" | grep -q "$foreign_alert" \
  && fail "the worker (DATA_REGION=$REGION) printed region $ALT's alert $foreign_alert.
safety.v_alert_sla_breach is not region-scoped and reportBreaches must be, or a
worker leaks another region's alert ids into its own operator's log — the same
boundary SEC-1 and migration 032 exist to hold."
[ "$rc3" -eq 0 ] || fail "the worker exited $rc3 with nothing wrong in its OWN region ($REGION).
A foreign region's breach must not hold this worker at a failing exit code: it
cannot claim, deliver or acknowledge that alert. Output was:
$out3"
echo "  a breach in $ALT is neither reported nor exit-coded by a $REGION worker"

# The same shape in the worker's OWN region, which must still page. Without this
# half, a filter scoped to NOTHING passes the check above — and that is the RF6
# defect restored: an alert that reached no one looking like success.
own_alert=$(count "SELECT a.id FROM safety.clinician_alert a
                    WHERE a.data_region = '$REGION' AND a.state = 'DELIVERED' AND $SCOPE
                    ORDER BY a.raised_at DESC LIMIT 1")
[ -n "$own_alert" ] || fail "run 2 left no DELIVERED alert in $REGION to age into a breach"
psql -v ON_ERROR_STOP=1 -q -c "
  UPDATE safety.clinician_alert
     SET raised_at       = now() - interval '3 days',
         notify_deadline = now() - interval '2 days',
         ack_deadline    = now() - interval '1 day'
   WHERE id = '$own_alert'"
AGED_ALERTS="$AGED_ALERTS,'$own_alert'"

set +e
out4=$(DATABASE_URL="$DB_URL" ALERT_CHANNEL_MODULE="$TMP/adapter.mjs" \
         node chat-pipeline/worker/alert-worker.mjs --once 2>&1)
rc4=$?
set -e

echo "$out4" | grep -q "$own_alert" \
  || fail "the worker did NOT report its OWN region's breached alert $own_alert.
This is the region filter scoped to nothing — indistinguishable from a correct
filter on a one-sided test. Output was:
$out4"
[ "$rc4" -eq 2 ] || fail "the worker exited $rc4 with an unacknowledged alert open in its own
region; expected 2. An alert that reached no one must not look like success."
echo "  a breach in $REGION IS reported and DOES hold the worker at exit 2"

echo "RF6: both outcomes verified against the real schema, and the breach report stops at the region."
