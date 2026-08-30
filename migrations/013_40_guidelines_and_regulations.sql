-- HealthPlus migration: 12. Migration 013 — §40 `GUIDELINES` and `REGULATIONS`
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 013 — GUIDELINES & REGULATIONS (§40 GUIDELINES / REGULATIONS)
-- ============================================================================
CREATE TABLE domain.guideline (
  id             uuid PRIMARY KEY,
  slug           text UNIQUE NOT NULL,
  title          text NOT NULL,
  issuing_body   text NOT NULL,
  jurisdiction   char(2),               -- NULL = international; §1.8.4/§3.6.6 apply either way
  version_label  text NOT NULL,
  effective_from date,
  effective_to   date,
  superseded_by  uuid REFERENCES domain.guideline(id),
  retired_at     timestamptz,
  disease_id     uuid REFERENCES domain.disease(id),
  clinical_domain text REFERENCES safety.clinical_domain(code),
  lifecycle      domain_lifecycle NOT NULL DEFAULT 'DRAFT',
  UNIQUE (issuing_body, slug, version_label),
  CONSTRAINT c_gl_not_self_supersede CHECK (superseded_by IS DISTINCT FROM id)
);

CREATE TRIGGER trg_guideline_supersede
  AFTER UPDATE ON domain.guideline
  FOR EACH ROW EXECUTE FUNCTION evidence.cascade_supersession('guideline');

CREATE TABLE domain.guideline_recommendation (
  id              uuid PRIMARY KEY,
  guideline_id    uuid NOT NULL REFERENCES domain.guideline(id),
  ordinal         smallint NOT NULL,
  section_ref     text,                  -- '1.4.12'
  treatment_id    uuid REFERENCES domain.treatment(id),
  disease_id      uuid REFERENCES domain.disease(id),
  population_key  text NOT NULL,
  -- §1.2.5 / §3.6.4: the source's OWN grade, persisted verbatim, never blended into
  -- confidence and never upgraded. §3.6.5: the source's own modal verb, preserved.
  strength_grade  text,                  -- 'STRONG'|'CONDITIONAL'|'A'|'B'|'I' — as published
  strength_scheme text,                  -- 'GRADE'|'USPSTF'|'ACC_AHA_COR'
  modal_verb      text,                  -- 'must'|'should'|'may be considered'
  UNIQUE (guideline_id, ordinal)
);

CREATE TABLE domain.regulation (
  id             uuid PRIMARY KEY,
  slug           text UNIQUE NOT NULL,
  title          text NOT NULL,
  jurisdiction   char(2) NOT NULL,       -- §3.7.2: never generalised, never reciprocal
  regulator      text NOT NULL,
  instrument_kind text NOT NULL
    CHECK (instrument_kind IN ('STATUTE','RULE','GUIDANCE','CIRCULAR','LICENCE_CONDITION')),
  version_label  text NOT NULL,
  in_force_from  date,
  in_force_to    date,
  superseded_by  uuid REFERENCES domain.regulation(id),
  retired_at     timestamptz,
  subject_kind   text NOT NULL
    CHECK (subject_kind IN ('TREATMENT_LEGALITY','DRUG_APPROVAL','DEVICE_APPROVAL',
                            'IMPORT_EXPORT','VISA_ENTRY','INSURANCE_MANDATE',
                            'ADVERTISING','DATA_PROTECTION','PRACTITIONER_CONDUCT')),
  UNIQUE (jurisdiction, regulator, slug, version_label),
  CONSTRAINT c_reg_not_self_supersede CHECK (superseded_by IS DISTINCT FROM id)
);

CREATE TRIGGER trg_regulation_supersede
  AFTER UPDATE ON domain.regulation
  FOR EACH ROW EXECUTE FUNCTION evidence.cascade_supersession('regulation');

CREATE TABLE domain.regulation_provision (
  id            uuid PRIMARY KEY,
  regulation_id uuid NOT NULL REFERENCES domain.regulation(id),
  ordinal       smallint NOT NULL,
  section_ref   text,
  treatment_id  uuid REFERENCES domain.treatment(id),
  medication_id uuid REFERENCES domain.medication(treatment_id),
  UNIQUE (regulation_id, ordinal)
);

-- deferred from migration 008: a dietary pattern is usually issued BY a guideline
ALTER TABLE domain.nutrition_pattern
  ADD CONSTRAINT fk_nutrition_pattern_guideline
  FOREIGN KEY (guideline_id) REFERENCES domain.guideline(id);

ALTER TABLE domain.guideline  ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.regulation ENABLE ROW LEVEL SECURITY;
