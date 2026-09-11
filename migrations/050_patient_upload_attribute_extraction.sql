-- ============================================================================
-- MIGRATION 050 — PATIENT UPLOAD EXTRACTION  (HP-RECON-007's corrected design)
--
-- Origin: a request to extract structured values (test name, result, unit,
-- reference range as printed) from a patient-uploaded lab report / scan /
-- photo via Claude vision, and store them on the patient's profile.
--
-- HP-RECON-007 found the request's own framing unbuildable against this
-- schema as specified: it asked for a claim/claim_source (Annex A, Layer 1)
-- binding, and HP-SCHEMA-001 §17 says outright, about exactly this case,
-- that a patient-supplied attribute "is not a claim... and must never
-- acquire one" — feeding it through the DQE would give it a confidence score
-- computed for institutional evidence, which is the §3.8.1 fabrication this
-- schema exists to prevent. It also asked to bind to domain.clinical_indicator,
-- whose own column comment says the patient's own value is Category C
-- (§2.4.1a) and "adding them is a §2.3.2 Board decision" — not made in v1.
--
-- What is actually buildable, and what this migration adds: the extraction
-- lands in principal.patient_attribute (migration 018), which HP-SCHEMA-001
-- §17 built for exactly this shape (user-supplied, model-inferred personal
-- data) and which nothing has ever written to. Concretely:
--
--   1. patient_attribute_kind gains DIAGNOSTIC_RESULT — the one thing 018
--      did not anticipate this table would carry.
--   2. principal.patient_upload_document — the state machine for a received
--      file, mirroring domain.provider_submission's RECEIVED -> ... shape
--      (HP-JOB-002's ingestion idiom), but filed in `principal` rather than
--      `domain` because it carries subject_id and a storage path for a named
--      patient — domain "holds no facts" (migration 001's own schema
--      comment) and this table is nothing but a fact about one subject.
--   3. principal.record_inferred_attribute(...) — the write-side DEFINER
--      function patient_attribute has never had. Migration 039 gave the
--      request path six SECURITY DEFINER verbs for `obs`/`principal` and
--      said why: "the idiom already exists ... six reviewable verbs, EXECUTE
--      to hp_app, and the tables themselves stay unreachable." This is the
--      seventh verb, for the table 039 didn't touch because nothing called
--      it yet.
--   4. patient_upload_role — one LOGIN role for this worker, per migration
--      034's "one LOGIN role per worker role" decision and 037's "gets LOGIN
--      in the migration that builds its caller." This migration builds the
--      caller (src/jobs/extractPatientUploadAttributes.ts), so it gets LOGIN
--      here rather than waiting for a follow-on migration.
--
-- What this migration deliberately does NOT do: it does not touch
-- evidence.claim, evidence.claim_source, evidence.evidence_source, or any
-- confidence column, and it does not add a DIAGNOSTIC_RESULT kind to
-- domain.clinical_indicator. Charter §1.7 modifier M9 has no application
-- here — M9 discounts a claim's confidence, and nothing this migration
-- writes has one. The model's own per-field certainty travels inside the
-- encrypted payload (for a future confirmation UI to render, e.g. "we're not
-- sure about this one"), never as a stored confidence value anywhere.
--
-- NOT RUN AGAINST A DATABASE. Read against migrations 001-049 as they exist
-- on disk (018, 034, 037, 039, 041 read directly this session) and written
-- to their idiom, but per this project's own standing correction ("execute
-- against the real schema rather than reading it") this needs `npm run
-- migrate` against a real Postgres and the eighteen gates in migrations/test/
-- before it is trusted. See HP-RECON-007 and the accompanying build note.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- §1  patient_attribute_kind gains one value.
--
-- ALTER TYPE ... ADD VALUE cannot be used in the same transaction as a
-- statement that USES the new value (PostgreSQL restriction, independent of
-- version) — this migration only adds it; nothing below inserts a row of
-- this kind, so the whole file can stay one transaction.
-- ---------------------------------------------------------------------------
ALTER TYPE patient_attribute_kind ADD VALUE IF NOT EXISTS 'DIAGNOSTIC_RESULT';

COMMENT ON TYPE patient_attribute_kind IS
  'HP-SCHEMA-001 §17 + migration 050. DIAGNOSTIC_RESULT: test name/result/unit/'
  'reference-range-as-printed extracted from a patient-uploaded lab report, scan, '
  'or photo. Always origin=MODEL_INFERRED, always provenance=inferred at write '
  'time (c_inferred_origin_matches). Never a claim (HP-SCHEMA-001 §17.2); never '
  'written to domain.clinical_indicator (Category C, §2.3.2, not enabled in v1).';

-- ---------------------------------------------------------------------------
-- §2  principal.patient_upload_document — the intake state machine.
--
-- Mirrors domain.provider_submission's RECEIVED -> ... shape and FOR UPDATE
-- idempotency idiom (extractClaimsFromProviderSubmission.ts), but lives in
-- `principal` because it is a fact about one named subject, not taxonomy.
-- ---------------------------------------------------------------------------
CREATE TYPE patient_upload_state AS ENUM ('RECEIVED', 'EXTRACTING', 'EXTRACTED', 'REJECTED');

CREATE TABLE principal.patient_upload_document (
  id                       uuid PRIMARY KEY,
  subject_id               uuid NOT NULL REFERENCES principal.patient_profile(user_id),
  data_region              char(2) NOT NULL REFERENCES public.region_registry(code),

  -- Supabase Storage coordinates. UNIQUE gives the webhook receiver
  -- ON CONFLICT DO NOTHING idempotency against duplicate/retried delivery.
  storage_bucket           text NOT NULL,
  storage_object_path      text NOT NULL,
  content_hash             text,
  mime_type                text NOT NULL,
  byte_size                bigint,

  received_at              timestamptz NOT NULL DEFAULT now(),
  state                    patient_upload_state NOT NULL DEFAULT 'RECEIVED',
  rejected_reason          text,
  -- Populated on EXTRACTED; empty array is a valid outcome (every field
  -- flagged illegible) and is distinct from REJECTED (the document itself
  -- could not be processed at all — wrong mime type, download failure, etc).
  extracted_attribute_ids  uuid[] NOT NULL DEFAULT '{}',
  updated_at               timestamptz NOT NULL DEFAULT now(),

  UNIQUE (storage_bucket, storage_object_path)
);

CREATE INDEX idx_pud_subject ON principal.patient_upload_document (subject_id);
CREATE INDEX idx_pud_state   ON principal.patient_upload_document (state);

CREATE OR REPLACE FUNCTION principal.touch_patient_upload_document() RETURNS trigger AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_pud_touch
  BEFORE UPDATE ON principal.patient_upload_document
  FOR EACH ROW EXECUTE FUNCTION principal.touch_patient_upload_document();

ALTER TABLE principal.patient_upload_document ENABLE ROW LEVEL SECURITY;

-- Subject-scoped policy for a future patient-facing read (reasoner_role /
-- confirmation UI) — dormant until granted, same shape as p_pa_own
-- (HP-SCHEMA-001 §17) and p_prf_own (migration 018c). Not granted by this
-- migration; nothing reads this table on the patient's behalf yet.
CREATE POLICY p_pud_own ON principal.patient_upload_document
  USING (subject_id = app.current_user_id());

-- Worker-scoped policy: the ingestion job processes every subject's uploads
-- in its own region, the same shape migration 037 gave dqe_role over
-- domain.provider_submission — a background worker has no "current subject",
-- only a region.
CREATE POLICY p_pud_upload_worker_select ON principal.patient_upload_document
  FOR SELECT TO patient_upload_role
  USING (data_region = app.current_region());

CREATE POLICY p_pud_upload_worker_update ON principal.patient_upload_document
  FOR UPDATE TO patient_upload_role
  USING (data_region = app.current_region())
  WITH CHECK (data_region = app.current_region());

-- The webhook receiver INSERTs the row before any state work happens, so it
-- needs its own INSERT check — WITH CHECK only, no USING (nothing to see yet).
CREATE POLICY p_pud_upload_worker_insert ON principal.patient_upload_document
  FOR INSERT TO patient_upload_role
  WITH CHECK (data_region = app.current_region());

-- ---------------------------------------------------------------------------
-- §3  principal.record_inferred_attribute — the write verb patient_attribute
-- has never had. Same idiom as migration 039's obs.record_* functions:
-- SECURITY DEFINER, pinned search_path, EXECUTE to exactly one caller.
--
-- patient_attribute is FORCE ROW LEVEL SECURITY (migration 018c), which
-- means p_pa_own applies to this function too, because SECURITY DEFINER
-- runs as the table owner and FORCE does not exempt the owner. Per migration
-- 041's finding about fetch_attribute_envelope ("THE PROFILE READ MUST RUN
-- INSIDE runAsUser()"), THIS FUNCTION DOES NOT SET app.user_id ITSELF — the
-- caller must set it, transaction-scoped, before calling, exactly as
-- chat-pipeline's runAsUser does for reads. If the caller's app.user_id does
-- not equal p_subject, the INSERT fails with "new row violates row-level
-- security policy" rather than silently writing nothing — a loud failure,
-- not the SEC-1 "healthy silence" shape.
--
-- attribute_key_digest is NOT NULL on patient_attribute (HP-SCHEMA-001 §17:
-- "salted digests for equality lookup WITHOUT plaintext") and nothing has
-- ever populated it, so this migration sets the convention: the caller
-- supplies a plaintext attribute key (this job uses the upload document's
-- id — there is no normalised clinical-vocabulary key to hash against yet,
-- since domain.clinical_indicator cannot carry a patient value at all; see
-- §1's comment), and the digest is computed here from the subject's own
-- salt, mirroring principal.attribute_ref_digest's HMAC exactly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION principal.record_inferred_attribute(
  p_subject                uuid,
  p_kind                   patient_attribute_kind,
  p_data_region            char(2),
  p_attribute_key          text,     -- plaintext; hashed below, never stored as such
  p_payload_ciphertext     bytea,
  p_cipher_alg             text,
  p_cipher_nonce           bytea,
  p_key_id                 uuid,
  p_origin                 attribute_origin,
  p_inferred_by            text,
  p_inferred_from_session  uuid
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, principal, public AS $$
DECLARE
  v_id    uuid := gen_random_uuid();
  v_salt  bytea;
  v_digest bytea;
BEGIN
  -- c_inferred_origin_matches already enforces this at the CHECK-constraint
  -- level once the row exists; refusing here gives a named-clause error
  -- instead of a generic constraint-violation from three frames down.
  IF p_origin NOT IN ('MODEL_INFERRED', 'RULE_INFERRED') THEN
    RAISE EXCEPTION
      'HP-ESC 3.8.1/3.8.2: record_inferred_attribute only accepts MODEL_INFERRED '
      'or RULE_INFERRED origin (a model- or rule-derived attribute can never be '
      'born stated), got %', p_origin;
  END IF;

  SELECT k.salt INTO v_salt FROM principal.subject_key k WHERE k.subject_id = p_subject;
  IF v_salt IS NULL THEN
    -- Erased, or never minted. Same answer either way, per
    -- subject_key_material's own documented convention.
    RAISE EXCEPTION
      'principal.record_inferred_attribute: subject % has no live key '
      '(erased, or a key was never minted for this subject)', p_subject;
  END IF;
  v_digest := hmac(convert_to(p_attribute_key, 'UTF8'), v_salt, 'sha256');

  INSERT INTO principal.patient_attribute (
    id, subject_id, data_region, kind,
    payload_ciphertext, cipher_alg, cipher_nonce, key_id,
    attribute_key_digest, ref_digest,
    provenance, origin, inferred_by, inferred_at, inferred_from_session
  ) VALUES (
    v_id, p_subject, p_data_region, p_kind,
    p_payload_ciphertext, p_cipher_alg, p_cipher_nonce, p_key_id,
    v_digest, NULL,
    'inferred', p_origin, p_inferred_by, now(), p_inferred_from_session
  );

  RETURN v_id;
END $$;

COMMENT ON FUNCTION principal.record_inferred_attribute IS
  'Migration 050. The write half of principal.patient_attribute — nothing wrote '
  'this table before this function existed (see migration 018''s header note on '
  'chat-pipeline/src/lib/subjectKey.ts). FORCE RLS means the caller must set '
  'app.user_id = p_subject, transaction-scoped, before calling, the same '
  'convention migration 041 documents for fetch_attribute_envelope.';

-- ---------------------------------------------------------------------------
-- §4  patient_upload_role — one LOGIN role, this migration's caller.
--
-- Same shape as migration 037's dqe_role: an out-of-process Fly.io worker,
-- its own deployment, its own secret, a small connection cap because it is
-- one process doing bounded background work. NOT dqe_role and NOT granted
-- dqe_role's privileges — dqe_role "gets no reach into app_user,
-- patient_profile, patient_attribute or subject_key, and R13 rule I would
-- flag it if it did" (migration 037 §4); this role is the mirror image,
-- reaching patient_attribute/patient_upload_document and nothing evidence
-- or domain owns.
-- ---------------------------------------------------------------------------
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'patient_upload_role') THEN
    CREATE ROLE patient_upload_role NOLOGIN;
  END IF;
END $$;

DO $$
BEGIN
  EXECUTE 'ALTER ROLE patient_upload_role LOGIN CONNECTION LIMIT 3';
END $$;

DO $$
DECLARE db text := current_database();
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO patient_upload_role', db);
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
    'ALTER ROLE patient_upload_role IN DATABASE %I SET app.data_region = %L', db, region);
END $$;

-- No password. Same reason as every other role: a password in a migration
-- is a password in git. `scripts/set_role_passwords.sh` is the operator step
-- (DEPLOY.md Step 2) — add patient_upload_role to that script's list.

-- ---------------------------------------------------------------------------
-- §5  The grants that only appear once something connects as the role.
--
-- Derived from exactly what src/jobs/extractPatientUploadAttributes.ts
-- issues, and nothing else — the same discipline migration 037 §4 states for
-- dqe_role, and the same warning: USAGE ON A SCHEMA GRANTS NOTHING ON ITS
-- OBJECTS (migration 039's closing note). Listed so R13-roleci / grant_contract
-- have something to score this role against once this migration is applied.
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA principal, obs TO patient_upload_role;

-- The intake state machine: read to claim a row FOR UPDATE, update to close
-- it out. INSERT is the webhook receiver's verb (§2's p_pud_upload_worker_insert).
GRANT SELECT, INSERT, UPDATE ON principal.patient_upload_document TO patient_upload_role;

-- The two verbs onto principal this role is allowed: mint/read key material
-- (to encrypt), and write an inferred attribute (never read one back — the
-- confirmation UI's role, not this one's).
GRANT EXECUTE ON FUNCTION principal.subject_key_material(uuid) TO patient_upload_role;
GRANT EXECUTE ON FUNCTION principal.record_inferred_attribute(
  uuid, patient_attribute_kind, char, text, bytea, text, bytea, uuid,
  attribute_origin, text, uuid
) TO patient_upload_role;

-- Abstention, same pattern as dqe_role (migration 037 §4/§5): the table has
-- RLS on with zero policies otherwise, so the INSERT above is inert without this.
ALTER POLICY p_dqf_dqe_insert ON obs.data_quality_flag TO dqe_role, patient_upload_role;
GRANT INSERT ON obs.data_quality_flag TO patient_upload_role;

-- ---------------------------------------------------------------------------
-- §6  What this role does NOT get, stated rather than left to be discovered.
--
-- No USAGE on evidence, domain, safety. No SELECT on patient_profile (the
-- FK on patient_upload_document.subject_id is the existence check; the job
-- never needs the profile row itself — see the accompanying build note for
-- why this is enough). No grant on patient_attribute directly — every read
-- or write of it goes through a function, same as every other role in this
-- schema (migration 041 §3's argument applies here without change).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- §7  principal.erase_subject and principal.assert_shred_complete did not
-- know this table existed, because it didn't. Found by re-reading 018's
-- erasure function against this migration's new table rather than assuming
-- Article 17 / §2.3.4g coverage carried over — it does not, automatically,
-- for any new table that references a subject.
--
-- WHY THIS IS NOT OPTIONAL, AND NOT JUST A COVERAGE GAP. patient_upload_document
-- has NO ON DELETE clause on its subject_id FK (defaults to NO ACTION), so
-- erase_subject's existing DELETE FROM principal.patient_profile would fail
-- outright — a foreign key violation — the first time it ran against a
-- subject who had ever uploaded a document. This is not "erasure silently
-- misses a table"; it is "erasure throws", the loud-failure direction, but
-- loud at the worst possible time (a live Art.17/DPDP request) rather than
-- at migration time. Fixed by inserting the new DELETE at the same
-- dependency tier as patient_risk_flag / attribute_access_log /
-- patient_attribute_confirmation — before patient_attribute, before
-- patient_profile — mirroring 018's own ordering comment ("key material
-- first, so a failure part-way still leaves the data unreadable").
--
-- CREATE OR REPLACE, not ALTER: both functions are already written to be
-- redefined this way (018 and 039 both use CREATE OR REPLACE FUNCTION
-- throughout), so this is additive to their body, not a new object.
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
  -- NEW (migration 050): the upload intake record. Deleted before
  -- patient_profile for the FK-ordering reason stated above. The uploaded
  -- bytes in Supabase Storage itself are NOT deleted here — this function
  -- only ever reached Postgres-resident data; the Storage object is a
  -- separate erasure step this migration does not implement (recorded as an
  -- open item in the build note, not silently assumed covered).
  DELETE FROM principal.patient_upload_document     WHERE subject_id = p_subject;
  DELETE FROM obs.response_content                  WHERE subject_id = p_subject;
  DELETE FROM principal.patient_profile             WHERE user_id = p_subject;

  -- 3. obs.response_audit is NOT touched. It holds no personal data and its pseudonym
  --    can no longer be recomputed, the salt having gone with the key. §2.3.4g intact.
END $$;

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
  -- NEW (migration 050)
  UNION ALL SELECT 'patient_upload_document', count(*) FROM principal.patient_upload_document
    WHERE subject_id = p_subject
  UNION ALL SELECT 'patient_profile', count(*) FROM principal.patient_profile
    WHERE user_id = p_subject
  UNION ALL SELECT 'response_content', count(*) FROM obs.response_content
    WHERE subject_id = p_subject;
$$;

COMMIT;
