-- HealthPlus migration: 026d — DQ-4: missing-source detection (defense-in-depth)
-- Source: HP-DQE-001 Data Quality Engine — Automated Checks, §5
-- Run: DAILY. Cheap integrity scan; catches a schema-invariant breach same-day.
--
-- trg_claim_requires_source (HP-SCHEMA-001 §1) is a deferred constraint trigger
-- on evidence.claim — it fires on INSERT OR UPDATE of the claim row and checks,
-- at commit, that at least one claim_source binding exists. It cannot see a
-- later DELETE FROM evidence.claim_source that empties a claim's bindings
-- without touching the claim row itself. That is the narrow gap this check
-- catches; it should fire close to never.
--
-- A second, softer signal: a claim can technically satisfy §1.0.1 (it has
-- bindings) while every one of them is hard_block'ed (retracted, superseded,
-- or expired via DQ-1) — nothing about it is currently publishable, the same
-- failure mode as having no source, reached a different way.
--
-- Not yet run against a live database.

CREATE OR REPLACE FUNCTION evidence.dqe_check_missing_source(p_as_at timestamptz DEFAULT now())
RETURNS TABLE(zero_binding_claims int, zero_live_binding_claims int)
LANGUAGE plpgsql AS $$
DECLARE v_zero int := 0; v_dead int := 0;
BEGIN
  -- ---- 4a. Should be impossible: trg_claim_requires_source only watches `claim` ----
  WITH orphans AS (
    SELECT c.id AS claim_id
      FROM evidence.claim c
     WHERE NOT EXISTS (SELECT 1 FROM evidence.claim_source cs WHERE cs.claim_id = c.id)
       AND NOT EXISTS (
         SELECT 1 FROM obs.data_quality_flag f
          WHERE f.claim_id = c.id AND f.flag_kind = 'MISSING_SOURCE' AND f.resolved_at IS NULL)
  )
  INSERT INTO obs.data_quality_flag
    (id, flag_kind, claim_id, severity, reason, detected_at, detected_by, charter_clause, detail)
  SELECT gen_random_uuid(), 'MISSING_SOURCE', o.claim_id, 'CRITICAL',
         format('Claim %s has ZERO evidence_source bindings — trg_claim_requires_source should make this impossible; bindings were deleted after the claim row was last touched. Unpublish and re-source immediately.',
                o.claim_id),
         p_as_at, 'dqe_batch_v1', 'HP-ESC 1.0.1 / 3.0.3',
         jsonb_build_object('note', 'claim_source rows were removed without an UPDATE on claim')
    FROM orphans o;
  GET DIAGNOSTICS v_zero = ROW_COUNT;

  -- ---- 4b. Sourced, but nothing live: functionally the same failure ----------
  WITH dead AS (
    SELECT c.id AS claim_id, count(*) AS n_bindings
      FROM evidence.claim c
      JOIN evidence.claim_source cs ON cs.claim_id = c.id
     GROUP BY c.id
    HAVING bool_and(cs.hard_block IS NOT NULL)
  )
  INSERT INTO obs.data_quality_flag
    (id, flag_kind, claim_id, severity, reason, detected_at, detected_by, charter_clause, detail)
  SELECT gen_random_uuid(), 'MISSING_SOURCE', d.claim_id, 'WARNING',
         format('Claim %s has %s binding(s), all hard-blocked — no LIVE source, even though it is not literally sourceless. Treat as unpublishable until re-sourced.',
                d.claim_id, d.n_bindings),
         p_as_at, 'dqe_batch_v1', 'HP-ESC 1.0.1 / 3.0.3',
         jsonb_build_object('n_bindings', d.n_bindings)
    FROM dead d
   WHERE NOT EXISTS (
     SELECT 1 FROM obs.data_quality_flag f
      WHERE f.claim_id = d.claim_id AND f.flag_kind = 'MISSING_SOURCE' AND f.resolved_at IS NULL
        AND f.reason LIKE '%all hard-blocked%');
  GET DIAGNOSTICS v_dead = ROW_COUNT;

  RETURN QUERY SELECT v_zero, v_dead;
END $$;

GRANT EXECUTE ON FUNCTION evidence.dqe_check_missing_source(timestamptz) TO dqe_role;
