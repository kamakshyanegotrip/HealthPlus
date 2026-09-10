#!/usr/bin/env node
/**
 * HealthPlus — audit payload key contract (HP-RB-001 §10, item 9)
 * ===========================================================================
 *
 * The runbook's order-of-execution list has eleven items. Item 9 reads:
 *
 *     "Write the test asserting no event type emits a non-whitelisted payload
 *      key."
 *
 * It was never written. Item 10 (UPDATE/DELETE refused) is now half-covered by
 * r10f_constraints.sh; this file is item 9, and the word that matters in it is
 * WHITELISTED.
 *
 * ---------------------------------------------------------------------------
 * WHY A BLACKLIST IS NOT THE SAME CHECK, AND BOTH EXISTING CONTROLS ARE ONE
 *
 * Two things guard `response_audit_event.payload` today, and they are the same
 * ten names twice:
 *
 *   migrations/003a  CHECK payload_no_pii — NOT (payload ?| ARRAY[...10...])
 *   auditLog.ts      BANNED_PAYLOAD_KEYS  —                  [...10...]
 *
 * A blacklist answers "is this one of the ten spellings we thought of in
 * August". It does not answer the runbook's question. `{ user_query: ... }`,
 * `{ chief_complaint: ... }`, `{ transcript: ... }` and `{ patient_id: ... }`
 * are all accepted by both controls, all the way to a hash-chained,
 * append-only, UNDELETABLE row — and HP-LB-001's audit-vs-erasure
 * reconciliation rests on that row containing nothing a subject can ask to
 * have erased. A blacklist on an immutable log is a control that fails in the
 * direction you cannot undo.
 *
 * So this gate inverts it: every key any call site emits must be NAMED BELOW.
 * Adding a payload field is then a two-line change — the call site and this
 * list — and the second line is where somebody has to look at the name and
 * decide whether it can carry a person.
 *
 * ---------------------------------------------------------------------------
 * WHY THE SOURCE AND NOT THE DATABASE
 *
 * A DB-side test can only see the payloads a fixture happens to write. The
 * runbook asks about EVENT TYPES — what the code can emit — and that is a
 * property of the call sites, most of which no test exercises (the emergency
 * template path, the two clinical-decision refusals, the validator block).
 * Reading them is the only way to cover all nine.
 *
 * The DB half — that the constraint actually refuses a banned key, as hp_app —
 * belongs with the other constraint refusals and is in r10f_constraints.sh.
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS GATE REFUSES TO GUESS
 *
 * If a call site passes anything other than an object LITERAL — a variable, a
 * spread, a ternary, a function call — its keys are not knowable here and the
 * gate FAILS rather than skipping. A skipped call site is the shape of finding
 * six in the register ("a fixture that proves nothing"): the gate would stay
 * green while the one payload nobody can see grows a `user_text` key.
 */

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const ROOT = new URL('../..', import.meta.url).pathname.replace(/\/$/, '');

// ---------------------------------------------------------------------------
// THE WHITELIST. Every key below is emitted by a call site in
// chat-pipeline/src/app/api/chat/route.ts, and every one of them is an id, an
// enum, a version, a boolean, a count or a digest — HP-RB-001 §3's rule for
// this column, restated as data rather than as a comment.
//
// `reason` and `path` are the two worth pausing on, and both are internal
// STRING CONSTANTS chosen from a fixed set in the source ('emergency_template',
// 'clinical_decision_refusal', unavailable.internalReason). Neither is derived
// from a request. If either ever becomes a formatted message, it stops being a
// version string and this line is the one that has to be re-argued.
// ---------------------------------------------------------------------------
const ALLOWED = new Set([
  // classification
  'category', 'classifier_version', 'confidence', 'ambiguous', 'inputs_digest',
  // severity and the rule that set it
  'severity', 'adoption_gate', 'reason', 'rule_id', 'rule_version',
  'rule_set_id', 'proposed_by_model', 'session_floor_applied',
  // the template that was rendered, and where it came from (J3-5)
  'template_id', 'template_version', 'template_source', 'template_load_failure',
  // publication
  'path', 'review_required', 'agg_confidence', 'blocked_sentence_count', 'uncited',
  // §2.2.5b — WHICH of the five triggers fired, as a list of enum names from a
  // closed set: MINOR_GATE, HIGH_RISK_PROFILE, ELEVATED_TOPIC,
  // ELEVATED_TOPIC_UNEVALUABLE, SEVERITY, CONFIDENCE_BAND, TIER_CONFLICT,
  // BELOW_FLOOR, UNCITED. Enums, so §3's rule holds — and note what is NOT
  // here: no matched TERM, no topic text, no flag key. A term is the clinician's
  // vocabulary rather than the user's, but ELEVATED_TOPIC alone already tells an
  // auditor which of fourteen topics fired via the ordinal in the review queue,
  // and putting the matched substring of a person's message on an append-only,
  // undeletable log is the one direction HP-LB-001's erasure reconciliation
  // cannot come back from.
  'review_triggers',
]);

// The only module permitted to write the log. Anything else reaching the table
// directly bypasses auditLog.ts's own guard and this gate's view of the world.
const SOLE_WRITER = 'chat-pipeline/src/lib/pipeline/auditLog.ts';

const failures = [];
const seen = new Set();
let callSites = 0;

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name === '.next' || name === 'dist') continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (/\.(ts|tsx|mjs|js)$/.test(p)) out.push(p);
  }
  return out;
}

function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .split('\n')
    .filter((line) => !/^\s*(\/\/|\*)/.test(line))
    .join('\n');
}

/** Walks from an opening delimiter to its match, skipping strings. */
function matchDelim(src, start, open, close) {
  let depth = 0;
  for (let i = start; i < src.length; i++) {
    const c = src[i];
    if (c === "'" || c === '"' || c === '`') {
      const q = c;
      i++;
      while (i < src.length && src[i] !== q) i += src[i] === '\\' ? 2 : 1;
      continue;
    }
    if (c === open) depth++;
    else if (c === close) {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/** Top-level commas of an argument list, strings and nesting respected. */
function splitArgs(src) {
  const parts = [];
  let depth = 0, last = 0;
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (c === "'" || c === '"' || c === '`') {
      const q = c;
      i++;
      while (i < src.length && src[i] !== q) i += src[i] === '\\' ? 2 : 1;
      continue;
    }
    if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) depth--;
    else if (c === ',' && depth === 0) { parts.push(src.slice(last, i)); last = i + 1; }
  }
  parts.push(src.slice(last));
  return parts.map((s) => s.trim()).filter((s) => s.length);
}

/** Top-level keys of an object literal, `{` … `}` inclusive. */
function literalKeys(objSrc) {
  const inner = objSrc.slice(1, -1);
  const keys = [];
  for (const field of splitArgs(inner)) {
    const m = /^(?:(['"])([A-Za-z_$][\w$]*)\1|([A-Za-z_$][\w$]*))\s*(?::|$)/.exec(field);
    if (!m) return null;                 // computed key, spread, shorthand we cannot name
    keys.push(m[2] ?? m[3]);
  }
  return keys;
}

// ---------------------------------------------------------------------------
for (const file of walk(join(ROOT, 'chat-pipeline', 'src')).concat(
  walk(join(ROOT, 'src')))) {
  const rel = relative(ROOT, file);
  const src = stripComments(readFileSync(file, 'utf8'));

  if (/INSERT\s+INTO\s+(public\.)?response_audit_event/i.test(src) && rel !== SOLE_WRITER) {
    failures.push(
      `${rel}: writes response_audit_event directly. Only ${SOLE_WRITER} may — a second ` +
      `writer skips assertPayloadClean() and is invisible to this gate.`);
  }

  let idx = 0;
  for (;;) {
    idx = src.indexOf('recordAuditEvent(', idx);
    if (idx < 0) break;
    // Skip the DECLARATION. Its parameter list is five identifiers wide and the
    // fourth is `payload: Record<string, unknown>`, which is exactly the shape
    // this gate refuses — so without this line the gate fails on the one site
    // that is not a call.
    if (/\bfunction\s+$/.test(src.slice(Math.max(0, idx - 40), idx))) {
      idx += 'recordAuditEvent('.length;
      continue;
    }
    const open = src.indexOf('(', idx);
    const close = matchDelim(src, open, '(', ')');
    if (close < 0) { failures.push(`${rel}: unbalanced recordAuditEvent( at offset ${idx}`); break; }
    idx = close;

    const args = splitArgs(src.slice(open + 1, close));
    if (args.length < 4) continue;           // the declaration itself, not a call
    callSites++;
    const line = src.slice(0, open).split('\n').length;
    const payload = args[3];

    if (!payload.startsWith('{') || !payload.endsWith('}')) {
      failures.push(
        `${rel}:${line}: payload is not an object literal (${payload.slice(0, 40)}…). ` +
        `Its keys cannot be checked, so this gate refuses to pass it rather than skip it.`);
      continue;
    }
    const keys = literalKeys(payload);
    if (keys === null) {
      failures.push(
        `${rel}:${line}: payload literal contains a spread or computed key. Name the keys ` +
        `so they can be checked against the whitelist.`);
      continue;
    }
    for (const k of keys) {
      seen.add(k);
      if (!ALLOWED.has(k)) {
        failures.push(
          `${rel}:${line}: payload key "${k}" is not in the whitelist in this file. ` +
          `HP-RB-001 §3: payload carries ids, enums, versions, scores and hashes — never ` +
          `user text, health attributes or names. If it is one of those, add it here.`);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// The two controls that already exist must agree with each other. They are the
// same ten names in two files and nothing has ever compared them; a key added
// to one and not the other is a guard that reports success it did not achieve.
// ---------------------------------------------------------------------------
{
  const mig = readFileSync(join(ROOT, 'migrations', '003a_response_audit_immutability_hp_rb_001.sql'), 'utf8');
  const arr = /payload\s*\?\|\s*ARRAY\[([^\]]*)\]/i.exec(mig);
  const code = readFileSync(join(ROOT, SOLE_WRITER), 'utf8');
  const list = /BANNED_PAYLOAD_KEYS\s*=\s*\[([^\]]*)\]/.exec(code);
  if (!arr || !list) {
    failures.push('could not read both banned-key lists — one of them has been renamed or removed.');
  } else {
    const names = (s) => new Set([...s.matchAll(/'([^']+)'/g)].map((m) => m[1]));
    const a = names(arr[1]), b = names(list[1]);
    const only = (x, y) => [...x].filter((k) => !y.has(k));
    if (only(a, b).length || only(b, a).length) {
      failures.push(
        `the two banned-key lists have drifted: constraint-only [${only(a, b)}], ` +
        `code-only [${only(b, a)}]. They are the same rule stated twice and must match.`);
    }
  }
}

// A whitelist entry with no call site is a name somebody kept after deleting
// its emitter. Reported, not fatal: it is untidiness, not a hole.
const unused = [...ALLOWED].filter((k) => !seen.has(k));

if (failures.length) {
  console.error(`RB-001 payload keys: ${failures.length} failure(s) across ${callSites} call site(s).\n`);
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}
console.log(
  `RB-001 payload keys: ${callSites} call site(s), ${seen.size} distinct key(s), all whitelisted.` +
  (unused.length ? `\n  note: ${unused.length} whitelist entr(ies) no longer emitted: ${unused.join(', ')}` : ''));
