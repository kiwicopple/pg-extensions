-- Goal: yseq_apply is safe for untrusted writers (research/text.md, "apply"),
-- like pn_apply_delta: inserts only with the caller's replica id or
-- <id>:<device>; deletes of anyone's characters; malformed ops 22023; null
-- or forged replica 42501; re-applying ops is a no-op; identity from
-- crdt.current_replica_id() by default. Also the function labels: no
-- SECURITY DEFINER, IMMUTABLE pure functions, apply pins search_path, and
-- nothing granted beyond EXECUTE.

select tap.plan(36);

select crdt.yseq_insert(crdt.yseq_empty(), 0, 'Hello', 'alice') as s \gset
select '{"i": [["bob", 1, ["alice", 5], null, "!"]], "d": []}' as bob_op \gset

-- owner rule
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'s', :'bob_op', 'bob')), 'Hello!', 'bob applies his own insert');
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'s', '{"i": [["bob:phone", 1, ["alice", 5], null, "?"]], "d": []}', 'bob')), 'Hello?',
              'bob applies an insert of his device key bob:phone');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', :'bob_op', 'mallory'), '42501', 'mallory cannot insert as bob: 42501');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', '{"i": [["bobby", 1, null, null, "x"]], "d": []}', 'bob'), '42501',
                     'bob cannot insert as bobby (owner compared exactly)');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', '{"i": [["bo", 1, null, null, "x"]], "d": []}', 'bob'), '42501',
                     'bob cannot insert as bo');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, null)', :'s', :'bob_op'), '42501', 'null replica: 42501');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', :'bob_op', 'bob:phone'), '22023', 'a caller id with ":" is not a replica id: 22023');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', :'bob_op', ''), '22023', 'empty caller id: 22023');
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'s', '{"i": [], "d": [["alice", 1, 2]]}', 'bob')), 'llo', 'bob may delete alice''s characters');
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'s', '[{"i": [["bob", 1, ["alice", 5], null, "!"]]}, {"d": [["alice", 1, 1]]}]', 'bob')), 'ello!',
              'an array of ops; missing "i" or "d" keys count as empty');

-- idempotent
select crdt.yseq_apply(:'s', :'bob_op', 'bob') as s2 \gset
select tap.is(crdt.yseq_apply(:'s2', :'bob_op', 'bob')::jsonb, :'s2'::jsonb, 're-applying an insert changes nothing');
select tap.is(crdt.yseq_apply(crdt.yseq_apply(:'s2', '{"i": [], "d": [["bob", 1, 1]]}', 'bob'), '{"i": [], "d": [["bob", 1, 1]]}', 'bob')::jsonb,
              crdt.yseq_apply(:'s2', '{"i": [], "d": [["bob", 1, 1]]}', 'bob')::jsonb, 're-applying a delete changes nothing');
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'s2', '{"i": [["bob", 1, ["alice", 5], null, "!?"]], "d": []}', 'bob')), 'Hello!?',
              'a run that overlaps applied ids integrates only the new end');

-- causal buffering
select crdt.yseq_apply(:'s', '{"i": [["bob", 2, ["bob", 1], null, "?"]], "d": [["bob", 2, 1], ["carol", 1, 1]]}', 'bob') as s3 \gset
select tap.is(crdt.yseq_value(:'s3'), 'Hello', 'an insert whose origin is missing waits');
select tap.is(jsonb_array_length(:'s3'::jsonb -> 'p'), 1, 'it is held in the state');
select tap.is(:'s3'::jsonb -> 'x', '[["bob", 2, 1], ["carol", 1, 1]]'::jsonb, 'deletes of unseen ids are held too');
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'s3', :'bob_op', 'bob')), 'Hello!', 'when the origin arrives, both integrate and the held delete applies');
select tap.is(crdt.yseq_apply(:'s3', :'bob_op', 'bob')::jsonb -> 'p', '[]'::jsonb, 'nothing pending afterwards');

-- malformed ops: 22023
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', o, 'bob'), '22023', 'malformed: ' || o)
from unnest(array[
    '"text"',
    '{"i": [["bob", 1, null, null, "x"]], "e": []}',
    '{"i": {"a": 1}}',
    '{"i": [["bob", 0, null, null, "x"]]}',
    '{"i": [["bob", 1.5, null, null, "x"]]}',
    '{"i": [["bob", 1, null, null, ""]]}',
    '{"i": [["bob", 1, ["alice"], null, "x"]]}',
    '{"i": [["bob", 1, null, ["alice", "5"], "x"]]}',
    '{"i": [["bob", 2147483647, null, null, "xy"]]}',
    '{"d": [["alice", 1]]}',
    '{"d": [["alice", 1, 0]]}',
    '{"d": [["al:", 1, 1]]}'
]) o;

-- default identity: crdt.current_replica_id()
begin;
set local crdt.replica_id = 'bob';
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'s', :'bob_op')), 'Hello!', 'default replica from the crdt.replica_id setting');
set local crdt.replica_id = 'mallory';
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L)', :'s', :'bob_op'), '42501', 'and forged inserts are rejected with it');
rollback;

-- labels
select tap.ok(not exists (select 1 from pg_proc where pronamespace = 'crdt'::regnamespace and proname ~ '^_?yseq_' and prosecdef),
              'no SECURITY DEFINER function');
select tap.ok(not exists (select 1 from pg_proc where pronamespace = 'crdt'::regnamespace and proname ~ '^_?yseq_' and prokind = 'f'
                          and (provolatile <> 'i' or proparallel <> 's')),
              'every yseq function is IMMUTABLE and PARALLEL SAFE');
select tap.ok((select proconfig @> array['search_path=pg_catalog, pg_temp'] from pg_proc where oid = 'crdt.yseq_apply(crdt.yseq, jsonb, text)'::regprocedure),
              'yseq_apply pins search_path');
select tap.ok(not exists (
    select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.pronamespace = 'crdt'::regnamespace and p.proname ~ '^_?yseq_' and a.grantee <> p.proowner
      and (a.grantee <> 0 or a.privilege_type <> 'EXECUTE')),
    'only EXECUTE to public is granted');
select * from tap.finish();
