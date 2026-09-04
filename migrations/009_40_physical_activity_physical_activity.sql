-- HealthPlus migration: 8. Migration 009 — §40 `PHYSICAL_ACTIVITY` (`physical_activity_*`)
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 009 — PHYSICAL ACTIVITY (§40 physical_activity_*)
-- ============================================================================
CREATE TABLE domain.activity_intensity_band (
  code       text PRIMARY KEY,          -- 'SEDENTARY'|'LIGHT'|'MODERATE'|'VIGOROUS'
  name       text NOT NULL,
  ordinal    smallint NOT NULL UNIQUE
  -- NO MET range. The band's numeric definition is a REFERENCE_RANGE claim: it differs
  -- by source and by population, which is exactly what §3.5.2 is about.
);

CREATE TABLE domain.activity (
  id            uuid PRIMARY KEY,
  slug          text UNIQUE NOT NULL,
  name          text NOT NULL,
  modality      text NOT NULL CHECK (modality IN
                  ('AEROBIC','RESISTANCE','FLEXIBILITY','BALANCE','BREATHING','MIXED')),
  intensity_band text REFERENCES domain.activity_intensity_band(code),
  weight_bearing boolean,
  equipment_required boolean NOT NULL DEFAULT false
);

CREATE TABLE domain.activity_recommendation (
  id             uuid PRIMARY KEY,
  disease_id     uuid REFERENCES domain.disease(id),
  treatment_id   uuid REFERENCES domain.treatment(id),
  activity_id    uuid REFERENCES domain.activity(id),
  population_key text NOT NULL,
  phase          text CHECK (phase IN ('PREHAB','ACUTE','RECOVERY','MAINTENANCE')),
  -- NO minutes-per-week, NO sets, NO heart-rate target. All GUIDELINE claims.
  CONSTRAINT c_act_rec_subject CHECK (num_nonnulls(disease_id, treatment_id, activity_id) >= 1)
);

CREATE TABLE domain.activity_precaution (
  id             uuid PRIMARY KEY,
  activity_id    uuid NOT NULL REFERENCES domain.activity(id),
  condition_kind text NOT NULL CHECK (condition_kind IN ('DISEASE','STATE','POST_PROCEDURE')),
  disease_id     uuid REFERENCES domain.disease(id),
  treatment_id   uuid REFERENCES domain.treatment(id),
  state_key      text,
  severity_class text NOT NULL CHECK (severity_class IN ('ABSOLUTE','RELATIVE')),
  population_key text NOT NULL,
  CONSTRAINT c_precaution_target_one CHECK (
    (condition_kind = 'DISEASE'        AND disease_id IS NOT NULL) OR
    (condition_kind = 'POST_PROCEDURE' AND treatment_id IS NOT NULL) OR
    (condition_kind = 'STATE'          AND state_key IS NOT NULL)
  )
);

-- a PUBLISHED progression ladder. §4.5.1a raises post-operative symptoms by one severity
-- level; the stage a guideline describes is what the rule set keys on. Not a person's stage.
CREATE TABLE domain.activity_progression_stage (
  id             uuid PRIMARY KEY,
  treatment_id   uuid NOT NULL REFERENCES domain.treatment(id),
  ordinal        smallint NOT NULL,
  stage_label    text NOT NULL,          -- 'partial weight bearing' | 'return to driving'
  population_key text NOT NULL,
  -- the day range is a GUIDELINE claim, not a column. See AMB-S-08 for the one place
  -- in this schema where that call went the other way, and why.
  UNIQUE (treatment_id, ordinal)
);

-- 6MWT, METs, grip strength. The MEASURE, never a person's result. §3.1.4/§3.1.5.
CREATE TABLE domain.functional_capacity_measure (
  id           uuid PRIMARY KEY,
  slug         text UNIQUE NOT NULL,
  name         text NOT NULL,
  unit_ucum    text NOT NULL,
  higher_is_better boolean NOT NULL,
  -- thresholds are REFERENCE_RANGE claims; §1.9.7 blocks any of them without a population
  used_in_travel_fitness boolean NOT NULL DEFAULT false   -- §25 / C-25 cross-reference
);

CREATE TABLE domain.disease_activity (
  id          uuid PRIMARY KEY,
  disease_id  uuid NOT NULL REFERENCES domain.disease(id),
  activity_id uuid NOT NULL REFERENCES domain.activity(id),
  UNIQUE (disease_id, activity_id)
);

CREATE TABLE domain.treatment_activity (
  id           uuid PRIMARY KEY,
  treatment_id uuid NOT NULL REFERENCES domain.treatment(id),
  activity_id  uuid NOT NULL REFERENCES domain.activity(id),
  phase        text NOT NULL CHECK (phase IN ('PREHAB','ACUTE','RECOVERY','MAINTENANCE')),
  UNIQUE (treatment_id, activity_id, phase)
);

ALTER TABLE domain.activity_recommendation     ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.activity_precaution         ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.functional_capacity_measure ENABLE ROW LEVEL SECURITY;
