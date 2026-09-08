-- ============================================================================
-- MIGRATION 040 — SECURITY DEFINER FUNCTIONS STOP GRANTING PUBLIC
--                 (register item R10d-obs, found while wiring it)
--
-- ⚠ THIS IS A PRIVILEGE ESCALATION FIX, AND MIGRATIONS 037 AND 039 ARE WHAT
--   MADE IT LIVE. Read this section before the SQL.
--
-- ---------------------------------------------------------------------------
-- WHAT WAS FOUND, AND HOW
--
-- Wiring patientProfile.ts onto principal.fetch_attribute_envelope, the first
-- question was which role may call it. The answer, from the running database
-- rather than from the migration that created it:
--
--     SELECT p.proname, r.rolname, has_function_privilege(r.rolname,p.oid,'EXECUTE')
--       FROM pg_proc p, pg_roles r WHERE p.proname='fetch_attribute_envelope';
--
--     fetch_attribute_envelope | alert_role            | t
--     fetch_attribute_envelope | confirmation_ui_role  | t
--     fetch_attribute_envelope | dqe_role              | t
--     fetch_attribute_envelope | erasure_role          | t
--     fetch_attribute_envelope | hp_app                | t
--     fetch_attribute_envelope | metrics_role          | t
--     fetch_attribute_envelope | reasoner_role         | t
--     fetch_attribute_envelope | redflag_role          | t
--
-- Every role. Migration 018 wrote `GRANT EXECUTE ... TO reasoner_role,
-- confirmation_ui_role` and never wrote the REVOKE that has to come first: a
-- function's DEFAULT ACL is EXECUTE TO PUBLIC, so a GRANT to a named role NARROWS
-- NOTHING. It reads as a restriction and is an addition.
--
-- Eleven SECURITY DEFINER functions were in that state. Nine carry an explicit
-- ACL that still includes the PUBLIC entry (`=X/postgres`) alongside the role
-- somebody meant to name; two are trigger functions on the default ACL.
--
-- ---------------------------------------------------------------------------
-- WHY IT WAS LATENT UNTIL NOW, AND WHOSE FAULT THAT IS
--
-- PUBLIC EXECUTE on a function in schema `principal` does nothing to a role
-- with no USAGE on `principal` — that is rule K, from the other side. Until this
-- month every application role except reasoner_role lacked that USAGE, so the
-- over-grant was unreachable and invisible.
--
-- Then:
--   * migration 037 (mine) gave dqe_role USAGE on obs, domain AND principal, to
--     reach three tables the ingestion job needs;
--   * migration 039 (mine) gave hp_app USAGE on obs, principal AND safety, so
--     its six new verbs would not be decoration.
--
-- Both were correct about the tables. Neither asked what ELSE was callable in
-- the schemas they opened. Rule K's own comment in 039 says "USAGE ON A SCHEMA
-- GRANTS NOTHING ON ITS OBJECTS" — true, and it is not the whole sentence. Usage
-- on a schema grants nothing on its objects THAT HAVE NOT ALREADY GRANTED
-- THEMSELVES TO PUBLIC.
--
-- ---------------------------------------------------------------------------
-- WHAT THAT ACTUALLY ALLOWED, DEMONSTRATED RATHER THAN ASSERTED
--
-- Against a database with 001–039 applied, as dqe_role — the role a background
-- ingestion job connects as — with a seeded subject:
--
--     SET SESSION AUTHORIZATION dqe_role;
--     SELECT principal.erase_subject('…');
--
--     key_live_after=false
--     attributes_left=0
--
-- Not a permission error. The ingestion job's role irreversibly crypto-shredded
-- a data subject: destroyed_at set, salt and wrapped DEK nulled, every Layer-2
-- row deleted. trg_key_destruction_final then refuses to undo any of it, which
-- is correct and is why this is unrecoverable rather than merely wrong.
--
-- The same role could read any subject's encrypted attribute envelopes through
-- fetch_attribute_envelope — writing itself an attribute_access_log entry
-- naming `dqe_role` as the accessor, which is at least honest.
--
-- ---------------------------------------------------------------------------
-- THE FIX, AND WHY IT HAS NO EXCEPTIONS
--
-- REVOKE EXECUTE FROM PUBLIC on every SECURITY DEFINER function, then GRANT to
-- exactly the roles the original migrations named. NO GRANTEE CHANGES HERE: this
-- migration removes PUBLIC and nothing else, so it cannot quietly re-decide who
-- may erase a subject while claiming to be a security fix. Where a function's
-- intended caller list looks wrong, that is a separate change with its own
-- argument.
--
-- The two trigger functions are included even though their PUBLIC grant is
-- inert. Both properties were checked against the running database rather than
-- assumed:
--
--   * `SELECT safety.event_requires_alert();`
--       ERROR: trigger functions can only be called as triggers
--   * a DEFINER trigger function with PUBLIC revoked still fires for a
--     non-owner's INSERT (PostgreSQL does not check EXECUTE when firing a
--     trigger) — verified on a throwaway table as dqe_role.
--
-- So including them costs nothing and buys the thing that matters more than the
-- two rows: the invariant becomes NO SECURITY DEFINER FUNCTION GRANTS PUBLIC,
-- with no carve-out to remember. grant_contract.mjs's new rule L enforces it on
-- every future migration, which is the actual fix — this file only cleans up
-- the eleven that already exist.
-- ============================================================================

BEGIN;

DO $$
DECLARE
  r        record;
  n_public int := 0;
BEGIN
  -- Enumerated from the catalogue rather than listed by hand, deliberately.
  -- A hand-written list is a list that goes stale on the next DEFINER function
  -- somebody adds, and the whole finding here is that a hand-written GRANT
  -- forgot the REVOKE that precedes it.
  FOR r IN
    SELECT n.nspname, p.proname, p.oid,
           pg_get_function_identity_arguments(p.oid) AS args
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE p.prosecdef
       AND n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND has_function_privilege('public', p.oid, 'EXECUTE')
     ORDER BY 1, 2
  LOOP
    RAISE NOTICE 'revoking PUBLIC EXECUTE: %.%(%)', r.nspname, r.proname, r.args;
    EXECUTE format('REVOKE ALL ON FUNCTION %I.%I(%s) FROM PUBLIC',
                   r.nspname, r.proname, r.args);
    n_public := n_public + 1;
  END LOOP;

  RAISE NOTICE '040: revoked PUBLIC EXECUTE from % SECURITY DEFINER function(s)', n_public;
END $$;

-- ---------------------------------------------------------------------------
-- AND THE RE-GRANTS.
--
-- REVOKE ALL removed the named roles' grants too, so each is restated. Every
-- line below reproduces a grant that already existed in the migration that
-- created the function — the source is named so the next reader can check that
-- this file changed nobody's reach:
--
--   018  erase_subject, assert_shred_complete            -> erasure_role
--   018  attribute_ref_digest                            -> reasoner_role
--   018  fetch_attribute_envelope   -> reasoner_role, confirmation_ui_role
--   029  mark_alert_delivered, mark_alert_undeliverable  -> alert_role
--   029  acknowledge_alert                 -> alert_role, hp_app
--   027  raise_alert                       -> redflag_role, hp_app
--   030  record_metric_sample                            -> metrics_role
--
-- The trigger functions get no re-grant: nothing can call them, and the trigger
-- fires without one.
--
-- 035's claim_alert_batch and 038/039's own verbs are absent because they
-- already did the REVOKE when they were written — the loop above did not touch
-- them, and restating their grants here would be noise.
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION principal.erase_subject(uuid)             TO erasure_role;
GRANT EXECUTE ON FUNCTION principal.assert_shred_complete(uuid)     TO erasure_role;
GRANT EXECUTE ON FUNCTION principal.attribute_ref_digest(uuid,text) TO reasoner_role;
GRANT EXECUTE ON FUNCTION principal.fetch_attribute_envelope(uuid,text,uuid,boolean)
  TO reasoner_role, confirmation_ui_role;

GRANT EXECUTE ON FUNCTION safety.raise_alert(uuid)                        TO redflag_role, hp_app;
GRANT EXECUTE ON FUNCTION safety.acknowledge_alert(uuid,uuid)             TO alert_role, hp_app;
GRANT EXECUTE ON FUNCTION safety.mark_alert_delivered(uuid,text,uuid)     TO alert_role;
GRANT EXECUTE ON FUNCTION safety.mark_alert_undeliverable(uuid,text)      TO alert_role;

GRANT EXECUTE ON FUNCTION obs.record_metric_sample(
  text,text,timestamptz,timestamptz,numeric,numeric,numeric,metric_status,text,text,text
) TO metrics_role;

-- ---------------------------------------------------------------------------
-- THE ASSERTION, IN THE MIGRATION ITSELF.
--
-- rule L in grant_contract.mjs is the durable enforcement, and it runs in CI.
-- This is here for the case CI is not what applied the file — a hand-run
-- migration against a real database should refuse to commit if it did not
-- achieve the thing it exists to achieve.
-- ---------------------------------------------------------------------------
DO $$
DECLARE leftover text;
BEGIN
  SELECT string_agg(n.nspname||'.'||p.proname, ', ')
    INTO leftover
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE p.prosecdef
     AND n.nspname NOT IN ('pg_catalog', 'information_schema')
     AND has_function_privilege('public', p.oid, 'EXECUTE');

  IF leftover IS NOT NULL THEN
    RAISE EXCEPTION '040 did not achieve its purpose: PUBLIC still holds EXECUTE on %', leftover;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- WHAT THIS DOES NOT FIX, recorded so it is not mistaken for done:
--
--   * dqe_role still holds USAGE on `principal` (migration 037), for one table:
--     SELECT on principal.provider_org. That is a wider door than the one thing
--     behind it needs, and narrowing it means moving provider_org's read behind
--     a verb or into another schema — a change to the ingestion path, not to a
--     grant, so it is not made here. With PUBLIC revoked, the door now opens
--     onto nothing dqe_role may call.
--   * hp_app holds USAGE on `principal` and `safety` (migration 039) on the
--     same terms.
--   * Whether raise_alert and acknowledge_alert SHOULD be callable by hp_app at
--     all is migration 039's question, not this file's. This preserves the
--     answer 027/029 gave.
-- ---------------------------------------------------------------------------

COMMIT;
