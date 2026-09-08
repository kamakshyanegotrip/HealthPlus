-- ============================================================================
-- MIGRATION — support tables/functions this pipeline needs that are implied
-- by existing project docs but have no committed DDL yet. Each block below
-- documents exactly which doc implies it and what's still an open decision.
-- Run after db/000_stub_upstream.sql (or the real committed migrations).
--
-- NONE of the new tables here are pre-adopted. Every reference table below
-- follows the project's existing adoption pattern (PROVISIONAL until a named
-- reviewer signs it — see AMB-CGM-2-4_Signoff_Package's restriction_kind_ref
-- / country_guideline_reverify_schedule precedent) rather than defaulting to
-- ADOPTED, because §6.3 change control applies to all of these just as it
-- does to claim_policy.
-- ============================================================================

CREATE TYPE adoption_state AS ENUM ('PROVISIONAL', 'ADOPTED', 'REJECTED');

-- ---- 1. obs.model_pricing — makes "cost" a durable, queryable fact --------
-- Closes the gap flagged in src/lib/pricing.ts: obs.ai_call has no cost
-- column by design (cost is derived, not a fact about the call — see that
-- file's comment), and a hard-coded pricing constant in application code
-- can't go through §6.3 change control the way a reference table can (same
-- reasoning Annex A.7 gives for tier_default living in a table, not code).
CREATE TABLE obs.model_pricing (
  model_version        text NOT NULL,
  input_usd_per_mtok    numeric(10,4) NOT NULL,
  output_usd_per_mtok   numeric(10,4) NOT NULL,
  effective_from        timestamptz NOT NULL,
  adoption_state        adoption_state NOT NULL DEFAULT 'PROVISIONAL',
  adopted_version       text,
  adopted_by            uuid,
  reviewed_at           timestamptz,
  source_note           text NOT NULL,   -- where the rate came from (vendor pricing page, ADR, etc.)
  PRIMARY KEY (model_version, effective_from)
);

-- Seeded PROVISIONAL from HP-ADR-001 §3.6's published rate table. Needs the
-- same sign-off pass AMB-CGM-2-4 gave restriction_kind_ref before treated
-- as authoritative for billing/finance use — fine to read for the observability
-- use case (per-call estimated cost logging) while still PROVISIONAL, since
-- nothing here gates publication the way claim_policy does.
INSERT INTO obs.model_pricing (model_version, input_usd_per_mtok, output_usd_per_mtok, effective_from, source_note) VALUES
  ('claude-haiku-4-5',  1, 5,  '2026-08-01T00:00:00Z', 'HP-ADR-001 §3.6'),
  ('claude-sonnet-5',   2, 10, '2026-08-01T00:00:00Z', 'HP-ADR-001 §3.6'),
  ('claude-opus-5',     5, 25, '2026-08-01T00:00:00Z', 'HP-ADR-001 §3.6');

-- Durable, queryable cost per ai_call row. LEFT JOIN + closest-effective-from
-- rather than an inner join, so a call logged under a model with no pricing
-- row yet still shows up (cost NULL) instead of silently vanishing from
-- cost dashboards — an unpriced model is a data gap to notice, not to hide.
CREATE OR REPLACE VIEW obs.ai_call_cost AS
SELECT
  c.id AS ai_call_id,
  c.audit_id,
  c.purpose,
  c.model_version,
  c.input_tokens,
  c.output_tokens,
  c.occurred_at,
  p.input_usd_per_mtok,
  p.output_usd_per_mtok,
  CASE WHEN p.model_version IS NULL THEN NULL
       ELSE round(
         (c.input_tokens::numeric  / 1000000) * p.input_usd_per_mtok +
         (c.output_tokens::numeric / 1000000) * p.output_usd_per_mtok,
       6)
  END AS estimated_cost_usd
FROM obs.ai_call c
LEFT JOIN LATERAL (
  SELECT * FROM obs.model_pricing mp
   WHERE mp.model_version = c.model_version AND mp.effective_from <= c.occurred_at
   ORDER BY mp.effective_from DESC LIMIT 1
) p ON true;

GRANT SELECT ON obs.model_pricing, obs.ai_call_cost TO hp_app, hp_reader;

-- ---- 2. safety.red_flag_rule / safety.safety_template ---------------------
-- Read by redFlagEngine.ts / loadSafetyTemplate. AMB-17 (clinical sign-off
-- on §4 severities/triggers/templates) is the Open Items Register's own
-- named blocker for this content — clinically_adopted defaults false here
-- for exactly that reason. Ships empty; matchDeterministicRules() and
-- loadSafetyTemplate() both already fail safe (severity NORMAL / hard-coded
-- fallback message) when no rows match, so an empty table is a safe, not a
-- broken, starting state.
-- R2/R3 RECONCILIATION (2 Sep 2026): both tables below now carry the REAL
-- committed shape from migrations/001_003 + 012, not a reconstruction of it.
-- Before this, three columns differed in ways that broke the engine against
-- the shipping schema (HP-RECON-001 §2, §3):
--
--   pattern was `text` holding a Postgres regex; the real column is `jsonb`
--   holding a structured pattern. A regex cannot express "temp >= 38 degC"
--   without also matching 38 degF, and §3.5.3 forbids converting between
--   units without a sourced factor. See src/lib/pipeline/rulePattern.ts.
--
--   red_flag_rule carried template_id/template_version. The real table does
--   not: a template is resolved by (severity, jurisdiction, language) through
--   §4.3.3's fallback ladder, not by a foreign key from the rule.
--
--   safety_template had `active` and no severity/jurisdiction/language/slots,
--   so loadSafetyTemplate()'s `AND active = true` raised against the real
--   schema and its catch silently served the unapproved hard-coded fallback.
--
-- What still differs, and why: no `principal.clinician` or
-- `safety.clinical_domain` table exists in this stub, so approved_by /
-- adopted_by / clinical_domain are plain columns rather than FKs. The
-- adoption columns (clinically_adopted / adopted_by / adopted_at) come from
-- migration 012 and are real.

-- §4.0.3 / §6.4: rules are versioned as a SET, because recall is a property of
-- the set rather than of any rule in it.
CREATE TABLE safety.red_flag_rule_set (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_label    text NOT NULL,
  jurisdiction     char(2),
  language         text NOT NULL,
  approved_by      uuid NOT NULL,          -- real: FK principal.clinician(user_id)
  approved_at      timestamptz NOT NULL,
  effective_from   timestamptz NOT NULL,
  superseded_by    uuid REFERENCES safety.red_flag_rule_set(id),
  retired_at       timestamptz,
  gold_set_version text,                   -- §6.4: what it was validated against
  recall_floor     numeric(4,3),           -- §4.0.3 published recall floor
  UNIQUE (version_label, jurisdiction, language),
  CONSTRAINT c_set_not_self_supersede CHECK (superseded_by IS DISTINCT FROM id)
);

CREATE TABLE safety.red_flag_rule (
  id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  version            int NOT NULL DEFAULT 1,
  -- §4.0.3 "pattern, keyword and structured-symptom rules". Structured, not a
  -- regex: parsed and evaluated by src/lib/pipeline/rulePattern.ts.
  pattern            jsonb NOT NULL,
  severity           red_flag_severity NOT NULL,
  rationale          text,                 -- what the rule is meant to catch, for the reviewing clinician
  approved_by        uuid NOT NULL,        -- real: FK principal.clinician(user_id)
  approved_at        timestamptz NOT NULL,
  retired_at         timestamptz,
  rule_set_id        uuid REFERENCES safety.red_flag_rule_set(id),
  clinical_domain    text,                 -- real: FK safety.clinical_domain(code)
  jurisdiction       char(2),
  -- §0.6 / AMB-17: a rule that has not been signed must not be able to fire.
  clinically_adopted boolean NOT NULL DEFAULT false,
  adopted_by         uuid,
  adopted_at         timestamptz,
  PRIMARY KEY (id, version),
  CONSTRAINT c_adoption_attributed CHECK (
    clinically_adopted = false OR (adopted_by IS NOT NULL AND adopted_at IS NOT NULL)
  )
);
CREATE INDEX idx_red_flag_rule_live ON safety.red_flag_rule (rule_set_id)
  WHERE clinically_adopted AND retired_at IS NULL;

CREATE TABLE safety.safety_template (
  id                 uuid NOT NULL,
  version            int NOT NULL DEFAULT 1,
  severity           red_flag_severity NOT NULL,
  jurisdiction       text NOT NULL,
  language           text NOT NULL,
  body               text NOT NULL,
  -- §4.3.2: the declared, typed slots. Nothing outside this list may be
  -- substituted into the body.
  slots              jsonb NOT NULL DEFAULT '[]'::jsonb,
  approved_by        uuid NOT NULL,        -- real: FK principal.clinician(user_id)
  approved_at        timestamptz NOT NULL,
  rule_set_id        uuid REFERENCES safety.red_flag_rule_set(id),
  is_fallback        boolean NOT NULL DEFAULT false,
  machine_translated boolean NOT NULL DEFAULT false,
  -- NO clinically_adopted/adopted_by/adopted_at here, deliberately. The real
  -- safety_template has none: migration 012 adds the adoption columns to
  -- red_flag_rule only, and approval of a TEMPLATE is expressed by
  -- approved_by/approved_at being NOT NULL. An earlier draft of this table
  -- invented them, and the resolver then filtered on clinically_adopted —
  -- which is the same shape of bug as the `active = true` predicate that made
  -- every emergency render an unapproved fallback (HP-RECON-001 §2).
  PRIMARY KEY (id, version),
  UNIQUE (severity, jurisdiction, language, version),
  -- §4.3.4: an untranslated template falls back to the approved English one
  -- plus the local emergency number, never to machine translation of
  -- safety-critical text.
  CONSTRAINT c_no_mt_safety_text CHECK (machine_translated = false)
);

-- §0.6 / AMB-17, mirroring migrations/027. Zero rows means nothing is signed to
-- run, and the engine refuses generative output rather than reporting NORMAL.
-- Defined here as well as there so ONE code path serves both schemas.
CREATE OR REPLACE FUNCTION safety.adopted_rule_set(
  p_jurisdiction char(2),
  p_language     text
) RETURNS TABLE (rule_set_id uuid, version_label text, recall_floor numeric(4,3), adopted_rules bigint)
LANGUAGE sql STABLE AS $$
  SELECT rs.id, rs.version_label, rs.recall_floor, count(r.id)
  FROM safety.red_flag_rule_set rs
  JOIN safety.red_flag_rule r
    ON r.rule_set_id = rs.id AND r.clinically_adopted AND r.retired_at IS NULL
  WHERE rs.retired_at IS NULL
    AND rs.superseded_by IS NULL
    AND rs.effective_from <= now()
    AND (rs.jurisdiction = p_jurisdiction OR rs.jurisdiction IS NULL)
    AND rs.language = p_language
  GROUP BY rs.id, rs.version_label, rs.recall_floor
  HAVING count(r.id) > 0
  ORDER BY rs.jurisdiction NULLS LAST, rs.effective_from DESC
  LIMIT 1;
$$;

-- BUG FOUND RUNNING scripts/smoke-test.mjs (R3 follow-up, 4 Sep 2026):
-- safety.adopted_rule_set() is LANGUAGE sql STABLE, i.e. invoker's rights, so
-- it reads red_flag_rule_set as whoever called it — hp_app, which had no grant
-- on that table. Every call to matchDeterministicRules would therefore have
-- raised "permission denied for table red_flag_rule_set", been caught by its
-- own try/catch, and returned adoptionGate = FAIL_CLOSED with
-- lookupFailed: true. The red-flag module would have been permanently
-- unavailable in production while every unit test stayed green, because the
-- unit tests inject a fake repository and never touch a role.
--
-- red_flag_rule_set is SELECT-only for both roles: rule sets are authored and
-- adopted by clinicians through a path that is not this application.
GRANT SELECT ON safety.red_flag_rule_set, safety.red_flag_rule, safety.safety_template
  TO hp_app, hp_reader;
GRANT EXECUTE ON FUNCTION safety.adopted_rule_set(char, text) TO hp_app, hp_reader;

-- ---- 3. subject_key (HP-SCHEMA-001 §17.1, LAYER 3) -------------------------
-- Referenced by response_content.key_id in the already-committed ADR-003
-- design but never given DDL. Minimal version: one active key per subject,
-- with rotation modeled as a new row + the old row's revoked_at set — never
-- an UPDATE of key material in place, so a compromised-key rotation is
-- itself auditable. Erasure (HP-LB-001) is destroying every row for a
-- subject_id, which is what makes response_content's ciphertext
-- unrecoverable without needing to touch response_content itself.
CREATE TABLE subject_key (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_id   uuid NOT NULL REFERENCES app_user(id),
  key_material bytea NOT NULL,   -- envelope-encrypted under a KMS key in any real deployment; plaintext here for a local stub only
  created_at   timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz,
  UNIQUE (subject_id, revoked_at)
);
CREATE INDEX idx_subject_key_active ON subject_key (subject_id) WHERE revoked_at IS NULL;

ALTER TABLE response_content ADD CONSTRAINT fk_response_content_key
  FOREIGN KEY (key_id) REFERENCES subject_key(id);

GRANT SELECT, INSERT ON subject_key TO hp_app;

-- ---- 4. side_effect_job — durable queue for sideEffectDispatcher.ts -------
-- HP-ADR-001 §3.2's "Postgres-backed queueing... transactional enqueue"
-- pattern (chosen over n8n) applied to post-response side effects, not just
-- ingestion. No worker consuming this is included — this is the producer
-- side only.
CREATE TYPE side_effect_job_status AS ENUM ('PENDING', 'IN_PROGRESS', 'DONE', 'FAILED');

CREATE TABLE side_effect_job (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind         text NOT NULL,
  payload      jsonb NOT NULL,
  data_region  char(2) NOT NULL REFERENCES public.region_registry(code),
  enqueued_at  timestamptz NOT NULL,
  started_at   timestamptz,
  finished_at  timestamptz,
  attempts     int NOT NULL DEFAULT 0,
  status       side_effect_job_status NOT NULL DEFAULT 'PENDING'
);
CREATE INDEX idx_side_effect_job_pending ON side_effect_job (enqueued_at) WHERE status = 'PENDING';

GRANT SELECT, INSERT, UPDATE ON side_effect_job TO hp_app;
-- ---- 5/6. RETRIEVAL, PORTED TO THE REAL GRAIN (R10c / HP-DR-003) -----------
--
-- REPLACES the old `evidence.claim_aggregate(claim_id, category)` and
-- `claim_search(query, domain_table)`. Both were stub inventions, and both
-- encoded the wrong grain: they retrieved on `evidence.claim.search_tsv` and
-- filtered on `evidence.claim.domain_table`, neither of which exists in the
-- shipping schema. HP-RECON-002 §3 recorded the divergence; migration 033
-- closes it; this section keeps the double able to accept the same calls.
--
-- STAND-IN DIFFERENCES, stated rather than left to be discovered:
--
--  * The function BODIES below are copied from migrations/033 rather than
--    shared with it, because a stub cannot import a migration. That is a real
--    drift risk and it is why both sides are tested: the real ones by
--    migrations/test/r10c_retrieval.sh, these by
--    test/runPipeline.integration.test.ts. IF YOU CHANGE ONE, CHANGE BOTH.
--  * evidence.retrieval_chunk here drops embedding_model/embedded_at and
--    makes `embedding` nullable — this stub has no embedding pipeline, and a
--    NOT NULL column with nothing to put in it forces every test fixture to
--    invent a vector. The real table keeps them NOT NULL.
--  * domain_attribute here has no FK to domain_attribute_kind and no
--    cardinality trigger. Those enforce §1.3.7's single-study prohibition,
--    which is the DQE's business and not the pipeline's; the real schema
--    enforces it and this stub deliberately does not pretend to.
-- ---------------------------------------------------------------------------

-- The registry that replaced `claim.domain_table`. FK-governed, so a claim
-- cannot be bound to a domain that does not exist — the fix for the bug class
-- where an enum value was passed where a table name was expected and every
-- lookup silently returned zero rows.
CREATE TABLE evidence.domain_entity_type (
  entity_type  text PRIMARY KEY,
  schema_name  text NOT NULL,
  table_name   text NOT NULL
);

-- Only the entity types the pipeline's own map names. The real registry has
-- ~100; seeding all of them here would be inventing content.
INSERT INTO evidence.domain_entity_type (entity_type, schema_name, table_name) VALUES
  ('nutrition_pattern','domain','nutrition_pattern'),
  ('activity_recommendation','domain','activity_recommendation'),
  ('activity_precaution','domain','activity_precaution'),
  ('lifestyle_screening_tool','domain','lifestyle_screening_tool'),
  ('reference_value','domain','reference_value'),
  ('clinical_indicator','domain','clinical_indicator'),
  ('hospital_cost','domain','hospital_cost'),
  ('hospital','domain','hospital'),
  ('medical_visa','domain','medical_visa'),
  ('regulation','domain','regulation'),
  ('environment','domain','environment'),
  ('guideline','domain','guideline');

CREATE TABLE evidence.domain_attribute (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type text NOT NULL REFERENCES evidence.domain_entity_type(entity_type),
  entity_id   uuid NOT NULL,
  attribute   text NOT NULL,
  claim_id    uuid REFERENCES evidence.claim(id),
  UNIQUE (entity_type, entity_id, attribute, claim_id)
);

-- Retrieval moved to chunk grain. A claim may have many chunks; a chunk may
-- anchor to a claim, a source, or a domain entity. Both rankers hang off here.
CREATE TABLE evidence.retrieval_chunk (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type   text REFERENCES evidence.domain_entity_type(entity_type),
  entity_id     uuid,
  claim_id      uuid REFERENCES evidence.claim(id) ON DELETE CASCADE,
  source_id     uuid REFERENCES evidence.evidence_source(id),
  chunk_ordinal integer NOT NULL DEFAULT 0,
  body          text NOT NULL,
  language      text NOT NULL DEFAULT 'en',
  embedding     vector(384),          -- STAND-IN: nullable here, NOT NULL in real
  tsv           tsvector GENERATED ALWAYS AS (to_tsvector('simple', body)) STORED,
  CONSTRAINT c_chunk_anchored
    CHECK (claim_id IS NOT NULL OR source_id IS NOT NULL
           OR (entity_type IS NOT NULL AND entity_id IS NOT NULL))
);
CREATE INDEX idx_stub_chunk_tsv ON evidence.retrieval_chunk USING gin (tsv);

-- §1.9.2 tier labels as reference data. PROPOSED until AMB-08 closes.
CREATE TABLE evidence.tier_label (
  tier           source_tier PRIMARY KEY,
  label          text NOT NULL,
  adoption_state text NOT NULL,
  CONSTRAINT c_tier_label_not_enum
    CHECK (length(btrim(label)) > 0 AND label NOT LIKE 'TIER\_%')
);
INSERT INTO evidence.tier_label (tier, label, adoption_state) VALUES
  ('TIER_1','Official / regulatory','PROPOSED'),
  ('TIER_2','Clinical guideline',   'PROPOSED'),
  ('TIER_3','Published research',   'PROPOSED'),
  ('TIER_4','Provider-supplied',    'PROPOSED'),
  ('TIER_5','General web',          'PROPOSED');

-- §1.9.4. IDENTICAL TO migrations/033 §2.
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

-- §1.9.1/§1.9.5/§1.3.4/§1.4.2. IDENTICAL TO migrations/033 §3.
CREATE OR REPLACE FUNCTION evidence.render_citation(p_source uuid)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT concat_ws(' — ',
      nullif(btrim(es.title), ''),
      nullif(btrim(es.publisher), ''),
      tl.label,
      to_char(coalesce(es.effective_at, es.published_at), 'FMDD Mon YYYY'),
      coalesce(nullif(btrim(es.doi), ''), nullif(btrim(es.url), ''))
    )
    || CASE WHEN es.tier = 'TIER_5' AND es.source_type ILIKE '%preprint%'
              THEN ' (preprint — not peer reviewed)' ELSE '' END
    || CASE WHEN es.tier = 'TIER_4' THEN ' (self-reported by provider)' ELSE '' END
    FROM evidence.evidence_source es
    JOIN evidence.tier_label tl ON tl.tier = es.tier
   WHERE es.id = p_source;
$$;

-- Replaces the stub's claim_aggregate(claim_id, category). The real
-- aggregate_claim takes NO category: HP-DR-003 §4 made policy_for the single
-- category gate, so aggregation is a property of the claim alone.
CREATE OR REPLACE FUNCTION evidence.aggregate_claim(p_claim uuid)
RETURNS TABLE (agg_confidence numeric, source_count smallint, min_tier smallint, best_tier smallint)
LANGUAGE sql STABLE AS $$
  -- STAND-IN: the real schema has evidence.tier_ordinal(); this stub does not,
  -- so the ordinal comes from the enum label. Same values, no new function.
  SELECT min(cs.confidence)::numeric,
         count(*)::smallint,
         min(right(es.tier::text, 1)::smallint)::smallint,
         max(right(es.tier::text, 1)::smallint)::smallint
    FROM evidence.claim_source cs
    JOIN evidence.evidence_source es ON es.id = cs.source_id
   WHERE cs.claim_id = p_claim AND es.retracted = false
  HAVING count(*) > 0;
$$;

-- HP-DR-003 §2 Option B, §3, §5. IDENTICAL IN BEHAVIOUR TO migrations/033 §4,
-- including the guard: an unknown entity type RAISES rather than filtering to
-- zero rows, because a wiring bug must not be able to look like an answer.
CREATE OR REPLACE FUNCTION evidence.claim_search(
  p_query text, p_entity_types text[],
  p_query_embedding vector(384) DEFAULT NULL, p_limit integer DEFAULT 12)
RETURNS TABLE (claim_id uuid, source_id uuid, rank numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE unknown text[];
BEGIN
  SELECT array_agg(t.et) INTO unknown
    FROM unnest(coalesce(p_entity_types,'{}')) AS t(et)
   WHERE NOT EXISTS (SELECT 1 FROM evidence.domain_entity_type d WHERE d.entity_type = t.et);
  IF unknown IS NOT NULL AND cardinality(unknown) > 0 THEN
    RAISE EXCEPTION 'claim_search: unknown entity_type(s) %; not present in evidence.domain_entity_type', unknown
      USING HINT = 'The application''s domain map has drifted from the registry.';
  END IF;
  IF p_entity_types IS NULL OR cardinality(p_entity_types) = 0 THEN
    RAISE EXCEPTION 'claim_search: no entity types given';
  END IF;

  RETURN QUERY
  WITH scoped AS (
    SELECT DISTINCT da.claim_id FROM evidence.domain_attribute da
     WHERE da.entity_type = ANY(p_entity_types) AND da.claim_id IS NOT NULL
  ),
  chunks AS (   -- DR-003 §3: a claim anchor is required. DO NOT REMOVE.
    SELECT rc.claim_id cid, rc.source_id sid, rc.tsv, rc.embedding
      FROM evidence.retrieval_chunk rc JOIN scoped s ON s.claim_id = rc.claim_id
     WHERE rc.claim_id IS NOT NULL
  ),
  fts_hits AS (
    SELECT c.cid, c.sid, ts_rank_cd(c.tsv, websearch_to_tsquery('simple', p_query)) score
      FROM chunks c
     WHERE p_query IS NOT NULL AND btrim(p_query) <> ''
       AND c.tsv @@ websearch_to_tsquery('simple', p_query)
  ),
  fts_best AS (  -- DR-003 §2: collapse to the claim's best chunk, THEN fuse
    SELECT DISTINCT ON (h.cid) h.cid, h.sid, h.score FROM fts_hits h
     ORDER BY h.cid, h.score DESC, h.sid
  ),
  fts_ranked AS (
    SELECT b.cid, b.sid, row_number() OVER (ORDER BY b.score DESC, b.cid) rnk FROM fts_best b
  ),
  vec_hits AS (
    SELECT c.cid, c.sid, (c.embedding <=> p_query_embedding) dist FROM chunks c
     WHERE p_query_embedding IS NOT NULL AND c.embedding IS NOT NULL
  ),
  vec_best AS (
    SELECT DISTINCT ON (v.cid) v.cid, v.sid, v.dist FROM vec_hits v ORDER BY v.cid, v.dist ASC, v.sid
  ),
  vec_ranked AS (
    SELECT b.cid, b.sid, row_number() OVER (ORDER BY b.dist ASC, b.cid) rnk FROM vec_best b
  )
  SELECT coalesce(f.cid, v.cid), coalesce(f.sid, v.sid),
         round(coalesce(1.0/(60+f.rnk),0)::numeric + coalesce(1.0/(60+v.rnk),0)::numeric, 8)
    FROM fts_ranked f FULL OUTER JOIN vec_ranked v ON v.cid = f.cid
   ORDER BY 3 DESC, 1
   LIMIT greatest(coalesce(p_limit,12),1);
END;
$$;

GRANT SELECT ON evidence.domain_entity_type, evidence.domain_attribute,
                evidence.retrieval_chunk, evidence.tier_label TO hp_app, hp_reader;
GRANT EXECUTE ON FUNCTION evidence.claim_search(text, text[], vector, integer) TO hp_app;
GRANT EXECUTE ON FUNCTION evidence.aggregate_claim(uuid)                       TO hp_app;
GRANT EXECUTE ON FUNCTION evidence.render_citation(uuid)                       TO hp_app;
GRANT EXECUTE ON FUNCTION evidence.confidence_band(numeric)                    TO hp_app;

-- ---- 7. safety.red_flag_event — per-message safety log (§4.0.7) -----------
-- SOURCE: HP-SCHEMA-001 Annex A Extension, migration 012/013 (quoted
-- verbatim block beginning "-- §4.0.7: every flag at MONITOR and above,
-- persisted with its full context"). Adapted to this stub's simpler shape,
-- same STAND-IN discipline as db/000's header:
--   * the real migration keys rule_id/template_id off composite (id,
--     version) FKs and a rule_set_id FK into a `safety.red_flag_rule_set`
--     table this stub doesn't build (db/000 keeps red_flag_rule/
--     safety_template as single-`id`-PK STAND-INs) — here rule_id/
--     template_id are plain FKs into those STAND-IN tables, and
--     (RESOLVED 2 Sep 2026 by R2/R3: red_flag_rule now carries the real
--     carries rather than a rule_set_id FK to a table that doesn't exist yet.
--   * `safety.session_severity_floor` (§4.0.8, the per-session sticky-
--     upward companion table this same doc section defines right after
--     red_flag_event) is intentionally NOT included in this pass — reading
--     it, applying it, and clearing it is a separate, still-open piece of
--     work (see README "What's still a documented placeholder").
--   * `action_taken`'s CHECK adds 'NONE' to the doc's five-value vocabulary
--     — see the column's own comment below for why.
-- Written by src/lib/pipeline/redFlagEngine.ts's `recordRedFlagEvent`,
-- called from all four of route.ts's `runPipeline` exit points, always
-- AFTER `upsertResponseAudit` for the same audit_id (the FK below requires
-- that row to already exist). Verified against a real Postgres instance in
-- scripts/smoke-test.mjs and test/runPipeline.integration.test.ts.
CREATE TABLE safety.red_flag_event (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  audit_id               uuid REFERENCES response_audit(id),
  subject_pseudonym      bytea NOT NULL,        -- never subject_id; ADR-003 §2.3
  session_pseudonym      bytea NOT NULL,
  occurred_at            timestamptz NOT NULL DEFAULT now(),
  severity               red_flag_severity NOT NULL,
  rule_id                uuid,
  -- composite, matching red_flag_rule's real PRIMARY KEY (id, version)
  rule_version           int,
  rule_set_id            uuid REFERENCES safety.red_flag_rule_set(id),
  trigger_detail         jsonb NOT NULL,        -- which pattern matched; no free user text
  template_id            uuid,
  template_version       int,
  -- Doc vocabulary is 'TEMPLATE_SHOWN'|'INTERSTITIAL'|'TAKEOVER'
  -- |'PANEL_ADDED'|'ESCALATED'. This pipeline only ever writes
  -- TEMPLATE_SHOWN (the §4.0.5 static-template short-circuit) or ESCALATED
  -- (a WARNING+ response routed to the review queue via side_effect_job) —
  -- INTERSTITIAL/TAKEOVER/PANEL_ADDED are conversational UI it doesn't
  -- render yet. 'NONE' is this stub's addition: a MONITOR-only event that
  -- §4.0.2 still requires to be persisted even though no UI action follows.
  action_taken            text NOT NULL
    CHECK (action_taken IN ('TEMPLATE_SHOWN','INTERSTITIAL','TAKEOVER','PANEL_ADDED','ESCALATED','NONE')),
  commercial_suppressed   boolean NOT NULL,      -- §4.0.6
  -- §6.5: latency measured from first byte of the INBOUND message, not
  -- scanner started_at.
  first_byte_at           timestamptz NOT NULL,
  scanner_started_at      timestamptz,
  template_displayed_at   timestamptz,
  clinician_notified_at   timestamptz,           -- NULL until a clinician-notification path exists — not built yet
  clinician_id             uuid,                 -- STAND-IN: no principal.clinician table in this stub
  outcome                  text,
  data_region              char(2) NOT NULL REFERENCES public.region_registry(code),
  -- §4.0.2: MONITOR is the floor for persistence.
  FOREIGN KEY (rule_id, rule_version)         REFERENCES safety.red_flag_rule(id, version),
  FOREIGN KEY (template_id, template_version) REFERENCES safety.safety_template(id, version),
  -- SEC-1: redundant against the primary key on (id) alone, and that is the
  -- point - it gives session_severity_floor's composite FK something to
  -- reference, which is what makes that table's denormalised data_region
  -- provably equal to this row's rather than equal by convention.
  CONSTRAINT u_rfe_id_region UNIQUE (id, data_region),
  CONSTRAINT c_event_at_least_monitor CHECK (severity >= 'MONITOR'),
  -- §4.1: at URGENT and above a pre-approved template is the only permitted output.
  CONSTRAINT c_urgent_needs_template CHECK (severity < 'URGENT' OR template_id IS NOT NULL),
  -- §4.0.5: at CRITICAL/EMERGENCY display is never gated on notification.
  CONSTRAINT c_emergency_display_not_gated CHECK (severity < 'CRITICAL' OR template_displayed_at IS NOT NULL),
  CONSTRAINT c_latency_ordered CHECK (template_displayed_at IS NULL OR template_displayed_at >= first_byte_at)
);
CREATE INDEX idx_rfe_severity_time ON safety.red_flag_event (severity, occurred_at);

GRANT SELECT, INSERT ON safety.red_flag_event TO hp_app, hp_reader;

-- ---- 8. safety.session_severity_floor (§4.0.8) -----------------------------
-- SOURCE: HP-SCHEMA-001 Annex A Extension (quoted verbatim, immediately after
-- red_flag_event in the same doc section): "levels are per-session sticky
-- upward until a clinician or a rule clears them." STAND-IN differences from
-- the quoted block, same discipline as red_flag_event above: `cleared_by`
-- has no FK (this stub has no `principal.clinician` table — see db/000's
-- header) rather than silently dropping the attribution requirement itself,
-- which stays enforced by c_clear_attributed.
--
-- Written by redFlagEngine.ts's `recordRedFlagEvent` — every red_flag_event
-- write also upserts this row, raising the floor to the event's severity
-- (never lowering it) unless the floor was previously cleared, in which case
-- a fresh event restarts it at whatever severity that event carries. Read by
-- `getSessionFloor` at the top of route.ts's `runPipeline`, before any
-- severity-based branching, so a session already sitting at WARNING+ can't
-- be reset to NORMAL just because one later message in it looks ordinary —
-- the whole point of a *session* floor rather than a per-message one.
-- `clearSessionSeverityFloor` exists and is tested but not called from
-- anywhere yet — there is no clinician-facing review tool in this repo for
-- it to be wired to; see README "What's still a documented placeholder".
--
-- SEC-1 / migration 032: `data_region` and the COMPOSITE FK below are not a
-- stub invention - they mirror what the shipping schema now enforces, and
-- they are here because this table is written on every flagged message and a
-- double that cannot accept the real write is not a double. Executing against
-- the real schema found that this table had no region at all: an IN-region
-- role could read, raise and clear an EU session's §4.0.8 floor. The
-- composite FK makes a floor whose region differs from its setting event's
-- impossible rather than merely unexpected.
--
-- STAND-IN difference, stated rather than silently absent: migration 032 also
-- puts ROW-LEVEL SECURITY on this table. That is deliberately NOT mirrored
-- here. This stub's callers are claims-less (`db().query()`, no per-request
-- GUC), which is exactly the configuration HP-SEC-001 v4.2 found breaks all
-- three of them, and the stub is a test double for the pipeline's own tests,
-- not the security boundary. Migration 032 is the one that ships.
CREATE TABLE safety.session_severity_floor (
  session_pseudonym bytea PRIMARY KEY,
  floor_severity     red_flag_severity NOT NULL,
  set_by_event_id    uuid NOT NULL REFERENCES safety.red_flag_event(id),
  set_at             timestamptz NOT NULL,
  cleared_at         timestamptz,
  cleared_by         uuid, -- STAND-IN: no principal.clinician table in this stub
  data_region        char(2) NOT NULL REFERENCES public.region_registry(code),
  CONSTRAINT c_clear_attributed CHECK (cleared_at IS NULL OR cleared_by IS NOT NULL),
  CONSTRAINT c_floor_region_is_its_event_region
    FOREIGN KEY (set_by_event_id, data_region)
    REFERENCES safety.red_flag_event (id, data_region)
);

GRANT SELECT, INSERT, UPDATE ON safety.session_severity_floor TO hp_app;
GRANT SELECT ON safety.session_severity_floor TO hp_reader;

-- ---- 9. safety.red_flag_log + safety.emergency_facility_reference ----------
-- HP-JOB-004 RF1/RF2. The real, shipping DDL for both is
-- `migrations/027_red_flag_module_additions.sql` in this same repo — now
-- reachable from this line of history, which it was not when db/000 was
-- written (see STUB_VS_REAL.md's opening paragraph). What follows is the
-- stub-shaped equivalent so this pipeline's own tests can run against plain
-- local Postgres. Since R2/R3 the rule and template tables carry the real
-- committed shape, so this file's divergence from migrations/ is now confined
-- to the tables listed in STUB_VS_REAL.md's remaining rows.
--
-- DO NOT ship this block. Migration 027 is the one that ships.

-- §4.0.7 gives MONITOR as the persistence floor and red_flag_event enforces it.
-- That is right for the governed record and useless for §6.4's false-negative
-- review, which is entirely about the messages the rules called NORMAL. You
-- cannot review what you did not write down. Hence a second, wider table.
CREATE TABLE safety.red_flag_log (
  id                      uuid PRIMARY KEY,
  event_id                uuid REFERENCES safety.red_flag_event(id),  -- null iff NORMAL
  audit_id                uuid,
  subject_pseudonym       bytea NOT NULL,
  session_pseudonym       bytea NOT NULL,
  occurred_at             timestamptz NOT NULL,

  rule_derived_severity   red_flag_severity NOT NULL,
  model_proposed_severity red_flag_severity,
  applied_severity        red_flag_severity NOT NULL,

  context_escalation      text[] NOT NULL DEFAULT '{}',
  rule_set_id             uuid,
  matched_rule_ids        uuid[] NOT NULL DEFAULT '{}',
  trigger_detail          jsonb NOT NULL,
  query_hash              bytea NOT NULL,          -- §3.13.1: a hash, never the query

  branch                  text NOT NULL
    CHECK (branch IN ('CONTINUE','MONITOR_PANEL','SAFETY_BLOCK_FIRST',
                      'TEMPLATE_TAKEOVER','FAIL_CLOSED')),
  template_id             uuid,
  template_version        int,
  commercial_suppressed   boolean NOT NULL,
  generation_blocked      boolean NOT NULL,
  needs_review            boolean NOT NULL,
  shadow_mode             boolean NOT NULL DEFAULT false,

  -- §6.5: from FIRST BYTE of the inbound message, not from scanner start.
  first_byte_at           timestamptz NOT NULL,
  scanner_started_at      timestamptz NOT NULL,
  scanner_completed_at    timestamptz NOT NULL,
  template_displayed_at   timestamptz,
  display_latency_ms      int,

  scanner_version         text NOT NULL,
  fail_safe_reason        text,
  data_region             char(2) NOT NULL,

  -- §4.0.3, restated where false-negative review will read it: the model may
  -- raise and may never lower. A clamping bug is a write failure, not a silent
  -- one. Relies on red_flag_severity's declaration order (AMB-S-11).
  CONSTRAINT c_never_lowered CHECK (
    applied_severity >= rule_derived_severity
    AND (model_proposed_severity IS NULL OR applied_severity >= model_proposed_severity)
  ),
  CONSTRAINT c_fail_closed_attributed CHECK (
    branch <> 'FAIL_CLOSED' OR fail_safe_reason IS NOT NULL
  ),
  CONSTRAINT c_latency_ordered CHECK (
    template_displayed_at IS NULL OR template_displayed_at >= first_byte_at
  )
);
CREATE INDEX idx_rfl_severity_time ON safety.red_flag_log (applied_severity, occurred_at);
-- the false-negative review's own query: rows the model wanted to raise and
-- the signed rules did not.
CREATE INDEX idx_rfl_model_disagreed ON safety.red_flag_log (occurred_at)
  WHERE model_proposed_severity IS NOT NULL
    AND model_proposed_severity > rule_derived_severity;

REVOKE UPDATE, DELETE ON safety.red_flag_log FROM PUBLIC;
GRANT INSERT, SELECT ON safety.red_flag_log TO hp_app;
GRANT SELECT ON safety.red_flag_log TO hp_reader;

-- §3.12.1's facility half. emergency_contact_reference holds phone numbers
-- only; §4.1's CRITICAL/EMERGENCY rows name a nearest ED and §3.12.1 forbids
-- the model supplying one. Job 18 populates this. An EMPTY TABLE IS A CORRECT
-- STATE — the slot resolves to unavailable and the template renders with the
-- emergency number alone. It is never a reason to name an unverified hospital,
-- and domain.hospital is TIER_4 commercial data (§1.4) that may never back an
-- emergency routing instruction.
CREATE TABLE safety.emergency_facility_reference (
  id                       uuid PRIMARY KEY,
  country                  char(2) NOT NULL,
  subdivision              text,
  city                     text,
  facility_name            text NOT NULL,
  address_line             text NOT NULL,
  has_emergency_department boolean NOT NULL,
  open_24h                 boolean NOT NULL,
  phone_e164               text,
  language                 text NOT NULL,
  last_verified_at         timestamptz NOT NULL,
  active                   boolean NOT NULL DEFAULT true,
  UNIQUE (country, subdivision, city, facility_name, language)
);
CREATE INDEX idx_efr_lookup
  ON safety.emergency_facility_reference (country, subdivision, city, language)
  WHERE active AND has_emergency_department;

GRANT SELECT ON safety.emergency_facility_reference TO hp_app, hp_reader;
