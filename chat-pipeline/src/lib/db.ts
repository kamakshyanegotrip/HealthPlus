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
/**
 * R13-conn, decided 8 September 2026: **Option 2 — one LOGIN role per worker
 * role**, and therefore one POOL per role rather than one connection that
 * assumes roles.
 *
 * The decision that drove it: a pool cannot become another role. `SET LOCAL
 * ROLE` (Option 1) would have left every privilege reachable from any code in
 * this process; a separate pool means a SQL-injection reached through the
 * retrieval path cannot write a §4.0.7 safety event, because `reasoner_role`
 * holds no grant on `safety.red_flag_event` and no way to acquire one.
 *
 * HP-RB-001 §2 still governs: "the application must never connect as owner or
 * superuser." None of these is.
 */
export type DbRole = 'app' | 'redflag' | 'reasoner';

/**
 * Each role's own connection string, and its pool ceiling.
 *
 * `max` is deliberately BELOW the CONNECTION LIMIT migration 034 §1 sets on
 * each role. The database's limit is the backstop; this is the budget. If they
 * were equal, a pool at capacity would be indistinguishable from a role
 * locked out, and the error would arrive at the worst moment.
 */
const ROLE_CONFIG: Record<DbRole, { env: string; max: number }> = {
  app:             { env: 'DATABASE_URL',                  max: 8 },
  redflag:         { env: 'DATABASE_URL_REDFLAG',          max: 3 },
  reasoner:        { env: 'DATABASE_URL_REASONER',         max: 5 },
};

const pools = new Map<DbRole, Pool>();
/** Which roles fell back to DATABASE_URL. Read by `dbRoleBindings()`. */
const fellBack = new Set<DbRole>();

export const DATA_REGION = process.env.DATA_REGION ?? 'IN';

const REGION_GUC = 'app.data_region';

/**
 * The pool for a role. Defaults to `app`, so every existing call site keeps
 * the behaviour it had.
 *
 * **The fallback is deliberate and it is recorded.** When a role has no
 * connection string of its own it uses `DATABASE_URL`, because the stub schema
 * (`chat-pipeline/db/`) grants `hp_app` directly and has no worker roles at
 * all — the pipeline's own tests must keep running until R10g retires it.
 *
 * A silent fallback would be the same species of bug this project keeps
 * finding, so it is not silent: `dbRoleBindings()` reports it, and a
 * deployment gate can assert that production configured both. Falling back
 * is correct against the stub and wrong against the real schema, and the
 * difference has to be visible rather than inferred.
 */
export function db(role: DbRole = 'app'): Pool {
  const existing = pools.get(role);
  if (existing) return existing;

  // Validated, not trusted: interpolated into a libpq startup option string
  // below. Thrown at pool construction so a misconfigured deployment fails at
  // start rather than on the first flagged message.
  if (!/^[A-Z]{2}$/.test(DATA_REGION)) {
    throw new Error(`DATA_REGION must be a two-letter region code, got ${JSON.stringify(DATA_REGION)}`);
  }

  const cfg = ROLE_CONFIG[role];
  const own = process.env[cfg.env];
  if (!own && role !== 'app') fellBack.add(role);
  const connectionString = own ?? process.env.DATABASE_URL;

  const pool = new Pool({
    connectionString,
    max: cfg.max,
    idleTimeoutMillis: 30_000,
    // Statement timeout protects the request-path red-flag scan and
    // knowledge lookups from ever queuing behind a slow analytical query —
    // §4.0.1/§4.0.5 require the safety path to be fast and synchronous.
    statement_timeout: 5_000,
    // SEC-1. The region GUC, set in the CONNECTION STARTUP PACKET rather than
    // by a query afterwards.
    //
    // The region is a property of the DEPLOYMENT, not of a request: one
    // process serves one region (HP-ADR-004 §2). So it belongs on the
    // connection, not in runAsUser — taking it from a caller-supplied claim
    // would let a request name its own region, which is the thing the boundary
    // exists to stop.
    //
    // The obvious spelling — `pool.on('connect', c => c.query('SET ...'))` —
    // was written first and then tested rather than trusted. It works, but
    // only because pg queues queries per client, and pg says that pattern is
    // removed in pg@9.0. A safety boundary that holds because of an internal
    // queue is not one to build on. `options` lands before the connection is
    // usable at all, so there is no ordering to get wrong.
    //
    // EVERY pool needs this, not just the first. Migration 034 §3 also sets a
    // per-role database default as braces — five pools is five chances to
    // forget, and forgetting does not fail loudly: `data_region = NULL` is
    // never true, so the pool would silently see zero rows.
    //
    // NOTE: this overrides any `options` carried in the connection string.
    options: `-c ${REGION_GUC}=${DATA_REGION}`,
  });

  pools.set(role, pool);
  return pool;
}

/**
 * Which roles have their own connection string and which fell back.
 *
 * Exists so a deployment check can assert the real thing rather than trusting
 * that four secrets were set. Reports only roles whose pool has actually been
 * constructed — a role nothing has used yet has bound to nothing.
 */
export function dbRoleBindings(): { role: DbRole; separate: boolean }[] {
  return (Object.keys(ROLE_CONFIG) as DbRole[])
    .filter((r) => pools.has(r))
    .map((r) => ({ role: r, separate: !fellBack.has(r) }));
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
