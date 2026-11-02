#!/usr/bin/env bash
# The phase 5 measurements of research/designs/e-cedar.md (throwaway; tag
# cedar-phase5): phase5.sql on a throwaway cluster, against the install file
# of the working tree, and, with a git revision as the argument, against that
# revision's install file too (the "before" column of the index table):
#   research/designs/e-cedar/phase5.sh 0845531
# Not a benchmark baseline: run it alone, nothing else on the machine.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(cd "$HERE/../../.." && pwd)
. "$EXT_DIR/test/lib/cluster.sh"
start_cluster
ensure_roles
"$PGBIN/psql" -X -q -d postgres -c 'select version()' -tA
run() {
    local label=$1 file=$2
    echo "== $label"
    psql_admin -c 'drop database if exists cedar_phase5' -c 'create database cedar_phase5'
    "$PGBIN/psql" -X -q -d cedar_phase5 -v ON_ERROR_STOP=1 -f "$file" >/dev/null
    "$PGBIN/psql" -X -q -d cedar_phase5 -f "$HERE/phase5.sql"
}
if [ $# -gt 0 ]; then
    OLD=$(mktemp)
    trap 'rm -f "$OLD"; stop_cluster' EXIT
    git -C "$EXT_DIR" show "$1:pg_permissions/pg_permissions--0.1.0.sql" > "$OLD"
    run "$1" "$OLD"
fi
run "working tree" "$EXT_DIR/pg_permissions--0.1.0.sql"
