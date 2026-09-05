-- ============================================================================
-- MIGRATION 029 — CLINICIAN ALERT DELIVERY  (register item RF6)
--
-- WHAT WAS WRONG
--
-- safety.red_flag_event has carried `clinician_notified_at` and `clinician_id`
-- since migration 012. Nothing has ever written either one. The only thing
-- downstream of a CRITICAL or EMERGENCY classification was
-- handleEmergencyConcurrentNotify() in worker/side-effect-worker.mjs, whose
-- entire body is a console.log — and which then marks the job DONE.
--
-- So the system's recorded state for "on-call clinician paged" (§4.1 level 5)
-- was: a job row reading DONE, a log line, and two NULL columns. A response
-- that alerted nobody was indistinguishable, in the data, from one that
-- reached a clinician in ten seconds. §4.0.9 forbids failing open to
-- generative output; recording a delivery that did not happen is the same
-- failure wearing different clothes, and it is worse for being invisible.
--
-- WHAT THIS MIGRATION ESTABLISHES
--
--   1. safety.alert_channel        — the channels that exist, each declaring
--                                    whether it can DELIVER to a human.
--   2. safety.on_call_roster       — who is paged, per region and severity.
--   3. safety.clinician_alert      — one durable row per notifiable event,
--                                    with a state machine and an SLA deadline.
--   4. safety.alert_sla            — the deadlines, NOT clinically adopted.
--   5. A deferrable constraint trigger: an event at URGENT+ may not exist
--      without an alert row.
--   6. safety.mark_alert_delivered / _acknowledged / _undeliverable — the
--      only ways the state moves, and the only writer of
--      red_flag_event.clinician_notified_at.
--
-- THE SPINE OF THE DESIGN
--
-- Only a channel that can prove delivery to a person may move an alert to
-- DELIVERED, and only a DELIVERED alert may stamp clinician_notified_at.
-- The LOG channel — which is the only channel this deployment currently has —
-- declares delivers = false, so it is structurally incapable of claiming a
-- notification occurred. It can only produce UNDELIVERABLE.
--
-- That is deliberate and it is the point of the migration. Today HealthPlus
-- cannot page anyone: there is no clinical lead (CL1-CL10), no roster, and no
-- SMS/pager/email provider (ADR-002 zero-cost stack). Before this migration
-- that fact was a comment in a worker file. After it, it is a row in
-- safety.clinician_alert with state UNDELIVERABLE and a reason, countable in
-- a §6.5 metric and impossible to mistake for success.
--
-- §3.0.3's "default-deny is structural, not persuasive" applied to delivery:
-- the system is not asked to remember that a log line is not a page. It is
-- made unable to record one as such.
--
-- WHAT THIS MIGRATION DOES NOT DO
--
-- It does not make anyone reachable. Populating safety.on_call_roster and
-- adding a delivering channel are CL-items and an ops decision respectively,
-- and both are named in the register. This migration makes their absence
-- loud instead of silent, which is the part that does not require a clinician
-- to be hired first.
--
-- NUMBERING: migrations run to 028 (transplant commercial block). Per
-- HP-JOB-002's Migration Numbering Ledger §3 this file is renumber-safe: no
-- object name encodes the number and every guard is idempotent.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Role. Same convention as 027 §1 — NOLOGIN, guarded, cluster-wide.
--    The alert worker is not the red-flag scanner: the scanner writes events
--    inside the request path, the alert worker reads them out of band and
--    talks to the outside world. Separate roles so a compromised notifier
--    cannot author safety events, and a compromised scanner cannot mark
--    things delivered.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'alert_role') THEN
    CREATE ROLE alert_role NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA safety, obs, public TO alert_role;

-- ---------------------------------------------------------------------------
-- 1. Channels, and the delivers flag that the rest of the file hangs on.
--
--    UNIQUE (code, delivers) exists so clinician_alert can carry a composite
--    FK to it. That makes `channel_delivers` on the alert row a denormalisation
--    the database itself proves correct, rather than one a trigger has to
--    police — the same technique migration 012 uses for (rule_id, version).
--    A plain CHECK can then reference it, which a CHECK could not do across
--    a table boundary.
-- ---------------------------------------------------------------------------
CREATE TABLE safety.alert_channel (
  code        text    PRIMARY KEY,
  delivers    boolean NOT NULL,
  description text    NOT NULL,
  UNIQUE (code, delivers)
);

COMMENT ON COLUMN safety.alert_channel.delivers IS
  'True only if this channel puts the alert in front of a human and can '
  'report back that it did. A channel that writes to a log, a file, or a '
  'table nobody watches is delivers = false. Only a delivering channel can '
  'move an alert to DELIVERED and stamp red_flag_event.clinician_notified_at.';

INSERT INTO safety.alert_channel (code, delivers, description) VALUES
  ('LOG',     false, 'Structured log line only. Reaches no person. The only channel this deployment currently has, which is why every alert it handles ends UNDELIVERABLE.'),
  ('EMAIL',   true,  'Email to the on-call address. Not configured (ADR-002: no email provider in the zero-cost stack).'),
  ('SMS',     true,  'SMS to the on-call number. Not configured.'),
  ('PAGER',   true,  'Paging API (PagerDuty/Opsgenie shape). Not configured.'),
  ('WEBHOOK', true,  'HTTP POST to a customer-operated endpoint that acknowledges receipt. Not configured.');

-- ---------------------------------------------------------------------------
-- 2. The SLA. NOT ADOPTED — same treatment as §4.4.1's time-to-care windows
--    (AMB-17) and safety.red_flag_rule.clinically_adopted. These numbers come
--    from CGP-001 §8.2, which labels them "proposed SLAs — for the clinical
--    lead to confirm or correct". They are reference data so that the worker
--    reads the adopted deadline rather than hard-coding a proposal, and so
--    that "nobody has agreed to these" is queryable.
-- ---------------------------------------------------------------------------
CREATE TABLE safety.alert_sla (
  severity            red_flag_severity PRIMARY KEY,
  notify_within       interval NOT NULL,
  acknowledge_within  interval NOT NULL,
  clinically_adopted  boolean  NOT NULL DEFAULT false,
  adopted_by          uuid     REFERENCES principal.clinician(user_id),
  adopted_at          timestamptz,
  CONSTRAINT c_alert_sla_at_least_urgent
    CHECK (severity >= 'URGENT'::red_flag_severity),
  CONSTRAINT c_alert_sla_adoption_complete
    CHECK ((clinically_adopted = false AND adopted_by IS NULL AND adopted_at IS NULL)
        OR (clinically_adopted = true  AND adopted_by IS NOT NULL AND adopted_at IS NOT NULL))
);

-- §4.1: URGENT is "notified within the URGENT SLA"; CRITICAL and EMERGENCY
-- are "mandatory and immediate". Immediate is expressed as zero, not as a
-- small number, because §4.0.5 makes the notification concurrent with display
-- — there is no budget to spend.
INSERT INTO safety.alert_sla (severity, notify_within, acknowledge_within) VALUES
  ('URGENT',    interval '15 minutes', interval '4 hours'),
  ('CRITICAL',  interval '0',          interval '4 hours'),
  ('EMERGENCY', interval '0',          interval '1 hour');

-- ---------------------------------------------------------------------------
-- 3. The roster. Empty on purpose — see the header.
--
--    No CHECK forces it to be non-empty: a constraint that made the table
--    refuse to be empty would just make migration 029 unrunnable, and the
--    honest state of this system today is that there IS no on-call clinician.
--    The emptiness is surfaced instead by safety.resolve_on_call() returning
--    NULL and the alert becoming UNDELIVERABLE with reason NO_ROSTER_ENTRY.
-- ---------------------------------------------------------------------------
CREATE TABLE safety.on_call_roster (
  id             uuid PRIMARY KEY,
  clinician_id   uuid NOT NULL REFERENCES principal.clinician(user_id),
  data_region    char(2) NOT NULL REFERENCES public.region_registry(code),
  min_severity   red_flag_severity NOT NULL,
  channel        text NOT NULL REFERENCES safety.alert_channel(code),
  address        text NOT NULL,   -- email / E.164 / endpoint. Never a name.
  effective_from timestamptz NOT NULL,
  effective_to   timestamptz,
  CONSTRAINT c_roster_window_ordered
    CHECK (effective_to IS NULL OR effective_to > effective_from),
  CONSTRAINT c_roster_at_least_urgent
    CHECK (min_severity >= 'URGENT'::red_flag_severity)
);

CREATE INDEX idx_roster_lookup
  ON safety.on_call_roster (data_region, min_severity, effective_from);

-- ---------------------------------------------------------------------------
-- 4. The alert itself.
--
--    state machine:  PENDING ──> DELIVERED ──> ACKNOWLEDGED
--                        └────> UNDELIVERABLE
--
--    UNDELIVERABLE is terminal and is NOT a failure of this table — it is the
--    correct, recorded outcome when there is no roster entry or no delivering
--    channel. It is what makes the current state of the system countable.
-- ---------------------------------------------------------------------------
CREATE TABLE safety.clinician_alert (
  id                uuid PRIMARY KEY,
  event_id          uuid NOT NULL REFERENCES safety.red_flag_event(id),
  severity          red_flag_severity NOT NULL,
  data_region       char(2) NOT NULL REFERENCES public.region_registry(code),

  raised_at         timestamptz NOT NULL,
  notify_deadline   timestamptz NOT NULL,
  ack_deadline      timestamptz NOT NULL,

  state             text NOT NULL,
  attempts          integer NOT NULL DEFAULT 0,
  last_attempt_at   timestamptz,

  -- Resolved at delivery time, not at raise time: the roster can change
  -- between an event being raised and the worker picking it up, and the
  -- record should say who was actually reached.
  channel           text,
  channel_delivers  boolean,
  clinician_id      uuid REFERENCES principal.clinician(user_id),

  delivered_at      timestamptz,
  acknowledged_at   timestamptz,
  acknowledged_by   uuid REFERENCES principal.clinician(user_id),
  undeliverable_reason text,

  CONSTRAINT c_alert_state_known
    CHECK (state IN ('PENDING', 'DELIVERED', 'ACKNOWLEDGED', 'UNDELIVERABLE')),

  CONSTRAINT c_alert_at_least_urgent
    CHECK (severity >= 'URGENT'::red_flag_severity),

  -- The composite FK. This is what makes channel_delivers trustworthy.
  CONSTRAINT c_alert_channel_capability
    FOREIGN KEY (channel, channel_delivers)
    REFERENCES safety.alert_channel (code, delivers),

  CONSTRAINT c_alert_channel_pair_together
    CHECK ((channel IS NULL) = (channel_delivers IS NULL)),

  -- THE RULE. A non-delivering channel can never produce a delivery.
  CONSTRAINT c_only_delivering_channel_delivers
    CHECK (state NOT IN ('DELIVERED', 'ACKNOWLEDGED')
           OR channel_delivers = true),

  CONSTRAINT c_delivered_has_timestamp_and_person
    CHECK (state NOT IN ('DELIVERED', 'ACKNOWLEDGED')
           OR (delivered_at IS NOT NULL AND clinician_id IS NOT NULL)),

  CONSTRAINT c_acknowledged_has_timestamp_and_person
    CHECK ((state = 'ACKNOWLEDGED')
           = (acknowledged_at IS NOT NULL AND acknowledged_by IS NOT NULL)),

  CONSTRAINT c_undeliverable_has_reason
    CHECK ((state = 'UNDELIVERABLE') = (undeliverable_reason IS NOT NULL)),

  CONSTRAINT c_ack_after_delivery
    CHECK (acknowledged_at IS NULL OR delivered_at IS NULL
           OR acknowledged_at >= delivered_at),

  CONSTRAINT c_deadlines_ordered
    CHECK (ack_deadline >= notify_deadline AND notify_deadline >= raised_at)
);

CREATE UNIQUE INDEX uq_alert_per_event ON safety.clinician_alert (event_id);
CREATE INDEX idx_alert_pending ON safety.clinician_alert (state, notify_deadline)
  WHERE state = 'PENDING';
CREATE INDEX idx_alert_unacked ON safety.clinician_alert (state, ack_deadline)
  WHERE state = 'DELIVERED';

-- ---------------------------------------------------------------------------
-- 5. An event at URGENT+ may not exist without an alert.
--
--    Deferrable, so the event and its alert go in inside one transaction in
--    either order — the same shape as evidence.claim_requires_source() in
--    migration 001_003, and for the same reason: §4.0.7 requires the event
--    persisted WITH clinician identity and outcome, and an alert that only
--    exists if a later fire-and-forget HTTP call succeeded is not persistence.
--
--    This is the constraint that makes RF6 more than a worker change. Before
--    it, "did every URGENT+ response raise an alert?" was a question you
--    answered by reading code. Now it is a question the database will not let
--    you answer wrongly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION safety.event_requires_alert() RETURNS trigger AS $$
BEGIN
  IF NEW.severity >= 'URGENT'::red_flag_severity
     AND NOT EXISTS (SELECT 1 FROM safety.clinician_alert a WHERE a.event_id = NEW.id)
  THEN
    RAISE EXCEPTION
      'HP-ESC 4.1: red_flag_event % is % and has no safety.clinician_alert row. '
      'Levels 3-5 carry mandatory clinician involvement; an event at this '
      'severity may not exist without the alert record that proves it was '
      'raised.', NEW.id, NEW.severity;
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_event_requires_alert
  AFTER INSERT OR UPDATE ON safety.red_flag_event
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION safety.event_requires_alert();

-- ---------------------------------------------------------------------------
-- 6. Raising. Called in the same transaction as the event insert.
--
--    Deadlines come from safety.alert_sla whether or not it is adopted — an
--    unadopted deadline is still the best available and a NULL deadline would
--    disable breach detection entirely. Adoption governs whether a breach is
--    a contractual failure, not whether it is measured.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION safety.raise_alert(p_event_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, safety, principal, public
AS $$
DECLARE
  v_ev     safety.red_flag_event%ROWTYPE;
  v_sla    safety.alert_sla%ROWTYPE;
  v_id     uuid;
BEGIN
  SELECT * INTO v_ev FROM safety.red_flag_event WHERE id = p_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'safety.raise_alert: no red_flag_event %', p_event_id;
  END IF;

  IF v_ev.severity < 'URGENT'::red_flag_severity THEN
    RETURN NULL;  -- levels 0-2 carry no mandatory notification (§4.1)
  END IF;

  SELECT * INTO v_sla FROM safety.alert_sla WHERE severity = v_ev.severity;
  IF NOT FOUND THEN
    -- §4.0.9 fail-safe: a missing SLA row escalates to the tightest one
    -- rather than defaulting to a generous deadline or to none.
    SELECT * INTO v_sla FROM safety.alert_sla ORDER BY acknowledge_within ASC LIMIT 1;
  END IF;

  INSERT INTO safety.clinician_alert
    (id, event_id, severity, data_region, raised_at, notify_deadline, ack_deadline, state)
  VALUES
    (gen_random_uuid(), p_event_id, v_ev.severity, v_ev.data_region,
     v_ev.occurred_at,
     v_ev.occurred_at + v_sla.notify_within,
     v_ev.occurred_at + v_sla.notify_within + v_sla.acknowledge_within,
     'PENDING')
  ON CONFLICT (event_id) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM safety.clinician_alert WHERE event_id = p_event_id;
  END IF;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- 6b. Raising is automatic.
--
--     §3.0.3: default-deny is structural, not persuasive. The same applies
--     here in the positive direction — raising an alert is a mechanical
--     consequence of an event's severity, with no decision in it, so it must
--     not depend on an application remembering to make a call. The previous
--     design did depend on that (sideEffectDispatcher enqueued a job, not
--     awaited, from the request path) and the consequence was that the alert
--     existed only if an HTTP handler got that far.
--
--     With this trigger the constraint trigger in §5 stops being a rule the
--     app must satisfy and becomes what it should be: a check that this
--     trigger has not been dropped or subverted. Both are kept. One creates
--     the row, the other refuses to let the event exist without it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION safety.raise_alert_for_event() RETURNS trigger AS $$
BEGIN
  IF NEW.severity >= 'URGENT'::red_flag_severity THEN
    PERFORM safety.raise_alert(NEW.id);
  END IF;
  RETURN NULL;  -- AFTER trigger; return value is ignored
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_raise_alert_for_event
  AFTER INSERT ON safety.red_flag_event
  FOR EACH ROW EXECUTE FUNCTION safety.raise_alert_for_event();

-- ---------------------------------------------------------------------------
-- 7. Resolving who is on call. Returns no rows when the roster is empty,
--    which is today's answer everywhere.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION safety.resolve_on_call(
  p_region char(2), p_severity red_flag_severity, p_at timestamptz)
RETURNS TABLE (clinician_id uuid, channel text, address text)
LANGUAGE sql
STABLE
AS $$
  SELECT r.clinician_id, r.channel, r.address
    FROM safety.on_call_roster r
    JOIN safety.alert_channel c ON c.code = r.channel
   WHERE r.data_region  = p_region
     AND r.min_severity <= p_severity
     AND r.effective_from <= p_at
     AND (r.effective_to IS NULL OR r.effective_to > p_at)
     AND c.delivers                 -- a non-delivering channel is not on call
   ORDER BY r.min_severity DESC, r.effective_from DESC;
$$;

-- ---------------------------------------------------------------------------
-- 8. State transitions. These functions are the ONLY writers of
--    red_flag_event.clinician_notified_at — see the grant revocation in §10.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION safety.mark_alert_delivered(
  p_alert_id uuid, p_channel text, p_clinician_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, safety, principal, public
AS $$
DECLARE
  v_delivers boolean;
  v_event    uuid;
BEGIN
  SELECT delivers INTO v_delivers FROM safety.alert_channel WHERE code = p_channel;
  IF v_delivers IS NULL THEN
    RAISE EXCEPTION 'safety.mark_alert_delivered: unknown channel %', p_channel;
  END IF;
  IF NOT v_delivers THEN
    -- Belt as well as the c_only_delivering_channel_delivers braces: refuse
    -- here too, so the caller gets a message naming the actual rule rather
    -- than a constraint violation it has to decode.
    RAISE EXCEPTION
      'safety.mark_alert_delivered: channel % does not deliver to a person. '
      'Use safety.mark_alert_undeliverable(). A log line is not a page.',
      p_channel;
  END IF;

  UPDATE safety.clinician_alert
     SET state = 'DELIVERED',
         channel = p_channel,
         channel_delivers = true,
         clinician_id = p_clinician_id,
         delivered_at = now(),
         last_attempt_at = now(),
         attempts = attempts + 1
   WHERE id = p_alert_id AND state = 'PENDING'
  RETURNING event_id INTO v_event;

  IF v_event IS NULL THEN
    RAISE EXCEPTION 'safety.mark_alert_delivered: alert % is not PENDING', p_alert_id;
  END IF;

  -- §4.0.7's "clinician identity" half, written for the first time.
  UPDATE safety.red_flag_event
     SET clinician_notified_at = now(),
         clinician_id = p_clinician_id
   WHERE id = v_event;
END $$;

CREATE OR REPLACE FUNCTION safety.mark_alert_undeliverable(
  p_alert_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, safety, public
AS $$
BEGIN
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'safety.mark_alert_undeliverable: a reason is required';
  END IF;
  UPDATE safety.clinician_alert
     SET state = 'UNDELIVERABLE',
         undeliverable_reason = p_reason,
         last_attempt_at = now(),
         attempts = attempts + 1
   WHERE id = p_alert_id AND state = 'PENDING';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'safety.mark_alert_undeliverable: alert % is not PENDING', p_alert_id;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION safety.acknowledge_alert(
  p_alert_id uuid, p_clinician_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, safety, principal, public
AS $$
BEGIN
  UPDATE safety.clinician_alert
     SET state = 'ACKNOWLEDGED',
         acknowledged_at = now(),
         acknowledged_by = p_clinician_id
   WHERE id = p_alert_id AND state = 'DELIVERED';
  IF NOT FOUND THEN
    RAISE EXCEPTION
      'safety.acknowledge_alert: alert % is not DELIVERED. An alert that was '
      'never delivered cannot be acknowledged.', p_alert_id;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 9. §6.5 metrics. Views, so the dashboard cannot compute them its own way —
--    same reasoning as 027 §6.
-- ---------------------------------------------------------------------------

-- Breaches, open right now. The worker escalates from this.
CREATE OR REPLACE VIEW safety.v_alert_sla_breach AS
  SELECT a.id, a.event_id, a.severity, a.data_region, a.state,
         a.raised_at, a.notify_deadline, a.ack_deadline,
         CASE WHEN a.state = 'PENDING'   AND now() > a.notify_deadline THEN 'NOT_NOTIFIED'
              WHEN a.state = 'DELIVERED' AND now() > a.ack_deadline    THEN 'NOT_ACKNOWLEDGED'
         END AS breach_kind
    FROM safety.clinician_alert a
   WHERE (a.state = 'PENDING'   AND now() > a.notify_deadline)
      OR (a.state = 'DELIVERED' AND now() > a.ack_deadline);

-- The one that matters for honesty. If this view is non-empty, the platform
-- classified something at URGENT+ and reached nobody. It is expected to be
-- non-empty for every such event until a roster and a delivering channel
-- exist — that is the current, true state of the system, and it should show
-- up on a dashboard rather than in a code comment.
CREATE OR REPLACE VIEW safety.v_alerts_reaching_nobody AS
  SELECT a.id, a.event_id, a.severity, a.data_region, a.raised_at,
         a.state, a.undeliverable_reason, a.attempts
    FROM safety.clinician_alert a
   WHERE a.state IN ('PENDING', 'UNDELIVERABLE')
      OR a.channel_delivers IS NOT TRUE;

COMMENT ON VIEW safety.v_alerts_reaching_nobody IS
  'Every URGENT+ event whose alert has not demonstrably reached a person. '
  'Non-empty is the honest current state (no roster, no delivering channel), '
  'not a bug in this view. Register items RF6-roster and RF6-channel close it.';

-- ---------------------------------------------------------------------------
-- 10. Grants.
--
--     The revocations are the load-bearing half. HP-RECON-001 §2b found that
--     column-level UPDATE privileges are checked at PLAN time, so a missing
--     grant fails every write in the statement rather than only the guarded
--     column — which is exactly what makes this enforceable: alert_role and
--     redflag_role hold NO update privilege on red_flag_event's notification
--     columns at all, so no application code path can stamp
--     clinician_notified_at except through mark_alert_delivered(), which is
--     SECURITY DEFINER and owned by the migration runner.
-- ---------------------------------------------------------------------------
GRANT SELECT ON safety.alert_channel, safety.alert_sla, safety.on_call_roster
  TO alert_role, redflag_role, hp_app, hp_reader;

GRANT SELECT ON safety.clinician_alert TO alert_role, hp_app, hp_reader;
GRANT SELECT ON safety.v_alert_sla_breach, safety.v_alerts_reaching_nobody
  TO alert_role, hp_app, hp_reader;

-- The scanner raises alerts (in the event's own transaction) but may not
-- resolve them. The notifier resolves them but may not raise them.
GRANT EXECUTE ON FUNCTION safety.raise_alert(uuid) TO redflag_role, hp_app;
GRANT EXECUTE ON FUNCTION safety.resolve_on_call(char(2), red_flag_severity, timestamptz)
  TO alert_role;
GRANT EXECUTE ON FUNCTION safety.mark_alert_delivered(uuid, text, uuid) TO alert_role;
GRANT EXECUTE ON FUNCTION safety.mark_alert_undeliverable(uuid, text)   TO alert_role;
GRANT EXECUTE ON FUNCTION safety.acknowledge_alert(uuid, uuid)          TO alert_role, hp_app;

-- No direct DML on the alert table for anyone but the definer functions.
REVOKE INSERT, UPDATE, DELETE ON safety.clinician_alert FROM alert_role, redflag_role, hp_app;
-- And no way to hand-stamp a notification.
REVOKE UPDATE ON safety.red_flag_event FROM alert_role, redflag_role, hp_app;

-- ---------------------------------------------------------------------------
-- 11. RLS. Same shape as 027 §5.
-- ---------------------------------------------------------------------------
ALTER TABLE safety.clinician_alert ENABLE ROW LEVEL SECURITY;
ALTER TABLE safety.on_call_roster  ENABLE ROW LEVEL SECURITY;

CREATE POLICY p_alert_region_scoped ON safety.clinician_alert
  FOR SELECT TO alert_role
  USING (data_region = app.current_region());

CREATE POLICY p_roster_region_scoped ON safety.on_call_roster
  FOR SELECT TO alert_role
  USING (data_region = app.current_region());
