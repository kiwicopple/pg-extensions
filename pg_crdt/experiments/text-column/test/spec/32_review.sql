-- Goal: regressions for the adversarial review of 2026-11-04 (repro scripts
-- in /tmp/yrev/s: dos.sql, probes.sql, probes2.sql, probes3.sql).
--   (2) many deletes or inserts in one apply cost O(n), not O(n^2): after a
--       40,000-character paste, 8,000 deletes of every other character, and
--       8,000 inserts after random characters, each well under a second
--       (they took 12.7 s and 1.0 s before);
--   (3) a writer that saves twice from one base does not duplicate text;
--   (4) the domain and yseq_merge reject malformed states (23514, 22023);
--   (5) integral numbers written as 1.0 are accepted; seq 2147483647 does
--       not overflow;
--   yseq_is_valid rejects pending entries that are not pending.

select tap.plan(16);

-- (2)
select crdt.yseq_apply(crdt.yseq_empty(), jsonb_build_object('v', '{}'::jsonb, 'i', jsonb_build_array(jsonb_build_array('bob', 1, null, null, repeat('a', 40000)))), 'bob') as big \gset
select setseed(0.1);
select clock_timestamp() as t0 \gset
select crdt.yseq_apply(:'big', jsonb_build_object('v', '{"bob": 40000}'::jsonb, 'd', (select jsonb_agg(jsonb_build_array('bob', g, 1)) from generate_series(1, 16000, 2) g)), 'mal') as dd \gset
select extract(epoch from clock_timestamp() - :'t0'::timestamptz) as dels_s \gset
select tap.is(crdt.yseq_length(:'dd'), 32000, '8,000 deletes in one apply: 8,000 characters gone');
select tap.ok(:dels_s < 1.5, format('and fast (%s s; O(n^2) took 12.7 s)', round(:dels_s::numeric, 2)));
select tap.ok(crdt.yseq_is_valid(:'dd'), 'and the state is valid');
select clock_timestamp() as t1 \gset
select crdt.yseq_apply(:'big', jsonb_build_object('v', '{"bob": 40000}'::jsonb, 'i', (
    select jsonb_agg(jsonb_build_array('mal', rn, jsonb_build_array('bob', g), jsonb_build_array('bob', g + 1), 'x'))
    from (select g, row_number() over () rn from (select g from generate_series(1, 39998, 2) g order by random() limit 8000) y) z)), 'mal') as ii \gset
select extract(epoch from clock_timestamp() - :'t1'::timestamptz) as ins_s \gset
select tap.is(crdt.yseq_length(:'ii'), 48000, '8,000 inserts after random characters in one apply');
select tap.ok(:ins_s < 2, format('and fast (%s s)', round(:ins_s::numeric, 2)));
select tap.ok(crdt.yseq_is_valid(:'ii') and length(replace(crdt.yseq_value(:'ii'), 'a', '')) = 8000, 'valid, with every x in');

-- (3)
select crdt.yseq_set(null, 'hello', 'alice') as h0 \gset
select crdt.yseq_set(:'h0', 'hello world', 'bob', base => :'h0') as h1 \gset
select tap.is(crdt.yseq_value(crdt.yseq_set(:'h1', 'hello world!', 'bob', base => :'h0')), 'hello world!',
              'a second save from the same base (autosave): no duplicated text');
select tap.is(crdt.yseq_value(crdt.yseq_set(crdt.yseq_set(:'h1', 'HELLO', 'carol', base => :'h0'), 'hello world!', 'bob', base => :'h0')),
              'HELLO world!', 'and another writer''s concurrent change survives it');

-- (4)
select tap.throws_ok($$select '{"t":"yseq","v":1,"r":["a"],"c":["x"],"n":[],"s":[],"m":[],"p":[],"x":[],"q":[]}'::crdt.yseq$$, '23514', 'domain: a count that is not a number');
select tap.throws_ok($$select '{"t":"yseq","v":1,"r":[],"c":[],"n":[],"s":[],"m":[],"p":[1],"x":[],"q":[]}'::crdt.yseq$$, '23514', 'domain: a pending run that is not an array of 5');
select tap.throws_ok($$select '{"t":"yseq","v":1,"r":[],"c":[],"n":[],"s":[5],"m":[],"p":[],"x":[],"q":[]}'::crdt.yseq$$, '23514', 'domain: chunk arrays of different lengths');
select tap.throws_ok($$select crdt.yseq_merge(crdt.yseq_empty(), '{"t":"yseq","v":1,"r":[],"c":[],"n":[],"s":[],"m":[],"p":[],"x":[["a",1,0]],"q":[]}')$$, '22023',
                     'yseq_merge: a malformed pending delete is 22023');
select tap.throws_ok($$select crdt.yseq_merge(crdt.yseq_empty(), '{"t":"yseq","v":1,"r":["a"],"c":[1],"n":[1],"s":["a"],"m":["{1,1}"],"p":[],"x":[],"q":[]}')$$, '22023',
                     'yseq_merge: chunk runs that are not 7 ints each are 22023');

-- (5)
select tap.is(crdt.yseq_value(crdt.yseq_apply(crdt.yseq_empty(), '{"v":{},"i":[["alice",1.0,null,null,"ab"]],"d":[["alice",2,1.0]]}', 'alice')), 'a',
              'seq and len written as 1.0 are accepted');
select tap.is(jsonb_array_length(crdt.yseq_apply(crdt.yseq_empty(), '{"v":{"alice":2147483646},"i":[["alice",2147483647,null,null,"a"]]}', 'alice') -> 'q'), 1,
              'seq 2147483647 waits without overflowing');

-- pending entries that are not pending
select tap.ok(not crdt.yseq_is_valid(jsonb_set(crdt.yseq_apply(crdt.yseq_empty(), '{"v":{},"i":[["a",1,null,null,"hi"]]}', 'a'), '{x}', '[["a",1,1]]'))
              and not crdt.yseq_is_valid(jsonb_set(crdt.yseq_apply(crdt.yseq_empty(), '{"v":{},"i":[["a",1,null,null,"hi"]]}', 'a'), '{p}', '[["b",1,null,null,"Q"]]')),
              'yseq_is_valid rejects a pending delete of a present id and a pending run that is ready');
select * from tap.finish();
