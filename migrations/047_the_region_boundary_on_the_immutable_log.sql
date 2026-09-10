-- =====================================================================
-- 047 — SEC-2's other half: a region boundary on the immutable audit log
--
-- This closes the last item in the build queue. It was recorded as "gated on
-- C-30", and the reason given for the gate was wrong. The reason is quoted
-- below because it was repeated in four places and believed for six days.
--
-- =====================================================================
-- §0.1  WHAT WAS BELIEVED
--
-- grant_contract_baseline.json, twice, and HP-SEC-003 §6, and HP-OIR-015 §3:
--
--     "public.response_audit_event is HP-RB-001's hash-chained immutable log,
--      so ADDING A COLUMN CHANGES WHAT EVERY row_hash COVERS. That is a
--      migration with a chain rewrite in it, not a column addition."
--
-- It is not true, and it is not true for a reason that is visible in
-- migration 003a. `audit_event_chain()` does not hash the row. It hashes an
-- ENUMERATED list of six columns:
--
--     canonical := audit_id |'|'| kind |'|'| occurred_at |'|'| actor
--                          |'|'| coalesce(subject_ref,'') |'|'| payload
--
-- A seventh column is invisible to that expression. Measured, on a database
-- built from migrations/ 001–046, with three events in the log:
--
--     before ADD COLUMN ....... 3/3 hashes verify, 3/3 links intact
--     after  ADD COLUMN ....... 3/3 hashes verify, 3/3 links intact
--
-- So the item could have been closed at any point in the last six days by a
-- migration that adds a nullable column and switches RLS on. Nothing about
-- the chain would have moved.
--
-- =====================================================================
-- §0.2  AND WHY IT IS BEING DONE THE HARD WAY ANYWAY
--
-- Because the easy version installs a hole at the moment it lands.
--
-- Once RLS scopes reads by `data_region`, the region column IS the visibility
-- key. Changing one row's region removes that row from every reader in its
-- region — which for an append-only log is a DELETE by another name. If the
-- column sits outside the hash, that edit breaks no link and HP-RB-001 §7's
-- nightly recomputation reports a clean chain.
--
-- The log's entire claim (003a §4, HP-RB-001 §8) is "tamper-EVIDENT": a
-- superuser can change anything and the recomputation will say so. Adding an
-- unhashed visibility key would carve out the one edit that guarantee does not
-- cover, and it would be carved out by this migration, on this day.
--
-- So `data_region` goes INSIDE the canonical form, which means the existing
-- rows' hashes change, which means the thing everyone was afraid of: a chain
-- rewrite. §4 does it, under a precondition that expires.
--
-- =====================================================================
-- §0.3  THE PRECONDITION THAT EXPIRES, AND WHY THIS IS THE LAST DAY
--
-- Recomputing a chain is not forgery while nobody has been told what the old
-- head was. The moment the head is published somewhere the operator does not
-- control — `public.audit_anchor`, HP-RB-001 §6, which is item 6 of that
-- runbook's order-of-execution list and has NOT happened — recomputation
-- becomes exactly the thing the anchor exists to detect.
--
--     SELECT count(*) FROM public.audit_anchor;   -->  0
--
-- RF3 has not run. There is no live database. There is no genesis anchor. The
-- window in which this table's canonical form can still be corrected closes on
-- the first `fly deploy`, and does not reopen.
--
-- §4 therefore REFUSES to run if an anchor exists, and says so in a message
-- that names the alternative rather than leaving the operator to invent one.
-- HP-RB-001's own framing is the same: "Run when: in the first migration,
-- before any real record exists. Not later."
--
-- =====================================================================
-- §0.4  ONE FORMULA, ONE PLACE
--
-- The canonical form was written out in three places before this file — the
-- trigger, the verification query reproduced in HP-RB-001 §7 (a document, so
-- unexecutable and unchecked), and the ad-hoc recomputation used to measure
-- §0.1. Three copies of an expression that must agree forever, and this
-- migration changes it.
--
-- §3 makes it ONE function, `public.audit_event_canonical()`, called by the
-- trigger, by the verifier, and by the rewrite. HP-RB-001 §7's query stops
-- being a paragraph and becomes `public.verify_audit_chain()` — §5 — which is
-- the object the nightly job should call. A formula that lives in a document
-- cannot be run by CI, and a formula copied three times is a formula that will
-- disagree with itself.
--
-- THE VERIFIER IS SECURITY DEFINER, and that is the whole of HP-SEC-004 again.
-- A chain verifier subject to RLS verifies a SLICE and reports a clean chain,
-- because every row it cannot see is a link it does not know is missing. It
-- returns `(seq, hash_ok, link_ok)` and nothing else — no payload, no actor,
-- no pseudonym, no region — so what it discloses across a residency boundary
-- is that a row exists, which is the irreducible minimum for proving none was
-- removed.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- §1. Report the state. Does not raise.
--
--     044 §0's rule: run_migrations.mjs keeps no ledger and applies every file
--     on every run, so a precondition check that raises once the postcondition
--     holds breaks the second run. This one reports and lets §2–§6 be
--     individually idempotent.
-- ---------------------------------------------------------------------
DO $$
DECLARE has_col boolean; rls boolean; n_rows bigint; n_anchor bigint;
BEGIN
  SELECT EXISTS (SELECT 1 FROM pg_attribute
                  WHERE attrelid = 'public.response_audit_event'::regclass
                    AND attname = 'data_region' AND attnum > 0 AND NOT attisdropped)
    INTO has_col;
  SELECT relrowsecurity FROM pg_class WHERE oid = 'public.response_audit_event'::regclass INTO rls;
  SELECT count(*) FROM public.response_audit_event INTO n_rows;
  SELECT count(*) FROM public.audit_anchor INTO n_anchor;

  RAISE NOTICE '047: response_audit_event — data_region=%, rls=%, rows=%, anchors=%',
    has_col, rls, n_rows, n_anchor;
END $$;

-- ---------------------------------------------------------------------
-- §2. The column, and the backfill that refuses to guess.
--
--     Same shape as 044 §1 on obs.response_audit, and the same rule: a row
--     that resolves to no region RAISES rather than taking a default.
--     Guessing a data region is the one thing HP-ADR-004 §2 forbids.
--
--     The backfill's source is the projection, because that is the only other
--     row in the database that describes the same turn. There is no FK
--     between them and there deliberately is not one — events are written
--     THROUGHOUT a turn and the projection lands at the END (the ordering
--     inversion migration 039 fixed for obs.ai_call) — so this is a lookup,
--     not a join the schema guarantees. Rows written before the projection
--     existed fall through to the connection's own region.
--
--     THE BACKFILL IS AN UPDATE ON A TABLE THAT REFUSES UPDATES, and finding
--     that out cost a run: written as a bare statement it passes on every
--     fresh database, because the log is EMPTY there and an UPDATE that
--     touches no row never fires a FOR EACH ROW trigger. It fails on the first
--     database that has ever recorded an event —
--
--         ERROR:  HP-ESC A.6: UPDATE on response_audit_event is forbidden
--
--     — which is CI green and dev broken, the exact asymmetry migration 036
--     found in obs.response_audit ("nothing has ever written this table
--     outside a CI fixture"). So the disable/enable is here as well as in §4,
--     scoped to the statement that needs it, and §7 asserts both triggers are
--     back on before this file commits. A DISABLE TRIGGER that survives to
--     COMMIT is permanent.
-- ---------------------------------------------------------------------
ALTER TABLE public.response_audit_event ADD COLUMN IF NOT EXISTS data_region char(2);

DO $$
DECLARE unresolved bigint; filled bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM public.response_audit_event WHERE data_region IS NULL) THEN
    ALTER TABLE public.response_audit_event DISABLE TRIGGER trg_audit_event_immutable;

    UPDATE public.response_audit_event e
       SET data_region = COALESCE(
             (SELECT a.data_region FROM obs.response_audit a WHERE a.id = e.audit_id),
             app.current_region())
     WHERE e.data_region IS NULL;
    GET DIAGNOSTICS filled = ROW_COUNT;

    ALTER TABLE public.response_audit_event ENABLE TRIGGER trg_audit_event_immutable;
    RAISE NOTICE '047 §2: backfilled the region on % pre-existing event(s).', filled;
  END IF;

  SELECT count(*) FROM public.response_audit_event WHERE data_region IS NULL INTO unresolved;
  IF unresolved > 0 THEN
    RAISE EXCEPTION
      '047: % audit event(s) resolve to no region. Their turn wrote no obs.response_audit '
      'row and app.data_region is unset on this connection. Set app.data_region to the '
      'region this database holds and re-run; do not default it (HP-ADR-004 §2).', unresolved;
  END IF;
END $$;

ALTER TABLE public.response_audit_event ALTER COLUMN data_region SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.response_audit_event'::regclass
                    AND conname = 'response_audit_event_data_region_fkey') THEN
    ALTER TABLE public.response_audit_event
      ADD CONSTRAINT response_audit_event_data_region_fkey
      FOREIGN KEY (data_region) REFERENCES public.region_registry(code);
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- §3. The canonical form, stated once.
--
--     STABLE, not IMMUTABLE: to_char(timestamp, text) is STABLE in pg_proc
--     because its output depends on DateStyle. Declaring it IMMUTABLE would be
--     a lie the planner is entitled to act on — it could cache a value across
--     a DateStyle change and produce two hashes for one row.
--
--     data_region is appended at the END rather than inserted next to `actor`
--     where it belongs semantically. Position is arbitrary; what matters is
--     that ONE expression exists. Appending also means the six original fields
--     occupy the same offsets they always did, so a pre-047 hash and a post-047
--     hash of the same event differ by exactly the suffix — which is what makes
--     §4's rewrite auditable by eye.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.audit_event_canonical(
  p_audit_id    uuid,
  p_kind        audit_event_kind,
  p_occurred_at timestamptz,
  p_actor       text,
  p_subject_ref uuid,
  p_payload     jsonb,
  p_data_region char(2)
) RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  -- jsonb text output is canonical in PostgreSQL: keys sorted, duplicates
  -- removed, whitespace normalised. Safe to hash directly (003a §4).
  SELECT p_audit_id::text
    || '|' || p_kind::text
    || '|' || to_char(p_occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US')
    || '|' || p_actor
    || '|' || coalesce(p_subject_ref::text, '')
    || '|' || p_payload::text
    || '|' || p_data_region::text;
$$;

REVOKE ALL ON FUNCTION public.audit_event_canonical(uuid, audit_event_kind, timestamptz, text, uuid, jsonb, char(2)) FROM PUBLIC;

-- The trigger. CREATE OR REPLACE, not ALTER, because the BODY changes — and
-- therefore SECURITY DEFINER and the pinned search_path have to be RESTATED.
-- CREATE OR REPLACE replaces every attribute of a function, not only the ones
-- named; a replace that omits them silently returns this function to INVOKER
-- and un-does R13-trig (migration 045), whose entire subject was that an
-- INVOKER chain trigger forks the log under RLS. §6 asserts it is still
-- DEFINER afterwards, because "I remembered to restate it" is not a check.
CREATE OR REPLACE FUNCTION public.audit_event_chain() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, principal, safety, obs, evidence, domain, public
AS $$
DECLARE
  last_hash bytea;
BEGIN
  -- Serialise chain appends. Concurrent inserts would otherwise read the same head.
  PERFORM pg_advisory_xact_lock(hashtext('response_audit_event_chain'));

  -- THE REGION IS DERIVED, NEVER ACCEPTED. Same rule as prev_hash/row_hash and
  -- for the same reason (003a §4: "the application never supplies them, which
  -- is what stops a compromised application from forging a chain"). A caller
  -- that supplies a region gets one of two answers and never a silent
  -- overwrite: agreement, or a refusal naming both values. This mirrors
  -- obs.record_response_audit as 044 §2 left it.
  IF app.current_region() IS NULL THEN
    RAISE EXCEPTION
      'HP-ADR-004 §2: app.data_region is not set on this connection, so the region of '
      'this audit event cannot be established. It is a property of the deployment and '
      'is set once per connection (src/lib/db.ts); it is never derived from a request.';
  END IF;

  IF NEW.data_region IS NOT NULL AND NEW.data_region IS DISTINCT FROM app.current_region() THEN
    RAISE EXCEPTION
      'HP-ADR-004 §2: audit event supplied data_region=% on a connection pinned to %.',
      NEW.data_region, app.current_region();
  END IF;

  NEW.data_region := app.current_region();

  SELECT row_hash INTO last_hash
    FROM response_audit_event ORDER BY seq DESC LIMIT 1;

  IF last_hash IS NULL THEN
    last_hash := decode(repeat('00', 32), 'hex');          -- genesis
  END IF;

  NEW.prev_hash := last_hash;
  NEW.row_hash  := digest(
    last_hash || convert_to(
      public.audit_event_canonical(NEW.audit_id, NEW.kind, NEW.occurred_at, NEW.actor,
                                   NEW.subject_ref, NEW.payload, NEW.data_region), 'UTF8'),
    'sha256');
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- §4. The rewrite. Conditional, refused once anchored, and a no-op on a
--     database that has never held an event — which is every fresh build.
--
--     GATED ON WHETHER IT WOULD CHANGE ANY BYTES, not on whether this file has
--     run before. A second application recomputes the same hashes from the
--     same inputs, so the guard below finds nothing to do and the anchor check
--     is never reached. That is what keeps this file re-runnable against an
--     already-anchored production database: it only refuses when it would
--     actually rewrite something.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  stale     bigint;
  anchors   bigint;
  anchored  bigint;   -- head_seq, renamed: a variable sharing a column's name
                      -- makes `SELECT max(head_seq)` ambiguous, and plpgsql says so
                      -- only when the anchored branch is finally exercised.
  prev      bytea := decode(repeat('00', 32), 'hex');
  r         record;
BEGIN
  SELECT count(*) INTO stale
    FROM public.response_audit_event e
   WHERE e.row_hash IS DISTINCT FROM digest(
           e.prev_hash || convert_to(
             public.audit_event_canonical(e.audit_id, e.kind, e.occurred_at, e.actor,
                                          e.subject_ref, e.payload, e.data_region), 'UTF8'),
           'sha256');

  IF stale = 0 THEN
    RAISE NOTICE '047 §4: no rewrite needed — % event(s), all already covering their region.',
      (SELECT count(*) FROM public.response_audit_event);
    RETURN;
  END IF;

  SELECT count(*) INTO anchors FROM public.audit_anchor;
  IF anchors > 0 THEN
    SELECT max(a.head_seq) INTO anchored FROM public.audit_anchor a;
    RAISE EXCEPTION
      '047 §4: REFUSING to rewrite the chain. % event(s) predate the region column, but '
      'this log has been externally anchored % time(s) (head_seq=%). Recomputing a hash '
      'whose old value was published outside this operator''s control is precisely the '
      'edit HP-RB-001 §6 exists to detect. On an anchored log the region column can only '
      'be added OUTSIDE the hash — a weaker control (§0.2), and a decision for whoever '
      'holds the anchors, not for this file.', stale, anchors, anchored;
  END IF;

  -- Not forgery: nobody was ever told what the old head was, and the
  -- recomputation is deterministic from the rows' own stored columns. It
  -- produces the chain that would have existed had 003a carried the column.
  --
  -- The immutability trigger has to come off to do it, which is the one thing
  -- 003a §5 says it is there to stop ("triggers stop a mistaken migration").
  -- This is the considered case rather than the mistaken one, and it is
  -- transactional — a failure below restores the trigger with the rollback.
  ALTER TABLE public.response_audit_event DISABLE TRIGGER trg_audit_event_immutable;

  FOR r IN SELECT * FROM public.response_audit_event ORDER BY seq LOOP
    UPDATE public.response_audit_event
       SET prev_hash = prev,
           row_hash  = digest(prev || convert_to(
             public.audit_event_canonical(r.audit_id, r.kind, r.occurred_at, r.actor,
                                          r.subject_ref, r.payload, r.data_region), 'UTF8'),
             'sha256')
     WHERE seq = r.seq
     RETURNING row_hash INTO prev;
  END LOOP;

  ALTER TABLE public.response_audit_event ENABLE TRIGGER trg_audit_event_immutable;

  RAISE NOTICE '047 §4: rewrote % of % event(s) onto the region-covering canonical form.',
    stale, (SELECT count(*) FROM public.response_audit_event);
END $$;

-- ---------------------------------------------------------------------
-- §5. HP-RB-001 §7 stops being a paragraph.
--
--     The runbook reproduces a recomputation query "for whoever wires up
--     pg_cron / the anchor job". Nobody has, and a query in a document is
--     neither runnable by CI nor updated when the formula changes — this
--     migration changes the formula, and that document's copy is now wrong.
--     So the query becomes an object, and §6 runs it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.verify_audit_chain()
RETURNS TABLE(seq bigint, hash_ok boolean, link_ok boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  WITH r AS (
    SELECT e.seq, e.prev_hash, e.row_hash,
           digest(e.prev_hash || convert_to(
             public.audit_event_canonical(e.audit_id, e.kind, e.occurred_at, e.actor,
                                          e.subject_ref, e.payload, e.data_region), 'UTF8'),
             'sha256') AS recomputed,
           lag(e.row_hash) OVER (ORDER BY e.seq) AS predecessor
      FROM public.response_audit_event e)
  SELECT r.seq,
         r.row_hash = r.recomputed,
         r.prev_hash = coalesce(r.predecessor, decode(repeat('00', 32), 'hex'))
    FROM r ORDER BY r.seq;
$$;

REVOKE ALL ON FUNCTION public.verify_audit_chain() FROM PUBLIC;
-- hp_reader is 003a §2's "verification job, analytics; read-only". It is the
-- caller this function exists for. hp_app deliberately does not get it: the
-- role that takes untrusted input has no business enumerating the whole log,
-- and a verifier it can call is a row-existence oracle across every region.
GRANT EXECUTE ON FUNCTION public.verify_audit_chain() TO hp_reader;

-- ---------------------------------------------------------------------
-- §6. RLS, and the two policies the grants actually need.
--
--     hp_app holds INSERT and SELECT; hp_reader holds SELECT (003a §5). Rule B
--     of the grant contract wants a policy for each, and rule M wants no policy
--     without a grant — both are satisfied by scoping the two verbs that exist.
--
--     NO policy FOR UPDATE or FOR DELETE, and their absence is the correct
--     shape: no role holds those privileges, so a policy would be rule-M dead
--     code, and RLS with no policy for a verb denies it outright — which is
--     the same answer forbid_mutation() gives, one layer earlier.
--
--     BOTH POLICIES CALL A FUNCTION NEITHER ROLE CAN CALL, which looks like a
--     defect and is not. Measured on this schema:
--
--         as hp_reader:  SELECT app.current_region()   -> permission denied
--                                                          for schema app
--         as hp_reader:  SELECT ... FROM response_audit_event
--                                                      -> 2 of 3 rows, filtered
--
--     A policy expression is evaluated with the TABLE OWNER's privileges, not
--     the querying role's, so `app` needs no USAGE grant for this to work. The
--     first thing to try on seeing the error above is to grant that USAGE, and
--     it would be thirty-one of migration 031's revocations again: a grant that
--     is individually defensible, widens what an untrusted-input role can
--     reach, and fixes nothing. Checked with both an inlinable SQL function and
--     a plpgsql one that cannot be inlined, because "the planner inlined it"
--     was the other candidate explanation and it would have been fragile.
-- ---------------------------------------------------------------------
ALTER TABLE public.response_audit_event ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_rae_region_scoped  ON public.response_audit_event;
DROP POLICY IF EXISTS p_rae_region_append  ON public.response_audit_event;

CREATE POLICY p_rae_region_scoped ON public.response_audit_event
  FOR SELECT USING (data_region = app.current_region());

-- The BEFORE INSERT trigger sets NEW.data_region before WITH CHECK is
-- evaluated, so this passes for every honest append and fails for none — its
-- job is to be the second answer if the trigger is ever dropped.
CREATE POLICY p_rae_region_append ON public.response_audit_event
  FOR INSERT WITH CHECK (data_region = app.current_region());

-- ---------------------------------------------------------------------
-- §7. The proof.
--
--     Six claims, each measured. (c), (d) and (f) are the ones that separate
--     this from a control that is correct in isolation:
--       (a) the chain verifies end to end under the new canonical form
--       (b) a reader in one region sees only that region
--       (c) an UNSET region sees NOTHING — SEC-1's "healthy drain of zero"
--       (d) three appends across two RLS slices still form ONE chain
--           (HP-SEC-004; the trigger is DEFINER, and this is what that buys)
--       (e) every trigger on the table is back on before COMMIT
--       (f) an append that NAMES a region other than the connection's is refused
--
--     THE APPENDS ARE MADE AS hp_app, NOT AS THE OWNER. The owner bypasses RLS
--     — response_audit_event is not FORCE — so an owner-run probe never
--     evaluates p_rae_region_append and would pass with the policy deleted.
--     That is this repository's third recurring pattern, "a fixture that proves
--     nothing", and it is one line away in either direction.
--
--     Rolls itself back through a raised exception, the way 045 §5 does:
--     the log refuses DELETE, so a test that inserts into it cannot clean up
--     after itself by any other means.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  other_region char(2);
  bad          bigint;
  n_in         bigint;
  n_unset      bigint;
  links        bigint;
  orphans      bigint;
  a1           uuid := gen_random_uuid();
  secdef       boolean;
  refused      boolean := false;
BEGIN
  BEGIN
    SELECT code INTO other_region FROM public.region_registry
     WHERE code <> 'IN' AND active_to IS NULL ORDER BY code LIMIT 1;
    IF other_region IS NULL THEN
      RAISE EXCEPTION '047 §7: needs a second admitted region to measure a boundary with.';
    END IF;

    -- (d) three appends, two of them in a slice the other cannot see — as the
    -- role that actually writes this table.
    SET LOCAL SESSION AUTHORIZATION hp_app;

    PERFORM set_config('app.data_region', 'IN', true);
    INSERT INTO public.response_audit_event (audit_id, kind, occurred_at, actor, payload)
    VALUES (a1, 'RESPONSE_DRAFTED', now(), 'system', '{"probe":1}'::jsonb);

    PERFORM set_config('app.data_region', other_region, true);
    INSERT INTO public.response_audit_event (audit_id, kind, occurred_at, actor, payload)
    VALUES (a1, 'CATEGORY_ASSIGNED', now(), 'system', '{"probe":2}'::jsonb);

    PERFORM set_config('app.data_region', 'IN', true);
    INSERT INTO public.response_audit_event (audit_id, kind, occurred_at, actor, payload)
    VALUES (a1, 'PUBLISHED', now(), 'system', '{"probe":3}'::jsonb);

    -- (f) the negative direction. A caller that names a region is answered,
    -- not silently corrected — and the refusal has to come from the trigger's
    -- own check rather than from the policy, because the policy would let a
    -- disagreeing value through if the trigger ever stopped overwriting it.
    BEGIN
      INSERT INTO public.response_audit_event (audit_id, kind, occurred_at, actor, payload, data_region)
      VALUES (a1, 'FLAG_RAISED', now(), 'system', '{"probe":4}'::jsonb, other_region);
    EXCEPTION WHEN raise_exception OR check_violation THEN
      refused := true;
    END;
    IF NOT refused THEN
      RAISE EXCEPTION
        '047 §7(f): an append naming data_region=% on a connection pinned to IN was ACCEPTED.',
        other_region;
    END IF;

    RESET SESSION AUTHORIZATION;

    -- (a) every row, not only the new ones.
    SELECT count(*) INTO bad FROM public.verify_audit_chain() v
     WHERE NOT v.hash_ok OR NOT v.link_ok;
    IF bad > 0 THEN
      RAISE EXCEPTION '047 §7(a): % event(s) fail verification after the rewrite.', bad;
    END IF;

    -- (d) one chain, not two: each probe row except the head is some other
    -- probe row's prev_hash. If the trigger were INVOKER, the middle row would
    -- be orphaned and the third would chain onto the first (HP-SEC-004).
    SELECT count(*) INTO links
      FROM public.response_audit_event e
      JOIN public.response_audit_event c ON c.prev_hash = e.row_hash
     WHERE e.audit_id = a1;
    SELECT count(*) INTO orphans
      FROM public.response_audit_event e
     WHERE e.audit_id = a1
       AND e.seq <> (SELECT max(seq) FROM public.response_audit_event WHERE audit_id = a1)
       AND NOT EXISTS (SELECT 1 FROM public.response_audit_event c WHERE c.prev_hash = e.row_hash);
    IF links <> 2 OR orphans <> 0 THEN
      RAISE EXCEPTION
        '047 §7(d): the three probe appends form % link(s) with % orphan(s); expected 2 and 0. '
        'The chain forked across the RLS slices — audit_event_chain is not seeing the true head.',
        links, orphans;
    END IF;

    -- (b) and (c), as the role that actually reads this table.
    SET LOCAL SESSION AUTHORIZATION hp_reader;

    PERFORM set_config('app.data_region', 'IN', true);
    SELECT count(*) INTO n_in FROM public.response_audit_event WHERE audit_id = a1;

    PERFORM set_config('app.data_region', '', true);
    SELECT count(*) INTO n_unset FROM public.response_audit_event WHERE audit_id = a1;

    RESET SESSION AUTHORIZATION;
    PERFORM set_config('app.data_region', 'IN', true);

    IF n_in <> 2 THEN
      RAISE EXCEPTION '047 §7(b): hp_reader in IN saw % of the 3 probe events; expected 2.', n_in;
    END IF;
    IF n_unset <> 0 THEN
      RAISE EXCEPTION
        '047 §7(c): with app.data_region UNSET, hp_reader saw % event(s); expected 0. '
        'Unset must fail CLOSED — a test that only checks its own region cannot tell '
        '"the boundary holds" from "the boundary is not there".', n_unset;
    END IF;

    -- The trigger is still DEFINER. Checked because §3 restated the attribute
    -- by hand and a CREATE OR REPLACE that forgot it would still pass (a)–(d)
    -- on this database, where nothing hides rows from the owner.
    SELECT p.prosecdef INTO secdef FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'audit_event_chain';
    IF NOT secdef THEN
      RAISE EXCEPTION '047 §7: audit_event_chain is INVOKER again — §3 dropped R13-trig.';
    END IF;

    -- (e) EVERY trigger on this table is enabled. §2 and §4 both switch the
    -- immutability trigger off, and DISABLE TRIGGER is a catalogue change: one
    -- that reaches COMMIT leaves the append-only log permanently writable, with
    -- nothing to notice it but this line.
    IF EXISTS (SELECT 1 FROM pg_trigger
                WHERE tgrelid = 'public.response_audit_event'::regclass
                  AND NOT tgisinternal AND tgenabled <> 'O') THEN
      RAISE EXCEPTION
        '047 §7(e): % is still disabled on response_audit_event. §2 or §4 turned it off '
        'and did not turn it back on; committing would leave the append-only log mutable.',
        (SELECT string_agg(tgname, ', ') FROM pg_trigger
          WHERE tgrelid = 'public.response_audit_event'::regclass
            AND NOT tgisinternal AND tgenabled <> 'O');
    END IF;

    RAISE EXCEPTION 'HP047ROLLBACK' USING ERRCODE = 'HP047';
  EXCEPTION WHEN SQLSTATE 'HP047' THEN
    RESET SESSION AUTHORIZATION;
    RAISE NOTICE
      '047 §7: chain verifies end to end; 3 appends across 2 regions form ONE chain '
      '(2 links, 0 orphans); hp_reader sees 2 in IN and 0 with the region unset.';
  END;
END $$;

COMMIT;
