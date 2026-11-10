#!/usr/bin/env bash
# WAL per keystroke, decomposed with pg_waldump --stats=record into record
# payload and full-page images (FPI), for plain text (lz4 and pglz), yseq_
# (lz4 and pglz) and ydoc_, at each size, with wal_compression off, pglz and
# lz4.
#
#   research/benchmarks/vacuum/wal.sh           # writes results/wal.md
#   QUICK=1 research/benchmarks/vacuum/wal.sh
#
# Per size, one database holds NDOCS documents of every shape. Per shape, runs
# of EDITS keystrokes (default 2,000, one pgbench client, random document and
# position, 80% insert / 20% delete), in this order:
#   cold        CHECKPOINT, then the edits: every page's first change after the
#               checkpoint carries an FPI (the worst case: checkpoints often)
#   warm        straight after cold, no checkpoint: pages already logged since
#               the checkpoint take no FPI (the best case: checkpoints rare)
#   cold pglz, cold lz4         as cold, with wal_compression set
#   reuse (off, lz4, pglz)      VACUUM, CHECKPOINT, edits: new TOAST chunks go
#               into space VACUUM freed in existing pages instead of new pages
#               at the end of the file, so they are first changes too
# autovacuum is off so nothing else writes WAL.
set -euo pipefail
. "$(dirname "$0")/common.sh"

if [ "$QUICK" = 1 ]; then EDITS=${EDITS:-300}; else EDITS=${EDITS:-2000}; fi
SHAPES=${SHAPES:-"plain plain_pglz a a_pglz b"}
OUT=${OUT:-$RESULTS/wal.md}
WAL_RAW=${WAL_RAW:-$RESULTS/wal-raw.txt}
: > "$WAL_RAW"

export PG_EXTRA_OPTS="$BASE_OPTS -c autovacuum=off ${PG_EXTRA_OPTS:-}"
start_cluster
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pgcrdt-wal.XXXXXX")
trap 'rm -rf "$WORK"; stop_cluster' EXIT
make_template

shape_label() {
    case $1 in plain) echo "plain text (lz4)" ;; plain_pglz) echo "plain text (pglz)" ;; a) echo "yseq_ (lz4)" ;; a_pglz) echo "yseq_ (pglz)" ;; b) echo "ydoc_" ;; esac
}

exec > >(tee "$OUT")
echo "# WAL per keystroke, decomposed"
echo
header
echo "$NDOCS documents per shape, $EDITS keystrokes per run (one pgbench client, random document and position, 80% insert / 20% delete of one character). Bytes per edit. 'LSN' is pg_wal_lsn_diff over the run (what research/benchmarks/text.md reports); 'records' and 'FPI' are pg_waldump --stats=record totals (FPI after wal_compression), 'heap' / 'btree' / 'other' split the waldump total by resource manager (Heap+Heap2, Btree, the rest: commits, XLOG, sequences)."
echo

# one run: label compression -> prints a row
wal_run() {
    local db=$1 shape=$2 size=$3 phase=$4 comp=$5 l0 l1
    l0=$(lsn "$db")
    WAL_LABEL="$(size_label $size) $shape $phase $comp" PGOPTIONS="$PGOPTIONS -c wal_compression=$comp" \
        pgb "$db" "$WORK/e_$shape.sql" -c 1 -j 1 -t "$EDITS"
    l1=$(qd "$db" -c "select pg_current_wal_flush_lsn()")
    WAL_LABEL="$(size_label $size) $shape $phase $comp" waldump "$l0" "$l1"
    local n=$P_OK
    row "$(size_label $size)" "$(shape_label $shape)" "$phase" "$comp" "$(div $(lsn_diff $l0 $l1) $n)" "$(div $W_REC $n)" "$(div $W_FPI $n)" \
        "$(pct $W_FPI $W_TOT)" "$(div $W_HEAP $n)" "$(div $W_BTREE $n)" "$(div $W_OTHER $n)"
}
vacuum_shape() {  # db shape
    local t
    for t in $(qd "$1" -c "select unnest(bench.rels('docs_$2', '$2'))::text"); do qd "$1" -c "vacuum $t" >/dev/null; done
}

echo "## Bytes per edit"
echo
hdr "size" "shape" "phase" "wal_compression" "LSN" "records" "FPI" "FPI share" "heap" "btree" "other"
for size in $SIZES; do
    db="vw_$size"
    progress "wal: loading $size"
    new_db "$db"
    for shape in $SHAPES; do
        qd "$db" -c "select bench.load('docs_$shape', '$shape', $size, $NDOCS)" >/dev/null
        edit_script "$WORK/e_$shape.sql" "$shape" "docs_$shape" "$size" "random(1, $NDOCS)"
    done
    qd "$db" -c "vacuum analyze" >/dev/null
    for shape in $SHAPES; do
        progress "wal: $shape $size"
        qd "$db" -c checkpoint >/dev/null
        wal_run "$db" "$shape" "$size" cold off
        wal_run "$db" "$shape" "$size" warm off
        for comp in pglz lz4; do
            qd "$db" -c checkpoint >/dev/null
            wal_run "$db" "$shape" "$size" cold "$comp"
        done
        for comp in off lz4 pglz; do
            vacuum_shape "$db" "$shape"
            qd "$db" -c checkpoint >/dev/null
            wal_run "$db" "$shape" "$size" reuse "$comp"
        done
    done
    drop_db "$db"
done
echo
progress "wal: done, $OUT"
