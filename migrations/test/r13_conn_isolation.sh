#!/usr/bin/env bash
# ============================================================================
# R13-conn — the roles are reachable, AND they are isolated from each other.
#
# R13-conn was decided on 8 September 2026 as Option 2: one LOGIN role per
# worker role, one pool per role, rather than one connection that assumes
# roles. Migration 034 implements it.
#
# THE ARGUMENT FOR OPTION 2 WAS A SECURITY CLAIM, SO THIS TESTS THE CLAIM.
# It was not "separate roles are tidier". It was: a pool cannot become another
# role, so code reached through the retrieval path cannot write a safety event.
# That claim is only worth the migration if it is true, and it is only true if
# each role's grants are as narrow as they are supposed to be.
#
# Section 2 is the one that matters. If reasoner_role can write a
# safety.red_flag_event, Option 2 bought nothing over Option 3 and the
# migration is decoration.
#
# Roles are exercised with SET SESSION AUTHORIZATION rather than by connecting
# with a password, deliberately: ALTER ROLE ... PASSWORD is CLUSTER-WIDE and
# has already escaped a throwaway database once in this project (HP-JOB-007
# §9). The privilege checks are identical either way; the connection itself is
# covered by sec1_region_context.sh §5, which uses a probe role it drops in a
# trap.
#
# Env: standard PG* vars. Run after migrations have been applied.
# ============================================================================
set -euo pipefail
PGDATABASE="${PGDATABASE:-healthplus}"
export PGDATABASE
fail() { echo "R13-conn FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. REACHABLE. The four roles with a caller can log in; the three without
#    cannot, and that is deliberate rather than an oversight.
# ---------------------------------------------------------------------------
echo "1. roles with a caller can log in; roles without one cannot"
for r in redflag_role reasoner_role alert_role metrics_role dqe_role; do
  ok=$(psql -qAt -c "SELECT rolcanlogin FROM pg_roles WHERE rolname='$r'")
  [ "$ok" = "t" ] || fail "$r cannot log in. Migration 034 §1 gives LOGIN to the four roles
that have a process behind them; without it every grant and policy R13 and
migration 031 fixed is still unreachable in production."
done
# dqe_role LEFT THIS LIST IN MIGRATION 037, which is the outcome the message
# below asks for: the ingestion job now connects through src/db/pool.ts's dqe
# pool, so the role has a caller and gets LOGIN in the migration that built it.
for r in confirmation_ui_role erasure_role; do
  ok=$(psql -qAt -c "SELECT rolcanlogin FROM pg_roles WHERE rolname='$r'")
  [ "$ok" = "f" ] || fail "$r can log in, but nothing connects as it.
Migration 034 §1 withholds LOGIN from roles with no caller on purpose — the
same reasoning that had migration 031 revoke thirty speculative grants. If a
caller now exists, give it LOGIN in the migration that builds the caller."
done
echo "  5 reachable, 2 deliberately not"

# ---------------------------------------------------------------------------
# 2. ISOLATED. THE CLAIM OPTION 2 WAS CHOSEN FOR.
#    No role but redflag_role may write a §4.0.7 safety event.
# ---------------------------------------------------------------------------
echo "2. only redflag_role may write a safety event"
for r in reasoner_role alert_role metrics_role; do
  can=$(psql -qAt -c "SELECT has_table_privilege('$r','safety.red_flag_event','INSERT')")
  [ "$can" = "f" ] || fail "$r can INSERT into safety.red_flag_event.
That is the whole claim Option 2 was chosen for: a pool cannot become another
role, so code reached through this role cannot forge a §4.0.7 event. If this
role can write one, Option 2 bought nothing over Option 3 and migration 034 is
decoration rather than a control."
done
can=$(psql -qAt -c "SELECT has_table_privilege('redflag_role','safety.red_flag_event','INSERT')")
[ "$can" = "t" ] || fail "redflag_role CANNOT write a red_flag_event. A boundary that also
blocks the permitted direction is an outage, not a boundary."
echo "  reasoner, alert and metrics all refused; redflag permitted"

# ---------------------------------------------------------------------------
# 3. AND THE REVERSE. The retrieval role reads evidence and nothing else.
# ---------------------------------------------------------------------------
echo "3. reasoner_role reads evidence and holds nothing in safety, obs or principal"
leak=$(psql -qAt -c "
  SELECT string_agg(DISTINCT table_schema||'.'||table_name, ', ')
    FROM information_schema.role_table_grants
   WHERE grantee='reasoner_role' AND table_schema <> 'evidence'")
[ -z "$leak" ] || fail "reasoner_role holds grants outside evidence: $leak
Retrieval reads evidence. Anything else is privilege it did not need and
cannot justify."
w=$(psql -qAt -c "
  SELECT count(*) FROM information_schema.role_table_grants
   WHERE grantee='reasoner_role' AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE')")
[ "$w" = "0" ] || fail "reasoner_role holds $w write privilege(s). Retrieval does not write."
echo "  evidence only, read only"

# ---------------------------------------------------------------------------
# 4. AND IT CAN ACTUALLY DO ITS JOB.
#    Found the hard way: after migration 033 gave reasoner_role EXECUTE on
#    claim_search, it had SELECT on NOTHING that claim_search reads. R13's
#    rules A and B were both clean — the role had schema USAGE, and those
#    tables have no RLS. A role that can execute a function but cannot read
#    what the function reads is a class neither rule covers.
# ---------------------------------------------------------------------------
echo "4. each role can perform its own real operation"
out=$(psql -qAt <<'SQL' 2>&1 || true
SET SESSION AUTHORIZATION reasoner_role;
SET app.data_region = 'IN';
SELECT 'rows:' || count(*) FROM evidence.claim_search('anything', ARRAY['guideline']::text[], NULL, 12);
SQL
)
case "$out" in
  *permission\ denied*) fail "reasoner_role cannot run retrieval: $out
Migration 034 §4 grants the eight evidence tables claim_search and its
callees read. This is the failure that appeared the moment the role could
log in — and it had been invisible because nothing had ever been that role." ;;
  *rows:*) echo "  reasoner_role runs claim_search" ;;
  *) fail "unexpected result running claim_search as reasoner_role: $out" ;;
esac

echo "R13-conn: roles reachable, isolated, and able to do their own work."
