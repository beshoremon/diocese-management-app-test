#!/bin/bash
# Idempotent local Postgres 17 (Neon-equivalent) for Phase 1 dev/testing ONLY.
# Developer convenience for validating the Neon schema/identity/RLS in the
# sandbox; NOT part of the application or deployment.
set -e
which psql >/dev/null 2>&1 || sudo apt-get install -y -qq postgresql postgresql-contrib
sudo mkdir -p /var/lib/postgresql/data /var/run/postgresql
sudo chown -R postgres:postgres /var/lib/postgresql /var/run/postgresql
[ -f /var/lib/postgresql/data/PG_VERSION ] || sudo -u postgres /usr/lib/postgresql/17/bin/initdb -D /var/lib/postgresql/data >/dev/null
sudo -u postgres /usr/lib/postgresql/17/bin/pg_ctl -D /var/lib/postgresql/data status >/dev/null 2>&1 || \
  sudo -u postgres /usr/lib/postgresql/17/bin/pg_ctl -D /var/lib/postgresql/data -l /var/lib/postgresql/logfile -o "-p 5432" start >/dev/null
sleep 2
sudo -u postgres psql -p 5432 -tc "select version();" | head -1
