-- Goal: regressions for the bugs the adversarial review found in the
-- sibling ydoc_, checked against yseq_:
--   (a) replica keys are capped (256 bytes; 32 keys per writer);
--   (b) runs that continue each other cost O(1) each in validation, and an
--       op carries at most 128 runs once those are joined;
--   (c) a waiting op that would fail with another error is dropped, and
--       does not break later calls;
--   (d) the op of a three-way save, after two saves from one base and a
--       concurrent edit by another writer, passes validation on a peer;
--   (e) every PL/pgSQL yseq function pins search_path;
--   (f) a base from another document is refused (22023), and so is a merge
--       of two documents with different ids;
--   (g) positions and lengths near 2^31 are 22023.

select tap.plan(22);

-- (a)
select tap.throws_ok(format('select crdt.yseq_apply(crdt.yseq_empty(), %L, %L)',
    jsonb_build_object('v', '{}'::jsonb, 'i', jsonb_build_array(jsonb_build_array(repeat('k', 6000), 1, null, null, 'x'))), repeat('k', 6000)),
    '22023', 'a 6,000-byte replica id is refused');
select tap.throws_ok(format('select crdt.yseq_apply(crdt.yseq_empty(), %L, %L)',
    jsonb_build_object('v', '{}'::jsonb, 'i', jsonb_build_array(jsonb_build_array('mal:' || repeat('d', 2000), 1, null, null, 'x'))), 'mal'),
    '22023', 'a 2,000-byte device key is refused');
select tap.throws_ok(format('select crdt.yseq_apply(crdt.yseq_empty(), %L, %L)',
    jsonb_build_object('v', jsonb_build_object(repeat('z', 300), 1), 'i', '[]'::jsonb, 'd', '[]'::jsonb), 'mal'),
    '22023', 'a 300-byte key in v is refused');
select tap.throws_ok(format('select crdt.yseq_insert(crdt.yseq_empty(), 0, %L, %L)', 'x', repeat('k', 300)), '22023', 'local edits: a 300-byte replica key is refused');
select tap.throws_ok(format('select crdt.yseq_apply(crdt.yseq_empty(), %L, %L)',
    (select jsonb_agg(jsonb_build_object('v', '{}'::jsonb, 'i', jsonb_build_array(jsonb_build_array('mal:d' || g, 1, null, null, 'x')))) from generate_series(1, 33) g), 'mal'),
    '54000', '33 device keys of one writer: 54000');
select tap.lives_ok(format('select crdt.yseq_apply(crdt.yseq_empty(), %L, %L)',
    (select jsonb_agg(jsonb_build_object('v', '{}'::jsonb, 'i', jsonb_build_array(jsonb_build_array('mal:d' || g, 1, null, null, 'x')))) from generate_series(1, 32) g), 'mal'),
    '32 device keys are allowed');

-- (b) a document of about 10,000 runs, then 3,000 chained one-character runs in one op
select setseed(0.2);
create function pg_temp.mk(n int) returns crdt.yseq language plpgsql as $$
declare
    s crdt.yseq := crdt.yseq_insert(crdt.yseq_empty(), 0, repeat('a', 2000), 'a');
begin
    for i in 1..n loop
        s := crdt.yseq_insert(s, floor(random() * crdt.yseq_length(s))::int, 'b', 'a');
    end loop;
    return s;
end;
$$;
select pg_temp.mk(8000) as many \gset
select clock_timestamp() as t0 \gset
select crdt.yseq_apply(:'many', jsonb_build_object('v', '{}'::jsonb, 'i', (
    select jsonb_agg(jsonb_build_array('A', g, case when g = 1 then null else jsonb_build_array('A', g - 1) end, null, 'x') order by g)
    from generate_series(1, 3000) g)), 'A') as chained \gset
select extract(epoch from clock_timestamp() - :'t0'::timestamptz) as chained_s \gset
select tap.is(crdt.yseq_length(:'chained'), 13000, '3,000 chained one-character runs in one op are accepted');
select tap.ok(:chained_s < 1, format('in %s s (O(runs x slots) took 2.3 s for 2,000 runs)', round(:chained_s::numeric, 2)));
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'many', jsonb_build_object('v', '{}'::jsonb, 'i', (
    select jsonb_agg(jsonb_build_array('A', g, case when g = 1 then null else jsonb_build_array('A', g - 1) end, case when g % 2 = 0 then null else jsonb_build_array('A', 1) end, 'x') order by g)
    from generate_series(1, 300) g)), 'A'), '22023', '300 runs that do not continue each other: more than 128, refused');

-- (c)
select crdt.yseq_insert(crdt.yseq_empty(), 0, 'abc', 'alice') as base3 \gset
select jsonb_set(:'base3'::jsonb, '{q}', '[["mal", {"v": {"x": 1}, "i": [["mal", 99999999999, null, null, "x"]]}],
                                           ["mal", {"v": {"x": 1}, "i": "junk"}],
                                           ["mal", {"v": {"x": 1}, "i": [["eve", 1, null, null, "x"]]}],
                                           [7, {"v": {"x": 1}}]]')::crdt.yseq as junkq \gset
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'junkq', '{"v": {"alice": 3}, "i": [["bob", 1, ["alice", 3], null, "!"]]}', 'bob')), 'abc!',
              'waiting ops that are malformed, overflow or forge a writer do not break a later apply');
select tap.is(crdt.yseq_apply(:'junkq', '{"v": {"alice": 3}, "i": [["bob", 1, ["alice", 3], null, "!"]]}', 'bob') -> 'q', '[]'::jsonb,
              'and they are dropped');
select tap.is(crdt.yseq_value(crdt.yseq_merge(crdt.yseq_empty(), :'junkq')), 'abc', 'nor a merge that carries them');

-- (d) two saves from one base by w, a concurrent edit by o on a peer
select crdt.yseq_insert(crdt.yseq_empty(), 0, E'one\ntwo\nthree', 'author') as d0 \gset
select crdt.yseq_set(:'d0', E'ONE\ntwo\nthree', 'w', base => :'d0') as srv1 \gset
select crdt.yseq_set(:'d0', E'one\ntwo\nthree!', 'o', base => :'d0') as o1 \gset
select crdt.yseq_merge(:'srv1', :'o1') as srv2 \gset
select crdt.yseq_set(:'srv2', E'ONE!\ntwo\nthree', 'w', base => :'d0') as srv3 \gset
select tap.is(crdt.yseq_value(:'srv3'), E'ONE!\ntwo\nthree!', 'server: w''s second save from the same base keeps o''s edit');
select crdt.yseq_merge(:'d0', :'o1') as peer \gset
select crdt.yseq_apply(:'peer', crdt.yseq_diff(:'d0', :'srv1'), 'w') as peer1 \gset
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'peer1', crdt.yseq_diff(:'srv2', :'srv3'), 'w')), E'ONE!\ntwo\nthree!',
              'peer: the op of w''s second save (yseq_diff) passes V3 and V5 and gives the same text');
select tap.lives_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'peer1', crdt.yseq_diff(:'srv2', :'srv3'), 'w'), 'and is not rejected');

-- (e)
select tap.is((select count(*) from pg_proc p join pg_language l on l.oid = p.prolang
               where p.pronamespace = 'crdt'::regnamespace and p.proname ~ '^_?yseq_' and l.lanname = 'plpgsql'
                 and not coalesce(p.proconfig @> array['search_path=pg_catalog, pg_temp'], false)), 0::bigint,
              'every PL/pgSQL yseq function pins search_path = pg_catalog, pg_temp');
select tap.ok((select count(*) from pg_proc p join pg_language l on l.oid = p.prolang
               where p.pronamespace = 'crdt'::regnamespace and p.proname ~ '^_?yseq_' and l.lanname = 'plpgsql') >= 15,
              'and there are such functions');

-- (f)
select crdt.yseq_set(crdt.yseq_new(), 'hello', 'alice') as da, crdt.yseq_set(crdt.yseq_new(), 'world', 'alice') as db \gset
select tap.throws_ok(format('select crdt.yseq_set(%L, %L, %L, base => %L)', :'db', 'help', 'zed', :'da'), '22023',
                     'a base from another document (different ids) is refused');
select tap.throws_ok(format('select crdt.yseq_merge(%L, %L)', :'da', :'db'), '22023', 'and so is a merge of different documents');
select tap.throws_ok(format('select crdt.yseq_set(%L, %L, %L, base => %L)', crdt.yseq_set(null, 'abc', 'alice'), 'abX', 'bob', crdt.yseq_set(null, 'abcdef', 'alice')), '22023',
                     'documents without ids: a base with characters the state lacks is refused');

-- (g)
select tap.throws_ok(format('select crdt.yseq_insert(%L, 2147483647, %L, %L)', :'base3', 'x', 'a'), '22023', 'insert at 2^31 - 1: 22023');
select tap.throws_ok(format('select crdt.yseq_delete(%L, 2147483647, 2147483647, %L)', :'base3', 'a'), '22023', 'delete of 2^31 - 1 at 2^31 - 1: 22023');
select * from tap.finish();
