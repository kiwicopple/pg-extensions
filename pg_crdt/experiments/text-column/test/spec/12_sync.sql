-- Goal: sync out (research/text.md): yseq_version, yseq_ops_since with a
-- version vector, yseq_diff as the op of a local edit, and YjsMod's
-- non-interleaving of concurrent runs typed at the same place.

select tap.plan(20);

select crdt.yseq_insert(crdt.yseq_empty(), 0, 'XY', 'base') as base \gset

-- two writers type four characters each, one keystroke at a time, at the same spot
create function pg_temp.type(s crdt.yseq, pos int, t text, r text) returns crdt.yseq language plpgsql as $$
begin
    for i in 1..length(t) loop
        s := crdt.yseq_insert(s, pos + i - 1, substr(t, i, 1), r);
    end loop;
    return s;
end;
$$;
select pg_temp.type(:'base', 1, 'aaaa', 'alice') as a, pg_temp.type(:'base', 1, 'bbbb', 'bob') as b \gset
select tap.is(crdt.yseq_value(crdt.yseq_merge(:'a', :'b')), 'XaaaabbbbY', 'concurrent typing at one spot does not interleave');
select tap.is(crdt.yseq_value(crdt.yseq_merge(:'b', :'a')), 'XaaaabbbbY', 'in either merge order (alice < bob, collate "C")');
select tap.is(crdt.yseq_value(crdt.yseq_merge(pg_temp.type(:'base', 1, 'aaaa', 'zed'), :'b')), 'XbbbbaaaaY', 'the lower replica id goes first');
select tap.is(crdt.yseq_value(crdt.yseq_merge(pg_temp.type(:'base', 1, 'aaaa', 'B'), pg_temp.type(:'base', 1, 'bbbb', 'a'))), 'XaaaabbbbY',
              '"B" < "a" in collate "C"');
select tap.is(crdt.yseq_ops_since(:'a', crdt.yseq_version(:'base')) -> 'i', '[["alice", 1, ["base", 1], ["base", 2], "aaaa"]]'::jsonb,
              'four keystrokes are one run on the wire');

-- ops_since with version vectors
select crdt.yseq_merge(:'a', :'b') as ab \gset
select tap.is(crdt.yseq_version(:'ab'), '{"base": 2, "alice": 4, "bob": 4}'::jsonb, 'version of the merge');
select tap.is(crdt.yseq_ops_since(:'ab', '{"base": 2, "alice": 4, "bob": 4}') -> 'i', '[]'::jsonb, 'nothing to send to an up-to-date replica');
select tap.is(crdt.yseq_ops_since(:'ab', '{"base": 2, "alice": 2, "bob": 4}') -> 'i', '[["alice", 3, ["alice", 2], ["base", 2], "aa"]]'::jsonb,
              'a replica with alice 1..2 gets alice 3..4, origin rewritten to the previous character');
select tap.is(jsonb_array_length(crdt.yseq_ops_since(:'ab', null) -> 'i'), 3, 'a null version vector means everything');
select tap.throws_ok(format('select crdt.yseq_ops_since(%L, %L)', :'ab', '{"alice": -1}'), '22023', 'a negative count is rejected: 22023');
select tap.throws_ok(format('select crdt.yseq_ops_since(%L, %L)', :'ab', '[1]'), '22023', 'a non-object version vector is rejected: 22023');
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'b', crdt.yseq_ops_since(:'ab', crdt.yseq_version(:'b')), 'alice')), 'XaaaabbbbY',
              'ops_since(state, version(other)) brings the other replica up to date');

-- deletes travel as a delete set
select crdt.yseq_delete(:'ab', 2, 4, 'bob') as abd \gset
select tap.is(crdt.yseq_ops_since(:'abd', crdt.yseq_version(:'ab')), '{"i": [], "d": [["alice", 2, 3], ["bob", 1, 1]]}'::jsonb,
              'ops_since sends the whole delete set');
select tap.is(crdt.yseq_diff(:'abd', crdt.yseq_delete(:'abd', 0, 1, 'bob')), '{"i": [], "d": [["base", 1, 1]]}'::jsonb,
              'yseq_diff sends only the new deletes');
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'b', crdt.yseq_ops_since(:'abd', crdt.yseq_version(:'b')), 'alice')), crdt.yseq_value(:'abd'),
              'a replica that applies them sees the deletes');

-- causal order of ops_since: a fresh state applies it in one pass without pending
select crdt.yseq_merge(pg_temp.type(:'ab', 0, 'qq', 'carol'), pg_temp.type(:'ab', 9, 'rr', 'dave')) as abcd \gset
select pg_temp.type(:'abcd', 3, 'zz', 'erin') as abcde \gset
select tap.ok(bool_and(ok), 'ops_since is causally ordered: every run''s origins come in earlier runs')
from (select r.o, (r.x -> 2 = 'null' or exists (select 1 from jsonb_array_elements(crdt.yseq_ops_since(:'abcde') -> 'i') with ordinality e(y, o2)
                                               where o2 < r.o and y ->> 0 = r.x -> 2 ->> 0
                                                 and (r.x -> 2 ->> 1)::int between (y ->> 1)::int and (y ->> 1)::int + length(y ->> 4) - 1))
            and (r.x -> 3 = 'null' or exists (select 1 from jsonb_array_elements(crdt.yseq_ops_since(:'abcde') -> 'i') with ordinality e(y, o2)
                                               where o2 < r.o and y ->> 0 = r.x -> 3 ->> 0
                                                 and (r.x -> 3 ->> 1)::int between (y ->> 1)::int and (y ->> 1)::int + length(y ->> 4) - 1)) ok
      from jsonb_array_elements(crdt.yseq_ops_since(:'abcde') -> 'i') with ordinality r(x, o)) z;
-- three-way set: two editors load the same version, change different
-- paragraphs, and both save (the second with the version it loaded as base)
select crdt.yseq_insert(crdt.yseq_empty(), 0, E'First paragraph.\nSecond paragraph.\nThird paragraph.', 'author') as doc0 \gset
select crdt.yseq_set(:'doc0', E'First paragraph, edited by A.\nSecond paragraph.\nThird paragraph.', 'a', base => :'doc0') as doc1 \gset
select crdt.yseq_set(:'doc1', E'First paragraph.\nSecond paragraph.\nThird paragraph, edited by B.', 'b', base => :'doc0') as doc2 \gset
select tap.is(crdt.yseq_value(:'doc2'), E'First paragraph, edited by A.\nSecond paragraph.\nThird paragraph, edited by B.',
              'two editors, same base, different paragraphs: both edits survive');
select tap.is(crdt.yseq_value(crdt.yseq_set(:'doc1', E'First paragraph.\nSecond paragraph.\nThird paragraph, edited by B.', 'b')),
              E'First paragraph.\nSecond paragraph.\nThird paragraph, edited by B.',
              'without base the second save is last-writer-wins for the whole text');
-- a delete next to an append
select crdt.yseq_set(:'doc0', E'First paragraph.\nSecond paragraph.\nThird paragraph.\nFourth.', 'a', base => :'doc0') as doc3 \gset
select tap.is(crdt.yseq_value(crdt.yseq_set(:'doc3', E'First paragraph.\nSecond paragraph.\nThird.', 'b', base => :'doc0')),
              E'First paragraph.\nSecond paragraph.\nThird.\nFourth.', 'a delete right before another editor''s append keeps the append');
-- two inserts at one spot do not interleave
select crdt.yseq_set(:'doc0', E'First paragraph.\nAAAA\nSecond paragraph.\nThird paragraph.', 'a', base => :'doc0') as doc4 \gset
select tap.is(crdt.yseq_value(crdt.yseq_set(:'doc4', E'First paragraph.\nBBBB\nSecond paragraph.\nThird paragraph.', 'b', base => :'doc0')),
              E'First paragraph.\nAAAA\nBBBB\nSecond paragraph.\nThird paragraph.', 'two saves inserting at one spot: both, not interleaved');
select * from tap.finish();
