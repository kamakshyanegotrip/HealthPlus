#!/usr/bin/env bash
# ============================================================================
# R10c — retrieval grain, citability, and the domain map, against the real
#        schema. HP-DR-003, approved 8 September 2026.
#
# WHY THIS EXISTS
#
# knowledgeLookup.ts carries a scar: the KnowledgeDomain enum was passed where
# a table name was expected, so every lookup silently returned zero rows. Its
# own comment calls that "the worst possible failure mode — a real data gap and
# a wiring bug produce the identical symptom."
#
# When R10c checked that map against the real registry, FIVE OF NINE entries
# did not resolve. Same bug, five times, latent behind the cutover. So this
# gate has two halves:
#
#   * sections 1-2 assert the MAP still resolves, and that an unresolvable one
#     RAISES rather than returning an empty set;
#   * sections 3-6 assert the RETRIEVAL RULES DR-003 approved, each with a
#     fixture built so the wrong answer is reachable. A trap that cannot win
#     proves nothing — RF4's first fixture taught that.
#
# Section 4 is the one that matters most: it runs BOTH fusion strategies over
# the same rows and asserts they disagree in the predicted direction. If they
# ever agree, the fixture has stopped exercising DR-003 §2 and this gate is
# measuring nothing.
#
# Env: standard PG* vars. Run after migrations have been applied.
# ============================================================================
set -euo pipefail

PGDATABASE="${PGDATABASE:-healthplus}"
export PGDATABASE

fail() { echo "R10c FAIL: $*" >&2; exit 1; }
Q="limit sodium day"

# ---------------------------------------------------------------------------
# 1. THE DOMAIN MAP. Every entity type the application names must exist in
#    evidence.domain_entity_type. This is HP-DR-003 §5's assertion, and it is
#    the check that would have caught all five broken entries.
#
#    The list is read FROM THE MODULE, not retyped here. A copy would drift
#    from the thing it is checking, which is the failure this whole gate is
#    about.
# ---------------------------------------------------------------------------
echo "1. every entity type in knowledgeLookup's domain map resolves in the registry"
MAP=$(npx --prefix chat-pipeline tsx -e "
  import { DOMAIN_ENTITY_TYPE_MAP } from './chat-pipeline/src/lib/pipeline/knowledgeLookup';
  const rows = Object.entries(DOMAIN_ENTITY_TYPE_MAP)
    .flatMap(([d, ts]) => (ts as string[]).map((t) => d + '\t' + t));
  console.log(rows.join('\n'));
" 2>/dev/null)
[ -n "$MAP" ] || fail "could not read DOMAIN_ENTITY_TYPE_MAP from the module"

missing=""
while IFS=$'\t' read -r dom et; do
  [ -n "$et" ] || continue
  n=$(psql -qAt -c "SELECT count(*) FROM evidence.domain_entity_type WHERE entity_type = '$et'")
  [ "$n" = "1" ] || missing="$missing $dom->$et"
done <<< "$MAP"

[ -z "$missing" ] || fail "domain map entries do not resolve against evidence.domain_entity_type:$missing
This is the bug class R10c exists to close. A non-resolving entity type would
have filtered to zero rows and read as 'no evidence on this topic'."
echo "  $(echo "$MAP" | wc -l) entity types, all present"

# ---------------------------------------------------------------------------
# 2. AND THE GUARD. An unknown entity type must RAISE, not return nothing.
#    Without this, section 1 could pass while the runtime still fails silently.
# ---------------------------------------------------------------------------
echo "2. an unknown entity type raises rather than returning an empty set"
out=$(psql -qAt -c \
  "SELECT count(*) FROM evidence.claim_search('x', ARRAY['domain.exercise_guidance'])" 2>&1 || true)
case "$out" in
  *"unknown entity_type"*) echo "  raises, as it must" ;;
  *) fail "claim_search accepted an entity type that does not exist and returned '$out'.
A wiring bug must not be able to look like an answer." ;;
esac

# ---------------------------------------------------------------------------
# 3. THE FIXTURE. One Tier 1 guideline with a single dense chunk; one Tier 4
#    provider document with ten sparse ones; plus two traps that must never be
#    retrieved. The Tier 4 chunks DO match the query — a trap that cannot win
#    proves nothing.
# ---------------------------------------------------------------------------
echo "3. fixture: 1 Tier-1 chunk vs 10 Tier-4 chunks, plus two unretrievable traps"
psql -v ON_ERROR_STOP=1 -q <<'SQL'
DO $$
DECLARE
  s1 uuid := gen_random_uuid(); s4 uuid := gen_random_uuid(); s5 uuid := gen_random_uuid();
  k1 uuid := gen_random_uuid(); k4 uuid := gen_random_uuid(); ko uuid := gen_random_uuid();
  ent uuid := gen_random_uuid(); i int;
  vn vector(384) := ('[1,' || repeat('0,',382) || '0]')::vector;
  vf vector(384) := ('[0,1,' || repeat('0,',381) || '0]')::vector;
BEGIN
  DELETE FROM evidence.retrieval_chunk
   WHERE source_id IN (SELECT id FROM evidence.evidence_source WHERE content_hash LIKE 'r10c-%');
  DELETE FROM evidence.domain_attribute
   WHERE claim_id IN (SELECT claim_id FROM evidence.claim_source
                       WHERE source_id IN (SELECT id FROM evidence.evidence_source
                                            WHERE content_hash LIKE 'r10c-%'));
  DELETE FROM evidence.claim_source
   WHERE source_id IN (SELECT id FROM evidence.evidence_source WHERE content_hash LIKE 'r10c-%');
  DELETE FROM evidence.evidence_source WHERE content_hash LIKE 'r10c-%';

  INSERT INTO evidence.evidence_source
    (id, tier, source_type, publisher, title, url, doi, published_at, effective_at,
     retrieved_at, last_verified_at, language, retracted, content_hash)
  VALUES
    (s1,'TIER_1','GUIDELINE','Ministry of Health','R10c salt guidance',
     'https://example.test/r10c-g', NULL, date '2025-01-10', date '2025-06-01', now(), now(),'en',false,'r10c-1'),
    (s4,'TIER_4','PROVIDER_SUBMISSION','Sunrise Hospital','R10c provider brochure',
     'https://example.test/r10c-p', NULL, date '2026-02-02', NULL, now(), now(),'en',false,'r10c-4'),
    (s5,'TIER_5','preprint','medRxiv','R10c preprint',
     NULL,'10.1101/r10c', date '2026-03-03', NULL, now(), now(),'en',false,'r10c-5');

  INSERT INTO evidence.claim (id, kind, statement, jurisdiction, population) VALUES
    (k1,'GENERAL_EDUCATION','R10c: limit sodium to under 2g per day.','IN','adults'),
    (k4,'GENERAL_EDUCATION','R10c: our sodium programme.','IN','adults'),
    (ko,'GENERAL_EDUCATION','R10c: claim with no domain binding.','IN','adults');

  INSERT INTO evidence.claim_source
    (claim_id, source_id, confidence, computed_by, policy_version, modifier_trail, computed_at) VALUES
    (k1,s1,0.95,'r10c','v1','[]'::jsonb,now()),
    (k4,s4,0.40,'r10c','v1','[]'::jsonb,now()),
    (ko,s1,0.95,'r10c','v1','[]'::jsonb,now());

  -- k1 and k4 are in the domain; ko deliberately is not
  INSERT INTO evidence.domain_attribute (id, entity_type, entity_id, attribute, claim_id) VALUES
    (gen_random_uuid(),'nutrition_pattern',ent,'description',k1),
    (gen_random_uuid(),'nutrition_pattern',ent,'description',k4);

  -- ONE dense chunk: all three query terms adjacent, so high cover density.
  INSERT INTO evidence.retrieval_chunk
    (id, claim_id, source_id, chunk_ordinal, body, language, embedding, embedding_model, embedding_model_version)
  VALUES (gen_random_uuid(), k1, s1, 0, 'limit sodium day adults', 'en', vn, 'r10c', 'v1');

  -- TEN sparse chunks: the same three terms, far apart, so each ranks BELOW
  -- the single dense one. They must still MATCH, or the trap cannot fire.
  FOR i IN 1..10 LOOP
    INSERT INTO evidence.retrieval_chunk
      (id, claim_id, source_id, chunk_ordinal, body, language, embedding, embedding_model, embedding_model_version)
    VALUES (gen_random_uuid(), k4, s4, i,
            'limit ' || repeat('filler ',25) || 'sodium ' || repeat('filler ',25) || 'day page ' || i,
            'en', vf, 'r10c', 'v1');
  END LOOP;

  -- TRAP A: the strongest match in the corpus, anchored to a SOURCE only.
  -- DR-003 §3: no claim anchor means no claim_source row, so no confidence and
  -- no policy disposition — policy_for would have nothing to gate.
  INSERT INTO evidence.retrieval_chunk
    (id, claim_id, source_id, chunk_ordinal, body, language, embedding, embedding_model, embedding_model_version)
  VALUES (gen_random_uuid(), NULL, s5, 0, 'limit sodium day limit sodium day', 'en', vn, 'r10c', 'v1');

  -- TRAP B: equally strong, a real claim, but bound to no domain entity.
  INSERT INTO evidence.retrieval_chunk
    (id, claim_id, source_id, chunk_ordinal, body, language, embedding, embedding_model, embedding_model_version)
  VALUES (gen_random_uuid(), ko, s1, 0, 'limit sodium day limit sodium day', 'en', vn, 'r10c', 'v1');
END $$;
SQL

# Confirm the trap is loaded rather than assuming it: the Tier 4 chunks must
# match the query, and must each rank below the Tier 1 one.
t4hits=$(psql -qAt -c "
  SELECT count(*) FROM evidence.retrieval_chunk rc
   WHERE rc.source_id = (SELECT id FROM evidence.evidence_source WHERE content_hash='r10c-4')
     AND rc.tsv @@ websearch_to_tsquery('simple','$Q')")
[ "$t4hits" = "10" ] || fail "the Tier 4 trap chunks do not match the query ($t4hits of 10 match).
A trap that cannot win proves nothing, and section 4 would pass vacuously."
echo "  10 Tier-4 chunks match the query; the trap is live"

# ---------------------------------------------------------------------------
# 4. HP-DR-003 §2. THE DECISION THAT CHANGES ANSWERS.
#    Collapse-then-fuse must rank the Tier 1 guideline above the Tier 4
#    brochure, AND fuse-then-collapse must rank them the other way round. Both
#    halves are asserted: without the second, this passes even if the fixture
#    stops discriminating.
# ---------------------------------------------------------------------------
echo "4. collapse-then-fuse ranks evidence; fuse-then-collapse would rank volume"
shipped=$(psql -qAt -c "
  SELECT es.tier FROM evidence.claim_search('$Q', ARRAY['nutrition_pattern']::text[], NULL, 12) cs
    JOIN evidence.evidence_source es ON es.id = cs.source_id
    JOIN evidence.claim c ON c.id = cs.claim_id
   WHERE c.statement LIKE 'R10c:%' ORDER BY cs.rank DESC LIMIT 1")
[ "$shipped" = "TIER_1" ] || fail "collapse-then-fuse put $shipped first, expected TIER_1.
A Tier 4 provider document outranking a Tier 1 guideline is exactly what
HP-DR-003 §2 Option B was approved to prevent. §1.4.4 caps Tier 4 CONFIDENCE;
it does not cap Tier 4 RANK — this does."

rejected=$(psql -qAt <<SQL
WITH scoped AS (SELECT DISTINCT claim_id FROM evidence.domain_attribute WHERE entity_type='nutrition_pattern'),
ch AS (SELECT rc.claim_id cid, rc.tsv FROM evidence.retrieval_chunk rc
         JOIN scoped s ON s.claim_id=rc.claim_id WHERE rc.claim_id IS NOT NULL),
hits AS (SELECT cid, ts_rank_cd(tsv, websearch_to_tsquery('simple','$Q')) sc
           FROM ch WHERE tsv @@ websearch_to_tsquery('simple','$Q')),
r AS (SELECT cid, row_number() OVER (ORDER BY sc DESC) rnk FROM hits)
SELECT es.tier FROM r
  JOIN evidence.claim c ON c.id=r.cid
  JOIN evidence.claim_source cso ON cso.claim_id=c.id
  JOIN evidence.evidence_source es ON es.id=cso.source_id
 WHERE c.statement LIKE 'R10c:%'
 GROUP BY es.tier ORDER BY sum(1.0/(60+r.rnk)) DESC LIMIT 1
SQL
)
[ "$rejected" = "TIER_4" ] || fail "the REJECTED strategy also put $rejected first, so this fixture
no longer distinguishes the two options and section 4 is measuring nothing.
Rebuild the fixture so chunk volume can actually buy rank."
echo "  shipped -> TIER_1, rejected strategy -> TIER_4; the decision is load-bearing"

# ---------------------------------------------------------------------------
# 5. HP-DR-003 §3 and §5. The two traps.
# ---------------------------------------------------------------------------
echo "5. an unanchored chunk and an unbound claim are both unreachable"
n=$(psql -qAt -c "
  SELECT count(*) FROM evidence.claim_search('$Q', ARRAY['nutrition_pattern']::text[], NULL, 12) cs
    JOIN evidence.evidence_source es ON es.id=cs.source_id WHERE es.content_hash='r10c-5'")
[ "$n" = "0" ] || fail "a chunk with no claim anchor was retrieved. It has no claim_source row,
so no confidence and no policy disposition — policy_for has nothing to gate,
and it would reach the composer past the §3.0.3 default-deny gate entirely."

n=$(psql -qAt -c "
  SELECT count(*) FROM evidence.claim_search('$Q', ARRAY['nutrition_pattern']::text[], NULL, 12) cs
    JOIN evidence.claim c ON c.id=cs.claim_id WHERE c.statement LIKE 'R10c: claim with no domain%'")
[ "$n" = "0" ] || fail "a claim with no domain_attribute binding was returned for a scoped search."
echo "  neither retrievable"

# ---------------------------------------------------------------------------
# 6. §1.9.4 and §1.9.1/§1.9.5 — the two things the schema has no column for.
# ---------------------------------------------------------------------------
echo "6. band boundaries and citation rendering"
bands=$(psql -qAt -c "
  SELECT string_agg(evidence.confidence_band(v), ',' ORDER BY ord)
    FROM (VALUES (0.95,1),(0.85,2),(0.84,3),(0.65,4),(0.64,5),(0.40,6),(0.39,7),(NULL,8)) t(v,ord)")
want="High,High,Medium,Medium,Low,Low,Insufficient,Insufficient"
[ "$bands" = "$want" ] || fail "§1.9.4 band boundaries are wrong.
  got:  $bands
  want: $want"

cit=$(psql -qAt -c "SELECT evidence.render_citation(id) FROM evidence.evidence_source WHERE content_hash='r10c-5'")
case "$cit" in
  *"preprint — not peer reviewed"*) : ;;
  *) fail "§1.3.4: a Tier 5 preprint citation must carry 'preprint — not peer reviewed'. Got: $cit" ;;
esac
cit4=$(psql -qAt -c "SELECT evidence.render_citation(id) FROM evidence.evidence_source WHERE content_hash='r10c-4'")
case "$cit4" in
  *"self-reported by provider"*) : ;;
  *) fail "§1.4.2: a Tier 4 citation must say it is self-reported. Got: $cit4" ;;
esac
case "$cit4" in
  *TIER_*) fail "§1.9.2 forbids showing TIER_n to users; the citation leaked the enum: $cit4" ;;
esac
echo "  bands correct; preprint and self-report markers present; no enum leak"

echo "R10c: retrieval grain, citability and the domain map verified against the real schema."
