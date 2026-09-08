/**
 * HealthPlus — the one extractor for SQL literals in the shipping tree.
 * ===========================================================================
 *
 * Lifted verbatim out of `query_contract.mjs` when `role_contract.mjs`
 * (register item R13-roleci) needed the same list. It is a separate module
 * rather than a copy on purpose: two extractors would drift, and the two gates
 * would then disagree about how many queries exist while both reported
 * confidently. This project has already paid for that shape twice — the stub
 * that drifted from the module it doubled, and a fake that encoded the same
 * wrong assumption as the code it tested.
 *
 * Nothing here talks to a database. It reads files and returns a list.
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, relative } from 'node:path';

// Shipping source only. Test files are excluded deliberately: a test may
// legitimately assert against a stub-shaped table, and mixing those in would
// blur the one question these checks exist to answer — does the code we deploy
// match the schema we deploy?
export const ROOTS = ['src', 'chat-pipeline/src', 'chat-pipeline/worker', 'chat-pipeline/scripts'];
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
export const EXCLUDE = new Set(['chat-pipeline/scripts/smoke-test.mjs']);

export function walk(dir, out = []) {
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

// A SQL literal, for these checks, is a backtick template literal whose first
// word is a statement keyword. Anchoring on the FIRST word rather than
// searching anywhere in the string is what keeps Annex B prompt text out:
// prompts mention SELECT and UPDATE in prose, but never start with them.
const STARTS_SQL = /^\s*(SELECT|INSERT\s+INTO|UPDATE|DELETE\s+FROM|WITH)\b/i;
const TOUCHES_RELATION = /\b(FROM|INTO|UPDATE)\s+[a-zA-Z_"]/;

/** @returns {{id:string,file:string,line:number,sql:string,interpolated:boolean}[]} */
export function extract(root = process.cwd()) {
  const found = [];
  for (const r of ROOTS) {
    for (const file of walk(join(root, r))) {
      const rel = relative(root, file).split('\\').join('/');
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
        // kind these checks would most like to see.
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
