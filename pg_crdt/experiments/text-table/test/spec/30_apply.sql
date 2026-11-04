-- Goal: ydoc_apply, the write path for untrusted writers. Inserts must carry
-- the writer's own ids (its replica id or <id>:<device>); deletes may target
-- anyone's characters; malformed ops are 22023, a missing or forged identity
-- 42501; re-applying is a no-op; inserts whose origins are missing wait, and
-- deletes of unseen ids apply when the insert arrives. Then the deployment
-- model: no table privileges for clients, an app-owned SECURITY DEFINER
-- wrapper that checks access and passes the identity.
\i :exp_dir/test/lib/helpers.sql

select crdt.ydoc_create() as d \gset
select crdt.ydoc_apply(:d, '{"i": [["alice", 1, null, null, "Hello"]], "d": []}', 'alice');
select crdt.ydoc_apply(:d, '{"i": [["alice:phone", 1, ["alice", 5], null, "!"]]}', 'alice');
select crdt.ydoc_apply(:d, '{"d": [["alice", 1, 1]]}', 'bob');
select crdt.ydoc_value(:d) as v1 \gset
select crdt.ydoc_apply(:d, '{"i": [["alice", 1, null, null, "Hello"]], "d": [["alice", 1, 1]]}', 'alice');
select crdt.ydoc_value(:d) as v2, crdt.ydoc_version(:d) as vv2 \gset
set crdt.replica_id = 'carol';
select crdt.ydoc_apply(:d, '{"i": [["carol", 1, ["alice", 3], ["alice", 4], "L"]]}');
reset crdt.replica_id;

-- buffering: carol 3 depends on carol 2 (missing); dave's insert names an
-- origin that has not arrived; a delete of dave's unseen ids.
select crdt.ydoc_create() as b \gset
select crdt.ydoc_merge(:b, '{"i": [["carol", 3, ["carol", 2], null, "Z"]]}');
select crdt.ydoc_merge(:b, '{"d": [["dave", 2, 2]]}');
select crdt.ydoc_merge(:b, '{"i": [["dave", 1, ["carol", 1], null, "wxyz"]]}');
select crdt.ydoc_value(:b) as b1, (select count(*) from crdt.ydoc_pending where doc = :b) as pend1 \gset
select crdt.ydoc_merge(:b, '{"i": [["carol", 1, null, null, "AB"]]}');
select crdt.ydoc_value(:b) as b2, (select count(*) from crdt.ydoc_pending where doc = :b) as pend2,
       (select count(*) from crdt.ydoc_pending_deletes where doc = :b) as pdel2 \gset
-- partial overlap with what is integrated: only the new tail is added
select crdt.ydoc_merge(:b, '{"i": [["carol", 2, ["carol", 1], null, "BZQ"]]}');

select tap.plan(27);
select tap.is(:'v1'::text, 'ello!', 'own inserts (id and device key), a delete of another replica''s char');
select tap.is(:'v2'::text, 'ello!', 're-applying an insert and a delete: no change');
select tap.is(:'vv2'::jsonb, '{"alice": 5, "alice:phone": 1}', 'version unchanged by the re-apply');
select tap.is(crdt.ydoc_value(:d), 'elLlo!', 'identity from crdt.current_replica_id() (the crdt.replica_id setting)');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '{"i": [["alice", 9, null, null, "x"]]}', 'bob'), '42501', 'forged insert (another replica''s id): 42501');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '{"i": [["alicex", 1, null, null, "x"]]}', 'alice'), '42501', 'owner compared exactly: alice cannot write alicex');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L)', :d, '{"i": [["alice", 9, null, null, "x"]]}'), '42501', 'no identity: 42501');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '{"i": []}', 'a:b'), '22023', 'a replica id with ":": 22023');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '[]', 'alice'), '22023', 'ops not an object');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '{"i": [], "x": 1}', 'alice'), '22023', 'unknown key');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '{"i": [["alice", 0, null, null, "x"]]}', 'alice'), '22023', 'seq 0');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '{"i": [["alice", 1.5, null, null, "x"]]}', 'alice'), '22023', 'fractional seq');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '{"i": [["alice", 7, null, null, ""]]}', 'alice'), '22023', 'empty text');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '{"i": [["alice", 7, ["bob"], null, "x"]]}', 'alice'), '22023', 'malformed origin');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '{"i": [["alice", 7, ["alice", 7], null, "x"]]}', 'alice'), '22023', 'origin is the run itself');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '{"i": [["alice", 7, null, null, 5]]}', 'alice'), '22023', 'text not a string');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '{"i": [["alice", 2147483647, null, null, "xy"]]}', 'alice'), '22023', 'ids past the integer range');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '{"d": [["alice", 1]]}', 'alice'), '22023', 'malformed delete');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '{"d": [["alice", 1, 0]]}', 'alice'), '22023', 'zero-length delete');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :d, '{"i": [["alice", 6, ["alice", 5], ["alice", 2], "x"]]}', 'alice'), '22023', 'originRight before originLeft');
select tap.is(:'b1'::text, '', 'inserts with missing origins or predecessor wait');
select tap.is(:'pend1'::int, 2, 'two runs buffered');
select tap.is(:'b2'::text, 'ABZwz', 'when the origins arrive the buffered runs integrate, and the early delete applies');
select tap.is(:'pend2'::int + :'pdel2'::int, 0, 'buffers empty');
select tap.is(crdt.ydoc_value(:b), 'ABZQwz', 'a run overlapping integrated ids adds only its new tail');
select tap.is(pg_temp.ydoc_check(:b) || pg_temp.ydoc_check(:d), '', 'invariants hold');
select tap.is(crdt.ydoc_ops_since(:b, '{"carol": 2}'),
              '{"d": [["dave", 2, 2]], "i": [["carol", 3, ["carol", 2], null, "ZQ"], ["dave", 1, ["carol", 1], null, "wxyz"]]}'::jsonb,
              'ops_since: inserts above the version in integration order, split rows joined into runs, and the deletes');

select * from tap.finish();
