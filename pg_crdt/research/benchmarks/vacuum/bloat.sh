#!/usr/bin/env bash
# Bloat under sustained keystroke edits with autovacuum OFF, then a plain
# VACUUM, then VACUUM FULL; and the HOT-update ratio with an index on another
# column. Text shapes: plain text (lz4), yseq_ (lz4), ydoc_.
#
#   research/benchmarks/vacuum/bloat.sh            # writes results/bloat.md
#   QUICK=1 research/benchmarks/vacuum/bloat.sh    # 10 documents, 2,000 edits
#
# Per shape and size: NDOCS documents (default 100) with a 40-edit history,
# then EDITS keystrokes (default 20,000: 200 per document) from 4 pgbench
# clients at random documents and positions, 80% insert / 20% delete of one
# character, one per transaction.
set -euo pipefail
. "$(dirname "$0")/common.sh"

if [ "$QUICK" = 1 ]; then EDITS=${EDITS:-2000}; HOT_EDITS=${HOT_EDITS:-1000}; else EDITS=${EDITS:-20000}; HOT_EDITS=${HOT_EDITS:-10000}; fi
CLIENTS=4
SHAPES=${SHAPES:-"plain a b"}
HOT_SIZES=${HOT_SIZES:-"1000 20000"}
OUT=${OUT:-$RESULTS/bloat.md}

export PG_EXTRA_OPTS="$BASE_OPTS -c autovacuum=off -c max_wal_size=2GB ${PG_EXTRA_OPTS:-}"
start_cluster
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pgcrdt-vac.XXXXXX")
trap 'rm -rf "$WORK"; stop_cluster' EXIT
make_template

# tables DB: one line per ydoc_ relation: name ins upd hot dead total_bytes
tables() {
    qd "$1" -F' ' -c "select relid::regclass, n_tup_ins, n_tup_upd, n_tup_hot_upd, n_dead_tup, pg_total_relation_size(relid)
                      from pg_stat_all_tables where relid = any (bench.rels('docs', 'b')) order by 1"
}
join_tables() {  # t0 t1 t2 t3 -> markdown rows for tables written during the edits
    awk -v f0="$1" -v f1="$2" -v f2="$3" -v f3="$4" '
        function m(x) { x = x / 1048576; return x >= 10 ? sprintf("%.1f", x) : sprintf("%.2f", x) }
        BEGIN {
            while ((getline < f0) > 0) { i0[$1] = $2; u0[$1] = $3; h0[$1] = $4; s0[$1] = $6 }
            while ((getline < f2) > 0) s2[$1] = $6
            while ((getline < f3) > 0) s3[$1] = $6
            while ((getline < f1) > 0) {
                ins = $2 - i0[$1]; upd = $3 - u0[$1]; hot = $4 - h0[$1]
                if (ins == 0 && upd == 0 && $5 == 0) continue
                printf "| %s | %d | %d | %s | %d | %s | %s | %s | %s |\n", $1, ins, upd, (upd > 0 ? sprintf("%.0f%%", 100 * hot / upd) : "-"), $5, m(s0[$1]), m($6), m(s2[$1]), m(s3[$1])
            }
        }'
}
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

shape_label() {
    case $1 in plain) echo "plain text (lz4)" ;; plain_pglz) echo "plain text (pglz)" ;; a) echo "yseq_ (lz4)" ;; a_pglz) echo "yseq_ (pglz)" ;; b) echo "ydoc_" ;; esac
}

exec > >(tee "$OUT")
echo "# Bloat with autovacuum off"
echo
header
echo "$NDOCS documents per run, $PLAN_EDITS-edit history each, then $EDITS keystrokes ($CLIENTS pgbench clients, random document and position, 80% insert / 20% delete of one character, one per transaction). Sizes in MB. 'live' is pgstattuple's tuple_len (heap + TOAST) after the run; 'dead TOAST' is dead_tuple_len of the TOAST relations; 'reusable' is pgstattuple free_space after VACUUM. For ydoc_ every crdt.ydoc_* table is included."
echo

DETAIL="$WORK/detail.md"
: > "$DETAIL"

echo "## Sizes"
echo
hdr "size" "shape" "loaded total" "after edits: total" "heap" "TOAST" "indexes" "dead heap tuples" "dead TOAST tuples" "dead TOAST MB" "live MB" "after VACUUM: total" "reusable" "returned to OS" "VACUUM s" "after VACUUM FULL" "total / live (before VACUUM)" "HOT %" "WAL MB" "WAL kB per edit"
for size in $SIZES; do
    for shape in $SHAPES; do
        db="vb_${shape}_${size}"
        progress "bloat: $shape $size"
        new_db "$db"
        qd "$db" -c "select bench.load('docs', '$shape', $size, $NDOCS)" >/dev/null
        qd "$db" -c "vacuum analyze" -c checkpoint >/dev/null
        rels="bench.rels('docs', '$shape')"
        snap M0 "$db" "$rels"
        [ "$shape" = b ] && tables "$db" > "$WORK/t0"
        edit_script "$WORK/e.sql" "$shape" docs "$size" "random(1, $NDOCS)"
        l0=$(lsn "$db")
        pgb "$db" "$WORK/e.sql" -c $CLIENTS -j $CLIENTS -t $((EDITS / CLIENTS))
        l1=$(lsn "$db")
        wal=$(lsn_diff "$l0" "$l1")
        sleep 1
        snap M1 "$db" "$rels"
        [ "$shape" = b ] && tables "$db" > "$WORK/t1"
        t0=$(now)
        qd "$db" -c "vacuum" >/dev/null
        t1=$(now)
        snap M2 "$db" "$rels"
        [ "$shape" = b ] && tables "$db" > "$WORK/t2"
        qd "$db" -c "vacuum full" >/dev/null
        snap M3 "$db" "$rels"
        [ "$shape" = b ] && tables "$db" > "$WORK/t3"
        upd=$((M1_n_upd - M0_n_upd)); hot=$((M1_n_hot - M0_n_hot))
        live=$((M1_heap_live + M1_toast_live))
        row "$(size_label $size)" "$(shape_label $shape)" "$(mb $M0_total)" "$(mb $M1_total)" "$(mb $M1_heap)" "$(mb $M1_toast)" "$(mb $M1_idx)" \
            "$M1_n_dead" "$M1_toast_n_dead" "$(mb $M1_toast_dead)" "$(mb $live)" "$(mb $M2_total)" "$(mb $((M2_heap_free + M2_toast_free)))" \
            "$(mb $((M1_total - M2_total)))" "$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')" "$(mb $M3_total)" \
            "$(ratio $M1_total $live)" "$(pct $hot $upd)" "$(mb $wal)" "$(kb $(div $wal $P_OK))"
        if [ "$shape" = b ]; then
            {
                echo "### ydoc_ tables, $(size_label $size)"
                echo
                echo "Counters during the edits; sizes in MB."
                echo
                hdr "table" "rows inserted" "updates" "HOT %" "dead tuples after edits" "loaded" "after edits" "after VACUUM" "after VACUUM FULL"
                join_tables "$WORK/t0" "$WORK/t1" "$WORK/t2" "$WORK/t3"
                echo
            } >> "$DETAIL"
        fi
        drop_db "$db"
    done
done
echo
echo "'returned to OS' is the file size VACUUM gave back (it truncates only empty pages at the end of a file). HOT % is n_tup_hot_upd / n_tup_upd during the edits, over all the shape's tables (for ydoc_ the internal tables; the documents table is not updated)."
echo
cat "$DETAIL"

# ------------------------------------------------------------- HOT variants
echo "## HOT updates with an index on another column"
echo
echo "$HOT_EDITS keystrokes per run, as above. 'none': primary key only. 'title index': a btree on title, which the edits do not change. 'updated_at index': a btree on updated_at, and every edit also sets updated_at = now() (a common app pattern). Index sizes in MB, before and after the edits."
echo
hdr "size" "shape" "index" "HOT %" "indexes before" "indexes after" "total after (MB)" "WAL kB per edit"
for size in $HOT_SIZES; do
    for shape in plain a; do
        for variant in none title upd; do
            db="vh_${shape}_${size}_$variant"
            progress "hot: $shape $size $variant"
            new_db "$db"
            qd "$db" -c "select bench.load('docs', '$shape', $size, $NDOCS)" >/dev/null
            case $variant in
                title) qd "$db" -c "create index on docs (title)" >/dev/null ;;
                upd) qd "$db" -c "create index on docs (updated_at)" >/dev/null ;;
            esac
            qd "$db" -c "vacuum analyze" -c checkpoint >/dev/null
            rels="bench.rels('docs', '$shape')"
            snap M0 "$db" "$rels" false
            edit_script "$WORK/e.sql" "$shape" docs "$size" "random(1, $NDOCS)" "$([ $variant = upd ] && echo upd)"
            l0=$(lsn "$db")
            pgb "$db" "$WORK/e.sql" -c $CLIENTS -j $CLIENTS -t $((HOT_EDITS / CLIENTS))
            l1=$(lsn "$db")
            sleep 1
            snap M1 "$db" "$rels" false
            label=$variant; [ $variant = title ] && label="title index"; [ $variant = upd ] && label="updated_at index"
            row "$(size_label $size)" "$(shape_label $shape)" "$label" "$(pct $((M1_n_hot - M0_n_hot)) $((M1_n_upd - M0_n_upd)))" \
                "$(mb $M0_idx)" "$(mb $M1_idx)" "$(mb $M1_total)" "$(kb $(div $(lsn_diff $l0 $l1) $P_OK))"
            drop_db "$db"
        done
    done
done
echo
progress "bloat: done, $OUT"
