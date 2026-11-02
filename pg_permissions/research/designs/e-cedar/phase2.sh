#!/usr/bin/env bash
# The phase 2 measurements of research/designs/e-cedar.md (throwaway; tags
# cedar-ancestors and cedar-requests), on a throwaway cluster:
#   1. ancestors.sql: closure table (A) against the recursive walk (C)
#   2. concurrent writes with pgbench: 8 clients put new leaf entities, with C
#      (cedar_put_entities, no lock) and with A (closure rows, global lock)
#   3. requests.sql: cedar_is_authorized per request, typical cases
# Not a benchmark baseline: run it alone, nothing else on the machine.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
EXT=$HERE/../../../pg_permissions--0.1.0.sql
. "$HERE/../../../test/lib/cluster.sh"
start_cluster
psql_admin -c 'create database cedar_measure'
"$PGBIN/psql" -X -q -d cedar_measure -c 'select version()' -tA
"$PGBIN/psql" -X -q -d cedar_measure -v ON_ERROR_STOP=1 -f "$EXT" >/dev/null
"$PGBIN/psql" -X -q -d cedar_measure -f "$HERE/ancestors.sql"
# depth-10 data for the concurrent writes
"$PGBIN/psql" -X -q -d cedar_measure -c 'select m.load(10, 1000)' >/dev/null
W=$(mktemp -d)
cat > "$W/c.sql" <<'SQL'
\set k random(1, 1000)
select permissions.cedar_put_entities(entities => jsonb_build_array(jsonb_build_object('uid', jsonb_build_object('type', 'User', 'id', 'p' || :client_id || '_' || random()), 'parents', jsonb_build_array(jsonb_build_object('type', 'Group', 'id', 'c' || :k || '_1')))));
SQL
cat > "$W/a.sql" <<'SQL'
\set k random(1, 1000)
select m.put_leaf_a('User', 'q' || :client_id || '_' || random(), 'Group', 'c' || :k || '_1');
SQL
for v in c a; do
    echo "concurrent writes, 8 clients, 10 s: candidate $(echo $v | tr a-z A-Z)"
    "$PGBIN/pgbench" -n -c 8 -j 8 -T 10 -f "$W/$v.sql" cedar_measure 2>&1 | grep -E '^(tps|latency average)'
done
rm -rf "$W"
psql_admin -c 'create database cedar_requests'
"$PGBIN/psql" -X -q -d cedar_requests -v ON_ERROR_STOP=1 -f "$EXT" >/dev/null
"$PGBIN/psql" -X -q -d cedar_requests -f "$HERE/requests.sql"
