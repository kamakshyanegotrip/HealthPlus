-- HealthPlus migration: 001-003 — Reconciled baseline
-- Source: HP-SCHEMA-001 Annex A Extension §1 ("The reconciled baseline —
-- what migrations 001-003 leave on disk").
--
-- This supersedes the standalone DDL fragments in the Evidence & Safety
-- Charter's Annex A and in Phase_1.1_Migration_Pack_ADR-003 (re-designated
-- HP-MIG-001 per HP-ADR-004): it is "Annex A with the three defects
-- corrected and the Migration Pack's identity/audit/independence work
-- folded in, reordered so it actually executes." Region is ap-south-1
-- (Mumbai) per HP-ADR-003 §2.1, reaffirmed by HP-ADR-004 over the Migration
-- Pack's withdrawn eu-central-1 line — region_registry is seeded 'IN' only
-- in migration 021, not here.
--
-- Not yet run against a live database.

-- ============================================================================
-- MIGRATION 001–003 (RECONCILED BASELINE) — extension, ordering and schemas
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS vector;      -- pgvector; ADR-001 §3.3 hybrid retrieval
CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- HMAC for subject_pseudonym

CREATE SCHEMA evidence;     -- claims, sources, confidence, policy
CREATE SCHEMA domain;       -- §40's taxonomy. Holds no facts.
CREATE SCHEMA principal;    -- Layer 3: patient / clinician / provider org
CREATE SCHEMA safety;       -- red-flag rules, templates, events
CREATE SCHEMA obs;          -- audit, ai calls, DQ flags, safety metrics
CREATE SCHEMA commercial;   -- relationships, commissions, ranking inputs

-- ---------- enums (Annex A.1, plus ADR-003 §1.2's three additions) ----------
CREATE TYPE source_tier       AS ENUM ('TIER_1','TIER_2','TIER_3','TIER_4','TIER_5');
CREATE TYPE response_category AS ENUM ('INFORMATIONAL','DECISION_SUPPORT','CLINICAL_DECISION');
CREATE TYPE red_flag_severity AS ENUM ('NORMAL','MONITOR','WARNING','URGENT','CRITICAL','EMERGENCY');
CREATE TYPE disease_severity  AS ENUM ('NORMAL_AT_RISK','MILD','MODERATE','SEVERE','CRITICAL');
CREATE TYPE review_state      AS ENUM
  ('NOT_REQUIRED','PENDING','APPROVED','APPROVED_WITH_EDITS','REJECTED','ESCALATED');
CREATE TYPE claim_kind AS ENUM (
  'GENERAL_EDUCATION','CLINICAL_EFFICACY','TEST_INTERPRETATION','REFERENCE_RANGE',
  'ELIGIBILITY','COST','PROVIDER_OUTCOME','PROVIDER_CREDENTIAL','GUIDELINE',
  'LEGAL_REGULATORY','LOGISTICS','SENTIMENT',
  'MEDICATION',      -- ADR-003 §1.2: §1.5.3 dosage/interaction gate had no kind to key on
  'ACCREDITATION',   -- ADR-003 §1.2: §1.2.6 directory rule, 365d half-life vs 180d for credentials
  'EPIDEMIOLOGY'     -- ADR-003 §1.2: §1.7.1 30-day half-life, the shortest in the table
);
CREATE TYPE policy_disposition AS ENUM (
  'PERMITTED','PERMITTED_ATTRIBUTED','REQUIRES_CORROBORATION','PROHIBITED');
CREATE TYPE user_status     AS ENUM ('ACTIVE','SUSPENDED','CLOSED');
CREATE TYPE provider_status AS ENUM ('PROSPECT','ACTIVE','SUSPENDED','TERMINATED');
CREATE TYPE provider_role   AS ENUM ('ADMIN','SUBMITTER','ANALYST');
CREATE TYPE entitlement_kind AS ENUM ('PORTAL_SUBMIT','ANALYTICS_API');
CREATE TYPE commercial_relationship AS ENUM
  ('NONE','LISTING_FEE','REFERRAL_COMMISSION','PREFERRED_PARTNER','EQUITY');
-- v0.2: clinical_domain is NOT an enum. ADR-003 §5.3 flagged that the vocabulary needs a
-- clinician's sign-off on its boundaries, and §6.3 requires a version, an adopter and a
-- rationale on any change to it — none of which an enum value can carry. It is a versioned
-- reference table (safety.clinical_domain, below), seeded in migration 019. This is the
-- Migration Pack §1.4 argument applied to the one type where it is unarguable.

-- ---------- region, before anything that references it ----------
CREATE TABLE public.region_registry (
  code            char(2) PRIMARY KEY,
  legal_basis     text NOT NULL,
  primary_regime  text NOT NULL,        -- 'GDPR' | 'DPDP' | …
  active_from     date NOT NULL,
  active_to       date
);

-- ---------- Layer 3 principals (ADR-003 §3) — must precede A.3's FKs ----------
CREATE TABLE principal.app_user (
  id           uuid PRIMARY KEY,
  auth_subject text UNIQUE NOT NULL,
  data_region  char(2) NOT NULL REFERENCES public.region_registry(code),
  status       user_status NOT NULL DEFAULT 'ACTIVE',
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE principal.clinician (
  user_id              uuid PRIMARY KEY REFERENCES principal.app_user(id),
  full_name            text NOT NULL,          -- §2.3.4b: never anonymous
  primary_jurisdiction char(2) NOT NULL
);

-- ---------- the clinical-domain vocabulary (v0.2; seeded in migration 019) ----------
-- §2.3.4c needs a vocabulary with BOUNDARIES, not a flat list: ADR-003 §5.3's worked
-- failure is a reviewer approved for "cardiac" reviewing an electrophysiology response.
-- Hence parent/child, and parent_covers defaulting to false.
CREATE TABLE safety.clinical_domain (
  code            text PRIMARY KEY,
  parent_code     text REFERENCES safety.clinical_domain(code),
  name            text NOT NULL,
  -- §2.4: is this domain on the Elevated-Risk Topic List? A domain may be elevated under
  -- more than one item (paediatric oncology), which is what clinical_domain_risk_link is for.
  elevated_risk   boolean NOT NULL DEFAULT false,
  -- §2.3.4c: may a reviewer scoped to the PARENT review this domain? Defaults to false.
  -- Fail-closed: inheritance is granted deliberately, per domain, by the clinical lead.
  parent_covers   boolean NOT NULL DEFAULT false,
  -- §2.2.5b / §2.4.3: does content in this domain always require pre-publication review?
  requires_prepublication_review boolean NOT NULL DEFAULT false,
  -- §0.6 / AMB-21: PROVISIONAL until the clinical lead signs the boundary. A provisional
  -- domain is USABLE but STRICTER (see assert_reviewer_in_scope, migration 019).
  adoption_state  text NOT NULL DEFAULT 'PROVISIONAL'
                  CHECK (adoption_state IN ('PROVISIONAL','ADOPTED','RETIRED')),
  adopted_by      uuid REFERENCES principal.clinician(user_id),
  adopted_at      timestamptz,
  adopted_version text NOT NULL,
  effective_from  timestamptz NOT NULL,
  superseded_by   text REFERENCES safety.clinical_domain(code),
  CONSTRAINT c_cd_adoption_attributed CHECK (
    adoption_state <> 'ADOPTED' OR (adopted_by IS NOT NULL AND adopted_at IS NOT NULL)),
  CONSTRAINT c_cd_not_self_parent CHECK (parent_code IS DISTINCT FROM code),
  CONSTRAINT c_cd_not_self_supersede CHECK (superseded_by IS DISTINCT FROM code)
);

-- §2.4: one domain, several elevated-risk items. Paediatric oncology is item 1 and item 5.
CREATE TABLE safety.clinical_domain_risk_link (
  domain_code   text NOT NULL REFERENCES safety.clinical_domain(code),
  charter_ref   text NOT NULL,            -- '§2.4.1 item 1'
  PRIMARY KEY (domain_code, charter_ref)
);

CREATE TABLE principal.clinician_registration (
  id                  uuid PRIMARY KEY,
  clinician_id        uuid NOT NULL REFERENCES principal.clinician(user_id),
  registry            text NOT NULL,           -- 'GMC' | 'NMC-IN' | 'DHA-AE'
  registration_no     text NOT NULL,
  jurisdiction        char(2) NOT NULL,
  verified_at         timestamptz,
  verified_by         uuid REFERENCES principal.app_user(id),
  verification_method text,
  expires_at          date,
  revoked_at          timestamptz,
  UNIQUE (registry, registration_no)
);

CREATE TABLE principal.clinician_scope (        -- §2.3.4c scope of practice
  clinician_id uuid NOT NULL REFERENCES principal.clinician(user_id),
  domain       text NOT NULL REFERENCES safety.clinical_domain(code),
  jurisdiction char(2) NOT NULL,
  granted_at   timestamptz NOT NULL,
  granted_by   uuid NOT NULL REFERENCES principal.app_user(id),
  PRIMARY KEY (clinician_id, domain, jurisdiction)
);

CREATE TABLE principal.provider_org (
  id         uuid PRIMARY KEY,
  legal_name text NOT NULL,
  country    char(2) NOT NULL,
  status     provider_status NOT NULL
);

CREATE TABLE principal.provider_membership (
  user_id         uuid NOT NULL REFERENCES principal.app_user(id),
  provider_org_id uuid NOT NULL REFERENCES principal.provider_org(id),
  role            provider_role NOT NULL,
  PRIMARY KEY (user_id, provider_org_id)
);

CREATE TABLE principal.provider_entitlement (
  provider_org_id uuid NOT NULL REFERENCES principal.provider_org(id),
  entitlement     entitlement_kind NOT NULL,
  effective_from  date NOT NULL,
  effective_to    date,
  PRIMARY KEY (provider_org_id, entitlement, effective_from)
);

CREATE TABLE principal.subject_key (            -- ADR-003 §2.4 crypto-shredding
  id           uuid PRIMARY KEY,
  subject_id   uuid NOT NULL UNIQUE REFERENCES principal.app_user(id),
  salt         bytea NOT NULL,
  wrapped_dek  bytea,                           -- NULL once destroyed
  destroyed_at timestamptz
);

-- ---------- Layer 1 evidence (Annex A.2, confidence corrected to the binding) ----------
CREATE TABLE evidence.evidence_source (
  id               uuid PRIMARY KEY,
  tier             source_tier NOT NULL,
  source_type      text NOT NULL,
  publisher        text NOT NULL,
  title            text NOT NULL,
  url              text,
  doi              text,
  published_at     date,
  effective_at     date,
  retrieved_at     timestamptz NOT NULL,
  last_verified_at timestamptz NOT NULL,
  data_year        int,
  version          text,
  jurisdiction     text,
  population       text,
  evidence_level   text,
  language         text NOT NULL,
  retracted        boolean NOT NULL DEFAULT false,
  superseded_by    uuid REFERENCES evidence.evidence_source(id),
  coi_declared     boolean,
  content_hash     text NOT NULL,
  CONSTRAINT src_resolvable CHECK (url IS NOT NULL OR doi IS NOT NULL),
  CONSTRAINT src_dated      CHECK (tier = 'TIER_5' OR published_at IS NOT NULL)
);

CREATE TABLE evidence.claim (
  id                uuid PRIMARY KEY,
  kind              claim_kind NOT NULL,
  statement         text NOT NULL,
  jurisdiction      text,
  population        text,
  effective_at      date,
  expires_at        date,
  -- confidence deliberately absent: ADR-003 migration 001 moved it to claim_source
  CONSTRAINT cost_expiry  CHECK (kind <> 'COST' OR expires_at IS NOT NULL),
  CONSTRAINT pop_required CHECK (
    kind NOT IN ('REFERENCE_RANGE','PROVIDER_OUTCOME','CLINICAL_EFFICACY')
    OR population IS NOT NULL
  )
);

CREATE TABLE evidence.claim_source (
  claim_id       uuid NOT NULL REFERENCES evidence.claim(id) ON DELETE CASCADE,
  source_id      uuid NOT NULL REFERENCES evidence.evidence_source(id),
  confidence     numeric(3,2) NOT NULL,
  computed_by    text NOT NULL DEFAULT 'DQE',
  policy_version text NOT NULL,
  modifier_trail jsonb NOT NULL,
  computed_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (claim_id, source_id),
  CONSTRAINT conf_range   CHECK (confidence >= 0.00 AND confidence <= 0.99),
  CONSTRAINT conf_not_llm CHECK (computed_by <> 'MODEL')
);

CREATE TABLE evidence.claim_aggregate (
  claim_id       uuid PRIMARY KEY REFERENCES evidence.claim(id) ON DELETE CASCADE,
  agg_confidence numeric(3,2) NOT NULL,
  source_count   smallint NOT NULL,
  min_tier       smallint NOT NULL,
  method_version text NOT NULL,
  computed_at    timestamptz NOT NULL
);

CREATE OR REPLACE FUNCTION evidence.claim_requires_source() RETURNS trigger AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM evidence.claim_source cs WHERE cs.claim_id = NEW.id) THEN
    RAISE EXCEPTION 'HP-ESC 1.0.1: claim % has no evidence source', NEW.id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_claim_requires_source
  AFTER INSERT OR UPDATE ON evidence.claim
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION evidence.claim_requires_source();

-- ---------- the §1.5.3 gate (ADR-003 §1.3), fail-closed ----------
CREATE TABLE evidence.claim_policy (
  tier            source_tier        NOT NULL,
  kind            claim_kind         NOT NULL,
  category        response_category  NOT NULL,
  disposition     policy_disposition NOT NULL,
  confidence_cap  numeric(3,2),
  min_sources     smallint NOT NULL DEFAULT 1,
  marker_id       text,
  charter_clause  text NOT NULL,
  adopted_version text NOT NULL,
  adopted_by      uuid NOT NULL REFERENCES principal.app_user(id),
  effective_from  timestamptz NOT NULL,
  PRIMARY KEY (tier, kind, category, effective_from)
);

CREATE TABLE evidence.confidence_modifier (
  id               text PRIMARY KEY,
  effect_kind      text NOT NULL CHECK (effect_kind IN ('ADDITIVE','CAP','HARD_BLOCK')),
  effect_value     numeric(3,2),
  max_cumulative   numeric(3,2),
  precedence_order smallint NOT NULL,
  charter_clause   text NOT NULL,
  adopted_version  text NOT NULL,
  effective_from   timestamptz NOT NULL,
  superseded_by    text REFERENCES evidence.confidence_modifier(id),
  UNIQUE (precedence_order, effective_from)
);

CREATE TABLE evidence.tier_default (            -- Annex A.7
  tier            source_tier NOT NULL,
  default_conf    numeric(3,2) NOT NULL,
  band_floor      numeric(3,2) NOT NULL,
  band_ceiling    numeric(3,2) NOT NULL,
  adopted_version text NOT NULL,
  effective_from  timestamptz NOT NULL,
  PRIMARY KEY (tier, effective_from)
);

-- ---------- Layer 1 safety artefacts (Annex A.3, clinician FK corrected) ----------
CREATE TABLE safety.red_flag_rule (
  id          uuid NOT NULL,
  version     int NOT NULL,
  pattern     jsonb NOT NULL,
  severity    red_flag_severity NOT NULL,
  rationale   text,
  approved_by uuid NOT NULL REFERENCES principal.clinician(user_id),
  approved_at timestamptz NOT NULL,
  retired_at  timestamptz,
  PRIMARY KEY (id, version)
);

CREATE TABLE safety.safety_template (
  id           uuid NOT NULL,
  version      int NOT NULL,
  severity     red_flag_severity NOT NULL,
  jurisdiction text NOT NULL,
  language     text NOT NULL,
  body         text NOT NULL,
  slots        jsonb NOT NULL,
  approved_by  uuid NOT NULL REFERENCES principal.clinician(user_id),
  approved_at  timestamptz NOT NULL,
  PRIMARY KEY (id, version),
  UNIQUE (severity, jurisdiction, language, version)
);

-- ---------- the bridge (Annex A.4) ----------
CREATE TABLE evidence.domain_attribute (
  id          uuid PRIMARY KEY,
  entity_type text NOT NULL,
  entity_id   uuid NOT NULL,
  attribute   text NOT NULL,
  claim_id    uuid NOT NULL REFERENCES evidence.claim(id),
  UNIQUE (entity_type, entity_id, attribute, claim_id)
);

-- ---------- audit, split three ways (ADR-003 §2.3/2.4) ----------
CREATE TABLE obs.response_audit (
  id                 uuid PRIMARY KEY,
  subject_pseudonym  bytea NOT NULL,          -- HMAC(user_id, subject_key.salt)
  occurred_at        timestamptz NOT NULL,
  category           response_category NOT NULL,
  classifier_version text NOT NULL,
  severity           red_flag_severity NOT NULL,
  rule_id            uuid,
  rule_version       int,
  template_id        uuid,
  template_version   int,
  agg_confidence     numeric(3,2) NOT NULL,
  policy_version     text NOT NULL,
  model_version      text NOT NULL,
  prompt_version     text NOT NULL,
  cited_claim_ids    uuid[] NOT NULL,
  review_state       review_state NOT NULL,
  reviewer_id        uuid REFERENCES principal.clinician(user_id),
  reviewer_reg_id    uuid REFERENCES principal.clinician_registration(id),
  clinical_domain    text REFERENCES safety.clinical_domain(code),
  prev_hash          bytea,
  row_hash           bytea NOT NULL,
  FOREIGN KEY (rule_id, rule_version)         REFERENCES safety.red_flag_rule(id, version),
  FOREIGN KEY (template_id, template_version) REFERENCES safety.safety_template(id, version),
  CONSTRAINT c_clinical_needs_review CHECK (
    category <> 'CLINICAL_DECISION'
    OR (review_state IN ('APPROVED','APPROVED_WITH_EDITS')
        AND reviewer_id IS NOT NULL AND reviewer_reg_id IS NOT NULL)
  ),
  CONSTRAINT c_min_conf CHECK (
    (category = 'INFORMATIONAL'     AND agg_confidence >= 0.65) OR
    (category = 'DECISION_SUPPORT'  AND agg_confidence >= 0.70) OR
    (category = 'CLINICAL_DECISION' AND agg_confidence >= 0.85)
  ),
  CONSTRAINT c_urgent_template_only CHECK (
    severity IN ('NORMAL','MONITOR','WARNING') OR template_id IS NOT NULL
  ),
  CONSTRAINT c_no_clinical_when_flagged CHECK (
    category <> 'CLINICAL_DECISION' OR severity IN ('NORMAL','MONITOR')
  ),
  CONSTRAINT c_emergency_not_gated CHECK (
    severity NOT IN ('CRITICAL','EMERGENCY') OR review_state <> 'PENDING'
  ),
  CONSTRAINT c_category_c_disabled_v1 CHECK (category <> 'CLINICAL_DECISION')
);

CREATE TABLE obs.response_content (             -- IS personal data. Encrypted per subject.
  audit_id    uuid PRIMARY KEY REFERENCES obs.response_audit(id),
  subject_id  uuid NOT NULL REFERENCES principal.app_user(id),
  data_region char(2) NOT NULL REFERENCES public.region_registry(code),
  ciphertext  bytea NOT NULL,
  key_id      uuid NOT NULL REFERENCES principal.subject_key(id)
);

CREATE TABLE commercial.provider_relationship (  -- §1.4.5
  provider_org_id uuid NOT NULL REFERENCES principal.provider_org(id),
  relationship    commercial_relationship NOT NULL,
  disclosure_id   text NOT NULL,
  effective_from  date NOT NULL,
  effective_to    date,
  PRIMARY KEY (provider_org_id, relationship, effective_from)
);
