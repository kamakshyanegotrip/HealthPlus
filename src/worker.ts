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
 *
 * NEW (migration 050 / HP-RECON-007): this process also starts a small HTTP
 * listener (webhookServer.ts) for the Supabase Storage webhook that triggers
 * extractPatientUploadAttributes. See that file's header for why an inbound
 * HTTP surface now exists on what fly.toml used to describe as having none —
 * fly.toml and DEPLOY.md are both updated to match. WEBHOOK_PORT defaults to
 * 8080 and must match fly.toml's [http_service] internal_port.
 */
import { ensureBossStarted, boss } from './db/pool';
import { registerExtractClaimsFromProviderSubmissionWorker } from './jobs/extractClaimsFromProviderSubmission';
import { registerExtractPatientUploadAttributesWorker } from './jobs/extractPatientUploadAttributes';
import { startWebhookServer } from './lib/webhookServer';

async function main() {
  await ensureBossStarted();
  await registerExtractClaimsFromProviderSubmissionWorker(boss);
  await registerExtractPatientUploadAttributesWorker(boss);

  const webhookPort = Number(process.env.WEBHOOK_PORT ?? 8080);
  const httpServer = startWebhookServer(webhookPort);

  console.log(
    '[worker] pg-boss started, extractClaimsFromProviderSubmission and ' +
      `extractPatientUploadAttributes registered, webhook listener on :${webhookPort}.`,
  );

  // Fly.io sends SIGTERM on deploy/stop; pg-boss's own stop() waits for any
  // in-flight job handler to finish before releasing its connections, so a
  // deploy doesn't kill a job mid-transaction.
  const shutdown = async (signal: string) => {
    console.log(`[worker] received ${signal}, stopping gracefully...`);
    try {
      await new Promise<void>((resolve) => httpServer.close(() => resolve()));
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
