# Stub schema vs. real migrations — an honest catalog

GAP: "Stub schema vs real migrations — local Postgres is a reconstruction from docs, not the project's committed migrations."

That's correct, and it still can't be fully resolved even now that this job has been pushed to a real repo (`github.com/kamakshyanegotrip/HealthPlus`, this job under `chat-pipeline/`): the repo's other HealthPlus job present there so far (`HP-OIR-002`, `extractClaimsFromProviderSubmission`, at the repo root) is itself, by its own README, a design/code-complete deliverable that has "not yet been run against a real Postgres instance" — there is still no `migrations/` folder anywhere in this repo to diff against. What follows is the honest part that *can* be done without that access — a table of every object in `db/000_stub_upstream.sql` / `db/010_chat_pipeline_support.sql` / `db/020_rls.sql`, marked by how confident this repo can be that it matches the real, committed schema, plus the exact reconciliation steps to run once someone has the real migrations to diff against — wherever they end up living.

**Related, already-done work:** a different job in this project, `claude/HP-JOB-002_Migration_Numbering_Ledger.md`, already reconciled real migration *numbers* 001–030c across HP-SCHEMA-001, HP-RB-001, HP-DQE-001, HP-JOB-001, and HP-JOB-002 — read that first if the question is "what migration number does X belong at." This document is narrower and different: it's about whether the *column shapes* this chat-pipeline job (HP-JOB-003) invented match whatever those real migrations actually contain, which the Ledger doesn't attempt (it works from migration numbers named in docs, not from re-deriving column lists). Nothing here was cross-checked against the Ledger's numbering — the two documents were built independently and should both be consulted, not treated as the same reconciliation pass.

## Confidence tiers

- **SOURCED** — the SQL comment cites a specific project doc and says "quoted verbatim" (or equivalent). High confidence the *shape* is right; the *migration number* it belongs at is the Ledger's job, not this table's.
- **DERIVED** — built by reasoning from a real, cited Charter/ADR clause, but not copied from an already-written CREATE statement in any doc. Medium confidence — the intent is real, the exact column list is this job's own invention.
- **STAND-IN** — explicitly invented because no committed migration exists yet for this table at all (HP-SEC-001 §2 set this precedent first; this job followed it). Low confidence by design — these are placeholders, not guesses at the real shape.

| Object | Tier | Source | Notes |
|---|---|---|---|
| `public.region_registry` | DERIVED | HP-ADR-003/HP-ADR-004 (region topology) | Ledger's migration 021 covers "region + `residency_admission`" — likely overlaps, not diffed |
| `app_user` | DERIVED | HP-SEC-001 / Migration Pack identity spine | Real table almost certainly has more columns (created_at, auth linkage, etc.) — this stub has only `id`, `data_region` |
| `evidence.evidence_source` | SOURCED | Phase_1.1_Migration_Pack_ADR-003 §1.3, HP-SCHEMA-001 | |
| `evidence.claim` | SOURCED | same | `domain_table` column is explicitly marked STAND-IN inline (a name, not an FK, until the real domain tables exist) |
| `evidence.claim_source` | SOURCED | same | |
| `evidence.claim_policy` | SOURCED | same | Ledger's migration 022 mentions a "225-row `claim_policy` matrix" — this stub does NOT seed 225 rows, only what `db/999`'s smoke-test scenarios need |
| `safety.response_category_state` | SOURCED | HP-SCHEMA-001 Annex A Extension, quoted verbatim | |
| `evidence.policy_for()` | SOURCED | same | |
| `obs.ai_call` | SOURCED | HP-SCHEMA-001 Annex A Extension migration 005, quoted verbatim | |
| `obs.fabrication_block` | SOURCED | same | |
| `response_audit_event`, `audit_event_chain()`, `forbid_mutation()` | SOURCED | HP-RB-001 §3–§5, quoted verbatim | This is the C-30 event-sourcing correction — Ledger's migration 003a |
| `response_audit` | DERIVED | merges Charter Annex A.5's CHECK constraints with the RB-001 projection shape | The `c_min_conf`/`c_category_c_disabled_v1` constraints are Annex A.5; nothing in the docs read for this job showed a single already-written `CREATE TABLE response_audit` to copy verbatim |
| `response_content` | DERIVED | AEAD-encrypted content column referenced across multiple docs | No `subject_key` FK yet — noted inline in `db/000` |
| `safety.red_flag_rule`, `safety.safety_template` | SOURCED | HP-SCHEMA-001 Annex A Extension migration 012/013, quoted verbatim | |
| `safety.red_flag_event` | SOURCED (spec) / **NEW (migration)** | HP-SCHEMA-001 Annex A Extension, quoted verbatim, "immediately after" red_flag_rule/safety_template | The §4.0.7 *requirement* is sourced; the actual `CREATE TABLE` was written by THIS job (Turn 5 of this build) — it has no migration number in the Ledger at all (030c is the Ledger's highest). If/when this repo's schema is reconciled with a real one, this table likely needs a genuinely new migration number, not just a rename |
| `safety.session_severity_floor` | SOURCED (spec) / **NEW (migration)** | HP-SCHEMA-001 Annex A Extension, "sticky upward until a clinician or a rule clears them" | Same caveat as `red_flag_event` — the §4.0.8 spec is real, the table is this job's own new addition, not yet in the Ledger |
| `obs.model_pricing` | DERIVED | reasoned from Annex A.7's "tier_default lives in a table, not code" pattern | Not a quoted-verbatim object anywhere — this job's own invention to close a gap `src/lib/pricing.ts` flagged |
| `subject_key` | STAND-IN | referenced by multiple docs, never defined with columns anywhere read | |
| `side_effect_job` | DERIVED | HP-ADR-001 §3.2's "Postgres-backed queueing" pattern, applied to post-response side effects | Producer-side table invented for this job; `worker/side-effect-worker.mjs` (this round's work) is the first consumer ever built for it |
| `patient_profile`, `patient_attribute` | STAND-IN | HP-SEC-001 §2, explicit precedent | HP-SEC-001's own words: "reconcile column names with the real migration when it lands" |
| `hospital_profile`, `hospital_cost` | STAND-IN | same | HP-JOB-001 (`Treatment_Cost_Maintenance.md`) separately built a much richer `hospital_cost_aggregate` / `domain.expected_cost_line` design for a DIFFERENT job track — **not reconciled with this stub at all**; if both jobs' schemas ever merge, `hospital_cost` here is almost certainly the wrong shape |
| `domain.guideline`, `domain.regulation`, `domain.nutrition_pattern`, `domain.exercise_guidance`, `domain.lifestyle_screening_tool`, `domain.clinical_metric_reference`, `domain.environment_reference` | STAND-IN | bare `id`-only placeholders | Exist only so `evidence.claim.domain_table` has something to point at for this job's own tests — carry no real columns at all |
| `auth.jwt()`, `auth.uid()` (db/020_rls.sql) | **N/A — dev/CI-only, never migrate to production** | mirrors Supabase's own runtime | A real Supabase project provides `auth.uid()`/`auth.jwt()` natively — this schema exists ONLY so RLS can be tested against a plain local Postgres. **Do not apply `db/020_rls.sql`'s `auth` schema creation to a real Supabase project** — apply only the `CREATE POLICY`/`hp_auth.*` statements there, against Supabase's real `auth` schema |
| `hp_auth.*`, RLS policies (db/020_rls.sql) | DERIVED | HP-SEC-001's design, independently re-derived for this job's own tables | HP-SEC-001's own `HP-SEC-001_RLS_Policies.sql` (sent directly to the user, not in this project's doc set) may already cover `patient_profile`/`hospital_profile`/`hospital_cost` with different policy names or a richer role model (scope-of-practice matching for clinicians, which this job's policies explicitly do NOT implement — see `db/020_rls.sql`'s own comment on why) |

## What this means practically

Every genuinely dangerous case — a table whose real shape differs from this stub in a way that would silently break something — is already flagged inline in the SQL with a `STAND-IN` or equivalent comment, and now also listed above. Nothing in `db/000`/`db/010`/`db/020` claims to be production-ready; the repeated point across this whole build (see README) is that this schema exists to let the *pipeline's own code* (route.ts, the pipeline/*.ts modules) be tested against real Postgres behavior — constraint violations, RLS enforcement, transaction ordering — not to be a candidate for what actually ships.

## The reconciliation procedure, once the real repo is connected

1. `ls migrations/ | sort` (or whatever the real folder is named) — cross-check against `HP-JOB-002_Migration_Numbering_Ledger.md`'s §4 check first, since that already answers the 027/028 gap question.
2. For every row marked **SOURCED** above, diff this stub's `CREATE TABLE` against the real migration file for that object — these should match closely; any difference is either a real migration change since the doc was written, or a transcription slip in this stub, either way worth a close look.
3. For every row marked **DERIVED**, treat the stub's column list as a first draft, not a source of truth — replace it with the real one wholesale.
4. For every row marked **STAND-IN**, the real migration (once it exists) simply replaces the stub table outright — expect `knowledgeLookup.ts`'s `DOMAIN_TABLE` map and `patientProfile.ts`'s query to both need column-name updates to match.
5. Re-run this repo's full test battery (`npm run typecheck && npm test && npm run eval && npm run db:migrate:stub && npm run test:db && npm run test:integration`) against the reconciled schema — that sequence is what actually catches a column-name mismatch, not a read-through (see this repo's own recurring lesson, e.g. `knowledgeLookup.ts`'s `domain_table` bug, caught only by `scripts/smoke-test.mjs` executing).

---

# Reconciliation performed — 2 September 2026 (J3-5)

The blocker this document opens with is gone. It said *"there is still no `migrations/` folder anywhere in this repo to diff against."* There was one the whole time — on a divergent, unpushed branch that this line of history could not see. Both halves were merged on `hp-integration` (`02783eb`), so the diff this document asks for could finally be run. It was, column by column, against `migrations/001–027`.

**Headline: 155 real tables, 20 stub tables, 18 in common. Six are identical. Twelve diverge, and four of those break running code.**

## A. Divergences that break code against the real schema

### A1. 🔴 `safety_template` has no `active` column — and the failure was silent

`loadSafetyTemplate()` queried `WHERE id = $1 AND active = true`. The real `safety.safety_template` (migration `001_003`) has columns `id, version, severity, jurisdiction, language, body, slots, approved_by, approved_at` — and **no `active`**. Only the stub in `db/010` has one.

Against the real schema that predicate raises `column "active" does not exist`. The function's `catch` swallowed it and returned the hard-coded fallback. So **every CRITICAL and EMERGENCY response would have rendered the unapproved hard-coded string instead of the clinician-authored template, and nothing anywhere would have said so.** The audit row recorded a `template_id` that was never actually displayed.

This is precisely the case this document's own §"What this means practically" was written to catch — *"a table whose real shape differs from this stub in a way that would silently break something"* — and it was not on the list, because the list was built without the real migrations to diff against.

**Fixed** (same commit as this note): the `active` predicate is dropped, the not-found and query-failed paths are separated, failures are logged loudly, and `loadSafetyTemplate()` now returns `{ body, source, failure }` so `route.ts` records `template_source: 'APPROVED_TEMPLATE' | 'HARDCODED_FALLBACK'` in the audit event. An emergency shown from the fallback is now distinguishable in the record from a real template.

### A2. 🔴 `red_flag_rule` carries no template in the real schema

Stub has `template_id` / `template_version` on the rule row; the real table does not. `matchDeterministicRules` SELECTs both, so against the real schema **the whole query fails** — which now degrades to `FAIL_CLOSED` rather than a fail-open (see `resolveAdoptionGate`), so it fails in the safe direction, but the engine cannot function against the shipping schema until template resolution is rewritten.

The real design resolves a template by `UNIQUE (severity, jurisdiction, language, version)`, not by a foreign key from the rule. **Not fixed** — this is a real rewrite of `resolveTemplateRequirement()` and needs the §4.3.3/§4.3.4 fallback ladder (exact → approved English → generic jurisdiction → next severity up) that the stub's shape cannot express.

### A3. 🔴 `red_flag_rule.pattern` is `jsonb`, not a regex string

Real: `pattern jsonb NOT NULL`. Stub: `pattern text -- Postgres regex`. The engine does `new RegExp(r.pattern, 'i').test(message)`.

These are two different rule-evaluation models. The real schema expects structured patterns — symptom-code sets, thresholds with units, keyword lists, travel-context predicates, conjunctions — which is also what Charter §4.0.3 describes ("pattern, keyword and structured-symptom rules"). A regex cannot express a unit-checked vital threshold, and §3.5.3 forbids coercing across units.

**Not fixed.** This is the largest single item in the reconciliation and should be scheduled as its own job.

### A4. 🟠 `safety_template` lacks `severity`, `jurisdiction`, `language`, `slots` in the stub

Which is why §4.3.2 slot-filling and §4.3.4's machine-translation ban were never testable here, and why the nearest-ED slot (RF4) is still unwired. The real table has all four, plus the `c_no_mt_safety_text` guard.

## B. Divergences that weaken testing rather than break it

### B1. 🟠 `claim_kind` enum: the stub has 10 of 15 values

Missing: `CLINICAL_EFFICACY`, `REFERENCE_RANGE`, `ELIGIBILITY`, `LOGISTICS`, `SENTIMENT`.

This matters more than a missing enum value usually would. `claim_policy` is the §1.5.3 tier × kind × category matrix — 5 × 15 × 3 = **225 rows** in migration 022. The stub can only express 5 × 10 × 3 = 150. **The two most safety-critical kinds in §1.5.3 — `CLINICAL_EFFICACY` and `REFERENCE_RANGE` — have no policy rows here at all**, so `emissionValidator`'s tier gate has never been exercised against them.

### B2. 🟠 `review_state` is missing `ESCALATED`

Charter §2.3.5b names four clinician actions: `APPROVED`, `APPROVED_WITH_EDITS`, `REJECTED`, `ESCALATED`. The stub enum omits the fourth, so an escalation cannot be recorded here. The declaration order also differs from the real enum; harmless today because nothing orders `review_state`, but worth knowing given `red_flag_severity` **is** ordered and three CHECK constraints depend on it (AMB-S-11).

### B3. 🟡 `claim.statement` vs `claim.text`

A straight rename. Code written against one fails against the other. Real also has `provider_org_id`, `effective_at`, `expires_at` — and `expires_at` carries the `cost_expiry` CHECK requiring it for `COST` claims (§1.7.1 hard expiry), which is therefore untestable here.

### B4. 🟡 `subject_key` shape differs

Real: `salt`, `wrapped_dek`, `destroyed_at`, with `c_salt_dies_with_key`. Stub: `key_material`, `revoked_at`. The stub cannot express ADR-003 §2.4's actual guarantee — *"a pseudonym you can still recompute from a user id is re-identifiable"* — so the erasure-vs-audit reconciliation (B4-legal) has never been tested here.

### B5. 🟡 `patient_profile` / `patient_attribute`

Confirmed STAND-IN, as this document already said. `patient_attribute` diverges on eighteen columns — the real one carries AEAD ciphertext, key ids, provenance and confirmation state; the stub has `label`/`user_id`.

### B6. 🟢 `region_registry`

Stub: `(code, name)`. Real: `(code, legal_basis, primary_regime, active_from, active_to)`. Minor, but `name` does not exist in the real schema.

## C. Confirmed correct

`claim_policy`, `fabrication_block`, `response_audit_event`, `response_category_state`, `response_content` and `session_severity_floor` match the real migrations column-for-column. The `response_audit_event` hash chain — the C-30 correction from HP-RB-001 — is faithful, which is the single most important thing on this list to have got right.

`red_flag_log` and `emergency_facility_reference` (added by migration 027) differ only in the stub dropping `ai_call_id`, the two floor columns, and the geo/source columns — deliberate, since the stub has no `obs.ai_call` FK target for some of them.

## D. What to do about it

| # | Action | Priority |
|---|---|---|
| 1 | ~~Fix `loadSafetyTemplate`'s `active` predicate and its silent catch~~ | ✅ done |
| 2 | Rewrite template resolution to select by `(severity, jurisdiction, language)` with the §4.3.3/§4.3.4 ladder; drop `template_id` from `red_flag_rule` in `db/010` | 🔴 high |
| 3 | Move rule patterns from regex `text` to structured `jsonb`, matching the real column and §4.0.3 | 🔴 high, own job |
| 4 | Bring `db/010`'s `safety_template` up to the real shape (severity, jurisdiction, language, slots, approval columns) so §4.3 is testable | 🟠 |
| 5 | Complete the `claim_kind` enum and seed the full 225-row `claim_policy` matrix | 🟠 |
| 6 | Add `ESCALATED` to `review_state` | 🟠 |
| 7 | Decide the direction for `claim.statement`/`claim.text` and `subject_key` | 🟡 |

**The strategic question these raise:** the stub was built because the real migrations were unreachable. They are reachable now. Options 2–7 all patch the stub to look more like the real schema; the alternative is to delete `db/000`–`db/020` and run the real `migrations/` in CI against a throwaway Postgres, which is what `run_migrations.mjs` already does and what removes this entire class of drift permanently. That is a bigger change and a real decision, not a default — but it is the one worth having.

---

## E. Divergence found by *running* the stub — 4 Sep 2026

Everything in sections A–D was found by comparing DDL. This one was not, and it is
the most serious item in this document.

### E1. 🔴 `db/010` never granted `hp_app` read on `safety.red_flag_rule_set`

`safety.adopted_rule_set()` is `LANGUAGE sql STABLE` — **invoker's rights, not
`SECURITY DEFINER`**. It reads `red_flag_rule_set`, so it reads that table as
whoever called it. The application connects as `hp_app`, and `db/010`'s grant was:

```sql
GRANT SELECT ON safety.red_flag_rule, safety.safety_template TO hp_app, hp_reader;
```

`red_flag_rule_set` is not in that list. Every call to `matchDeterministicRules`
would therefore have raised `permission denied for table red_flag_rule_set`, been
swallowed by the function's own `try/catch`, and returned
`adoptionGate = FAIL_CLOSED` with `lookupFailed: true`. The red-flag module would
have been **permanently unavailable in production** — correctly failing closed,
which is the design working, but for a reason nobody would have looked for.

Nothing caught this. The unit tests inject a fake rule-set repository and never
touch a role. `tsc` cannot see a grant. Both CI jobs were green on the day the
grant was written, because at that point the smoke test was still issuing the
*old* pre-R3 query, which read `red_flag_rule` directly and never called the
function. It surfaced only when `scripts/smoke-test.mjs` was rewritten to issue
`matchDeterministicRules`' query **verbatim, as `hp_app`** — which is the entire
justification for that script existing.

Fixed in `db/010`: `red_flag_rule_set` added to the grant, plus an explicit
`GRANT EXECUTE` on the function.

**`migrations/027` was already correct** — it grants `red_flag_rule_set` to
`redflag_role` and `EXECUTE` on `adopted_rule_set` at lines 223 and 317. So this
is drift in the safe direction for the real deployment, and it means the *stub*
was the thing that would have shipped broken had CI been trusted as the gate. The
lesson generalises past this one grant: a stub that omits a privilege the real
schema grants produces a false RED, but a stub that grants a privilege the real
schema omits would produce a false GREEN, and this document's section D option —
run the real migrations in CI — is the only thing that closes that direction.

### E2. Stale test fixtures that the R2/R3 rewrites left behind

Found the same way, in the same run. All fixed:

| Where | Referenced | Now |
|---|---|---|
| `scripts/smoke-test.mjs` | `red_flag_rule.template_id`, `ruleset_version` filter | `safety.adopted_rule_set($1,$2)` join, jsonb `pattern` |
| `scripts/smoke-test.mjs` | `safety_template.active` | `(severity, jurisdiction, language)` + `ORDER BY version DESC` |
| `scripts/smoke-test.mjs` | `red_flag_event.ruleset_version` | `rule_set_id`, plus the real rule id/version so the composite FK is exercised |
| `scripts/smoke-test.mjs`, `test/runPipeline.integration.test.ts` | `GENERIC_ESCALATION_TEMPLATE_ID` (`5555…`) | the seeded CRITICAL template `4444…402`, which is what the §4.3.3 ladder resolves a URGENT/CRITICAL scan to |
| `eval/gold/redFlagComposition.gold.json`, `eval/run-eval.ts` | `resolveTemplateRequirement` | 11 `templateLadder_cases` driving `resolveTemplateForSeverity` through an injected lookup |

Two of these were cascades: four `session_severity_floor` checks failed only
because the `red_flag_event` insert above them had failed, leaving
`set_by_event_id` null. Eight reported failures, four distinct causes.

