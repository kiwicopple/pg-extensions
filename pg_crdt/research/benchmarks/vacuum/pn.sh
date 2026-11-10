#!/usr/bin/env bash
# PN-Counter (pn_): state size, bloat with autovacuum off, HOT ratio, WAL per
# increment decomposed with pg_waldump, the delta-table variant and what the
# hand-written compaction recipe recovers, and steady state with autovacuum on.
#
#   research/benchmarks/vacuum/pn.sh            # writes results/pn.md
#   QUICK=1 research/benchmarks/vacuum/pn.sh
#
# State column: NCOUNTERS rows (default 100), each a crdt.pn with R replicas
# (ids user-000001 ..., a third also in n); every write is
#   update counters set s = crdt.pn_increment(s, <random replica of R>, 1) where id = <random>
# Delta table: insert into deltas (counter, d) values (<random>, <one-entry delta>),
# read with pn_merge_agg; compaction is the recipe of
# docs/guides/storage-and-performance.md, run for all counters at once
# (compaction is not built into the extension).
set -euo pipefail
. "$(dirname "$0")/common.sh"

if [ "$QUICK" = 1 ]; then
    WRITES=${WRITES:-2000}; HOT_WRITES=${HOT_WRITES:-1000}; WAL_WRITES=${WAL_WRITES:-300}; DURATION=${DURATION:-40}
else
    WRITES=${WRITES:-20000}; HOT_WRITES=${HOT_WRITES:-10000}; WAL_WRITES=${WAL_WRITES:-2000}; DURATION=${DURATION:-180}
fi
NCOUNTERS=${NCOUNTERS:-100}
REPLICAS=${REPLICAS:-"10 100 1000 10000"}
DELTA_REPLICAS=${DELTA_REPLICAS:-1000}
AV_REPLICAS=${AV_REPLICAS:-"10 1000"}
SPREAD_RATE=${SPREAD_RATE:-200}
HOT_RATE=${HOT_RATE:-100}
SAMPLE=${SAMPLE:-5}
CLIENTS=4
OUT=${OUT:-$RESULTS/pn.md}
WAL_RAW=${WAL_RAW:-$RESULTS/pn-wal-raw.txt}
: > "$WAL_RAW"

export PG_EXTRA_OPTS="$BASE_OPTS -c autovacuum=off -c max_wal_size=2GB ${PG_EXTRA_OPTS:-}"
start_cluster
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pgcrdt-pn.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORK"; stop_cluster' EXIT
make_template ""

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

load_counters() {  # db replicas [variant]
    qd "$1" >/dev/null <<SQL
select setseed(0.42);
create table counters (id int primary key, title text not null, updated_at timestamptz not null default now(), s crdt.pn not null);
insert into counters (id, title, s) select c, 'Counter ' || c, bench.pn_state($2) from generate_series(1, $NCOUNTERS) c;
SQL
    case ${3:-} in
        title) qd "$1" -c "create index on counters (title)" >/dev/null ;;
        upd) qd "$1" -c "create index on counters (updated_at)" >/dev/null ;;
    esac
    qd "$1" -c "vacuum analyze" -c checkpoint >/dev/null
}
inc_script() {  # file replicas ids [variant]
    local set_upd=""
    [ "${4:-}" = upd ] && set_upd=", updated_at = now()"
    cat > "$1" <<EOF
\\set id $3
\\set r random(1, $2)
update counters set s = crdt.pn_increment(s, 'user-' || lpad(:r::text, 6, '0'), 1)$set_upd where id = :id;
EOF
}
load_deltas() {  # db
    qd "$1" >/dev/null <<'SQL'
create table deltas (id bigserial primary key, counter int not null, d crdt.pn not null);
create index on deltas (counter);
create table snapshots (counter int primary key, state crdt.pn not null);
SQL
    qd "$1" -c "vacuum analyze" -c checkpoint >/dev/null
}
delta_script() {  # file replicas
    cat > "$1" <<EOF
\\set id random(1, $NCOUNTERS)
\\set r random(1, $2)
\\set c random(1, 1000000)
insert into deltas (counter, d) values (:id, crdt.pn_increment(crdt.pn_empty(), 'user-' || lpad(:r::text, 6, '0'), :c));
EOF
}
read_ms() {  # db -> mean ms of reading one counter's value (snapshot merged with its deltas)
    cat > "$WORK/read.sql" <<EOF
\\set id random(1, $NCOUNTERS)
select crdt.pn_value(crdt.pn_merge((select state from snapshots where counter = :id), (select crdt.pn_merge_agg(d) from deltas where counter = :id)));
EOF
    "$PGBIN/pgbench" -n -f "$WORK/read.sql" -c 1 -t 500 "$1" 2>&1 | sed -n 's/^latency average = \([0-9.]*\) ms/\1/p'
}

exec > >(tee "$OUT")
echo "# PN-Counter: storage, bloat, WAL"
echo
header

# ------------------------------------------------------------- 1. state size
progress "pn: state size"
echo "## State size"
echo
echo "Stored size (pg_column_size, after TOAST compression) of one crdt.pn with R replicas, a third of them also in n, every count drawn up to the given maximum (the count's digits are what grows with the number of increments)."
echo
qd vac_tmpl >/dev/null <<SQL
select setseed(0.42);
create table bench.g (r int, top bigint, s crdt.pn);
insert into bench.g select r, c, bench.pn_state(r, c) from unnest(array[1, 10, 100, 1000, 10000]) r, unnest(array[1, 1000, 1000000, 1000000000]::bigint[]) c;
SQL
hdr "replicas" "counts up to 1" "up to 1,000" "up to 1,000,000" "up to 1,000,000,000" "as JSON text (up to 1,000,000)" "bytes per replica (up to 1,000,000)"
for r in 1 10 100 1000 10000; do
    row "$r" $(qd vac_tmpl -F' ' -c "select string_agg(pg_column_size(s)::text, ' ' order by top) from bench.g where r = $r") \
        "$(qd vac_tmpl -c "select length(s::text) from bench.g where r = $r and top = 1000000")" \
        "$(qd vac_tmpl -c "select round(pg_column_size(s)::numeric / r, 1) from bench.g where r = $r and top = 1000000")"
done
qd vac_tmpl -c "drop table bench.g" >/dev/null
echo

# ------------------------------------------------------------- 2. bloat, autovacuum off
echo "## State column: bloat with autovacuum off"
echo
echo "$NCOUNTERS counters, $WRITES increments ($CLIENTS clients, random counter and replica, one per transaction). Sizes in MB; columns as in bloat.md."
echo
hdr "replicas" "stored state (bytes)" "loaded total" "after: total" "heap" "TOAST" "dead heap tuples" "dead TOAST tuples" "dead TOAST MB" "live MB" "after VACUUM: total" "reusable" "after VACUUM FULL" "total / live" "HOT %" "WAL per write (B)" "us per write"
for r in $REPLICAS; do
    db="vp_$r"
    progress "pn: bloat $r"
    new_db "$db"
    load_counters "$db" "$r"
    rels="array['counters']::regclass[]"
    snap M0 "$db" "$rels"
    stored=$(qd "$db" -c "select round(avg(pg_column_size(s))) from counters")
    inc_script "$WORK/inc.sql" "$r" "random(1, $NCOUNTERS)"
    l0=$(lsn "$db"); t0=$(now)
    pgb "$db" "$WORK/inc.sql" -c $CLIENTS -j $CLIENTS -t $((WRITES / CLIENTS))
    t1=$(now); l1=$(lsn "$db")
    sleep 1
    snap M1 "$db" "$rels"
    qd "$db" -c vacuum >/dev/null
    snap M2 "$db" "$rels"
    qd "$db" -c "vacuum full" >/dev/null
    snap M3 "$db" "$rels"
    live=$((M1_heap_live + M1_toast_live))
    row "$r" "$stored" "$(mb $M0_total)" "$(mb $M1_total)" "$(mb $M1_heap)" "$(mb $M1_toast)" "$M1_n_dead" "$M1_toast_n_dead" "$(mb $M1_toast_dead)" "$(mb $live)" \
        "$(mb $M2_total)" "$(mb $((M2_heap_free + M2_toast_free)))" "$(mb $M3_total)" "$(ratio $M1_total $live)" \
        "$(pct $((M1_n_hot - M0_n_hot)) $((M1_n_upd - M0_n_upd)))" "$(div $(lsn_diff $l0 $l1) $P_OK)" \
        "$(awk -v a="$t0" -v b="$t1" -v n="$P_OK" -v c=$CLIENTS 'BEGIN { printf "%.0f", (b - a) * 1e6 * c / n }')"
    drop_db "$db"
done
echo
echo "'us per write' is wall time x clients / writes (client round trip included, fsync off)."
echo

# ------------------------------------------------------------- 3. HOT variants
echo "## State column: HOT updates with an index on another column"
echo
echo "$HOT_WRITES increments per run. Index variants as in bloat.md."
echo
hdr "replicas" "index" "HOT %" "indexes before (MB)" "indexes after (MB)" "total after (MB)" "WAL per write (B)"
for r in 10 1000; do
    for variant in none title upd; do
        db="vph_${r}_$variant"
        progress "pn: hot $r $variant"
        new_db "$db"
        load_counters "$db" "$r" "$variant"
        rels="array['counters']::regclass[]"
        snap M0 "$db" "$rels" false
        inc_script "$WORK/inc.sql" "$r" "random(1, $NCOUNTERS)" "$variant"
        l0=$(lsn "$db")
        pgb "$db" "$WORK/inc.sql" -c $CLIENTS -j $CLIENTS -t $((HOT_WRITES / CLIENTS))
        l1=$(lsn "$db")
        sleep 1
        snap M1 "$db" "$rels" false
        label=$variant; [ $variant = title ] && label="title index"; [ $variant = upd ] && label="updated_at index"
        row "$r" "$label" "$(pct $((M1_n_hot - M0_n_hot)) $((M1_n_upd - M0_n_upd)))" "$(mb $M0_idx)" "$(mb $M1_idx)" "$(mb $M1_total)" "$(div $(lsn_diff $l0 $l1) $P_OK)"
        drop_db "$db"
    done
done
echo

# ------------------------------------------------------------- 4. delta table
echo "## Delta table and compaction"
echo
echo "$NCOUNTERS counters, deltas from $DELTA_REPLICAS replicas, $WRITES inserts ($CLIENTS clients), then the compaction recipe for all counters in one statement:"
echo
echo '```sql'
echo 'with folded as (delete from deltas returning counter, d)'
echo 'insert into snapshots (counter, state)'
echo 'select counter, crdt.pn_merge_agg(d) from folded group by counter'
echo 'on conflict (counter) do update set state = crdt.pn_merge(snapshots.state, excluded.state);'
echo '```'
echo
echo "Then VACUUM, a second batch of $WRITES inserts, VACUUM FULL. Sizes in MB (deltas and snapshots tables, with indexes). 'read ms' is the mean latency of reading one counter's value (snapshot merged with its deltas; pgbench, 500 reads)."
echo
db="vp_delta"
progress "pn: delta table"
new_db "$db"
load_deltas "$db"
rels="array['deltas', 'snapshots']::regclass[]"
delta_script "$WORK/delta.sql" "$DELTA_REPLICAS"
hdr "step" "delta rows" "snapshot rows" "total" "heap" "indexes" "dead tuples" "reusable" "read ms" "WAL MB" "seconds"
step_row() {  # label wal secs
    snap D "$db" "$rels"
    row "$1" "$(qd "$db" -c "select count(*) from deltas")" "$(qd "$db" -c "select count(*) from snapshots")" "$(mb $D_total)" "$(mb $D_heap)" "$(mb $D_idx)" \
        "$D_n_dead" "$(mb $((D_heap_free + D_toast_free)))" "$(read_ms "$db")" "$2" "$3"
}
step_row "empty" - -
l0=$(lsn "$db"); t0=$(now)
pgb "$db" "$WORK/delta.sql" -c $CLIENTS -j $CLIENTS -t $((WRITES / CLIENTS))
t1=$(now); l1=$(lsn "$db"); sleep 1
step_row "after $WRITES inserts" "$(mb $(lsn_diff $l0 $l1))" "$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')"
ins_wal=$(div $(lsn_diff $l0 $l1) $P_OK)
l0=$(lsn "$db"); t0=$(now)
qd "$db" >/dev/null <<'SQL'
with folded as (delete from deltas returning counter, d)
insert into snapshots (counter, state)
select counter, crdt.pn_merge_agg(d) from folded group by counter
on conflict (counter) do update set state = crdt.pn_merge(snapshots.state, excluded.state);
SQL
t1=$(now); l1=$(lsn "$db"); sleep 1
step_row "after compaction" "$(mb $(lsn_diff $l0 $l1))" "$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')"
t0=$(now); qd "$db" -c vacuum >/dev/null; t1=$(now)
step_row "after VACUUM" - "$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')"
l0=$(lsn "$db")
pgb "$db" "$WORK/delta.sql" -c $CLIENTS -j $CLIENTS -t $((WRITES / CLIENTS))
l1=$(lsn "$db"); sleep 1
step_row "after $WRITES more inserts" "$(mb $(lsn_diff $l0 $l1))" -
qd "$db" >/dev/null <<'SQL'
with folded as (delete from deltas returning counter, d)
insert into snapshots (counter, state)
select counter, crdt.pn_merge_agg(d) from folded group by counter
on conflict (counter) do update set state = crdt.pn_merge(snapshots.state, excluded.state);
SQL
qd "$db" -c vacuum >/dev/null
step_row "after compaction + VACUUM" - -
qd "$db" -c "vacuum full" >/dev/null
step_row "after VACUUM FULL" - -
echo
echo "Snapshot state after both batches: $(qd "$db" -c "select round(avg(pg_column_size(state))) from snapshots") bytes per counter on average. Insert WAL: $ins_wal bytes per delta (LSN)."
drop_db "$db"
echo

# ------------------------------------------------------------- 5. WAL decomposition
echo "## WAL per write, decomposed"
echo
echo "$WAL_WRITES writes per run, one client. 'cold' starts right after a CHECKPOINT, 'warm' follows it without one. Bytes per write; columns as in wal.md."
echo
hdr "write" "replicas" "phase" "wal_compression" "LSN" "records" "FPI" "FPI share" "heap" "btree" "other"
pn_wal_run() {  # db script label replicas phase comp
    local l0 l1
    l0=$(lsn "$1")
    PGOPTIONS="$PGOPTIONS -c wal_compression=$6" pgb "$1" "$2" -c 1 -j 1 -t "$WAL_WRITES"
    l1=$(qd "$1" -c "select pg_current_wal_flush_lsn()")
    WAL_LABEL="$3 $4 $5 $6" waldump "$l0" "$l1"
    row "$3" "$4" "$5" "$6" "$(div $(lsn_diff $l0 $l1) $P_OK)" "$(div $W_REC $P_OK)" "$(div $W_FPI $P_OK)" "$(pct $W_FPI $W_TOT)" \
        "$(div $W_HEAP $P_OK)" "$(div $W_BTREE $P_OK)" "$(div $W_OTHER $P_OK)"
}
for r in $REPLICAS; do
    db="vpw_$r"
    progress "pn: wal $r"
    new_db "$db"
    load_counters "$db" "$r"
    inc_script "$WORK/inc.sql" "$r" "random(1, $NCOUNTERS)"
    qd "$db" -c checkpoint >/dev/null
    pn_wal_run "$db" "$WORK/inc.sql" "state column" "$r" cold off
    pn_wal_run "$db" "$WORK/inc.sql" "state column" "$r" warm off
    qd "$db" -c checkpoint >/dev/null
    pn_wal_run "$db" "$WORK/inc.sql" "state column" "$r" cold lz4
    drop_db "$db"
done
db="vpw_delta"
new_db "$db"
load_deltas "$db"
delta_script "$WORK/delta.sql" "$DELTA_REPLICAS"
qd "$db" -c checkpoint >/dev/null
pn_wal_run "$db" "$WORK/delta.sql" "delta insert" "$DELTA_REPLICAS" cold off
pn_wal_run "$db" "$WORK/delta.sql" "delta insert" "$DELTA_REPLICAS" warm off
qd "$db" -c checkpoint >/dev/null
pn_wal_run "$db" "$WORK/delta.sql" "delta insert" "$DELTA_REPLICAS" cold lz4
drop_db "$db"
echo

# ------------------------------------------------------------- 6. autovacuum on
echo "## State column: steady state with autovacuum on (default settings), fsync=on"
echo
# A new cluster: fsync and autovacuum are on the command line of the first one
# (test/lib/cluster.sh passes fsync=off), where ALTER SYSTEM cannot change them.
stop_cluster
export PG_EXTRA_OPTS="$BASE_OPTS -c fsync=on -c max_wal_size=2GB"
start_cluster
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$WORK"; stop_cluster' EXIT
make_template ""
echo "Settings now: $(qd postgres -c "select string_agg(name || '=' || current_setting(name), ', ' order by name) from pg_settings where name in ('autovacuum','fsync','autovacuum_naptime','autovacuum_vacuum_scale_factor','autovacuum_vacuum_threshold','autovacuum_vacuum_cost_limit','autovacuum_vacuum_cost_delay')")."
echo
echo "'spread': $SPREAD_RATE increments/s over all $NCOUNTERS counters (4 clients). 'hot': $HOT_RATE increments/s on counter 1 (2 clients). $DURATION s per run. Columns as in autovac.md."
echo
hdr "replicas" "scenario" "writes/s achieved" "loaded" "at 60 s" "at 120 s" "end" "peak" "live at end" "end / live" "peak dead heap / TOAST" "autovacuums heap / TOAST" "WAL MB/s"
for r in $AV_REPLICAS; do
    for scenario in spread hot; do
        db="vpa_${r}_$scenario"
        progress "pn: autovac $r $scenario"
        new_db "$db"
        load_counters "$db" "$r"
        rels="array['counters']::regclass[]"
        snap M0 "$db" "$rels"
        if [ $scenario = spread ]; then inc_script "$WORK/inc.sql" "$r" "random(1, $NCOUNTERS)"; clients=4; rate=$SPREAD_RATE
        else inc_script "$WORK/inc.sql" "$r" "1"; clients=2; rate=$HOT_RATE; fi
        samples="$WORK/samples"; : > "$samples"
        l0=$(lsn "$db"); t0=$(date +%s)
        (
            while :; do
                qd "$db" -F' ' -c "select $(date +%s) - $t0, total, n_dead, toast_n_dead, av_heap, av_toast from bench.measure($rels, false)" >> "$samples" 2>/dev/null || true
                sleep "$SAMPLE"
            done
        ) &
        sampler=$!
        pgb "$db" "$WORK/inc.sql" -c $clients -j $clients -T "$DURATION" -R "$rate"
        kill $sampler 2>/dev/null; wait $sampler 2>/dev/null || true
        l1=$(lsn "$db"); elapsed=$(( $(date +%s) - t0 ))
        sleep 1
        snap M1 "$db" "$rels"
        at() { awk -v t="$1" '$1 <= t { v = $2 } END { print v + 0 }' "$samples"; }
        peak=$(awk -v e="$M1_total" '{ if ($2 > m) m = $2 } END { print (e > m ? e : m) + 0 }' "$samples")
        live=$((M1_heap_live + M1_toast_live))
        row "$r" "$scenario" "$P_TPS" "$(mb $M0_total)" "$(mb $(at 60))" "$(mb $(at 120))" "$(mb $M1_total)" "$(mb $peak)" "$(mb $live)" "$(ratio $M1_total $live)" \
            "$(awk '{ if ($3 > m) m = $3 } END { print m + 0 }' "$samples") / $(awk '{ if ($4 > m) m = $4 } END { print m + 0 }' "$samples")" \
            "$((M1_av_heap - M0_av_heap)) / $((M1_av_toast - M0_av_toast))" \
            "$(awk -v w="$(lsn_diff $l0 $l1)" -v t="$elapsed" 'BEGIN { printf "%.2f", w / t / 1048576 }')"
        drop_db "$db"
    done
done
echo
progress "pn: done, $OUT"
