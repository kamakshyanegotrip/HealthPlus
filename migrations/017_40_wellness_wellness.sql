-- HealthPlus migration: 16. Migration 017 — §40 `WELLNESS` (`wellness_*`)
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 017 — WELLNESS (§40 wellness_*)
-- ============================================================================
CREATE TABLE domain.wellness_category (
  id        uuid PRIMARY KEY,
  slug      text UNIQUE NOT NULL,
  name      text NOT NULL,               -- 'AYURVEDA'|'YOGA'|'SPA'|'NUTRITION_RETREAT'
                                         -- |'MENTAL_PSYCHOSOCIAL'|'FITNESS'|'DETOX'
  clinical_domain text REFERENCES safety.clinical_domain(code)
);

-- AYUSH systems and their non-Indian equivalents. Separate from category because one
-- programme can draw on several, and because regulatory status attaches to the MODALITY.
CREATE TABLE domain.wellness_modality (
  id            uuid PRIMARY KEY,
  slug          text UNIQUE NOT NULL,
  name          text NOT NULL,           -- 'Ayurveda'|'Yoga'|'Naturopathy'|'Unani'
                                         -- |'Siddha'|'Homeopathy'|'TCM'|'Physiotherapy'
  regulated_in  char(2)[] NOT NULL DEFAULT '{}',  -- jurisdictions with a statutory council
  -- §3.6.1: a modality's efficacy claims are CLINICAL_EFFICACY claims like any other and
  -- face the same tier gate. Traditional use is not evidence of efficacy.
  evidence_posture text CHECK (evidence_posture IN
    ('GUIDELINE_SUPPORTED','TRADITIONAL_USE','CONTESTED','INSUFFICIENT_EVIDENCE'))
);

CREATE TABLE domain.wellness_program (
  id                  uuid PRIMARY KEY,
  provider_org_id     uuid NOT NULL REFERENCES principal.provider_org(id),   -- E-4
  hospital_id         uuid REFERENCES domain.hospital(id),                   -- E-4
  category_id         uuid NOT NULL REFERENCES domain.wellness_category(id),
  slug                text UNIQUE NOT NULL,
  name                text NOT NULL,
  country_code        char(2) NOT NULL REFERENCES domain.country(code),
  -- §5.1: CDSCO's exclusion is "general wellness … without a medical purpose".
  -- No default. Someone declares this per programme, and it is attributable.
  medical_purpose_declared boolean NOT NULL,
  declared_by         uuid REFERENCES principal.app_user(id),
  declared_at         timestamptz,
  -- §4.5.2 / AMB-18: mental-health wellness content routes to the safeguarding protocol.
  safeguarding_reviewed boolean NOT NULL DEFAULT false,
  safeguarding_reviewed_by uuid REFERENCES principal.clinician(user_id),
  lifecycle           domain_lifecycle NOT NULL DEFAULT 'DRAFT',
  CONSTRAINT c_medical_purpose_attributed
    CHECK (declared_by IS NOT NULL AND declared_at IS NOT NULL),
  CONSTRAINT c_safeguarding_attributed
    CHECK (safeguarding_reviewed = false OR safeguarding_reviewed_by IS NOT NULL)
);

-- §20 mental & psychosocial wellness may not be PUBLISHED without safeguarding review.
CREATE OR REPLACE FUNCTION domain.assert_wellness_safeguarding() RETURNS trigger AS $$
DECLARE dom text;
BEGIN
  SELECT c.clinical_domain INTO dom
    FROM domain.wellness_category c WHERE c.id = NEW.category_id;
  IF NEW.lifecycle = 'PUBLISHED'
     AND dom IN ('MENTAL_HEALTH','PSYCHIATRY','ADDICTION_MEDICINE','SELF_HARM_SAFEGUARDING')
     AND NEW.safeguarding_reviewed = false THEN
    RAISE EXCEPTION
      'HP-ESC 4.5.2 / AMB-18: wellness program % is mental-health domain and has no safeguarding review',
      NEW.id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_wellness_safeguarding
  BEFORE INSERT OR UPDATE ON domain.wellness_program
  FOR EACH ROW EXECUTE FUNCTION domain.assert_wellness_safeguarding();

CREATE TABLE domain.wellness_program_modality (
  id          uuid PRIMARY KEY,
  program_id  uuid NOT NULL REFERENCES domain.wellness_program(id),
  modality_id uuid NOT NULL REFERENCES domain.wellness_modality(id),
  UNIQUE (program_id, modality_id)
);

CREATE TABLE domain.wellness_component (
  id             uuid PRIMARY KEY,
  program_id     uuid NOT NULL REFERENCES domain.wellness_program(id),
  ordinal        smallint NOT NULL,
  component_kind text NOT NULL CHECK (component_kind IN
    ('ACTIVITY','DIET','THERAPY','CONSULTATION','EDUCATION','TREATMENT','REST')),
  activity_id    uuid REFERENCES domain.activity(id),
  pattern_id     uuid REFERENCES domain.nutrition_pattern(id),
  modality_id    uuid REFERENCES domain.wellness_modality(id),
  UNIQUE (program_id, ordinal)
);

-- Deliberately NOT principal.clinician. A yoga therapist is not on a medical register,
-- and letting a non-medical credential sit in clinician_registration would let it satisfy
-- a §2.3.4b attribution check. There is no foreign key from here into the review queue.
CREATE TABLE domain.wellness_practitioner (
  id              uuid PRIMARY KEY,
  provider_org_id uuid NOT NULL REFERENCES principal.provider_org(id),   -- E-4
  full_name       text NOT NULL,
  country_code    char(2) NOT NULL REFERENCES domain.country(code),
  -- §3.11.1: nothing here may be presented as clinical authority.
  is_clinically_registered boolean NOT NULL DEFAULT false
    CONSTRAINT c_wellness_practitioner_not_clinician
      CHECK (is_clinically_registered = false)
);

CREATE TABLE domain.wellness_practitioner_credential (
  id              uuid PRIMARY KEY,
  practitioner_id uuid NOT NULL REFERENCES domain.wellness_practitioner(id),
  modality_id     uuid REFERENCES domain.wellness_modality(id),
  awarding_body   text NOT NULL,
  credential_ref  text,
  -- §3.4.4 / §3.4.3: an unverified credential displays as claimed, not as held.
  verified        boolean NOT NULL DEFAULT false,
  verified_at     timestamptz,
  verified_by     uuid REFERENCES principal.app_user(id),
  expires_at      date,
  UNIQUE (practitioner_id, awarding_body, credential_ref),
  CONSTRAINT c_wpc_verification_attributed
    CHECK (verified = false OR (verified_at IS NOT NULL AND verified_by IS NOT NULL))
);

CREATE TABLE domain.wellness_contraindication (
  id             uuid PRIMARY KEY,
  modality_id    uuid REFERENCES domain.wellness_modality(id),
  program_id     uuid REFERENCES domain.wellness_program(id),
  condition_kind text NOT NULL CHECK (condition_kind IN ('DISEASE','STATE','POST_PROCEDURE')),
  disease_id     uuid REFERENCES domain.disease(id),
  treatment_id   uuid REFERENCES domain.treatment(id),
  state_key      text,
  severity_class text NOT NULL CHECK (severity_class IN ('ABSOLUTE','RELATIVE')),
  population_key text NOT NULL,
  CONSTRAINT c_wellness_contra_subject CHECK (num_nonnulls(modality_id, program_id) >= 1),
  CONSTRAINT c_wellness_contra_target CHECK (
    (condition_kind = 'DISEASE'        AND disease_id IS NOT NULL) OR
    (condition_kind = 'POST_PROCEDURE' AND treatment_id IS NOT NULL) OR
    (condition_kind = 'STATE'          AND state_key IS NOT NULL)
  )
);

CREATE TABLE domain.wellness_outcome_measure (
  id           uuid PRIMARY KEY,
  program_id   uuid REFERENCES domain.wellness_program(id),
  modality_id  uuid REFERENCES domain.wellness_modality(id),
  measure      text NOT NULL,
  measure_unit text NOT NULL,
  population_key text NOT NULL,
  -- NO value. A provider-asserted wellness outcome is a PROVIDER_OUTCOME claim capped
  -- at 0.40 with the §1.4.4 marker, exactly like a surgical outcome.
  UNIQUE (program_id, modality_id, measure, population_key),
  CONSTRAINT c_wom_subject CHECK (num_nonnulls(program_id, modality_id) >= 1)
);

-- §1.5.5: reviews may be shown as sentiment and MUST NOT be adjacent to, or convertible
-- into, anything that reads as a clinical quality score. Separate table, separate claim
-- kind, and no numeric aggregate column of any sort.
CREATE TABLE domain.sentiment_subject (
  id              uuid PRIMARY KEY,
  entity_type     text NOT NULL REFERENCES evidence.domain_entity_type(entity_type),
  entity_id       uuid NOT NULL,
  platform        text NOT NULL,
  -- NO star rating, NO review count, NO computed score. §3.4.5 and §1.5.5 both apply.
  UNIQUE (entity_type, entity_id, platform)
);

ALTER TABLE domain.wellness_program      ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.wellness_practitioner ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.sentiment_subject     ENABLE ROW LEVEL SECURITY;
