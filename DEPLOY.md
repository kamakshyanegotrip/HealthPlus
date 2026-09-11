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

> **And on that day, expect the opposite failure — by design.** §2.2.5b trigger 2 checks each
> message against the §2.4.1 Elevated-Risk Topic List. Migration `048` ships that list with the
> Charter's fourteen topics carrying **empty terms and none adopted**, so the trigger cannot be
> evaluated, §3.0.3 resolves it closed, and every response is held at `review_state = 'PENDING'`
> with `review_triggers` containing `ELEVATED_TOPIC_UNEVALUABLE`. That is not a bug and it is
> not the same state as "checked, nothing matched" — the audit row distinguishes them precisely
> so an auditor can tell them apart later.
>
> The topic list is **not** on CGP-001 §9's ninety-day schedule, so *"rule set signed, topic
> list not"* is the expected intermediate state rather than an edge case. Adopting a topic
> requires a named clinician (`adopted_by` → `principal.clinician`) and at least one term, the
> same way a red-flag rule does. Until then the system answers nothing before the gate and holds
> everything after it, and both are the fail-closed reading.

---

## §1. The five processes

Three of these did not exist in the old documents.

| # | Process | Runs where | Entry point | Connects as |
|---|---|---|---|---|
| 1 | **Web app** | Vercel | `chat-pipeline/` (Next.js) | `hp_app` + `reasoner_role` + `redflag_role` |
| 2 | **Alert worker** | Fly.io | `chat-pipeline/worker/alert-worker.mjs` | `alert_role` |
| 3 | **Ingestion worker** | Fly.io | `src/worker.ts` (pg-boss) | `queue_role` + `dqe_role` + `patient_upload_role` |
| 4 | **Safety metrics** | scheduled | `src/jobs/computeSafetyMetrics.mjs` | `metrics_role` |
| 5 | **Storage erasure drain** | scheduled | `src/jobs/drainStorageErasure.ts` | `storage_erasure_role` |

**NEW (migration 051).** Process 5 closes the gap migration 050 shipped with a comment instead of
code: `erase_subject` deletes the `patient_upload_document` row but never touched the bytes it
pointed at in Supabase Storage. Migration 051 makes `erase_subject` enqueue the object's bucket
and path into `principal.storage_erasure_queue` in the same transaction as the rest of the
erasure; this process drains that queue — `DELETE`s the object from Supabase Storage, then clears
the row. Same "scheduled, standalone script" shape as process 4, not a pg-boss job — see the
file's own header. Run it `--once` on a schedule (Fly machine cron, GitHub Actions, or a
continuous poll loop) the same way process 4 is run; there is no requirement it run continuously.

**CHANGED (migration 050 / HP-RECON-007).** Process 3 is no longer poll-only: it also runs a
small inbound HTTP listener (`src/lib/webhookServer.ts`) that a Supabase Storage webhook calls
when a patient uploads a lab report, scan, or photo. The listener does one INSERT and one
`boss.send()`, transactionally, and returns — the Storage download and the Claude vision call
still happen inside the pg-boss job (`extractPatientUploadAttributes`), asynchronously, never in
the request handler. `fly.toml` for this process now has an `[http_service]` block; see Step 5.

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

Migrations `042`–`049` each assert their own effect and will fail the run rather than report a
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

Generate eight distinct strong passwords and run this **once**, as the owner, against the live
database — from a shell whose history you control, not from a file in the repo:

```sql
ALTER ROLE hp_app             WITH PASSWORD '…';
ALTER ROLE reasoner_role      WITH PASSWORD '…';
ALTER ROLE redflag_role       WITH PASSWORD '…';
ALTER ROLE alert_role         WITH PASSWORD '…';
ALTER ROLE metrics_role       WITH PASSWORD '…';
ALTER ROLE queue_role         WITH PASSWORD '…';
ALTER ROLE dqe_role           WITH PASSWORD '…';
ALTER ROLE patient_upload_role  WITH PASSWORD '…';
ALTER ROLE storage_erasure_role WITH PASSWORD '…';
```

**Check** — each must connect, and `hp_app` must *not* be able to read a patient attribute:

```bash
psql "postgresql://hp_app:<pw>@<host>:5432/<db>" -c 'SELECT 1'
psql "postgresql://reasoner_role:<pw>@<host>:5432/<db>" -c 'SELECT 1'
# ... and so on for each

# this MUST fail with "permission denied" — if it succeeds, stop and investigate
psql "postgresql://hp_app:<pw>@<host>:5432/<db>" \
  -c 'SELECT count(*) FROM principal.patient_attribute'

# patient_upload_role must reach principal.patient_upload_document and the two
# functions migration 050 grants it, and MUST NOT reach evidence/domain — this
# MUST fail with "permission denied":
psql "postgresql://patient_upload_role:<pw>@<host>:5432/<db>" \
  -c 'SELECT count(*) FROM evidence.claim'

# storage_erasure_role must reach its three verbs (via EXECUTE only) and MUST
# NOT be able to read the queue table directly — this MUST fail with
# "permission denied for table storage_erasure_queue":
psql "postgresql://storage_erasure_role:<pw>@<host>:5432/<db>" \
  -c 'SELECT count(*) FROM principal.storage_erasure_queue'
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
fly secrets set DATABASE_URL_PATIENT_UPLOAD='postgresql://patient_upload_role:<pw>@<host>:5432/<db>'
fly secrets set ANTHROPIC_API_KEY='…'
fly secrets set SUBJECT_KEY_WRAPPING_KEY='base64:…'
fly secrets set SUPABASE_URL='https://<project-ref>.supabase.co'
fly secrets set SUPABASE_SERVICE_ROLE_KEY='…'
fly secrets set SUPABASE_STORAGE_WEBHOOK_SECRET='…'
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

**`DATABASE_URL_PATIENT_UPLOAD` is new in migration 050.** `extractPatientUploadAttributes`
writes `principal.patient_attribute` (via `principal.record_inferred_attribute`) and
`principal.patient_upload_document`, and deliberately runs as neither `hp_app` nor `dqe_role` —
`dqe_role` "gets no reach into app_user, patient_profile, patient_attribute or subject_key"
(migration 037 §4) by design, and this job's whole purpose is the opposite of that boundary. It
also falls back to `DATABASE_URL` if unset; set it, the same as `DATABASE_URL_DQE`.

**`DATABASE_URL_STORAGE_ERASURE` is new in migration 051**, for process 5
(`drainStorageErasure.ts`) — `storage_erasure_role`'s own connection string, same fallback
contract as every other role pool in `src/db/pool.ts`. It reuses `SUPABASE_URL` and
`SUPABASE_SERVICE_ROLE_KEY` below (already required for the download side); no new Supabase-side
secret is needed for the delete side.

The remaining new secrets are for the same job:

| Variable | Value | Required |
|---|---|---|
| `DATABASE_URL_PATIENT_UPLOAD` | `patient_upload_role` connection string | **yes** — falls back to `DATABASE_URL` (queue_role) if unset, which cannot reach `principal` at all, so the job will fail-closed rather than run under-privileged |
| `SUBJECT_KEY_WRAPPING_KEY` | **the identical 32 bytes** set on the web app in Step 3 | **yes** — this worker unwraps the same per-subject DEKs `chat-pipeline` mints; a different key makes every write undecryptable to the other process |
| `SUPABASE_URL` | Supabase project URL | **yes** — used to download the uploaded object from Storage |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase service-role key (Settings → API) | **yes** — Storage downloads go through the REST API, not the DB connection |
| `SUPABASE_STORAGE_WEBHOOK_SECRET` | a strong random value, also configured on the Supabase Database Webhook itself (custom header) | **yes** — `webhookServer.ts` fails closed (rejects every request) if this is unset; see the caveat below |
| `PATIENT_UPLOAD_BUCKET` | Storage bucket name for patient uploads | optional — defaults to `patient-uploads` |
| `WEBHOOK_PORT` | must match `fly.toml`'s `[http_service] internal_port` | optional — defaults to `8080`, and `fly.toml` here already sets `internal_port = 8080` |
| `ANTHROPIC_MODEL_PATIENT_UPLOAD_EXTRACTION` | e.g. `claude-opus-4-5` | optional — Opus tier, per ADR-001 §3.6; see the model-tier note below |
| `PATIENT_UPLOAD_RESIDENCY_ACKNOWLEDGED` | `yes` | **required to activate this feature at all** — see the residency block below |

Also still optional: `ANTHROPIC_MODEL_CLAIM_EXTRACTION`, `PROVIDER_PORTAL_BASE_URL`.

> **This feature is blocked until `PATIENT_UPLOAD_RESIDENCY_ACKNOWLEDGED=yes` is set, on
> purpose.** Sending patient images/PDFs to the Anthropic API sharpens ADR-003 §2.1 / Charter
> §5.2a's "no health data leaves India" tension beyond what the existing text-only extraction job
> already carries. Put directly to the user rather than resolved unilaterally (HP-JOB-010 §4/§6):
> **block until formally resolved.** So as shipped: `worker.ts` does not register
> `extractPatientUploadAttributes` unless this env var is `yes`, and the webhook route answers
> every request with `503` regardless of authentication until it is — checked before the auth
> check, deliberately, so a leaked webhook secret does not get further than a correct one while
> the feature is off. This is the same explicit-acknowledgment-env-var shape
> `chat-pipeline/scripts/seed-demo.ts` already uses for `DEMO_SEED_I_UNDERSTAND`, not a new idiom.
> **Do not set this to `yes` without a resolution on record** — accept the tension formally, block
> the feature permanently, or pursue in-region hosting (ADR-001 §3.6's own Bedrock `ap-south-1`
> escape-hatch note) — and record whichever it is as an ADR. Setting the env var is not itself the
> decision.
>
> **Configure the Supabase side too**, once the residency decision clears this to activate. In
> the Supabase dashboard, create a Database Webhook on `storage.objects` (INSERT) pointed at
> `https://<this-fly-app>.fly.dev/webhooks/supabase-storage/patient-upload`, with a custom header
> carrying the same value as `SUPABASE_STORAGE_WEBHOOK_SECRET`. **Reconfirmed 2026-09-10** with a
> live fetch of `supabase.com/docs/guides/database/webhooks` and the community's own webhook-auth
> discussion (`github.com/orgs/supabase/discussions/14115`), not just prior research: Database
> Webhooks are still exactly a stored `net.http_post(url, body, params, headers, timeout)` call
> with no built-in HMAC or signature of any kind, and a static header set once at webhook-creation
> time is still the only Supabase-native mechanism — this deployment's shared-secret header is that
> mechanism, correctly used. The one thing that reconfirmation surfaced as a genuine gap, not
> closed here because it wasn't asked for: the community's fallback for stronger integrity
> protection (beyond "is the secret right") is to hand-roll HMAC-SHA256 signing on top — the
> "Standard Webhooks" pattern, a Postgres trigger that signs the payload with pgcrypto and a vault
> secret, sending an id/timestamp/signature triple this receiver would verify and reject if
> replayed. Worth doing if this secret is ever shared with a party you don't fully trust; not done
> here because a bearer secret behind TLS matches what was asked for.
>
> **Model tier: resolved.** ADR-001 §3.6 tiers Opus for "offline claim extraction and conflict
> resolution" generally; this job originally shipped on Sonnet per the original request. Put to
> the user directly (keep Sonnet with a formal ADR addition, switch to Opus for consistency, or
> leave it open) — the user chose consistency. `ANTHROPIC_MODEL_PATIENT_UPLOAD_EXTRACTION` now
> defaults to Opus, the same tier `ANTHROPIC_MODEL_CLAIM_EXTRACTION` uses; no ADR update needed
> since this no longer carves out an exception to §3.6's existing rule.
>
> **Storage-object erasure: closed by migration 051.** What migration 050 §7 left as a tracked
> follow-up — the uploaded object's bytes surviving in Supabase Storage after `erase_subject` —
> is now implemented, not just documented: `erase_subject` enqueues the object's bucket and path
> into `principal.storage_erasure_queue` in the same transaction as the rest of the erasure, and
> `src/jobs/drainStorageErasure.ts` (process 5, §1) drains that queue by calling Supabase
> Storage's `DELETE /storage/v1/object/{bucket}/{path}` and clearing the row. Two things worth
> knowing before you rely on it: (1) `assert_shred_complete` now correctly reports a
> `storage_erasure_queue` row as SURVIVING until the drain worker has actually run — checking it
> immediately after `erase_subject` for a subject who had uploads WILL show one surviving row,
> on purpose, so poll it rather than treating a single check right after erasure as final; (2) a
> failed Storage DELETE is left PENDING for retry, with no automatic terminal "gave up" state, so
> a `storage_erasure_queue` row with a rising `attempts` count is this worker's way of surfacing a
> stuck erasure — worth a dashboard/alert once this is live, not built here.

**Check:** `fly logs` shows one of two lines depending on whether the residency env var is set —

```
[worker] pg-boss started, extractClaimsFromProviderSubmission registered, extractPatientUploadAttributes registered, webhook listener on :8080.
[worker] pg-boss started, extractClaimsFromProviderSubmission registered, extractPatientUploadAttributes BLOCKED (residency not acknowledged), webhook listener on :8080.
```

If the residency decision has not cleared yet, the second line is correct and expected — this is
the feature working as designed, the same way §0 treats the unavailability notice as success, not
failure. Then, from outside, confirm the webhook endpoint refuses a request:

```bash
curl -i -X POST https://<this-fly-app>.fly.dev/webhooks/supabase-storage/patient-upload
# 503 if PATIENT_UPLOAD_RESIDENCY_ACKNOWLEDGED is unset — the feature is off
# 401/403 once it is set and this is an unauthenticated request — if it accepts silently
# instead, SUPABASE_STORAGE_WEBHOOK_SECRET is unset or wrong
```

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

-- 9. patient_upload_role reaches only what migration 050 grants it, and none
--    of evidence/domain.                                  MUST return false, three times.
SELECT has_schema_privilege('patient_upload_role', s, 'USAGE')
  FROM unnest(ARRAY['evidence','domain']) s
UNION ALL
SELECT has_table_privilege('patient_upload_role','principal.patient_attribute','SELECT');

-- 10. storage_erasure_role has no direct table privilege on the queue it
--     drains — every access goes through the three claim/mark verbs.
--                                                          MUST return false.
SELECT has_table_privilege('storage_erasure_role',
  'principal.storage_erasure_queue', 'SELECT,INSERT,UPDATE,DELETE');
```

Checks 3 and 4 are the two that were false in production shape until migrations 044 and 045,
and neither was visible to any test running as the owner. Check 8 was 1 until migration 047 —
the one table left was the immutable audit log itself. Check 9 is new with migration 050 —
`patient_upload_role` writes `patient_attribute` only through `record_inferred_attribute`
(SECURITY DEFINER), never by direct table grant, the same discipline migration 041 already
holds for `reasoner_role`'s read side. Check 10 is new with migration 051, same discipline again
— verified live in this build (see §5) with a direct `SELECT` attempt as `storage_erasure_role`,
which failed with `permission denied for table storage_erasure_queue` as required.

---

## §4. What this does not cover

- **A CDN/WAF** in front of Vercel (Cloudflare, per HP-ADR-002).
- **A delivering alert channel.** `safety.alert_channel` has no delivering row, so every alert
  is recorded UNDELIVERABLE. Choosing one is RF6-channel and it needs your account.
- **A reviewer console.** `obs.response_audit.review_state = 'PENDING'` records the §2.2.5b
  obligation and nothing reads it; `obs.review_queue_item.clinical_domain` is NOT NULL and
  nothing produces one (R10b, parked pending the clinical lead). Every held response logs
  `REVIEW REQUIRED AND NOT QUEUED` for this reason — CI's own integration logs show it. All
  five §2.2.5b triggers are implemented and fire correctly; what is missing is the human at
  the other end, and with the topic list unadopted (§0) that queue is *every* response.
- **An adopted Elevated-Risk Topic List.** Migration `048` seeds the fourteen §2.4.1 topics with
  no terms and no signature, and `safety.adopted_topic_list()` returns nothing until a clinician
  signs. Sheet D of the CGP-004 review pack is where the terms come from. See §0.
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
- ~~Deletion of Storage object bytes on erasure~~ — **closed by migration 051**; see Step 5's
  residency blockquote and §1 process 5.
- **A shared crypto package.** Assessed by execution, not implemented, and here is why it stops
  at assessment rather than going further. First, the assessment: the two files' stated invariant
  ("THE ENVELOPE FORMAT MUST STAY BYTE-IDENTICAL") was **verified true, live, in this session**,
  not just read and trusted — a script imported both `chat-pipeline/src/lib/subjectKey.ts` and
  this worker's `src/lib/subjectAttributeCrypto.ts` under a shared random wrapping key and
  round-tripped real ciphertext in both directions: `chat-pipeline`'s `encryptAttribute` decrypts
  correctly under the worker's exact byte layout, the worker's `encryptAttribute` decrypts
  correctly through `chat-pipeline`'s own `decryptAttribute`, `ATTRIBUTE_CIPHER_ALG` is the
  identical string in both, and a wrapped DEK built the way `chat-pipeline`'s (unexported) `wrap()`
  lays it out (`nonce | tag | ciphertext`) unwraps correctly through the worker's `getLiveSubjectKey`.
  Four checks, four matches. The duplication is real but it is not currently a live bug — both
  copies genuinely agree today.

  Second, why this stays a recommendation rather than a change made here: turning it into one
  `@healthplus/crypto` package both apps import is a cross-repo restructuring — npm workspace or
  private-registry wiring, a Vercel build-root change, a Fly `Dockerfile` change, and an import
  path change in both `subjectKey.ts`'s and `subjectAttributeCrypto.ts`'s callers — none of which
  can be deploy-verified in this environment (§5: no Vercel/Fly account exists here). Landing that
  blind, on a system whose whole design point is "no amount of reading substitutes for running
  it," would be the one change in this entire piece of work that violates its own standard. The
  concrete next step, when someone can deploy-verify it: extract exactly the four functions this
  worker already narrows to (`wrappingKey`/`unwrap`/`encryptAttribute`/the `getLiveSubjectKey`
  read path) into a package `chat-pipeline` re-exports from and this worker imports directly, and
  re-run the round-trip check against the package instead of the two duplicated files.
  `scripts/verify_crypto_compat.mjs` (new — `npx tsx scripts/verify_crypto_compat.mjs`, no
  database or secrets required, self-contained) is that check, committed as a permanent script
  rather than a one-off: run it now to confirm the duplication is still honest (4/4 pass as of
  this build), and re-point its two imports at the future shared package to turn it into that
  refactor's actual regression test.
- **A normalized test-name vocabulary.** `principal.record_inferred_attribute`'s `attribute_key`
  is currently `DIAGNOSTIC_RESULT:<documentId>:<testName>` — the test name as Claude's vision
  call transcribed it, verbatim, not resolved against a controlled vocabulary — so two uploads of
  the same lab test (e.g. "HbA1c" vs "Hemoglobin A1c" vs a lab's own house abbreviation) are not
  recognized as the same attribute for supersession; each upload creates a new, independently
  active row rather than superseding the prior one. Not implemented here: it is a **Category
  C/§2.4.1a Board decision**, the same class of call HP-SCHEMA-001 §17 already flagged for
  `domain.clinical_indicator` and Charter §2.3.2 requires be made by the Board, not inferred by a
  migration. The two ingredients a Board decision would need are already in this schema and this
  job, not missing: (1) `patient_attribute_kind` is an enum, not free text, so the Board is
  choosing a vocabulary shape (a fixed list of recognized test names vs. a fuzzy-match threshold
  vs. leaving it verbatim and accepting the duplication), not designing the column; (2) the
  extraction job already carries the printed test name as distinct data (see the next bullet),
  so resolving it against a future vocabulary table is additive, not a rework of what exists.
- **`printed_flag_verbatim` / the boundary between what the model reads and what it states.**
  Re-verified by reading the actual code, not assumed from the field name: the extraction prompt
  (`EXTRACTION_TASK_INSTRUCTIONS` in `src/jobs/extractPatientUploadAttributes.ts`) already draws
  this line explicitly — "Do not characterise, interpret, or comment on any result. Do not say
  whether a value is normal, abnormal, high, low, concerning, or reassuring... If the document
  itself prints a flag or annotation... transcribe that exact printed text into
  printed_flag_verbatim — do not add one that is not printed." This is enforced today by prompt
  instruction and by what the job's `zod` schema and Postgres payload carry (value, unit,
  reference range, and printed flag as transcribed strings; no field for an inferred severity or
  recommendation exists to populate), not by a second, independent code-level check that rejects
  a response where the model stated more than it was asked to — the file's own §3.0.3 structural
  validation (`isUsable`) rejects on illegibility/incompleteness, not on the model having
  overstepped this boundary.
  Whether that gap needs closing — and how, e.g. a validator that rejects any output field not
  drawn from the four printed items — is itself a clinical-safety judgment call (how much
  transcription "smoothing" is acceptable vs. how paranoid the check must be about a model
  overstepping), which is exactly the shape of thing HP-SR-002's five review triggers exist to
  route to a clinical reviewer rather than have a migration decide unilaterally. Recorded here as
  open, not closed, and not silently assumed covered by the prompt alone.

---

## §5. What has been verified here, and what has not

Following the distinction this repo's other documents draw.

**Verified by execution** against a real Postgres 16 + pgvector, on a database built only from
`migrations/`:

- all 52 migration files (`001`–`049`) apply clean, and re-apply
- pg-boss starts as `queue_role` and fails as every application role
- the whole pipeline runs end to end, as `hp_app`/`reasoner_role`/`redflag_role` over password
  auth, and produces the §0 unavailability result on an unsigned schema
- eighteen gates in `migrations/test/`, both DB-backed suites (12 tests, 0 skipped), 127 unit
  tests, the 51-case eval gate — every one of them twice in a row, against the same database,
  so a gate that only works once shows up as a gate that only works once (one did)
- the alert worker's both outcomes and its region scoping (`rf6_alert_delivery.sh`)
- the metrics job and its BLOCK verdict (`j34_metrics.sh`)
- the audit chain: 19 events written by the pipeline itself verify 0 bad / 19, and the migration
  that rewrote it refuses to run once `public.audit_anchor` holds a row — checked in both
  directions, on a log with rows and on one without

**Verified by execution, migration `050`.** Originally written against the live schema read
directly out of this repo but not run — that gap has since been closed: applied against a real
Postgres 16 + pgvector, fresh and re-applied, alongside `001`–`049`; `npm run typecheck` and
`npm test` (37/37, including the new suite) both clean; both `migrations/test/grant_contract.mjs`
and `migrations/test/role_contract.mjs` report OK with zero new violations. Running those two
gates for real — not just reading the migration — found and fixed five load-bearing defects
before any of this reached a real deployment:

- **Role-creation ordering.** `CREATE POLICY ... TO patient_upload_role` in §2 ran before §4
  created the role — the migration could not apply at all until the role-creation block was
  moved earlier in the file.
- **A missing `REVOKE ... FROM PUBLIC`.** `record_inferred_attribute` is `SECURITY DEFINER`;
  Postgres defaults a new function's ACL to `EXECUTE TO PUBLIC`, so without an explicit revoke,
  any role able to connect — not just `patient_upload_role` — could have called it and written a
  `MODEL_INFERRED` `patient_attribute` row for any subject. Caught by `grant_contract.mjs`'s
  `L-definer-not-public` rule.
- **A missing `GRANT EXECUTE ON FUNCTION app.current_region()`, and a missing
  `GRANT USAGE ON SCHEMA app`.** Every RLS policy on `patient_upload_document` calls
  `app.current_region()`. Without these two grants, every single statement the job and the
  webhook receiver issue against that table — the `FOR UPDATE` claim, both state-close updates,
  and the webhook's own `INSERT` — would have failed closed with "permission denied for function
  current_region" in production. Caught by `role_contract.mjs`, run as the role the code actually
  connects as, not as the owner.
- **`p_pud_own` scoped to PUBLIC by default.** Left without a `TO` clause (mirroring migration
  018's older `p_pa_own`/`p_prf_own`), this policy's `USING` clause was evaluated for every role
  querying the table — including `patient_upload_role`, which never touches
  `app.current_user_id()` directly — because PostgreSQL combines every applicable permissive
  policy's `USING` clause for the querying role. Rescoped to `FOR SELECT TO reasoner_role`,
  matching migration 041's later, more careful `p_pp_own` idiom rather than 018's looser one.
- **Two gate-maintenance gaps**, not schema bugs but real gaps in the CI instruments themselves:
  `role_contract.mjs`'s blanket `src/jobs/` → `dqe_role` prefix would have silently misclassified
  `extractPatientUploadAttributes.ts` as connecting with `dqe_role`'s privileges — the opposite of
  true, since `dqe_role` has no reach into `principal` at all. And `src/lib/webhookServer.ts` had
  no `ENTRY_POINTS` declaration at all, since it sits outside `src/jobs/`. Both are now declared
  explicitly, ahead of the general rule where order matters.

Two further defects were caught the same way, outside the database: a stray SQL-style `''`
apostrophe-escape in `subjectAttributeCrypto.ts` (valid in SQL, a syntax error in TypeScript) that
`tsc` would never have let this ship past, and a test assertion in
`extractPatientUploadAttributes.test.ts` that checked a bound-parameter array for two values the
job actually inlines as inline SQL literals (`'MODEL_INFERRED'::attribute_origin`,
`'DIAGNOSTIC_RESULT'::patient_attribute_kind`) rather than binding — the kind of test bug that
passes by accident until the code it's checking changes shape.

None of this was visible from reading the migration, however carefully — every one of these seven
findings required actually running it.

**Verified by execution, migration `051`.** Applied against the same database, on top of
`001`–`050`, then exercised end to end at the SQL level before any application code was trusted
to be correct: created a real subject with an app_user/subject_key/patient_profile/
patient_upload_document lifecycle, ran `erase_subject`, confirmed `storage_erasure_queue` gained
exactly one row with the right bucket/path and confirmed `assert_shred_complete` correctly
reported it as the one surviving relation; then, as `storage_erasure_role` over
`SET SESSION AUTHORIZATION` (a real second role, not the owner), claimed the row with
`claim_storage_erasure_batch`, confirmed a direct `SELECT` on the table itself fails with
`permission denied` (no table grant exists — every access is through the three verbs), called
`mark_storage_erasure_complete` and confirmed the row is gone and `assert_shred_complete` now
returns all-zero. Separately verified the failure path: `mark_storage_erasure_failed` increments
`attempts` and records `last_error` rather than deleting the row (left PENDING for retry, by
design), and refuses an empty error message. `npm run typecheck` clean with the new
`src/jobs/drainStorageErasure.ts` in the tree; `grant_contract.mjs`, `role_contract.mjs`,
`query_contract.mjs`, `schema_contract.test.sql`, `rb001_payload_keys.mjs`, and the full regression
sweep (`key_mint.sh`, `r13_conn_isolation.sh`, `r10d_attr.sh`, `r10f_constraints.sh`,
`c30_projection.sh`, `sr1_review_triggers.sh`, `j34_metrics.sh`) all still clean afterward — this
migration touches `erase_subject`/`assert_shred_complete`, both shared with every other erasure
path, so re-running the whole regression set rather than assuming isolation was the point, not an
extra step.

This found one more real defect the same way the 050 pass did: **a missing
`GRANT USAGE ON SCHEMA principal`.** `storage_erasure_role` had `EXECUTE` on the three verbs but
no `USAGE` on the schema they live in, and Postgres checks schema `USAGE` for the *caller*
before it matters that the function is `SECURITY DEFINER` — the same `app.current_region()`
lesson migration 050 learned, recurring in a different schema. First attempt to actually call
`claim_storage_erasure_batch` as `storage_erasure_role` failed outright with
`permission denied for schema principal`; fixed by adding the grant, and this file records both
the failure and the fix rather than only the corrected end state.

Still not verified: a real end-to-end upload against a staging Supabase project (the webhook
firing, the job claiming the row, Storage download, a real Claude vision call, decrypting the
written attribute back, and now the drain worker's own real `DELETE` call against live Storage)
— that needs Supabase/Fly/Anthropic accounts, which this environment does not have.

**Unverified — needs your accounts.** No Vercel, Fly.io or Supabase account exists in the
environment this was written in, and container registries are blocked there, so: `vercel deploy`,
`fly launch/deploy/secrets`, the `Dockerfile` builds themselves (every command inside them was
run directly, in the same layout), and whether Fly's `bom` region has capacity on your org.
Treat the first real deploy as the first true test of those.
