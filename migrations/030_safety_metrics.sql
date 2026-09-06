-- ============================================================================
-- MIGRATION 030 — §6.5 SAFETY METRICS  (register item J3-4)
--
-- WHAT WAS MISSING
--
-- §6.5 names six primary safety metrics. Migration 005 built the series table
-- (obs.safety_metric_sample) and the three tables that feed it — fabrication_
-- block, abstention_event, review_queue_item — and migration 027 added
-- safety.v_emergency_display_latency. Nothing has ever queried any of them.
-- There is no metrics module, no registry of what the six metrics ARE, and no
-- row in the series table.
--
-- THE PROBLEM WITH JUST WRITING THE QUERIES
--
-- Two of the six cannot be computed at all today:
--
--   * red-flag recall needs the clinician-labelled gold set (CL9 / AMB-22),
--     and there is no clinical lead to label it;
--   * fabrication rate on adversarial evaluation needs an adversarial set
--     that does not exist.
--
-- `obs.safety_metric_sample.value` is `numeric NOT NULL`. So the table as
-- built can record "recall is 0.0" and can record nothing at all, but cannot
-- record "recall is unmeasurable". Those three are very different, and the
-- difference is the whole point: §6.4 makes a red-flag recall regression a
-- **release blocker**, and a release gate that reads a missing recall figure
-- as "no regression detected" passes precisely when it knows least.
--
-- This is the RF6 failure in a different table. A metric that cannot be
-- computed must not be recorded as a number, and must not be silently absent.
--
-- WHAT THIS MIGRATION ESTABLISHES
--
--   1. obs.safety_metric      — the registry. What each metric is, which
--                               Charter clause it serves, which direction is
--                               "better", and whether it gates a release.
--   2. A `status` on every sample: COMPUTED | NO_DATA | UNCOMPUTABLE, with
--      `value` nullable and constrained to be present exactly when COMPUTED.
--   3. Four views, one per computable metric, so the dashboard cannot compute
--      them its own way (the convention from 027 §6).
--   4. obs.record_metric_sample() — the only writer.
--   5. obs.v_release_gate — §6.4, fail-closed: an UNCOMPUTABLE recall BLOCKS.
--
-- §3.0.4 MADE STRUCTURAL
--
-- "abstention is a positive metric, and no metric may reward completeness over
-- abstention." The registry carries a `direction`, and a CHECK forbids
-- abstention_rate from ever being declared LOWER_IS_BETTER. AMB-13 asks
-- whether any existing product metric penalises abstention; this makes the
-- answer un-guessable for at least this table.
--
-- NUMBERING: migrations run to 029. Renumber-safe per HP-JOB-002's Ledger §3.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Role. Metrics are read-mostly and are computed out of band. A separate
--    role so the thing that reads every safety table to compute an aggregate
--    is not the thing that writes safety events.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'metrics_role') THEN
    CREATE ROLE metrics_role NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA obs, safety, public TO metrics_role;

-- ---------------------------------------------------------------------------
-- 1. Enums.
-- ---------------------------------------------------------------------------
CREATE TYPE metric_direction AS ENUM (
  'HIGHER_IS_BETTER',
  'LOWER_IS_BETTER',
  'NOT_A_TARGET'       -- observed and reported; explicitly not optimised
);

CREATE TYPE metric_status AS ENUM (
  'COMPUTED',        -- a real number, from real denominators
  'NO_DATA',         -- the query ran; the window held nothing to measure
  'UNCOMPUTABLE'     -- the inputs this metric needs do not exist at all
);

COMMENT ON TYPE metric_status IS
  'NO_DATA and UNCOMPUTABLE are not the same and must never be collapsed. '
  'NO_DATA means nothing happened in the window - a quiet week. UNCOMPUTABLE '
  'means the metric cannot be measured with what exists - no gold set, no '
  'adversarial suite. A dashboard may render NO_DATA as a gap in a line; it '
  'must render UNCOMPUTABLE as a statement that the number is unknown.';

-- ---------------------------------------------------------------------------
-- 2. The registry.
-- ---------------------------------------------------------------------------
CREATE TABLE obs.safety_metric (
  metric_key        text PRIMARY KEY,
  charter_clause    text NOT NULL,
  description       text NOT NULL,
  unit              text NOT NULL,
  direction         metric_direction NOT NULL,
  is_release_gate   boolean NOT NULL DEFAULT false,
  -- What the metric needs that may not exist. NULL means it is computable
  -- from tables this system already writes.
  blocked_on        text,
  dimensioned_by    text,   -- e.g. 'prohibition_class'; NULL for scalar metrics

  -- §3.0.4. Abstention is a positive metric. A system that measured
  -- abstention as a cost would be optimised toward answering when it should
  -- not, which is the exact failure §3 exists to prevent. Encoded here rather
  -- than remembered.
  CONSTRAINT c_abstention_is_never_a_cost
    CHECK (metric_key <> 'abstention_rate' OR direction <> 'LOWER_IS_BETTER')
);

INSERT INTO obs.safety_metric
  (metric_key, charter_clause, description, unit, direction, is_release_gate, blocked_on, dimensioned_by)
VALUES
  ('red_flag_recall', '§6.5, §6.4',
   'Proportion of clinician-labelled red-flag cases the scanner assigned at or above the labelled severity.',
   'ratio', 'HIGHER_IS_BETTER', true,
   'CL9 / AMB-22 — no clinician-labelled gold set exists, and no clinical lead to produce one (B2).',
   NULL),

  ('emergency_display_latency_ms_p95', '§6.5, §4.0.5',
   'p95 milliseconds from FIRST BYTE OF THE INBOUND USER MESSAGE to the CRITICAL/EMERGENCY template reaching the user. Not from scanner start.',
   'ms', 'LOWER_IS_BETTER', false, NULL, 'severity'),

  ('block_rate', '§6.5, §3.13',
   'Fabrication blocks per response audited, by §3 prohibition class.',
   'ratio', 'NOT_A_TARGET', false, NULL, 'prohibition_class'),

  ('fabrication_rate_adversarial', '§6.5, §6.4',
   'Proportion of adversarial evaluation prompts that produced a §3-prohibited emission reaching the validator boundary.',
   'ratio', 'LOWER_IS_BETTER', true,
   'No adversarial evaluation set exists. Distinct from the eval gold set; needs its own construction.',
   NULL),

  ('review_turnaround_h', '§6.5, §2.3.5b',
   'Median hours from review enqueue to decision. Reviews never time out into publication (§2.3.5b), so this measures a queue that blocks, not one that expires.',
   'hours', 'LOWER_IS_BETTER', false, NULL, NULL),

  ('abstention_rate', '§6.5, §3.0.4',
   'Abstention events per response audited. A POSITIVE metric: saying "I do not know" correctly is the system working.',
   'ratio', 'NOT_A_TARGET', false, NULL, 'reason');

COMMENT ON COLUMN obs.safety_metric.direction IS
  'NOT_A_TARGET is used deliberately for block_rate and abstention_rate. Both '
  'go up for good reasons (more prohibitions enforced, more honest refusals) '
  'and for bad ones (a worse corpus, a broken retriever). Declaring a target '
  'direction for either would invite tuning it, and §3.0.4 forbids that for '
  'abstention specifically.';

-- ---------------------------------------------------------------------------
-- 3. The sample table gains a status, a dimension, and a nullable value.
--
--    `value numeric NOT NULL` is what made "unmeasurable" unrepresentable.
--    Dropping the NOT NULL alone would let a NULL mean anything; the CHECK
--    below makes value present exactly when the status says there is one.
-- ---------------------------------------------------------------------------
ALTER TABLE obs.safety_metric_sample
  ADD COLUMN status              metric_status,
  ADD COLUMN dimension           text,
  ADD COLUMN uncomputable_reason text;

-- Existing rows: there are none (nothing has ever written here), but the
-- migration must be correct if that ever stops being true.
UPDATE obs.safety_metric_sample SET status = 'COMPUTED' WHERE status IS NULL;

ALTER TABLE obs.safety_metric_sample
  ALTER COLUMN status SET NOT NULL,
  ALTER COLUMN value  DROP NOT NULL;

ALTER TABLE obs.safety_metric_sample
  ADD CONSTRAINT c_value_present_iff_computed
    CHECK ((status = 'COMPUTED') = (value IS NOT NULL)),

  ADD CONSTRAINT c_uncomputable_has_reason
    CHECK ((status = 'UNCOMPUTABLE') = (uncomputable_reason IS NOT NULL)),

  -- A COMPUTED ratio must come from a real denominator. Recording 0/0 as
  -- "0.0" is how an empty window becomes a headline figure.
  ADD CONSTRAINT c_computed_has_denominator
    CHECK (status <> 'COMPUTED' OR denominator IS NULL OR denominator > 0),

  ADD CONSTRAINT c_no_data_has_no_numbers
    CHECK (status <> 'NO_DATA' OR (value IS NULL AND numerator IS NULL)),

  ADD CONSTRAINT c_window_ordered
    CHECK (window_end > window_start),

  ADD CONSTRAINT c_sample_metric_known
    FOREIGN KEY (metric_key) REFERENCES obs.safety_metric(metric_key);

-- The old uniqueness did not know about dimensions, so block_rate for two
-- prohibition classes in the same window would have collided.
ALTER TABLE obs.safety_metric_sample
  DROP CONSTRAINT IF EXISTS safety_metric_sample_metric_key_window_start_window_end_met_key;

CREATE UNIQUE INDEX uq_metric_sample
  ON obs.safety_metric_sample
     (metric_key, coalesce(dimension, ''), window_start, window_end, method_version);

CREATE INDEX idx_metric_sample_lookup
  ON obs.safety_metric_sample (metric_key, window_end DESC);

-- ---------------------------------------------------------------------------
-- 4. The four computable metrics, as views.
--
--    Definitions live here so a dashboard cannot quietly compute a different
--    number and call it the same thing — the same reasoning as 027 §6. Each
--    view returns one row per (window, dimension) with an explicit numerator
--    and denominator, so a reader can always see what a ratio was over.
-- ---------------------------------------------------------------------------

-- §6.5 / §4.0.5. Reads safety.red_flag_log, whose display_latency_ms is
-- measured from first byte of the INBOUND message. HP-ESC-201 Task 6's note:
-- measuring from scanner start makes the dashboard look healthy while the
-- user waits.
CREATE OR REPLACE VIEW obs.v_metric_emergency_latency AS
  SELECT date_trunc('day', l.occurred_at)              AS window_start,
         date_trunc('day', l.occurred_at) + interval '1 day' AS window_end,
         l.applied_severity::text                      AS dimension,
         count(*)                                      AS denominator,
         percentile_disc(0.95) WITHIN GROUP (ORDER BY l.display_latency_ms) AS value
    FROM safety.red_flag_log l
   WHERE l.applied_severity IN ('CRITICAL', 'EMERGENCY')
     AND NOT l.shadow_mode
     AND l.display_latency_ms IS NOT NULL
   GROUP BY 1, 2, 3;

-- §6.5 / §3.13. Blocks per audited response, by prohibition class. The
-- denominator is responses, not blocks — "how often did §3 have to stop
-- something" is only meaningful against how much was attempted.
--
-- Two grouping levels, and the second is not decoration. A per-class row can
-- only exist for a class that actually fired, so a day on which §3 blocked
-- NOTHING produces no per-class rows at all — and a missing row is
-- indistinguishable from a day the job did not run. The undimensioned row
-- (dimension IS NULL) is a LEFT JOIN, so "0 blocks out of 10 responses" is a
-- real, recorded 0.0. Zero is a measurement.
CREATE OR REPLACE VIEW obs.v_metric_block_rate AS
  WITH audited AS (
    SELECT date_trunc('day', a.occurred_at) AS d, count(*) AS n
      FROM obs.response_audit a
     GROUP BY 1
  )
  -- per prohibition class
  SELECT au.d                          AS window_start,
         au.d + interval '1 day'       AS window_end,
         b.prohibition_class           AS dimension,
         count(b.id)                   AS numerator,
         au.n                          AS denominator,
         round(count(b.id)::numeric / au.n, 6) AS value
    FROM audited au
    JOIN obs.fabrication_block b
      ON date_trunc('day', b.occurred_at) = au.d
   GROUP BY au.d, au.n, b.prohibition_class
  UNION ALL
  -- all classes together, including none
  SELECT au.d,
         au.d + interval '1 day',
         NULL::text,
         count(b.id),
         au.n,
         round(count(b.id)::numeric / au.n, 6)
    FROM audited au
    LEFT JOIN obs.fabrication_block b
      ON date_trunc('day', b.occurred_at) = au.d
   GROUP BY au.d, au.n;

-- §6.5 / §3.0.4. Same denominator as block_rate, deliberately: abstention and
-- blocking are two outcomes of the same population, and measuring them against
-- different bases would let one be traded off against the other unnoticed.
--
-- The undimensioned row matters more here than anywhere. A system that abstains
-- ZERO times over a real volume of traffic is not a system with nothing to
-- abstain from; it is a system that has stopped saying "I don't know". §3.0.4
-- makes abstention a positive metric, and a positive metric that silently
-- disappears when it reaches zero cannot do its job.
CREATE OR REPLACE VIEW obs.v_metric_abstention_rate AS
  WITH audited AS (
    SELECT date_trunc('day', a.occurred_at) AS d, count(*) AS n
      FROM obs.response_audit a
     GROUP BY 1
  )
  SELECT au.d                          AS window_start,
         au.d + interval '1 day'       AS window_end,
         e.reason                      AS dimension,
         count(e.id)                   AS numerator,
         au.n                          AS denominator,
         round(count(e.id)::numeric / au.n, 6) AS value
    FROM audited au
    JOIN obs.abstention_event e
      ON date_trunc('day', e.occurred_at) = au.d
   GROUP BY au.d, au.n, e.reason
  UNION ALL
  SELECT au.d,
         au.d + interval '1 day',
         NULL::text,
         count(e.id),
         au.n,
         round(count(e.id)::numeric / au.n, 6)
    FROM audited au
    LEFT JOIN obs.abstention_event e
      ON date_trunc('day', e.occurred_at) = au.d
   GROUP BY au.d, au.n;

-- §6.5 / §2.3.5b. Only DECIDED items. An undecided review is not a slow
-- turnaround, it is an open queue — counting it as a zero, or excluding the
-- window because of it, would both understate the problem. The open backlog
-- is its own view below.
CREATE OR REPLACE VIEW obs.v_metric_review_turnaround AS
  SELECT date_trunc('day', q.decided_at)              AS window_start,
         date_trunc('day', q.decided_at) + interval '1 day' AS window_end,
         count(*)                                     AS denominator,
         round(
           percentile_disc(0.50) WITHIN GROUP (
             ORDER BY EXTRACT(EPOCH FROM (q.decided_at - q.enqueued_at))
           )::numeric / 3600.0, 4)                    AS value
    FROM obs.review_queue_item q
   WHERE q.decided_at IS NOT NULL
   GROUP BY 1, 2;

-- Not a §6.5 metric, but the thing that makes review_turnaround honest:
-- reviews that have never been decided. §2.3.5b says review never times out
-- into publication, so a growing number here is a growing number of responses
-- that will never publish.
CREATE OR REPLACE VIEW obs.v_review_backlog AS
  SELECT count(*) FILTER (WHERE q.claimed_by IS NULL)     AS unclaimed,
         count(*)                                          AS open_total,
         min(q.enqueued_at)                                AS oldest_enqueued_at,
         max(now() - q.enqueued_at)                        AS longest_open
    FROM obs.review_queue_item q
   WHERE q.decided_at IS NULL;

-- ---------------------------------------------------------------------------
-- 5. The writer.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION obs.record_metric_sample(
  p_metric_key   text,
  p_dimension    text,
  p_window_start timestamptz,
  p_window_end   timestamptz,
  p_numerator    numeric,
  p_denominator  numeric,
  p_value        numeric,
  p_status       metric_status,
  p_method_version text,
  p_gold_set_version text DEFAULT NULL,
  p_uncomputable_reason text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, obs, public
AS $$
DECLARE
  v_metric obs.safety_metric%ROWTYPE;
  v_id     uuid;
BEGIN
  SELECT * INTO v_metric FROM obs.safety_metric WHERE metric_key = p_metric_key;
  IF NOT FOUND THEN
    RAISE EXCEPTION
      'obs.record_metric_sample: unknown metric "%". Add it to obs.safety_metric '
      'with its Charter clause and direction first — a metric with no registry '
      'row has no agreed definition.', p_metric_key;
  END IF;

  -- A metric the registry says is blocked cannot be reported as a number,
  -- whatever the caller computed. This is the guard that keeps a plausible
  -- placeholder from becoming a headline recall figure.
  IF v_metric.blocked_on IS NOT NULL AND p_status = 'COMPUTED' THEN
    RAISE EXCEPTION
      'obs.record_metric_sample: metric "%" is recorded as blocked on: %. '
      'It cannot be COMPUTED until that is resolved and the blocked_on is '
      'cleared. Record it UNCOMPUTABLE instead.', p_metric_key, v_metric.blocked_on;
  END IF;

  INSERT INTO obs.safety_metric_sample
    (id, metric_key, dimension, window_start, window_end,
     numerator, denominator, value, status, method_version,
     gold_set_version, uncomputable_reason, computed_at)
  VALUES
    (gen_random_uuid(), p_metric_key, p_dimension, p_window_start, p_window_end,
     p_numerator, p_denominator, p_value, p_status, p_method_version,
     p_gold_set_version, p_uncomputable_reason, now())
  ON CONFLICT (metric_key, coalesce(dimension, ''), window_start, window_end, method_version)
  DO UPDATE SET
     numerator = EXCLUDED.numerator,
     denominator = EXCLUDED.denominator,
     value = EXCLUDED.value,
     status = EXCLUDED.status,
     gold_set_version = EXCLUDED.gold_set_version,
     uncomputable_reason = EXCLUDED.uncomputable_reason,
     computed_at = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------
-- 6. §6.4 — the release gate, fail-closed.
--
--    "A red-flag recall regression is a release blocker."
--
--    A gate that only blocks on a MEASURED regression passes when recall is
--    unmeasured, which is today and every day until CL9 lands. That reading
--    is exactly backwards: the less the system knows about its own recall,
--    the more confident the gate becomes. §4.0.9's fail-safe principle
--    applied to release: no recall figure BLOCKS.
--
--    This view is advisory in the sense that no trigger enforces it — a human
--    or a pipeline reads it. What it will not do is stay silent.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW obs.v_release_gate AS
  WITH gated AS (
    SELECT m.metric_key, m.direction, m.blocked_on,
           s.value, s.status, s.window_end, s.gold_set_version,
           row_number() OVER (PARTITION BY m.metric_key ORDER BY s.window_end DESC) AS rn
      FROM obs.safety_metric m
      LEFT JOIN obs.safety_metric_sample s
        ON s.metric_key = m.metric_key AND s.dimension IS NULL
     WHERE m.is_release_gate
  ),
  latest AS (SELECT * FROM gated WHERE rn = 1 OR rn IS NULL)
  SELECT g.metric_key,
         coalesce(g.status::text, 'NEVER_COMPUTED') AS status,
         g.value,
         g.window_end AS measured_through,
         CASE
           WHEN g.status IS NULL          THEN 'BLOCK'
           WHEN g.status <> 'COMPUTED'    THEN 'BLOCK'
           ELSE 'PASS'
         END AS verdict,
         CASE
           WHEN g.status IS NULL THEN
             'No sample has ever been recorded for this release-gating metric. '
             || coalesce(g.blocked_on, 'No blocker recorded — the metrics job may not have run.')
           WHEN g.status <> 'COMPUTED' THEN
             'Latest sample is ' || g.status::text || '. '
             || coalesce(g.blocked_on, 'A release gate cannot be satisfied by an unmeasured metric.')
           ELSE NULL
         END AS reason
    FROM latest g;

COMMENT ON VIEW obs.v_release_gate IS
  'One row per release-gating §6.5 metric. verdict BLOCK means the metric is '
  'not measurable or has never been measured — NOT that a regression was '
  'detected. Both currently BLOCK, and will until CL9 produces a gold set and '
  'an adversarial suite is built. A green release gate here is a claim that '
  'red-flag recall is known.';

-- ---------------------------------------------------------------------------
-- 7. Coverage. Makes "how many of the six can we actually measure" a query
--    rather than a conversation.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW obs.v_metric_coverage AS
  SELECT m.metric_key,
         m.charter_clause,
         m.blocked_on IS NULL                       AS computable,
         m.blocked_on,
         m.is_release_gate,
         (SELECT max(s.window_end) FROM obs.safety_metric_sample s
           WHERE s.metric_key = m.metric_key)       AS last_window_end,
         (SELECT count(*) FROM obs.safety_metric_sample s
           WHERE s.metric_key = m.metric_key)       AS samples
    FROM obs.safety_metric m;

-- ---------------------------------------------------------------------------
-- 8. Grants. The metrics job reads widely and writes only through the
--    definer function — the same shape as 029 §10.
-- ---------------------------------------------------------------------------
GRANT SELECT ON obs.safety_metric, obs.safety_metric_sample TO metrics_role, hp_app, hp_reader;
GRANT SELECT ON obs.response_audit, obs.fabrication_block, obs.abstention_event,
                obs.review_queue_item TO metrics_role;
GRANT SELECT ON safety.red_flag_log TO metrics_role;
GRANT SELECT ON obs.v_metric_emergency_latency, obs.v_metric_block_rate,
                obs.v_metric_abstention_rate, obs.v_metric_review_turnaround,
                obs.v_review_backlog, obs.v_release_gate, obs.v_metric_coverage
  TO metrics_role, hp_app, hp_reader;

GRANT EXECUTE ON FUNCTION obs.record_metric_sample(
  text, text, timestamptz, timestamptz, numeric, numeric, numeric,
  metric_status, text, text, text) TO metrics_role;

-- No direct DML. record_metric_sample() enforces the registry and the
-- blocked_on rule; a role that could INSERT directly could write a recall
-- figure nobody can justify.
REVOKE INSERT, UPDATE, DELETE ON obs.safety_metric_sample FROM metrics_role, hp_app;
REVOKE INSERT, UPDATE, DELETE ON obs.safety_metric        FROM metrics_role, hp_app;
