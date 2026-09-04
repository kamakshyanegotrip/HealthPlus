/**
 * HealthPlus — §3 emission validators (HP-OIR-002/003 Build Queue item 2,
 * "B6": "§3 emission validators + clause-named tests").
 *
 * Charter §3.0.3: "Enforcement is structural, not persuasive. Every class
 * MUST be backed by (a) a typed field that is nullable and (b) a
 * response-time validator that blocks emission of a value in that field
 * with no linked source ID. Prompt instructions alone are insufficient and
 * MUST NOT be relied upon as the sole control."
 *
 * This module is that response-time validator layer. It is deliberately
 * generic over which surface calls it — Annex A.8 lists these gates as
 * "application-layer gates that cannot be [database] constraints" and they
 * apply identically whether the candidate content came from the extraction
 * pipeline (Part A, `extractClaimsFromProviderSubmission.ts`) or a live
 * chat/generation surface (Part B, not yet built). Both should import from
 * here — one source of truth, the same pattern `safety/systemPromptFragments.ts`
 * already establishes for the Phase 3.1 prompt fragment.
 *
 * Each function below is named for, and enforces, exactly one Charter
 * clause, per Annex A.8's naming convention
 * (`test_hp_esc_<section>_<clause>_<description>`). `runEmissionGate`
 * composes all of them into the single response-time checkpoint a caller
 * actually invokes.
 *
 * These are deliberately pure, synchronous, and side-effect-free: no DB
 * calls, no model calls. They operate only on data the caller has already
 * resolved (claims, their bound sources, and the response envelope), which
 * is what makes them independently unit-testable per Annex A.8 without a
 * live database or Anthropic API key — matching this repo's existing
 * testing convention (see `jobs/extractClaimsFromProviderSubmission.test.ts`).
 */

import type { ClaimKind } from '../lib/claimKindPolicy';
import { SELF_REPORT_MARKER, TIER_4_CLINICAL_CLAIM_CAP } from '../lib/claimKindPolicy';

// ---------------------------------------------------------------------------
// Shared types
// ---------------------------------------------------------------------------

export type SourceTier = 'TIER_1' | 'TIER_2' | 'TIER_3' | 'TIER_4' | 'TIER_5';

export type RedFlagSeverity = 'NORMAL' | 'MONITOR' | 'WARNING' | 'URGENT' | 'CRITICAL' | 'EMERGENCY';

const SEVERITY_ORDER: Record<RedFlagSeverity, number> = {
  NORMAL: 0,
  MONITOR: 1,
  WARNING: 2,
  URGENT: 3,
  CRITICAL: 4,
  EMERGENCY: 5,
};

/** A source as bound to a claim, resolved by the caller from persisted
 *  `evidence_source` / `claim_source` rows — never invented by this module. */
export interface EmissionSource {
  id: string;
  tier: SourceTier;
  /** true when the source document is itself *about* the named provider
   *  entity the claim is attributed to (e.g. the hospital's own submission,
   *  or a registry entry naming that hospital) — as opposed to a generic
   *  literature/population source that happens to be cited alongside a
   *  provider-specific claim. Required to enforce §3.4.2. */
  isProviderSpecific: boolean;
}

export interface ClaimForEmission {
  id: string;
  kind: ClaimKind;
  statement: string;
  population: string | null;
  /** ISO date. Present only for kinds that track a hard expiry (§1.7.1),
   *  e.g. COST. null means "no expiry tracked for this kind", not "never
   *  expires" — callers must not treat null as evergreen for a kind that
   *  §1.7.1 assigns a hard_expiry_days to. */
  expiresAt: string | null;
  confidence: number;
  /** When the claim attributes a fact to a specific named provider entity
   *  (hospital, clinic, clinician) rather than describing something at
   *  population level. Required for §3.4.2. */
  attributedToNamedProvider: boolean;
  sources: EmissionSource[];
}

/** The full candidate response envelope, as it exists immediately before
 *  being shown to a user — after generation, before emission. */
export interface CandidateResponse {
  claims: ClaimForEmission[];
  severity: RedFlagSeverity;
  /** true if the response includes any provider recommendation, price,
   *  booking flow, or promotional content — the classes §4.0.6 requires
   *  suppressed at severity >= WARNING. */
  includesCommercialContent: boolean;
  /** The final rendered user-facing text, scanned for prohibited language
   *  classes (§3.10.3) that cannot be expressed as a structural field check. */
  outputText: string;
  /** Whether the red-flag scanner completed successfully for this turn.
   *  'ERROR' and 'MISSING' both represent scanner failure — §4.0.9 requires
   *  both to fail toward the highest severity, not toward silent pass-through. */
  severityScanStatus: 'OK' | 'ERROR' | 'MISSING';
}

export interface Violation {
  /** Charter clause this violation enforces, e.g. "HP-ESC 3.3.8". */
  clause: string;
  claimId?: string;
  message: string;
}

export interface EmissionGateResult {
  blocked: boolean;
  violations: Violation[];
}

function isAtLeast(severity: RedFlagSeverity, floor: RedFlagSeverity): boolean {
  return SEVERITY_ORDER[severity] >= SEVERITY_ORDER[floor];
}

// ---------------------------------------------------------------------------
// §1.5.3 — tier × claim_kind matrix
// ---------------------------------------------------------------------------

/** §1.5.3: "A Tier 5 source MUST NOT be used as the basis for any statement
 *  about: clinical efficacy or safety; dosage; test interpretation;
 *  diagnosis; treatment eligibility; contraindications; drug interactions;
 *  outcome or complication rates; regulatory or legal status; or price.
 *  Enforced as a hard pipeline gate keyed on `claim_kind`, not as model
 *  guidance." This is the Annex A.8 worked example verbatim
 *  (`test_hp_esc_1_5_3_tier5_blocked_for_efficacy_claims`), generalised to
 *  every claim_kind §1.5.3 names.
 */
const TIER_5_PROHIBITED_KINDS = new Set<ClaimKind>([
  'CLINICAL_EFFICACY',
  'TEST_INTERPRETATION',
  'REFERENCE_RANGE',
  'ELIGIBILITY',
  'PROVIDER_OUTCOME',
  'LEGAL_REGULATORY',
  'COST',
]);

export function validateHpEsc_1_5_3_TierClaimKindMatrix(claim: ClaimForEmission): Violation[] {
  if (!TIER_5_PROHIBITED_KINDS.has(claim.kind)) return [];
  const tier5Sources = claim.sources.filter((s) => s.tier === 'TIER_5');
  if (tier5Sources.length === 0) return [];
  return [
    {
      clause: 'HP-ESC 1.5.3',
      claimId: claim.id,
      message: `claim kind ${claim.kind} cites a TIER_5 source, which §1.5.3 prohibits as a basis for this claim class`,
    },
  ];
}

// ---------------------------------------------------------------------------
// §3.0.1 / §3.0.3 — no claim without a resolved source
// ---------------------------------------------------------------------------

/** §3.0.1: "state that it does not have the information ... and stop." /
 *  §3.0.3: "a response-time validator that blocks emission of a value in
 *  that field with no linked source ID." This is the application-layer
 *  mirror of the `claim_requires_source` DB constraint trigger (Annex A.2)
 *  — it exists so the gate blocks *before* an insert is attempted, not only
 *  as a last-resort DB-level backstop.
 */
export function validateHpEsc_3_0_1_NoSourcelessEmission(claim: ClaimForEmission): Violation[] {
  if (claim.sources.length > 0) return [];
  return [
    {
      clause: 'HP-ESC 3.0.1',
      claimId: claim.id,
      message: 'claim has no resolved evidence source and must not be emitted; abstain and log a data_quality_flag instead',
    },
  ];
}

// ---------------------------------------------------------------------------
// §3.3.8 — expired cost is unavailable, not approximate
// ---------------------------------------------------------------------------

/** §3.3.8: "Prices past the §1.7.1 hard expiry are unavailable, not
 *  approximate. This overrides `Arch.docx` §38's worked example, in which a
 *  2025 hospital price would still surface as Medium confidence." The
 *  caller passes `now` explicitly so this stays a pure function under test.
 */
export function validateHpEsc_3_3_8_CostPastHardExpiryUnavailable(
  claim: ClaimForEmission,
  now: Date,
): Violation[] {
  if (claim.kind !== 'COST') return [];
  if (!claim.expiresAt) {
    // §1.9.7-adjacent: a COST claim is required by the `cost_expiry` DB
    // constraint to carry an expiry. A null expiry here is itself the
    // violation — never treat "no expiry recorded" as "never expires".
    return [
      {
        clause: 'HP-ESC 3.3.8',
        claimId: claim.id,
        message: 'COST claim has no recorded expiry; a cost with no tracked expiry must not be emitted',
      },
    ];
  }
  if (new Date(claim.expiresAt).getTime() >= now.getTime()) return [];
  return [
    {
      clause: 'HP-ESC 3.3.8',
      claimId: claim.id,
      message: `COST claim expired at ${claim.expiresAt}; an expired price is unavailable, not an approximation`,
    },
  ];
}

// ---------------------------------------------------------------------------
// §3.4.2 — no attributing a population statistic to a named provider
// ---------------------------------------------------------------------------

/** §3.4.2: "MUST NOT convert a general, literature-derived outcome rate
 *  into a facility-specific one, or vice versa. Attributing a published
 *  population figure to a named hospital is fabrication." A claim attributed
 *  to a named provider must be backed by at least one source that is
 *  itself provider-specific — a purely literature/population source cannot
 *  carry it alone, no matter how high that source's tier is.
 */
export function validateHpEsc_3_4_2_NoProviderSpecificAttributionFromGenericSource(
  claim: ClaimForEmission,
): Violation[] {
  if (!claim.attributedToNamedProvider) return [];
  if (!(claim.kind === 'PROVIDER_OUTCOME' || claim.kind === 'PROVIDER_CREDENTIAL')) return [];
  const hasProviderSpecificSource = claim.sources.some((s) => s.isProviderSpecific);
  if (hasProviderSpecificSource) return [];
  return [
    {
      clause: 'HP-ESC 3.4.2',
      claimId: claim.id,
      message: 'claim attributes an outcome/credential to a named provider but every bound source is generic/literature-level, not about that provider',
    },
  ];
}

// ---------------------------------------------------------------------------
// §3.5.2 / §1.9.7 — reference range requires a population
// ---------------------------------------------------------------------------

/** §3.5.2: "MUST NOT present a reference range without naming the issuing
 *  source, the units, and the population it applies to ... a context-free
 *  range is unsafe even when numerically common." Mirrors the DB
 *  `pop_required` CHECK (Annex A.2) at the application layer, ahead of insert. */
export function validateHpEsc_3_5_2_ReferenceRangeRequiresPopulation(claim: ClaimForEmission): Violation[] {
  if (claim.kind !== 'REFERENCE_RANGE') return [];
  if (claim.population) return [];
  return [
    {
      clause: 'HP-ESC 3.5.2',
      claimId: claim.id,
      message: 'REFERENCE_RANGE claim has no population and is unsafe to emit even if the value itself is correct',
    },
  ];
}

// ---------------------------------------------------------------------------
// §1.4.4 — Tier 4 clinical/outcome claims: hard cap + mandatory marker
// ---------------------------------------------------------------------------

/** §1.4.4: "Any Tier 4 assertion of clinical outcome, success rate,
 *  complication rate, survival, patient volume, comparative superiority, or
 *  'world-class/best/leading' positioning is capped at confidence 0.40 and
 *  MUST NOT be presented as fact. It MUST be attributed in the user-facing
 *  text with an explicit self-report marker." A claim qualifies here when
 *  PROVIDER_OUTCOME (or an accreditation-asserting PROVIDER_CREDENTIAL) is
 *  supported *only* by Tier 4 sources — once a Tier 1-3 source also backs
 *  it, §1.4.4's Tier-4-specific cap no longer solely governs it.
 */
export function validateHpEsc_1_4_4_Tier4ClinicalCapAndMarker(claim: ClaimForEmission): Violation[] {
  if (claim.kind !== 'PROVIDER_OUTCOME') return [];
  if (claim.sources.length === 0) return []; // §3.0.1 already covers the sourceless case
  const solelyTier4 = claim.sources.every((s) => s.tier === 'TIER_4');
  if (!solelyTier4) return [];

  const violations: Violation[] = [];
  if (claim.confidence > TIER_4_CLINICAL_CLAIM_CAP) {
    violations.push({
      clause: 'HP-ESC 1.4.4',
      claimId: claim.id,
      message: `Tier-4-only PROVIDER_OUTCOME claim has confidence ${claim.confidence}, above the ${TIER_4_CLINICAL_CLAIM_CAP} hard cap`,
    });
  }
  if (!claim.statement.includes(SELF_REPORT_MARKER)) {
    violations.push({
      clause: 'HP-ESC 1.4.4',
      claimId: claim.id,
      message: 'Tier-4-only PROVIDER_OUTCOME claim is missing the mandatory self-report marker string',
    });
  }
  return violations;
}

// ---------------------------------------------------------------------------
// §3.10.3 — no reassurance language
// ---------------------------------------------------------------------------

/** §3.10.3: "MUST NOT use reassurance language ('nothing to worry about',
 *  'that's normal', 'you'll be fine', 'this is a routine procedure with no
 *  risk') in any category. Reassurance about an individual's situation is a
 *  clinical act." A deterministic keyword scan on the final rendered text —
 *  the class of check §3.0.3 says prompt instructions cannot be trusted to
 *  enforce alone. Not exhaustive; extend the list under §6.3 change control,
 *  same as the tier defaults (Annex A.7).
 */
const REASSURANCE_PHRASES = [
  'nothing to worry about',
  "that's normal",
  'that is normal',
  "you'll be fine",
  'you will be fine',
  'routine procedure with no risk',
  'no need to worry',
  "it's nothing serious",
];

export function validateHpEsc_3_10_3_NoReassuranceLanguage(response: Pick<CandidateResponse, 'outputText'>): Violation[] {
  const haystack = response.outputText.toLowerCase();
  const hit = REASSURANCE_PHRASES.find((phrase) => haystack.includes(phrase));
  if (!hit) return [];
  return [
    {
      clause: 'HP-ESC 3.10.3',
      message: `output text contains reassurance language ("${hit}"), which is a clinical act and prohibited in every response category`,
    },
  ];
}

// ---------------------------------------------------------------------------
// §4.0.6 — commercial content suppressed at severity >= WARNING
// ---------------------------------------------------------------------------

/** §4.0.6: "At severity >= WARNING, the system MUST NOT continue with
 *  commercial content — provider recommendations, package pricing, booking
 *  flows, upsells — in the same response. Safety content is rendered
 *  alone." */
export function validateHpEsc_4_0_6_NoCommercialContentAtElevatedSeverity(
  response: Pick<CandidateResponse, 'severity' | 'includesCommercialContent'>,
): Violation[] {
  if (!isAtLeast(response.severity, 'WARNING')) return [];
  if (!response.includesCommercialContent) return [];
  return [
    {
      clause: 'HP-ESC 4.0.6',
      message: `response carries commercial content at severity ${response.severity}; safety content must render alone at WARNING and above`,
    },
  ];
}

// ---------------------------------------------------------------------------
// §4.0.9 — fail-safe on scanner error
// ---------------------------------------------------------------------------

/** §4.0.9: "Scanner error, classifier failure, or a missing template
 *  escalates to the highest applicable severity and its template. Failing
 *  open to generative output is prohibited." This validator does not (and
 *  cannot, being pure) fix the severity itself — it blocks emission of any
 *  response whose severity scan did not complete cleanly, forcing the
 *  caller to re-run the response through the highest-severity/EMERGENCY
 *  template path rather than falling through to whatever category/content
 *  it had already generated.
 */
export function validateHpEsc_4_0_9_FailSafeOnScannerError(
  response: Pick<CandidateResponse, 'severityScanStatus'>,
): Violation[] {
  if (response.severityScanStatus === 'OK') return [];
  return [
    {
      clause: 'HP-ESC 4.0.9',
      message: `red-flag scan did not complete (status: ${response.severityScanStatus}); must fail to the highest applicable severity, never fail open to generative output`,
    },
  ];
}

// ---------------------------------------------------------------------------
// Aggregate gate
// ---------------------------------------------------------------------------

/** The single response-time checkpoint a generation surface actually calls.
 *  Runs every validator above against every claim (and the response
 *  envelope, for the response-level checks) and blocks emission if any
 *  violation is found. This is the "response-time validator" §3.0.3 requires
 *  to exist alongside the nullable typed fields — prompt instructions
 *  (Annex B) are the first line of defence, not the only one.
 */
export function runEmissionGate(response: CandidateResponse, now: Date = new Date()): EmissionGateResult {
  const violations: Violation[] = [];

  for (const claim of response.claims) {
    violations.push(...validateHpEsc_1_5_3_TierClaimKindMatrix(claim));
    violations.push(...validateHpEsc_3_0_1_NoSourcelessEmission(claim));
    violations.push(...validateHpEsc_3_3_8_CostPastHardExpiryUnavailable(claim, now));
    violations.push(...validateHpEsc_3_4_2_NoProviderSpecificAttributionFromGenericSource(claim));
    violations.push(...validateHpEsc_3_5_2_ReferenceRangeRequiresPopulation(claim));
    violations.push(...validateHpEsc_1_4_4_Tier4ClinicalCapAndMarker(claim));
  }

  violations.push(...validateHpEsc_3_10_3_NoReassuranceLanguage(response));
  violations.push(...validateHpEsc_4_0_6_NoCommercialContentAtElevatedSeverity(response));
  violations.push(...validateHpEsc_4_0_9_FailSafeOnScannerError(response));

  return { blocked: violations.length > 0, violations };
}
