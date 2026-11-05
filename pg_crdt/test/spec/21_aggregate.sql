-- Goal: crdt.pn_merge_agg over a delta table equals folding pn_merge over the
-- same rows, in any order, serially and in a parallel plan (where its combine
-- function merges partial states). This is the read side of the insert-only
-- delta-table storage shape (architecture.md section 4).
\ir ../fixtures/gen.sql

select setseed(0.5);
-- 40 counters, 4,000 random deltas (about 1.5 p and 0.5 n entries each, from 10 replicas).
create table deltas (id bigserial primary key, counter int not null, d crdt.pn not null);
insert into deltas (counter, d)
select 1 + floor(random() * 40)::int,
       jsonb_build_object('t', 'pn', 'v', 1,
                          'p', spec.rand_map(10, 0.15),
                          'n', spec.rand_map(10, 0.05))
from generate_series(1, 4000);
analyze deltas;

create temp table by_agg as
select counter, crdt.pn_merge_agg(d) as s from deltas group by counter;
create temp table by_fold as
select counter, spec.fold_merge(array_agg(d order by id)) as s from deltas group by counter;
create temp table by_agg_shuffled as
select counter, crdt.pn_merge_agg(d order by random()) as s from deltas group by counter;
-- An independent oracle: per-key max over every delta row with one GROUP BY.
create temp table by_groupby as
select counter,
       jsonb_build_object('t', 'pn', 'v', 1,
           'p', coalesce(jsonb_object_agg(key, mx) filter (where map = 'p'), '{}'),
           'n', coalesce(jsonb_object_agg(key, mx) filter (where map = 'n'), '{}')) as s
from (select counter, m.map, e.key, max(e.value::bigint) as mx
      from deltas, lateral (values ('p'), ('n')) m(map), lateral jsonb_each(d -> m.map) e
      group by 1, 2, 3) x
group by counter;

-- A parallel plan: partial aggregates in workers, combined with pn_merge.
create function pg_temp.explain_json(q text) returns json language plpgsql as $$
declare
    j json;
begin
    execute 'explain (analyze, format json) ' || q into j;
    return j;
end;
$$;

\set agg_query 'select string_agg(counter || ''='' || s::text, '';'' order by counter) from (select counter, crdt.pn_merge_agg(d) as s from deltas group by counter) x'

set max_parallel_workers_per_gather = 0;
select (:agg_query) as serial_result \gset

set max_parallel_workers_per_gather = 4;
set parallel_setup_cost = 0;
set parallel_tuple_cost = 0;
set min_parallel_table_scan_size = 0;
set parallel_leader_participation = off;
select pg_temp.explain_json(:'agg_query')::text as par_plan \gset
select (:agg_query) as parallel_result \gset
reset all;

select tap.plan(10);

select tap.is((select count(*)::int from by_agg), 40, 'pn_merge_agg ran for 40 counters');
select tap.is((select count(*)::int from by_agg a join by_fold f using (counter) where a.s::jsonb is distinct from f.s::jsonb), 0,
              'pn_merge_agg equals folding pn_merge in id order, 40 counters');
select tap.is((select count(*)::int from by_agg a join by_agg_shuffled f using (counter) where a.s::jsonb is distinct from f.s::jsonb), 0,
              'pn_merge_agg in shuffled order gives the same states');
select tap.is((select count(*)::int from by_agg a join by_groupby g using (counter) where a.s::jsonb is distinct from g.s), 0,
              'pn_merge_agg equals a per-key max over all delta rows (one GROUP BY)');
select tap.is((select count(*)::int from by_agg a where crdt.pn_value(a.s) is distinct from
                  (select sum(v) from (select (x.s -> 'p' ->> k)::bigint as v from by_groupby x, jsonb_object_keys(x.s -> 'p') k where x.counter = a.counter
                                       union all
                                       select -(x.s -> 'n' ->> k)::bigint from by_groupby x, jsonb_object_keys(x.s -> 'n') k where x.counter = a.counter) y)),
              0, 'and the values agree');

select tap.ok(:'par_plan' like '%"Partial Mode": "Partial"%' and :'par_plan' ~ '"Workers Launched": [1-9]',
              'the parallel plan runs partial pn_merge_agg aggregates in workers');
select tap.is(:'parallel_result'::text, :'serial_result'::text,
              'the parallel plan (combine function = pn_merge) gives the same states as the serial plan');

select tap.is((select crdt.pn_merge_agg(d) from deltas where false), null::crdt.pn,
              'pn_merge_agg over no rows is null (like sum)');
select tap.is((select crdt.pn_merge_agg(x)::jsonb from (values (null::crdt.pn), ('{"t": "pn", "v": 1, "p": {"a": 2}, "n": {}}'), (null)) v(x)),
              '{"t": "pn", "v": 1, "p": {"a": 2}, "n": {}}'::jsonb, 'pn_merge_agg skips null states');
select tap.is((select crdt.pn_value(crdt.pn_merge_agg(d)) from deltas where counter = 1),
              (select crdt.pn_value(s) from by_fold where counter = 1),
              'pn_value(pn_merge_agg(d)) reads a counter from its delta rows');

select * from tap.finish();
