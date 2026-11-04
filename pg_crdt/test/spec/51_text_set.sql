-- Goal: ydoc_set, the blessed path for a form or ORM save. The diff is the
-- common prefix and suffix, then one delete and one insert. Without base it
-- diffs against the current text (so a stale save reverts the region it
-- spans); with base (crdt.ydoc_base, read with the text) it diffs against the
-- text the editor started from, and concurrent saves to different
-- paragraphs both survive.
\i :ext_dir/test/lib/text-helpers.sql

select crdt.ydoc_create() as d \gset
select crdt.ydoc_set(:d, 'The quick brown fox', 'alice') as op1 \gset
select crdt.ydoc_set(:d, 'The quick red fox', 'bob') as op2 \gset
select crdt.ydoc_set(:d, 'The quick red fox', 'bob') as op3 \gset
select crdt.ydoc_set(:d, 'A quick red fox!', 'carol') \g /dev/null
select crdt.ydoc_value(:d) as v4 \gset
select crdt.ydoc_set(:d, '', 'carol') \g /dev/null
select crdt.ydoc_value(:d) as v5 \gset
select crdt.ydoc_set(:d, 'ça 😀 marche', 'alice') \g /dev/null
select crdt.ydoc_set(:d, 'ça 🎉🎉 marche', 'bob') as op6 \gset

-- Two editors read the same version, change different paragraphs, save.
select crdt.ydoc_create() as p \gset
select crdt.ydoc_set(:p, E'Para one.\nPara two.\nPara three.', 'alice') \g /dev/null
select crdt.ydoc_value(:p) as base_text, crdt.ydoc_base(:p) as base \gset
select crdt.ydoc_set(:p, E'Para ONE, edited.\nPara two.\nPara three.', 'alice', :'base') \g /dev/null
select crdt.ydoc_set(:p, E'Para one.\nPara two.\nPara three, edited.', 'bob', :'base') \g /dev/null
select crdt.ydoc_value(:p) as merged \gset
-- The same without base: bob's save reverts alice's paragraph.
select crdt.ydoc_create() as q \gset
select crdt.ydoc_set(:q, E'Para one.\nPara two.\nPara three.', 'alice') \g /dev/null
select crdt.ydoc_set(:q, E'Para ONE, edited.\nPara two.\nPara three.', 'alice') \g /dev/null
select crdt.ydoc_set(:q, E'Para one.\nPara two.\nPara three, edited.', 'bob') \g /dev/null
-- base: a delete by one editor and an edit next to it by another
select crdt.ydoc_create() as r \gset
select crdt.ydoc_set(:r, 'abc def ghi', 'alice') \g /dev/null
select crdt.ydoc_base(:r) as base2 \gset
select crdt.ydoc_set(:r, 'abc ghi', 'alice', :'base2') \g /dev/null
select crdt.ydoc_set(:r, 'abc def ghi jkl', 'bob', :'base2') \g /dev/null
-- base: both insert at the same place
select crdt.ydoc_create() as s \gset
select crdt.ydoc_set(:s, 'ab', 'x') \g /dev/null
select crdt.ydoc_base(:s) as base3 \gset
select crdt.ydoc_set(:s, 'a123b', 'bob', :'base3') \g /dev/null
select crdt.ydoc_set(:s, 'aXYZb', 'alice', :'base3') \g /dev/null

-- random targets from a multibyte alphabet whose characters share UTF-8
-- lead or continuation bytes (é è © ¨ 😀 😁): value always equals the target
select setseed(0.9);
create temp table setrun (ok boolean);
do $$
declare
    d bigint := crdt.ydoc_create();
    t text := '';
begin
    for i in 1..300 loop
        if random() < 0.5 and length(t) > 0 then
            t := overlay(t placing (select string_agg((array['é','è','©','¨','😀','😁','a'])[1 + floor(random() * 7)::int], '') from generate_series(1, floor(random() * 3)::int))
                         from 1 + floor(random() * length(t))::int for floor(random() * 3)::int);
        else
            t := (select string_agg((array['é','è','©','¨','😀','😁','a'])[1 + floor(random() * 7)::int], '') from generate_series(1, 1 + floor(random() * 12)::int));
        end if;
        t := coalesce(t, '');
        perform crdt.ydoc_set(d, t, 'r' || i % 3);
        insert into setrun values (crdt.ydoc_value(d) = t and crdt.ydoc_length(d) = length(t));
    end loop;
end $$;

select tap.plan(17);
select tap.is((select count(*)::int from setrun where not ok), 0, '300 random sets over multibyte characters: value equals the target');
select tap.is(:'op1'::jsonb, '{"v": {}, "i": [["alice", 1, null, null, "The quick brown fox"]], "d": []}', 'set on an empty doc: one insert');
select tap.is(:'op2'::jsonb, '{"v": {"alice": 19}, "i": [["bob", 1, ["alice", 10], ["alice", 11], "red"]], "d": [["alice", 11, 5]]}',
              'set: one delete and one insert in the middle (prefix and suffix kept)');
select tap.is(:'op3'::jsonb - 'v', '{"i": [], "d": []}', 'set to the same text: no ops');
select tap.is(:'v4'::text, 'A quick red fox!', 'set: change at both ends');
select tap.is(:'v5'::text, '', 'set to empty');
select tap.is(:'op6'::jsonb -> 'd', '[["alice", 23, 1]]'::jsonb, 'set: diff in code points (non-BMP)');
select tap.is(crdt.ydoc_value(:d), 'ça 🎉🎉 marche', 'set: unicode text');
select tap.is(pg_temp.ydoc_check(:d), '', 'invariants hold');
select tap.is(:'merged'::text, E'Para ONE, edited.\nPara two.\nPara three, edited.', 'with base: concurrent saves to different paragraphs both survive');
select tap.is(crdt.ydoc_value(:q), E'Para one.\nPara two.\nPara three, edited.', 'without base: the stale save reverts the other paragraph (documented)');
select tap.is(crdt.ydoc_value(:r), 'abc ghi jkl', 'with base: a delete and an append by two editors both survive');
select tap.is(crdt.ydoc_value(:s), 'aXYZ123b', 'with base: concurrent inserts at one place are not interleaved (alice < bob)');
select tap.is(pg_temp.ydoc_check(:p) || pg_temp.ydoc_check(:r) || pg_temp.ydoc_check(:s), '', 'invariants hold (base)');
select tap.throws_ok(format('select crdt.ydoc_set(%s, %L, %L, %L)', :p, 'x', 'alice', '{"g": 999, "v": {}}'), '22023', 'base from the future');
select tap.throws_ok(format('select crdt.ydoc_set(%s, %L, %L, %L)', :p, 'x', 'alice', '{"g": 1, "v": {"zed": 5}}'), '22023', 'base with ids the doc does not have');
select tap.throws_ok(format('select crdt.ydoc_set(%s, %L, %L, %L)', :p, 'x', 'alice', '[1]'), '22023', 'malformed base');

select * from tap.finish();
