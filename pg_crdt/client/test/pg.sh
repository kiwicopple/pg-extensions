#!/usr/bin/env bash
# Run the client's integration test (pg.test.js) against Postgres with the
# extension installed: a throwaway cluster from test/lib/cluster.sh, as
# test/run.sh does, or with --external the server from PGHOST/PGPORT/PGUSER.
#
#   client/test/pg.sh
#   client/test/pg.sh --external
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(cd "$HERE/../.." && pwd)
EXTERNAL=0
[ "${1:-}" = "--external" ] && EXTERNAL=1
. "$EXT_DIR/test/lib/cluster.sh"

start_cluster
export PATH="$PGBIN:$PATH"

DB=pgcrdt_client_test
psql_admin -c "drop database if exists $DB with (force)" -c "create database $DB encoding 'UTF8' template template0"
"$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$EXT_DIR/pg_crdt--0.0.1.sql" >/dev/null
echo "Postgres: $("$PGBIN/psql" -X -tA -d "$DB" -c 'show server_version')"

status=0
PG_CRDT_CLIENT_DB=$DB PGCLIENTENCODING=UTF8 node --test "$HERE/pg.test.js" || status=$?
psql_admin -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
exit $status
