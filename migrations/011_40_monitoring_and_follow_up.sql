-- HealthPlus migration: 10. Migration 011 — §40 `MONITORING` and `FOLLOW_UP`
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 011 — MONITORING & FOLLOW_UP (§40 MONITORING / FOLLOW_UP)
-- ============================================================================
CREATE TABLE domain.monitoring_protocol (
  id             uuid PRIMARY KEY,
  slug           text UNIQUE NOT NULL,
  name           text NOT NULL,
  disease_id     uuid REFERENCES domain.disease(id),
  treatment_id   uuid REFERENCES domain.treatment(id),
  population_key text NOT NULL,
  issuing_body   text,
  lifecycle      domain_lifecycle NOT NULL DEFAULT 'DRAFT',
  CONSTRAINT c_protocol_subject CHECK (num_nonnulls(disease_id, treatment_id) >= 1)
);

CREATE TABLE domain.monitoring_parameter (
  id           uuid PRIMARY KEY,
  protocol_id  uuid NOT NULL REFERENCES domain.monitoring_protocol(id),
  indicator_id uuid REFERENCES domain.clinical_indicator(id),
  test_id      uuid REFERENCES domain.diagnostic_test(id),
  ordinal      smallint NOT NULL,
  -- NO interval column. §3.5.6 prohibits fabricating screening intervals; the interval
  -- is a GUIDELINE claim on domain_attribute(entity_type='monitoring_parameter').
  UNIQUE (protocol_id, ordinal),
  CONSTRAINT c_param_subject CHECK (num_nonnulls(indicator_id, test_id) >= 1)
);

CREATE TABLE domain.follow_up_schedule (
  id             uuid PRIMARY KEY,
  slug           text UNIQUE NOT NULL,
  treatment_id   uuid NOT NULL REFERENCES domain.treatment(id),
  population_key text NOT NULL,
  issuing_body   text,
  lifecycle      domain_lifecycle NOT NULL DEFAULT 'DRAFT'
);

CREATE TABLE domain.follow_up_milestone (
  id            uuid PRIMARY KEY,
  schedule_id   uuid NOT NULL REFERENCES domain.follow_up_schedule(id),
  ordinal       smallint NOT NULL,
  offset_days   int NOT NULL,          -- from the index procedure; a schedule, not a fact
  window_days   int,
  -- §4.5.1a: the post-operative window that raises severity by one level. Population-level
  -- schedule data, keyed by the red-flag rule set — never a determination about a person.
  raises_severity boolean NOT NULL DEFAULT false,
  UNIQUE (schedule_id, ordinal),
  CONSTRAINT c_window_nonneg CHECK (window_days IS NULL OR window_days >= 0)
);

ALTER TABLE domain.monitoring_protocol ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.follow_up_schedule  ENABLE ROW LEVEL SECURITY;
