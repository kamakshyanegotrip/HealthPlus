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
src/
  safety/systemPromptFragments.ts   — single source of truth for Charter Annex B
                                       system-prompt blocks (PHASE_3_1_SAFETY_FRAGMENT)
  lib/claimKindPolicy.ts            — deterministic Tier 4 confidence/marker policy
  lib/anthropicClient.ts            — shared Anthropic client + model constant
  db/pool.ts                        — shared pg Pool + pg-boss instance
  jobs/extractClaimsFromProviderSubmission.ts       — the task
  jobs/extractClaimsFromProviderSubmission.test.ts  — test_hp_esc_3_3_1_no_unsourced_cost_output
```

## Status

Design/code complete and tested in isolation (`npm test` — 3/3 passing,
`npm run typecheck` clean). **Not yet deployed against a live database.**
Per the Open Items Register, B7 (provisioning Supabase `ap-south-1` +
pgvector) is still open, and `HP-SCHEMA-001` / `HP-DQE-001`'s migrations
have not yet been run anywhere. This task assumes those tables exist as
specified; it has not been run against a real Postgres instance.

Two assumptions flagged in code comments, worth confirming before this goes
further: `principal.provider_org`'s jurisdiction column name (assumed
`country`), and the exact Anthropic model identifier for the Opus tier
(`ANTHROPIC_MODEL_CLAIM_EXTRACTION`, env-overridable).

## Running the tests

```sh
npm install
npm test        # vitest
npm run typecheck
```

No live database or Anthropic API key is required to run the tests — the
Postgres pool and Anthropic client are both mocked.
