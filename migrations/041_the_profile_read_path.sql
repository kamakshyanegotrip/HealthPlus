-- ============================================================================
-- MIGRATION 041 — THE PROFILE READ PATH  (register item R10d-attr)
--
-- The request path reads a patient profile on every turn: the region it is
-- operating in, and — since HP-SR-001 — whether §2.4.3's minor gate applies.
-- Against the real schema it could do neither.
--
--     SELECT r.rolname, c.relname, has_table_privilege(...)
--       FROM pg_class c ... WHERE n.nspname = 'principal';
--
--     hp_app        | patient_profile   | (none)
--     hp_app        | patient_risk_flag | (none)
--     reasoner_role | patient_profile   | (none)
--     reasoner_role | patient_risk_flag | (none)
--
-- In the whole `principal` schema exactly ONE table is readable by any
-- application role — provider_org, granted to dqe_role by migration 037. Every
-- other table, including the two this migration is about, is owner-only.
--
-- ---------------------------------------------------------------------------
-- WHY A GRANT HERE, WHEN 039 CHOSE FUNCTIONS
--
-- Migration 039 gave the request path SECURITY DEFINER verbs rather than grants,
-- and said why: obs.response_audit had RLS OFF and no policies, so a grant would
-- have handed over the table with no row boundary behind it. That argument does
-- not transfer, because the situation here is the opposite one.
--
--   principal.patient_risk_flag   RLS on. Policy p_prf_own already exists:
--                                 USING (subject_id = app.current_user_id()).
--                                 Well-formed, correctly scoped, and it has
--                                 NEVER ONCE EVALUATED — because no role holds
--                                 SELECT, so nothing ever reaches the table for
--                                 a policy to filter.
--
--   principal.patient_profile     RLS on, and ZERO policies. Default-deny for
--                                 everyone. A grant alone would be R13 rule B's
--                                 exact shape: a privilege that does nothing.
--
-- So this is the mirror image of rule B, and it is worth naming because the
-- grant contract cannot currently see it: A POLICY WITH NO GRANT IS AS INERT AS
-- A GRANT WITH NO POLICY. Rule B catches one direction. Nothing catches the
-- other, and HP-SR-001 recorded the symptom without the cause — "§4.6's
-- flagged-high-risk-profile trigger is already built in the schema and nothing
-- reads it". Nothing reads it because nothing *can*.
--
-- The fix is therefore to complete the pair the schema already started: grant
-- the read, and where the policy is missing, write it. That leaves the row
-- boundary where it belongs — enforced by the database on every statement —
-- rather than restated inside a function body where the next reader has to
-- trust the restatement.
--
-- ---------------------------------------------------------------------------
-- AND WHY patient_attribute IS DELIBERATELY LEFT WITH NO GRANT
--
-- It is the third table the profile read touches, and it gets nothing here.
-- Access stays exclusively through principal.fetch_attribute_envelope, because
-- that function does two things a SELECT privilege cannot:
--
--   * it WRITES principal.attribute_access_log on every read — the §3.8.2 audit
--     of who looked at a subject's attributes, for what purpose, under which
--     audit id. A direct SELECT grant would let the request path read health
--     attributes with no record that it did, which is precisely the guarantee
--     the envelope exists to provide;
--   * it enforces that `inferred` rows are reachable only for purpose
--     CONFIRMATION_UI, raising HP-ESC 3.8.2 otherwise.
--
-- So p_pa_own on patient_attribute stays dormant BY DESIGN rather than by
-- oversight, and that distinction is recorded here so a future reader tidying
-- up "unused policies" does not read it as dead code and delete it. It is the
-- backstop for the day somebody grants a direct read.
--
-- ---------------------------------------------------------------------------
-- ⚠ THE THING THAT WILL NOT REPRODUCE LOCALLY, STATED BEFORE IT BITES
--
-- principal.patient_attribute is FORCE ROW LEVEL SECURITY. FORCE means the
-- policy applies to the TABLE OWNER too — and therefore inside a SECURITY
-- DEFINER function, which runs as that owner. So fetch_attribute_envelope is
-- itself subject-scoped by p_pa_own, and returns rows only when the caller has
-- set `app.user_id` to the subject being read.
--
-- EXCEPT that a SUPERUSER bypasses RLS entirely, FORCE or not. In this
-- repository every migration and every gate runs as `postgres`, which is a
-- superuser, so that boundary has never once applied. On a deployment where the
-- owner is not a superuser — which is the normal Supabase shape — it applies in
-- full. Verified rather than assumed, with a throwaway non-superuser-owned table:
--
--     app.user_id unset            -> 0 rows
--     app.user_id = the subject    -> 1 row
--     app.user_id = someone else   -> 0 rows
--
-- The consequence for the application is concrete: THE PROFILE READ MUST RUN
-- INSIDE runAsUser(), which sets app.user_id transaction-scoped. A bare pooled
-- query would work perfectly in CI and return an empty profile in production —
-- the exact "healthy silence" failure SEC-1 exists to prevent, and the reason
-- §3.0.3's unknown-age gate would then fire for every subject alive.
--
-- migrations/test/r10d_attr.sh §4 exercises the production shape directly, by
-- reassigning the table and the function to a non-superuser owner for the
-- duration of the check.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- §1  patient_profile — the grant AND the policy, because it had neither.
--
-- Read by the request path once per turn for the subject's own region. Scoped
-- to the caller's own row by the same predicate the rest of `principal` uses,
-- so this cannot become a way to enumerate profiles: app.user_id is set from
-- the verified JWT subject by runAsUser and is transaction-scoped.
-- ---------------------------------------------------------------------------
GRANT SELECT ON principal.patient_profile TO reasoner_role;

CREATE POLICY p_pp_own ON principal.patient_profile
  FOR SELECT TO reasoner_role
  USING (user_id = app.current_user_id());

-- ---------------------------------------------------------------------------
-- §2  patient_risk_flag — the grant its policy has been waiting for.
--
-- Ten flag keys (migration 018), of which AGE_UNDER_18 is §2.4.3's, and
-- PREGNANCY / IMMUNOSUPPRESSION / ACTIVE_MALIGNANCY / ANTICOAGULATION /
-- TRANSPLANT_RECIPIENT / POST_OP_UNDER_30D / DIALYSIS / ANAPHYLAXIS_HISTORY are
-- §2.4.1 Elevated-Risk Topic List territory — SR-1, which is the clinical
-- lead's to define. This migration makes them READABLE; it does not decide what
-- any of them mean.
--
-- No new policy: p_prf_own already covers this table for PUBLIC with the right
-- predicate, so the grant alone brings it to life.
--
-- trg_risk_flag_stated_only guarantees on the write side that a flag can only
-- be set from a `stated` attribute — §4.6.2 — so a model-inferred attribute can
-- never raise one. That is the property that makes reading these flags safe for
-- a mandatory-review decision, and it is already enforced.
-- ---------------------------------------------------------------------------
GRANT SELECT ON principal.patient_risk_flag TO reasoner_role;

-- ---------------------------------------------------------------------------
-- §3  NOTHING FOR patient_attribute. See the header.
--
-- Recorded as an explicit non-action, with the assertion that keeps it true:
-- if a later migration grants a direct read, this fails and the author has to
-- come and read the argument above before overriding it.
-- ---------------------------------------------------------------------------
DO $$
DECLARE g text;
BEGIN
  SELECT string_agg(DISTINCT grantee, ', ') INTO g
    FROM information_schema.role_table_grants
   WHERE table_schema = 'principal' AND table_name = 'patient_attribute'
     AND grantee <> 'postgres';

  IF g IS NOT NULL THEN
    RAISE EXCEPTION
      'principal.patient_attribute has a direct grant to %; the request path must read it '
      'only through fetch_attribute_envelope', g
      USING HINT = 'That function writes principal.attribute_access_log on every read (§3.8.2) '
                   'and enforces the inferred/CONFIRMATION_UI rule. A direct SELECT bypasses both.';
  END IF;
END $$;

COMMENT ON POLICY p_pp_own ON principal.patient_profile IS
  'R10d-attr. patient_profile had RLS enabled and no policy at all, so every read denied. '
  'Scoped to the caller''s own row via app.user_id, which runAsUser sets transaction-scoped '
  'from the verified JWT subject.';

COMMIT;
