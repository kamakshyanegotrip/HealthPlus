#!/usr/bin/env tsx
/**
 * The DEMO rule set — a development fixture, and nothing else.
 *
 * ===========================================================================
 * WHAT THIS IS FOR
 *
 * `scripts/seed-real.ts` seeds ONE rule (chest pain) and TWO templates. That is
 * deliberate: the integration tests assert exact severities and exact rendered
 * text against it, and a fixture with fifty rules in it would make those
 * assertions depend on which rule happened to match first.
 *
 * It is also useless for looking at the product. One rule means one path
 * through the escalation ladder, and every other message returns NORMAL.
 *
 * This script loads the 44 evaluable rules and 5 templates from
 * `scripts/fixtures/draft-rule-set.json` — the machine form of the same list
 * that HealthPlus_Clinical_Review_Pack.xlsx puts in front of the clinical lead
 * (HP-CGP-004). Both are generated from one source, so the thing you demo and
 * the thing they are marking up cannot drift apart.
 *
 * ===========================================================================
 * WHAT THIS IS NOT
 *
 * IT IS NOT AN ADOPTED RULE SET, and running it does not close AMB-17.
 *
 * Every rule it writes carries `clinically_adopted = true`, `approved_by` and
 * `adopted_by` pointing at 'Seed Clinician' — a row in `principal.app_user`
 * with the auth_subject 'seed-clinician' and no registration number, because no
 * clinician has signed anything. In a development database that is a fixture.
 * In any database holding a real patient record it is a FABRICATED CLINICAL
 * GOVERNANCE RECORD, and `red_flag_rule.adopted_by` is a foreign key into
 * `principal.clinician` precisely so that it cannot be written by accident.
 *
 * Hence the guard below. It is deliberately a nuisance.
 *
 * ===========================================================================
 * HOW IT AVOIDS BREAKING CI
 *
 * `safety.adopted_rule_set()` is `ORDER BY jurisdiction NULLS LAST,
 * effective_from DESC LIMIT 1`. seed-real's set is `now() - interval '1 day'`;
 * this one is `now()`, so it WINS while it exists, and `--revert` sets
 * `retired_at` on it, after which the seed-real set is selected again and the
 * integration tests pass unchanged.
 *
 * That is supersession using the schema's own machinery rather than deleting
 * rows out from under it — and `retired_at` rather than DELETE means the demo
 * set stays visible in the audit trail of anything that ran against it.
 *
 *   npx tsx scripts/seed-demo.ts             # load the demo set
 *   npx tsx scripts/seed-demo.ts --revert    # retire it; CI fixture is live again
 *   npx tsx scripts/seed-demo.ts --status    # which set adopted_rule_set() returns
 */
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import type pg from 'pg';
import { seedQuery, endSeedPool, withSeedTx, SEED } from './seed-real';

const HERE = dirname(fileURLToPath(import.meta.url));

/** Stable so re-running converges instead of accumulating rule sets. */
const DEMO_RULE_SET = '44444444-4444-4444-4444-4444444444de';
const DEMO_LABEL = 'DEMO-NOT-CLINICALLY-ADOPTED';

interface DraftRule {
  id: string;
  severity: string;
  trigger: string;
  pattern: unknown;
  evaluableToday: boolean;
  rationale: string;
  source: string;
}
interface DraftTemplate {
  id: string; severity: string; jurisdiction: string; language: string;
  body: string; slots: string; note: string;
}

function load() {
  const raw = readFileSync(join(HERE, 'fixtures', 'draft-rule-set.json'), 'utf8');
  return JSON.parse(raw) as { rules: DraftRule[]; templates: DraftTemplate[] };
}

/**
 * A uuid derived from the rule's own id, so the same draft rule always lands on
 * the same row and a re-run updates rather than duplicates. Not cryptographic —
 * it only has to be stable and collision-free across 51 short ASCII strings.
 */
function ruleUuid(ruleId: string): string {
  let h = 0x811c9dc5;
  for (const ch of ruleId) { h ^= ch.charCodeAt(0); h = Math.imul(h, 0x01000193) >>> 0; }
  const hex = h.toString(16).padStart(8, '0');
  return `44444444-4444-4444-4d44-${hex}${'0'.repeat(4)}`;
}

async function currentSet() {
  const rows = await seedQuery<{ version_label: string; adopted_rules: string }>(
    `SELECT version_label, adopted_rules FROM safety.adopted_rule_set($1, 'en')`,
    [process.env.DATA_REGION ?? 'IN'],
  );
  return rows[0] ?? null;
}

async function status() {
  const s = await currentSet();
  if (!s) {
    console.log('adopted_rule_set(): NOTHING ADOPTED — every turn ends in the unavailability notice.');
  } else {
    console.log(`adopted_rule_set(): ${s.version_label} (${s.adopted_rules} rules)`);
  }
}

async function revert() {
  const n = await withSeedTx((c) =>
    c.query(
      `UPDATE safety.red_flag_rule_set SET retired_at = now()
        WHERE id = $1 AND retired_at IS NULL RETURNING id`,
      [DEMO_RULE_SET],
    ).then((res) => res.rowCount ?? 0),
  );
  console.log(n ? 'seed-demo: demo rule set retired.' : 'seed-demo: nothing to retire.');
  await status();
}

async function apply() {
  if (process.env.DEMO_SEED_I_UNDERSTAND !== 'yes') {
    console.error(
      'REFUSING.\n\n' +
      'This writes rules marked clinically_adopted=true, attributed to a fixture\n' +
      'clinician who has signed nothing. In a development database that is a\n' +
      'fixture; anywhere a real patient record could land it is a fabricated\n' +
      'clinical governance record.\n\n' +
      'If this database is a throwaway, set DEMO_SEED_I_UNDERSTAND=yes and run again.',
    );
    process.exitCode = 1;
    return;
  }

  const { rules, templates } = load();
  const evaluable = rules.filter((r) => r.evaluableToday);

  // ONE TRANSACTION for the whole fixture — see withSeedTx's comment. Before
  // it, a unique-key failure on the fourth template left three rules sets'
  // worth of rows committed one at a time and an adopted-but-partial rule set
  // selected by adopted_rule_set().
  const { loaded, evaluableCount } = await withSeedTx(async (c) => {
  const region = await c.query<{ data_region: string }>(
    `SELECT data_region FROM public.residency_admission
      WHERE admission_state = 'ADMITTED' ORDER BY residency_country LIMIT 1`,
  ).then((x) => x.rows);
  if (!region.length) throw new Error('seed-demo: no ADMITTED residency. Run scripts/seed-real.ts first.');
  const r = region[0].data_region;

  const clin = await c.query(`SELECT user_id FROM principal.clinician WHERE user_id = $1`, [SEED.clinician]);
  if (!clin.rowCount) throw new Error('seed-demo: the fixture clinician does not exist. Run scripts/seed-real.ts first.');

  // effective_from = now() so this set outranks seed-real's (now() - 1 day) in
  // adopted_rule_set()'s ORDER BY. retired_at is cleared on re-apply so a
  // reverted set can be brought back without a new id.
  await c.query(
    `INSERT INTO safety.red_flag_rule_set
       (id, version_label, jurisdiction, language, approved_by, approved_at, effective_from)
     VALUES ($1, $2, $3, 'en', $4, now(), now())
     ON CONFLICT (id) DO UPDATE
       SET retired_at = NULL, effective_from = now(), superseded_by = NULL`,
    [DEMO_RULE_SET, DEMO_LABEL, r, SEED.clinician],
  );

  for (const rule of evaluable) {
    await c.query(
      `INSERT INTO safety.red_flag_rule
         (id, version, pattern, severity, rationale, approved_by, approved_at,
          rule_set_id, jurisdiction, clinically_adopted, adopted_by, adopted_at)
       VALUES ($1, 1, $2::jsonb, $3, $4, $5, now(), $6, $7, true, $5, now())
       -- DO UPDATE, not DO NOTHING: seed-real learned this the hard way. A
       -- fixture must CONVERGE on its declared state, or an edited draft rule
       -- silently keeps its old pattern in every long-lived dev database.
       ON CONFLICT (id, version) DO UPDATE
         SET pattern = EXCLUDED.pattern, severity = EXCLUDED.severity,
             rationale = EXCLUDED.rationale, retired_at = NULL`,
      [ruleUuid(rule.id), JSON.stringify(rule.pattern), rule.severity,
       `${rule.id} — ${rule.trigger} [DRAFT, UNADOPTED; source: ${rule.source}]`,
       SEED.clinician, DEMO_RULE_SET, r],
    );
  }

  // §4.3.3 RESOLVES A TEMPLATE BY (severity, jurisdiction, language) — AND THE
  // SCHEMA ENFORCES THAT AS A UNIQUE KEY:
  //
  //     safety_template_severity_jurisdiction_language_version_key
  //     Key (severity, jurisdiction, language, version)=(URGENT, IN, en, 1)
  //         already exists.
  //
  // Found by running this, not by reading the DDL. Two consequences, and the
  // second is a finding rather than a fixture problem:
  //
  //   1. seed-real already owns (URGENT, IN, en, 1) and (CRITICAL, IN, en, 1),
  //      and the integration test asserts the CRITICAL body VERBATIM. This
  //      script must not overwrite them — skipping is required, not tidiness.
  //   2. The mental-health EMERGENCY variant in the review pack CANNOT EXIST.
  //      Its key is (EMERGENCY, IN, en) — the same as the general emergency
  //      template. The ladder has no dimension for "which kind of emergency",
  //      so a self-harm-specific emergency template needs a schema change, not
  //      a clinician's signature. That belongs to AMB-18 and is recorded on
  //      sheet G of the review pack.
  const existing = await c.query<{ severity: string; jurisdiction: string; language: string }>(
    `SELECT severity::text, jurisdiction, language FROM safety.safety_template WHERE version = 1`,
  ).then((x) => x.rows);
  const taken = new Set(existing.map((e) => `${e.severity}|${e.jurisdiction}|${e.language}`));
  let loaded = 0;
  for (const t of templates) {
    const juris = t.jurisdiction === 'IN' ? r : t.jurisdiction;
    const key = `${t.severity}|${juris}|${t.language}`;
    if (taken.has(key)) {
      console.warn(`seed-demo: SKIPPED ${t.id} — a ${key} template already exists at version 1 ` +
                   `(§4.3.3's resolution key is unique). See this file's comment.`);
      continue;
    }
    taken.add(key);
    await c.query(
      `INSERT INTO safety.safety_template
         (id, version, severity, jurisdiction, language, body, slots, approved_by, approved_at,
          rule_set_id, is_fallback, machine_translated)
       VALUES ($1, 1, $2, $3, $4, $5, '{}'::jsonb, $6, now(), $7, false, false)
       ON CONFLICT (id, version) DO UPDATE SET body = EXCLUDED.body`,
      [templateUuid(t.id), t.severity, juris, t.language, t.body, SEED.clinician, DEMO_RULE_SET],
    );
    loaded++;
  }
  return { loaded, evaluableCount: evaluable.length };
  });

  console.log(
    `seed-demo: loaded ${evaluableCount} evaluable rules (of ${rules.length} drafted) ` +
    `and ${loaded} template(s) as ${DEMO_LABEL}.`,
  );
  console.log('seed-demo: NOT ADOPTED. Revert with: npx tsx scripts/seed-demo.ts --revert');
  await status();
}

function templateUuid(id: string): string {
  let h = 0x811c9dc5;
  for (const ch of id) { h ^= ch.charCodeAt(0); h = Math.imul(h, 0x01000193) >>> 0; }
  return `44444444-4444-4444-4e44-${h.toString(16).padStart(8, '0')}0000`;
}

const arg = process.argv[2];
const run = arg === '--revert' ? revert : arg === '--status' ? status : apply;
run()
  .catch((e) => { console.error(e); process.exitCode = 1; })
  .finally(() => endSeedPool());
