# Always-on alert worker (HP-ADR-001 §3.4: "a separate always-on Node worker on
# Fly.io for everything else" — Vercel Functions cap at 800s max duration and are
# not long-lived, so a polling consumer cannot live there).
#
# WHAT CHANGED. This image used to run worker/side-effect-worker.mjs, the
# consumer for the stub-invented `side_effect_job` queue. That table exists only
# in chat-pipeline/db/010 and never existed in the real schema; the worker's
# three handlers were all `console.log('would ...')`, and its one real
# responsibility — §4.0.5 emergency notification — moved to RF6 (migration 029)
# in a previous change. Both the queue and its consumer are gone; see
# src/lib/pipeline/sideEffectDispatcher.ts's header for where the review
# obligation is recorded now.
#
# worker/alert-worker.mjs is what remains and what this image runs: the RF6
# clinician-alert delivery loop, which claims alerts through
# safety.claim_alert_batch and records DELIVERED or UNDELIVERABLE. It is the one
# worker in this repository that performs a real, asserted side effect.
#
# ⚠ IT REFUSES TO START WITHOUT DATA_REGION. Migration 035 made the claim
# region-scoped, so a worker with no region drains an empty batch and reports
# healthy silence on the §4.1 path. Set it with `fly secrets set` or in
# fly.toml's [env]; the process exits non-zero rather than run without it.
#
# Deliberately minimal: exactly one runtime dependency (pg) and no build step.
#
# Build context is THIS directory (worker/), not the repo root — fly.toml lives
# here too and `fly deploy` is meant to be run from inside worker/, so every COPY
# path below is relative to worker/.
FROM node:22-slim

WORKDIR /app

# Only the worker's own dependency graph — NOT the full Next.js app's
# package.json, which pulls in next/react/zod/jose etc. this process never uses.
COPY package.json package-lock.json* ./
RUN npm install --omit=dev

COPY alert-worker.mjs ./

# No HEALTHCHECK/EXPOSE — this process serves no HTTP traffic of its own; it only
# holds an outbound connection to Postgres. Fly.io's own process supervision (see
# fly.toml) is what restarts it if it exits.
CMD ["node", "alert-worker.mjs"]
