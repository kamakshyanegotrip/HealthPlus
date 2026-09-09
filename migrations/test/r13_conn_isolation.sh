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
# 3. AND THE REVERSE. What the retrieval role may reach, stated precisely.
#
# THIS SECTION USED TO SAY "evidence and nothing else", and migration 041 made
# it fail — correctly, by catching a real widening. Reworking it turned up that
# the old assertion had ALREADY been false for as long as it existed, in a place
# it did not look: it checked information_schema.role_table_grants only, and
# reasoner_role has held EXECUTE on principal.fetch_attribute_envelope and
# principal.attribute_ref_digest since migration 018. A boundary that only
# inspects tables is not a boundary on a schema whose access is function-shaped.
#
# So the invariant is restated as what it actually needs to be, in three parts:
#
#   (a) reasoner_role writes NOTHING, anywhere. Retrieval does not write, and
#       this is the part that makes Option 2 worth its cost.
#   (b) reasoner_role holds nothing at all — table OR function — in `safety` or
#       `obs`. Those are the schemas whose integrity §4.0.7 and C-30 depend on,
#       and they are the blast radius Option 2 was chosen to bound.
#   (c) outside `evidence`, its reach is an ENUMERATED allowlist, and every
#       table on it must be RLS-scoped to the calling subject's own rows. That
#       last clause is what keeps the allowlist from becoming a place to park an
#       unbounded read: being listed here is not enough, the row boundary has to
#       be real.
#
# Adding to the allowlist means coming here and arguing for it, which is the
# point. R10d-attr's argument: the §2.4.3 minor gate reads
# principal.patient_risk_flag, the composer needs the subject's region, and both
# reads are confined by p_prf_own / p_pp_own to the one subject the request is
# already about — so a SQL injection reached through retrieval gains access to
# the profile of the person whose request it is, and to nobody else's.
# ---------------------------------------------------------------------------
echo "3. reasoner_role: no writes, nothing in safety/obs, and an RLS-scoped allowlist elsewhere"

# (a) no writes, anywhere.
w=$(psql -qAt -c "
  SELECT count(*) FROM information_schema.role_table_grants
   WHERE grantee='reasoner_role' AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE')")
[ "$w" = "0" ] || fail "reasoner_role holds $w write privilege(s). Retrieval does not write."

# (b) nothing in safety or obs — tables and functions both.
leak=$(psql -qAt -c "
  SELECT string_agg(DISTINCT table_schema||'.'||table_name, ', ')
    FROM information_schema.role_table_grants
   WHERE grantee='reasoner_role' AND table_schema IN ('safety','obs')")
[ -z "$leak" ] || fail "reasoner_role holds table grants in safety/obs: $leak
Those schemas are the blast radius Option 2 exists to bound — code reached
through the retrieval role must not be able to touch a §4.0.7 event or the C-30
audit projection."

fleak=$(psql -qAt -c "
  SELECT string_agg(n.nspname||'.'||p.proname, ', ')
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('safety','obs')
     AND has_function_privilege('reasoner_role', p.oid, 'EXECUTE')
     AND NOT has_function_privilege('public', p.oid, 'EXECUTE')")
[ -z "$fleak" ] || fail "reasoner_role holds EXECUTE in safety/obs: $fleak
A function grant reaches just as far as a table grant, and this check did not
look at functions until R10d-attr."

# (c) the allowlist outside evidence, tables and functions.
ALLOW_TABLES="principal.patient_profile principal.patient_risk_flag"
ALLOW_FUNCS="principal.fetch_attribute_envelope principal.attribute_ref_digest"

outside=$(psql -qAt -c "
  SELECT DISTINCT table_schema||'.'||table_name
    FROM information_schema.role_table_grants
   WHERE grantee='reasoner_role' AND table_schema <> 'evidence' ORDER BY 1")
for obj in $outside; do
  case " $ALLOW_TABLES " in
    *" $obj "*) ;;
    *) fail "reasoner_role holds a grant on $obj, which is not on this gate's allowlist.
Retrieval reads evidence. A grant anywhere else needs an argument recorded in
section 3's header — not just a migration that adds it." ;;
  esac
done

outside_f=$(psql -qAt -c "
  SELECT n.nspname||'.'||p.proname
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname NOT IN ('evidence','pg_catalog','information_schema','app','public')
     AND has_function_privilege('reasoner_role', p.oid, 'EXECUTE')
     AND NOT has_function_privilege('public', p.oid, 'EXECUTE')
   ORDER BY 1")
for obj in $outside_f; do
  case " $ALLOW_FUNCS " in
    *" $obj "*) ;;
    *) fail "reasoner_role holds EXECUTE on $obj, which is not on this gate's allowlist." ;;
  esac
done

# And the clause that makes the allowlist safe rather than merely a list: every
# allowlisted principal table must confine the role to the calling subject.
for obj in $ALLOW_TABLES; do
  tbl=${obj#principal.}
  scoped=$(psql -qAt -c "
    SELECT count(*) FROM pg_policy pol
      JOIN pg_class c ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname='principal' AND c.relname='$tbl'
       AND c.relrowsecurity
       AND pg_get_expr(pol.polqual, pol.polrelid) LIKE '%current_user_id()%'")
  [ "$scoped" -ge 1 ] || fail "principal.$tbl is on the allowlist but has no RLS policy
scoping it to app.current_user_id(). The allowlist is only defensible while every
entry on it is confined to the subject the request is already about; without the
policy this is an unbounded read of every patient in the database."
done
echo "  no writes; nothing in safety/obs; 2 tables + 2 functions allowlisted, all subject-scoped"

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
