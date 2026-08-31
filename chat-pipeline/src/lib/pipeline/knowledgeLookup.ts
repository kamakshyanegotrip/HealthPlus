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
 * Full-text + vector hybrid search (pgvector 384-dim + Postgres FTS fused by
 * RRF, per HP-ADR-001 §3.3) is assumed to already populate a `claim_search`
 * view; this module queries that view rather than re-implementing ranking.
 */

const DOMAIN_TABLE: Record<KnowledgeDomain, string> = {
  NUTRITION: 'domain.nutrition_pattern',
  EXERCISE: 'domain.exercise_guidance',
  LIFESTYLE: 'domain.lifestyle_screening_tool',
  MONITORING: 'domain.clinical_metric_reference',
  COST: 'hospital_cost',
  HOSPITAL: 'hospital_profile',
  VISA: 'domain.regulation',
  ENVIRONMENT: 'domain.environment_reference',
  GUIDELINE: 'domain.guideline',
};

async function lookupDomain(domain: KnowledgeDomain, query: string, category: ResponseCategory): Promise<RetrievedClaim[]> {
  const table = DOMAIN_TABLE[domain];
  // claim_search: view over evidence.claim joined to the RRF-fused hybrid
  // search function, cross-joined to evidence.policy_for(tier, kind,
  // category) so a PROHIBITED or category-disabled row never makes it into
  // the result set (§3.0.3's "absence of a row is a prohibition" is
  // enforced by policy_for itself; this query just refuses to override it).
  // BUG FOUND BY scripts/smoke-test.mjs (run against a real Postgres, not
  // just read): this used to pass `domain` (the KnowledgeDomain enum, e.g.
  // "GUIDELINE") as claim_search's second argument, while claim_search
  // filters internally on `c.domain_table` (the SQL table name, e.g.
  // "domain.guideline"). The two never matched, so every lookup silently
  // returned zero rows — exactly the kind of failure that reads as "no
  // sources for this query" rather than as an error, which for a §3.0.3
  // system is the worst possible failure mode (a real data gap and a wiring
  // bug produce the identical symptom). Fixed by passing `table` into
  // claim_search consistently with the outer WHERE clause; the outer filter
  // is kept as a second, redundant check on the same value rather than
  // removed, matching this codebase's existing belt-and-braces pattern.
  const { rows } = await db().query(
    `SELECT c.id AS claim_id, c.kind, es.tier, c.text, c.jurisdiction, c.population,
            ca.confidence, ca.confidence_band, ca.citation
       FROM claim_search($1, $2) cs
       JOIN evidence.claim c ON c.id = cs.claim_id
       JOIN evidence.evidence_source es ON es.id = cs.source_id
       JOIN LATERAL evidence.claim_aggregate(c.id, $3) ca ON true
       JOIN LATERAL evidence.policy_for(es.tier, c.kind, $3::response_category) pol ON true
      WHERE c.domain_table = $4
        AND pol.disposition <> 'PROHIBITED'
        AND es.retracted = false
      ORDER BY cs.rank
      LIMIT 12`,
    [query, table, category, table],
  );

  return rows.map((r) => ({
    claimId: r.claim_id,
    kind: r.kind,
    tier: r.tier,
    category,
    confidence: Number(r.confidence),
    confidenceBand: r.confidence_band,
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
  const results = await Promise.all(uniqueDomains.map((d) => lookupDomain(d, ctx.message, category).catch(() => [] as RetrievedClaim[])));

  const byDomain = new Map<KnowledgeDomain, RetrievedClaim[]>();
  uniqueDomains.forEach((d, i) => byDomain.set(d, results[i] ?? []));
  return byDomain;
}

export function flattenClaims(byDomain: Map<KnowledgeDomain, RetrievedClaim[]>): RetrievedClaim[] {
  return Array.from(byDomain.values()).flat();
}
