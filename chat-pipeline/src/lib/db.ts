import { Pool, type PoolClient } from 'pg';

/**
 * A single pooled connection, authenticated as `hp_app` only (HP-RB-001 §2:
 * "the application must never connect as owner or superuser — if it does,
 * every control below is decorative"). hp_app has INSERT/SELECT on
 * response_audit_event and no UPDATE/DELETE/TRUNCATE grant on it at all; the
 * forbid_mutation() trigger is the belt to this braces.
 *
 * Self-hosted Postgres, Mumbai (ap-south-1), per HP-ADR-004 / HP-ADR-003 —
 * no health data leaves India at v1, so DATABASE_URL must point at the
 * regional instance and DATA_REGION must agree with it.
 */
let pool: Pool | null = null;

export function db(): Pool {
  if (!pool) {
    pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      max: 10,
      idleTimeoutMillis: 30_000,
      // Statement timeout protects the request-path red-flag scan and
      // knowledge lookups from ever queuing behind a slow analytical query —
      // §4.0.1/§4.0.5 require the safety path to be fast and synchronous.
      statement_timeout: 5_000,
    });
  }
  return pool;
}

export const DATA_REGION = process.env.DATA_REGION ?? 'IN';

/**
 * Runs `fn` against a dedicated client from the pool with the caller's
 * verified JWT claims (src/lib/auth.ts's AuthContext) set as the
 * `request.jwt.claims` GUC for the duration of one transaction — the same
 * GUC db/020_rls.sql's `auth.jwt()`/`auth.uid()` stub functions read, and
 * the same one HP-SEC-001 §5 used via `set_config(...)` to impersonate
 * roles while validating its own policies against a stub Supabase auth
 * schema.
 *
 * Why this exists: HP-SEC-001's RLS design assumes every end-user request
 * connects to Postgres as itself (Supabase/PostgREST's `authenticated`
 * role, populated per-request). This app instead connects once, as the
 * single pooled `hp_app` technical role (HP-RB-001 §2 forbids anything
 * else) — so there is no per-user Postgres identity for RLS to key off
 * unless the app sets one explicitly, per request. `SET LOCAL` (via
 * set_config's third argument `true`) scopes the GUC to the current
 * transaction only, so it can never leak onto a pooled connection handed to
 * a *different* request afterwards — that leak is exactly the failure mode
 * a naive `SET request.jwt.claims` (session-scoped, no BEGIN/COMMIT) would
 * have, and pg's connection pooling makes that a real risk, not a
 * theoretical one.
 */
export async function runAsUser<T>(
  claims: { sub: string; user_role: string; hospital_id?: string | null; admin_scopes?: string[] },
  fn: (client: PoolClient) => Promise<T>,
): Promise<T> {
  const client = await db().connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT set_config($1, $2, true)', ['request.jwt.claims', JSON.stringify(claims)]);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {
      // best-effort — the connection may already be unusable if the error
      // came from inside the transaction; client.release() below still runs.
    });
    throw err;
  } finally {
    client.release();
  }
}
