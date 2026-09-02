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
CREATE TABLE safety.red_flag_rule (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ruleset_version    text NOT NULL,
  version            int NOT NULL DEFAULT 1,
  severity           red_flag_severity NOT NULL,
  pattern            text NOT NULL,          -- Postgres regex; clinician-authored
  pattern_notes      text,                   -- what the pattern is meant to catch, for the reviewing clinician
  template_id        uuid,
  template_version   int,
  clinically_adopted boolean NOT NULL DEFAULT false,   -- AMB-17 gate
  adopted_by         uuid,
  adopted_at         timestamptz,
  CONSTRAINT c_adopted_needs_reviewer CHECK (
    clinically_adopted = false OR (adopted_by IS NOT NULL AND adopted_at IS NOT NULL)
  )
);
CREATE INDEX idx_red_flag_rule_active ON safety.red_flag_rule (ruleset_version) WHERE clinically_adopted;

CREATE TABLE safety.safety_template (
  id                 uuid PRIMARY KEY,
  version            int NOT NULL DEFAULT 1,
  body               text NOT NULL,
  active             boolean NOT NULL DEFAULT false,   -- also AMB-17-gated, same reasoning
  clinically_adopted boolean NOT NULL DEFAULT false,
  adopted_by         uuid,
  adopted_at         timestamptz,
  CONSTRAINT c_template_adopted_needs_reviewer CHECK (
    clinically_adopted = false OR (adopted_by IS NOT NULL AND adopted_at IS NOT NULL)
  ),
  CONSTRAINT c_active_requires_adopted CHECK (active = false OR clinically_adopted = true)
);
ALTER TABLE safety.red_flag_rule ADD CONSTRAINT fk_red_flag_template
  FOREIGN KEY (template_id) REFERENCES safety.safety_template(id);

GRANT SELECT ON safety.red_flag_rule, safety.safety_template TO hp_app, hp_reader;

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

-- ---- 5. evidence.claim_aggregate(claim_id, category) -----------------------
-- HP-SCHEMA-001 §23.3 argues by name for MIN-over-cited-sources aggregation
-- ("A mean over cited claims lets a 0.95 claim carry a 0.50 one... MIN is
-- the only rule consistent with [§3.10.1]") but that section is about
-- response-level aggregation across MULTIPLE claims. This function is the
-- claim level: MIN across a single claim's own concordant source bindings,
-- gated through policy_for so a PROHIBITED disposition still returns 0.00
-- rather than a number that looks usable. knowledgeLookup.ts calls this
-- once per candidate claim; route.ts separately does the response-level MIN
-- across whichever claims actually got cited.
CREATE OR REPLACE FUNCTION evidence.claim_aggregate(p_claim_id uuid, p_category response_category)
RETURNS TABLE (confidence numeric(3,2), confidence_band text, citation text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_conf numeric(3,2);
  v_kind claim_kind;
  v_tier source_tier;
  v_pol evidence.claim_policy;
BEGIN
  SELECT c.kind INTO v_kind FROM evidence.claim c WHERE c.id = p_claim_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 0.00::numeric(3,2), 'Insufficient'::text, NULL::text;
    RETURN;
  END IF;

  -- MIN across this claim's own concordant source bindings, excluding any
  -- binding a hard block already zeroed.
  SELECT MIN(cs.confidence), (array_agg(es.tier ORDER BY cs.confidence))[1]
    INTO v_conf, v_tier
    FROM evidence.claim_source cs
    JOIN evidence.evidence_source es ON es.id = cs.source_id
   WHERE cs.claim_id = p_claim_id AND cs.hard_block IS NULL;

  IF v_conf IS NULL THEN
    RETURN QUERY SELECT 0.00::numeric(3,2), 'Insufficient'::text, NULL::text;
    RETURN;
  END IF;

  SELECT * INTO v_pol FROM evidence.policy_for(v_tier, v_kind, p_category);
  IF v_pol.disposition = 'PROHIBITED' THEN
    RETURN QUERY SELECT 0.00::numeric(3,2), 'Insufficient'::text, NULL::text;
    RETURN;
  END IF;
  IF v_pol.confidence_cap IS NOT NULL AND v_conf > v_pol.confidence_cap THEN
    v_conf := v_pol.confidence_cap;
  END IF;

  RETURN QUERY SELECT
    v_conf,
    CASE WHEN v_conf >= 0.85 THEN 'High' WHEN v_conf >= 0.65 THEN 'Medium'
         WHEN v_conf >= 0.40 THEN 'Low' ELSE 'Insufficient' END,
    format('claim:%s', p_claim_id)::text; -- placeholder rendering; §1.9.5 requires the
                                            -- real citation string to come from
                                            -- evidence_source fields, not be assembled
                                            -- here — wire to the real renderer, this is
                                            -- only enough to keep the pipeline running
END $$;

GRANT EXECUTE ON FUNCTION evidence.claim_aggregate TO hp_app;

-- ---- 6. claim_search(query, domain) — hybrid FTS + vector, RRF-fused ------
-- HP-ADR-001 §3.3: "pgvector at 512 dims + Postgres FTS fused with RRF" (the
-- dimension was later confirmed at 384 in HP-SCHEMA-001 §11 — this stub
-- follows the confirmed number). No embedding call is made inside SQL — the
-- caller passes a pre-embedded query vector; this signature takes plain text
-- and does FTS-only ranking as a temporary fallback (search_tsv @@ query),
-- clearly marked, so the pipeline is at least runnable before the embedding
-- step is wired in. Replace the vector half before relying on recall.
-- Param named p_domain_table (not p_domain) deliberately: this filters on
-- evidence.claim.domain_table, the SQL table name (e.g. "domain.guideline"),
-- NOT the app-level KnowledgeDomain enum (e.g. "GUIDELINE") that
-- knowledgeLookup.ts's `domain` variable holds. Those two were conflated in
-- an earlier version of this function's caller and it silently zeroed every
-- lookup (caught by scripts/smoke-test.mjs, not by review) — the param name
-- is now part of preventing that regression, not just documenting it.
CREATE OR REPLACE FUNCTION claim_search(p_query text, p_domain_table text, p_query_embedding vector(384) DEFAULT NULL)
RETURNS TABLE (claim_id uuid, source_id uuid, rank numeric)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p_query_embedding IS NULL THEN
    -- FTS-ONLY FALLBACK — not the RRF-fused hybrid search HP-ADR-001 §3.3
    -- specifies. Flagged loudly rather than silently degrading recall.
    RETURN QUERY
      SELECT c.id, cs.source_id, ts_rank(c.search_tsv, websearch_to_tsquery('english', p_query))::numeric
        FROM evidence.claim c
        JOIN evidence.claim_source cs ON cs.claim_id = c.id
       WHERE c.domain_table = p_domain_table
         AND c.search_tsv @@ websearch_to_tsquery('english', p_query)
       ORDER BY 3 DESC
       LIMIT 40;
    RETURN;
  END IF;

  -- Reciprocal Rank Fusion of FTS rank and vector distance, k=60 (a common
  -- RRF default; not a value taken from any project doc — tune against a
  -- real eval set per HP-ADR-001 §3.3's own "spend the effort on chunking
  -- and on an eval set" guidance before trusting this constant).
  RETURN QUERY
  WITH fts AS (
    SELECT c.id AS claim_id, cs.source_id,
           row_number() OVER (ORDER BY ts_rank(c.search_tsv, websearch_to_tsquery('english', p_query)) DESC) AS rnk
      FROM evidence.claim c JOIN evidence.claim_source cs ON cs.claim_id = c.id
     WHERE c.domain_table = p_domain_table
     LIMIT 100
  ), vec AS (
    SELECT c.id AS claim_id, cs.source_id,
           row_number() OVER (ORDER BY c.embedding <=> p_query_embedding) AS rnk
      FROM evidence.claim c JOIN evidence.claim_source cs ON cs.claim_id = c.id
     WHERE c.domain_table = p_domain_table AND c.embedding IS NOT NULL
     LIMIT 100
  )
  SELECT COALESCE(f.claim_id, v.claim_id), COALESCE(f.source_id, v.source_id),
         (COALESCE(1.0/(60+f.rnk), 0) + COALESCE(1.0/(60+v.rnk), 0))::numeric AS rank
    FROM fts f FULL OUTER JOIN vec v ON f.claim_id = v.claim_id AND f.source_id = v.source_id
   ORDER BY rank DESC
   LIMIT 40;
END $$;

GRANT EXECUTE ON FUNCTION claim_search TO hp_app;

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
--     ruleset_version is the text column the STAND-IN red_flag_rule already
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
  rule_id                uuid REFERENCES safety.red_flag_rule(id),
  rule_version           int,
  ruleset_version        text,                  -- STAND-IN for the real rule_set_id FK, see header
  trigger_detail         jsonb NOT NULL,        -- which pattern matched; no free user text
  template_id            uuid REFERENCES safety.safety_template(id),
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
CREATE TABLE safety.session_severity_floor (
  session_pseudonym bytea PRIMARY KEY,
  floor_severity     red_flag_severity NOT NULL,
  set_by_event_id    uuid NOT NULL REFERENCES safety.red_flag_event(id),
  set_at             timestamptz NOT NULL,
  cleared_at         timestamptz,
  cleared_by         uuid, -- STAND-IN: no principal.clinician table in this stub
  CONSTRAINT c_clear_attributed CHECK (cleared_at IS NULL OR cleared_by IS NOT NULL)
);

GRANT SELECT, INSERT, UPDATE ON safety.session_severity_floor TO hp_app;
GRANT SELECT ON safety.session_severity_floor TO hp_reader;

-- ---- 9. safety.red_flag_log + safety.emergency_facility_reference ----------
-- HP-JOB-004 RF1/RF2. The real, shipping DDL for both is
-- `migrations/027_red_flag_module_additions.sql` in this same repo — now
-- reachable from this line of history, which it was not when db/000 was
-- written (see STUB_VS_REAL.md's opening paragraph). What follows is the
-- stub-shaped equivalent so this pipeline's own tests can run against plain
-- local Postgres; it uses `ruleset_version text` where the real table uses a
-- `rule_set_id uuid` FK, exactly as the STAND-IN red_flag_rule above does.
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
