#!/usr/bin/env bash
# Run the test suite or the benchmark against Postgres 16, 17 and 18 (Docker),
# for each design, strictly one at a time.
#
#   docker/run-matrix.sh test                                  # 3 versions x designs a, b, c
#   docker/run-matrix.sh test --versions 18 --designs c -- -v 03_tle
#   docker/run-matrix.sh bench -- --scale large                # 3 x 3 large runs
#   docker/run-matrix.sh bench --versions 16,17 -- --scale medium --shape wide
#   docker/run-matrix.sh bench --designs a -- --scale small --duration 2 --tag smoke
#
# Options:
#   --versions 16,17,18   which servers, in this order (default all three)
#   --designs a,b,c       which prototypes, in this order (default a, b and c);
#                         `d` is prototypes/d-per-model.sql (tests only so far:
#                         it has no benchmark seeds yet), `ext` the extension
#                         file pg_permissions--0.0.1.sql
#   --keep-running        leave the last server running (default: compose down)
#   -- ARGS               passed to test/run.sh or bench/run.sh
#                         (--external and --impl are added here)
#
# For each version the other servers are stopped and this one is started, so
# only one server uses the CPUs at a time. Each design then runs in a
# throwaway client container (`docker compose run`) from the same image, so
# psql and pgbench match the server version. It connects over the server's
# Unix socket (a shared volume), like the local throwaway cluster, and has
# its own cpus/mem limits, so pgbench doesn't take CPU from the server's 4.
# Benchmark JSON gets environment "docker" and a host description that
# includes the container limits read from the server's cgroup.
#
# Output is copied to bench/results/matrix-<test|bench>-<timestamp>.log (git
# ignored). A summary is printed at the end; exit status is 1 if any run failed.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(dirname "$HERE")

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

MODE=${1:-}
case "$MODE" in
    test|bench) shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

VERSIONS=16,17,18
DESIGNS=a,b,c
KEEP=0
PASS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --versions) VERSIONS=$2; shift 2 ;;
        --designs) DESIGNS=$2; shift 2 ;;
        --keep-running) KEEP=1; shift ;;
        --) shift; PASS=("$@"); break ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1 (harness arguments go after --)" >&2; exit 2 ;;
    esac
done

impl_for() {
    case "$1" in
        a) echo prototypes/a-tuple-core.sql ;;
        b) echo prototypes/b-policy-first.sql ;;
        c) echo prototypes/c-compiled-model.sql ;;
        d) echo prototypes/d-per-model.sql ;;
        ext) echo pg_permissions--0.0.1.sql ;;
        *) echo "unknown design: $1 (expected a, b, c, d or ext)" >&2; return 1 ;;
    esac
}
IFS=, read -r -a VERSION_LIST <<<"$VERSIONS"
IFS=, read -r -a DESIGN_LIST <<<"$DESIGNS"
for v in "${VERSION_LIST[@]}"; do
    case "$v" in 16|17|18) ;; *) echo "unknown version: $v (expected 16, 17 or 18)" >&2; exit 2 ;; esac
done
for d in "${DESIGN_LIST[@]}"; do impl_for "$d" >/dev/null || exit 2; done

compose() { docker compose -f "$HERE/compose.yaml" "$@"; }

if [ "$(uname -s)" = Darwin ]; then
    MACHINE="$(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) CPU, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
else
    MACHINE="$(uname -m), $(nproc) CPU"
fi

# The host's time zone, so report dates and file names in bench/results/ match
# local runs (containers default to UTC).
TZ_NAME=${TZ:-$(readlink /etc/localtime 2>/dev/null | sed -n 's|.*/zoneinfo/||p')}

mkdir -p "$EXT_DIR/bench/results"
LOG="$EXT_DIR/bench/results/matrix-$MODE-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

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
        SUMMARY+=("$svc | (all) | server failed to start")
        FAILED=1
        continue
    fi
    read -r quota period < <(compose exec -T "$svc" cat /sys/fs/cgroup/cpu.max)
    mem=$(compose exec -T "$svc" cat /sys/fs/cgroup/memory.max | tr -d '\r')
    cpus=$( [ "$quota" = max ] && echo unlimited || awk -v q="$quota" -v p="$period" 'BEGIN { printf "%g", q / p }')
    memdesc=$( [ "$mem" = max ] && echo unlimited || awk -v m="$mem" 'BEGIN { printf "%gg", m / 1073741824 }')
    host="$MACHINE; container cpus=$cpus mem=$memdesc"

    for d in "${DESIGN_LIST[@]}"; do
        impl=$(impl_for "$d")
        echo
        echo "==== $svc / $d ($impl): $MODE/run.sh ${PASS[*]:-}"
        start=$(date +%s)
        out_file=$(mktemp)
        compose run --rm --no-deps -T --entrypoint bash -u postgres \
            -e PGHOST=/var/run/postgresql -e PGUSER=postgres -e TZ="${TZ_NAME:-UTC}" \
            -e BENCH_ENVIRONMENT=docker -e BENCH_HOST="$host" \
            "$svc" "/pg_permissions/$MODE/run.sh" --external --impl "$impl" ${PASS[@]+"${PASS[@]}"} 2>&1 |
            grep --line-buffered -v -E '^ ?Container .*(Creating|Created|Starting|Started|Running|Waiting|Healthy)' | tee "$out_file"
        status=${PIPESTATUS[0]}
        secs=$(( $(date +%s) - start ))
        if [ "$MODE" = test ]; then
            result=$(grep -E '^(All passed|Failures|No spec files)' "$out_file" | tail -1 | sed 's/\x1b\[[0-9;]*m//g')
        else
            result=$(grep -E '^Saved ' "$out_file" | sed 's/^Saved //' | paste -sd ' ' -)
        fi
        [ "$status" = 0 ] || FAILED=1
        SUMMARY+=("$svc | $d | exit $status, ${secs}s | ${result:-no result}")
        rm -f "$out_file"
    done
    compose stop "$svc" >/dev/null 2>&1
done

if [ $KEEP = 1 ]; then
    compose up -d --wait "pg${VERSION_LIST[${#VERSION_LIST[@]}-1]}" >/dev/null 2>&1
else
    compose down >/dev/null 2>&1
fi

echo
echo "==== Summary ($MODE, $(( ($(date +%s) - START_ALL) / 60 )) min total; log: ${LOG#$EXT_DIR/})"
printf '%s\n' "${SUMMARY[@]}"
exit $FAILED
