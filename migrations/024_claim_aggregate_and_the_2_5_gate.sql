-- HealthPlus migration: 23. Migration 024 — `claim_aggregate`, and the §2.5 gate
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 024 — aggregate methods, conflicts, and the §2.5 gate
-- ============================================================================

-- §1.8.3 applies to "a clinical claim". Which kinds those are is a §6.2 judgement,
-- so it is a table rather than a hard-coded list in a function body.
CREATE TABLE evidence.claim_kind_class (
  kind            claim_kind PRIMARY KEY,
  is_clinical     boolean NOT NULL,
  charter_clause  text NOT NULL,
  adopted_version text NOT NULL,
  effective_from  timestamptz NOT NULL
);

INSERT INTO evidence.claim_kind_class (kind, is_clinical, charter_clause, adopted_version, effective_from)
SELECT v.kind::claim_kind, v.cl, v.ref, 'HP-SCHEMA-001 v0.5', TIMESTAMPTZ '2026-08-29 00:00:00+00'
FROM (VALUES
  ('GENERAL_EDUCATION',   true,  'HP-ESC 2.1.3 (a clinical statement, even at population level)'),
  ('CLINICAL_EFFICACY',   true,  'HP-ESC 1.3.7'),
  ('TEST_INTERPRETATION', true,  'HP-ESC 3.1'),
  ('REFERENCE_RANGE',     true,  'HP-ESC 3.5'),
  ('ELIGIBILITY',         true,  'HP-ESC 3.2'),
  ('MEDICATION',          true,  'HP-ESC 3.12.2'),
  ('GUIDELINE',           true,  'HP-ESC 3.6'),
  ('EPIDEMIOLOGY',        true,  'HP-ESC 1.7.1'),
  ('PROVIDER_OUTCOME',    false, 'HP-ESC 1.4.4 — provider-asserted, governed by the Tier 4 cap'),
  ('PROVIDER_CREDENTIAL', false, 'HP-ESC 3.4.4 — a registry fact'),
  ('ACCREDITATION',       false, 'HP-ESC 1.2.6 — a registry fact'),
  ('COST',                false, 'HP-ESC 3.3 — financial, not clinical'),
  ('LEGAL_REGULATORY',    false, 'HP-ESC 3.7 — legal, and Tier 1 only, so T1-vs-T2 cannot arise'),
  ('LOGISTICS',           false, 'HP-ESC 1.5.4'),
  ('SENTIMENT',           false, 'HP-ESC 1.5.5')
) AS v(kind, cl, ref);

CREATE OR REPLACE FUNCTION evidence.tier_ordinal(p source_tier) RETURNS smallint
LANGUAGE sql IMMUTABLE AS $$
  SELECT (array_position(ARRAY['TIER_1','TIER_2','TIER_3','TIER_4','TIER_5'], p::text))::smallint;
$$;

-- ---- the method registry: three implementations, at most one adopted ----
CREATE TABLE evidence.aggregate_method (
  method_key      text PRIMARY KEY,
  label           text NOT NULL,
  formula         text NOT NULL,
  parameter_k     numeric(3,2),           -- DISAGREEMENT_PENALISED only
  monotonic_vs_best text NOT NULL         -- how it relates to BEST_SOURCE; drives §23.1's argument
    CHECK (monotonic_vs_best IN ('EQUAL','NEVER_HIGHER','EITHER_DIRECTION')),
  adoption_state  text NOT NULL DEFAULT 'CANDIDATE'
    CHECK (adoption_state IN ('CANDIDATE','PROVISIONAL','ADOPTED','RETIRED')),
  adopted_by      uuid REFERENCES principal.app_user(id),
  adopted_at      timestamptz,
  board_minute_ref text,
  rationale       text,
  charter_clause  text NOT NULL,
  adopted_version text NOT NULL,
  effective_from  timestamptz NOT NULL,
  -- §6.3: adopting a scoring method is a Board act with a minute, not a deploy
  CONSTRAINT c_adoption_attributed CHECK (
    adoption_state <> 'ADOPTED'
    OR (adopted_by IS NOT NULL AND adopted_at IS NOT NULL AND board_minute_ref IS NOT NULL))
);

-- exactly one live method: PROVISIONAL and ADOPTED are both "in use", so both are covered
CREATE UNIQUE INDEX uq_one_live_aggregate_method
  ON evidence.aggregate_method ((adoption_state IN ('ADOPTED','PROVISIONAL')))
  WHERE adoption_state IN ('ADOPTED','PROVISIONAL');

INSERT INTO evidence.aggregate_method
  (method_key, label, formula, parameter_k, monotonic_vs_best, adoption_state, rationale,
   charter_clause, adopted_version, effective_from) VALUES
  ('BEST_SOURCE','Best available source','max(confidence) over live bindings', NULL,
   'EQUAL','CANDIDATE',
   'HP-ESC 1.6: a Tier 1 or Tier 2 source may be sole source for Decision Support. '
   'Corroboration is already paid at the binding by M3, so it is not paid twice here.',
   'HP-ESC 1.6 / 1.7 M3','HP-SCHEMA-001 v0.5', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('TIER_WEIGHTED_MEAN','Tier-weighted mean','sum(w*c)/sum(w), w = 5..1 by tier', NULL,
   'EITHER_DIRECTION','CANDIDATE',
   'Uses all evidence weighted by authority. Known defect: a concordant Tier 5 source '
   'LOWERS the score, inverting M3. Recorded so the Board chooses it knowingly or not at all.',
   'HP-ESC 1.6','HP-SCHEMA-001 v0.5', TIMESTAMPTZ '2026-08-29 00:00:00+00'),
  ('DISAGREEMENT_PENALISED','Best source, penalised for comparable-tier disagreement',
   'max(c) - k * (max(c) - min(c)) over bindings within one tier of the best', 1.00,
   'NEVER_HIGHER','PROVISIONAL',
   'Seeded provisional because it is never higher than BEST_SOURCE and equals it when '
   'comparable sources agree. A later Board decision to adopt BEST_SOURCE can therefore '
   'only raise aggregates, so nothing published under this method becomes retroactively '
   'unpublishable. k = 1.00 is uncalibrated.',
   'HP-ESC 1.8 / 1.8.3','HP-SCHEMA-001 v0.5', TIMESTAMPTZ '2026-08-29 00:00:00+00');

-- ---- §1.8.1 / §1.8.2: conflicts as first-class, resolvable rows ----
CREATE TABLE evidence.claim_conflict (
  id             uuid PRIMARY KEY,
  claim_a        uuid NOT NULL REFERENCES evidence.claim(id) ON DELETE CASCADE,
  claim_b        uuid NOT NULL REFERENCES evidence.claim(id) ON DELETE CASCADE,
  entity_type    text,
  entity_id      uuid,
  attribute      text,
  detected_at    timestamptz NOT NULL DEFAULT now(),
  detected_by    text NOT NULL,           -- DQE version, or 'colocated_single_claim_attribute'
  resolution_state text NOT NULL DEFAULT 'UNRESOLVED' CHECK (resolution_state IN (
    'UNRESOLVED',              -- §1.8.3 applies while this holds
    'RESOLVED_BY_TIER',        -- §1.8.1(a)
    'RESOLVED_BY_RECENCY',     -- §1.8.1(b)
    'RESOLVED_BY_JURISDICTION',-- §1.8.1(c)
    'SURFACED_TO_USER')),      -- §1.8.1(d): a tie is shown, never silently resolved
  winning_claim_id uuid REFERENCES evidence.claim(id),
  resolved_at    timestamptz,
  resolved_by    uuid REFERENCES principal.app_user(id),
  charter_clause text NOT NULL DEFAULT 'HP-ESC 1.8.1',
  -- §1.8.2: suppressing a contradiction is prohibited where it is material to a
  -- Decision Support response. A resolved conflict still has to be statable.
  must_be_surfaced boolean NOT NULL DEFAULT true,
  CONSTRAINT c_conflict_distinct CHECK (claim_a <> claim_b),
  CONSTRAINT c_conflict_ordered  CHECK (claim_a < claim_b),   -- one row per unordered pair
  CONSTRAINT c_resolution_names_winner CHECK (
    resolution_state NOT IN ('RESOLVED_BY_TIER','RESOLVED_BY_RECENCY','RESOLVED_BY_JURISDICTION')
    OR winning_claim_id IS NOT NULL),
  -- §1.8.1(d): a surfaced tie has no winner by definition
  CONSTRAINT c_surfaced_has_no_winner CHECK (
    resolution_state <> 'SURFACED_TO_USER' OR winning_claim_id IS NULL),
  UNIQUE (claim_a, claim_b, entity_type, entity_id, attribute)
);
CREATE INDEX idx_conflict_open ON evidence.claim_conflict (claim_a, claim_b)
  WHERE resolution_state = 'UNRESOLVED';

-- What the schema alone can detect: two claims on an attribute the registry caps at one.
-- Everything else is semantic and belongs to the DQE (§1.8.5), which writes rows here.
CREATE OR REPLACE FUNCTION evidence.detect_colocated_conflicts()
RETURNS TABLE (entity_type text, entity_id uuid, attribute text, claim_a uuid, claim_b uuid)
LANGUAGE sql STABLE AS $$
  SELECT a.entity_type, a.entity_id, a.attribute,
         LEAST(a.claim_id, b.claim_id), GREATEST(a.claim_id, b.claim_id)
    FROM evidence.domain_attribute a
    JOIN evidence.domain_attribute b
      ON b.entity_type = a.entity_type AND b.entity_id = a.entity_id
     AND b.attribute = a.attribute AND b.claim_id > a.claim_id
    JOIN evidence.domain_attribute_kind k
      ON k.entity_type = a.entity_type AND k.attribute = a.attribute
   WHERE k.max_claims = 1;
$$;

-- §1.8.1's resolution order, deterministic. (d) is the important branch: it does not
-- pick a winner, it marks the conflict for display.
CREATE OR REPLACE FUNCTION evidence.resolve_conflict(p_conflict uuid, p_target_jurisdiction text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  ta smallint; tb smallint; da timestamptz; db timestamptz;
  ea date; eb date; ja text; jb text; a uuid; b uuid; st text; win uuid;
BEGIN
  SELECT c.claim_a, c.claim_b INTO a, b FROM evidence.claim_conflict c WHERE c.id = p_conflict;
  IF a IS NULL THEN RAISE EXCEPTION 'HP-ESC 1.8.1: no conflict %', p_conflict; END IF;

  SELECT min(evidence.tier_ordinal(es.tier)), max(es.last_verified_at)
    INTO ta, da FROM evidence.claim_source cs
    JOIN evidence.evidence_source es ON es.id = cs.source_id
   WHERE cs.claim_id = a AND cs.hard_block IS NULL;
  SELECT min(evidence.tier_ordinal(es.tier)), max(es.last_verified_at)
    INTO tb, db FROM evidence.claim_source cs
    JOIN evidence.evidence_source es ON es.id = cs.source_id
   WHERE cs.claim_id = b AND cs.hard_block IS NULL;
  SELECT cl.expires_at, cl.jurisdiction INTO ea, ja FROM evidence.claim cl WHERE cl.id = a;
  SELECT cl.expires_at, cl.jurisdiction INTO eb, jb FROM evidence.claim cl WHERE cl.id = b;

  IF ta IS NULL OR tb IS NULL THEN
    st := 'SURFACED_TO_USER'; win := NULL;                       -- nothing live to compare
  ELSIF ta <> tb THEN
    st := 'RESOLVED_BY_TIER';                                    -- §1.8.1(a)
    win := CASE WHEN ta < tb THEN a ELSE b END;
  ELSIF da IS DISTINCT FROM db
        AND NOT (ea IS NOT NULL AND ea < current_date)
        AND NOT (eb IS NOT NULL AND eb < current_date) THEN
    st := 'RESOLVED_BY_RECENCY';                                 -- §1.8.1(b)
    win := CASE WHEN da > db THEN a ELSE b END;
  ELSIF (ja IS NOT DISTINCT FROM p_target_jurisdiction)
     <> (jb IS NOT DISTINCT FROM p_target_jurisdiction) THEN
    st := 'RESOLVED_BY_JURISDICTION';                            -- §1.8.1(c)
    win := CASE WHEN ja IS NOT DISTINCT FROM p_target_jurisdiction THEN a ELSE b END;
  ELSE
    st := 'SURFACED_TO_USER'; win := NULL;                       -- §1.8.1(d)
  END IF;

  UPDATE evidence.claim_conflict
     SET resolution_state = st, winning_claim_id = win, resolved_at = now()
   WHERE id = p_conflict;
  RETURN st;
END $$;

-- ============================================================================
-- MIGRATION 024b — the aggregate, split so §1.8.3 can reach across claims
-- ============================================================================

-- The method, and only the method. No §1.8.3 here, or the two sides recurse.
CREATE OR REPLACE FUNCTION evidence.aggregate_claim_base(p_claim uuid)
RETURNS TABLE (agg numeric(3,2), n smallint, min_tier smallint, best_tier smallint,
               method_key text, trail jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE m evidence.aggregate_method; v numeric; sp numeric; steps jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO m FROM evidence.aggregate_method
   WHERE adoption_state IN ('ADOPTED','PROVISIONAL') LIMIT 1;
  IF m.method_key IS NULL THEN
    RAISE EXCEPTION 'HP-ESC 6.2: no aggregate method is adopted; §2.5 cannot be evaluated';
  END IF;

  SELECT count(*)::smallint,
         max(evidence.tier_ordinal(es.tier))::smallint,
         min(evidence.tier_ordinal(es.tier))::smallint
    INTO n, min_tier, best_tier
    FROM evidence.claim_source cs
    JOIN evidence.evidence_source es ON es.id = cs.source_id
   WHERE cs.claim_id = p_claim AND cs.hard_block IS NULL;

  IF COALESCE(n,0) = 0 THEN
    -- every binding hard-blocked, or none exist: unpublishable, not "low confidence"
    RETURN QUERY SELECT 0.00::numeric(3,2), 0::smallint, NULL::smallint, NULL::smallint,
      m.method_key, jsonb_build_array(jsonb_build_object('step','NO_LIVE_BINDINGS','to',0.00));
    RETURN;
  END IF;

  IF m.method_key = 'BEST_SOURCE' THEN
    SELECT max(cs.confidence) INTO v FROM evidence.claim_source cs
     WHERE cs.claim_id = p_claim AND cs.hard_block IS NULL;
    steps := steps || jsonb_build_object('step','BEST_SOURCE','to',v);

  ELSIF m.method_key = 'TIER_WEIGHTED_MEAN' THEN
    SELECT sum((6 - evidence.tier_ordinal(es.tier)) * cs.confidence)
           / NULLIF(sum(6 - evidence.tier_ordinal(es.tier)), 0)
      INTO v
      FROM evidence.claim_source cs
      JOIN evidence.evidence_source es ON es.id = cs.source_id
     WHERE cs.claim_id = p_claim AND cs.hard_block IS NULL;
    steps := steps || jsonb_build_object('step','TIER_WEIGHTED_MEAN','to',round(v,2));

  ELSIF m.method_key = 'DISAGREEMENT_PENALISED' THEN
    SELECT max(cs.confidence) INTO v FROM evidence.claim_source cs
     WHERE cs.claim_id = p_claim AND cs.hard_block IS NULL;
    -- spread over COMPARABLE bindings only: within one tier of the best. A Tier 5 source
    -- disagreeing with a Tier 1 one is not a disagreement, it is §1.8.1(a).
    SELECT max(cs.confidence) - min(cs.confidence) INTO sp
      FROM evidence.claim_source cs
      JOIN evidence.evidence_source es ON es.id = cs.source_id
     WHERE cs.claim_id = p_claim AND cs.hard_block IS NULL
       AND evidence.tier_ordinal(es.tier) <= best_tier + 1;
    v := v - COALESCE(m.parameter_k, 1.00) * COALESCE(sp, 0);
    steps := steps || jsonb_build_object('step','DISAGREEMENT_PENALISED',
               'k', m.parameter_k, 'spread', COALESCE(sp,0), 'to', round(v,2));
  ELSE
    RAISE EXCEPTION 'HP-SCHEMA 024: aggregate method % has no implementation', m.method_key;
  END IF;

  v := LEAST(GREATEST(round(v,2), 0.00), 0.99);
  RETURN QUERY SELECT v::numeric(3,2), n, min_tier, best_tier, m.method_key,
                      steps || jsonb_build_object('step','FINAL','to',v);
END $$;

-- Base, then §1.8.3 as an override that reaches across to the other side.
CREATE OR REPLACE FUNCTION evidence.aggregate_claim(p_claim uuid)
RETURNS TABLE (agg_confidence numeric(3,2), source_count smallint, min_tier smallint,
               best_tier smallint, method_key text, conflict_id uuid,
               demotion_required boolean, trail jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE b record; other uuid; ob record; c record; clinical boolean;
BEGIN
  SELECT * INTO b FROM evidence.aggregate_claim_base(p_claim);
  agg_confidence := b.agg; source_count := b.n; min_tier := b.min_tier;
  best_tier := b.best_tier; method_key := b.method_key; trail := b.trail;
  demotion_required := false; conflict_id := NULL;

  SELECT k.is_clinical INTO clinical
    FROM evidence.claim cl JOIN evidence.claim_kind_class k ON k.kind = cl.kind
   WHERE cl.id = p_claim;

  IF COALESCE(clinical, false) AND b.best_tier IS NOT NULL THEN
    FOR c IN
      SELECT cf.id, CASE WHEN cf.claim_a = p_claim THEN cf.claim_b ELSE cf.claim_a END AS other_id
        FROM evidence.claim_conflict cf
       -- "unresolved" means no rule broke the tie. §1.8.1(d)'s SURFACED_TO_USER is a
       -- decision to SHOW the disagreement, not a decision about which side is right,
       -- so it counts as unresolved here.
       WHERE cf.resolution_state NOT IN
             ('RESOLVED_BY_TIER','RESOLVED_BY_RECENCY','RESOLVED_BY_JURISDICTION')
         AND (cf.claim_a = p_claim OR cf.claim_b = p_claim)
    LOOP
      SELECT * INTO ob FROM evidence.aggregate_claim_base(c.other_id);
      -- §1.8.3 is specifically a TIER 1 vs TIER 2 conflict, in either direction
      IF ob.best_tier IS NOT NULL
         AND ((b.best_tier = 1 AND ob.best_tier = 2) OR (b.best_tier = 2 AND ob.best_tier = 1))
      THEN
        IF ob.agg < agg_confidence THEN
          trail := trail || jsonb_build_object(
            'step','CONFLICT_1_8_3','conflict', c.id, 'other_claim', c.other_id,
            'other_agg', ob.agg, 'from', agg_confidence, 'to', ob.agg,
            'clause','HP-ESC 1.8.3');
          agg_confidence := ob.agg;
        END IF;
        conflict_id := c.id;
        demotion_required := true;   -- §1.8.3: Decision Support -> Informational
      END IF;
    END LOOP;
  END IF;
  RETURN NEXT;
END $$;

-- Materialise into the table ADR-003 §1.1 defined, so the derivation is stored with
-- its inputs rather than recomputed silently at read time.
ALTER TABLE evidence.claim_aggregate
  ADD COLUMN best_tier         smallint,
  ADD COLUMN method_key        text REFERENCES evidence.aggregate_method(method_key),
  ADD COLUMN conflict_id       uuid REFERENCES evidence.claim_conflict(id),
  ADD COLUMN demotion_required boolean NOT NULL DEFAULT false,
  ADD COLUMN derivation        jsonb,
  ADD CONSTRAINT c_agg_range CHECK (agg_confidence >= 0.00 AND agg_confidence <= 0.99),
  ADD CONSTRAINT c_demotion_names_conflict CHECK (
    demotion_required = false OR conflict_id IS NOT NULL),
  ADD CONSTRAINT c_tiers_ordered CHECK (
    best_tier IS NULL OR min_tier IS NULL OR best_tier <= min_tier);

CREATE OR REPLACE FUNCTION evidence.refresh_claim_aggregate(p_claim uuid)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE a record; m text;
BEGIN
  SELECT * INTO a FROM evidence.aggregate_claim(p_claim);
  SELECT method_key || '@' || adopted_version INTO m
    FROM evidence.aggregate_method WHERE method_key = a.method_key;
  INSERT INTO evidence.claim_aggregate
    (claim_id, agg_confidence, source_count, min_tier, best_tier, method_key, method_version,
     conflict_id, demotion_required, derivation, computed_at)
  VALUES (p_claim, a.agg_confidence, a.source_count, COALESCE(a.min_tier,5),
          a.best_tier, a.method_key, m, a.conflict_id, a.demotion_required, a.trail, now())
  ON CONFLICT (claim_id) DO UPDATE SET
    agg_confidence = EXCLUDED.agg_confidence, source_count = EXCLUDED.source_count,
    min_tier = EXCLUDED.min_tier, best_tier = EXCLUDED.best_tier,
    method_key = EXCLUDED.method_key, method_version = EXCLUDED.method_version,
    conflict_id = EXCLUDED.conflict_id, demotion_required = EXCLUDED.demotion_required,
    derivation = EXCLUDED.derivation, computed_at = EXCLUDED.computed_at;
END $$;

-- ---- §2.5: the response-level gate ----
-- MIN over cited claims, and this half is NOT a Board option: §3.10.1 prohibits
-- presenting a low-confidence claim in high-confidence language, and any mean lets a
-- strong claim carry a weak one past the floor. See §23.3.
CREATE OR REPLACE FUNCTION evidence.response_aggregate(
  p_claim_ids uuid[], p_category response_category
) RETURNS TABLE (agg_confidence numeric(3,2), effective_category response_category,
                 meets_floor boolean, demotion_required boolean,
                 conflicts_to_surface uuid[], trail jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE floor_ numeric(3,2); steps jsonb := '[]'::jsonb; weakest uuid;
BEGIN
  IF p_claim_ids IS NULL OR array_length(p_claim_ids,1) IS NULL THEN
    -- §1.0.1 / §3.0.3: a response citing nothing asserts nothing
    RETURN QUERY SELECT 0.00::numeric(3,2), p_category, false, false, ARRAY[]::uuid[],
      jsonb_build_array(jsonb_build_object('step','NO_CITED_CLAIMS','to',0.00));
    RETURN;
  END IF;

  SELECT min(a.agg_confidence), bool_or(a.demotion_required)
    INTO agg_confidence, demotion_required
    FROM unnest(p_claim_ids) AS t(cid)
   CROSS JOIN LATERAL evidence.aggregate_claim(t.cid) a;

  -- §1.8.2 is broader than §1.8.3: silent suppression of a contradiction is prohibited
  -- wherever it is material, whether or not the conflict triggered a confidence penalty.
  -- A conflict resolved by tier still has to be statable — resolution is not erasure.
  SELECT COALESCE(array_agg(DISTINCT cf.id), ARRAY[]::uuid[])
    INTO conflicts_to_surface
    FROM evidence.claim_conflict cf
   WHERE cf.must_be_surfaced
     AND (cf.claim_a = ANY(p_claim_ids) OR cf.claim_b = ANY(p_claim_ids));

  SELECT t.cid INTO weakest
    FROM unnest(p_claim_ids) AS t(cid)
   CROSS JOIN LATERAL evidence.aggregate_claim(t.cid) a
   ORDER BY a.agg_confidence LIMIT 1;
  steps := steps || jsonb_build_object('step','MIN_OVER_CITED','weakest_claim',weakest,
                                       'to',agg_confidence,'clause','HP-ESC 3.10.1');

  -- §1.8.3 / §2.2.2: a demoted response drops one category
  effective_category := CASE
    WHEN NOT demotion_required THEN p_category
    WHEN p_category = 'CLINICAL_DECISION' THEN 'DECISION_SUPPORT'
    WHEN p_category = 'DECISION_SUPPORT'  THEN 'INFORMATIONAL'
    ELSE 'INFORMATIONAL' END;
  IF demotion_required THEN
    steps := steps || jsonb_build_object('step','DEMOTE','from',p_category,
                                         'to',effective_category,'clause','HP-ESC 1.8.3');
  END IF;

  floor_ := CASE effective_category
    WHEN 'INFORMATIONAL' THEN 0.65 WHEN 'DECISION_SUPPORT' THEN 0.70 ELSE 0.85 END;
  meets_floor := agg_confidence >= floor_;
  steps := steps || jsonb_build_object('step','FLOOR','required',floor_,
                                       'meets',meets_floor,'clause','HP-ESC 2.5');
  trail := steps;
  RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION evidence.aggregate_claim(uuid),
                          evidence.aggregate_claim_base(uuid),
                          evidence.response_aggregate(uuid[], response_category) TO dqe_role;
