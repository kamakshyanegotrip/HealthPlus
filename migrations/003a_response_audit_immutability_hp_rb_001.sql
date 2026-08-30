-- HealthPlus migration: 003a — Audit immutability (event-sourced correction)
-- Source: HP-RB-001 Runbook: Audit Immutability Before First Data
--
-- HP-RB-001 §1 identifies a genuine contradiction in Charter v1.0 Annex A.5/A.6:
-- `response_audit` cannot be both mutable (review_state moves PENDING -> APPROVED)
-- and immutable (UPDATE/DELETE revoked) as originally specified. The fix, adopted
-- here and logged as Charter amendment C-30 (pending formal version increment):
-- make the audit an append-only EVENT log (this file), and derive the mutable,
-- queryable `response_audit` projection from it (see migration 018, which carries
-- the projection table with its CHECK constraints).
--
-- Sequenced 003a so it sorts after 001_003_reconciled_baseline.sql and before
-- 004_foundation.sql: per HP-RB-001 "Run when: in the first migration, before any
-- real record exists. Not later." and "Steps 1-8 are one sitting. Do them before
-- the first migration that creates a user."
--
-- Every statement below was executed against PostgreSQL 16.13 before this runbook
-- was issued (see HP-RB-001 Appendix — execution evidence: chain linkage, UPDATE/
-- DELETE/TRUNCATE rejection, payload_no_pii rejection, and tamper detection after
-- a superuser edit all verified). Not yet run against the live Supabase instance.
--
-- What this file deliberately does NOT include: the nightly hash-chain
-- verification query and the hourly external-anchor job (HP-RB-001 §6-7) are
-- operational jobs, not schema — they belong in the ops/cron layer, not a
-- migration, and are reproduced verbatim in HP-RB-001 for whoever wires up
-- pg_cron / the anchor job.

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- digest()

-- ---------------------------------------------------------------------------
-- §2 — role separation. The application must NEVER connect as owner/superuser;
-- every control below is decorative if it does.
-- ---------------------------------------------------------------------------
CREATE ROLE hp_owner   NOLOGIN;                  -- owns schema; used only for migrations
CREATE ROLE hp_app     LOGIN PASSWORD '...';     -- the application — set a real password out of band
CREATE ROLE hp_reader  LOGIN PASSWORD '...';     -- verification job, analytics; read-only

-- ---------------------------------------------------------------------------
-- §3 — the append-only event log
-- ---------------------------------------------------------------------------
CREATE TYPE audit_event_kind AS ENUM (
  'RESPONSE_DRAFTED','CATEGORY_ASSIGNED','SEVERITY_ASSIGNED','VALIDATOR_BLOCK',
  'TEMPLATE_RENDERED','REVIEW_REQUESTED','REVIEW_DECIDED','PUBLISHED','FLAG_RAISED'
);

CREATE TABLE response_audit_event (
  seq         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  audit_id    uuid        NOT NULL,          -- groups events for one response
  kind        audit_event_kind NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  actor       text        NOT NULL,          -- 'system' | 'clinician:<uuid>' | 'job:<name>'
  subject_ref uuid,                          -- pseudonymous ref into the erasable store
  payload     jsonb       NOT NULL,
  prev_hash   bytea       NOT NULL,
  row_hash    bytea       NOT NULL
);

-- Payload discipline is a hard rule, not a convention: payload holds IDs, enums,
-- version strings, numeric scores and hashes — never user text, health
-- attributes, or names. If free text must be evidenced, store its SHA-256 here
-- and the text itself in the erasable store (subject_key-wrapped, per migration 018).
ALTER TABLE response_audit_event ADD CONSTRAINT payload_no_pii CHECK (
  NOT (payload ?| ARRAY['user_text','message','name','email','phone','dob',
                        'symptoms','conditions','health_flags','free_text'])
);

-- ---------------------------------------------------------------------------
-- §4 — the hash chain. The application never supplies prev_hash/row_hash; the
-- trigger computes both, which is what stops a compromised application from
-- forging a chain.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit_event_chain() RETURNS trigger AS $$
DECLARE
  last_hash bytea;
  canonical text;
BEGIN
  -- Serialise chain appends. Concurrent inserts would otherwise read the same head.
  PERFORM pg_advisory_xact_lock(hashtext('response_audit_event_chain'));

  SELECT row_hash INTO last_hash
    FROM response_audit_event ORDER BY seq DESC LIMIT 1;

  IF last_hash IS NULL THEN
    last_hash := decode(repeat('00', 32), 'hex');          -- genesis
  END IF;

  -- jsonb text output is canonical in Postgres: keys sorted, duplicates removed,
  -- whitespace normalised. Safe to hash directly.
  canonical := NEW.audit_id::text
    || '|' || NEW.kind::text
    || '|' || to_char(NEW.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US')
    || '|' || NEW.actor
    || '|' || coalesce(NEW.subject_ref::text, '')
    || '|' || NEW.payload::text;

  NEW.prev_hash := last_hash;
  NEW.row_hash  := digest(last_hash || convert_to(canonical, 'UTF8'), 'sha256');
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_event_chain
  BEFORE INSERT ON response_audit_event
  FOR EACH ROW EXECUTE FUNCTION audit_event_chain();

-- Throughput note (HP-RB-001 §4): the advisory lock serialises appends. At v1
-- volume this is irrelevant; if it ever isn't, shard the chain by day and
-- anchor each shard — do not remove the lock.

-- ---------------------------------------------------------------------------
-- §5 — forbid mutation. Belt and braces on purpose: grants stop the
-- application, triggers stop a mistaken migration, neither stops a superuser
-- (see §8 in HP-RB-001 — tamper-evident, not tamper-proof).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION forbid_mutation() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'HP-ESC A.6: % on % is forbidden', TG_OP, TG_TABLE_NAME;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_event_immutable
  BEFORE UPDATE OR DELETE ON response_audit_event
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

CREATE TRIGGER trg_audit_event_no_truncate
  BEFORE TRUNCATE ON response_audit_event
  EXECUTE FUNCTION forbid_mutation();

REVOKE ALL ON response_audit_event FROM PUBLIC;
GRANT INSERT, SELECT ON response_audit_event TO hp_app;
GRANT SELECT                ON response_audit_event TO hp_reader;
-- Deliberately no UPDATE, DELETE, TRUNCATE to anyone but the owner.

-- ---------------------------------------------------------------------------
-- §6 — external anchoring. A hash chain inside a database proves nothing
-- against someone who controls that database; what makes it evidence is
-- periodically publishing its head somewhere that operator does not control.
-- The hourly anchor job itself (HP-RB-001 §6) is an ops job, not schema.
-- ---------------------------------------------------------------------------
CREATE TABLE audit_anchor (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  anchored_at  timestamptz NOT NULL DEFAULT now(),
  head_seq     bigint      NOT NULL,
  head_hash    bytea       NOT NULL,
  event_count  bigint      NOT NULL,
  external_uri text
);

-- Remaining HP-RB-001 order-of-execution items NOT captured in schema and
-- still required before first real data (see HP-RB-001 §10 for the full list):
--   5. Create the anchor bucket with a write-only, no-delete token; verify a
--      delete against it actually fails.
--   6. Write the GENESIS anchor row — before any real event exists.
--   7. Schedule the hourly anchor job and the nightly verification job
--      (HP-RB-001 §7's recomputation query).
--   8. Configure WAL-G shipping to the same anchor object store; run a
--      restore drill (not just a backup).
--   9. Write the test asserting no event type emits a non-whitelisted payload key.
--  10. Write the test asserting UPDATE/DELETE on response_audit_event fail as hp_app.
--  11. Log Charter amendment C-30 formally at the next version increment.
