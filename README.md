# HealthPlus — extractClaimsFromProviderSubmission

A pg-boss background task implementing the "extract" stage of the ingestion
pipeline described in `HP-ADR-001` §5 (fetch → parse → **extract** → embed →
score), tracked as Build Queue item #4 in the HealthPlus Open Items Register
(`HP-OIR-002`).

## What this does

Triggered when a `domain.provider_submission` row transitions
`RECEIVED → PARSED` (never from a live user request). It calls the
Anthropic API (Opus tier, per `HP-ADR-001` §3.6) to extract candidate claims
from a hospital/provider partner-portal submission, then **deterministically
validates every candidate against the actual submission payload** before
writing anything — confidence is always computed by code, never by the
model (Evidence & Safety Charter v1.0 §1.0.5), and anything that can't be
verified against the payload is left unwritten and logged to
`obs.data_quality_flag` instead of guessed.

Claim inserts and their downstream `embed-claim` job are enqueued in the
same Postgres transaction, using pg-boss's `db` adapter interface — the
transactional-enqueue guarantee `HP-ADR-001` §3.2 calls out.

See inline documentation in `src/jobs/extractClaimsFromProviderSubmission.ts`
for the full numbered logic and the Charter clauses each step enforces.

## Layout

```
migrations/                         — HP-OIR-003 build item 1: consolidated,
                                       numbered, verified migration files
                                       (see migrations/README.md)
src/
  safety/systemPromptFragments.ts   — single source of truth for Charter Annex B
                                       system-prompt blocks (PHASE_3_1_SAFETY_FRAGMENT)
  safety/emissionValidators.ts      — HP-OIR "B6": §3 emission validators, the
                                       response-time checkpoint §3.0.3 requires
                                       alongside nullable typed fields
  safety/emissionValidators.test.ts — clause-named tests, one suite per validator
  lib/claimKindPolicy.ts            — deterministic Tier 4 confidence/marker policy
  lib/anthropicClient.ts            — shared Anthropic client + model constant
  db/pool.ts                        — shared pg Pool + pg-boss instance
  jobs/extractClaimsFromProviderSubmission.ts       — the task
  jobs/extractClaimsFromProviderSubmission.test.ts  — test_hp_esc_3_3_1_no_unsourced_cost_output
```

## Status

Design/code complete and tested in isolation (`npm test` — 33/33 passing,
`npm run typecheck` clean). **Not yet deployed against a live database.**
Supabase is provisioned (`ap-south-1`, pgvector enabled — HP-OIR-003 B7,
closed). `HP-SCHEMA-001` / `HP-DQE-001` / `HP-RB-001`'s migrations are now
consolidated into 28 ordered files under `migrations/` and verified to apply
cleanly, in order, against a real PostgreSQL 16.13 + pgvector instance (see
`migrations/README.md`) — but **not yet against the live Supabase project**.
This task assumes those tables exist as specified; it has not itself been
run against a real Postgres instance.

`safety/emissionValidators.ts` implements the §3 emission-gate validators
named in Annex A.8 (`§1.5.3`, `§3.0.1`, `§3.3.8`, `§3.4.2`, `§3.5.2`,
`§1.4.4`, `§3.10.3`, `§4.0.6`, `§4.0.9`) as pure, DB-free functions plus one
aggregate `runEmissionGate()` checkpoint. It is written to be shared by both
this extraction task and any future live-generation surface ("Part B"),
the same way `systemPromptFragments.ts` already is — neither currently
calls `runEmissionGate()` directly (this extraction job does its own
inline structural anchoring against the source payload, which is a
narrower and stricter check than the general-purpose gate needs to be);
wiring it in is a follow-up once a second caller exists to justify the
shared integration point.

Two assumptions flagged in code comments, worth confirming before this goes
further: `principal.provider_org`'s jurisdiction column name (assumed
`country`), and the exact Anthropic model identifier for the Opus tier
(`ANTHROPIC_MODEL_CLAIM_EXTRACTION`, env-overridable).

## Migrations

See `migrations/README.md` for the full source reconciliation. Short version:
28 files, `001_003_reconciled_baseline.sql` through `026e_dq5_...sql`, plus
`ops/dqe_cron_schedule.sql`. Verified this session to apply cleanly, in
order, against a real PostgreSQL 16.13 + pgvector instance. Not yet run
against the live Supabase project.

## Running the tests

```sh
npm install
npm test        # vitest
npm run typecheck
```

No live database or Anthropic API key is required to run the tests — the
Postgres pool and Anthropic client are both mocked.
