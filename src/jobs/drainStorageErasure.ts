/**
 * HealthPlus (worker) — drains principal.storage_erasure_queue (migration 051).
 *
 * WHAT THIS CLOSES
 *
 * principal.erase_subject deletes the `patient_upload_document` row for an
 * erased subject, but never touched the bytes it pointed at in Supabase
 * Storage — migration 050 shipped with that gap named in a comment, not
 * closed. Migration 051 made erase_subject enqueue the object's coordinates
 * into `storage_erasure_queue` in the same transaction as the rest of the
 * Postgres-side erasure. This file is the other half: an out-of-process
 * worker that actually calls Supabase Storage's DELETE endpoint and clears
 * the queue row once it has.
 *
 * WHY THIS IS A SEPARATE "SCHEDULED" PROCESS, NOT A pg-boss JOB
 *
 * Same shape as src/jobs/computeSafetyMetrics.mjs and
 * chat-pipeline/worker/alert-worker.mjs: a queue that is itself a table,
 * drained by a small standalone process run on a schedule (Fly machine cron,
 * GitHub Actions, or a continuous poll loop), not enqueued through pg-boss.
 * There is no pg-boss job that would ever enqueue "drain the erasure
 * queue" — it is driven by the queue's own contents, the same reason
 * alert-worker.mjs polls `safety.clinician_alert` directly instead of
 * waiting on a job.
 *
 * CONNECTION: `jobPool('storageErasure')` (src/db/pool.ts) — connects as
 * `storage_erasure_role` when `DATABASE_URL_STORAGE_ERASURE` is set,
 * otherwise falls back to `DATABASE_URL` (queue_role), which cannot reach
 * `principal` at all and will fail closed rather than run under-privileged,
 * the same fallback contract every other role pool in that file already has.
 *
 * ONE TRANSACTION PER BATCH, same reason alert-worker.mjs gives: the row
 * locks `claim_storage_erasure_batch`'s FOR UPDATE SKIP LOCKED takes must be
 * held until the outcome (delete + clear the row, or record the failure) is
 * committed, or a second worker instance could pick up a row this one is
 * mid-way through. Unlike alert-worker.mjs, this worker's "commit the
 * outcome" step is preceded by a real network call (the Storage DELETE)
 * that must NOT be inside that transaction's lock window any longer than
 * necessary — it is called once per claimed row, its result recorded, and
 * the transaction is committed promptly after.
 *
 * Usage:
 *   node --import tsx src/jobs/drainStorageErasure.ts            # continuous poll
 *   node --import tsx src/jobs/drainStorageErasure.ts --once     # drain, report, exit (CI)
 *
 * Env: DATABASE_URL_STORAGE_ERASURE (or DATABASE_URL fallback), DATA_REGION,
 * SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (see src/lib/supabaseStorage.ts).
 *   STORAGE_ERASURE_POLL_INTERVAL_MS  default 30000 — this queue is not
 *     latency-sensitive the way §4.0.5 alerts are; erasure has no display
 *     deadline, only an eventual-completion one.
 *   STORAGE_ERASURE_BATCH_SIZE        default 20
 */
import type { PoolClient } from 'pg';
import { jobPool } from '../db/pool';
import { deleteStorageObject } from '../lib/supabaseStorage';

const POLL_INTERVAL_MS = Number(process.env.STORAGE_ERASURE_POLL_INTERVAL_MS ?? 30000);
const BATCH_SIZE = Number(process.env.STORAGE_ERASURE_BATCH_SIZE ?? 20);
const RUN_ONCE = process.argv.includes('--once');

interface QueuedErasure {
  id: string;
  subject_id: string;
  storage_bucket: string;
  storage_object_path: string;
  attempts: number;
}

async function claimBatch(client: PoolClient): Promise<QueuedErasure[]> {
  const { rows } = await client.query(
    `SELECT id, subject_id, storage_bucket, storage_object_path, attempts
       FROM principal.claim_storage_erasure_batch($1)`,
    [BATCH_SIZE],
  );
  return rows;
}

async function processOne(client: PoolClient, row: QueuedErasure): Promise<'DELETED' | 'FAILED'> {
  try {
    await deleteStorageObject(row.storage_bucket, row.storage_object_path);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error(
      `drainStorageErasure: DELETE failed for queue row ${row.id} ` +
        `(bucket=${row.storage_bucket}, path=${row.storage_object_path}, attempt ${row.attempts + 1}): ${message}`,
    );
    await client.query('SELECT principal.mark_storage_erasure_failed($1, $2)', [row.id, message.slice(0, 500)]);
    return 'FAILED';
  }

  // mark_storage_erasure_complete DELETEs the row outright (migration 051 §3
  // — nothing about a completed erasure is retained). No FOUND check needed
  // here beyond what the function itself already raises on.
  await client.query('SELECT principal.mark_storage_erasure_complete($1)', [row.id]);
  console.log(
    `drainStorageErasure: deleted ${row.storage_bucket}/${row.storage_object_path} ` +
      `(subject ${row.subject_id}) — Storage erasure complete.`,
  );
  return 'DELETED';
}

async function runBatch(): Promise<{ count: number; deleted: number; failed: number }> {
  const pool = jobPool('storageErasure');
  const client = await pool.connect();
  const tally = { DELETED: 0, FAILED: 0 };
  try {
    await client.query('BEGIN');
    const rows = await claimBatch(client);
    for (const row of rows) {
      const outcome = await processOne(client, row);
      tally[outcome] += 1;
    }
    await client.query('COMMIT');
    return { count: rows.length, deleted: tally.DELETED, failed: tally.FAILED };
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined);
    // Do NOT swallow — a row left PENDING is retried next cycle. A silently
    // eaten batch-level error (a connection drop mid-batch, say) would
    // instead look like an empty, healthy queue.
    console.error('drainStorageErasure: batch failed, rolling back and retrying next cycle:', err);
    return { count: 0, deleted: 0, failed: 0 };
  } finally {
    client.release();
  }
}

async function main() {
  console.log(
    `drainStorageErasure: starting (${RUN_ONCE ? 'drain-and-exit' : 'continuous poll'}, ` +
      `batch ${BATCH_SIZE}).`,
  );

  if (RUN_ONCE) {
    const result = await runBatch();
    console.log(
      `drainStorageErasure: drained ${result.count} row(s) — ${result.deleted} deleted, ` +
        `${result.failed} failed (left PENDING for retry).`,
    );
    // Exit non-zero on a failure so a CI/cron invocation surfaces it, the
    // same convention rf6_alert_delivery.sh's worker run relies on.
    process.exit(result.failed > 0 ? 1 : 0);
  }

  let shuttingDown = false;
  for (const sig of ['SIGINT', 'SIGTERM'] as const) {
    process.on(sig, () => {
      console.log(`drainStorageErasure: ${sig} received, finishing current batch then exiting.`);
      shuttingDown = true;
    });
  }

  while (!shuttingDown) {
    await runBatch();
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }
}

main().catch((err) => {
  console.error('drainStorageErasure: fatal error:', err);
  process.exit(1);
});
