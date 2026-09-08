-- ============================================================================
-- MIGRATION 038 — MINTING A SUBJECT KEY  (register item R10-key, mint half)
--
-- principal.subject_key has existed since 001_003 and nothing has ever created
-- a row in it. Five functions reference the table — attribute_ref_digest,
-- fetch_attribute_envelope, erase_subject, assert_key_destruction_final,
-- assert_shred_complete — and every one of them CONSUMES or DESTROYS a key.
-- There is no mint.
--
-- The consequence is not theoretical. obs.response_content.key_id is NOT NULL
-- with an FK to this table, so the encrypted response store cannot be written
-- at all; auditLog.ts passes null and its own comment says the cipher it uses
-- instead is "a working placeholder … do not ship this derivation as the
-- production key path" (HP-RECON-006 §3).
--
-- ---------------------------------------------------------------------------
-- WHAT THIS IS NOT, AND WHY THAT MATTERS
--
-- An earlier note in this session called the key work "a legal dependency,
-- not just an engineering one", on the strength of HP-SEC-001's line that
-- erase_subject() is "intentionally not wired up until HP-LB-001 Q1/Q2/Q4 come
-- back from counsel". Reading the schema rather than the note corrects it:
--
--   * principal.erase_subject IS implemented, in migration 018, and it IS the
--     audit-vs-erasure reconciliation — it nulls salt and wrapped_dek, sets
--     destroyed_at, deletes the Layer 2 rows, and deliberately leaves
--     obs.response_audit alone because the pseudonym can no longer be
--     recomputed once the salt is gone.
--   * What is "not wired up" is a CALLER: erasure_role is still NOLOGIN and no
--     erasure workflow exists. That is what LB-001 gates.
--
-- Creating a key asks counsel nothing. The data model it belongs to was
-- committed long ago — Phase_1.1 lists the audit/content/key split as one of
-- two decisions that cannot be unwound — and this migration builds the half
-- that was missing from it.
--
-- ---------------------------------------------------------------------------
-- THE SPLIT: THE DATABASE OWNS THE SALT, THE APPLICATION OWNS THE WRAP
--
-- The salt is generated HERE, with gen_random_bytes(32), and returned to the
-- caller. It is an HMAC salt, not a secret in the DEK's sense — subject_pseudonym
-- is HMAC(user_id, salt) — but generating it in the database means the
-- application cannot choose a weak one, cannot reuse one across subjects, and
-- cannot accidentally derive it from something guessable. That is worth more
-- than the alternative's symmetry.
--
-- The wrapped DEK arrives from the caller because only the caller holds the
-- wrapping key. Decided 8 September: one master key in the secret store
-- (SUBJECT_KEY_WRAPPING_KEY), AES-256-GCM wrap in the application, per ADR-002's
-- zero-cost stack. THE MASTER KEY IS THEREFORE A SINGLE POINT OF COMPROMISE, and
-- that is recorded rather than discovered: an attacker holding it and a database
-- dump can unwrap every live DEK. Rotation is a re-wrap of every live row and
-- needs no schema change; it is a job to write when there is something to
-- protect, not before.
--
-- This function validates the shape of what it is given and nothing more. It
-- cannot tell a real wrapped DEK from 48 random bytes, and does not pretend to.
--
-- ---------------------------------------------------------------------------
-- DESTRUCTION IS FINAL, AND THE DATABASE ALREADY SAID SO
--
-- trg_key_destruction_final (migration 018) refuses to clear destroyed_at or to
-- restore material to a destroyed key. So a subject whose key was destroyed
-- cannot be re-minted by UPDATE — and this function does not try. It RAISES.
--
-- A person who is erased and later returns is a NEW subject with a new
-- app_user row and a new key. Reusing the row would resurrect the linkage
-- erasure existed to sever, and would erase the record that erasure happened.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION principal.ensure_subject_key(
  p_subject     uuid,
  p_wrapped_dek bytea
)
RETURNS TABLE (key_id uuid, salt bytea, created boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, principal, public
AS $$
DECLARE
  v_id        uuid;
  v_salt      bytea;
  v_destroyed timestamptz;
BEGIN
  SELECT k.id, k.salt, k.destroyed_at
    INTO v_id, v_salt, v_destroyed
    FROM principal.subject_key k
   WHERE k.subject_id = p_subject;

  IF FOUND THEN
    IF v_destroyed IS NOT NULL THEN
      RAISE EXCEPTION 'HP-ESC 2.3.4g: subject % has a DESTROYED key; destruction is final', p_subject
        USING HINT = 'An erased subject who returns is a new subject with a new app_user '
                     'row. Reusing this one would resurrect the linkage erasure severed, '
                     'and would erase the record that erasure happened.';
    END IF;
    RETURN QUERY SELECT v_id, v_salt, false;
    RETURN;
  END IF;

  -- THE DEK IS VALIDATED HERE, ON THE MINT PATH ONLY, and not at the top.
  -- A caller holding an existing key wants the salt back; making it fabricate a
  -- plausible wrapped DEK first would be a validation that guards nothing and
  -- costs a wrap on every request. 32 bytes is the AES-256 DEK, and a GCM wrap
  -- adds a 12-byte nonce and a 16-byte tag, so anything shorter cannot be a
  -- wrapped key of the size this design uses — a caller that passed the DEK
  -- unwrapped, or passed an empty buffer, would otherwise be stored happily.
  IF p_wrapped_dek IS NULL OR length(p_wrapped_dek) < 32 THEN
    RAISE EXCEPTION 'ensure_subject_key: wrapped DEK is missing or implausibly short (%)',
      coalesce(length(p_wrapped_dek), 0)
      USING HINT = 'The caller wraps a 32-byte DEK with SUBJECT_KEY_WRAPPING_KEY; '
                   'AES-256-GCM adds a 12-byte nonce and a 16-byte tag.';
  END IF;

  -- ON CONFLICT rather than a bare INSERT: two requests for the same new
  -- subject race, subject_id is UNIQUE, and the loser would otherwise get a
  -- constraint violation on a request that did nothing wrong.
  INSERT INTO principal.subject_key (id, subject_id, salt, wrapped_dek)
  VALUES (gen_random_uuid(), p_subject, gen_random_bytes(32), p_wrapped_dek)
  ON CONFLICT (subject_id) DO NOTHING
  RETURNING id, principal.subject_key.salt INTO v_id, v_salt;

  IF v_id IS NOT NULL THEN
    RETURN QUERY SELECT v_id, v_salt, true;
    RETURN;
  END IF;

  -- Lost the race. Re-read — and re-check destruction, because the row we just
  -- collided with could in principle be a destroyed one.
  SELECT k.id, k.salt, k.destroyed_at INTO v_id, v_salt, v_destroyed
    FROM principal.subject_key k WHERE k.subject_id = p_subject;
  IF v_destroyed IS NOT NULL THEN
    RAISE EXCEPTION 'HP-ESC 2.3.4g: subject % has a DESTROYED key; destruction is final', p_subject;
  END IF;
  RETURN QUERY SELECT v_id, v_salt, false;
END;
$$;

COMMENT ON FUNCTION principal.ensure_subject_key(uuid, bytea) IS
  'R10-key. Idempotently mints the per-subject key ADR-003 §2.4''s crypto-shredding '
  'design requires, returning the HMAC salt the caller needs for subject_pseudonym. '
  'The database generates the salt; the caller supplies the wrapped DEK because only '
  'the caller holds the wrapping key. RAISES for a destroyed key: destruction is final.';

REVOKE ALL ON FUNCTION principal.ensure_subject_key(uuid, bytea) FROM PUBLIC;

-- hp_app only. The request path mints on first use; nothing else has any
-- business creating a subject key, and principal.subject_key itself stays
-- unreachable to every application role — as it is today, with no grants at all.
GRANT EXECUTE ON FUNCTION principal.ensure_subject_key(uuid, bytea) TO hp_app;

COMMIT;
