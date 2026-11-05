-- Goal: the local editing API. create, insert, delete, value, length,
-- version; positions in code points (non-BMP characters count as one); the
-- ops each edit returns; errors for bad positions, null and malformed replicas,
-- and missing documents.
\i :ext_dir/test/lib/text-helpers.sql

select crdt.ydoc_create() as d \gset
select crdt.ydoc_insert(:'d', 0, 'Hello', 'alice') as op1 \gset
select crdt.ydoc_insert(:'d', 5, ' world', 'alice') as op2 \gset
select crdt.ydoc_insert(:'d', 5, ',', 'bob') as op3 \gset
select crdt.ydoc_delete(:'d', 0, 1, 'bob') as op4 \gset
select crdt.ydoc_insert(:'d', 0, 'J', 'bob') as op5 \gset

select crdt.ydoc_create() as u \gset
select crdt.ydoc_insert(:'u', 0, 'a😀b', 'alice') \g /dev/null
select crdt.ydoc_insert(:'u', 2, '🎉', 'bob') \g /dev/null
select crdt.ydoc_insert(:'u', 1, 'é', 'carol') \g /dev/null
select crdt.ydoc_delete(:'u', 2, 1, 'carol') \g /dev/null

select crdt.ydoc_create() as e \gset
select pg_temp.did(:'e') as eid \gset

select tap.plan(30);
select tap.is(crdt.ydoc_value(:'d'), 'Jello, world', 'inserts and deletes by position');
select tap.is(crdt.ydoc_length(:'d'), 12, 'length');
select tap.is(pg_temp.ydoc_check(:'d'), '', 'invariants hold');
select tap.is(:'op1'::jsonb, '{"v": {}, "i": [["alice", 1, null, null, "Hello"]], "d": []}', 'first insert op: no origins, v = the version before the op');
select tap.is(:'op2'::jsonb, '{"v": {"alice": 5}, "i": [["alice", 6, ["alice", 5], null, " world"]], "d": []}', 'append: originLeft is the last char, typing on extends the run');
select tap.is(:'op3'::jsonb, '{"v": {"alice": 11}, "i": [["bob", 1, ["alice", 5], ["alice", 6], ","]], "d": []}', 'insert inside a run: both origins');
select tap.is(:'op4'::jsonb, '{"v": {"alice": 11, "bob": 1}, "i": [], "d": [["alice", 1, 1]]}', 'delete op names the ids');
select tap.is(:'op5'::jsonb, '{"v": {"alice": 11, "bob": 1}, "i": [["bob", 2, null, ["alice", 1], "J"]], "d": []}', 'insert at 0 after a deleted first char: originRight is the tombstone');
select tap.is(crdt.ydoc_version(:'d'), '{"alice": 11, "bob": 2}'::jsonb, 'version vector');
select tap.is((select count(*)::int from crdt.ydoc_items where doc = pg_temp.did(:'d') and replica = crdt._ydoc_rid(pg_temp.did(:'d'), 'alice')), 3, 'alice''s run split in three rows (deleted H, ello, world)');
select tap.is(crdt.ydoc_value(:'u'), 'aé🎉b', 'non-BMP characters count as one position');
select tap.is(crdt.ydoc_length(:'u'), 4, 'length in code points');
select tap.is(pg_temp.ydoc_check(:'u'), '', 'invariants hold (unicode)');
select tap.is(crdt.ydoc_value(:'e'), '', 'empty document');
select tap.is(crdt.ydoc_version(:'e'), '{}'::jsonb, 'empty version');
select tap.is(crdt.ydoc_value('nodoc'), null, 'value of a missing document is null');
select tap.is(crdt.ydoc_insert(:'e', 0, '', 'alice'), '{"v": {}, "i": [], "d": []}'::jsonb, 'empty insert is a no-op');
select tap.is(crdt.ydoc_delete(:'d', 3, 0, 'alice') - 'v', '{"i": [], "d": []}'::jsonb, 'zero-length delete is a no-op');
select tap.throws_ok(format('select crdt.ydoc_insert(%L, 13, %L, %L)', :'d', 'x', 'alice'), '22023', 'insert past the end');
select tap.throws_ok(format('select crdt.ydoc_insert(%L, -1, %L, %L)', :'d', 'x', 'alice'), '22023', 'negative position');
select tap.throws_ok(format('select crdt.ydoc_delete(%L, 10, 3, %L)', :'d', 'alice'), '22023', 'delete past the end');
select tap.throws_ok(format('select crdt.ydoc_insert(%L, 0, %L, null)', :'d', 'x'), '22004', 'null replica');
select tap.throws_ok(format('select crdt.ydoc_insert(%L, 0, %L, %L)', :'d', 'x', 'alice:'), '22023', 'malformed replica key');
select tap.throws_ok(format('select crdt.ydoc_insert(%L, 0, null, %L)', :'d', 'alice'), '22004', 'null text');
select tap.throws_ok(format('select crdt.ydoc_insert(%L, 0, %L, %L)', 'nodoc', 'x', 'alice'), 'P0002', 'missing document');
select tap.lives_ok(format('select crdt.ydoc_insert(%L, 0, %L, %L)', :'e', 'x', 'alice:phone'), 'a device key can write');
select tap.is(crdt.ydoc_version(:'e'), '{"alice:phone": 1}'::jsonb, 'ids carry the device key');
select tap.lives_ok(format('select crdt.ydoc_drop(%L)', :'e'), 'drop');
select tap.is((select count(*)::int from crdt.ydoc_items where doc = :eid) + (select count(*)::int from crdt.ydoc_docs where id = :eid), 0, 'drop removes rows');
select tap.is(crdt.ydoc_ops_since(:'d', crdt.ydoc_version(:'d')), '{"i": [], "d": [["alice", 1, 1]]}'::jsonb, 'ops_since at the current version: no inserts, all deletes');

select * from tap.finish();
