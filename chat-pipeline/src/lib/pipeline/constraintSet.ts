import type { KnowledgeDomain, PatientProfile, RetrievedClaim } from '../types';

/**
 * PATIENT CONSTRAINT RESOLUTION — the precedence layer between the patient's
 * stated profile (blueprint §36) and the population-level evidence set.
 *
 * ===========================================================================
 * THE ONE DISTINCTION THIS WHOLE FILE TURNS ON
 *
 * A constraint here decides WHICH PUBLISHED CONTENT IS SHOWN. It never decides
 * WHAT IS TRUE OF THIS PATIENT.
 *
 * Those sound close and they are not. "Published vegetarian dietary patterns for
 * type 2 diabetes say X [citation]" is Category B: it is population-level
 * content, cited, selected for relevance because the patient said they are
 * vegetarian. "You should eat X" is Category C — §2.4.1a lists the blueprint's
 * §11 Personalized Diet Engine as exactly that, prohibited under §2.3.1.
 *
 * The Charter licenses the first explicitly. §2.5's category table gives
 * Decision Support the row "Individualised to user's clinical data: Partially
 * (preferences, logistics, budget)", and §2.1.7 says the blueprint's engines are
 * "not cancelled; they are re-scoped" to population-level reference content.
 * Selection by stated preference is the re-scoped form. Prescription is not.
 *
 * So every constraint below has an `effect` that is one of SUPPRESS, REORDER or
 * BOUND — three verbs that all act on the CLAIM SET. There is deliberately no
 * verb that acts on the patient. If a future constraint needs one, it is a
 * Category C capability and belongs behind the §2.3.2 gate, not here.
 *
 * ===========================================================================
 * WHY SUPPRESSION IS SURFACED RATHER THAN SILENT
 *
 * §1.8.2 prohibits "silent suppression of a lower-tier source that contradicts
 * the published answer". This is relevance filtering rather than contradiction
 * suppression, so that clause does not strictly bite — but the failure mode it
 * guards against is the same one, and §2.2.3d independently requires the
 * response to "explicitly name what is unknown, unverified, or stale".
 *
 * `applyConstraints` therefore returns the suppressed claims WITH the constraint
 * that suppressed each, and the composer is told to say what it filtered and
 * why. A patient who reads "the guidance below is the vegetarian pattern from
 * [source], because you've told us you're vegetarian" can correct us. A patient
 * who reads guidance with no such sentence cannot tell whether we knew.
 *
 * ===========================================================================
 * ONLY STATED ATTRIBUTES BECOME CONSTRAINTS (§3.8.2)
 *
 * §3.8.2 forbids carrying an unconfirmed inference forward as an established
 * fact. `lookupPatientProfile` already calls fetch_attribute_envelope with
 * include_inferred = false and the function RAISES for any purpose but
 * CONFIRMATION_UI, so everything on the profile that reaches here is `stated` by
 * construction. `statedConditions` still carries its provenance per-item and
 * `resolveConstraints` still checks it — belt and braces, because the day
 * CONFIRMATION_UI starts promoting inferred attributes is the day a silent
 * default here becomes a §3.8.2 violation nobody notices.
 */

/**
 * Precedence, highest first. The ladder is the answer to the request's
 * "dietary restrictions override generic nutrition advice; exercise
 * contraindications override generic activity advice; budget and mobility
 * constrain which countries/hospitals are even mentioned" — expressed as ranks
 * over the claim set rather than as instructions the composer is trusted to
 * remember in the right order.
 */
export type ConstraintRank =
  /** §4.0.6 — at severity >= WARNING no commercial content may appear at all. */
  | 'SAFETY_SUPPRESSION'
  /** A stated dietary/cultural/religious exclusion. Outranks generic nutrition content. */
  | 'DIETARY_EXCLUSION'
  /** Stated mobility limitation. Raises published activity PRECAUTIONS above recommendations. */
  | 'ACTIVITY_PRECAUTION_PRIORITY'
  /** Stated budget ceiling. Bounds which cost/provider content may be mentioned. */
  | 'BUDGET_CEILING'
  /** Stated mobility/travel limitation. Bounds which logistics content is relevant. */
  | 'MOBILITY_BOUND'
  /** Everything else the patient stated: language, city, timing. */
  | 'PREFERENCE';

const RANK_ORDER: Record<ConstraintRank, number> = {
  SAFETY_SUPPRESSION: 0,
  DIETARY_EXCLUSION: 1,
  ACTIVITY_PRECAUTION_PRIORITY: 2,
  BUDGET_CEILING: 3,
  MOBILITY_BOUND: 4,
  PREFERENCE: 5,
};

export type ConstraintEffect =
  /** Remove the claim from the set handed to the composer. */
  | 'SUPPRESS'
  /** Keep the claim but raise it above its peers in the same domain. */
  | 'REORDER'
  /** Keep the claim but mark it as outside a stated bound, to be named as such. */
  | 'BOUND';

export interface PatientConstraint {
  key: string;
  rank: ConstraintRank;
  effect: ConstraintEffect;
  /** The domains this constraint acts on. Empty means all. */
  appliesTo: readonly KnowledgeDomain[];
  /** Human-readable, and shown to the patient so they can correct us. */
  statement: string;
  /** Which profile field this came from, for the audit trail. */
  basis: string;
  /** Free-text tokens a claim must not contain, for SUPPRESS constraints. */
  excludesTokens?: readonly string[];
  /** Upper bound in minor currency units, for BUDGET_CEILING. */
  ceilingAmount?: number;
  ceilingCurrency?: string;
}

export interface ConstraintSet {
  constraints: PatientConstraint[];
  /**
   * True when the profile carried nothing usable. The composer is told to say
   * so rather than to proceed as if the patient had stated no restrictions —
   * "we hold no dietary information for you" and "you have no dietary
   * restrictions" are different sentences and §3.8.1 forbids the second.
   */
  empty: boolean;
}

/**
 * The keys this reads out of the decrypted PREFERENCE payload. Section 36 of the
 * blueprint groups the profile as demographics / medical / lifestyle / travel /
 * preferences; these are the travel-and-preferences fields that are legitimately
 * Category B inputs.
 *
 * DELIBERATELY NOT READ: anything under the medical group. `statedConditions` is
 * on the profile and this module does not touch it, because a constraint derived
 * from a diagnosis is a determination about the patient's clinical situation —
 * the exact thing §2.3.1 defines as Category C. The dietary constraint below
 * comes from the patient saying "I am vegetarian", never from the platform
 * reasoning "this patient has diabetes, therefore restrict carbohydrate".
 *
 * Unknown keys are ignored, never guessed at. A profile written by a future
 * intake form with different key names produces `empty: true` and a composer
 * that says it holds no preferences — which is wrong-but-honest, and is the
 * direction §3.0.3 resolves an unestablished fact.
 */
interface PreferenceShape {
  dietary_pattern?: unknown; // 'vegetarian' | 'vegan' | 'halal' | 'kosher' | 'jain' | 'none'
  food_exclusions?: unknown; // string[]
  mobility?: unknown; // 'unrestricted' | 'limited' | 'wheelchair' | 'bedbound'
  budget_ceiling_amount?: unknown; // number, minor units
  budget_ceiling_currency?: unknown; // ISO 4217
  preferred_language?: unknown;
  preferred_destination_country?: unknown;
}

/**
 * Token sets a dietary pattern excludes. These are SELECTION tokens matched
 * against retrieved claim text — not nutritional advice, and not exhaustive.
 * They exist so that a Tier 1/2 nutrition claim whose worked examples are built
 * on excluded foods is not handed to the composer as this patient's relevant
 * guidance.
 *
 * A miss here costs relevance, never safety: an excluded claim that slips
 * through is still cited, still population-level, and still framed as published
 * guidance rather than as instruction. That asymmetry is why a crude token list
 * is an acceptable v1 and a crude list applied to a PRESCRIPTION would not be.
 */
const DIETARY_EXCLUSION_TOKENS: Record<string, readonly string[]> = {
  vegetarian: ['meat', 'poultry', 'chicken', 'beef', 'pork', 'mutton', 'fish', 'seafood', 'gelatin'],
  vegan: ['meat', 'poultry', 'chicken', 'beef', 'pork', 'mutton', 'fish', 'seafood', 'gelatin', 'dairy', 'milk', 'egg', 'honey', 'whey'],
  halal: ['pork', 'bacon', 'ham', 'lard', 'alcohol', 'gelatin'],
  kosher: ['pork', 'bacon', 'ham', 'lard', 'shellfish', 'prawn', 'shrimp'],
  jain: ['meat', 'poultry', 'chicken', 'fish', 'egg', 'onion', 'garlic', 'potato', 'root vegetable'],
};

const LIMITED_MOBILITY = new Set(['limited', 'wheelchair', 'bedbound']);

function asString(v: unknown): string | null {
  return typeof v === 'string' && v.trim().length > 0 ? v.trim().toLowerCase() : null;
}

function asStringArray(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string' && x.trim().length > 0).map((x) => x.trim().toLowerCase()) : [];
}

/**
 * Build the constraint ladder from the profile.
 *
 * `redFlagSeverityAtLeastWarning` is passed in rather than read, because §4.0.6
 * is a property of THIS TURN's scan and not of the patient. Passing it makes the
 * commercial-suppression constraint appear in the same ladder as everything else,
 * so the composer sees one ordered list rather than a list plus a separate rule
 * it has to remember outranks the list.
 */
export function resolveConstraints(
  profile: PatientProfile | null,
  opts: { redFlagSeverityAtLeastWarning: boolean },
): ConstraintSet {
  const constraints: PatientConstraint[] = [];

  if (opts.redFlagSeverityAtLeastWarning) {
    constraints.push({
      key: 'safety.commercial_suppressed',
      rank: 'SAFETY_SUPPRESSION',
      effect: 'SUPPRESS',
      appliesTo: ['COST', 'HOSPITAL'],
      statement: 'A safety flag is active on this conversation, so provider, pricing and booking content is withheld from this response.',
      basis: 'red-flag scan, this turn (§4.0.6)',
    });
  }

  const prefs = (profile?.preferences ?? null) as PreferenceShape | null;

  if (prefs) {
    const pattern = asString(prefs.dietary_pattern);
    const explicitExclusions = asStringArray(prefs.food_exclusions);
    const patternTokens = pattern && pattern !== 'none' ? (DIETARY_EXCLUSION_TOKENS[pattern] ?? []) : [];
    const allTokens = [...patternTokens, ...explicitExclusions];

    if (allTokens.length > 0) {
      constraints.push({
        key: 'diet.exclusion',
        rank: 'DIETARY_EXCLUSION',
        effect: 'SUPPRESS',
        appliesTo: ['NUTRITION', 'LIFESTYLE'],
        statement:
          pattern && pattern !== 'none'
            ? `You have told us you follow a ${pattern} diet, so the nutrition guidance below is drawn from published ${pattern} patterns rather than general ones.`
            : `You have told us you avoid: ${explicitExclusions.join(', ')}. The nutrition guidance below is selected accordingly.`,
        basis: 'patient_attribute PREFERENCE.dietary_pattern / food_exclusions (stated)',
        excludesTokens: allTokens,
      });
    }

    const mobility = asString(prefs.mobility);
    if (mobility && LIMITED_MOBILITY.has(mobility)) {
      // TWO constraints from one field, and they are genuinely different acts.
      constraints.push({
        key: 'exercise.precaution_priority',
        rank: 'ACTIVITY_PRECAUTION_PRIORITY',
        effect: 'REORDER',
        appliesTo: ['EXERCISE'],
        statement:
          `You have told us your mobility is ${mobility}. Published activity PRECAUTIONS are shown before general activity recommendations for that reason — ` +
          'which of them apply to you is a question for the clinician assessing you, not something this platform determines.',
        basis: 'patient_attribute PREFERENCE.mobility (stated)',
      });
      constraints.push({
        key: 'travel.mobility_bound',
        rank: 'MOBILITY_BOUND',
        effect: 'BOUND',
        appliesTo: ['HOSPITAL', 'ENVIRONMENT'],
        statement: `Travel, transfer and accommodation content is bounded by the ${mobility} mobility you stated.`,
        basis: 'patient_attribute PREFERENCE.mobility (stated)',
      });
    }

    const amount = typeof prefs.budget_ceiling_amount === 'number' && Number.isFinite(prefs.budget_ceiling_amount) ? prefs.budget_ceiling_amount : null;
    const currency = asString(prefs.budget_ceiling_currency);
    if (amount !== null && currency) {
      constraints.push({
        key: 'cost.budget_ceiling',
        rank: 'BUDGET_CEILING',
        effect: 'BOUND',
        appliesTo: ['COST', 'HOSPITAL'],
        statement:
          `You stated a budget ceiling of ${amount} ${currency.toUpperCase()}. Options whose indicative cost sits above it are named as being above it rather than ` +
          'quietly dropped, because an indicative estimate is not a price (§3.3.3) and a bound applied silently would read as one.',
        basis: 'patient_attribute PREFERENCE.budget_ceiling_* (stated)',
        ceilingAmount: amount,
        ceilingCurrency: currency.toUpperCase(),
      });
    }

    const language = asString(prefs.preferred_language);
    const destination = asString(prefs.preferred_destination_country);
    if (language || destination) {
      constraints.push({
        key: 'preference.general',
        rank: 'PREFERENCE',
        effect: 'REORDER',
        appliesTo: [],
        statement: [
          language ? `Preferred language: ${language}.` : null,
          destination ? `Preferred destination: ${destination}.` : null,
        ]
          .filter(Boolean)
          .join(' '),
        basis: 'patient_attribute PREFERENCE (stated)',
      });
    }
  }

  constraints.sort((a, b) => RANK_ORDER[a.rank] - RANK_ORDER[b.rank]);
  return { constraints, empty: constraints.length === 0 };
}

export interface ConstraintApplication {
  /** Claims the composer may use, in constraint-adjusted order. */
  admitted: RetrievedClaim[];
  /** Claims withheld, each with the constraint that withheld it. §2.2.3d. */
  suppressed: Array<{ claim: RetrievedClaim; byConstraint: string; statement: string }>;
  /** Claims kept but flagged as sitting outside a stated bound. */
  bounded: Array<{ claim: RetrievedClaim; byConstraint: string; statement: string }>;
}

function appliesToDomain(c: PatientConstraint, domain: KnowledgeDomain): boolean {
  return c.appliesTo.length === 0 || c.appliesTo.includes(domain);
}

/**
 * Apply the ladder to a retrieved claim set.
 *
 * ORDER MATTERS AND IS THE POINT. Constraints are applied in rank order, and the
 * first SUPPRESS to match wins — so a safety suppression cannot be undone by a
 * lower-ranked preference, and a dietary exclusion is decided before any
 * reordering runs. This is the "overrides" in the request, made mechanical.
 *
 * BOUND does not remove anything. A hospital whose indicative cost exceeds the
 * stated ceiling is kept and marked, because §3.3.3 makes every cost figure an
 * indicative estimate rather than a price — silently dropping an option because
 * an ESTIMATE cleared a threshold would treat the estimate as a quotation, which
 * is the thing §3.3 exists to prevent. The composer names it as above the stated
 * budget and lets the patient decide.
 */
export function applyConstraints(set: ConstraintSet, claims: readonly RetrievedClaim[]): ConstraintApplication {
  const admitted: RetrievedClaim[] = [];
  const suppressed: ConstraintApplication['suppressed'] = [];
  const bounded: ConstraintApplication['bounded'] = [];
  const reorderPriority = new Map<string, number>();

  for (const claim of claims) {
    let withheld: PatientConstraint | null = null;

    for (const c of set.constraints) {
      if (!appliesToDomain(c, claim.domain)) continue;

      if (c.effect === 'SUPPRESS') {
        const tokens = c.excludesTokens;
        // A constraint with no token list suppresses its whole domain
        // (SAFETY_SUPPRESSION). One with tokens suppresses only claims whose
        // text actually mentions an excluded item.
        const hit = !tokens || tokens.some((t) => claim.text.toLowerCase().includes(t));
        if (hit) {
          withheld = c;
          break;
        }
      } else if (c.effect === 'BOUND') {
        if (c.ceilingAmount !== undefined) {
          const amount = extractCostAmount(claim, c.ceilingCurrency);
          if (amount !== null && amount > c.ceilingAmount) {
            bounded.push({ claim, byConstraint: c.key, statement: c.statement });
          }
        } else {
          bounded.push({ claim, byConstraint: c.key, statement: c.statement });
        }
      } else if (c.effect === 'REORDER') {
        const current = reorderPriority.get(claim.claimId);
        const rank = RANK_ORDER[c.rank];
        // `activity_precaution` is what ACTIVITY_PRECAUTION_PRIORITY promotes,
        // not the whole EXERCISE domain — promoting a recommendation alongside
        // its precaution would leave the ordering exactly where it started.
        const promotes = c.key !== 'exercise.precaution_priority' || /precaution|caution|avoid|risk|contraindicat/i.test(claim.text);
        if (promotes && (current === undefined || rank < current)) reorderPriority.set(claim.claimId, rank);
      }
    }

    if (withheld) {
      suppressed.push({ claim, byConstraint: withheld.key, statement: withheld.statement });
    } else {
      admitted.push(claim);
    }
  }

  // Stable sort: promoted claims first in rank order, everything else in
  // retrieval order. `sort` is stable in every runtime this targets (V8, ES2019+).
  const UNPROMOTED = Number.MAX_SAFE_INTEGER;
  admitted.sort((a, b) => (reorderPriority.get(a.claimId) ?? UNPROMOTED) - (reorderPriority.get(b.claimId) ?? UNPROMOTED));

  return { admitted, suppressed, bounded };
}

/**
 * Pull a comparable amount out of a COST claim.
 *
 * Deliberately conservative: it reads the claim's own text for a figure in the
 * ceiling's currency and returns null for anything it cannot read cleanly. A
 * null means the claim is NOT bounded — it is admitted unmarked — because
 * marking a claim "above your budget" on the strength of a number this function
 * guessed at would be §3.3.2 (estimating a price by analogy) wearing a filter's
 * clothes. Under-marking costs the patient a sentence; over-marking tells them
 * something false about a price.
 *
 * The real fix is structured cost on the claim record rather than a regex over
 * its text. `domain.hospital_cost` has the columns; `RetrievedClaim` does not
 * carry them through yet. Recorded as HP-JOB-011 open item 2 rather than
 * improvised here.
 */
function extractCostAmount(claim: RetrievedClaim, currency: string | undefined): number | null {
  if (claim.kind !== 'COST' || !currency) return null;
  const symbol = { USD: '\\$', INR: '₹', EUR: '€', GBP: '£' }[currency] ?? null;
  const pattern = symbol
    ? new RegExp(`(?:${symbol}|\\b${currency}\\b)\\s*([\\d,]+(?:\\.\\d+)?)`, 'i')
    : new RegExp(`\\b${currency}\\b\\s*([\\d,]+(?:\\.\\d+)?)`, 'i');
  const m = pattern.exec(claim.text);
  if (!m?.[1]) return null;
  const n = Number(m[1].replace(/,/g, ''));
  return Number.isFinite(n) ? n : null;
}
