#!/usr/bin/env bash
# Run the test suite on Postgres 16, 17 and 18 in Docker, with pg_tle and
# pg_crdt.control in the extension directory, so every branch of 03_install
# runs (plain script, pgtle.install_extension, create extension from the
# control file).
#
#   test/docker.sh                 # 16, 17 and 18, one after the other
#   test/docker.sh 18              # one version
#   test/docker.sh 17 18 -- -v 03  # runner arguments after --
#
# Each run is a throwaway container from $PG_CRDT_IMAGE:<version> (default
# pg_permissions-pg, the Postgres + pg_tle images that pg_permissions/docker
# builds: `docker compose -f pg_permissions/docker/compose.yaml build`). As
# root it copies the control file and the SQL file into the extension
# directory, then runs test/run.sh as postgres with its own throwaway cluster
# (test/lib/cluster.sh preloads pg_tle when it finds it).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(dirname "$HERE")
IMAGE=${PG_CRDT_IMAGE:-pg_permissions-pg}

VERSIONS=()
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --) shift; ARGS=("$@"); break ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) VERSIONS+=("$1"); shift ;;
    esac
done
[ ${#VERSIONS[@]} = 0 ] && VERSIONS=(16 17 18)

status=0
summary=()
for v in "${VERSIONS[@]}"; do
    if ! docker image inspect "$IMAGE:$v" >/dev/null 2>&1; then
        echo "error: image $IMAGE:$v not found; build it with: docker compose -f pg_permissions/docker/compose.yaml build pg$v" >&2
        status=1; summary+=("$v: image missing"); continue
    fi
    echo "==== Postgres $v ($IMAGE:$v)"
    out=$(mktemp)
    docker run --rm -v "$EXT_DIR:/pg_crdt:ro" "$IMAGE:$v" bash -c '
        cp /pg_crdt/pg_crdt.control /pg_crdt/pg_crdt--*.sql "$(pg_config --sharedir)/extension/" &&
        exec gosu postgres /pg_crdt/test/run.sh "$@"' _ ${ARGS[@]+"${ARGS[@]}"} 2>&1 | tee "$out"
    [ "${PIPESTATUS[0]}" = 0 ] || status=1
    summary+=("$v: $(grep -E '^(All passed|Failures|No spec files)' "$out" | tail -1)")
    rm -f "$out"
    echo
done

echo "==== Summary"
printf '%s\n' "${summary[@]}"
exit $status
