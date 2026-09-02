// A deterministic, NON-SEMANTIC stand-in embedding function — feature
// hashing ("the hashing trick"), not a pretrained model. It exists purely
// to give claim_search()'s vector half (db/010_chat_pipeline_support.sql
// §6) something real to compute cosine distance against, so that branch of
// the SQL can actually be exercised end-to-end in this sandbox.
//
// WHY NOT A REAL EMBEDDING MODEL: HP-ADR-001 §3.3 / HP-SCHEMA-001 §11
// specify bge-small-en-v1.5 (384 dims) — the real, committed choice. This
// sandbox cannot download those weights: huggingface.co returns 403 from
// here (checked directly, not assumed). There is no other reachable source
// of pretrained 384-dim embedding weights in this environment, and writing
// one from scratch would not be "a real embedding," just a different fake
// one with extra steps. Feature hashing is the honest alternative: it is a
// real, textbook technique (used in production systems, e.g. Vowpal
// Wabbit), it is NOT dressed up as bge-small-en-v1.5 anywhere in this repo,
// and every place it is used says so.
//
// WHAT IT ACTUALLY PROVES: that the vector column, the hnsw index, the
// <=> distance operator, and the RRF fusion query in claim_search() are all
// wired correctly and return sensibly-ranked rows when given real 384-dim
// vectors — none of which had ever been exercised before (every previous
// call site passes p_query_embedding = NULL). It does NOT prove anything
// about retrieval QUALITY — cosine distance between two hashed bag-of-words
// vectors correlates with shared vocabulary, not with medical meaning, so a
// query and a claim that mean the same thing in different words will NOT
// necessarily score well here the way a real embedding model would.
//
// WHAT WOULD BE NEEDED TO FINISH THIS FOR REAL: an actual embedding call
// (either a local ONNX/sentence-transformers runtime with the real
// bge-small-en-v1.5 weights, or a hosted embedding API) wired into (a) an
// offline backfill for evidence.claim.embedding across the whole corpus,
// and (b) the request path in knowledgeLookup.ts, which currently calls
// claim_search() with only 2 arguments (query, domain table) — the
// embedding parameter is never passed at all today. This script and
// generate-embeddings.mjs deliberately do NOT wire into knowledgeLookup.ts
// or any request path — shipping a non-semantic vector as if it were the
// real thing would be worse than the current, clearly-flagged FTS-only
// fallback, not better.
const DIMS = 384;

function stableHash32(str) {
  // FNV-1a, 32-bit — deterministic across Node versions/platforms, which
  // matters here since embeddings computed once at seed time must match
  // any later recomputation for tests to be reproducible.
  let hash = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    hash ^= str.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return hash >>> 0;
}

/**
 * Tokenizes, hashes each token into one of DIMS buckets (sign determined by
 * a second hash, standard feature-hashing practice to reduce collision
 * bias), accumulates, then L2-normalizes so every vector has unit length —
 * matching what a real sentence-embedding model's output looks like
 * shape-wise, which is what pgvector's cosine operator (<=>) expects to
 * compare meaningfully.
 */
export function pseudoEmbed(text) {
  const vec = new Array(DIMS).fill(0);
  const tokens = text
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, ' ')
    .split(/\s+/)
    .filter((t) => t.length > 1);

  for (const token of tokens) {
    const h = stableHash32(token);
    const bucket = h % DIMS;
    const sign = stableHash32(token + '#sign') % 2 === 0 ? 1 : -1;
    vec[bucket] += sign;
  }

  const norm = Math.sqrt(vec.reduce((sum, x) => sum + x * x, 0));
  if (norm === 0) return vec; // all-zero vector (empty/degenerate text) — pgvector accepts this, cosine distance to it is undefined-but-harmless for our purposes
  return vec.map((x) => x / norm);
}

/** Renders a JS number array as the pgvector text literal format: '[0.1,0.2,...]' */
export function toPgVectorLiteral(vec) {
  return `[${vec.map((x) => x.toFixed(8)).join(',')}]`;
}
