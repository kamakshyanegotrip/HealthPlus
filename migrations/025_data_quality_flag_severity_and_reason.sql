-- HealthPlus migration: 025 — first-class severity and reason on obs.data_quality_flag
-- Source: HP-DQE-001 Data Quality Engine — Automated Checks, §1
-- Extends: HP-SCHEMA-001 v0.5 migrations 001-024 (assumed applied)
--
-- obs.data_quality_flag (HP-SCHEMA-001 migration 005) has no `severity` column
-- and no `reason` column -- it has `detail jsonb`. Burying severity inside
-- `detail` works, but "show me every open CRITICAL flag" becomes a jsonb
-- operator scan instead of an indexed WHERE, which is the wrong trade for a
-- table whose entire purpose is to be triaged on a schedule. Additive only --
-- nothing already on disk changes shape; `detail` stays for the structured
-- trail each check already wants to keep.
--
-- Not yet run against a live database.

CREATE TYPE dq_flag_severity AS ENUM ('INFO', 'WARNING', 'CRITICAL');

ALTER TABLE obs.data_quality_flag
  ADD COLUMN severity dq_flag_severity NOT NULL DEFAULT 'WARNING',
  ADD COLUMN reason    text;   -- one human-readable line; `detail` keeps the structured trail

-- the query every on-call dashboard runs: open flags, worst first
CREATE INDEX idx_dq_open_severity ON obs.data_quality_flag (severity, detected_at)
  WHERE resolved_at IS NULL;

COMMENT ON COLUMN obs.data_quality_flag.reason IS
  'Human-readable, e.g. "COST claim c3f1... last verified 214 days ago; hard expiry is 180 days -- HARD_BLOCKED per HP-ESC 1.7.2." detail carries the same facts structured for re-computation.';

-- severity is three-valued by design (HP-DQE-001 §1): CRITICAL -- already
-- enforced (a hard_block was set, or a conflict has no rule to resolve it and
-- must be surfaced), nothing further to decide, only to review; WARNING --
-- not yet enforced, needs a human or a later pass before it becomes CRITICAL;
-- INFO -- provenance/audit noise worth keeping (a resolved-by-rule conflict
-- that still has to be statable under §1.8.2, even though nobody need act on it).
