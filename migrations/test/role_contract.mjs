#!/usr/bin/env node
/**
 * HealthPlus — SQL role contract check (register item R13-roleci)
 * ===========================================================================
 *
 * The same 39 SQL literals `query_contract.mjs` probes, PREPAREd again — but
 * as the role each module actually connects as, instead of as the owner.
 *
 * WHY THIS EXISTS, AND IT IS NOT A REFINEMENT
 *
 * CI-3 was built to catch stub-vs-real drift and it runs as `postgres`. Same
 * schema, different connecting role (HP-RECON-004 §1):
 *
 *     postgres   31 of 39 resolve      <- what CI has been measuring
 *     hp_app      1 of 39 resolve      <- what the request path can run
 *
 * Thirty fail with `permission denied`, not with a missing table. So the gate
 * that was used to SIZE the R10 cutover could not see the class of failure the
 * cutover mostly consists of. That is the ninth instance of this project's
 * standing pattern — a check that does not cover itself — and the first where
 * the blind spot was in the instrument used to plan the work.
 *
 * The register's standing correction already carried the clause that would
 * have caught it: execute AS THE REAL ROLE. It was adopted for the gates after
 * SEC-1 and never applied back to the survey. This file applies it.
 *
 * WHAT IT PROVES, AND WHAT IT DOES NOT
 *
 * A pass means the role may reach every relation the statement names, with the
 * privileges the statement needs — including the ones a bare SELECT does not
 * ask for. `SELECT ... FOR UPDATE` needs UPDATE, and that distinction is not
 * academic: it is how this gate found, on its first run, that the alert worker
 * cannot claim a batch as `alert_role` (see the baseline entry for
 * alert-worker.mjs:129).
 *
 * It says nothing about whether RLS returns any ROWS to that role: a policy
 * that filters everything away still passes here. Row visibility is
 * sec1_region_context.sh's and r13_conn_isolation.sh's job.
 *
 * It also says nothing about whether the query is CORRECT against the schema —
 * a missing table or column is the query contract's finding, and anything that
 * is not a permission failure is deliberately handed back to it rather than
 * baselined twice.
 *
 * HOW A ROLE IS DECIDED — derived where derivable, declared where not
 *
 * In-process modules go through `src/lib/db.ts`, so their role is readable
 * from the source: `db('reasoner')` means `reasoner_role`, `db()` and
 * `runAsUser()` mean `hp_app`. That is derived on every run and cannot drift.
 *
 * Out-of-process entry points each build their own pool from `DATABASE_URL`,
 * so their role is a DEPLOYMENT fact — which secret that process is given —
 * and no amount of reading the file can recover it. Those are declared in
 * ENTRY_POINTS below, and the declaration is the specification: if the
 * deployment gives that process a different role than the one named here, this
 * gate is measuring the wrong thing and the fix is to make them agree.
 *
 * A file with SQL and no role from either route is a HARD ERROR, never a
 * default. A silent default to the owner is exactly how CI-3 came to report 31
 * when the answer was 1.
 *
 * THE BASELINE
 *
 * Same rules as the query contract, and for the same reasons: it may only
 * shrink; a baselined site that starts passing fails the build; an entry
 * matching no site fails the build. Sixteen entries today, every one of them
 * `hp_app`, each tagged with the register item that closes it.
 *
 * USAGE
 *   PGDATABASE=hp_test node migrations/test/role_contract.mjs
 *   PGDATABASE=hp_test node migrations/test/role_contract.mjs --write-baseline
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { extract } from './sql_literals.mjs';

const BASELINE = 'migrations/test/role_contract_baseline.json';

/** `db('<key>')` in src/lib/db.ts terms -> the database role that pool logs in as. */
const POOL_ROLE = { app: 'hp_app', redflag: 'redflag_role', reasoner: 'reasoner_role' };

/**
 * Entry points that construct their own pool from `DATABASE_URL`. The role is
 * whichever login the deployment hands that process, so it cannot be derived —
 * it is declared here, and this declaration is what the deployment must match.
 *
 * `reason` is not decoration: it is the evidence for the claim, so a reader can
 * check the declaration against the file rather than trusting it.
 */
const ENTRY_POINTS = [
  {
    prefix: 'chat-pipeline/worker/alert-worker.mjs',
    role: 'alert_role',
    reason: "its own Fly process; the file's own header says it connects as alert_role (migration 029)",
  },
  {
    prefix: 'chat-pipeline/worker/side-effect-worker.mjs',
    role: 'hp_app',
    reason: 'its header says "the same connection string the app itself uses" — which is the finding, not the design (HP-RECON-004 §2)',
  },
  {
    prefix: 'src/jobs/computeSafetyMetrics.mjs',
    role: 'metrics_role',
    reason: 'the scheduled metrics process; obs.record_metric_sample EXECUTE is granted to metrics_role and to nothing else',
  },
  {
    prefix: 'src/jobs/',
    role: 'dqe_role',
    reason: "src/db/pool.ts is per-role since R10-role-routing: jobPool('dqe') carries DATABASE_URL_DQE, and migration 037 gave dqe_role LOGIN because this became its caller. Until the operator sets that password the pool falls back to DATABASE_URL — recorded by poolRoleBindings(), not silent — so this declaration is the SPECIFICATION the deployment must match, which is exactly what it is for",
  },
];

function deriveRole(file, src) {
  const declared = ENTRY_POINTS.find((e) => file.startsWith(e.prefix));
  const found = new Set();
  for (const m of src.matchAll(/\bdb\(\s*'([a-z]+)'\s*\)/g)) {
    const role = POOL_ROLE[m[1]];
    if (!role) return { error: `db('${m[1]}') names no pool this check knows; add it to POOL_ROLE` };
    found.add(role);
  }
  if (/\bdb\(\s*\)/.test(src) || /\brunAsUser\s*\(/.test(src)) found.add('hp_app');

  // A declaration and a derivation that disagree is worth surfacing, not
  // silently resolving: one of the two is wrong about how the code deploys.
  if (declared && found.size && !found.has(declared.role)) {
    return { error: `declared as ${declared.role} but the source uses ${[...found].join(', ')}` };
  }
  if (declared) return { role: declared.role, how: 'declared' };
  if (found.size === 1) return { role: [...found][0], how: 'derived' };
  if (found.size > 1) {
    return { error: `uses more than one pool (${[...found].join(', ')}); declare it in ENTRY_POINTS` };
  }
  return { error: 'no db() call and no ENTRY_POINTS declaration — which role does this connect as?' };
}

function psql(sql) {
  try {
    execFileSync('psql', ['-v', 'ON_ERROR_STOP=1', '-q', '-c', sql],
      { stdio: ['ignore', 'ignore', 'pipe'] });
    return null;
  } catch (err) {
    const line = String(err.stderr || '').trim().split('\n')[0] || 'unknown error';
    return line.replace(/^ERROR:\s*/, '');
  }
}

/**
 * PREPARE ALONE IS NOT ENOUGH, and finding that out is why the instrument
 * check below exists.
 *
 * PostgreSQL resolves names at PREPARE, so a missing schema USAGE is caught
 * there — `permission denied for schema obs`. But TABLE-level privileges are
 * checked at executor start, which PREPARE never reaches: `PREPARE ... SELECT
 * FROM a_table_this_role_cannot_read` succeeds silently. A gate built on
 * PREPARE alone would therefore catch exactly the failures where a role has no
 * access to a schema at all, and MISS the ones where it has USAGE and lacks
 * the grant — which is precisely the class that bit reasoner_role on
 * evidence.domain_entity_type (migration 034 §4), the case R13's rules A and B
 * both read as clean.
 *
 * `EXPLAIN EXECUTE` reaches executor start and performs the check without
 * running the query: no rows read, no rows written, no triggers fired. Verified
 * both directions, including that an INSERT probed this way leaves the table
 * untouched.
 *
 * Parameters are filled with NULL. Their values cannot change a permission
 * decision, and PREPARE has already inferred their types.
 */
const probe = (role, sql, n) => {
  const clean = sql.replace(/;\s*$/, '');
  const params = Math.max(0, ...[...clean.matchAll(/\$(\d+)/g)].map((m) => Number(m[1])));
  const args = params ? `(${Array(params).fill('NULL').join(', ')})` : '';
  return psql(`SET SESSION AUTHORIZATION ${role}; PREPARE rc_${n} AS ${clean}; EXPLAIN EXECUTE rc_${n}${args}`);
};

// ---------------------------------------------------------------------------
// PREFLIGHT, in three parts. Each exists because its absence would let this
// gate pass while proving nothing.
// ---------------------------------------------------------------------------

// 1. A database at all. Without this, every probe fails with a connection
//    error, and a large enough baseline would report them as known-failing and
//    exit green — a check that passes hardest when it is not running.
if (psql('SELECT 1') !== null) {
  console.error('Cannot reach a database to probe against.');
  console.error('This check PREPAREs each query as a role; it cannot run without one.');
  process.exit(1);
}

// 2. THE INSTRUMENT ITSELF. Everything here rests on one assumption: that
//    SET SESSION AUTHORIZATION plus PREPARE actually enforces privileges. If
//    it did not — a superuser role, a Postgres that defers the check to
//    EXECUTE, a psql that silently drops the first statement — every probe
//    would pass and this gate would report a clean bill of health for a
//    codebase that cannot run.
//
//    So it is required to observe a denial it knows must happen: pg_authid is
//    readable only by superusers, in every PostgreSQL, regardless of this
//    project's schema. A control that depends on our own DDL would go stale;
//    this one cannot.
{
  const control = probe('hp_app', 'SELECT rolname FROM pg_authid', 'ctl');
  if (control === null) {
    console.error('INSTRUMENT CHECK FAILED: hp_app was able to PREPARE a read of pg_authid.');
    console.error('Either the authorization switch is not taking effect or hp_app is a superuser.');
    console.error('Every result this gate produces would be meaningless, so it refuses to produce any.');
    process.exit(1);
  }
  if (!/permission denied/i.test(control)) {
    console.error(`INSTRUMENT CHECK INCONCLUSIVE: expected "permission denied", got: ${control}`);
    process.exit(1);
  }
}

// 3. Every role this run intends to probe must exist. A missing role would
//    otherwise report as a per-query error and read as a schema problem.
const wanted = [...new Set([...Object.values(POOL_ROLE), ...ENTRY_POINTS.map((e) => e.role)])];
{
  const missing = wanted.filter((r) => psql(`SET SESSION AUTHORIZATION ${r}; RESET SESSION AUTHORIZATION`) !== null);
  if (missing.length) {
    console.error(`Role(s) absent from this cluster: ${missing.join(', ')}`);
    console.error('Apply the migrations first: 003a creates hp_app/hp_owner/hp_reader, 027/029/030 the'); 
    console.error('worker roles, 034 their LOGIN state. No stub file is needed for any of them.');
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------
const literals = extract();
const byFile = new Map();
for (const q of literals) {
  if (!byFile.has(q.file)) byFile.set(q.file, deriveRole(q.file, readFileSync(q.file, 'utf8')));
}

const unmapped = [...byFile.entries()].filter(([, v]) => v.error);
if (unmapped.length) {
  console.error(`\n${unmapped.length} FILE(S) WITH SQL AND NO ROLE:\n`);
  for (const [f, v] of unmapped) console.error(`  ${f}\n    ${v.error}`);
  console.error('\nThis check will not guess. A file whose connecting role is unknown is a file');
  console.error('whose SQL has never been proved runnable — defaulting it to the owner is how');
  console.error('the query contract came to report 31 of 39 when the answer was 1.');
  process.exit(1);
}

// This gate answers ONE question: may this role reach what this statement
// names? A `relation does not exist` is a real problem and it is the QUERY
// contract's problem — baselining it here too would mean two gates reporting
// one fact, and two baselines to shrink for one fix. So anything that is not a
// permission failure is recorded as `notMine` and reported as a count.
const probed = literals.map((q, i) => {
  const { role } = byFile.get(q.file);
  const err = q.interpolated ? null : probe(role, q.sql, i);
  const isPerm = err !== null && /permission denied/i.test(err);
  return { ...q, role, error: isPerm ? err : null, notMine: err !== null && !isPerm ? err : null };
});

// A SITE IS (statement, role), NOT (statement, role, line).
//
// The same SQL text appearing twice in one file — extractClaims issues its
// provider-submission read from two call sites — is ONE permission question
// asked twice, and the answer cannot differ. Keeping both would put two
// identical rows in the baseline, and then a single fix would have to remove
// two entries or the orphan rule would go red. Line numbers are dropped from
// the key for the same reason: an unrelated edit above a query must not
// invalidate its baseline entry.
const seen = new Set();
const results = probed.filter((r) => {
  const k = `${r.id}:${r.role}`;
  if (seen.has(k)) return false;
  seen.add(k);
  return true;
});

if (process.argv.includes('--write-baseline')) {
  const entries = results.filter((r) => r.error).map((r) => ({
    id: r.id, file: r.file, role: r.role, error: r.error,
    why: 'TODO: state why this role cannot run this query yet',
    item: 'TODO: the register item that will fix it',
  }));
  writeFileSync(BASELINE, JSON.stringify({
    note: 'Queries that do not resolve AS THE ROLE THEIR MODULE CONNECTS AS. See role_contract.mjs. Entries may only be REMOVED, never edited to hide a regression.',
    source: 'HP-RECON-004 — the request path has no role',
    entries,
  }, null, 2) + '\n');
  console.log(`wrote ${entries.length} baseline entries to ${BASELINE}`);
  process.exit(0);
}

let baseline = { entries: [] };
try { baseline = JSON.parse(readFileSync(BASELINE, 'utf8')); } catch { /* first run */ }

// A site is (query, role): the same SQL reached by two roles is two facts.
const key = (r) => `${r.id}:${r.role}`;
const dupes = baseline.entries.map(key).filter((k, i, all) => all.indexOf(k) !== i);
if (dupes.length) {
  console.error(`Baseline has duplicate id:role pairs: ${[...new Set(dupes)].join(', ')}`);
  process.exit(1);
}
const known = new Set(baseline.entries.map(key));

const failing = results.filter((r) => r.error);
const passing = results.filter((r) => !r.error && !r.notMine && !r.interpolated);
const deferred = results.filter((r) => r.notMine);
const unexpected = failing.filter((r) => !known.has(key(r)));
const fixedButBaselined = passing.filter((r) => known.has(key(r)));
const orphans = baseline.entries.filter((e) => !results.some((r) => key(r) === key(e)));

const roles = [...new Set(results.map((r) => r.role))].sort();
console.log(`SQL literals found: ${results.length}   roles in play: ${roles.join(', ')}`);
console.log(`reachable by their own module's role: ${passing.length}`);
console.log(`not a permission question (query contract's): ${deferred.length}`);
console.log(`known-failing (baselined):          ${failing.length - unexpected.length} of ${known.size}`);

if (unexpected.length) {
  console.error(`\n${unexpected.length} QUERY(S) THEIR OWN ROLE CANNOT RUN, AND NOT BASELINED:\n`);
  for (const r of unexpected) {
    console.error(`  ${r.file}:${r.line}  as ${r.role}`);
    console.error(`    ${r.error}`);
    console.error(`    ${r.sql.replace(/\s+/g, ' ').slice(0, 100)}...\n`);
  }
  console.error('A grant this role does not hold is not a smaller problem than a missing table.');
  console.error(`If it is known and scheduled, baseline it in ${BASELINE} with a reason and an item.`);
}
if (orphans.length) {
  console.error(`\n${orphans.length} BASELINE ENTRY(S) MATCH NO SITE:\n`);
  for (const e of orphans) console.error(`  ${e.id} as ${e.role}  was ${e.file}  (${e.item})`);
  console.error('\nThe query was deleted, its text changed, or its module moved to another role.');
}
if (fixedButBaselined.length) {
  console.error(`\n${fixedButBaselined.length} BASELINED SITE(S) NOW RUN. Remove them:\n`);
  for (const r of fixedButBaselined) console.error(`  ${r.id} as ${r.role}  ${r.file}:${r.line}`);
  console.error('\nThe baseline may only shrink.');
}

if (unexpected.length || fixedButBaselined.length || orphans.length) process.exit(1);
console.log('\nROLE CONTRACT OK.');
