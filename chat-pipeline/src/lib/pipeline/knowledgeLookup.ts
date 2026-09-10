import { db } from '../db';
import type { KnowledgeDomain, PipelineContext, ResponseCategory, RetrievedClaim } from '../types';

/**
 * Knowledge Lookup Layer — direct SQL, no LLM, run in parallel across the
 * domains the intent/complexity classifier flagged as relevant. This is
 * retrieval, not generation: every row returned is a claim–source binding
 * already scored by the DQE (§1.0.5 — confidence is never computed here,
 * only read) and already gated through `evidence.policy_for` (§3.0.3
 * fail-closed: a tier×kind×category combination with no policy row, or an
 * explicit PROHIBITED row, or a disabled category (§2.3.2/CLINICAL_DECISION)
 * is excluded before it ever reaches the composer — the emission validator
 * is a second, independent check on top of this, not a replacement for it).
 *
 * R10c / HP-DR-003, approved 8 September 2026. Rewritten against the shipping
 * schema, where RETRIEVAL HAPPENS AT CHUNK GRAIN AND CITATION AT CLAIM GRAIN.
 * `evidence.claim_search` (migration 033 §4) bridges the two: it collapses
 * each claim to its best-ranked chunk per ranker BEFORE fusing, so chunk count
 * — an artefact of the chunker — cannot buy rank. Executed against a fixture
 * where a Tier 4 provider brochure holds ten weak chunks and a Tier 1
 * guideline holds one strong one: the rejected alternative ranked the
 * brochure NINE TIMES higher; this one does not.
 */

/**
 * R10c. The domain map, checked against `evidence.domain_entity_type` rather
 * than written from the stub.
 *
 * FIVE OF THE NINE PREVIOUS ENTRIES DID NOT RESOLVE AT ALL — `hospital_cost`
 * was unqualified, `hospital_profile` and `domain.environment_reference` were
 * renamed, and `domain.exercise_guidance` and
 * `domain.clinical_metric_reference` never existed under any spelling. Each
 * one would have returned zero rows, silently, which is the failure this file
 * already carries a scar from: a real data gap and a wiring bug produce the
 * identical symptom. `claim_search` now RAISES on an unknown entity type, and
 * `migrations/test/r10c_retrieval.sh` asserts this map against the registry
 * in CI, so the map cannot drift again without something going red.
 *
 * A domain maps to a SET, not to one table, because the real schema split
 * these deliberately and picking one would silently discard the rest:
 *
 *   EXERCISE     an activity recommendation without its precautions is the
 *                dangerous half of the pair (§4 high-risk profiles).
 *   MONITORING   `reference_value` is the only one of the candidates that
 *                carries `population_key`, and §1.9.7 blocks a reference range
 *                with a null population from publication at all.
 *   VISA         `medical_visa` is the specific instrument; `regulation` is
 *                the law behind it. §1.8.4 requires both jurisdictions'
 *                positions where they diverge, so dropping either loses half
 *                the answer.
 */
const DOMAIN_ENTITY_TYPES: Record<KnowledgeDomain, readonly string[]> = {
  NUTRITION: ['nutrition_pattern'],
  EXERCISE: ['activity_recommendation', 'activity_precaution'],
  LIFESTYLE: ['lifestyle_screening_tool'],
  MONITORING: ['reference_value', 'clinical_indicator'],
  COST: ['hospital_cost'],
  HOSPITAL: ['hospital'],
  VISA: ['medical_visa', 'regulation'],
  ENVIRONMENT: ['environment'],
  GUIDELINE: ['guideline'],
};

/** Exported for the CI gate, which asserts every value against the registry. */
export const DOMAIN_ENTITY_TYPE_MAP = DOMAIN_ENTITY_TYPES;

/**
 * Thrown when retrieval itself fails, as distinct from retrieval finding
 * nothing. Those two must never look the same to a caller — see
 * `lookupKnowledge`.
 */
export class RetrievalFailedError extends Error {
  readonly clause = 'HP-ESC §3.0.3';
  constructor(readonly domain: KnowledgeDomain, readonly cause: unknown) {
    super(`retrieval failed for domain ${domain}: ${cause instanceof Error ? cause.message : String(cause)}`);
    this.name = 'RetrievalFailedError';
  }
}

async function lookupDomain(
  domain: KnowledgeDomain,
  query: string,
  category: ResponseCategory,
): Promise<RetrievedClaim[]> {
  const entityTypes = DOMAIN_ENTITY_TYPES[domain];

  // NOTE ON `ORDER BY cs.rank DESC`, which is the reverse of what this query
  // used to say. The stub's claim_search returned a position (lower = better).
  // Reciprocal Rank Fusion returns a SCORE (higher = better). Ordering the new
  // function ascending would return the twelve WORST matches while looking
  // entirely correct — a silent inversion, not an error.
  //
  // `aggregate_claim` and `policy_for` are both CROSS JOIN LATERAL on purpose.
  // Each drops the row when it yields nothing, and yielding nothing is exactly
  // the case §3.0.3 calls a prohibition: no policy row for this
  // tier×kind×category means not permitted, not "permitted by default".
  const { rows } = await db('reasoner').query(
    `SELECT c.id AS claim_id, c.kind, es.tier,
            c.statement AS text, c.jurisdiction, c.population,
            ag.agg_confidence AS confidence,
            evidence.confidence_band(ag.agg_confidence) AS confidence_band,
            -- §2.2.5b TRIGGER 5, and it costs NO EXTRA JOIN. aggregate_claim
            -- has returned these two since migration 024 and this query has
            -- discarded them ever since: §1.8.3's Tier 1 vs Tier 2 conflict
            -- detection, its confidence demotion, and the conflict's own id are
            -- all computed in the database, on this very row, and then dropped
            -- on the floor. HP-SR-001 recorded trigger 5 as "no conflict
            -- detection exists" — the detection exists; the READER did not.
            ag.conflict_id,
            ag.demotion_required,
            evidence.render_citation(es.id) AS citation
       FROM evidence.claim_search($1, $2::text[], NULL, $4::integer) cs
       JOIN evidence.claim c ON c.id = cs.claim_id
       JOIN evidence.evidence_source es ON es.id = cs.source_id
       CROSS JOIN LATERAL evidence.aggregate_claim(c.id) ag
       CROSS JOIN LATERAL evidence.policy_for(es.tier, c.kind, $3::response_category) pol
      WHERE pol.disposition <> 'PROHIBITED'
        AND es.retracted = false
        -- §1.9.4: below 0.40 is the Insufficient band, which "is not published
        -- as an assertion under §2". Dropped HERE because nothing downstream
        -- drops it — emissionValidator has no band check at all, verified by
        -- grep, not assumed. If this moves, that check has to exist first.
        AND ag.agg_confidence >= 0.40
        -- §1.9.1 makes a resolvable citation mandatory for a surfaced claim,
        -- so a claim whose citation cannot be rendered is not publishable.
        -- §1.9.5 forbids the model supplying the missing one.
        AND evidence.render_citation(es.id) IS NOT NULL
      ORDER BY cs.rank DESC
      LIMIT $4::integer`,
    [query, entityTypes, category, 12],
  );

  return rows.map((r) => ({
    claimId: r.claim_id,
    kind: r.kind,
    tier: r.tier,
    category,
    confidence: Number(r.confidence),
    confidenceBand: r.confidence_band,
    // §1.8.3. `conflictId` is set whenever this claim is in a Tier 1/Tier 2
    // conflict that no rule broke — including SURFACED_TO_USER, which is a
    // decision to SHOW a disagreement rather than a decision about which side
    // is right. `demotionRequired` is the stronger signal: the aggregate was
    // actually pulled down to the other side's.
    conflictId: r.conflict_id ?? undefined,
    demotionRequired: r.demotion_required === true,
    citation: r.citation, // rendered from the persisted source record, §1.9.5
    text: r.text,
    jurisdiction: r.jurisdiction ?? undefined,
    population: r.population ?? undefined,
    domain,
  }));
}

export async function lookupKnowledge(
  ctx: PipelineContext,
  domains: KnowledgeDomain[],
  category: ResponseCategory,
): Promise<Map<KnowledgeDomain, RetrievedClaim[]>> {
  // §2.3.2 / c_category_c_disabled_v1: never even attempt retrieval scoped
  // to CLINICAL_DECISION — policy_for would return PROHIBITED for every row
  // anyway (safety.response_category_state.enabled = false for that
  // category), but skipping the query entirely avoids doing 9 DB round
  // trips for a response that's about to be short-circuited regardless.
  if (category === 'CLINICAL_DECISION') return new Map();

  const uniqueDomains = Array.from(new Set(domains));

  // R10c. This used to be `.catch(() => [])`.
  //
  // That turned every failure — a dropped connection, a schema drift, the
  // unknown-entity-type guard migration 033 §4 exists to fire — into an empty
  // result, which the composer reads as "there is no evidence on this topic".
  // This file's own comment calls that "the worst possible failure mode: a
  // real data gap and a wiring bug produce the identical symptom", and then
  // the file did it. A §3.0.3 system may answer with less; it may not answer
  // with less while believing it looked.
  //
  // `allSettled` so one domain's failure does not discard the other eight's
  // results, and the rejections are re-raised together so the caller fails
  // closed with every reason named rather than the first one.
  const settled = await Promise.allSettled(
    uniqueDomains.map((d) => lookupDomain(d, ctx.message, category)),
  );

  const failures = settled.flatMap((s, i) =>
    s.status === 'rejected' ? [new RetrievalFailedError(uniqueDomains[i]!, s.reason)] : [],
  );
  if (failures.length > 0) {
    throw new AggregateError(failures, `knowledge retrieval failed for ${failures.length} domain(s)`);
  }

  const byDomain = new Map<KnowledgeDomain, RetrievedClaim[]>();
  uniqueDomains.forEach((d, i) => {
    const s = settled[i];
    byDomain.set(d, s && s.status === 'fulfilled' ? s.value : []);
  });
  return byDomain;
}

export function flattenClaims(byDomain: Map<KnowledgeDomain, RetrievedClaim[]>): RetrievedClaim[] {
  return Array.from(byDomain.values()).flat();
}
