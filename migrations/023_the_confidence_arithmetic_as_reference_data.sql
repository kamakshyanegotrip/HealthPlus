-- HealthPlus migration: 22. Migration 023 — the confidence arithmetic, as reference data
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 023 — tier defaults, design sub-modifiers, decay clocks, modifiers
-- ============================================================================

-- ---- §1.6 tier defaults and bands ----
ALTER TABLE evidence.tier_default
  ADD COLUMN adoption_state text NOT NULL DEFAULT 'ADOPTED'
    CHECK (adoption_state IN ('ADOPTED','PROVISIONAL')),
  ADD COLUMN charter_clause text NOT NULL DEFAULT 'HP-ESC 1.6',
  -- §1.1.4: "Confidence 1.00 is never assigned to any source in any tier."
  ADD CONSTRAINT c_ceiling_never_one CHECK (band_ceiling <= 0.99),
  ADD CONSTRAINT c_band_ordered CHECK (band_floor <= default_conf AND default_conf <= band_ceiling),
  ADD CONSTRAINT c_band_nonneg  CHECK (band_floor >= 0.00);

INSERT INTO evidence.tier_default
  (tier, default_conf, band_floor, band_ceiling, adoption_state, charter_clause,
   adopted_version, effective_from) VALUES
  ('TIER_1', 0.95, 0.85, 0.99, 'ADOPTED', 'HP-ESC 1.1.4', 'HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('TIER_2', 0.85, 0.70, 0.94, 'ADOPTED', 'HP-ESC 1.2.4', 'HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('TIER_3', 0.75, 0.45, 0.90, 'ADOPTED', 'HP-ESC 1.3.2', 'HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('TIER_4', 0.55, 0.30, 0.75, 'ADOPTED', 'HP-ESC 1.4.3', 'HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('TIER_5', 0.25, 0.05, 0.40, 'ADOPTED', 'HP-ESC 1.5.2', 'HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00');

-- ---- §1.3.3 study-design sub-modifiers: applied BEFORE the §1.7 modifiers ----
-- Without these, Tier 3 is a single number and §1.3.2's "study design dominates" is
-- a sentence with nothing behind it.
CREATE TABLE evidence.study_design_submodifier (
  design_key      text NOT NULL,
  applies_to_tier source_tier NOT NULL DEFAULT 'TIER_3',
  label           text NOT NULL,
  adjustment      numeric(3,2) NOT NULL,
  resulting_base  numeric(3,2) NOT NULL,   -- the Charter's own column, kept for audit
  charter_clause  text NOT NULL,
  adopted_version text NOT NULL,
  effective_from  timestamptz NOT NULL,
  PRIMARY KEY (design_key, applies_to_tier, effective_from)
);

INSERT INTO evidence.study_design_submodifier
  (design_key, label, adjustment, resulting_base, charter_clause, adopted_version, effective_from) VALUES
  ('SYSTEMATIC_REVIEW_RCT','Systematic review / meta-analysis of RCTs',       0.10, 0.85, 'HP-ESC 1.3.3','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('RCT_POWERED',          'Individual RCT, adequately powered',              0.05, 0.80, 'HP-ESC 1.3.3','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('PROSPECTIVE_COHORT',   'Prospective cohort',                              0.00, 0.75, 'HP-ESC 1.3.3','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('RETROSPECTIVE_COHORT', 'Retrospective cohort / registry analysis',       -0.05, 0.70, 'HP-ESC 1.3.3','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('CASE_CONTROL',         'Case-control',                                   -0.10, 0.65, 'HP-ESC 1.3.3','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('CASE_SERIES',          'Case series (n >= 10)',                          -0.20, 0.55, 'HP-ESC 1.3.3','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('CASE_REPORT',          'Case report / n < 10',                           -0.30, 0.45, 'HP-ESC 1.3.3','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('NARRATIVE_REVIEW',     'Narrative review, editorial, commentary',        -0.25, 0.50, 'HP-ESC 1.3.3','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('PRECLINICAL',          'Animal, in-vitro, or modelling study',           -0.30, 0.45, 'HP-ESC 1.3.3','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00');

-- ---- §1.7.1 decay clocks, per claim kind ----
-- M1 has no meaning without these. Values are PROVISIONAL: §1.7.1 calls them proposed
-- defaults and AMB-07 records that the numbers are a business decision, not an
-- engineering one. The mapping from §1.7.1's claim types onto claim_kind is HP-ADR-003
-- §1.3's own "Half-life / expiry" column.
CREATE TABLE evidence.claim_kind_decay (
  kind             claim_kind NOT NULL,
  half_life_days   int,            -- NULL = no decay (§1.7.1 "Anatomy, physiology…")
  hard_expiry_days int,            -- NULL = never expires
  adoption_state   text NOT NULL DEFAULT 'PROVISIONAL'
    CHECK (adoption_state IN ('ADOPTED','PROVISIONAL')),
  charter_clause   text NOT NULL,
  ambiguity_ref    text,
  adopted_version  text NOT NULL,
  effective_from   timestamptz NOT NULL,
  PRIMARY KEY (kind, effective_from),
  CONSTRAINT c_expiry_after_halflife CHECK (
    half_life_days IS NULL OR hard_expiry_days IS NULL OR hard_expiry_days >= half_life_days),
  -- a decay clock with an expiry but no half-life would expire without ever decaying
  CONSTRAINT c_expiry_needs_halflife CHECK (
    hard_expiry_days IS NULL OR half_life_days IS NOT NULL)
);

INSERT INTO evidence.claim_kind_decay
  (kind, half_life_days, hard_expiry_days, charter_clause, ambiguity_ref, adopted_version, effective_from)
SELECT v.kind::claim_kind, v.hl, v.exp, v.cl, 'AMB-07', 'HP-SCHEMA-001 v0.4',
       TIMESTAMPTZ '2026-08-29 00:00:00+00'
FROM (VALUES
  ('GENERAL_EDUCATION',   NULL, NULL, 'HP-ESC 1.7.1 (anatomy, physiology, general mechanism)'),
  ('CLINICAL_EFFICACY',   1095, 1825, 'HP-ESC 1.7.1 (clinical guideline recommendation)'),
  ('TEST_INTERPRETATION', NULL, NULL, 'HP-ESC 3.1.1 (deny-only kind; decay never reached)'),
  ('REFERENCE_RANGE',     1095, 1825, 'HP-ESC 1.7.1 / HP-ADR-003 §1.3'),
  ('ELIGIBILITY',          180,  365, 'HP-ESC 1.7.1 / HP-ADR-003 §1.3'),
  ('MEDICATION',           180,  365, 'HP-ESC 1.7.1 (drug/device approval status)'),
  ('COST',                  90,  180, 'HP-ESC 1.7.1 (price, package cost, fees)'),
  ('PROVIDER_OUTCOME',     180,  365, 'HP-ESC 1.7.1 / HP-ADR-003 §1.3'),
  ('PROVIDER_CREDENTIAL',  180,  365, 'HP-ESC 1.7.1 (provider staffing, surgeon affiliation)'),
  ('ACCREDITATION',        365,  730, 'HP-ESC 1.7.1 (accreditation status)'),
  ('GUIDELINE',           1095, 1825, 'HP-ESC 1.7.1 (clinical guideline recommendation)'),
  ('LEGAL_REGULATORY',     180,  365, 'HP-ESC 1.7.1 (visa, entry, legal, regulatory status)'),
  ('EPIDEMIOLOGY',          30,   90, 'HP-ESC 1.7.1 (epidemiological / outbreak data)'),
  ('LOGISTICS',           NULL, NULL, 'HP-ADR-003 §1.3 (none)'),
  ('SENTIMENT',           NULL, NULL, 'HP-ADR-003 §1.3 (none)')
) AS v(kind, hl, exp, cl);

-- ---- §1.7 modifiers M1-M9 ----
-- The existing table cannot express M1 (repeats per elapsed half-life), M6's resolution
-- duty or M8's persistence duty, so four columns are added rather than the semantics
-- being dropped on the floor.
ALTER TABLE evidence.confidence_modifier
  ADD COLUMN label            text,
  ADD COLUMN condition_key    text,       -- what the application must decide
  ADD COLUMN applies_per      text        -- NULL = once; 'ELAPSED_HALF_LIFE' = repeating
    CHECK (applies_per IS NULL OR applies_per IN ('ELAPSED_HALF_LIFE','CORROBORATING_SOURCE')),
  ADD COLUMN duty             text,       -- a non-arithmetic obligation the modifier carries
  ADD COLUMN adoption_state   text NOT NULL DEFAULT 'ADOPTED'
    CHECK (adoption_state IN ('ADOPTED','PROVISIONAL')),
  ADD COLUMN ambiguity_ref    text,
  ADD CONSTRAINT c_additive_has_value CHECK (
    effect_kind <> 'ADDITIVE' OR effect_value IS NOT NULL),
  ADD CONSTRAINT c_cap_has_value CHECK (
    effect_kind <> 'CAP' OR effect_value IS NOT NULL),
  ADD CONSTRAINT c_hard_block_has_no_value CHECK (
    effect_kind <> 'HARD_BLOCK' OR effect_value IS NULL);

INSERT INTO evidence.confidence_modifier
  (id, label, effect_kind, effect_value, max_cumulative, applies_per, condition_key, duty,
   precedence_order, adoption_state, ambiguity_ref, charter_clause, adopted_version, effective_from) VALUES
  ('M1','Recency decay','ADDITIVE',-0.05,-0.30,'ELAPSED_HALF_LIFE','AGE_VS_HALF_LIFE',
   NULL,1,'ADOPTED','AMB-07','HP-ESC 1.7 M1','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('M2','Stale-price penalty','ADDITIVE',-0.20,-0.20,NULL,'COST_OLDER_THAN_HALF_LIFE',
   NULL,2,'ADOPTED',NULL,'HP-ESC 1.7 M2','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('M3','Corroboration','ADDITIVE',0.05,0.10,'CORROBORATING_SOURCE','CONCORDANT_EQUAL_OR_HIGHER_TIER',
   'Duplicates merged on content_hash are never counted as corroboration (§1.8.5)',
   3,'ADOPTED',NULL,'HP-ESC 1.7 M3','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('M4','Jurisdiction mismatch','CAP',0.70,NULL,NULL,'SOURCE_JURISDICTION_NE_CLAIM_JURISDICTION',
   NULL,4,'ADOPTED',NULL,'HP-ESC 1.7 M4 / 1.1.5','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('M5','Conflict of interest','ADDITIVE',-0.15,-0.15,NULL,'AUTHOR_FUNDER_PUBLISHER_STAKE',
   NULL,5,'ADOPTED',NULL,'HP-ESC 1.7 M5','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('M6','Secondary reporting','ADDITIVE',-0.10,-0.10,NULL,'REPORTS_ANOTHER_SOURCE',
   'The primary source MUST be resolved before use in a §2.2 Decision Support response',
   6,'ADOPTED',NULL,'HP-ESC 1.7 M6','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('M7','Superseded','HARD_BLOCK',NULL,NULL,NULL,'NEWER_VERSION_EXISTS',
   'Must resolve to the current version (evidence.current_version)',
   7,'ADOPTED',NULL,'HP-ESC 1.7 M7','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('M8','Translation','ADDITIVE',-0.05,-0.05,NULL,'MACHINE_TRANSLATED',
   'The original-language snippet MUST be persisted. Never applied to safety-critical text (§4.3.4)',
   8,'ADOPTED',NULL,'HP-ESC 1.7 M8','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('M9','Extraction uncertainty','ADDITIVE',-0.10,-0.10,NULL,'BELOW_PARSE_CONFIDENCE_THRESHOLD',
   'Threshold value is uncalibrated - AMB-06. Applying M9 requires a recorded threshold',
   9,'PROVISIONAL','AMB-06','HP-ESC 1.7 M9','HP-SCHEMA-001 v0.4', TIMESTAMPTZ '2026-08-29 00:00:00+00');

-- §1.7.0(2): a cap may sit below a tier's band floor and still govern, but it may never
-- sit above the ceiling — that would be a permission the tier does not grant.
CREATE OR REPLACE FUNCTION evidence.assert_cap_within_ceiling()
RETURNS TABLE (tier source_tier, kind claim_kind, category response_category,
               confidence_cap numeric, band_ceiling numeric)
LANGUAGE sql STABLE AS $$
  SELECT p.tier, p.kind, p.category, p.confidence_cap, t.band_ceiling
    FROM evidence.claim_policy p
    JOIN evidence.tier_default t ON t.tier = p.tier
   WHERE p.confidence_cap IS NOT NULL AND p.confidence_cap > t.band_ceiling;
$$;

-- ============================================================================
-- MIGRATION 023b — the §1.7 arithmetic, deterministic and trail-emitting
-- ============================================================================
CREATE OR REPLACE FUNCTION evidence.compute_confidence(
  p_tier               source_tier,
  p_kind               claim_kind,
  p_category           response_category,
  p_study_design       text        DEFAULT NULL,
  p_last_verified_at   timestamptz DEFAULT NULL,
  p_as_at              timestamptz DEFAULT now(),
  p_retracted          boolean     DEFAULT false,
  p_superseded         boolean     DEFAULT false,
  p_corroborating      int         DEFAULT 0,     -- concordant sources BEYOND the first
  p_jurisdiction_match boolean     DEFAULT true,
  p_coi                boolean     DEFAULT false,
  p_secondary          boolean     DEFAULT false,
  p_machine_translated boolean     DEFAULT false,
  p_extraction_uncertain boolean   DEFAULT false
) RETURNS TABLE (confidence numeric(3,2), hard_block hard_block_reason, trail jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v numeric(6,4); floor_ numeric(3,2); ceil_ numeric(3,2); def_ numeric(3,2);
  adj numeric; hl int; exp_ int; age_days numeric; halves int;
  cap numeric(3,2); pol evidence.claim_policy; steps jsonb := '[]'::jsonb;
  eff numeric(3,2); maxc numeric(3,2); m3 numeric;
BEGIN
  SELECT t.default_conf, t.band_floor, t.band_ceiling INTO def_, floor_, ceil_
    FROM evidence.tier_default t
   WHERE t.tier = p_tier AND t.effective_from <= p_as_at
   ORDER BY t.effective_from DESC LIMIT 1;
  IF def_ IS NULL THEN
    RAISE EXCEPTION 'HP-ESC 1.6: no tier_default row for % as at %', p_tier, p_as_at;
  END IF;
  v := def_;
  steps := steps || jsonb_build_object('step','TIER_DEFAULT','tier',p_tier,'to',v);

  -- §1.3.3, before the §1.7 modifiers, clamped to the tier band
  IF p_study_design IS NOT NULL THEN
    SELECT s.adjustment INTO adj FROM evidence.study_design_submodifier s
     WHERE s.design_key = p_study_design AND s.applies_to_tier = p_tier
       AND s.effective_from <= p_as_at
     ORDER BY s.effective_from DESC LIMIT 1;
    IF adj IS NULL THEN
      RAISE EXCEPTION 'HP-ESC 1.3.3: design % is not defined for %', p_study_design, p_tier;
    END IF;
    v := LEAST(GREATEST(v + adj, floor_), ceil_);
    steps := steps || jsonb_build_object('step','DESIGN','id',p_study_design,'effect',adj,'to',v);
  END IF;

  -- §1.7.0(1): hard blocks win outright and return immediately.
  IF p_retracted THEN
    RETURN QUERY SELECT 0.00::numeric(3,2), 'RETRACTED'::hard_block_reason,
      steps || jsonb_build_object('step','HARD_BLOCK','id','1.3.5','to',0.00);
    RETURN;
  END IF;
  IF p_superseded THEN
    RETURN QUERY SELECT 0.00::numeric(3,2), 'M7_SUPERSEDED'::hard_block_reason,
      steps || jsonb_build_object('step','HARD_BLOCK','id','M7','to',0.00);
    RETURN;
  END IF;

  SELECT d.half_life_days, d.hard_expiry_days INTO hl, exp_
    FROM evidence.claim_kind_decay d
   WHERE d.kind = p_kind AND d.effective_from <= p_as_at
   ORDER BY d.effective_from DESC LIMIT 1;

  IF p_last_verified_at IS NOT NULL THEN
    age_days := EXTRACT(EPOCH FROM (p_as_at - p_last_verified_at)) / 86400.0;
    IF exp_ IS NOT NULL AND age_days > exp_ THEN
      -- §1.7.2: past hard expiry the claim is UNAVAILABLE, not approximate.
      RETURN QUERY SELECT 0.00::numeric(3,2), 'EXPIRED'::hard_block_reason,
        steps || jsonb_build_object('step','HARD_BLOCK','id','1.7.2',
                                    'age_days',round(age_days,1),'expiry_days',exp_,'to',0.00);
      RETURN;
    END IF;
  END IF;

  -- ---- additive modifiers, in §1.7.0's fixed order ----
  -- M1 recency decay
  IF hl IS NOT NULL AND age_days IS NOT NULL THEN
    halves := floor(age_days / hl)::int;
    IF halves > 0 THEN
      SELECT m.effect_value, m.max_cumulative INTO eff, maxc
        FROM evidence.confidence_modifier m WHERE m.id = 'M1';
      adj := GREATEST(eff * halves, maxc);
      v := v + adj;
      steps := steps || jsonb_build_object('step','M1','half_lives',halves,'effect',adj,'to',v);
    END IF;
  END IF;

  -- M2 stale price: a COST claim past its half-life, on top of M1
  IF p_kind = 'COST' AND hl IS NOT NULL AND age_days IS NOT NULL AND age_days > hl THEN
    SELECT m.effect_value INTO eff FROM evidence.confidence_modifier m WHERE m.id = 'M2';
    v := v + eff;
    steps := steps || jsonb_build_object('step','M2','effect',eff,'to',v);
  END IF;

  -- M3 corroboration
  IF p_corroborating > 0 THEN
    SELECT m.effect_value, m.max_cumulative INTO eff, maxc
      FROM evidence.confidence_modifier m WHERE m.id = 'M3';
    m3 := LEAST(eff * p_corroborating, maxc);
    v := v + m3;
    steps := steps || jsonb_build_object('step','M3','sources',p_corroborating,'effect',m3,'to',v);
  END IF;

  -- M5, M6, M8, M9: independent conditions the application decides, applied in
  -- §1.7.0's fixed precedence order.
  IF p_coi THEN
    SELECT m.effect_value INTO eff FROM evidence.confidence_modifier m WHERE m.id='M5';
    v := v + eff; steps := steps || jsonb_build_object('step','M5','effect',eff,'to',v);
  END IF;
  IF p_secondary THEN
    SELECT m.effect_value INTO eff FROM evidence.confidence_modifier m WHERE m.id='M6';
    v := v + eff; steps := steps || jsonb_build_object('step','M6','effect',eff,'to',v);
  END IF;
  IF p_machine_translated THEN
    SELECT m.effect_value INTO eff FROM evidence.confidence_modifier m WHERE m.id='M8';
    v := v + eff; steps := steps || jsonb_build_object('step','M8','effect',eff,'to',v);
  END IF;
  IF p_extraction_uncertain THEN
    SELECT m.effect_value INTO eff FROM evidence.confidence_modifier m WHERE m.id='M9';
    v := v + eff; steps := steps || jsonb_build_object('step','M9','effect',eff,'to',v);
  END IF;

  -- §1.7.0(3): additive modifiers are clamped to the tier band after summation
  v := LEAST(GREATEST(v, floor_), ceil_);
  steps := steps || jsonb_build_object('step','BAND_CLAMP','floor',floor_,'ceiling',ceil_,'to',v);

  -- §1.7.0(2) and (4): caps win over the band floor; where two apply, the lower governs.
  IF NOT p_jurisdiction_match THEN
    SELECT m.effect_value INTO cap FROM evidence.confidence_modifier m WHERE m.id='M4';
  END IF;
  pol := evidence.policy_for(p_tier, p_kind, p_category);
  IF pol.confidence_cap IS NOT NULL THEN
    cap := LEAST(COALESCE(cap, pol.confidence_cap), pol.confidence_cap);
  END IF;
  IF cap IS NOT NULL AND v > cap THEN
    v := cap;
    steps := steps || jsonb_build_object('step','CAP','to',v,'clause','HP-ESC 1.7.0(2)');
  END IF;

  -- §1.0.4 two decimals; §1.1.4 never 1.00
  v := LEAST(GREATEST(round(v, 2), 0.00), 0.99);
  RETURN QUERY SELECT v::numeric(3,2), NULL::hard_block_reason,
                      steps || jsonb_build_object('step','FINAL','to',v);
END $$;

-- §6.3 made runnable: recompute a stored binding from the inputs its own trail names,
-- and report any that no longer agree. A coefficient change that silently leaves old
-- bindings behind shows up here rather than in an incident review.
CREATE OR REPLACE FUNCTION evidence.assert_binding_reproducible(p_claim uuid)
RETURNS TABLE (source_id uuid, stored numeric, recomputed numeric)
LANGUAGE sql STABLE AS $$
  SELECT cs.source_id, cs.confidence, c.confidence
    FROM evidence.claim_source cs
    JOIN evidence.claim cl ON cl.id = cs.claim_id
    JOIN evidence.evidence_source es ON es.id = cs.source_id
   CROSS JOIN LATERAL evidence.compute_confidence(
     es.tier, cl.kind, 'DECISION_SUPPORT',
     (cs.modifier_trail #>> '{0,design}'),
     es.last_verified_at, now(),
     es.retracted, es.superseded_by IS NOT NULL
   ) c
   WHERE cs.claim_id = p_claim AND cs.hard_block IS NULL
     AND cs.confidence IS DISTINCT FROM c.confidence;
$$;

-- ADR-003 migration 003 names dqe_role but does not create it; created here so the
-- §1.0.5 boundary is expressible. The DQE computes confidence and nothing else does.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dqe_role') THEN
    CREATE ROLE dqe_role NOLOGIN;
  END IF;
END $$;
GRANT USAGE ON SCHEMA evidence, safety TO dqe_role;

GRANT EXECUTE ON FUNCTION evidence.compute_confidence(
  source_tier, claim_kind, response_category, text, timestamptz, timestamptz,
  boolean, boolean, int, boolean, boolean, boolean, boolean, boolean) TO dqe_role;
