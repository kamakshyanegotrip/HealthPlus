-- ============================================================================
-- MIGRATION 035 — THE ALERT WORKER CAN CLAIM A BATCH  (register item RF6-claim)
--
-- FOUND BY R13-roleci ON ITS FIRST RUN, IN SHIPPED CODE:
--
--     chat-pipeline/worker/alert-worker.mjs:129  as alert_role
--         permission denied for table clinician_alert
--
-- `alert_role` holds SELECT on safety.clinician_alert and no UPDATE, and that
-- is deliberate: every state transition it is allowed to make goes through the
-- SECURITY DEFINER functions migration 029 wrote — mark_alert_delivered,
-- mark_alert_undeliverable, acknowledge_alert. The table itself is read-only to
-- it by design.
--
-- But the worker's batch-claim query is
--
--     SELECT ... FROM safety.clinician_alert WHERE state = 'PENDING'
--      ORDER BY severity DESC, raised_at ASC LIMIT $1 FOR UPDATE SKIP LOCKED
--
-- and `FOR UPDATE` requires UPDATE privilege — it is a write lock, whatever the
-- statement's first word says. So the worker's FIRST query fails on every poll
-- and NO §4.1 CRITICAL/EMERGENCY CLINICIAN ALERT IS EVER DELIVERED. The worker
-- starts, logs a batch failure, rolls back, and retries forever.
--
-- RF6 shipped in PR #5 with a CI gate that connects as the owner, which is
-- exactly why this survived: as `postgres` the query is fine. HP-RECON-004 §1
-- is the general statement of that problem; this is one of its consequences.
--
-- ---------------------------------------------------------------------------
-- WHY A FUNCTION RATHER THAN `GRANT UPDATE`
--
-- Granting UPDATE would work and would undo the design. `alert_role` would then
-- be able to write any column of any alert row directly — including
-- `delivered_at` — and the three DEFINER functions that exist precisely so it
-- CANNOT do that would become advisory. Migration 029's shape is: the worker
-- may read alerts and may ask for specific, validated transitions. Claiming a
-- batch is one more such ask.
--
-- It would also need an UPDATE *policy*: RLS is on, and the only policy is
-- SELECT-scoped, so an UPDATE by alert_role would be denied by default-deny
-- anyway. Adding one to make a lock work is a lot of new surface for a lock.
--
-- ---------------------------------------------------------------------------
-- ⚠ THE THING A SECURITY DEFINER FUNCTION SILENTLY TAKES AWAY
--
-- safety.clinician_alert carries RLS and one policy:
--
--     p_alert_region_scoped  FOR SELECT TO alert_role
--     USING (data_region = app.current_region())
--
-- The table is owned by `postgres` and does NOT have FORCE ROW LEVEL SECURITY,
-- so RLS IS NOT APPLIED to the owner — and a SECURITY DEFINER function runs as
-- its owner. A naive DEFINER wrapper would therefore hand `alert_role` PENDING
-- alerts from every region, quietly deleting the ADR-003/ADR-004 residency
-- boundary while fixing a permission error. The fix would have been the
-- regression.
--
-- So the boundary is RESTATED IN THE BODY, as an explicit predicate, and the
-- function refuses to run at all when the region is unknown rather than
-- returning rows from everywhere or from nowhere. Both directions are covered
-- by migrations/test/rf6_claim.sh, including a control that seeds a second
-- region and asserts it is not returned.
--
-- ---------------------------------------------------------------------------
-- AND WHY IT RAISES INSTEAD OF RETURNING NOTHING
--
-- `data_region = NULL` is never true. A worker that connects without
-- app.data_region set would therefore claim zero alerts, forever, while every
-- log line said the batch completed successfully — which is SEC-1's failure
-- mode exactly, and this table is the §4.1 emergency path. An empty batch is
-- indistinguishable from a quiet night, so it must not be how a misconfigured
-- connection presents.
--
-- Migration 034 §3 sets `app.data_region` as a per-role default IN THIS
-- DATABASE for alert_role, so a real login already arrives with it. This
-- exception is the second lock on that door, not the first.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION safety.claim_alert_batch(p_limit integer)
RETURNS TABLE (
  id              uuid,
  event_id        uuid,
  severity        red_flag_severity,
  data_region     char(2),
  raised_at       timestamptz,
  notify_deadline timestamptz,
  ack_deadline    timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, safety, app, public
AS $$
DECLARE
  v_region char(2) := app.current_region();
BEGIN
  IF v_region IS NULL THEN
    RAISE EXCEPTION 'claim_alert_batch: app.data_region is not set on this connection'
      USING HINT = 'Every region-scoped predicate would be false and this worker would '
                   'report healthy empty batches forever (SEC-1). Migration 034 §3 sets a '
                   'per-role default; a pool that overrides it must set it deliberately.';
  END IF;

  IF p_limit IS NULL OR p_limit < 1 THEN
    RAISE EXCEPTION 'claim_alert_batch: p_limit must be a positive integer, got %', p_limit;
  END IF;

  -- The region predicate is NOT redundant with p_alert_region_scoped. This
  -- function runs as its owner, for whom that policy is not enforced. Remove
  -- this line and the worker silently gains cross-region reach.
  RETURN QUERY
    SELECT a.id, a.event_id, a.severity, a.data_region,
           a.raised_at, a.notify_deadline, a.ack_deadline
      FROM safety.clinician_alert a
     WHERE a.state = 'PENDING'
       AND a.data_region = v_region
     ORDER BY a.severity DESC, a.raised_at ASC
     LIMIT p_limit
       FOR UPDATE SKIP LOCKED;
END;
$$;

-- The locks this takes are the caller's, held to the caller's COMMIT — a
-- plpgsql function runs inside the calling transaction, so the worker's
-- one-transaction-per-batch discipline is unchanged. That is the whole reason
-- the claim can move into a function without changing its concurrency
-- semantics, and it is why the worker must keep its explicit BEGIN.
COMMENT ON FUNCTION safety.claim_alert_batch(integer) IS
  'RF6-claim. Claims up to p_limit PENDING alerts in the caller''s region with '
  'FOR UPDATE SKIP LOCKED, inside the caller''s transaction. SECURITY DEFINER '
  'because alert_role deliberately holds no UPDATE on safety.clinician_alert; '
  'the region predicate is explicit because RLS does not apply to the owner.';

REVOKE ALL ON FUNCTION safety.claim_alert_batch(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION safety.claim_alert_batch(integer) TO alert_role;

COMMIT;
