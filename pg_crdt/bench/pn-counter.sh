#!/usr/bin/env bash
# PN-Counter benchmark: merge latency vs number of replicas, merge variants,
# and WAL bytes per write for the two storage shapes. Prints Markdown tables
# for research/benchmarks/pn-counter.md. Not polished; a measurement tool.
#
#   bench/pn-counter.sh               # throwaway cluster from test/lib/cluster.sh
#   bench/pn-counter.sh --external    # the server from PGHOST/PGPORT/PGUSER
#
# The throwaway cluster runs with full_page_writes=on (the test cluster turns
# it off), so the WAL numbers include full-page images after each CHECKPOINT,
# as on a production server. fsync stays off; it does not change WAL volume.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(dirname "$HERE")
. "$EXT_DIR/test/lib/cluster.sh"

EXTERNAL=0
[ "${1:-}" = --external ] && EXTERNAL=1
export PG_EXTRA_OPTS="-c full_page_writes=on ${PG_EXTRA_OPTS:-}"

start_cluster
DB=pgcrdt_bench
psql_admin -c "drop database if exists $DB" -c "create database $DB"
PSQL=("$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$DB")
"${PSQL[@]}" -f "$EXT_DIR/pg_crdt--0.0.1.sql"

echo "Postgres: $("${PSQL[@]}" -tA -c 'show server_version')"
if [ "$(uname -s)" = Darwin ]; then
    echo "Machine:  $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) CPU, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(sw_vers -productVersion)"
else
    echo "Machine:  $(uname -m), $(nproc) CPU"
fi
echo "Date:     $(date '+%Y-%m-%d %H:%M %Z')"
echo

"${PSQL[@]}" <<'SQL'
create schema bench;

-- Variants of pn_merge, for comparison only (not in the extension).

-- 1. The overlay with || for every change (crdt.pn_merge uses jsonb_set
--    when exactly one entry changes), on plain jsonb: no domain CHECK.
create function bench.merge_no_domain(a jsonb, b jsonb) returns jsonb
language sql immutable parallel safe
return case when a is null then b when b is null then a else (
    select jsonb_build_object('t', 'pn', 'v', 1,
        'p', m.ap || coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(m.bp) e
                               where (m.ap -> e.key) is null or e.value > (m.ap -> e.key)), '{}'::jsonb),
        'n', m.an || coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(m.bn) e
                               where (m.an -> e.key) is null or e.value > (m.an -> e.key)), '{}'::jsonb))
    from (select a -> 'p' as ap, a -> 'n' as an, b -> 'p' as bp, b -> 'n' as bn offset 0) m) end;

-- 2. The first draft of pn_merge: the same overlay, with `a -> 'p' -> e.key`
--    inline, so a is detoasted and its map copied once per entry of b.
create function bench.merge_naive_overlay(a crdt.pn, b crdt.pn) returns crdt.pn
language sql immutable parallel safe
return case when a is null then b when b is null then a else jsonb_build_object(
    't', 'pn', 'v', 1,
    'p', (a -> 'p') || coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(b -> 'p') e
                                 where e.value > coalesce(a -> 'p' -> e.key, '-1'::jsonb)), '{}'::jsonb),
    'n', (a -> 'n') || coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(b -> 'n') e
                                 where e.value > coalesce(a -> 'n' -> e.key, '-1'::jsonb)), '{}'::jsonb))::crdt.pn end;

-- 2b. Full join of both maps, per-key greatest, rebuilt with jsonb_object_agg.
create function bench.merge_fulljoin(a crdt.pn, b crdt.pn) returns crdt.pn
language sql immutable parallel safe
return case when a is null then b when b is null then a else jsonb_build_object(
    't', 'pn', 'v', 1,
    'p', (select coalesce(jsonb_object_agg(coalesce(x.key, y.key), greatest(x.value, y.value)), '{}')
          from jsonb_each(a -> 'p') x full join jsonb_each(b -> 'p') y on x.key = y.key),
    'n', (select coalesce(jsonb_object_agg(coalesce(x.key, y.key), greatest(x.value, y.value)), '{}')
          from jsonb_each(a -> 'n') x full join jsonb_each(b -> 'n') y on x.key = y.key))::crdt.pn end;

-- 3. The same overlay in PL/pgSQL, the maps in variables.
create function bench.merge_plpgsql(a crdt.pn, b crdt.pn) returns crdt.pn
language plpgsql immutable parallel safe as $$
declare
    ap jsonb;
    an jsonb;
begin
    if a is null then return b; end if;
    if b is null then return a; end if;
    ap := a -> 'p';
    an := a -> 'n';
    return jsonb_build_object(
        't', 'pn', 'v', 1,
        'p', ap || coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(b -> 'p') e
                             where (ap -> e.key) is null or e.value > (ap -> e.key)), '{}'::jsonb),
        'n', an || coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(b -> 'n') e
                             where (an -> e.key) is null or e.value > (an -> e.key)), '{}'::jsonb));
end;
$$;

-- 4. The anti-pattern: a PL/pgSQL loop of jsonb_set, one per entry of b.
create function bench.merge_loop(a crdt.pn, b crdt.pn) returns crdt.pn
language plpgsql immutable parallel safe as $$
declare
    r jsonb := a;
    e record;
begin
    if a is null then return b; end if;
    if b is null then return a; end if;
    for e in select m.map, x.key, x.value from (values ('p'), ('n')) m(map), jsonb_each(b -> m.map) x loop
        if e.value > coalesce(r -> e.map -> e.key, '-1'::jsonb) then
            r := jsonb_set(r, array[e.map, e.key], e.value);
        end if;
    end loop;
    return r;
end;
$$;

-- Random state with n replicas: p for all, n for a third.
create function bench.state(n int, lo int, hi int) returns crdt.pn language sql volatile as $$
    select jsonb_build_object('t', 'pn', 'v', 1,
        'p', (select jsonb_object_agg('user-' || lpad(i::text, 6, '0'), lo + floor(random() * (hi - lo))::bigint) from generate_series(1, n) i),
        'n', (select jsonb_object_agg('user-' || lpad(i::text, 6, '0'), lo + floor(random() * (hi - lo))::bigint) from generate_series(1, n, 3) i))
$$;

-- pairs: rows of (a, full, delta) per size. full has the same keys as a with
-- random values (about half larger); delta raises one existing entry of a.
create table bench.pairs (n int, a crdt.pn, full_b crdt.pn, delta crdt.pn);
select setseed(0.1) \g /dev/null
insert into bench.pairs
select n, s.a, s.full_b,
       jsonb_build_object('t', 'pn', 'v', 1, 'p', jsonb_build_object('user-' || lpad((1 + floor(random() * n))::int::text, 6, '0'), 10000000), 'n', '{}'::jsonb)
from (values (10, 2000), (100, 400), (1000, 60), (10000, 12)) v(n, m),
     generate_series(1, v.m),
     lateral (select bench.state(v.n, 1, 1000000) as a, bench.state(v.n, 1, 1000000) as full_b) s;
analyze bench.pairs;

-- Average microseconds per call of expr over the rows of size n: the best of 3.
create function bench.us_per_call(expr text, n int) returns numeric language plpgsql as $$
declare
    t0 timestamptz;
    best numeric;
    rows bigint;
    took numeric;
begin
    for i in 1..3 loop
        t0 := clock_timestamp();
        execute format('select count(%s) from bench.pairs where n = %s', expr, n) into rows;
        took := extract(epoch from clock_timestamp() - t0) * 1e6 / rows;
        best := least(best, took);
    end loop;
    return round(best, 1);
end;
$$;
SQL

echo "### Merge latency (microseconds per call, best of 3)"
echo
"${PSQL[@]}" -P footer=off -P format=aligned <<'SQL'
select n as replicas,
       (select pg_catalog.round(avg(pg_column_size(a))) from bench.pairs p where p.n = s.n) as state_bytes,
       bench.us_per_call('crdt.pn_merge(a, full_b)', n) as "pn_merge full",
       bench.us_per_call('crdt.pn_merge(a, delta)', n) as "pn_merge delta",
       bench.us_per_call('bench.merge_no_domain(a, full_b)', n) as "concat-only, no domain full",
       bench.us_per_call('bench.merge_no_domain(a, delta)', n) as "concat-only, no domain delta",
       bench.us_per_call('bench.merge_plpgsql(a, full_b)', n) as "plpgsql full",
       bench.us_per_call('bench.merge_plpgsql(a, delta)', n) as "plpgsql delta",
       bench.us_per_call('bench.merge_fulljoin(a, full_b)', n) as "full join full",
       bench.us_per_call('bench.merge_fulljoin(a, delta)', n) as "full join delta",
       case when n <= 1000 then bench.us_per_call('bench.merge_naive_overlay(a, full_b)', n) end as "naive full",
       bench.us_per_call('bench.merge_naive_overlay(a, delta)', n) as "naive delta",
       case when n <= 1000 then bench.us_per_call('bench.merge_loop(a, full_b)', n) end as "jsonb_set loop full",
       bench.us_per_call('bench.merge_loop(a, delta)', n) as "jsonb_set loop delta",
       bench.us_per_call('crdt.pn_value(a)', n) as "pn_value",
       bench.us_per_call('crdt.pn_is_valid(a)', n) as "pn_is_valid",
       bench.us_per_call('crdt.pn_increment(a, ''user-000001'', 1)', n) as "pn_increment"
from (select distinct n from bench.pairs) s
order by n;
SQL
echo

# WAL per write. K writes, each its own transaction (autocommit), after a CHECKPOINT.
K=500
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pgcrdt-bench.XXXXXX")
trap 'rm -rf "$WORK"; stop_cluster' EXIT

"${PSQL[@]}" <<'SQL'
create table bench.counters (id int primary key, s crdt.pn not null);
create table bench.deltas (id bigserial primary key, counter int not null, d crdt.pn not null);
create index on bench.deltas (counter);
create table bench.wal (shape text, replicas int, writes int, wal_bytes numeric, ms numeric, state_bytes int);
SQL

measure() {  # shape replicas script
    local shape=$1 n=$2 script=$3
    "${PSQL[@]}" -c checkpoint
    "${PSQL[@]}" <<SQL
select pg_current_wal_insert_lsn() as l0, extract(epoch from clock_timestamp()) as t0 \gset
\i $script
select pg_current_wal_insert_lsn() as l1, extract(epoch from clock_timestamp()) as t1 \gset
insert into bench.wal values ('$shape', $n, $K, pg_wal_lsn_diff(:'l1', :'l0'), (:t1 - :t0) * 1000,
    (select pg_column_size(s) from bench.counters where id = 1));
SQL
}

for n in 10 100 1000 10000; do
    "${PSQL[@]}" -c "truncate bench.counters, bench.deltas" \
        -c "select setseed(0.2)" >/dev/null \
        -c "insert into bench.counters values (1, bench.state($n, 1, 1000))"
    # Each write raises one replica's p entry: a delta of one entry.
    "${PSQL[@]}" -tA -c "select format('update bench.counters set s = crdt.pn_merge(s, %L) where id = 1;',
        jsonb_build_object('t', 'pn', 'v', 1, 'p', jsonb_build_object('user-' || lpad((1 + i % $n)::text, 6, '0'), 100000 + i), 'n', '{}'::jsonb))
        from generate_series(1, $K) i" > "$WORK/update.sql"
    "${PSQL[@]}" -tA -c "select format('insert into bench.deltas (counter, d) values (1, %L);',
        jsonb_build_object('t', 'pn', 'v', 1, 'p', jsonb_build_object('user-' || lpad((1 + i % $n)::text, 6, '0'), 100000 + i), 'n', '{}'::jsonb))
        from generate_series(1, $K) i" > "$WORK/insert.sql"
    measure "state column (update ... pn_merge)" "$n" "$WORK/update.sql"
    measure "delta table (insert)" "$n" "$WORK/insert.sql"
done

# Read side of the delta table: pn_value(pn_merge_agg(d)) over K delta rows.
read_ms=$("${PSQL[@]}" -tA <<'SQL'
create function bench.read_ms() returns numeric language plpgsql as $$
declare
    t0 timestamptz;
    v bigint;
    best numeric;
begin
    for i in 1..5 loop
        t0 := clock_timestamp();
        select crdt.pn_value(crdt.pn_merge_agg(d)) into v from bench.deltas where counter = 1;
        best := least(best, extract(epoch from clock_timestamp() - t0) * 1000);
    end loop;
    return round(best, 2);
end;
$$;
select bench.read_ms();
SQL
)

echo "### WAL per write ($K writes, one transaction each, after a CHECKPOINT; full_page_writes=on)"
echo
"${PSQL[@]}" -P footer=off <<'SQL'
select shape, replicas, state_bytes as "state bytes (on disk)",
       round(wal_bytes / writes) as "WAL bytes per write",
       round(ms * 1000 / writes) as "us per write (client)"
from bench.wal order by shape desc, replicas;
SQL
echo
echo "Reading the delta table back: pn_value(pn_merge_agg(d)) over $K delta rows (10,000-replica run's table): ${read_ms} ms"
