# Helpers for the vacuum and WAL benchmarks. Source, don't execute.
#
# Each script starts its own throwaway cluster through test/lib/cluster.sh
# (Unix socket only, deleted on exit), with the settings of
# research/benchmarks/text.md plus whatever the script adds in PG_EXTRA_OPTS,
# and builds a template database with the extension (yseq_, ydoc_, pn_),
# pgstattuple, pg_freespacemap and setup.sql. Every measured run uses a fresh
# database cloned from that template, so the crdt.ydoc_* tables hold only the
# run's documents.

VAC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXT_DIR=$(cd "$VAC_DIR/../../.." && pwd)
IMPL="$EXT_DIR/pg_crdt--0.0.1.sql"
RESULTS="$VAC_DIR/results"
mkdir -p "$RESULTS"
. "$EXT_DIR/test/lib/cluster.sh"
export PGCLIENTENCODING=UTF8

QUICK=${QUICK:-0}
if [ "$QUICK" = 1 ]; then
    NDOCS=${NDOCS:-10}
else
    NDOCS=${NDOCS:-100}
fi
SIZES=${SIZES:-"1000 5000 20000 100000"}
PLAN_EDITS=40                 # history of each document before the workload

# The settings of research/benchmarks/text.md.
BASE_OPTS="-c shared_buffers=512MB -c full_page_writes=on -c checkpoint_timeout=30min -c max_wal_size=8GB -c wal_compression=off"

progress() { echo "[$(date +%H:%M:%S)] $*" >&2; }
row() { local o="|" a; for a in "$@"; do o+=" $a |"; done; echo "$o"; }
hdr() { row "$@"; local o="|" a; for a in "$@"; do o+=" --- |"; done; echo "$o"; }
mb() { awk -v x="$1" 'BEGIN { x = x / 1048576; if (x >= 100) printf "%.0f", x; else if (x >= 10) printf "%.1f", x; else printf "%.2f", x }'; }
kb() { awk -v x="$1" 'BEGIN { x = x / 1024; if (x >= 100) printf "%.0f", x; else if (x >= 10) printf "%.1f", x; else printf "%.2f", x }'; }
i0() { awk -v x="$1" 'BEGIN { printf "%.0f", x }'; }
pct() { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%.0f%%", 100 * a / b; else printf "-" }'; }
ratio() { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) { r = a / b; if (r >= 10) printf "%.0f", r; else printf "%.1f", r } else printf "-" }'; }
div() { awk -v a="$1" -v b="$2" 'BEGIN { if (b > 0) printf "%.0f", a / b; else printf "0" }'; }
size_label() { awk -v s="$1" 'BEGIN { printf "%d kB", s / 1000 }'; }

# qd DB args...: psql on database DB, tuples only, unaligned.
qd() { local db=$1; shift; "$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -tA -d "$db" "$@"; }

machine() {
    if [ "$(uname -s)" = Darwin ]; then
        echo "$(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) CPU, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(sw_vers -productVersion)"
    else
        echo "$(uname -m), $(nproc) CPU"
    fi
}

header() {  # print the setup lines of a results file
    echo "Postgres: $(qd postgres -c 'show server_version')"
    echo "Machine:  $(machine)"
    echo "Date:     $(date '+%Y-%m-%d %H:%M %Z')"
    echo "Settings: $(qd postgres -c "select string_agg(name || '=' || current_setting(name), ', ' order by name) from pg_settings where name in ('shared_buffers','fsync','full_page_writes','synchronous_commit','wal_compression','max_wal_size','checkpoint_timeout','default_toast_compression','autovacuum','autovacuum_naptime','autovacuum_vacuum_scale_factor','autovacuum_vacuum_threshold','autovacuum_vacuum_cost_limit','autovacuum_vacuum_cost_delay','wal_level')")"
    echo "Code:     git $(git -C "$EXT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)$(git -C "$EXT_DIR" diff --quiet -- experiments pg_crdt--0.0.1.sql 2>/dev/null || echo ' + uncommitted changes'); NDOCS=$NDOCS; QUICK=$QUICK"
    echo
}

# make_template [sizes]: the template database vac_tmpl, with edit plans for
# NDOCS documents of each size.
make_template() {
    local sizes=${1-$SIZES} arr
    arr=$(echo "$sizes" | tr ' ' ',')
    psql_admin -c "drop database if exists vac_tmpl" -c "create database vac_tmpl encoding 'UTF8' template template0"
    "$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d vac_tmpl -f "$IMPL" -f "$VAC_DIR/setup.sql" >/dev/null
    if [ -n "$arr" ]; then
        progress "generating edit plans: $NDOCS documents of each size ($sizes)"
        qd vac_tmpl -c "select bench.make_plans(array[$arr], $NDOCS, $PLAN_EDITS)" >/dev/null
    fi
    qd vac_tmpl -c "vacuum analyze" >/dev/null
}

new_db() { psql_admin -c "drop database if exists $1 with (force)" -c "create database $1 template vac_tmpl"; }
drop_db() { psql_admin -c "drop database if exists $1 with (force)"; }

lsn() { qd "$1" -c "select pg_current_wal_insert_lsn()"; }
lsn_diff() { qd postgres -c "select pg_wal_lsn_diff('$2', '$1')::bigint"; }

# snap PREFIX DB RELS_SQL [deep]: bench.measure into variables PREFIX_heap ...
SNAP_COLS="heap toast idx total heap_live heap_dead heap_free toast_live toast_dead toast_free fsm n_live n_dead toast_n_dead n_upd n_hot n_ins toast_n_ins av_heap av_toast"
snap() {
    local p=$1 db=$2 rels=$3 deep=${4:-true} line n i=1 v
    line=$(qd "$db" -F' ' -c "select * from bench.measure($rels, $deep)")
    for n in $SNAP_COLS; do
        v=$(echo "$line" | awk -v i=$i '{ print $i }')
        eval "${p}_$n=\${v:-0}"
        i=$((i + 1))
    done
}
sv() { eval "echo \${$1_$2}"; }   # sv PREFIX col

# edit_script FILE SHAPE TBL SIZE IDS [variant]: one keystroke per
# transaction, 80% insert of one character and 20% delete of one character, at
# a random position in the first half of the document. IDS is a pgbench
# expression for the document id (random(1, 100), or 1 for a hot row).
# variant upd: the statement also sets updated_at = now() (plain and yseq_).
# variant append: typing at the end of the document instead of at random
# positions (insert after the last character, delete is a backspace of the last
# character), so yseq_ extends its last run instead of splitting runs.
edit_script() {
    local f=$1 shape=$2 tbl=$3 size=$4 ids=$5 variant=${6:-} half set_upd=""
    half=$((size / 2))
    [ "$variant" = upd ] && set_upd=", updated_at = now()"
    if [ "$variant" = append ]; then
        {
            echo "\\set id $ids"
            echo "\\set r random(1, 10)"
            echo "\\if :r <= 8"
            case $shape in
                plain*) echo "update $tbl set body = body || 'x' where id = :id;" ;;
                a*)     echo "update $tbl set body = crdt.yseq_insert(body, crdt.yseq_length(body), 'x', 'bench') where id = :id;" ;;
                b*)     echo "select crdt.ydoc_insert(d, crdt.ydoc_length(d), 'x', 'bench') from (select body_doc as d from $tbl where id = :id) s;" ;;
            esac
            echo "\\else"
            case $shape in
                plain*) echo "update $tbl set body = left(body, -1) where id = :id;" ;;
                a*)     echo "update $tbl set body = crdt.yseq_delete(body, crdt.yseq_length(body) - 1, 1, 'bench') where id = :id;" ;;
                b*)     echo "select crdt.ydoc_delete(d, crdt.ydoc_length(d) - 1, 1, 'bench') from (select body_doc as d from $tbl where id = :id) s;" ;;
            esac
            echo "\\endif"
        } > "$f"
        return
    fi
    {
        echo "\\set id $ids"
        echo "\\set pos random(0, $half)"
        echo "\\set r random(1, 10)"
        echo "\\if :r <= 8"
        case $shape in
            plain*) echo "update $tbl set body = overlay(body placing 'x' from :pos + 1 for 0)$set_upd where id = :id;" ;;
            a*)     echo "update $tbl set body = crdt.yseq_insert(body, :pos, 'x', 'bench')$set_upd where id = :id;" ;;
            b*)     echo "select crdt.ydoc_insert((select body_doc from $tbl where id = :id), :pos, 'x', 'bench');" ;;
        esac
        echo "\\else"
        case $shape in
            plain*) echo "update $tbl set body = overlay(body placing '' from :pos + 1 for 1)$set_upd where id = :id;" ;;
            a*)     echo "update $tbl set body = crdt.yseq_delete(body, :pos, 1, 'bench')$set_upd where id = :id;" ;;
            b*)     echo "select crdt.ydoc_delete((select body_doc from $tbl where id = :id), :pos, 1, 'bench');" ;;
        esac
        echo "\\endif"
    } > "$f"
}

# pgb DB SCRIPT args...: run pgbench; sets P_OK (transactions) and P_TPS.
pgb() {
    local db=$1 script=$2 out
    shift 2
    out=$("$PGBIN/pgbench" -n -f "$script" "$@" "$db" 2>&1) || { echo "$out" | tail -5 >&2; }
    P_OK=$(sed -n 's/^number of transactions actually processed: \([0-9]*\).*/\1/p' <<<"$out")
    P_TPS=$(sed -n 's/^tps = \([0-9.]*\) .*/\1/p' <<<"$out")
    P_OK=${P_OK:-0}; P_TPS=${P_TPS:-0}
    if grep -qi 'error\|abort' <<<"$out"; then
        echo "WARNING: pgbench: $(grep -i -m1 'error\|abort' <<<"$out" | cut -c1-200)" >&2
    fi
}

# waldump L0 L1: pg_waldump --stats=record over [L0, L1); sets W_N (records),
# W_REC (record bytes, FPIs excluded), W_FPI (full-page image bytes, after
# wal_compression), W_TOT, and W_HEAP / W_BTREE / W_OTHER (combined bytes by
# resource manager: Heap+Heap2, Btree, everything else). Appends the raw
# output to $WAL_RAW when set.
waldump() {
    local out
    out=$("$PGBIN/pg_waldump" -p "$PGCRDT_TMP/data/pg_wal" -s "$1" -e "$2" --stats=record 2>&1) || true
    if [ -n "${WAL_RAW:-}" ]; then { echo "== ${WAL_LABEL:-} $1 .. $2"; echo "$out"; echo; } >> "$WAL_RAW"; fi
    W_N=$(awk '$1 == "Total" { print $2 }' <<<"$out")
    W_REC=$(awk '$1 == "Total" { print $3 }' <<<"$out")
    W_FPI=$(awk '$1 == "Total" { print $5 }' <<<"$out")
    W_TOT=$(awk '$1 == "Total" { print $7 }' <<<"$out")
    # per-record lines: Type N (pct) Record (pct) FPI (pct) Combined (pct)
    W_HEAP=$(awk '$1 ~ /^Heap2?\// { gsub(/[()]/, ""); s += $(NF-1) } END { print s + 0 }' <<<"$out")
    W_BTREE=$(awk '$1 ~ /^Btree\// { gsub(/[()]/, ""); s += $(NF-1) } END { print s + 0 }' <<<"$out")
    W_N=${W_N:-0}; W_REC=${W_REC:-0}; W_FPI=${W_FPI:-0}; W_TOT=${W_TOT:-0}
    W_OTHER=$((W_TOT - W_HEAP - W_BTREE))
    if [ "$W_TOT" = 0 ]; then echo "WARNING: pg_waldump returned nothing for $1 .. $2: $(echo "$out" | head -3)" >&2; fi
}
