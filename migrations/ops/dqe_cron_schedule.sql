-- HealthPlus ops script (NOT a numbered migration): pg_cron wiring for the
-- five DQ checks in migrations 026a-026e.
-- Source: HP-DQE-001 Data Quality Engine — Automated Checks, §7
--
-- Cadence rationale (full detail in HP-DQE-001 §7): the half-life table sets
-- the schedule, not a house convention. EPIDEMIOLOGY (30d half-life / 90d hard
-- expiry) is the shortest clock in the system, COST (90d/180d) the
-- second-shortest — DQ-1 and DQ-4 run daily because §1.7.2 is a
-- publish-blocking compliance gate, not merely a quality signal. DQ-2/DQ-3 run
-- daily incremental + weekly full resweep. DQ-5 runs weekly only, because the
-- guideline corpus itself changes on a clinical body's multi-year cycle.
--
-- Requires the pg_cron extension (available on Supabase, enable separately —
-- see the Supabase dashboard's Database > Extensions page). Requires
-- migrations 001-026 already applied and dqe_role already granted EXECUTE on
-- each function (each migration file grants this itself).
--
-- Not yet run against a live database.

SELECT cron.schedule('dqe-daily-outdated',      '0 2 * * *', 'SELECT evidence.dqe_check_outdated()');
SELECT cron.schedule('dqe-daily-missing-source','15 2 * * *','SELECT evidence.dqe_check_missing_source()');
SELECT cron.schedule('dqe-daily-duplicates',    '30 2 * * *','SELECT evidence.dqe_check_duplicates()');       -- incremental
SELECT cron.schedule('dqe-daily-contradictions','45 2 * * *','SELECT evidence.dqe_check_contradictions()');   -- incremental
SELECT cron.schedule('dqe-weekly-duplicates',   '0 3 * * 0', 'SELECT evidence.dqe_check_duplicates()');       -- full resweep, Sundays
SELECT cron.schedule('dqe-weekly-contradictions','15 3 * * 0','SELECT evidence.dqe_check_contradictions()');  -- full resweep, Sundays
SELECT cron.schedule('dqe-weekly-guidelines',   '30 3 * * 0', 'SELECT evidence.dqe_check_conflicting_guidelines()');

-- The "incremental vs full" distinction for DQ-2/DQ-3 is a scoping choice for
-- a fuller implementation (e.g. a p_since parameter restricting the source
-- scan), not a second function — the design as migrated runs correctly as a
-- full scan every time; safe to call this way if incremental scoping isn't
-- built yet, just costlier at scale.
