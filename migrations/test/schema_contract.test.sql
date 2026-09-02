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

ROLLBACK;
