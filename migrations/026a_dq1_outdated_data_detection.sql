-- HealthPlus migration: 026a — DQ-1: outdated-data detection and hard-expiry enforcement
-- Source: HP-DQE-001 Data Quality Engine — Automated Checks, §2
-- Run: DAILY (see HP-DQE-001 §7 for the full schedule and rationale). Scans
-- every live claim_source binding, all claim kinds, in one pass.
--
-- The half-life table is not re-derived here -- it reads evidence.claim_kind_decay,
-- seeded in HP-SCHEMA-001 migration 022 (COST 90d/180d, LEGAL_REGULATORY 180d/365d,
-- ACCREDITATION 365d/730d, CLINICAL_EFFICACY/GUIDELINE 1095d/1825d, MEDICATION
-- 180d/365d, EPIDEMIOLOGY 30d/90d). The clock is evidence_source.last_verified_at,
-- never retrieved_at (Charter §1.7.2 is explicit these differ). A claim past hard
-- expiry is made unpublishable, not merely flagged: the same hard_block mechanism
-- compute_confidence() and cascade_supersession() already use is applied directly.
--
-- Not yet run against a live database.

CREATE OR REPLACE FUNCTION evidence.dqe_check_outdated(p_as_at timestamptz DEFAULT now())
RETURNS TABLE(hard_blocked_count int, half_life_warning_count int)
LANGUAGE plpgsql AS $$
DECLARE
  v_blocked int := 0;
  v_warned  int := 0;
  v_touched uuid[];
BEGIN
  -- ---- 1a. HARD EXPIRY: §1.7.2 — enforce, don't just observe ----------------
  WITH expired AS (
    SELECT cs.claim_id, cs.source_id, cl.kind, es.last_verified_at,
           EXTRACT(EPOCH FROM (p_as_at - es.last_verified_at)) / 86400.0 AS age_days,
           d.half_life_days, d.hard_expiry_days
      FROM evidence.claim_source cs
      JOIN evidence.claim          cl ON cl.id = cs.claim_id
      JOIN evidence.evidence_source es ON es.id = cs.source_id
      JOIN LATERAL (
        SELECT d2.half_life_days, d2.hard_expiry_days
          FROM evidence.claim_kind_decay d2
         WHERE d2.kind = cl.kind AND d2.effective_from <= p_as_at
         ORDER BY d2.effective_from DESC LIMIT 1
      ) d ON true
     WHERE cs.hard_block IS NULL                      -- not already blocked by this or M7/retraction
       AND d.hard_expiry_days IS NOT NULL
       AND EXTRACT(EPOCH FROM (p_as_at - es.last_verified_at)) / 86400.0 > d.hard_expiry_days
  ),
  do_block AS (
    UPDATE evidence.claim_source cs
       SET confidence = 0.00, hard_block = 'EXPIRED', hard_blocked_at = p_as_at
      FROM expired e
     WHERE cs.claim_id = e.claim_id AND cs.source_id = e.source_id
    RETURNING cs.claim_id, cs.source_id
  ),
  do_flag AS (
    INSERT INTO obs.data_quality_flag
      (id, flag_kind, claim_id, source_id, severity, reason, detected_at, detected_by,
       charter_clause, detail)
    SELECT gen_random_uuid(), 'OUTDATED', e.claim_id, e.source_id, 'CRITICAL',
           format('%s claim last verified %s days ago; hard expiry is %s days — HARD_BLOCKED per HP-ESC 1.7.2, confidence forced to 0.00.',
                  e.kind, round(e.age_days), e.hard_expiry_days),
           p_as_at, 'dqe_batch_v1', 'HP-ESC 1.7.2',
           jsonb_build_object('kind', e.kind, 'age_days', round(e.age_days,1),
             'half_life_days', e.half_life_days, 'hard_expiry_days', e.hard_expiry_days,
             'last_verified_at', e.last_verified_at, 'action', 'HARD_BLOCKED')
      FROM expired e
    RETURNING claim_id
  )
  SELECT array_agg(DISTINCT claim_id), count(*) INTO v_touched, v_blocked FROM do_flag;

  -- a hard-blocked binding changes what the claim's stored aggregate should say —
  -- keep evidence.claim_aggregate honest rather than leaving it to the next read.
  IF v_touched IS NOT NULL THEN
    PERFORM evidence.refresh_claim_aggregate(c) FROM unnest(v_touched) AS c;
  END IF;

  -- ---- 1b. PAST HALF-LIFE, still inside hard expiry: a re-verification signal ----
  -- Not blocked — M1 recency decay already prices this into confidence at the next
  -- compute_confidence() run. This flag exists so a human queue can act BEFORE the
  -- hard-expiry cliff, not after.
  INSERT INTO obs.data_quality_flag
    (id, flag_kind, claim_id, source_id, severity, reason, detected_at, detected_by,
     charter_clause, detail)
  SELECT gen_random_uuid(), 'OUTDATED', cs.claim_id, cs.source_id, 'WARNING',
         format('%s claim last verified %s days ago, past its %s-day half-life; %s days remain before hard expiry (%s days).',
                cl.kind, round(age.days), d.half_life_days,
                round(d.hard_expiry_days - age.days), d.hard_expiry_days),
         p_as_at, 'dqe_batch_v1', 'HP-ESC 1.7.1 M1',
         jsonb_build_object('kind', cl.kind, 'age_days', round(age.days,1),
           'half_life_days', d.half_life_days, 'hard_expiry_days', d.hard_expiry_days,
           'days_to_hard_expiry', round(d.hard_expiry_days - age.days,1))
    FROM evidence.claim_source cs
    JOIN evidence.claim          cl ON cl.id = cs.claim_id
    JOIN evidence.evidence_source es ON es.id = cs.source_id
    JOIN LATERAL (
      SELECT d2.half_life_days, d2.hard_expiry_days
        FROM evidence.claim_kind_decay d2
       WHERE d2.kind = cl.kind AND d2.effective_from <= p_as_at
       ORDER BY d2.effective_from DESC LIMIT 1
    ) d ON true
    JOIN LATERAL (
      SELECT EXTRACT(EPOCH FROM (p_as_at - es.last_verified_at)) / 86400.0 AS days
    ) age ON true
   WHERE cs.hard_block IS NULL
     AND d.half_life_days IS NOT NULL
     AND age.days > d.half_life_days
     AND (d.hard_expiry_days IS NULL OR age.days <= d.hard_expiry_days)
     AND NOT EXISTS (   -- don't re-flag the same binding every day of its decline
       SELECT 1 FROM obs.data_quality_flag f
        WHERE f.claim_id = cs.claim_id AND f.source_id = cs.source_id
          AND f.flag_kind = 'OUTDATED' AND f.resolved_at IS NULL
          AND f.detected_at > p_as_at - interval '7 days');
  GET DIAGNOSTICS v_warned = ROW_COUNT;

  RETURN QUERY SELECT v_blocked, v_warned;
END $$;

GRANT EXECUTE ON FUNCTION evidence.dqe_check_outdated(timestamptz) TO dqe_role;
