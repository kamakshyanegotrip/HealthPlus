-- HealthPlus migration: 13. Migration 014 — §40 `COUNTRY`
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 014 — COUNTRY (§40 COUNTRY / country_guideline / medical_visa / environment)
-- ============================================================================
CREATE TABLE domain.country (
  code        char(2) PRIMARY KEY,       -- ISO 3166-1 alpha-2
  name        text NOT NULL,
  region      text,
  currency    char(3),
  languages   text[] NOT NULL DEFAULT '{}',
  lifecycle   domain_lifecycle NOT NULL DEFAULT 'DRAFT'
);

CREATE TABLE domain.country_guideline (
  id           uuid PRIMARY KEY,
  country_code char(2) NOT NULL REFERENCES domain.country(code),
  guideline_id uuid NOT NULL REFERENCES domain.guideline(id),
  status       text NOT NULL
    CHECK (status IN ('ADOPTED','ENDORSED','SUPERSEDED_LOCALLY','NOT_APPLICABLE')),
  UNIQUE (country_code, guideline_id)
);

CREATE TABLE domain.medical_visa (
  id             uuid PRIMARY KEY,
  country_code   char(2) NOT NULL REFERENCES domain.country(code),
  visa_class     text NOT NULL,          -- 'MEDICAL' | 'MEDICAL_ATTENDANT' | 'E_MEDICAL'
  applicant_nationality char(2),         -- NULL = all nationalities
  regulation_id  uuid REFERENCES domain.regulation(id),
  -- NO duration, NO fee, NO document list, NO processing time. All LEGAL_REGULATORY or
  -- COST claims: §3.7.1 requires a sourced in-date Tier 1 record for each.
  UNIQUE (country_code, visa_class, applicant_nationality)
);

CREATE TABLE domain.environment (
  id             uuid PRIMARY KEY,
  country_code   char(2) NOT NULL REFERENCES domain.country(code),
  subdivision    text,
  factor_kind    text NOT NULL
    CHECK (factor_kind IN ('CLIMATE','ALTITUDE','AIR_QUALITY','ENDEMIC_DISEASE',
                           'WATER_SAFETY','VACCINATION_REQUIREMENT')),
  -- §3.5.2 names altitude as a reason a reference range is not portable; this table is
  -- what a REFERENCE_RANGE claim's population_key can be qualified against.
  UNIQUE (country_code, subdivision, factor_kind)
);

ALTER TABLE domain.medical_visa ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.environment  ENABLE ROW LEVEL SECURITY;
