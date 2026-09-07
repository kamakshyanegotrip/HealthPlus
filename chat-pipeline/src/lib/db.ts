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

export const DATA_REGION = process.env.DATA_REGION ?? 'IN';

/**
 * SEC-1. The GUCs the SHIPPING SCHEMA's row-level security actually reads.
 *
 * Fifteen of the sixteen policies in migrations/ are expressed in terms of
 * `app.current_region()`, `app.current_user_id()` and
 * `app.current_provider_org()`, which read `app.data_region`, `app.user_id`
 * and `app.provider_org_id` respectively. Until this file was changed, the
 * application set none of them: the pool set no GUC at all, and `runAsUser()`
 * set exactly one — `request.jwt.claims` — which no policy in that schema
 * reads. `request.jwt.claims` is the stub's vocabulary (db/020_rls.sql, and
 * the HP-SEC-001 policy files); the real schema speaks `app.*`.
 *
 * The consequence was not a subtle one, and it was confirmed by connecting the
 * way this file connects rather than the way a test finds convenient:
 *
 *     ERROR:  new row violates row-level security policy for table
 *             "red_flag_event"
 *
 * — the §4.0.7 write the pipeline performs on every flagged message, refused,
 * because `data_region = app.current_region()` compared a real value to NULL.
 *
 * `request.jwt.claims` is still set alongside these, unchanged. The stub
 * schema is what runs today; both vocabularies have to be spoken until R10
 * retires one of them, and setting a GUC nothing reads costs nothing.
 */
const REGION_GUC = 'app.data_region';

export function db(): Pool {
  if (!pool) {
    // Validated, not trusted: this value is interpolated into a libpq startup
    // option string below, and a two-letter check is the whole of what makes
    // that safe. Thrown at pool construction so a misconfigured deployment
    // fails at start rather than on the first flagged message.
    if (!/^[A-Z]{2}$/.test(DATA_REGION)) {
      throw new Error(`DATA_REGION must be a two-letter region code, got ${JSON.stringify(DATA_REGION)}`);
    }
    pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      max: 10,
      idleTimeoutMillis: 30_000,
      // Statement timeout protects the request-path red-flag scan and
      // knowledge lookups from ever queuing behind a slow analytical query —
      // §4.0.1/§4.0.5 require the safety path to be fast and synchronous.
      statement_timeout: 5_000,
      // SEC-1. The region GUC, set in the CONNECTION STARTUP PACKET rather
      // than by a query afterwards.
      //
      // The region is a property of the DEPLOYMENT, not of a request: one
      // process serves one region (HP-ADR-004 §2 — one region, immutable at
      // project creation). So it belongs on the connection, not in
      // runAsUser: taking it from a caller-supplied claim would let a request
      // name its own region, which is the thing the boundary exists to stop.
      //
      // The obvious spelling — `pool.on('connect', c => c.query('SET ...'))`
      // — was written first and then tested rather than trusted. It does
      // work, but only because pg queues queries per client so the SET lands
      // ahead of the first real one; pg emits "Calling client.query() when
      // the client is already executing a query is deprecated and will be
      // removed in pg@9.0" while doing it. A safety boundary that holds
      // because of an internal queue, and is scheduled for removal, is not
      // one to build on. `options` is set before the connection is usable at
      // all, so there is no ordering to get wrong.
      //
      // NOTE: this overrides any `options` carried in DATABASE_URL's query
      // string. Nothing sets one today; if something ever does, it has to be
      // merged here rather than added there.
      options: `-c ${REGION_GUC}=${DATA_REGION}`,
    });
  }
  return pool;
}

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
    // SEC-1: the two per-user GUCs the shipping schema's policies read.
    // `app.data_region` is not set here — it is set once per connection in
    // db(), because it is a property of the deployment and not of the caller;
    // taking it from a caller-supplied claim would let a request name its own
    // region, which is the whole thing HP-ADR-004 §2 exists to prevent.
    //
    // Transaction-scoped (set_config's third argument), so neither value can
    // survive onto the pooled connection handed to the next request.
    await client.query('SELECT set_config($1, $2, true)', ['app.user_id', claims.sub]);
    await client.query('SELECT set_config($1, $2, true)', [
      'app.provider_org_id',
      claims.hospital_id ?? '',
    ]);
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
