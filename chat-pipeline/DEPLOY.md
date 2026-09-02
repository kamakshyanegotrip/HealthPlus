# Deployment

GAP RESOLVED: "No deployment / ops config — no Vercel env setup, no worker consuming `side_effect_job`, etc." This document covers both halves of HP-ADR-001 §3.4's split ("Next.js 16 on Vercel Pro for the web surface; a separate always-on Node worker on Fly.io for everything else").

**Honesty note, upfront:** everything below has been built and verified as far as this sandbox allows — no Vercel account and no Fly.io account exist here; the Docker daemon can be started in this sandbox, but every container registry (Docker Hub, ghcr.io, gcr.io, quay.io, public.ecr.aws) is explicitly denied by this sandbox's own network policy (confirmed via its egress-proxy status endpoint: HTTP 403 at the gateway, not a connectivity failure), so `worker/Dockerfile`'s base image can never actually be pulled here even with the daemon running. Wherever a step needed one of these, it's marked **VERIFIED** (actually run and confirmed working here) or **UNVERIFIED — needs your account** (correct as far as it can be checked without one). This mirrors the same distinction this repo's other docs already draw — e.g. `../.github/workflows/chat-pipeline-ci.yml`'s own header comment on what actionlint checked vs. what a real GitHub Actions run would still be the first true test of.

## 1. The web app (Vercel)

**Config:** `vercel.json` in this job's own directory (`chat-pipeline/vercel.json` — this repo holds more than one HealthPlus job, so this isn't the git repo's root). **UNVERIFIED — needs a Vercel account**; the file's shape (framework preset, build/install commands, one route's `maxDuration`) was written against Vercel's documented `vercel.json` schema, not confirmed by an actual deploy. If the Vercel project is configured to build from this repo, set its **Root Directory** to `chat-pipeline` in the project settings — otherwise it will look for `package.json` at the git repo root and find HP-OIR-002's instead.

### Environment variables to set in the Vercel project

All of these are read by `src/lib/*` at request time — see each variable's own file for the full doc comment on what it does and why.

| Variable | Source / how to get it | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | Your Anthropic Console | Never committed; **not available in this sandbox** — see README's "What's still a documented placeholder" for what that blocks |
| `DATABASE_URL` | Your Postgres provider (Supabase, per HP-ADR-001 §3.1) | Must point at the `hp_app` role, never an owner/superuser role — HP-RB-001 §2 |
| `DATA_REGION` | Fixed: `IN` | HP-ADR-003/HP-ADR-004 — Mumbai `ap-south-1`, no hard requirement to change this in v1 |
| `SUBJECT_HMAC_KEY` | Generate once, store in Vercel's encrypted env store, never rotate without a migration plan (ADR-003 §2.3: rotate via `subject_key`, never reuse across regions) | 32+ random bytes, base64-encoded, prefixed `base64:` — see `.env.example` |
| `SUPABASE_JWT_SECRET` | Your Supabase project's JWT secret (Project Settings → API) | HS256 shared secret — see `src/lib/auth.ts`'s header comment for the ES256/JWKS migration path if the project later moves off shared-secret signing |
| `RED_FLAG_RULESET_VERSION` | e.g. `rf-rules-2026.08.1` | Selects the active row-set in `safety.red_flag_rule` — bump only through the §6.3 change-control process, and re-run `npm run eval` first (§6.4) |
| `PROMPT_VERSION_COMPOSE` | e.g. `compose-2026.08.1` | Matches the version string in `src/lib/prompts/registry.ts` |
| `POLICY_VERSION` | e.g. `HP-SCHEMA-001-v0.4` | Informational — not currently read by any code path this repo builds, kept for parity with `.env.example` |
| `SIDE_EFFECT_DISPATCH_URL` | The Fly.io worker's internal URL, IF you wire the optional best-effort HTTP ping (§2 below) | Optional — `sideEffectDispatcher.ts`'s durable enqueue works with this unset; it only skips the low-latency ping |

Set `maxDuration` in `vercel.json` (currently 60s) higher if a real Anthropic call plus retrieval plus streaming synthesis is observed to routinely exceed that — HP-ADR-001 §3.4 cites Vercel Pro's ceiling at 800s.

**Before the first deploy:** apply the real database migrations (not `db/*.sql` — those are this repo's own stub/test schema, see README's "Stub schema vs. real migrations" section) against your actual Supabase project, per whatever migration tooling that project uses.

## 2. The side-effect worker (Fly.io)

**Code:** `worker/side-effect-worker.mjs`, `worker/package.json`, `worker/Dockerfile`, `worker/fly.toml`.

**VERIFIED in this sandbox:**
- `npm install --omit=dev` against `worker/package.json` alone (no repo-root `package.json` involved) — 0 vulnerabilities, 14 packages.
- Running `node side-effect-worker.mjs --once` from that standalone install, against the real local Postgres this repo's other tests use, with `DATABASE_URL` pointed at `hp_app` — successfully drained a real `CLINICIAN_REVIEW` job end to end (claimed via `SELECT ... FOR UPDATE SKIP LOCKED`, processed, marked `DONE`).
- The retry path: an unrecognized job `kind` was requeued twice and marked `FAILED` on the third attempt, exactly matching `WORKER_MAX_ATTEMPTS=3`'s intended behaviour — checked against the actual `side_effect_job.attempts`/`status` columns afterward, not just the console output.
- `worker/fly.toml` parses as valid TOML.

**UNVERIFIED — needs a Fly.io account, and a container registry this sandbox's network policy allows (it has neither):**
- Building the `worker/Dockerfile` image itself. Every command inside it (`npm install --omit=dev`, `node side-effect-worker.mjs`) was run directly, unsandboxed, with the same working directory layout the Dockerfile produces. The Docker daemon itself *can* run in this sandbox (`dockerd` starts and `docker ps`/`docker run` against a local image work) — but `docker build`'s `FROM node:22-slim` line needs to pull from Docker Hub, and this sandbox's egress proxy explicitly denies every container registry it was tested against (Docker Hub, ghcr.io, gcr.io, quay.io, public.ecr.aws — all HTTP 403 at the gateway, confirmed via the proxy's own status endpoint, not a timeout). So the build was never executed here, for a network-policy reason rather than a missing-daemon one.
- `fly launch` / `fly deploy` / `fly secrets set` — Fly.io CLI is not installed here, and there is no account to launch against.
- Whether Fly.io's Mumbai region code (`bom`, set as `primary_region` in `fly.toml`) has capacity available on a real account — region availability varies and this has not been checked against a live Fly.io org.

### Steps (for you to run)

```bash
cd worker
fly launch --no-deploy   # creates the app, confirms/adjusts the app name and region from fly.toml
fly secrets set DATABASE_URL='postgres://hp_app:...@<your-host>:5432/<your-db>'
fly deploy
```

`fly.toml` deliberately has no `[[services]]`/`[http_service]` block and no autostop/autostart config — this process holds a long-lived Postgres connection and polls continuously; it is meant to run as one always-on machine, not scale to zero between requests the way an HTTP service would. `fly status` should show it running continuously after deploy, not cycling.

### Optional: the low-latency ping

`sideEffectDispatcher.ts`'s `pingWorker()` does a best-effort HTTP POST to `SIDE_EFFECT_DISPATCH_URL` for anything worth nudging sooner than the worker's normal poll interval (e.g. an EMERGENCY-severity concurrent notify). The worker in this repo does not currently expose an HTTP listener to receive that ping — it is a pure polling consumer. Wiring up a small HTTP receiver in the worker (to shortcut its own next poll rather than waiting `WORKER_POLL_INTERVAL_MS`) is a reasonable follow-on, not built here: the durable queue is the source of truth regardless (`pingWorker`'s own comment: "If this fails, the enqueued row above is still the source of truth"), so its absence degrades latency, not correctness.

## 3. What this does NOT cover

- Provisioning the real Supabase project, its real migrations, or its RLS policies against real data — see README's "Stub schema vs. real migrations" and "RLS" sections for what's stubbed here vs. what a real deployment needs.
- A CDN/WAF in front of Vercel (Cloudflare, per HP-ADR-002) — not configured here.
- Secrets rotation, backup/restore drills, or on-call paging integration for the worker's stub handlers (see `worker/side-effect-worker.mjs`'s own header comment on exactly what's stubbed there).
- CI deployment automation (a GitHub Actions job that runs `vercel deploy`/`fly deploy` on merge to main) — `../.github/workflows/chat-pipeline-ci.yml` only runs tests; wiring an actual deploy step needs `VERCEL_TOKEN`/`FLY_API_TOKEN` secrets in the GitHub repo, which (like everything else in this section) needs real accounts this sandbox doesn't have.
