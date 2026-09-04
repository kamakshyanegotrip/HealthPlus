-- HealthPlus migration: 6. Migration 007 — §40 `TREATMENTS`
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 007 — TREATMENTS (§40 TREATMENTS branch)
-- ============================================================================
CREATE TYPE treatment_kind AS ENUM
  ('MEDICATION','PROCEDURE','SURGERY','REHABILITATION','DEVICE','RADIOTHERAPY','OTHER');

CREATE TABLE domain.treatment (
  id          uuid PRIMARY KEY,
  slug        text UNIQUE NOT NULL,
  name        text NOT NULL,
  kind        treatment_kind NOT NULL,
  clinical_domain text REFERENCES safety.clinical_domain(code),  -- routes §2.2.5b review
  lifecycle   domain_lifecycle NOT NULL DEFAULT 'DRAFT',
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE domain.disease_treatment (
  id           uuid PRIMARY KEY,
  disease_id   uuid NOT NULL REFERENCES domain.disease(id),
  treatment_id uuid NOT NULL REFERENCES domain.treatment(id),
  line_of_therapy smallint,             -- 1 = first line, per the cited guideline only
  UNIQUE (disease_id, treatment_id, line_of_therapy)
);

-- subtype tables: one row per treatment of that kind, sharing the treatment's id
CREATE TABLE domain.medication (
  treatment_id  uuid PRIMARY KEY REFERENCES domain.treatment(id),
  inn_name      text NOT NULL,          -- international nonproprietary name
  atc_code      text,
  route         text,
  -- NO dose, NO frequency, NO max daily. §3.12.2 prohibits inventing dosages and
  -- claim_kind MEDICATION exists (ADR-003 §1.2) so the §1.5.3 gate can key on it.
  controlled_status text                -- 'SCHEDULE_II'… ; a LEGAL_REGULATORY claim's subject
);

CREATE TABLE domain.procedure (
  treatment_id uuid PRIMARY KEY REFERENCES domain.treatment(id),
  cpt_code     text,
  icd_pcs_code text,
  setting      text                     -- 'INPATIENT'|'DAY_CASE'|'OUTPATIENT'
);

CREATE TABLE domain.surgery (
  treatment_id     uuid PRIMARY KEY REFERENCES domain.treatment(id),
  approach         text,                -- 'OPEN'|'LAPAROSCOPIC'|'ROBOTIC'|'ENDOSCOPIC'
  anaesthesia_type text,                -- descriptor; §3.2.3 forbids clearing an individual
  typical_los_attr_note text            -- see comment below
);

COMMENT ON COLUMN domain.surgery.typical_los_attr_note IS
  'Documentation only. Typical length of stay is a CLINICAL_EFFICACY claim reached via '
  'domain_attribute(entity_type=''surgery'', attribute=''typical_length_of_stay''). '
  'This column exists to stop the next person adding an integer here.';

CREATE TABLE domain.rehabilitation (
  treatment_id uuid PRIMARY KEY REFERENCES domain.treatment(id),
  discipline   text                     -- 'PHYSIO'|'OCCUPATIONAL'|'SPEECH'|'CARDIAC_REHAB'
);

-- conflict #7: OUTCOMES governed. Names the measure; the value is a claim.
CREATE TABLE domain.treatment_outcome (
  id             uuid PRIMARY KEY,
  treatment_id   uuid NOT NULL REFERENCES domain.treatment(id),
  disease_id     uuid REFERENCES domain.disease(id),
  measure        text NOT NULL,         -- 'five_year_survival'|'revision_rate'|'complication_rate'
  measure_unit   text NOT NULL,         -- '%' | 'per_1000_patient_years'
  population_key text NOT NULL,         -- §1.9.7; mirrors the claim's population
  time_horizon   text,                  -- '5y' | '30d' | 'in_hospital'
  -- §3.4.2: a population figure must never be attributable to a named provider from
  -- here. Provider-specific outcomes live in hospital_treatment_outcome (migration 015)
  -- and carry the §1.4.4 marker.
  UNIQUE (treatment_id, disease_id, measure, population_key, time_horizon)
);

-- §3.2.6: published criteria, reproduced verbatim with citation. There is deliberately
-- no column, and no table anywhere in this schema, that records whether a person meets one.
CREATE TABLE domain.treatment_eligibility_criterion (
  id             uuid PRIMARY KEY,
  treatment_id   uuid NOT NULL REFERENCES domain.treatment(id),
  criterion_kind text NOT NULL CHECK (criterion_kind IN ('INCLUSION','EXCLUSION')),
  ordinal        smallint NOT NULL,
  issuer_kind    text NOT NULL CHECK (issuer_kind IN ('GUIDELINE','PROVIDER','INSURER','REGULATOR')),
  provider_org_id uuid REFERENCES principal.provider_org(id),   -- E-4 scope when PROVIDER
  UNIQUE (treatment_id, criterion_kind, ordinal, issuer_kind, provider_org_id),
  CONSTRAINT c_provider_criterion_scoped
    CHECK ((issuer_kind = 'PROVIDER') = (provider_org_id IS NOT NULL))
);

-- population-level contraindications: what a guideline says, for whom. §3.2.3 forbids
-- asserting one for an individual, which is why there is no subject_id on this table.
CREATE TABLE domain.treatment_contraindication (
  id             uuid PRIMARY KEY,
  treatment_id   uuid NOT NULL REFERENCES domain.treatment(id),
  condition_kind text NOT NULL CHECK (condition_kind IN ('DISEASE','MEDICATION','STATE')),
  disease_id     uuid REFERENCES domain.disease(id),
  medication_id  uuid REFERENCES domain.medication(treatment_id),
  state_key      text,                  -- 'PREGNANCY' | 'RENAL_IMPAIRMENT' | …
  severity_class text NOT NULL CHECK (severity_class IN ('ABSOLUTE','RELATIVE')),
  CONSTRAINT c_contra_target_one CHECK (
    (condition_kind = 'DISEASE'    AND disease_id IS NOT NULL AND medication_id IS NULL AND state_key IS NULL) OR
    (condition_kind = 'MEDICATION' AND medication_id IS NOT NULL AND disease_id IS NULL AND state_key IS NULL) OR
    (condition_kind = 'STATE'      AND state_key IS NOT NULL AND disease_id IS NULL AND medication_id IS NULL)
  )
);

-- ---------- v0.2: AMB-S-04 resolved. Subtypes, and now enforced as such. ----------
-- Sharing treatment.id is only a subtype relationship if the database says so. Two
-- invariants: the subtype row must match treatment.kind, and a treatment whose kind has
-- a subtype table must HAVE that row. Without the second, a MEDICATION with no
-- domain.medication row is a treatment with no INN, no ATC and no §1.5.3 gate to key on.
CREATE OR REPLACE FUNCTION domain.assert_subtype_kind() RETURNS trigger AS $$
DECLARE k treatment_kind; expected treatment_kind := TG_ARGV[0]::treatment_kind;
BEGIN
  SELECT t.kind INTO k FROM domain.treatment t WHERE t.id = NEW.treatment_id;
  IF k IS DISTINCT FROM expected THEN
    RAISE EXCEPTION
      'HP-SCHEMA AMB-S-04: treatment % is kind %, cannot have a % subtype row',
      NEW.treatment_id, k, expected;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_medication_kind      BEFORE INSERT OR UPDATE ON domain.medication
  FOR EACH ROW EXECUTE FUNCTION domain.assert_subtype_kind('MEDICATION');
CREATE TRIGGER trg_procedure_kind       BEFORE INSERT OR UPDATE ON domain.procedure
  FOR EACH ROW EXECUTE FUNCTION domain.assert_subtype_kind('PROCEDURE');
CREATE TRIGGER trg_surgery_kind         BEFORE INSERT OR UPDATE ON domain.surgery
  FOR EACH ROW EXECUTE FUNCTION domain.assert_subtype_kind('SURGERY');
CREATE TRIGGER trg_rehabilitation_kind  BEFORE INSERT OR UPDATE ON domain.rehabilitation
  FOR EACH ROW EXECUTE FUNCTION domain.assert_subtype_kind('REHABILITATION');

-- Completeness, deferred so a treatment and its subtype row insert in one transaction.
CREATE OR REPLACE FUNCTION domain.assert_subtype_present() RETURNS trigger AS $$
DECLARE present boolean;
BEGIN
  present := CASE NEW.kind
    WHEN 'MEDICATION'     THEN EXISTS (SELECT 1 FROM domain.medication     x WHERE x.treatment_id = NEW.id)
    WHEN 'PROCEDURE'      THEN EXISTS (SELECT 1 FROM domain.procedure      x WHERE x.treatment_id = NEW.id)
    WHEN 'SURGERY'        THEN EXISTS (SELECT 1 FROM domain.surgery        x WHERE x.treatment_id = NEW.id)
    WHEN 'REHABILITATION' THEN EXISTS (SELECT 1 FROM domain.rehabilitation x WHERE x.treatment_id = NEW.id)
    ELSE true    -- DEVICE, RADIOTHERAPY and OTHER have no subtype table yet
  END;
  IF NOT present THEN
    RAISE EXCEPTION 'HP-SCHEMA AMB-S-04: treatment % is kind % and has no subtype row',
      NEW.id, NEW.kind;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_treatment_subtype_present
  AFTER INSERT OR UPDATE ON domain.treatment
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION domain.assert_subtype_present();

-- kind is single-valued, so mutual exclusivity between subtype tables follows from the
-- kind check above. Changing a treatment's kind after its subtype row exists is refused
-- by trg_*_kind on the subtype and by trg_treatment_subtype_present on the parent.

ALTER TABLE domain.treatment          ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.treatment_outcome  ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.treatment_eligibility_criterion ENABLE ROW LEVEL SECURITY;
