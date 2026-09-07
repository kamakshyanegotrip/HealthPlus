#!/usr/bin/env bash
# ============================================================================
# RF4 — the nearest-ED lookup, run against the real schema.
#
# WHY THIS EXISTS AS WELL AS THE UNIT TESTS
#
# test/templateSlots.test.ts covers the renderer thoroughly and injects a fake
# for resolveNearestFacility, so it says nothing at all about the SQL. A
# negative control proved it: deleting `AND has_emergency_department` from the
# query broke nothing that any test could see.
#
# That is the shape of PR #4's bug — a fake that encodes the same assumption
# as the code — and it is exactly what CI-3 exists to stop. So this runs the
# ACTUAL exported function against a real database with real rows, and asserts
# the two predicates that are safety-relevant and invisible to a fake:
#
#   * a facility with no emergency department is never returned;
#   * a facility in a DIFFERENT city is never returned. Naming an emergency
#     department 1,400 km away is worse than naming none, because the
#     actionable instruction is the emergency number beside it and a wrong
#     address competes with it for attention.
#
# plus the ranking: city beats subdivision beats country.
#
# Env: standard PG* vars. Run after migrations have been applied.
# ============================================================================
set -euo pipefail

PGDATABASE="${PGDATABASE:-healthplus}"
export PGDATABASE
DB_URL="postgresql://${PGUSER:-postgres}:${PGPASSWORD:-postgres}@${PGHOST:-localhost}:${PGPORT:-5432}/${PGDATABASE}"

fail() { echo "RF4 FAIL: $*" >&2; exit 1; }

echo "RF4 fixture: six facilities, three of them traps that WIN if their guard is dropped"
psql -v ON_ERROR_STOP=1 -q <<'SQL'
DO $$
DECLARE s uuid := gen_random_uuid();
BEGIN
  DELETE FROM safety.emergency_facility_reference WHERE facility_name LIKE 'RF4 %';

  INSERT INTO evidence.evidence_source
    (id, tier, source_type, publisher, title, url, published_at,
     retrieved_at, last_verified_at, language, retracted, content_hash)
  VALUES (s, 'TIER_1', 'GUIDELINE', 'RF4 fixture publisher', 'RF4 fixture',
          'https://example.test/rf4', now(), now(), now(), 'en', false, gen_random_bytes(8));

  INSERT INTO safety.emergency_facility_reference
    (id, country, subdivision, city, facility_name, address_line,
     has_emergency_department, open_24h, phone_e164, language,
     source_id, last_verified_at, active)
  VALUES
    -- The right answer for Delhi / New Delhi. Deliberately NOT open 24h, so
    -- every trap below outranks it on the open_24h tiebreak and would WIN if
    -- its guard were removed. A trap that cannot win proves nothing: the
    -- first version of this fixture had two traps that lost on an arbitrary
    -- tiebreak, and both negative controls passed while the guards were gone.
    (gen_random_uuid(),'IN','Delhi','New Delhi','RF4 City General','12 Ring Road',
     true,  false, '+911123456789','en', s, now() - interval '2 hours', true),
    -- region-level: the right answer when only the subdivision is known
    (gen_random_uuid(),'IN','Delhi',NULL,'RF4 Region Hospital','Region Road',
     true,  false, NULL,'en', s, now() - interval '2 hours', true),
    -- country-level: the right answer when nothing narrower is known
    (gen_random_uuid(),'IN',NULL,NULL,'RF4 National Centre','National Ave',
     true,  true,  NULL,'en', s, now() - interval '2 hours', true),
    -- TRAP 1: real ED, wrong city. Outranks nothing in Delhi because it is
    -- excluded outright; it exists so the city predicate has something to
    -- exclude.
    (gen_random_uuid(),'IN','Maharashtra','Mumbai','RF4 Wrong City','Marine Drive',
     true,  true,  NULL,'en', s, now(), true),
    -- TRAP 2: right city, open 24h, freshly verified, NO emergency department.
    -- Wins the ranking outright if `has_emergency_department` is dropped.
    (gen_random_uuid(),'IN','Delhi','New Delhi','RF4 No ED Clinic','No ED St',
     false, true,  NULL,'en', s, now(), true),
    -- TRAP 3: right city, real ED, open 24h, freshly verified — and INACTIVE.
    -- Wins the ranking outright if `active` is dropped.
    (gen_random_uuid(),'IN','Delhi','New Delhi','RF4 Inactive Best','Retired Rd',
     true,  true,  NULL,'en', s, now(), false);
END $$;
SQL

# Run the REAL exported function — not a reimplementation of its query, which
# could drift from it exactly as PR #4's fake drifted from provider_org.
probe() { # $1 subdivision-or-null, $2 city-or-null
  DATABASE_URL="$DB_URL" npx --prefix chat-pipeline tsx -e "
    import { resolveNearestFacility } from './chat-pipeline/src/lib/pipeline/templateSlots';
    const sub = ${1};
    const city = ${2};
    resolveNearestFacility('IN', sub, city, 'en').then((f) => {
      console.log(f ? f.facilityName : '<none>');
      process.exit(0);
    });
  " 2>/dev/null | tail -1
}

got=$(probe "'Delhi'" "'New Delhi'")
[ "$got" = "RF4 City General" ] || fail "Delhi/New Delhi returned '$got', expected RF4 City General"
echo "  city match          -> $got"

got=$(probe "'Delhi'" "null")
[ "$got" = "RF4 Region Hospital" ] || fail "Delhi/- returned '$got', expected RF4 Region Hospital"
echo "  subdivision match   -> $got"

got=$(probe "null" "null")
[ "$got" = "RF4 National Centre" ] || fail "-/- returned '$got', expected RF4 National Centre"
echo "  country match       -> $got"

# THE ONE THAT MATTERS. A patient in Kochi must not be sent to Mumbai.
got=$(probe "'Kerala'" "'Kochi'")
[ "$got" != "RF4 Wrong City" ] || fail "a facility in a DIFFERENT city was returned. \
Naming an emergency department 1,400 km away competes for attention with the \
emergency number beside it, which is the instruction that actually helps."
[ "$got" = "RF4 National Centre" ] || fail "Kerala/Kochi returned '$got', expected the country-level row"
echo "  wrong city refused  -> $got"

# And the clinic with no ED must be invisible at every level. Written out
# rather than looped: the city argument contains a space, and quoting it
# through a loop variable is how a check ends up silently probing nothing.
no_ed_check() { # $1 subdivision, $2 city, $3 label
  local g
  g=$(probe "$1" "$2")
  [ "$g" != "RF4 No ED Clinic" ] \
    || fail "a facility with has_emergency_department = false was returned for $3. \
§4.1 names an EMERGENCY DEPARTMENT; a clinic that does not have one is the wrong place to send someone."
}
no_ed_check "'Delhi'" "'New Delhi'" "city level"
no_ed_check "'Delhi'" "null"        "subdivision level"
no_ed_check "null"    "null"        "country level"
echo "  no-ED clinic never returned at any level"

# An inactive row is a row someone deliberately took out of service. It must
# be invisible even though it is the best match on every other axis.
inactive_check() { # $1 subdivision, $2 city, $3 label
  local g
  g=$(probe "$1" "$2")
  [ "$g" != "RF4 Inactive Best" ] \
    || fail "an inactive facility was returned for $3. active = false is how a \
facility is withdrawn; returning one anyway sends a person to a place someone \
took off the list on purpose."
}
inactive_check "'Delhi'" "'New Delhi'" "city level"
inactive_check "'Delhi'" "null"        "subdivision level"
inactive_check "null"    "null"        "country level"
echo "  inactive facility never returned at any level"

echo "RF4: nearest-ED lookup verified against the real schema."
