#!/usr/bin/env bash
# Steady state under autovacuum with its default settings: a fixed edit rate
# for DURATION seconds, sampling table + TOAST size and dead tuples every
# SAMPLE seconds.
#
#   research/benchmarks/vacuum/autovac.sh                    # results/autovac.md
#   SHAPES=a OUT=results/autovac-a.md research/benchmarks/vacuum/autovac.sh
#
# Scenarios (each on a fresh table of NDOCS documents):
#   spread  SPREAD_RATE keystrokes per second in total (default 200), 4
#           clients, at random documents and positions
#   hot     HOT_RATE keystrokes per second (default 50), 2 clients, all on
#           document 1 (one row updated constantly)
#   spread-append, hot-append   the same, typing at the end of the document
#           instead of at random positions (SCENARIOS="spread-append hot-append")
# The cluster runs with fsync=on and autovacuum at its defaults
# (autovacuum_naptime 1min, scale factor 0.2, threshold 50, cost delay 2ms,
# cost limit 200); max_wal_size=2GB to bound disk use.
set -euo pipefail
. "$(dirname "$0")/common.sh"

if [ "$QUICK" = 1 ]; then DURATION=${DURATION:-40}; else DURATION=${DURATION:-180}; fi
SAMPLE=${SAMPLE:-5}
SPREAD_RATE=${SPREAD_RATE:-200}
HOT_RATE=${HOT_RATE:-50}
SHAPES=${SHAPES:-"plain a b"}
SCENARIOS=${SCENARIOS:-"spread hot"}
OUT=${OUT:-$RESULTS/autovac.md}

export PG_EXTRA_OPTS="$BASE_OPTS -c fsync=on -c max_wal_size=2GB ${PG_EXTRA_OPTS:-}"
start_cluster
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pgcrdt-av.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORK"; stop_cluster' EXIT
make_template

shape_label() {
    case $1 in plain) echo "plain text (lz4)" ;; a) echo "yseq_ (lz4)" ;; b) echo "ydoc_" ;; pn*) echo "pn_ state column" ;; esac
}

exec > >(tee "$OUT")
echo "# Steady state with autovacuum on (default settings)"
echo
header
echo "$NDOCS documents per run. 'spread': $SPREAD_RATE keystrokes/s in total over all documents (4 clients). 'hot': $HOT_RATE keystrokes/s on one document (2 clients). Random positions in the first half of the document, except '-append': typing at the end. $DURATION s per run, sampled every $SAMPLE s. Sizes in MB: table + TOAST + indexes (for ydoc_ every crdt.ydoc_* table). 'live' is pgstattuple tuple_len (heap + TOAST) at the end. 'peak dead' is the largest n_dead_tup seen in a sample (heap / TOAST). 'autovacuums' counts autovacuum runs on the tables / their TOAST relations during the run."
echo

TIMELINE="$WORK/timeline.md"
: > "$TIMELINE"
echo "## Summary"
echo
hdr "size" "shape" "scenario" "edits/s achieved" "loaded" "at 60 s" "at 120 s" "end" "peak" "live at end" "end / live" "peak dead heap / TOAST" "autovacuums heap / TOAST" "WAL MB/s"
for scenario in $SCENARIOS; do
    for size in $SIZES; do
        for shape in $SHAPES; do
            db="va_${shape}_${size}_$(echo $scenario | tr - _)"
            progress "autovac: $scenario $shape $size"
            new_db "$db"
            qd "$db" -c "select bench.load('docs', '$shape', $size, $NDOCS)" >/dev/null
            qd "$db" -c "vacuum analyze" -c checkpoint >/dev/null
            rels="bench.rels('docs', '$shape')"
            snap M0 "$db" "$rels"
            case $scenario in
                spread)        edit_script "$WORK/e.sql" "$shape" docs "$size" "random(1, $NDOCS)"; clients=4; rate=$SPREAD_RATE ;;
                hot)           edit_script "$WORK/e.sql" "$shape" docs "$size" "1"; clients=2; rate=$HOT_RATE ;;
                spread-append) edit_script "$WORK/e.sql" "$shape" docs "$size" "random(1, $NDOCS)" append; clients=4; rate=$SPREAD_RATE ;;
                hot-append)    edit_script "$WORK/e.sql" "$shape" docs "$size" "1" append; clients=2; rate=$HOT_RATE ;;
            esac
            samples="$WORK/samples"
            : > "$samples"
            l0=$(lsn "$db")
            t0=$(date +%s)
            (
                while :; do
                    qd "$db" -F' ' -c "select $(date +%s) - $t0, total, n_dead, toast_n_dead, av_heap, av_toast from bench.measure($rels, false)" >> "$samples" 2>/dev/null || true
                    sleep "$SAMPLE"
                done
            ) &
            sampler=$!
            pgb "$db" "$WORK/e.sql" -c $clients -j $clients -T "$DURATION" -R "$rate"
            kill $sampler 2>/dev/null; wait $sampler 2>/dev/null || true
            l1=$(lsn "$db")
            elapsed=$(( $(date +%s) - t0 ))
            sleep 1
            snap M1 "$db" "$rels"
            at() { awk -v t="$1" '$1 <= t { v = $2 } END { print v + 0 }' "$samples"; }
            peak=$(awk -v e="$M1_total" '{ if ($2 > m) m = $2 } END { print (e > m ? e : m) + 0 }' "$samples")
            pdh=$(awk '{ if ($3 > m) m = $3 } END { print m + 0 }' "$samples")
            pdt=$(awk '{ if ($4 > m) m = $4 } END { print m + 0 }' "$samples")
            live=$((M1_heap_live + M1_toast_live))
            row "$(size_label $size)" "$(shape_label $shape)" "$scenario" "$P_TPS" "$(mb $M0_total)" "$(mb $(at 60))" "$(mb $(at 120))" "$(mb $M1_total)" "$(mb $peak)" \
                "$(mb $live)" "$(ratio $M1_total $live)" "$pdh / $pdt" "$((M1_av_heap - M0_av_heap)) / $((M1_av_toast - M0_av_toast))" \
                "$(awk -v w="$(lsn_diff $l0 $l1)" -v t="$elapsed" 'BEGIN { printf "%.2f", w / t / 1048576 }')"
            {
                echo "### $(size_label $size), $(shape_label $shape), $scenario"
                echo
                echo "| s | total MB | dead heap | dead TOAST | autovacuums heap / TOAST |"
                echo "| ---: | ---: | ---: | ---: | --- |"
                awk -v step=30 -v ah="$M0_av_heap" -v at="$M0_av_toast" '
                    $1 >= next_t { printf "| %d | %.1f | %d | %d | %d / %d |\n", $1, $2 / 1048576, $3, $4, $5 - ah, $6 - at; next_t = $1 + step }' "$samples"
                echo
            } >> "$TIMELINE"
            drop_db "$db"
        done
    done
done
echo
echo "## Timelines (every 30 s)"
echo
cat "$TIMELINE"
progress "autovac: done, $OUT"
