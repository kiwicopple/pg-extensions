#!/usr/bin/env bash
# Run the test suite against Postgres 16, 17 and 18 (Docker), one server at
# a time.
#
#   docker/run-matrix.sh                         # 3 versions x the extension
#   docker/run-matrix.sh --versions 18 -- -v 03_tle
#   docker/run-matrix.sh -- registry             # only the registry specs
#
# Options:
#   --versions 16,17,18   which servers, in this order (default all three)
#   --keep-running        leave the last server running (default: compose down)
#   -- ARGS               passed to test/run.sh (--external is added here)
#
# For each version the other servers are stopped and this one is started.
# The suite then runs in a throwaway client container (`docker compose run`)
# from the same image, so psql matches the server version, over the server's
# Unix socket (a shared volume). The servers preload pg_tle, so
# test/spec/03_tle_install.sql runs its pgtle.install_extension branch.
#
# A summary is printed at the end; exit status is 1 if any run failed.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

# Accept and ignore a leading "test", like pg_permissions' run-matrix.sh.
[ "${1:-}" = test ] && shift

VERSIONS=16,17,18
KEEP=0
PASS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --versions) VERSIONS=$2; shift 2 ;;
        --keep-running) KEEP=1; shift ;;
        --) shift; PASS=("$@"); break ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1 (test/run.sh arguments go after --)" >&2; exit 2 ;;
    esac
done

IFS=, read -r -a VERSION_LIST <<<"$VERSIONS"
for v in "${VERSION_LIST[@]}"; do
    case "$v" in 16|17|18) ;; *) echo "unknown version: $v (expected 16, 17 or 18)" >&2; exit 2 ;; esac
done

compose() { docker compose -f "$HERE/compose.yaml" "$@"; }

SUMMARY=()
FAILED=0
START_ALL=$(date +%s)
for v in "${VERSION_LIST[@]}"; do
    svc="pg$v"
    echo "==== $svc: stopping other servers, starting $svc"
    compose stop >/dev/null 2>&1
    if ! compose up -d --wait "$svc" >/dev/null 2>&1; then
        echo "error: $svc didn't start; docker compose logs $svc:"
        compose logs --tail 30 "$svc"
        SUMMARY+=("$svc | server failed to start")
        FAILED=1
        continue
    fi

    # The real control file, for test/spec/04_control_install.sql.
    if ! compose exec -T -u root "$svc" sh -c \
        'cp /pg_validate/pg_validate.control /pg_validate/pg_validate--*.sql "$(pg_config --sharedir)/extension/"'; then
        echo "warning: couldn't copy pg_validate.control into $svc; 04_control_install will SKIP"
    fi

    echo "==== $svc: test/run.sh ${PASS[*]:-}"
    start=$(date +%s)
    out_file=$(mktemp)
    compose run --rm --no-deps -T --entrypoint bash -u postgres \
        -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
        "$svc" /pg_validate/test/run.sh --external ${PASS[@]+"${PASS[@]}"} 2>&1 |
        grep --line-buffered -v -E '^ ?Container .*(Creating|Created|Starting|Started|Running|Waiting|Healthy)' | tee "$out_file"
    status=${PIPESTATUS[0]}
    secs=$(( $(date +%s) - start ))
    result=$(grep -E '^(All passed|Failures|No spec files)' "$out_file" | tail -1 | sed 's/\x1b\[[0-9;]*m//g')
    [ "$status" = 0 ] || FAILED=1
    SUMMARY+=("$svc | exit $status, ${secs}s | ${result:-no result}")
    rm -f "$out_file"
    compose stop "$svc" >/dev/null 2>&1
done

if [ $KEEP = 1 ]; then
    compose up -d --wait "pg${VERSION_LIST[${#VERSION_LIST[@]}-1]}" >/dev/null 2>&1
else
    compose down >/dev/null 2>&1
fi

echo
echo "==== Summary ($(( ($(date +%s) - START_ALL) / 60 )) min total)"
printf '%s\n' "${SUMMARY[@]}"
exit $FAILED
