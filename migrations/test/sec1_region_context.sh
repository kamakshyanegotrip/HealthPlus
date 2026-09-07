#!/usr/bin/env bash
# ============================================================================
# SEC-1 — the region boundary, executed the way the APPLICATION connects.
#
# WHY THIS EXISTS AS WELL AS THE OTHER GATES
#
# Migration 031 added region-scoped RLS to safety.red_flag_event and
# safety.red_flag_log, and its verification passed. It passed because the test
# ran `SET app.data_region = 'IN'` by hand before touching anything.
#
# The application does not do that. It sets `request.jwt.claims` and nothing
# else, and no policy in this schema reads that GUC. So every one of the
# region-scoped policies evaluated `data_region = NULL` for every real
# connection, and the §4.0.7 write the pipeline performs on every flagged
# message was refused:
#
#     ERROR: new row violates row-level security policy for table
#            "red_flag_event"
#
# That is the seventh instance of this project's oldest pattern — a check that
# does not cover itself — and it is the same direction as the other six: the
# gate exercised a path the application does not take. So this gate does not
# set the context itself. It asserts, in both directions, that:
#
#   1. WITHOUT the request context, the pipeline's own writes are REFUSED.
#      This is the negative control that keeps the rest honest: if someone
#      removes the `SET app.data_region` from db.ts, section 1 stops failing
#      and this gate goes red.
#
#   2. WITH the context set exactly as db.ts sets it, own-region reads,
#      raises and clears SUCCEED.
#
#   3. WITH the context set, another region's floor is invisible, cannot be
#      raised, and cannot be cleared. Before migration 032, all three of those
#      succeeded — proven, not assumed, against a two-region fixture.
#
#   4. The composite FK refuses a region/event mismatch even with RLS out of
#      the way, so the boundary survives a future policy edit.
#
# Env: standard PG* vars. Run after migrations have been applied.
# ============================================================================
set -euo pipefail

PGDATABASE="${PGDATABASE:-healthplus}"
export PGDATABASE

fail() { echo "SEC-1 FAIL: $*" >&2; exit 1; }

# The GUC db.ts sets on every pooled connection, spelled out here so this file
# and that one can be diffed by eye. If they drift, section 1's negative
# control is what catches it.
APP_CONTEXT="SET app.data_region = 'IN';"

echo "SEC-1 fixture: one IN session and one EU session, both with a §4.0.8 floor"
psql -v ON_ERROR_STOP=1 -q <<'SQL'
DO $$
DECLARE eid_in uuid := gen_random_uuid();
        eid_eu uuid := gen_random_uuid();
        uid    uuid;
BEGIN
  DELETE FROM safety.session_severity_floor
   WHERE session_pseudonym IN ('\x5ec11111', '\x5ec12222');
  DELETE FROM safety.red_flag_event
   WHERE session_pseudonym IN ('\x5ec11111', '\x5ec12222');

  INSERT INTO region_registry (code, legal_basis, primary_regime, active_from)
  VALUES ('EU', 'SEC-1 fixture — a second region to be excluded from', 'GDPR', date '2026-01-01')
  ON CONFLICT (code) DO NOTHING;

  -- WARNING, not CRITICAL: c_urgent_needs_template would demand a template
  -- and the RF6 auto-raise trigger would demand a roster. Neither is what
  -- this gate is about, and a fixture that drags in two unrelated subsystems
  -- is a fixture that goes red for unrelated reasons.
  INSERT INTO safety.red_flag_event
    (id, subject_pseudonym, session_pseudonym, occurred_at, severity, trigger_detail,
     action_taken, commercial_suppressed, first_byte_at, data_region)
  VALUES
    (eid_in, '\x5ec1a1', '\x5ec11111', now(), 'WARNING', '{}'::jsonb, 'TEMPLATE', false, now(), 'IN'),
    (eid_eu, '\x5ec1a2', '\x5ec12222', now(), 'WARNING', '{}'::jsonb, 'TEMPLATE', false, now(), 'EU');

  INSERT INTO safety.session_severity_floor
    (session_pseudonym, floor_severity, set_by_event_id, set_at, data_region)
  VALUES ('\x5ec11111', 'WARNING', eid_in, now(), 'IN'),
         ('\x5ec12222', 'WARNING', eid_eu, now(), 'EU');

  -- A clinician for the clearance path. c_clear_attributed makes an anonymous
  -- clearance impossible, so a cross-region clear can only be tested with a
  -- real one — and testing it with a NULL would have "passed" for the wrong
  -- reason, which is how the first version of this check fooled itself.
  --
  -- Reuse the existing user if this fixture has run before. The obvious
  -- spelling — always gen_random_uuid(), then ON CONFLICT DO NOTHING on both
  -- inserts — is wrong on the SECOND run and was caught by a negative control
  -- failing for the wrong reason: the app_user insert quietly does nothing
  -- (auth_subject is already taken) while the clinician insert goes ahead
  -- with the fresh uid and hits clinician_user_id_fkey. A fixture that only
  -- works on an empty database is the schema-contract bug all over again.
  SELECT id INTO uid FROM principal.app_user WHERE auth_subject = 'sec1-fixture-clinician';
  IF uid IS NULL THEN
    uid := gen_random_uuid();
    INSERT INTO principal.app_user (id, auth_subject, data_region, status, created_at)
    VALUES (uid, 'sec1-fixture-clinician', 'IN', 'ACTIVE', now());
  END IF;
  INSERT INTO principal.clinician (user_id, full_name, primary_jurisdiction)
  VALUES (uid, 'SEC-1 Fixture Clinician', 'IN')
  ON CONFLICT (user_id) DO NOTHING;

  -- Section 5 writes probe events through the real pool; clear them so a
  -- rerun starts from the same state as a first run.
  DELETE FROM safety.red_flag_event WHERE session_pseudonym = '\x5ec1b000';
END $$;
SQL

CLINICIAN=$(psql -qAt -c \
  "SELECT user_id FROM principal.clinician c
     JOIN principal.app_user u ON u.id = c.user_id
    WHERE u.auth_subject = 'sec1-fixture-clinician' LIMIT 1")
[ -n "$CLINICIAN" ] || fail "fixture clinician was not created"

# ----------------------------------------------------------------------------
# 1. THE NEGATIVE CONTROL. No request context — the state db.ts was in before
#    SEC-1 — and the pipeline's own write must be refused.
#
#    This runs FIRST on purpose. If it ever passes, every assertion below is
#    meaningless, because it would mean the policies are not being consulted
#    at all (an owner connection, RLS disabled, a policy loosened to `true`).
# ----------------------------------------------------------------------------
echo "1. without the request context, the §4.0.7 write must be refused"
out=$(psql -qAt <<SQL 2>&1 || true
SET SESSION AUTHORIZATION redflag_role;
BEGIN;
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-0000-0000-000000000001","user_role":"patient"}', true);
INSERT INTO safety.red_flag_event
  (id, subject_pseudonym, session_pseudonym, occurred_at, severity, trigger_detail,
   action_taken, commercial_suppressed, first_byte_at, data_region)
VALUES (gen_random_uuid(), '\x5ec1a9', '\x5ec19999', now(), 'WARNING', '{}'::jsonb,
        'TEMPLATE', false, now(), 'IN');
SQL
)
case "$out" in
  *"violates row-level security policy"*)
    echo "  refused, as it must be — request.jwt.claims is not the vocabulary this schema reads" ;;
  *) fail "a claims-only connection was ALLOWED to write a red_flag_event.
Either db.ts's request context is no longer what this gate expects, or a
region policy has been loosened. Both are the same failure: the boundary is
no longer being enforced on the path the application actually takes.
Got: $out" ;;
esac

# ----------------------------------------------------------------------------
# 2. WITH the context db.ts now sets, the three real callers must all work.
# ----------------------------------------------------------------------------
echo "2. with the request context, the pipeline's own floor operations succeed"
psql -v ON_ERROR_STOP=1 -qAt <<SQL >/dev/null || fail "an OWN-region floor operation was refused.
A boundary that also blocks the permitted direction is not a boundary, it is
an outage — see the R13 finding where RF6's own backstop trigger blocked every
emergency it existed to protect."
SET SESSION AUTHORIZATION redflag_role;
$APP_CONTEXT
-- recordRedFlagEvent()'s floor-raise, verbatim in shape
INSERT INTO safety.session_severity_floor
  (session_pseudonym, floor_severity, set_by_event_id, set_at, cleared_at, cleared_by, data_region)
SELECT '\x5ec11111', 'URGENT', id, now(), NULL, NULL, 'IN'
  FROM safety.red_flag_event WHERE session_pseudonym = '\x5ec11111'
ON CONFLICT (session_pseudonym) DO UPDATE SET
  floor_severity = EXCLUDED.floor_severity, set_by_event_id = EXCLUDED.set_by_event_id,
  set_at = now(), cleared_at = NULL, cleared_by = NULL, data_region = EXCLUDED.data_region
WHERE safety.session_severity_floor.cleared_at IS NOT NULL
   OR EXCLUDED.floor_severity > safety.session_severity_floor.floor_severity;
-- getSessionFloor()
SELECT floor_severity FROM safety.session_severity_floor WHERE session_pseudonym = '\x5ec11111';
-- clearSessionSeverityFloor()
UPDATE safety.session_severity_floor
   SET cleared_at = now(), cleared_by = '$CLINICIAN'
 WHERE session_pseudonym = '\x5ec11111' AND cleared_at IS NULL;
SQL

got=$(psql -qAt <<SQL
SET SESSION AUTHORIZATION redflag_role;
$APP_CONTEXT
SELECT floor_severity || ':' || (cleared_at IS NOT NULL)::text
  FROM safety.session_severity_floor WHERE session_pseudonym = '\x5ec11111';
SQL
)
[ "$got" = "URGENT:true" ] || fail "own-region floor ended at '$got', expected URGENT:true"
echo "  raise, read and clear all succeed in-region"

# ----------------------------------------------------------------------------
# 3. THE ONE THAT MATTERS. Before migration 032 all three of these succeeded.
# ----------------------------------------------------------------------------
echo "3. another region's floor must be invisible and untouchable"

n=$(psql -qAt <<SQL
SET SESSION AUTHORIZATION redflag_role;
$APP_CONTEXT
SELECT count(*) FROM safety.session_severity_floor WHERE session_pseudonym = '\x5ec12222';
SQL
)
[ "$n" = "0" ] || fail "an IN-region role can SEE the EU session's §4.0.8 floor ($n rows). \
HP-ADR-004 §2 says no health data leaves its region; a session's safety floor is health data."

# A cross-region raise. Under RLS this is refused by the INSERT policy; note
# that ON CONFLICT DO UPDATE on a row the reader cannot see behaves as a plain
# INSERT and hits the unique index, so BOTH outcomes are checked: it must
# either error, or leave the EU row untouched. Accepting "no error" alone
# would have passed while the row was silently overwritten.
psql -qAt <<SQL >/dev/null 2>&1 || true
SET SESSION AUTHORIZATION redflag_role;
$APP_CONTEXT
INSERT INTO safety.session_severity_floor
  (session_pseudonym, floor_severity, set_by_event_id, set_at, cleared_at, cleared_by, data_region)
SELECT '\x5ec12222', 'EMERGENCY', id, now(), NULL, NULL, 'IN'
  FROM safety.red_flag_event WHERE session_pseudonym = '\x5ec11111'
ON CONFLICT (session_pseudonym) DO UPDATE SET
  floor_severity = EXCLUDED.floor_severity, set_by_event_id = EXCLUDED.set_by_event_id,
  set_at = now(), data_region = EXCLUDED.data_region;
SQL
after=$(psql -qAt -c \
  "SELECT floor_severity || '/' || data_region FROM safety.session_severity_floor
    WHERE session_pseudonym = '\x5ec12222'")
[ "$after" = "WARNING/EU" ] || fail "an IN-region role CHANGED the EU session's floor (now '$after', \
was WARNING/EU). A region that can raise another region's §4.0.8 floor can escalate \
or de-escalate a session it has no lawful visibility into."

# And the clearance. A cleared floor exerts no pull on later messages
# (applySessionFloor), so clearing another region's floor silently disables
# that session's stickiness — the quietest of the three.
psql -qAt <<SQL >/dev/null 2>&1 || true
SET SESSION AUTHORIZATION redflag_role;
$APP_CONTEXT
UPDATE safety.session_severity_floor
   SET cleared_at = now(), cleared_by = '$CLINICIAN'
 WHERE session_pseudonym = '\x5ec12222' AND cleared_at IS NULL;
SQL
cleared=$(psql -qAt -c \
  "SELECT (cleared_at IS NOT NULL)::text FROM safety.session_severity_floor
    WHERE session_pseudonym = '\x5ec12222'")
[ "$cleared" = "false" ] || fail "an IN-region role CLEARED the EU session's §4.0.8 floor. \
A cleared floor exerts no pull on later messages, so this silently switches off \
stickiness for a session in a region this role cannot see."
echo "  invisible, unraisable, unclearable"

# ----------------------------------------------------------------------------
# 4. The composite FK, with RLS out of the picture. Policies can be edited;
#    this constraint is what makes a region/event mismatch impossible rather
#    than merely currently prevented.
# ----------------------------------------------------------------------------
echo "4. the composite FK refuses a region/event mismatch on its own"
out=$(psql -qAt <<'SQL' 2>&1 || true
INSERT INTO safety.session_severity_floor
  (session_pseudonym, floor_severity, set_by_event_id, set_at, data_region)
SELECT '\x5ec13333', 'WARNING', id, now(), 'EU'
  FROM safety.red_flag_event WHERE session_pseudonym = '\x5ec11111';
SQL
)
case "$out" in
  *c_floor_region_is_its_event_region*)
    echo "  refused by c_floor_region_is_its_event_region, as owner, with RLS not consulted" ;;
  *) fail "a floor in region EU was accepted for an event in region IN, as the owner.
The composite FK is the half of this that survives a policy being edited; if it
is gone, section 3 is protected by RLS alone.
Got: $out" ;;
esac

# ----------------------------------------------------------------------------
# 5. THE ONE THAT TIES THE TWO HALVES TOGETHER.
#
#    Everything above sets the context by hand, which is precisely the habit
#    that let SEC-1 exist: migration 031's verification did the same, and so
#    proved the policies correct while the application could not satisfy them.
#    So this section does not set anything. It imports the REAL exported
#    db() from chat-pipeline/src/lib/db.ts, connects through it as a member of
#    redflag_role, and asserts:
#
#      * with DATA_REGION set as a deployment sets it, the §4.0.7 write the
#        pipeline performs on every flagged message is ACCEPTED; and
#      * with DATA_REGION naming a DIFFERENT region, the same write through
#        the same pool is REFUSED.
#
#    The second is what makes the first mean something. Without it, a db.ts
#    that set the region to a constant, or to whatever the row said, would
#    pass.
#
#    This needs a LOGIN role, and roles are CLUSTER-wide — they outlive the
#    throwaway database this gate runs against. That has bitten this project
#    before (an ALTER ROLE in an earlier fixture escaped its test database and
#    had to be undone by hand), so the role is dropped by a trap on EXIT, not
#    at the end of the happy path, and DROP OWNED comes first because the
#    GRANT CONNECT is a dependent object that makes a bare DROP ROLE fail.
# ----------------------------------------------------------------------------
echo "5. the real db() pool from chat-pipeline carries the region, and only its own"

PROBE="sec1_probe_$$"
cleanup() { psql -qAt -c "DROP OWNED BY $PROBE;" >/dev/null 2>&1 || true
            psql -qAt -c "DROP ROLE IF EXISTS $PROBE;" >/dev/null 2>&1 || true; }
trap cleanup EXIT

psql -v ON_ERROR_STOP=1 -q \
  -c "DROP ROLE IF EXISTS $PROBE;" \
  -c "CREATE ROLE $PROBE LOGIN PASSWORD 'probe' IN ROLE redflag_role;" \
  -c "GRANT CONNECT ON DATABASE \"$PGDATABASE\" TO $PROBE;"

probe_write() { # $1 = DATA_REGION the deployment is configured with
  DATABASE_URL="postgresql://$PROBE:probe@${PGHOST:-localhost}:${PGPORT:-5432}/$PGDATABASE" \
  DATA_REGION="$1" \
  npx --prefix chat-pipeline tsx -e "
    import { db } from './chat-pipeline/src/lib/db';
    const p = db();
    p.query(\`INSERT INTO safety.red_flag_event
        (id, subject_pseudonym, session_pseudonym, occurred_at, severity, trigger_detail,
         action_taken, commercial_suppressed, first_byte_at, data_region)
        VALUES (gen_random_uuid(), '\\\\x5ec1b0', '\\\\x5ec1b000', now(), 'WARNING', '{}'::jsonb,
                'TEMPLATE', false, now(), 'IN')\`)
      .then(() => { console.log('ACCEPTED'); return p.end(); })
      .then(() => process.exit(0))
      .catch((e) => { console.log('REFUSED:' + e.message); p.end().finally(() => process.exit(0)); });
  " 2>/dev/null | tail -1
}

got=$(probe_write 'IN')
case "$got" in
  ACCEPTED) echo "  DATA_REGION=IN -> the §4.0.7 write is accepted through the app's own pool" ;;
  *) fail "the application's own connection cannot perform the write the pipeline performs on
every flagged message. Got: $got
This is SEC-1 itself: db.ts is not putting app.data_region on the connection, so
every region-scoped policy in this schema compares a real value to NULL." ;;
esac

got=$(probe_write 'EU')
case "$got" in
  *"violates row-level security policy"*)
    echo "  DATA_REGION=EU -> the same write is refused, so the region is really being read" ;;
  ACCEPTED) fail "a pool configured for region EU wrote an IN-region red_flag_event.
The write succeeding under DATA_REGION=IN therefore proves nothing: the policy is
not consulting the connection's region at all." ;;
  *) fail "expected an RLS refusal under DATA_REGION=EU, got: $got" ;;
esac

echo "SEC-1: region context and the §4.0.8 floor boundary verified against the real schema."
