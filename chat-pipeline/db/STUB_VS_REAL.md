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
