-- Goal: differential tests on a real editing trace (automerge-paper, from
-- josephg/editing-traces, converted by experiments/text-ref). The local API
-- generates exactly the ops the JS reference generated for the first 20,000
-- patches (same originLeft/originRight convention, same run extension; with
-- ydoc_compact every 2,000 patches, which must not change any op), the
-- reference's ops merged one by one give the same text, and the whole trace
-- in 2,598 batched ops (100 patches each) gives the trace's final text. The
-- reference's ops also pass the untrusted path's causal rules.
-- The trace files are generated (gitignored); without them this file SKIPs.
\set trace_dir :exp_dir/../text-ref/traces
select (pg_stat_file(:'trace_dir' || '/automerge-paper.batch100.jsonl', true)).size is not null as has_trace \gset

\if :has_trace
create temp table patches (n bigserial primary key, p jsonb);
create temp table ops (n bigserial primary key, op jsonb);
create temp table batch (n bigserial primary key, op jsonb);
select format($c$copy patches (p) from %L with (format csv, delimiter E'\x01', quote E'\x02')$c$, :'trace_dir' || '/automerge-paper.patches.jsonl') as c1,
       format($c$copy ops (op) from %L with (format csv, delimiter E'\x01', quote E'\x02')$c$, :'trace_dir' || '/automerge-paper.ops.jsonl') as c2,
       format($c$copy batch (op) from %L with (format csv, delimiter E'\x01', quote E'\x02')$c$, :'trace_dir' || '/automerge-paper.batch100.jsonl') as c3 \gset
:c1;
:c2;
:c3;
delete from patches where n > 20000;
delete from ops where n > 20000;

select crdt.ydoc_create() as a, crdt.ydoc_create() as b, crdt.ydoc_create() as c, crdt.ydoc_create() as u \gset
create temp table mismatch (n bigint, got jsonb, want jsonb);
select set_config('ydoc.a', :'a', false), set_config('ydoc.b', :'b', false), set_config('ydoc.c', :'c', false) \g /dev/null
do $$
declare
    r record;
    op jsonb;
    d bigint := current_setting('ydoc.a')::bigint;
begin
    for r in select p.n, p.p, o.op as want from patches p join ops o using (n) order by n loop
        if (r.p ->> 1)::int > 0 then op := crdt.ydoc_delete(d, (r.p ->> 0)::int, (r.p ->> 1)::int, 'paper');
        else op := crdt.ydoc_insert(d, (r.p ->> 0)::int, r.p ->> 2, 'paper'); end if;
        if op <> r.want then insert into mismatch values (r.n, op, r.want); end if;
        if r.n % 2000 = 0 then perform crdt.ydoc_compact(d); end if;
    end loop;
end $$;
do $$
declare r record; d bigint := current_setting('ydoc.b')::bigint;
begin
    for r in select op from ops order by n loop perform crdt.ydoc_merge(d, r.op); end loop;
end $$;
do $$
declare r record; d bigint := current_setting('ydoc.c')::bigint;
begin
    for r in select op from batch order by n loop perform crdt.ydoc_merge(d, r.op); end loop;
end $$;

create temp table ust (s text);
select set_config('ydoc.u', :'u', false) \g /dev/null
do $$
declare r record; d bigint := current_setting('ydoc.u')::bigint;
begin
    for r in select op from ops order by n loop insert into ust values (crdt.ydoc_apply(d, r.op, 'paper')); end loop;
end $$;

select tap.plan(6);
select tap.is((select count(*)::int from patches), 20000, '20,000 patches loaded');
select tap.is((select count(*)::int from mismatch), 0, 'local insert/delete by position, compacted every 2,000 patches: every op (v, i, d) equals the reference''s op');
select tap.is(crdt.ydoc_value(:b), crdt.ydoc_value(:a), 'the reference''s ops merged one by one give the same text');
select tap.is((select string_agg(distinct s, ',') from ust), 'accepted', 'the reference''s ops through the untrusted path (ydoc_apply, rules V0-V7): all accepted');
select tap.is(crdt.ydoc_value(:u), crdt.ydoc_value(:a), 'and give the same text');
select tap.is(md5(crdt.ydoc_value(:c)), 'f6ee9cff45a87f3b7f29d60920bfce10', 'the whole trace (batched ops) gives the trace''s final text (104,852 chars)');
\else
\echo '# trace files missing (run experiments/text-ref/regen-traces.sh); NOT tested'
select tap.plan(1);
select tap.pass('SKIP trace files not generated');
\endif

select * from tap.finish();
