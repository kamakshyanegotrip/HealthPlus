# Deploying the pg-boss worker to Fly.io

HP-OIR-003 build item 8. Everything up to "create a Fly.io account" is done
and verified in this repo; account creation and the actual deploy are yours
to run — Claude can't create accounts or hold your API tokens/secrets.

## What's already verified (this session, in a sandbox — not on Fly.io itself)

- `src/worker.ts` — the process entrypoint. Starts pg-boss against
  `DATABASE_URL`, registers `extractClaimsFromProviderSubmission`, and
  shuts down gracefully on `SIGTERM` (what Fly sends on deploy/stop) —
  confirmed by actually running it against a real local Postgres and
  watching it log `pg-boss started, extractClaimsFromProviderSubmission
  registered.` before being sent `SIGTERM` and exiting cleanly.
- `Dockerfile` — `npm ci --omit=dev` (confirmed clean: 0 vulnerabilities,
  since the only `npm audit` findings in this repo are in the dev-only
  vitest/esbuild/vite chain, not anything the worker actually runs) then
  `npm run start`. **Not build-tested with `docker build` itself** in this
  session — the sandbox's network egress blocked Docker Hub
  (`registry-1.docker.io: Forbidden`) — but the two things that could break
  it (the lockfile installing cleanly, and the worker booting from
  production-only `node_modules`) were both verified directly.
- `fly.toml` — region `bom` (Mumbai), matching the Supabase project's
  `ap-south-1`; a `[processes]` worker entry, no `[http_service]` (this
  process takes no inbound traffic).

## What you need to do

1. **Create a Fly.io account** at [fly.io](https://fly.io) if you don't have
   one, and install `flyctl` (the Fly CLI) per their install instructions
   for your OS.
2. **Push the two commits already sitting in your local repo** (if you
   haven't already — see the two commits `8c0ddb9` and `919c4a7` on `main`,
   ahead of `origin/main`):
   ```powershell
   cd "D:\Health Plus"
   git push
   ```
3. **Run the migrations against your live Supabase database**, if you
   haven't already (HP-OIR-003 build item 3 — see `migrations/README.md`).
   The worker will start regardless, but its job will fail at runtime
   against tables that don't exist yet.
4. **From `D:\Health Plus`, log in and launch:**
   ```powershell
   fly auth login
   fly launch --no-deploy
   ```
   `--no-deploy` lets you confirm/edit the generated app name and region
   before anything actually ships. It will likely offer to overwrite this
   repo's `fly.toml` — decline, or diff afterward, so the Mumbai region and
   worker-process config aren't silently replaced with Fly's defaults.
5. **Set your secrets** (never commit these; this is the one place they
   belong):
   ```powershell
   fly secrets set DATABASE_URL="postgresql://postgres:<password>@<host>:5432/postgres"
   fly secrets set ANTHROPIC_API_KEY="sk-ant-..."
   fly secrets set ANTHROPIC_MODEL_CLAIM_EXTRACTION="<confirm the exact Opus model id first — see the README's flagged assumption>"
   ```
   Use the **Direct connection** string from Supabase (Project Settings >
   Database > Connection string > Direct connection), not the pooler — see
   the top-level README for why Direct is correct for a long-running worker
   like this one.
6. **Deploy:**
   ```powershell
   fly deploy
   ```
7. **Verify it's actually running:**
   ```powershell
   fly logs
   ```
   You should see the same `[worker] pg-boss started,
   extractClaimsFromProviderSubmission registered.` line this session saw
   locally. If you see a Postgres auth or connection error instead, recheck
   the `DATABASE_URL` secret — this is the most common first failure and is
   exactly what this session's own local runs surfaced when the connection
   string was wrong.

## What this does not cover

- Scaling, alerting, and restart-policy tuning — the `fly.toml` above is a
  minimal, correct starting point (`shared-cpu-1x`, 512MB), not a
  production-sized config. Revisit once you see real job volume.
- Confirming `ANTHROPIC_MODEL_CLAIM_EXTRACTION`'s exact model identifier
  against Anthropic's current model list — flagged as an open assumption in
  the top-level README since this task was first written; confirm it before
  the first real extraction job runs, not after.
