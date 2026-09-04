-- HealthPlus migration: 026c — DQ-3: contradiction detection and §1.8.1 resolution
-- Source: HP-DQE-001 Data Quality Engine — Automated Checks, §4
-- Run: DAILY incremental; WEEKLY full resweep.
--
-- evidence.detect_colocated_conflicts() (HP-SCHEMA-001) finds every
-- structurally-detectable contradiction; evidence.resolve_conflict() implements
-- §1.8.1(a)-(d). This job (1) turns freshly-detected colocations into
-- claim_conflict rows, (2) calls the resolver, and (3) writes the
-- data_quality_flag that makes a conflict visible to whoever is triaging data
-- quality, not only to whoever is composing a response.
--
-- Deliberate choice: resolve_conflict() takes a target jurisdiction for rule
-- (c), and a scheduled job has no asker — so this calls resolve_conflict(id,
-- NULL). Rules (a) tier and (b) recency still fire correctly; only when
-- neither can decide does the jurisdiction branch degenerate to
-- SURFACED_TO_USER, the safety-correct default for a background job.
--
-- Not yet run against a live database.

CREATE OR REPLACE FUNCTION evidence.dqe_check_contradictions(p_as_at timestamptz DEFAULT now())
RETURNS TABLE(newly_registered int, resolved_by_tier int, resolved_by_recency int,
              surfaced_to_user int, flags_written int)
LANGUAGE plpgsql AS $$
DECLARE
  r record; v_st text;
  v_new int := 0; v_tier int := 0; v_rec int := 0; v_surf int := 0; v_flags int := 0;
BEGIN
  -- ---- 3a. Register every schema-detectable colocated conflict -------------
  INSERT INTO evidence.claim_conflict
    (id, claim_a, claim_b, entity_type, entity_id, attribute, detected_at, detected_by)
  SELECT gen_random_uuid(), c.claim_a, c.claim_b, c.entity_type, c.entity_id, c.attribute,
         p_as_at, 'dqe_batch_v1'
    FROM evidence.detect_colocated_conflicts() c
  ON CONFLICT (claim_a, claim_b, entity_type, entity_id, attribute) DO NOTHING;
  GET DIAGNOSTICS v_new = ROW_COUNT;

  -- ---- 3b. Apply §1.8.1's order to everything still UNRESOLVED --------------
  -- Deliberate, not a trigger (AMB-S-28 in HP-SCHEMA-001 §24): resolution is a
  -- scheduled act, so §1.8.3's "unresolved Tier 1 vs Tier 2" penalty still has
  -- something to bite on between runs.
  FOR r IN
    SELECT cc.id FROM evidence.claim_conflict cc WHERE cc.resolution_state = 'UNRESOLVED'
  LOOP
    v_st := evidence.resolve_conflict(r.id, NULL);
    v_tier := v_tier + (v_st = 'RESOLVED_BY_TIER')::int;
    v_rec  := v_rec  + (v_st = 'RESOLVED_BY_RECENCY')::int;
    v_surf := v_surf + (v_st = 'SURFACED_TO_USER')::int;
  END LOOP;

  -- ---- 3c. §1.8.2: material contradictions must be STATABLE, resolved or not --
  -- Resolving a conflict names a winner; it does not authorise silence about the
  -- loser. Every conflict this run touched (new or just resolved) gets a flag.
  INSERT INTO obs.data_quality_flag
    (id, flag_kind, claim_id, entity_type, entity_id, severity, reason, detected_at,
     detected_by, charter_clause, detail)
  SELECT gen_random_uuid(), 'CONTRADICTION', cc.claim_a, cc.entity_type, cc.entity_id,
         CASE WHEN cc.resolution_state = 'SURFACED_TO_USER' THEN 'CRITICAL' ELSE 'INFO' END,
         CASE WHEN cc.resolution_state = 'SURFACED_TO_USER'
              THEN format('Claims %s and %s conflict on %s.%s and cannot be resolved by tier, recency or jurisdiction — must be surfaced to the user per HP-ESC 1.8.1(d), never silently picked.',
                          cc.claim_a, cc.claim_b, cc.entity_type, cc.attribute)
              ELSE format('Claims %s and %s conflicted on %s.%s; resolved %s. Still must be stated when material per HP-ESC 1.8.2 — resolution is not suppression.',
                          cc.claim_a, cc.claim_b, cc.entity_type, cc.attribute, cc.resolution_state)
         END,
         p_as_at, 'dqe_batch_v1', 'HP-ESC 1.8.1-1.8.2',
         jsonb_build_object('conflict_id', cc.id, 'claim_a', cc.claim_a, 'claim_b', cc.claim_b,
           'resolution_state', cc.resolution_state, 'winning_claim_id', cc.winning_claim_id)
    FROM evidence.claim_conflict cc
   WHERE (cc.detected_at >= p_as_at - interval '1 hour'
          OR cc.resolved_at >= p_as_at - interval '1 hour')
     AND NOT EXISTS (
       SELECT 1 FROM obs.data_quality_flag f
        WHERE f.flag_kind = 'CONTRADICTION' AND f.resolved_at IS NULL
          AND f.detail->>'conflict_id' = cc.id::text
          AND f.detail->>'resolution_state' = cc.resolution_state);
  GET DIAGNOSTICS v_flags = ROW_COUNT;

  RETURN QUERY SELECT v_new, v_tier, v_rec, v_surf, v_flags;
END $$;

GRANT EXECUTE ON FUNCTION evidence.dqe_check_contradictions(timestamptz) TO dqe_role;
