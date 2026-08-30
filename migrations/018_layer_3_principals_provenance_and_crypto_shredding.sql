-- HealthPlus migration: 17. Migration 018 — Layer 3 principals, provenance, and crypto-shredding
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 018 — patient principal, §3.8.2 provenance, §2.3.4g/Art.17 erasure
-- ============================================================================
CREATE TYPE provenance_status AS ENUM ('stated','inferred');

CREATE TYPE patient_attribute_kind AS ENUM (
  'HISTORY','MEDICATION','ALLERGY','DIAGNOSIS','PRIOR_PROCEDURE',
  'DEMOGRAPHIC','PREFERENCE','TRAVEL_CONTEXT'
);

-- §4.6.2: profile flags are set only from user-stated or provider-supplied data,
-- never inferred. The origin is therefore a first-class column, not a comment.
CREATE TYPE attribute_origin AS ENUM (
  'USER_STATED',        -- the person typed or selected it
  'PROVIDER_SUPPLIED',  -- came from a provider_submission
  'MODEL_INFERRED',     -- extracted from conversation; provenance MUST be 'inferred'
  'RULE_INFERRED'       -- derived by a deterministic rule; still 'inferred'
);

-- ---- v0.2: the salt must die with the key, or the pseudonym stays re-identifiable ----
-- ADR-003 §2.4 names this as "the subtlety that makes or breaks this" and then leaves
-- salt NOT NULL, which means destroying wrapped_dek does not break the linkage. Fixed.
ALTER TABLE principal.subject_key
  ALTER COLUMN salt DROP NOT NULL,
  -- Both states written out, rather than an equality between two expressions. The
  -- equality form permits a destroyed key to have its salt put BACK (false = false),
  -- which would make every pseudonym recomputable again. Found by test T30.
  ADD CONSTRAINT c_salt_dies_with_key CHECK (
    (destroyed_at IS NULL     AND salt IS NOT NULL AND wrapped_dek IS NOT NULL) OR
    (destroyed_at IS NOT NULL AND salt IS NULL     AND wrapped_dek IS NULL)
  );

-- Destruction is one-way. A CHECK constrains a row's shape, not its history, so
-- un-destroying a key needs a trigger. §2.3.4g and Article 17 both depend on this.
CREATE OR REPLACE FUNCTION principal.assert_key_destruction_final() RETURNS trigger AS $$
BEGIN
  IF OLD.destroyed_at IS NOT NULL AND NEW.destroyed_at IS NULL THEN
    RAISE EXCEPTION 'HP-ESC 2.3.4g: subject key % is destroyed; destruction is final', OLD.id;
  END IF;
  IF OLD.destroyed_at IS NOT NULL
     AND (NEW.salt IS NOT NULL OR NEW.wrapped_dek IS NOT NULL) THEN
    RAISE EXCEPTION 'HP-ESC 2.3.4g: key material may not be restored to destroyed key %', OLD.id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_key_destruction_final
  BEFORE UPDATE ON principal.subject_key
  FOR EACH ROW EXECUTE FUNCTION principal.assert_key_destruction_final();

CREATE TABLE principal.patient_profile (
  user_id      uuid PRIMARY KEY REFERENCES principal.app_user(id),
  data_region  char(2) NOT NULL REFERENCES public.region_registry(code),
  created_at   timestamptz NOT NULL DEFAULT now(),
  -- §4.5.1b: emergency routing uses the person's CURRENT physical location, determined
  -- from stated location, not account address. Stored as a stated attribute, not here.
  key_id       uuid NOT NULL REFERENCES principal.subject_key(id)
);

CREATE TABLE principal.patient_attribute (
  id             uuid PRIMARY KEY,
  subject_id     uuid NOT NULL REFERENCES principal.patient_profile(user_id),
  data_region    char(2) NOT NULL REFERENCES public.region_registry(code),   -- E-4
  -- coarse and deliberately uninformative. Deleted on erasure with the rest of the row.
  kind           patient_attribute_kind NOT NULL,

  -- ---- the envelope: value, attribute_key and any taxonomy reference, all inside ----
  payload_ciphertext bytea NOT NULL,
  cipher_alg     text NOT NULL,          -- 'AES-256-GCM'
  cipher_nonce   bytea NOT NULL,
  key_id         uuid NOT NULL REFERENCES principal.subject_key(id),
  -- salted digests for equality lookup WITHOUT plaintext. HMAC under subject_key.salt,
  -- so they stop matching anything the moment the salt is destroyed.
  attribute_key_digest bytea NOT NULL,
  ref_digest     bytea,                  -- HMAC of (entity_type || entity_id), when it refers

  -- ---- §3.8.2 provenance ----
  provenance     provenance_status NOT NULL,
  origin         attribute_origin NOT NULL,
  inferred_by    text,                   -- model+prompt version, or rule id
  inferred_at    timestamptz,
  inferred_from_session uuid,
  confirmed_at   timestamptz,
  confirmed_session_id  uuid,
  confirmation_id uuid,                  -- FK added after the confirmation table exists

  recorded_at    timestamptz NOT NULL DEFAULT now(),
  superseded_at  timestamptz,            -- the person changed or withdrew it
  active         boolean GENERATED ALWAYS AS (superseded_at IS NULL) STORED,

  -- An inferred row must name what inferred it. Without this, "inferred" is decorative.
  CONSTRAINT c_inferred_has_inference_record CHECK (
    provenance <> 'inferred'
    OR (inferred_by IS NOT NULL AND inferred_at IS NOT NULL AND inferred_from_session IS NOT NULL)
  ),
  -- A model- or rule-derived attribute can never be born 'stated'. §3.8.1/§3.8.2.
  CONSTRAINT c_inferred_origin_matches CHECK (
    origin NOT IN ('MODEL_INFERRED','RULE_INFERRED') OR provenance = 'inferred'
      OR confirmation_id IS NOT NULL
  ),
  -- An inferred row carries no confirmation. Confirmation IS the promotion.
  CONSTRAINT c_inferred_unconfirmed CHECK (
    provenance <> 'inferred'
    OR (confirmed_at IS NULL AND confirmed_session_id IS NULL AND confirmation_id IS NULL)
  ),
  -- A row that was promoted must carry the full confirmation triple. §3.8.2 + your brief.
  CONSTRAINT c_promotion_fully_logged CHECK (
    confirmation_id IS NULL
    OR (provenance = 'stated' AND confirmed_at IS NOT NULL AND confirmed_session_id IS NOT NULL)
  )
);
CREATE INDEX idx_pa_subject ON principal.patient_attribute (subject_id, kind) WHERE active;
CREATE INDEX idx_pa_refdigest ON principal.patient_attribute (ref_digest) WHERE active;

-- Append-only. The confirmation is evidence that a person was asked and answered.
CREATE TABLE principal.patient_attribute_confirmation (
  id               uuid PRIMARY KEY,
  attribute_id     uuid NOT NULL REFERENCES principal.patient_attribute(id),
  subject_id       uuid NOT NULL REFERENCES principal.patient_profile(user_id),
  confirmed_by     uuid NOT NULL REFERENCES principal.app_user(id),
  session_id       uuid NOT NULL,          -- the confirming session, per your brief
  confirmed_at     timestamptz NOT NULL DEFAULT now(),
  action           text NOT NULL CHECK (action IN ('CONFIRMED','CORRECTED','REJECTED')),
  -- §3.8.3: what the person was actually shown, hashed. A confirmation whose prompt
  -- text cannot be reconstructed is not evidence of informed confirmation.
  prompt_text_hash bytea NOT NULL,
  prompt_version   text NOT NULL,
  ui_surface       text NOT NULL,          -- 'chat_inline'|'profile_review'|'onboarding'
  data_region      char(2) NOT NULL REFERENCES public.region_registry(code),
  UNIQUE (attribute_id, session_id, confirmed_at)
);

ALTER TABLE principal.patient_attribute
  ADD CONSTRAINT fk_pa_confirmation
  FOREIGN KEY (confirmation_id) REFERENCES principal.patient_attribute_confirmation(id);

-- ---- the promotion gate ----
-- §3.8.2: an inferred value must never silently promote. This refuses the UPDATE
-- outright unless a confirmation row for THIS attribute exists, and it refuses every
-- other provenance mutation as well, including the reverse direction.
CREATE OR REPLACE FUNCTION principal.assert_provenance_promotion() RETURNS trigger AS $$
BEGIN
  IF NEW.provenance IS DISTINCT FROM OLD.provenance THEN
    IF NOT (OLD.provenance = 'inferred' AND NEW.provenance = 'stated') THEN
      RAISE EXCEPTION
        'HP-ESC 3.8.2: provenance may only move inferred -> stated (attribute %, % -> %)',
        NEW.id, OLD.provenance, NEW.provenance;
    END IF;
    IF NEW.confirmation_id IS NULL THEN
      RAISE EXCEPTION
        'HP-ESC 3.8.2: attribute % cannot promote to stated without a confirmation record',
        NEW.id;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM principal.patient_attribute_confirmation c
       WHERE c.id = NEW.confirmation_id
         AND c.attribute_id = NEW.id
         AND c.action = 'CONFIRMED'
         AND c.session_id = NEW.confirmed_session_id
         AND c.confirmed_at = NEW.confirmed_at
    ) THEN
      RAISE EXCEPTION
        'HP-ESC 3.8.2: confirmation % does not match attribute % / session % / timestamp',
        NEW.confirmation_id, NEW.id, NEW.confirmed_session_id;
    END IF;
  -- §3.8.2 second limb: a stated row may not be silently rewritten either. Changing the
  -- value means superseding the row, not editing it.
  ELSIF NEW.payload_ciphertext IS DISTINCT FROM OLD.payload_ciphertext
        AND OLD.superseded_at IS NULL AND NEW.superseded_at IS NULL THEN
    RAISE EXCEPTION
      'HP-ESC 3.8.1: attribute % value may not be edited in place; supersede it', NEW.id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_provenance_promotion
  BEFORE UPDATE ON principal.patient_attribute
  FOR EACH ROW EXECUTE FUNCTION principal.assert_provenance_promotion();

-- §4.6.1: the high-risk profile flags that raise the floor severity by one level.
-- §4.6.2: NEVER inferred. Enforced against the attribute's provenance, not by convention.
CREATE TABLE principal.patient_risk_flag (
  id            uuid PRIMARY KEY,
  subject_id    uuid NOT NULL REFERENCES principal.patient_profile(user_id),
  flag_key      text NOT NULL CHECK (flag_key IN (
                  'AGE_UNDER_18','AGE_75_PLUS','PREGNANCY','IMMUNOSUPPRESSION',
                  'ACTIVE_MALIGNANCY','ANTICOAGULATION','TRANSPLANT_RECIPIENT',
                  'POST_OP_UNDER_30D','DIALYSIS','ANAPHYLAXIS_HISTORY')),
  source_attribute_id uuid NOT NULL REFERENCES principal.patient_attribute(id),
  set_at        timestamptz NOT NULL DEFAULT now(),
  cleared_at    timestamptz,
  data_region   char(2) NOT NULL REFERENCES public.region_registry(code),
  UNIQUE (subject_id, flag_key, set_at)
);

CREATE OR REPLACE FUNCTION principal.assert_risk_flag_stated() RETURNS trigger AS $$
DECLARE p provenance_status;
BEGIN
  SELECT a.provenance INTO p
    FROM principal.patient_attribute a WHERE a.id = NEW.source_attribute_id;
  IF p <> 'stated' THEN
    RAISE EXCEPTION
      'HP-ESC 4.6.2: risk flag % may not be set from an inferred attribute (%)',
      NEW.flag_key, NEW.source_attribute_id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_risk_flag_stated_only
  BEFORE INSERT OR UPDATE ON principal.patient_risk_flag
  FOR EACH ROW EXECUTE FUNCTION principal.assert_risk_flag_stated();

-- ---- every read of an envelope is logged. §2.3.4d provenance, and the audit trail
-- ---- that makes "who decrypted what" answerable after an incident.
CREATE TABLE principal.attribute_access_log (
  id            uuid PRIMARY KEY,
  attribute_id  uuid NOT NULL REFERENCES principal.patient_attribute(id),
  subject_id    uuid NOT NULL,
  accessed_at   timestamptz NOT NULL DEFAULT now(),
  accessor_role text NOT NULL,
  accessor_id   uuid,
  purpose       text NOT NULL CHECK (purpose IN
                  ('REASONING','CONFIRMATION_UI','CLINICAL_REVIEW','SUBJECT_ACCESS','EXPORT')),
  audit_id      uuid REFERENCES obs.response_audit(id),
  data_region   char(2) NOT NULL REFERENCES public.region_registry(code)
);

-- ============================================================================
-- MIGRATION 018b — the gated read path, erasure, and shred verification
-- ============================================================================

-- The ONLY supported way to read an envelope. SECURITY DEFINER so the caller never
-- touches the base table. Returns nothing once the key is destroyed.
CREATE OR REPLACE FUNCTION principal.fetch_attribute_envelope(
  p_subject uuid, p_purpose text, p_audit_id uuid DEFAULT NULL,
  p_include_inferred boolean DEFAULT false
) RETURNS TABLE (
  attribute_id uuid, kind patient_attribute_kind, provenance provenance_status,
  payload_ciphertext bytea, cipher_alg text, cipher_nonce bytea, key_id uuid
) LANGUAGE plpgsql SECURITY DEFINER SET search_path = principal, public AS $$
DECLARE live boolean;
BEGIN
  -- crypto-shredding gate: a destroyed key ends all access, for every caller, forever.
  SELECT (k.wrapped_dek IS NOT NULL AND k.destroyed_at IS NULL AND k.salt IS NOT NULL)
    INTO live
    FROM principal.subject_key k WHERE k.subject_id = p_subject;
  IF NOT COALESCE(live, false) THEN
    RETURN;                       -- erased, or never existed. Same answer either way.
  END IF;

  -- §3.8.2: inferred rows are reachable only by the confirmation path, by name.
  IF p_include_inferred AND p_purpose <> 'CONFIRMATION_UI' THEN
    RAISE EXCEPTION
      'HP-ESC 3.8.2: inferred attributes may only be read for CONFIRMATION_UI, not %',
      p_purpose;
  END IF;

  INSERT INTO principal.attribute_access_log
    (id, attribute_id, subject_id, accessor_role, accessor_id, purpose, audit_id, data_region)
  SELECT gen_random_uuid(), a.id, a.subject_id, current_user, app.current_user_id(),
         p_purpose, p_audit_id, a.data_region
    FROM principal.patient_attribute a
   WHERE a.subject_id = p_subject AND a.active
     AND (a.provenance = 'stated' OR p_include_inferred);

  RETURN QUERY
  SELECT a.id, a.kind, a.provenance, a.payload_ciphertext, a.cipher_alg,
         a.cipher_nonce, a.key_id
    FROM principal.patient_attribute a
   WHERE a.subject_id = p_subject AND a.active
     AND (a.provenance = 'stated' OR p_include_inferred);
END $$;

-- salted equality lookup without plaintext. Dies with the salt.
CREATE OR REPLACE FUNCTION principal.attribute_ref_digest(p_subject uuid, p_ref text)
RETURNS bytea LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = principal, public AS $$
DECLARE s bytea;
BEGIN
  SELECT k.salt INTO s FROM principal.subject_key k WHERE k.subject_id = p_subject;
  IF s IS NULL THEN RETURN NULL; END IF;      -- erased: nothing can be matched again
  -- pgcrypto's hmac is (bytea, bytea, text); p_ref must be encoded, not cast.
  RETURN hmac(convert_to(p_ref, 'UTF8'), s, 'sha256');
END $$;

-- ---- erasure: destroy the key material, then delete what DELETE can reach ----
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
  DELETE FROM obs.response_content                  WHERE subject_id = p_subject;
  DELETE FROM principal.patient_profile             WHERE user_id = p_subject;

  -- 3. obs.response_audit is NOT touched. It holds no personal data and its pseudonym
  --    can no longer be recomputed, the salt having gone with the key. §2.3.4g intact.
END $$;

-- The testable guarantee. Returns one row per surviving plaintext linkage; an erased
-- subject must return zero. Run it in CI against a fixture, and after every real erasure.
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
  UNION ALL SELECT 'patient_profile', count(*) FROM principal.patient_profile
    WHERE user_id = p_subject
  UNION ALL SELECT 'response_content', count(*) FROM obs.response_content
    WHERE subject_id = p_subject;
$$;

-- ============================================================================
-- MIGRATION 018c — role separation for §3.8.2 and §2.3.4g
-- ============================================================================
CREATE ROLE reasoner_role        NOLOGIN;   -- Clinical Reasoning + Recommendation Synthesis
CREATE ROLE confirmation_ui_role NOLOGIN;
CREATE ROLE erasure_role         NOLOGIN;   -- runs the DPDP/Art.17 workflow, nothing else

GRANT USAGE ON SCHEMA principal, evidence, domain, app TO reasoner_role;
GRANT USAGE ON SCHEMA principal, app TO confirmation_ui_role;
GRANT USAGE ON SCHEMA principal TO erasure_role;

-- The reasoner cannot see the base table or the views. Not "must filter them" — cannot
-- see them. Its only path is the gated function, and every call it makes is logged.
REVOKE ALL ON principal.patient_attribute FROM reasoner_role;
GRANT EXECUTE ON FUNCTION principal.fetch_attribute_envelope(uuid,text,uuid,boolean)
  TO reasoner_role, confirmation_ui_role;
GRANT EXECUTE ON FUNCTION principal.attribute_ref_digest(uuid,text) TO reasoner_role;

-- The confirmation UI is the only caller permitted to pass p_include_inferred, and the
-- only thing that may write a confirmation or perform the promotion UPDATE.
GRANT INSERT ON principal.patient_attribute_confirmation TO confirmation_ui_role;
GRANT UPDATE (provenance, confirmed_at, confirmed_session_id, confirmation_id)
  ON principal.patient_attribute TO confirmation_ui_role;

-- §2.3.4g-equivalent: the record of being asked is not rewritable, and the access log
-- is not editable by anything that reads through it.
REVOKE UPDATE, DELETE ON principal.patient_attribute_confirmation
  FROM confirmation_ui_role, reasoner_role;
REVOKE ALL ON principal.attribute_access_log FROM reasoner_role, confirmation_ui_role;

GRANT EXECUTE ON FUNCTION principal.erase_subject(uuid)         TO erasure_role;
GRANT EXECUTE ON FUNCTION principal.assert_shred_complete(uuid) TO erasure_role;

ALTER TABLE principal.patient_profile      ENABLE ROW LEVEL SECURITY;
ALTER TABLE principal.patient_attribute    ENABLE ROW LEVEL SECURITY;
ALTER TABLE principal.patient_attribute    FORCE ROW LEVEL SECURITY;
ALTER TABLE principal.patient_attribute_confirmation ENABLE ROW LEVEL SECURITY;
ALTER TABLE principal.patient_risk_flag    ENABLE ROW LEVEL SECURITY;
ALTER TABLE principal.attribute_access_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_pa_own ON principal.patient_attribute
  USING (subject_id = app.current_user_id());
CREATE POLICY p_prf_own ON principal.patient_risk_flag
  USING (subject_id = app.current_user_id());
