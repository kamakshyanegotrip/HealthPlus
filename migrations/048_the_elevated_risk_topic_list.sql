-- =====================================================================
-- 048 — §2.2.5b trigger 2: the Elevated-Risk Topic List gets a table, a
--       reader, and a fail-closed answer for the day it is not adopted
--
-- =====================================================================
-- §0.1  WHAT THIS CLOSES
--
-- HP-SR-001 §1 found three of §2.2.5b's five pre-publication review triggers
-- missing. Two of them turned out to need no clinical input at all and were
-- closed in the same change as this file:
--
--   trigger 1  "a flagged high-risk profile (§4.6)"  -> the flags reached
--              patientProfile.ts and nine of the ten were thrown away
--   trigger 5  "a Tier 1/Tier 2 conflict (§1.8.3)"   -> detection has existed
--              in this schema since migration 024, and the retrieval query
--              CROSS JOIN LATERALs the function that returns conflict_id and
--              then drops the column
--
-- Trigger 2 is different, and this file is the difference. The Charter's
-- fourteen topics are the Charter's; the TERMS that detect them in a message
-- are a clinical judgement nobody has made. So the mechanism is built here and
-- the content is not.
--
-- =====================================================================
-- §0.2  THE FAIL-CLOSED QUESTION, WHICH IS THE WHOLE DESIGN
--
-- What should §2.2.5b trigger 2 do on a system where no topic list has been
-- adopted? There are two answers and only one of them is this project's.
--
--   Not fire.       The trigger is simply absent. Every Decision Support
--                   response on oncology, paediatrics, pregnancy, self-harm,
--                   transplant or assisted dying publishes unreviewed, and
--                   nothing anywhere says so.
--
--   Resolve upward. "We cannot tell whether this topic requires review" is not
--                   "this topic does not require review". §3.0.3: the absence
--                   of a policy row is a prohibition. Review is forced, and the
--                   audit row records that it was forced because the trigger
--                   was UNEVALUABLE rather than because it matched.
--
-- The second, and the precedent is exact: `safety.adopted_rule_set()` returning
-- nothing makes `resolveAdoptionGate()` return FAIL_CLOSED and the whole turn
-- end in the unavailability notice, rather than returning NORMAL. Migration
-- 027's own comment says why — "returning NORMAL from an empty rule set would
-- make an unsigned deployment look safe while detecting nothing."
--
-- WHY THIS IS NOT ACADEMIC TODAY. §4 is unadopted, so every turn already ends
-- in unavailability and this trigger is never reached. It becomes live at one
-- specific future moment: the day CL2–CL5 are signed and the topic list is not.
-- That is a plausible sequence — the rule set is weeks 2–4 of CGP-001 §9 and
-- the topic list is not on that schedule at all — and on that day the choice
-- above is the difference between a system that over-reviews and a system that
-- publishes paediatric oncology content with no human in the loop.
--
-- =====================================================================
-- §0.3  WHICH ROLE READS IT, AND THE WIDENING THIS FILE DID NOT DO
--
-- The obvious answer is `hp_app`: the classifier's input is the user's message,
-- which hp_app already holds, and hp_app has USAGE on `safety`. Measured before
-- writing it:
--
--     information_schema.role_table_grants, schema 'safety', grantee 'hp_app'
--     -> ZERO ROWS
--
-- hp_app holds USAGE on the schema and not one table in it. That is not an
-- oversight, it is R13-conn: the role that takes untrusted user input can reach
-- nothing in `safety`, so an injection through the request path cannot read a
-- rule, a template, or an alert channel. One SELECT grant on a reference table
-- is individually defensible and is the first crack in it — which is precisely
-- the shape of the thirty grants migration 031 revoked.
--
-- So `redflag_role` reads this, alongside the eight other safety reference
-- tables it already reads. It runs in the request path on its own pool, and
-- §2.4.1 is a safety clause. The classifier costs one query on a connection
-- that is already open.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- §1. The table.
--
--     Modelled on safety.red_flag_rule's discipline rather than invented:
--     approval is a clinician's uuid and a timestamp, retirement is a column
--     rather than a DELETE, and nothing is adopted by default.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS safety.elevated_risk_topic (
  id                 uuid PRIMARY KEY,
  -- The Charter's own numbering, 1..14 in §2.4.1. Kept because the register,
  -- the review pack and the Charter all refer to these by number, and a list
  -- whose items cannot be named across documents is a list nobody can discuss.
  ordinal            smallint NOT NULL CHECK (ordinal BETWEEN 1 AND 99),
  topic              text     NOT NULL,
  -- Detection terms, whole-word matched the same way rulePattern.ts matches a
  -- KEYWORD_ANY. EMPTY on arrival and that is the point: the Charter names the
  -- topics, a clinician says how to recognise them.
  terms              text[]   NOT NULL DEFAULT '{}',
  jurisdiction       char(2)  REFERENCES public.region_registry(code),
  language           text     NOT NULL DEFAULT 'en',
  clinically_adopted boolean  NOT NULL DEFAULT false,
  adopted_by         uuid     REFERENCES principal.clinician(user_id),
  adopted_at         timestamptz,
  retired_at         timestamptz,
  charter_clause     text     NOT NULL DEFAULT 'HP-ESC 2.4.1',
  -- §0.6: an unsigned entry may not fire, and "signed" means a named clinician
  -- and a date, not a boolean somebody set.
  CONSTRAINT c_topic_adoption_is_signed CHECK (
    clinically_adopted = false OR (adopted_by IS NOT NULL AND adopted_at IS NOT NULL)),
  -- AN ADOPTED TOPIC WITH NO TERMS IS A CONTROL THAT REPORTS SUCCESS IT DID NOT
  -- ACHIEVE — this repository's second recurring pattern, and the one shape
  -- this table can rule out in the schema rather than in a review.
  CONSTRAINT c_adopted_topic_is_detectable CHECK (
    clinically_adopted = false OR cardinality(terms) > 0),
  -- NULLS NOT DISTINCT so that a jurisdiction-agnostic row collides with
  -- another jurisdiction-agnostic row. Without it, NULL never equals NULL and
  -- the uniqueness this states would silently not exist.
  CONSTRAINT c_topic_unique UNIQUE NULLS NOT DISTINCT (ordinal, jurisdiction, language)
);

COMMENT ON TABLE safety.elevated_risk_topic IS
  'Charter §2.4.1. The fourteen topics are the Charter''s and ship with this '
  'migration; the terms that detect them are a clinical judgement and ship '
  'empty. safety.adopted_topic_list() returns nothing until a clinician signs, '
  'and an empty return forces review rather than skipping the trigger (§3.0.3).';

-- ---------------------------------------------------------------------
-- §2. The fourteen topics, verbatim from Charter §2.4.1, UNADOPTED.
--
--     Reference data, on the same footing as public.region_registry and
--     evidence.aggregate_method: the Charter states these, so the schema may
--     state them. The TERMS are not reference data — they are a draft — and a
--     draft does not belong in a migration. HP-CGP-004's workbook is where they
--     are proposed and chat-pipeline/scripts/seed-demo.ts is where a developer
--     loads them into a database that is not production.
--
--     Deterministic uuids so a re-run converges instead of duplicating.
-- ---------------------------------------------------------------------
INSERT INTO safety.elevated_risk_topic (id, ordinal, topic, language)
VALUES
  ('2c4a0001-0000-4000-8000-000000000001', 1,  'Oncology — diagnosis, staging, treatment selection, prognosis, clinical trials.', 'en'),
  ('2c4a0001-0000-4000-8000-000000000002', 2,  'Cardiac and neuro-interventional procedures.', 'en'),
  ('2c4a0001-0000-4000-8000-000000000003', 3,  'Transplantation, including any question touching organ sourcing. See 2.4.2.', 'en'),
  ('2c4a0001-0000-4000-8000-000000000004', 4,  'Fertility, IVF, surrogacy, gamete donation.', 'en'),
  ('2c4a0001-0000-4000-8000-000000000005', 5,  'Paediatric anything (user or subject under 18).', 'en'),
  ('2c4a0001-0000-4000-8000-000000000006', 6,  'Pregnancy and obstetrics.', 'en'),
  ('2c4a0001-0000-4000-8000-000000000007', 7,  'Bariatric surgery.', 'en'),
  ('2c4a0001-0000-4000-8000-000000000008', 8,  'Stem-cell, gene, regenerative and "experimental" therapies.', 'en'),
  ('2c4a0001-0000-4000-8000-000000000009', 9,  'Cosmetic and aesthetic surgery with general anaesthesia.', 'en'),
  ('2c4a0001-0000-4000-8000-00000000000a', 10, 'Mental health, psychiatric care, addiction treatment, and any content touching self-harm.', 'en'),
  ('2c4a0001-0000-4000-8000-00000000000b', 11, 'Assisted dying / end-of-life care.', 'en'),
  ('2c4a0001-0000-4000-8000-00000000000c', 12, 'Gender-affirming care.', 'en'),
  ('2c4a0001-0000-4000-8000-00000000000d', 13, 'Any treatment unapproved, off-label, or illegal in either the user''s origin jurisdiction or the destination.', 'en'),
  ('2c4a0001-0000-4000-8000-00000000000e', 14, 'Immunosuppression, anticoagulation, chemotherapy, and other narrow-therapeutic-index drug contexts.', 'en')
ON CONFLICT (id) DO UPDATE SET topic = EXCLUDED.topic;

-- ---------------------------------------------------------------------
-- §3. The reader. Zero rows means NOT ADOPTED, and the caller must treat that
--     as "cannot tell" rather than "no".
--
--     Deliberately the same shape as safety.adopted_rule_set(): same argument
--     order, same jurisdiction-NULL-means-any rule, same "returns nothing when
--     nothing is signed". Two functions answering the same kind of question in
--     two different shapes is how a caller comes to handle one correctly and
--     the other by accident.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION safety.adopted_topic_list(
  p_jurisdiction char(2),
  p_language     text
) RETURNS TABLE (
  ordinal smallint,
  topic   text,
  terms   text[]
)
LANGUAGE sql STABLE AS $$
  SELECT t.ordinal, t.topic, t.terms
    FROM safety.elevated_risk_topic t
   WHERE t.clinically_adopted            -- §0.6: unsigned may not fire
     AND t.retired_at IS NULL
     AND cardinality(t.terms) > 0        -- restated; the CHECK already forbids it
     AND (t.jurisdiction = p_jurisdiction OR t.jurisdiction IS NULL)
     AND t.language = p_language
   ORDER BY t.ordinal;
$$;

COMMENT ON FUNCTION safety.adopted_topic_list(char(2), text) IS
  'Charter §2.2.5b trigger 2. ZERO ROWS MEANS THE TRIGGER CANNOT BE EVALUATED, '
  'which under §3.0.3 forces review — it does not mean the topic is absent. '
  'The caller records ELEVATED_TOPIC_UNEVALUABLE so the audit trail '
  'distinguishes "no adopted list" from "checked, no match".';

-- ---------------------------------------------------------------------
-- §4. Grants, RLS, and the boundary this migration did not cross.
-- ---------------------------------------------------------------------
GRANT SELECT ON safety.elevated_risk_topic TO redflag_role;

-- THE REVOKE HAS TO COME FIRST, AND WRITING THIS FILE WITHOUT IT IS HOW THE
-- POINT WAS PROVED. A function's default ACL is EXECUTE TO PUBLIC, so the GRANT
-- below narrows nothing on its own — it reads as a restriction and is an
-- addition. Found by revoking the named grant and watching the call still
-- succeed, which is the only way this failure announces itself.
--
-- Migration 040 did this for the SECURITY DEFINER functions and grant_contract
-- rule L keeps them clean. Migration 049 does it for the eighteen INVOKER
-- functions in the same state, this one having been the nineteenth for about
-- twenty minutes.
REVOKE ALL ON FUNCTION safety.adopted_topic_list(char(2), text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safety.adopted_topic_list(char(2), text) TO redflag_role;

ALTER TABLE safety.elevated_risk_topic ENABLE ROW LEVEL SECURITY;

-- Reference data with no data_region column, so it cannot be region-scoped and
-- must not pretend to be — the same reasoning migration 031 §4 gives for
-- p_rfr_readable on safety.red_flag_rule. Retired and unadopted rows stay
-- readable: the list is what the Charter says it is, and a reader that can only
-- see the adopted subset cannot tell "not adopted" from "not a topic".
DROP POLICY IF EXISTS p_ert_readable ON safety.elevated_risk_topic;
CREATE POLICY p_ert_readable ON safety.elevated_risk_topic
  FOR SELECT TO redflag_role
  USING (true);

DO $$
DECLARE n bigint;
BEGIN
  SELECT count(*) INTO n FROM information_schema.role_table_grants
   WHERE table_schema = 'safety' AND grantee = 'hp_app';
  IF n > 0 THEN
    RAISE EXCEPTION
      '048 §4: hp_app now holds % grant(s) in schema safety. R13-conn''s guarantee '
      'is that the role taking untrusted user input can reach nothing there, and '
      'this migration was one SELECT away from being the first exception. If a '
      'grant is genuinely needed, it is a decision to record, not a side effect.', n;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- §5. The proof, run as redflag_role.
--
--     Four claims, and the first is the one that matters:
--       (a) with nothing adopted the reader returns ZERO rows — the state the
--           caller must turn into "force review", not "no match"
--       (b) an adopted topic with terms is returned
--       (c) an adopted topic with NO terms cannot be written at all
--       (d) adoption without a named clinician cannot be written at all
--
--     Rolls itself back through a raised exception (045 §5's pattern), so the
--     table is left exactly as §2 wrote it: fourteen topics, none adopted.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  before_n int; after_n int; clin uuid; refused boolean;
BEGIN
  BEGIN
    SET LOCAL SESSION AUTHORIZATION redflag_role;
    SELECT count(*) INTO before_n FROM safety.adopted_topic_list('IN', 'en');
    RESET SESSION AUTHORIZATION;

    IF before_n <> 0 THEN
      RAISE EXCEPTION
        '048 §5(a): adopted_topic_list returned % row(s) on a schema where no '
        'clinician has signed anything. Nothing may be adopted by a migration.', before_n;
    END IF;

    -- A clinician to sign the probe row. Any row in principal.clinician will do;
    -- there is none on a bare schema, so (b) is skipped rather than faked — a
    -- probe that invented a clinician to test adoption would be writing the
    -- exact forgery this table exists to prevent.
    SELECT user_id INTO clin FROM principal.clinician LIMIT 1;

    IF clin IS NOT NULL THEN
      UPDATE safety.elevated_risk_topic
         SET terms = ARRAY['probe048'], clinically_adopted = true,
             adopted_by = clin, adopted_at = now()
       WHERE ordinal = 1 AND language = 'en';

      SET LOCAL SESSION AUTHORIZATION redflag_role;
      SELECT count(*) INTO after_n FROM safety.adopted_topic_list('IN', 'en');
      RESET SESSION AUTHORIZATION;

      IF after_n <> 1 THEN
        RAISE EXCEPTION '048 §5(b): one adopted topic, reader returned %.', after_n;
      END IF;

      -- (c) adopted with no terms
      refused := false;
      BEGIN
        UPDATE safety.elevated_risk_topic SET terms = '{}'
         WHERE ordinal = 1 AND language = 'en';
      EXCEPTION WHEN check_violation THEN refused := true;
      END;
      IF NOT refused THEN
        RAISE EXCEPTION
          '048 §5(c): a topic was left ADOPTED with no terms. That is a review '
          'trigger that can never match, recorded as active.';
      END IF;

      -- (d) adopted with no named clinician
      refused := false;
      BEGIN
        UPDATE safety.elevated_risk_topic SET adopted_by = NULL
         WHERE ordinal = 1 AND language = 'en';
      EXCEPTION WHEN check_violation THEN refused := true;
      END;
      IF NOT refused THEN
        RAISE EXCEPTION '048 §5(d): adoption survived losing its approving clinician.';
      END IF;

      RAISE NOTICE '048 §5: 0 adopted -> 0 rows; 1 adopted -> 1 row; termless and '
                   'unsigned adoption both refused.';
    ELSE
      RAISE NOTICE '048 §5: 0 adopted -> 0 rows. (b)-(d) skipped: no clinician row '
                   'exists to sign a probe with, and inventing one is the forgery '
                   'this table exists to prevent. migrations/test/sr1_review_triggers.sh '
                   'covers them against a seeded schema.';
    END IF;

    RAISE EXCEPTION 'HP048ROLLBACK' USING ERRCODE = 'HP048';
  EXCEPTION WHEN SQLSTATE 'HP048' THEN
    RESET SESSION AUTHORIZATION;
  END;
END $$;

DO $$
DECLARE n bigint;
BEGIN
  SELECT count(*) INTO n FROM safety.elevated_risk_topic WHERE clinically_adopted;
  IF n <> 0 THEN
    RAISE EXCEPTION '048: % topic(s) left adopted after §5 rolled back.', n;
  END IF;
  RAISE NOTICE '048: 14 Charter topics present, 0 adopted, reader fails closed.';
END $$;

COMMIT;
