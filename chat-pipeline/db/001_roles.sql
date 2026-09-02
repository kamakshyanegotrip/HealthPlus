-- Role setup for the stub schema — deliberately separate from db/000, since
-- on a real managed/Supabase Postgres project these roles are provisioned
-- at the platform level, not created by an app migration. Local dev and CI
-- both need them created explicitly first; this file is that one-time step.
-- Idempotent — safe to re-run against an existing database.
--
-- hp_app: the single pooled technical role the app itself connects as
-- (HP-RB-001 §2 — "the application must never connect as owner or
-- superuser"). Password below is a fixed local-dev/CI value, not a secret;
-- a real deployment sets this via its own secrets manager and never commits
-- a password here (see README's "Deployment" section).
--
-- hp_reader: read-only role for reporting/analytics access (db/000, db/010
-- grant it SELECT on a handful of tables) — never used by the app route
-- itself.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hp_app') THEN
    CREATE ROLE hp_app LOGIN PASSWORD 'hp_app_pw';
  ELSE
    ALTER ROLE hp_app WITH LOGIN PASSWORD 'hp_app_pw';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hp_reader') THEN
    CREATE ROLE hp_reader LOGIN PASSWORD 'hp_reader_pw';
  ELSE
    ALTER ROLE hp_reader WITH LOGIN PASSWORD 'hp_reader_pw';
  END IF;
END
$$;
