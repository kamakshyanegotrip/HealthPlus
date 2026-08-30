-- HealthPlus migration: 14. Migration 015 — §40 `HOSPITAL`
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 015 — HOSPITAL (§40 HOSPITAL branch)
-- ============================================================================
CREATE TABLE domain.hospital (
  id              uuid PRIMARY KEY,
  provider_org_id uuid NOT NULL REFERENCES principal.provider_org(id),   -- E-4
  slug            text UNIQUE NOT NULL,
  legal_name      text NOT NULL,
  display_name    text NOT NULL,
  country_code    char(2) NOT NULL REFERENCES domain.country(code),
  subdivision     text,
  city            text,
  lifecycle       domain_lifecycle NOT NULL DEFAULT 'DRAFT',
  created_at      timestamptz NOT NULL DEFAULT now(),
  -- §1.4.7: nothing on this table is a ranking input, and nothing here is confidence.
  -- The ranker reads commercial.*; the DQE reads evidence.*; neither reads the other.
  rls_scope       text NOT NULL DEFAULT 'PROVIDER' CHECK (rls_scope = 'PROVIDER')
);
CREATE INDEX idx_hospital_org ON domain.hospital (provider_org_id);

CREATE TABLE domain.specialist (
  id              uuid PRIMARY KEY,
  provider_org_id uuid NOT NULL REFERENCES principal.provider_org(id),   -- E-4
  full_name       text NOT NULL,
  specialty_id    uuid REFERENCES domain.specialty(id),
  -- §3.4.4: qualifications, board certification, registration number and years of
  -- experience are PROVIDER_CREDENTIAL claims, not columns. A provider-asserted
  -- credential displays as "claimed by provider, not verified" until §1.2.6 resolution.
  registry_verified boolean NOT NULL DEFAULT false,
  registry_name   text,
  verified_at     timestamptz,
  verified_by     uuid REFERENCES principal.app_user(id),
  CONSTRAINT c_specialist_verification_attributed
    CHECK (registry_verified = false OR (registry_name IS NOT NULL AND verified_at IS NOT NULL))
);

CREATE TABLE domain.hospital_specialist (
  id            uuid PRIMARY KEY,
  hospital_id   uuid NOT NULL REFERENCES domain.hospital(id),
  specialist_id uuid NOT NULL REFERENCES domain.specialist(id),
  -- §1.7.1: provider staffing and surgeon affiliation, 180d half-life / 365d expiry.
  -- The affiliation ITSELF is a claim; this row is the subject of it.
  UNIQUE (hospital_id, specialist_id)
);

CREATE TABLE domain.accreditation_body (
  id           uuid PRIMARY KEY,
  slug         text UNIQUE NOT NULL,
  name         text NOT NULL,           -- 'JCI' | 'NABH' | 'ISQua'
  is_statutory boolean NOT NULL,        -- §1.2.6: statutory → Tier 1, else Tier 2
  directory_url text
);

-- §1.2.6 + §3.4.3: two rows, two tiers. The provider's assertion and the accreditor's
-- directory entry are never the same record.
CREATE TABLE domain.hospital_accreditation (
  id                        uuid PRIMARY KEY,
  hospital_id               uuid NOT NULL REFERENCES domain.hospital(id),
  body_id                   uuid NOT NULL REFERENCES domain.accreditation_body(id),
  asserted_by               text NOT NULL
    CHECK (asserted_by IN ('PROVIDER','ACCREDITOR_DIRECTORY')),
  accreditation_ref         text,
  verified_against_directory boolean NOT NULL DEFAULT false,
  verified_at               timestamptz,
  verified_by               uuid REFERENCES principal.app_user(id),
  UNIQUE (hospital_id, body_id, asserted_by, accreditation_ref),
  -- §3.4.3: a provider's own assertion can NEVER be marked verified on this row.
  -- Verification is the existence of the sibling ACCREDITOR_DIRECTORY row.
  CONSTRAINT c_provider_claim_never_self_verified CHECK (
    asserted_by <> 'PROVIDER' OR verified_against_directory = false),
  CONSTRAINT c_verification_attributed CHECK (
    verified_against_directory = false OR (verified_at IS NOT NULL AND verified_by IS NOT NULL))
);

CREATE TABLE domain.hospital_treatment (
  id           uuid PRIMARY KEY,
  hospital_id  uuid NOT NULL REFERENCES domain.hospital(id),
  treatment_id uuid NOT NULL REFERENCES domain.treatment(id),
  offered      boolean NOT NULL DEFAULT true,
  UNIQUE (hospital_id, treatment_id)
);

-- conflict #7, second half: COSTS governed. No price column anywhere.
CREATE TABLE domain.hospital_cost (
  id                  uuid PRIMARY KEY,
  hospital_id         uuid NOT NULL REFERENCES domain.hospital(id),
  hospital_treatment_id uuid NOT NULL REFERENCES domain.hospital_treatment(id),
  currency            char(3) NOT NULL,        -- §3.3.3: currency-stamped, always
  scope_key           text NOT NULL,           -- 'SURGEON_FEE'|'PACKAGE'|'ALL_INCLUSIVE'
  inclusions_stated   boolean NOT NULL,        -- §3.3.4: if scope is unknown, SAY so
  exclusions_stated   boolean NOT NULL,
  -- NO amount. The figure is a COST claim, and claim.cost_expiry already forces an
  -- expires_at on it. §1.7.1: 90-day half-life, 180-day hard expiry. §3.3.8: past hard
  -- expiry the cost is UNAVAILABLE, not approximate — which is what "no column" buys.
  UNIQUE (hospital_treatment_id, currency, scope_key)
);

COMMENT ON TABLE domain.hospital_cost IS
  'The §3.3 test case. If anyone adds an amount column here, §3.3.1, §3.3.2 and §3.3.8 '
  'all become prompt instructions again, which §3.0.3 explicitly forbids as a sole control.';

-- §1.4.4: provider-asserted clinical outcomes. Capped at 0.40 and marker-mandatory,
-- enforced through the claim_policy row and domain_attribute_kind.requires_marker.
CREATE TABLE domain.hospital_treatment_outcome (
  id                    uuid PRIMARY KEY,
  hospital_id           uuid NOT NULL REFERENCES domain.hospital(id),
  hospital_treatment_id uuid NOT NULL REFERENCES domain.hospital_treatment(id),
  measure               text NOT NULL,
  measure_unit          text NOT NULL,
  population_key        text NOT NULL,          -- §1.9.7, and claim.pop_required
  time_horizon          text,
  self_reported         boolean NOT NULL DEFAULT true,
  -- §3.4.2: a population figure may never be attributed to this hospital. Enforced by
  -- the claim being PROVIDER_OUTCOME with provider_org_id set, not CLINICAL_EFFICACY.
  UNIQUE (hospital_treatment_id, measure, population_key, time_horizon)
);

-- §1.4.1: the partner-portal ingestion path. Everything arriving here is Tier 4 by
-- construction, and nothing is published from this table — it is an inbox, not content.
CREATE TABLE domain.provider_submission (
  id              uuid PRIMARY KEY,
  provider_org_id uuid NOT NULL REFERENCES principal.provider_org(id),
  submitted_by    uuid NOT NULL REFERENCES principal.app_user(id),
  submitted_at    timestamptz NOT NULL DEFAULT now(),
  payload         jsonb NOT NULL,
  content_hash    text NOT NULL,          -- §1.8.5 duplicate detection on ingest
  state           text NOT NULL DEFAULT 'RECEIVED'
    CHECK (state IN ('RECEIVED','PARSED','CLAIMS_CREATED','REJECTED')),
  rejected_reason text,
  data_region     char(2) NOT NULL REFERENCES public.region_registry(code),
  UNIQUE (provider_org_id, content_hash)
);

ALTER TABLE domain.hospital                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.specialist                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.hospital_accreditation     ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.hospital_cost              ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.hospital_treatment_outcome ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.provider_submission        ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.provider_submission        FORCE ROW LEVEL SECURITY;

-- One worked policy, to fix the pattern. The rest are Phase 1.2.
CREATE POLICY p_submission_own_org ON domain.provider_submission
  USING (provider_org_id = app.current_provider_org());
