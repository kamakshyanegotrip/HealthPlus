// Smoke test: runs the ACTUAL SQL strings from src/lib/pipeline/*.ts and
// src/lib/anthropic.ts against a real Postgres instance (db/000 + db/010 +
// db/999 applied first), connected as hp_app — the same role the app uses,
// not a superuser — so grants get exercised too, not just syntax.
//
// This is not a substitute for running the TypeScript modules themselves
// (that needs a live Anthropic key and a full app_user/JWT harness this repo
// doesn't have), but it does what HP-SEC-001 §5 found valuable: "None of
// these would have shown up from reading the SQL — they only surfaced by
// executing it." Run with: node scripts/smoke-test.mjs
import pg from 'pg';
import { randomUUID } from 'node:crypto';
import { pseudoEmbed, toPgVectorLiteral } from './pseudo-embed.mjs';

const pool = new pg.Pool({
  host: '127.0.0.1',
  port: 5432,
  database: 'hp_test',
  user: 'hp_app',
  password: 'hp_app_pw',
});

const USER_ID = '11111111-1111-1111-1111-111111111111';
// Second patient + two hospitals, seeded in db/999 purely to exercise
// HP-SEC-001 RLS (db/020_rls.sql) below.
const USER_ID_B = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const HOSPITAL_PUBLISHED = 'cccccccc-1111-1111-1111-111111111111';
const HOSPITAL_DRAFT = 'cccccccc-2222-2222-2222-222222222222';
const AUDIT_ID = '99999999-9999-9999-9999-999999999999';
let failures = 0;

async function check(name, fn) {
  try {
    const result = await fn();
    console.log(`OK   ${name}`, result ?? '');
  } catch (err) {
    failures++;
    console.error(`FAIL ${name}:`, err.message);
  }
}

// Mirrors src/lib/db.ts's runAsUser: sets request.jwt.claims as a
// per-transaction GUC (the same one HP-SEC-001 §5 used via set_config to
// impersonate roles during its own validation) on the shared hp_app
// connection, scoped so it can never leak onto a different pooled query.
async function asUser(claims, fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT set_config($1, $2, true)', ['request.jwt.claims', claims ? JSON.stringify(claims) : null]);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

// Same as asUser, but always rolls back — for probing INSERT/UPDATE
// permission without persisting a row (hp_app has no DELETE grant on
// hospital_profile/hospital_cost, so a commit-then-cleanup approach isn't
// available here the way it is for other checks in this file).
async function asUserDryRun(claims, fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT set_config($1, $2, true)', ['request.jwt.claims', claims ? JSON.stringify(claims) : null]);
    const result = await fn(client);
    await client.query('ROLLBACK');
    return result;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

const PATIENT_PROFILE_QUERY = `SELECT p.user_id, p.data_region, p.age_band, p.preferences, p.is_minor,
              COALESCE(
                jsonb_agg(jsonb_build_object('label', a.label, 'provenance', a.provenance))
                  FILTER (WHERE a.label IS NOT NULL),
                '[]'::jsonb
              ) AS stated_conditions
         FROM patient_profile p
         LEFT JOIN patient_attribute a ON a.user_id = p.user_id AND a.kind = 'condition'
        WHERE p.user_id = $1
        GROUP BY p.user_id, p.data_region, p.age_band, p.preferences, p.is_minor`;

async function main() {
  // ---- patientProfile.ts, now RLS-gated (HP-SEC-001, db/020_rls.sql) ----
  await check('patientProfile.lookupPatientProfile (as the profile owner, via RLS)', async () => {
    const { rows } = await asUser({ sub: USER_ID, user_role: 'patient' }, (client) => client.query(PATIENT_PROFILE_QUERY, [USER_ID]));
    if (rows.length !== 1) throw new Error(`expected 1 row, got ${rows.length}`);
    if (!Array.isArray(rows[0].stated_conditions) || rows[0].stated_conditions.length !== 1) {
      throw new Error(`expected 1 stated condition, got ${JSON.stringify(rows[0].stated_conditions)}`);
    }
    return JSON.stringify(rows[0].stated_conditions);
  });

  // ---- HP-SEC-001 RLS (db/020_rls.sql) ----------------------------------
  await check('RLS patient_profile: querying with NO request.jwt.claims set returns zero rows (fail-closed)', async () => {
    const { rows } = await asUser(null, (client) => client.query(PATIENT_PROFILE_QUERY, [USER_ID]));
    if (rows.length !== 0) throw new Error(`expected 0 rows with no claims set, got ${rows.length}`);
    return 'correctly blocked with no claims';
  });

  await check("RLS patient_profile: patient A's claims cannot read patient B's row, even asking for it by id directly", async () => {
    const { rows } = await asUser({ sub: USER_ID, user_role: 'patient' }, (client) => client.query(PATIENT_PROFILE_QUERY, [USER_ID_B]));
    if (rows.length !== 0) throw new Error(`expected 0 rows (cross-patient read), got ${rows.length}`);
    return 'correctly blocked cross-patient read';
  });

  await check('RLS patient_profile: SELECT * with no WHERE clause at all still only ever returns the caller\'s own row', async () => {
    // The strongest form of this check: no application-level filter is even
    // present here — if RLS weren't doing real work, this would return
    // every patient_profile row in the table.
    const { rows } = await asUser({ sub: USER_ID, user_role: 'patient' }, (client) => client.query('SELECT user_id FROM patient_profile'));
    if (rows.length !== 1 || rows[0].user_id !== USER_ID) {
      throw new Error(`expected exactly [${USER_ID}], got ${JSON.stringify(rows.map((r) => r.user_id))}`);
    }
    return `rows visible: ${JSON.stringify(rows.map((r) => r.user_id))}`;
  });

  // ---- HP-SEC-001 §4 marketplace pattern: hospital_profile/hospital_cost -
  // Not wired into any route yet (see db/020_rls.sql's comment) — validated
  // at the DB level only, the same methodology HP-SEC-001 §5 itself used.
  await check('RLS hospital_profile: a patient sees PUBLISHED listings from every hospital, never DRAFT ones', async () => {
    const { rows } = await asUser({ sub: USER_ID, user_role: 'patient' }, (client) => client.query('SELECT id, status FROM hospital_profile ORDER BY id'));
    const ids = rows.map((r) => r.id);
    if (!ids.includes(HOSPITAL_PUBLISHED)) throw new Error('patient could not see the PUBLISHED hospital');
    if (ids.includes(HOSPITAL_DRAFT)) throw new Error('patient could see the DRAFT hospital — marketplace isolation broken');
    return `visible: ${JSON.stringify(ids)}`;
  });

  await check("RLS hospital_profile: a hospital_admin sees its OWN org's DRAFT listing too, but not another org's DRAFT", async () => {
    const { rows } = await asUser({ sub: randomUUID(), user_role: 'hospital_admin', hospital_id: HOSPITAL_DRAFT }, (client) =>
      client.query('SELECT id FROM hospital_profile ORDER BY id'),
    );
    const ids = rows.map((r) => r.id);
    if (!ids.includes(HOSPITAL_DRAFT)) throw new Error("hospital_admin could not see its own org's DRAFT listing");
    if (!ids.includes(HOSPITAL_PUBLISHED)) throw new Error("hospital_admin unexpectedly could not see the other org's PUBLISHED listing (marketplace read should still apply)");
    return `visible: ${JSON.stringify(ids)}`;
  });

  await check('RLS hospital_profile: a platform_admin sees every listing regardless of status', async () => {
    const { rows } = await asUser({ sub: randomUUID(), user_role: 'platform_admin' }, (client) => client.query('SELECT id FROM hospital_profile ORDER BY id'));
    const ids = rows.map((r) => r.id);
    if (!ids.includes(HOSPITAL_PUBLISHED) || !ids.includes(HOSPITAL_DRAFT)) {
      throw new Error(`platform_admin expected to see both hospitals, saw ${JSON.stringify(ids)}`);
    }
    return `visible: ${JSON.stringify(ids)}`;
  });

  await check("RLS hospital_cost: follows its parent hospital_profile's marketplace visibility, not its own status", async () => {
    const { rows } = await asUser({ sub: USER_ID, user_role: 'patient' }, (client) => client.query('SELECT id, hospital_id FROM hospital_cost ORDER BY id'));
    const hospitalIds = rows.map((r) => r.hospital_id);
    if (!hospitalIds.includes(HOSPITAL_PUBLISHED)) throw new Error('patient could not see cost rows for the PUBLISHED hospital');
    if (hospitalIds.includes(HOSPITAL_DRAFT)) throw new Error("patient could see cost rows for the DRAFT hospital — hospital_cost isn't respecting its parent's visibility");
    return `visible hospital_ids: ${JSON.stringify(hospitalIds)}`;
  });

  await check('RLS hospital_profile: a hospital_admin CAN INSERT a new row whose id matches its own hospital_id claim', async () => {
    const newId = randomUUID();
    const { rows } = await asUserDryRun({ sub: randomUUID(), user_role: 'hospital_admin', hospital_id: newId }, (client) =>
      client.query("INSERT INTO hospital_profile (id, name, status) VALUES ($1, 'New own-org listing', 'DRAFT') RETURNING id", [newId]),
    );
    if (rows.length !== 1 || rows[0].id !== newId) throw new Error('expected the insert to succeed and return the new id');
    return 'correctly permitted by hospital_profile_own_org_write WITH CHECK (rolled back, not persisted)';
  });

  await check("RLS hospital_profile: a hospital_admin CANNOT INSERT a row whose id doesn't match its own hospital_id claim", async () => {
    let rejected = false;
    try {
      await asUserDryRun({ sub: randomUUID(), user_role: 'hospital_admin', hospital_id: HOSPITAL_PUBLISHED }, (client) =>
        client.query("INSERT INTO hospital_profile (id, name, status) VALUES ($1, 'Rogue listing', 'DRAFT')", [randomUUID()]),
      );
    } catch {
      rejected = true;
    }
    if (!rejected) throw new Error('INSERT for an unowned hospital_id should have been rejected by RLS WITH CHECK, but succeeded');
    return 'correctly rejected by hospital_profile_own_org_write WITH CHECK';
  });

  // ---- knowledgeLookup.ts (FTS-only fallback path, no query_embedding) ---
  await check('knowledgeLookup.lookupDomain [GUIDELINE, DECISION_SUPPORT]', async () => {
    const { rows } = await pool.query(
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
      ['HbA1c target diabetes guideline', 'domain.guideline', 'DECISION_SUPPORT', 'domain.guideline'],
    );
    if (rows.length !== 1) throw new Error(`expected 1 claim to surface, got ${rows.length}`);
    if (Number(rows[0].confidence) <= 0) throw new Error(`expected positive confidence, got ${rows[0].confidence}`);
    return `confidence=${rows[0].confidence} band=${rows[0].confidence_band}`;
  });

  // ---- claim_search()'s vector half (db/010 §6) -------------------------
  // GAP RESOLVED: "claim_search() vector half untested — no embedding
  // pipeline, so similarity search was never exercised." Every call site in
  // knowledgeLookup.ts passes claim_search() only 2 arguments, so
  // p_query_embedding is always NULL and the RRF/vector branch (db/010
  // lines ~258-280) had literally never executed — not "untested" in the
  // sense of missing assertions, but genuinely never-run code. These checks
  // call claim_search() directly with a real 384-dim vector (produced by
  // scripts/generate-embeddings.mjs's backfill + scripts/pseudo-embed.mjs
  // for the query) to prove that branch's SQL — the vector column, the hnsw
  // index, the <=> operator, and the RRF fusion query — is actually
  // correct. See pseudo-embed.mjs's header for exactly what this does and
  // does NOT prove (real similarity RANKING quality needs a real embedding
  // model, which huggingface.co being unreachable from this sandbox blocks
  // — this validates the SQL plumbing the real model will eventually feed).
  // Requires scripts/generate-embeddings.mjs to have been run first (it's
  // now a step in `npm run db:migrate:stub` and in CI) — if it hasn't, the
  // first check below will explain why in its own error rather than a
  // confusing "0 rows".
  await check("claim_search() vector branch actually executes when given a real embedding (never exercised by any call site before this)", async () => {
    const { rows: embeddedCount } = await pool.query('SELECT count(*) FROM evidence.claim WHERE embedding IS NOT NULL');
    if (Number(embeddedCount[0].count) === 0) {
      throw new Error('no claims have an embedding yet — run `node scripts/generate-embeddings.mjs` first (now a step in npm run db:migrate:stub)');
    }
    // A query embedding derived from text that shares heavy vocabulary with
    // the seeded GUIDELINE claim — close, not identical, so this also
    // exercises actual distance computation rather than a degenerate
    // zero-distance case.
    const queryVec = toPgVectorLiteral(pseudoEmbed('HbA1c target guidance for diabetes'));
    const { rows } = await pool.query('SELECT claim_id, rank FROM claim_search($1, $2, $3::vector)', ['HbA1c target diabetes guideline', 'domain.guideline', queryVec]);
    if (rows.length === 0) throw new Error('expected the vector-fused RRF query to return at least one row');
    return `${rows.length} row(s), top rank=${rows[0].rank}`;
  });

  await check('claim_search() vector branch: an embedding built from a claim\'s OWN text ranks that claim at or near the top', async () => {
    const GUIDELINE_CLAIM_ID = '33333333-3333-3333-3333-333333333333';
    const { rows: claimRows } = await pool.query('SELECT text FROM evidence.claim WHERE id = $1', [GUIDELINE_CLAIM_ID]);
    if (claimRows.length !== 1) throw new Error('seeded GUIDELINE claim not found — check db/999_seed_smoke_test.sql');
    const selfVec = toPgVectorLiteral(pseudoEmbed(claimRows[0].text));
    // p_query left deliberately generic (few shared FTS tokens) so this
    // check is actually exercising the VECTOR ranking, not riding along on
    // a strong FTS match for the same reasons the RRF result happens to
    // look right.
    const { rows } = await pool.query('SELECT claim_id, rank FROM claim_search($1, $2, $3::vector)', ['general information', 'domain.guideline', selfVec]);
    if (rows.length === 0) throw new Error('expected at least one row back');
    if (rows[0].claim_id !== GUIDELINE_CLAIM_ID) {
      throw new Error(`expected the claim's own text-derived embedding to rank it first; got ${rows[0].claim_id} first instead`);
    }
    return `self-similarity correctly ranked first, rank=${rows[0].rank}`;
  });

  await check('knowledgeLookup: CLINICAL_DECISION category is excluded by policy_for (fail-closed)', async () => {
    const { rows } = await pool.query(
      `SELECT c.id
         FROM claim_search($1, $2) cs
         JOIN evidence.claim c ON c.id = cs.claim_id
         JOIN evidence.evidence_source es ON es.id = cs.source_id
         JOIN LATERAL evidence.policy_for(es.tier, c.kind, $3::response_category) pol ON true
        WHERE c.domain_table = $4 AND pol.disposition <> 'PROHIBITED'`,
      ['HbA1c target diabetes guideline', 'domain.guideline', 'CLINICAL_DECISION', 'domain.guideline'],
    );
    if (rows.length !== 0) throw new Error(`expected 0 rows (category disabled), got ${rows.length}`);
    return 'confirmed: 0 rows leak through for a disabled category';
  });

  // ---- redFlagEngine.ts matchDeterministicRules --------------------------
  // R3: the live rule set is chosen by safety.adopted_rule_set(jurisdiction,
  // language) — not by a `ruleset_version` string — and `pattern` is structured
  // jsonb, not a regex. RULE_QUERY below is matchDeterministicRules' query
  // verbatim. Running it here is the whole point of this script: a column the
  // module names but the schema does not have fails LOUDLY at this line instead
  // of silently at request time, which is exactly how `active = true` and
  // `clinically_adopted = true` were each caught.
  const RULE_QUERY = `SELECT r.id, r.version, r.severity, r.pattern, r.clinically_adopted,
              s.rule_set_id
         FROM safety.adopted_rule_set($1, $2) s
         JOIN safety.red_flag_rule r
           ON r.rule_set_id = s.rule_set_id
          AND r.clinically_adopted = true
          AND r.retired_at IS NULL`;

  // Mirrors rulePattern.ts's KEYWORD_ANY arm — the only kind evaluable from raw
  // SQL, since THRESHOLD needs a structured PatternInput this script has no way
  // to build. test/rulePattern.test.ts covers every kind properly; what is
  // being proved here is the QUERY, not the matcher.
  const keywordAnyMatches = (pattern, message) =>
    pattern.kind === 'KEYWORD_ANY' &&
    pattern.terms.some((t) => message.toLowerCase().includes(t.toLowerCase()));

  await check('redFlagEngine.matchDeterministicRules [no match]', async () => {
    const { rows } = await pool.query(RULE_QUERY, ['IN', 'en']);
    if (rows.length === 0) throw new Error('adopted_rule_set returned nothing — the §0.6 gate would FAIL_CLOSED, so no match assertion below would mean anything');
    const message = 'How much does a hip replacement typically cost in Chennai?';
    const matched = rows.filter((r) => keywordAnyMatches(r.pattern, message));
    if (matched.length !== 0) throw new Error(`expected no match, got ${matched.length}`);
    return `no match across ${rows.length} adopted rule(s), as expected`;
  });

  await check('redFlagEngine.matchDeterministicRules [match: chest pain]', async () => {
    const { rows } = await pool.query(RULE_QUERY, ['IN', 'en']);
    const message = "I'm having crushing chest pain and can't breathe";
    const matched = rows.filter((r) => keywordAnyMatches(r.pattern, message));
    if (matched.length === 0) throw new Error('expected a match, got none');
    if (matched[0].severity !== 'URGENT') throw new Error(`expected URGENT, got ${matched[0].severity}`);
    // red_flag_event.rule_set_id is what ties an event to the signed set it came
    // from; if the join stops returning it the module writes null and the
    // provenance is gone.
    if (!matched[0].rule_set_id) throw new Error('rule_set_id must come back from the join');
    return `matched severity=${matched[0].severity} rule_set_id=${matched[0].rule_set_id}`;
  });

  await check('§0.6 / AMB-17: adopted_rule_set returns nothing for a jurisdiction with no signed set', async () => {
    // Negative control for the gate. resolveAdoptionGate() turns zero adopted
    // rules into FAIL_CLOSED rather than NORMAL — an unsigned deployment must
    // not look healthy while detecting nothing.
    const { rows } = await pool.query(RULE_QUERY, ['TR', 'en']);
    if (rows.length !== 0) throw new Error(`expected zero adopted rules for TR/en, got ${rows.length}`);
    return 'zero adopted rules for TR/en -> resolveAdoptionGate() = FAIL_CLOSED';
  });

  // ---- templateResolution.ts lookupTemplate (R2) --------------------------
  await check('templateResolution.lookupTemplate (keyed by severity/jurisdiction/language — no `active`, no `clinically_adopted`)', async () => {
    const { rows } = await pool.query(
      `SELECT id, version, severity, jurisdiction, language, body, slots,
              is_fallback, machine_translated
         FROM safety.safety_template
        WHERE severity = $1 AND jurisdiction = $2 AND language = $3
        ORDER BY version DESC
        LIMIT 1`,
      ['CRITICAL', 'IN', 'en'],
    );
    if (rows.length !== 1) throw new Error('expected the seeded CRITICAL template to load');
    if (rows[0].id !== '44444444-4444-4444-4444-444444444402') throw new Error(`unexpected template ${rows[0].id}`);
    return rows[0].body;
  });

  await check('§4.3.3: no URGENT template exists, which is why a URGENT scan resolves UPWARD to the CRITICAL one', async () => {
    const { rows } = await pool.query(
      `SELECT id FROM safety.safety_template WHERE severity = 'URGENT' AND jurisdiction = 'IN' AND language = 'en'`,
    );
    if (rows.length !== 0) throw new Error(`expected no URGENT row, got ${rows.length} — the ladder-climb the event insert below relies on is no longer being exercised`);
    return 'no URGENT row — selectTemplate climbs to CRITICAL (eval case tl-07 proves the climb itself)';
  });

  // ---- anthropic.ts logAiCall --------------------------------------------
  await check('anthropic.logAiCall INSERT + c_model_may_not_lower constraint (valid raise)', async () => {
    await pool.query(
      `INSERT INTO obs.ai_call
         (id, audit_id, occurred_at, purpose, provider, model_version, prompt_version,
          retrieval_version, input_tokens, output_tokens, latency_ms, outcome,
          retrieved_claim_ids, proposed_severity, applied_severity, data_region)
       VALUES (gen_random_uuid(), $1, now(), $2, 'anthropic', $3, $4,
               $5, $6, $7, $8, $9,
               $10, $11, $12, $13)`,
      [AUDIT_ID, 'RED_FLAG_PROPOSE', 'claude-haiku-4-5', 'rf-rules-2026.08.1', null, 40, 12, 210, 'OK', [], 'WARNING', 'URGENT', 'IN'],
    );
    return 'insert ok';
  });

  await check('anthropic.logAiCall: c_model_may_not_lower REJECTS an actual lower (constraint does its job)', async () => {
    let threw = false;
    try {
      await pool.query(
        `INSERT INTO obs.ai_call
           (id, audit_id, occurred_at, purpose, provider, model_version, prompt_version,
            input_tokens, output_tokens, latency_ms, outcome, proposed_severity, applied_severity, data_region)
         VALUES (gen_random_uuid(), $1, now(), 'RED_FLAG_PROPOSE', 'anthropic', 'claude-haiku-4-5', 'v1',
                 10, 10, 100, 'OK', $2, $3, 'IN')`,
        [AUDIT_ID, 'EMERGENCY', 'NORMAL'],
      );
    } catch (err) {
      threw = /c_model_may_not_lower/.test(err.message) || err.code === '23514';
      if (!threw) throw err;
    }
    if (!threw) throw new Error('expected the DB to reject a lowered severity, but it accepted it');
    return 'DB constraint correctly rejected a lowered severity';
  });

  await check('obs.ai_call_cost view resolves an estimated cost', async () => {
    const { rows } = await pool.query(
      `SELECT estimated_cost_usd FROM obs.ai_call_cost WHERE audit_id = $1 AND model_version = 'claude-haiku-4-5' LIMIT 1`,
      [AUDIT_ID],
    );
    if (rows.length !== 1 || rows[0].estimated_cost_usd === null) throw new Error('expected a resolved cost, got null/none');
    return `estimated_cost_usd=${rows[0].estimated_cost_usd}`;
  });

  // ---- emissionValidator.ts logFabricationBlock --------------------------
  await check('emissionValidator.logFabricationBlock INSERT', async () => {
    await pool.query(
      `INSERT INTO obs.fabrication_block
         (id, occurred_at, audit_id, prohibition_class, claim_kind, tier, category,
          policy_tier, policy_kind, policy_category, policy_effective_from,
          query_hash, retrieved_source_state, message_template_id, data_region)
       VALUES (gen_random_uuid(), now(), $1, $2, $3, $4, $5,
               $6, $7, $8, $9,
               $10, $11, $12, $13)`,
      [AUDIT_ID, '3.10', null, null, 'DECISION_SUPPORT', null, null, null, null, Buffer.from('deadbeef', 'hex'), JSON.stringify({ retrievedClaimIds: [] }), 'SENTENCE_OMITTED_REASSURANCE', 'IN'],
    );
    return 'insert ok';
  });

  // ---- auditLog.ts response_audit_event + response_audit + response_content
  await check('auditLog.recordAuditEvent INSERT (hash chain trigger fires)', async () => {
    const { rows } = await pool.query(
      `INSERT INTO response_audit_event (audit_id, kind, occurred_at, actor, subject_ref, payload)
       VALUES ($1, $2, now(), $3, $4, $5::jsonb) RETURNING prev_hash, row_hash`,
      [AUDIT_ID, 'CATEGORY_ASSIGNED', 'system', null, JSON.stringify({ category: 'DECISION_SUPPORT', classifier_version: 'cat-clf-2026.08.1' })],
    );
    if (!rows[0].row_hash) throw new Error('expected the chain trigger to populate row_hash');
    return `row_hash=${Buffer.from(rows[0].row_hash).toString('hex').slice(0, 12)}...`;
  });

  await check('auditLog: response_audit_event UPDATE is blocked (belt: GRANT; braces: forbid_mutation trigger)', async () => {
    // HP-RB-001 §5: "the grants stop the application, the triggers stop a
    // mistaken migration, and neither stops a superuser." hp_app has no
    // UPDATE grant at all, so it never reaches the trigger — Postgres
    // rejects it at the permission layer first. Accept either rejection
    // reason; what matters is that hp_app cannot mutate this table by
    // either path.
    let threw = false;
    let reason = '';
    try {
      await pool.query(`UPDATE response_audit_event SET actor = 'tampered' WHERE audit_id = $1`, [AUDIT_ID]);
    } catch (err) {
      threw = true;
      reason = /forbidden/i.test(err.message) ? 'forbid_mutation trigger' : /permission denied/i.test(err.message) ? 'GRANT (hp_app has no UPDATE)' : err.message;
    }
    if (!threw) throw new Error('expected this UPDATE to be blocked by either the GRANT or the trigger, but it succeeded');
    return `blocked by: ${reason}`;
  });

  await check('auditLog.upsertResponseAudit INSERT (c_min_conf / c_category_c_disabled_v1 constraints hold)', async () => {
    await pool.query(
      `INSERT INTO response_audit
         (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
          template_id, agg_confidence, policy_version, model_version, prompt_version,
          cited_claim_ids, review_state, clinical_domain)
       VALUES ($1, $2, now(), $3, $4, $5,
               $6, $7, $8, $9, $10,
               $11, $12, $13)`,
      [
        AUDIT_ID,
        Buffer.from('feedface', 'hex'),
        'DECISION_SUPPORT',
        'cat-clf-2026.08.1',
        'NORMAL',
        null,
        '0.72',
        'HP-SCHEMA-001-v0.4',
        'claude-opus-5',
        'compose-2026.08.1',
        ['33333333-3333-3333-3333-333333333333'],
        'NOT_REQUIRED',
        null,
      ],
    );
    return 'insert ok';
  });

  await check('auditLog: c_category_c_disabled_v1 REJECTS a CLINICAL_DECISION row (constraint does its job)', async () => {
    let threw = false;
    try {
      await pool.query(
        `INSERT INTO response_audit
           (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
            agg_confidence, policy_version, model_version, prompt_version, cited_claim_ids, review_state)
         VALUES (gen_random_uuid(), $1, now(), 'CLINICAL_DECISION', 'v1', 'NORMAL', 0.90, 'v1', 'm', 'p', '{}', 'PENDING')`,
        [Buffer.from('00000000', 'hex')],
      );
    } catch (err) {
      threw = /c_category_c_disabled_v1/.test(err.message) || err.code === '23514';
      if (!threw) throw err;
    }
    if (!threw) throw new Error('expected c_category_c_disabled_v1 to reject this row, but it was accepted');
    return 'DB constraint correctly rejected a CLINICAL_DECISION row';
  });

  await check('auditLog.persistResponseContent INSERT (AEAD ciphertext, no subject_key FK yet)', async () => {
    const key = Buffer.alloc(32, 7);
    const crypto = await import('node:crypto');
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
    const enc = Buffer.concat([cipher.update('the visible response text', 'utf8'), cipher.final()]);
    const ciphertext = Buffer.concat([iv, cipher.getAuthTag(), enc]);
    await pool.query(
      `INSERT INTO response_content (audit_id, subject_id, data_region, ciphertext, key_id)
       VALUES ($1, $2, $3, $4, $5)`,
      [AUDIT_ID, USER_ID, 'IN', ciphertext, null],
    );
    return 'insert ok';
  });

  // ---- knowledgeLookup.ts across the other 8 of 9 knowledge domains ------
  // Turn-5 gap: only GUIDELINE had ever been queried. Same query pattern as
  // the GUIDELINE check above, run once per remaining domain table against
  // db/999's new seed rows.
  const otherDomains = [
    ['NUTRITION query', 'low glycaemic index diet', 'domain.nutrition_pattern'],
    ['EXERCISE query', 'aerobic activity minutes diabetes', 'domain.exercise_guidance'],
    ['LIFESTYLE query', 'pre-travel checklist elective surgery', 'domain.lifestyle_screening_tool'],
    ['MONITORING query (GENERAL_EDUCATION claim)', 'glucose monitor calibration setup', 'domain.clinical_metric_reference'],
    ['COST query', 'hospital cost package pricing orthopaedic', 'hospital_cost'],
    ['HOSPITAL query', 'JCI accreditation hospital credential', 'hospital_profile'],
    ['VISA query', 'medical visa invitation letter', 'domain.regulation'],
    ['ENVIRONMENT query', 'air quality index recovery destination', 'domain.environment_reference'],
  ];
  for (const [label, query, table] of otherDomains) {
    await check(`knowledgeLookup.lookupDomain [${label}, DECISION_SUPPORT]`, async () => {
      const { rows } = await pool.query(
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
        [query, table, 'DECISION_SUPPORT', table],
      );
      if (rows.length !== 1) throw new Error(`expected 1 claim to surface for ${table}, got ${rows.length}`);
      if (Number(rows[0].confidence) <= 0) throw new Error(`expected positive confidence, got ${rows[0].confidence}`);
      return `domain_table=${table} confidence=${rows[0].confidence}`;
    });
  }

  await check('knowledgeLookup: MONITORING domain surfaces the seeded TEST_INTERPRETATION claim (drives §2.0.2 reconciliation)', async () => {
    const { rows } = await pool.query(
      `SELECT c.id AS claim_id, c.kind
         FROM claim_search($1, $2) cs
         JOIN evidence.claim c ON c.id = cs.claim_id
         JOIN evidence.evidence_source es ON es.id = cs.source_id
         JOIN LATERAL evidence.policy_for(es.tier, c.kind, $3::response_category) pol ON true
        WHERE c.domain_table = $4
          AND pol.disposition <> 'PROHIBITED'
          AND es.retracted = false`,
      ['fasting glucose reading interpretation diagnosis correlation', 'domain.clinical_metric_reference', 'DECISION_SUPPORT', 'domain.clinical_metric_reference'],
    );
    const kinds = rows.map((r) => r.kind);
    if (!kinds.includes('TEST_INTERPRETATION')) throw new Error(`expected a TEST_INTERPRETATION claim to surface, got kinds=${JSON.stringify(kinds)}`);
    return `kinds=${JSON.stringify(kinds)}`;
  });

  // ---- safety.red_flag_event (§4.0.7) -------------------------------------
  let firstRedFlagEventId = null;
  await check('redFlagEngine.recordRedFlagEvent INSERT (WARNING+, all §4 CHECK constraints hold)', async () => {
    const { rows } = await pool.query(
      `INSERT INTO safety.red_flag_event
         (id, audit_id, subject_pseudonym, session_pseudonym, occurred_at, severity,
          rule_id, rule_version, rule_set_id, trigger_detail, template_id, template_version,
          action_taken, commercial_suppressed, first_byte_at, scanner_started_at,
          template_displayed_at, data_region)
       VALUES (gen_random_uuid(), $1, $2, $3, now(), $4,
               $5, $6, $7, $8::jsonb, $9, $10,
               $11, $12, $13, $14,
               $15, $16)
       RETURNING id`,
      [
        AUDIT_ID,
        Buffer.from('feedface', 'hex'),
        Buffer.from('deadbeef', 'hex'),
        'URGENT',
        // R3: the seeded rule and set, so FOREIGN KEY (rule_id, rule_version)
        // is actually exercised rather than skipped by passing nulls.
        '88888888-8888-8888-8888-888888888801',
        1,
        '77777777-7777-7777-7777-777777777777',
        JSON.stringify({ matchedRuleIds: ['88888888-8888-8888-8888-888888888801'] }),
        // R2: the generic escalation template is gone. red_flag_event's
        // FOREIGN KEY (template_id, template_version) means this id has to
        // be a template that actually exists — and under the §4.3.3 ladder a
        // URGENT row with no URGENT template resolves UPWARD to the seeded
        // CRITICAL one (db/999), never down to WARNING.
        '44444444-4444-4444-4444-444444444402',
        1,
        'ESCALATED',
        true,
        new Date(Date.now() - 5000).toISOString(),
        new Date(Date.now() - 4000).toISOString(),
        null,
        'IN',
      ],
    );
    firstRedFlagEventId = rows[0].id;
    return `insert ok, id=${firstRedFlagEventId}`;
  });

  await check('safety.red_flag_event: c_event_at_least_monitor REJECTS a NORMAL-severity row', async () => {
    let threw = false;
    try {
      await pool.query(
        `INSERT INTO safety.red_flag_event
           (id, audit_id, subject_pseudonym, session_pseudonym, occurred_at, severity,
            trigger_detail, action_taken, commercial_suppressed, first_byte_at, data_region)
         VALUES (gen_random_uuid(), $1, $2, $3, now(), 'NORMAL', '{}'::jsonb, 'NONE', true, now(), 'IN')`,
        [AUDIT_ID, Buffer.from('feedface', 'hex'), Buffer.from('deadbeef', 'hex')],
      );
    } catch (err) {
      threw = /c_event_at_least_monitor/.test(err.message) || err.code === '23514';
      if (!threw) throw err;
    }
    if (!threw) throw new Error('expected c_event_at_least_monitor to reject a NORMAL-severity row, but it was accepted');
    return 'DB constraint correctly rejected a NORMAL-severity event';
  });

  await check('safety.red_flag_event: c_urgent_needs_template REJECTS URGENT with no template_id', async () => {
    let threw = false;
    try {
      await pool.query(
        `INSERT INTO safety.red_flag_event
           (id, audit_id, subject_pseudonym, session_pseudonym, occurred_at, severity,
            trigger_detail, action_taken, commercial_suppressed, first_byte_at, data_region)
         VALUES (gen_random_uuid(), $1, $2, $3, now(), 'URGENT', '{}'::jsonb, 'ESCALATED', true, now(), 'IN')`,
        [AUDIT_ID, Buffer.from('feedface', 'hex'), Buffer.from('deadbeef', 'hex')],
      );
    } catch (err) {
      threw = /c_urgent_needs_template/.test(err.message) || err.code === '23514';
      if (!threw) throw err;
    }
    if (!threw) throw new Error('expected c_urgent_needs_template to reject a template-less URGENT row, but it was accepted');
    return 'DB constraint correctly rejected a template-less URGENT event';
  });

  // ---- safety.session_severity_floor (§4.0.8) ------------------------------
  const SESSION_PSEUDO = Buffer.from('deadbeef', 'hex'); // same session_pseudonym the URGENT event above used

  await check('redFlagEngine: session_severity_floor upsert (raise) mirrors recordRedFlagEvent\'s own logic', async () => {
    await pool.query(
      `INSERT INTO safety.session_severity_floor
         (session_pseudonym, floor_severity, set_by_event_id, set_at, cleared_at, cleared_by)
       VALUES ($1, $2, $3, now(), NULL, NULL)
       ON CONFLICT (session_pseudonym) DO UPDATE SET
         floor_severity = EXCLUDED.floor_severity, set_by_event_id = EXCLUDED.set_by_event_id,
         set_at = now(), cleared_at = NULL, cleared_by = NULL
       WHERE safety.session_severity_floor.cleared_at IS NOT NULL
          OR EXCLUDED.floor_severity > safety.session_severity_floor.floor_severity`,
      [SESSION_PSEUDO, 'URGENT', firstRedFlagEventId],
    );
    const { rows } = await pool.query(`SELECT floor_severity FROM safety.session_severity_floor WHERE session_pseudonym = $1`, [SESSION_PSEUDO]);
    if (rows.length !== 1 || rows[0].floor_severity !== 'URGENT') throw new Error(`expected floor_severity=URGENT, got ${JSON.stringify(rows)}`);
    return 'floor set to URGENT';
  });

  await check('safety.session_severity_floor: a LOWER severity does not lower an active floor (sticky upward)', async () => {
    await pool.query(
      `INSERT INTO safety.session_severity_floor
         (session_pseudonym, floor_severity, set_by_event_id, set_at, cleared_at, cleared_by)
       VALUES ($1, $2, $3, now(), NULL, NULL)
       ON CONFLICT (session_pseudonym) DO UPDATE SET
         floor_severity = EXCLUDED.floor_severity, set_by_event_id = EXCLUDED.set_by_event_id,
         set_at = now(), cleared_at = NULL, cleared_by = NULL
       WHERE safety.session_severity_floor.cleared_at IS NOT NULL
          OR EXCLUDED.floor_severity > safety.session_severity_floor.floor_severity`,
      [SESSION_PSEUDO, 'MONITOR', firstRedFlagEventId],
    );
    const { rows } = await pool.query(`SELECT floor_severity FROM safety.session_severity_floor WHERE session_pseudonym = $1`, [SESSION_PSEUDO]);
    if (rows[0].floor_severity !== 'URGENT') throw new Error(`expected floor to stay at URGENT, got ${rows[0].floor_severity}`);
    return 'floor correctly stayed at URGENT despite a MONITOR-severity event';
  });

  await check('safety.session_severity_floor: c_clear_attributed REJECTS an unattributed clear', async () => {
    let threw = false;
    try {
      await pool.query(`UPDATE safety.session_severity_floor SET cleared_at = now() WHERE session_pseudonym = $1`, [SESSION_PSEUDO]);
    } catch (err) {
      threw = /c_clear_attributed/.test(err.message) || err.code === '23514';
      if (!threw) throw err;
    }
    if (!threw) throw new Error('expected c_clear_attributed to reject an unattributed clear, but it was accepted');
    return 'DB constraint correctly rejected an unattributed clear';
  });

  await check('redFlagEngine.clearSessionSeverityFloor / a fresh event after clearing restarts the floor at its own (lower) severity', async () => {
    await pool.query(`UPDATE safety.session_severity_floor SET cleared_at = now(), cleared_by = $2 WHERE session_pseudonym = $1`, [SESSION_PSEUDO, USER_ID]);
    await pool.query(
      `INSERT INTO safety.session_severity_floor
         (session_pseudonym, floor_severity, set_by_event_id, set_at, cleared_at, cleared_by)
       VALUES ($1, $2, $3, now(), NULL, NULL)
       ON CONFLICT (session_pseudonym) DO UPDATE SET
         floor_severity = EXCLUDED.floor_severity, set_by_event_id = EXCLUDED.set_by_event_id,
         set_at = now(), cleared_at = NULL, cleared_by = NULL
       WHERE safety.session_severity_floor.cleared_at IS NOT NULL
          OR EXCLUDED.floor_severity > safety.session_severity_floor.floor_severity`,
      [SESSION_PSEUDO, 'MONITOR', firstRedFlagEventId],
    );
    const { rows } = await pool.query(`SELECT floor_severity, cleared_at FROM safety.session_severity_floor WHERE session_pseudonym = $1`, [SESSION_PSEUDO]);
    if (rows[0].floor_severity !== 'MONITOR' || rows[0].cleared_at !== null) throw new Error(`expected a fresh MONITOR floor, got ${JSON.stringify(rows[0])}`);
    return 'a cleared floor was correctly restarted at the next event\'s (lower) severity';
  });

  // ---- side effect dispatcher --------------------------------------------
  await check('sideEffectDispatcher.enqueueJob INSERT', async () => {
    await pool.query(
      `INSERT INTO side_effect_job (id, kind, payload, data_region, enqueued_at, status)
       VALUES (gen_random_uuid(), $1, $2::jsonb, $3, now(), 'PENDING')`,
      ['CLINICIAN_REVIEW', JSON.stringify({ auditId: AUDIT_ID }), 'IN'],
    );
    return 'insert ok';
  });

  await pool.end();
  console.log(`\n${failures === 0 ? 'ALL CHECKS PASSED' : `${failures} CHECK(S) FAILED`}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error('smoke test crashed:', err);
  process.exit(1);
});
