-- HealthPlus migration: 5. Migration 006 — §40 `DISEASE` and its children
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 006 — DISEASE core (§40 root branch)
-- ============================================================================
CREATE TYPE domain_lifecycle AS ENUM ('DRAFT','PUBLISHED','RETIRED');

CREATE TABLE domain.disease_category (
  id          uuid PRIMARY KEY,
  slug        text UNIQUE NOT NULL,
  name        text NOT NULL,
  parent_id   uuid REFERENCES domain.disease_category(id),
  lifecycle   domain_lifecycle NOT NULL DEFAULT 'DRAFT',
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT c_cat_not_self_parent CHECK (parent_id IS DISTINCT FROM id)
);

CREATE TABLE domain.specialty (
  id        uuid PRIMARY KEY,
  slug      text UNIQUE NOT NULL,
  name      text NOT NULL,
  -- the bridge to §2.3.4c scope-of-practice checking; NULL means "not risk-classified"
  clinical_domain text REFERENCES safety.clinical_domain(code)
);

CREATE TABLE domain.icd_code (
  id        uuid PRIMARY KEY,
  system    text NOT NULL,          -- 'ICD-10-CM' | 'ICD-11-MMS'
  code      text NOT NULL,
  title     text NOT NULL,
  UNIQUE (system, code)
);

CREATE TABLE domain.disease (
  id             uuid PRIMARY KEY,
  slug           text UNIQUE NOT NULL,
  name           text NOT NULL,
  synonyms       text[] NOT NULL DEFAULT '{}',
  category_id    uuid REFERENCES domain.disease_category(id),
  lifecycle      domain_lifecycle NOT NULL DEFAULT 'DRAFT',
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid REFERENCES principal.app_user(id),
  -- E-4: disease content is global, never provider- or subject-scoped. Recorded
  -- explicitly so a later RLS policy cannot accidentally treat it as tenant data.
  rls_scope      text NOT NULL DEFAULT 'GLOBAL' CHECK (rls_scope = 'GLOBAL')
);

CREATE TABLE domain.disease_icd_code (
  id         uuid PRIMARY KEY,
  disease_id uuid NOT NULL REFERENCES domain.disease(id),
  icd_id     uuid NOT NULL REFERENCES domain.icd_code(id),
  UNIQUE (disease_id, icd_id)
);

CREATE TABLE domain.disease_specialty (
  id           uuid PRIMARY KEY,
  disease_id   uuid NOT NULL REFERENCES domain.disease(id),
  specialty_id uuid NOT NULL REFERENCES domain.specialty(id),
  is_primary   boolean NOT NULL DEFAULT false,
  UNIQUE (disease_id, specialty_id)
);

-- ---------- the four association children, each independently claimable ----------
CREATE TABLE domain.symptom (
  id       uuid PRIMARY KEY,
  slug     text UNIQUE NOT NULL,
  name     text NOT NULL,
  synonyms text[] NOT NULL DEFAULT '{}',
  body_system text
);

CREATE TABLE domain.disease_symptom (
  id           uuid PRIMARY KEY,
  disease_id   uuid NOT NULL REFERENCES domain.disease(id),
  symptom_id   uuid NOT NULL REFERENCES domain.symptom(id),
  -- no frequency, no typicality, no "common/rare": those are claims.
  UNIQUE (disease_id, symptom_id)
);

CREATE TABLE domain.cause (
  id   uuid PRIMARY KEY,
  slug text UNIQUE NOT NULL,
  name text NOT NULL,
  cause_class text                   -- 'INFECTIOUS'|'GENETIC'|'ENVIRONMENTAL'|'IDIOPATHIC'…
);

CREATE TABLE domain.disease_cause (
  id         uuid PRIMARY KEY,
  disease_id uuid NOT NULL REFERENCES domain.disease(id),
  cause_id   uuid NOT NULL REFERENCES domain.cause(id),
  UNIQUE (disease_id, cause_id)
);

CREATE TABLE domain.risk_factor (
  id         uuid PRIMARY KEY,
  slug       text UNIQUE NOT NULL,
  name       text NOT NULL,
  modifiable boolean
);

CREATE TABLE domain.disease_risk_factor (
  id             uuid PRIMARY KEY,
  disease_id     uuid NOT NULL REFERENCES domain.disease(id),
  risk_factor_id uuid NOT NULL REFERENCES domain.risk_factor(id),
  -- no relative risk, no odds ratio, no hazard ratio: CLINICAL_EFFICACY claims,
  -- and §1.9.7 blocks any of them without a population.
  UNIQUE (disease_id, risk_factor_id)
);

CREATE TABLE domain.complication (
  id   uuid PRIMARY KEY,
  slug text UNIQUE NOT NULL,
  name text NOT NULL
);

CREATE TABLE domain.disease_complication (
  id              uuid PRIMARY KEY,
  disease_id      uuid NOT NULL REFERENCES domain.disease(id),
  complication_id uuid NOT NULL REFERENCES domain.complication(id),
  -- no rate column. §3.4.1 and §3.4.2 both live here.
  UNIQUE (disease_id, complication_id)
);

-- ---------- diagnostics: what a test measures, never what a result means ----------
CREATE TABLE domain.diagnostic_test (
  id          uuid PRIMARY KEY,
  slug        text UNIQUE NOT NULL,
  name        text NOT NULL,
  loinc_code  text,
  modality    text,                  -- 'LAB'|'IMAGING'|'PATHOLOGY'|'FUNCTIONAL'|'GENETIC'
  -- §3.1.7: "what a named test measures and why clinicians order it" is a
  -- GENERAL_EDUCATION claim via domain_attribute. There is no interpretation column.
  lifecycle   domain_lifecycle NOT NULL DEFAULT 'DRAFT'
);

CREATE TABLE domain.disease_diagnostic_test (
  id          uuid PRIMARY KEY,
  disease_id  uuid NOT NULL REFERENCES domain.disease(id),
  test_id     uuid NOT NULL REFERENCES domain.diagnostic_test(id),
  role        text,                  -- 'SCREENING'|'DIAGNOSTIC'|'MONITORING'|'STAGING'
  UNIQUE (disease_id, test_id)
);

CREATE TABLE domain.clinical_indicator (
  id          uuid PRIMARY KEY,
  slug        text UNIQUE NOT NULL,
  name        text NOT NULL,         -- 'HbA1c' | 'LDL-C' | 'eGFR'
  test_id     uuid REFERENCES domain.diagnostic_test(id),
  unit_ucum   text NOT NULL,         -- UCUM code. A slot descriptor, not a measurement.
  -- §6's Patient value / Interpretation / Recommended next step are NOT here.
  -- They are Category C (§2.4.1a) and adding them is a §2.3.2 Board decision.
  lifecycle   domain_lifecycle NOT NULL DEFAULT 'DRAFT'
);

-- A reference_value is a SLOT, not a range. The range is a REFERENCE_RANGE claim,
-- and §1.9.7's pop_required constraint on claim makes the population non-optional.
CREATE TABLE domain.reference_value (
  id                uuid PRIMARY KEY,
  indicator_id      uuid NOT NULL REFERENCES domain.clinical_indicator(id),
  population_key    text NOT NULL,   -- 'adult_nonpregnant' | 'paediatric_2_5y' | …
  jurisdiction      char(2),         -- §3.5.4: a range from one jurisdiction is not portable
  issuing_lab       text,            -- §3.5.1: the issuing laboratory's own published range
  unit_ucum         text NOT NULL,
  value_class       text NOT NULL    -- §3.5.8: a reference range and a treatment target
    CHECK (value_class IN ('REFERENCE_RANGE','TREATMENT_TARGET')),
                                     -- are separate, separately sourced claims
  UNIQUE (indicator_id, population_key, jurisdiction, issuing_lab, value_class)
);

-- ---------- §7 severity models: versioned (E-2), population-level only ----------
CREATE TABLE domain.disease_severity_model (
  id              uuid PRIMARY KEY,
  disease_id      uuid NOT NULL REFERENCES domain.disease(id),
  name            text NOT NULL,      -- 'KDIGO CKD stage' | 'NYHA class'
  issuing_body    text NOT NULL,
  version_label   text NOT NULL,
  effective_from  date NOT NULL,
  effective_to    date,
  superseded_by   uuid REFERENCES domain.disease_severity_model(id),
  retired_at      timestamptz,
  -- §4.7.3 / §3.1.3: stored and displayed as population-level reference content.
  -- No severity classification is computed for an individual while Category C is off.
  -- Drop this constraint only on a recorded §2.3.2 Board enablement.
  individual_use_enabled boolean NOT NULL DEFAULT false
    CONSTRAINT c_severity_individual_disabled_v1 CHECK (individual_use_enabled = false),
  UNIQUE (disease_id, name, version_label),
  CONSTRAINT c_sev_not_self_supersede CHECK (superseded_by IS DISTINCT FROM id)
);

CREATE TRIGGER trg_severity_model_supersede
  AFTER UPDATE ON domain.disease_severity_model
  FOR EACH ROW EXECUTE FUNCTION evidence.cascade_supersession('disease_severity_model');

-- §4.7.2: criteria, score, guideline, evidence, limitations and recommended escalation
-- are ALL claims. This table names the levels; domain_attribute carries the six facts.
CREATE TABLE domain.disease_severity_level (
  id          uuid PRIMARY KEY,
  model_id    uuid NOT NULL REFERENCES domain.disease_severity_model(id),
  level       disease_severity NOT NULL,
  level_label text NOT NULL,          -- the model's own label, e.g. 'G3a'
  ordinal     smallint NOT NULL,
  UNIQUE (model_id, level),
  UNIQUE (model_id, ordinal)
);

ALTER TABLE domain.disease                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.clinical_indicator      ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.reference_value         ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.disease_severity_model  ENABLE ROW LEVEL SECURITY;
