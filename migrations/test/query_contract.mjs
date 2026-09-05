#!/usr/bin/env node
/**
 * HealthPlus — SQL query contract check (register item CI-3)
 * ===========================================================================
 *
 * Extracts every SQL literal in the shipping source tree and PREPAREs it
 * against whatever schema this process is pointed at. PREPARE resolves table
 * names, column names and function signatures without executing anything and
 * without needing a single row of data, so this is a schema-conformance check
 * that costs about a second and needs no fixtures.
 *
 * WHY THIS EXISTS
 *
 * Five schema bugs were found in the first week of September 2026, and four of
 * them were found by executing something against the real schema rather than
 * reading it. The fifth — `SELECT id, name, country FROM principal.provider_org`
 * against a table whose column is `legal_name` (PR #4) — had survived because:
 *
 *   * the assumption was flagged in a comment and never closed, and
 *   * the unit test doubled that query with a fake returning `{ id, name,
 *     country }`, so the fake encoded the same wrong assumption as the code and
 *     the test passed for exactly the reason the code was broken.
 *
 * A fake written from the code cannot catch a schema mismatch. This check has
 * no fakes in it. It asks the database.
 *
 * WHAT IT CANNOT DO
 *
 * PREPARE proves a query *resolves and typechecks*. It says nothing about
 * whether it returns the right rows. That is the integration test's job
 * (R10f). Do not let a green run here be read as "retrieval works".
 *
 * THE BASELINE, AND WHY IT SHRINKS
 *
 * Ten queries do not currently resolve against the real schema — the stub-vs-
 * real divergence catalogued in HP-RECON-002. Failing the build on those today
 * would just block every PR until R10 lands, so they are recorded in
 * query_contract_baseline.json with a reason and the R10 item that will fix
 * each one.
 *
 * The check fails on TWO conditions, and the second is the important one:
 *
 *   1. A query fails that is not in the baseline  -> a new bug. Fix it.
 *   2. A baselined query now PASSES               -> you fixed it. Remove the
 *                                                    baseline entry.
 *
 * Rule 2 is what stops the baseline becoming a permanent excuse list. It can
 * only shrink, and it cannot go stale without turning the build red.
 *
 * USAGE
 *   PGDATABASE=hp_test node migrations/test/query_contract.mjs
 *   ... --write-baseline    regenerate the baseline from current reality
 */

import { readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { join, relative } from 'node:path';

const ROOT = process.cwd();
const BASELINE = 'migrations/test/query_contract_baseline.json';

// Shipping source only. Test files are excluded deliberately: a test may
// legitimately assert against a stub-shaped table, and mixing those into this
// baseline would blur the one question this check exists to answer — does the
// code we deploy match the schema we deploy?
const ROOTS = ['src', 'chat-pipeline/src', 'chat-pipeline/worker', 'chat-pipeline/scripts'];
const EXT = /\.(ts|tsx|mjs|js)$/;
const IS_TEST = /\.test\.(ts|tsx|mjs|js)$/;

// Named exclusions, each of which must earn its place.
//
// scripts/smoke-test.mjs is a test OF the stub schema, by design — it asserts
// against db/000..020 and is deleted at R10g along with them. Every one of its
// SQL literals fails against the real schema for the same uninteresting
// reason, and baselining ten copies of "this is the stub smoke test" would
// bury the failures that actually mean something. Delete this exclusion when
// R10g deletes the file.
const EXCLUDE = new Set(['chat-pipeline/scripts/smoke-test.mjs']);

function walk(dir, out = []) {
  let entries;
  try { entries = readdirSync(dir); } catch { return out; }
  for (const e of entries) {
    if (e === 'node_modules' || e === '.next' || e.startsWith('.')) continue;
    const p = join(dir, e);
    const st = statSync(p);
    if (st.isDirectory()) walk(p, out);
    else if (EXT.test(e) && !IS_TEST.test(e)) out.push(p);
  }
  return out;
}

// A SQL literal, for this check, is a backtick template literal whose first
// word is a statement keyword. Anchoring on the FIRST word rather than
// searching anywhere in the string is what keeps Annex B prompt text out:
// prompts mention SELECT and UPDATE in prose, but never start with them.
const STARTS_SQL = /^\s*(SELECT|INSERT\s+INTO|UPDATE|DELETE\s+FROM|WITH)\b/i;
const TOUCHES_RELATION = /\b(FROM|INTO|UPDATE)\s+[a-zA-Z_"]/;

function extract() {
  const found = [];
  for (const r of ROOTS) {
    for (const file of walk(join(ROOT, r))) {
      const rel = relative(ROOT, file).split('\\').join('/');
      if (EXCLUDE.has(rel)) continue;
      const src = readFileSync(file, 'utf8');
      const re = /`([^`]*)`/gs;
      let m;
      while ((m = re.exec(src)) !== null) {
        const sql = m[1];
        if (!STARTS_SQL.test(sql)) continue;
        if (!TOUCHES_RELATION.test(sql)) continue;
        // ${} interpolation cannot be prepared as written. Flag rather than
        // silently skip — a query assembled by interpolation is exactly the
        // kind this check would most like to see.
        const interpolated = sql.includes('${');
        const line = src.slice(0, m.index).split('\n').length;
        const norm = sql.replace(/\s+/g, ' ').trim();
        found.push({
          id: createHash('sha256').update(norm).digest('hex').slice(0, 12),
          file: rel, line, sql: sql.trim(), interpolated,
        });
      }
    }
  }
  return found;
}

function probe(sql, n) {
  try {
    execFileSync('psql', ['-v', 'ON_ERROR_STOP=1', '-q', '-c',
      `PREPARE qc_${n} AS ${sql.replace(/;\s*$/, '')}`],
      { stdio: ['ignore', 'ignore', 'pipe'] });
    return null;
  } catch (err) {
    const line = String(err.stderr || '').trim().split('\n')[0] || 'unknown error';
    return line.replace(/^ERROR:\s*/, '');
  }
}

const queries = extract();
const results = queries.map((q, i) => ({
  ...q,
  error: q.interpolated ? null : probe(q.sql, i),
}));

if (process.argv.includes('--write-baseline')) {
  const entries = results.filter((r) => r.error).map((r) => ({
    id: r.id, file: r.file, error: r.error,
    why: 'TODO: state why this cannot resolve yet',
    item: 'TODO: the register item that will fix it',
  }));
  writeFileSync(BASELINE, JSON.stringify({ note: 'See query_contract.mjs. Entries may only be REMOVED, never edited to hide a regression.', entries }, null, 2) + '\n');
  console.log(`wrote ${entries.length} baseline entries to ${BASELINE}`);
  process.exit(0);
}

let baseline = { entries: [] };
try { baseline = JSON.parse(readFileSync(BASELINE, 'utf8')); } catch { /* first run */ }
const known = new Map(baseline.entries.map((e) => [e.id, e]));

const failing = results.filter((r) => r.error);
const passing = results.filter((r) => !r.error && !r.interpolated);
const interpolated = results.filter((r) => r.interpolated);

const unexpectedFailures = failing.filter((r) => !known.has(r.id));
const fixedButStillBaselined = passing.filter((r) => known.has(r.id));

console.log(`SQL literals found: ${results.length}  (interpolated, not probed: ${interpolated.length})`);
console.log(`resolve against this schema: ${passing.length}`);
console.log(`known-failing (baselined):   ${failing.length - unexpectedFailures.length} of ${known.size}`);

if (unexpectedFailures.length) {
  console.error(`\n${unexpectedFailures.length} QUERY(S) DO NOT RESOLVE AND ARE NOT BASELINED:\n`);
  for (const r of unexpectedFailures) {
    console.error(`  ${r.file}:${r.line}`);
    console.error(`    ${r.error}`);
    console.error(`    ${r.sql.replace(/\s+/g, ' ').slice(0, 110)}...\n`);
  }
  console.error('If this is a genuine, known divergence rather than a bug, add it to');
  console.error(`${BASELINE} with a reason and the register item that will close it.`);
}

if (fixedButStillBaselined.length) {
  console.error(`\n${fixedButStillBaselined.length} BASELINED QUERY(S) NOW RESOLVE. Remove them from the baseline:\n`);
  for (const r of fixedButStillBaselined) console.error(`  ${r.id}  ${r.file}:${r.line}`);
  console.error('\nThe baseline may only shrink. Leaving a fixed entry in it lets the next');
  console.error('real regression at that spot pass unnoticed.');
}

if (unexpectedFailures.length || fixedButStillBaselined.length) process.exit(1);
console.log('\nQUERY CONTRACT OK.');
