-- HealthPlus migration: 026b — DQ-2: duplicate detection
-- Source: HP-DQE-001 Data Quality Engine — Automated Checks, §3
-- Run: DAILY incremental (new sources/claims since last run); WEEKLY full resweep.
--
-- Charter §1.8.5 names two surfaces: content_hash on evidence_source, and claim
-- equivalence within an (entity, attribute) pair -- because a duplicate is not
-- always the same document re-uploaded, it is sometimes the same fact re-asserted
-- as if it were independent corroboration. A third check follows directly from
-- the Charter's own sentence -- "duplicates are merged, never double-counted as
-- corroboration under M3" -- a testable claim about claim_source.modifier_trail.
--
-- Not yet run against a live database.

CREATE OR REPLACE FUNCTION evidence.dqe_check_duplicates(p_as_at timestamptz DEFAULT now())
RETURNS TABLE(source_dupe_pairs int, claim_dupe_pairs int, m3_violations int)
LANGUAGE plpgsql AS $$
DECLARE v_src int := 0; v_claim int := 0; v_m3 int := 0;
BEGIN
  -- ---- 2a. Source-level: identical content_hash, two live evidence_source rows ----
  WITH dupes AS (
    SELECT a.id AS source_a, b.id AS source_b, a.content_hash
      FROM evidence.evidence_source a
      JOIN evidence.evidence_source b
        ON b.content_hash = a.content_hash AND b.id > a.id
     WHERE NOT a.retracted AND NOT b.retracted
       AND a.superseded_by IS DISTINCT FROM b.id     -- a real new version isn't a duplicate
       AND b.superseded_by IS DISTINCT FROM a.id
       AND NOT EXISTS (
         SELECT 1 FROM obs.data_quality_flag f
          WHERE f.flag_kind = 'DUPLICATE' AND f.resolved_at IS NULL
            AND f.detail->>'source_a' = a.id::text AND f.detail->>'source_b' = b.id::text)
  )
  INSERT INTO obs.data_quality_flag
    (id, flag_kind, source_id, severity, reason, detected_at, detected_by, charter_clause, detail)
  SELECT gen_random_uuid(), 'DUPLICATE', d.source_a, 'WARNING',
         format('Source %s shares content_hash with source %s — same document ingested twice; merge before it can be counted as independent corroboration.',
                d.source_a, d.source_b),
         p_as_at, 'dqe_batch_v1', 'HP-ESC 1.8.5',
         jsonb_build_object('source_a', d.source_a, 'source_b', d.source_b, 'content_hash', d.content_hash)
    FROM dupes d;
  GET DIAGNOSTICS v_src = ROW_COUNT;

  -- ---- 2b. Claim-level: same (entity, attribute), equivalent statement ----
  -- Corroboration masquerading as duplication: two claim rows bound to the same
  -- domain fact, same kind, same statement/jurisdiction/population — not two
  -- independent sources agreeing, one fact recorded twice.
  WITH claim_pairs AS (
    SELECT da.entity_type, da.entity_id, da.attribute, c1.id AS claim_a, c2.id AS claim_b
      FROM evidence.domain_attribute da
      JOIN evidence.domain_attribute db
        ON db.entity_type = da.entity_type AND db.entity_id = da.entity_id
       AND db.attribute = da.attribute AND db.claim_id > da.claim_id
      JOIN evidence.claim c1 ON c1.id = da.claim_id
      JOIN evidence.claim c2 ON c2.id = db.claim_id
     WHERE c1.kind = c2.kind
       AND lower(trim(c1.statement)) = lower(trim(c2.statement))
       AND c1.jurisdiction IS NOT DISTINCT FROM c2.jurisdiction
       AND c1.population   IS NOT DISTINCT FROM c2.population
       AND NOT EXISTS (
         SELECT 1 FROM obs.data_quality_flag f
          WHERE f.flag_kind = 'DUPLICATE' AND f.resolved_at IS NULL
            AND f.detail->>'claim_a' = c1.id::text AND f.detail->>'claim_b' = c2.id::text)
  )
  INSERT INTO obs.data_quality_flag
    (id, flag_kind, entity_type, entity_id, claim_id, severity, reason, detected_at,
     detected_by, charter_clause, detail)
  SELECT gen_random_uuid(), 'DUPLICATE', cp.entity_type, cp.entity_id, cp.claim_a, 'WARNING',
         format('Claim %s duplicates claim %s on %s.%s (%s) — identical statement re-ingested as a second claim; merge, do not treat as corroboration.',
                cp.claim_a, cp.claim_b, cp.entity_type, cp.attribute, cp.entity_id),
         p_as_at, 'dqe_batch_v1', 'HP-ESC 1.8.5',
         jsonb_build_object('claim_a', cp.claim_a, 'claim_b', cp.claim_b, 'attribute', cp.attribute)
    FROM claim_pairs cp;
  GET DIAGNOSTICS v_claim = ROW_COUNT;

  -- ---- 2c. M3 audit: has corroboration credit already been paid between duplicates? ----
  -- This is the sharpest test of the Charter's own sentence: a binding whose trail
  -- shows an M3 step, where another binding on the SAME claim shares its source's
  -- content_hash, was corroborated by its own duplicate.
  WITH m3_bad AS (
    SELECT cs.claim_id, cs.source_id, es.content_hash
      FROM evidence.claim_source cs
      JOIN evidence.evidence_source es ON es.id = cs.source_id
     WHERE cs.modifier_trail @> '[{"step":"M3"}]'::jsonb
       AND EXISTS (
         SELECT 1 FROM evidence.claim_source cs2
           JOIN evidence.evidence_source es2 ON es2.id = cs2.source_id
          WHERE cs2.claim_id = cs.claim_id AND cs2.source_id <> cs.source_id
            AND es2.content_hash = es.content_hash)
       AND NOT EXISTS (
         SELECT 1 FROM obs.data_quality_flag f
          WHERE f.flag_kind = 'DUPLICATE' AND f.resolved_at IS NULL
            AND f.claim_id = cs.claim_id AND f.source_id = cs.source_id
            AND f.reason LIKE 'M3 corroboration%')
  )
  INSERT INTO obs.data_quality_flag
    (id, flag_kind, claim_id, source_id, severity, reason, detected_at, detected_by,
     charter_clause, detail)
  SELECT gen_random_uuid(), 'DUPLICATE', mb.claim_id, mb.source_id, 'CRITICAL',
         format('M3 corroboration credit was paid on claim %s using a source that duplicates (content_hash %s) another binding already on the same claim — recompute confidence without the double count.',
                mb.claim_id, left(mb.content_hash, 12)),
         p_as_at, 'dqe_batch_v1', 'HP-ESC 1.8.5',
         jsonb_build_object('content_hash', mb.content_hash)
    FROM m3_bad mb;
  GET DIAGNOSTICS v_m3 = ROW_COUNT;

  RETURN QUERY SELECT v_src, v_claim, v_m3;
END $$;

GRANT EXECUTE ON FUNCTION evidence.dqe_check_duplicates(timestamptz) TO dqe_role;
