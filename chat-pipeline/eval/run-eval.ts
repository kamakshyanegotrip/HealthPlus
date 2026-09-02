#!/usr/bin/env -S npx tsx
/**
 * §6.4 eval suite runner — "prompts, classifiers and retrieval config are
 * versioned artefacts with an eval suite gating release." The prompt
 * registry (src/lib/prompts/registry.ts) is the versioning half of that
 * requirement; this is the gating half.
 *
 * Drives the gold-set fixtures in eval/gold/*.json against the ACTUAL,
 * currently-shipping pure functions (imported directly from src/, not
 * reimplemented here) that classifySentence, parseAndResolveCategory, and
 * the red-flag severity composition logic are built from. All three are
 * deliberately pure — no DB, no network, no live Anthropic call — so this
 * suite runs anywhere, including CI, in well under a second.
 *
 * HONEST SCOPE NOTE: this evaluates the deterministic logic WRAPPED AROUND
 * each model call (parsing, ambiguity resolution, fail-closed defaults,
 * severity clamping, template resolution) — not the model's own judgement.
 * Evaluating the model call itself (does Haiku actually classify this
 * message as DECISION_SUPPORT) needs a live ANTHROPIC_API_KEY and real
 * traffic, which this sandbox does not have — see scripts/live-anthropic-
 * smoke.mjs and the README for that half, honestly marked as unrun here.
 * What IS fully evaluated below is real and load-bearing: it is exactly the
 * code that turns a model's raw output into what gets persisted and shown
 * to a patient, and it is exactly the code a prompt-format change (e.g.
 * altering the classifier's JSON shape) or a ruleset bump could silently
 * break without ever touching the model itself.
 *
 * Usage: npm run eval
 * Exit code: 0 if every case in every suite passes, 1 otherwise (this is
 * the actual "gate" — wire this into CI as a required check, same as any
 * other test).
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { classifySentence } from '../src/lib/pipeline/emissionValidator';
import { parseAndResolveCategory } from '../src/lib/pipeline/categoryClassifier';
import {
  clampSeverity,
  resolveTemplateRequirement,
  deriveActionTaken,
  applySessionFloor,
  GENERIC_ESCALATION_TEMPLATE_ID,
  type RedFlagActionTaken,
} from '../src/lib/pipeline/redFlagEngine';
import type { RetrievedClaim, ResponseCategory, RedFlagSeverity } from '../src/lib/types';

const HERE = dirname(fileURLToPath(import.meta.url));
const GOLD_DIR = join(HERE, 'gold');

interface CaseResult {
  suite: string;
  id: string;
  description: string;
  pass: boolean;
  detail?: string;
}

const results: CaseResult[] = [];

function record(suite: string, id: string, description: string, pass: boolean, detail?: string) {
  results.push({ suite, id, description, pass, detail });
}

// ---- suite 1: emissionValidator.classifySentence --------------------------
function runEmissionValidatorSuite() {
  const path = join(GOLD_DIR, 'emissionValidator.gold.json');
  const gold = JSON.parse(readFileSync(path, 'utf8'));
  const suiteName = gold.suite as string;
  const claimBank: Record<string, RetrievedClaim> = gold.retrievedClaims;

  for (const c of gold.cases) {
    const claims = new Map<string, RetrievedClaim>((c.claims as string[]).map((key) => [claimBank[key]!.claimId, claimBank[key]!]));
    const verdict = classifySentence(c.raw, claims);
    const problems: string[] = [];

    if (verdict.kind !== c.expect.kind) problems.push(`kind: expected ${c.expect.kind}, got ${verdict.kind}`);
    if (c.expect.prohibitionClass && verdict.kind === 'blocked' && verdict.prohibitionClass !== c.expect.prohibitionClass) {
      problems.push(`prohibitionClass: expected ${c.expect.prohibitionClass}, got ${verdict.prohibitionClass}`);
    }
    if (c.expect.citedClaimIds && verdict.kind === 'sentence') {
      const got = [...verdict.citedClaimIds].sort();
      const want = [...(c.expect.citedClaimIds as string[])].sort();
      if (JSON.stringify(got) !== JSON.stringify(want)) problems.push(`citedClaimIds: expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
    }
    if (c.expect.textEquals !== undefined && 'text' in verdict && verdict.text !== c.expect.textEquals) {
      problems.push(`text: expected "${c.expect.textEquals}", got "${verdict.text}"`);
    }
    if (c.expect.textMustNotContain !== undefined && 'text' in verdict && verdict.text.includes(c.expect.textMustNotContain)) {
      problems.push(`text unexpectedly still contains "${c.expect.textMustNotContain}"`);
    }

    record(suiteName, c.id, c.description, problems.length === 0, problems.join('; '));
  }
}

// ---- suite 2: categoryClassifier.parseAndResolveCategory -------------------
function runCategoryClassifierSuite() {
  const path = join(GOLD_DIR, 'categoryClassifier.gold.json');
  const gold = JSON.parse(readFileSync(path, 'utf8'));
  const suiteName = gold.suite as string;

  for (const c of gold.cases) {
    const { category, confidence, ambiguous } = parseAndResolveCategory(c.rawText);
    const problems: string[] = [];
    if (category !== c.expect.category) problems.push(`category: expected ${c.expect.category}, got ${category}`);
    if (ambiguous !== c.expect.ambiguous) problems.push(`ambiguous: expected ${c.expect.ambiguous}, got ${ambiguous}`);
    if (c.expect.confidence !== undefined && confidence !== c.expect.confidence) problems.push(`confidence: expected ${c.expect.confidence}, got ${confidence}`);
    record(suiteName, c.id, c.description, problems.length === 0, problems.join('; '));
  }
}

// ---- suite 3: redFlagEngine severity composition ---------------------------
function runRedFlagCompositionSuite() {
  const path = join(GOLD_DIR, 'redFlagComposition.gold.json');
  const gold = JSON.parse(readFileSync(path, 'utf8'));
  const suiteName = gold.suite as string;

  for (const c of gold.clampSeverity_cases) {
    const got = clampSeverity(c.base as RedFlagSeverity, c.proposed as RedFlagSeverity);
    record(suiteName, c.id, c.description, got === c.expect, got === c.expect ? undefined : `expected ${c.expect}, got ${got}`);
  }

  for (const c of gold.resolveTemplateRequirement_cases) {
    const wantTemplateId = c.expect.templateId === 'GENERIC_ESCALATION_TEMPLATE_ID' ? GENERIC_ESCALATION_TEMPLATE_ID : c.expect.templateId;
    const got = resolveTemplateRequirement(c.applied as RedFlagSeverity, c.ruleTemplateId, c.ruleTemplateVersion);
    const problems: string[] = [];
    if (got.templateId !== wantTemplateId) problems.push(`templateId: expected ${wantTemplateId}, got ${got.templateId}`);
    if (got.templateVersion !== c.expect.templateVersion) problems.push(`templateVersion: expected ${c.expect.templateVersion}, got ${got.templateVersion}`);
    record(suiteName, c.id, c.description, problems.length === 0, problems.join('; '));
  }

  for (const c of gold.deriveActionTaken_cases) {
    const got: RedFlagActionTaken = deriveActionTaken(c.severity as RedFlagSeverity, c.emergencyTemplateShown as boolean);
    record(suiteName, c.id, c.description, got === c.expect, got === c.expect ? undefined : `expected ${c.expect}, got ${got}`);
  }

  for (const c of gold.applySessionFloor_cases) {
    const got = applySessionFloor(c.severity as RedFlagSeverity, c.floor);
    record(suiteName, c.id, c.description, got === c.expect, got === c.expect ? undefined : `expected ${c.expect}, got ${got}`);
  }
}

// ---- run + report -----------------------------------------------------------
runEmissionValidatorSuite();
runCategoryClassifierSuite();
runRedFlagCompositionSuite();

const bySuite = new Map<string, CaseResult[]>();
for (const r of results) {
  if (!bySuite.has(r.suite)) bySuite.set(r.suite, []);
  bySuite.get(r.suite)!.push(r);
}

let totalPass = 0;
let totalCases = 0;
for (const [suite, cases] of bySuite) {
  const pass = cases.filter((c) => c.pass).length;
  totalPass += pass;
  totalCases += cases.length;
  console.log(`\n${suite} — ${pass}/${cases.length} passed`);
  for (const c of cases) {
    if (c.pass) {
      console.log(`  OK   ${c.id}  ${c.description}`);
    } else {
      console.log(`  FAIL ${c.id}  ${c.description}\n       ${c.detail}`);
    }
  }
}

const passRate = totalCases > 0 ? ((totalPass / totalCases) * 100).toFixed(1) : '0.0';
console.log(`\n${'='.repeat(70)}`);
console.log(`TOTAL: ${totalPass}/${totalCases} passed (${passRate}%)`);
console.log('='.repeat(70));

if (totalPass !== totalCases) {
  console.error('\nEVAL GATE FAILED — at least one gold-set case regressed. This must be fixed (or the gold-set case deliberately revised with a documented reason) before the change that caused it ships.');
  process.exit(1);
}
console.log('\nEVAL GATE PASSED.');
