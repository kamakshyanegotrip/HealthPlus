-- ============================================================================
-- MIGRATION 051 — STORAGE ERASURE QUEUE (closing the gap migration 050 §7
-- named but did not implement)
--
-- Origin: HP-JOB-010's own completeness review flagged, and the user then
-- asked to have closed, one thing migration 050 built the enforcement
-- comment for but not the mechanism: principal.erase_subject deletes the
-- `patient_upload_document` ROW, but the bytes it points at in Supabase
-- Storage were never touched. §2.3.4g / Article 17 erasure that leaves the
-- uploaded lab report itself sitting in Storage is not erasure, whatever the
-- Postgres side looks like.
--
-- WHY THIS CANNOT BE A ONE-LINE FIX INSIDE erase_subject. Deleting a Storage
-- object means an HTTP call to Supabase's Storage REST API. This cluster has
-- no `pg_net` (checked: `select extname from pg_extension` lists only
-- plpgsql, vector, pgcrypto) and nothing else in this schema calls out to
-- HTTP from inside a function — that is not this codebase's idiom, and
-- adding a new one, unreviewed, inside a SECURITY DEFINER erasure path is
-- exactly the kind of thing HP-SEC-002/003/004 exist to catch, not repeat.
-- The codebase's actual idiom for "a fact needs an out-of-process HTTP side
-- effect, reliably, exactly-once-ish" already exists: migration 029/035's
-- clinician_alert + claim_alert_batch + a small drain worker
-- (alert-worker.mjs). This migration is that same shape, once, for Storage
-- deletion:
--
--   1. principal.storage_erasure_queue — the table IS the queue, the same
--      design note 029/RF6 already made about clinician_alert ("the alert
--      table IS the queue... an alert cannot be lost by this worker being
--      down, by a fire-and-forget HTTP call failing, or by a request handler
--      returning early"). erase_subject INSERTs into it in the SAME
--      transaction as the rest of the Postgres-side erasure, so a row here
--      cannot be silently skipped by a failure elsewhere in that function.
--   2. storage_erasure_role — one LOGIN role, this migration's caller
--      (src/jobs/drainStorageErasure.ts, added alongside this migration),
--      same "one LOGIN role per worker role" / "LOGIN in the migration that
--      builds its caller" decision migrations 034/037/046/050 already made.
--   3. principal.claim_storage_erasure_batch / mark_storage_erasure_complete
--      / mark_storage_erasure_failed — SECURITY DEFINER verbs mirroring
--      safety.claim_alert_batch / mark_alert_delivered exactly (region
--      check, FOR UPDATE SKIP LOCKED, RAISE on a bad call), because that
--      pattern is already reviewed and this is the same shape of problem.
--
-- WHAT THIS DELIBERATELY DOES NOT PRETEND. erase_subject enqueuing a
-- deletion is not the same instant as the object being gone from Storage —
-- that leg is necessarily asynchronous, the drain worker being a separate
-- Fly process. principal.assert_shred_complete is changed to say so
-- honestly: it now reports a `storage_erasure_queue` row as SURVIVING until
-- the drain worker has actually deleted the object and the row is removed.
-- Calling assert_shred_complete immediately after erase_subject for a
-- subject who had uploads WILL show one surviving row, correctly, until the
-- worker catches up — this is the accurate signal, not a bug, and callers
-- (RB-001's runbook, any admin tool) should poll it rather than treat a
-- single check right after erase_subject as final.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- §1  storage_erasure_role — one LOGIN role, this migration's caller.
-- ---------------------------------------------------------------------------
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'storage_erasure_role') THEN
    CREATE ROLE storage_erasure_role NOLOGIN;
  END IF;
END $$;

DO $$
BEGIN
  EXECUTE 'ALTER ROLE storage_erasure_role LOGIN CONNECTION LIMIT 2';
END $$;

DO $$
DECLARE db text := current_database();
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO storage_erasure_role', db);
END $$;

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

  EXECUTE format(
    'ALTER ROLE storage_erasure_role IN DATABASE %I SET app.data_region = %L', db, region);
END $$;

-- No password here either — scripts/set_role_passwords.sh is the operator
-- step (DEPLOY.md Step 2); add storage_erasure_role to that script's list.

-- ---------------------------------------------------------------------------
-- §2  principal.storage_erasure_queue — the queue IS the table.
-- ---------------------------------------------------------------------------
CREATE TABLE principal.storage_erasure_queue (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- No FK to patient_profile/subject_key: by the time this row is drained,
  -- erase_subject has already deleted the patient_profile row it would
  -- reference. subject_id here is kept only for operator-visible log
  -- correlation while the row is PENDING, the same way clinician_alert keeps
  -- event_id after the event it names may itself have been superseded.
  subject_id           uuid NOT NULL,
  data_region          char(2) NOT NULL REFERENCES public.region_registry(code),
  storage_bucket       text NOT NULL,
  storage_object_path  text NOT NULL,
  requested_at         timestamptz NOT NULL DEFAULT now(),
  attempts             integer NOT NULL DEFAULT 0,
  last_error           text,
  UNIQUE (storage_bucket, storage_object_path)
);

CREATE INDEX idx_seq_region ON principal.storage_erasure_queue (data_region);

-- RLS ON with zero policies: deny-by-default for any role that is not this
-- table's owner. Nothing needs a policy here because nothing holds a direct
-- table grant (below) — every legitimate access is through the three
-- SECURITY DEFINER verbs in §3, the same shape rule I (HP-SEC-003/004) asks
-- for everywhere else a subject_id-bearing table exists.
ALTER TABLE principal.storage_erasure_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE principal.storage_erasure_queue FORCE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- §3  Three SECURITY DEFINER verbs, mirroring safety.claim_alert_batch /
-- mark_alert_delivered / mark_alert_undeliverable exactly in shape.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION principal.claim_storage_erasure_batch(p_limit integer)
RETURNS TABLE (
  id                   uuid,
  subject_id           uuid,
  storage_bucket       text,
  storage_object_path  text,
  attempts             integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, principal, app, public
AS $$
DECLARE
  v_region char(2) := app.current_region();
BEGIN
  IF v_region IS NULL THEN
    RAISE EXCEPTION 'claim_storage_erasure_batch: app.data_region is not set on this connection'
      USING HINT = 'Same SEC-1 hazard claim_alert_batch guards against: an unset region '
                   'would make every region-scoped predicate false and this worker would '
                   'report healthy empty batches forever.';
  END IF;

  IF p_limit IS NULL OR p_limit < 1 THEN
    RAISE EXCEPTION 'claim_storage_erasure_batch: p_limit must be a positive integer, got %', p_limit;
  END IF;

  RETURN QUERY
    SELECT q.id, q.subject_id, q.storage_bucket, q.storage_object_path, q.attempts
      FROM principal.storage_erasure_queue q
     WHERE q.data_region = v_region
     ORDER BY q.requested_at ASC
     LIMIT p_limit
       FOR UPDATE SKIP LOCKED;
END;
$$;

COMMENT ON FUNCTION principal.claim_storage_erasure_batch(integer) IS
  'Claims up to p_limit queued Storage-object deletions in the caller''s region with '
  'FOR UPDATE SKIP LOCKED, inside the caller''s transaction — same shape as '
  'safety.claim_alert_batch (migration 035).';

-- Deletion succeeded: the row is removed outright, not marked. Nothing about
-- a completed erasure needs to be retained — retaining "we deleted subject
-- X's object" after the fact would itself be a small plaintext linkage this
-- migration exists to close, not create.
CREATE OR REPLACE FUNCTION principal.mark_storage_erasure_complete(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, principal, public
AS $$
BEGIN
  DELETE FROM principal.storage_erasure_queue WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'mark_storage_erasure_complete: no such queue row %', p_id;
  END IF;
END;
$$;

-- Deletion failed (Storage API error, network, etc). Left PENDING so the
-- next drain picks it up again — a transient failure must not be
-- indistinguishable from success, and must not silently stop being retried
-- either. attempts/last_error are operator-visible via a direct query as the
-- table owner; there is no automatic terminal "FAILED" state on purpose,
-- mirroring RF6's own "NO ONE ON CALL... this is not a retry-able
-- condition" EXCEPT the opposite: unlike an undeliverable alert, a failed
-- Storage delete has no terminal outcome to record — it must keep being
-- true work until it succeeds.
CREATE OR REPLACE FUNCTION principal.mark_storage_erasure_failed(p_id uuid, p_error text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, principal, public
AS $$
BEGIN
  IF p_error IS NULL OR btrim(p_error) = '' THEN
    RAISE EXCEPTION 'mark_storage_erasure_failed: p_error is required';
  END IF;

  UPDATE principal.storage_erasure_queue
     SET attempts = attempts + 1,
         last_error = p_error
   WHERE id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'mark_storage_erasure_failed: no such queue row %', p_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION principal.claim_storage_erasure_batch(integer)  FROM PUBLIC;
REVOKE ALL ON FUNCTION principal.mark_storage_erasure_complete(uuid)   FROM PUBLIC;
REVOKE ALL ON FUNCTION principal.mark_storage_erasure_failed(uuid,text) FROM PUBLIC;

-- FOUND BY RUNNING THIS MIGRATION, not by reading it: calling a
-- SECURITY DEFINER function still requires the CALLER to hold USAGE on the
-- schema the function lives in — EXECUTE on the function alone is not
-- enough, the same "GRANT USAGE ON SCHEMA app" lesson migration 050 §5 (the
-- app.current_region() grant) already learned the same way. Without this,
-- storage_erasure_role fails at "permission denied for schema principal"
-- before it ever reaches the function body.
GRANT USAGE ON SCHEMA principal TO storage_erasure_role;

GRANT EXECUTE ON FUNCTION principal.claim_storage_erasure_batch(integer)   TO storage_erasure_role;
GRANT EXECUTE ON FUNCTION principal.mark_storage_erasure_complete(uuid)    TO storage_erasure_role;
GRANT EXECUTE ON FUNCTION principal.mark_storage_erasure_failed(uuid,text) TO storage_erasure_role;

-- No direct table grant to storage_erasure_role on purpose — every access is
-- through the three verbs above, the same "the tables themselves stay
-- unreachable" idiom migration 039 used for obs.record_* / principal writes.

-- ---------------------------------------------------------------------------
-- §4  principal.erase_subject enqueues the Storage deletion; the object's
-- coordinates are read BEFORE patient_upload_document is deleted, in the
-- same transaction, so the two cannot drift apart.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION principal.erase_subject(p_subject uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = principal, obs, public AS $$
BEGIN
  -- 1. key material first, so a failure part-way still leaves the data unreadable
  UPDATE principal.subject_key
     SET wrapped_dek = NULL, salt = NULL, destroyed_at = now()
   WHERE subject_id = p_subject AND destroyed_at IS NULL;

  -- 2. Layer 2 rows carrying any plaintext linkage
  DELETE FROM principal.patient_risk_flag           WHERE subject_id = p_subject;
  DELETE FROM principal.attribute_access_log        WHERE subject_id = p_subject;
  DELETE FROM principal.patient_attribute_confirmation WHERE subject_id = p_subject;
  UPDATE principal.patient_attribute
     SET confirmation_id = NULL WHERE subject_id = p_subject;
  DELETE FROM principal.patient_attribute           WHERE subject_id = p_subject;

  -- NEW (migration 051): capture the Storage coordinates for every upload
  -- this subject has BEFORE the row naming them is deleted. ON CONFLICT DO
  -- NOTHING makes a second erase_subject call for an already-erased subject
  -- (whose patient_upload_document rows are already gone) a no-op here, not
  -- an error — erase_subject as a whole is already safe to call twice
  -- (018's UPDATE ... WHERE destroyed_at IS NULL guards the one genuinely
  -- destructive step), and this must not be the thing that breaks that.
  INSERT INTO principal.storage_erasure_queue
    (subject_id, data_region, storage_bucket, storage_object_path)
  SELECT d.subject_id, d.data_region, d.storage_bucket, d.storage_object_path
    FROM principal.patient_upload_document d
   WHERE d.subject_id = p_subject
  ON CONFLICT (storage_bucket, storage_object_path) DO NOTHING;

  -- migration 050: the upload intake record itself.
  DELETE FROM principal.patient_upload_document     WHERE subject_id = p_subject;
  DELETE FROM obs.response_content                  WHERE subject_id = p_subject;
  DELETE FROM principal.patient_profile             WHERE user_id = p_subject;

  -- 3. obs.response_audit is NOT touched. It holds no personal data and its pseudonym
  --    can no longer be recomputed, the salt having gone with the key. §2.3.4g intact.
END $$;

-- ---------------------------------------------------------------------------
-- §5  assert_shred_complete now tells the truth about the async leg: a
-- queued-but-not-yet-drained Storage deletion is reported as surviving,
-- deliberately (see this file's header).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION principal.assert_shred_complete(p_subject uuid)
RETURNS TABLE (relation text, surviving bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = principal, obs, public AS $$
  SELECT 'subject_key.salt_or_dek', count(*) FROM principal.subject_key
    WHERE subject_id = p_subject AND (salt IS NOT NULL OR wrapped_dek IS NOT NULL)
  UNION ALL SELECT 'patient_attribute', count(*) FROM principal.patient_attribute
    WHERE subject_id = p_subject
  UNION ALL SELECT 'patient_attribute_confirmation', count(*)
    FROM principal.patient_attribute_confirmation WHERE subject_id = p_subject
  UNION ALL SELECT 'patient_risk_flag', count(*) FROM principal.patient_risk_flag
    WHERE subject_id = p_subject
  UNION ALL SELECT 'attribute_access_log', count(*) FROM principal.attribute_access_log
    WHERE subject_id = p_subject
  UNION ALL SELECT 'patient_upload_document', count(*) FROM principal.patient_upload_document
    WHERE subject_id = p_subject
  -- NEW (migration 051): PENDING Storage deletions for this subject. Non-zero
  -- immediately after erase_subject is EXPECTED — see this file's header —
  -- and should be polled, not treated as a failed erasure on first check.
  UNION ALL SELECT 'storage_erasure_queue', count(*) FROM principal.storage_erasure_queue
    WHERE subject_id = p_subject
  UNION ALL SELECT 'patient_profile', count(*) FROM principal.patient_profile
    WHERE user_id = p_subject
  UNION ALL SELECT 'response_content', count(*) FROM obs.response_content
    WHERE subject_id = p_subject;
$$;

COMMIT;
