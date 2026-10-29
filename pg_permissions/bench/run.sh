#!/usr/bin/env bash
# Benchmark a pg_permissions implementation with pgbench.
#
#   bench/run.sh --impl prototypes/a-tuple-core.sql              # small scale, 10s per workload
#   bench/run.sh --impl prototypes/a-tuple-core.sql --scale large
#   bench/run.sh --impl ... --shape wide --scale medium          # stress shape
#   bench/run.sh --impl ... --only parents,write_nest_team       # rerun some workloads
#   bench/run.sh --impl ... --check                              # exit 1 if any p95 is over budget
#
# Options:
#   --scale small|medium|large   10k/100k/1M documents (default small)
#   --shape default|deep|wide    team graph (default default):
#                                  deep: teams in chains 9 deep, users in the leaf teams
#                                  wide: 4x the teams, each user in 50, 50 documents per team
#   --duration SECONDS           per workload (default 10)
#   --clients N                  pgbench clients (default 4)
#   --only NAME[,NAME...]        run only workloads whose name contains one of these;
#                                phases after the last selected workload aren't seeded
#   --design a|b|c|d|none        default: the letter before the first dash of the
#                                --impl file name (a-tuple-core.sql -> a), else none
#   --external                   use the server from PGHOST/PGPORT/PGUSER
#   --tag NAME                   appended to the JSON run_id (e.g. smoke)
#   --check                      exit 1 if a p95 is over budget or a workload fails
#                                (workloads without a budget never fail; budgets.tsv
#                                keys stress shapes as e.g. medium-wide, none set yet)
#
# Phases, in order. Each seed is timed and followed by VACUUM FULL ANALYZE
# of the non-empty tables;
# the report records seed time, size and row count of every table in schema
# `permissions`, and a checksum of the documents that sample users see:
#   1. rbac     bench/seed_rbac.sql (preset API, any engine); rbac_* and write_assign_role
#   2. sharing  designs/<design>/seed_sharing.sql (native API); share_* and write_share
#   3. parents_proj  designs/<design>/seed_parents.sql (folders; documents linked
#               only by the app column documents.folder_id; two-arm policy
#               `id = any(shares) or folder_id = any(viewable folders)`);
#               parents_proj_select_page and parents_proj_select_count
#   4. parents  designs/<design>/seed_parent_docs.sql (a parent link per document;
#               single-branch policy, one engine call returns every visible id);
#               parents_select_page and parents_select_count
#   5. nesting  write_nest_team, then designs/<design>/seed_nest.sql, then nest_check
# Phases 2-5 are skipped if the design has no files for them. All designs read
# the same data from the shape tables (bench/seed_shape.sql). Checksums are
# saved to bench/results/equivalence-<scale>-<shape>-<design>.tsv (complete
# runs only, not --only) and compared with the other designs' latest files: identical data and correct engines
# give identical checksums. Results are printed as a markdown table and saved
# to bench/results/. Complete runs also write
# bench/baselines/data/pg<major>-<environment>-<design>-<scale>-<shape>[-<tag>].json
# with bench/report_to_json.sh ($BENCH_ENVIRONMENT, default local, and
# $BENCH_HOST set its environment and host fields).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(dirname "$HERE")
. "$EXT_DIR/test/lib/cluster.sh"

IMPL="pg_permissions--0.0.1.sql"
SCALE=small
SHAPE=default
DURATION=10
CLIENTS=4
ONLY=
CHECK=0
EXTERNAL=0
DESIGN=
TAG=
while [ $# -gt 0 ]; do
    case "$1" in
        --impl) IMPL=$2; shift 2 ;;
        --tag) TAG=$2; shift 2 ;;
        --scale) SCALE=$2; shift 2 ;;
        --shape) SHAPE=$2; shift 2 ;;
        --duration) DURATION=$2; shift 2 ;;
        --clients) CLIENTS=$2; shift 2 ;;
        --only) ONLY=$2; shift 2 ;;
        --design) DESIGN=$2; shift 2 ;;
        --design=*) DESIGN=${1#--design=}; shift ;;
        --check) CHECK=1; shift ;;
        --external) EXTERNAL=1; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$SCALE" in
    small)  DOCS=10000;   USERS=1000;  ORGS=20;  TEAMS=50 ;;
    medium) DOCS=100000;  USERS=5000;  ORGS=50;  TEAMS=200 ;;
    large)  DOCS=1000000; USERS=10000; ORGS=100; TEAMS=500 ;;
    *) echo "unknown scale: $SCALE" >&2; exit 2 ;;
esac

# MPU: teams per user, GPT: documents shared with each team, LEVELS: chain depth
case "$SHAPE" in
    default) MPU=1;  GPT=5;  NESTING=tree4; LEVELS=9 ;;
    deep)    MPU=1;  GPT=5;  NESTING=chain; LEVELS=9 ;;
    wide)    MPU=50; GPT=50; NESTING=tree4; LEVELS=9; TEAMS=$((TEAMS * 4)) ;;
    *) echo "unknown shape: $SHAPE (expected default, deep or wide)" >&2; exit 2 ;;
esac
case "$SHAPE" in
    deep) SHAPE_DESC="teams in chains $LEVELS deep, users in the leaf teams, $GPT documents per team" ;;
    *)    SHAPE_DESC="$MPU team(s) per user, $GPT documents per team, 4-ary team tree" ;;
esac

IMPL=$(resolve_impl "$IMPL")
[ -f "$IMPL" ] || { echo "error: implementation not found: $IMPL" >&2; exit 2; }
IMPL_NAME=$(basename "$IMPL" .sql)

if [ -z "$DESIGN" ]; then
    case "$IMPL_NAME" in
        [abcd]-*) DESIGN=${IMPL_NAME%%-*} ;;
        *) DESIGN=none ;;
    esac
fi
case "$DESIGN" in
    a|b|c|d|none) ;;
    *) echo "unknown design: $DESIGN (expected a, b, c, d or none)" >&2; exit 2 ;;
esac
DESIGN_DIR="$HERE/designs/$DESIGN"

PHASE1="rbac_check rbac_select_page rbac_select_count rbac_update_one write_assign_role"
PHASE2="share_list_objects share_select_page write_share"
PHASE3="parents_proj_select_page parents_proj_select_count"
PHASE4="parents_select_page parents_select_count"
PHASE5="write_nest_team nest_check"
# users whose visible documents are checksummed (every 5th user is a folder viewer)
SAMPLE_USERS="1 2 3 5 10 77 500 $USERS"

start_cluster
ensure_roles

DB=pgperm_bench
VARS=(-v docs=$DOCS -v users=$USERS -v orgs=$ORGS -v teams=$TEAMS
      -v mpu=$MPU -v gpt=$GPT -v nesting=$NESTING -v levels=$LEVELS)
PGB_VARS=(-D docs=$DOCS -D users=$USERS -D orgs=$ORGS -D teams=$TEAMS)

psql_admin -c "drop database if exists $DB" -c "create database $DB"
"$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$IMPL" >/dev/null

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pgperm-bench.XXXXXX")
cleanup_work() { case "$WORK" in */pgperm-bench.*) rm -rf "$WORK" ;; esac; stop_cluster; }
trap cleanup_work EXIT INT TERM

RESULTS=()
SEEDS=()
EXPLAINS=""
: > "$WORK/sizes.tsv"
: > "$WORK/equiv.tsv"

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }'; }
psql_db() { "$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 "${VARS[@]}" -d "$DB" "$@"; }

# Is NAME selected by --only? (each comma-separated item is a substring)
selected() {
    [ -z "$ONLY" ] && return 0
    local item
    local IFS=,
    for item in $ONLY; do
        case "$1" in *"$item"*) return 0 ;; esac
    done
    return 1
}

# Does phase N or any later phase have a selected workload? Seeds are cumulative,
# so phase N must be seeded if so.
phase_needed() {
    local p w list
    for p in 1 2 3 4 5; do
        [ "$p" -ge "$1" ] || continue
        eval "list=\$PHASE$p"
        for w in $list; do selected "$w" && return 0; done
    done
    return 1
}

skip_workloads() {
    local w
    for w in $1; do
        selected "$w" && RESULTS+=("| $w | skipped | | | | | |")
    done
    return 0
}

# Budgets are keyed by scale for the default shape and by scale-shape (e.g.
# medium-wide) for the stress shapes, which have none yet.
budget_for() {
    local key=$SCALE
    [ "$SHAPE" = default ] || key="$SCALE-$SHAPE"
    awk -v s="$key" -v w="$1" '$1 == s && $2 == w { print $3 }' "$HERE/budgets.tsv"
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

# Size and exact row count of every table in schema permissions, after a seed.
record_sizes() {
    psql_db -tA -F $'\t' >>"$WORK/sizes.tsv" <<SQL
select '$1', c.relname, pg_total_relation_size(c.oid),
       (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from permissions.%I', c.relname),
                                             false, true, '')))[1]::text::bigint
from pg_class c
where c.relnamespace = 'permissions'::regnamespace and c.relkind in ('r', 'p')
order by c.relname;
SQL
}

# VACUUM FULL ANALYZE every non-empty user table: sizes are live data and no
# phase inherits bloat from the previous one's workloads. Empty tables are
# left alone on purpose: analyzed-as-empty statistics make some engines'
# write triggers pick plans that go quadratic when the next seed loads tens of
# thousands of rows in one transaction (B's wide sharing seed: 225 s instead
# of 3 s at small scale). Never-analyzed tables keep the planner's defaults,
# which is also the state of a freshly installed extension. The plain VACUUM
# after VACUUM FULL sets the visibility map, which VACUUM FULL leaves empty:
# without it index-only scans fetch every heap page (rbac_select_count at
# large went from 1 ms to 6 ms).
vacuum_nonempty() {
    psql_db >/dev/null <<'SQL'
select format(v, n.nspname, c.relname)
from pg_class c join pg_namespace n on n.oid = c.relnamespace,
     (values (1, 'vacuum (full, analyze) %I.%I'), (2, 'vacuum %I.%I')) cmd(step, v)
where c.relkind = 'r' and n.nspname not in ('pg_catalog', 'information_schema')
  and n.nspname not like 'pg\_%'
  and (xpath('/row/e/text()', query_to_xml(format('select exists (select from %I.%I) as e', n.nspname, c.relname),
                                            false, true, '')))[1]::text = 'true'
order by n.nspname, c.relname, step
\gexec
SQL
}

# Load a seed file, timed, then vacuum_nonempty and record sizes. Returns 1,
# printing the first error, if the file fails.
seed() {
    local phase=$1 file=$2 start secs out
    echo "Seeding $phase..."
    start=$(now)
    if ! out=$(psql_db -f "$file" 2>&1 >/dev/null); then
        echo "  failed: $(printf '%s\n' "$out" | grep -m1 ERROR || printf '%s\n' "$out" | head -1)"
        SEEDS+=("| $phase | failed | | |")
        return 1
    fi
    secs=$(since "$start")
    vacuum_nonempty
    record_sizes "$phase"
    local bytes rows
    read -r bytes rows < <(awk -F'\t' -v p="$phase" '$1 == p { b += $3; r += $4 } END { printf "%d %d\n", b, r }' "$WORK/sizes.tsv")
    echo "  done in ${secs}s; permission tables: $(numfmt_mb "$bytes") MB, $rows rows"
    SEEDS+=("| $phase | $secs | $(numfmt_mb "$bytes") | $rows |")
}

numfmt_mb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'; }

# For each sample user: how many documents RLS lets them see, and an md5 of the
# sorted ids. Guards against fast-but-empty workloads and feeds the
# cross-engine equivalence check.
checksums() {
    local policy=$1 lines
    lines=$("$PGBIN/psql" -X -q -tA -F $'\t' -d "$DB" <<SQL 2>&1
create temp table visible (u int, n bigint, digest text);
grant all on visible to authenticated;
do \$\$
declare u int; n bigint; d text;
begin
    foreach u in array '{$(echo $SAMPLE_USERS | tr ' ' ',')}'::int[] loop
        perform set_config('permissions.subject_id', md5('user' || u)::uuid::text, true);
        set local role authenticated;
        select count(*), md5(coalesce(string_agg(id::text, ',' order by id), '')) into n, d from public.documents;
        reset role;
        insert into visible values (u, n, d);
    end loop;
end \$\$;
select '$policy', u, n, digest from visible order by u;
SQL
)
    if ! printf '%s\n' "$lines" | awk -F'\t' 'NF != 4 { exit 1 }'; then
        echo "  checksum failed: $(printf '%s\n' "$lines" | head -1)"
        return 0
    fi
    printf '%s\n' "$lines" >>"$WORK/equiv.tsv"
    echo "  visible documents: $(printf '%s\n' "$lines" | awk -F'\t' '{ printf "%suser %s: %s", (NR > 1 ? ", " : ""), $2, $3 }')"
    # over user, count and digest only, so equal visible sets give equal checksums across policies
    echo "  checksum ($policy): $(printf '%s\n' "$lines" | cut -f2- | { md5 -q 2>/dev/null || md5sum | cut -c1-32; })"
    case "$(printf '%s\n' "$lines" | awk -F'\t' '$3 == 0' | head -1)" in
        "") ;;
        *) echo "  warning: a sample user sees no documents; check the seed" >&2 ;;
    esac
}

run_workload() {
    local name=$1
    selected "$name" || return 0
    local wfile="$HERE/workloads/$name.sql"
    [ -f "$wfile" ] || wfile="$DESIGN_DIR/workloads/$name.sql"
    if [ ! -f "$wfile" ]; then
        printf '  %-22s skipped (no workload file for design %s)\n' "$name" "$DESIGN"
        RESULTS+=("| $name | skipped | | | | | |")
        return 0
    fi
    local dir="$WORK/$name"
    mkdir -p "$dir"
    printf '  %-22s ' "$name"
    local out
    if ! out=$(cd "$dir" && "$PGBIN/pgbench" -n -T "$DURATION" -c "$CLIENTS" -j "$CLIENTS" -l \
                 "${PGB_VARS[@]}" -f "$wfile" "$DB" 2>&1); then
        echo "ERROR"
        printf '%s\n' "$out" | grep -iE 'error|abort' | head -3 | sed 's/^/      /'
        RESULTS+=("| $name | error | | | | | |")
        return 0
    fi
    local tps avg p50 p95 budget status
    tps=$(printf '%s\n' "$out" | sed -n 's/^tps = \([0-9.]*\).*/\1/p' | head -1)
    avg=$(printf '%s\n' "$out" | sed -n 's/^latency average = \([0-9.]*\) ms/\1/p')
    read -r p50 p95 < <(cat "$dir"/pgbench_log.* | awk '{ print $3 / 1000 }' | sort -n |
        awk '{ a[NR] = $1 } END { if (NR == 0) { print "- -"; exit }
             printf "%.2f %.2f\n", a[(int(NR * 0.50) > 0) ? int(NR * 0.50) : 1], a[(int(NR * 0.95) > 0) ? int(NR * 0.95) : 1] }')
    budget=$(budget_for "$name")
    if [ -z "$budget" ]; then status="-"
    elif awk -v p="$p95" -v b="$budget" 'BEGIN { exit !(p <= b) }'; then status="ok"
    else status="OVER"; fi
    printf 'p50 %8s ms   p95 %8s ms   %8.0f tps   budget %s\n' "$p50" "$p95" "$tps" "${budget:+$budget ms ($status)}"
    RESULTS+=("| $name | $p50 | $p95 | $avg | ${tps%.*} | ${budget:--} | $status |")
}

PG_VERSION=$("$PGBIN/psql" -X -tA -d "$DB" -c 'show server_version')
RUN_DATE=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "Implementation: ${IMPL#$EXT_DIR/} (design: $DESIGN)"
echo "Scale:          $SCALE ($DOCS documents, $USERS users, $ORGS orgs, $TEAMS teams)"
echo "Shape:          $SHAPE ($SHAPE_DESC)"
echo "pgbench:        ${DURATION}s per workload, $CLIENTS clients${ONLY:+, only: $ONLY}"
echo "Postgres:       $PG_VERSION"
echo

psql_db -f "$HERE/seed_shape.sql" >/dev/null

# ---- 1. rbac
seed rbac "$HERE/seed_rbac.sql" || { echo "error: the RBAC seed must load" >&2; exit 1; }
checksums rbac
explain_as_user "rbac_select_page (RBAC policy, user 1)"
for w in $PHASE1; do run_workload "$w"; done

# ---- 2. sharing
SHARED=0
if phase_needed 2; then
    echo
    if [ ! -f "$DESIGN_DIR/seed_sharing.sql" ]; then
        echo "Sharing skipped: no sharing benchmark for design $DESIGN (bench/designs/$DESIGN/)"
        skip_workloads "$PHASE2 $PHASE3 $PHASE4 $PHASE5"
    elif seed sharing "$DESIGN_DIR/seed_sharing.sql"; then
        SHARED=1
        checksums sharing
        explain_as_user "share_select_page (two-branch policy, user 1)"
        for w in $PHASE2; do run_workload "$w"; done
    else
        echo "  skipped: this implementation doesn't support the sharing API"
        skip_workloads "$PHASE2 $PHASE3 $PHASE4 $PHASE5"
    fi
fi

# ---- 3. parents, two-arm projection (after the share workloads: it replaces
#      the select policy). Documents point at folders only through folder_id.
PARENTS=0
if [ $SHARED = 1 ] && phase_needed 3; then
    echo
    if [ ! -f "$DESIGN_DIR/seed_parents.sql" ]; then
        echo "Parents skipped: no parents benchmark for design $DESIGN"
        skip_workloads "$PHASE3 $PHASE4"
    elif seed parents_proj "$DESIGN_DIR/seed_parents.sql"; then
        PARENTS=1
        checksums parents_proj
        explain_as_user "parents_proj_select_page (two-arm projection policy, user 1)"
        for w in $PHASE3; do run_workload "$w"; done
    else
        skip_workloads "$PHASE3 $PHASE4"
    fi
fi

# ---- 4. parents, single branch: a parent link per document, one engine call
if [ $PARENTS = 1 ] && phase_needed 4; then
    echo
    if [ ! -f "$DESIGN_DIR/seed_parent_docs.sql" ]; then
        echo "Single-branch parents skipped: no seed_parent_docs.sql for design $DESIGN"
        skip_workloads "$PHASE4"
    elif seed parents "$DESIGN_DIR/seed_parent_docs.sql"; then
        checksums parents
        explain_as_user "parents_select_page (single-branch policy, user 1)"
        for w in $PHASE4; do run_workload "$w"; done
    else
        skip_workloads "$PHASE4"
    fi
fi

# ---- 5. nesting: the write, then one nest for good, then the read side
if [ $SHARED = 1 ] && phase_needed 5; then
    echo
    echo "Nesting (team md5('nest-src'), 1,000 members):"
    run_workload write_nest_team
    if [ ! -f "$DESIGN_DIR/seed_nest.sql" ]; then
        echo "  nest_check skipped: no seed_nest.sql for design $DESIGN"
        skip_workloads nest_check
    elif seed nesting "$DESIGN_DIR/seed_nest.sql"; then
        # engine-independent sanity check: a nested user sees the target team's documents
        seen=$("$PGBIN/psql" -X -q -tA -d "$DB" <<SQL 2>&1
\\o /dev/null
select set_config('permissions.subject_id', md5('nest-user' || 1)::uuid::text, false);
\\o
set role authenticated;
select count(*) from public.documents
where id in (select md5('doc' || ((($TEAMS::bigint * 9973 + j * 7919) % $DOCS) + 1))::uuid from generate_series(1, 5) j);
SQL
)
        echo "  nested user 1 sees $seen of the 5 documents shared with team $TEAMS"
        [ "$seen" = 5 ] || echo "  warning: nest_check would measure a failing check" >&2
        run_workload nest_check
    else
        skip_workloads nest_check
    fi
fi

# ---- equivalence across designs
mkdir -p "$HERE/results"
# only complete runs are saved for comparison; --only runs just compare
EQUIV_FILE="$HERE/results/equivalence-$SCALE-$SHAPE-$DESIGN.tsv"
[ -n "$ONLY" ] || cp "$WORK/equiv.tsv" "$EQUIV_FILE"
[ -z "$ONLY" ] || EQUIV_FILE="$WORK/equiv.tsv"
EQUIV_SUMMARY=""
for other in a b c d none; do
    [ "$other" = "$DESIGN" ] && continue
    f="$HERE/results/equivalence-$SCALE-$SHAPE-$other.tsv"
    [ -s "$f" ] || continue
    line=$(awk -F'\t' -v me="$EQUIV_FILE" '
        FILENAME == me { mine[$1 FS $2] = $3 FS $4; next }
        ($1 FS $2) in mine {
            pol[$1] = 1
            if (mine[$1 FS $2] != $3 FS $4) bad[$1] = bad[$1] (bad[$1] == "" ? "" : ",") $2
        }
        END {
            n = 0
            for (p in pol) { out = out (n++ ? "; " : "") p ": " (p in bad ? "MISMATCH (users " bad[p] ")" : "same") }
            print out
        }' "$EQUIV_FILE" "$f")
    [ -n "$line" ] || continue
    EQUIV_SUMMARY="$EQUIV_SUMMARY
- vs design $other ($(date -r "$f" '+%Y-%m-%d %H:%M')): $line"
done

echo
echo "Equivalence with other designs' latest runs ($SCALE, $SHAPE):${EQUIV_SUMMARY:- no other runs to compare with}"

suffix=$SCALE
[ "$SHAPE" = default ] || suffix="$SCALE-$SHAPE"
report="$HERE/results/$(date +%Y%m%d-%H%M%S)-$IMPL_NAME-$suffix.md"
{
    echo "# Benchmark: $IMPL_NAME (design $DESIGN), $SCALE scale, $SHAPE shape"
    echo
    echo "- Date: $(date '+%Y-%m-%d %H:%M')"
    echo "- Postgres: $PG_VERSION"
    echo "- Data: $DOCS documents, $USERS users, $ORGS orgs, $TEAMS teams"
    echo "- Shape: $SHAPE ($SHAPE_DESC)"
    echo "- pgbench: ${DURATION}s per workload, $CLIENTS clients${ONLY:+ (only: $ONLY)}"
    [ "${EXTERNAL}" = 1 ] || echo "- Throwaway cluster with fsync off: write numbers are optimistic"
    echo
    echo "| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |"
    echo "| --- | --- | --- | --- | --- | --- | --- |"
    [ ${#RESULTS[@]} -eq 0 ] || printf '%s\n' "${RESULTS[@]}"
    echo
    echo "## Seed time and storage"
    echo
    echo "Seed time is the native-API load only. Sizes are \`pg_total_relation_size\` (table, indexes, toast) of every table in schema \`permissions\` after the seed and \`VACUUM FULL\` (non-empty tables only, see \`vacuum_nonempty\` in run.sh), cumulative across phases."
    echo
    echo "| phase | seed s | permission tables MB | rows |"
    echo "| --- | --- | --- | --- |"
    [ ${#SEEDS[@]} -eq 0 ] || printf '%s\n' "${SEEDS[@]}"
    echo
    awk -F'\t' '
        !($1 in seen) { seen[$1] = 1; phases[++np] = $1 }
        !($2 in tseen) { tseen[$2] = 1; tables[++nt] = $2 }
        { v[$1 FS $2] = sprintf("%.2f MB, %d rows", $3 / 1048576, $4) }
        END {
            if (np == 0) exit
            printf "| table |"; for (i = 1; i <= np; i++) printf " after %s |", phases[i]; print ""
            printf "| --- |"; for (i = 1; i <= np; i++) printf " --- |"; print ""
            for (t = 1; t <= nt; t++) {
                printf "| %s |", tables[t]
                for (i = 1; i <= np; i++) printf " %s |", ((phases[i] FS tables[t]) in v ? v[phases[i] FS tables[t]] : "")
                print ""
            }
        }' "$WORK/sizes.tsv"
    echo
    echo "## Equivalence"
    echo
    echo "Documents each sample user sees through RLS after each seed, and the md5 of their sorted ids. Every 5th user is also a folder viewer, so for users not divisible by 5 parents_proj and parents must equal sharing, and parents_proj must always equal parents."
    echo
    echo "| policy | user | visible | md5 |"
    echo "| --- | --- | --- | --- |"
    awk -F'\t' '{ printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }' "$WORK/equiv.tsv"
    echo
    echo "Compared with other designs' latest runs at this scale and shape:${EQUIV_SUMMARY:- none yet.}"
    echo
    echo "## Query plans"
    printf '%s\n' "$EXPLAINS"
} > "$report"

echo
echo "Saved ${report#$EXT_DIR/}"
if [ -z "$ONLY" ]; then
    if json=$("$HERE/report_to_json.sh" --date "$RUN_DATE" ${TAG:+--tag "$TAG"} "$report"); then
        echo "Saved ${json#$EXT_DIR/}"
    else
        echo "warning: JSON export failed" >&2
    fi
fi

if [ $CHECK = 1 ] && [ ${#RESULTS[@]} -gt 0 ] && printf '%s\n' "${RESULTS[@]}" | grep -q -E '\| (OVER|error) \|'; then
    echo "Some workloads are over budget or failed." >&2
    exit 1
fi
