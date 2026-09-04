-- HealthPlus migration: 026e — DQ-5: conflicting-guideline detection (§1.8.4)
-- Source: HP-DQE-001 Data Quality Engine — Automated Checks, §6
-- Run: WEEKLY (guideline corpus changes slowly).
--
-- domain.guideline_recommendation carries disease_id, treatment_id,
-- population_key, and the source's own strength_grade/modal_verb (persisted
-- verbatim per §3.6.4-3.6.5, never upgraded). Two recommendations from two
-- different guidelines are two different domain_attribute rows, so
-- detect_colocated_conflicts() (which only compares claims bound to the SAME
-- entity) cannot see this class of conflict by construction — this check is
-- the detector for that specific, high-value case.
--
-- §1.8.4 requires telling two situations apart: two guidelines disagreeing
-- WITHIN the same jurisdiction is a genuine clinical conflict (CRITICAL,
-- routed through §1.8.1 resolution like any other contradiction). Two
-- guidelines disagreeing ACROSS jurisdictions is, in the Charter's own words,
-- "the norm in medical tourism, not an error" (WARNING, both jurisdictions
-- stated, neither presented as universal).
--
-- Not yet run against a live database.

CREATE OR REPLACE FUNCTION evidence.dqe_check_conflicting_guidelines(p_as_at timestamptz DEFAULT now())
RETURNS TABLE(same_jurisdiction_conflicts int, cross_jurisdiction_divergences int)
LANGUAGE plpgsql AS $$
DECLARE v_same int := 0; v_cross int := 0;
BEGIN
  WITH live_recs AS (
    -- One row per recommendation whose OWN claim is still live — a recommendation
    -- bound to a hard-blocked or expired GUIDELINE claim is not a live disagreement,
    -- it is stale data DQ-1 already caught.
    SELECT gr.id AS rec_id, gr.guideline_id, gr.disease_id, gr.treatment_id,
           gr.population_key, gr.strength_grade, gr.modal_verb,
           g.issuing_body, g.jurisdiction, da.claim_id
      FROM domain.guideline_recommendation gr
      JOIN domain.guideline g ON g.id = gr.guideline_id
      JOIN evidence.domain_attribute da
        ON da.entity_type = 'guideline_recommendation' AND da.entity_id = gr.id
       AND da.attribute = 'recommendation_text'
      JOIN evidence.claim_aggregate ca ON ca.claim_id = da.claim_id
     WHERE g.retired_at IS NULL AND g.superseded_by IS NULL
       AND ca.agg_confidence > 0.00
  ),
  pairs AS (
    -- Same disease, same treatment (or both NULL — a disease-level recommendation),
    -- same population, from two DIFFERENT guidelines, that actually say something
    -- different: a differing published grade or a differing modal verb.
    SELECT a.rec_id AS rec_a, b.rec_id AS rec_b, a.claim_id AS claim_a, b.claim_id AS claim_b,
           a.disease_id, a.treatment_id, a.population_key,
           a.issuing_body AS body_a, b.issuing_body AS body_b,
           a.jurisdiction AS juris_a, b.jurisdiction AS juris_b,
           a.strength_grade AS grade_a, b.strength_grade AS grade_b,
           a.modal_verb AS verb_a, b.modal_verb AS verb_b,
           (a.jurisdiction IS NOT DISTINCT FROM b.jurisdiction) AS same_jurisdiction
      FROM live_recs a
      JOIN live_recs b
        ON b.disease_id = a.disease_id
       AND b.treatment_id IS NOT DISTINCT FROM a.treatment_id
       AND b.population_key = a.population_key
       AND b.guideline_id > a.guideline_id
     WHERE a.modal_verb IS DISTINCT FROM b.modal_verb
        OR a.strength_grade IS DISTINCT FROM b.strength_grade
  ),
  registered AS (
    -- Filed against the shared disease, not a single colocated entity — this is the
    -- cross-entity semantic case §23's note describes, so entity_type/entity_id here
    -- is context for a human reader, not an FK-validated colocation like §1.8.1's
    -- schema-detectable case.
    INSERT INTO evidence.claim_conflict
      (id, claim_a, claim_b, entity_type, entity_id, attribute, detected_at, detected_by, must_be_surfaced)
    SELECT gen_random_uuid(), LEAST(p.claim_a,p.claim_b), GREATEST(p.claim_a,p.claim_b),
           'disease', p.disease_id, 'guideline_recommendation', p_as_at,
           'dqe_batch_v1:conflicting_guideline', true
      FROM pairs p
    ON CONFLICT (claim_a, claim_b, entity_type, entity_id, attribute) DO NOTHING
    RETURNING claim_a
  )
  INSERT INTO obs.data_quality_flag
    (id, flag_kind, claim_id, entity_type, entity_id, severity, reason, detected_at,
     detected_by, charter_clause, detail)
  SELECT gen_random_uuid(), 'CONFLICTING_GUIDELINE', p.claim_a, 'disease', p.disease_id,
         CASE WHEN p.same_jurisdiction THEN 'CRITICAL' ELSE 'WARNING' END,
         CASE WHEN p.same_jurisdiction
           THEN format('%s (%s) and %s (%s) disagree on the SAME jurisdiction for disease %s / treatment %s: "%s" vs "%s" — genuine clinical conflict, route through HP-ESC 1.8.1 resolution.',
                       p.body_a, COALESCE(p.grade_a,p.verb_a), p.body_b, COALESCE(p.grade_b,p.verb_b),
                       p.disease_id, p.treatment_id, p.verb_a, p.verb_b)
           ELSE format('%s (%s) says "%s" while %s (%s) says "%s" for disease %s / treatment %s — cross-jurisdictional divergence, normal per HP-ESC 1.8.4. Both positions MUST be stated with jurisdictions named; neither is universal.',
                       p.body_a, p.juris_a, p.verb_a, p.body_b, p.juris_b, p.verb_b, p.disease_id, p.treatment_id)
         END,
         p_as_at, 'dqe_batch_v1', 'HP-ESC 1.8.4',
         jsonb_build_object('other_claim', p.claim_b, 'treatment_id', p.treatment_id,
           'population_key', p.population_key,
           'guideline_a', jsonb_build_object('body',p.body_a,'jurisdiction',p.juris_a,'grade',p.grade_a,'verb',p.verb_a),
           'guideline_b', jsonb_build_object('body',p.body_b,'jurisdiction',p.juris_b,'grade',p.grade_b,'verb',p.verb_b),
           'same_jurisdiction', p.same_jurisdiction)
    FROM pairs p
   WHERE NOT EXISTS (
     SELECT 1 FROM obs.data_quality_flag f
      WHERE f.flag_kind = 'CONFLICTING_GUIDELINE' AND f.resolved_at IS NULL
        AND f.claim_id = p.claim_a AND f.detail->>'other_claim' = p.claim_b::text);

  SELECT count(*) FILTER (WHERE (detail->>'same_jurisdiction')::boolean),
         count(*) FILTER (WHERE NOT (detail->>'same_jurisdiction')::boolean)
    INTO v_same, v_cross
    FROM obs.data_quality_flag
   WHERE flag_kind = 'CONFLICTING_GUIDELINE' AND detected_at = p_as_at;

  RETURN QUERY SELECT v_same, v_cross;
END $$;

GRANT EXECUTE ON FUNCTION evidence.dqe_check_conflicting_guidelines(timestamptz) TO dqe_role;
