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
  deriveActionTaken,
  applySessionFloor,
  type RedFlagActionTaken,
} from '../src/lib/pipeline/redFlagEngine';
// R2: template resolution moved out of redFlagEngine. `resolveTemplateRequirement`
// and `GENERIC_ESCALATION_TEMPLATE_ID` no longer exist — a template is found by
// climbing the §4.3.3/§4.3.4 ladder, not by an FK on the rule row. Both functions
// below take an injected `lookup`, so the suite stays pure (no DB, no network).
import {
  resolveTemplateForSeverity,
  NoApprovedTemplateError,
  type SafetyTemplateRow,
} from '../src/lib/pipeline/templateResolution';
// HP-JOB-011 — the composition layer the RESPONSE_COMPOSER prompt sits on.
import { resolveConstraints, applyConstraints } from '../src/lib/pipeline/constraintSet';
import { planCoverage, type DimensionKey } from '../src/lib/pipeline/coveragePlan';
import { loadPrompt } from '../src/lib/prompts/registry';
import type { RetrievedClaim, ResponseCategory, RedFlagSeverity, PatientProfile, KnowledgeDomain } from '../src/lib/types';

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
async function runRedFlagCompositionSuite() {
  const path = join(GOLD_DIR, 'redFlagComposition.gold.json');
  const gold = JSON.parse(readFileSync(path, 'utf8'));
  const suiteName = gold.suite as string;

  for (const c of gold.clampSeverity_cases) {
    const got = clampSeverity(c.base as RedFlagSeverity, c.proposed as RedFlagSeverity);
    record(suiteName, c.id, c.description, got === c.expect, got === c.expect ? undefined : `expected ${c.expect}, got ${got}`);
  }

  for (const c of gold.templateLadder_cases) {
    // Stands in for `lookupTemplate`, including its `ORDER BY version DESC
    // LIMIT 1` — the ladder must be exercised against the same one-row-per-key
    // contract the real query provides, or the eval proves nothing about it.
    const rows = c.available as SafetyTemplateRow[];
    const lookup = async (a: { severity: RedFlagSeverity; jurisdiction: string; language: string }) =>
      rows
        .filter((r) => r.severity === a.severity && r.jurisdiction === a.jurisdiction && r.language === a.language)
        .sort((x, y) => y.version - x.version)[0] ?? null;

    const problems: string[] = [];
    try {
      const got = await resolveTemplateForSeverity(
        c.requested as RedFlagSeverity,
        c.jurisdiction as string,
        c.language as string,
        lookup,
      );
      if (c.expect.failClosed) {
        problems.push(`expected NoApprovedTemplateError, got ${got ? got.template.id : 'null'}`);
      } else if (c.expect.needed === false) {
        if (got !== null) problems.push(`expected no template to be required, got ${got.template.id}`);
      } else if (!got) {
        problems.push(`templateId: expected ${c.expect.templateId}, got null`);
      } else {
        if (got.template.id !== c.expect.templateId) problems.push(`templateId: expected ${c.expect.templateId}, got ${got.template.id}`);
        if (got.resolvedSeverity !== c.expect.resolvedSeverity) problems.push(`resolvedSeverity: expected ${c.expect.resolvedSeverity}, got ${got.resolvedSeverity}`);
        if (got.isFallback !== c.expect.isFallback) problems.push(`isFallback: expected ${c.expect.isFallback}, got ${got.isFallback} (${got.fallbackReason ?? 'no reason'})`);
      }
    } catch (err) {
      if (c.expect.failClosed && err instanceof NoApprovedTemplateError) {
        // The §4.0.9 fail-closed path. Nothing to assert beyond the class:
        // the caller turns this into FAIL_CLOSED, never into generation.
      } else {
        problems.push(`unexpected throw: ${(err as Error).name}: ${(err as Error).message}`);
      }
    }
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

// ---- suite 4: composition — coverage plan and constraint ladder (HP-JOB-011)
/**
 * §6.4 gates "prompts, classifiers and retrieval config". `RESPONSE_COMPOSER`
 * is now one of those prompts, and the thing a prompt change can silently break
 * is not the prose — it is WHICH DIMENSIONS GET DEFERRED. A composer that stops
 * deferring travel fitness is a §3.2.3 violation that reads perfectly well.
 *
 * So what is gated here is the deterministic layer the composer prompt sits on
 * top of: the deferral map, the publishable/refuse decision, and the two ladder
 * behaviours a reviewer would most plausibly "simplify" — that a budget bound
 * marks rather than drops (§3.3.3), and that a stated condition never becomes a
 * constraint (§3.8.2).
 *
 * Same honest scope note as the suites above: this is the code around the model
 * call, not the model's judgement. Whether Opus actually weaves needs a live
 * key — `npm run eval:composer`, marked unrun.
 */
function runCompositionSuite() {
  const suite = 'composition (coveragePlan + constraintSet, HP-JOB-011)';
  const fx = JSON.parse(readFileSync(join(GOLD_DIR, 'section42.gold.json'), 'utf8')) as {
    message: string;
    intent: { requiresKnowledgeDomains: KnowledgeDomain[] };
    preferences: Record<string, unknown>;
    expectedDimensions: DimensionKey[];
    expectedDeferred: DimensionKey[];
    claims: RetrievedClaim[];
  };

  const profile = {
    userId: 'eval', dataRegion: 'IN', residencyCountry: 'NG', riskFlags: [],
    statedConditions: [{ label: 'type 2 diabetes', provenance: 'stated' as const }],
    preferences: fx.preferences, isMinor: null,
  } as PatientProfile;

  const ladder = resolveConstraints(profile, { redFlagSeverityAtLeastWarning: false });
  const applied = applyConstraints(ladder, fx.claims);
  const plan = planCoverage({
    message: fx.message,
    intentDomains: fx.intent.requiresKnowledgeDomains,
    admittedClaims: applied.admitted,
    categoryWasClinicalDecision: true,
  });

  const eq = (a: readonly string[], b: readonly string[]) => [...a].sort().join(',') === [...b].sort().join(',');

  record(suite, 'cmp-01', '§42 plans all ten dimensions',
    eq(plan.dimensions.map((d) => d.key), fx.expectedDimensions),
    `got ${plan.dimensions.map((d) => d.key).join(',')}`);

  record(suite, 'cmp-02', '§42 defers exactly the four Category C dimensions (§2.4.1a)',
    eq(plan.deferredDimensions, fx.expectedDeferred),
    `got ${plan.deferredDimensions.join(',')}`);

  record(suite, 'cmp-03', 'a mixed turn is publishable rather than refused (§2.3.6(c))',
    plan.publishable === true);

  record(suite, 'cmp-04', 'every deferral carries its clause and a question for the clinician',
    plan.dimensions.filter((d) => d.deferral).every((d) => Boolean(d.deferral?.clause) && Boolean(d.deferral?.clinicianQuestion)));

  const pure = planCoverage({ message: 'Am I fit to fly?', intentDomains: [], admittedClaims: [], categoryWasClinicalDecision: true });
  record(suite, 'cmp-05', 'a pure Category C turn is NOT publishable — the flat refusal stands',
    pure.publishable === false);

  const ordinary = planCoverage({ message: fx.message, intentDomains: fx.intent.requiresKnowledgeDomains, admittedClaims: applied.admitted, categoryWasClinicalDecision: false });
  record(suite, 'cmp-06', 'no deferral machinery runs on an ordinary Decision Support turn',
    ordinary.deferredDimensions.length === 0);

  record(suite, 'cmp-07', 'a stated dietary exclusion suppresses the conflicting pattern and says why',
    applied.suppressed.length > 0 && applied.suppressed.every((s) => /vegetarian/i.test(s.statement)));

  record(suite, 'cmp-08', 'an over-budget cost claim is MARKED, never dropped (§3.3.3)',
    applied.bounded.length > 0 && applied.bounded.every((b) => applied.admitted.some((c) => c.claimId === b.claim.claimId)));

  record(suite, 'cmp-09', 'a stated CONDITION never becomes a constraint (§3.8.2 / §2.3.1)',
    !/diabet/i.test(JSON.stringify(ladder)));

  record(suite, 'cmp-10', 'the composer prompt is registry-versioned (§6.4)',
    loadPrompt('RESPONSE_COMPOSER').version.length > 0);
}

// ---- run + report -----------------------------------------------------------
// NOTE (R2): the template-ladder suite is async, and this package is CommonJS
// (no `"type": "module"` in package.json), so tsx transforms this file to CJS
// where top-level await is a hard build error — not a runtime one, which means
// it fails the gate before a single case runs. Hence the explicit `.then`
// rather than `await` at module scope. Caught by running `npm run eval`; a
// review would not have shown it.
function report(): void {

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
}

runEmissionValidatorSuite();
runCategoryClassifierSuite();
runCompositionSuite();
runRedFlagCompositionSuite().then(report, (err: unknown) => {
  console.error('\nEVAL GATE FAILED — the red-flag composition suite threw before it could report:', err);
  process.exit(1);
});
