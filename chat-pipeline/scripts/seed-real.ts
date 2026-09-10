#!/usr/bin/env tsx
/**
 * R10e — the integration seed, against the REAL schema.
 *
 * Replaces chat-pipeline/db/999_seed_smoke_test.sql, which seeded the stub.
 * Two things make this a TypeScript module rather than another .sql file, and
 * both are consequences of the real schema rather than preferences:
 *
 *   1. principal.patient_attribute stores CIPHERTEXT, and the application owns
 *      the wrapping key. A SQL seed can write random bytes into those columns —
 *      migrations/test/r10d_attr.sh does exactly that, because it only cares
 *      about the envelope's VISIBILITY — but it cannot write bytes the pipeline
 *      can decrypt. If the seed cannot produce readable attributes, the
 *      integration test cannot exercise the decryption path at all.
 *   2. The subject key must be minted through principal.ensure_subject_key with
 *      a real wrapped DEK, which means running subjectKey.ts's own wrap. Seeding
 *      it any other way would be seeding a key the application cannot use.
 *
 * So the seed uses the same code the request path uses. That is the point: a
 * fixture built by a different mechanism from the one under test is how the stub
 * came to disagree with the schema in twelve places.
 *
 * IDEMPOTENT. Every insert is ON CONFLICT DO NOTHING or guarded, so it can run
 * against a database a previous run touched — the integration test calls it in
 * beforeAll, and CI runs it once as a step.
 */
import pg from 'pg';
import { randomUUID } from 'node:crypto';
import { getOrMintSubjectKey, encryptAttribute, type SubjectKey } from '../src/lib/subjectKey';

/**
 * THE SEED DOES NOT USE `db()`, AND THAT IS THE POINT.
 *
 * `db()` is the application's pool, and HP-RB-001 §2 says the application never
 * connects as owner or superuser. It holds INSERT on nothing this file writes —
 * checked rather than assumed:
 *
 *   has_table_privilege('hp_app','principal.app_user','INSERT')        -> false
 *   has_table_privilege('hp_app','principal.patient_attribute','INSERT')-> false
 *   has_table_privilege('hp_app','evidence.claim','INSERT')            -> false
 *   has_table_privilege('hp_app','safety.red_flag_rule','INSERT')      -> false
 *   has_table_privilege('hp_app','obs.response_audit','INSERT')        -> false
 *
 * and `principal.attribute_ref_digest` is EXECUTE to `reasoner_role` only.
 *
 * So seeding through `db()` fails — correctly. The danger is the obvious "fix":
 * granting hp_app what the seed needs, which would hand the role that parses
 * untrusted user input the ability to write evidence, safety rules and health
 * attributes. A separate connection string keeps that pressure off entirely.
 *
 * NO FALLBACK TO DATABASE_URL. A fallback would silently run the seed as
 * whatever the app is, which is the failure this comment exists to prevent.
 */
const SEED_URL_ENV = 'SEED_DATABASE_URL';

let seedPool: pg.Pool | null = null;

function seedDb(): pg.Pool {
  if (seedPool) return seedPool;
  const connectionString = process.env[SEED_URL_ENV];
  if (!connectionString) {
    throw new Error(
      `seed-real: ${SEED_URL_ENV} is not set. The seed writes to principal, safety and ` +
        'evidence, and the application role holds INSERT on none of them by design — see ' +
        'the comment above seedDb(). Point it at an owner connection; do NOT reuse ' +
        'DATABASE_URL and do NOT grant hp_app the missing privileges.',
    );
  }
  seedPool = new pg.Pool({ connectionString, max: 2 });
  return seedPool;
}

/**
 * Read the database back on the seed's own connection.
 *
 * For test assertions that INSPECT what a run left behind — ciphertext bytes,
 * access-log rows, registry contents. Those are not application reads and must
 * not be made to look like ones: `hp_app` holds SELECT on none of them, so
 * routing them through `db()` would either fail in CI or, worse, invite a grant
 * to hp_app so that the test passes.
 */
export async function seedQuery<R extends pg.QueryResultRow = pg.QueryResultRow>(
  sql: string,
  params: unknown[] = [],
): Promise<R[]> {
  const { rows } = await seedDb().query<R>(sql, params);
  return rows;
}

/**
 * One connection and one transaction, for a caller outside this file.
 *
 * `seedQuery` goes through the POOL, so a `BEGIN` sent through it and the
 * statements after it are not necessarily on the same connection — the
 * transaction would silently not exist, and a half-finished run would leave a
 * partial fixture behind. scripts/seed-demo.ts hit exactly that: a template
 * insert failed on a unique key and the rows before it had already committed
 * one at a time.
 *
 * Same reasoning as seedRealSchema()'s own transaction, which is why this lives
 * beside it rather than being reinvented there.
 */
export async function withSeedTx<T>(fn: (c: pg.PoolClient) => Promise<T>): Promise<T> {
  const c = await seedDb().connect();
  try {
    await c.query('BEGIN');
    const out = await fn(c);
    await c.query('COMMIT');
    return out;
  } catch (err) {
    await c.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    c.release();
  }
}

/** Closes the seed's own pool. The application's pools are not ours to end. */
export async function endSeedPool(): Promise<void> {
  if (seedPool) {
    const p = seedPool;
    seedPool = null;
    await p.end();
  }
}

/** Stable ids so tests can name fixtures without querying for them. */
export const SEED = {
  /** A subject whose age IS established, and established as an adult. */
  adultUser: '11111111-1111-1111-1111-111111111111',
  /** A subject whose age was NEVER established — no age risk flag at all.
   *  §3.0.3 resolves that closed, so every response for them forces review.
   *  Under the stub this could not be written down: is_minor was NOT NULL
   *  DEFAULT false, so "unknown" was recorded as "adult". */
  unknownAgeUser: 'cccccccc-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  /** A second subject, used only to prove one subject cannot read another's. */
  otherUser: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',

  guidelineClaim: '33333333-3333-3333-3333-333333333333',
  guidelineSource: '33333333-3333-3333-3333-333333333330',
  guidelineEntity: '33333333-3333-3333-3333-33333333333e',

  clinician: '55555555-5555-5555-5555-555555555555',
  ruleSet: '44444444-4444-4444-4444-444444444400',
  chestPainRule: '44444444-4444-4444-4444-444444444401',
  criticalTemplate: '44444444-4444-4444-4444-444444444402',
  urgentTemplate: '44444444-4444-4444-4444-444444444403',
} as const;

export const SEEDED_CRITICAL_TEMPLATE_BODY =
  'This may be a medical emergency. Contact your local emergency number now.';

export interface SeededRegion {
  region: string;
  residency: string;
}

async function q(c: pg.PoolClient, sql: string, params: unknown[] = []) {
  return c.query(sql, params);
}

/**
 * THE REGION COMES FROM residency_admission, the table that states the
 * precondition — ADR-004 §3 refuses a patient profile whose residency counsel
 * has not admitted. Not from region_registry ordered by active_from: three
 * gates have been bitten by that, because a neighbouring fixture's region sorts
 * first. The rule is that a fixture derives from the table defining its own
 * precondition.
 */
async function resolveRegion(c: pg.PoolClient): Promise<SeededRegion> {
  const { rows } = await q(
    c,
    `SELECT residency_country, data_region
       FROM public.residency_admission
      WHERE admission_state = 'ADMITTED'
      ORDER BY residency_country
      LIMIT 1`,
  );
  if (!rows[0]) {
    throw new Error(
      'seed-real: no ADMITTED residency exists. ADR-004 §3 refuses a patient profile ' +
        'without one, so no subject can be seeded. Migration 021 admits IN->IN.',
    );
  }
  return { region: rows[0].data_region, residency: rows[0].residency_country };
}

/** The clinician every approved artefact is attributed to. */
async function seedClinician(c: pg.PoolClient, r: SeededRegion) {
  await q(
    c,
    `INSERT INTO principal.app_user (id, auth_subject, data_region)
     VALUES ($1, 'seed-clinician', $2) ON CONFLICT (id) DO NOTHING`,
    [SEED.clinician, r.region],
  );
  await q(
    c,
    `INSERT INTO principal.clinician (user_id, full_name, primary_jurisdiction)
     VALUES ($1, 'Seed Clinician', $2) ON CONFLICT (user_id) DO NOTHING`,
    [SEED.clinician, r.region],
  );
}

/**
 * A subject, with a real minted key and — for the ones that need them — real
 * ENCRYPTED attributes and the §2.4.3 risk flag.
 *
 * `ageFlag` is the whole point of the three fixtures: 'adult' establishes
 * adulthood, null establishes nothing. There is no is_minor column to set.
 */
async function seedSubject(
  c: pg.PoolClient,
  r: SeededRegion,
  userId: string,
  authSubject: string,
  ageFlag: 'AGE_75_PLUS' | 'AGE_UNDER_18' | null,
  preferences: Record<string, unknown> | null,
): Promise<SubjectKey> {
  await q(
    c,
    `INSERT INTO principal.app_user (id, auth_subject, data_region)
     VALUES ($1, $2, $3) ON CONFLICT (id) DO NOTHING`,
    [userId, authSubject, r.region],
  );

  // Through the application's own mint, so the DEK is one the pipeline can
  // unwrap. This is why the seed is TypeScript.
  // On the seed's OWN connection, not `db()` — see seedDb(). The mint is the
  // application's code either way, which is the property that matters.
  const key = await getOrMintSubjectKey(userId, c);

  await q(
    c,
    `INSERT INTO principal.patient_profile (user_id, data_region, key_id, residency_country)
     VALUES ($1, $2, $3, $4) ON CONFLICT (user_id) DO NOTHING`,
    [userId, r.region, key.keyId, r.residency],
  );

  // A DEMOGRAPHIC attribute, encrypted with the subject's own DEK. Its payload
  // is real JSON the pipeline decrypts and reads — unlike the gate's fixture,
  // which uses random bytes because it only tests visibility.
  const demographic = encryptAttribute(key, { label: 'age band recorded at registration' });
  const demographicId = randomUUID();
  const { rowCount } = await q(
    c,
    `INSERT INTO principal.patient_attribute
       (id, subject_id, data_region, kind, payload_ciphertext, cipher_alg, cipher_nonce,
        key_id, attribute_key_digest, provenance, origin)
     SELECT $1, $2, $3, 'DEMOGRAPHIC', $4, $5, $6, $7,
            principal.attribute_ref_digest($2, 'age_band'), 'stated', 'USER_STATED'
      WHERE NOT EXISTS (
        SELECT 1 FROM principal.patient_attribute a
         WHERE a.subject_id = $2 AND a.kind = 'DEMOGRAPHIC' AND a.active)
     RETURNING id`,
    [demographicId, userId, r.region, demographic.ciphertext, demographic.alg, demographic.nonce, key.keyId],
  );

  if (preferences) {
    const pref = encryptAttribute(key, preferences);
    await q(
      c,
      `INSERT INTO principal.patient_attribute
         (id, subject_id, data_region, kind, payload_ciphertext, cipher_alg, cipher_nonce,
          key_id, attribute_key_digest, provenance, origin)
       SELECT $1, $2, $3, 'PREFERENCE', $4, $5, $6, $7,
              principal.attribute_ref_digest($2, 'preferences'), 'stated', 'USER_STATED'
        WHERE NOT EXISTS (
          SELECT 1 FROM principal.patient_attribute a
           WHERE a.subject_id = $2 AND a.kind = 'PREFERENCE' AND a.active)`,
      [randomUUID(), userId, r.region, pref.ciphertext, pref.alg, pref.nonce, key.keyId],
    );
  }

  // §4.6.2: trg_risk_flag_stated_only refuses a flag sourced from an inferred
  // attribute, which is why the DEMOGRAPHIC above is 'stated'. The flag needs a
  // source attribute id, so this only runs when we actually inserted one.
  if (ageFlag && rowCount) {
    await q(
      c,
      `INSERT INTO principal.patient_risk_flag
         (id, subject_id, flag_key, source_attribute_id, data_region)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (subject_id, flag_key, set_at) DO NOTHING`,
      [randomUUID(), userId, ageFlag, demographicId, r.region],
    );
  }

  return key;
}

/**
 * The §0.6 adoption gate's input. Without an ADOPTED rule set for the
 * jurisdiction/language, resolveAdoptionGate returns FAIL_CLOSED and every turn
 * ends in the unavailability notice — correct, and useless for testing the rest
 * of the pipeline.
 */
async function seedSafety(c: pg.PoolClient, r: SeededRegion) {
  await q(
    c,
    `INSERT INTO safety.red_flag_rule_set
       (id, version_label, jurisdiction, language, approved_by, approved_at, effective_from)
     VALUES ($1, 'seed-rules-2026.09', $2, 'en', $3, now(), now() - interval '1 day')
     ON CONFLICT (id) DO NOTHING`,
    [SEED.ruleSet, r.region, SEED.clinician],
  );

  // A structured pattern rulePattern.ts can parse — never a raw regex.
  //
  // THE SHAPE IS THE DISCRIMINATED UNION IN rulePattern.ts, and getting it
  // wrong is silent in a way worth recording. The first version of this seed
  // wrote `{any_of:[{all_of:[...]}]}`, which parses to nothing: the parser
  // reports `unknown pattern kind undefined`, the scan treats an unevaluable
  // rule as a SCANNER FAULT (§4.0.9 forbids failing open), and every turn ends
  // in the unavailability notice. The seed still printed "seeded", and
  // `safety.adopted_rule_set` still reported one adopted set — so nothing in
  // the seed or in a SQL check could see it. Only driving the pipeline could.
  // There is no OR combinator by design; ALL_OF is the only nesting.
  await q(
    c,
    `INSERT INTO safety.red_flag_rule
       (id, version, pattern, severity, rationale, approved_by, approved_at,
        rule_set_id, jurisdiction, clinically_adopted, adopted_by, adopted_at)
     VALUES ($1, 1, $2::jsonb, 'URGENT', 'Seed fixture: chest pain with breathlessness',
             $3, now(), $4, $5, true, $3, now())
     -- DO UPDATE, not DO NOTHING, and only for the pattern. A fixture must
     -- CONVERGE on its declared state: with DO NOTHING, the malformed pattern
     -- described above survived every subsequent run against the same database
     -- and the seed reported success each time. CI builds a fresh database and
     -- would not have shown it; a developer's long-lived one is where the
     -- fixture and the file silently disagree.
     ON CONFLICT (id, version) DO UPDATE SET pattern = EXCLUDED.pattern`,
    [
      SEED.chestPainRule,
      JSON.stringify({ kind: 'KEYWORD_ANY', terms: ['chest pain', 'crushing chest'] }),
      SEED.clinician,
      SEED.ruleSet,
      r.region,
    ],
  );

  // §4.3.3's ladder resolves by (severity, jurisdiction, language). The
  // CRITICAL one is what the emergency short-circuit renders.
  for (const [id, severity, body] of [
    [SEED.criticalTemplate, 'CRITICAL', SEEDED_CRITICAL_TEMPLATE_BODY],
    [SEED.urgentTemplate, 'URGENT', 'Please seek medical advice about this promptly.'],
  ] as const) {
    await q(
      c,
      `INSERT INTO safety.safety_template
         (id, version, severity, jurisdiction, language, body, slots, approved_by, approved_at,
          rule_set_id, is_fallback, machine_translated)
       VALUES ($1, 1, $2, $3, 'en', $4, '{}'::jsonb, $5, now(), $6, false, false)
       -- Converges on the declared body for the same reason the rule pattern
       -- does: the integration test asserts the rendered text VERBATIM, so a
       -- stale body in a long-lived database is a failure whose cause is in a
       -- table rather than in the diff.
       ON CONFLICT (id, version) DO UPDATE SET body = EXCLUDED.body`,
      [id, severity, r.region, body, SEED.clinician, SEED.ruleSet],
    );
  }
}

/**
 * One retrievable GUIDELINE claim, with the whole chain knowledgeLookup.ts
 * requires: a source that renders a citation, a claim_source carrying
 * confidence, a domain_attribute binding it to a registered entity type, and a
 * retrieval_chunk to match on.
 *
 * Every one of those is load-bearing. Drop the domain_attribute and
 * claim_search's `scoped` CTE returns nothing; drop the retrieval_chunk and
 * there is nothing to rank; drop the claim_source and aggregate_claim yields no
 * confidence, so the CROSS JOIN LATERAL drops the row. Each omission looks
 * exactly like "no evidence on this topic".
 */
async function seedEvidence(c: pg.PoolClient) {
  await q(
    c,
    `INSERT INTO evidence.evidence_source
       (id, tier, source_type, publisher, title, url, published_at, effective_at,
        retrieved_at, last_verified_at, language, retracted, content_hash)
     VALUES ($1, 'TIER_1', 'CLINICAL_GUIDELINE', 'Seed Health Authority',
             'Seed clinical guideline on post-operative recovery',
             'https://example.invalid/seed-guideline', current_date - 365, current_date - 365,
             now(), now(), 'en', false, 'seedhash-guideline-0001')
     ON CONFLICT (id) DO NOTHING`,
    [SEED.guidelineSource],
  );

  await q(
    c,
    `INSERT INTO evidence.claim (id, kind, statement, jurisdiction, population, effective_at)
     VALUES ($1, 'GUIDELINE',
             'Most people are advised to resume light walking within 24 to 48 hours after an uncomplicated procedure.',
             NULL, 'adults following uncomplicated elective surgery', current_date - 365)
     ON CONFLICT (id) DO NOTHING`,
    [SEED.guidelineClaim],
  );

  // §1.9.7 needs a population on a range/statistic claim, which the claim above
  // carries. confidence must clear knowledgeLookup's 0.40 Insufficient floor.
  await q(
    c,
    `INSERT INTO evidence.claim_source
       (claim_id, source_id, confidence, computed_by, policy_version, modifier_trail, computed_at)
     VALUES ($1, $2, 0.86, 'seed-real.ts', 'HP-SCHEMA-001-v0.4', '[]'::jsonb, now())
     ON CONFLICT (claim_id, source_id) DO NOTHING`,
    [SEED.guidelineClaim, SEED.guidelineSource],
  );

  // HP-DR-003 §5: retrieval is scoped through the registry, so the claim must
  // be BOUND to a registered (entity_type, attribute) pair whose expected claim
  // kind matches. guideline/scope expects GUIDELINE and requires at least one.
  await q(
    c,
    `INSERT INTO evidence.domain_attribute (id, entity_type, entity_id, attribute, claim_id)
     VALUES ($1, 'guideline', $2, 'scope', $3)
     ON CONFLICT (entity_type, entity_id, attribute, claim_id) DO NOTHING`,
    [randomUUID(), SEED.guidelineEntity, SEED.guidelineClaim],
  );

  // The searchable text. tsv is GENERATED ALWAYS from body with the 'simple'
  // configuration; the embedding is a deterministic placeholder, because the
  // FTS ranker alone is enough to retrieve this and CI has no embedding model.
  await q(
    c,
    `INSERT INTO evidence.retrieval_chunk
       (id, claim_id, source_id, chunk_ordinal, body, language,
        embedding, embedding_model, embedding_model_version, embedded_at)
     SELECT $1, $2, $3, 0,
            'Guidance on resuming light walking and gentle activity after an uncomplicated elective procedure, including recovery timelines.',
            'en', array_fill(0.01::real, ARRAY[384])::vector, 'bge-small-en-v1.5', '1.5', now()
      WHERE NOT EXISTS (SELECT 1 FROM evidence.retrieval_chunk rc WHERE rc.claim_id = $2)`,
    [randomUUID(), SEED.guidelineClaim, SEED.guidelineSource],
  );
}

export async function seedRealSchema(): Promise<{
  region: SeededRegion;
  keys: Record<'adult' | 'unknownAge' | 'other', SubjectKey>;
}> {
  // ONE connection and ONE transaction for the whole seed.
  //
  // It used to be three connections, because the subject mint went through
  // `db()` — a different pool — and so could not see rows this transaction had
  // not committed yet. Now that `getOrMintSubjectKey` takes the connection to
  // use, that constraint is gone, and losing it is worth having: a seed that
  // fails halfway leaves nothing behind, so a re-run starts from the same state
  // every time rather than from wherever the last failure stopped.
  const c = await seedDb().connect();
  try {
    await c.query('BEGIN');
    const region = await resolveRegion(c);
    await seedClinician(c, region);
    await seedSafety(c, region);
    await seedEvidence(c);

    const adult = await seedSubject(c, region, SEED.adultUser, 'seed-adult', 'AGE_75_PLUS', {
      budget_band: 'mid',
      preferred_city: 'Chennai',
    });
    const unknownAge = await seedSubject(c, region, SEED.unknownAgeUser, 'seed-unknown-age', null, null);
    const other = await seedSubject(c, region, SEED.otherUser, 'seed-other', 'AGE_75_PLUS', null);

    await c.query('COMMIT');
    return { region, keys: { adult, unknownAge, other } };
  } catch (err) {
    await c.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    c.release();
  }
}

// Runnable standalone: `tsx scripts/seed-real.ts`
if (process.argv[1] && process.argv[1].endsWith('seed-real.ts')) {
  seedRealSchema()
    .then(async ({ region }) => {
      console.log(`seed-real: seeded region ${region.region} (residency ${region.residency})`);
      await endSeedPool();
    })
    .catch(async (err) => {
      console.error('seed-real FAILED:', err);
      await endSeedPool().catch(() => {});
      process.exit(1);
    });
}
