-- ============================================================================
-- MIGRATION 031 — MAKING THE GRANTS REAL  (register items R13-rls, part of R13)
--
-- R13's first run found 47 grants that cannot be exercised, in three classes:
--
--   A  30  a table grant held by a role with no USAGE on the schema
--   B  13  a grant on an RLS-enabled table with no policy permitting it
--   C   4  a NOLOGIN role with no members — nothing can ever be it
--
-- This migration closes A and B. It deliberately does NOT touch C, which is
-- the connection-model decision set out in HP-JOB-007 §5 and is not
-- engineering's to make.
--
-- ---------------------------------------------------------------------------
-- CLASS A — ALL THIRTY WERE MINE, AND THE FIX IS TO TAKE THEM BACK
--
-- Every one came from migration 029 §10 and 030 §8, written on 5 and 6
-- September: SELECT on the RF6 alert tables and the §6.5 metric tables and
-- views, granted to hp_app and hp_reader. Neither role holds USAGE on `safety`
-- or `obs`, so all thirty fail at schema resolution before the table grant is
-- consulted.
--
-- There are two honest repairs and only one of them is right.
--
--   * Grant the missing USAGE and write the missing policies. This makes the
--     grants work — but nothing calls them. The alert worker runs as
--     alert_role and the metrics job as metrics_role; no code path reads any
--     of these tables as hp_app or hp_reader. J3-4-dashboard, the only thing
--     that would, is unbuilt.
--
--   * Revoke them. Least privilege: a grant with no caller is not access, it
--     is future access nobody has justified yet.
--
-- I granted them reflexively, on the reasoning that a reader role should be
-- able to read. That is how privilege creeps: each grant is individually
-- defensible and none has a caller. When J3-4-dashboard is built it gets
-- exactly the grants it needs, with USAGE and policies, and R13 will verify
-- all three conditions hold.
--
-- safety.on_call_roster is the one I would most want back. It carries
-- clinician contact addresses, and I granted SELECT on it to hp_app, hp_reader
-- AND redflag_role in one line of 029 §10 without asking what any of them
-- would do with a pager number. Only alert_role has any business there.
--
-- ---------------------------------------------------------------------------
-- CLASS B — THE EIGHT THAT SURVIVE ARE REAL AND GET POLICIES
--
-- After the revocations above, eight rule-B findings remain. Each is a role
-- that genuinely reads or writes the table and is silently denied:
--
--   redflag_role        -> safety.red_flag_event   INSERT, SELECT
--                          obs.ai_call             INSERT
--                          safety.red_flag_rule    SELECT
--   metrics_role        -> obs.fabrication_block   SELECT
--                          obs.review_queue_item   SELECT
--                          safety.red_flag_log     SELECT
--   confirmation_ui_role-> principal.patient_attribute_confirmation INSERT
--
-- The first group is the one that matters: migration 012 enabled RLS on
-- red_flag_event and never wrote a policy, so the red-flag module has never
-- been able to persist a §4.0.7 event. safety.red_flag_log got its two
-- policies in 027 §5; the event table beside it did not.
--
-- Every policy below matches the shape already in use for its schema —
-- region-scoped for the safety/obs tables (027 §5, 029 §11), subject-scoped
-- for principal (`p_pa_own`), readable for reference data (`p_efr_readable`).
-- None of them widens access beyond what the existing GRANT already states.
--
-- These policies are correct whichever way HP-JOB-007 §5 is decided: they
-- name the role, and whether the application reaches that role by membership
-- or by its own login is orthogonal.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. CLASS A — revoke the grants that have no caller.
--
--    Written as REVOKE against the exact grants 029 §10 and 030 §8 made, so
--    this file reads as the correction it is rather than as new policy.
-- ---------------------------------------------------------------------------

-- From migration 029 §10.
REVOKE SELECT ON safety.alert_channel, safety.alert_sla FROM hp_app, hp_reader;
REVOKE SELECT ON safety.clinician_alert               FROM hp_app, hp_reader;
REVOKE SELECT ON safety.v_alert_sla_breach,
                 safety.v_alerts_reaching_nobody      FROM hp_app, hp_reader;

-- The roster carries contact addresses. alert_role keeps it; nobody else had
-- a reason for it in the first place.
REVOKE SELECT ON safety.on_call_roster FROM hp_app, hp_reader, redflag_role;

-- From migration 030 §8.
REVOKE SELECT ON obs.safety_metric, obs.safety_metric_sample FROM hp_app, hp_reader;
REVOKE SELECT ON obs.v_metric_emergency_latency, obs.v_metric_block_rate,
                 obs.v_metric_abstention_rate, obs.v_metric_review_turnaround,
                 obs.v_review_backlog, obs.v_release_gate, obs.v_metric_coverage
  FROM hp_app, hp_reader;

-- ---------------------------------------------------------------------------
-- 2. CLASS B — safety.red_flag_event.
--
--    THE ONE THAT MATTERS. Migration 012 enabled RLS here and wrote no
--    policy, so every §4.0.7 event write has been denied since the table was
--    created. Same two-policy shape as safety.red_flag_log in 027 §5: read
--    within your own region, write only into it.
--
--    Note the asymmetry, which is deliberate and copied from 027: the SELECT
--    policy uses USING, the INSERT policy uses WITH CHECK. An INSERT policy
--    with a USING clause would be checked against rows that do not exist yet.
-- ---------------------------------------------------------------------------
CREATE POLICY p_rfe_region_scoped ON safety.red_flag_event
  FOR SELECT TO redflag_role
  USING (data_region = app.current_region());

CREATE POLICY p_rfe_insert_own_region ON safety.red_flag_event
  FOR INSERT TO redflag_role
  WITH CHECK (data_region = app.current_region());

-- ---------------------------------------------------------------------------
-- 2b. A GRANT AND A POLICY ARE STILL NOT ENOUGH — the trigger has to run too.
--
--     Found by executing the insert above as redflag_role with the policies
--     from §2 in place. The INSERT itself succeeded; the transaction then
--     failed at COMMIT with:
--
--       ERROR: permission denied for table clinician_alert
--       CONTEXT: PL/pgSQL function safety.event_requires_alert()
--
--     safety.event_requires_alert() is RF6's backstop — the deferrable
--     constraint trigger from 029 §5 that refuses to let an URGENT+ event
--     exist without an alert. I wrote it as a plain INVOKER function, so it
--     reads safety.clinician_alert with the caller's privileges, and
--     redflag_role has none there. The check meant to guarantee that an
--     emergency is never silently unalerted was itself blocking every
--     emergency from being recorded at all.
--
--     This is a fourth way a grant can be real and still not work, alongside
--     R13's A, B and C: the writer must also be able to execute every trigger
--     the write fires. R13 gains rule H for it.
--
--     SECURITY DEFINER with a pinned search_path, matching the other RF6
--     functions in 029 §6-§8. An integrity check owned by the schema should
--     not require the caller to hold privileges on the tables it consults —
--     granting redflag_role SELECT on clinician_alert would work too, and
--     would be the wrong fix: it widens access to alert records in order to
--     satisfy a constraint that is none of the caller's business.
--
--     Body is unchanged from 029 §5.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION safety.event_requires_alert() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, safety, public
AS $$
BEGIN
  IF NEW.severity >= 'URGENT'::red_flag_severity
     AND NOT EXISTS (SELECT 1 FROM safety.clinician_alert a WHERE a.event_id = NEW.id)
  THEN
    RAISE EXCEPTION
      'HP-ESC 4.1: red_flag_event % is % and has no safety.clinician_alert row. '
      'Levels 3-5 carry mandatory clinician involvement; an event at this '
      'severity may not exist without the alert record that proves it was '
      'raised.', NEW.id, NEW.severity;
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------------
-- 3. CLASS B — obs.ai_call. §4.0.3's propose-only model calls are logged here
--    by the scanner; without this the log is silently empty and §6.4's
--    "any change to model version ... requires re-running the suite" has no
--    record of which model version ran.
-- ---------------------------------------------------------------------------
CREATE POLICY p_ai_call_insert_own_region ON obs.ai_call
  FOR INSERT TO redflag_role
  WITH CHECK (data_region = app.current_region());

-- ---------------------------------------------------------------------------
-- 4. CLASS B — safety.red_flag_rule.
--
--    Reference data with no data_region column, so it cannot be region-scoped
--    and must not pretend to be. Readable, on the same reasoning as
--    emergency_facility_reference in 027 §5: the scanner reads this on the
--    emergency path and a rule it cannot see is a rule that does not fire.
--
--    Retired rules stay readable on purpose — red_flag_event and red_flag_log
--    both carry (rule_id, rule_version) foreign keys, and an audit record that
--    cannot resolve the rule that produced it is not an audit record.
-- ---------------------------------------------------------------------------
CREATE POLICY p_rfr_readable ON safety.red_flag_rule
  FOR SELECT TO redflag_role
  USING (true);

-- ---------------------------------------------------------------------------
-- 5. CLASS B — the three tables the §6.5 metrics read.
--
--    Without these the metrics job reads zero rows and reports NO_DATA for
--    every metric: a metrics module reporting nothing wrong because it can
--    see nothing at all. J3-4's own CI could not catch it, because CI runs as
--    the owner.
--
--    Region-scoped, like everything else these roles touch. A metric computed
--    across regions would silently mix jurisdictions, which ADR-003 exists to
--    prevent.
-- ---------------------------------------------------------------------------
CREATE POLICY p_fb_region_scoped ON obs.fabrication_block
  FOR SELECT TO metrics_role
  USING (data_region = app.current_region());

CREATE POLICY p_rqi_region_scoped ON obs.review_queue_item
  FOR SELECT TO metrics_role
  USING (data_region = app.current_region());

CREATE POLICY p_rfl_metrics_region_scoped ON safety.red_flag_log
  FOR SELECT TO metrics_role
  USING (data_region = app.current_region());

-- obs.response_audit is the denominator for block_rate and abstention_rate and
-- obs.abstention_event supplies the numerator; neither carries RLS, so neither
-- needs a policy. Recorded here so the next reader does not go looking for one.

-- ---------------------------------------------------------------------------
-- 6. CLASS B — principal.patient_attribute_confirmation.
--
--    Pre-existing, and the only one of these that touches patient data
--    directly. Subject-scoped rather than region-scoped, matching
--    principal.patient_attribute's `p_pa_own`: a confirmation may only be
--    written for the subject whose session is making it.
--
--    WITH CHECK, not USING, and both conditions: the row must belong to the
--    current subject AND name them as the confirmer. Without the second, one
--    subject could record a confirmation against another's attribute.
-- ---------------------------------------------------------------------------
CREATE POLICY p_pac_insert_own ON principal.patient_attribute_confirmation
  FOR INSERT TO confirmation_ui_role
  WITH CHECK (subject_id = app.current_user_id()
              AND confirmed_by = app.current_user_id());

-- ---------------------------------------------------------------------------
-- 7. CLASS C is NOT addressed here, on purpose.
--
--    redflag_role, alert_role, metrics_role and confirmation_ui_role remain
--    NOLOGIN with no members, so nothing can assume them and the policies
--    above are still unreachable in production. That is the finding, not an
--    oversight: closing it means choosing between three security models
--    (HP-JOB-007 §5) with materially different behaviour under compromise,
--    and one of them — granting membership to hp_app — is a trap in this
--    cluster, because hp_app has rolinherit = true and would silently acquire
--    every privilege at all times rather than having to assume the role.
--
--    R13 keeps the four findings baselined and red-flagged until that is
--    decided. A migration that quietly picked one would be engineering making
--    a security decision by default, which is exactly the shape of thing this
--    week's work has been removing.
-- ---------------------------------------------------------------------------
