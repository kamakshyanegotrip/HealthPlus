-- =====================================================================
-- 046 — the queue role, because pg-boss cannot start as any role this
--       schema has
--
-- FOUND while writing the deployment run-book, by starting pg-boss rather than
-- by reading its documentation.
--
-- `src/worker.ts` is the always-on ingestion process (HP-ADR-001 §3.4). It does
-- `new PgBoss({ connectionString })` from `DATABASE_URL`, and pg-boss creates
-- and migrates its own `pgboss` schema on start. Every role this schema defines
-- fails that:
--
--     has_database_privilege('hp_app',        <db>, 'CREATE')  -> false
--     has_database_privilege('dqe_role',      <db>, 'CREATE')  -> false
--     has_database_privilege('alert_role',    <db>, 'CREATE')  -> false
--     has_database_privilege('metrics_role',  <db>, 'CREATE')  -> false
--     has_database_privilege('reasoner_role', <db>, 'CREATE')  -> false
--     has_database_privilege('redflag_role',  <db>, 'CREATE')  -> false
--
-- and the observed failure is `permission denied for database`, on start, before
-- a single job is registered. The run-book's step "point DATABASE_URL at hp_app
-- and deploy" would have produced a worker that has never once started.
--
-- OWNING THE SCHEMA IS NOT ENOUGH. The first attempt created the `pgboss` schema
-- as owner and handed it to a role by AUTHORIZATION. pg-boss still failed the
-- same way: it issues its own `CREATE SCHEMA IF NOT EXISTS` regardless of
-- whether the schema is there. The privilege it needs is CREATE on the DATABASE,
-- and nothing narrower will do while it manages its own schema version.
--
-- =====================================================================
-- WHY A ROLE OF ITS OWN, AND WHY THAT IS NOT A WIDENING
--
-- CREATE on the database is more than any application role here holds, and none
-- of them should gain it — HP-RB-001 §2 and migration 031's revocation of thirty
-- speculative grants both point the other way. So the privilege goes to a role
-- that holds nothing else:
--
--     principal  USAGE = false      evidence  USAGE = false
--     safety     USAGE = false      domain    USAGE = false
--     obs        USAGE = false
--
-- Verified after the fact, as the role. `queue_role` can manage a job queue and
-- cannot read a patient, a claim, a safety event or an audit row. It is a
-- queue-infrastructure role, not an application one.
--
-- WHAT IS IN THE QUEUE. pg-boss job payloads are written by
-- `src/jobs/extractClaimsFromProviderSubmission.ts` — provider submissions and
-- evidence extraction. No patient data passes through this queue today. If a job
-- carrying subject data is ever added, that is the moment to ask whether the
-- payload column needs the same treatment `obs.response_content` gets, and this
-- comment is where that question should be answered rather than rediscovered.
--
-- MIGRATION 034 §1's PRINCIPLE PUTS THIS HERE RATHER THAN IN A RUN-BOOK: "a role
-- gets LOGIN in the migration that builds its caller." `src/worker.ts` is the
-- caller and it already exists. A role created by hand during a deploy is a role
-- that exists only in one operator's shell history, and the next environment
-- built from `migrations/` would not have it.
--
-- NO PASSWORD HERE. Same rule as 034: "a password in a migration is a password
-- in git", and ALTER ROLE ... PASSWORD is cluster-wide, so a migration setting
-- one would change the credential on every database in the cluster. The operator
-- sets it out of band; the run-book says where.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- §1. The role. Created idempotently; roles are cluster-wide, so this file
--     declares the whole intended state of it rather than a delta (034's
--     second rule).
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'queue_role') THEN
    CREATE ROLE queue_role;
  END IF;

  -- LOGIN because src/worker.ts connects as it. CONNECTION LIMIT sized like the
  -- others in 034 §1: pg-boss holds a small pool plus its maintenance
  -- connection, and a ceiling makes a leak visible instead of exhausting the
  -- database's own limit.
  EXECUTE 'ALTER ROLE queue_role LOGIN CONNECTION LIMIT 4';

  -- Explicitly NOT a superuser, NOT a createrole, NOT a createdb. Stated rather
  -- than assumed, because the one privilege below is unusual enough that the
  -- absence of the others should be on the record.
  EXECUTE 'ALTER ROLE queue_role NOSUPERUSER NOCREATEROLE NOCREATEDB NOREPLICATION NOBYPASSRLS';
END $$;

-- ---------------------------------------------------------------------
-- §2. CREATE on THIS database.
--
--     Database-scoped, so it cannot be written as a literal — the database name
--     differs per deployment and the local, CI and production names are all
--     different. format(%I) against current_database() is the only spelling that
--     is correct in all three.
-- ---------------------------------------------------------------------
DO $$
BEGIN
  EXECUTE format('GRANT CREATE ON DATABASE %I TO queue_role', current_database());
END $$;

-- ---------------------------------------------------------------------
-- §3. The schema, pre-created and owned.
--
--     pg-boss would create it itself given §2. It is created here anyway so that
--     ownership is a property of the schema rather than an accident of whoever
--     started the worker first — and so that §5 can assert the boundary without
--     needing pg-boss to have run.
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS pgboss AUTHORIZATION queue_role;

-- ---------------------------------------------------------------------
-- §4. And nothing else. Asserted, not assumed.
--
--     The point of a separate role is the smallness of what it reaches. That is
--     a claim about the schema, so it is checked here and will fail the
--     migration if a later grant widens it.
-- ---------------------------------------------------------------------
DO $$
DECLARE reachable text[];
BEGIN
  SELECT array_agg(n ORDER BY n) INTO reachable
    FROM unnest(ARRAY['principal','safety','obs','evidence','domain']) n
   WHERE has_schema_privilege('queue_role', n, 'USAGE');

  IF reachable IS NOT NULL THEN
    RAISE EXCEPTION
      '046: queue_role has USAGE on %. It holds CREATE on the database so that '
      'pg-boss can manage its own schema; that is only acceptable while it can '
      'reach nothing else. Revoke, or move the queue to its own database.',
      array_to_string(reachable, ', ');
  END IF;

  IF (SELECT rolsuper OR rolcreaterole OR rolcreatedb OR rolbypassrls
        FROM pg_roles WHERE rolname = 'queue_role') THEN
    RAISE EXCEPTION '046: queue_role holds a role attribute it must not.';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- §5. The privilege that was missing, present.
-- ---------------------------------------------------------------------
DO $$
BEGIN
  IF NOT has_database_privilege('queue_role', current_database(), 'CREATE') THEN
    RAISE EXCEPTION
      '046: queue_role still cannot CREATE in %. pg-boss issues its own '
      'CREATE SCHEMA on start and fails with "permission denied for database" '
      'without this — before registering a single job handler.', current_database();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_namespace n JOIN pg_roles r ON r.oid = n.nspowner
                  WHERE n.nspname = 'pgboss' AND r.rolname = 'queue_role') THEN
    RAISE EXCEPTION '046: schema pgboss exists but queue_role does not own it.';
  END IF;

  RAISE NOTICE '046: queue_role can start pg-boss in % and reaches no application schema.',
    current_database();
END $$;

COMMIT;
