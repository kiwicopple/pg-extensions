#!/usr/bin/env bash
# Run measure.sql (throwaway, tag cedar-eval-micro) on a throwaway cluster.
# Not a benchmark baseline: run it alone, nothing else on the machine.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../../test/lib/cluster.sh"
start_cluster
psql_admin -c 'create database cedar_measure'
"$PGBIN/psql" -X -q -d cedar_measure -c 'select version()' -tA
"$PGBIN/psql" -X -q -d cedar_measure -f "$HERE/measure.sql"
