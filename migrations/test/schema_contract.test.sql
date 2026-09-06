-- ============================================================================
-- Schema contract tests — run against the REAL migrations (001..027)
--
-- These exist because HP-RECON-001 found two Charter guarantees that the
-- chat-pipeline stub schema could not express, and which therefore had never
-- been exercised anywhere:
--
--   1. §1.5.3's tier x claim_kind matrix. The stub's claim_kind enum carries
--      10 of 15 values, so its claim_policy could only ever hold 150 of the
--      225 rows, and CLINICAL_EFFICACY and REFERENCE_RANGE — two of the most
--      safety-critical kinds in the Charter — had no policy rows at all.
--
--   2. ADR-003 §2.4 / migration 018's c_salt_dies_with_key. The stub's
--      subject_key has key_material/revoked_at instead of salt/wrapped_dek/
--      destroyed_at, so it cannot represent the constraint at all. B4-legal's
--      technical half was recorded as done on the strength of the design; no
--      test had ever run it.
--
-- Run with: psql -v ON_ERROR_STOP=1 -f schema_contract.test.sql
-- Any failure raises and aborts. Silence is success.
-- ============================================================================

\set ON_ERROR_STOP on

-- One transaction for the whole file: the subject_key cases below insert a
-- fixture, and CI must be able to run this repeatedly against the same database
-- without the second run tripping over the first run's rows.
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. §1.5.3 — the tier x kind x category matrix is complete
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  n_rows   int;
  n_kinds  int;
  n_tiers  int;
  n_cats   int;
BEGIN
  SELECT count(*) INTO n_rows FROM evidence.claim_policy;
  ASSERT n_rows = 225,
    format('claim_policy must hold 225 rows (5 tiers x 15 kinds x 3 categories); found %s', n_rows);

  SELECT count(DISTINCT kind), count(DISTINCT tier), count(DISTINCT category)
    INTO n_kinds, n_tiers, n_cats FROM evidence.claim_policy;
  ASSERT n_kinds = 15, format('expected 15 claim kinds, found %s', n_kinds);
  ASSERT n_tiers = 5,  format('expected 5 source tiers, found %s', n_tiers);
  ASSERT n_cats  = 3,  format('expected 3 response categories, found %s', n_cats);
END $$;

-- The five kinds the stub schema could not express at all.
DO $$
DECLARE k text; c int;
BEGIN
  FOREACH k IN ARRAY ARRAY['CLINICAL_EFFICACY','REFERENCE_RANGE','ELIGIBILITY','LOGISTICS','SENTIMENT']
  LOOP
    SELECT count(*) INTO c FROM evidence.claim_policy WHERE kind = k::claim_kind;
    ASSERT c = 15, format('claim_kind %s must have 15 policy rows (5 tiers x 3 categories); found %s', k, c);
  END LOOP;
END $$;

-- §1.5.3: "A Tier 5 source MUST NOT be used as the basis for any statement
-- about: clinical efficacy or safety; ... test interpretation; ... reference
-- ranges" — so TIER_5 is PROHIBITED for these kinds in EVERY category.
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
    FROM evidence.claim_policy
   WHERE tier = 'TIER_5'
     AND kind IN ('CLINICAL_EFFICACY','REFERENCE_RANGE','TEST_INTERPRETATION','ELIGIBILITY')
     AND disposition <> 'PROHIBITED';
  ASSERT bad = 0,
    format('§1.5.3: TIER_5 must be PROHIBITED for clinical kinds in every category; %s row(s) are not', bad);
END $$;

-- §1.4.4: provider-supplied clinical claims are capped, never presented as fact.
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad
    FROM evidence.claim_policy
   WHERE tier = 'TIER_4' AND kind = 'PROVIDER_OUTCOME'
     AND (disposition = 'PERMITTED' AND (confidence_cap IS NULL OR confidence_cap > 0.40));
  ASSERT bad = 0,
    format('§1.4.4: TIER_4 PROVIDER_OUTCOME must be capped at 0.40 or prohibited; %s row(s) are not', bad);
END $$;

-- ---------------------------------------------------------------------------
-- 2. ADR-003 §2.4 — c_salt_dies_with_key actually enforces
--
-- "a pseudonym you can still recompute from a user id is re-identifiable, and
-- therefore still personal data". The constraint makes the destroyed state the
-- ONLY state in which salt may be NULL, and the only state in which it may not
-- be present. These four cases are the whole guarantee.
-- ---------------------------------------------------------------------------
-- subject_key.subject_id is NOT NULL and FKs to principal.app_user, and
-- app_user.data_region FKs to region_registry — so the fixture has to be built
-- before the constraint can be exercised. Everything here runs inside the
-- surrounding transaction and is rolled back.
DO $$
DECLARE ok boolean; uid uuid := 'bbbbbbbb-0000-4000-8000-000000000001';
BEGIN
  INSERT INTO principal.app_user (id, auth_subject, data_region) VALUES (uid, 'schema-contract-test', 'IN')
    ON CONFLICT DO NOTHING;

  -- (a) live key: salt and wrapped_dek present, destroyed_at null — ACCEPTED
  BEGIN
    INSERT INTO principal.subject_key (id, subject_id, salt, wrapped_dek, destroyed_at)
      VALUES ('aaaaaaaa-0000-4000-8000-000000000001', uid, '\x01'::bytea, '\x02'::bytea, NULL);
    ok := true;
  EXCEPTION WHEN check_violation THEN ok := false;
  END;
  ASSERT ok, 'a live subject_key with salt + wrapped_dek must be accepted';
  DELETE FROM principal.subject_key WHERE subject_id = uid;

  -- (b) destroyed key: salt and wrapped_dek NULL, destroyed_at set — ACCEPTED
  BEGIN
    INSERT INTO principal.subject_key (id, subject_id, salt, wrapped_dek, destroyed_at)
      VALUES ('aaaaaaaa-0000-4000-8000-000000000002', uid, NULL, NULL, now());
    ok := true;
  EXCEPTION WHEN check_violation THEN ok := false;
  END;
  ASSERT ok, 'a destroyed subject_key with salt and wrapped_dek nulled must be accepted';
  DELETE FROM principal.subject_key WHERE subject_id = uid;

  -- (c) THE ONE THAT MATTERS: destroyed, but the salt survived — REJECTED.
  -- This is the state in which erasure has been performed on paper while every
  -- pseudonym remains recomputable from a user id in practice. ADR-003 §2.4
  -- names exactly this: "a pseudonym you can still recompute from a user id is
  -- re-identifiable, and therefore still personal data."
  BEGIN
    INSERT INTO principal.subject_key (id, subject_id, salt, wrapped_dek, destroyed_at)
      VALUES ('aaaaaaaa-0000-4000-8000-000000000003', uid, '\x01'::bytea, NULL, now());
    ok := true;
  EXCEPTION WHEN check_violation THEN ok := false;
  END;
  ASSERT NOT ok,
    'ADR-003 §2.4: a DESTROYED subject_key that still carries its salt must be rejected — '
    'erasure that leaves the salt behind is not erasure';

  -- (d) live key with no salt — REJECTED (nothing to pseudonymise with)
  BEGIN
    INSERT INTO principal.subject_key (id, subject_id, salt, wrapped_dek, destroyed_at)
      VALUES ('aaaaaaaa-0000-4000-8000-000000000004', uid, NULL, '\x02'::bytea, NULL);
    ok := true;
  EXCEPTION WHEN check_violation THEN ok := false;
  END;
  ASSERT NOT ok, 'a live subject_key with a NULL salt must be rejected';

  RAISE NOTICE 'c_salt_dies_with_key: all four states behave as ADR-003 2.4 requires';
END $$;

-- ---------------------------------------------------------------------------
-- 3. The engine's own queries must PARSE against this schema (R2/R3)
--
-- Two production bugs came from the pipeline querying columns that exist only
-- in the chat-pipeline stub and not in the committed schema:
--
--   safety_template.active        -> loadSafetyTemplate() raised, its catch
--                                    swallowed the error, and every
--                                    CRITICAL/EMERGENCY silently rendered an
--                                    unapproved hard-coded fallback.
--   red_flag_rule.ruleset_version -> matchDeterministicRules() raised.
--
-- A third, safety_template.clinically_adopted, was caught during R2 only
-- because these queries were run against both schemas by hand. This section
-- makes that check permanent. It asserts nothing about ROWS — the real schema
-- is correctly empty until CL2 is signed — only that every column the engine
-- names exists here. Zero rows is a pass; a missing column is a failure.
-- ---------------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
  -- matchDeterministicRules(), verbatim in shape
  SELECT count(*) INTO n FROM (
    SELECT r.id, r.version, r.severity, r.pattern, r.clinically_adopted, s.rule_set_id
      FROM safety.adopted_rule_set('IN', 'en') s
      JOIN safety.red_flag_rule r
        ON r.rule_set_id = s.rule_set_id
       AND r.clinically_adopted = true
       AND r.retired_at IS NULL
  ) q;

  -- lookupTemplate(), the §4.3.3 ladder's single rung
  SELECT count(*) INTO n FROM (
    SELECT id, version, severity, jurisdiction, language, body, slots,
           is_fallback, machine_translated
      FROM safety.safety_template
     WHERE severity = 'CRITICAL' AND jurisdiction = 'IN' AND language = 'en'
     ORDER BY version DESC LIMIT 1
  ) q;

  -- recordRedFlagEvent(), every column the INSERT names
  SELECT count(*) INTO n FROM (
    SELECT id, audit_id, subject_pseudonym, session_pseudonym, occurred_at, severity,
           rule_id, rule_version, rule_set_id, trigger_detail, template_id, template_version,
           action_taken, commercial_suppressed, first_byte_at, scanner_started_at,
           template_displayed_at, data_region
      FROM safety.red_flag_event
  ) q;

  -- recordRedFlagLog(), likewise
  SELECT count(*) INTO n FROM (
    SELECT id, event_id, audit_id, subject_pseudonym, session_pseudonym, occurred_at,
           rule_derived_severity, model_proposed_severity, applied_severity,
           context_escalation, rule_set_id, matched_rule_ids, trigger_detail, query_hash,
           branch, template_id, template_version, commercial_suppressed, generation_blocked,
           needs_review, shadow_mode, first_byte_at, scanner_started_at, scanner_completed_at,
           template_displayed_at, display_latency_ms, scanner_version, fail_safe_reason, data_region
      FROM safety.red_flag_log
  ) q;

  RAISE NOTICE 'engine queries parse against this schema';
END $$;

-- §4.0.3 / R3: the pattern column is jsonb, not text. A regex cannot express a
-- unit-checked threshold, and §3.5.3 forbids coercing across units.
DO $$
DECLARE t text;
BEGIN
  SELECT data_type INTO t FROM information_schema.columns
   WHERE table_schema='safety' AND table_name='red_flag_rule' AND column_name='pattern';
  ASSERT t = 'jsonb', format('red_flag_rule.pattern must be jsonb (§4.0.3); found %s', t);
END $$;

-- R2: a template is identified by (severity, jurisdiction, language, version),
-- never by a foreign key from the rule.
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema='safety' AND table_name='red_flag_rule'
     AND column_name IN ('template_id','template_version');
  ASSERT n = 0,
    'red_flag_rule must not carry a template FK — §4.3.3 resolves templates by '
    '(severity, jurisdiction, language)';
END $$;


-- R12 / HP-RECON-001 §2b: privileges, not just columns.
--
-- Every assertion above this line checks that a column EXISTS. None of them
-- checks that the role running the module may READ or WRITE it, and that gap
-- has now produced two production bugs — a missing SELECT on red_flag_rule_set
-- (stub, false RED) and a missing UPDATE on session_severity_floor's two clear
-- columns (this schema, false GREEN, every red_flag_event write failing at plan
-- time). A schema is not a contract until the grants are part of it.
DO $$
DECLARE
  missing text[] := '{}';
  c       text;
BEGIN
  -- Reads. adopted_rule_set() is LANGUAGE sql STABLE — invoker's rights — so
  -- red_flag_rule_set is read as the CALLER, which is why it must be listed.
  FOREACH c IN ARRAY ARRAY[
    'safety.red_flag_rule', 'safety.red_flag_rule_set', 'safety.safety_template',
    'safety.emergency_contact_reference', 'safety.emergency_facility_reference',
    'safety.red_flag_event', 'safety.red_flag_log', 'safety.session_severity_floor'
  ] LOOP
    IF NOT has_table_privilege('redflag_role', c, 'SELECT') THEN
      missing := missing || (c || ':SELECT');
    END IF;
  END LOOP;

  -- Writes the module actually issues.
  FOREACH c IN ARRAY ARRAY[
    'safety.red_flag_event', 'safety.red_flag_log', 'safety.session_severity_floor'
  ] LOOP
    IF NOT has_table_privilege('redflag_role', c, 'INSERT') THEN
      missing := missing || (c || ':INSERT');
    END IF;
  END LOOP;

  -- The §4.0.8 floor. recordRedFlagEvent's upsert re-arms a cleared floor
  -- (cleared_at = NULL, cleared_by = NULL) and clearSessionSeverityFloor writes
  -- those two columns alone; PostgreSQL checks column UPDATE privilege at PLAN
  -- time, so a missing one fails every write, not just the conflicting ones.
  FOREACH c IN ARRAY ARRAY[
    'floor_severity', 'set_by_event_id', 'set_at', 'cleared_at', 'cleared_by'
  ] LOOP
    IF NOT has_column_privilege('redflag_role', 'safety.session_severity_floor', c, 'UPDATE') THEN
      missing := missing || ('session_severity_floor.' || c || ':UPDATE');
    END IF;
  END LOOP;

  -- And the one the scanner must NOT have: moving a floor between sessions.
  IF has_column_privilege('redflag_role', 'safety.session_severity_floor', 'session_pseudonym', 'UPDATE') THEN
    missing := missing || 'session_severity_floor.session_pseudonym:UPDATE MUST NOT BE GRANTED'::text;
  END IF;

  -- §4.0.3: a scanner that can edit its own rules is not a control.
  FOREACH c IN ARRAY ARRAY[
    'safety.red_flag_rule', 'safety.red_flag_rule_set', 'safety.safety_template'
  ] LOOP
    IF has_table_privilege('redflag_role', c, 'INSERT')
       OR has_table_privilege('redflag_role', c, 'UPDATE')
       OR has_table_privilege('redflag_role', c, 'DELETE') THEN
      missing := missing || (c || ':WRITE MUST NOT BE GRANTED');
    END IF;
  END LOOP;

  -- HP-RB-001 append-only.
  IF has_table_privilege('redflag_role', 'safety.red_flag_log', 'UPDATE')
     OR has_table_privilege('redflag_role', 'safety.red_flag_log', 'DELETE') THEN
    missing := missing || 'red_flag_log:UPDATE/DELETE MUST NOT BE GRANTED'::text;
  END IF;

  ASSERT array_length(missing, 1) IS NULL,
    format('redflag_role grant contract violated: %s', array_to_string(missing, ', '));
  RAISE NOTICE 'redflag_role grants match what the module issues';
END $$;


-- HP-DR-002 / §2.4.2 — the transplant commercial block (migration 028).
--
-- Structure alone proves nothing here: the question is whether the trigger
-- actually refuses, on the paths the schema actually has. The first draft of
-- migration 028 guarded entity types 'treatment'/'procedure'/'surgery' and was
-- unfireable, because migration 020's registry declares no commercial contract
-- on any of them — every commercial contract that can reach a treatment runs
-- through the PROVIDER side. That was found by running this test, not by
-- reading the migration, which is the entire reason it builds real rows.
DO $$
DECLARE
  v_org        uuid := gen_random_uuid();
  v_hospital   uuid := gen_random_uuid();
  v_tx         uuid := gen_random_uuid();   -- a transplant treatment
  v_ord        uuid := gen_random_uuid();   -- an ordinary one
  v_ht_tx      uuid := gen_random_uuid();
  v_ht_ord     uuid := gen_random_uuid();
  v_cost_tx    uuid := gen_random_uuid();
  v_cost_ord   uuid := gen_random_uuid();
  v_claim_cost uuid := gen_random_uuid();
  v_claim_avail uuid := gen_random_uuid();
  v_claim_edu  uuid := gen_random_uuid();
  v_msg        text;
  v_blocked    boolean;
BEGIN
  INSERT INTO domain.country (code, name) VALUES ('IN', 'India')
    ON CONFLICT (code) DO NOTHING;
  INSERT INTO principal.provider_org (id, legal_name, country, status)
    VALUES (v_org, 'DR-002 Test Hospital Group', 'IN', 'ACTIVE');
  INSERT INTO domain.hospital (id, provider_org_id, slug, legal_name, display_name, country_code)
    VALUES (v_hospital, v_org, 'dr002-test-hospital', 'DR-002 Test Hospital',
            'DR-002 Test Hospital', 'IN');

  INSERT INTO domain.treatment (id, slug, name, kind, involves_donated_organ_or_tissue)
  VALUES (v_tx,  'dr002-liver-transplant', 'Liver transplantation', 'SURGERY', true),
         (v_ord, 'dr002-hip-replacement',  'Hip replacement',       'SURGERY', false);

  INSERT INTO domain.hospital_treatment (id, hospital_id, treatment_id)
  VALUES (v_ht_tx, v_hospital, v_tx), (v_ht_ord, v_hospital, v_ord);

  INSERT INTO domain.hospital_cost
      (id, hospital_id, hospital_treatment_id, currency, scope_key,
       inclusions_stated, exclusions_stated)
  VALUES (v_cost_tx,  v_hospital, v_ht_tx,  'INR', 'ALL_IN', true, true),
         (v_cost_ord, v_hospital, v_ht_ord, 'INR', 'ALL_IN', true, true);

  INSERT INTO evidence.claim (id, kind, statement, expires_at)
    VALUES (v_claim_cost, 'COST', 'Package price is 100 INR.', current_date + 30);
  INSERT INTO evidence.claim (id, kind, statement)
    VALUES (v_claim_avail, 'LOGISTICS', 'Next available slot is in three weeks.'),
           (v_claim_edu, 'GENERAL_EDUCATION', 'A liver transplant replaces a diseased liver.');

  -- 1. The flagship path: a COST claim on a transplant hospital_cost row,
  --    resolved two hops through hospital_treatment. Assert on the MESSAGE,
  --    not merely that something raised — three BEFORE triggers sit on this
  --    table and a test that accepts any exception cannot tell which one fired.
  v_blocked := false;
  BEGIN
    INSERT INTO evidence.domain_attribute (id, entity_type, entity_id, attribute, claim_id)
    VALUES (gen_random_uuid(), 'hospital_cost', v_cost_tx, 'amount', v_claim_cost);
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    v_blocked := v_msg LIKE '%HP-DR-002%';
  END;
  ASSERT v_blocked,
    'HP-DR-002: a COST claim on a transplant hospital_cost row was accepted, or was '
    'refused by a different trigger. Message: ' || COALESCE(v_msg, '(none)');

  -- 2. hospital_treatment.availability is declared LOGISTICS, not COST. Kind
  --    filtering alone would let it through — and "this hospital performs liver
  --    transplants, next slot in three weeks" is routing a patient to a
  --    transplant centre, which HP-DR-002 §1 names explicitly.
  v_blocked := false; v_msg := NULL;
  BEGIN
    INSERT INTO evidence.domain_attribute (id, entity_type, entity_id, attribute, claim_id)
    VALUES (gen_random_uuid(), 'hospital_treatment', v_ht_tx, 'availability', v_claim_avail);
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    v_blocked := v_msg LIKE '%HP-DR-002%';
  END;
  ASSERT v_blocked,
    'HP-DR-002: a non-commercial claim kind on a provider-commercial transplant entity '
    'was accepted — the block is filtering on claim kind alone. Message: ' || COALESCE(v_msg, '(none)');

  -- 3. NEGATIVE CONTROL. The identical COST claim binds fine to an ordinary
  --    treatment's cost row. If this ever fails, the block has stopped being
  --    conditional and is suppressing pricing across the whole product.
  INSERT INTO evidence.domain_attribute (id, entity_type, entity_id, attribute, claim_id)
  VALUES (gen_random_uuid(), 'hospital_cost', v_cost_ord, 'amount', v_claim_cost);

  -- 4. NEGATIVE CONTROL. Reference content ABOUT a transplant is permitted —
  --    HP-DR-002 §1 blocks the commercial engine, not the subject. If this
  --    fails, a transplant patient is left with nothing at all.
  INSERT INTO evidence.domain_attribute (id, entity_type, entity_id, attribute, claim_id)
  VALUES (gen_random_uuid(), 'treatment', v_tx, 'description', v_claim_edu);

  RAISE NOTICE 'HP-DR-002: transplant commercial block holds, reference content still permitted';
END $$;

-- The flag has no default, on purpose: a new treatment must state whether it
-- involves a donated organ rather than inheriting a silent false. "Nobody
-- thought about it" has to be a failed insert, not a quiet mis-classification.
DO $$
DECLARE v_blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO domain.treatment (id, slug, name, kind)
    VALUES (gen_random_uuid(), 'dr002-unstated', 'Treatment with no stated donor status', 'SURGERY');
  EXCEPTION WHEN not_null_violation THEN v_blocked := true;
  END;
  ASSERT v_blocked,
    'domain.treatment.involves_donated_organ_or_tissue accepted an insert that did not '
    'state it — migration 028''s DROP DEFAULT has been undone';
  RAISE NOTICE 'involves_donated_organ_or_tissue must be stated explicitly';
END $$;


ROLLBACK;

-- ############################################################################
-- RF6 — CLINICIAN ALERT DELIVERY (migration 029)
--
-- The bug this closes: worker/side-effect-worker.mjs marked an
-- EMERGENCY_CONCURRENT_NOTIFY job DONE after writing a console.log, and
-- red_flag_event.clinician_notified_at was never written by anything. A
-- response that paged nobody recorded exactly the same state as one that
-- reached a clinician.
--
-- These assertions test the RULE, not the DDL: that the database refuses to
-- record a delivery that did not happen. Every one of them fails if a future
-- change makes "alerted" reachable without a person on the other end.
-- ############################################################################

BEGIN;

-- Fixture: a clinician, a region, an audit and an EMERGENCY event.
DO $$
DECLARE
  v_user     uuid := gen_random_uuid();
  v_region   char(2);
  v_tmpl     uuid := gen_random_uuid();
  v_audit    uuid;
  v_event    uuid := gen_random_uuid();
  v_low      uuid := gen_random_uuid();
  v_alert    uuid;
  v_blocked  boolean;
  v_state    text;
  v_notified timestamptz;
  v_reason   text;
  v_n        int;
BEGIN
  SELECT code INTO v_region FROM public.region_registry LIMIT 1;
  ASSERT v_region IS NOT NULL, 'no region_registry rows — fixture cannot be built';

  INSERT INTO principal.app_user (id, auth_subject, data_region)
  VALUES (v_user, 'rf6-' || v_user::text, v_region);
  INSERT INTO principal.clinician (user_id, full_name, primary_jurisdiction)
  VALUES (v_user, 'RF6 fixture clinician', v_region);

  -- URGENT+ events carry c_urgent_needs_template. A fixture template, not a
  -- real one: this suite tests the alert path, not template governance.
  INSERT INTO safety.safety_template
    (id, version, severity, jurisdiction, language, body, slots, approved_by, approved_at)
  VALUES (v_tmpl, 1, 'EMERGENCY', v_region, 'en', 'RF6 fixture body', '{}'::jsonb, v_user, now());

  -- ---------------------------------------------------------------------
  -- 1a. §4.1 levels 3-5 — raising is automatic. No application call.
  --     The previous design enqueued a job from a fire-and-forget path, so
  --     the alert existed only if that path ran. This asserts it now exists
  --     because the event does.
  -- ---------------------------------------------------------------------
  INSERT INTO safety.red_flag_event
    (id, subject_pseudonym, session_pseudonym, occurred_at, severity,
     trigger_detail, template_id, template_version, action_taken,
     commercial_suppressed, first_byte_at, template_displayed_at, data_region)
  VALUES
    (v_event, '\x00'::bytea, '\x00'::bytea, now(), 'CRITICAL',
     '{}'::jsonb, v_tmpl, 1, 'TEMPLATE', true, now(), now(), v_region);

  SELECT count(*) INTO v_n FROM safety.clinician_alert WHERE event_id = v_event;
  ASSERT v_n = 1,
    'a CRITICAL red_flag_event did not automatically raise a clinician_alert. '
    'trg_raise_alert_for_event is missing or did not fire, and raising an alert '
    'is once again something application code has to remember to do.';

  -- ...and levels 0-2 must NOT raise one. §4.1 gives MONITOR and WARNING no
  -- mandatory notification; raising alerts nobody owes an answer to is how a
  -- real alert gets lost in noise.
  INSERT INTO safety.red_flag_event
    (id, subject_pseudonym, session_pseudonym, occurred_at, severity,
     trigger_detail, action_taken,
     commercial_suppressed, first_byte_at, template_displayed_at, data_region)
  VALUES
    (v_low, '\x02'::bytea, '\x02'::bytea, now(), 'MONITOR',
     '{}'::jsonb, 'NONE', true, now(), now(), v_region);
  SELECT count(*) INTO v_n FROM safety.clinician_alert WHERE event_id = v_low;
  ASSERT v_n = 0,
    format('a MONITOR event raised %s clinician alert(s). §4.1 levels 0-2 carry no '
           'mandatory notification.', v_n);

  RAISE NOTICE 'RF6: URGENT+ raises an alert automatically, MONITOR does not';
END $$;

ROLLBACK;

BEGIN;

-- ---------------------------------------------------------------------------
-- 1b. The coupling does not rest on that trigger alone. With auto-raise
--     disabled, the DEFERRABLE constraint trigger must still refuse the event
--     at commit. Two independent mechanisms: one creates the row, the other
--     forbids the event without it.
--
--     Its own transaction because ALTER TABLE ... DISABLE TRIGGER cannot run
--     while deferred trigger events are pending, and 1a leaves some.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user    uuid := gen_random_uuid();
  v_region  char(2);
  v_tmpl    uuid := gen_random_uuid();
  v_blocked boolean := false;
BEGIN
  SELECT code INTO v_region FROM public.region_registry LIMIT 1;
  INSERT INTO principal.app_user (id, auth_subject, data_region)
  VALUES (v_user, 'rf6-' || v_user::text, v_region);
  INSERT INTO principal.clinician (user_id, full_name, primary_jurisdiction)
  VALUES (v_user, 'RF6 backstop clinician', v_region);
  INSERT INTO safety.safety_template
    (id, version, severity, jurisdiction, language, body, slots, approved_by, approved_at)
  VALUES (v_tmpl, 1, 'EMERGENCY', v_region, 'en', 'RF6 fixture body', '{}'::jsonb, v_user, now());

  ALTER TABLE safety.red_flag_event DISABLE TRIGGER trg_raise_alert_for_event;

  BEGIN
    INSERT INTO safety.red_flag_event
      (id, subject_pseudonym, session_pseudonym, occurred_at, severity,
       trigger_detail, template_id, template_version, action_taken,
       commercial_suppressed, first_byte_at, template_displayed_at, data_region)
    VALUES
      (gen_random_uuid(), '\\x03'::bytea, '\\x03'::bytea, now(), 'CRITICAL',
       '{}'::jsonb, v_tmpl, 1, 'TEMPLATE', true, now(), now(), v_region);
    SET CONSTRAINTS safety.trg_event_requires_alert IMMEDIATE;
  EXCEPTION WHEN raise_exception THEN
    v_blocked := true;
  END;

  ASSERT v_blocked,
    'HP-ESC 4.1: with auto-raise disabled, a CRITICAL red_flag_event was still '
    'accepted with no clinician_alert row. The backstop constraint is gone, so a '
    'single dropped trigger now silently returns the platform to alerting nobody.';
  RAISE NOTICE 'RF6: the backstop constraint holds when auto-raise is disabled';
END $$;

ROLLBACK;

BEGIN;

DO $$
DECLARE
  v_user     uuid := gen_random_uuid();
  v_region   char(2);
  v_tmpl     uuid := gen_random_uuid();
  v_event    uuid := gen_random_uuid();
  v_alert    uuid;
  v_blocked  boolean;
  v_state    text;
  v_notified timestamptz;
  v_n        int;
BEGIN
  SELECT code INTO v_region FROM public.region_registry LIMIT 1;
  INSERT INTO principal.app_user (id, auth_subject, data_region)
  VALUES (v_user, 'rf6-' || v_user::text, v_region);
  INSERT INTO principal.clinician (user_id, full_name, primary_jurisdiction)
  VALUES (v_user, 'RF6 fixture clinician', v_region);

  -- URGENT+ events carry c_urgent_needs_template. A fixture template, not a
  -- real one: this suite tests the alert path, not template governance.
  INSERT INTO safety.safety_template
    (id, version, severity, jurisdiction, language, body, slots, approved_by, approved_at)
  VALUES (v_tmpl, 1, 'EMERGENCY', v_region, 'en', 'RF6 fixture body', '{}'::jsonb, v_user, now());

  INSERT INTO safety.red_flag_event
    (id, subject_pseudonym, session_pseudonym, occurred_at, severity,
     trigger_detail, template_id, template_version, action_taken,
     commercial_suppressed, first_byte_at, template_displayed_at, data_region)
  VALUES
    (v_event, '\x00'::bytea, '\x00'::bytea, now(), 'EMERGENCY',
     '{}'::jsonb, v_tmpl, 1, 'TEMPLATE', true, now(), now(), v_region);

  v_alert := safety.raise_alert(v_event);
  ASSERT v_alert IS NOT NULL, 'safety.raise_alert returned NULL for an EMERGENCY event';

  SELECT state INTO v_state FROM safety.clinician_alert WHERE id = v_alert;
  ASSERT v_state = 'PENDING', format('new alert should be PENDING, was %s', v_state);

  -- ---------------------------------------------------------------------
  -- 2. THE SPINE. A non-delivering channel cannot produce a delivery.
  --    LOG is the only channel this deployment has. If this assertion ever
  --    fails, the platform can once again record "clinician notified" on the
  --    strength of a log line.
  -- ---------------------------------------------------------------------
  v_blocked := false;
  BEGIN
    PERFORM safety.mark_alert_delivered(v_alert, 'LOG', v_user);
  EXCEPTION WHEN raise_exception THEN v_blocked := true;
  END;
  ASSERT v_blocked,
    'safety.mark_alert_delivered accepted the LOG channel. A log line is not a page: '
    'a channel with delivers = false must never be able to move an alert to DELIVERED.';

  -- and the constraint holds even if the function is bypassed entirely
  v_blocked := false;
  BEGIN
    UPDATE safety.clinician_alert
       SET state = 'DELIVERED', channel = 'LOG', channel_delivers = false,
           clinician_id = v_user, delivered_at = now()
     WHERE id = v_alert;
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN v_blocked := true;
  END;
  ASSERT v_blocked,
    'c_only_delivering_channel_delivers did not fire on a direct UPDATE. The rule must '
    'live in the table, not only in the function that is supposed to be used.';

  -- ...and the composite FK makes lying about the flag impossible too
  v_blocked := false;
  BEGIN
    UPDATE safety.clinician_alert
       SET state = 'DELIVERED', channel = 'LOG', channel_delivers = true,
           clinician_id = v_user, delivered_at = now()
     WHERE id = v_alert;
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN v_blocked := true;
  END;
  ASSERT v_blocked,
    'the (channel, channel_delivers) composite FK accepted LOG paired with delivers = true. '
    'channel_delivers is no longer a denormalisation the database proves.';

  RAISE NOTICE 'RF6: a non-delivering channel cannot record a delivery (3 ways)';

  -- ---------------------------------------------------------------------
  -- 3. The honest outcome is available and requires a reason.
  -- ---------------------------------------------------------------------
  v_blocked := false;
  BEGIN
    PERFORM safety.mark_alert_undeliverable(v_alert, '');
  EXCEPTION WHEN raise_exception THEN v_blocked := true;
  END;
  ASSERT v_blocked, 'mark_alert_undeliverable accepted an empty reason';

  PERFORM safety.mark_alert_undeliverable(v_alert, 'NO_ROSTER_ENTRY');
  SELECT state INTO v_state FROM safety.clinician_alert WHERE id = v_alert;
  ASSERT v_state = 'UNDELIVERABLE', format('expected UNDELIVERABLE, got %s', v_state);

  -- ---------------------------------------------------------------------
  -- 4. §4.0.7 — clinician_notified_at is NOT stamped by a failed delivery.
  --    This is the assertion that would have caught the original bug.
  -- ---------------------------------------------------------------------
  SELECT clinician_notified_at INTO v_notified
    FROM safety.red_flag_event WHERE id = v_event;
  ASSERT v_notified IS NULL,
    'red_flag_event.clinician_notified_at was stamped for an UNDELIVERABLE alert. '
    'The platform is again recording notifications that did not occur.';

  -- ...and an undelivered alert cannot be acknowledged
  v_blocked := false;
  BEGIN
    PERFORM safety.acknowledge_alert(v_alert, v_user);
  EXCEPTION WHEN raise_exception THEN v_blocked := true;
  END;
  ASSERT v_blocked, 'acknowledge_alert accepted an alert that was never delivered';

  -- ---------------------------------------------------------------------
  -- 5. The state shows up where a human will see it.
  -- ---------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM safety.v_alerts_reaching_nobody WHERE id = v_alert;
  ASSERT v_n = 1,
    'an UNDELIVERABLE alert does not appear in safety.v_alerts_reaching_nobody — '
    'the one view whose non-emptiness is the platform admitting it reached no one';

  RAISE NOTICE 'RF6: an undelivered alert stamps nothing and surfaces in the metric view';
END $$;

ROLLBACK;

BEGIN;

-- ---------------------------------------------------------------------------
-- 6. POSITIVE CONTROL. With a roster entry on a delivering channel, the whole
--    path works and DOES stamp §4.0.7's clinician identity. Without this the
--    suite above would pass just as well if delivery were impossible outright,
--    which is not the goal — the goal is that delivery is possible and
--    truthful.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_user     uuid := gen_random_uuid();
  v_region   char(2);
  v_tmpl     uuid := gen_random_uuid();
  v_event    uuid := gen_random_uuid();
  v_alert    uuid;
  v_oncall   record;
  v_notified timestamptz;
  v_who      uuid;
  v_state    text;
  v_n        int;
BEGIN
  SELECT code INTO v_region FROM public.region_registry LIMIT 1;
  INSERT INTO principal.app_user (id, auth_subject, data_region)
  VALUES (v_user, 'rf6-' || v_user::text, v_region);
  INSERT INTO principal.clinician (user_id, full_name, primary_jurisdiction)
  VALUES (v_user, 'RF6 on-call', v_region);

  INSERT INTO safety.safety_template
    (id, version, severity, jurisdiction, language, body, slots, approved_by, approved_at)
  VALUES (v_tmpl, 1, 'EMERGENCY', v_region, 'en', 'RF6 fixture body', '{}'::jsonb, v_user, now());

  INSERT INTO safety.on_call_roster
    (id, clinician_id, data_region, min_severity, channel, address, effective_from)
  VALUES
    (gen_random_uuid(), v_user, v_region, 'URGENT', 'SMS', '+10000000000', now() - interval '1 day');

  -- the roster resolves, and it resolves to a delivering channel
  SELECT * INTO v_oncall
    FROM safety.resolve_on_call(v_region, 'EMERGENCY'::red_flag_severity, now()) LIMIT 1;
  ASSERT v_oncall.clinician_id = v_user, 'resolve_on_call did not find the roster entry';

  INSERT INTO safety.red_flag_event
    (id, subject_pseudonym, session_pseudonym, occurred_at, severity,
     trigger_detail, template_id, template_version, action_taken,
     commercial_suppressed, first_byte_at, template_displayed_at, data_region)
  VALUES
    (v_event, '\x01'::bytea, '\x01'::bytea, now(), 'EMERGENCY',
     '{}'::jsonb, v_tmpl, 1, 'TEMPLATE', true, now(), now(), v_region);

  v_alert := safety.raise_alert(v_event);
  PERFORM safety.mark_alert_delivered(v_alert, v_oncall.channel, v_oncall.clinician_id);

  SELECT clinician_notified_at, clinician_id INTO v_notified, v_who
    FROM safety.red_flag_event WHERE id = v_event;
  ASSERT v_notified IS NOT NULL,
    'a real delivery did NOT stamp red_flag_event.clinician_notified_at — RF6 has '
    'traded a false positive for a false negative';
  ASSERT v_who = v_user, '§4.0.7 clinician identity was not recorded on delivery';

  PERFORM safety.acknowledge_alert(v_alert, v_user);
  SELECT state INTO v_state FROM safety.clinician_alert WHERE id = v_alert;
  ASSERT v_state = 'ACKNOWLEDGED', format('expected ACKNOWLEDGED, got %s', v_state);

  -- and now it is NOT in the reaching-nobody view
  SELECT count(*) INTO v_n FROM safety.v_alerts_reaching_nobody WHERE id = v_alert;
  ASSERT v_n = 0,
    'an acknowledged, delivered alert still appears in v_alerts_reaching_nobody';

  RAISE NOTICE 'RF6: a real delivery on a delivering channel stamps §4.0.7 and clears the view';
END $$;

-- ---------------------------------------------------------------------------
-- 7. The SLA is reference data and is NOT adopted. Same discipline as
--    red_flag_rule.clinically_adopted / AMB-17: these numbers came from
--    CGP-001 §8.2, which calls them proposals. If this ever passes silently
--    with clinically_adopted = true, someone adopted an SLA without a
--    clinician, which is the §0.6 failure mode.
-- ---------------------------------------------------------------------------
DO $$
DECLARE n_adopted int; n_rows int;
BEGIN
  SELECT count(*) FILTER (WHERE clinically_adopted), count(*)
    INTO n_adopted, n_rows FROM safety.alert_sla;
  ASSERT n_rows = 3, format('expected SLA rows for URGENT/CRITICAL/EMERGENCY, found %s', n_rows);
  ASSERT n_adopted = 0,
    format('%s alert SLA row(s) are marked clinically_adopted with no clinical lead '
           'appointed. Charter §0.6 / AMB-17: adoption requires a named clinician.', n_adopted);
  RAISE NOTICE 'RF6: alert SLAs are present and correctly NOT adopted';
END $$;

-- ---------------------------------------------------------------------------
-- 8. Grants. The notification columns must be un-writable by every application
--    role, so mark_alert_delivered() is the only path. HP-RECON-001 §2b: this
--    is checked at PLAN time, so a stray grant would not merely widen access,
--    it would let a whole UPDATE statement through.
-- ---------------------------------------------------------------------------
DO $$
DECLARE missing text[] := '{}'; r text; c text;
BEGIN
  FOREACH r IN ARRAY ARRAY['alert_role','redflag_role','hp_app'] LOOP
    FOREACH c IN ARRAY ARRAY['clinician_notified_at','clinician_id'] LOOP
      IF has_column_privilege(r, 'safety.red_flag_event', c, 'UPDATE') THEN
        missing := missing || (r || ' CAN UPDATE red_flag_event.' || c);
      END IF;
    END LOOP;
    IF has_table_privilege(r, 'safety.clinician_alert', 'UPDATE')
       OR has_table_privilege(r, 'safety.clinician_alert', 'INSERT') THEN
      missing := missing || (r || ' HAS DIRECT DML ON clinician_alert');
    END IF;
  END LOOP;

  -- the read side must work, or the worker cannot see its own queue
  IF NOT has_table_privilege('alert_role', 'safety.clinician_alert', 'SELECT') THEN
    missing := missing || 'alert_role CANNOT SELECT clinician_alert'::text;
  END IF;
  IF NOT has_function_privilege('alert_role', 'safety.mark_alert_delivered(uuid, text, uuid)', 'EXECUTE') THEN
    missing := missing || 'alert_role CANNOT EXECUTE mark_alert_delivered'::text;
  END IF;

  ASSERT cardinality(missing) = 0,
    format('RF6 grant contract violated: %s', array_to_string(missing, '; '));
  RAISE NOTICE 'RF6: notification columns are writable only through the definer function';
END $$;

ROLLBACK;
