#!/bin/bash
# =====================================================================
# Run the project's existing SQL authorization/functional test suite against
# the NEON identity layer, proving RLS behavior is functionally UNCHANGED
# after auth.uid() → app.uid().
#
# Builds a fresh DB (Neon identity + all migrations + grants + servant auth,
# NO owner bootstrap — the tests seed their own owner), then runs every
# supabase/tests/*_test.sql.
#
# Usage: PSQL_SUPER="sudo -u postgres psql -p 5432" DB=neon_test bash db/neon/run_tests.sh
# =====================================================================
set -e
cd "$(dirname "$0")/../.."
PSQL="${PSQL_SUPER:-psql} -v ON_ERROR_STOP=1 -q"
DB=${DB:-neon_test}

echo "### building $DB (Neon identity + migrations + grants + servant auth)"
$PSQL -d postgres -c "drop database if exists $DB;" -c "create database $DB;" >/dev/null 2>&1
$PSQL -d "$DB" -f db/neon/00_identity.sql >/dev/null 2>&1
for f in supabase/migrations/*.sql; do
  b=$(basename "$f"); v=${b%%_*}; n=${b:0:4}
  [ "$v" = "0002" ] && continue
  if [ "$n" = "0005" ]; then
    $PSQL -d "$DB" -c "alter type public.approval_status add value if not exists 'suspended';" >/dev/null 2>&1 || true
    sed "/alter type public.approval_status add value/d" "$f" > /tmp/_m.sql; src=/tmp/_m.sql
  else src="$f"; fi
  $PSQL -d "$DB" -f "$src" >/dev/null 2>&1 || { echo "MIGRATION FAILED: $b"; exit 1; }
done
$PSQL -d "$DB" -f db/neon/10_grants.sql >/dev/null 2>&1
$PSQL -d "$DB" -f db/neon/20_servant_auth.sql >/dev/null 2>&1

echo "### running tests"
pass=0; fail=0; failed_list=""
for t in supabase/tests/*_test.sql; do
  tb=$(basename "$t")
  [ "$tb" = "_test_invites.sql" ] && continue
  if out=$($PSQL -d "$DB" -f "$t" 2>&1); then
    pass=$((pass+1)); echo "  PASS $tb"
  else
    fail=$((fail+1)); failed_list="$failed_list $tb"
    echo "  FAIL $tb"
    echo "$out" | grep -iE "error|exception" | grep -iv "^notice" | head -3 | sed 's/^/        /'
  fi
done
echo ""
echo "### RESULT: $pass passed, $fail failed"
[ -n "$failed_list" ] && echo "### failed:$failed_list"
[ "$fail" = "0" ]
