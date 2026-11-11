#!/usr/bin/env bash
# yseq_ (shape A) benchmark: edit latency, read latency, merge, storage and
# WAL per edit for documents of 1k to 1M characters, and a replay of the
# automerge-paper editing trace. Prints Markdown for NOTES.md. A
# measurement tool, not polished.
#
#   experiments/text-column/bench.sh                # throwaway cluster (test/lib/cluster.sh)
#   experiments/text-column/bench.sh --quick        # skip the 1M document and the long replays
#   experiments/text-column/bench.sh --impl x.sql   # load x.sql after the extension (create or replace a variant)
#   experiments/text-column/bench.sh --full-trace   # only: the whole trace, one UPDATE per patch (lz4 column)
#
# Needs the trace files from experiments/text-ref (regen-traces.sh).
# The cluster runs with full_page_writes=on, as bench/pn-counter.sh, so WAL
# numbers include full-page images after each CHECKPOINT. fsync is off.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(cd "$HERE/../.." && pwd)
TRACES="$EXT_DIR/experiments/text-ref/traces"
. "$EXT_DIR/test/lib/cluster.sh"

QUICK=0
FULL_TRACE=0
IMPL=
while [ $# -gt 0 ]; do
    case "$1" in
        --quick) QUICK=1; shift ;;
        --full-trace) FULL_TRACE=1; shift ;;
        --external) EXTERNAL=1; shift ;;
        --impl) IMPL=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
for f in automerge-paper.patches.jsonl automerge-paper.batch100.jsonl automerge-paper.ops.jsonl; do
    [ -f "$TRACES/$f" ] || { echo "error: $TRACES/$f is missing; run experiments/text-ref/regen-traces.sh" >&2; exit 2; }
done

export PG_EXTRA_OPTS="-c full_page_writes=on -c max_wal_size=4GB ${PG_EXTRA_OPTS:-}"
export PGCLIENTENCODING=UTF8
start_cluster
DB=yseq_bench
psql_admin -c "drop database if exists $DB" -c "create database $DB encoding 'UTF8' template template0"
PSQL=("$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$DB")
"${PSQL[@]}" -f "$EXT_DIR/pg_crdt--0.0.1.sql"
[ -n "$IMPL" ] && "${PSQL[@]}" -f "$IMPL"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/yseq-bench.XXXXXX")
trap 'rm -rf "$WORK"; stop_cluster' EXIT

echo "Postgres: $("${PSQL[@]}" -tA -c 'show server_version')"
if [ "$(uname -s)" = Darwin ]; then
    echo "Machine:  $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) CPU, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB, macOS $(sw_vers -productVersion)"
else
    echo "Machine:  $(uname -m), $(nproc) CPU"
fi
echo "Date:     $(date '+%Y-%m-%d %H:%M %Z')"
echo "Impl:     pg_crdt--0.0.1.sql${IMPL:+ + ${IMPL#$EXT_DIR/}}, chunk size $("${PSQL[@]}" -tA -c 'select crdt._yseq_cmax()') runs"
echo

"${PSQL[@]}" <<SQL
create schema bench;
create table bench.patches (n bigint generated always as identity primary key, p jsonb not null);
create table bench.batch100 (n bigint generated always as identity primary key, op jsonb not null);
create table bench.ops (n bigint generated always as identity primary key, op jsonb not null);
\copy bench.patches (p) from '$TRACES/automerge-paper.patches.jsonl' with (format csv, quote e'\x01', delimiter e'\x02')
\copy bench.batch100 (op) from '$TRACES/automerge-paper.batch100.jsonl' with (format csv, quote e'\x01', delimiter e'\x02')
\copy bench.ops (op) from '$TRACES/automerge-paper.ops.jsonl' with (format csv, quote e'\x01', delimiter e'\x02')

-- Replay the first lim patches by position in memory. Returns the state.
create function bench.replay(lim bigint) returns crdt.yseq language plpgsql as \$\$
declare
    s crdt.yseq := crdt.yseq_empty();
    r record;
begin
    for r in select (p ->> 0)::int pos, (p ->> 1)::int del, p ->> 2 ins from bench.patches where n <= lim order by n loop
        if r.del > 0 then s := crdt.yseq_delete(s, r.pos, r.del, 'paper'); end if;
        if r.ins <> '' then s := crdt.yseq_insert(s, r.pos, r.ins, 'paper'); end if;
    end loop;
    return s;
end;
\$\$;

-- n random local edits (70% insert 'ab', 30% delete 1) as replica r.
create function bench.diverge(s crdt.yseq, r text, n int) returns crdt.yseq language plpgsql as \$\$
declare
    len int;
begin
    for i in 1..n loop
        len := crdt.yseq_length(s);
        if random() < 0.7 or len < 10 then
            s := crdt.yseq_insert(s, floor(random() * (len + 1))::int, 'ab', r);
        else
            s := crdt.yseq_delete(s, floor(random() * (len - 1))::int, 1, r);
        end if;
    end loop;
    return s;
end;
\$\$;

-- Milliseconds per execution of q (with \$1 = the state), the best of 3 runs of n.
create function bench.ms(q text, s crdt.yseq, n int) returns numeric language plpgsql as \$\$
declare
    t0 timestamptz;
    best numeric;
    x record;
begin
    for k in 1..3 loop
        t0 := clock_timestamp();
        for i in 1..n loop
            execute q using s into x;
        end loop;
        best := least(best, extract(epoch from clock_timestamp() - t0) * 1000 / n);
    end loop;
    return round(best, 3);
end;
\$\$;

create table bench.docs (id int primary key, label text, s crdt.yseq not null);
create table bench.docs_lz4 (id int primary key, s crdt.yseq compression lz4 not null);
create table bench.plain (id int primary key, t text not null);
create table bench.res (label text, metric text, shape text, us numeric, wal numeric);
SQL

if [ $FULL_TRACE = 1 ]; then
    # the whole trace as single-patch UPDATEs on one row (lz4), in 26 slices for progress
    "${PSQL[@]}" -c "create table bench.trace_lz4 (id int primary key, s crdt.yseq compression lz4 not null)" \
                 -c "insert into bench.trace_lz4 values (1, crdt.yseq_empty())" \
                 -c "create table bench.slices (slice int, chars int, us numeric, wal numeric)"
    for k in $(seq 0 25); do
        lo=$((k * 10000)); hi=$(((k + 1) * 10000))
        "${PSQL[@]}" -tA -c "select case when (p->>1)::int > 0 then format('update bench.trace_lz4 set s = crdt.yseq_delete(s, %s, %s, ''paper'') where id = 1;', p->>0, p->>1)
                                   else format('update bench.trace_lz4 set s = crdt.yseq_insert(s, %s, %L, ''paper'') where id = 1;', p->>0, p->>2) end
                              from bench.patches where n > $lo and n <= $hi order by n" > "$WORK/slice.sql"
        cnt=$(wc -l < "$WORK/slice.sql")
        "${PSQL[@]}" <<SQL
select pg_current_wal_insert_lsn() as l0, extract(epoch from clock_timestamp()) as t0 \gset
\i $WORK/slice.sql
select pg_current_wal_insert_lsn() as l1, extract(epoch from clock_timestamp()) as t1 \gset
insert into bench.slices select $k, (select crdt.yseq_length(s) from bench.trace_lz4), (:t1 - :t0) * 1e6 / $cnt, pg_wal_lsn_diff(:'l1', :'l0') / $cnt;
SQL
    done
    echo "### The whole trace, one UPDATE per patch (lz4 column; us and WAL bytes per patch, per slice of 10,000 patches)"
    echo
    "${PSQL[@]}" -P footer=off <<'SQL'
select slice * 10000 + 1 as from_patch, chars as chars_after, round(us) as us_per_patch, round(wal) as wal_per_patch from bench.slices order by slice;
select round(sum(us * case when slice = 25 then 9778 else 10000 end) / 1e6) as total_s,
       round(sum(us * case when slice = 25 then 9778 else 10000 end) / 259778) as mean_us_per_patch,
       pg_size_pretty(sum(wal * case when slice = 25 then 9778 else 10000 end)) as total_wal
from bench.slices;
select crdt.yseq_length(s) as final_chars, pg_column_size(s) as stored_bytes from bench.trace_lz4;
SQL
    exit 0
fi

echo "### Building the documents"
echo
t0=$(date +%s)
"${PSQL[@]}" <<'SQL'
select setseed(0.3);
-- trace prefixes: about 1k, 10k and the whole trace (104,852 characters)
insert into bench.docs values (1, '1k (trace)', bench.replay(1400)), (2, '10k (trace)', bench.replay(15000));
SQL
"${PSQL[@]}" -tA <<'SQL'
select clock_timestamp() as t0 \gset
insert into bench.docs values (3, '100k (trace)', bench.replay(1000000));
select format('Full trace replayed in memory (259,778 patches, yseq_insert/yseq_delete in a PL/pgSQL loop, no table writes): %s s, %s us per patch',
              round(extract(epoch from clock_timestamp() - :'t0'::timestamptz), 1),
              round(extract(epoch from clock_timestamp() - :'t0'::timestamptz) * 1e6 / 259778));
SQL
if [ $QUICK = 0 ]; then
    "${PSQL[@]}" <<'SQL'
select setseed(0.4);
-- 1M: ten copies of the trace's final text pasted at once, then 20,000 random edits
insert into bench.docs
select 4, '1M (paste + 20k edits)', bench.diverge(crdt.yseq_insert(crdt.yseq_empty(), 0, repeat(crdt.yseq_value(s), 10), 'paste'), 'edit', 20000)
from bench.docs where id = 3;
SQL
fi
"${PSQL[@]}" <<'SQL'
insert into bench.docs_lz4 select id, s::text::jsonb::crdt.yseq from bench.docs;
insert into bench.plain select id, crdt.yseq_value(s) from bench.docs;
-- pristine copies: every measurement starts from these
create table bench.orig as select * from bench.docs;
create table bench.orig_plain as select * from bench.plain;
analyze bench.docs;
SQL
echo "Built in $(( $(date +%s) - t0 )) s"
echo

echo "### Documents and storage"
echo
"${PSQL[@]}" -P footer=off <<'SQL'
select d.label as document,
       crdt.yseq_length(d.s) as chars,
       (select sum((length(x) - length(replace(x, ',', '')) + 1) / 7) from jsonb_array_elements_text(d.s -> 'm') x) as runs,
       jsonb_array_length(d.s -> 'm') as chunks,
       octet_length(p.t) as text_bytes,
       pg_column_size(p.t) as plain_stored,
       octet_length(d.s::text) as state_json_bytes,
       pg_column_size(d.s) as stored_pglz,
       pg_column_size(l.s) as stored_lz4,
       round(pg_column_size(d.s)::numeric / octet_length(p.t), 2) as pglz_vs_text
from bench.docs d join bench.plain p using (id) join bench.docs_lz4 l using (id)
order by id;
SQL
echo

echo "### Function latency, in memory (ms per call, best of 3; the state already detoasted)"
echo
"${PSQL[@]}" -P footer=off <<'SQL'
select label as document,
       bench.ms(format('select crdt.yseq_insert($1, %s, ''x'', ''bench'')', crdt.yseq_length(s) / 2), s, 50) as "insert 1",
       bench.ms(format('select crdt.yseq_delete($1, %s, 1, ''bench'')', crdt.yseq_length(s) / 2), s, 50) as "delete 1",
       bench.ms(format('select crdt.yseq_insert($1, %s, repeat(''p'', 1000), ''bench'')', crdt.yseq_length(s) / 3), s, 20) as "paste 1k",
       bench.ms(format('select crdt.yseq_set($1, %L, ''bench'')',
                       overlay(crdt.yseq_value(s) placing repeat('Q', 300) from crdt.yseq_length(s) / 2 for 280)), s, 10) as "set (1 paragraph)",
       bench.ms('select crdt.yseq_value($1)', s, 50) as "value",
       bench.ms('select crdt.yseq_length($1)', s, 50) as "length",
       bench.ms(format('select crdt.yseq_apply($1, %L, ''zz'')', jsonb_build_object('v', crdt.yseq_version(s), 'i', jsonb_build_array(jsonb_build_array('zz', 1, null,
                jsonb_build_array(s -> 'r' ->> (((s #>> '{m,0}')::int[])[1] - 1), ((s #>> '{m,0}')::int[])[2]), 'x')))), s, 10) as "apply 1 run",
       bench.ms(format('select crdt.yseq_apply($1, %L, ''zz'')', jsonb_build_object('v', crdt.yseq_version(s) || jsonb_build_object('paper', (crdt.yseq_version(s) ->> 'paper')::int - 1), 'i', jsonb_build_array(jsonb_build_array('zz', 1, null,
                jsonb_build_array(s -> 'r' ->> (((s #>> '{m,0}')::int[])[1] - 1), ((s #>> '{m,0}')::int[])[2]), 'x')))), s, 10) as "apply 1 run (sender behind: V3 scan)",
       bench.ms('select crdt.yseq_ops_since($1, crdt.yseq_version($1))', s, 5) as "ops_since (none)",
       bench.ms('select crdt.yseq_ops_since($1, ''{}'')', s, 3) as "ops_since (all)"
from (select label, (s::jsonb || '{}')::crdt.yseq s, id from bench.docs) d
order by id;
SQL
echo

# Edits as table updates: K statements, each its own transaction, after a CHECKPOINT.
measure() {  # label metric shape script K [table id]: resets the row from bench.orig first
    local label=$1 metric=$2 shape=$3 script=$4 k=$5
    if [ -n "${6:-}" ]; then
        if [ "$6" = plain ]; then
            "${PSQL[@]}" -c "update bench.plain set t = (select t from bench.orig_plain where id = $7) where id = $7"
        else
            "${PSQL[@]}" -c "update bench.$6 set s = (select s from bench.orig where id = $7) where id = $7"
        fi
    fi
    "${PSQL[@]}" -c checkpoint
    "${PSQL[@]}" <<SQL
select pg_current_wal_insert_lsn() as l0, extract(epoch from clock_timestamp()) as t0 \gset
\i $script
select pg_current_wal_insert_lsn() as l1, extract(epoch from clock_timestamp()) as t1 \gset
insert into bench.res values ('$label', '$metric', '$shape', (:t1 - :t0) * 1e6 / $k, pg_wal_lsn_diff(:'l1', :'l0') / $k);
SQL
}

ids="1 2 3"
[ $QUICK = 0 ] && ids="1 2 3 4"
for id in $ids; do
    label=$("${PSQL[@]}" -tA -c "select label from bench.orig where id = $id")
    len=$("${PSQL[@]}" -tA -c "select crdt.yseq_length(s) from bench.docs where id = $id")
    K=200; [ "$id" = 4 ] && K=40
    for tbl in docs docs_lz4; do
        shape="yseq ($([ $tbl = docs ] && echo pglz || echo lz4))"
        "${PSQL[@]}" -tA -c "select setseed(0.5)" -c "select format('update bench.$tbl set s = crdt.yseq_insert(s, %s, ''x'', ''bench'') where id = $id;', floor(random() * ($len - $K))::int) from generate_series(1, $K)" > "$WORK/ins.sql"
        measure "$label" "insert 1 char" "$shape" "$WORK/ins.sql" $K $tbl $id
        "${PSQL[@]}" -tA -c "select format('update bench.$tbl set s = crdt.yseq_delete(s, %s, 1, ''bench'') where id = $id;', floor(random() * ($len - $K))::int) from generate_series(1, $K)" > "$WORK/del.sql"
        measure "$label" "delete 1 char" "$shape" "$WORK/del.sql" $K $tbl $id
        "${PSQL[@]}" -tA -c "select format('update bench.$tbl set s = crdt.yseq_insert(s, %s, repeat(''p'', 1000), ''bench'') where id = $id;', floor(random() * $len)::int) from generate_series(1, $K / 4)" > "$WORK/paste.sql"
        measure "$label" "paste 1k" "$shape" "$WORK/paste.sql" $((K / 4)) $tbl $id
        # set(): a chain of texts, each one 300-character paragraph different from the last
        "${PSQL[@]}" -c "update bench.$tbl set s = (select s from bench.orig where id = $id) where id = $id"
        "${PSQL[@]}" <<SQL
drop table if exists bench.texts;
create table bench.texts as
with recursive c(i, t) as (
    select 0, crdt.yseq_value(s) from bench.$tbl where id = $id
    union all
    select i + 1, overlay(t placing repeat(chr(65 + i % 26), 300) from (1 + floor(random() * (length(t) - 300)))::int for 300)
    from c where i < $K / 4
)
select i, t from c where i > 0;
SQL
        "${PSQL[@]}" -tA -c "select format('update bench.$tbl set s = crdt.yseq_set(s, (select t from bench.texts where i = %s), ''bench'') where id = $id;', i) from generate_series(1, $K / 4) i" > "$WORK/set.sql"
        measure "$label" "set (1 paragraph)" "$shape" "$WORK/set.sql" $((K / 4)) $tbl $id
    done
    "${PSQL[@]}" -tA -c "select format('update bench.plain set t = overlay(t placing ''x'' from %s for 0) where id = $id;', 1 + floor(random() * ($len - $K))::int) from generate_series(1, $K)" > "$WORK/plain.sql"
    measure "$label" "insert 1 char" "plain text" "$WORK/plain.sql" $K plain $id
done

echo "### Edits as table updates (one statement per transaction; us per statement as the client sees it, WAL bytes per statement)"
echo
"${PSQL[@]}" -P footer=off <<'SQL'
select label as document, metric, shape, round(us) as us_per_edit, round(wal) as wal_bytes_per_edit
from bench.res
order by (select id from bench.docs d where d.label = res.label), metric, shape;
SQL
echo

echo "### Read latency: SELECT of the text from the table (ms, best of 3 runs of 20, detoast included)"
echo
"${PSQL[@]}" -P footer=off <<'SQL'
create function bench.read_ms(q text) returns numeric language plpgsql as $$
declare
    t0 timestamptz;
    best numeric;
    x int;
begin
    for k in 1..3 loop
        t0 := clock_timestamp();
        for i in 1..20 loop
            execute q into x;
        end loop;
        best := least(best, extract(epoch from clock_timestamp() - t0) * 1000 / 20);
    end loop;
    return round(best, 3);
end;
$$;
select d.label as document,
       bench.read_ms(format('select length(crdt.yseq_value(s)) from bench.docs where id = %s', d.id)) as "yseq_value (pglz)",
       bench.read_ms(format('select length(crdt.yseq_value(s)) from bench.docs_lz4 where id = %s', d.id)) as "yseq_value (lz4)",
       bench.read_ms(format('select length(t) from bench.plain where id = %s', d.id)) as "plain text column"
from bench.docs d order by id;
SQL
"${PSQL[@]}" <<'SQL'
update bench.docs d set s = o.s from bench.orig o where o.id = d.id;
update bench.docs_lz4 d set s = o.s from bench.orig o where o.id = d.id;
update bench.plain d set t = o.t from bench.orig_plain o where o.id = d.id;
SQL
echo

echo "### Merge of two replicas that diverged by N concurrent edits each (ms, in memory)"
echo
"${PSQL[@]}" -P footer=off <<SQL
select setseed(0.6);
create table bench.diverged as
select d.id, d.label, n, bench.diverge(d.s, 'ra', n) a, bench.diverge(d.s, 'rb', n) b
from bench.orig d, (values (100), (1000)) v(n)
where d.id <= 3 or n = 100;
create function bench.merge_ms(a crdt.yseq, b crdt.yseq) returns numeric language plpgsql as \$\$
declare
    t0 timestamptz;
    best numeric;
    m crdt.yseq;
begin
    a := (a::jsonb || '{}')::crdt.yseq;
    b := (b::jsonb || '{}')::crdt.yseq;
    for k in 1..3 loop
        t0 := clock_timestamp();
        m := crdt.yseq_merge(a, b);
        best := least(best, extract(epoch from clock_timestamp() - t0) * 1000);
    end loop;
    return round(best, 1);
end;
\$\$;
select label as document, n as "edits each", crdt.yseq_length(a) as chars,
       bench.merge_ms(a, b) as "merge(a, b) ms",
       jsonb_array_length(crdt.yseq_ops_since(b, crdt.yseq_version(a)) -> 'i') as "runs only in b",
       crdt._yseq_normalize(crdt.yseq_merge(a, b)) = crdt._yseq_normalize(crdt.yseq_merge(b, a)) as "merge(a,b) = merge(b,a)"
from bench.diverged order by id, n;
SQL
echo

echo "### Trace replay in a table row (automerge-paper, 259,778 patches, final 104,852 characters)"
echo
N1=10000; [ $QUICK = 1 ] && N1=2000
"${PSQL[@]}" -c "create table bench.trace (id int primary key, s crdt.yseq not null)" \
             -c "create table bench.trace_lz4 (id int primary key, s crdt.yseq compression lz4 not null)" \
             -c "insert into bench.trace values (1, crdt.yseq_empty())" -c "insert into bench.trace_lz4 values (1, crdt.yseq_empty())"
"${PSQL[@]}" -tA -c "select case when (p->>1)::int > 0 then format('update bench.trace set s = crdt.yseq_delete(s, %s, %s, ''paper'') where id = 1;', p->>0, p->>1)
                               else format('update bench.trace set s = crdt.yseq_insert(s, %s, %L, ''paper'') where id = 1;', p->>0, p->>2) end
                          from bench.patches where n <= $N1 order by n" > "$WORK/trace.sql"
measure "trace" "first $N1 patches, one UPDATE each" "yseq (pglz)" "$WORK/trace.sql" $N1
sed 's/bench.trace /bench.trace_lz4 /' "$WORK/trace.sql" > "$WORK/trace_lz4.sql"
measure "trace" "first $N1 patches, one UPDATE each" "yseq (lz4)" "$WORK/trace_lz4.sql" $N1
# the last 2,000 patches, from the state after the first 257,778
"${PSQL[@]}" -c "update bench.trace set s = bench.replay(257778) where id = 1" -c "update bench.trace_lz4 set s = (select s from bench.trace where id = 1) where id = 1"
"${PSQL[@]}" -tA -c "select case when (p->>1)::int > 0 then format('update bench.trace set s = crdt.yseq_delete(s, %s, %s, ''paper'') where id = 1;', p->>0, p->>1)
                               else format('update bench.trace set s = crdt.yseq_insert(s, %s, %L, ''paper'') where id = 1;', p->>0, p->>2) end
                          from bench.patches where n > 257778 order by n" > "$WORK/trace_end.sql"
measure "trace" "last 2000 patches, one UPDATE each" "yseq (pglz)" "$WORK/trace_end.sql" 2000
sed 's/bench.trace /bench.trace_lz4 /' "$WORK/trace_end.sql" > "$WORK/trace_end_lz4.sql"
measure "trace" "last 2000 patches, one UPDATE each" "yseq (lz4)" "$WORK/trace_end_lz4.sql" 2000
"${PSQL[@]}" -tA -c "select (select crdt.yseq_value(s) from bench.trace where id = 1) = (select t from bench.orig_plain where id = 3)" > "$WORK/trace_ok"
# batched: the batch100 ops (100 patches each) through yseq_apply
"${PSQL[@]}" -c "update bench.trace set s = crdt.yseq_empty() where id = 1" -c "update bench.trace_lz4 set s = crdt.yseq_empty() where id = 1"
"${PSQL[@]}" -tA -c "select format('update bench.trace set s = crdt.yseq_apply(s, %L, ''paper'') where id = 1;', op) from bench.batch100 order by n" > "$WORK/batch.sql"
NB=$("${PSQL[@]}" -tA -c "select count(*) from bench.batch100")
measure "trace" "batch100: $NB yseq_apply calls of 100 patches" "yseq (pglz)" "$WORK/batch.sql" "$NB"
sed 's/bench.trace /bench.trace_lz4 /' "$WORK/batch.sql" > "$WORK/batch_lz4.sql"
measure "trace" "batch100: $NB yseq_apply calls of 100 patches" "yseq (lz4)" "$WORK/batch_lz4.sql" "$NB"
"${PSQL[@]}" -tA -c "select (select crdt.yseq_value(s) from bench.trace where id = 1) = (select t from bench.orig_plain where id = 3)" >> "$WORK/trace_ok"

"${PSQL[@]}" -P footer=off <<'SQL'
select metric, shape, round(us) as us_per_statement, round(wal) as wal_bytes_per_statement
from bench.res where label = 'trace' order by metric, shape;
SQL
echo
echo "Final text equals the trace's endContent: last-2000 replay $(sed -n 1p "$WORK/trace_ok"), batch100 replay $(sed -n 2p "$WORK/trace_ok")"
