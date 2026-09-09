-- =====================================================================
-- 043 — reasoner_role cannot read the confidence machinery it is required
--       to run
--
-- FOUND BY: the same run as 042, immediately after 042 fixed the first wall.
-- With `evidence.policy_for` reachable, retrieval failed one step later:
--
--   ERROR: permission denied for table aggregate_method
--   CONTEXT: SQL statement "SELECT * FROM evidence.aggregate_method
--            WHERE adoption_state IN ('ADOPTED','PROVISIONAL') LIMIT 1"
--   PL/pgSQL function evidence.aggregate_claim_base(uuid) line 4
--   SQL statement "SELECT * FROM evidence.aggregate_claim_base(p_claim)"
--   PL/pgSQL function evidence.aggregate_claim(uuid) line 4
--
-- =====================================================================
-- WHY THIS IS A GRANT AND 042 WAS A DEFINER
--
-- The two findings look identical and are not, and the difference decides the
-- instrument.
--
-- 042: `policy_for` reads `safety.response_category_state`. reasoner_role must
-- hold NOTHING in schema `safety` — that is R13-conn's whole property — so the
-- access had to move inside the function, and SECURITY DEFINER was the way.
--
-- 043: `aggregate_claim` reads three tables in `evidence`, a schema
-- reasoner_role already has USAGE on and already reads eleven other tables in.
-- The tables are ADOPTED CONFIGURATION, not health data and not evidence
-- content: which aggregation method is in force, which conflicts have been
-- recorded against a claim, and which class a claim kind belongs to. Reading
-- them is exactly what computing a confidence requires.
--
-- So the narrow fix is the grant, and making these definers instead would be
-- the wide one: it would hide readable policy behind a function boundary for
-- no gain and add three more definers to keep 040's rule over. A DEFINER is for
-- crossing a boundary that must not be crossed. There is no such boundary here.
--
-- =====================================================================
-- WHY THESE THREE AND NOT THE OTHER FIVE
--
-- Eight tables in `evidence` were unreadable by reasoner_role. Five stay that
-- way: claim_aggregate, claim_kind_decay, confidence_modifier,
-- study_design_submodifier, domain_attribute_kind. They are not needed — the
-- retrieval path was run as reasoner_role with exactly the three grants below
-- and returned its row, which is how the set was established rather than
-- reasoned about. A grant nobody needs is a grant nobody will notice going
-- wrong later.
--
-- (domain_attribute_kind in particular is the registry the R10f test reads to
-- pin that TEST_INTERPRETATION has no slot. That is a SEED-connection read, not
-- a request-path one, and it stays that way.)
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- §1. The three reads evidence.aggregate_claim actually performs.
--
-- SELECT only. reasoner_role holds no write on anything in this schema and
-- must not start now: the retrieval path takes untrusted user text, and the
-- reason it runs on its own role at all is so that a compromise there cannot
-- write evidence, safety rules, or audit rows.
-- ---------------------------------------------------------------------

-- which aggregation method is adopted (evidence.aggregate_claim_base line 4)
GRANT SELECT ON evidence.aggregate_method  TO reasoner_role;

-- recorded conflicts against a claim; they lower the aggregate
GRANT SELECT ON evidence.claim_conflict    TO reasoner_role;

-- the claim kind's class, which selects the decay/aggregation treatment
GRANT SELECT ON evidence.claim_kind_class  TO reasoner_role;

-- ---------------------------------------------------------------------
-- §2. The whole retrieval query, run AS reasoner_role, inside this
--     transaction.
--
-- Not "the grants exist" — three GRANT statements always leave three grants
-- existing. This runs the actual shape knowledgeLookup.ts issues, as the actual
-- role, and fails the migration if it cannot complete. That is the check that
-- would have caught both 042 and 043 before either shipped.
--
-- It asserts COMPLETION, not a row count: the query is run against whatever
-- evidence the database happens to hold, and an empty corpus is not a
-- privilege failure. A permission error raises; no rows does not.
-- ---------------------------------------------------------------------
DO $$
DECLARE n integer;
BEGIN
  SET LOCAL SESSION AUTHORIZATION reasoner_role;

  SELECT count(*) INTO n
    FROM evidence.claim_search('probe', ARRAY['guideline']::text[], NULL, 12) cs
    JOIN evidence.claim c ON c.id = cs.claim_id
    JOIN evidence.evidence_source es ON es.id = cs.source_id
    CROSS JOIN LATERAL evidence.aggregate_claim(c.id) ag
    CROSS JOIN LATERAL evidence.policy_for(es.tier, c.kind, 'DECISION_SUPPORT'::response_category) pol
   WHERE pol.disposition <> 'PROHIBITED'
     AND es.retracted = false
     AND ag.agg_confidence >= 0.40
     AND evidence.render_citation(es.id) IS NOT NULL;

  RESET SESSION AUTHORIZATION;
  RAISE NOTICE '043: the retrieval query completes as reasoner_role (% row(s))', n;
EXCEPTION WHEN insufficient_privilege THEN
  RESET SESSION AUTHORIZATION;
  RAISE EXCEPTION
    '043: the retrieval path is still unreachable by reasoner_role: %. '
    'Add the missing SELECT here rather than granting the schema wholesale.',
    SQLERRM;
END $$;

-- ---------------------------------------------------------------------
-- §3. The direction that must NOT change: reasoner_role stays out of safety
--     and obs, and holds no write anywhere in evidence.
--
-- r13_conn_isolation.sh §3 is the standing gate for this. It is restated here
-- because this migration is the one that widens reasoner_role, and a widening
-- migration should be the place that says what it did not widen.
-- ---------------------------------------------------------------------
DO $$
DECLARE bad text[] := ARRAY[]::text[]; r record;
BEGIN
  IF has_schema_privilege('reasoner_role', 'safety', 'USAGE') THEN
    bad := bad || 'USAGE on schema safety';
  END IF;
  IF has_schema_privilege('reasoner_role', 'obs', 'USAGE') THEN
    bad := bad || 'USAGE on schema obs';
  END IF;

  FOR r IN
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'evidence' AND c.relkind = 'r'
       AND (has_table_privilege('reasoner_role', c.oid, 'INSERT')
         OR has_table_privilege('reasoner_role', c.oid, 'UPDATE')
         OR has_table_privilege('reasoner_role', c.oid, 'DELETE'))
  LOOP
    bad := bad || ('write on evidence.' || r.relname);
  END LOOP;

  IF array_length(bad, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      '043 §3: reasoner_role holds %. The retrieval path parses untrusted user '
      'text; it runs on its own role so that a compromise there cannot write '
      'evidence, safety rules or audit rows (R13-conn).',
      array_to_string(bad, ', ');
  END IF;
END $$;

COMMIT;
