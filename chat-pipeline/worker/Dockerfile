# Always-on side-effect worker (HP-ADR-001 §3.4: "a separate always-on Node
# worker on Fly.io for everything else" — Vercel Functions cap at 800s max
# duration and are not long-lived, so the side_effect_job queue consumer
# (worker/side-effect-worker.mjs) cannot live there).
#
# Deliberately minimal: this worker has exactly one runtime dependency (pg)
# and no build step (plain .mjs, no bundler) — matching src/lib's own
# principle of the fewest moving parts that still catch real bugs (see
# scripts/smoke-test.mjs's header comment on the same theme).
#
# Build context is THIS directory (worker/), not the repo root — fly.toml
# lives here too and `fly deploy` is meant to be run from inside worker/, so
# every COPY path below is relative to worker/, not the repo root. (Verified
# by actually building this image, not just read — see DEPLOY.md.)
FROM node:22-slim

WORKDIR /app

# Only the worker's own dependency graph — NOT the full Next.js app's
# package.json, which pulls in next/react/zod/jose etc. this process never
# uses. A separate, minimal manifest keeps the worker's image small and its
# dependency surface honest about what it actually needs.
COPY package.json package-lock.json* ./
RUN npm install --omit=dev

COPY side-effect-worker.mjs ./

# No HEALTHCHECK/EXPOSE — this process serves no HTTP traffic of its own; it
# only holds an outbound connection to Postgres. Fly.io's own process
# supervision (see fly.toml) is what restarts it if it exits.
CMD ["node", "side-effect-worker.mjs"]
