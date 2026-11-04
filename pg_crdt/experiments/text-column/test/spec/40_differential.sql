-- Goal: the same ops give the same text as the JS reference
-- (experiments/text-ref/ref.mjs, YjsMod checked against reference-crdts).
-- Fixtures: experiments/text-ref/fixtures/fixtures.sql, table
-- text_fixtures(name, ops, ops_causal, expected): fuzzed multi-replica
-- sessions, unicode and case-sensitive replica ids (collate "C" order), a
-- non-interleaving case, empty and delete-all. For every fixture:
--   1. ops one per yseq_apply call, in the fixture's shuffled order with its
--      duplicates (inserts wait for their origins, deletes for their ids);
--   2. ops_causal one per call;
--   3. all ops in one call;
--   4. the ops split in two halves, applied to two states, then merged;
--   5. the result's ops_since({}) replayed into an empty state;
--   each equal to the expected text, with nothing pending.
-- Without the fixture file the file passes with a SKIP assertion.

\set fixtures :exp_dir/../text-ref/fixtures/fixtures.sql
select (pg_stat_file(:'fixtures', true)).size is not null as has_fixtures \gset

\if :has_fixtures
set client_min_messages = warning;
\i :fixtures

-- the writer of an op: the replica of its insert runs (deletes may come from anyone)
create function pg_temp.owner(op jsonb) returns text language sql immutable as $$
    select coalesce(split_part(op -> 'i' -> 0 ->> 0, ':', 1), 'anyone')
$$;

create function pg_temp.apply_each(ops jsonb) returns crdt.yseq language plpgsql as $$
declare
    s crdt.yseq := crdt.yseq_empty();
    op jsonb;
begin
    for op in select x from jsonb_array_elements(ops) with ordinality a(x, o) order by o loop
        s := crdt.yseq_apply(s, op, pg_temp.owner(op));
    end loop;
    return s;
end;
$$;

create table results as
select f.name, f.expected,
       crdt.yseq_value(e.s1) as each_text, e.s1 -> 'p' as each_pending,
       crdt.yseq_value(pg_temp.apply_each(f.ops_causal)) as causal_text,
       crdt.yseq_value(crdt._yseq_integrate(crdt.yseq_empty(),
           (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(f.ops) op, jsonb_array_elements(op -> 'i') x),
           (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(f.ops) op, jsonb_array_elements(op -> 'd') x))) as batch_text,
       crdt.yseq_value(crdt.yseq_merge(
           pg_temp.apply_each((select coalesce(jsonb_agg(x order by o), '[]') from jsonb_array_elements(f.ops) with ordinality a(x, o) where o % 2 = 0)),
           pg_temp.apply_each((select coalesce(jsonb_agg(x order by o), '[]') from jsonb_array_elements(f.ops) with ordinality a(x, o) where o % 2 = 1)))) as merge_text,
       crdt.yseq_value(crdt._yseq_integrate(crdt.yseq_empty(), crdt.yseq_ops_since(e.s1) -> 'i', crdt.yseq_ops_since(e.s1) -> 'd')) as resync_text,
       crdt.yseq_is_valid(e.s1) as valid
from text_fixtures f, lateral (select pg_temp.apply_each(f.ops) as s1) e;

select tap.plan(7);
select tap.ok(count(*) >= 50, 'fixtures loaded: ' || count(*)) from results;
select tap.ok(bool_and(each_text = expected and each_pending = '[]'),
              'shuffled ops with duplicates, one per call: expected text, nothing pending'
              || coalesce(' (failing: ' || string_agg(name, ', ') filter (where each_text <> expected or each_pending <> '[]') || ')', ''))
from results;
select tap.ok(bool_and(causal_text = expected), 'ops_causal one per call: expected text'
              || coalesce(' (failing: ' || string_agg(name, ', ') filter (where causal_text <> expected) || ')', '')) from results;
select tap.ok(bool_and(batch_text = expected), 'all ops in one call: expected text'
              || coalesce(' (failing: ' || string_agg(name, ', ') filter (where batch_text <> expected) || ')', '')) from results;
select tap.ok(bool_and(merge_text = expected), 'two halves applied separately, then merged: expected text'
              || coalesce(' (failing: ' || string_agg(name, ', ') filter (where merge_text <> expected) || ')', '')) from results;
select tap.ok(bool_and(resync_text = expected), 'ops_since({}) replayed into an empty state: expected text'
              || coalesce(' (failing: ' || string_agg(name, ', ') filter (where resync_text <> expected) || ')', '')) from results;
select tap.ok(bool_and(valid), 'every result passes yseq_is_valid') from results;
select format('# %s: got %s want %s', name, left(each_text, 80), left(expected, 80)) from results where each_text <> expected limit 3;
\else
\echo '# experiments/text-ref/fixtures/fixtures.sql not found; differential tests were NOT run'
select tap.plan(1);
select tap.pass('SKIP fixtures not available');
\endif

select * from tap.finish();
