#!/usr/bin/env node
// GAP RESOLVED: "no worker consuming side_effect_job, etc." —
// sideEffectDispatcher.ts (src/lib/pipeline/sideEffectDispatcher.ts) has
// always been "the producer side only" (its own header comment says so).
// This is the consumer: a small polling worker that dequeues
// `side_effect_job` rows with SELECT ... FOR UPDATE SKIP LOCKED (so
// multiple worker instances/processes never double-process the same row —
// the standard Postgres queue-worker pattern, and the reason HP-ADR-001 §3.2
// chose "Postgres-backed queueing" in the first place), processes each by
// `kind`, and marks it DONE or FAILED.
//
// HONEST SCOPE NOTE: this repo has no clinician-dashboard table, no pager/
// SMS integration, and no email service configured anywhere (grep confirms
// no `clinician_review` or similar table exists in db/*.sql — the queue
// producer side names CLINICIAN_REVIEW/POST_HOC_SAMPLE_REVIEW/EMERGENCY_
// CONCURRENT_NOTIFY jobs, but nothing downstream to actually deliver them
// to a person exists yet, in this repo or this sandbox). So each handler
// below does the honest thing: log, in structured form, exactly what a real
// integration would need to do next (create a review record, call a paging
// API, send a notification) — and marks the job DONE, since "logged and
// ready for a real integration to pick up" is what this worker can
// truthfully claim to have accomplished. What IS real and now proven
// end-to-end: the dequeue-with-locking, retry-on-failure, and status
// lifecycle (PENDING -> IN_PROGRESS -> DONE|FAILED) against a live
// Postgres — none of which had ever been run before this file existed.
//
// Usage:
//   node worker/side-effect-worker.mjs           # continuous poll loop (real deployment mode)
//   node worker/side-effect-worker.mjs --once     # drain whatever is queued right now, then exit (CI/local testing)
//
// Env: DATABASE_URL (same connection string the app itself uses — this
// worker connects as hp_app too, per HP-RB-001 §2; db/010 already grants
// hp_app SELECT/INSERT/UPDATE on side_effect_job, so no new grant was
// needed). WORKER_POLL_INTERVAL_MS (default 2000), WORKER_BATCH_SIZE
// (default 5), WORKER_MAX_ATTEMPTS (default 3, after which a failing job is
// marked FAILED instead of requeued).
import pg from 'pg';

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  console.error('side-effect-worker: DATABASE_URL is not set — refusing to start (same requirement src/lib/db.ts has).');
  process.exit(1);
}

const pool = new pg.Pool({ connectionString: DATABASE_URL, max: 4 });

const POLL_INTERVAL_MS = Number(process.env.WORKER_POLL_INTERVAL_MS ?? 2000);
const BATCH_SIZE = Number(process.env.WORKER_BATCH_SIZE ?? 5);
const MAX_ATTEMPTS = Number(process.env.WORKER_MAX_ATTEMPTS ?? 3);
const RUN_ONCE = process.argv.includes('--once');

let shuttingDown = false;
process.on('SIGINT', () => {
  console.log('side-effect-worker: SIGINT received, finishing current batch then exiting.');
  shuttingDown = true;
});
process.on('SIGTERM', () => {
  console.log('side-effect-worker: SIGTERM received, finishing current batch then exiting.');
  shuttingDown = true;
});

/**
 * Dequeues up to BATCH_SIZE PENDING jobs, atomically flipping them to
 * IN_PROGRESS in the same statement (UPDATE ... FROM (SELECT ... FOR UPDATE
 * SKIP LOCKED)) so two worker processes racing this same query never both
 * claim the same row — SKIP LOCKED is what makes that safe without an
 * explicit application-level lock table.
 */
async function claimBatch() {
  const { rows } = await pool.query(
    `UPDATE side_effect_job
        SET status = 'IN_PROGRESS', started_at = now(), attempts = attempts + 1
      WHERE id IN (
        SELECT id FROM side_effect_job
         WHERE status = 'PENDING'
         ORDER BY enqueued_at
         LIMIT $1
         FOR UPDATE SKIP LOCKED
      )
      RETURNING id, kind, payload, data_region, enqueued_at, attempts`,
    [BATCH_SIZE],
  );
  return rows;
}

async function markDone(id) {
  await pool.query(`UPDATE side_effect_job SET status = 'DONE', finished_at = now() WHERE id = $1`, [id]);
}

async function markFailedOrRequeue(id, attempts, err) {
  console.error(`side-effect-worker: job ${id} failed (attempt ${attempts}/${MAX_ATTEMPTS}):`, err instanceof Error ? err.message : err);
  if (attempts >= MAX_ATTEMPTS) {
    await pool.query(`UPDATE side_effect_job SET status = 'FAILED', finished_at = now() WHERE id = $1`, [id]);
  } else {
    // Back to PENDING for a later poll to pick up again — enqueued_at is
    // NOT reset, so a repeatedly-failing job doesn't jump the queue ahead
    // of jobs that haven't been tried yet.
    await pool.query(`UPDATE side_effect_job SET status = 'PENDING' WHERE id = $1`, [id]);
  }
}

// ---- per-kind handlers ------------------------------------------------
// Every handler below is a STUB — see the file header's honest scope note.
// Each is written so swapping in a real integration later is a single
// function body change, not a restructuring of the worker.

async function handleClinicianReview(job) {
  // A real integration would INSERT into a clinician_review queue table (or
  // call an external review-workflow API) and probably page/notify the
  // on-call clinician per HP-ADR-001's own framing of this as a queue that
  // "must never time out." Neither exists in this repo yet.
  console.log('[CLINICIAN_REVIEW] would create a review-queue entry for audit', job.payload.auditId, '— reason:', job.payload.reason, '— severity:', job.payload.severity);
}

async function handlePostHocSampleReview(job) {
  // A real integration would add this response to a sampling dashboard /
  // export it to whatever tool AMB-10's (still-open) sampling-rate decision
  // eventually feeds.
  console.log('[POST_HOC_SAMPLE_REVIEW] would enqueue audit', job.payload.auditId, 'for post-hoc sampled review, category', job.payload.category);
}

async function handleEmergencyConcurrentNotify(job) {
  // SUPERSEDED BY RF6 (migration 029 + worker/alert-worker.mjs).
  //
  // This handler used to be:
  //
  //     console.log('[EMERGENCY_CONCURRENT_NOTIFY] would page on-call ...')
  //
  // and then the job was marked DONE. That is the defect RF6 closed: a
  // response that paged nobody recorded the same state as one that reached a
  // clinician in ten seconds, and red_flag_event.clinician_notified_at — a
  // column that has existed since migration 012 — was never written by
  // anything at all.
  //
  // Notification is no longer this worker's business, and deliberately no
  // longer any worker's business to REMEMBER: migration 029's AFTER INSERT
  // trigger raises a safety.clinician_alert row inside the red_flag_event's
  // own transaction, so the alert exists whether or not this job is ever
  // enqueued, delivered or processed. alert-worker.mjs drains it and is the
  // only thing that can mark it delivered.
  //
  // This handler is kept, and does nothing but assert that invariant, because
  // the producer (sideEffectDispatcher.ts) still enqueues the job and an
  // unrecognised kind throws. If the alert is missing, something has removed
  // the trigger and the job SHOULD fail — a job that quietly succeeds here is
  // exactly what went wrong the first time.
  const { rows } = await pool.query(
    `SELECT a.id, a.state
       FROM safety.clinician_alert a
       JOIN safety.red_flag_event e ON e.id = a.event_id
      WHERE e.audit_id = $1`,
    [job.payload.auditId],
  );
  if (rows.length === 0) {
    throw new Error(
      `EMERGENCY_CONCURRENT_NOTIFY: audit ${job.payload.auditId} was ${job.payload.severity} ` +
      `but no safety.clinician_alert exists for it. Migration 029's ` +
      `trg_raise_alert_for_event has not fired — nobody is being alerted.`,
    );
  }
  console.log(
    `[EMERGENCY_CONCURRENT_NOTIFY] audit ${job.payload.auditId} (${job.payload.severity}): ` +
    `alert ${rows[0].id} is ${rows[0].state}; delivery is alert-worker.mjs's job.`,
  );
}

const HANDLERS = {
  CLINICIAN_REVIEW: handleClinicianReview,
  POST_HOC_SAMPLE_REVIEW: handlePostHocSampleReview,
  EMERGENCY_CONCURRENT_NOTIFY: handleEmergencyConcurrentNotify,
};

async function processJob(job) {
  const handler = HANDLERS[job.kind];
  if (!handler) {
    // An unrecognized kind is a bug (a producer added a new job kind
    // without a matching handler here) — fail loudly rather than silently
    // marking it done, so it surfaces instead of vanishing.
    throw new Error(`no handler registered for job kind "${job.kind}"`);
  }
  await handler(job);
}

async function runBatch() {
  const jobs = await claimBatch();
  if (jobs.length === 0) return 0;

  for (const job of jobs) {
    try {
      await processJob(job);
      await markDone(job.id);
      console.log(`side-effect-worker: job ${job.id} (${job.kind}) done.`);
    } catch (err) {
      await markFailedOrRequeue(job.id, job.attempts, err);
    }
  }
  return jobs.length;
}

async function main() {
  console.log(`side-effect-worker: starting (${RUN_ONCE ? 'drain-and-exit mode' : `continuous poll, every ${POLL_INTERVAL_MS}ms`}, batch size ${BATCH_SIZE}).`);

  if (RUN_ONCE) {
    let totalProcessed = 0;
    let processedThisRound;
    do {
      processedThisRound = await runBatch();
      totalProcessed += processedThisRound;
    } while (processedThisRound > 0);
    console.log(`side-effect-worker: drained ${totalProcessed} job(s), exiting.`);
    await pool.end();
    return;
  }

  while (!shuttingDown) {
    const processed = await runBatch();
    if (processed === 0) {
      await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
    }
  }
  await pool.end();
  console.log('side-effect-worker: stopped.');
}

main().catch((err) => {
  console.error('side-effect-worker: fatal error', err);
  process.exit(1);
});
