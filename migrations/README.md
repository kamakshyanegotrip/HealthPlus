# HealthPlus — consolidated migrations

HP-OIR-003 Build Queue item 1: real, ordered, numbered migration files
extracted from the project's design docs, so the schema can actually be run
against a database rather than living as SQL fences scattered across markdown.

## Sources and how they were reconciled

Four documents contributed migrations, in this order of authority:

1. **`Evidence_and_Safety_Charter_v1.0.md` Annex A** — the original schema,
   superseded in three places by the corrections below.
2. **`Phase_1.1_Migration_Pack_ADR-003.md`** (re-designated **HP-MIG-001** per
   `HP-ADR-004`, since it collided with the real `HP-ADR-003`'s document ID) —
   corrects Annex A's confidence-on-`claim` grain, adds the `claim_kind`
   gaps and the tier×kind×category policy matrix, and designs the region /
   audit-split / identity schema. **Its own §2.1 region choice
   (`eu-central-1`) is withdrawn** — see below.
3. **`ADR-003_Region_and_Hosting.md`** and **`HP-ADR-004_Region_Conflict_Resolution.md`**
   — settle the region conflict in favour of **`ap-south-1` (Mumbai)**,
   which is what Supabase is actually provisioned in. `HP-ADR-004` explains
   *why* the Migration Pack said Frankfurt (it was answering ADR-001's open
   question, not aware `HP-ADR-003` had already answered it) and confirms
   only §2.1 of the Migration Pack is affected — everything else in it
   stands.
4. **`HP-SCHEMA-001_Annex_A_Extension.md` v0.5** — the actual, current,
   tested source. It folds in the Migration Pack's corrections (minus
   Frankfurt), assumes migrations 001–003 as a reconciled baseline, and
   defines migrations 004–024 in full: the `Arch.docx` §40 domain modules,
   Layer 3 principals, the clinical-domain vocabulary, the seeded attribute
   registry, the region/residency gate, the 225-row policy matrix, the
   confidence arithmetic, and `claim_aggregate`. Per its own header: **"DDL
   executed against PostgreSQL 16.13 + pgvector; loads clean and passes its
   behavioural suite."**
5. **`RB-001_Audit_Immutability_Runbook.md`** — a design correction Annex A
   and the Migration Pack both needed: `response_audit` cannot be both
   mutable (`review_state` changes) and immutable (`UPDATE`/`DELETE`
   revoked) as originally specified. Fixed by making the audit an
   append-only **event** log (`response_audit_event`, migration `003a`) with
   the mutable `response_audit` row (migration 018) derived from it. Logged
   as pending Charter amendment **C-30**.
6. **`HP-DQE-001_Data_Quality_Engine_Checks.md`** — the five Data Quality
   Engine checks (`Arch.docx` §38 / Charter §1.8.5), written directly against
   `HP-SCHEMA-001`'s actual table and function names. Adds migrations
   025–026e.

## What's in this directory

| File | Migration(s) | Source |
|---|---|---|
| `001_003_reconciled_baseline.sql` | 001–003 | HP-SCHEMA-001 §1 (reconciled baseline) |
| `003a_response_audit_immutability_hp_rb_001.sql` | — (must run before any user exists) | HP-RB-001 |
| `004_foundation.sql` … `017_...wellness...sql` | 004–017 | HP-SCHEMA-001 §3–16 |
| `018_layer_3_principals_provenance_and_crypto_shredding.sql` | 018 | HP-SCHEMA-001 §17 |
| `019_the_clinical_domain_vocabulary_and_the_scope_trigger.sql` | 019 | HP-SCHEMA-001 §18 |
| `020_seeding_the_attribute_registry.sql` | 020 | HP-SCHEMA-001 §19 |
| `021_region_and_the_residency_admission_gate.sql` | 021 | HP-SCHEMA-001 §20 / HP-ADR-004 |
| `022_the_225_row_claim_policy_matrix.sql` | 022 | HP-SCHEMA-001 §21 |
| `023_the_confidence_arithmetic_as_reference_data.sql` | 023 | HP-SCHEMA-001 §22 |
| `024_claim_aggregate_and_the_2_5_gate.sql` | 024 | HP-SCHEMA-001 §23 |
| `025_data_quality_flag_severity_and_reason.sql` | 025 | HP-DQE-001 §1 |
| `026a`…`026e_*.sql` | 026 | HP-DQE-001 §2–6 (DQ-1 … DQ-5) |
| `ops/dqe_cron_schedule.sql` | — (ops wiring, not a migration) | HP-DQE-001 §7 |

Run in filename-sorted order (`001_003_...` → `003a_...` → `004_...` →
… → `026e_...`) — that ordering is deliberate and load-bearing: `003a` must
run before the first migration that creates a user (HP-RB-001), and
`004`–`026e` each assume everything before them is already applied.

## Verified this session

Every file above was applied in order against a real **PostgreSQL 16.13 +
pgvector 0.6.0** instance (this session's own sandbox — not the live
Supabase database) with `ON_ERROR_STOP=1`. All 28 files applied cleanly with
no errors. Seed data was spot-checked against the counts each source
document claims:

| Table | Expected | Got |
|---|---|---|
| `evidence.claim_policy` | 225 | 225 |
| `evidence.tier_default` | 5 | 5 |
| `evidence.confidence_modifier` | 9 (M1–M9) | 9 |
| `evidence.claim_kind_decay` | 15 | 15 |
| `public.region_registry` | `IN` + a `ZZ` reference-only sentinel | 2 (`IN`, `ZZ`) |
| `public.residency_admission` | 1 admitted + 32 blocked + 20 pending = 53 | 53 |

This is a real-Postgres syntax/dependency check, not a design review — it
confirms the files apply cleanly in this order, not that every business
rule inside them is correct. It has **not** been run against the live
Supabase `ap-south-1` project; that is HP-OIR-003 build item 3
("run migrations against the live Supabase DB"), which needs the project's
own `DATABASE_URL` and is the user's to execute.

## What this does not include

- The `hp_app` / `hp_reader` role passwords in `003a` are literal
  placeholders (`'...'`)  — set real passwords out of band before running
  against a real database, and never commit real ones to this repo.
- HP-RB-001's operational steps that are not schema — the anchor bucket
  setup, the genesis anchor write, the hourly anchor job, the nightly
  verification job, WAL-G shipping, and the restore drill — are not migration
  files. They're reproduced as SQL/procedure in `RB-001_Audit_Immutability_Runbook.md`
  itself (§6–9) and need to be wired up as scheduled jobs once there's a
  place to run them (see HP-OIR-003 build item 6, Fly.io worker).
- `pg_cron` itself needs enabling on the Supabase project (Database >
  Extensions) before `ops/dqe_cron_schedule.sql` can run.
