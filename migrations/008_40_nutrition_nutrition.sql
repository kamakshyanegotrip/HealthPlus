-- HealthPlus migration: 7. Migration 008 — §40 `NUTRITION` (`nutrition_*`)
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 008 — NUTRITION (§40 nutrition_*)
-- ============================================================================
CREATE TABLE domain.nutrient (
  id        uuid PRIMARY KEY,
  slug      text UNIQUE NOT NULL,
  name      text NOT NULL,
  unit_ucum text NOT NULL,
  class     text NOT NULL CHECK (class IN
              ('MACRO','VITAMIN','MINERAL','ELECTROLYTE','FIBRE','FATTY_ACID','OTHER')),
  -- NO RDA, NO upper limit. Both are REFERENCE_RANGE claims and §3.5.2 makes the
  -- population mandatory on each of them.
  parent_id uuid REFERENCES domain.nutrient(id)     -- 'omega-3' -> 'EPA'
);

CREATE TABLE domain.food_item (
  id         uuid PRIMARY KEY,
  slug       text UNIQUE NOT NULL,
  name       text NOT NULL,
  food_group text,
  fdc_id     text,                       -- USDA FoodData Central, where matched
  -- medical tourism is cross-cultural: the same food carries different names and
  -- different preparation assumptions per market. Both are LOGISTICS-class context.
  local_names jsonb NOT NULL DEFAULT '{}'
);

-- a slot, not a measurement. The amount is a claim, sourced to a composition database.
CREATE TABLE domain.food_nutrient (
  id           uuid PRIMARY KEY,
  food_item_id uuid NOT NULL REFERENCES domain.food_item(id),
  nutrient_id  uuid NOT NULL REFERENCES domain.nutrient(id),
  basis        text NOT NULL CHECK (basis IN ('PER_100G','PER_100ML','PER_SERVING')),
  serving_desc text,
  unit_ucum    text NOT NULL,
  UNIQUE (food_item_id, nutrient_id, basis, serving_desc)
);

CREATE TABLE domain.nutrition_pattern (
  id           uuid PRIMARY KEY,
  slug         text UNIQUE NOT NULL,
  name         text NOT NULL,           -- 'DASH' | 'Mediterranean' | 'renal (stage 4)'
  issuing_body text,
  guideline_id uuid,                    -- FK added in migration 013 (guideline table)
  lifecycle    domain_lifecycle NOT NULL DEFAULT 'DRAFT'
);

CREATE TABLE domain.nutrition_pattern_component (
  id           uuid PRIMARY KEY,
  pattern_id   uuid NOT NULL REFERENCES domain.nutrition_pattern(id),
  ordinal      smallint NOT NULL,
  nutrient_id  uuid REFERENCES domain.nutrient(id),
  food_item_id uuid REFERENCES domain.food_item(id),
  food_group   text,
  direction    text NOT NULL CHECK (direction IN ('INCREASE','LIMIT','AVOID','MAINTAIN')),
  UNIQUE (pattern_id, ordinal),
  CONSTRAINT c_pattern_component_subject
    CHECK (num_nonnulls(nutrient_id, food_item_id, food_group) = 1)
);

CREATE TABLE domain.nutrition_recommendation (
  id             uuid PRIMARY KEY,
  disease_id     uuid REFERENCES domain.disease(id),
  treatment_id   uuid REFERENCES domain.treatment(id),   -- peri-operative guidance
  pattern_id     uuid REFERENCES domain.nutrition_pattern(id),
  nutrient_id    uuid REFERENCES domain.nutrient(id),
  food_item_id   uuid REFERENCES domain.food_item(id),
  direction      text NOT NULL CHECK (direction IN ('INCREASE','LIMIT','AVOID','MAINTAIN')),
  population_key text NOT NULL,         -- §1.9.7: never a person, always a population
  care_phase     text CHECK (care_phase IN
                   ('PRE_TREATMENT','PERI_TREATMENT','RECOVERY','LONG_TERM')),
  -- NO target amount. A gram-per-day figure is a REFERENCE_RANGE or GUIDELINE claim and
  -- §3.5.6 prohibits fabricating thresholds.
  CONSTRAINT c_nutrition_rec_has_subject CHECK (
    num_nonnulls(pattern_id, nutrient_id, food_item_id) >= 1
  ),
  CONSTRAINT c_nutrition_rec_has_context CHECK (
    num_nonnulls(disease_id, treatment_id) >= 1
  )
);

-- allergen, intolerance, religious and cultural restrictions, as DEFINITIONS. A person's
-- own restriction is a patient_attribute (§3.8), never a row here.
CREATE TABLE domain.nutrition_restriction (
  id               uuid PRIMARY KEY,
  slug             text UNIQUE NOT NULL,
  name             text NOT NULL,        -- 'peanut' | 'gluten' | 'halal' | 'jain vegetarian'
  restriction_kind text NOT NULL CHECK (restriction_kind IN
                     ('ALLERGEN','INTOLERANCE','METABOLIC','RELIGIOUS','CULTURAL','ETHICAL')),
  -- §4.6.1 lists anaphylaxis history as a high-risk profile flag. ALLERGEN rows are the
  -- vocabulary that flag is expressed in; the flag itself lives in patient_risk_flag.
  safety_critical  boolean NOT NULL DEFAULT false
);

CREATE TABLE domain.food_restriction_link (
  id             uuid PRIMARY KEY,
  food_item_id   uuid NOT NULL REFERENCES domain.food_item(id),
  restriction_id uuid NOT NULL REFERENCES domain.nutrition_restriction(id),
  relation       text NOT NULL CHECK (relation IN ('CONTAINS','MAY_CONTAIN','EXCLUDED_BY')),
  UNIQUE (food_item_id, restriction_id, relation)
);

-- §12, population-level only: what a published monograph says about a pair.
CREATE TABLE domain.food_drug_interaction (
  id            uuid PRIMARY KEY,
  food_item_id  uuid REFERENCES domain.food_item(id),
  nutrient_id   uuid REFERENCES domain.nutrient(id),
  medication_id uuid NOT NULL REFERENCES domain.medication(treatment_id),
  mechanism_key text,                   -- 'CYP3A4_INHIBITION' | 'VITAMIN_K_ANTAGONISM'
  severity_class text NOT NULL CHECK (severity_class IN ('MAJOR','MODERATE','MINOR')),
  -- §1.5.3 and ADR-003 §1.2: interaction claims are claim_kind MEDICATION, which is why
  -- that value had to be added to the enum. Tier 5 is prohibited as support.
  onset_class   text CHECK (onset_class IN ('RAPID','DELAYED','UNSPECIFIED')),
  CONSTRAINT c_fdi_has_food CHECK (num_nonnulls(food_item_id, nutrient_id) = 1),
  UNIQUE (food_item_id, nutrient_id, medication_id)
);

-- published screening instruments (MUST, MNA, SGA). Versioned under E-2: a superseded
-- instrument must STOP being answerable, not decay. §3.5.6 governs its cut-offs.
CREATE TABLE domain.nutrition_screening_tool (
  id             uuid PRIMARY KEY,
  slug           text NOT NULL,
  name           text NOT NULL,
  issuing_body   text NOT NULL,
  version_label  text NOT NULL,
  population_key text NOT NULL,
  effective_from date,
  superseded_by  uuid REFERENCES domain.nutrition_screening_tool(id),
  retired_at     timestamptz,
  -- §2.3.1 / §3.1.3: storing the instrument is permitted; scoring a person is Category C.
  individual_scoring_enabled boolean NOT NULL DEFAULT false
    CONSTRAINT c_nst_individual_disabled_v1 CHECK (individual_scoring_enabled = false),
  UNIQUE (slug, version_label),
  CONSTRAINT c_nst_not_self_supersede CHECK (superseded_by IS DISTINCT FROM id)
);

CREATE TRIGGER trg_nutrition_tool_supersede
  AFTER UPDATE ON domain.nutrition_screening_tool
  FOR EACH ROW EXECUTE FUNCTION evidence.cascade_supersession('nutrition_screening_tool');

CREATE TABLE domain.nutrition_screening_item (
  id       uuid PRIMARY KEY,
  tool_id  uuid NOT NULL REFERENCES domain.nutrition_screening_tool(id),
  ordinal  smallint NOT NULL,
  -- the item TEXT and its published scoring are GUIDELINE claims; §3.9.4 requires a
  -- verbatim quotation to be character-identical to the stored source text.
  item_kind text NOT NULL CHECK (item_kind IN ('QUESTION','MEASUREMENT','OBSERVATION')),
  UNIQUE (tool_id, ordinal)
);

CREATE TABLE domain.disease_nutrition (
  id         uuid PRIMARY KEY,
  disease_id uuid NOT NULL REFERENCES domain.disease(id),
  pattern_id uuid NOT NULL REFERENCES domain.nutrition_pattern(id),
  UNIQUE (disease_id, pattern_id)
);

ALTER TABLE domain.nutrition_recommendation  ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.food_drug_interaction     ENABLE ROW LEVEL SECURITY;
ALTER TABLE domain.nutrition_screening_tool  ENABLE ROW LEVEL SECURITY;
