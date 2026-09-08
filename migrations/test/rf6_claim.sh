#!/usr/bin/env bash
# ============================================================================
# RF6-claim — the alert worker can claim a batch, and only its own region's.
#
# R13-roleci found, on its first run, that alert-worker.mjs:129 fails as
# alert_role: `SELECT ... FOR UPDATE` needs UPDATE, which that role deliberately
# does not hold. Migration 035 moves the claim into a SECURITY DEFINER function.
#
# THIS GATE EXISTS BECAUSE THE FIX HAS A TRAP IN IT. safety.clinician_alert
# carries RLS scoped to the caller's region, the table is owned by postgres, and
# it is not FORCE ROW LEVEL SECURITY — so a DEFINER function runs with RLS NOT
# APPLIED. A wrapper that merely lifted the query would fix the permission error
# and silently hand the worker every region's alerts. Section 3 is that control.
#
# Sections 1 and 4 are the other two directions: the privilege must not have
# been widened, and a connection with no region must FAIL rather than report
# healthy empty batches — the SEC-1 failure mode, on the §4.1 emergency path.
#
# Env: standard PG* vars, as the owner. Run after migrations have been applied.
# Re-runnable: every fixture is scoped to this run and dropped in a trap.
# ============================================================================
set -euo pipefail
PGDATABASE="${PGDATABASE:-healthplus}"
export PGDATABASE
fail() { echo "RF6-claim FAIL: $*" >&2; exit 1; }
count() { psql -qtAc "$1" | tr -d '[:space:]'; }

# THE REGION IS READ FROM alert_role'S OWN LOGIN DEFAULT, not from the registry.
#
# An earlier draft took `code FROM region_registry ... ORDER BY active_from
# LIMIT 1`. That is what migration 034 §3 does, so it looked right — and it made
# this gate's answer depend on what OTHER gates had left in the table.
# sec1_region_context.sh seeds a second region to demonstrate the boundary, with
# an active_from that sorts FIRST, so on any run after it this gate silently
# adopted that region as "its own" and treated the real one as the foreign one.
# Its cleanup would then have deleted the admitted region from region_registry.
#
# The deployment truth for this worker is the per-role default 034 §3 installed,
# so that is what is read — and its absence is a failure here at the top rather
# than a puzzle two hundred lines down, because every later assertion depends on
# it. This also removes the coupling: nothing this gate does depends on what
# another gate left behind.
REGION=$(count "SELECT substring(x FROM 'app.data_region=(.*)') FROM pg_db_role_setting s
                  JOIN pg_roles r ON r.oid = s.setrole
                  JOIN pg_database d ON d.oid = s.setdatabase, unnest(s.setconfig) x
                 WHERE r.rolname='alert_role' AND d.datname = current_database()
                   AND x LIKE 'app.data_region=%'")
[ -n "$REGION" ] || fail "alert_role has no app.data_region default in this database.
Migration 034 §3 sets it, and without it a real worker login arrives with no
region — so migration 035's exception becomes the worker's steady state rather
than its guard, and nothing below this line would mean anything."

# A code no other gate uses and no migration seeds. 'EU' was the obvious choice
# and is exactly the wrong one: sec1_region_context.sh already uses it, and two
# gates sharing a demonstration fixture is how the bug above happened. XA is in
# the ISO 3166 user-assigned range, so it can never collide with a real one.
ALT=XA
ALT_INSERTED=no

FIFO=$(mktemp -u); BGPID=""
cleanup() {
  [ -n "$BGPID" ] && kill "$BGPID" 2>/dev/null || true
  rm -f "$FIFO" 2>/dev/null || true
  # The second region is a demonstration fixture, not a seeded region. ADR-004
  # §2 admits exactly one, and a gate that left a second behind would make the
  # next run of every region-scoped check measure a different system.
  psql -qtA -c "DELETE FROM safety.clinician_alert a USING safety.red_flag_event e
                 WHERE e.id = a.event_id AND e.trigger_detail ? 'rf6_claim_ci';
                DELETE FROM safety.red_flag_event WHERE trigger_detail ? 'rf6_claim_ci';
                DELETE FROM safety.safety_template WHERE body = 'RF6-claim CI fixture';
                DELETE FROM principal.clinician WHERE full_name = 'RF6-claim CI clinician';
                DELETE FROM principal.app_user WHERE auth_subject LIKE 'rf6claim-ci-%';
                DELETE FROM public.region_registry WHERE code = '$ALT' AND '$ALT_INSERTED' = 'yes';" >/dev/null 2>&1 || true
}
trap cleanup EXIT

seed_alert () {  # $1 = region
  psql -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$
DECLARE
  v_user uuid := gen_random_uuid();
  v_tmpl uuid := gen_random_uuid();
  v_v int;
BEGIN
  SELECT coalesce(max(version), 0) + 1 INTO v_v
    FROM safety.safety_template
   WHERE severity = 'EMERGENCY' AND jurisdiction = '$1' AND language = 'en';

  INSERT INTO principal.app_user (id, auth_subject, data_region)
  VALUES (v_user, 'rf6claim-ci-' || v_user::text, '$1');
  INSERT INTO principal.clinician (user_id, full_name, primary_jurisdiction)
  VALUES (v_user, 'RF6-claim CI clinician', '$1');
  INSERT INTO safety.safety_template
    (id, version, severity, jurisdiction, language, body, slots, approved_by, approved_at)
  VALUES (v_tmpl, v_v, 'EMERGENCY', '$1', 'en', 'RF6-claim CI fixture', '{}'::jsonb, v_user, now());

  -- The alert is raised by 029's trigger on this insert; it is never inserted
  -- directly, so the fixture exercises the real production path into PENDING.
  INSERT INTO safety.red_flag_event
    (id, subject_pseudonym, session_pseudonym, occurred_at, severity, trigger_detail,
     template_id, template_version, action_taken, commercial_suppressed,
     first_byte_at, template_displayed_at, data_region)
  VALUES (gen_random_uuid(), gen_random_bytes(8), gen_random_bytes(8), now(), 'EMERGENCY',
          '{"rf6_claim_ci": true}'::jsonb, v_tmpl, v_v, 'TEMPLATE', true, now(), now(), '$1');
END \$\$;
SQL
}

# ---------------------------------------------------------------------------
# 1. THE PRIVILEGE DID NOT WIDEN.
#
#    The tempting fix was GRANT UPDATE. If someone applies it later, migration
#    029's three DEFINER transition functions stop being the only way alert_role
#    can change an alert, and this goes red.
# ---------------------------------------------------------------------------
echo "1. alert_role gained EXECUTE, not UPDATE"
[ "$(count "SELECT has_function_privilege('alert_role','safety.claim_alert_batch(integer)','EXECUTE')")" = "t" ] \
  || fail "alert_role cannot EXECUTE safety.claim_alert_batch — migration 035 §GRANT did not take"
for p in UPDATE INSERT DELETE; do
  [ "$(count "SELECT has_table_privilege('alert_role','safety.clinician_alert','$p')")" = "f" ] \
    || fail "alert_role holds $p on safety.clinician_alert. Migration 029 made every state
transition a DEFINER function precisely so it would not. If the batch claim was
'fixed' with a grant, the three transition functions are now advisory."
done
[ "$(count "SELECT has_table_privilege('alert_role','safety.clinician_alert','SELECT')")" = "t" ] \
  || fail "alert_role lost SELECT on safety.clinician_alert — the worker still reads it directly"
echo "  EXECUTE yes; UPDATE/INSERT/DELETE still no"

# ---------------------------------------------------------------------------
# 2. THE ORIGINAL FAILURE, STILL FAILING.
#
#    The bug was not "the worker could not read"; it was "FOR UPDATE is a write
#    lock". Asserting the raw query is STILL refused is what stops this gate
#    passing for the wrong reason — if it started working, the privilege widened
#    and section 1's real subject changed underneath it.
# ---------------------------------------------------------------------------
echo "2. the raw FOR UPDATE the worker used to issue is still refused"
raw=$(psql -qtA -c "SET SESSION AUTHORIZATION alert_role;
  SELECT id FROM safety.clinician_alert WHERE state='PENDING' LIMIT 1 FOR UPDATE" 2>&1 || true)
echo "$raw" | grep -qi "permission denied" \
  || fail "alert_role can now run SELECT ... FOR UPDATE directly. Either UPDATE was granted
or an UPDATE policy was added. Migration 035's whole justification is that this
statement is a write and this role does not write. Got: $raw"
echo "  still permission denied, as designed"

# ---------------------------------------------------------------------------
# 3. IT CLAIMS ITS OWN REGION, AND ONLY ITS OWN.
#
#    THE CONTROL THAT MATTERS. The function is SECURITY DEFINER over a table
#    whose RLS is not FORCEd, so the policy does not run. If migration 035's
#    explicit `data_region = v_region` predicate were dropped, everything else
#    here would still pass and the worker would silently reach every region.
#
#    The region is set by hand in this session because SET SESSION AUTHORIZATION
#    does not apply a role's login-time defaults. That those defaults exist is a
#    separate claim, asserted in section 5 rather than assumed here.
# ---------------------------------------------------------------------------
echo "3. claims PENDING alerts in its own region, and not another's"
# Inserted, and recorded as inserted — the cleanup below deletes this row only
# if THIS run created it. A gate that deletes a region it merely found could
# remove the admitted one, which is precisely what the earlier draft would have
# done once it mistook EU for its own region.
psql -v ON_ERROR_STOP=1 -q -c "INSERT INTO public.region_registry (code, legal_basis, primary_regime, active_from)
  VALUES ('$ALT', 'RF6-claim CI fixture', 'CI', now()) ON CONFLICT (code) DO NOTHING"
ALT_INSERTED=yes
# Two in the caller's own region: section 5 needs a second one to prove that a
# concurrent claimer SKIPS the locked row rather than simply finding nothing.
seed_alert "$REGION"
seed_alert "$REGION"
seed_alert "$ALT"

# Which alerts belong to this run is established HERE, as the owner, because
# alert_role cannot read safety.red_flag_event — it holds SELECT on
# clinician_alert and nothing else in that schema. A test that needed a wider
# grant than the code does would be measuring a role the worker never is.
MINE=$(count "SELECT coalesce(string_agg(a.event_id::text, ','), '')
                FROM safety.clinician_alert a
                JOIN safety.red_flag_event e ON e.id = a.event_id
               WHERE e.trigger_detail ? 'rf6_claim_ci'")
[ -n "$MINE" ] || fail "no alert was raised for this run's seeded events — 029's trigger did not fire"

own=$(count "SET SESSION AUTHORIZATION alert_role; SET app.data_region = '$REGION';
  SELECT count(*) FROM safety.claim_alert_batch(50) c
   WHERE c.event_id = ANY(string_to_array('$MINE', ',')::uuid[])")
[ "$own" -ge 1 ] || fail "claim_alert_batch returned no rows for its own region ($REGION).
A PENDING EMERGENCY alert was seeded and 029's trigger raised it; if the claim
comes back empty the worker still delivers nothing."

other=$(count "SET SESSION AUTHORIZATION alert_role; SET app.data_region = '$REGION';
  SELECT count(*) FROM safety.claim_alert_batch(50) c WHERE c.data_region = '$ALT'")
[ "$other" = "0" ] || fail "claim_alert_batch returned $other alert(s) from region $ALT while the
caller's region is $REGION. safety.clinician_alert's RLS policy does NOT protect
this path — the function is SECURITY DEFINER and the table is not FORCE ROW
LEVEL SECURITY — so the boundary lives only in migration 035's explicit
predicate. It is gone."
echo "  own region returned $own; region $ALT returned 0"

# ---------------------------------------------------------------------------
# 4. NO REGION IS AN ERROR, NOT AN EMPTY BATCH.
#
#    data_region = NULL is never true, so without this the worker would report
#    healthy zero-alert batches forever. On the §4.1 path an empty batch is
#    indistinguishable from a quiet night.
# ---------------------------------------------------------------------------
echo "4. an unset region raises rather than returning nothing"
noregion=$(psql -qtA -c "SET SESSION AUTHORIZATION alert_role; SET app.data_region = '';
  SELECT count(*) FROM safety.claim_alert_batch(50)" 2>&1 || true)
echo "$noregion" | grep -qi "app.data_region is not set" \
  || fail "with no region set, claim_alert_batch did not raise. Got: $noregion
Returning zero rows here is the SEC-1 failure mode: silent, healthy-looking, and
on the emergency path."
echo "  raises, with the SEC-1 hint attached"

# ---------------------------------------------------------------------------
# 5. THE PROPERTY THE MOVE INTO A FUNCTION COULD HAVE BROKEN.
#
#    SKIP LOCKED across two real connections. A plpgsql function runs in the
#    CALLER's transaction, so the locks must outlive the call and a second
#    claimer must skip them. If the claim had ended up in a transaction of its
#    own, both workers would claim the same alert and one §4.1 alert would be
#    delivered twice.
# ---------------------------------------------------------------------------
echo "5. locks survive the call, so a second claimer skips them"
mkfifo "$FIFO"
psql -qtA -f "$FIFO" > /tmp/rf6claim_a.out 2>&1 &
BGPID=$!
exec 9>"$FIFO"
cat >&9 <<SQL
BEGIN;
SET SESSION AUTHORIZATION alert_role;
SET app.data_region = '$REGION';
SELECT 'A:'||c.id FROM safety.claim_alert_batch(1) c;
SQL
sleep 2  # let session A take and hold its lock

b_id=$(count "SET SESSION AUTHORIZATION alert_role; SET app.data_region = '$REGION';
  SELECT coalesce((SELECT c.id::text FROM safety.claim_alert_batch(1) c), 'none')")
a_id=$(grep -o 'A:[0-9a-f-]*' /tmp/rf6claim_a.out | head -1 | cut -d: -f2)
cat >&9 <<SQL
ROLLBACK;
SQL
exec 9>&-
wait "$BGPID" 2>/dev/null || true
BGPID=""

[ -n "$a_id" ] || fail "session A claimed nothing; the concurrency check proved nothing"
[ "$b_id" != "none" ] || fail "session B claimed nothing while A held one row. With two PENDING
alerts seeded, B should have skipped A's locked row and taken the other."
[ "$a_id" != "$b_id" ] || fail "both sessions claimed the same alert ($a_id). FOR UPDATE SKIP
LOCKED is not holding across the function call, so two workers would deliver the
same §4.1 alert twice."

echo "  A and B claimed different alerts; alert_role logs in with app.data_region=$REGION"

echo "RF6-claim: the worker can claim a batch, in its own region only, and cannot write the table."
