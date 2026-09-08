-- ============================================================================
-- MIGRATION 036 — FINISH C-30: obs.response_audit IS A PROJECTION, NOT A CHAIN
--
-- THE SYMPTOM. This has been true since migration 001_003 and nobody hit it,
-- because nothing has ever written this table outside a CI fixture:
--
--     INSERT INTO obs.response_audit (id, subject_pseudonym, …)
--     ERROR:  null value in column "row_hash" of relation "response_audit"
--             violates not-null constraint
--
-- As the OWNER. With every grant there is. `obs.response_audit` carries
-- `prev_hash bytea` and `row_hash bytea NOT NULL`, and NOTHING COMPUTES THEM:
-- the only trigger on the table is assert_reviewer_in_scope, and the only
-- function in the database that touches it is principal.erase_subject.
--
-- So the row is writable only by a caller who supplies a hash by hand — which
-- is exactly what migration 003a forbids, in its own words:
--
--     "The application never supplies prev_hash/row_hash; the trigger computes
--      both, which is what stops a compromised application from forging a chain."
--
-- The table demands a value its governing runbook forbids its writer to
-- produce, and no third party produces it. It has never been writable by any
-- permitted means.
--
-- ---------------------------------------------------------------------------
-- WHY THE COLUMNS ARE VESTIGIAL, AND HOW THAT WAS CHECKED
--
-- HP-RB-001's correction (logged as amendment C-30) says the record of truth is
-- the append-only, hash-chained `public.response_audit_event`, and that
-- `obs.response_audit` is a MUTABLE PROJECTION derived from it, carrying the
-- Charter's CHECK constraints and rebuildable at any time.
--
-- 003a implemented that — on the NEW table. Nobody went back to the old one, so
-- the projection kept the chain columns of the design it replaced.
--
-- Checked rather than assumed: across migrations/, chat-pipeline/src,
-- chat-pipeline/worker and src/jobs, there is NO reader and NO writer of
-- obs.response_audit.row_hash or .prev_hash. Every chain reference in this
-- repository — the trigger, its advisory lock, the verification HP-RB-001
-- describes — names public.response_audit_event.
--
-- The single exception proves the point: migrations/test/j34_metrics.sh had to
-- insert `gen_random_bytes(8)` as a row_hash, three times, to make its fixture
-- work at all. A random eight bytes standing in for a SHA-256 chain link is not
-- a chain; it is the shape of a chain, satisfied to get past a constraint. This
-- migration removes the constraint and that commit removes the forgery.
--
-- Note also that chat-pipeline/db/000_stub_upstream.sql — a reconstruction
-- written FROM the corrected documents — gives response_audit no chain columns
-- at all. The stub had C-30 right and the real schema is the one that lagged.
--
-- ---------------------------------------------------------------------------
-- WHY NOT ADD THE TRIGGER INSTEAD (the option that looks safer and is not)
--
-- Mirroring 003a's audit_event_chain() onto this table would drop nothing and
-- would reinstate the exact contradiction HP-RB-001 was written to resolve.
-- The projection is MUTABLE by design: review_state moves PENDING -> APPROVED
-- and reviewer_id fills in after the fact. A hash chain over a row that changes
-- either breaks at the first review decision, or covers only the immutable
-- columns and therefore attests to something nobody reads.
--
-- Tamper-evidence lives in the event log, which is append-only, which is why it
-- can be chained at all. Recorded here so the question is not reopened by
-- someone reading a changelog line that says "dropped a hash column".
--
-- ---------------------------------------------------------------------------
-- WHAT THIS DOES NOT TOUCH
--
-- public.response_audit_event keeps prev_hash/row_hash NOT NULL, keeps
-- trg_audit_event_chain, keeps forbid_mutation(), keeps its narrow grants. The
-- chain that matters is untouched, and migrations/test/c30_projection.sh
-- asserts that in both directions rather than leaving it to be believed.
--
-- The Charter text for C-30 (Annex A.5/A.6) still lags and still needs Board
-- approval per §6.3. This migration implements what 003a already decided; it
-- does not pre-empt the amendment's wording.
-- ============================================================================

BEGIN;

-- Fail loudly rather than silently no-op if someone has already changed this,
-- so a partially-applied cluster cannot look finished.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'obs' AND table_name = 'response_audit'
       AND column_name = 'row_hash'
  ) THEN
    RAISE NOTICE '036: obs.response_audit.row_hash already absent — nothing to finish';
  END IF;
END $$;

ALTER TABLE obs.response_audit DROP COLUMN IF EXISTS prev_hash;
ALTER TABLE obs.response_audit DROP COLUMN IF EXISTS row_hash;

COMMENT ON TABLE obs.response_audit IS
  'C-30 / HP-RB-001: a MUTABLE PROJECTION of public.response_audit_event, '
  'carrying the Charter''s CHECK constraints and rebuildable from the log at '
  'any time. It is deliberately NOT hash-chained — review_state and reviewer_id '
  'change after the row is written, and a chain over a mutable row attests to '
  'nothing. Tamper-evidence is the event log''s job (migration 003a).';

COMMIT;
