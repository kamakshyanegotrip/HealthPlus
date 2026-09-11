/**
 * HealthPlus (worker) — Supabase Storage webhook receiver.
 *
 * WHY THIS EXISTS ON THIS PROCESS, AND WHY fly.toml DID NOT HAVE ONE BEFORE.
 * fly.toml's header comment called this "a background worker with no
 * inbound HTTP traffic" — true when it only ran pg-boss jobs enqueued by
 * something else. The patient-upload feature was asked for as "triggered by
 * a Supabase Storage webhook" on this same Fly.io worker, so this file adds
 * exactly that: a small HTTP listener alongside pg-boss, doing only enough
 * work to be safe to run inline (verify the request, insert one row, enqueue
 * one job, respond) — the heavy part (downloading the file, calling Claude
 * with vision input) stays in the pg-boss job
 * (extractPatientUploadAttributes.ts), asynchronous to this handler, which
 * is the whole reason ADR-001 ruled out Vercel Functions for this pipeline
 * in the first place. This endpoint does not reopen that argument; it just
 * does the trigger step ADR-001's own pipeline shape (fetch -> parse ->
 * extract -> ...) puts before the queue.
 *
 * WHAT SUPABASE ACTUALLY SENDS. Supabase Database Webhooks (the mechanism
 * for firing an HTTP request on a table INSERT, which is how a Storage
 * upload is observed — the object lands as a row in `storage.objects`) POST
 * a JSON body shaped:
 *
 *   { type: "INSERT", table: "objects", schema: "storage",
 *     record: { id, bucket_id, name, owner_id, metadata: { mimetype, size }, ... },
 *     old_record: null }
 *
 * AUTHENTICATION — RECONFIRMED 2026-09-10 against supabase.com/docs/guides
 * /database/webhooks and community discussion (github.com/orgs/supabase
 * /discussions/14115). Supabase Database Webhooks still carry no built-in
 * request signature or HMAC of any kind — the webhook is just a stored
 * `net.http_post(url, body, params, headers, timeout)` call the database
 * fires on row insert, and `headers` is a static JSON object you set once at
 * webhook-creation time (Database -> Webhooks, or the `net.http_post` call
 * behind it). A static shared-secret header, checked with a constant-time
 * comparison, IS the documented mechanism — that is what this handler does.
 * It is not the strongest thing Supabase users do: the community's fallback
 * for stronger integrity protection is to hand-roll HMAC-SHA256 signing
 * (the "Standard Webhooks" pattern — a Postgres trigger signs the payload
 * with pgcrypto and a vault secret, sending an id/timestamp/signature
 * triple the receiver verifies and checks isn't replayed). That is *not*
 * implemented here — it is meaningfully more setup (a vault secret, a
 * signing trigger on Supabase's side, timestamp/replay checking on this
 * side) for a receiver that already sits behind TLS and a bearer secret,
 * and it was not asked for. If this endpoint's threat model changes (e.g.
 * the webhook secret needs to be shared with a party you don't fully
 * trust), upgrading to that pattern is the documented next step, not a
 * mystery to research from scratch.
 *
 * WHY owner_id, NOT THE STORAGE PATH, NAMES THE PATIENT. record.owner_id
 * (or the older `owner` column, handled as a fallback) is the auth.uid() of
 * whoever uploaded the object under Supabase's standard Storage RLS model —
 * it is set by the database from the authenticated session, not by
 * whatever path the client chose to upload to. Trusting a path segment
 * instead (e.g. "patient-uploads/<uuid>/file.pdf") would let a client name
 * any subject id it likes in the path; owner_id cannot be spoofed the same
 * way. The bucket is still checked against PATIENT_UPLOAD_BUCKET so this
 * receiver only acts on the bucket it is meant for, in case the webhook is
 * (mis)configured across all of `storage.objects`.
 */
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { randomUUID, timingSafeEqual } from 'node:crypto';
import { jobPool, ensureBossStarted } from '../db/pool';
import { fromPgClient } from './pgBossAdapter';
import { SUPPORTED_MIME_TYPES } from './supabaseStorage';
import { QUEUE_NAME as EXTRACT_QUEUE_NAME } from '../jobs/extractPatientUploadAttributes';

const WEBHOOK_PATH = '/webhooks/supabase-storage/patient-upload';
const PATIENT_UPLOAD_BUCKET = process.env.PATIENT_UPLOAD_BUCKET ?? 'patient-uploads';

interface StorageObjectRecord {
  id?: string;
  bucket_id?: string;
  name?: string;
  owner?: string | null;
  owner_id?: string | null;
  metadata?: { mimetype?: string; size?: number } | null;
}

interface DatabaseWebhookPayload {
  type?: string;
  table?: string;
  schema?: string;
  record?: StorageObjectRecord;
}

function readBody(req: IncomingMessage): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function isAuthorized(req: IncomingMessage): boolean {
  const expected = process.env.SUPABASE_STORAGE_WEBHOOK_SECRET;
  if (!expected) {
    // Fail closed. A webhook receiver with no configured secret is not
    // "open in dev" — it is a live endpoint that writes patient-linked
    // rows and enqueues an Anthropic call, reachable by anyone who finds
    // the URL.
    return false;
  }
  const header = req.headers['x-webhook-secret'];
  const provided = Array.isArray(header) ? header[0] : header;
  if (!provided) return false;
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

async function handlePatientUploadWebhook(req: IncomingMessage, res: ServerResponse): Promise<void> {
  // Blocked pending a residency decision — see worker.ts's header. Checked
  // before auth, deliberately: a misconfigured or leaked webhook secret
  // should not be able to get further than an authorized one while this
  // feature is off. Doubles up with worker.ts not registering the job at
  // all, so even a request that somehow got past this would enqueue nothing
  // anyone processes.
  if (process.env.PATIENT_UPLOAD_RESIDENCY_ACKNOWLEDGED !== 'yes') {
    res.writeHead(503).end('patient upload extraction is not enabled on this deployment');
    return;
  }

  if (!isAuthorized(req)) {
    res.writeHead(401).end('unauthorized');
    return;
  }

  let payload: DatabaseWebhookPayload;
  try {
    payload = JSON.parse((await readBody(req)).toString('utf8'));
  } catch {
    res.writeHead(400).end('invalid json');
    return;
  }

  if (payload.type !== 'INSERT' || payload.schema !== 'storage' || payload.table !== 'objects') {
    // Not an error — a webhook can be configured broadly; anything that
    // isn't a new Storage object insert is simply not this receiver's job.
    res.writeHead(200).end('ignored');
    return;
  }

  const record = payload.record;
  if (!record || record.bucket_id !== PATIENT_UPLOAD_BUCKET) {
    res.writeHead(200).end('ignored: wrong bucket');
    return;
  }

  const subjectId = record.owner_id ?? record.owner ?? null;
  const objectPath = record.name;
  const mimeType = record.metadata?.mimetype ?? 'application/octet-stream';

  if (!subjectId || !objectPath) {
    // Permanent, not retryable: Supabase did not give us what this receiver
    // needs. Logged rather than silently 200'd, so a misconfigured bucket
    // (e.g. anonymous uploads with no owner) is visible in the logs instead
    // of just dropping uploads on the floor.
    console.error(
      JSON.stringify({ event: 'patient_upload_webhook_rejected', reason: 'missing owner or path', record }),
    );
    res.writeHead(200).end('ignored: no owner or path');
    return;
  }

  if (!SUPPORTED_MIME_TYPES.has(mimeType)) {
    console.warn(
      JSON.stringify({ event: 'patient_upload_webhook_unsupported_mime', mimeType, objectPath }),
    );
    res.writeHead(200).end('ignored: unsupported mime type');
    return;
  }

  // Transactional insert + enqueue, same pattern as
  // extractClaimsFromProviderSubmission's claim insert + embed-claim send:
  // the row and its processing job commit or roll back together.
  const pool = jobPool('patientUpload');
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const documentId = randomUUID();
    const insertResult = await client.query(
      `INSERT INTO principal.patient_upload_document
         (id, subject_id, data_region, storage_bucket, storage_object_path, mime_type, byte_size)
       VALUES ($1, $2, current_setting('app.data_region', true), $3, $4, $5, $6)
       ON CONFLICT (storage_bucket, storage_object_path) DO NOTHING
       RETURNING id`,
      [documentId, subjectId, PATIENT_UPLOAD_BUCKET, objectPath, mimeType, record.metadata?.size ?? null],
    );

    if (insertResult.rowCount === 0) {
      // Duplicate delivery (Database Webhooks do not guarantee exactly-once)
      // for an object this receiver has already recorded. Not an error.
      await client.query('ROLLBACK');
      res.writeHead(200).end('duplicate: already recorded');
      return;
    }

    const boss = await ensureBossStarted();
    await boss.send(
      EXTRACT_QUEUE_NAME,
      { documentId },
      { db: fromPgClient(client) },
    );

    await client.query('COMMIT');
    res.writeHead(202).end('accepted');
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined);
    console.error(JSON.stringify({ event: 'patient_upload_webhook_error', error: String(err) }));
    // 500 so Supabase's webhook delivery retries — this failure is on our
    // side (DB/connection), not a permanent rejection of the payload.
    res.writeHead(500).end('internal error');
  } finally {
    client.release();
  }
}

export function startWebhookServer(port: number): ReturnType<typeof createServer> {
  const server = createServer((req, res) => {
    if (req.method === 'POST' && req.url === WEBHOOK_PATH) {
      void handlePatientUploadWebhook(req, res);
      return;
    }
    if (req.method === 'GET' && req.url === '/healthz') {
      res.writeHead(200).end('ok');
      return;
    }
    res.writeHead(404).end('not found');
  });
  server.listen(port, () => {
    console.log(`[webhook] listening on :${port}${WEBHOOK_PATH}`);
  });
  return server;
}
