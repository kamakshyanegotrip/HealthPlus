/**
 * HealthPlus — Postgres pools and the pg-boss instance for background jobs.
 *
 * ADR-001 §3.2 / Open Items Register (Build Queue, "Ingestion pipeline on
 * pg-boss"): background jobs run on pg-boss against the same Postgres database
 * the application uses, specifically so a job handler can insert application
 * rows and enqueue a follow-on job in one transaction — the transactional-
 * enqueue guarantee a Postgres-backed queue gives you and a hosted workflow
 * engine (n8n) cannot (ADR-001 §3.2 point 7).
 *
 * ---------------------------------------------------------------------------
 * R10-role-routing: ONE POOL PER ROLE, for the same reason R13-conn decided it
 * for the request path.
 *
 * This module used to be "one pg.Pool from DATABASE_URL", which meant every
 * background job ran as `hp_app` — a role holding USAGE on `public` and nothing
 * else in the real schema. R13-roleci scored the ingestion job's ten SQL
 * literals as failing AS THE ROLE THEY CONNECT AS: `permission denied for
 * schema evidence`, `domain`, `principal`, `obs`. Ten sites, one cause, and no
 * amount of reading the SQL would have shown it, because as the owner every one
 * of them resolves.
 *
 * `dqe_role` is the role the schema already built for ingestion: USAGE on
 * `evidence` and `safety` and the grants the Data Quality Engine needs. It had
 * no LOGIN until migration 037, on the principle migration 034 §1 set — a role
 * gets LOGIN in the migration that builds its caller. This file is that caller.
 *
 * NEW (migration 050): `patient_upload_role`, the caller for
 * extractPatientUploadAttributes. Deliberately NOT dqe_role — dqe_role "gets
 * no reach into app_user, patient_profile, patient_attribute or subject_key"
 * (migration 037 §4) and this job's whole purpose is writing
 * patient_attribute, so it needs its own lane with the opposite reach:
 * principal and nothing evidence/domain owns.
 *
 * `DATABASE_URL` here is `queue_role` (see migration 046 and DEPLOY.md Step
 * 5) — pg-boss's own `pgboss` schema needs CREATE on the database, which no
 * application role holds by design, so the shared `boss` instance below
 * connects with the plain `connectionString`, never through `jobPool()`.
 *
 * THE FALLBACK IS DELIBERATE AND IT IS RECORDED. When a role has no connection
 * string of its own, its pool falls back to DATABASE_URL rather than refusing to
 * start, because the operator step that sets these passwords has not run and
 * the stub schema has no worker roles at all. `poolRoleBindings()` reports which
 * pools fell back, so a deployment check can assert the real thing rather than
 * discovering it from a permission error at 3am. A SILENT fallback would be the
 * same species of bug this project keeps finding: a control that reports success
 * it did not achieve.
 *
 * SEC-1's region GUC travels in the startup packet, exactly as
 * chat-pipeline/src/lib/db.ts sends it — no round trip, and no window in which a
 * connection exists without a region. Migration 037 also sets a per-role default
 * as braces.
 */
import { Pool } from 'pg';
import PgBoss from 'pg-boss';

const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  throw new Error('DATABASE_URL is required — see ADR-001 §3.1 (Supabase Postgres, ap-south-1).');
}

const DATA_REGION = process.env.DATA_REGION ?? 'IN';
if (!/^[A-Z]{2}$/.test(DATA_REGION)) {
  throw new Error(`DATA_REGION must be two uppercase letters, got ${JSON.stringify(DATA_REGION)}`);
}

export type JobRole = 'dqe' | 'patientUpload' | 'storageErasure' | 'app';

const ROLE_CONFIG: Record<JobRole, { env: string; max: number }> = {
  // Ingestion: claim extraction, provider submissions, data-quality flags.
  dqe: { env: 'DATABASE_URL_DQE', max: 3 },
  // NEW (migration 050): patient upload extraction — principal.patient_attribute
  // and principal.patient_upload_document only, never evidence/domain.
  patientUpload: { env: 'DATABASE_URL_PATIENT_UPLOAD', max: 3 },
  // NEW (migration 051): drains principal.storage_erasure_queue — nothing but
  // the three claim/mark verbs on that one table (src/jobs/drainStorageErasure.ts).
  storageErasure: { env: 'DATABASE_URL_STORAGE_ERASURE', max: 2 },
  // Everything not yet routed to a role of its own. Named rather than implicit,
  // so `poolRoleBindings()` can report it and R13-roleci can score it.
  app: { env: 'DATABASE_URL', max: 4 },
};

const pools = new Map<JobRole, Pool>();

export function jobPool(role: JobRole = 'app'): Pool {
  let p = pools.get(role);
  if (!p) {
    const cfg = ROLE_CONFIG[role];
    const own = process.env[cfg.env];
    p = new Pool({
      connectionString: own ?? connectionString,
      max: cfg.max,
      options: `-c app.data_region=${DATA_REGION}`,
    });
    pools.set(role, p);
  }
  return p;
}

/**
 * Which pools are actually connecting as their own role, and which fell back.
 * A deployment check should assert `separate === true` for every role before
 * calling itself configured; until the operator step runs, ingestion is still
 * running as hp_app and this is how you find out on purpose.
 */
export function poolRoleBindings(): { role: JobRole; separate: boolean }[] {
  return (Object.keys(ROLE_CONFIG) as JobRole[]).map((role) => ({
    role,
    separate: role === 'app' ? true : Boolean(process.env[ROLE_CONFIG[role].env]),
  }));
}

/**
 * The ingestion pool. Kept as a named export because that is what
 * `extractClaimsFromProviderSubmission` imports and what its unit test mocks;
 * the indirection through `jobPool` is what makes the role explicit.
 */
export const pgPool = jobPool('dqe');

/**
 * pg-boss's OWN control connection. Connects as `queue_role` in production
 * (DATABASE_URL — see this file's header and DEPLOY.md Step 5), which holds
 * CREATE on the database and USAGE on none of principal/safety/obs/evidence/
 * domain. This must stay on the plain `connectionString`, never on a
 * `jobPool()` role pool — pg-boss issues its own `CREATE SCHEMA IF NOT
 * EXISTS pgboss` on start, which every application role deliberately lacks.
 */
export const boss = new PgBoss({ connectionString });

let started = false;
export async function ensureBossStarted(): Promise<PgBoss> {
  if (!started) {
    await boss.start();
    started = true;
  }
  return boss;
}
