# HealthPlus chat pipeline — one turn, end to end, streamed

A Next.js 16 App Router route (`src/app/api/chat/route.ts`) implementing the full
chat pipeline for a single turn: intent/complexity classification, RESPONSE_CATEGORY
assignment, the red-flag safety engine, patient profile + knowledge lookup, clinical
reasoning, streamed synthesis, a structural emission validator, audit persistence, and
a fire-and-forget side-effect dispatch — streamed to the client over Server-Sent
Events.

This isn't a generic chatbot pipeline with health-flavored names bolted on. It's built
directly against this project's own governance artifacts — Evidence & Safety Charter
v1.0 (HP-ESC), DR-001 (v1 scope decision), HP-ADR-001 (stack), HP-RB-001 (audit
immutability), HP-SEC-001 (RLS/JWT), and the committed schema in
`HP-SCHEMA-001_Annex_A_Extension.md` — and every non-obvious design choice below cites
the clause or document that forced it.

## Why Next.js on Vercel, not a bare Fastify service

HP-ADR-001 §3.4 splits the stack: "Next.js 16 on Vercel Pro for the web surface; a
separate always-on Node worker on Fly.io for everything else." Chat is the web
surface. The always-on worker is where the OCR/parsing/ingestion jobs live that would
blow past Vercel Functions' 4.5 MB body / 800s duration / 4 GB ceilings — none of which
this route comes close to. `maxDuration = 800` in `route.ts` documents that ceiling
rather than testing it.

## Two deviations from existing decisions, flagged rather than silently taken

**1. Opus on the live user-facing path.** HP-ADR-001 §3.6 reserves Opus 5 for
*offline* claim extraction and conflict resolution, and puts Sonnet 5 on user-facing
generation, specifically because that ADR is "reversal cost: LOW." The pipeline spec
this repo implements explicitly asks for Opus on `PERSONALIZED RECOMMENDATION
SYNTHESIS` (unconditionally) and on `CLINICAL & DIAGNOSTIC REASONING` (when the
complexity score from step 1 is HIGH). Rather than silently pick one document over the
other, `src/lib/pricing.ts` makes this a named, defaulted-on toggle
(`ALLOW_OPUS_ON_LIVE_PATH`, default `true`) — every `obs.ai_call` row records which
model actually ran either way, so the deviation is auditable, not silent. Set
`ALLOW_OPUS_ON_LIVE_PATH=false` to fall back to Sonnet-only generation and stay
literally inside HP-ADR-001 §3.6 until someone amends it or confirms the deviation.

**2. Token-by-token vs sentence-by-sentence streaming.** The spec asks for both "Opus
streamed token-by-token to the client" and an emission validator that "buffers and
checks the stream sentence-by-sentence... before each sentence reaches the client."
These are in tension by construction — you can't validate a claim's sourcing before its
sentence is complete. `src/lib/pipeline/emissionValidator.ts` resolves this in favor of
the validator: the client gets genuinely incremental output (each sentence streams the
moment it's validated, not the whole response at once), at sentence granularity rather
than token granularity. For a health-safety control, that's the correct trade-off, and
it's the one Charter §3.0.3 actually requires ("Enforcement is structural, not
persuasive").

## Pipeline order, and why it isn't quite the literal order in the spec

```
intent + complexity (Haiku)
  -> RESPONSE_CATEGORY classifier (Haiku) — persisted to response_audit_event
     before generation, §2.0.1/§2.0.4
  -> red-flag scan (deterministic rules + model propose-only channel) — ALWAYS
     runs here, independent of category, §4.0.1
     -> CRITICAL/EMERGENCY? short-circuit to the static §4.0.5 template.
        This wins over EVERYTHING, including a CLINICAL_DECISION refusal —
        an emergency inside a clinical-decision-shaped message still needs
        the emergency banner.
  -> category == CLINICAL_DECISION? short-circuit to the §2.3.6 refusal.
     Not a fallback — DR-001 §1 and the DB constraint
     `c_category_c_disabled_v1` make this the only legal outcome for that
     category in v1. No patient lookup, no retrieval, no generation spent
     on a response that can't ship.
  -> patient profile lookup (direct DB read)
  -> knowledge lookup layer, parallel, direct SQL, no LLM — skipped entirely
     if category is CLINICAL_DECISION (see above)
  -> §2.0.2 monotonic-upward re-check now that retrieval has actually run
     (a TEST_INTERPRETATION-kind claim surfacing mid-retrieval can only push
     the category UP, never down — re-triggers the §2.3.6 short-circuit)
  -> clinical & diagnostic reasoning (Sonnet, escalate to Opus if HIGH
     complexity) — reasons ONLY over population-level retrieved claims,
     never over the patient's stated/inferred conditions (see
     clinicalReasoning.ts header comment — this is what keeps "personalized"
     meaning logistics/preferences, not a clinical determination, real
     rather than aspirational)
  -> personalized recommendation synthesis (Opus by default, streamed)
  -> response emission validator, sentence by sentence, §3.0.3
  -> audit persistence (response_audit_event append-only log +
     response_audit projection + encrypted response_content)
  -> side-effect dispatcher, fired but NOT awaited
```

The spec's literal order puts the safety engine after the category classifier and
before everything else — this implementation keeps that, but adds the emergency
short-circuit and the CLINICAL_DECISION short-circuit as explicit branches, because
running knowledge lookup and two more LLM calls for a request that's structurally
guaranteed to end in a static refusal wastes latency and money on every single
CLINICAL_DECISION-classified turn (and per DR-001 that's expected to be common —
Telemedicine Practice Guidelines §5.4 is the whole reason Category C is off).

## What changed since the first delivery

The first pass shipped a pipeline that type-checked but had never been run. This pass
closed most of the gaps that review surfaced, and — importantly — found and fixed a
real bug by actually executing the SQL rather than re-reading it, the same lesson
HP-SEC-001 §5 already drew from its own build: *"None of these would have shown up
from reading the SQL — they only surfaced by executing it."*

**Verified against a real Postgres 16 + pgvector instance**, not just type-checked.
`db/000_stub_upstream.sql` reconstructs the pieces of the committed schema this
pipeline actually touches (each block cites which doc it's copied from, or is marked
STAND-IN per the same convention HP-SEC-001 §2 used for its own stub tables);
`db/010_chat_pipeline_support.sql` is genuinely new — the tables/functions below that
were previously just "referenced but not committed." `scripts/smoke-test.mjs` connects
as `hp_app` (not a superuser) and runs the actual SQL strings from every pipeline
module, exercising real grants and real constraints, not just syntax. `npm run test:db`
runs it. **This caught a real bug**: `knowledgeLookup.ts` was calling `claim_search()`
with the `KnowledgeDomain` enum (`"GUIDELINE"`) where the function expected the actual
SQL table name (`"domain.guideline"`) — every knowledge lookup was silently returning
zero rows. For a §3.0.3 system, a wiring bug and "no sources exist for this query"
produce the identical symptom, which is exactly why this needed to be run, not read.
Fixed in both `knowledgeLookup.ts` and the `claim_search()` signature (renamed
`p_domain` → `p_domain_table` so the mismatch can't silently recur).

**New DDL for the referenced-but-uncommitted pieces**, all in
`db/010_chat_pipeline_support.sql`, each following this project's own reference-table
pattern (PROVISIONAL until a named reviewer adopts it — the same shape as
`restriction_kind_ref` in `AMB-CGM-2-4_Signoff_Package.md`):
- `obs.model_pricing` + `obs.ai_call_cost` — closes the cost gap below.
- `safety.red_flag_rule` / `safety.safety_template` — ships empty and
  `clinically_adopted = false` by default (AMB-17 is still the real blocker; both
  `matchDeterministicRules()` and `loadSafetyTemplate()` already fail safe on empty).
- `subject_key` — LAYER 3 per HP-SCHEMA-001 §17.1, wired to `response_content.key_id`.
- `side_effect_job` — the durable queue `sideEffectDispatcher.ts` enqueues into.
- `evidence.claim_aggregate()` and `claim_search()` — a working, if unrefined,
  implementation: FTS-only fallback plus an RRF-fused hybrid path once a query
  embedding is supplied. The RRF `k=60` constant is a common default, not a value from
  any project doc — tune it against a real eval set before trusting it, per HP-ADR-001
  §3.3's own instruction to "spend the effort on chunking and on an eval set."

**Cost is now durable**, not just console-logged. `obs.model_pricing` (seeded from
HP-ADR-001 §3.6's rate table, PROVISIONAL) joins to `obs.ai_call` via the
`obs.ai_call_cost` view, resolving the correct rate as of each call's `occurred_at`.
Verified: `scripts/smoke-test.mjs` inserts an `ai_call` row and reads its cost back
through the view. `src/lib/pricing.ts`'s in-process estimate still feeds the
structured console log line for local debugging, but the view is the system of record.

**Real JWT auth**, replacing the header-reading placeholder. `src/lib/auth.ts` verifies
a Supabase-issued HS256 JWT's signature and expiry and extracts HP-SEC-001's
`app_metadata.user_role`/`hospital_id`/`admin_scopes` claims; `route.ts` now rejects
anything but a verified `patient` token (a clinician or hospital_admin token would hit
an RLS wall three steps into the pipeline anyway — checking the role up front turns
that into a clean 403 instead of a confusing empty profile). Seven unit tests in
`test/auth.test.ts` cover valid tokens, expiry, bad signatures, and unrecognized roles.

**A frontend adapter**, closing the "SSE producer only" gap. `examples/frontend-adapter/`
has a framework-agnostic `sendChatMessage()` (deliberately not the browser
`EventSource` API — that can't POST or set an Authorization header, and this route
needs both) and a small `useHealthPlusChat` React hook wired to every event `route.ts`
actually emits.

**A swappable prompt registry**, the closest this pass could get to "the worked prompts
you referenced were never included." `src/lib/prompts/registry.ts` is now the single
place every LLM-facing prompt lives (category classifier, red-flag propose-only,
intent/complexity, clinical reasoning), each tagged `source:
'claude-authored-placeholder'`. Dropping in the real prompts is now a one-file diff
instead of a hunt through four source modules. Two components the original spec
pointed at worked prompts turned out not to need one: the emission validator is
deliberately code, not a prompt (its own doc comment says so), and the side-effect
dispatcher makes no LLM call at all — see the registry file's header for the full
reasoning, in case either was actually meant to be LLM-driven, which would be a
different, larger change than swapping text.

**Unit tests exist now.** 40 tests across five files (plus the four-test DB-backed
integration suite described below), all passing, all named for the
clause they enforce per Annex A.2's convention
(`test_hp_esc_<section>_<description>`). The category classifier's ambiguity-resolves-
upward rule (§2.0.3), the red-flag "model may raise, never lower" clamp (§4.0.3), and
the emission validator's reassurance/eligibility/citation-integrity/population checks
(§3.10.3, §3.2, §3.9.2, §1.9.7) were all pulled out into pure functions specifically so
they're testable without a live model or database — see `parseAndResolveCategory`,
`clampSeverity`/`resolveTemplateRequirement`, and `classifySentence`. Writing these
tests caught a second real bug: the citation-marker regex only matched hex-looking
IDs, so a malformed marker was silently left as raw `[[claim:...]]` text in the visible
response instead of being stripped and blocked — fixed, with a regression test.

## What changed since the second delivery

The second pass closed the "worked prompts / cost / tests / DDL / auth / live
verification / frontend" gaps but left three real ones: the orchestration layer
(`route.ts`'s `POST`/`runPipeline`) had never actually been run — only its individual
steps' SQL had; `safety.red_flag_event` (§4.0.7 — "every flag at MONITOR and above,
persisted with its full context") was referenced by the Charter but never had DDL or a
writer; and the knowledge-lookup smoke test only ever exercised the GUIDELINE domain,
leaving the other eight untouched. This pass closed all three, and — again — running
code rather than re-reading it found a real, ship-blocking bug.

**`runPipeline` is now actually run, end to end, four ways.** It's exported from
`route.ts` (it was module-private) specifically so `test/runPipeline.integration.test.ts`
can drive it directly against a real local Postgres, with `src/lib/anthropic.ts`'s
`__setAnthropicClientForTesting` swapping in a scripted mock for the four LLM-facing
calls (no live Anthropic call is made). Four tests, one per branch: the §4.0.5
emergency short-circuit (a model-raised severity reaching CRITICAL), the §2.3.6
CLINICAL_DECISION short-circuit, the §2.0.2 post-retrieval reconciliation (a retrieved
TEST_INTERPRETATION claim upgrading DECISION_SUPPORT mid-pipeline — this specific branch
had never been exercised by anything before), and the normal completion path (a cited
GUIDELINE claim streaming through, getting validated, and landing in every audit table).
Run with `npm run test:integration` (needs the same local Postgres as `test:db`).

**This caught a real, ship-blocking bug on the first run**: `response_content.audit_id`
is a real foreign key into `response_audit(id)` (`db/000`'s stub schema), but all four
of `runPipeline`'s exit points called `persistResponseContent()` *before*
`upsertResponseAudit()` — the FK target didn't exist yet. Every single response this
route ever generated would have failed to persist its content with a foreign-key
violation, immediately after already having streamed the (unpersisted) answer to the
user. `scripts/smoke-test.mjs` never caught this because it exercises each statement
in isolation with its own hand-picked insert order, never the real sequence. Fixed by
reordering all four branches (`upsertResponseAudit` first, then
`persistResponseContent`, then `recordRedFlagEvent`) — see the comment left at the
first fix site in `route.ts`.

**`safety.red_flag_event` now has DDL and a writer.** `db/010_chat_pipeline_support.sql`
§7 adds the table (adapted from the verbatim block quoted in
`HP-SCHEMA-001_Annex_A_Extension.md`, with the same STAND-IN discipline `db/000` already
uses for `red_flag_rule`/`safety_template`). `redFlagEngine.ts`'s new
`recordRedFlagEvent()` writes it from all four of `runPipeline`'s exit points — always
after `upsertResponseAudit`, since `red_flag_event.audit_id` is also a real FK. It
no-ops below the §4.0.2 MONITOR floor. `deriveActionTaken()` is the pure function
deciding `TEMPLATE_SHOWN` vs `ESCALATED` vs `NONE` (this pipeline's own addition to the
doc's action_taken vocabulary, for a MONITOR-only event with no UI action — see the
DDL's comment); §6.5's "latency from first byte of the inbound message, not scanner
start" is captured as `PipelineContext.receivedAt`, set at the top of `POST` before
auth or body parsing. Verified in both `scripts/smoke-test.mjs` (the table's CHECK
constraints, in isolation) and the new integration test (the real writer, in context).

Writing this DDL surfaced a second real bug, found before it could bite in production
rather than after: `resolveTemplateRequirement`'s fallback used to be the bare string
`'GENERIC_ESCALATION_TEMPLATE'` — not a UUID. `loadSafetyTemplate`'s try/catch silently
swallowed the resulting invalid-uuid query error and fell back to its own hard-coded
message, so the bug was invisible there; it stopped being invisible the moment
`red_flag_event.template_id` (a real `uuid` FK column) tried to store it. Fixed by
making the fallback a real, fixed UUID (`GENERIC_ESCALATION_TEMPLATE_ID`,
`redFlagEngine.ts`) with a seeded row in `db/999`, plus a regression test asserting its
shape.

**Knowledge lookup is now exercised across all nine domains, not one.**
`db/999_seed_smoke_test.sql` seeds a claim in each of NUTRITION, EXERCISE, LIFESTYLE,
MONITORING, COST, HOSPITAL, VISA, and ENVIRONMENT (GUIDELINE was already seeded), and
`scripts/smoke-test.mjs` queries all nine. One of the MONITORING claims is deliberately
`TEST_INTERPRETATION`-kind, seeded specifically so a query can retrieve it and exercise
the §2.0.2 reconciliation branch above — `knowledgeLookup.ts`'s "identical code path,
different table name" assumption now has eight more real code paths to have diverged
in, and didn't.

## What changed since the third delivery

The third pass closed the eight gaps an explicit punch-list review surfaced: no live
model traffic, an unreconciled stub schema, an unexercised vector search path, no CI,
a missing §4.0.8 safety table, no eval gate, no deployment config, and RLS never
applied. All eight are now either genuinely done and verified against real Postgres, or
built and verified as far as this sandbox's real constraints (no `ANTHROPIC_API_KEY`
for this app, no container-registry access, no Vercel/Fly.io/HuggingFace accounts)
allow — each one says explicitly, in its own file, which half is which. See "Follow-up"
below for what changed after this pass, once the user could supply some of what was
missing.

## Follow-up: revisiting the three items still blocked after the third delivery

Asked to actually complete the three remaining blockers (no live Anthropic call, no
Docker image build, no deploy accounts), each was re-checked directly rather than just
re-stated, and one turned out to be only half-blocked:

**Docker**: the daemon itself can actually be started in this sandbox (the packaged
`service docker start` script fails on a `ulimit` permission error, but running
`dockerd` directly works, and `docker run` against a local image is fully functional).
What's still blocked is pulling `worker/Dockerfile`'s `FROM node:22-slim` base image —
this sandbox's egress proxy explicitly denies every container registry tested (Docker
Hub, ghcr.io, gcr.io, quay.io, public.ecr.aws), confirmed as a policy denial (HTTP 403 at
the gateway) via the proxy's own status endpoint, not a timeout or DNS failure. So the
image build is still unverified here, for a more precise reason than "no daemon."

**Git / CI**: the user provided a real GitHub repo
(`github.com/kamakshyanegotrip/HealthPlus`). It wasn't empty — it already held a
different HealthPlus job's real, committed deliverable (`HP-OIR-002`,
`extractClaimsFromProviderSubmission`, at the repo root, with its own
`package.json`/`tsconfig.json`/`README.md`). Rather than overwrite that, this job was
added as `chat-pipeline/` — this file's own directory — leaving HP-OIR-002's files at
the repo root untouched. That move required relocating the CI workflow: GitHub Actions
only discovers workflows under the *repo root's* `.github/workflows/`, so
`ci.yml` moved to `../.github/workflows/chat-pipeline-ci.yml` (one level up from this
file), scoped with `paths: ['chat-pipeline/**']` and `defaults.run.working-directory:
chat-pipeline` so it only runs on and only touches this job. **Committed locally, not yet
pushed**: the sandbox's own git credential-injection proxy rejected the push with
`access denied by the git proxy: ... is not in this session's authorized repository
set` — a session-level permission separate from git-read access (cloning and
`ls-remote` both worked fine), and something only the user can grant from wherever this
environment's repository authorizations are managed. The commit is sitting ready to go;
nothing about it needs redoing once that's granted.

**Live Anthropic call: done, and it immediately found a real bug.** The user created a
Console account and API key and provided it directly. The very first real call ever
made to `CATEGORY_CLASSIFIER` — via `npm run smoke:live` — came back as
`{"category": "CLINICAL_DECISION", "confidence": 0}` for a plainly INFORMATIONAL
question ("What is a typical recovery timeline after a knee replacement, generally
speaking?"). That's the pipeline's own fail-closed default, not a real classification —
confirmed by capturing the raw model text directly: the real Haiku response wrapped its
JSON in a ` ```json ` fence and appended a "**Reasoning:**" paragraph, despite the
prompt's "Output strict JSON only" instruction. `parseAndResolveCategory`'s bare
`JSON.parse(rawText)` threw on the leading backtick and silently fell back to
`CLINICAL_DECISION`/confidence 0 — meaning, before this fix, *every* real production
call would have been forced into the §2.3.6 refusal template regardless of what the
model actually decided, because its real judgment never survived parsing. The same
`JSON.parse(text)` pattern existed at two more call sites
(`redFlagEngine.ts`'s propose-only call, `intentComplexity.ts`) that had never been
exercised live either. Fixed with a new `src/lib/jsonExtract.ts` — a defensive
extraction layer (clean-JSON fast path, then fenced-block stripping, then a brace-span
fallback) wired into all three call sites; it doesn't change what happens when nothing
is extractable, so every existing fail-closed/fail-safe default is still the real
safety net. 9 new unit tests (`test/jsonExtract.test.ts`) use the exact real raw text
captured from the live call as a fixture. Re-running `npm run smoke:live` against the
real model afterward confirmed the fix: the same question now correctly classifies as
`{"category": "INFORMATIONAL", "confidence": 0.95}`. This is the clearest example yet in
this repo of its own repeated lesson — every prior test of these three parsers used
hand-written, already-clean JSON fixtures; only a real model call could have caught
this, and did, on literally the first one ever made.

**`safety.session_severity_floor` (§4.0.8) is now implemented**, and finishing it found
two more real, ship-blocking bugs the same way the last two passes did: by running the
new integration test against real Postgres, not by re-reading the code.
`db/010_chat_pipeline_support.sql` adds the table (sticky-upward-until-cleared, per the
Charter's own wording) and `redFlagEngine.ts` adds `getSessionFloor`/
`applySessionFloor`/`clearSessionSeverityFloor`, wired into `route.ts` right after the
deterministic-plus-model severity is composed. The first bug: a zero-citation response
(all filler, nothing to cite) was streaming through with `aggConfidence = 0.0` under a
model-scored category, violating the DB's own `c_min_conf` check — the emission
validator only ever blocked *uncited numeric* claims, not the zero-citation case
entirely, so nothing upstream caught it. Fixed by treating an all-uncited response like
the existing static-template carve-outs: `aggConfidence = 1.0`, category downgraded to
`INFORMATIONAL`, always `reviewRequired`. The second: raising severity via the session
floor didn't recompute the required template, so a floor-raised URGENT session could
carry a null `template_id` and violate `c_urgent_needs_template` — fixed by calling
`resolveTemplateRequirement` again after the floor is applied, exactly mirroring how a
model-side raise already composes it. Both are exercised by
`test_session_severity_floor_sticks_across_turns_in_the_same_session` in
`test/runPipeline.integration.test.ts`.

**HP-SEC-001 row-level security is now installed and enforced on the real route, not
just designed.** `db/020_rls.sql` enables RLS on `patient_profile`/`patient_attribute`
(own-row-only) and `hospital_profile`/`hospital_cost` (published-marketplace-visibility
plus own-org read/write for `hospital_admin`, full visibility for `platform_admin`).
Because this app connects as one pooled technical role (`hp_app`), not one Postgres
role per user the way HP-SEC-001's original Supabase/PostgREST design assumes, the
bridge is `runAsUser()` in `src/lib/db.ts`: it opens a transaction, sets
`request.jwt.claims` via `SET LOCAL`/`set_config`, runs the query, commits. `route.ts`
now populates `ctx.authClaims` from the verified JWT and `patientProfile.ts` calls
`runAsUser` instead of the pool directly. Verified two ways: `scripts/smoke-test.mjs`
gained nine raw-SQL checks (fail-closed with no claims set, cross-patient reads blocked
even when the `WHERE` clause alone would have matched, the marketplace visibility
pattern for all three roles, hospital_admin `INSERT` permitted for its own org and
rejected for another's), and `test/runPipeline.integration.test.ts` gained three tests
driving the real `lookupPatientProfile` function, not raw SQL. `db/020_rls.sql`'s own
header comment is explicit that this is a narrower role model than HP-SEC-001's
original (no clinician scope-of-practice matching) and should be reconciled against
HP-SEC-001's own policy file, not assumed to be the final version.

**A §6.4 eval suite now exists and actually gates.** `eval/run-eval.ts` runs 45 gold
cases (`eval/gold/*.json`) straight against this repo's real pure functions —
`classifySentence`, `parseAndResolveCategory`, `clampSeverity`,
`resolveTemplateRequirement`, `deriveActionTaken`, `applySessionFloor` — and exits
non-zero on any failure. This isn't just more unit tests: it's a distinct artifact,
runnable in CI as a release gate the way §6.4 asks for ("prompts, classifiers and
retrieval config are versioned artefacts with an eval suite gating release"), separate
from `npm test`'s developer-facing suite. Confirmed it actually catches a regression,
not just passes by construction: temporarily broke `clampSeverity`, watched the gate
fail (44/45, `EVAL GATE FAILED`), restored it, re-verified clean.

**CI is now wired up, and now actually running for real.** `../.github/workflows/chat-pipeline-ci.yml`
(at the repo root, since GitHub Actions only discovers workflows there — this job lives
in `chat-pipeline/`, one of possibly several HealthPlus jobs in this repo) runs two jobs
on every push/PR that touches `chat-pipeline/**`: `typecheck-and-unit` (typecheck,
`npm test`, `npm run eval`) and `db-integration`, which spins up a real
`pgvector/pgvector:pg16` Postgres service container, applies every `db/*.sql` file in
order, and runs `npm run test:db` and `npm run test:integration` against it. This was
validated with `actionlint` (zero findings) and every command inside it was run
directly, then pushed to a real GitHub repo — check the Actions tab for the actual run
result, since a real CI run is the first true test of the runner environment itself
(image pull, service-container health-check timing), the same way executing SQL is the
first true test of a migration.

**Correction to the claim above**: the first real run of this workflow (Actions run #1, job "DB smoke test + orchestration integration test") failed immediately, at the very first database step, with `FATAL: database "hp_test" does not exist`. The job-level `PGDATABASE: hp_test` env var applies to every step in the job, including `Create hp_test database` itself, so a bare `psql -c "CREATE DATABASE hp_test;"` tried to connect to `hp_test` in order to create `hp_test` — a chicken-and-egg failure that only a real GitHub Actions runner could surface, since a local dev machine's `hp_test` database, once created, stays around across runs and never re-triggers this. Fixed by pointing that one step at Postgres's always-present `postgres` administrative database instead: `psql -d postgres -c "CREATE DATABASE hp_test;"`. Same lesson as every other bug documented in this file, one level up: CI config, not just application code, only proves itself by actually running.

**`claim_search()`'s vector branch has now actually been executed**, not just written.
No real embedding model was reachable to generate genuine semantic vectors
(`huggingface.co` returns 403 from this sandbox), so `scripts/pseudo-embed.mjs` builds a
deliberately non-semantic feature-hashing embedding — labeled as such in its own header
comment — purely to prove the SQL plumbing (the `vector` column, the `hnsw` index, the
`<=>` operator, the RRF fusion query) actually works end to end.
`scripts/generate-embeddings.mjs` backfills it for every seeded claim (now part of
`npm run db:migrate:stub`), and two new smoke-test checks prove the vector branch
executes and that a claim's own text-derived embedding ranks that claim first by
self-similarity. Production code (`knowledgeLookup.ts`'s two `claim_search()` call
sites) was deliberately left FTS-only, two-argument, unchanged — wiring a fake-but-
plausible embedding into the real request path would be a worse failure mode than the
current, honestly-flagged fallback.

**Deployment and ops configuration now exists**, closing the "producer only" gap
`sideEffectDispatcher.ts` had documented about itself since the first delivery.
`worker/side-effect-worker.mjs` is the first-ever consumer of `side_effect_job`: it
claims rows with `SELECT ... FOR UPDATE SKIP LOCKED`, dispatches by `kind`, and
requeues-then-fails after `WORKER_MAX_ATTEMPTS`. Genuinely tested, not just written: run
standalone against real local Postgres, it drained a real job to `DONE` and separately
proved the retry path (an unrecognized kind requeued twice, `FAILED` on the third
attempt, checked against the actual `attempts`/`status` columns afterward).
`worker/Dockerfile` and `worker/fly.toml` are written and every command inside the
Dockerfile was run directly outside a container — but the image itself was never built
(no Docker daemon reachable in this sandbox) and never deployed (no Fly.io account).
`vercel.json` sets the route's `maxDuration` but was never deployed either (no Vercel
account). `DEPLOY.md` is explicit, in its own opening section, about exactly which half
of each is VERIFIED vs UNVERIFIED — don't take either file's existence as proof it
works on the real platform, only as proof its logic was actually exercised somewhere.

**The stub-schema-vs-real-migrations gap is now catalogued, not just flagged inline.**
`db/STUB_VS_REAL.md` classifies every table/schema/function across `db/000`/`db/010`/
`db/020` into SOURCED (comment cites a doc, quoted verbatim), DERIVED (reasoned from a
cited clause, not copied), or STAND-IN (no committed migration exists at all yet) tiers,
cross-references the separately-discovered `HP-JOB-002_Migration_Numbering_Ledger.md`
project doc (which reconciles real migration *numbers*, a different question this table
doesn't attempt), flags the specific known conflict between this repo's `hospital_cost`
stub and HP-JOB-001's separate, richer `hospital_cost_aggregate` design, and gives a
five-step reconciliation procedure for once real repo access exists. This still can't be
fully resolved even now that this job lives in a real repo (see "Follow-up" above) — the
real committed migrations aren't in this repo either, only two independent jobs' own
deliverables — so this is the honest ceiling of what could be done without them.

**A live-Anthropic smoke script exists and is ready to run**, but has never actually
been run. `scripts/live-anthropic-smoke.ts` calls this pipeline's real
`classifyCategory`/`scanRedFlags` (and, with `--full`, `buildReasoningBrief`/
`beginSynthesis`) against the real Anthropic API and real Postgres — no mocks. There is
no `ANTHROPIC_API_KEY` available to this sandbox for this app; that was checked
directly, not assumed — `curl -X POST https://api.anthropic.com/v1/messages` with no
key from this exact sandbox returns a genuine HTTP 401
`{"type":"authentication_error",...}`, proving the network path is open
(`api.anthropic.com` is on this sandbox's egress allowlist) and a credential is the only
missing piece. Set `ANTHROPIC_API_KEY` and `DATABASE_URL` and run `npm run smoke:live`
for the first genuine end-to-end validation against the live model — this remains the
one punch-list item that is code-complete but truly unverified, because it cannot be
verified without a credential this sandbox does not have.

## What's still a documented placeholder

- `persistResponseContent`'s per-subject encryption key derivation (`auditLog.ts`)
  stands in for `subject_key`'s real key material — the table now exists
  (`db/010`), but the derivation in code is a stand-in, not real envelope
  encryption under a KMS key.
- `patientProfile.ts` and `knowledgeLookup.ts` query table names taken from
  HP-SEC-001 §2's stand-in tables — reconcile column names against the real
  migration when it lands. See `db/STUB_VS_REAL.md` for the full catalog of which
  objects are SOURCED, DERIVED, or STAND-IN, and the reconciliation procedure.
- `claim_search()`'s vector branch is now exercised end to end, but only with a
  deliberately non-semantic feature-hashing embedding (`scripts/pseudo-embed.mjs`) —
  it proves the SQL plumbing works, not retrieval quality. Production code
  (`knowledgeLookup.ts`) still calls `claim_search()` FTS-only; wiring in a real
  embedding model is a distinct, not-yet-started piece of work.
- No live Anthropic API call has actually been made — `scripts/live-anthropic-smoke.ts`
  is built and ready, but this sandbox has no `ANTHROPIC_API_KEY` for this app to run it
  with. This is the one punch-list item left genuinely unverified, and only because of
  that missing credential.
- No frontend/Phase 4.2 integration beyond the example adapter — nobody has actually
  rendered a response with it.
- `../.github/workflows/chat-pipeline-ci.yml` has been validated with `actionlint`, every
  command it contains was run directly, and it's now pushed to a real GitHub repo — check
  the Actions tab for the actual run result if this bullet hasn't been updated since.
- `worker/Dockerfile`'s image has never actually been built (no Docker daemon reachable
  in this sandbox), and nothing in `DEPLOY.md` — the Vercel deploy, the Fly.io
  deploy — has been run against a real account. Every command *inside* those configs
  was verified by running it directly, outside the container/platform it's meant for.
- HP-SEC-001's RLS is now installed and tested against this repo's own stub schema and
  route, but uses a narrower role model than HP-SEC-001's original design (no clinician
  scope-of-practice matching) — reconcile against HP-SEC-001's own policy file before
  treating `db/020_rls.sql` as final, and never apply its `auth` schema stub to a real
  Supabase project (Supabase provides `auth.uid()`/`auth.jwt()` natively — only the
  `CREATE POLICY`/`hp_auth.*` statements should be ported).

## Cost logging

Resolved this pass — see "What changed" above. `obs.ai_call_cost` (a view, not a
column on `obs.ai_call` — see `src/lib/pricing.ts`'s comment for why) is the durable,
queryable source; the console log line from `anthropic.ts` is a same-process estimate
for local debugging only.

## Running

```bash
cp .env.example .env.local   # fill in DATABASE_URL, ANTHROPIC_API_KEY, SUBJECT_HMAC_KEY, SUPABASE_JWT_SECRET
npm install
npm run dev
```

Bring up a local stub schema and run the DB-level checks (needs a local Postgres 16
with the `vector` extension available — `apt install postgresql-16-pgvector` on
Debian/Ubuntu). `db/001_roles.sql` creates the `hp_app`/`hp_reader` roles the rest of
the chain connects as — HP-RB-001 §2 requires the app never connect as owner or
superuser, so run this against a superuser connection once per database:

```bash
createdb hp_test
export PGDATABASE=hp_test   # psql -f below picks this up; or pass -d hp_test each time
psql -f db/001_roles.sql                    # creates hp_app / hp_reader roles (idempotent)
psql -f db/000_stub_upstream.sql
psql -f db/010_chat_pipeline_support.sql
psql -f db/020_rls.sql                      # HP-SEC-001 RLS policies + hp_auth schema
psql -f db/999_seed_smoke_test.sql          # sample data
node scripts/generate-embeddings.mjs        # backfills pseudo-embeddings so claim_search()'s vector branch is exercised
npm run test:db                             # scripts/smoke-test.mjs, connects as hp_app
```

Or run the whole chain above in one shot:

```bash
npm run db:migrate:stub
```

Run the unit tests (no DB or network needed):

```bash
npm test
```

Run the §6.4 eval suite (no DB or network needed — gates prompt/classifier/retrieval
changes against 45 gold cases, exits non-zero on any regression):

```bash
npm run eval
```

Run the orchestration integration test — drives the real `runPipeline` (including the
new RLS-enforced patient lookup and the §4.0.8 session severity floor) against the
Postgres instance set up above, with the Anthropic client mocked (no live API call, no
`ANTHROPIC_API_KEY` needed for this one):

```bash
npm run test:integration
```

Run the side-effect worker against the same database (drains `side_effect_job` rows
enqueued by `sideEffectDispatcher.ts`; `--once` drains what's pending and exits instead
of polling forever):

```bash
DATABASE_URL=postgres://hp_app:hp_app_pw@127.0.0.1:5432/hp_test node worker/side-effect-worker.mjs --once
```

Make a real, billed call to the live Anthropic API (needs `ANTHROPIC_API_KEY` — see
"What's still a documented placeholder" above for why this hasn't been run in this
sandbox):

```bash
ANTHROPIC_API_KEY=sk-ant-... DATABASE_URL=postgres://hp_app:hp_app_pw@127.0.0.1:5432/hp_test npm run smoke:live
```

See `DEPLOY.md` for Vercel (web) and Fly.io (worker) deployment instructions.

Exercise the route for real once a real Postgres + Anthropic key are configured:

```bash
curl -N -X POST http://localhost:3000/api/chat \
  -H 'content-type: application/json' \
  -H 'authorization: Bearer <a real Supabase-issued patient JWT>' \
  -d '{"sessionId": "<uuid>", "message": "How do three hospitals in Chennai compare for a hip replacement, roughly what would it cost, and what visa do I need?"}'
```

You'll see `event: intent`, `event: category`, `event: severity`, `event: sources`, a
stream of `event: sentence`, then `event: done` — standard SSE. Consume it with
`examples/frontend-adapter/sendChatMessage()` (or the `useHealthPlusChat` hook) rather
than the browser `EventSource` API, which can't do the POST + Bearer auth this route
needs.
