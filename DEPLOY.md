# Deploying HealthPlus

**One run-book for the whole deployment.** There used to be two — this file for the
pg-boss worker and `chat-pipeline/DEPLOY.md` for the web app — which between them described
two of the four processes and, after the R10 cutover, described several things that are no
longer true. `chat-pipeline/DEPLOY.md` now points here.

Read §0 before anything else. It is short and it changes what "working" means.

---

## §0. What a correct deployment does today

**It refuses to answer health questions, and that is the system working.**

Charter §4 is not adopted: CL2–CL5 are unsigned, so there is no clinically adopted red-flag
rule set. `safety.adopted_rule_set()` returns nothing, `resolveAdoptionGate()` returns
FAIL_CLOSED, and **every message** — not only risky ones — ends in the unavailability notice:

```
intent → category → unavailable ("We can't answer health questions right now")
                  → done: SAFETY_UNAVAILABLE
```

Measured on a database built from `migrations/` with no clinical sign-off, driven with an
ordinary question about post-operative recovery.

This is §0.6 / AMB-17 working as designed: *"we scanned and found nothing"* and *"we never
scanned"* both produce NORMAL, and only one of them is an assessment. It cannot be worked
around — `safety.red_flag_rule.adopted_by` and `approved_by` are foreign keys into
`principal.clinician`, so seeding rules to make it answer would mean writing a clinician's
name against a sign-off that did not happen.

**So deploy for the infrastructure, not for the answers.** Everything below can be completed,
verified and left running; what it will serve is CL5-ADD-001's unavailability copy, which was
written for exactly this state. The day CL2–CL5 are signed, the gate opens with no code change.

---

## §1. The four processes

Two of these did not exist in the old documents.

| # | Process | Runs where | Entry point | Connects as |
|---|---|---|---|---|
| 1 | **Web app** | Vercel | `chat-pipeline/` (Next.js) | `hp_app` + `reasoner_role` + `redflag_role` |
| 2 | **Alert worker** | Fly.io | `chat-pipeline/worker/alert-worker.mjs` | `alert_role` |
| 3 | **Ingestion worker** | Fly.io | `src/worker.ts` (pg-boss) | `queue_role` + `dqe_role` |
| 4 | **Safety metrics** | scheduled | `src/jobs/computeSafetyMetrics.mjs` | `metrics_role` |

The web app opens **three** connections as three different roles, and this is the point rather
than an implementation detail: `hp_app` takes untrusted user input and can read no health
attribute and write no safety row; `reasoner_role` walks the retrieval and profile path;
`redflag_role` writes safety events. R13-conn chose one LOGIN role per worker role precisely so
that a SQL injection reached through retrieval cannot write a §4.0.7 safety event.

**Since R10g there is no fallback.** `chat-pipeline/src/lib/db.ts` refuses to construct a pool
with no connection string of its own. A missing `DATABASE_URL_REASONER` is a start-up error,
not a silent degradation — because falling back runs retrieval as `hp_app` and fails with a
permission error three frames inside a PL/pgSQL function, which reads as a broken grant rather
than a missing secret.

---

## §2. Order of operations

Each step has a check. Do not start the next one until the check passes.

### Step 1 — Apply the schema

```bash
export DATABASE_URL='postgresql://postgres:<pw>@<host>:5432/postgres'   # the OWNER connection
node migrations/run_migrations.mjs
```

`migrations/` is the only schema. (`chat-pipeline/db/` was a stub of an upstream schema that
did not exist when the pipeline was written; it had drifted in twelve places and R10g deleted
it. Any document still mentioning it is stale.)

Migrations `042`–`047` each assert their own effect and will fail the run rather than report a
success they did not achieve.

> **Order matters once, and only here.** Migration `047` puts the region inside the audit log's
> hash chain and recomputes the existing rows to match. That is legitimate exactly while nobody
> has been told what the old chain head was — so `047` **refuses to run** if
> `public.audit_anchor` holds any row, and says so rather than rewriting anyway.
>
> Practical consequence: **apply the schema before writing the genesis anchor** (HP-RB-001 §10,
> item 6). On a database that has never held an audit event — which is every new deployment —
> there is nothing to rewrite and the order is moot. On one that has, the anchor is the point of
> no return. Re-applying `047` afterwards is safe: it only refuses when it would actually change
> bytes.

**Check:**

```sql
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname IN ('principal','safety','obs','evidence','domain');   -- non-zero
SELECT code FROM public.region_registry;                                 -- IN and ZZ
SELECT * FROM public.residency_admission WHERE admission_state='ADMITTED';  -- at least one
```

> **Note on `pg_cron`.** `migrations/ops/dqe_cron_schedule.sql` is **not** a numbered migration
> and `run_migrations.mjs` does not apply it. Enable the `pg_cron` extension in the Supabase
> dashboard (Database → Extensions) and run that file separately, once, when you want the five
> data-quality checks scheduled.

---

### Step 2 — Set the role passwords, out of band

No migration sets a password. `ALTER ROLE … PASSWORD` is **cluster-wide**, so a migration that
set one would change that credential on every database in the cluster, and a password in a
migration is a password in git.

Generate six distinct strong passwords and run this **once**, as the owner, against the live
database — from a shell whose history you control, not from a file in the repo:

```sql
ALTER ROLE hp_app        WITH PASSWORD '…';
ALTER ROLE reasoner_role WITH PASSWORD '…';
ALTER ROLE redflag_role  WITH PASSWORD '…';
ALTER ROLE alert_role    WITH PASSWORD '…';
ALTER ROLE metrics_role  WITH PASSWORD '…';
ALTER ROLE queue_role    WITH PASSWORD '…';
ALTER ROLE dqe_role      WITH PASSWORD '…';
```

**Check** — each must connect, and `hp_app` must *not* be able to read a patient attribute:

```bash
psql "postgresql://hp_app:<pw>@<host>:5432/<db>" -c 'SELECT 1'
psql "postgresql://reasoner_role:<pw>@<host>:5432/<db>" -c 'SELECT 1'
# ... and so on for each

# this MUST fail with "permission denied" — if it succeeds, stop and investigate
psql "postgresql://hp_app:<pw>@<host>:5432/<db>" \
  -c 'SELECT count(*) FROM principal.patient_attribute'
```

That last one failing is the deployment's single most load-bearing check. HP-RB-001 §2: *"the
application must never connect as owner or superuser — if it does, every control below is
decorative."*

---

### Step 3 — The web app (Vercel)

Set **Root Directory** to `chat-pipeline` in the Vercel project settings, or the build will find
the repo root's `package.json` instead.

| Variable | Value | Required |
|---|---|---|
| `DATABASE_URL` | `hp_app` connection string | **yes** |
| `DATABASE_URL_REASONER` | `reasoner_role` connection string | **yes** — no fallback since R10g |
| `DATABASE_URL_REDFLAG` | `redflag_role` connection string | **yes** — no fallback since R10g |
| `DATA_REGION` | `IN` | **yes** — validated as two uppercase letters at pool construction |
| `SUBJECT_KEY_WRAPPING_KEY` | `base64:` + **exactly 32 random bytes** | **yes** |
| `SUPABASE_JWT_SECRET` | Supabase project's JWT secret (Settings → API) | **yes** |
| `ANTHROPIC_API_KEY` | Anthropic Console | **yes** |
| `POLICY_VERSION` | e.g. `HP-SCHEMA-001-v0.4` | recommended — written into every audit row; defaults to `unspecified` |
| `PROMPT_VERSION_COMPOSE` | e.g. `compose-2026.08.1` | recommended |
| `ALLOW_OPUS_ON_LIVE_PATH` | unset | optional |
| `SIDE_EFFECT_DISPATCH_URL` | unset | optional; a latency nudge, not a correctness path |

**Two variables from the old document are gone and must not be set:**

- **`SUBJECT_HMAC_KEY`** — replaced by `SUBJECT_KEY_WRAPPING_KEY`. The old one was a single
  process-wide HMAC secret standing in for the per-subject key table, and under it *erasure
  deleted nothing*: every pseudonym stayed recomputable from a `user_id` and one env var. The
  new one wraps a per-subject DEK the database mints, so `principal.erase_subject` nulling the
  salt makes the link genuinely unrecoverable. It must be **exactly** 32 bytes —
  `subjectKey.ts` refuses anything else rather than deriving quietly.
- **`RED_FLAG_RULESET_VERSION`** — no longer read by anything. R3 replaced it with
  `safety.adopted_rule_set(jurisdiction, language)`. An env var could name a rule set that was
  never adopted; the function cannot.

Generate the wrapping key with:

```bash
echo "base64:$(head -c 32 /dev/urandom | base64)"
```

**Check:** open the deployed app and send any health question. You should get the
unavailability notice (§0). If you get an error instead, read the logs — a missing
`DATABASE_URL_REASONER` fails at pool construction with a message naming the variable.

---

### Step 4 — The alert worker (Fly.io)

This is the §4.1 critical path: it delivers CRITICAL/EMERGENCY clinician alerts.

```bash
cd chat-pipeline/worker
fly launch --no-deploy          # confirm app name and region (bom = Mumbai) from fly.toml
fly secrets set DATABASE_URL='postgresql://alert_role:<pw>@<host>:5432/<db>'
fly deploy
```

`DATA_REGION=IN` is already set in `fly.toml` — it is not a secret, it names a region — and the
worker **exits non-zero without it**, because migration 035 scoped its batch claim by region
and a region-less worker drains an empty batch while reporting success.

Optional, both with defaults: `ALERT_POLL_INTERVAL_MS` (5000), `ALERT_BATCH_SIZE` (20).

`fly.toml` deliberately has no `[[services]]`/`[http_service]` block and no autostop — this
process holds a long-lived connection and polls. `fly status` should show it running
continuously, not cycling.

**Check:** `fly logs` shows it claiming batches. With no delivering channel configured yet
(§6), every alert is recorded UNDELIVERABLE — **loudly and on purpose**. That is RF6's whole
point: an alert that reached nobody must not look like success.

---

### Step 5 — The ingestion worker (Fly.io)

```bash
fly launch --no-deploy          # from the repo root; uses ./fly.toml
fly secrets set DATABASE_URL='postgresql://queue_role:<pw>@<host>:5432/<db>'
fly secrets set DATABASE_URL_DQE='postgresql://dqe_role:<pw>@<host>:5432/<db>'
fly secrets set ANTHROPIC_API_KEY='…'
fly deploy
```

**`DATABASE_URL` here is `queue_role`, not `hp_app`.** This is the one place the run-book
departs from "the application connects as `hp_app`", and it is not a choice — it is a
measurement:

pg-boss creates and migrates its own `pgboss` schema on start, which needs CREATE on the
**database**. No application role has it, by design. Pointed at `hp_app`, this process fails
with `permission denied for database` before registering a single job handler. Owning the
schema is not enough either — pg-boss issues its own `CREATE SCHEMA IF NOT EXISTS` regardless.

Migration 046 creates `queue_role` for exactly this: it holds CREATE on the database and
**USAGE on none of** `principal`, `safety`, `obs`, `evidence` or `domain`. It can manage a job
queue and cannot read a patient, a claim, a safety event or an audit row. The migration asserts
that boundary and fails if a later grant widens it.

`DATABASE_URL_DQE` is separate because the ingestion job's actual work — claim extraction,
provider submissions, data-quality flags — runs as `dqe_role`, which has the evidence grants.
Unlike the web app's pools, this one still falls back to `DATABASE_URL` if unset, and
`poolRoleBindings()` reports the fallback rather than hiding it. Set it.

Also optional: `ANTHROPIC_MODEL_CLAIM_EXTRACTION`, `PROVIDER_PORTAL_BASE_URL`.

**Check:** `fly logs` shows
`[worker] pg-boss started, extractClaimsFromProviderSubmission registered.`

---

### Step 6 — Safety metrics, and the release gate

```bash
DATABASE_URL='postgresql://metrics_role:<pw>@<host>:5432/<db>' \
DATA_REGION=IN \
node src/jobs/computeSafetyMetrics.mjs --days 7
```

Schedule it daily (Fly machine cron, GitHub Actions schedule, or pg_cron — the job is a plain
Node process and does not care).

**Check — and expect it to BLOCK.** With CL9's red-flag gold set unsigned, two of the six §6.5
metrics are unmeasurable, and the §6.4 release gate reports BLOCK on both. That is correct:
a gate that passed without a gold set would be reporting a safety property nobody has
measured. `migrations/test/j34_metrics.sh` asserts exactly this shape in CI.

Note that since migration 044 the `obs.v_metric_*` views run as their **caller**, so any
dashboard role you add needs SELECT on the base tables — and gets the region boundary applied,
which it did not before.

---

## §3. Verifying the deployment as a whole

Run these against the live database once everything is up.

```sql
-- 1. The application cannot reach health data directly.  MUST return false.
SELECT has_table_privilege('hp_app','principal.patient_attribute','SELECT');

-- 2. Retrieval's role can execute the retrieval path.    MUST return true.
SELECT has_function_privilege('reasoner_role',
       'evidence.policy_for(source_tier,claim_kind,response_category)','EXECUTE');

-- 3. No view bypasses row-level security.                MUST return 0.
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE c.relkind='v' AND n.nspname NOT IN ('pg_catalog','information_schema')
   AND NOT coalesce(array_to_string(c.reloptions,',') LIKE '%security_invoker=true%',false);

-- 4. No constraint trigger decides on the caller's slice. MUST return 0.
SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE p.prorettype='trigger'::regtype AND NOT p.prosecdef
   AND n.nspname NOT IN ('pg_catalog','information_schema')
   AND p.prosrc ~ '(FROM|JOIN|INTO|UPDATE|DELETE FROM)\s';

-- 5. The queue role reaches nothing.                     MUST return false, five times.
SELECT has_schema_privilege('queue_role', s, 'USAGE')
  FROM unnest(ARRAY['principal','safety','obs','evidence','domain']) s;

-- 6. §4 adoption — expected EMPTY until CL2-CL5 are signed. See §0.
SELECT * FROM safety.adopted_rule_set('IN','en');

-- 7. The audit chain verifies end to end.  MUST return 0 bad, and this is the
--    query the nightly job should run (HP-RB-001 §7 — it used to live only in
--    that document; migration 047 made it an object so it can be executed).
SELECT count(*) FILTER (WHERE NOT hash_ok OR NOT link_ok) AS bad,
       count(*) AS events
  FROM public.verify_audit_chain();

-- 8. Nothing pseudonym-bearing is left unscoped by region.  MUST return 0.
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE c.relkind='r' AND NOT c.relrowsecurity
   AND c.oid IN (SELECT attrelid FROM pg_attribute
                  WHERE attname IN ('subject_pseudonym','subject_ref') AND attnum > 0);
```

Checks 3 and 4 are the two that were false in production shape until migrations 044 and 045,
and neither was visible to any test running as the owner. Check 8 was 1 until migration 047 —
the one table left was the immutable audit log itself.

---

## §4. What this does not cover

- **A CDN/WAF** in front of Vercel (Cloudflare, per HP-ADR-002).
- **A delivering alert channel.** `safety.alert_channel` has no delivering row, so every alert
  is recorded UNDELIVERABLE. Choosing one is RF6-channel and it needs your account.
- **A reviewer console.** `obs.response_audit.review_state = 'PENDING'` records the §2.2.5b
  obligation and nothing reads it; `obs.review_queue_item.clinical_domain` is NOT NULL and
  nothing produces one (R10b, parked pending the clinical lead).
- **Backup/restore rehearsal** (V10) — do this before the first real record, not after.
- **The external anchor and the nightly verification job** (HP-RB-001 §6-§7, items 5-7 of that
  runbook's order-of-execution list). The *query* is no longer missing — `public.verify_audit_chain()`
  exists and §3 check 7 runs it — but nothing schedules it, and no anchor bucket exists. A hash
  chain inside a database proves nothing against whoever controls that database; what makes it
  evidence is publishing its head somewhere you do not control. Note the ordering in Step 1:
  the first anchor is what freezes the chain's canonical form.
- **Secrets rotation.** Rotating `SUBJECT_KEY_WRAPPING_KEY` needs a plan: it wraps every
  subject DEK, so a rotation must re-wrap them, not merely replace the key.
- **CI deployment automation.** The workflows run tests only; a deploy step would need
  `VERCEL_TOKEN`/`FLY_API_TOKEN` as GitHub secrets.

---

## §5. What has been verified here, and what has not

Following the distinction this repo's other documents draw.

**Verified by execution** against a real Postgres 16 + pgvector, on a database built only from
`migrations/`:

- all 50 migrations apply clean, and re-apply
- pg-boss starts as `queue_role` and fails as every application role
- the whole pipeline runs end to end, as `hp_app`/`reasoner_role`/`redflag_role` over password
  auth, and produces the §0 unavailability result on an unsigned schema
- seventeen gates in `migrations/test/`, both DB-backed suites, 120 unit tests, the 51-case
  eval gate — every one of them twice in a row, against the same database, so a gate that only
  works once shows up as a gate that only works once (one did)
- the alert worker's both outcomes and its region scoping (`rf6_alert_delivery.sh`)
- the metrics job and its BLOCK verdict (`j34_metrics.sh`)
- the audit chain: 19 events written by the pipeline itself verify 0 bad / 19, and the migration
  that rewrote it refuses to run once `public.audit_anchor` holds a row — checked in both
  directions, on a log with rows and on one without

**Unverified — needs your accounts.** No Vercel, Fly.io or Supabase account exists in the
environment this was written in, and container registries are blocked there, so: `vercel deploy`,
`fly launch/deploy/secrets`, the `Dockerfile` builds themselves (every command inside them was
run directly, in the same layout), and whether Fly's `bom` region has capacity on your org.
Treat the first real deploy as the first true test of those.
