-- ============================================================================
-- MIGRATION 034 — THE CONNECTION MODEL  (register item R13-conn, decided)
--
-- HP-JOB-007 §7 left one decision open: `redflag_role`, `alert_role`,
-- `metrics_role`, `confirmation_ui_role` and (since R10c) `reasoner_role` hold
-- real grants and real policies, and are NOLOGIN with no members. Everything
-- R13 and migration 031 fixed is therefore still unreachable in production.
-- Five roles, one decision, not five bugs.
--
-- DECIDED 8 September 2026: **Option 2 — one LOGIN role per worker role.**
--
-- ---------------------------------------------------------------------------
-- WHY THIS, AND WHY IT IS CHEAPER THAN HP-JOB-007 §7 MADE IT SOUND
--
-- §7 discussed the five roles as one question. They are not. They split by
-- PROCESS, and the split does most of the work:
--
--   Next.js web app   hp_app, redflag_role, reasoner_role, confirmation_ui_role
--   alert-worker      alert_role only          (its own Fly process)
--   metrics job       metrics_role only        (its own scheduled process)
--
-- For the two out-of-process workers this is nearly free: each already has its
-- own deployment and its own secret store, so it is one more connection string
-- each and the separation is total. A compromised metrics job cannot write a
-- safety event under any circumstances, because the role it connects as holds
-- no grant on safety.red_flag_event.
--
-- For the three roles inside the web process the choice was real, and Option 2
-- still won: a POOL CANNOT BECOME ANOTHER ROLE. A SQL-injection reached
-- through the retrieval path cannot write a §4.0.7 event, because
-- reasoner_role has exactly one grant and it is on evidence.tier_label.
-- Option 1 (SET LOCAL ROLE) would have left every role reachable from any code
-- in the process; Option 3 abandons the separation and would have required
-- DROPPING the roles rather than leaving a control that exists only in DDL.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES NOT DO, DELIBERATELY
--
-- It does not set passwords. A password in a migration is a password in git.
-- The roles get LOGIN and nothing else; `scripts/set_role_passwords.sh` is the
-- operator step, and until it runs these roles can be named but not used —
-- which is the correct failure direction.
--
-- It does not grant these roles to hp_app. That is Option 1's mechanism and
-- was explicitly not chosen. Note for anyone tempted later: hp_app has
-- rolinherit = true, so `GRANT redflag_role TO hp_app` would silently hand it
-- every privilege at all times rather than requiring SET ROLE — collapsing
-- this into Option 3 without saying so. If that ever becomes desirable, set
-- hp_app NOINHERIT in the same transaction or do not do it at all.
--
-- ROLES ARE CLUSTER-WIDE. Every statement below is idempotent, because this
-- migration may run against a cluster where a previous database already
-- altered them. That is the same lesson migration 018 §7 and 027 §1 record,
-- and the same one that made a negative control escape a throwaway database
-- earlier in this project.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- §1  LOGIN, AND NOTHING ELSE
--
-- CONNECTION LIMITS ARE NOT DECORATION. Supabase's pooler has a finite budget
-- and this change turns one pool into five. The two narrow roles are used on a
-- small fraction of requests — confirmation_ui_role only when a patient
-- confirms an attribute, redflag_role only when a message is flagged — so they
-- are capped low. The numbers are a starting point, not a measurement; raise
-- them from observed saturation, not from anxiety.
--
-- The cap is also a containment property, not just capacity planning: a role
-- that has run away cannot starve the others of connections.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  -- The web process: two narrow roles alongside hp_app.
  EXECUTE 'ALTER ROLE redflag_role  LOGIN CONNECTION LIMIT 4';
  EXECUTE 'ALTER ROLE reasoner_role LOGIN CONNECTION LIMIT 6';
  -- Out-of-process workers: their own deployments, their own secrets.
  EXECUTE 'ALTER ROLE alert_role    LOGIN CONNECTION LIMIT 3';
  EXECUTE 'ALTER ROLE metrics_role  LOGIN CONNECTION LIMIT 2';

  -- AND THE OTHER DIRECTION, STATED RATHER THAN ASSUMED.
  --
  -- Roles are CLUSTER-WIDE. A migration that only grants LOGIN describes the
  -- state it wants for four roles and says nothing about the other three, so
  -- running it against a cluster where an earlier attempt gave one of them
  -- LOGIN leaves that role logged-in-capable forever.
  --
  -- That is not hypothetical: this migration's own first draft gave
  -- confirmation_ui_role LOGIN, and after the draft was corrected the role
  -- KEPT it, because dropping the database does not drop the role. The gate
  -- caught it; nothing else would have.
  --
  -- So the intended state is declared for all seven, not just the four that
  -- change. A migration over cluster-wide objects has to be declarative or it
  -- is only correct on a fresh cluster.
  EXECUTE 'ALTER ROLE confirmation_ui_role NOLOGIN';
  EXECUTE 'ALTER ROLE dqe_role             NOLOGIN';
  EXECUTE 'ALTER ROLE erasure_role         NOLOGIN';
END $$;

-- THREE ROLES ARE DELIBERATELY LEFT WITHOUT LOGIN, and the third was a
-- correction to this migration's own first draft.
--
--   dqe_role              the DQE runs as part of ingestion; no process
--   erasure_role          the erasure workflow is unbuilt (HP-LB-001 blocks it)
--   confirmation_ui_role  its one grant is INSERT on
--                         principal.patient_attribute_confirmation, and NOTHING
--                         IN THE CODEBASE WRITES THAT TABLE. The confirmation
--                         UI does not exist yet.
--
-- The first draft gave confirmation_ui_role LOGIN along with the others, which
-- contradicted the paragraph above it in the same file. Giving a role LOGIN
-- because it appears in a list of five, rather than because something connects
-- as it, is the same reflex that had migration 031 revoke thirty speculative
-- grants — each individually defensible, none with a caller.
--
-- R13 rule C will keep reporting all three, and that is correct: they are
-- unreachable because nothing needs to reach them yet. They get LOGIN in the
-- migration that builds their caller, not before.

-- ---------------------------------------------------------------------------
-- §2  EACH ROLE MAY CONNECT TO THIS DATABASE
--
-- LOGIN alone is not enough: CONNECT on the database is granted to PUBLIC by
-- default in a stock cluster, but a hardened deployment revokes that, and
-- relying on a default that a security review will remove is how a working
-- system breaks at the worst moment. Granted explicitly.
-- ---------------------------------------------------------------------------
DO $$
DECLARE db text := current_database();
BEGIN
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO redflag_role, reasoner_role, '
                 'alert_role, metrics_role', db);
END $$;

-- ---------------------------------------------------------------------------
-- §3  THE ONE THING A PER-ROLE POOL MUST NOT LOSE
--
-- SEC-1 put the region on the connection: db.ts passes `-c app.data_region=IN`
-- in the startup packet, because every region-scoped policy reads
-- app.current_region() and the application had never set it.
--
-- Five pools means five connections that each need that GUC. A pool that
-- forgets it does not fail loudly — it silently sees zero rows, because
-- `data_region = NULL` is never true. That is the SEC-1 failure mode returning
-- through the door this migration opens.
--
-- Belt: db.ts sets it per pool. Braces: a per-role default here, so a
-- connection that arrives without it still lands in the right region rather
-- than in no region at all.
--
-- This is a DATABASE-scoped default, so it does not leak to a session
-- connecting to a different database in the same cluster, and it is overridden
-- by anything db.ts sends in the startup packet.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  db     text := current_database();
  region text;
BEGIN
  -- Read the region from the registry rather than hardcoding 'IN': ADR-004 §2
  -- admits exactly one, and if that ever changes this should follow the data.
  SELECT code INTO region FROM region_registry
   WHERE code <> 'ZZ' AND active_to IS NULL ORDER BY active_from LIMIT 1;

  IF region IS NULL THEN
    RAISE EXCEPTION 'no admitted region in region_registry; cannot set a per-role default'
      USING HINT = 'ADR-004 §2 seeds IN. A cluster with none is a cluster where '
                   'every region-scoped policy would deny.';
  END IF;

  EXECUTE format('ALTER ROLE redflag_role         IN DATABASE %I SET app.data_region = %L', db, region);
  EXECUTE format('ALTER ROLE reasoner_role        IN DATABASE %I SET app.data_region = %L', db, region);
  EXECUTE format('ALTER ROLE alert_role           IN DATABASE %I SET app.data_region = %L', db, region);
  EXECUTE format('ALTER ROLE metrics_role         IN DATABASE %I SET app.data_region = %L', db, region);
END $$;

-- ---------------------------------------------------------------------------
-- §4  THE GRANTS THAT ONLY APPEAR ONCE SOMETHING CONNECTS AS THE ROLE
--
-- Found by executing the retrieval query as reasoner_role the moment this
-- migration gave it LOGIN:
--
--     ERROR: permission denied for table domain_entity_type
--     CONTEXT: SQL statement "... FROM evidence.domain_entity_type ..."
--
-- reasoner_role held EXECUTE on claim_search and SELECT on nothing that
-- claim_search reads. Migration 033 granted what 033 added; the tables
-- underneath were never granted because nothing had ever been that role.
--
-- This is the SAME CLASS as HP-JOB-007's finding, arriving through the door
-- this migration opens, and R13 did not catch it: rule A is clean (the role
-- HAS schema USAGE) and rule B is clean (these tables have no RLS). The gap is
-- a role that can EXECUTE a function but cannot READ what the function reads —
-- rule H's shape, but for a plain function rather than a trigger. R13 gains
-- rule J for it, so the check now covers the bug it was written from.
--
-- WHY GRANTS RATHER THAN SECURITY DEFINER. Making claim_search DEFINER would
-- let reasoner_role read nothing at all, which is tighter. It is not done here
-- because the OUTER query in knowledgeLookup.ts also joins evidence.claim and
-- evidence_source directly, so DEFINER on one function would close half the
-- hole and leave the other half looking closed. Doing it properly means moving
-- the whole retrieval into one DEFINER function — a real hardening, worth
-- doing, and not worth smuggling into a connection-model migration.
--
-- Everything below is read-only, and every table is evidence or reference
-- data. reasoner_role gets no write anywhere, and nothing outside `evidence`.
-- ---------------------------------------------------------------------------
GRANT SELECT ON
    evidence.domain_entity_type,
    evidence.domain_attribute,
    evidence.retrieval_chunk,
    evidence.claim,
    evidence.evidence_source,
    evidence.claim_source,
    evidence.claim_policy,
    evidence.tier_default
  TO reasoner_role;

COMMIT;
