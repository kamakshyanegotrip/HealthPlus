-- =====================================================================
-- 045 — R13-trig: a constraint trigger is the schema's business, not the
--       caller's
--
-- SIXTEEN trigger functions were still SECURITY INVOKER. The register said
-- eight; a hand-written survey for this migration said thirteen, because it
-- listed the schemas it expected — safety, obs, principal, evidence, public —
-- and `domain` was not among them. The loop in §2 enumerates from pg_proc and
-- found three more on its first run (assert_subtype_kind, assert_subtype_present,
-- assert_wellness_safeguarding). Migration 040 enumerated for this reason and
-- said so; the reason turned up again here, in the same file that quotes it.
--
-- The framing was out of date too. What is underneath is worse than an
-- unexercised grant class.
--
-- =====================================================================
-- 1. THE TWO PRECEDENTS DISAGREE, AND ONE OF THEM MISREPORTS THE OTHER
--
-- Migration 031 §2b fixed `safety.event_requires_alert` by making it SECURITY
-- DEFINER, and said why a grant would have been wrong:
--
--     "granting redflag_role SELECT on clinician_alert would work too, and
--      would be the wrong fix: it widens access to alert records in order to
--      satisfy a constraint that is none of the caller's business."
--
-- Migration 037 §4 hit the identical shape with `evidence.claim_requires_source`
-- and fixed it with exactly that grant — `GRANT SELECT ON evidence.claim_source
-- TO dqe_role`, annotated in that file as "WHICH THE JOB ITSELF NEVER READS" —
-- while stating "migration 031 fixed event_requires_alert the same way". It did
-- not. 031 chose the fix 037 then made.
--
-- So the schema has two idioms for one problem and a comment that misdescribes
-- the file it cites. §2 below settles it on 031's side and removes the grant.
--
-- =====================================================================
-- 2. RULE H SEES ONE HALF OF THE PROBLEM
--
-- An INVOKER trigger runs with the writer's privileges. Rule H asks whether the
-- writer can READ what the trigger reads, which is the direction that produces a
-- loud failure: permission denied, from inside a trigger, and nothing is written.
--
-- The other direction is silent. Under row-level security the writer does not
-- get a permission error — it gets FEWER ROWS. A constraint that counts, or that
-- looks for a conflicting row, then reaches its verdict on the caller's slice of
-- the table rather than on the table.
--
-- `evidence.assert_attribute_cardinality` is that shape today:
--
--     SELECT count(*) INTO n FROM evidence.domain_attribute WHERE ...;
--     IF hi IS NOT NULL AND n > hi THEN RAISE EXCEPTION ...
--
-- An undercount passes the cap. evidence.domain_attribute has no RLS yet, so it
-- is dormant — but the same shape is live elsewhere, and one case is not dormant
-- at all.
--
-- =====================================================================
-- 3. THE AUDIT CHAIN FORKS. MEASURED, NOT ARGUED.
--
-- `public.audit_event_chain` is INVOKER and computes each row's prev_hash by
-- reading the current head of the log:
--
--     SELECT row_hash INTO last_hash FROM response_audit_event ORDER BY seq DESC LIMIT 1;
--
-- Under RLS "the head" becomes "the head this caller can see". Probed on this
-- schema with a policy that hides rows from each other, three appends by hp_app:
--
--     n=1  prev=000000000000   (genesis)
--     n=2  prev=000000000000   <-- genesis AGAIN; it could not see n=1
--     n=3  prev=<hash of n=1>  <-- skipped n=2 entirely
--
-- Two branches from genesis, and n=2 orphaned with nothing chaining onto it.
-- HP-RB-001's immutable, hash-chained record of truth stops being a chain and
-- becomes a forest, in which a row can be removed from the middle of a branch
-- without breaking any link a verifier can follow.
--
-- THIS IS A PRECONDITION, NOT HARDENING. SEC-2's remaining half is exactly
-- "add data_region and RLS to public.response_audit_event". The day that lands
-- with this trigger still INVOKER, the chain forks silently. R13-trig has to go
-- first.
--
-- =====================================================================
-- 4. WHAT THIS DOES
--
-- Every trigger function that TOUCHES A TABLE becomes SECURITY DEFINER with a
-- pinned search_path — thirteen of the sixteen. Three touch nothing and are
-- deliberately left alone:
-- `public.forbid_mutation` (raises), `safety.raise_alert_for_event` (delegates
-- to the already-definer safety.raise_alert), and
-- `principal.assert_key_destruction_final` (compares OLD to NEW). Converting a
-- function that reads nothing changes nothing and adds a definer to audit.
--
-- ALTER FUNCTION, NOT CREATE OR REPLACE. Restating thirteen bodies to change one
-- property is thirteen chances to mistype a constraint, and the bodies are not
-- what is wrong with them. ALTER is transactional and touches only the flag and
-- the path.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- §0. The state, reported. (Reports rather than raises: run_migrations.mjs
--     keeps no ledger, so every file here has to survive a second run.)
-- ---------------------------------------------------------------------
DO $$
DECLARE invoker_touching integer;
BEGIN
  SELECT count(*) INTO invoker_touching
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE p.prorettype = 'trigger'::regtype AND NOT p.prosecdef
     AND n.nspname NOT IN ('pg_catalog','information_schema')
     AND p.prosrc ~ '(FROM|JOIN|INTO|UPDATE|DELETE FROM)\s';
  RAISE NOTICE '045: % INVOKER trigger function(s) touch a table', invoker_touching;
END $$;

-- ---------------------------------------------------------------------
-- §1. A PINNED search_path IS ONLY SAFE IF NOBODY CAN PLANT IN IT.
--
--     The classic SECURITY DEFINER escalation is an object created earlier in
--     the resolution order than the one the author meant. Pinning the path
--     removes the caller's control over it; it does not help if an application
--     role can CREATE in one of the pinned schemas. That is the invariant this
--     migration actually depends on, so it is asserted rather than assumed.
-- ---------------------------------------------------------------------
DO $$
DECLARE offender text;
BEGIN
  SELECT r.rolname || ' can CREATE in ' || n.nspname INTO offender
    FROM pg_roles r, pg_namespace n
   WHERE r.rolname IN ('hp_app','hp_reader','reasoner_role','redflag_role',
                       'alert_role','metrics_role','dqe_role',
                       'confirmation_ui_role','erasure_role')
     AND n.nspname IN ('principal','safety','obs','evidence','domain','public')
     AND has_schema_privilege(r.rolname, n.nspname, 'CREATE')
   LIMIT 1;

  IF offender IS NOT NULL THEN
    RAISE EXCEPTION
      '045: %. A pinned search_path on a SECURITY DEFINER function is only worth '
      'anything while no caller can create objects in the schemas it names. '
      'Revoke CREATE before converting these triggers.', offender;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- §2. THE CONVERSION.
--
--     Enumerated from pg_proc, not hand-listed — migration 040 wrote its list
--     that way because a hand-written list that forgets an entry IS the finding
--     restated, and the same applies here.
--
--     The predicate is "does the body touch a table", which is what decides
--     whether running as the caller can change the answer. A function that
--     reads nothing is skipped and named in the notice, so the skip is visible
--     rather than silent.
-- ---------------------------------------------------------------------
DO $$
DECLARE f record; n_conv integer := 0; n_skip integer := 0;
BEGIN
  FOR f IN
    SELECT p.oid, n.nspname, p.proname,
           p.prosrc ~ '(FROM|JOIN|INTO|UPDATE|DELETE FROM)\s' AS touches
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE p.prorettype = 'trigger'::regtype
       AND NOT p.prosecdef
       AND n.nspname NOT IN ('pg_catalog','information_schema')
     ORDER BY n.nspname, p.proname
  LOOP
    IF NOT f.touches THEN
      RAISE NOTICE '045: %.% reads nothing — left as INVOKER', f.nspname, f.proname;
      n_skip := n_skip + 1;
      CONTINUE;
    END IF;

    EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER', f.oid::regprocedure);
    -- One path for all of them. Per-function paths would be narrower, and would
    -- also be a second place for the truth about what each body reaches to live;
    -- §1 asserts the property that makes the breadth safe.
    EXECUTE format(
      'ALTER FUNCTION %s SET search_path = pg_catalog, principal, safety, obs, evidence, domain, public',
      f.oid::regprocedure);
    RAISE NOTICE '045: %.% -> SECURITY DEFINER', f.nspname, f.proname;
    n_conv := n_conv + 1;
  END LOOP;

  RAISE NOTICE '045: % converted, % left as INVOKER', n_conv, n_skip;
END $$;

-- ---------------------------------------------------------------------
-- §3. Migration 040's rule L, applied to what §2 just created.
--
--     A trigger function cannot be CALLED directly — PostgreSQL refuses with
--     "trigger functions can only be called as triggers" — so revoking PUBLIC
--     here does not stop any trigger firing and does not need a compensating
--     grant. It is done because rule L is a property of the schema and an
--     exception nobody can exploit is still an exception somebody has to
--     re-derive as harmless later.
-- ---------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE p.prorettype = 'trigger'::regtype AND p.prosecdef
       AND n.nspname NOT IN ('pg_catalog','information_schema')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.oid::regprocedure);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- §4. Migration 037's grant, withdrawn.
--
--     `GRANT SELECT ON evidence.claim_source TO dqe_role` existed for one
--     reason: to let the INVOKER `claim_requires_source` fire. 037 said so in
--     the same breath as granting it — "WHICH THE JOB ITSELF NEVER READS" —
--     and grep confirms it: src/jobs/extractClaimsFromProviderSubmission.ts
--     INSERTs claim_source and never selects from it.
--
--     §2 made that trigger a definer, so the reason is gone. Migration 031's
--     argument now applies with nothing left to trade against it, and the
--     read is withdrawn. INSERT stays — the job really does write this table.
--
--     If any dqe_role query does read it, `role_contract.mjs` fails on the next
--     run and names the file and line. That is the check; this is not a guess.
-- ---------------------------------------------------------------------
REVOKE SELECT ON evidence.claim_source FROM dqe_role;

-- ---------------------------------------------------------------------
-- §5. THE PROOF — the chain, under the RLS that SEC-2's remaining half will
--     add, appending as a non-owner.
--
--     THE PROBE CANNOT CLEAN UP AFTER ITSELF, and that is the table working as
--     designed: `forbid_mutation` refuses DELETE on the append-only log, so the
--     first version of this block died on its own teardown with
--     "HP-ESC A.6: DELETE on response_audit_event is forbidden".
--
--     So it undoes itself the only way an append-only table allows — by never
--     committing. The inner BEGIN gives plpgsql an implicit savepoint; raising
--     at the end of it rolls back every row, policy and ALTER the probe made,
--     while the counts survive in plpgsql variables, which are memory and not
--     transactional. Only the ALTERs in §2 outlive this file.
--
--     The policy column is a stand-in for data_region: what matters is only
--     that some rows are invisible to the writer.
-- ---------------------------------------------------------------------
DO $$
DECLARE a uuid := '00000045-0000-0000-0000-000000000001';
        forks integer; orphans integer; region char(2);
BEGIN
  SELECT data_region INTO region FROM public.residency_admission
   WHERE admission_state = 'ADMITTED' ORDER BY residency_country LIMIT 1;
  IF region IS NULL THEN
    RAISE EXCEPTION '045 §5: no ADMITTED residency exists; cannot seed the parent audit row.';
  END IF;

  BEGIN
    INSERT INTO obs.response_audit
      (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
       agg_confidence, policy_version, model_version, prompt_version, cited_claim_ids,
       review_state, data_region)
    VALUES (a, sha256('045'::bytea), now(), 'INFORMATIONAL', 'c', 'NORMAL', 0.90,
            'pv', 'm', 'p', '{}', 'NOT_REQUIRED', region);

    ALTER TABLE public.response_audit_event ENABLE ROW LEVEL SECURITY;
    CREATE POLICY p_045_probe_read ON public.response_audit_event
      FOR SELECT USING (actor = current_setting('app.probe_actor', true));
    CREATE POLICY p_045_probe_write ON public.response_audit_event
      FOR INSERT WITH CHECK (true);

    SET LOCAL SESSION AUTHORIZATION hp_app;
      PERFORM set_config('app.probe_actor', 'system', true);
      INSERT INTO public.response_audit_event (audit_id, kind, occurred_at, actor, payload)
      VALUES (a, 'PUBLISHED', now(), 'system', '{"n":1}');
      PERFORM set_config('app.probe_actor', 'other', true);
      INSERT INTO public.response_audit_event (audit_id, kind, occurred_at, actor, payload)
      VALUES (a, 'PUBLISHED', now(), 'other', '{"n":2}');
      PERFORM set_config('app.probe_actor', 'system', true);
      INSERT INTO public.response_audit_event (audit_id, kind, occurred_at, actor, payload)
      VALUES (a, 'PUBLISHED', now(), 'system', '{"n":3}');
    RESET SESSION AUTHORIZATION;

    -- LINKS, NOT GENESIS ROWS.
    --
    -- The first version of this counted rows whose prev_hash is the genesis
    -- value and demanded exactly one. That is only true of an EMPTY log: on a
    -- database that has already served a request the probe's first append
    -- chains onto the existing head, so the count is zero and the check failed
    -- on its second run against its own success. The property under test was
    -- never "how many rows start a chain" — it is "does each append point at
    -- the row actually before it", which is true of any log at any length.
    SELECT count(*) INTO forks
      FROM (SELECT prev_hash, lag(row_hash) OVER (ORDER BY seq) AS should_be
              FROM public.response_audit_event WHERE audit_id = a) s
     WHERE s.should_be IS NOT NULL AND s.prev_hash = s.should_be;

    -- An orphan: a probe row nothing chains onto, other than the last one.
    SELECT count(*) INTO orphans
      FROM public.response_audit_event e
     WHERE e.audit_id = a
       AND e.seq <> (SELECT max(seq) FROM public.response_audit_event WHERE audit_id = a)
       AND NOT EXISTS (SELECT 1 FROM public.response_audit_event c
                        WHERE c.prev_hash = e.row_hash);

    RAISE EXCEPTION 'HP045-PROBE-DONE' USING ERRCODE = 'HP045';
  EXCEPTION WHEN SQLSTATE 'HP045' THEN
    -- Everything above is rolled back to the savepoint. forks and orphans are
    -- plpgsql variables and survive.
    RESET SESSION AUTHORIZATION;
  END;

  -- Three appends, so two links between them, and nothing left dangling.
  IF forks <> 2 OR orphans <> 0 THEN
    RAISE EXCEPTION
      '045 §5: the audit chain still forks under RLS — % of 2 links hold and % row(s) '
      'are orphaned. audit_event_chain must chain onto the TRUE head, which it can '
      'only see as the owner.', forks, orphans;
  END IF;

  RAISE NOTICE '045 §5: three appends across two RLS slices form ONE chain — 2/2 links, 0 orphans.';
END $$;

-- ---------------------------------------------------------------------
-- §6. The invariant, asserted: nothing that touches a table decides a
--     constraint on the caller's slice of it.
-- ---------------------------------------------------------------------
DO $$
DECLARE leftover text[];
BEGIN
  SELECT array_agg(n.nspname || '.' || p.proname ORDER BY 1) INTO leftover
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE p.prorettype = 'trigger'::regtype AND NOT p.prosecdef
     AND n.nspname NOT IN ('pg_catalog','information_schema')
     AND p.prosrc ~ '(FROM|JOIN|INTO|UPDATE|DELETE FROM)\s';

  IF leftover IS NOT NULL THEN
    RAISE EXCEPTION
      '045 §6: % still run(s) as the caller and reads a table. Under row-level '
      'security that means deciding a constraint on the caller''s slice — an '
      'undercount passes a cap, and a hidden row passes a uniqueness check.',
      array_to_string(leftover, ', ');
  END IF;
END $$;

COMMIT;
