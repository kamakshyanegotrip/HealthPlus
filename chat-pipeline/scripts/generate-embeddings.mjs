// R10c: backfills evidence.retrieval_chunk.embedding, not evidence.claim.
// Both the tsvector and the embedding moved to CHUNK grain (HP-DR-003):
// a claim may have many chunks, and retrieval ranks passages, not claims.
// Backfills every seeded chunk using the
// deterministic, non-semantic pseudo-embedding in pseudo-embed.mjs — see
// that file's header for exactly what this does and does not prove. This
// is a TEST-DATA step, not a production migration: it does not belong in
// db/999_seed_smoke_test.sql because it's derived data computed in JS, not
// hand-authored fixture rows, and it deliberately runs with elevated
// privileges (hp_app has no UPDATE grant on evidence.claim — read-only by
// design, db/000's application role grants) that the app itself must never
// have.
//
// Usage: node scripts/generate-embeddings.mjs
// Connects as the postgres superuser (matches how db/*.sql migrations are
// applied — see README) via PG* env vars, defaulting to the same
// postgres/postgres TCP credentials this repo's CI Postgres service
// container uses (.github/workflows/ci.yml).
import pg from 'pg';
import { pseudoEmbed, toPgVectorLiteral } from './pseudo-embed.mjs';

const pool = new pg.Pool({
  host: process.env.PGHOST ?? '127.0.0.1',
  port: Number(process.env.PGPORT ?? 5432),
  database: process.env.PGDATABASE ?? 'hp_test',
  user: process.env.PGUSER ?? 'postgres',
  password: process.env.PGPASSWORD ?? 'postgres',
});

async function main() {
  const { rows } = await pool.query('SELECT id, body AS text FROM evidence.retrieval_chunk WHERE embedding IS NULL');
  if (rows.length === 0) {
    console.log('No chunks with a NULL embedding — nothing to backfill.');
    await pool.end();
    return;
  }

  for (const row of rows) {
    const vec = pseudoEmbed(row.text);
    await pool.query('UPDATE evidence.retrieval_chunk SET embedding = $1::vector WHERE id = $2', [toPgVectorLiteral(vec), row.id]);
  }

  console.log(`Backfilled ${rows.length} chunk embedding(s) with pseudo-embed (non-semantic — see pseudo-embed.mjs header).`);
  await pool.end();
}

main().catch((err) => {
  console.error('generate-embeddings.mjs failed:', err);
  process.exit(1);
});
