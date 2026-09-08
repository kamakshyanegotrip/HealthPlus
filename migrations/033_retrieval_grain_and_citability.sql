-- ============================================================================
-- MIGRATION 033 — RETRIEVAL GRAIN AND CITABILITY  (register item R10c)
--
-- Implements HP-DR-003, approved 8 September 2026. That record decided four
-- things; building them found two more the gap table had not listed, and both
-- are Charter rendering rules rather than engineering choices:
--
--   * RetrievedClaim.citation      §1.9.1 / §1.9.5 — NO COLUMN EXISTS
--   * RetrievedClaim.confidenceBand §1.9.4         — NO COLUMN EXISTS
--
-- The stub's claim_aggregate() returned both as invented columns. The real
-- aggregate_claim() returns neither, and correctly so: the Charter
-- Reconciliation Changelog §1.3 calls the band "a derived, non-stored
-- presentation value", and §1.9.5 makes the citation a rendering of the
-- persisted source record. Neither belongs in a stored column. Both belong in
-- exactly one definition, which is what §2 and §3 below are.
--
-- ---------------------------------------------------------------------------
-- THE BUG CLASS THIS MIGRATION EXISTS TO CLOSE
--
-- knowledgeLookup.ts carries a scar: `domain` (the enum, "GUIDELINE") was
-- passed where a table name ("domain.guideline") was expected, so every
-- lookup silently returned zero rows. Its own comment calls that "the worst
-- possible failure mode — a real data gap and a wiring bug produce the
-- identical symptom."
--
-- Checked against the real registry before writing a line: FIVE OF THE NINE
-- entries in the app's DOMAIN_TABLE map do not resolve at all.
--
--   COST        hospital_cost                    -> domain.hospital_cost
--   HOSPITAL    hospital_profile                 -> domain.hospital
--   ENVIRONMENT domain.environment_reference     -> domain.environment
--   EXERCISE    domain.exercise_guidance         -> does not exist, any spelling
--   MONITORING  domain.clinical_metric_reference -> does not exist, any spelling
--
-- The same bug, five times over, sitting latent behind the cutover. So
-- claim_search does not merely filter on the entity types it is given — §4
-- RAISES on an unknown one. A wiring mistake now fails loudly. That is the
-- whole point of the function being plpgsql rather than sql.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- §1  TIER LABELS AS REFERENCE DATA (§1.9.2)
--
-- §1.9.2: "Tier labels are shown to users in plain language, not as TIER_n."
-- The labels it gives are marked "Proposed" and carry ⚑ AMB-08, which is open
-- (Open Items Register §10, P1).
--
-- So they go in a table with an adoption_state, exactly as tier_default
-- carries one. Three consequences, and the third is the reason:
--
--   * The citation renderer never hardcodes a user-facing string.
--   * Closing AMB-08 is an UPDATE, not a code change and a redeploy.
--   * The proposed-ness is visible in the data rather than lost in a comment,
--     so nobody later mistakes these for adopted copy.
-- ---------------------------------------------------------------------------
CREATE TABLE evidence.tier_label (
  tier            source_tier PRIMARY KEY,
  label           text        NOT NULL,
  adoption_state  text        NOT NULL,
  charter_clause  text        NOT NULL,
  effective_from  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT c_tier_label_adoption
    CHECK (adoption_state IN ('PROPOSED', 'ADOPTED', 'WITHDRAWN')),
  -- A label a user sees must not be empty or a bare enum leak.
  CONSTRAINT c_tier_label_not_enum
    CHECK (length(btrim(label)) > 0 AND label NOT LIKE 'TIER\_%')
);

INSERT INTO evidence.tier_label (tier, label, adoption_state, charter_clause) VALUES
  ('TIER_1', 'Official / regulatory', 'PROPOSED', 'HP-ESC §1.9.2 ⚑AMB-08'),
  ('TIER_2', 'Clinical guideline',    'PROPOSED', 'HP-ESC §1.9.2 ⚑AMB-08'),
  ('TIER_3', 'Published research',    'PROPOSED', 'HP-ESC §1.9.2 ⚑AMB-08'),
  ('TIER_4', 'Provider-supplied',     'PROPOSED', 'HP-ESC §1.9.2 ⚑AMB-08'),
  ('TIER_5', 'General web',           'PROPOSED', 'HP-ESC §1.9.2 ⚑AMB-08');

COMMENT ON TABLE evidence.tier_label IS
  'User-facing tier labels (§1.9.2). PROPOSED until AMB-08 closes; update the '
  'rows, do not edit render_citation().';

-- ---------------------------------------------------------------------------
-- §2  THE CONFIDENCE BAND (§1.9.4)
--
-- One definition, in the database, because two callers already need it
-- (synthesis.ts puts it in the model prompt; clinicalReasoning.ts puts it in
-- another) and a band that differs between the prompt and the audit is worse
-- than no band at all.
--
-- IMMUTABLE: it is arithmetic on one number. The boundaries are §1.9.4's,
-- reconciling Arch.docx §38's three labels with the Charter's four:
--
--     >= 0.85  High           publishable
--     0.65-0.84 Medium        publishable
--     0.40-0.64 Low           publishable, with explicit uncertainty
--     <  0.40  Insufficient   NOT published as an assertion under §2
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION evidence.confidence_band(p_confidence numeric)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN p_confidence IS NULL  THEN 'Insufficient'
    WHEN p_confidence >= 0.85  THEN 'High'
    WHEN p_confidence >= 0.65  THEN 'Medium'
    WHEN p_confidence >= 0.40  THEN 'Low'
    ELSE 'Insufficient'
  END;
$$;

COMMENT ON FUNCTION evidence.confidence_band(numeric) IS
  'HP-ESC §1.9.4. NULL maps to Insufficient deliberately: an absent '
  'confidence is not a low one, and both are unpublishable, so the '
  'fail-closed answer is the same.';

-- ---------------------------------------------------------------------------
-- §3  CITATION RENDERING (§1.9.1, §1.9.5, §1.3.4)
--
-- §1.9.5: "A citation MUST NOT be generated, completed, reformatted, or
-- 'tidied' by the model. Citation strings are rendered from the persisted
-- source record. Model-authored citations are a fabrication class under §3.9."
--
-- That makes this a SAFETY control, not a formatting helper, and it is why it
-- lives in SQL rather than in TypeScript: a control that each caller
-- re-implements is a control that each caller can get wrong. There is one
-- renderer, and every path that shows a citation goes through it.
--
-- §1.9.1 requires: source title, publisher, tier label, publication/revision
-- date, and URL or DOI.
--
-- §1.3.4 requires that a preprint carry "preprint — not peer reviewed" in any
-- surfaced citation. That is enforced here rather than left to the composer,
-- for the same reason as above.
--
-- Returns NULL when the source does not exist. A NULL citation must be treated
-- by callers as "this claim cannot be surfaced" — §1.9.1 makes the citation
-- mandatory for a surfaced claim, so a claim without one is not publishable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION evidence.render_citation(p_source uuid)
RETURNS text LANGUAGE sql STABLE
SET search_path = pg_catalog, evidence, public
AS $$
  SELECT
    -- title — publisher — tier label — date — locator
    concat_ws(' — ',
      nullif(btrim(es.title), ''),
      nullif(btrim(es.publisher), ''),
      tl.label,
      -- §1.9.1 "publication/revision date": the revision is the more honest
      -- of the two when both exist, because it is what the text currently
      -- says rather than when it first appeared.
      to_char(coalesce(es.effective_at, es.published_at), 'FMDD Mon YYYY'),
      coalesce(nullif(btrim(es.doi), ''), nullif(btrim(es.url), ''))
    )
    -- §1.3.4. Appended rather than interpolated so it cannot be lost if the
    -- field order above ever changes.
    || CASE
         WHEN es.tier = 'TIER_5' AND es.source_type ILIKE '%preprint%'
           THEN ' (preprint — not peer reviewed)'
         ELSE ''
       END
    -- §1.4.2/§1.4.4: Tier 4 is self-reported by a party with a direct
    -- commercial interest in the user's decision. The Charter calls that the
    -- defining property of the tier; a citation that does not say so is
    -- letting the reader assume otherwise.
    || CASE WHEN es.tier = 'TIER_4' THEN ' (self-reported by provider)' ELSE '' END
    FROM evidence.evidence_source es
    JOIN evidence.tier_label tl ON tl.tier = es.tier
   WHERE es.id = p_source;
$$;

-- ---------------------------------------------------------------------------
-- §4  claim_search — HYBRID RETRIEVAL AT CHUNK GRAIN, RESOLVED TO CLAIMS
--
-- HP-DR-003 §2 Option B, approved: COLLAPSE FIRST, THEN FUSE. For each ranker
-- independently, take each claim's best-ranked chunk, and fuse those per-claim
-- ranks with Reciprocal Rank Fusion.
--
-- Why, in one line: chunk count is an artefact of the chunker, not of evidence
-- quality. Under the alternative, a long repetitive Tier 4 marketing document
-- chunks into many near-identical passages and can outrank a Tier 1 guideline
-- that says the same thing once. §1.4.4 caps Tier 4 CONFIDENCE; it does not
-- cap Tier 4 RANK. This closes that by construction.
--
-- THE EMBEDDING IS AN ARGUMENT, NOT A COMPUTATION.
-- Postgres cannot embed text; the application holds the model. Passing NULL
-- gives full-text-only retrieval, which is a real degradation and the caller
-- is expected to know it has done so — it is not a silent fallback, because
-- the caller chose it.
--
-- source_id IS THE SOURCE OF THE BEST-RANKED CHUNK, deliberately. §3.9.2 says
-- a UUID not retrieved for THIS response is fabrication. The passage actually
-- retrieved is the chunk, so the source that gets cited is that chunk's
-- source, not an arbitrary one of the claim's several.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION evidence.claim_search(
  p_query           text,
  p_entity_types    text[],
  p_query_embedding vector(384) DEFAULT NULL,
  p_limit           integer     DEFAULT 12
)
RETURNS TABLE (claim_id uuid, source_id uuid, rank numeric)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, evidence, public
AS $$
DECLARE
  unknown text[];
BEGIN
  -- THE GUARD THIS FUNCTION EXISTS FOR.
  -- An entity type that does not exist would filter to zero rows and return an
  -- empty set, which reads as "no evidence on this topic" — indistinguishable
  -- from a real data gap. That is the exact failure knowledgeLookup.ts already
  -- carries a scar from, and five of the nine mappings were wrong when this
  -- was written. A wiring bug must not be able to look like an answer.
  SELECT array_agg(t.et) INTO unknown
    FROM unnest(coalesce(p_entity_types, '{}')) AS t(et)
   WHERE NOT EXISTS (
     SELECT 1 FROM evidence.domain_entity_type d WHERE d.entity_type = t.et);

  IF unknown IS NOT NULL AND cardinality(unknown) > 0 THEN
    RAISE EXCEPTION
      'claim_search: unknown entity_type(s) %; not present in evidence.domain_entity_type',
      unknown
      USING HINT = 'The application''s domain map has drifted from the registry. '
                   'This is a wiring bug, not an empty result — see migration 033 §4.';
  END IF;

  IF p_entity_types IS NULL OR cardinality(p_entity_types) = 0 THEN
    RAISE EXCEPTION 'claim_search: no entity types given'
      USING HINT = 'An unscoped search would range over every domain at once.';
  END IF;

  RETURN QUERY
  WITH scoped AS (
    -- HP-DR-003 §5: scope through the registry, FK-governed, not through a
    -- free-text column a claim could carry a typo in.
    SELECT DISTINCT da.claim_id
      FROM evidence.domain_attribute da
     WHERE da.entity_type = ANY(p_entity_types)
       AND da.claim_id IS NOT NULL
  ),
  chunks AS (
    -- HP-DR-003 §3, approved: retrieval REQUIRES a claim anchor.
    -- A source-anchored or entity-anchored chunk has no claim_source row, so
    -- it has no confidence and no policy disposition, and policy_for has
    -- nothing to gate. Admitting it would put text in front of the composer
    -- that the §3.0.3 default-deny gate cannot evaluate — the exact hole that
    -- gate exists to close.
    -- DO NOT REMOVE THIS PREDICATE. Those chunks are the input to claim
    -- EXTRACTION, which is the ingestion job's business, not retrieval's.
    SELECT rc.claim_id AS cid, rc.source_id AS sid, rc.tsv, rc.embedding
      FROM evidence.retrieval_chunk rc
      JOIN scoped s ON s.claim_id = rc.claim_id
     WHERE rc.claim_id IS NOT NULL
  ),
  -- ---- ranker 1: full text -------------------------------------------------
  -- 'simple', not 'english': retrieval_chunk.tsv is GENERATED ALWAYS AS
  -- to_tsvector('simple', body). A query parsed with a different
  -- configuration matches nothing, silently. Checked, not assumed.
  fts_hits AS (
    SELECT c.cid, c.sid,
           ts_rank_cd(c.tsv, websearch_to_tsquery('simple', p_query)) AS score
      FROM chunks c
     WHERE p_query IS NOT NULL
       AND btrim(p_query) <> ''
       AND c.tsv @@ websearch_to_tsquery('simple', p_query)
  ),
  fts_best AS ( -- collapse: each claim's strongest passage, per DR-003 §2
    SELECT DISTINCT ON (h.cid) h.cid, h.sid, h.score
      FROM fts_hits h ORDER BY h.cid, h.score DESC, h.sid
  ),
  fts_ranked AS (
    SELECT b.cid, b.sid, row_number() OVER (ORDER BY b.score DESC, b.cid) AS rnk
      FROM fts_best b
  ),
  -- ---- ranker 2: vector ----------------------------------------------------
  vec_hits AS (
    SELECT c.cid, c.sid, (c.embedding <=> p_query_embedding) AS dist
      FROM chunks c
     WHERE p_query_embedding IS NOT NULL
       AND c.embedding IS NOT NULL
  ),
  vec_best AS ( -- collapse, same rule
    SELECT DISTINCT ON (v.cid) v.cid, v.sid, v.dist
      FROM vec_hits v ORDER BY v.cid, v.dist ASC, v.sid
  ),
  vec_ranked AS (
    SELECT b.cid, b.sid, row_number() OVER (ORDER BY b.dist ASC, b.cid) AS rnk
      FROM vec_best b
  )
  -- ---- fuse ----------------------------------------------------------------
  -- RRF with k = 60, the standard constant: it damps the difference between
  -- the top few positions so one ranker cannot dominate on a single hit.
  SELECT
    coalesce(f.cid, v.cid) AS claim_id,
    -- Prefer the full-text ranker's source when both fired: it is the passage
    -- whose literal wording matched, which is the more defensible thing to
    -- cite under §3.9.2 than a nearest-neighbour.
    coalesce(f.sid, v.sid) AS source_id,
    round(
      coalesce(1.0 / (60 + f.rnk), 0)::numeric
    + coalesce(1.0 / (60 + v.rnk), 0)::numeric, 8) AS rank
    FROM fts_ranked f
    FULL OUTER JOIN vec_ranked v ON v.cid = f.cid
   ORDER BY rank DESC, claim_id
   LIMIT greatest(coalesce(p_limit, 12), 1);
END;
$$;

COMMENT ON FUNCTION evidence.claim_search(text, text[], vector, integer) IS
  'HP-DR-003 §2 Option B (collapse chunks to claims per ranker, then fuse), '
  '§3 (claim anchor required), §5 (scope via the registry). Raises on an '
  'unknown entity_type rather than returning zero rows — see migration 033 §4.';

-- ---------------------------------------------------------------------------
-- §5  GRANTS
--
-- reasoner_role is the role that runs retrieval. Least privilege: EXECUTE on
-- the three functions and SELECT on the one new reference table, nothing more.
-- R13's rule A will confirm the schema USAGE is real rather than nominal.
-- ---------------------------------------------------------------------------
GRANT SELECT ON evidence.tier_label TO reasoner_role;
GRANT EXECUTE ON FUNCTION evidence.claim_search(text, text[], vector, integer) TO reasoner_role;
GRANT EXECUTE ON FUNCTION evidence.render_citation(uuid)                       TO reasoner_role;
GRANT EXECUTE ON FUNCTION evidence.confidence_band(numeric)                    TO reasoner_role;

COMMIT;
