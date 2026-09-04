# HealthPlus pg-boss worker — HP-OIR-003 build item 8.
#
# Runs src/worker.ts directly via tsx rather than compiling to JS first: the
# tsconfig's "module": "ESNext" + "moduleResolution": "Bundler" combination
# (chosen for the vitest/dev workflow) does not emit Node-ESM-resolvable
# relative imports from a plain `tsc` build without every relative import
# rewritten to carry an explicit .js extension. tsx sidesteps that entirely
# and is a normal, supported way to run a small worker in production; if this
# repo grows enough to want a real build step, revisit then.

FROM node:22-slim

WORKDIR /app

# Install dependencies first so this layer caches across code-only changes.
# --omit=dev skips vitest/typescript/@types — pure dev tooling not needed to
# run the worker, and, as of this writing, the only source of npm audit
# findings in this repo (esbuild/vite/vitest, all transitive dev deps).
# tsx is a normal (non-dev) dependency, so it IS installed here — it's how
# the worker actually runs, not a build tool.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY tsconfig.json ./
COPY src ./src

# Deliberately NOT copying migrations/ into the runtime image: migrations are
# run once, out of band, from a developer machine or CI
# (`npm run migrate` / `node migrations/run_migrations.mjs`), never by the
# worker process itself at boot. Keeping them out keeps the image smaller and
# keeps "apply schema changes" and "run the worker" as two separate,
# separately-reviewable actions.

ENV NODE_ENV=production

CMD ["npm", "run", "start"]
