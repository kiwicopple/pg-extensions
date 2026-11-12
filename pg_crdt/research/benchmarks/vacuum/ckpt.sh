#!/usr/bin/env bash
# How checkpoint frequency changes the full-page-image share of WAL: the same
# fixed-rate keystroke stream with checkpoint_timeout=30s and with the default
# 5min, decomposed with pg_waldump.
#
#   research/benchmarks/vacuum/ckpt.sh          # writes results/ckpt.md
#
# Per size, shape and setting: a fresh table of NDOCS documents, CHECKPOINT,
# then RATE keystrokes per second (default 100, 2 clients, random documents
# and positions) for DURATION seconds (default 90). With 30s, three timed
# checkpoints fall inside the run; with 5min, none does (the run starts right
# after a checkpoint, so its first touch of every page is still an FPI).
# fsync=on, autovacuum off, wal_keep_size=4GB so pg_waldump can read the whole
# run after the checkpoints recycle segments.
set -euo pipefail
. "$(dirname "$0")/common.sh"

if [ "$QUICK" = 1 ]; then DURATION=${DURATION:-35}; else DURATION=${DURATION:-90}; fi
RATE=${RATE:-100}
CK_SIZES=${CK_SIZES:-"5000 100000"}
SHAPES=${SHAPES:-"plain a b"}
SETTINGS=${SETTINGS:-"30s 5min"}
OUT=${OUT:-$RESULTS/ckpt.md}
WAL_RAW=${WAL_RAW:-$RESULTS/ckpt-raw.txt}
: > "$WAL_RAW"

# checkpoint_timeout is set with ALTER SYSTEM per run, so it must not be on
# the command line (command-line settings win over postgresql.auto.conf).
export PG_EXTRA_OPTS="${BASE_OPTS/-c checkpoint_timeout=30min/} -c fsync=on -c autovacuum=off -c wal_keep_size=4GB ${PG_EXTRA_OPTS:-}"
start_cluster
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pgcrdt-ck.XXXXXX")
trap 'rm -rf "$WORK"; stop_cluster' EXIT
SIZES=$CK_SIZES
make_template "$CK_SIZES"

shape_label() {
    case $1 in plain) echo "plain text (lz4)" ;; a) echo "yseq_ (lz4)" ;; b) echo "ydoc_" ;; esac
}

exec > >(tee "$OUT")
echo "# Checkpoint frequency and full-page images"
echo
header
echo "$NDOCS documents, $RATE keystrokes/s (2 clients, random document and position, 80% insert / 20% delete) for $DURATION s after a CHECKPOINT, with checkpoint_timeout as given (max_wal_size 8GB, so only timed checkpoints). Bytes per edit from pg_waldump --stats=record."
echo
hdr "size" "shape" "checkpoint_timeout" "checkpoints in run" "edits" "WAL per edit" "records" "FPI" "FPI share" "WAL MB/s"
for size in $CK_SIZES; do
    for shape in $SHAPES; do
        for setting in $SETTINGS; do
            db="vc_${shape}_${size}"
            progress "ckpt: $shape $size $setting"
            new_db "$db"
            qd "$db" -c "select bench.load('docs', '$shape', $size, $NDOCS)" >/dev/null
            qd "$db" -c "vacuum analyze" >/dev/null
            qd postgres -c "alter system set checkpoint_timeout = '$setting'" -c "select pg_reload_conf()" >/dev/null
            sleep 1
            [ "$(qd postgres -c 'show checkpoint_timeout')" = "$setting" ] || echo "WARNING: checkpoint_timeout is $(qd postgres -c 'show checkpoint_timeout'), not $setting" >&2
            qd "$db" -c checkpoint >/dev/null
            edit_script "$WORK/e.sql" "$shape" docs "$size" "random(1, $NDOCS)"
            c0=$(qd postgres -c "select checkpoints_timed + checkpoints_req from pg_stat_bgwriter")
            l0=$(lsn "$db")
            pgb "$db" "$WORK/e.sql" -c 2 -j 2 -T "$DURATION" -R "$RATE"
            l1=$(qd "$db" -c "select pg_current_wal_flush_lsn()")
            c1=$(qd postgres -c "select checkpoints_timed + checkpoints_req from pg_stat_bgwriter")
            WAL_LABEL="$(size_label $size) $shape checkpoint_timeout=$setting" waldump "$l0" "$l1"
            row "$(size_label $size)" "$(shape_label $shape)" "$setting" "$((c1 - c0))" "$P_OK" "$(div $W_TOT $P_OK)" "$(div $W_REC $P_OK)" "$(div $W_FPI $P_OK)" \
                "$(pct $W_FPI $W_TOT)" "$(awk -v w="$W_TOT" -v t="$DURATION" 'BEGIN { printf "%.2f", w / t / 1048576 }')"
            drop_db "$db"
        done
    done
done
qd postgres -c "alter system reset checkpoint_timeout" -c "select pg_reload_conf()" >/dev/null
echo
progress "ckpt: done, $OUT"
