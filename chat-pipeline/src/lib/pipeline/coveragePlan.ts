import type { KnowledgeDomain, RetrievedClaim } from '../types';

/**
 * COVERAGE PLAN — what the answer must address, what it may say about each
 * part, and which parts must reference each other.
 *
 * ===========================================================================
 * THE PROBLEM THIS EXISTS TO FIX
 *
 * Blueprint §42's worked example asks ten things at once: clinical readiness,
 * diet, exercise restrictions, hospital and city comparison, cost, visa, travel
 * fitness, accommodation, recovery period, follow-up. Four of those ten are
 * Category C — §2.4.1a names the blueprint's §11 diet engine, §15 exercise
 * contraindication engine and §25 travel-fitness engine explicitly, and
 * readiness is §3.2.1/§3.2.5 eligibility.
 *
 * Before this module, §2.0.2's monotonic-upward rule took the whole turn up
 * with them and `route.ts` returned CLINICAL_DECISION_REFUSAL — one static
 * paragraph, no hospitals, no costs, no visa, no recovery timeline. The six
 * dimensions the platform is fully permitted to answer were lost because they
 * arrived in the same message as four it is not.
 *
 * That is not what §2.3.6 asks for. §2.3.6 is explicit that the v1 path is to
 * "(a) state plainly that it cannot interpret the user's individual clinical
 * situation; (b) explain what kind of professional can; (c) OFFER THE ADJACENT
 * PERMITTED HELP — explaining in general terms what the test measures,
 * reproducing published criteria with citation, or preparing a question list
 * for the user's clinician". Clause (c) was not implemented. This module is
 * clause (c).
 *
 * ===========================================================================
 * WHY THIS DOES NOT BREAK §2.0.2, AND THE PRECEDENT IT FOLLOWS
 *
 * §2.0.2 says a response whose component qualifies for a higher category takes
 * "the higher category AND ITS SAFEGUARDS". The safeguards of Category C are
 * §2.3.4 and §2.3.5: a named clinician approving the CLINICAL DETERMINATION
 * before publication. The response this module plans CONTAINS NO CLINICAL
 * DETERMINATION. It says, of each Category C dimension, that the platform
 * cannot determine it, reproduces the published criteria with citation, and
 * hands the patient a question for the clinician who can. That is §2.3.6
 * output, not §2.3.1 output, and §2.3.6 is "a permanent, first-class path in
 * v1 — not a fallback".
 *
 * The precedent is already in this repository and predates this change:
 * route.ts's existing CLINICAL_DECISION branch writes its audit row with
 * `category: 'INFORMATIONAL'`, commented "the refusal message itself is
 * informational, not a clinical decision". Same reasoning, one step further —
 * a refusal that also carries permitted decision-support content publishes as
 * DECISION_SUPPORT and takes DECISION_SUPPORT's safeguards in full: §2.2.4's
 * long-form disclaimer, §2.2.3's options-not-recommendation and criteria
 * disclosure, and every §2.2.5b review trigger, none of which is relaxed here.
 *
 * WHAT IS NOT WIDENED, stated so a reviewer can check rather than trust:
 *   * Retrieval is ALWAYS called with the published category, never with
 *     CLINICAL_DECISION. `evidence.policy_for` therefore gates at
 *     DECISION_SUPPORT, which is strictly narrower than Category C would be.
 *   * No TEST_INTERPRETATION claim can reach the composer. Both walls in
 *     test/runPipeline.integration.test.ts's
 *     `test_2_0_2_post_retrieval_reconciliation_is_unreachable` still stand.
 *   * `c_category_c_disabled_v1` is untouched. Nothing here writes, or wants
 *     to write, a CLINICAL_DECISION audit row.
 *   * A query with NO answerable dimension still takes the old flat refusal.
 *     `planCoverage` returns `publishable: false` and route.ts short-circuits
 *     exactly as before.
 *
 * ===========================================================================
 * WEAVING IS A DATA STRUCTURE, NOT AN ADJECTIVE
 *
 * "One coherent answer, not a concatenation" is easy to ask a model for and
 * hard to check. So coherence here is `requiredCrossReferences`: named pairs of
 * dimensions the answer must actually connect, each with the reason they
 * connect. The visa duration has to cover the recovery period. The budget
 * ceiling spans hospital, cost and accommodation together. What the patient
 * asks their surgeon about readiness is the same question list that decides
 * whether the travel dates hold.
 *
 * These are assertable. `test/section42.composition.test.ts` fails a composed
 * answer that addresses all ten dimensions in ten disconnected paragraphs, and
 * that negative case is what makes the positive one mean anything.
 */

export type DimensionKey =
  | 'CLINICAL_READINESS'
  | 'DIET'
  | 'EXERCISE'
  | 'HOSPITAL_COMPARISON'
  | 'COST'
  | 'VISA'
  | 'TRAVEL_FITNESS'
  | 'ACCOMMODATION'
  | 'RECOVERY_PERIOD'
  | 'FOLLOW_UP';

export const ALL_DIMENSIONS: readonly DimensionKey[] = [
  'CLINICAL_READINESS',
  'DIET',
  'EXERCISE',
  'HOSPITAL_COMPARISON',
  'COST',
  'VISA',
  'TRAVEL_FITNESS',
  'ACCOMMODATION',
  'RECOVERY_PERIOD',
  'FOLLOW_UP',
];

/**
 * The individual determination each dimension would make if the platform were
 * permitted to make it, and the clause that says it is not. `null` means the
 * dimension carries no Category C component at all.
 *
 * Note that DIET and EXERCISE are NOT wholly deferred. §2.1.7 re-scopes the
 * blueprint's engines rather than cancelling them: published dietary patterns
 * and published activity precautions are Category A/B reference content and are
 * fully answerable. What is deferred is the prescription — "eat this", "do not
 * do that" — addressed to this patient. Splitting the dimension rather than
 * deferring it whole is the difference between a useful answer and a useless
 * one, and it is what the Charter actually says.
 */
interface DeferralSpec {
  clause: string;
  /** What the platform must say it cannot do, in the composer's own words. */
  cannot: string;
  /** §2.3.6(c) — the permitted adjacent help for this dimension. */
  adjacentHelp: string;
  /** §2.3.6(c) — a question the patient can put to their own clinician. */
  clinicianQuestion: string;
}

const DEFERRALS: Partial<Record<DimensionKey, DeferralSpec>> = {
  CLINICAL_READINESS: {
    clause: '§3.2.1, §3.2.5 (via §2.3.1)',
    cannot: 'say whether this patient is ready for, or a candidate for, this surgery',
    adjacentHelp:
      'reproduce the published pre-operative criteria the destination or the guideline body actually sets, with citation and the population they apply to, and state that whether the patient meets them is for the assessing surgeon and anaesthetist to determine',
    clinicianQuestion:
      'Ask your treating doctor: against the pre-operative criteria this hospital uses, where do I currently stand, and what would need to change before you would list me?',
  },
  DIET: {
    clause: '§2.4.1a (blueprint §11), §2.3.1',
    cannot: 'prescribe a diet for this patient or set targets for them',
    adjacentHelp:
      'reproduce published dietary pattern guidance for the condition, selected for the dietary restrictions the patient stated, with citation and population',
    clinicianQuestion:
      'Ask your treating doctor or a dietitian: which of these published patterns fits my situation, and what should I be aiming for before surgery?',
  },
  EXERCISE: {
    clause: '§2.4.1a (blueprint §15), §3.2.3',
    cannot: 'tell this patient which activities are contraindicated for them',
    adjacentHelp:
      'reproduce published activity precautions and their stated rationale, with citation, ordered so precautions appear before general recommendations where mobility is limited',
    clinicianQuestion:
      'Ask your treating doctor or physiotherapist: given my mobility, which of these published precautions apply to me, and what may I safely do before and after surgery?',
  },
  TRAVEL_FITNESS: {
    clause: '§3.2.3 (blueprint §25), §2.4.1a',
    cannot:
      'determine that this patient is or is not fit to fly, or whether they need medical escort, oxygen, or pre-flight clearance',
    adjacentHelp:
      'reproduce the published fitness-to-travel criteria of the relevant airline or guideline body with citation, and prompt the patient to obtain clearance',
    clinicianQuestion:
      'Ask your treating doctor: will you assess me against these published fitness-to-fly criteria and issue clearance if appropriate, and how close to the flight does that need to happen?',
  },
};

/**
 * The four dimensions that carry a Category C component. Exported so route.ts
 * can answer "is this query ASKING ONLY for things we cannot determine?" before
 * spending a profile read and a retrieval on it — a pure Category C question
 * ("what does my HbA1c of 9.4 mean?") takes the flat §2.3.6 refusal on exactly
 * the path it always did, with no added latency.
 */
export const DEFERRABLE_DIMENSIONS: ReadonlySet<DimensionKey> = new Set(Object.keys(DEFERRALS) as DimensionKey[]);

/**
 * Which retrieved-knowledge domains feed which dimension. A dimension with no
 * admitted claim in any of its domains is ANSWERABLE-but-unsourced, which
 * resolves to NO_EVIDENCE — §3.0.1's "state that it does not have the
 * information, name what kind of source would have it, and stop".
 */
const DIMENSION_DOMAINS: Record<DimensionKey, readonly KnowledgeDomain[]> = {
  CLINICAL_READINESS: ['GUIDELINE', 'MONITORING'],
  DIET: ['NUTRITION', 'LIFESTYLE'],
  EXERCISE: ['EXERCISE'],
  HOSPITAL_COMPARISON: ['HOSPITAL'],
  COST: ['COST'],
  VISA: ['VISA'],
  TRAVEL_FITNESS: ['GUIDELINE', 'ENVIRONMENT'],
  ACCOMMODATION: ['ENVIRONMENT', 'HOSPITAL'],
  RECOVERY_PERIOD: ['GUIDELINE'],
  FOLLOW_UP: ['GUIDELINE', 'HOSPITAL'],
};

/**
 * The coherence graph. Each edge is a connection the composed answer must
 * actually make, with the reason — the reason is in the prompt because an
 * instruction to "cross-reference" without one produces a sentence that names
 * both dimensions and connects nothing.
 */
export interface CrossReference {
  from: DimensionKey;
  to: DimensionKey;
  because: string;
}

export const CROSS_REFERENCES: readonly CrossReference[] = [
  {
    from: 'CLINICAL_READINESS',
    to: 'DIET',
    because: 'the published pre-operative criteria are stated in terms the dietary guidance is aimed at, so the two must be presented as one question, not two topics',
  },
  {
    from: 'CLINICAL_READINESS',
    to: 'RECOVERY_PERIOD',
    because: 'the readiness question the patient puts to their surgeon determines when surgery could happen, which sets every date downstream',
  },
  {
    from: 'EXERCISE',
    to: 'RECOVERY_PERIOD',
    because: 'published pre-operative activity precautions and the published post-operative rehabilitation course are the same programme at two points in time',
  },
  // NOT AN EDGE, and the reason is written here so nobody adds one: the budget
  // ceiling spans HOSPITAL_COMPARISON, COST and ACCOMMODATION together, but it
  // is a CONSTRAINT rather than a dimension. It lives in constraintSet.ts and
  // reaches the composer through the precedence ladder, which is what lets it
  // outrank a preference — something an edge in this graph cannot express.
  {
    from: 'COST',
    to: 'HOSPITAL_COMPARISON',
    because: 'an indicative cost is meaningless without the hospital it belongs to and the scope it includes, so the comparison and the figures are one table, not two lists',
  },
  {
    from: 'COST',
    to: 'ACCOMMODATION',
    because: 'the stated budget has to cover the stay as well as the procedure, so accommodation cannot be priced in a separate paragraph as though the ceiling applied twice',
  },
  {
    from: 'VISA',
    to: 'RECOVERY_PERIOD',
    because: 'the medical visa duration must cover the published recovery period before travel is bookable, and this is the single most common way a medical-travel plan fails',
  },
  {
    from: 'VISA',
    to: 'TRAVEL_FITNESS',
    because: 'clearance for the flight and permission to enter are two separate gates on the same journey and the patient needs both, in that order',
  },
  {
    from: 'TRAVEL_FITNESS',
    to: 'RECOVERY_PERIOD',
    because: 'the return flight sits inside the post-operative window, so fitness for the outbound leg is not the same question as fitness for the inbound one',
  },
  {
    from: 'FOLLOW_UP',
    to: 'HOSPITAL_COMPARISON',
    because: 'follow-up happens after the patient has gone home to another country, so how each hospital handles remote follow-up is a comparison criterion, not an afterthought',
  },
  {
    from: 'FOLLOW_UP',
    to: 'RECOVERY_PERIOD',
    because: 'the follow-up schedule is what the recovery period is measured against, and §4.5.1(a) makes a returned post-operative patient a raised-severity case if it lapses',
  },
  {
    from: 'ACCOMMODATION',
    to: 'RECOVERY_PERIOD',
    because: 'the length of stay is set by the published recovery course, not chosen independently of it',
  },
];

export type DimensionDisposition =
  /** Fully answerable from admitted claims. */
  | 'ANSWERABLE'
  /** Answerable in its population-level form; its individual determination is deferred. */
  | 'ANSWERABLE_WITH_DEFERRAL'
  /** Nothing but the individual determination was ever asked; wholly deferred. */
  | 'DEFERRED'
  /** In scope and permitted, but no admitted claim supports it. §3.0.1. */
  | 'NO_EVIDENCE';

export interface PlannedDimension {
  key: DimensionKey;
  disposition: DimensionDisposition;
  claims: RetrievedClaim[];
  deferral: DeferralSpec | null;
}

export interface CoveragePlan {
  dimensions: PlannedDimension[];
  crossReferences: CrossReference[];
  /**
   * False when nothing is answerable — every requested dimension is either
   * wholly deferred or unsourced. route.ts falls back to the flat §2.3.6
   * refusal in that case, unchanged from before this module existed.
   */
  publishable: boolean;
  /** Dimensions carrying a deferred component, for the audit record. */
  deferredDimensions: DimensionKey[];
}

/**
 * Which of the ten dimensions this message is actually asking about.
 *
 * Keyword matching, deliberately. The alternative — another model call to
 * decompose the query — adds a network hop on the latency path §6.5 measures,
 * and adds a model output that would then need its own validator. The cost of a
 * miss is bounded and asymmetric: a dimension wrongly INCLUDED yields a
 * NO_EVIDENCE line ("we hold nothing on that"), which is honest and cheap; a
 * dimension wrongly EXCLUDED is simply not mentioned, which is the pre-existing
 * behaviour. Neither direction can produce an unsourced assertion, because
 * everything downstream still passes the emission validator.
 *
 * `intentDomains` from the intent classifier is unioned in, so a dimension the
 * keywords miss but retrieval was already told to fetch for still gets planned.
 */
const DIMENSION_PATTERNS: Record<DimensionKey, RegExp> = {
  CLINICAL_READINESS: /\b(ready|readiness|fit for surgery|candidate|eligib|suitab|pre-?op|clearance|control(led)?|before surgery)\b/i,
  DIET: /\b(diet|dietary|nutrition|food|eat|eating|meal|vegetarian|vegan|halal|kosher|jain)\b/i,
  EXERCISE: /\b(exercise|activity|physio|physical|walk|walking|mobility|rehab|restriction)\b/i,
  HOSPITAL_COMPARISON: /\b(hospital|clinic|surgeon|centre|center|compare|comparison|which city|where should)\b/i,
  COST: /\b(cost|price|budget|afford|expensive|cheap|fee|package|estimate|how much)\b/i,
  VISA: /\b(visa|entry|immigration|passport|permit|documentation|invitation letter)\b/i,
  TRAVEL_FITNESS: /\b(fit to fly|fitness to (fly|travel)|travel fitness|safe to (fly|travel)|flight|flying|escort|oxygen)\b/i,
  ACCOMMODATION: /\b(accommodation|hotel|stay|lodging|guest ?house|where to stay|attendant)\b/i,
  RECOVERY_PERIOD: /\b(recover|recovery|convalesc|how long|length of stay|discharge|rehabilitation|weeks after)\b/i,
  FOLLOW_UP: /\b(follow[- ]?up|aftercare|review appointment|check[- ]?up|back home|once i (return|am home))\b/i,
};

const DOMAIN_TO_DIMENSIONS: Record<KnowledgeDomain, readonly DimensionKey[]> = {
  NUTRITION: ['DIET'],
  EXERCISE: ['EXERCISE'],
  LIFESTYLE: ['DIET'],
  MONITORING: ['CLINICAL_READINESS'],
  COST: ['COST'],
  HOSPITAL: ['HOSPITAL_COMPARISON'],
  VISA: ['VISA'],
  ENVIRONMENT: ['ACCOMMODATION'],
  GUIDELINE: ['RECOVERY_PERIOD'],
};

export function detectDimensions(message: string, intentDomains: readonly KnowledgeDomain[] = []): DimensionKey[] {
  const found = new Set<DimensionKey>();
  for (const key of ALL_DIMENSIONS) {
    if (DIMENSION_PATTERNS[key].test(message)) found.add(key);
  }
  for (const d of intentDomains) {
    for (const k of DOMAIN_TO_DIMENSIONS[d] ?? []) found.add(k);
  }
  return ALL_DIMENSIONS.filter((k) => found.has(k));
}

/**
 * Build the plan.
 *
 * `categoryWasClinicalDecision` is what distinguishes the two shapes this
 * produces. When the classifier did NOT say CLINICAL_DECISION, no deferral
 * applies — the patient did not ask for an individual determination, so
 * CLINICAL_READINESS and TRAVEL_FITNESS simply carry their published-criteria
 * content like any other dimension. When it DID, every dimension with a
 * DeferralSpec picks it up. That keeps the deferral machinery off the ordinary
 * Decision Support path entirely rather than making every answer defensive.
 */
export function planCoverage(opts: {
  message: string;
  intentDomains: readonly KnowledgeDomain[];
  admittedClaims: readonly RetrievedClaim[];
  categoryWasClinicalDecision: boolean;
}): CoveragePlan {
  const requested = detectDimensions(opts.message, opts.intentDomains);
  const byDomain = new Map<KnowledgeDomain, RetrievedClaim[]>();
  for (const c of opts.admittedClaims) {
    const list = byDomain.get(c.domain);
    if (list) list.push(c);
    else byDomain.set(c.domain, [c]);
  }

  const dimensions: PlannedDimension[] = requested.map((key) => {
    const claims = DIMENSION_DOMAINS[key].flatMap((d) => byDomain.get(d) ?? []);
    const deferral = opts.categoryWasClinicalDecision ? (DEFERRALS[key] ?? null) : null;

    let disposition: DimensionDisposition;
    if (deferral && claims.length === 0) {
      // Nothing published to reproduce, and the individual determination is
      // off the table. DEFERRED rather than NO_EVIDENCE: the honest thing to
      // say is "we can't determine this and hold no published criteria for it
      // either", and DEFERRED carries the clause that explains why.
      disposition = 'DEFERRED';
    } else if (deferral) {
      disposition = 'ANSWERABLE_WITH_DEFERRAL';
    } else if (claims.length === 0) {
      disposition = 'NO_EVIDENCE';
    } else {
      disposition = 'ANSWERABLE';
    }

    return { key, disposition, claims, deferral };
  });

  const present = new Set(dimensions.map((d) => d.key));
  const crossReferences = CROSS_REFERENCES.filter((x) => present.has(x.from) && present.has(x.to));

  // Publishable when at least one dimension has real, admitted evidence behind
  // it. A plan of nothing but DEFERRED and NO_EVIDENCE is a plan to say
  // "I can't help with any of this" at length, which is worse than the short
  // static refusal — so route.ts uses the short one.
  const publishable = dimensions.some((d) => d.disposition === 'ANSWERABLE' || d.disposition === 'ANSWERABLE_WITH_DEFERRAL');

  return {
    dimensions,
    crossReferences,
    publishable,
    deferredDimensions: dimensions.filter((d) => d.deferral !== null).map((d) => d.key),
  };
}
