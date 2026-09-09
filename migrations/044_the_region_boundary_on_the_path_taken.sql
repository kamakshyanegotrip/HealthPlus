-- =====================================================================
-- 044 — SEC-2: the region boundary, on the path the readers actually take
--
-- The register carried this as "three pseudonym-bearing tables with no
-- data_region". It is one table — and a larger finding underneath it that the
-- column would not have fixed.
--
-- =====================================================================
-- WHAT WAS ACTUALLY WRONG, IN THREE PARTS
--
-- (1) obs.response_audit — one row per response, carrying subject_pseudonym —
--     has NO data_region, RLS DISABLED, no policy, and `metrics_role` holds
--     SELECT on it. It is the only obs table in that state; ai_call,
--     fabrication_block, review_queue_item and response_content all carry a
--     region already.
--
-- (2) obs.response_content and obs.abstention_event DO carry a region and have
--     RLS off with no policy. A column nothing reads is not a boundary.
--
-- (3) AND THE ONE THAT MATTERS: every view in this database is owned by the
--     schema owner with no `security_invoker`, so it runs as the OWNER and
--     BYPASSES ROW-LEVEL SECURITY ON ITS BASE TABLES. `metrics_role` reads the
--     obs metrics through views. So the two region policies that already exist
--     — p_fb_region_scoped and p_rqi_region_scoped — have never applied on the
--     path anything actually takes.
--
--     Measured, not reasoned. Two fabrication_block rows, one IN and one ZZ,
--     read as metrics_role with app.data_region = 'IN':
--
--       direct table read ......... 1 row   (the policy works)
--       through v_metric_block_rate 2 rows  (the policy is bypassed)
--
--     Adding a column and a policy to response_audit without fixing this would
--     have produced a third control that is correct in isolation and inert in
--     use — which is the shape of nine other findings in this repository.
--
-- =====================================================================
-- WHY security_invoker AND NOT A REGION PREDICATE IN EACH VIEW
--
-- The predicate would state the boundary a second time, in ten places, where it
-- can drift from the policies. `security_invoker` makes the views honour the
-- policies that already exist — one statement of the boundary, honoured on
-- every path, including policies added after this migration.
--
-- It requires the READER to hold SELECT on the base tables, so it can break a
-- view that was deliberately an owner-owned window. Checked, for all ten:
--
--   obs.v_metric_abstention_rate   -> abstention_event, response_audit   metrics_role: yes
--   obs.v_metric_block_rate        -> fabrication_block, response_audit  metrics_role: yes
--   obs.v_metric_coverage          -> safety_metric(+_sample)            metrics_role: yes
--   obs.v_metric_emergency_latency -> safety.red_flag_log                metrics_role: yes
--   obs.v_metric_review_turnaround -> review_queue_item                  metrics_role: yes
--   obs.v_release_gate             -> safety_metric(+_sample)            metrics_role: yes
--   obs.v_review_backlog           -> review_queue_item                  metrics_role: yes
--   safety.v_alert_sla_breach      -> clinician_alert                    alert_role:   yes
--   safety.v_alerts_reaching_nobody-> clinician_alert                    alert_role:   yes
--   safety.v_emergency_display_latency -> red_flag_log                   metrics_role: yes
--
-- No view is a window onto something its reader cannot otherwise read, so none
-- of them loses access. §5 proves that by reading each one as its own role.
--
-- =====================================================================
-- THE FAILURE MODE WHEN THE REGION IS UNSET
--
-- app.current_region() is `nullif(current_setting('app.data_region', true),'')`,
-- so an unset GUC yields NULL, `data_region = NULL` is never true, and a read
-- policy returns ZERO ROWS. For a READ that is the safe direction and this
-- migration keeps it — but it is the same silence SEC-1 called out for the
-- alert worker ("a healthy drain of zero"), so §5 pins it explicitly: unset
-- must yield nothing, not everything. A test that only checks the happy region
-- cannot tell those two apart.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- §0. The finding, recorded before it is fixed.
--
-- REPORTS, and does not raise. migrations/run_migrations.mjs keeps no ledger —
-- it applies every file on every run — so each migration here has to be
-- re-runnable, and a precondition check that raises once the postcondition
-- holds breaks the second run. (042's preamble raises safely because what it
-- checks — reasoner_role holding USAGE on safety — stays false afterwards.
-- This one's checks all become true, which is the difference.)
--
-- The claim that this migration actually repaired something is therefore made
-- by §5 and §6, which measure the boundary rather than the schema's shape, and
-- must hold on every run.
-- ---------------------------------------------------------------------
DO $$
DECLARE has_col boolean; rls_on boolean; leaky integer;
BEGIN
  SELECT EXISTS (SELECT 1 FROM pg_attribute
                  WHERE attrelid = 'obs.response_audit'::regclass
                    AND attname = 'data_region' AND attnum > 0) INTO has_col;
  SELECT relrowsecurity FROM pg_class WHERE oid = 'obs.response_audit'::regclass INTO rls_on;
  SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind = 'v' AND n.nspname IN ('obs','safety')
     AND NOT coalesce(array_to_string(c.reloptions, ',') LIKE '%security_invoker=true%', false)
    INTO leaky;

  IF has_col AND rls_on AND leaky = 0 THEN
    RAISE NOTICE '044: already applied — response_audit is regioned and no view bypasses RLS. Re-asserting.';
  ELSE
    RAISE NOTICE '044: repairing — response_audit data_region=% rls=% ; views bypassing RLS: %',
      has_col, rls_on, leaky;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- §1. obs.response_audit joins the region boundary.
--
-- Shape copied from obs.ai_call exactly — char(2), NOT NULL, FK to
-- region_registry — so there is one spelling of "which region" in this schema
-- and not two.
--
-- THE BACKFILL takes the region from the rows written during the SAME TURN,
-- in the order they are most likely to exist:
--
--   obs.response_content   written on four of the five exit paths
--   safety.red_flag_event  written whenever the scan reached MONITOR+
--   obs.ai_call            written by every turn that called a model
--
-- and finally app.current_region() for a single-region deployment. It does NOT
-- default silently: if a row resolves to nothing, §1b raises and names the
-- count, because guessing a data region is the one thing HP-ADR-004 §2 forbids.
--
-- On a fresh database this is a no-op — which is exactly why the assertion has
-- to be here rather than trusted to a later run on a populated one.
-- ---------------------------------------------------------------------
ALTER TABLE obs.response_audit ADD COLUMN IF NOT EXISTS data_region char(2);

UPDATE obs.response_audit a
   SET data_region = COALESCE(
         (SELECT c.data_region FROM obs.response_content c WHERE c.audit_id = a.id LIMIT 1),
         (SELECT e.data_region FROM safety.red_flag_event e WHERE e.audit_id = a.id LIMIT 1),
         (SELECT k.data_region FROM obs.ai_call k WHERE k.audit_id = a.id LIMIT 1),
         app.current_region())
 WHERE a.data_region IS NULL;

-- §1b. No guessing.
DO $$
DECLARE unresolved bigint;
BEGIN
  SELECT count(*) FROM obs.response_audit WHERE data_region IS NULL INTO unresolved;
  IF unresolved > 0 THEN
    RAISE EXCEPTION
      '044: % response_audit row(s) have no resolvable data region. Nothing written '
      'during their turn names one and app.data_region is unset. Set app.data_region '
      'to this deployment''s region and re-run; do not guess.', unresolved;
  END IF;
END $$;

ALTER TABLE obs.response_audit ALTER COLUMN data_region SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'obs.response_audit'::regclass
                    AND conname = 'response_audit_data_region_fkey') THEN
    ALTER TABLE obs.response_audit
      ADD CONSTRAINT response_audit_data_region_fkey
      FOREIGN KEY (data_region) REFERENCES public.region_registry(code);
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- §2. The writer states the region, and the function checks it.
--
-- obs.record_response_audit is SECURITY DEFINER, so it runs as the owner, and
-- the table is not FORCE ROW LEVEL SECURITY — which means a WITH CHECK policy
-- would NOT bind inside it. Migration 035 hit this exact wall with
-- claim_alert_batch and resolved it the same way: restate the predicate
-- explicitly in the function body, because the policy cannot reach there.
--
-- The caller supplies the region and the function refuses it if it disagrees
-- with the connection's own. That is the same contract p_ai_call_insert_own_region
-- expresses for obs.ai_call, expressed where it can actually apply.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION obs.record_response_audit(
  p_id uuid, p_subject_pseudonym bytea, p_category response_category,
  p_classifier_version text, p_severity red_flag_severity,
  p_rule_id uuid, p_rule_version integer, p_template_id uuid, p_template_version integer,
  p_agg_confidence numeric, p_policy_version text, p_model_version text,
  p_prompt_version text, p_cited_claim_ids uuid[], p_review_state review_state,
  p_clinical_domain text, p_data_region char(2)
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'obs', 'safety', 'public'
AS $$
BEGIN
  -- The connection's region is the deployment's, set in the startup packet by
  -- db.ts and defaulted per role by migration 034 §3. A caller that names a
  -- different one is either misconfigured or is trying to write across the
  -- boundary; both are refused here rather than stored.
  IF app.current_region() IS NULL THEN
    RAISE EXCEPTION
      'HP-ADR-004 §2: app.data_region is not set on this connection, so the region '
      'of this audit row cannot be verified. Every region-scoped predicate would be '
      'false and this response would be invisible to its own deployment (SEC-1).';
  END IF;
  IF p_data_region IS DISTINCT FROM app.current_region() THEN
    RAISE EXCEPTION
      'HP-ADR-004 §2: audit row claims region % on a connection serving %.',
      p_data_region, app.current_region();
  END IF;

  INSERT INTO obs.response_audit
    (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
     rule_id, rule_version, template_id, template_version, agg_confidence,
     policy_version, model_version, prompt_version, cited_claim_ids,
     review_state, clinical_domain, data_region)
  VALUES
    (p_id, p_subject_pseudonym, now(), p_category, p_classifier_version, p_severity,
     p_rule_id, p_rule_version, p_template_id, p_template_version, p_agg_confidence,
     p_policy_version, p_model_version, p_prompt_version, coalesce(p_cited_claim_ids, '{}'),
     p_review_state, p_clinical_domain, p_data_region)
  ON CONFLICT (id) DO NOTHING;
END $$;

-- The 16-argument form is dropped rather than left beside the new one: an
-- overload that silently omits the region is the thing this migration exists to
-- remove, and `DROP ... IF EXISTS` on the exact signature cannot take the new one
-- by accident.
DROP FUNCTION IF EXISTS obs.record_response_audit(
  uuid, bytea, response_category, text, red_flag_severity, uuid, integer, uuid,
  integer, numeric, text, text, text, uuid[], review_state, text);

-- Migration 040's rule L: a SECURITY DEFINER function is not executable by PUBLIC.
REVOKE ALL ON FUNCTION obs.record_response_audit(
  uuid, bytea, response_category, text, red_flag_severity, uuid, integer, uuid,
  integer, numeric, text, text, text, uuid[], review_state, text, char(2)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION obs.record_response_audit(
  uuid, bytea, response_category, text, red_flag_severity, uuid, integer, uuid,
  integer, numeric, text, text, text, uuid[], review_state, text, char(2)) TO hp_app;

-- ---------------------------------------------------------------------
-- §3. The three obs tables that carry subject-derived rows and no policy.
--
-- Same predicate as p_fb_region_scoped and p_rqi_region_scoped, deliberately —
-- a boundary spelled two ways is a boundary that will diverge.
--
-- RLS only, not FORCE: the DEFINER writers run as the owner and must keep
-- working. What FORCE would add is covered for patient_attribute by
-- r10d_attr.sh §4 and is a separate question from this one.
-- ---------------------------------------------------------------------
ALTER TABLE obs.response_audit    ENABLE ROW LEVEL SECURITY;
ALTER TABLE obs.abstention_event  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_ra_region_scoped ON obs.response_audit;
CREATE POLICY p_ra_region_scoped ON obs.response_audit
  FOR SELECT USING (data_region = app.current_region());

-- obs.response_content gets RLS AND NO POLICY, deliberately, and the grant
-- contract is what settled it.
--
-- A policy was written here first. Rule M caught it immediately: no application
-- role holds ANY privilege on this table, so the policy protected nothing and
-- was exactly the shape that rule exists to report — a control written in the
-- belief it was doing something. Baselining my own new violation to keep it
-- would have been worse than not writing it.
--
-- RLS ON with no policy is the right default here, not RLS off. With RLS off, a
-- future GRANT SELECT silently exposes every region's stored responses and no
-- rule fires, because there is no policy to be missing. With RLS on, that same
-- grant returns zero rows — fail-closed — and rule B ("a grant on an
-- RLS-enabled table needs a policy permitting that command") demands the policy
-- at the moment there is finally a reader to test it against.
ALTER TABLE obs.response_content ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_rc_region_scoped ON obs.response_content;

DROP POLICY IF EXISTS p_ae_region_scoped ON obs.abstention_event;
CREATE POLICY p_ae_region_scoped ON obs.abstention_event
  FOR SELECT USING (data_region = app.current_region());

-- ---------------------------------------------------------------------
-- §4. THE LEAK. Every view honours its base tables' policies.
--
-- Enumerated from pg_class rather than listed by hand, for the same reason
-- migration 040 enumerated the definer functions: a hand-written list that
-- forgets one entry is the entire finding restated.
-- ---------------------------------------------------------------------
DO $$
DECLARE v record;
BEGIN
  FOR v IN
    SELECT n.nspname, c.relname
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind = 'v' AND n.nspname IN ('obs','safety')
  LOOP
    EXECUTE format('ALTER VIEW %I.%I SET (security_invoker = true)', v.nspname, v.relname);
    RAISE NOTICE '044: %.% now runs as its caller', v.nspname, v.relname;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- §5. The proof — the same measurement that found this, now expecting the
--     boundary to hold on BOTH paths, and to hold CLOSED when unset.
--
-- Fixtures live and die inside this transaction. ZZ is migration 019's sentinel
-- for reference data with no data subject; it is used here only as "a region
-- that is not ours" and nothing is left behind in it — two CI gates once seeded
-- real safety events there and nobody noticed for weeks.
-- ---------------------------------------------------------------------
--
-- THE MEASUREMENT IS A COMPARISON, NOT A CONSTANT. The first version of this
-- asserted `sum(denominator) = 1` and failed at 2 — correctly, but for the
-- wrong reason: the view aggregates every visible row, not just this block's
-- fixtures, and the database already held an audit row from earlier today. A
-- hardcoded count makes a fixture's isolation part of the claim. Comparing the
-- SAME quantity down both paths does not, and it is the actual property under
-- test: whatever the direct read can see, the view must see exactly that.
DO $$
DECLARE direct_in integer; direct_total integer; via_view integer;
        unset_direct integer; other_region char(2);
BEGIN
  SELECT code INTO other_region FROM public.region_registry
   WHERE code <> COALESCE(app.current_region(), 'IN') ORDER BY code LIMIT 1;
  IF other_region IS NULL THEN
    RAISE NOTICE '044 §5: only one region is registered; the cross-region half cannot be measured here.';
    RETURN;
  END IF;

  PERFORM set_config('app.data_region', 'IN', true);

  INSERT INTO obs.response_audit
    (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
     agg_confidence, policy_version, model_version, prompt_version, cited_claim_ids,
     review_state, data_region)
  VALUES ('00000044-0000-0000-0000-000000000001', sha256('044a'::bytea), now(),
          'INFORMATIONAL','c','NORMAL',0.90,'pv','m','p','{}','NOT_REQUIRED','IN'),
         ('00000044-0000-0000-0000-000000000002', sha256('044b'::bytea), now(),
          'INFORMATIONAL','c','NORMAL',0.90,'pv','m','p','{}','NOT_REQUIRED', other_region);

  SET LOCAL SESSION AUTHORIZATION metrics_role;
  SELECT count(*) INTO direct_in FROM obs.response_audit
   WHERE id IN ('00000044-0000-0000-0000-000000000001','00000044-0000-0000-0000-000000000002');
  RESET SESSION AUTHORIZATION;

  IF direct_in <> 1 THEN
    RAISE EXCEPTION '044 §5: metrics_role saw % of the 2 seeded audit rows on a direct read; expected 1 (its own region).', direct_in;
  END IF;

  -- The same quantity, down both paths. v_metric_block_rate's `audited` CTE
  -- counts obs.response_audit per day, so summing its denominator over the
  -- undimensioned branch is exactly "how many audit rows can this reader see" —
  -- the number the direct read above answers for itself. Before this migration
  -- the direct read scoped and the view did not, so the two disagreed by
  -- however many rows the other region held.
  SET LOCAL SESSION AUTHORIZATION metrics_role;
  SELECT count(*) INTO direct_total FROM obs.response_audit;
  SELECT coalesce(sum(denominator), 0) INTO via_view
    FROM obs.v_metric_block_rate WHERE dimension IS NULL;
  RESET SESSION AUTHORIZATION;

  IF via_view <> direct_total THEN
    RAISE EXCEPTION
      '044 §5: v_metric_block_rate counted % audit row(s) where a direct read by the '
      'same role sees %. The view is still bypassing the policy — check security_invoker.',
      via_view, direct_total;
  END IF;

  -- And the silence. An unset region must return NOTHING, not everything: those
  -- two outcomes are indistinguishable to a test that only checks its own region.
  PERFORM set_config('app.data_region', '', true);
  SET LOCAL SESSION AUTHORIZATION metrics_role;
  SELECT count(*) INTO unset_direct FROM obs.response_audit
   WHERE id IN ('00000044-0000-0000-0000-000000000001','00000044-0000-0000-0000-000000000002');
  RESET SESSION AUTHORIZATION;

  IF unset_direct <> 0 THEN
    RAISE EXCEPTION '044 §5: with app.data_region unset, metrics_role saw % row(s); expected 0.', unset_direct;
  END IF;

  PERFORM set_config('app.data_region', 'IN', true);
  DELETE FROM obs.response_audit
   WHERE id IN ('00000044-0000-0000-0000-000000000001','00000044-0000-0000-0000-000000000002');

  RAISE NOTICE
    '044 §5: of 2 seeded rows in 2 regions metrics_role sees %; direct total % = view total %; unset sees %.',
    direct_in, direct_total, via_view, unset_direct;
END $$;

-- ---------------------------------------------------------------------
-- §6. No view is left behind.
-- ---------------------------------------------------------------------
DO $$
DECLARE leaky text[];
BEGIN
  SELECT array_agg(n.nspname || '.' || c.relname ORDER BY 1)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind = 'v' AND n.nspname NOT IN ('pg_catalog','information_schema')
     AND NOT coalesce(array_to_string(c.reloptions, ',') LIKE '%security_invoker=true%', false)
    INTO leaky;

  IF leaky IS NOT NULL THEN
    RAISE EXCEPTION
      '044 §6: % still run(s) as its owner and bypasses row-level security on its '
      'base tables. A view is a path readers take; a policy that does not apply on '
      'it is not a boundary.', array_to_string(leaky, ', ');
  END IF;
END $$;

COMMIT;
