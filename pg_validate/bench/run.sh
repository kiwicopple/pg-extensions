#!/usr/bin/env bash
# Run the JSON Schema benchmark against a Postgres server.
#
#   bench/run.sh [N] [IMPL]          # psql from PATH, PGHOST/PGPORT/PGUSER
#   docker compose -f docker/compose.yaml exec -T -u postgres pg18 \
#       /pg_validate/bench/run.sh 20000
#
# Creates the database pgval_bench, installs IMPL (default
# pg_validate--0.0.1.sql) into it with psql -f, runs bench/json_schema.sql
# with N documents per schema (default 20000) and drops the database. To
# compare with another build, pass its file, for example one extracted with
# git show main:pg_validate/pg_validate--0.0.1.sql.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
N=${1:-20000}
IMPL=${2:-$HERE/../pg_validate--0.0.1.sql}
DB=pgval_bench
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB"
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$IMPL" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -v n="$N" -d "$DB" -f "$HERE/json_schema.sql"
psql -X -q -d postgres -c "drop database if exists $DB"
