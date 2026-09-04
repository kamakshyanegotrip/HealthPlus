-- HealthPlus migration: 3. Migration 004 — foundation
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 004 — foundation: registries, versioning, retrieval, RLS scoping
-- ============================================================================

-- ---------- E-2: a hard block is not a low score, and must be distinguishable ----------
-- §1.7.0 precedence rule 1: retraction, supersession and expiry set 0.00 outright,
-- overriding the tier band. Without this column an audit cannot tell "we scored this
-- 0.00" from "we blocked this", and §3.13.2's data-gap signal reads the difference.
CREATE TYPE hard_block_reason AS ENUM (
  'M7_SUPERSEDED',      -- §1.7 M7
  'RETRACTED',          -- §1.3.5
  'EXPIRED',            -- §1.7.2
  'PREDATORY_VENUE',    -- §1.3.6
  'UNSOURCED'           -- §1.5.6 TIER_5_UNSOURCED
);

ALTER TABLE evidence.claim_source
  ADD COLUMN hard_block        hard_block_reason,
  ADD COLUMN hard_blocked_at   timestamptz,
  ADD CONSTRAINT c_hard_block_is_zero
    CHECK (hard_block IS NULL OR confidence = 0.00),
  ADD CONSTRAINT c_hard_block_dated
    CHECK ((hard_block IS NULL) = (hard_blocked_at IS NULL));

-- ---------- E-4: the scoping column ADR-003 migration 003's GRANT already assumed ----------
-- GRANT SELECT (id, provider_org_id, kind, jurisdiction) ON evidence.claim TO ranker_role
ALTER TABLE evidence.claim
  ADD COLUMN provider_org_id uuid REFERENCES principal.provider_org(id);

COMMENT ON COLUMN evidence.claim.provider_org_id IS
  'RLS scope + §1.4.5 disclosure join. NULL for non-provider claims. The ranker may '
  'read this column and NOT claim_source.confidence (ADR-003 §3.4).';

-- ---------- E-1: the entity-type registry ----------
CREATE TABLE evidence.domain_entity_type (
  entity_type     text PRIMARY KEY,         -- 'hospital' | 'clinical_indicator' | …
  schema_name     text NOT NULL,
  table_name      text NOT NULL,
  rls_scope       text NOT NULL
    CHECK (rls_scope IN ('GLOBAL','PROVIDER','SUBJECT')),
  blueprint_ref   text,                     -- '§40 HOSPITAL' …
  adopted_version text NOT NULL,
  UNIQUE (schema_name, table_name)
);

-- ---------- E-1: the attribute contract — cardinality and required-ness AS DATA ----------
CREATE TABLE evidence.domain_attribute_kind (
  entity_type        text NOT NULL REFERENCES evidence.domain_entity_type(entity_type),
  attribute          text NOT NULL,
  expected_claim_kind claim_kind NOT NULL,
  min_claims         smallint NOT NULL DEFAULT 0,   -- 0 = optional, 1+ = required
  max_claims         smallint,                      -- NULL = unbounded
  requires_marker    boolean NOT NULL DEFAULT false,-- §1.4.4 self-report marker
  min_category       response_category,             -- lowest category that may publish it
  charter_clause     text NOT NULL,
  blueprint_ref      text,
  adopted_version    text NOT NULL,
  adopted_by         uuid NOT NULL REFERENCES principal.app_user(id),
  effective_from     timestamptz NOT NULL,
  PRIMARY KEY (entity_type, attribute),
  CONSTRAINT c_card_sane CHECK (max_claims IS NULL OR max_claims >= GREATEST(min_claims,1))
);

ALTER TABLE evidence.domain_attribute
  ADD CONSTRAINT fk_domain_attribute_kind
    FOREIGN KEY (entity_type, attribute)
    REFERENCES evidence.domain_attribute_kind(entity_type, attribute);

-- The claim bound to an attribute must be of the kind the registry declares. Without
-- this, a SENTIMENT claim can be bound to a 'complication_rate' attribute and §1.5.5's
-- separation of sentiment from clinical quality is defeated at the data layer.
CREATE OR REPLACE FUNCTION evidence.assert_attribute_claim_kind() RETURNS trigger AS $$
DECLARE expected claim_kind; actual claim_kind; found boolean;
BEGIN
  SELECT true, k.expected_claim_kind INTO found, expected
    FROM evidence.domain_attribute_kind k
   WHERE k.entity_type = NEW.entity_type AND k.attribute = NEW.attribute;
  -- §3.0.3 fail-closed, same rule as claim_policy: an unregistered attribute is a
  -- prohibition, never a permission. The FK would also refuse this; the trigger fires
  -- first and says why, because "violates fk_domain_attribute_kind" is not a diagnosis.
  IF NOT COALESCE(found, false) THEN
    RAISE EXCEPTION
      'HP-ESC 3.0.3 default-deny: attribute %.% is not in domain_attribute_kind',
      NEW.entity_type, NEW.attribute;
  END IF;
  SELECT c.kind INTO actual FROM evidence.claim c WHERE c.id = NEW.claim_id;
  IF expected IS DISTINCT FROM actual THEN
    RAISE EXCEPTION
      'HP-ESC 1.5.3: attribute %.% expects claim_kind %, got % (claim %)',
      NEW.entity_type, NEW.attribute, expected, actual, NEW.claim_id;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_domain_attribute_kind_matches
  BEFORE INSERT OR UPDATE ON evidence.domain_attribute
  FOR EACH ROW EXECUTE FUNCTION evidence.assert_attribute_claim_kind();

-- Cardinality is deferred: a multi-claim attribute is assembled across several inserts,
-- and §1.8.2 wants two claims on one (entity, attribute) to be *detectable*, not refused.
CREATE OR REPLACE FUNCTION evidence.assert_attribute_cardinality() RETURNS trigger AS $$
DECLARE n int; lo smallint; hi smallint;
BEGIN
  SELECT k.min_claims, k.max_claims INTO lo, hi
    FROM evidence.domain_attribute_kind k
   WHERE k.entity_type = NEW.entity_type AND k.attribute = NEW.attribute;
  SELECT count(*) INTO n FROM evidence.domain_attribute d
   WHERE d.entity_type = NEW.entity_type
     AND d.entity_id   = NEW.entity_id
     AND d.attribute   = NEW.attribute;
  IF hi IS NOT NULL AND n > hi THEN
    RAISE EXCEPTION 'HP-SCHEMA 004: %.% on entity % has % claims, max is %',
      NEW.entity_type, NEW.attribute, NEW.entity_id, n, hi;
  END IF;
  -- §1.3.7's single-study prohibition, enforced rather than declared: an attribute with
  -- min_claims = 2 must reach two bindings before the transaction commits. The practical
  -- consequence is that both concordant sources are written together, which is the right
  -- shape — "studies show" is a claim about a body of evidence, not about one paper.
  IF lo > 0 AND n < lo THEN
    RAISE EXCEPTION 'HP-ESC 1.3.7: %.% on entity % has % claim(s), minimum is %',
      NEW.entity_type, NEW.attribute, NEW.entity_id, n, lo;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_domain_attribute_cardinality
  AFTER INSERT OR UPDATE ON evidence.domain_attribute
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION evidence.assert_attribute_cardinality();

-- ---------- E-2: supersession, generalised from evidence_source ----------
-- Applied to disease_severity_model, guideline, regulation, red_flag_rule_set and
-- safety_template_set below. TG_ARGV[0] is the entity_type the rows bridge under.
CREATE OR REPLACE FUNCTION evidence.cascade_supersession() RETURNS trigger AS $$
DECLARE v_entity_type text := TG_ARGV[0]; n int;
BEGIN
  IF NEW.superseded_by IS NOT NULL AND OLD.superseded_by IS NULL THEN
    IF NEW.superseded_by = NEW.id THEN
      RAISE EXCEPTION 'HP-ESC 1.7 M7: % % cannot supersede itself', v_entity_type, NEW.id;
    END IF;
    -- §1.7 M7 + §1.7.0(1): every claim behind this version drops to a hard block.
    UPDATE evidence.claim_source cs
       SET confidence = 0.00, hard_block = 'M7_SUPERSEDED', hard_blocked_at = now()
     WHERE cs.claim_id IN (
             SELECT da.claim_id FROM evidence.domain_attribute da
              WHERE da.entity_type = v_entity_type AND da.entity_id = NEW.id)
       AND cs.hard_block IS NULL;
    GET DIAGNOSTICS n = ROW_COUNT;
    -- §1.8.5 / §3.13.2: a supersession that blocks NOTHING almost always means the new
    -- version was loaded without re-binding its claims — the old version is still the
    -- only thing anything points at. That is a data-quality event, not a no-op.
    IF n = 0 THEN
      INSERT INTO obs.data_quality_flag
        (id, flag_kind, entity_type, entity_id, detected_at, detected_by, charter_clause, detail)
      VALUES (gen_random_uuid(), 'UNRESOLVED_SUPERSESSION', v_entity_type, NEW.id, now(),
              'trg_supersede', 'HP-ESC 1.7 M7',
              jsonb_build_object('superseded_by', NEW.superseded_by,
                                 'note', 'no claim bindings were blocked'));
    END IF;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

-- §3.6.3 / §1.7 M7 second limb: resolve to the current version, with a cycle guard.
CREATE OR REPLACE FUNCTION evidence.current_version(
  p_schema text, p_table text, p_id uuid
) RETURNS uuid LANGUAGE plpgsql STABLE AS $$
DECLARE cur uuid := p_id; nxt uuid; hops int := 0;
BEGIN
  LOOP
    EXECUTE format('SELECT superseded_by FROM %I.%I WHERE id = $1', p_schema, p_table)
      INTO nxt USING cur;
    EXIT WHEN nxt IS NULL;
    hops := hops + 1;
    IF hops > 64 THEN
      RAISE EXCEPTION 'HP-ESC 1.7 M7: supersession cycle at %.% from %', p_schema, p_table, p_id;
    END IF;
    cur := nxt;
  END LOOP;
  RETURN cur;
END $$;

-- ---------- E-3: retrieval, one table, 384 dimensions ----------
-- ADR-003 §4 (F.3) adopted 384 (bge-small-en-v1.5, local, MIT) and dropped ADR-001
-- §3.3's 512-dim paid line. The column is sized to the decision, not to the range.
CREATE TABLE evidence.retrieval_chunk (
  id                      uuid PRIMARY KEY,
  entity_type             text REFERENCES evidence.domain_entity_type(entity_type),
  entity_id               uuid,
  claim_id                uuid REFERENCES evidence.claim(id) ON DELETE CASCADE,
  source_id               uuid REFERENCES evidence.evidence_source(id),
  chunk_ordinal           int NOT NULL DEFAULT 0,
  body                    text NOT NULL,
  language                text NOT NULL,
  embedding               vector(384) NOT NULL,
  embedding_model         text NOT NULL,     -- 'bge-small-en-v1.5'
  embedding_model_version text NOT NULL,     -- re-embed is auditable; see ADR CHG-001 F.3
  embedded_at             timestamptz NOT NULL DEFAULT now(),
  tsv                     tsvector
    GENERATED ALWAYS AS (to_tsvector('simple', body)) STORED,
  -- a chunk with no anchor is unciteable and therefore §1.9.1-unusable
  CONSTRAINT c_chunk_anchored CHECK (claim_id IS NOT NULL OR source_id IS NOT NULL
                                     OR (entity_type IS NOT NULL AND entity_id IS NOT NULL))
);

CREATE INDEX idx_chunk_hnsw ON evidence.retrieval_chunk
  USING hnsw (embedding vector_cosine_ops);
CREATE INDEX idx_chunk_tsv  ON evidence.retrieval_chunk USING gin (tsv);
CREATE INDEX idx_chunk_entity ON evidence.retrieval_chunk (entity_type, entity_id);

-- ---------- E-4: RLS session context ----------
CREATE SCHEMA app;

CREATE OR REPLACE FUNCTION app.current_user_id() RETURNS uuid
  LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.user_id', true),'')::uuid $$;

CREATE OR REPLACE FUNCTION app.current_provider_org() RETURNS uuid
  LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.provider_org_id', true),'')::uuid $$;

CREATE OR REPLACE FUNCTION app.current_region() RETURNS char(2)
  LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.data_region', true),'')::char(2) $$;
