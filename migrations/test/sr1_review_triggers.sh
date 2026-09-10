#!/usr/bin/env bash
# ============================================================================
# SR-1 — §2.2.5b's five pre-publication review triggers, the database half.
#
# WHY THIS GATE EXISTS
#
# Charter §2.2.5d: "With Category C disabled (§2.3.2), 2.2.5b is the ONLY
# pre-publication human-review path in the product." HP-SR-001 found two of its
# five triggers implemented. The other three were closed together:
#
#   1  flagged high-risk profile (§4.6)     patientProfile.ts — was reading all
#                                           ten flags and using one
#   2  Elevated-Risk Topic List (§2.4.1)    migration 048 + elevatedTopic.ts
#   5  Tier 1/Tier 2 conflict (§1.8.3)      detection existed since migration
#                                           024; knowledgeLookup discarded the
#                                           column that carried it
#
# WHAT THIS FILE COVERS AND WHAT IT DOES NOT — the sixth clause of the standing
# correction, "name the depth your check stops at".
#
#   Covered here: everything the DATABASE decides. Whether an unadopted topic
#   list returns nothing, whether a termless or unsigned adoption can be written
#   at all, whether the reader is reachable by the role that calls it and
#   unreachable by the role that must not.
#
#   NOT covered here: the three-valued classifier and the trigger arithmetic,
#   which are pure TypeScript. chat-pipeline/test/elevatedTopic.test.ts and
#   reviewTriggers.test.ts cover those, and runPipeline.integration.test.ts
#   asserts the audit row's review_triggers end to end. A shell gate that
#   claimed to cover them would be claiming coverage it does not have — which
#   is what r10f_constraints.sh's header did until this week.
#
# Env: standard PG* vars, as the owner. Re-runnable: every write is rolled back.
# ============================================================================
set -euo pipefail
PGDATABASE="${PGDATABASE:-healthplus}"
export PGDATABASE
fail() { echo "SR-1 FAIL: $*" >&2; exit 1; }
count() { psql -qtAc "$1" | tr -d '[:space:]'; }

echo "SR-1: §2.2.5b review triggers, database half"

# ---------------------------------------------------------------------------
# §1. TRIGGER 2 fails CLOSED when no list is adopted.
#
#     The reader returning zero rows is the whole design (migration 048 §0.2):
#     the caller must read it as "cannot tell", not as "no match". This asserts
#     the zero; elevatedTopic.ts's UNEVALUABLE state asserts the reading.
# ---------------------------------------------------------------------------
REGION=$(count "SELECT data_region FROM public.residency_admission
                 WHERE admission_state = 'ADMITTED' ORDER BY residency_country LIMIT 1")
[ -n "$REGION" ] || fail "no ADMITTED residency; cannot resolve a jurisdiction."

ADOPTED=$(count "SELECT count(*) FROM safety.adopted_topic_list('$REGION','en')")
[ "$ADOPTED" = "0" ] || fail "adopted_topic_list returned $ADOPTED row(s) on a schema where
no clinician has signed anything. A topic list adopted by a migration is the same forgery
as a rule set adopted by one."
echo "  ok  §2.4.1 nothing adopted -> reader returns 0 (trigger 2 is UNEVALUABLE, not CLEAR)"

TOPICS=$(count "SELECT count(*) FROM safety.elevated_risk_topic")
[ "$TOPICS" = "14" ] || fail "expected the Charter's fourteen topics, found $TOPICS."
echo "  ok  §2.4.1's fourteen topics are present and none is adopted"

# ---------------------------------------------------------------------------
# §2. An adopted topic is returned — and adoption's two preconditions are
#     enforced by the SCHEMA rather than by whoever writes the UPDATE.
#
#     All three writes below are rolled back, so this gate leaves the table as
#     migration 048 wrote it.
# ---------------------------------------------------------------------------
CLIN=$(count "SELECT user_id FROM principal.clinician LIMIT 1")
if [ -n "$CLIN" ]; then
  OUT=$(psql -v ON_ERROR_STOP=1 -qtA <<SQL
BEGIN;
UPDATE safety.elevated_risk_topic
   SET terms = ARRAY['sr1probe'], clinically_adopted = true,
       adopted_by = '$CLIN', adopted_at = now()
 WHERE ordinal = 1 AND language = 'en';
SELECT 'adopted=' || count(*) FROM safety.adopted_topic_list('$REGION','en');
ROLLBACK;
SQL
)
  echo "$OUT" | grep -q "adopted=1" || fail "one adopted topic, reader returned: $OUT"
  echo "  ok  §2.4.1 one adopted topic -> reader returns it"

  # An adopted topic with no terms is a review trigger that can never match,
  # recorded as active — the second recurring pattern, in a table.
  if psql -v ON_ERROR_STOP=1 -q -c "BEGIN;
      UPDATE safety.elevated_risk_topic
         SET clinically_adopted = true, adopted_by = '$CLIN', adopted_at = now(), terms = '{}'
       WHERE ordinal = 2 AND language = 'en'; ROLLBACK;" >/dev/null 2>&1; then
    fail "a topic was adopted with NO TERMS. c_adopted_topic_is_detectable did not refuse it."
  fi
  echo "  ok  §2.4.1 adoption with no terms is refused (c_adopted_topic_is_detectable)"

  if psql -v ON_ERROR_STOP=1 -q -c "BEGIN;
      UPDATE safety.elevated_risk_topic
         SET clinically_adopted = true, terms = ARRAY['x'], adopted_by = NULL, adopted_at = NULL
       WHERE ordinal = 3 AND language = 'en'; ROLLBACK;" >/dev/null 2>&1; then
    fail "a topic was adopted with NO NAMED CLINICIAN. §0.6 means a signature, not a boolean."
  fi
  echo "  ok  §2.4.1 adoption without a named clinician is refused (c_topic_adoption_is_signed)"
else
  echo "  --  §2 skipped: no principal.clinician row to sign a probe with. Inventing one is"
  echo "      the forgery this table exists to prevent; run after scripts/seed-real.ts to cover it."
fi

# ---------------------------------------------------------------------------
# §3. The reader is reachable by the role that calls it, and by no other.
#
#     elevatedTopic.ts runs on the REDFLAG pool, not db(). Migration 048 §0.3
#     records why: hp_app holds USAGE on `safety` and not one table grant in it,
#     which is R13-conn's guarantee, and the topic list was one SELECT away from
#     being its first exception.
#
#     BOTH DIRECTIONS. A gate that only proves redflag_role CAN read would pass
#     just as happily if hp_app could too.
# ---------------------------------------------------------------------------
psql -v ON_ERROR_STOP=1 -qtAc \
  "SET LOCAL SESSION AUTHORIZATION redflag_role;
   SELECT count(*) FROM safety.adopted_topic_list('$REGION','en')" >/dev/null \
  || fail "redflag_role cannot call adopted_topic_list, so trigger 2 can never be evaluated."
echo "  ok  redflag_role can call safety.adopted_topic_list"

if psql -v ON_ERROR_STOP=1 -q -c \
  "SET LOCAL SESSION AUTHORIZATION hp_app;
   SELECT count(*) FROM safety.elevated_risk_topic" >/dev/null 2>&1; then
  fail "hp_app can read safety.elevated_risk_topic. R13-conn's guarantee is that the role
taking untrusted user input reaches NOTHING in safety; migration 048 §4 asserts the same
thing at apply time and this asserts it stays true."
fi
echo "  ok  hp_app cannot read it — R13-conn's boundary holds"

# ---------------------------------------------------------------------------
# §4. TRIGGER 5's inputs exist and are exposed.
#
#     §1.8.3's detection has been in the schema since migration 024. What was
#     missing was a reader, and the reader is the retrieval query selecting two
#     columns the function already returned. This asserts the function still
#     returns them — a rename or a signature change would otherwise turn the
#     trigger off silently, which is precisely how it was off for a year.
# ---------------------------------------------------------------------------
for col in conflict_id demotion_required; do
  HAS=$(count "SELECT count(*) FROM pg_proc p
                 JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname='evidence' AND p.proname='aggregate_claim'
                  AND pg_get_function_result(p.oid) LIKE '%$col%'")
  [ "$HAS" = "1" ] || fail "evidence.aggregate_claim no longer returns $col.
§2.2.5b trigger 5 reads it from the retrieval query; without it the trigger cannot fire and
nothing else would say so."
done
echo "  ok  §1.8.3 evidence.aggregate_claim still returns conflict_id and demotion_required"

CONFLICT_TABLE=$(count "SELECT count(*) FROM information_schema.tables
                         WHERE table_schema='evidence' AND table_name='claim_conflict'")
[ "$CONFLICT_TABLE" = "1" ] || fail "evidence.claim_conflict is gone; §1.8.3 has no input."
echo "  ok  §1.8.3 evidence.claim_conflict exists (detection input)"

# ---------------------------------------------------------------------------
# §5. TRIGGER 1's input: the ten §4.6 flag keys the Charter's list depends on.
#
#     highRiskProfileRequiresReview fires on ANY active flag, so the SET of
#     keys is what defines the trigger's breadth. A key removed from the CHECK
#     constraint silently narrows a safety gate.
# ---------------------------------------------------------------------------
KEYS=$(count "SELECT count(*) FROM (
    SELECT regexp_matches(pg_get_constraintdef(c.oid), '''([A-Z_0-9]+)''', 'g')
      FROM pg_constraint c
     WHERE c.conrelid = 'principal.patient_risk_flag'::regclass
       AND pg_get_constraintdef(c.oid) LIKE '%flag_key%') s")
[ "$KEYS" = "10" ] || fail "principal.patient_risk_flag's flag_key CHECK now admits $KEYS
key(s), not the ten §4.6 names. §2.2.5b trigger 1 fires on ANY of them, so this set IS the
trigger's breadth — changing it narrows or widens a safety gate silently."
echo "  ok  §4.6 the ten high-risk flag keys are intact (trigger 1's breadth)"

echo "SR-1: the database half of all five §2.2.5b triggers holds."
