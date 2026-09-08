-- ============================================================================
-- MIGRATION 037 — dqe_role GAINS A CALLER  (register item R10-role-routing)
--
-- Migration 034 §1 withheld LOGIN from three roles and said why:
--
--     "They get LOGIN in the migration that builds their caller, not before."
--
-- migrations/test/r13_conn_isolation.sh enforces that, and its failure message
-- names the remedy: "If a caller now exists, give it LOGIN in the migration
-- that builds the caller." This is that migration for dqe_role.
--
-- ---------------------------------------------------------------------------
-- THE CALLER, AND WHY IT WAS NOT ONE BEFORE
--
-- src/jobs/extractClaimsFromProviderSubmission.ts is the ingestion path. It has
-- always connected through src/db/pool.ts, which is built from DATABASE_URL and
-- has never been per-role — so it ran as hp_app, which holds USAGE on `public`
-- and nothing else. R13-roleci scored its ten SQL literals as failing AS THE
-- ROLE THEIR MODULE CONNECTS AS: `permission denied for schema evidence`,
-- `domain`, `principal`, `obs`. Ten sites, one cause.
--
-- dqe_role is the role the schema already built for that work: USAGE on
-- `evidence` and `safety`, and the grants the Data Quality Engine needs. It had
-- no LOGIN because nothing had ever connected as it. The same commit as this
-- migration gives src/db/pool.ts a dqe pool, so it now does.
--
-- ---------------------------------------------------------------------------
-- WHY THIS RESTATES ALL SEVEN ROLES RATHER THAN JUST THE ONE THAT CHANGES
--
-- 034 §1 is declarative over all seven for a reason it learned the hard way:
-- ROLES ARE CLUSTER-WIDE, so a migration that only says what it wants for the
-- roles it changes is correct on a fresh cluster and silently wrong on one
-- where an earlier attempt left different state. Dropping the database does not
-- drop the role.
--
-- That argument does not stop applying because a second migration now touches
-- the same objects. If 037 said only `ALTER ROLE dqe_role LOGIN`, then the
-- newest statement of intent would be split across two files and neither would
-- be complete — and 034, read alone, would still say dqe_role is NOLOGIN.
--
-- So the invariant is: THE NEWEST MIGRATION OVER A CLUSTER-WIDE OBJECT DECLARES
-- THE WHOLE STATE. 034 remains correct as history; this file is now the answer
-- to "what is the intended LOGIN state?".
-- ============================================================================

BEGIN;

DO $$
BEGIN
  -- The web process.
  EXECUTE 'ALTER ROLE redflag_role  LOGIN CONNECTION LIMIT 4';
  EXECUTE 'ALTER ROLE reasoner_role LOGIN CONNECTION LIMIT 6';
  -- Out-of-process workers, each its own deployment.
  EXECUTE 'ALTER ROLE alert_role    LOGIN CONNECTION LIMIT 3';
  EXECUTE 'ALTER ROLE metrics_role  LOGIN CONNECTION LIMIT 2';

  -- NEW IN 037. Ingestion runs as a background job on pg-boss, not per request,
  -- so a small cap: it is one process doing bounded work, and a runaway
  -- ingestion must not be able to starve the request path of connections.
  EXECUTE 'ALTER ROLE dqe_role      LOGIN CONNECTION LIMIT 3';

  -- STILL NO LOGIN, and still for the reason 034 gave.
  --
  --   confirmation_ui_role  its one grant is INSERT on
  --                         principal.patient_attribute_confirmation, and
  --                         nothing in the codebase writes that table. The
  --                         confirmation UI does not exist yet.
  --   erasure_role          the erasure workflow is unbuilt, and HP-LB-001
  --                         blocks it.
  EXECUTE 'ALTER ROLE confirmation_ui_role NOLOGIN';
  EXECUTE 'ALTER ROLE erasure_role         NOLOGIN';
END $$;

DO $$
DECLARE db text := current_database();
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO dqe_role', db);
END $$;

-- SEC-1's region GUC, same belt-and-braces as 034 §3. Ingestion writes
-- region-stamped rows (obs.data_quality_flag, evidence.*), and a connection
-- that arrives without a region does not fail loudly — it writes NULL or reads
-- nothing, depending on the statement. The per-role default means a real dqe
-- login lands in the right region even if the pool forgets.
DO $$
DECLARE
  db     text := current_database();
  region text;
BEGIN
  SELECT code INTO region FROM region_registry
   WHERE code <> 'ZZ' AND active_to IS NULL ORDER BY active_from LIMIT 1;

  IF region IS NULL THEN
    RAISE EXCEPTION 'no admitted region in region_registry; cannot set a per-role default'
      USING HINT = 'ADR-004 §2 seeds IN. A cluster with none is a cluster where '
                   'every region-scoped policy would deny.';
  END IF;

  EXECUTE format('ALTER ROLE dqe_role IN DATABASE %I SET app.data_region = %L', db, region);
END $$;

-- No passwords, for the same reason 034 set none: a password in a migration is
-- a password in git. Until `scripts/set_role_passwords.sh` runs, dqe_role can
-- be named but not used, and src/db/pool.ts's fallback keeps ingestion running
-- as hp_app — recorded by dbRoleBindings(), not silent.

-- ---------------------------------------------------------------------------
-- §4  THE GRANTS THAT ONLY APPEAR ONCE SOMETHING CONNECTS AS THE ROLE
--
-- dqe_role held schema USAGE on `evidence`, `safety`, `app` and `public` — and
-- NOT ONE TABLE PRIVILEGE. Zero. R13's rule A reads that as clean (the role has
-- USAGE) and rule B reads it as clean (no grant, so no grant-without-policy),
-- which is the same blind spot HP-JOB-007 recorded for the safety schema and
-- migration 034 §4 closed for reasoner_role. A role with USAGE and no grants
-- looks configured and can do nothing.
--
-- Every grant below is derived from a statement the ingestion job actually
-- issues, and from nothing else. The nine sites R13-roleci reports as
-- `permission denied` are exactly the nine this closes.
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA obs, domain, principal TO dqe_role;

-- Ingestion writes data-quality findings; it never reads them back.
GRANT INSERT ON obs.data_quality_flag TO dqe_role;

-- The submission is the job's input, and its state machine is the job's output
-- (REJECTED with a reason, or CLAIMS_CREATED). SELECT and UPDATE, no INSERT:
-- submissions are created by providers, never by the engine that processes them.
GRANT SELECT, UPDATE ON domain.provider_submission TO dqe_role;

-- §5 of HP-DR-002's entity-binding step reads the submitting organisation to
-- bind claims to it. principal is the pseudonym schema, so this is deliberately
-- ONE TABLE: provider_org is an organisation record and carries no subject
-- pseudonyms. dqe_role gets no reach into app_user, patient_profile,
-- patient_attribute or subject_key, and R13 rule I would flag it if it did.
GRANT SELECT ON principal.provider_org TO dqe_role;

-- The engine's actual product: sources, claims, and the claim-source bindings
-- that carry confidence. Plus the decay table it reads to compute expiry.
GRANT INSERT ON evidence.evidence_source, evidence.claim, evidence.claim_source TO dqe_role;
GRANT SELECT ON evidence.claim_kind_decay TO dqe_role;

-- AND SELECT ON claim_source, WHICH THE JOB ITSELF NEVER READS.
--
-- Found by R13's rule H, not by reading the job: inserting evidence.claim fires
-- the INVOKER trigger evidence.claim_requires_source(), which enforces §1.0.1 —
-- "claim % has no evidence source" — by SELECTing evidence.claim_source. An
-- invoker's-rights trigger runs as whoever wrote the row, so a writer that
-- cannot read that table cannot fire its own constraint, and every claim insert
-- would fail with a permission error from inside a trigger.
--
-- This is the sixth grant class this project has found and the second time rule
-- H has caught it (migration 031 fixed event_requires_alert the same way). A
-- write grant is not complete until the writer can run what its write fires.
GRANT SELECT ON evidence.claim_source TO dqe_role;

-- ---------------------------------------------------------------------------
-- §5  AND THE POLICIES, BECAUSE TWO OF THOSE TABLES CARRY RLS
--
-- A grant onto a table with RLS enabled and no policy for the role is a grant
-- that does nothing — R13's rule B, and the shape migration 031 §5 spent its
-- length on. Both cases here are real:
--
--   obs.data_quality_flag       RLS on, ZERO policies. Default-deny for
--                               everyone, so the INSERT above is inert alone.
--   domain.provider_submission  RLS on, one policy, and it is the wrong shape
--                               for this caller: `p_submission_own_org` is
--                               USING (provider_org_id = app.current_provider_org()),
--                               which is a PROVIDER SESSION's boundary. A
--                               background job has no current provider org, so
--                               it would read zero rows — silently, which is
--                               the SEC-1 failure mode: a job that processes
--                               nothing and reports success.
--
-- ⚠ THE SCOPING CHOICE, STATED RATHER THAN BURIED. Ingestion processes every
-- organisation's submissions — that is what ingestion is — so it cannot be
-- scoped by provider org. It is scoped by REGION instead, the same boundary
-- migration 031 §5 gave metrics_role, and both directions are bounded: USING
-- limits which rows it can reach, WITH CHECK limits what it can leave behind.
-- That is SEC-1's lesson; a policy with only USING lets a region-correct row be
-- updated into a region-incorrect one.
--
-- obs.data_quality_flag HAS NO data_region COLUMN, so its policy cannot be
-- region-scoped and is written as an unconditional INSERT permission for this
-- one role. That is a gap in the table, not a decision made here, and it is
-- SEC-2's territory — recorded so the next reader does not mistake
-- `WITH CHECK (true)` for carelessness.
-- ---------------------------------------------------------------------------
CREATE POLICY p_dqf_dqe_insert ON obs.data_quality_flag
  FOR INSERT TO dqe_role
  WITH CHECK (true);

CREATE POLICY p_submission_dqe_read ON domain.provider_submission
  FOR SELECT TO dqe_role
  USING (data_region = app.current_region());

CREATE POLICY p_submission_dqe_state ON domain.provider_submission
  FOR UPDATE TO dqe_role
  USING (data_region = app.current_region())
  WITH CHECK (data_region = app.current_region());

COMMIT;
