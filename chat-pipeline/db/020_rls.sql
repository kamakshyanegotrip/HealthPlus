-- ============================================================================
-- Row Level Security (HP-SEC-001) — applied to THIS pipeline's stub schema.
--
-- Context / honesty note: HP-SEC-001's own deliverable (`HP-SEC-001_RLS_
-- Policies.sql`, described in the HP-SEC-001 project doc) was designed and
-- validated against a *Supabase/PostgREST* access pattern: every end-user
-- request connects to Postgres directly as the `authenticated` role, with
-- `auth.uid()`/`auth.jwt()` populated per-request by PostgREST from the
-- caller's verified JWT. THIS repo's route.ts is architecturally different —
-- it's a Next.js server route that verifies the JWT itself (src/lib/auth.ts)
-- and then queries Postgres through a single pooled *technical* role,
-- `hp_app` (HP-RB-001 §2: "the application must never connect as owner or
-- superuser"). There is no single Postgres role per end user here.
--
-- To make RLS a real, enforced control rather than a comment claiming it is
-- one (patientProfile.ts's header literally says "RLS does the real access
-- control here" — that was aspirational until this file), this migration
-- reproduces the same auth.uid()/auth.jwt() surface HP-SEC-001 validated
-- against, but backs it with a per-request `SET LOCAL request.jwt.claims`
-- (see src/lib/db.ts's `runAsUser`) on the *shared* hp_app connection,
-- scoped to the transaction that runs the request's queries — the same GUC
-- HP-SEC-001 §5 used to impersonate roles during its own testing
-- (`set_config('request.jwt.claims', ...)`), just set by the app itself
-- instead of by PostgREST.
--
-- Run after db/010_chat_pipeline_support.sql.
-- ============================================================================

-- ---- stub auth schema (mirrors Supabase's auth.uid()/auth.jwt()) ----------
CREATE SCHEMA IF NOT EXISTS auth;

CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
$$;

CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE
AS $$
  SELECT NULLIF(auth.jwt() ->> 'sub', '')::uuid;
$$;

-- ---- hp_auth helpers -------------------------------------------------------
-- HP-SEC-001 §5 bug #2 ("self-referential recursion via hp_auth.app_user_id()")
-- happened because that function queried a table (app_user) that itself had
-- an RLS policy calling the same function. None of the functions below query
-- any RLS-protected table — they only read the GUC via auth.jwt()/auth.uid()
-- — so that recursion class does not apply here. Flagging it explicitly so
-- a future change that has one of these functions look up a real "role of
-- record" table doesn't reintroduce it blind: if that happens, make the new
-- function SECURITY DEFINER and owned by a BYPASSRLS role, exactly as
-- HP-SEC-001 §5 documents doing.
CREATE SCHEMA IF NOT EXISTS hp_auth;

CREATE OR REPLACE FUNCTION hp_auth.app_user_id() RETURNS uuid
LANGUAGE sql STABLE
AS $$ SELECT auth.uid(); $$;

CREATE OR REPLACE FUNCTION hp_auth.app_user_role() RETURNS text
LANGUAGE sql STABLE
AS $$ SELECT auth.jwt() ->> 'user_role'; $$;

CREATE OR REPLACE FUNCTION hp_auth.app_hospital_id() RETURNS uuid
LANGUAGE sql STABLE
AS $$ SELECT NULLIF(auth.jwt() ->> 'hospital_id', '')::uuid; $$;

GRANT USAGE ON SCHEMA auth, hp_auth TO hp_app, hp_reader;
GRANT EXECUTE ON FUNCTION auth.jwt, auth.uid TO hp_app, hp_reader;
GRANT EXECUTE ON FUNCTION hp_auth.app_user_id, hp_auth.app_user_role, hp_auth.app_hospital_id TO hp_app, hp_reader;

-- ---- patient_profile / patient_attribute: own-row only, fail-closed -------
-- Deliberately narrower than HP-SEC-001's full design: that doc's brief
-- covers clinician/hospital_admin/platform_admin visibility into OTHER
-- people's clinical data via scope-of-practice tables (clinician_scope,
-- clinician_registration) that do not exist in this stub schema (HP-SEC-001
-- §2 lists them as real-migration items, not stand-ins it built). Rather
-- than invent a scope-matching rule this repo can't verify against a real
-- table, patient_profile/patient_attribute here are patient-own-row-only,
-- for every role — the one rule this stub CAN state and test with
-- confidence, and the one route.ts's own POST handler already assumes
-- (§lines ~42-50: "a clinician or hospital_admin token... would still hit an
-- RLS wall downstream"). Extending this to real clinician/admin access is an
-- open follow-up, not a silent gap — see README.
ALTER TABLE patient_profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE patient_attribute ENABLE ROW LEVEL SECURITY;

CREATE POLICY patient_profile_own_row ON patient_profile
  FOR ALL
  USING (user_id = hp_auth.app_user_id())
  WITH CHECK (user_id = hp_auth.app_user_id());

CREATE POLICY patient_attribute_own_row ON patient_attribute
  FOR ALL
  USING (user_id = hp_auth.app_user_id())
  WITH CHECK (user_id = hp_auth.app_user_id());

-- ---- hospital_profile / hospital_cost: the §4 marketplace pattern ---------
-- SOURCE: HP-SEC-001 §4 — "hospital_admin cannot see other hospitals' data —
-- including published listings... hospital_admin gets full CRUD on its own
-- org in any status; patient/clinician get read-only access to PUBLISHED
-- rows across all orgs; hospital_admin never gets that marketplace-wide
-- grant." platform_admin gets read access to everything ("platform_admin can
-- read broadly", HP-SEC-001 §3) but no special write grant here — writes
-- stay hospital_admin-only, matching the doc's own "own org" CRUD framing.
-- Not wired into any route in this repo (no hospital-browsing endpoint
-- exists yet) — validated at the DB level only, same as HP-SEC-001's own
-- methodology, via scripts/smoke-test.mjs role impersonation.
ALTER TABLE hospital_profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE hospital_cost ENABLE ROW LEVEL SECURITY;

CREATE POLICY hospital_profile_marketplace_read ON hospital_profile
  FOR SELECT
  USING (
    status = 'PUBLISHED'
    OR hp_auth.app_user_role() = 'platform_admin'
    OR (hp_auth.app_user_role() = 'hospital_admin' AND id = hp_auth.app_hospital_id())
  );

CREATE POLICY hospital_profile_own_org_write ON hospital_profile
  FOR INSERT
  WITH CHECK (hp_auth.app_user_role() = 'hospital_admin' AND id = hp_auth.app_hospital_id());

CREATE POLICY hospital_profile_own_org_update ON hospital_profile
  FOR UPDATE
  USING (hp_auth.app_user_role() = 'hospital_admin' AND id = hp_auth.app_hospital_id())
  WITH CHECK (hp_auth.app_user_role() = 'hospital_admin' AND id = hp_auth.app_hospital_id());

CREATE POLICY hospital_cost_marketplace_read ON hospital_cost
  FOR SELECT
  USING (
    hp_auth.app_user_role() = 'platform_admin'
    OR EXISTS (
      SELECT 1 FROM hospital_profile h
       WHERE h.id = hospital_cost.hospital_id
         AND (h.status = 'PUBLISHED' OR (hp_auth.app_user_role() = 'hospital_admin' AND h.id = hp_auth.app_hospital_id()))
    )
  );

CREATE POLICY hospital_cost_own_org_write ON hospital_cost
  FOR INSERT
  WITH CHECK (hp_auth.app_user_role() = 'hospital_admin' AND hospital_id = hp_auth.app_hospital_id());

CREATE POLICY hospital_cost_own_org_update ON hospital_cost
  FOR UPDATE
  USING (hp_auth.app_user_role() = 'hospital_admin' AND hospital_id = hp_auth.app_hospital_id())
  WITH CHECK (hp_auth.app_user_role() = 'hospital_admin' AND hospital_id = hp_auth.app_hospital_id());

-- hp_app already holds table-level SELECT/INSERT (db/000 §"application role
-- grants") on all four tables above — RLS narrows which ROWS those grants
-- can touch, it does not replace them (HP-SEC-001 §5 bug #4: "base table
-- GRANTs were missing entirely... every CREATE POLICY applied without error
-- and was still completely inert" — the grants already exist here, but the
-- lesson is the reason this comment calls it out rather than assuming it's
-- obvious). No UPDATE grant exists yet on hospital_profile/hospital_cost for
-- hp_app; add one if/when a write path is built — the policies above are
-- ready for it.
