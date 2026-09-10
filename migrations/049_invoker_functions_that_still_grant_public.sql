-- =====================================================================
-- 049 — eighteen GRANTs that read as restrictions and are not
--
-- =====================================================================
-- §0.1  HOW THIS WAS FOUND
--
-- Migration 048 grants `safety.adopted_topic_list()` to `redflag_role`. To
-- prove that grant was load-bearing, it was revoked and the call was expected
-- to fail. It succeeded — twice, once through PREPARE and once through EXECUTE:
--
--     REVOKE EXECUTE ON FUNCTION safety.adopted_topic_list(char(2),text)
--       FROM redflag_role;
--     SET SESSION AUTHORIZATION redflag_role;
--     SELECT * FROM safety.adopted_topic_list('IN','en');   -->  0 rows, no error
--
-- A function's DEFAULT ACL is `EXECUTE TO PUBLIC`. Revoking the named grant
-- removes nothing while PUBLIC's entry stands, so the GRANT had narrowed
-- nothing at all. That is HP-SEC-002's finding exactly, and grant_contract's
-- rule L exists to catch it — but rule L is scoped to SECURITY DEFINER
-- functions, because that is where the consequence was severe (a definer runs
-- as its OWNER, so PUBLIC EXECUTE hands every role the owner's reach; migration
-- 040 §0 records `dqe_role` being able to crypto-shred any data subject).
--
-- =====================================================================
-- §0.2  WHAT THE CATALOGUE SAYS, AND WHY IT IS EIGHTEEN AND NOT ONE HUNDRED
--
-- Across principal, safety, obs, evidence, domain, app and public:
--
--     SECURITY DEFINER, PUBLIC-executable ........   0 of  34   (rule L holds)
--     INVOKER,          PUBLIC-executable ....... 103 of 104
--
-- One hundred and three is not a defect list, it is the PostgreSQL default, and
-- a migration that swept all of them would be changing a language default on a
-- hunch. The defect is narrower and precisely identifiable:
--
--     a function whose ACL NAMES A ROLE and STILL CARRIES PUBLIC
--
-- Somebody wrote a GRANT there. They meant to say "this role, and not others".
-- The ACL says "this role, and also everyone". Eighteen functions are in that
-- state, and they are not obscure ones:
--
--     safety.adopted_rule_set        the §0.6 adoption gate itself
--     safety.resolve_on_call         RF6's on-call resolution
--     evidence.claim_search          the retrieval entry point
--     evidence.aggregate_claim       §1.8.3's conflict and demotion
--     app.current_region             the region every RLS policy compares to
--     … and thirteen more, enumerated by §1 rather than by hand
--
-- =====================================================================
-- §0.3  HOW DANGEROUS THIS IS, STATED HONESTLY
--
-- Less than rule L's case, and the difference matters. An INVOKER function runs
-- as its CALLER, so PUBLIC EXECUTE grants no reach the caller did not already
-- have: `evidence.claim_search` still reads `evidence` as whoever called it,
-- and a role without USAGE on the schema cannot call it at all. Checked, not
-- assumed — `hp_app` holds USAGE on `safety` and no table grant in it, so it
-- cannot usefully call `safety.adopted_rule_set()` today.
--
-- "Cannot usefully today" is the same sentence HP-SEC-002 was true under, right
-- up until migrations 037 and 039 granted schema USAGE to `dqe_role` and
-- `hp_app` for unrelated and entirely correct reasons, and eleven latent
-- over-grants became live in one afternoon.
--
-- The certain harm is smaller and is already here: **the DDL misdescribes the
-- system.** A reader auditing `GRANT EXECUTE ON safety.adopted_rule_set TO
-- redflag_role` concludes that redflag_role is who may call it. That is false,
-- and this repository's fourth recurring pattern is a record that misdescribes
-- the work. Here the record is the schema.
--
-- =====================================================================
-- §0.4  ENUMERATED, NOT LISTED
--
-- The eighteen are found from `pg_proc` at run time, the way migration 040
-- enumerated the definers and 044 enumerated the views. A hand-written list
-- that forgets an entry is the finding restated, and a hand-written list is
-- also wrong the moment somebody adds the nineteenth.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- §1. Revoke PUBLIC from every INVOKER function whose ACL already names a
--     role other than the owner.
--
--     Functions with a DEFAULT acl (proacl IS NULL) are untouched: nobody
--     expressed an intention about those, so removing PUBLIC from them is a
--     policy decision about the whole schema rather than a correction of a
--     specific mistake. Recorded in the register as an open question, not
--     smuggled in here.
-- ---------------------------------------------------------------------
DO $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT n.nspname, p.proname,
           pg_get_function_identity_arguments(p.oid) AS args
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname IN ('principal','safety','obs','evidence','domain','app','public')
       AND p.prokind = 'f'
       AND NOT p.prosecdef                      -- rule L owns the definers
       AND p.proacl IS NOT NULL                 -- somebody wrote a GRANT here
       AND EXISTS (SELECT 1 FROM unnest(p.proacl) a WHERE a::text LIKE '=X/%')
       AND EXISTS (SELECT 1 FROM unnest(p.proacl) a
                    WHERE a::text NOT LIKE '=X/%'
                      AND a::text NOT LIKE (pg_get_userbyid(p.proowner) || '=%'))
     ORDER BY 1, 2
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %I.%I(%s) FROM PUBLIC',
                   r.nspname, r.proname, r.args);
    n := n + 1;
  END LOOP;
  RAISE NOTICE '049: revoked PUBLIC from % invoker function(s) whose ACL already named a role.', n;
END $$;

-- ---------------------------------------------------------------------
-- §1b. The grants that PUBLIC was standing in for.
--
--      §1 ALONE IS A REGRESSION, and role_contract caught it within a minute of
--      the first clean build — the sixth recurring pattern, "the contract
--      catching the fix", for the fourth time:
--
--        auditLog.ts:56        as hp_app         permission denied for function current_region
--        knowledgeLookup.ts:98 as reasoner_role  permission denied for function aggregate_claim
--        patientProfile.ts:89  as reasoner_role  permission denied for function current_user_id
--        patientProfile.ts:101 as reasoner_role  permission denied for function current_user_id
--
--      Four live query paths were executing these through PUBLIC. That is the
--      finding rather than a complication of it: an ACL that names `dqe_role`
--      and `alert_role` while `reasoner_role` and `hp_app` silently depend on
--      the PUBLIC entry beside them describes a privilege model nobody holds.
--
--      A SUBTLETY WORTH RECORDING, because it cost a wrong hypothesis.
--      `app.current_region()` is called from RLS POLICY expressions, and a
--      policy expression is evaluated with the TABLE OWNER's privileges — which
--      is why `hp_reader`, with no USAGE on schema `app`, reads a region-scoped
--      table happily while `SELECT app.current_region()` from the same session
--      is refused (migration 047 §6 measured exactly that). EXECUTE on the
--      function is nevertheless checked against the CALLER when the statement is
--      planned. So the policy path needs the grant even though the schema-USAGE
--      path does not, and neither fact predicts the other.
--
--      Granted narrowly: each role gets the functions its own code paths call,
--      derived from role_contract's failures rather than from a guess about
--      what "seems needed".
-- ---------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION app.current_region()   TO hp_app, hp_reader, reasoner_role;
GRANT EXECUTE ON FUNCTION app.current_user_id()  TO hp_app, reasoner_role;
GRANT EXECUTE ON FUNCTION evidence.aggregate_claim(uuid)      TO reasoner_role;
GRANT EXECUTE ON FUNCTION evidence.aggregate_claim_base(uuid) TO reasoner_role;

-- AND THE SCHEMA USAGE THOSE GRANTS APPEAR TO NEED AND DID NOT.
--
-- grant_contract rule K then fired three times: "EXECUTE granted, no USAGE on
-- schema app — an EXECUTE grant is dead unless the role holds USAGE on the
-- function's schema." The grants above were demonstrably NOT dead — they turned
-- four failing queries green — so rule K's premise does not hold universally,
-- and the exception is worth stating because nothing else in this schema
-- documents it:
--
--   * USAGE on a schema is checked when a NAME is RESOLVED.
--   * An RLS policy stores the function's OID, resolved when the policy was
--     created. Evaluating it resolves no name, so USAGE is never consulted.
--   * EXECUTE is a privilege check on that OID and IS made, against the caller,
--     when the statement is planned.
--
-- So a role can be required to hold EXECUTE on a function it can never name.
-- Rule K is right about every DIRECT call and blind to this one, which is not a
-- reason to weaken it — three of its four historical findings were real.
--
-- Granting the USAGE is the honest resolution rather than baselining a false
-- positive: it makes the privilege model conventional, and it costs nothing
-- measurable. Schema `app` holds THREE FUNCTIONS AND NO RELATIONS, and after §1
-- each is EXECUTE-granted to named roles only — so USAGE conveys the ability to
-- name `current_provider_org`, which neither role may execute. Strictly narrower
-- than the state before this file, where all three were PUBLIC-executable to
-- every role that already had USAGE.
GRANT USAGE ON SCHEMA app TO hp_app, hp_reader;

-- ---------------------------------------------------------------------
-- §2. Nothing that could call these lost the ability to.
--
--     The named grants are untouched by §1 — REVOKE ... FROM PUBLIC removes one
--     ACL entry — but "untouched" is a claim, and this file's whole subject is
--     grants that do not do what they appear to. So it is checked, as each role.
-- ---------------------------------------------------------------------
DO $$
DECLARE r record; lost text[] := '{}';
BEGIN
  FOR r IN
    SELECT n.nspname||'.'||p.proname AS fn, p.oid, a.grantee_name
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      CROSS JOIN LATERAL (
        SELECT split_part(x::text, '=', 1) AS grantee_name
          FROM unnest(p.proacl) x
         WHERE x::text NOT LIKE '=X/%') a
     WHERE n.nspname IN ('principal','safety','obs','evidence','domain','app','public')
       AND p.prokind = 'f' AND NOT p.prosecdef AND p.proacl IS NOT NULL
       AND a.grantee_name <> pg_get_userbyid(p.proowner)
       AND a.grantee_name <> ''
  LOOP
    IF NOT has_function_privilege(r.grantee_name, r.oid, 'EXECUTE') THEN
      lost := lost || (r.grantee_name || ' -> ' || r.fn);
    END IF;
  END LOOP;

  IF array_length(lost, 1) > 0 THEN
    RAISE EXCEPTION
      '049 §2: % named grant(s) stopped working: %. REVOKE ... FROM PUBLIC was '
      'supposed to remove ONE acl entry.', array_length(lost, 1), array_to_string(lost, '; ');
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- §3. And the class is closed, not just its eighteen members.
--
--     Asserted here so that re-applying this file over a schema a later
--     migration widened fails loudly, and asserted again as a standing rule in
--     grant_contract.mjs — because a one-time assertion inside a migration is
--     not a standing property (044 §5's lesson, stated there about views).
-- ---------------------------------------------------------------------
DO $$
DECLARE remaining text[];
BEGIN
  SELECT array_agg(n.nspname||'.'||p.proname ORDER BY n.nspname, p.proname)
    INTO remaining
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('principal','safety','obs','evidence','domain','app','public')
     AND p.prokind = 'f' AND NOT p.prosecdef AND p.proacl IS NOT NULL
     AND EXISTS (SELECT 1 FROM unnest(p.proacl) a WHERE a::text LIKE '=X/%')
     AND EXISTS (SELECT 1 FROM unnest(p.proacl) a
                  WHERE a::text NOT LIKE '=X/%'
                    AND a::text NOT LIKE (pg_get_userbyid(p.proowner) || '=%'));

  IF remaining IS NOT NULL THEN
    RAISE EXCEPTION
      '049 §3: % function(s) still name a role AND grant PUBLIC: %',
      array_length(remaining, 1), array_to_string(remaining, ', ');
  END IF;

  RAISE NOTICE '049: no invoker function names a role and grants PUBLIC.';
END $$;

COMMIT;
