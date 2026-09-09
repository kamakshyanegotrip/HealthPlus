#!/usr/bin/env node
// ============================================================================
// HealthPlus — GRANT / RLS contract check (register item R13)
// ============================================================================
//
// WHY THIS EXISTS
//
// Two of the eight bugs found in the first fortnight of September were GRANT
// gaps, and both were invisible to every test in the repository:
//
//   * db/010 never granted hp_app SELECT on safety.red_flag_rule_set, which
//     adopted_rule_set() reads with invoker's rights. The red-flag module
//     would have been permanently FAIL_CLOSED in production — correctly, and
//     inexplicably.
//   * migrations/027 granted UPDATE on three session_severity_floor columns
//     but not cleared_at/cleared_by. PostgreSQL checks column privileges at
//     PLAN time, so a missing column grant fails the whole statement, not
//     just the guarded column.
//
// R12 added grant assertions for safety.* only. R13 is the generalisation,
// and writing it immediately found a third class the first two were instances
// of: a privilege that CANNOT BE EXERCISED reads exactly like a privilege
// that can.
//
// A grant is only real if all three of these hold:
//
//   1. the role holds USAGE on the schema             (rule A)
//   2. no RLS policy silently denies it               (rule B)
//   3. something can actually BE that role            (rule C)
//
// Miss any one and `information_schema.role_table_grants` still shows the
// privilege. Every audit that reads the grant table alone — including R12's —
// will report a permission the database will refuse at runtime.
//
// WHAT IT FOUND ON ITS FIRST RUN
//
// See grant_contract_baseline.json. In short: hp_app and hp_reader are the
// only roles that can log in, and neither holds USAGE on `safety` or `obs`;
// redflag_role, alert_role, metrics_role and confirmation_ui_role hold the
// real grants but are NOLOGIN with no members, so nothing can ever be them.
// As built, no process can write a red_flag_event, a clinician_alert, an
// ai_call, a fabrication_block or a safety_metric_sample against the real
// schema. This is an R10 prerequisite nobody had listed — see HP-JOB-007.
//
// WHY IT DID NOT SURFACE EARLIER
//
// Every test in this repository, including the ones written this week to
// "execute against the real schema rather than reading it", connects as the
// owner. The owner bypasses RLS and holds every privilege, so none of the
// three conditions above was ever exercised. Executing against the real
// schema is necessary and was not sufficient: it also has to execute AS THE
// REAL ROLE. That is R13-roleci.
//
// THE BASELINE
//
// Same discipline as CI-3's query contract, and for the same reason: failing
// the build on all 47 findings today would block every PR until the
// connection model is decided, which is a call for a human to make. Each
// entry carries a reason and the item that closes it. The gate fails on:
//
//   1. a violation that is not baselined   -> a new one. Fix it.
//   2. a baselined violation now resolved  -> you fixed it. Remove the entry.
//   3. a baseline entry matching nothing   -> the object is gone. Remove it.
//
// Usage:
//   node migrations/test/grant_contract.mjs
//   node migrations/test/grant_contract.mjs --write-baseline
// ============================================================================
import pg from 'pg';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const BASELINE = join(process.cwd(), 'migrations/test/grant_contract_baseline.json');

const DATABASE_URL =
  process.env.DATABASE_URL ||
  `postgresql://${process.env.PGUSER || 'postgres'}:${process.env.PGPASSWORD || 'postgres'}` +
  `@${process.env.PGHOST || 'localhost'}:${process.env.PGPORT || 5432}/${process.env.PGDATABASE || 'healthplus'}`;

// Roles this contract governs. The owner is excluded on purpose: it holds
// everything and bypasses RLS, which is exactly why running tests as the
// owner proves nothing about any of these rules.
const APP_ROLES = `('hp_app','hp_reader','redflag_role','alert_role','metrics_role',
                    'dqe_role','erasure_role','reasoner_role','confirmation_ui_role')`;

/** The same list as an ARRAY literal, for rules that need `unnest` rather than `IN`. */
const APP_ROLES_ARRAY = `ARRAY${APP_ROLES.replace('(', '[').replace(/\)$/, ']')}`;

// Append-only by design: an audit or log row that can be updated or deleted
// is not an audit record. §2.3.4g, HP-RB-001, §3.13.1, §4.0.7.
const APPEND_ONLY = `('red_flag_log','response_audit_event','fabrication_block',
                      'abstention_event','ai_call','safety_metric_sample',
                      'attribute_access_log','response_audit')`;

// Reference and policy data: written by migrations and by governed processes,
// never by the application. §1.5.3's matrix, §4.3.1's templates, §6.5's
// registry, the emergency reference tables.
const REFERENCE = `('claim_policy','claim_kind_decay','alert_sla','alert_channel',
                    'safety_metric','region_registry','emergency_contact_reference',
                    'emergency_facility_reference','response_category_state',
                    'red_flag_rule','red_flag_rule_set','safety_template')`;

const RULES = [
  {
    id: 'A-schema-usage',
    title: 'A table grant is dead unless the role holds USAGE on the schema',
    why:
      'information_schema.role_table_grants shows the privilege either way. Without ' +
      'schema USAGE every statement fails with "permission denied for schema", and an ' +
      'audit that reads the grant table reports access the database will refuse.',
    sql: `
      SELECT g.grantee AS role, g.table_schema||'.'||g.table_name AS object,
             g.privilege_type AS detail
        FROM information_schema.role_table_grants g
       WHERE g.grantee IN ${APP_ROLES}
         AND NOT has_schema_privilege(g.grantee, g.table_schema, 'USAGE')`,
  },
  {
    id: 'B-rls-policy',
    title: 'A grant on an RLS-enabled table needs a policy permitting that command',
    why:
      'RLS enabled with no matching policy is deny-all for every non-owner role. ' +
      'The grant is visible, the access is not. This is fail-closed and therefore ' +
      'safe, but it is silent — the module simply never writes, exactly as in the ' +
      'adopted_rule_set() bug.',
    sql: `
      WITH g AS (
        SELECT grantee, table_schema, table_name, privilege_type
          FROM information_schema.role_table_grants
         WHERE grantee IN ${APP_ROLES}
           AND privilege_type IN ('SELECT','INSERT','UPDATE','DELETE')
      ), t AS (
        SELECT c.oid, n.nspname, c.relname
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relkind = 'r' AND c.relrowsecurity
      )
      SELECT g.grantee AS role, t.nspname||'.'||t.relname AS object,
             g.privilege_type AS detail
        FROM g JOIN t ON t.nspname = g.table_schema AND t.relname = g.table_name
       WHERE NOT EXISTS (
         SELECT 1 FROM pg_policy p
          WHERE p.polrelid = t.oid
            AND (p.polcmd = '*' OR p.polcmd = CASE g.privilege_type
                  WHEN 'SELECT' THEN 'r' WHEN 'INSERT' THEN 'a'
                  WHEN 'UPDATE' THEN 'w' WHEN 'DELETE' THEN 'd' END)
            AND (p.polroles = '{0}' OR g.grantee::regrole::oid = ANY(p.polroles)))`,
  },
  {
    id: 'C-role-reachable',
    title: 'A role holding privileges must be reachable — it can log in, or something is a member of it',
    why:
      'A NOLOGIN role with no members is a privilege set no process can ever assume. ' +
      'Its grants describe an intended security model rather than an operating one, ' +
      'and reading them gives a false picture of what the running system can do.',
    sql: `
      SELECT DISTINCT g.grantee AS role, '(role)'::text AS object,
             'NOLOGIN and no members'::text AS detail
        FROM information_schema.role_table_grants g
        JOIN pg_roles r ON r.rolname = g.grantee
       WHERE g.grantee IN ${APP_ROLES}
         AND NOT r.rolcanlogin
         AND NOT EXISTS (SELECT 1 FROM pg_auth_members am WHERE am.roleid = r.oid)`,
  },
  {
    id: 'D-append-only',
    title: 'Append-only tables grant no UPDATE, DELETE or TRUNCATE to any application role',
    why:
      'HP-RB-001: an audit record that can be rewritten is not an audit record. ' +
      'C-30 replaced a mutable response_audit with an append-only event log ' +
      'precisely because the original design could not hold both properties.',
    sql: `
      SELECT grantee AS role, table_schema||'.'||table_name AS object,
             privilege_type AS detail
        FROM information_schema.role_table_grants
       WHERE grantee IN ${APP_ROLES}
         AND privilege_type IN ('UPDATE','DELETE','TRUNCATE')
         AND table_name IN ${APPEND_ONLY}`,
  },
  {
    id: 'E-reference-readonly',
    title: 'Reference and policy tables grant no writes to any application role',
    why:
      'The §1.5.3 matrix, §4.3.1 templates, §6.5 registry and the §3.12.1 emergency ' +
      'reference tables are governed data. An application role that can write them ' +
      'can rewrite the policy it is being judged against.',
    sql: `
      SELECT grantee AS role, table_schema||'.'||table_name AS object,
             privilege_type AS detail
        FROM information_schema.role_table_grants
       WHERE grantee IN ${APP_ROLES}
         AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE')
         AND table_name IN ${REFERENCE}`,
  },
  {
    id: 'F-no-delete',
    title: 'No application role holds DELETE or TRUNCATE anywhere',
    why:
      'ADR-003 §2.4: erasure is crypto-shredding — destroying the subject key — not ' +
      'row deletion. A DELETE grant is both an erasure path that leaves the audit ' +
      'trail inconsistent and a way to remove evidence of what happened.',
    sql: `
      SELECT grantee AS role, table_schema||'.'||table_name AS object,
             privilege_type AS detail
        FROM information_schema.role_table_grants
       WHERE grantee IN ${APP_ROLES}
         AND privilege_type IN ('DELETE','TRUNCATE')`,
  },
  {
    id: 'H-trigger-executable',
    title: 'A writer must be able to execute every trigger its write fires',
    why:
      'The fourth way a grant can be real and still not work, after A, B and C. ' +
      'An INVOKER trigger function runs with the caller\'s privileges, so a write ' +
      'that passes the GRANT and the RLS policy can still fail inside a trigger that ' +
      'reads a table the caller cannot see. Found the hard way: RF6\'s own backstop, ' +
      'safety.event_requires_alert(), read safety.clinician_alert as INVOKER — the ' +
      'check meant to guarantee an emergency is never silently unalerted was blocking ' +
      'every emergency from being recorded at all. Fixed in migration 031 §2b.',
    sql: `
      WITH writers AS (
        SELECT DISTINCT g.grantee AS role, c.oid AS tbl
          FROM information_schema.role_table_grants g
          JOIN pg_class c ON c.relname = g.table_name
          JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = g.table_schema
         WHERE g.grantee IN ${APP_ROLES}
           AND g.privilege_type IN ('INSERT','UPDATE','DELETE')
      ), trig AS (
        SELECT w.role, p.proname, p.prosrc, n.nspname||'.'||c.relname AS on_table
          FROM writers w
          JOIN pg_trigger t ON t.tgrelid = w.tbl AND NOT t.tgisinternal
          JOIN pg_proc p ON p.oid = t.tgfoid
          JOIN pg_class c ON c.oid = w.tbl
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE NOT p.prosecdef
      ), refs AS (
        SELECT trig.role, trig.proname, trig.on_table,
               (regexp_matches(trig.prosrc,
                 '(safety|obs|principal|evidence|domain|commercial)\\.([a-zA-Z_][a-zA-Z0-9_]*)',
                 'g'))[1] AS sch,
               (regexp_matches(trig.prosrc,
                 '(safety|obs|principal|evidence|domain|commercial)\\.([a-zA-Z_][a-zA-Z0-9_]*)',
                 'g'))[2] AS rel
          FROM trig
      )
      SELECT DISTINCT refs.role AS role,
             refs.on_table||' -> '||refs.proname||'()' AS object,
             'cannot read '||refs.sch||'.'||refs.rel AS detail
        FROM refs
        JOIN pg_class rc ON rc.relname = refs.rel
        JOIN pg_namespace rn ON rn.oid = rc.relnamespace AND rn.nspname = refs.sch
       WHERE rc.relkind IN ('r','v','m')
         AND NOT has_table_privilege(refs.role, rc.oid, 'SELECT')`,
  },
  {
    id: 'K-function-schema-usage',
    title: 'An EXECUTE grant is dead unless the role holds USAGE on the function\'s schema',
    why:
      'Rule A\'s twin, and it went unwritten for four migrations while a live example ' +
      'sat in the schema. hp_app holds EXECUTE on safety.raise_alert and ' +
      'safety.acknowledge_alert and has USAGE on `public` only, so both calls fail with ' +
      '"permission denied for schema safety" — the grants have been decoration since ' +
      'they were written. This matters more now than it did: migration 039 makes ' +
      'SECURITY DEFINER functions the request path\'s ONLY way to write obs, so an ' +
      'EXECUTE grant that cannot be reached is no longer an unused convenience, it is ' +
      'the whole access path.',
    sql: `
      SELECT DISTINCT g.grantee AS role,
             g.routine_schema||'.'||g.routine_name AS object,
             'EXECUTE granted, no USAGE on schema '||g.routine_schema AS detail
        FROM information_schema.role_routine_grants g
       WHERE g.grantee IN ${APP_ROLES}
         AND g.privilege_type = 'EXECUTE'
         AND NOT has_schema_privilege(g.grantee, g.routine_schema, 'USAGE')`,
  },
  {
    id: 'M-policy-with-no-grant',
    title: 'A row-level policy is inert unless some application role can reach the table',
    why:
      'Rule B\'s exact mirror, and the half that was missing. B catches a GRANT with no ' +
      'policy behind it — a privilege that reaches a default-deny table. This catches a ' +
      'POLICY with no grant in front of it: a row boundary, correctly written and scoped, ' +
      'guarding a table no application role holds a single privilege on. It never ' +
      'evaluates, because nothing ever reaches the table for it to filter. ' +
      'Both shapes read as "configured" to anyone skimming the schema, and neither does ' +
      'anything. ' +
      'HP-SR-001 recorded the symptom without the cause: "§4.6\'s flagged-high-risk-profile ' +
      'trigger is already built in the schema — principal.patient_risk_flag — and nothing ' +
      'reads it." Nothing read it because nothing COULD. p_prf_own has been sitting on that ' +
      'table since migration 018 with USING (subject_id = app.current_user_id()) — the right ' +
      'predicate, waiting for a reader that no migration ever granted. §2.4.3\'s minor gate ' +
      'was reading a stub column instead, defaulted to false, for the entire life of the ' +
      'project. Migration 041 grants the read; this rule is what would have found it. ' +
      'ONE ENTRY IS BASELINED AND IS NOT A DEFECT: principal.patient_attribute keeps p_pa_own ' +
      'with no grant deliberately, because the request path must read attributes only through ' +
      'principal.fetch_attribute_envelope — which writes the §3.8.2 access log on every read ' +
      'and enforces the inferred/CONFIRMATION_UI rule. The policy is the backstop for the day ' +
      'somebody adds a direct grant, so it is dormant by design rather than by oversight.',
    sql: `
      WITH app_roles AS (
        SELECT unnest(${APP_ROLES_ARRAY}) AS r
      ),
      policied AS (
        SELECT c.oid, n.nspname, c.relname,
               string_agg(DISTINCT p.polname, ', ') AS pols
          FROM pg_policy p
          JOIN pg_class c ON c.oid = p.polrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE c.relrowsecurity
           AND n.nspname NOT IN ('pg_catalog','information_schema')
         GROUP BY 1,2,3
      )
      SELECT 'PUBLIC'::text AS role,
             t.nspname||'.'||t.relname AS object,
             'RLS policy '||t.pols||' exists; no application role holds any privilege' AS detail
        FROM policied t
       WHERE NOT EXISTS (
         SELECT 1
           FROM app_roles a, unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE']) pv
          WHERE has_table_privilege(a.r, t.oid, pv))`,
  },
  {
    id: 'L-definer-not-public',
    title: 'No SECURITY DEFINER function grants EXECUTE to PUBLIC',
    why:
      'Rule K asks whether an EXECUTE grant can be REACHED. This asks the opposite and ' +
      'more dangerous question: whether a function that named a role is in fact callable ' +
      'by every role. A function\'s DEFAULT ACL is EXECUTE TO PUBLIC, so a migration that ' +
      'writes GRANT EXECUTE TO reasoner_role without the REVOKE FROM PUBLIC that must ' +
      'precede it has NARROWED NOTHING — it reads as a restriction and is an addition. ' +
      'Eleven functions were in that state when this rule was written, nine of them with ' +
      'an explicit ACL that still carried the PUBLIC entry beside the role somebody meant ' +
      'to name. ' +
      'A SECURITY DEFINER function runs as its owner, so this is not a small over-grant: ' +
      'it hands every role the owner\'s reach through that function. It sat latent because ' +
      'PUBLIC EXECUTE on a function in `principal` does nothing to a role without USAGE on ' +
      '`principal` — rule K from the other side — and migrations 037 and 039 then granted ' +
      'exactly that USAGE to dqe_role and hp_app for unrelated, correct reasons. ' +
      'What it allowed, proven by execution against 001-039 and not by reading: ' +
      '`SET SESSION AUTHORIZATION dqe_role; SELECT principal.erase_subject(...)` ran, and ' +
      'irreversibly crypto-shredded a data subject. The ingestion job\'s role could erase ' +
      'any person in the database. Migration 040 is the cleanup; this rule is the fix. ' +
      'TRIGGER FUNCTIONS ARE INCLUDED, though their PUBLIC grant is inert — both checked ' +
      'against a running database: a trigger function cannot be called directly at all ' +
      '("trigger functions can only be called as triggers"), and revoking PUBLIC does not ' +
      'stop it firing for a non-owner. Including them costs nothing and makes the ' +
      'invariant exceptionless, and a rule with a carve-out is a rule nobody applies.',
    sql: `
      SELECT 'PUBLIC'::text AS role,
             n.nspname||'.'||p.proname AS object,
             'SECURITY DEFINER, EXECUTE held by PUBLIC (runs as '||
               pg_get_userbyid(p.proowner)||')' AS detail
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE p.prosecdef
         AND n.nspname NOT IN ('pg_catalog','information_schema')
         AND has_function_privilege('public', p.oid, 'EXECUTE')`,
  },
  {
    id: 'G-public-holds-nothing',
    title: 'PUBLIC holds no table privilege in any application schema',
    why:
      'A privilege granted to PUBLIC is held by every role that will ever exist, ' +
      'including ones added later for unrelated reasons. It is the one grant nobody ' +
      'audits because it names no role.',
    sql: `
      SELECT 'PUBLIC'::text AS role, table_schema||'.'||table_name AS object,
             privilege_type AS detail
        FROM information_schema.role_table_grants
       WHERE grantee = 'PUBLIC'
         AND table_schema NOT IN ('pg_catalog','information_schema')`,
  },
  {
    id: 'N-view-runs-as-owner',
    title: 'A view honours the row-level security of the tables it reads',
    why:
      'A view without `security_invoker` runs as ITS OWNER, and the owner of every view ' +
      'here is the owner of the tables underneath it — so the view BYPASSES every policy ' +
      'on its base tables. Rules B, I and M all reason about a policy existing and being ' +
      'reachable. None of them asks whether the policy applies on the path the reader ' +
      'actually takes, and for the metrics and alert roles that path is a view. ' +
      'Measured before migration 044 fixed it: two obs.fabrication_block rows, one IN and ' +
      'one ZZ, read as metrics_role with app.data_region = IN — a direct table read ' +
      'returned 1 row and obs.v_metric_block_rate returned 2. p_fb_region_scoped and ' +
      'p_rqi_region_scoped had never applied to anything that reads them. ' +
      'This rule is standing rather than a one-time assertion in 044 because 044 can only ' +
      'see the views that existed when it ran; the next migration to add one would ' +
      'reintroduce the leak silently. ' +
      'A view over nothing but reference data is still reported. Making it run as its ' +
      'caller costs nothing there, and deciding case by case is how the exception list ' +
      'becomes the rule.',
    sql: `
      SELECT coalesce(pg_get_userbyid(c.relowner), '?')::text AS role,
             n.nspname || '.' || c.relname AS object,
             'view runs as its owner; RLS on its base tables does not apply'::text AS detail
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE c.relkind = 'v'
         AND n.nspname NOT IN ('pg_catalog','information_schema')
         AND NOT coalesce(array_to_string(c.reloptions, ',') LIKE '%security_invoker=true%', false)`,
  },
  {
    id: 'I-pseudonym-readable-unbounded',
    title: 'A role that can read a table of pseudonyms reads it through a row boundary',
    why:
      'Rules A–H all start from a GRANT and ask whether it can be EXERCISED. None asks ' +
      'the opposite question — whether a grant that works has any row boundary behind ' +
      'it — and a table with RLS switched off produces no finding anywhere, because ' +
      'there is no policy to be missing. Rule B covers grant + RLS on + no policy; this ' +
      'covers grant + RLS off, and together they close the grid. ' +
      'That gap is how SEC-1 sat here since migration 012: safety.session_severity_floor ' +
      'holds a per-session §4.0.8 safety floor, is derived from the region-scoped ' +
      'red_flag_event, and had no data_region, no RLS and no policy — so an IN-region ' +
      'role could read, raise and clear an EU session\'s floor. All three proven by ' +
      'execution, and all three fixed in migration 032. ' +
      'A pseudonym is a person. HP-ADR-004 §2 / ADR-003 §2.1 say a region cannot see ' +
      'another region\'s people. A policy whose USING is literally `true` counts as no ' +
      'boundary, because it is one — safety.red_flag_rule and emergency_facility_reference ' +
      'are reference data and correctly have such policies, but they hold no pseudonym ' +
      'and so never reach this rule. ' +
      'A table nothing can read is NOT reported: an absent grant is a boundary too, and ' +
      'the moment a grant appears this rule fires.',
    sql: `
      WITH holds_pseudonym AS (
        SELECT c.oid, n.nspname, c.relname, c.relrowsecurity
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
         WHERE c.relkind = 'r'
           AND n.nspname IN ('safety','obs','principal','evidence','domain','public')
           AND a.attname IN ('subject_pseudonym','session_pseudonym','subject_id','subject_ref')
         GROUP BY c.oid, n.nspname, c.relname, c.relrowsecurity
      ), readers AS (
        SELECT DISTINCT grantee, table_schema, table_name
          FROM information_schema.role_table_grants
         WHERE grantee IN ${APP_ROLES} AND privilege_type = 'SELECT'
      )
      SELECT r.grantee AS role,
             t.nspname||'.'||t.relname AS object,
             CASE WHEN NOT t.relrowsecurity
                  THEN 'can SELECT; RLS is off, so every row is visible'
                  ELSE 'can SELECT through a policy whose USING is true' END AS detail
        FROM holds_pseudonym t
        JOIN readers r ON r.table_schema = t.nspname AND r.table_name = t.relname
       WHERE NOT t.relrowsecurity
          OR EXISTS (
               SELECT 1 FROM pg_policy p
                WHERE p.polrelid = t.oid
                  AND p.polpermissive
                  AND p.polcmd IN ('r','*')
                  AND pg_get_expr(p.polqual, p.polrelid) = 'true'
                  AND (p.polroles = '{0}' OR r.grantee::regrole::oid = ANY(p.polroles)))`,
  },
];

const key = (ruleId, r) => `${ruleId}|${r.role}|${r.object}|${r.detail}`;

async function main() {
  const pool = new pg.Pool({ connectionString: DATABASE_URL, max: 2 });

  // Preflight. Without it, an unreachable database produces zero violations
  // for every rule and the gate reports a perfectly clean grant model — a
  // check that passes hardest when it is not running. CI-3 had this exact
  // hole and it was closed the same way.
  let client;
  try {
    client = await pool.connect();
    await client.query('SELECT 1');
  } catch (err) {
    console.error('Cannot reach a database to audit.');
    console.error(String(err.message).split('\n')[0]);
    console.error('\nThis check reads pg_policy, pg_roles and information_schema against a live');
    console.error('schema; it cannot run without one. Point DATABASE_URL or PGHOST/PGUSER/PGDATABASE');
    console.error('at a database with migrations applied.');
    process.exit(1);
  }

  // INSTRUMENT SELF-CHECK, and it is here because this gate just failed it.
  //
  // The preflight above proves a database ANSWERS. It does not prove the
  // database has a schema, and every rule in this file is a query that returns
  // zero rows against an empty one — so an empty database produces eleven
  // `clean` lines and the words GRANT CONTRACT OK. That is not a hypothetical:
  // running this against a database whose migration run had silently failed
  // printed exactly that, and only the baseline-orphan check (four entries "no
  // longer violating") gave the game away. A check that passes hardest when it
  // is not really running is the failure mode CI-3 had and role_contract.mjs
  // already carries a self-check for; this is grant_contract's.
  //
  // The threshold is deliberately low and structural rather than a count that
  // has to be maintained: `principal.subject_key` exists from the first
  // migration, and SECURITY DEFINER functions are what rules K and L are about.
  const { rows: [health] } = await client.query(`
    SELECT to_regclass('principal.subject_key') IS NOT NULL AS has_core,
           (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE p.prosecdef AND n.nspname NOT IN ('pg_catalog','information_schema')) AS definers`);
  if (!health.has_core || Number(health.definers) === 0) {
    console.error('The database is reachable but does not look migrated.');
    console.error(`  principal.subject_key present: ${health.has_core}`);
    console.error(`  SECURITY DEFINER functions:    ${health.definers}`);
    console.error('\nEvery rule below returns zero rows against an empty schema, so running');
    console.error('anyway would report a perfectly clean grant model. Apply the migrations first.');
    process.exit(1);
  }

  const found = [];
  for (const rule of RULES) {
    const { rows } = await client.query(rule.sql);
    for (const r of rows) found.push({ ruleId: rule.id, ...r, k: key(rule.id, r) });
  }

  if (process.argv.includes('--write-baseline')) {
    const entries = found.map((f) => ({
      key: f.k, rule: f.ruleId, role: f.role, object: f.object, detail: f.detail,
      why: 'TODO: state why this is tolerated today',
      item: 'TODO: the register item that closes it',
    }));
    writeFileSync(BASELINE, JSON.stringify({
      note: 'See grant_contract.mjs. Entries may only be REMOVED, never edited to hide a regression.',
      entries,
    }, null, 2) + '\n');
    console.log(`wrote ${entries.length} baseline entries to ${BASELINE}`);
    await client.release(); await pool.end();
    process.exit(0);
  }

  let baseline = { entries: [] };
  try { baseline = JSON.parse(readFileSync(BASELINE, 'utf8')); } catch { /* first run */ }

  const dupes = baseline.entries.map((e) => e.key)
    .filter((k, i, all) => all.indexOf(k) !== i);
  if (dupes.length) {
    console.error(`Baseline has duplicate keys: ${[...new Set(dupes)].join(', ')}`);
    process.exit(1);
  }
  const known = new Set(baseline.entries.map((e) => e.key));
  const foundKeys = new Set(found.map((f) => f.k));

  const unexpected = found.filter((f) => !known.has(f.k));
  const orphans = baseline.entries.filter((e) => !foundKeys.has(e.key));

  const byRule = new Map();
  for (const f of found) byRule.set(f.ruleId, (byRule.get(f.ruleId) || 0) + 1);

  console.log(`Grant contract — ${RULES.length} rules checked against this schema.\n`);
  for (const rule of RULES) {
    const n = byRule.get(rule.id) || 0;
    const mark = n === 0 ? 'clean' : `${n} known`;
    console.log(`  ${rule.id.padEnd(24)} ${mark}`);
  }
  console.log(`\nbaselined: ${known.size}   new: ${unexpected.length}   resolved-but-still-baselined: ${orphans.length}`);

  if (unexpected.length) {
    console.error(`\n${unexpected.length} GRANT/RLS VIOLATION(S) NOT IN THE BASELINE:\n`);
    for (const f of unexpected) {
      const rule = RULES.find((r) => r.id === f.ruleId);
      console.error(`  [${f.ruleId}] ${f.role} -> ${f.object} (${f.detail})`);
      console.error(`     ${rule.title}`);
    }
    console.error('\nIf this is a genuine, known divergence rather than a bug, add it to');
    console.error(`${BASELINE} with a reason and the register item that will close it.`);
  }

  if (orphans.length) {
    console.error(`\n${orphans.length} BASELINE ENTRY(S) NO LONGER VIOLATE. Remove them:\n`);
    for (const e of orphans) console.error(`  [${e.rule}] ${e.role} -> ${e.object} (${e.detail})`);
    console.error('\nThe baseline may only shrink. A resolved entry left behind would excuse');
    console.error('the next real regression at that spot.');
  }

  await client.release();
  await pool.end();
  if (unexpected.length || orphans.length) process.exit(1);
  console.log('\nGRANT CONTRACT OK.');
  process.exit(0);
}

main().catch(async (err) => {
  console.error('grant_contract: fatal:', err);
  process.exit(1);
});
