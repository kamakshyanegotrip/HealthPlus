-- ============================================================================
-- MIGRATION 039 — HOW THE REQUEST PATH WRITES obs  (register item R10d-obs)
--
-- Of the sixteen objects in schema `obs`, exactly one had an INSERT grant to any
-- application role — obs.ai_call, to redflag_role. The response audit, its
-- encrypted content, fabrication blocks, the review queue and abstention events
-- were owner-only, and obs.response_audit additionally had RLS off with no
-- policies, so this was never a policy gap that CREATE POLICY closes. There was
-- simply no way for the request path to write its own audit trail
-- (HP-RECON-004 §3).
--
-- ---------------------------------------------------------------------------
-- WHY FUNCTIONS AND NOT GRANTS
--
-- Decided 8 September. The obvious fix — GRANT hp_app USAGE on obs and INSERT on
-- five tables — is not what the rest of this schema does. hp_app's real surface
-- is deliberately narrow and function-shaped: USAGE on `public` only,
-- INSERT/SELECT on public.response_audit_event, and EXECUTE on two SECURITY
-- DEFINER functions (safety.raise_alert, safety.acknowledge_alert). And where
-- metrics_role must write obs, it holds no INSERT either — it holds EXECUTE on
-- obs.record_metric_sample, which is DEFINER.
--
-- So the idiom already exists and this migration follows it: six reviewable
-- verbs, EXECUTE to hp_app, and the tables themselves stay unreachable.
--
-- ---------------------------------------------------------------------------
-- THE ORDERING INVERSION, AND THE SHAPE CHOSEN FOR IT
--
-- obs.ai_call.audit_id and obs.fabrication_block.audit_id both FK to
-- obs.response_audit(id). route.ts mints ctx.auditId at the top of the request
-- and threads it through every AI call and every validator block — then writes
-- the audit row at the END, once category, confidence and review state are
-- known. So every one of those writes referenced a parent that did not exist:
--
--     ERROR: insert or update on table "ai_call" violates foreign key
--            constraint "ai_call_audit_id_fkey"
--
-- A skeleton audit row written early does not fix it: c_min_conf,
-- c_category_c_disabled_v1 and c_urgent_template_only mean a row without a
-- category and a confidence is not insertable at all.
--
-- DECIDED: log with audit_id NULL, and backfill after the audit row lands.
-- record_ai_call and record_fabrication_block RETURN their row id; the caller
-- collects them and calls attach_pending once. The FK and every CHECK stay.
--
-- THE COST, STATED: a request that dies before the audit row is written leaves
-- its telemetry unattributed — audit_id NULL, cost and latency still recorded.
-- That is the request you would most want attributed. It is the price of
-- keeping the FK, and it is visible in the data rather than hidden: those rows
-- are findable with `WHERE audit_id IS NULL`.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. THE AUDIT PROJECTION
--
-- ON CONFLICT DO NOTHING: C-30 makes this a projection of
-- public.response_audit_event, written once at publication. The log is the
-- record of truth; a second write for the same audit id is a retry, not a
-- correction.
--
-- rule_version and template_version are parameters, and that is a fix rather
-- than a transcription. obs.response_audit carries composite foreign keys
-- (rule_id, rule_version) -> safety.red_flag_rule and (template_id,
-- template_version) -> safety.safety_template. The caller passed only the ids,
-- and under MATCH SIMPLE a composite FK with any NULL column is not checked at
-- all — so the audit row could name a template that does not exist and nothing
-- would object. RedFlagOutcome has carried both versions all along.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION obs.record_response_audit(
  p_id                 uuid,
  p_subject_pseudonym  bytea,
  p_category           response_category,
  p_classifier_version text,
  p_severity           red_flag_severity,
  p_rule_id            uuid,
  p_rule_version       int,
  p_template_id        uuid,
  p_template_version   int,
  p_agg_confidence     numeric,
  p_policy_version     text,
  p_model_version      text,
  p_prompt_version     text,
  p_cited_claim_ids    uuid[],
  p_review_state       review_state,
  p_clinical_domain    text
) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, obs, safety, public AS $$
  INSERT INTO obs.response_audit
    (id, subject_pseudonym, occurred_at, category, classifier_version, severity,
     rule_id, rule_version, template_id, template_version, agg_confidence,
     policy_version, model_version, prompt_version, cited_claim_ids,
     review_state, clinical_domain)
  VALUES
    (p_id, p_subject_pseudonym, now(), p_category, p_classifier_version, p_severity,
     p_rule_id, p_rule_version, p_template_id, p_template_version, p_agg_confidence,
     p_policy_version, p_model_version, p_prompt_version, coalesce(p_cited_claim_ids, '{}'),
     p_review_state, p_clinical_domain)
  ON CONFLICT (id) DO NOTHING;
$$;

-- ---------------------------------------------------------------------------
-- 2. THE ENCRYPTED CONTENT
--
-- key_id is NOT NULL with an FK to principal.subject_key, which is why this
-- could not be written before migration 038 gave the system a way to mint one.
-- The function does not mint: the caller does that explicitly, because a write
-- path that quietly creates key material is a write path that can create it by
-- accident.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION obs.record_response_content(
  p_audit_id   uuid,
  p_subject_id uuid,
  p_region     char(2),
  p_ciphertext bytea,
  p_key_id     uuid
) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, obs, principal, public AS $$
  INSERT INTO obs.response_content (audit_id, subject_id, data_region, ciphertext, key_id)
  VALUES (p_audit_id, p_subject_id, p_region, p_ciphertext, p_key_id)
  ON CONFLICT (audit_id) DO NOTHING;
$$;

-- ---------------------------------------------------------------------------
-- 3. AI CALLS — audit_id DELIBERATELY NULL AT WRITE TIME
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION obs.record_ai_call(
  p_purpose            ai_call_purpose,
  p_model_version      text,
  p_prompt_version     text,
  p_retrieval_version  text,
  p_input_tokens       int,
  p_output_tokens      int,
  p_latency_ms         int,
  p_outcome            ai_call_outcome,
  p_retrieved_claim_ids uuid[],
  p_proposed_severity  red_flag_severity,
  p_applied_severity   red_flag_severity,
  p_region             char(2)
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, obs, public AS $$
DECLARE v_id uuid := gen_random_uuid();
BEGIN
  INSERT INTO obs.ai_call
    (id, audit_id, occurred_at, purpose, provider, model_version, prompt_version,
     retrieval_version, input_tokens, output_tokens, latency_ms, outcome,
     retrieved_claim_ids, proposed_severity, applied_severity, data_region)
  VALUES
    (v_id, NULL, now(), p_purpose, 'anthropic', p_model_version, p_prompt_version,
     p_retrieval_version, p_input_tokens, p_output_tokens, p_latency_ms, p_outcome,
     coalesce(p_retrieved_claim_ids, '{}'), p_proposed_severity, p_applied_severity, p_region);
  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. FABRICATION BLOCKS — same treatment, same reason
--
-- §3.13.1 requires a block to be logged, and a block happens during validation,
-- before the audit row exists. Recording it unattached is strictly better than
-- not recording it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION obs.record_fabrication_block(
  p_prohibition_class     text,
  p_claim_kind            claim_kind,
  p_tier                  source_tier,
  p_category              response_category,
  p_policy_tier           source_tier,
  p_policy_kind           claim_kind,
  p_policy_category       response_category,
  p_policy_effective_from timestamptz,
  p_query_hash            bytea,
  p_retrieved_source_state jsonb,
  p_message_template_id   text,
  p_region                char(2)
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, obs, evidence, public AS $$
DECLARE v_id uuid := gen_random_uuid();
BEGIN
  INSERT INTO obs.fabrication_block
    (id, occurred_at, ai_call_id, audit_id, prohibition_class, claim_kind, tier, category,
     policy_tier, policy_kind, policy_category, policy_effective_from,
     query_hash, retrieved_source_state, message_template_id, data_region)
  VALUES
    (v_id, now(), NULL, NULL, p_prohibition_class, p_claim_kind, p_tier, p_category,
     p_policy_tier, p_policy_kind, p_policy_category, p_policy_effective_from,
     p_query_hash, p_retrieved_source_state, p_message_template_id, p_region);
  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. THE BACKFILL
--
-- `AND audit_id IS NULL` is not defensive tidiness. Without it, a caller that
-- passed another request's ids — through a bug, or deliberately — could
-- re-parent telemetry that already belongs to a different audit row, and the
-- cost and latency of one response would silently move to another. A row is
-- attachable exactly once.
--
-- Returns the number of rows actually attached so the caller can tell the
-- difference between "nothing to do" and "the ids I passed were not mine".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION obs.attach_pending(
  p_audit_id uuid,
  p_ai_calls uuid[],
  p_blocks   uuid[]
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, obs, public AS $$
DECLARE n int := 0; m int := 0;
BEGIN
  IF p_audit_id IS NULL THEN
    RAISE EXCEPTION 'attach_pending: audit_id is required';
  END IF;

  UPDATE obs.ai_call SET audit_id = p_audit_id
   WHERE id = ANY(coalesce(p_ai_calls, '{}')) AND audit_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;

  UPDATE obs.fabrication_block SET audit_id = p_audit_id
   WHERE id = ANY(coalesce(p_blocks, '{}')) AND audit_id IS NULL;
  GET DIAGNOSTICS m = ROW_COUNT;

  RETURN n + m;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. READING THE KEY MATERIAL — the other half of migration 038
--
-- 038 gave the system a way to MINT a subject key and deliberately left
-- principal.subject_key with no grants at all. That is right for the table and
-- insufficient for the design: obs.response_content is encrypted under the
-- subject's DEK, so the application must be able to obtain that DEK on every
-- request that writes or reads content — not only on the request that minted it.
--
-- ensure_subject_key returns the id and the salt, which is what
-- subject_pseudonym needs. It does not return the wrapped DEK, so this is the
-- read verb that does.
--
-- WHAT THIS DOES AND DOES NOT GIVE AWAY. hp_app already holds
-- SUBJECT_KEY_WRAPPING_KEY, so handing it the wrapped DEK hands it the DEK.
-- That is inherent: something has to encrypt, and it is the application. The
-- property the design actually buys is that THE DATABASE NEVER HOLDS THE
-- WRAPPING KEY — a dump, a replica, or a backup tape is unreadable on its own.
-- Stating it here so nobody later reads "hp_app can fetch wrapped DEKs" as a
-- regression rather than as the design.
--
-- A DESTROYED KEY RETURNS NOTHING. Not an error, not a row with NULLs: zero
-- rows, the same answer as a subject who never existed. That is
-- fetch_attribute_envelope's behaviour too, and for the same reason — after
-- erasure the two cases are not distinguishable and must not be made so.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION principal.subject_key_material(p_subject uuid)
RETURNS TABLE (key_id uuid, salt bytea, wrapped_dek bytea)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, principal, public AS $$
  SELECT k.id, k.salt, k.wrapped_dek
    FROM principal.subject_key k
   WHERE k.subject_id = p_subject
     AND k.destroyed_at IS NULL
     AND k.salt IS NOT NULL
     AND k.wrapped_dek IS NOT NULL;
$$;

COMMENT ON FUNCTION principal.subject_key_material(uuid) IS
  'R10d-obs. The read half of migration 038''s mint: returns the live key material '
  'the application needs to derive subject_pseudonym and to unwrap the content DEK. '
  'Returns ZERO ROWS for a destroyed key — indistinguishable from a subject who '
  'never existed, which is what erasure means.';

-- ---------------------------------------------------------------------------
-- GRANTS. hp_app and nothing else: these are the request path's verbs.
-- redflag_role keeps its existing direct INSERT on obs.ai_call — the red-flag
-- module writes its own calls on its own pool, and nothing here changes that.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- AND THE USAGE WITHOUT WHICH EVERY EXECUTE GRANT ABOVE IS DECORATION.
--
-- Found by R13's new rule K, written in the same commit as this migration, and
-- it immediately reported three — two of them pre-existing and one of them mine:
--
--   hp_app -> safety.raise_alert            EXECUTE granted, no USAGE on safety
--   hp_app -> safety.acknowledge_alert      EXECUTE granted, no USAGE on safety
--   hp_app -> principal.ensure_subject_key  EXECUTE granted, no USAGE on principal
--
-- The first two have been decoration since they were written: hp_app holds USAGE
-- on `public` and nothing else, so both calls fail with "permission denied for
-- schema safety". The third is migration 038's, from two PRs ago — the mint was
-- unreachable by the only role granted it.
--
-- USAGE ON A SCHEMA GRANTS NOTHING ON ITS OBJECTS. hp_app still holds no table
-- privilege anywhere in obs, safety or principal, so the claim that the tables
-- stay unreachable is unchanged: this makes exactly the granted functions
-- callable and nothing else. Rule K now fails the build if that stops being true.
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA obs, principal, safety TO hp_app;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'obs.record_response_audit(uuid,bytea,response_category,text,red_flag_severity,uuid,int,uuid,int,numeric,text,text,text,uuid[],review_state,text)',
    'obs.record_response_content(uuid,uuid,char,bytea,uuid)',
    'obs.record_ai_call(ai_call_purpose,text,text,text,int,int,int,ai_call_outcome,uuid[],red_flag_severity,red_flag_severity,char)',
    'obs.record_fabrication_block(text,claim_kind,source_tier,response_category,source_tier,claim_kind,response_category,timestamptz,bytea,jsonb,text,char)',
    'obs.attach_pending(uuid,uuid[],uuid[])',
    'principal.subject_key_material(uuid)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO hp_app', f);
  END LOOP;
END $$;

COMMIT;
