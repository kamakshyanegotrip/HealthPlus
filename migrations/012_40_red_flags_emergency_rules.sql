-- HealthPlus migration: 11. Migration 012 — §40 `RED_FLAGS` / `EMERGENCY_RULES`
-- Source: HP-SCHEMA-001 Annex A Extension
-- Extracted verbatim from the design doc's SQL fences; not yet run against a live database.

-- ============================================================================
-- MIGRATION 012 — RED FLAGS & EMERGENCY RULES (§40 RED_FLAGS / EMERGENCY_RULES)
-- ============================================================================

-- §4.0.3: rules are clinician-owned and versioned as a SET, because recall is a
-- property of the set, not of any rule in it. §6.4 regresses against this version.
CREATE TABLE safety.red_flag_rule_set (
  id             uuid PRIMARY KEY,
  version_label  text NOT NULL,
  jurisdiction   char(2),
  language       text NOT NULL,
  approved_by    uuid NOT NULL REFERENCES principal.clinician(user_id),
  approved_at    timestamptz NOT NULL,
  effective_from timestamptz NOT NULL,
  superseded_by  uuid REFERENCES safety.red_flag_rule_set(id),
  retired_at     timestamptz,
  gold_set_version text,                -- §6.4: what it was validated against
  recall_floor   numeric(4,3),          -- §4.0.3 published recall floor
  UNIQUE (version_label, jurisdiction, language),
  CONSTRAINT c_set_not_self_supersede CHECK (superseded_by IS DISTINCT FROM id)
);

CREATE TRIGGER trg_rule_set_supersede
  AFTER UPDATE ON safety.red_flag_rule_set
  FOR EACH ROW EXECUTE FUNCTION evidence.cascade_supersession('red_flag_rule_set');

ALTER TABLE safety.red_flag_rule
  ADD COLUMN rule_set_id     uuid REFERENCES safety.red_flag_rule_set(id),
  ADD COLUMN clinical_domain text REFERENCES safety.clinical_domain(code),
  ADD COLUMN jurisdiction    char(2),
  -- §0.6 / AMB-17: §4 is NOT ADOPTED until the clinical lead signs the triggers and
  -- time-to-care windows. A rule that has not been signed must not be able to fire.
  ADD COLUMN clinically_adopted boolean NOT NULL DEFAULT false,
  ADD COLUMN adopted_by      uuid REFERENCES principal.clinician(user_id),
  ADD COLUMN adopted_at      timestamptz,
  ADD CONSTRAINT c_adoption_attributed
    CHECK (clinically_adopted = false OR (adopted_by IS NOT NULL AND adopted_at IS NOT NULL));

ALTER TABLE safety.safety_template
  ADD COLUMN rule_set_id  uuid REFERENCES safety.red_flag_rule_set(id),
  -- §4.3.4: an untranslated template falls back to approved English plus the local
  -- emergency number — never to machine translation of safety-critical text.
  ADD COLUMN is_fallback  boolean NOT NULL DEFAULT false,
  ADD COLUMN machine_translated boolean NOT NULL DEFAULT false,
  ADD CONSTRAINT c_no_mt_safety_text CHECK (machine_translated = false);

-- §3.12.1: a MAINTAINED reference table. A missing entry results in "call your local
-- emergency number", never a guessed one — which is why there is no default and no
-- nullable fallback string anywhere in this table.
CREATE TABLE safety.emergency_contact_reference (
  id             uuid PRIMARY KEY,
  country        char(2) NOT NULL,
  subdivision    text,                  -- state/province where the number differs
  contact_kind   text NOT NULL
    CHECK (contact_kind IN ('EMERGENCY','AMBULANCE','POISON','CRISIS_LINE','POLICE')),
  number_e164    text NOT NULL,
  label          text NOT NULL,
  language       text NOT NULL,
  source_id      uuid NOT NULL REFERENCES evidence.evidence_source(id),  -- Tier 1 expected
  last_verified_at timestamptz NOT NULL,
  verified_by    uuid REFERENCES principal.app_user(id),
  active         boolean NOT NULL DEFAULT true,
  UNIQUE (country, subdivision, contact_kind, language)
);

COMMENT ON TABLE safety.emergency_contact_reference IS
  'The one table in this schema that references evidence_source directly rather than '
  'through a claim. Deliberate: §4.0.5 forbids gating emergency output on anything, '
  'including a claim-confidence lookup. The source binding is for provenance and the '
  '§1.7.1 re-verification clock, not for a runtime gate.';

ALTER TABLE domain.cessation_support
  ADD CONSTRAINT fk_cessation_contact
    FOREIGN KEY (contact_ref_id) REFERENCES safety.emergency_contact_reference(id);

-- §4.0.7: every flag at MONITOR and above, persisted with its full context.
CREATE TABLE safety.red_flag_event (
  id                   uuid PRIMARY KEY,
  audit_id             uuid REFERENCES obs.response_audit(id),
  subject_pseudonym    bytea NOT NULL,       -- never subject_id; ADR-003 §2.3
  session_pseudonym    bytea NOT NULL,
  occurred_at          timestamptz NOT NULL,
  severity             red_flag_severity NOT NULL,
  rule_id              uuid,
  rule_version         int,
  rule_set_id          uuid REFERENCES safety.red_flag_rule_set(id),
  trigger_detail       jsonb NOT NULL,       -- which pattern matched; no free user text
  template_id          uuid,
  template_version     int,
  action_taken         text NOT NULL,        -- 'TEMPLATE_SHOWN'|'INTERSTITIAL'|'TAKEOVER'
                                             -- |'PANEL_ADDED'|'ESCALATED'
  commercial_suppressed boolean NOT NULL,    -- §4.0.6
  -- §6.5: latency measured from first byte of the INBOUND message, not scanner start.
  first_byte_at        timestamptz NOT NULL,
  scanner_started_at   timestamptz,
  template_displayed_at timestamptz,
  clinician_notified_at timestamptz,
  clinician_id         uuid REFERENCES principal.clinician(user_id),
  outcome              text,
  data_region          char(2) NOT NULL REFERENCES public.region_registry(code),
  FOREIGN KEY (rule_id, rule_version)         REFERENCES safety.red_flag_rule(id, version),
  FOREIGN KEY (template_id, template_version) REFERENCES safety.safety_template(id, version),
  -- §4.0.2: MONITOR is the floor for persistence
  CONSTRAINT c_event_at_least_monitor CHECK (severity >= 'MONITOR'),
  -- §4.1: at URGENT and above a pre-approved template is the only permitted output
  CONSTRAINT c_urgent_needs_template CHECK (
    severity < 'URGENT' OR template_id IS NOT NULL),
  -- §4.0.5: at CRITICAL/EMERGENCY display is never gated on notification
  CONSTRAINT c_emergency_display_not_gated CHECK (
    severity < 'CRITICAL' OR template_displayed_at IS NOT NULL),
  CONSTRAINT c_latency_ordered CHECK (
    template_displayed_at IS NULL OR template_displayed_at >= first_byte_at)
);
CREATE INDEX idx_rfe_severity_time ON safety.red_flag_event (severity, occurred_at);

-- §4.0.8: levels are per-session sticky upward until a clinician or a rule clears them.
CREATE TABLE safety.session_severity_floor (
  session_pseudonym bytea PRIMARY KEY,
  floor_severity    red_flag_severity NOT NULL,
  set_by_event_id   uuid NOT NULL REFERENCES safety.red_flag_event(id),
  set_at            timestamptz NOT NULL,
  cleared_at        timestamptz,
  cleared_by        uuid REFERENCES principal.clinician(user_id),
  -- a floor may only be cleared by a named clinician or an explicit resolution rule
  CONSTRAINT c_clear_attributed CHECK (
    cleared_at IS NULL OR cleared_by IS NOT NULL)
);

ALTER TABLE safety.red_flag_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE safety.red_flag_rule  ENABLE ROW LEVEL SECURITY;
