-- Goal: differential tests against the JS reference (experiments/text-ref),
-- on the trusted path (ydoc_merge).
-- Each fixture is a set of ops from several replicas and the text the
-- reference produces. Every fixture must give exactly that text when its ops
-- are merged:
--   1. one by one in a shuffled order with duplicates (needs buffering),
--   2. one by one in causal order,
--   3. all in one ydoc_merge call (runs in array order),
--   4. shuffled again, with ydoc_compact after every 5 ops,
-- and the document must round-trip through ydoc_ops_since into a fresh one
-- with nothing left buffered (ops_since is causal).
\i :exp_dir/test/lib/helpers.sql
\set QUIET on
\i :exp_dir/../text-ref/fixtures/fixtures.sql
\set QUIET off

create temp table runs (name text, mode text, doc bigint);
-- The reference now validates untrusted ops (the "v" rules). ydoc_merge is
-- the trusted path: "v" is ignored, and the ops the reference rejects
-- (listed by position, only in malicious-* fixtures) are left out; the
-- expected text excludes them.
create temp table fx as
select f.name, f.expected,
       coalesce((select jsonb_agg(o.op order by o.n) from jsonb_array_elements(f.ops) with ordinality o(op, n)
                 where not f.rejected @> to_jsonb(o.n - 1)), '[]') as ops,
       coalesce((select jsonb_agg(o.op order by o.n) from jsonb_array_elements(f.ops_causal) with ordinality o(op, n)
                 where not f.rejected_causal @> to_jsonb(o.n - 1)), '[]') as ops_causal
from text_fixtures f;

do $$
declare
    f record;
    d bigint;
begin
    for f in select * from fx order by name loop
        d := crdt.ydoc_create();
        perform pg_temp.merge_all(d, f.ops);
        insert into runs values (f.name, 'shuffled', d);

        -- shuffled, with ydoc_compact (horizon = now) after every 5 ops
        d := crdt.ydoc_create();
        for k in 1 .. jsonb_array_length(f.ops) loop
            perform crdt.ydoc_merge(d, f.ops -> (k - 1));
            if k % 5 = 0 then perform crdt.ydoc_compact(d); end if;
        end loop;
        insert into runs values (f.name, 'compacted', d);

        d := crdt.ydoc_create();
        perform pg_temp.merge_all(d, f.ops_causal);
        insert into runs values (f.name, 'causal', d);

        d := crdt.ydoc_create();
        perform crdt.ydoc_merge(d, jsonb_build_object(
            'i', coalesce((select jsonb_agg(r order by o.n, r.n) from jsonb_array_elements(f.ops) with ordinality o(op, n),
                                  jsonb_array_elements(o.op -> 'i') with ordinality r(r, n)), '[]'),
            'd', coalesce((select jsonb_agg(r order by o.n, r.n) from jsonb_array_elements(f.ops) with ordinality o(op, n),
                                  jsonb_array_elements(o.op -> 'd') with ordinality r(r, n)), '[]')));
        insert into runs values (f.name, 'one batch', d);
    end loop;
    -- round trip of the shuffled documents
    for f in select r.name, r.doc from runs r where r.mode = 'shuffled' loop
        d := crdt.ydoc_create();
        perform crdt.ydoc_merge(d, crdt.ydoc_ops_since(f.doc, '{}'));
        insert into runs values (f.name, 'ops_since', d);
    end loop;
end;
$$;

select tap.plan(9);
select tap.is((select count(*)::int from text_fixtures), 71, 'all 71 fixtures loaded (57 honest, 14 malicious with their rejected ops left out)');
select tap.is((select string_agg(r.name, ', ') from runs r join fx f using (name)
               where r.mode = 'shuffled' and crdt.ydoc_value(r.doc) is distinct from f.expected), null,
              'shuffled delivery with duplicates: every fixture equals the reference');
select tap.is((select string_agg(r.name, ', ') from runs r join fx f using (name)
               where r.mode = 'compacted' and crdt.ydoc_value(r.doc) is distinct from f.expected), null,
              'shuffled delivery with ydoc_compact every 5 ops: every fixture equals the reference');
select tap.is((select string_agg(r.name, ', ') from runs r join fx f using (name)
               where r.mode = 'causal' and crdt.ydoc_value(r.doc) is distinct from f.expected), null,
              'causal delivery: every fixture equals the reference');
select tap.is((select string_agg(r.name, ', ') from runs r join fx f using (name)
               where r.mode = 'one batch' and crdt.ydoc_value(r.doc) is distinct from f.expected), null,
              'all ops in one call: every fixture equals the reference');
select tap.is((select string_agg(r.name, ', ') from runs r join fx f using (name)
               where r.mode = 'ops_since' and crdt.ydoc_value(r.doc) is distinct from f.expected), null,
              'ops_since round trip into a fresh document: every fixture equals the reference');
select tap.is((select count(*)::int from crdt.ydoc_pending), 0, 'nothing left buffered (inserts)');
select tap.is((select count(*)::int from crdt.ydoc_pending p join runs r on r.doc = p.doc where r.mode = 'ops_since'), 0,
              'nothing buffered after applying ops_since output');
select tap.is((select string_agg(r.name || '/' || r.mode || ': ' || pg_temp.ydoc_check(r.doc), '; ') from runs r
               where pg_temp.ydoc_check(r.doc) <> ''), null, 'invariants hold in every document');

select * from tap.finish();
