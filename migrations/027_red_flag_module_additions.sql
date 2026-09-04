-- ============================================================================
-- MIGRATION 027 — RED-FLAG MODULE RUNTIME SUPPORT
--
-- HP-JOB-004. Extends HP-SCHEMA-001 migration 012 (safety.red_flag_rule_set,
-- red_flag_rule, safety_template, emergency_contact_reference, red_flag_event,
-- session_severity_floor) with the two objects the runtime module needs and
-- migration 012 does not provide:
--
--   1. safety.red_flag_log            — EVERY classification, including NORMAL.
--                                       safety.red_flag_event is the governed
--                                       §4.0.7 record and its CHECK constraint
--                                       c_event_at_least_monitor forbids NORMAL
--                                       rows. False-negative review (§6.4) needs
--                                       the NORMAL rows, so they get their own
--                                       append-only table rather than a Charter
--                                       amendment to relax §4.0.7's floor.
--
--   2. safety.emergency_facility_reference
--                                     — the "nearest ED" half of §3.12.1.
--                                       safety.emergency_contact_reference holds
--                                       phone numbers only. §4.1's CRITICAL and
--                                       EMERGENCY rows name a nearest ED, and
--                                       §3.12.1 forbids the model generating one.
--                                       Job 18 (Phase 2 Part A §3.12.1) populates
--                                       this table; until it does, slot resolution
--                                       returns UNRESOLVED and the template
--                                       renders with the emergency number alone.
--
-- Numbered 027 because this repo's migrations run to 026e and no 027/028
-- exist — which answers the open question in HP-JOB-002's Migration Numbering
-- Ledger §4 directly: they were never used. HP-JOB-001 (029/029b) and HP-JOB-002
-- (030/030b/030c) are not in this repo at all; if they land later they take
-- 028+ and nothing here changes. Renumber-safe in the sense of HP-JOB-002's Migration Numbering Ledger §3: no
-- object name encodes a migration number, every guard is idempotent, and no code
-- in this job depends on this job's own number. If migrations/ turns out to run
-- to 026e rather than 030c, this file becomes 028_… with no line changed.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Role. ADR-003 migration 003's convention: NOLOGIN, guarded, cluster-wide.
--    (Build item 1 found that CREATE ROLE has no IF NOT EXISTS.)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'redflag_role') THEN
    CREATE ROLE redflag_role NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA safety, obs, public TO redflag_role;

-- ---------------------------------------------------------------------------
-- 2. §3.12.1 — the facility half of the maintained reference table.
--    Maintained by Job 18. Never generated, never guessed, never inferred from
--    a hospital row in domain.hospital: a commercial provider listing is TIER_4
--    (§1.4) and an emergency routing instruction may not rest on it.
-- ---------------------------------------------------------------------------
CREATE TABLE safety.emergency_facility_reference (
  id                 uuid PRIMARY KEY,
  country            char(2) NOT NULL,
  subdivision        text,                 -- state/province
  city               text,
  facility_name      text NOT NULL,
  address_line       text NOT NULL,
  latitude           numeric(8,5),
  longitude          numeric(8,5),
  -- §3.12.1 names "emergency-department capabilities" explicitly. A facility
  -- without a 24h ED is not a nearest-ED answer, so the flag is NOT NULL and
  -- the resolver filters on it rather than assuming.
  has_emergency_department boolean NOT NULL,
  open_24h           boolean NOT NULL,
  phone_e164         text,
  language           text NOT NULL,
  source_id          uuid NOT NULL REFERENCES evidence.evidence_source(id),
  last_verified_at   timestamptz NOT NULL,
  verified_by        uuid REFERENCES principal.app_user(id),
  active             boolean NOT NULL DEFAULT true,
  UNIQUE (country, subdivision, city, facility_name, language)
);

CREATE INDEX idx_efr_lookup
  ON safety.emergency_facility_reference (country, subdivision, city, language)
  WHERE active AND has_emergency_department;

COMMENT ON TABLE safety.emergency_facility_reference IS
  'Job 18 (Phase 2 Part A §3.12.1) maintains this. Like '
  'safety.emergency_contact_reference it binds to evidence_source directly '
  'rather than through a claim: §4.0.5 forbids gating emergency output on a '
  'claim-confidence lookup. An empty table is a correct state — the resolver '
  'returns UNRESOLVED and the template renders the emergency number alone. It '
  'is never a reason to let the model supply an address.';

-- ---------------------------------------------------------------------------
-- 3. §4.0.7 + §6.4 — the full classification log.
--
--    red_flag_event  : the governed record, MONITOR and above, one row per flag.
--    red_flag_log    : one row per SCAN, every severity including NORMAL, for
--                      false-negative review and for the §6.5 latency metric.
--
--    Holds no free user text. trigger_detail records which pattern matched;
--    query_hash is a hash, never the query, matching obs.fabrication_block.
-- ---------------------------------------------------------------------------
CREATE TABLE safety.red_flag_log (
  id                     uuid PRIMARY KEY,
  event_id               uuid REFERENCES safety.red_flag_event(id),  -- null iff NORMAL
  audit_id               uuid REFERENCES obs.response_audit(id),
  ai_call_id             uuid REFERENCES obs.ai_call(id),            -- §4.0.3 step 2

  subject_pseudonym      bytea NOT NULL,     -- HMAC under the destroyable subject key
  session_pseudonym      bytea NOT NULL,
  occurred_at            timestamptz NOT NULL,

  -- ---- the three severities §4.0.3 keeps apart -------------------------------
  rule_derived_severity  red_flag_severity NOT NULL,  -- step 1, deterministic
  model_proposed_severity red_flag_severity,          -- step 2, propose-only
  applied_severity       red_flag_severity NOT NULL,  -- what the user actually got

  -- ---- why it ended up there -------------------------------------------------
  profile_floor_applied  red_flag_severity,   -- §4.6 raised the floor to this
  session_floor_applied  red_flag_severity,   -- §4.0.8 sticky floor
  context_escalation     text[] NOT NULL DEFAULT '{}',  -- §4.5 trigger codes
  rule_set_id            uuid REFERENCES safety.red_flag_rule_set(id),
  matched_rule_ids       uuid[] NOT NULL DEFAULT '{}',
  trigger_detail         jsonb NOT NULL,      -- which pattern matched; no user text
  query_hash             bytea NOT NULL,

  -- ---- what was done ---------------------------------------------------------
  branch                 text NOT NULL
    CHECK (branch IN ('CONTINUE','MONITOR_PANEL','SAFETY_BLOCK_FIRST',
                      'TEMPLATE_TAKEOVER','FAIL_CLOSED')),
  template_id            uuid,
  template_version       int,
  commercial_suppressed  boolean NOT NULL,    -- §4.0.6
  generation_blocked     boolean NOT NULL,    -- §4.1, ≥ URGENT
  needs_review           boolean NOT NULL,    -- §2.2.5b, WARNING-level DS content
  shadow_mode            boolean NOT NULL DEFAULT false,  -- §0.6 / AMB-17

  -- ---- §6.5 latency, from FIRST BYTE of the inbound message -------------------
  first_byte_at          timestamptz NOT NULL,
  scanner_started_at     timestamptz NOT NULL,
  scanner_completed_at   timestamptz NOT NULL,
  template_displayed_at  timestamptz,
  display_latency_ms     int,                 -- template_displayed_at - first_byte_at

  scanner_version        text NOT NULL,
  fail_safe_reason       text,                -- §4.0.9, null on the happy path
  data_region            char(2) NOT NULL REFERENCES public.region_registry(code),

  FOREIGN KEY (template_id, template_version)
    REFERENCES safety.safety_template(id, version),

  -- §4.0.3: the model may RAISE a rule-derived severity and never lower it.
  -- Expressed here as well as in obs.ai_call because this table is the one a
  -- false-negative review reads. A clamping bug is a write failure, not a
  -- silent one. Relies on red_flag_severity's declaration order (AMB-S-11).
  CONSTRAINT c_never_lowered CHECK (
    applied_severity >= rule_derived_severity
    AND (model_proposed_severity IS NULL
         OR applied_severity >= model_proposed_severity)
  ),

  -- §4.0.7: a flag at MONITOR or above must have its governed event row.
  -- Shadow mode is the one exception: an unadopted rule fires nowhere.
  CONSTRAINT c_monitor_has_event CHECK (
    applied_severity < 'MONITOR' OR shadow_mode OR event_id IS NOT NULL
  ),

  -- §4.1: at URGENT and above a pre-approved template is the only permitted
  -- output, and generation on the topic is blocked outright.
  CONSTRAINT c_urgent_is_template_only CHECK (
    applied_severity < 'URGENT' OR shadow_mode
    OR (template_id IS NOT NULL AND generation_blocked)
  ),

  -- §4.0.6: commercial content is suppressed at WARNING and above.
  CONSTRAINT c_commercial_suppressed_at_warning CHECK (
    applied_severity < 'WARNING' OR shadow_mode OR commercial_suppressed
  ),

  -- §4.0.5: at CRITICAL/EMERGENCY display is never gated. If the branch was a
  -- takeover, the display timestamp and its latency must both be present —
  -- §6.5 makes that latency a safety metric, and a metric that can be null is
  -- a metric that will be null.
  CONSTRAINT c_emergency_latency_recorded CHECK (
    applied_severity < 'CRITICAL' OR shadow_mode
    OR (template_displayed_at IS NOT NULL AND display_latency_ms IS NOT NULL)
  ),

  CONSTRAINT c_latency_ordered CHECK (
    template_displayed_at IS NULL OR template_displayed_at >= first_byte_at
  ),
  CONSTRAINT c_scan_ordered CHECK (
    scanner_completed_at >= scanner_started_at
    AND scanner_started_at >= first_byte_at
  ),
  -- §4.0.9: a fail-safe branch must say why it fired.
  CONSTRAINT c_fail_closed_attributed CHECK (
    branch <> 'FAIL_CLOSED' OR fail_safe_reason IS NOT NULL
  )
);

CREATE INDEX idx_rfl_severity_time  ON safety.red_flag_log (applied_severity, occurred_at);
CREATE INDEX idx_rfl_session        ON safety.red_flag_log (session_pseudonym, occurred_at);
CREATE INDEX idx_rfl_event          ON safety.red_flag_log (event_id);
CREATE INDEX idx_rfl_ruleset        ON safety.red_flag_log (rule_set_id, applied_severity);
-- the false-negative review's own query: NORMAL rows the model wanted to raise
CREATE INDEX idx_rfl_model_disagreed ON safety.red_flag_log (occurred_at)
  WHERE model_proposed_severity IS NOT NULL
    AND model_proposed_severity > rule_derived_severity;

COMMENT ON TABLE safety.red_flag_log IS
  'One row per scan, every severity including NORMAL. safety.red_flag_event is '
  'the governed §4.0.7 record (MONITOR and above); this is the complete audit '
  'surface §6.4 false-negative review and §6.5 latency measurement read. '
  'Append-only: UPDATE and DELETE are revoked below.';

-- ---------------------------------------------------------------------------
-- 4. Append-only, in the HP-RB-001 sense: revoked, not merely conventional.
-- ---------------------------------------------------------------------------
REVOKE UPDATE, DELETE ON safety.red_flag_log FROM PUBLIC;
GRANT  INSERT, SELECT  ON safety.red_flag_log TO redflag_role;
GRANT  INSERT, SELECT  ON safety.red_flag_event TO redflag_role;
GRANT  SELECT ON safety.red_flag_rule, safety.red_flag_rule_set,
                 safety.safety_template,
                 safety.emergency_contact_reference,
                 safety.emergency_facility_reference TO redflag_role;
-- BUG FOUND BY THE R12 GRANT AUDIT (HP-RECON-001 §2b, 4 Sep 2026). The column
-- list above used to stop at (floor_severity, set_by_event_id, set_at), which
-- looks right — those are the three columns a floor RAISE writes — and is
-- wrong twice over:
--
--   * recordRedFlagEvent's upsert re-arms a cleared floor in the same
--     statement: ON CONFLICT ... DO UPDATE SET ..., cleared_at = NULL,
--     cleared_by = NULL. PostgreSQL checks column-level UPDATE privilege when
--     it PLANS the statement, not when a conflict actually occurs, so this
--     failed with "permission denied for table session_severity_floor" on
--     EVERY red_flag_event write — no conflicting row required. §4.0.2's
--     persistence floor would have been violated for every flagged message.
--   * clearSessionSeverityFloor writes exactly those two columns and nothing
--     else, so a clinician could never clear a session floor at all.
--
-- Verified against this migration applied to a real PostgreSQL 16.13: both
-- statements raise as redflag_role before the fix and succeed after it. The
-- stub (chat-pipeline/db/010) grants UPDATE on the whole table, so CI was
-- green throughout — a false GREEN, the direction HP-RECON-001 §2b warns is
-- unguarded. migrations/test/schema_contract.test.sql now asserts these six
-- privileges directly.
--
-- The column list stays explicit rather than becoming a bare table grant:
-- session_pseudonym must remain unwritable, or a scanner could move a floor
-- from one session to another.
GRANT  INSERT, SELECT,
       UPDATE (floor_severity, set_by_event_id, set_at, cleared_at, cleared_by)
       ON safety.session_severity_floor TO redflag_role;
GRANT  INSERT ON obs.ai_call TO redflag_role;

-- The scanner reads rules; it may never write them. §4.0.3 makes the rule set
-- clinician-owned, and a scanner that can edit its own rules is not a control.
REVOKE INSERT, UPDATE, DELETE
  ON safety.red_flag_rule, safety.red_flag_rule_set, safety.safety_template,
     safety.emergency_contact_reference, safety.emergency_facility_reference
  FROM redflag_role;

-- ---------------------------------------------------------------------------
-- 5. RLS. Same shape as migration 012's red_flag_event.
-- ---------------------------------------------------------------------------
ALTER TABLE safety.red_flag_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE safety.emergency_facility_reference ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_rfl_region_scoped ON safety.red_flag_log
  FOR SELECT TO redflag_role
  USING (data_region = app.current_region());

CREATE POLICY p_rfl_insert_own_region ON safety.red_flag_log
  FOR INSERT TO redflag_role
  WITH CHECK (data_region = app.current_region());

-- §4.0.5: the reference tables are read by the emergency path. They are not
-- subject-scoped and must not be filtered by anything that could fail closed
-- on a lookup — an unreadable emergency number is the failure mode §3.12.1 is
-- written to prevent.
CREATE POLICY p_efr_readable ON safety.emergency_facility_reference
  FOR SELECT TO redflag_role
  USING (active);

-- ---------------------------------------------------------------------------
-- 6. §6.5 — the metric, as a view, so the dashboard cannot compute it its own
--    way. Latency is from first byte of the INBOUND message, not scanner start.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW safety.v_emergency_display_latency AS
SELECT
  date_trunc('hour', occurred_at)                     AS bucket,
  applied_severity,
  count(*)                                            AS scans,
  percentile_disc(0.50) WITHIN GROUP (ORDER BY display_latency_ms) AS p50_ms,
  percentile_disc(0.95) WITHIN GROUP (ORDER BY display_latency_ms) AS p95_ms,
  percentile_disc(0.99) WITHIN GROUP (ORDER BY display_latency_ms) AS p99_ms,
  max(display_latency_ms)                             AS max_ms
FROM safety.red_flag_log
WHERE applied_severity IN ('CRITICAL','EMERGENCY')
  AND NOT shadow_mode
  AND display_latency_ms IS NOT NULL
GROUP BY 1, 2;

COMMENT ON VIEW safety.v_emergency_display_latency IS
  '§6.5: emergency-template display latency, measured from first byte of the '
  'inbound user message. Charter §6.5 makes this latency itself a safety '
  'metric, which is why it is a view over the log rather than a client-side '
  'aggregation each dashboard defines for itself.';

-- ---------------------------------------------------------------------------
-- 7. §0.6 / AMB-17 — the launch gate, as a queryable fact rather than a memo.
--    Returns the adopted rule set for a jurisdiction/language, or no row. The
--    module fails closed on no row; see src/safety/redFlag/index.ts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION safety.adopted_rule_set(
  p_jurisdiction char(2),
  p_language     text
) RETURNS TABLE (
  rule_set_id    uuid,
  version_label  text,
  recall_floor   numeric(4,3),
  adopted_rules  bigint
)
LANGUAGE sql STABLE AS $$
  SELECT rs.id, rs.version_label, rs.recall_floor, count(r.id)
  FROM safety.red_flag_rule_set rs
  JOIN safety.red_flag_rule r
    ON r.rule_set_id = rs.id
   AND r.clinically_adopted           -- §0.6: an unsigned rule may not fire
   AND r.retired_at IS NULL
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

GRANT EXECUTE ON FUNCTION safety.adopted_rule_set(char(2), text) TO redflag_role;

COMMENT ON FUNCTION safety.adopted_rule_set(char(2), text) IS
  'Charter §0.6 and AMB-17: §4 is not adopted until the clinical lead signs the '
  'triggers and time-to-care windows. Zero rows here means the red-flag module '
  'has nothing signed to run, and the module refuses generative output rather '
  'than returning NORMAL. Returning NORMAL from an empty rule set would make '
  'an unsigned deployment look safe while detecting nothing.';
