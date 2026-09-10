#!/usr/bin/env tsx
/**
 * What does the CURRENTLY ADOPTED rule set do with these messages?
 *
 * ===========================================================================
 * WHY THIS IS A SCRIPT RATHER THAN A TEST
 *
 * A test asserts an expected answer. This has none: the review pack's forty
 * gold-set cases ship UNLABELLED, because the labels are the clinical lead's
 * and a fixture that arrived with its own answers would be worth nothing as a
 * measure of anything (HP-CGP-004 §2).
 *
 * So this prints what the rules DO, and says nothing about whether that is
 * right. It exists for the loop between sending the pack and getting it back:
 *
 *   npx tsx scripts/seed-demo.ts             # load the 44 draft rules
 *   npx tsx scripts/scan-probe.ts            # see what they catch
 *   npx tsx scripts/scan-probe.ts "free text message"   # try one by hand
 *   npx tsx scripts/seed-demo.ts --revert    # back to the CI fixture
 *
 * ===========================================================================
 * THE NUMBER AT THE BOTTOM IS NOT A RECALL FIGURE
 *
 * It counts how many synthetic cases the adopted rules leave at NORMAL. Some of
 * those SHOULD be NORMAL — four of the forty are deliberate hard negatives
 * (pricing, logistics, accreditation, recovery times) and a rule set that
 * flagged them would be worse, not better.
 *
 * Recall becomes computable when the returned pack supplies the labels, and
 * §6.4's release gate reports UNCOMPUTABLE until then. That is CL9 / AMB-22,
 * and this script is not a substitute for it.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { scanRedFlags } from '../src/lib/pipeline/redFlagEngine';
import { seedQuery, endSeedPool } from './seed-real';

const HERE = dirname(fileURLToPath(import.meta.url));

interface GoldCase { case: string; message: string; why: string }

async function severityOf(message: string): Promise<string> {
  const ctx = {
    sessionId: randomUUID(),
    userId: randomUUID(),
    message,
    dataRegion: process.env.DATA_REGION ?? 'IN',
    auditId: randomUUID(),
    receivedAt: new Date().toISOString(),
    statedCountry: null,
    language: 'en',
  } as never;
  const out = (await scanRedFlags(ctx)) as { severity: string };
  return out.severity;
}

(async () => {
  const adopted = await seedQuery<{ version_label: string; adopted_rules: string }>(
    `SELECT version_label, adopted_rules FROM safety.adopted_rule_set($1, 'en')`,
    [process.env.DATA_REGION ?? 'IN'],
  );
  if (!adopted.length) {
    console.log('NOTHING IS ADOPTED. Every message ends in the unavailability notice, and');
    console.log('the scanner is not consulted at all — §0.6 / AMB-17 working as designed.');
    await endSeedPool();
    return;
  }
  console.log(`adopted rule set: ${adopted[0].version_label} (${adopted[0].adopted_rules} rules)\n`);

  // Indices are taken against the SLICED array. Against process.argv they are
  // off by two, and the flag's value survives the filter and is scanned as if it
  // were a patient message — which prints "NORMAL | /path/to/out.json" and looks
  // like a working run.
  const args = process.argv.slice(2);
  const jsonAt = args.indexOf('--json');
  const jsonOut = jsonAt >= 0 ? args[jsonAt + 1] ?? null : null;
  const argMessages = args.filter((_, i) => jsonAt < 0 || (i !== jsonAt && i !== jsonAt + 1));
  if (argMessages.length) {
    for (const m of argMessages) console.log(`${(await severityOf(m)).padEnd(10)} | ${m}`);
    await endSeedPool();
    return;
  }

  const gold = (JSON.parse(readFileSync(join(HERE, 'fixtures', 'draft-rule-set.json'), 'utf8'))
    .goldSet ?? []) as GoldCase[];
  let normal = 0;
  const results: Array<{ case: string; severity: string }> = [];
  for (const g of gold) {
    const sev = await severityOf(g.message);
    if (sev === 'NORMAL') normal++;
    results.push({ case: g.case, severity: sev });
    console.log(`${g.case}  ${sev.padEnd(10)} | ${g.message.slice(0, 92)}`);
  }
  // --json feeds the review pack's "Draft rules assign" column, so the clinician
  // compares their label against what the rules DO rather than against nothing.
  if (jsonOut) {
    writeFileSync(jsonOut, JSON.stringify(
      { ruleSet: adopted[0].version_label, rules: adopted[0].adopted_rules, results }, null, 2) + '\n');
    console.log(`\nwrote ${jsonOut}`);
  }
  console.log(
    `\n${normal} of ${gold.length} synthetic cases are left at NORMAL by the adopted rules.\n` +
    'Four of them are deliberate hard negatives, so this is NOT a miss count and NOT a recall\n' +
    'figure. Recall needs the clinical lead\'s labels (CL9 / AMB-22); until they exist the\n' +
    '§6.4 gate correctly reports that it cannot measure safety at all.',
  );
  await endSeedPool();
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
  void endSeedPool();
});
