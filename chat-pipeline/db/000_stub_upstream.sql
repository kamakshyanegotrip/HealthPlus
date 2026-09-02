-- ============================================================================
-- STUB UPSTREAM SCHEMA — for testing THIS pipeline's queries only.
--
-- This is NOT a substitute for the real committed migrations. It exists for
-- the same reason HP-SEC-001 built one ("a throwaway stub Supabase
-- environment... plus a stub upstream schema matching the committed DDL,
-- then ran the actual policy script" — HP-SEC-001 §5): reading SQL does not
-- catch bugs that executing it does. Every table/function below is either
-- (a) copied as closely as possible from a snippet actually quoted in a
-- committed project doc (marked SOURCE: <doc>), or (b) a minimal invented
-- stand-in for something referenced but not yet committed (marked STAND-IN
-- — reconcile with the real migration when it lands, same caveat HP-SEC-001
-- §2 already put on its own stand-ins).
--
-- Run before db/010_chat_pipeline_support.sql.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), digest()
CREATE EXTENSION IF NOT EXISTS vector;     -- pgvector, HP-ADR-001 §3.3

-- ---- enums (SOURCE: HP-SCHEMA-001 Annex A Extension, Charter v1.0 Annex A) -
CREATE TYPE response_category AS ENUM ('INFORMATIONAL','DECISION_SUPPORT','CLINICAL_DECISION');
CREATE TYPE red_flag_severity AS ENUM ('NORMAL','MONITOR','WARNING','URGENT','CRITICAL','EMERGENCY');
CREATE TYPE source_tier AS ENUM ('TIER_1','TIER_2','TIER_3','TIER_4','TIER_5');
CREATE TYPE claim_kind AS ENUM (
  'GENERAL_EDUCATION','COST','PROVIDER_CREDENTIAL','ACCREDITATION','LEGAL_REGULATORY',
  'GUIDELINE','MEDICATION','EPIDEMIOLOGY','TEST_INTERPRETATION','PROVIDER_OUTCOME'
);
CREATE TYPE policy_disposition AS ENUM ('PERMITTED','PERMITTED_ATTRIBUTED','REQUIRES_CORROBORATION','PROHIBITED');
CREATE TYPE ai_call_purpose AS ENUM ('CATEGORY_CLASSIFY','RED_FLAG_PROPOSE','COMPOSE','EXTRACT','RERANK','TRANSLATE','EMBED');
CREATE TYPE ai_call_outcome AS ENUM ('OK','BLOCKED','ERROR','TIMEOUT','REFUSED_BY_POLICY');
CREATE TYPE audit_event_kind AS ENUM (
  'RESPONSE_DRAFTED','CATEGORY_ASSIGNED','SEVERITY_ASSIGNED','VALIDATOR_BLOCK',
  'TEMPLATE_RENDERED','REVIEW_REQUESTED','REVIEW_DECIDED','PUBLISHED','FLAG_RAISED'
);
CREATE TYPE review_state AS ENUM ('PENDING','APPROVED','APPROVED_WITH_EDITS','REJECTED','NOT_REQUIRED');

CREATE TABLE public.region_registry (code char(2) PRIMARY KEY, name text NOT NULL);
INSERT INTO public.region_registry VALUES ('IN', 'India');

CREATE TABLE app_user (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), data_region char(2) NOT NULL REFERENCES public.region_registry(code));

-- ---- evidence schema (SOURCE: Phase_1.1_Migration_Pack_ADR-003 §1.3, HP-SCHEMA-001) --
CREATE SCHEMA evidence;

CREATE TABLE evidence.evidence_source (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tier          source_tier NOT NULL,
  retracted     boolean NOT NULL DEFAULT false,
  superseded_by uuid,
  last_verified_at timestamptz
);

CREATE TABLE evidence.claim (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind           claim_kind NOT NULL,
  domain_table   text NOT NULL,       -- which domain.* table this claim supports (STAND-IN name)
  text           text NOT NULL,
  jurisdiction   text,
  population     text,
  search_tsv     tsvector,
  embedding      vector(384)          -- HP-ADR-001 §3.3: 384 dims (bge-small-en-v1.5) per ADR-002/HP-SCHEMA-001 §11 "confirmed at 384 dimensions"
);
CREATE INDEX idx_claim_fts ON evidence.claim USING GIN (search_tsv);
CREATE INDEX idx_claim_vec ON evidence.claim USING hnsw (embedding vector_cosine_ops);

CREATE TABLE evidence.claim_source (
  claim_id   uuid NOT NULL REFERENCES evidence.claim(id),
  source_id  uuid NOT NULL REFERENCES evidence.evidence_source(id),
  confidence numeric(3,2) NOT NULL,   -- §1.0.5: computed by the DQE, read-only here
  hard_block text,
  PRIMARY KEY (claim_id, source_id)
);

-- SOURCE: HP-SCHEMA-001 Annex A Extension (quoted verbatim in project docs)
CREATE TABLE evidence.claim_policy (
  tier             source_tier        NOT NULL,
  kind             claim_kind         NOT NULL,
  category         response_category  NOT NULL,
  disposition      policy_disposition NOT NULL,
  confidence_cap   numeric(3,2),
  min_sources      smallint NOT NULL DEFAULT 1,
  marker_id        text,
  charter_clause   text NOT NULL,
  adopted_version  text NOT NULL,
  adopted_by       uuid NOT NULL,
  effective_from   timestamptz NOT NULL,
  PRIMARY KEY (tier, kind, category, effective_from)
);

CREATE SCHEMA safety;

-- SOURCE: HP-SCHEMA-001 Annex A Extension (quoted verbatim)
CREATE TABLE safety.response_category_state (
  category         response_category PRIMARY KEY,
  enabled          boolean NOT NULL,
  enabled_by       uuid,
  enabled_at       timestamptz,
  board_minute_ref text,
  charter_clause   text NOT NULL,
  adopted_version  text NOT NULL,
  CONSTRAINT c_enablement_attributed CHECK (
    enabled = false OR category <> 'CLINICAL_DECISION'
    OR (enabled_by IS NOT NULL AND enabled_at IS NOT NULL AND board_minute_ref IS NOT NULL))
);
INSERT INTO safety.response_category_state (category, enabled, charter_clause, adopted_version) VALUES
  ('INFORMATIONAL',     true,  'HP-ESC 2.5 (v1 availability: On)',  'HP-SCHEMA-001 v0.3'),
  ('DECISION_SUPPORT',  true,  'HP-ESC 2.5 (v1 availability: On)',  'HP-SCHEMA-001 v0.3'),
  ('CLINICAL_DECISION', false, 'HP-ESC 2.3.2 (out of scope for v1)','HP-SCHEMA-001 v0.3');

-- SOURCE: HP-SCHEMA-001 Annex A Extension (quoted verbatim, fail-closed twice)
CREATE OR REPLACE FUNCTION evidence.policy_for(
  p_tier source_tier, p_kind claim_kind, p_cat response_category
) RETURNS evidence.claim_policy LANGUAGE plpgsql STABLE AS $$
DECLARE r evidence.claim_policy; cat_on boolean;
BEGIN
  SELECT s.enabled INTO cat_on FROM safety.response_category_state s WHERE s.category = p_cat;
  IF NOT COALESCE(cat_on, false) THEN
    r.tier := p_tier; r.kind := p_kind; r.category := p_cat;
    r.disposition := 'PROHIBITED'; r.min_sources := 1;
    r.charter_clause := 'HP-ESC 2.3.2 category disabled';
    RETURN r;
  END IF;
  SELECT * INTO r FROM evidence.claim_policy
   WHERE tier = p_tier AND kind = p_kind AND category = p_cat AND effective_from <= now()
   ORDER BY effective_from DESC LIMIT 1;
  IF NOT FOUND THEN
    r.tier := p_tier; r.kind := p_kind; r.category := p_cat;
    r.disposition := 'PROHIBITED'; r.min_sources := 1;
    r.charter_clause := 'HP-ESC 3.0.3 default-deny';
  END IF;
  RETURN r;
END $$;

-- ---- obs schema (SOURCE: HP-SCHEMA-001 Annex A Extension migration 005, quoted verbatim) --
CREATE SCHEMA obs;

CREATE TABLE obs.response_audit (id uuid PRIMARY KEY); -- forward-declared; real shape below

CREATE TABLE obs.ai_call (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  audit_id           uuid,
  occurred_at        timestamptz NOT NULL,
  purpose            ai_call_purpose NOT NULL,
  provider           text NOT NULL,
  model_version      text NOT NULL,
  prompt_version     text NOT NULL,
  retrieval_version  text,
  input_tokens       int,
  output_tokens      int,
  latency_ms         int,
  outcome            ai_call_outcome NOT NULL,
  retrieved_claim_ids uuid[] NOT NULL DEFAULT '{}',
  proposed_severity  red_flag_severity,
  applied_severity   red_flag_severity,
  data_region        char(2) NOT NULL REFERENCES public.region_registry(code),
  CONSTRAINT c_model_may_not_lower CHECK (
    proposed_severity IS NULL OR applied_severity IS NULL
    OR applied_severity >= proposed_severity
    OR purpose <> 'RED_FLAG_PROPOSE'
  )
);
CREATE INDEX idx_ai_call_audit ON obs.ai_call (audit_id);
CREATE INDEX idx_ai_call_time  ON obs.ai_call (occurred_at);

CREATE TABLE obs.fabrication_block (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_at            timestamptz NOT NULL,
  ai_call_id             uuid,
  audit_id               uuid,
  prohibition_class      text NOT NULL,
  claim_kind             claim_kind,
  tier                   source_tier,
  category               response_category NOT NULL,
  policy_tier            source_tier,
  policy_kind            claim_kind,
  policy_category        response_category,
  policy_effective_from  timestamptz,
  query_hash             bytea NOT NULL,
  retrieved_source_state jsonb NOT NULL,
  message_template_id    text,
  data_region            char(2) NOT NULL REFERENCES public.region_registry(code),
  CONSTRAINT c_class_format CHECK (prohibition_class ~ '^[13]\.[0-9]+(\.[0-9]+)?$')
);
CREATE INDEX idx_block_class_time ON obs.fabrication_block (prohibition_class, occurred_at);

DROP TABLE obs.response_audit;

-- ---- immutable audit trace (SOURCE: HP-RB-001 §3-§5, quoted verbatim) -----
CREATE TABLE response_audit_event (
  seq         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  audit_id    uuid        NOT NULL,
  kind        audit_event_kind NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  actor       text        NOT NULL,
  subject_ref uuid,
  payload     jsonb       NOT NULL,
  prev_hash   bytea       NOT NULL,
  row_hash    bytea       NOT NULL
);
ALTER TABLE response_audit_event ADD CONSTRAINT payload_no_pii CHECK (
  NOT (payload ?| ARRAY['user_text','message','name','email','phone','dob',
                        'symptoms','conditions','health_flags','free_text'])
);

CREATE OR REPLACE FUNCTION audit_event_chain() RETURNS trigger AS $$
DECLARE
  last_hash bytea;
  canonical text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('response_audit_event_chain'));
  SELECT row_hash INTO last_hash FROM response_audit_event ORDER BY seq DESC LIMIT 1;
  IF last_hash IS NULL THEN
    last_hash := decode(repeat('00', 32), 'hex');
  END IF;
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

CREATE OR REPLACE FUNCTION forbid_mutation() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'HP-ESC A.6: % on % is forbidden', TG_OP, TG_TABLE_NAME;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_event_immutable
  BEFORE UPDATE OR DELETE ON response_audit_event
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- ---- response_audit projection (SOURCE: merges Charter Annex A.5's CHECK
-- constraints with Phase_1.1_Migration_Pack_ADR-003 §2.3's pseudonymous
-- LAYER 1 column set, per HP-RB-001 §1's instruction to treat A.5 as the
-- projection's constraint set, not its column set) ----------------------
CREATE TABLE response_audit (
  id                  uuid PRIMARY KEY,
  subject_pseudonym   bytea NOT NULL,
  occurred_at         timestamptz NOT NULL,
  category            response_category NOT NULL,
  classifier_version  text NOT NULL,
  severity            red_flag_severity NOT NULL,
  template_id         text,
  agg_confidence      numeric(3,2) NOT NULL,
  policy_version      text NOT NULL,
  model_version       text NOT NULL,
  prompt_version      text NOT NULL,
  cited_claim_ids     uuid[] NOT NULL DEFAULT '{}',
  review_state        review_state NOT NULL,
  clinical_domain      text,
  CONSTRAINT c_min_conf CHECK (
    (category = 'INFORMATIONAL'     AND agg_confidence >= 0.65) OR
    (category = 'DECISION_SUPPORT'  AND agg_confidence >= 0.70) OR
    (category = 'CLINICAL_DECISION' AND agg_confidence >= 0.85) OR
    agg_confidence = 1.00  -- static template / static refusal paths, not model-scored
  ),
  CONSTRAINT c_category_c_disabled_v1 CHECK (category <> 'CLINICAL_DECISION')
);

CREATE TABLE response_content (
  audit_id       uuid PRIMARY KEY REFERENCES response_audit(id),
  subject_id     uuid NOT NULL REFERENCES app_user(id),
  data_region    char(2) NOT NULL,
  ciphertext     bytea NOT NULL,
  key_id         uuid
);

-- ---- STAND-IN domain tables (HP-SEC-001 §2 precedent: "minimal, clearly-
-- labelled stand-in tables ... reconcile column names with the real
-- migration when it lands") ------------------------------------------------
CREATE TABLE patient_profile (
  user_id      uuid PRIMARY KEY REFERENCES app_user(id),
  data_region  char(2) NOT NULL,
  age_band     text,
  preferences  jsonb,
  is_minor     boolean NOT NULL DEFAULT false
);

CREATE TABLE patient_attribute (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES app_user(id),
  kind        text NOT NULL,
  label       text NOT NULL,
  provenance  text NOT NULL CHECK (provenance IN ('stated','inferred'))
);

CREATE TABLE hospital_profile (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL, status text NOT NULL DEFAULT 'PUBLISHED');
CREATE TABLE hospital_cost (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), hospital_id uuid REFERENCES hospital_profile(id));

CREATE SCHEMA domain;
CREATE TABLE domain.guideline (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
CREATE TABLE domain.regulation (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
CREATE TABLE domain.nutrition_pattern (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
CREATE TABLE domain.exercise_guidance (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
CREATE TABLE domain.lifestyle_screening_tool (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
CREATE TABLE domain.clinical_metric_reference (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
CREATE TABLE domain.environment_reference (id uuid PRIMARY KEY DEFAULT gen_random_uuid());

-- ---- application role grants (SOURCE: HP-RB-001 §5, hp_app path only) -----
REVOKE ALL ON response_audit_event FROM PUBLIC;
GRANT INSERT, SELECT ON response_audit_event TO hp_app;
GRANT SELECT ON response_audit_event TO hp_reader;
GRANT USAGE ON SCHEMA obs, evidence, safety, domain, public TO hp_app;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA obs TO hp_app;
GRANT SELECT ON ALL TABLES IN SCHEMA evidence, safety, domain TO hp_app;
GRANT SELECT, INSERT ON response_audit, response_content, patient_profile, patient_attribute,
  hospital_profile, hospital_cost, app_user, public.region_registry TO hp_app;
GRANT EXECUTE ON FUNCTION evidence.policy_for TO hp_app;
