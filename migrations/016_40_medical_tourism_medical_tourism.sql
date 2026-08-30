-- HealthPlus migration: 15. Migration 016 — §40 `MEDICAL_TOURISM` (`medical_tourism_*`)
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 016 — MEDICAL TOURISM (§40 medical_tourism_*)
-- ============================================================================

-- the canonical stage vocabulary. §4.5.1 keys on these: 'ABROAD' selects destination
-- emergency routing (§4.5.1b), 'RETURNED_HOME' raises post-op symptoms a level (§4.5.1a).
CREATE TABLE domain.care_pathway_stage (
  code           text PRIMARY KEY,
  name           text NOT NULL,
  ordinal        smallint NOT NULL UNIQUE,
  location_class text NOT NULL CHECK (location_class IN ('ORIGIN','IN_TRANSIT','DESTINATION')),
  -- §4.5.1a: does being in this stage raise the floor severity for symptom messages?
  raises_severity boolean NOT NULL DEFAULT false,
  charter_ref    text
);

CREATE TABLE domain.medical_tourism_package (
  id                    uuid PRIMARY KEY,
  provider_org_id       uuid NOT NULL REFERENCES principal.provider_org(id),  -- E-4
  hospital_id           uuid REFERENCES domain.hospital(id),                  -- E-4
  slug                  text UNIQUE NOT NULL,
  name                  text NOT NULL,
  destination_country   char(2) NOT NULL REFERENCES domain.country(code),
  primary_treatment_id  uuid REFERENCES domain.treatment(id),
  -- NO price, NO duration, NO "all inclusive" boolean without a stated scope.
  -- §3.3.3/§3.3.4: every figure is an indicative, dated, scoped COST claim.
  lifecycle             domain_lifecycle NOT NULL DEFAULT 'DRAFT',
  created_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_package_org ON domain.medical_tourism_package (provider_org_id);

CREATE TABLE domain.package_pathway_stage (
  id          uuid PRIMARY KEY,
  package_id  uuid NOT NULL REFERENCES domain.medical_tourism_package(id),
  stage_code  text NOT NULL REFERENCES domain.care_pathway_stage(code),
  ordinal     smallint NOT NULL,
  UNIQUE (package_id, stage_code),
  UNIQUE (package_id, ordinal)
);

CREATE TABLE domain.package_component (
  id           uuid PRIMARY KEY,
  package_id   uuid NOT NULL REFERENCES domain.medical_tourism_package(id),
  ordinal      smallint NOT NULL,
  stage_code   text REFERENCES domain.care_pathway_stage(code),
  component_kind text NOT NULL CHECK (component_kind IN
    ('TREATMENT','CONSULTATION','DIAGNOSTIC','ACCOMMODATION','TRANSFER','INTERPRETER',
     'VISA_SUPPORT','AFTERCARE','INSURANCE','COMPANION','REPATRIATION')),
  treatment_id uuid REFERENCES domain.treatment(id),
  included     boolean NOT NULL,          -- §3.3.4: exclusions are as material as inclusions
  UNIQUE (package_id, ordinal)
);

CREATE TABLE domain.destination_profile (
  id                  uuid PRIMARY KEY,
  country_code        char(2) NOT NULL REFERENCES domain.country(code),
  treatment_id        uuid REFERENCES domain.treatment(id),
  specialty_id        uuid REFERENCES domain.specialty(id),
  -- NO volume, NO ranking, NO "leading destination". §3.4.6 forbids comparative
  -- superiority without a Tier 1-3 comparative source, and §1.4.7 keeps rank out of here.
  UNIQUE (country_code, treatment_id, specialty_id),
  CONSTRAINT c_destination_subject CHECK (num_nonnulls(treatment_id, specialty_id) >= 1)
);

CREATE TABLE domain.travel_requirement (
  id                  uuid PRIMARY KEY,
  destination_country char(2) NOT NULL REFERENCES domain.country(code),
  origin_country      char(2) REFERENCES domain.country(code),   -- NULL = all origins
  requirement_kind    text NOT NULL CHECK (requirement_kind IN
    ('VISA','VACCINATION','INSURANCE','ESCORT_POLICY','CUSTOMS_MEDICATION',
     'HEALTH_DECLARATION','MINOR_CONSENT','REPATRIATION_COVER')),
  regulation_id       uuid REFERENCES domain.regulation(id),
  medical_visa_id     uuid REFERENCES domain.medical_visa(id),
  UNIQUE (destination_country, origin_country, requirement_kind)
);

-- §25 / C-25 / §3.2.3: PUBLISHED criteria only. No subject_id, no determination,
-- no "fit" boolean. The criterion text is a GUIDELINE claim.
CREATE TABLE domain.travel_fitness_criterion (
  id             uuid PRIMARY KEY,
  issuing_body   text NOT NULL,           -- 'IATA' | 'AsMA' | airline medical department
  guideline_id   uuid REFERENCES domain.guideline(id),
  treatment_id   uuid REFERENCES domain.treatment(id),
  disease_id     uuid REFERENCES domain.disease(id),
  measure_id     uuid REFERENCES domain.functional_capacity_measure(id),
  population_key text NOT NULL,
  ordinal        smallint NOT NULL,
  criterion_kind text NOT NULL CHECK (criterion_kind IN
    ('TIME_SINCE_PROCEDURE','CLEARANCE_REQUIRED','ESCORT_INDICATED',
     'OXYGEN_INDICATED','ABSOLUTE_RESTRICTION','CABIN_ALTITUDE')),
  UNIQUE (issuing_body, treatment_id, disease_id, population_key, ordinal),
  CONSTRAINT c_fitness_subject CHECK (num_nonnulls(treatment_id, disease_id) >= 1)
);

COMMENT ON TABLE domain.travel_fitness_criterion IS
  'HP-ESC C-25. Reproduces published criteria with citation. Any column added here that '
  'references an app_user makes this table a §3.2.3 violation and a Category C surface.';

CREATE TABLE domain.accommodation_option (
  id              uuid PRIMARY KEY,
  provider_org_id uuid REFERENCES principal.provider_org(id),   -- E-4
  hospital_id     uuid REFERENCES domain.hospital(id),          -- E-4
  country_code    char(2) NOT NULL REFERENCES domain.country(code),
  city            text,
  accommodation_kind text NOT NULL CHECK (accommodation_kind IN
    ('ON_CAMPUS','GUEST_HOUSE','HOTEL','SERVICED_APARTMENT','RECOVERY_RESIDENCE')),
  -- clinically relevant attributes only; the rest is LOGISTICS-class context (§1.5.4)
  step_free_access boolean,
  nursing_on_site  boolean,
  distance_band    text CHECK (distance_band IN ('ON_SITE','UNDER_2KM','UNDER_10KM','OVER_10KM'))
);

CREATE TABLE domain.transfer_service (
  id              uuid PRIMARY KEY,
  provider_org_id uuid REFERENCES principal.provider_org(id),   -- E-4
  country_code    char(2) NOT NULL REFERENCES domain.country(code),
  transfer_kind   text NOT NULL CHECK (transfer_kind IN
    ('AIRPORT','INTER_FACILITY','AMBULANCE','AIR_AMBULANCE','WHEELCHAIR_ASSIST')),
  medically_staffed boolean NOT NULL DEFAULT false
);

CREATE TABLE domain.interpreter_service (
  id              uuid PRIMARY KEY,
  provider_org_id uuid REFERENCES principal.provider_org(id),   -- E-4
  hospital_id     uuid REFERENCES domain.hospital(id),
  language        text NOT NULL,
  -- §4.3.4 forbids machine-translating safety-critical text. A machine-only interpreter
  -- service must never be presented as satisfying a consent or safety conversation.
  human_interpreter boolean NOT NULL,
  clinical_certified boolean NOT NULL DEFAULT false,
  UNIQUE (provider_org_id, hospital_id, language, human_interpreter)
);

-- population-level aftercare structure, per treatment. Never a person's plan: generating
-- one that reads as a clinical document is §3.8.4.
CREATE TABLE domain.aftercare_template (
  id             uuid PRIMARY KEY,
  treatment_id   uuid NOT NULL REFERENCES domain.treatment(id),
  population_key text NOT NULL,
  issuing_body   text,
  follow_up_schedule_id uuid REFERENCES domain.follow_up_schedule(id),
  monitoring_protocol_id uuid REFERENCES domain.monitoring_protocol(id),
  -- §4.5.1a: continuity of care is broken once the person flies home. The template must
  -- carry BOTH local emergency routing and the operating provider's contact route.
  requires_local_routing boolean NOT NULL DEFAULT true
    CONSTRAINT c_aftercare_local_routing CHECK (requires_local_routing = true),
  UNIQUE (treatment_id, population_key, issuing_body)
);

CREATE TABLE domain.repatriation_requirement (
  id                  uuid PRIMARY KEY,
  destination_country char(2) NOT NULL REFERENCES domain.country(code),
  origin_country      char(2) REFERENCES domain.country(code),
  treatment_id        uuid REFERENCES domain.treatment(id),
  requirement_kind    text NOT NULL CHECK (requirement_kind IN
    ('MEDICAL_CLEARANCE_DOCUMENT','ESCORT','OXYGEN','STRETCHER','MEDICATION_CARRIAGE',
     'RECORDS_TRANSFER','INSURANCE_NOTIFICATION')),
  regulation_id       uuid REFERENCES domain.regulation(id),
  -- §3.8.4: the platform never GENERATES a clearance document. It may say one is required
  -- and who issues it. That distinction is the whole table.
  issued_by_kind      text NOT NULL CHECK (issued_by_kind IN
    ('TREATING_CLINICIAN','AIRLINE_MEDICAL','INSURER','REGULATOR')),
  UNIQUE (destination_country, origin_country, treatment_id, requirement_kind)
);

ALTER TABLE domain.medical_tourism_package  ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.travel_fitness_criterion ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.accommodation_option     ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.transfer_service         ENABLE ROW LEVEL SECURITY;
