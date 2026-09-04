/**
 * HealthPlus — pg-boss worker process entrypoint.
 *
 * HP-OIR-003 build item 8 (deploy the pg-boss worker to Fly.io). This is the
 * always-on process Fly.io runs: it starts pg-boss against DATABASE_URL,
 * registers every job handler this repo defines, and stays alive handling
 * work until the process receives a shutdown signal — matching ADR-001 §3.4
 * ("never Vercel Functions"; pg-boss needs a long-running worker, not a
 * request-scoped function) and ADR-003 §2.3's choice of a Direct (not
 * pooled) Postgres connection for exactly this kind of persistent process.
 *
 * As more jobs are added to src/jobs/, register their worker here too — this
 * file is the one place that assembles "everything this deployment runs."
 */
import { ensureBossStarted, boss } from './db/pool';
import { registerExtractClaimsFromProviderSubmissionWorker } from './jobs/extractClaimsFromProviderSubmission';

async function main() {
  await ensureBossStarted();
  await registerExtractClaimsFromProviderSubmissionWorker(boss);

  console.log('[worker] pg-boss started, extractClaimsFromProviderSubmission registered.');

  // Fly.io sends SIGTERM on deploy/stop; pg-boss's own stop() waits for any
  // in-flight job handler to finish before releasing its connections, so a
  // deploy doesn't kill a job mid-transaction.
  const shutdown = async (signal: string) => {
    console.log(`[worker] received ${signal}, stopping pg-boss gracefully...`);
    try {
      await boss.stop({ graceful: true, timeout: 30_000 });
      console.log('[worker] stopped cleanly.');
      process.exit(0);
    } catch (err) {
      console.error('[worker] error during shutdown:', err);
      process.exit(1);
    }
  };
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));
}

main().catch((err) => {
  console.error('[worker] fatal error during startup:', err);
  process.exit(1);
});
