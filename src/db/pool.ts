/**
 * HealthPlus — shared Postgres pool and pg-boss instance.
 *
 * ADR-001 §3.2 / Open Items Register §8 (Build Queue #4, "Ingestion pipeline
 * on pg-boss"): background jobs run on pg-boss against the same Postgres
 * database the application uses, specifically so a job handler can insert
 * application rows and enqueue a follow-on job in one transaction — the
 * transactional-enqueue guarantee a Postgres-backed queue gives you and a
 * hosted workflow engine (n8n) cannot (ADR-001 §3.2 point 7).
 *
 * This module is intentionally minimal: one `pg.Pool`, one `PgBoss`
 * instance, both constructed from the same connection string, both started
 * once at process boot. Real deployments should wire proper pool sizing,
 * TLS, and graceful shutdown; that is outside the scope of this task file.
 */
import { Pool } from 'pg';
import PgBoss from 'pg-boss';

const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  throw new Error('DATABASE_URL is required — see ADR-001 §3.1 (Supabase Postgres, ap-south-1).');
}

export const pgPool = new Pool({ connectionString });

export const boss = new PgBoss({ connectionString });

let started = false;
export async function ensureBossStarted(): Promise<PgBoss> {
  if (!started) {
    await boss.start();
    started = true;
  }
  return boss;
}
