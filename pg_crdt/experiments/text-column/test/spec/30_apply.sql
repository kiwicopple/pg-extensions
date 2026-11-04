-- Goal: yseq_apply is safe for untrusted writers (research/text.md, "apply"
-- and Amendment 1), like pn_apply_delta: inserts only with the caller's
-- replica id or <id>:<device>; deletes of anyone's characters it has seen;
-- malformed ops 22023; null or forged replica 42501; re-applying is a
-- no-op; identity from crdt.current_replica_id() by default. The causal
-- rules (experiments/text-ref/README.md): V0 shape of v, V1 origins covered,
-- V2 own seq, V6 deletes covered (on arrival), V7 wait for v, V3 v closed,
-- V4 origin order, V5 nothing covered between the origins; each op whole or
-- not at all; a quota on waiting ops per writer (54000). Also the function
-- labels.

select tap.plan(52);

select crdt.yseq_insert(crdt.yseq_empty(), 0, 'Hello', 'alice') as s \gset
select '{"v": {"alice": 5}, "i": [["bob", 1, ["alice", 5], null, "!"]], "d": []}' as bob_op \gset

-- owner rule
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'s', :'bob_op', 'bob')), 'Hello!', 'bob applies his own insert');
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'s', '{"v": {"alice": 5}, "i": [["bob:phone", 1, ["alice", 5], null, "?"]]}', 'bob')), 'Hello?',
              'bob applies an insert of his device key bob:phone');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', :'bob_op', 'mallory'), '42501', 'mallory cannot insert as bob: 42501');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', '{"v": {}, "i": [["bobby", 1, null, null, "x"]]}', 'bob'), '42501',
                     'bob cannot insert as bobby (owner compared exactly)');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', '{"v": {}, "i": [["bo", 1, null, null, "x"]]}', 'bob'), '42501',
                     'bob cannot insert as bo');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, null)', :'s', :'bob_op'), '42501', 'null replica: 42501');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', :'bob_op', 'bob:phone'), '22023', 'a caller id with ":" is not a replica id: 22023');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', :'bob_op', ''), '22023', 'empty caller id: 22023');
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'s', '{"v": {"alice": 5}, "i": [], "d": [["alice", 1, 2]]}', 'bob')), 'llo', 'bob may delete alice''s characters he has seen');
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'s', '[{"v": {"alice": 5}, "i": [["bob", 1, ["alice", 5], null, "!"]]}, {"v": {"alice": 5, "bob": 1}, "d": [["alice", 1, 1]]}]', 'bob')),
              'ello!', 'an array of ops; a missing "i" or "d" counts as empty');

-- idempotent
select crdt.yseq_apply(:'s', :'bob_op', 'bob') as s2 \gset
select tap.is(crdt.yseq_apply(:'s2', :'bob_op', 'bob')::jsonb, :'s2'::jsonb, 're-applying an insert changes nothing');
select tap.is(crdt.yseq_apply(crdt.yseq_apply(:'s2', '{"v": {"alice": 5, "bob": 1}, "d": [["bob", 1, 1]]}', 'bob'), '{"v": {"alice": 5, "bob": 1}, "d": [["bob", 1, 1]]}', 'bob')::jsonb,
              crdt.yseq_apply(:'s2', '{"v": {"alice": 5, "bob": 1}, "d": [["bob", 1, 1]]}', 'bob')::jsonb, 're-applying a delete changes nothing');
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'s2', '{"v": {"alice": 5, "bob": 1}, "i": [["bob", 2, ["bob", 1], null, "?"]]}', 'bob')), 'Hello!?',
              'the next op of the same writer chains on');

-- static rules, on arrival: 22023
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', '{"i": [["bob", 1, ["alice", 5], null, "!"]]}', 'bob'), '22023', 'V0: no v');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', '{"v": {"alice": 0}, "i": [["bob", 1, null, null, "!"]]}', 'bob'), '22023', 'V0: a count of 0');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', '{"v": {"alice": 1.5}, "i": []}', 'bob'), '22023', 'V0: a count that is not an integer');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', '{"v": {"alice": 4}, "i": [["bob", 1, ["alice", 5], null, "!"]]}', 'bob'), '22023',
                     'V1: originLeft not covered by v');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', '{"v": {"alice": 5}, "i": [["bob", 2, ["alice", 5], null, "!"]]}', 'bob'), '22023',
                     'V2: the first seq is not v[bob] + 1');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', '{"v": {"alice": 4}, "d": [["alice", 5, 1]]}', 'bob'), '22023',
                     'V6: deleting a character not covered by v (no pre-deleting future text)');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', crdt.yseq_empty(), '{"v": {"zed": 3}, "d": [["zed", 3, 1]], "i": [["mal", 1, ["zed", 4], null, "x"]]}', 'mal'), '22023',
                     'static rules apply even when v names ids the document lacks');

-- V7: wait until the document covers v
select crdt.yseq_apply(crdt.yseq_empty(), :'bob_op', 'bob') as w1 \gset
select tap.is(crdt.yseq_value(:'w1'), '', 'an op whose v names unseen characters waits');
select tap.is(jsonb_array_length(:'w1'::jsonb -> 'q'), 1, 'it is held in the state (q)');
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'w1', '{"v": {}, "i": [["alice", 1, null, null, "Hello"]]}', 'alice')), 'Hello!',
              'when the characters arrive, the waiting op integrates');
select tap.is(crdt.yseq_apply(:'w1', '{"v": {}, "i": [["alice", 1, null, null, "Hello"]]}', 'alice') -> 'q', '[]'::jsonb, 'and leaves q');
select tap.is(crdt.yseq_value(crdt.yseq_merge(crdt.yseq_insert(crdt.yseq_empty(), 0, 'Hello', 'alice'), :'w1')), 'Hello!',
              'a waiting op travels with yseq_merge and integrates there');

-- dynamic rules
select crdt.yseq_apply(crdt.yseq_empty(), '{"v": {}, "i": [["alice", 1, null, null, "abc"]]}', 'alice') as abc \gset
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'abc', '{"v": {}, "i": [["bob", 1, null, null, "Y"]]}', 'bob')), 'abcY',
              'honest op with v {}: bob types at the end of an empty document, concurrently with alice');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'abc', '{"v": {"alice": 3}, "i": [["mal", 1, null, ["alice", 2], "X"]]}', 'mal'), '22023',
                     'V5: the reviewer''s repro (originRight skips a, which v covers)');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'abc', '{"v": {"alice": 3}, "i": [["mal", 1, ["alice", 3], ["alice", 1], "X"]]}', 'mal'), '22023',
                     'V4: originLeft after originRight');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'abc', '{"v": {"alice": 3}, "i": [["mal", 1, ["alice", 2], ["alice", 2], "X"]]}', 'mal'), '22023',
                     'V4: equal origins');
select tap.is(crdt.yseq_value(crdt.yseq_apply(:'abc', '{"v": {"alice": 1}, "i": [["mal", 1, ["alice", 1], null, "X"]]}', 'mal')), 'abcX',
              'V5 allows items v does not cover between the origins (concurrent text)');
select crdt.yseq_apply(:'abc', '{"v": {"alice": 3}, "i": [["bob", 1, ["alice", 3], null, "Z"]]}', 'bob') as abcz \gset
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'abcz', '{"v": {"alice": 2, "bob": 1}, "i": [["m", 1, null, null, "x"]]}', 'm'), '22023',
                     'V3: v covers bob:1 but not its origin alice:3');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'abc', '{"v": {"alice": 3}, "i": [["m", 1, ["alice", 3], null, "ok"], ["m", 3, ["alice", 1], ["alice", 3], "bad"]]}', 'm'), '22023',
                     'a two-run op whose second run breaks V5 is rejected');
-- a waiting op decided later: rejected silently, with nothing of it applied
select crdt.yseq_apply(crdt.yseq_empty(), '{"v": {"alice": 3}, "i": [["m", 1, ["alice", 3], null, "ok"], ["m", 3, ["alice", 1], ["alice", 3], "bad"]]}', 'm') as wq \gset
select tap.is(jsonb_array_length(:'wq'::jsonb -> 'q'), 1, 'the same op, before alice''s text, waits');
select crdt.yseq_apply(:'wq', '{"v": {}, "i": [["alice", 1, null, null, "abc"]]}', 'alice') as wq2 \gset
select tap.is(crdt.yseq_value(:'wq2'), 'abc', 'when alice''s text arrives, that call succeeds and nothing of the bad op is applied (whole op)');
select tap.is(:'wq2'::jsonb -> 'q', '[]'::jsonb, 'and the bad op leaves q');
select tap.is(crdt.yseq_version(:'wq2'), '{"alice": 3}'::jsonb, 'no id of the rejected op exists');

-- quota: at most 256 waiting runs and deletes, 64 kB, per writer
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', crdt.yseq_empty(),
    (select jsonb_agg(jsonb_build_object('v', jsonb_build_object('ghost', 1) || case when g > 1 then jsonb_build_object('mal', g - 1) else '{}'::jsonb end, 'i', jsonb_build_array(jsonb_build_array('mal', g, null, null, 'x'))))
     from generate_series(1, 300) g), 'mal'), '54000', 'more than 256 waiting runs from one writer: 54000');
select tap.lives_ok(format('select crdt.yseq_apply(%L, %L, %L)', crdt.yseq_empty(),
    (select jsonb_agg(jsonb_build_object('v', jsonb_build_object('ghost', 1) || case when g > 1 then jsonb_build_object('mal', g - 1) else '{}'::jsonb end, 'i', jsonb_build_array(jsonb_build_array('mal', g, null, null, 'x'))))
     from generate_series(1, 200) g), 'mal'), '200 waiting runs are within the quota');
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', crdt.yseq_empty(),
    jsonb_build_object('v', '{"ghost": 1}'::jsonb, 'i', jsonb_build_array(jsonb_build_array('mal', 1, null, null, repeat('x', 70000)))), 'mal'), '54000',
    'more than 64 kB waiting from one writer: 54000');

-- malformed ops: 22023
select tap.throws_ok(format('select crdt.yseq_apply(%L, %L, %L)', :'s', o, 'bob'), '22023', 'malformed: ' || o)
from unnest(array[
    '"text"',
    '{"v": {}, "i": [["bob", 1, null, null, "x"]], "e": []}',
    '{"v": {}, "i": {"a": 1}}',
    '{"v": {}, "i": [["bob", 0, null, null, "x"]]}',
    '{"v": {}, "i": [["bob", 1, null, null, ""]]}',
    '{"v": {}, "i": [["bob", 1, ["alice"], null, "x"]]}',
    '{"v": {}, "d": [["alice", 1]]}'
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
