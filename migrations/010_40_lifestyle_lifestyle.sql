-- HealthPlus migration: 9. Migration 010 — §40 `LIFESTYLE` (`lifestyle_*`)
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 010 — LIFESTYLE (§40 lifestyle_*)
-- ============================================================================
CREATE TABLE domain.lifestyle_domain_ref (
  id       uuid PRIMARY KEY,
  slug     text UNIQUE NOT NULL,        -- 'SLEEP'|'STRESS'|'SMOKING'|'ALCOHOL'|'SUBSTANCE'
                                        -- |'OCCUPATIONAL'|'SEXUAL_HEALTH'|'SOCIAL'|'ORAL'
  name     text NOT NULL,
  clinical_domain text REFERENCES safety.clinical_domain(code),   -- addiction → ADDICTION_MEDICINE
  -- §2.4 item 10: anything touching addiction or self-harm forces elevated handling.
  elevated_risk boolean NOT NULL DEFAULT false
);

-- what "hazardous drinking" or "heavy smoking" MEANS, per an issuing body. The numbers
-- are claims; this row is the subject of them.
CREATE TABLE domain.lifestyle_risk_behaviour (
  id                  uuid PRIMARY KEY,
  lifestyle_domain_id uuid NOT NULL REFERENCES domain.lifestyle_domain_ref(id),
  slug                text UNIQUE NOT NULL,
  name                text NOT NULL,
  issuing_body        text,
  population_key      text NOT NULL,
  unit_ucum           text,             -- 'units/week' | 'pack-years'
  -- NO threshold value. §3.5.6 prohibits fabricating cut-offs, and thresholds for these
  -- differ by jurisdiction more than almost anything else in the corpus.
  jurisdiction        char(2)
);

CREATE TABLE domain.lifestyle_recommendation (
  id                  uuid PRIMARY KEY,
  lifestyle_domain_id uuid NOT NULL REFERENCES domain.lifestyle_domain_ref(id),
  disease_id          uuid REFERENCES domain.disease(id),
  treatment_id        uuid REFERENCES domain.treatment(id),
  behaviour_id        uuid REFERENCES domain.lifestyle_risk_behaviour(id),
  population_key      text NOT NULL,
  care_phase          text CHECK (care_phase IN
                        ('PRE_TREATMENT','PERI_TREATMENT','RECOVERY','LONG_TERM')),
  direction           text NOT NULL CHECK (direction IN ('INCREASE','REDUCE','CEASE','MAINTAIN'))
);

CREATE TABLE domain.cessation_support (
  id                  uuid PRIMARY KEY,
  lifestyle_domain_id uuid NOT NULL REFERENCES domain.lifestyle_domain_ref(id),
  support_kind        text NOT NULL CHECK (support_kind IN
                        ('BEHAVIOURAL','PHARMACOTHERAPY','HELPLINE','PROGRAMME','DIGITAL')),
  treatment_id        uuid REFERENCES domain.treatment(id),   -- when it is a medication
  jurisdiction        char(2),          -- helplines are jurisdictional; §3.12.1 applies
  -- §3.12.1: a helpline NUMBER is never stored here. It comes from
  -- safety.emergency_contact_reference, which is maintained, not generated.
  contact_ref_id      uuid
);

CREATE TABLE domain.occupational_exposure (
  id           uuid PRIMARY KEY,
  slug         text UNIQUE NOT NULL,
  name         text NOT NULL,           -- 'silica dust' | 'night-shift work'
  agent_class  text CHECK (agent_class IN
                 ('CHEMICAL','PHYSICAL','BIOLOGICAL','ERGONOMIC','PSYCHOSOCIAL')),
  iarc_group   text                     -- where the agent is IARC-classified
);

CREATE TABLE domain.disease_occupational_exposure (
  id          uuid PRIMARY KEY,
  disease_id  uuid NOT NULL REFERENCES domain.disease(id),
  exposure_id uuid NOT NULL REFERENCES domain.occupational_exposure(id),
  UNIQUE (disease_id, exposure_id)
);

-- AUDIT-C, PHQ-9, GAD-7 and the like. Same rule as the nutrition instruments: the tool
-- may be stored and reproduced; scoring a person against it is §3.1.3 and Category C.
-- §4.5.2: anything in the MENTAL_HEALTH domain also routes to the safeguarding protocol.
CREATE TABLE domain.lifestyle_screening_tool (
  id                  uuid PRIMARY KEY,
  lifestyle_domain_id uuid NOT NULL REFERENCES domain.lifestyle_domain_ref(id),
  slug                text NOT NULL,
  name                text NOT NULL,
  issuing_body        text NOT NULL,
  version_label       text NOT NULL,
  population_key      text NOT NULL,
  superseded_by       uuid REFERENCES domain.lifestyle_screening_tool(id),
  retired_at          timestamptz,
  individual_scoring_enabled boolean NOT NULL DEFAULT false
    CONSTRAINT c_lst_individual_disabled_v1 CHECK (individual_scoring_enabled = false),
  -- §4.5.2 / AMB-18: a self-harm-relevant instrument may not be published at all until
  -- the safeguarding protocol exists and a named lead owns it.
  safeguarding_relevant boolean NOT NULL DEFAULT false,
  safeguarding_reviewed_by uuid REFERENCES principal.clinician(user_id),
  UNIQUE (slug, version_label),
  CONSTRAINT c_lst_not_self_supersede CHECK (superseded_by IS DISTINCT FROM id),
  CONSTRAINT c_lst_safeguarding_gate CHECK (
    safeguarding_relevant = false OR safeguarding_reviewed_by IS NOT NULL)
);

CREATE TRIGGER trg_lifestyle_tool_supersede
  AFTER UPDATE ON domain.lifestyle_screening_tool
  FOR EACH ROW EXECUTE FUNCTION evidence.cascade_supersession('lifestyle_screening_tool');

CREATE TABLE domain.lifestyle_screening_item (
  id      uuid PRIMARY KEY,
  tool_id uuid NOT NULL REFERENCES domain.lifestyle_screening_tool(id),
  ordinal smallint NOT NULL,
  item_kind text NOT NULL CHECK (item_kind IN ('QUESTION','MEASUREMENT','OBSERVATION')),
  UNIQUE (tool_id, ordinal)
);

CREATE TABLE domain.disease_lifestyle (
  id                  uuid PRIMARY KEY,
  disease_id          uuid NOT NULL REFERENCES domain.disease(id),
  lifestyle_domain_id uuid NOT NULL REFERENCES domain.lifestyle_domain_ref(id),
  UNIQUE (disease_id, lifestyle_domain_id)
);

ALTER TABLE domain.lifestyle_recommendation  ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.lifestyle_screening_tool  ENABLE ROW LEVEL SECURITY;
