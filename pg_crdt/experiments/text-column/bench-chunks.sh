#!/usr/bin/env bash
# Chunk size sweep for yseq_: the same documents re-chunked with
# crdt._yseq_cmax() = 16 .. 1,000,000 (the last is one chunk: the flat
# representation). Prints a Markdown table for NOTES.md.
#
#   experiments/text-column/bench-chunks.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(cd "$HERE/../.." && pwd)
TRACES="$EXT_DIR/experiments/text-ref/traces"
. "$EXT_DIR/test/lib/cluster.sh"
[ -f "$TRACES/automerge-paper.patches.jsonl" ] || { echo "error: run experiments/text-ref/regen-traces.sh" >&2; exit 2; }

export PGCLIENTENCODING=UTF8
start_cluster
DB=yseq_chunks
psql_admin -c "drop database if exists $DB" -c "create database $DB encoding 'UTF8' template template0"
PSQL=("$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -d "$DB")
"${PSQL[@]}" -f "$EXT_DIR/pg_crdt--0.0.1.sql" -f "$HERE/impl.sql"

echo "Postgres: $("${PSQL[@]}" -tA -c 'show server_version'), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
echo

"${PSQL[@]}" <<SQL
create schema bench;
create table bench.patches (n bigint generated always as identity primary key, p jsonb not null);
\copy bench.patches (p) from '$TRACES/automerge-paper.patches.jsonl' with (format csv, quote e'\x01', delimiter e'\x02')
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
create table bench.base as select 10 as id, bench.replay(15000) s union all select 100, bench.replay(1000000);
create table bench.res (chunk_max int, doc int, runs int, chunks int, json_bytes int, replay_40k_s numeric,
                        ins numeric, del numeric, set1 numeric, apply1 numeric, value numeric);
SQL

for c in 16 32 64 128 256 1024 1000000; do
    "${PSQL[@]}" <<SQL
create or replace function crdt._yseq_cmax() returns int language sql immutable parallel safe return $c;
select clock_timestamp() as t0 \gset
select bench.replay(40000) is not null as ok \gset
select extract(epoch from clock_timestamp() - :'t0'::timestamptz) as replay \gset
insert into bench.res
select $c, id,
       (select sum((length(x) - length(replace(x, ',', '')) + 1) / 7) from jsonb_array_elements_text(n.s -> 'm') x),
       jsonb_array_length(n.s -> 'm'),
       octet_length(n.s::text),
       round(:replay, 1),
       bench.ms(format('select crdt.yseq_insert(\$1, %s, ''x'', ''b'')', crdt.yseq_length(n.s) / 2), n.s, 30),
       bench.ms(format('select crdt.yseq_delete(\$1, %s, 1, ''b'')', crdt.yseq_length(n.s) / 2), n.s, 30),
       bench.ms(format('select crdt.yseq_set(\$1, %L, ''b'')', overlay(crdt.yseq_value(n.s) placing 'QQQ' from crdt.yseq_length(n.s) / 2 for 3)), n.s, 10),
       bench.ms('select crdt.yseq_apply(\$1, ''{"i": [["zz", 1, null, null, "x"]]}'', ''zz'')', n.s, 5),
       bench.ms('select crdt.yseq_value(\$1)', n.s, 30)
from (select id, crdt._yseq_normalize(s) s from bench.base) n;
SQL
done

echo "### Chunk size (crdt._yseq_cmax()); in-memory ms per call on the trace documents"
echo
"${PSQL[@]}" -P footer=off <<'SQL'
select case when chunk_max = 1000000 then 'flat (one chunk)' else chunk_max::text end as "max runs per chunk",
       case doc when 10 then '10k (trace)' else '100k (trace)' end as document,
       chunks, json_bytes, ins as "insert 1", del as "delete 1", set1 as "set", apply1 as "apply 1 run", value,
       replay_40k_s as "replay first 40k patches (s)"
from bench.res order by doc, chunk_max;
SQL
