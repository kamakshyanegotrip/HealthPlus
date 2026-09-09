-- =====================================================================
-- 042 — evidence.policy_for cannot be executed by the only role that calls it
--
-- FOUND BY: test/runPipeline.integration.test.ts, R10f, running the real
-- pipeline against the real schema as the real roles for the first time.
-- Every knowledge lookup failed with:
--
--   ERROR: permission denied for schema safety
--   QUERY: SELECT s.enabled FROM safety.response_category_state s
--          WHERE s.category = p_cat
--   CONTEXT: PL/pgSQL function evidence.policy_for(...) line 5
--
-- =====================================================================
-- THE SHAPE OF IT
--
-- `evidence.policy_for` is SECURITY INVOKER, and its first statement reads
-- `safety.response_category_state` — §2.3.2's category-enablement switch, the
-- lock that keeps CLINICAL_DECISION disabled. Its caller is
-- `src/lib/pipeline/knowledgeLookup.ts`, which runs the retrieval query on the
-- `reasoner` pool, i.e. as `reasoner_role`.
--
-- `reasoner_role` holds no USAGE on schema `safety`. That is not an oversight
-- to correct — it is R13-conn's entire point, recorded in db.ts: "a SQL
-- injection reached through the retrieval path cannot write a §4.0.7 safety
-- event, because reasoner_role holds no grant on safety.red_flag_event and no
-- way to acquire one." Granting `safety` USAGE to fix this would spend that
-- property to make a test pass.
--
-- So the function is the thing that has to change, not the role.
--
-- =====================================================================
-- WHY NOTHING CAUGHT IT
--
-- Every gate in migrations/test runs as `postgres`, and a superuser has USAGE
-- on every schema. The function therefore worked in every check ever written
-- for it, and failed the first time a non-superuser called it. This is the
-- fourth finding in this repository with that exact shape (FORCE RLS,
-- p_prf_own, the DEFINER PUBLIC grants, now this), and the pattern is worth
-- naming: a privilege boundary that only exists for non-superusers is
-- invisible to a suite that runs as one.
--
-- `migrations/test/r13_conn_isolation.sh` §3 checks what reasoner_role can
-- REACH. It could not have caught this, and the reason is instructive: this is
-- the opposite failure. Not a role reaching something it should not, but a role
-- unable to reach something it must. §4 below is that missing direction.
--
-- =====================================================================
-- THE FIX, AND WHY SECURITY DEFINER IS THE RIGHT INSTRUMENT HERE
--
-- `policy_for` is a pure verdict function: three enum arguments in, one
-- `evidence.claim_policy` row out. It writes nothing, it takes no text, and
-- both of its reads are of adopted policy — the category switch and the policy
-- matrix. There is no user-controlled input for a definer context to widen.
--
-- Running it as its owner lets it read the category switch without its callers
-- holding any access to `safety` at all, which is strictly narrower than the
-- alternative. The §2.3.2 lock also gets stronger rather than weaker: the
-- switch becomes unreadable to every application role, so no caller can
-- observe it, cache it, or race it — they can only receive its verdict.
--
-- Migration 040's rule stands and is applied here: a SECURITY DEFINER function
-- must not be executable by PUBLIC. §2 revokes and re-grants by name.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- §0. The finding, asserted before it is fixed.
--
-- If a future schema change makes `policy_for` reachable some other way — or
-- gives reasoner_role `safety` USAGE, which is the wrong fix — this migration
-- should not silently claim to have repaired something that was not broken.
-- ---------------------------------------------------------------------
DO $$
DECLARE definer boolean; usage_on_safety boolean;
BEGIN
  SELECT p.prosecdef INTO definer
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'evidence' AND p.proname = 'policy_for';
  IF definer IS NULL THEN
    RAISE EXCEPTION '042: evidence.policy_for does not exist';
  END IF;

  SELECT has_schema_privilege('reasoner_role', 'safety', 'USAGE') INTO usage_on_safety;
  IF usage_on_safety THEN
    RAISE EXCEPTION
      '042: reasoner_role has USAGE on schema safety. That is the wrong fix for '
      'this finding and it defeats R13-conn; remove the grant, then re-run.';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- §1. The function, unchanged in body, changed in security context.
--
-- The body below is migration 019's verbatim, re-stated rather than ALTERed so
-- the whole definition lives in one file and nobody has to reconstruct it from
-- two. search_path is PINNED — a SECURITY DEFINER function without one is the
-- classic escalation, and 040 pinned every other definer in this schema.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION evidence.policy_for(
  p_tier source_tier, p_kind claim_kind, p_cat response_category
) RETURNS evidence.claim_policy
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = evidence, safety, public
AS $$
DECLARE r evidence.claim_policy; cat_on boolean;
BEGIN
  -- lock 1: §2.3.2 category enablement, independent of the matrix
  SELECT s.enabled INTO cat_on
    FROM safety.response_category_state s WHERE s.category = p_cat;
  IF NOT COALESCE(cat_on, false) THEN
    r.tier := p_tier; r.kind := p_kind; r.category := p_cat;
    r.disposition := 'PROHIBITED';
    r.min_sources := 1;
    r.charter_clause := 'HP-ESC 2.3.2 category disabled';
    RETURN r;
  END IF;
  -- lock 2: §3.0.3 default-deny — absence of a row is a prohibition, never a permission
  SELECT * INTO r FROM evidence.claim_policy
   WHERE tier = p_tier AND kind = p_kind AND category = p_cat
     AND effective_from <= now()
   ORDER BY effective_from DESC LIMIT 1;
  IF NOT FOUND THEN
    r.tier := p_tier; r.kind := p_kind; r.category := p_cat;
    r.disposition := 'PROHIBITED';
    r.min_sources := 1;
    r.charter_clause := 'HP-ESC 3.0.3 default-deny';
  END IF;
  RETURN r;
END $$;

-- ---------------------------------------------------------------------
-- §2. Migration 040's rule, applied to the function 040 could not have covered
--     because it was not a definer yet.
--
-- A function's default ACL is EXECUTE TO PUBLIC, so the REVOKE is what narrows
-- anything; the GRANT alone would narrow nothing. Grants are stated by name,
-- and the list is exactly the roles that call it.
-- ---------------------------------------------------------------------
REVOKE ALL ON FUNCTION evidence.policy_for(source_tier, claim_kind, response_category) FROM PUBLIC;

-- reasoner_role: the retrieval path (knowledgeLookup.ts), the caller this
-- migration exists for.
GRANT EXECUTE ON FUNCTION evidence.policy_for(source_tier, claim_kind, response_category) TO reasoner_role;

-- dqe_role: the Data Quality Engine evaluates dispositions when it recomputes
-- confidence (HP-DQE-001). It reads the same verdict for the same reason.
GRANT EXECUTE ON FUNCTION evidence.policy_for(source_tier, claim_kind, response_category) TO dqe_role;

-- ---------------------------------------------------------------------
-- §3. The fix, asserted. Not "the grant exists" — that is 040's rule L and
--     grant_contract.mjs already checks it. This asserts the thing that was
--     actually broken: that the CALL SUCCEEDS as the role that makes it.
--
-- SET SESSION AUTHORIZATION and back, inside the migration's own transaction,
-- so a failure rolls the whole thing back rather than leaving a half-fixed
-- function behind.
-- ---------------------------------------------------------------------
DO $$
DECLARE d text;
BEGIN
  SET LOCAL SESSION AUTHORIZATION reasoner_role;
  SELECT disposition INTO d
    FROM evidence.policy_for('TIER_1'::source_tier, 'GUIDELINE'::claim_kind,
                             'DECISION_SUPPORT'::response_category);
  RESET SESSION AUTHORIZATION;

  IF d IS NULL THEN
    RAISE EXCEPTION '042: policy_for returned no disposition as reasoner_role';
  END IF;
  -- The value itself is not asserted — that is the policy matrix's business and
  -- it is allowed to change. What is asserted is that the call completed at all,
  -- which is what it could not do before.
  RAISE NOTICE '042: policy_for is callable by reasoner_role (disposition %)', d;
END $$;

-- ---------------------------------------------------------------------
-- §4. The direction r13_conn_isolation.sh does not check: a role that cannot
--     reach what it MUST reach.
--
-- The isolation gate enumerates what reasoner_role can touch and fails if the
-- set grows. That catches over-reach and is silent on under-reach, and
-- under-reach is what broke retrieval. So this asserts the retrieval path's
-- whole function surface is executable by the role that runs it — every
-- function knowledgeLookup.ts names.
--
-- Deliberately a LIST rather than a query over the evidence schema: the point
-- is that these specific functions are reachable, and a query would go green
-- the day one of them is dropped.
-- ---------------------------------------------------------------------
DO $$
DECLARE fn text; missing text[] := ARRAY[]::text[];
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'evidence.claim_search(text,text[],vector,integer)',
    'evidence.aggregate_claim(uuid)',
    'evidence.policy_for(source_tier,claim_kind,response_category)',
    'evidence.confidence_band(numeric)',
    'evidence.render_citation(uuid)'
  ] LOOP
    IF NOT has_function_privilege('reasoner_role', fn, 'EXECUTE') THEN
      missing := missing || fn;
    END IF;
  END LOOP;

  IF array_length(missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      '042 §4: reasoner_role cannot execute the retrieval path: %. '
      'knowledgeLookup.ts calls every one of these; a missing EXECUTE here is '
      'a retrieval failure at request time, not a missing feature.',
      array_to_string(missing, ', ');
  END IF;
END $$;

COMMIT;
