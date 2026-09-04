-- HealthPlus migration: 4. Migration 005 — observability and data quality
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 005 — observability (§3.13 fabrication logging, §6.5 safety metrics)
-- ============================================================================
CREATE TYPE ai_call_purpose AS ENUM (
  'CATEGORY_CLASSIFY',   -- §2.0.1
  'RED_FLAG_PROPOSE',    -- §4.0.3, propose-only; may raise, never lower
  'COMPOSE',             -- generative response
  'EXTRACT',             -- ingestion: claim extraction from a source
  'RERANK',
  'TRANSLATE',           -- §1.7 M8; never for safety-critical text (§4.3.4)
  'EMBED'
);
CREATE TYPE ai_call_outcome AS ENUM ('OK','BLOCKED','ERROR','TIMEOUT','REFUSED_BY_POLICY');

CREATE TYPE dq_flag_kind AS ENUM (
  'MISSING_SOURCE',           -- §3.0.3 / §1.0.1
  'DUPLICATE',                -- §1.8.5, C-21
  'CONTRADICTION',            -- §1.8.1–2
  'OUTDATED',                 -- §1.7.2
  'CONFLICTING_GUIDELINE',    -- §1.8.4
  'RETRACTED',                -- §1.3.5
  'UNRESOLVED_SUPERSESSION',  -- §1.7 M7, written by trg_supersede
  'POPULATION_MISSING',       -- §1.9.7
  'EXTRACTION_UNCERTAIN',     -- §1.7 M9
  'JURISDICTION_MISMATCH',    -- §1.7 M4
  'UNVERIFIED_ACCREDITATION'  -- §1.2.6 / §3.4.3
);

-- Per-call trace. Holds NO free text: prompts and completions are personal data and
-- live in obs.response_content under the destroyable subject key (ADR-003 §2.3).
CREATE TABLE obs.ai_call (
  id                 uuid PRIMARY KEY,
  audit_id           uuid REFERENCES obs.response_audit(id),
  occurred_at        timestamptz NOT NULL,
  purpose            ai_call_purpose NOT NULL,
  provider           text NOT NULL,
  model_version      text NOT NULL,
  prompt_version     text NOT NULL,
  retrieval_version  text,
  input_tokens       int,
  output_tokens      int,
  latency_ms         int,
  outcome            ai_call_outcome NOT NULL,
  retrieved_claim_ids uuid[] NOT NULL DEFAULT '{}',
  proposed_severity  red_flag_severity,   -- §4.0.3: what the model proposed
  applied_severity   red_flag_severity,   -- what the deterministic rules allowed
  data_region        char(2) NOT NULL REFERENCES public.region_registry(code),
  -- §4.0.3: the model may raise a rule-derived severity and never lower it.
  -- Recorded as a constraint so a clamping bug is a write failure, not a silent one.
  CONSTRAINT c_model_may_not_lower CHECK (
    proposed_severity IS NULL OR applied_severity IS NULL
    OR applied_severity >= proposed_severity
    OR purpose <> 'RED_FLAG_PROPOSE'
  )
);
CREATE INDEX idx_ai_call_audit ON obs.ai_call (audit_id);
CREATE INDEX idx_ai_call_time  ON obs.ai_call (occurred_at);

-- §3.13.1: every §3 block, with class, query hash, retrieved-source state, message shown.
CREATE TABLE obs.fabrication_block (
  id                     uuid PRIMARY KEY,
  occurred_at            timestamptz NOT NULL,
  ai_call_id             uuid REFERENCES obs.ai_call(id),
  audit_id               uuid REFERENCES obs.response_audit(id),
  prohibition_class      text NOT NULL,          -- '3.1' … '3.12', §3.13.1 "class ID"
  claim_kind             claim_kind,
  tier                   source_tier,
  category               response_category NOT NULL,
  policy_tier            source_tier,            -- the claim_policy row that refused
  policy_kind            claim_kind,
  policy_category        response_category,
  policy_effective_from  timestamptz,
  query_hash             bytea NOT NULL,         -- §3.13.1: hash, never the query text
  retrieved_source_state jsonb NOT NULL,         -- tiers/ids present at refusal time
  message_template_id    text,                   -- what the user was shown instead
  data_region            char(2) NOT NULL REFERENCES public.region_registry(code),
  FOREIGN KEY (policy_tier, policy_kind, policy_category, policy_effective_from)
    REFERENCES evidence.claim_policy(tier, kind, category, effective_from),
  CONSTRAINT c_class_format CHECK (prohibition_class ~ '^3\.[0-9]+(\.[0-9]+)?$')
);
CREATE INDEX idx_block_class_time ON obs.fabrication_block (prohibition_class, occurred_at);

-- §3.0.4 / §6.5: abstention is a POSITIVE metric. Logged separately from blocks so
-- "we correctly said we don't know" is countable and can never be tuned against.
CREATE TABLE obs.abstention_event (
  id              uuid PRIMARY KEY,
  occurred_at     timestamptz NOT NULL,
  audit_id        uuid REFERENCES obs.response_audit(id),
  reason          text NOT NULL,   -- 'NO_SOURCE' | 'EXPIRED' | 'BELOW_BAND' | 'CATEGORY_C'
  claim_kind      claim_kind,
  category        response_category NOT NULL,
  data_region     char(2) NOT NULL REFERENCES public.region_registry(code)
);

-- §1.8.5: the seven DQE functions, one shape. Written by the engine and by trg_supersede.
CREATE TABLE obs.data_quality_flag (
  id              uuid PRIMARY KEY,
  flag_kind       dq_flag_kind NOT NULL,
  entity_type     text,
  entity_id       uuid,
  claim_id        uuid REFERENCES evidence.claim(id) ON DELETE CASCADE,
  source_id       uuid REFERENCES evidence.evidence_source(id),
  detected_at     timestamptz NOT NULL,
  detected_by     text NOT NULL,          -- DQE version or trigger name
  charter_clause  text NOT NULL,
  detail          jsonb,
  resolved_at     timestamptz,
  resolved_by     uuid REFERENCES principal.app_user(id),
  resolution_note text,
  CONSTRAINT c_flag_targets_something CHECK (
    claim_id IS NOT NULL OR source_id IS NOT NULL
    OR (entity_type IS NOT NULL AND entity_id IS NOT NULL)
  ),
  CONSTRAINT c_resolution_paired CHECK ((resolved_at IS NULL) = (resolved_by IS NULL))
);
CREATE INDEX idx_dq_open ON obs.data_quality_flag (flag_kind, detected_at)
  WHERE resolved_at IS NULL;

-- §6.5: the metric series, stored rather than computed ad hoc, so a regression is
-- visible as a series and not as an argument. §6.4 makes a recall drop a release blocker.
CREATE TABLE obs.safety_metric_sample (
  id             uuid PRIMARY KEY,
  metric_key     text NOT NULL,      -- 'red_flag_recall' | 'emergency_display_latency_ms_p95'
                                     -- | 'block_rate_3_1' | 'abstention_rate' | 'review_turnaround_h'
  window_start   timestamptz NOT NULL,
  window_end     timestamptz NOT NULL,
  numerator      numeric,
  denominator    numeric,
  value          numeric NOT NULL,
  method_version text NOT NULL,
  gold_set_version text,             -- §6.4: clinician-labelled gold set this was scored against
  computed_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (metric_key, window_start, window_end, method_version)
);

-- §2.2.5b: the only pre-publication human-review path in v1. Category C is off, which
-- did not remove the clinician requirement (§2.2.5d).
CREATE TABLE obs.review_queue_item (
  id             uuid PRIMARY KEY,
  audit_id       uuid NOT NULL REFERENCES obs.response_audit(id),
  reason         text NOT NULL,   -- 'HIGH_RISK_PROFILE'|'ELEVATED_TOPIC'|'SEVERITY_WARNING'
                                  -- |'CONF_BAND_070_074'|'TIER_CONFLICT'|'USER_FLAGGED'
  clinical_domain text NOT NULL REFERENCES safety.clinical_domain(code),
  enqueued_at    timestamptz NOT NULL,
  claimed_by     uuid REFERENCES principal.clinician(user_id),
  claimed_at     timestamptz,
  decided_at     timestamptz,
  decision       review_state,
  data_region    char(2) NOT NULL REFERENCES public.region_registry(code),
  -- §2.3.5b: there is no implicit approval and no timeout-to-publish.
  CONSTRAINT c_no_implicit_approval CHECK ((decided_at IS NULL) = (decision IS NULL))
);

ALTER TABLE obs.ai_call            ENABLE ROW LEVEL SECURITY;
ALTER TABLE obs.fabrication_block  ENABLE ROW LEVEL SECURITY;
ALTER TABLE obs.data_quality_flag  ENABLE ROW LEVEL SECURITY;
ALTER TABLE obs.review_queue_item  ENABLE ROW LEVEL SECURITY;
