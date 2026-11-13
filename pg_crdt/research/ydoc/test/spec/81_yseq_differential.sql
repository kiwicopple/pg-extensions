-- Goal: the same ops give the same text and the same decisions as the JS
-- reference (experiments/text-ref/ref.mjs, YjsMod checked against
-- reference-crdts; validated path per research/text.md, Amendment 1).
-- Fixtures: experiments/text-ref/fixtures/fixtures.sql, table
-- text_fixtures(name, ops, ops_causal, rejected, rejected_causal, expected):
-- fuzzed multi-replica sessions, unicode and case-sensitive replica ids,
-- non-interleaving, empty, delete-all, and malicious-* (untrusted ops that
-- break the causal rules V1 to V6). For every fixture:
--   1. ops one per yseq_apply call (validated), in the fixture's shuffled
--      order with its duplicates: expected text, nothing waiting; every op
--      that raised 22023 is in `rejected`, and every op in `rejected` raised
--      or waited first (it is then decided in a later call, silently);
--   2. ops_causal one per call: expected text, and the ops that raised are
--      exactly `rejected_causal` (in causal order nothing waits);
--   3. the ops split in two halves, each half validated into its own state,
--      then the two states merged (trusted): expected text;
--   4. the result's ops_since({}) replayed through the trusted path into an
--      empty state: expected text;
--   5. honest fixtures only: all ops in one trusted call: expected text.
-- Without the fixture file the file passes with a SKIP assertion.

\set fixtures :ext_dir/../../experiments/text-ref/fixtures/fixtures.sql
select (pg_stat_file(:'fixtures', true)).size is not null as has_fixtures \gset

\if :has_fixtures
set client_min_messages = warning;
\i :fixtures

-- the writer of an op: the replica of its insert runs (deletes may come from anyone)
create function pg_temp.owner(op jsonb) returns text language sql immutable as $$
    select coalesce(split_part(op -> 'i' -> 0 ->> 0, ':', 1), 'anyone')
$$;

-- apply ops one per call; returns the state, the 0-based positions that
-- raised 22023, and the positions that waited at least once
create function pg_temp.apply_each(ops jsonb, out s crdt.yseq, out raised int[], out waited int[]) language plpgsql as $$
declare
    op jsonb;
    pos int;
begin
    s := crdt.yseq_empty();
    raised := '{}';
    waited := '{}';
    for op, pos in select x, o::int - 1 from jsonb_array_elements(ops) with ordinality a(x, o) order by o loop
        begin
            s := crdt.yseq_apply(s, op, pg_temp.owner(op));
            if s -> 'q' @> jsonb_build_array(jsonb_build_array(pg_temp.owner(op), op)) then
                waited := waited || pos;
            end if;
        exception when sqlstate '22023' then
            raised := raised || pos;
        end;
    end loop;
end;
$$;

create table results as
select f.name, f.expected,
       crdt.yseq_value(e.s) as each_text, e.s -> 'q' as each_waiting, e.s -> 'p' as each_pending,
       e.raised <@ array(select jsonb_array_elements_text(f.rejected)::int)
         and array(select jsonb_array_elements_text(f.rejected)::int) <@ (e.raised || e.waited) as each_decisions,
       crdt.yseq_value(c.s) as causal_text,
       c.raised::text = array(select jsonb_array_elements_text(f.rejected_causal)::int order by 1)::text as causal_decisions,
       crdt.yseq_value(crdt.yseq_merge(
           (pg_temp.apply_each((select coalesce(jsonb_agg(x order by o), '[]') from jsonb_array_elements(f.ops_causal) with ordinality a(x, o) where o % 2 = 0))).s,
           (pg_temp.apply_each((select coalesce(jsonb_agg(x order by o), '[]') from jsonb_array_elements(f.ops_causal) with ordinality a(x, o) where o % 2 = 1))).s)) as merge_text,
       crdt.yseq_value(crdt._yseq_integrate(crdt.yseq_empty(), crdt.yseq_ops_since(e.s) -> 'i', crdt.yseq_ops_since(e.s) -> 'd')) as resync_text,
       case when f.name like 'malicious%' then f.expected
            else crdt.yseq_value(crdt._yseq_integrate(crdt.yseq_empty(),
                (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(f.ops) op, jsonb_array_elements(op -> 'i') x),
                (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(f.ops) op, jsonb_array_elements(op -> 'd') x))) end as batch_text,
       crdt.yseq_is_valid(e.s) as valid
from text_fixtures f,
     lateral pg_temp.apply_each(f.ops) e,
     lateral pg_temp.apply_each(f.ops_causal) c;

select tap.plan(10);
select tap.ok(count(*) >= 70 and count(*) filter (where name like 'malicious%') >= 14,
              format('fixtures loaded: %s (%s malicious)', count(*), count(*) filter (where name like 'malicious%'))) from results;
select tap.ok(bool_and(each_text = expected and each_waiting = '[]' and each_pending = '[]'),
              'validated, shuffled with duplicates, one op per call: expected text, nothing waiting'
              || coalesce(' (failing: ' || string_agg(name, ', ') filter (where not (each_text = expected and each_waiting = '[]' and each_pending = '[]')) || ')', ''))
from results;
select tap.ok(bool_and(each_decisions), 'and the decisions match `rejected`'
              || coalesce(' (failing: ' || string_agg(name, ', ') filter (where not each_decisions) || ')', '')) from results;
select tap.ok(bool_and(causal_text = expected), 'validated, causal order: expected text'
              || coalesce(' (failing: ' || string_agg(name, ', ') filter (where causal_text <> expected) || ')', '')) from results;
select tap.ok(bool_and(causal_decisions), 'and the ops that raised are exactly `rejected_causal`'
              || coalesce(' (failing: ' || string_agg(name, ', ') filter (where not causal_decisions) || ')', '')) from results;
select tap.ok(bool_and(merge_text = expected), 'two halves validated separately, then merged (trusted): expected text'
              || coalesce(' (failing: ' || string_agg(name, ', ') filter (where merge_text <> expected) || ')', '')) from results;
select tap.ok(bool_and(resync_text = expected), 'ops_since({}) replayed on the trusted path: expected text'
              || coalesce(' (failing: ' || string_agg(name, ', ') filter (where resync_text <> expected) || ')', '')) from results;
select tap.ok(bool_and(batch_text = expected), 'honest fixtures, all ops in one trusted call: expected text'
              || coalesce(' (failing: ' || string_agg(name, ', ') filter (where batch_text <> expected) || ')', '')) from results;
select tap.ok(bool_and(valid), 'every result passes yseq_is_valid') from results;
select tap.ok((select count(*) from results where name like 'malicious%' and each_decisions and causal_decisions and each_text = expected)
              = (select count(*) from results where name like 'malicious%'), 'every malicious fixture: right text and right decisions');
select format('# %s: got %s want %s', name, left(each_text, 80), left(expected, 80)) from results where each_text <> expected limit 3;
\else
\echo '# experiments/text-ref/fixtures/fixtures.sql not found; differential tests were NOT run'
select tap.plan(1);
select tap.pass('SKIP fixtures not available');
\endif

select * from tap.finish();
