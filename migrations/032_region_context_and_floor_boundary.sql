-- ============================================================================
-- MIGRATION 032 — THE REGION BOUNDARY THE APPLICATION NEVER CROSSED
--                 (register item SEC-1, restated)
--
-- SEC-1 was on the register as "session_severity_floor_patient_read needs a
-- session_id JWT claim the app does not emit". That policy does not exist in
-- this schema. It is a stub-only object, from db/*, and the register line was
-- written from the stub — the same mistake R6 was.
--
-- Executing against the real schema, as the real role, found two things
-- underneath it. Both are worse than the line they replace.
--
-- ---------------------------------------------------------------------------
-- FINDING 1 — FIFTEEN OF SIXTEEN POLICIES LISTEN FOR SOMETHING NOTHING SAYS
--
-- Every region-scoped policy in this schema reads `app.current_region()`,
-- which reads the GUC `app.data_region`. Three more read `app.current_user_id()`
-- and `app.current_provider_org()`, from `app.user_id` and `app.provider_org_id`.
--
-- The application sets none of those three. `chat-pipeline/src/lib/db.ts`'s
-- pool sets no GUC at all, and `runAsUser()` sets exactly one —
-- `request.jwt.claims` — which no policy in this schema reads. That GUC
-- belongs to the stub's db/020_rls.sql and to the HP-SEC-001 policy files; it
-- is a different vocabulary for a different schema.
--
-- So the app speaks `request.jwt.claims` and the schema listens for `app.*`,
-- and NULL never equals anything. Confirmed by execution rather than by
-- reading, connecting exactly as the application connects — as redflag_role,
-- with `request.jwt.claims` set and nothing else — and issuing the §4.0.7
-- write the pipeline performs on every flagged message:
--
--     ERROR:  new row violates row-level security policy for table
--             "red_flag_event"
--
-- This is HP-JOB-007's disconnect one layer up. HP-JOB-007 found that the
-- grants name roles nothing can be; this finds that the policies name a
-- context nothing sets. Migration 031's own verification passed because the
-- test set `app.data_region` by hand. That is my check not covering itself,
-- for the seventh time, and in the same direction as the other six: the gate
-- exercised a path the application does not take.
--
-- Nothing is broken in production today, for the same reason as R13: the
-- pipeline still runs against the stub schema. This is latent behind R10, and
-- it would have surfaced at cutover as "the red-flag module writes nothing",
-- which is precisely how the adopted_rule_set() bug presented.
--
-- The schema half of the repair is §1 below. The application half is
-- `applyRequestContext()` in db.ts, and the gate that proves the two agree is
-- migrations/test/sec1_region_context.sh, which connects the way the app
-- connects rather than the way a test finds convenient.
--
-- ---------------------------------------------------------------------------
-- FINDING 2 — THE §4.0.8 FLOOR IS THE ONE PIECE OF SESSION SAFETY STATE
--             WITH NO REGION BOUNDARY AT ALL
--
-- safety.red_flag_event and safety.red_flag_log are region-scoped by RLS.
-- safety.session_severity_floor — which is DERIVED from red_flag_event, and
-- carries an FK to it — has no data_region column, no RLS, and no policy.
--
-- Proven by execution as redflag_role with app.data_region = 'IN', against a
-- fixture holding one IN session and one EU session:
--
--   red_flag_event rows visible          1 of 2   correct
--   session_severity_floor rows visible  2 of 2   the leak
--
-- and it is not only a read. The same IN-region role successfully:
--
--   * raised the EU session's floor to URGENT through the exact ON CONFLICT
--     upsert recordRedFlagEvent() issues, pointing set_by_event_id at an
--     IN-region event that no EU reader can see; and
--   * cleared the EU session's floor, attributed to an IN-jurisdiction
--     clinician.
--
-- A floor is a safety control (§4.0.8: a session at WARNING+ stays there). A
-- region that can raise or clear another region's floor can both over- and
-- under-escalate a session it has no lawful visibility into, and HP-ADR-004
-- §2 / ADR-003 §2.1 say it should not be able to see it at all.
--
-- §2 gives the table a region, and proves the denormalisation with a COMPOSITE
-- FOREIGN KEY rather than a convention — the same device migration 029 used to
-- make `channel_delivers` a database fact. A floor's region is not merely
-- expected to match its setting event's region; it CANNOT differ.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- §1  THE ROLES WHOSE POLICIES DEPEND ON app.* CAN NOW REACH app.*
--
-- A policy expression binds to the function's OID at CREATE POLICY time and
-- is evaluated as the policy owner, so these policies work today without this
-- grant. What does not work is a role calling the helper itself:
--
--     SET SESSION AUTHORIZATION redflag_role;
--     SELECT app.current_region();
--     ERROR:  permission denied for schema app
--
-- That is a landmine of exactly the shape HP-SEC-001's v3 review named on the
-- stub, and it has a concrete cost here: the CI gate below cannot assert that
-- the request context was set unless the role can read it back. A check that
-- cannot observe the thing it is checking is the pattern this project keeps
-- finding, so the grant comes first and the gate depends on it.
--
-- USAGE on a schema conveys nothing but name resolution. Each function is
-- STABLE and reads one GUC.
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA app TO redflag_role, alert_role, metrics_role, dqe_role;
GRANT EXECUTE ON FUNCTION app.current_region()       TO redflag_role, alert_role, metrics_role, dqe_role;
GRANT EXECUTE ON FUNCTION app.current_user_id()      TO redflag_role, alert_role, metrics_role, dqe_role;
GRANT EXECUTE ON FUNCTION app.current_provider_org() TO redflag_role, alert_role, metrics_role, dqe_role;

-- ---------------------------------------------------------------------------
-- §2  A FLOOR CANNOT BELONG TO A DIFFERENT REGION FROM THE EVENT THAT SET IT
--
-- The unique constraint on (id, data_region) is redundant against the primary
-- key on (id) alone — that is the point. It exists so the composite foreign
-- key below has something to reference, which is the only way to make the
-- denormalised column provably consistent with its source rather than
-- consistent by the good behaviour of the code that writes it.
-- ---------------------------------------------------------------------------
ALTER TABLE safety.red_flag_event
  ADD CONSTRAINT u_rfe_id_region UNIQUE (id, data_region);

ALTER TABLE safety.session_severity_floor
  ADD COLUMN data_region char(2);

-- Backfill from the setting event. Every existing row has one: set_by_event_id
-- is NOT NULL and references red_flag_event, whose data_region is NOT NULL.
UPDATE safety.session_severity_floor f
   SET data_region = e.data_region
  FROM safety.red_flag_event e
 WHERE e.id = f.set_by_event_id
   AND f.data_region IS NULL;

ALTER TABLE safety.session_severity_floor
  ALTER COLUMN data_region SET NOT NULL,
  ADD CONSTRAINT session_severity_floor_data_region_fkey
    FOREIGN KEY (data_region) REFERENCES region_registry(code),
  -- The one that matters: a floor's region IS its setting event's region.
  -- Not checked by the application, not asserted by a test — refused by the
  -- database. The cross-region raise proven above becomes impossible even if
  -- the RLS policies below were dropped tomorrow.
  ADD CONSTRAINT c_floor_region_is_its_event_region
    FOREIGN KEY (set_by_event_id, data_region)
    REFERENCES safety.red_flag_event (id, data_region);

-- ---------------------------------------------------------------------------
-- §3  ROW-LEVEL SECURITY, MATCHING red_flag_event's SHAPE — PLUS UPDATE
--
-- red_flag_event needs only SELECT and INSERT policies because it is
-- append-only (R13 rule D). This table is not: §4.0.8's floor is raised by an
-- ON CONFLICT DO UPDATE and lowered by a clinician's clearance, so it needs a
-- third policy that red_flag_event does not have.
--
-- The UPDATE policy carries BOTH a USING and a WITH CHECK, and they are the
-- same expression. The two do different jobs, and which one does what was
-- established by execution rather than by reading the manual, because the
-- first version of this comment got the mechanism wrong:
--
--   * USING decides which rows are REACHABLE. In practice the SELECT policy
--     above already covers that here — with the UPDATE policy loosened all
--     the way to USING (true), a cross-region UPDATE still matched zero rows,
--     because a role holding SELECT on the table has SELECT policies applied
--     to an UPDATE's row search as well.
--
--   * WITH CHECK decides what the RESULTING row may look like, and it is the
--     only thing standing between a reachable row and a cross-region write.
--     With the SELECT policy loosened as well and no WITH CHECK, an IN-region
--     role raised the EU session's floor to EMERGENCY. Restoring WITH CHECK
--     alone refused it.
--
-- So neither is redundant: one bounds what can be found, the other bounds
-- what can be written, and an ON CONFLICT DO UPDATE is checked against both.
-- ---------------------------------------------------------------------------
ALTER TABLE safety.session_severity_floor ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_ssf_region_scoped ON safety.session_severity_floor
  FOR SELECT USING (data_region = app.current_region());

CREATE POLICY p_ssf_insert_own_region ON safety.session_severity_floor
  FOR INSERT WITH CHECK (data_region = app.current_region());

CREATE POLICY p_ssf_update_own_region ON safety.session_severity_floor
  FOR UPDATE USING (data_region = app.current_region())
         WITH CHECK (data_region = app.current_region());

-- The floor-raise upsert writes data_region on both the INSERT and the
-- ON CONFLICT branch, so redflag_role needs the column on both. It does NOT
-- get UPDATE on session_pseudonym — migration 027 withheld that deliberately
-- (a floor cannot be moved to another session) and schema_contract asserts it.
GRANT INSERT (data_region), UPDATE (data_region), SELECT (data_region)
  ON safety.session_severity_floor TO redflag_role;

COMMIT;
