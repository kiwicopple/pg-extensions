#!/usr/bin/env bash
# Benchmark a pg_permissions implementation with pgbench.
#
#   bench/run.sh --impl prototypes/a-tuple-core.sql              # small scale, 10s per workload
#   bench/run.sh --impl prototypes/a-tuple-core.sql --scale large
#   bench/run.sh --impl ... --check                              # exit 1 if any p95 is over budget
#
# Options: --scale small|medium|large  --duration SECONDS  --clients N
#          --only PATTERN  --design a|b|c|none  --external  --check
#
# --design defaults to the first letter of the --impl file name before a dash
# (a-tuple-core.sql -> a); anything else (the extension) is "none".
#
# Seeds tenant-scoped RBAC (preset API, any engine), runs the rbac_* and
# write_assign_role workloads, then, if bench/designs/<design>/ exists, seeds
# that design's per-document sharing (its native API) and runs its share_* and
# write_share workloads from bench/designs/<design>/workloads/. Otherwise
# sharing is skipped. Results are printed as a markdown table and saved to
# bench/results/.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(dirname "$HERE")
. "$EXT_DIR/test/lib/cluster.sh"

IMPL="pg_permissions--0.0.1.sql"
SCALE=small
DURATION=10
CLIENTS=4
ONLY=
CHECK=0
EXTERNAL=0
DESIGN=
while [ $# -gt 0 ]; do
    case "$1" in
        --impl) IMPL=$2; shift 2 ;;
        --scale) SCALE=$2; shift 2 ;;
        --duration) DURATION=$2; shift 2 ;;
        --clients) CLIENTS=$2; shift 2 ;;
        --only) ONLY=$2; shift 2 ;;
        --design) DESIGN=$2; shift 2 ;;
        --design=*) DESIGN=${1#--design=}; shift ;;
        --check) CHECK=1; shift ;;
        --external) EXTERNAL=1; shift ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$SCALE" in
    small)  DOCS=10000;   USERS=1000;  ORGS=20;  TEAMS=50 ;;
    medium) DOCS=100000;  USERS=5000;  ORGS=50;  TEAMS=200 ;;
    large)  DOCS=1000000; USERS=10000; ORGS=100; TEAMS=500 ;;
    *) echo "unknown scale: $SCALE" >&2; exit 2 ;;
esac

IMPL=$(resolve_impl "$IMPL")
[ -f "$IMPL" ] || { echo "error: implementation not found: $IMPL" >&2; exit 2; }
IMPL_NAME=$(basename "$IMPL" .sql)

if [ -z "$DESIGN" ]; then
    case "$IMPL_NAME" in
        [abc]-*) DESIGN=${IMPL_NAME%%-*} ;;
        *) DESIGN=none ;;
    esac
fi
case "$DESIGN" in
    a|b|c|none) ;;
    *) echo "unknown design: $DESIGN (expected a, b, c or none)" >&2; exit 2 ;;
esac
DESIGN_DIR="$HERE/designs/$DESIGN"

start_cluster
ensure_roles

DB=pgperm_bench
VARS=(-v docs=$DOCS -v users=$USERS -v orgs=$ORGS -v teams=$TEAMS)
PGB_VARS=(-D docs=$DOCS -D users=$USERS -D orgs=$ORGS -D teams=$TEAMS)

psql_admin -c "drop database if exists $DB" -c "create database $DB"
"$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$IMPL" >/dev/null

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pgperm-bench.XXXXXX")
cleanup_work() { case "$WORK" in */pgperm-bench.*) rm -rf "$WORK" ;; esac; stop_cluster; }
trap cleanup_work EXIT INT TERM

RESULTS=()
EXPLAINS=""

budget_for() {
    awk -v s="$SCALE" -v w="$1" '$1 == s && $2 == w { print $3 }' "$HERE/budgets.tsv"
}

explain_as_user() {
    local label=$1
    EXPLAINS="$EXPLAINS
### $label

\`\`\`
$("$PGBIN/psql" -X -q -tA -d "$DB" <<SQL 2>&1
\\o /dev/null
select set_config('permissions.subject_id', md5('user' || 1)::uuid::text, false);
\\o
set role authenticated;
explain (analyze, buffers, costs off) select id, title from public.documents order by id limit 50;
SQL
)
\`\`\`
"
}

# Guards against a workload that silently matches nothing: how many documents
# do sample users see through RLS?
sanity_check() {
    local line
    line=$("$PGBIN/psql" -X -q -tA -d "$DB" <<'SQL' 2>&1
create temp table visible (u int, n bigint);
grant all on visible to authenticated;
do $$
declare u int; n bigint;
begin
    foreach u in array array[1, 2, 3, 500] loop
        perform set_config('permissions.subject_id', md5('user' || u)::uuid::text, true);
        set local role authenticated;
        select count(*) into n from public.documents;
        reset role;
        insert into visible values (u, n);
    end loop;
end $$;
select string_agg(format('user %s: %s', u, n), ', ' order by u) from visible;
SQL
)
    echo "  visible documents: $line"
    case "$line" in
        *": 0"*) echo "  warning: a sample user sees no documents; check the seed" >&2 ;;
    esac
}

run_workload() {
    local name=$1
    if [ -n "$ONLY" ]; then case "$name" in *"$ONLY"*) ;; *) return ;; esac; fi
    local wfile="$HERE/workloads/$name.sql"
    [ -f "$wfile" ] || wfile="$DESIGN_DIR/workloads/$name.sql"
    local dir="$WORK/$name"
    mkdir -p "$dir"
    printf '  %-22s ' "$name"
    local out
    if ! out=$(cd "$dir" && "$PGBIN/pgbench" -n -T "$DURATION" -c "$CLIENTS" -j "$CLIENTS" -l \
                 "${PGB_VARS[@]}" -f "$wfile" "$DB" 2>&1); then
        echo "ERROR"
        printf '%s\n' "$out" | grep -iE 'error|abort' | head -3 | sed 's/^/      /'
        RESULTS+=("| $name | error | | | | | |")
        return
    fi
    local tps avg p50 p95 budget status
    tps=$(printf '%s\n' "$out" | sed -n 's/^tps = \([0-9.]*\).*/\1/p' | head -1)
    avg=$(printf '%s\n' "$out" | sed -n 's/^latency average = \([0-9.]*\) ms/\1/p')
    read -r p50 p95 < <(cat "$dir"/pgbench_log.* | awk '{ print $3 / 1000 }' | sort -n |
        awk '{ a[NR] = $1 } END { if (NR == 0) { print "- -"; exit }
             printf "%.2f %.2f\n", a[int(NR * 0.50) > 0 ? int(NR * 0.50) : 1], a[int(NR * 0.95) > 0 ? int(NR * 0.95) : 1] }')
    budget=$(budget_for "$name")
    if [ -z "$budget" ]; then status="-"
    elif awk -v p="$p95" -v b="$budget" 'BEGIN { exit !(p <= b) }'; then status="ok"
    else status="OVER"; fi
    printf 'p50 %8s ms   p95 %8s ms   %8.0f tps   budget %s\n' "$p50" "$p95" "$tps" "${budget:+$budget ms ($status)}"
    RESULTS+=("| $name | $p50 | $p95 | $avg | ${tps%.*} | ${budget:--} | $status |")
}

echo "Implementation: ${IMPL#$EXT_DIR/} (design: $DESIGN)"
echo "Scale:          $SCALE ($DOCS documents, $USERS users, $ORGS orgs, $TEAMS teams)"
echo "pgbench:        ${DURATION}s per workload, $CLIENTS clients"
echo "Postgres:       $("$PGBIN/psql" -X -tA -d "$DB" -c 'show server_version')"
echo

echo "Seeding RBAC..."
start=$(date +%s)
"$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 "${VARS[@]}" -d "$DB" -f "$HERE/seed_rbac.sql" >/dev/null
"$PGBIN/psql" -X -q -d "$DB" -c "vacuum analyze"
echo "  done in $(( $(date +%s) - start ))s"
sanity_check
explain_as_user "rbac_select_page (RBAC policy, user 1)"

for w in rbac_check rbac_select_page rbac_select_count rbac_update_one write_assign_role; do
    run_workload "$w"
done

echo
SHARE_WORKLOADS=(share_list_objects share_select_page write_share)
echo "Seeding sharing (design $DESIGN)..."
start=$(date +%s)
if [ ! -f "$DESIGN_DIR/seed_sharing.sql" ]; then
    echo "  skipped: no sharing benchmark for design $DESIGN (bench/designs/$DESIGN/)"
    for w in "${SHARE_WORKLOADS[@]}"; do
        RESULTS+=("| $w | skipped | | | | | |")
    done
elif seed_out=$("$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 "${VARS[@]}" -d "$DB" -f "$DESIGN_DIR/seed_sharing.sql" 2>&1 >/dev/null); then
    "$PGBIN/psql" -X -q -d "$DB" -c "vacuum analyze"
    echo "  done in $(( $(date +%s) - start ))s"
    sanity_check
    explain_as_user "share_select_page (two-branch policy, user 1)"
    for w in "${SHARE_WORKLOADS[@]}"; do
        run_workload "$w"
    done
else
    echo "  skipped: this implementation doesn't support the sharing API"
    printf '%s\n' "$seed_out" | grep ERROR | head -1 | sed 's/^/  /'
    for w in "${SHARE_WORKLOADS[@]}"; do
        RESULTS+=("| $w | skipped | | | | | |")
    done
fi

mkdir -p "$HERE/results"
report="$HERE/results/$(date +%Y%m%d-%H%M%S)-$IMPL_NAME-$SCALE.md"
{
    echo "# Benchmark: $IMPL_NAME (design $DESIGN), $SCALE scale"
    echo
    echo "- Date: $(date '+%Y-%m-%d %H:%M')"
    echo "- Postgres: $("$PGBIN/psql" -X -tA -d "$DB" -c 'show server_version')"
    echo "- Data: $DOCS documents, $USERS users, $ORGS orgs, $TEAMS teams"
    echo "- pgbench: ${DURATION}s per workload, $CLIENTS clients"
    [ "${EXTERNAL}" = 1 ] || echo "- Throwaway cluster with fsync off: write numbers are optimistic"
    echo
    echo "| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |"
    echo "| --- | --- | --- | --- | --- | --- | --- |"
    printf '%s\n' "${RESULTS[@]}"
    echo
    echo "## Query plans"
    printf '%s\n' "$EXPLAINS"
} > "$report"

echo
echo "Saved ${report#$EXT_DIR/}"

if [ $CHECK = 1 ] && printf '%s\n' "${RESULTS[@]}" | grep -q -E '\| (OVER|error) \|'; then
    echo "Some workloads are over budget or failed." >&2
    exit 1
fi
