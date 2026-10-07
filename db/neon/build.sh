#!/bin/bash
# =====================================================================
# Build the full Neon-ready database from scratch.
#   db/neon/00_identity.sql     → app.*/auth.* identity, auth.users, roles, ext
#   supabase/migrations/*.sql   → the application schema UNCHANGED
#   db/neon/20_servant_auth.sql → servant_sessions + servant login/switch
#   db/neon/30_bootstrap.sql    → owner bootstrap (optional; replaces 0002)
#
# Usage:
#   DBURL="postgres://user:pass@host/db" bash db/neon/build.sh        # Neon/any PG
#   PSQL_SUPER="psql -p 5432 -U postgres" DB=app bash db/neon/build.sh  # local
# =====================================================================
set -e
cd "$(dirname "$0")/../.."

if [ -n "$DBURL" ]; then
  PSQL="psql $DBURL -v ON_ERROR_STOP=1 -q"
else
  PSQL="${PSQL_SUPER:-psql} -d ${DB:-app} -v ON_ERROR_STOP=1 -q"
fi

echo "==> 00_identity.sql"
$PSQL -f db/neon/00_identity.sql >/dev/null

echo "==> application migrations"
for f in supabase/migrations/*.sql; do
  b=$(basename "$f"); v=${b%%_*}; n=${b:0:4}
  [ "$v" = "0002" ] && { echo "   skip $b (Neon bootstrap replaces it)"; continue; }
  if [ "$n" = "0005" ]; then
    $PSQL -c "alter type public.approval_status add value if not exists 'suspended';" >/dev/null 2>&1 || true
    sed "/alter type public.approval_status add value/d" "$f" > /tmp/_m.sql; src=/tmp/_m.sql
  else src="$f"; fi
  if ! out=$($PSQL -f "$src" 2>&1); then echo "FAILED $b"; echo "$out" | grep -iv "^notice" | head -20; exit 1; fi
done

echo "==> 10_grants.sql"
$PSQL -f db/neon/10_grants.sql >/dev/null

echo "==> 20_servant_auth.sql"
$PSQL -f db/neon/20_servant_auth.sql >/dev/null

if [ -f db/neon/30_bootstrap.sql ]; then
  echo "==> 30_bootstrap.sql"
  $PSQL -f db/neon/30_bootstrap.sql >/dev/null
fi

echo "ALL OK"
