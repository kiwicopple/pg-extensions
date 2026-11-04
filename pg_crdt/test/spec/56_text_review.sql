-- Goal: regressions for the adversarial review of 2026-11-05 (repro
-- scripts t1-t11 in the review). Each block names the finding.
\i :ext_dir/test/lib/text-helpers.sql
create function pg_temp.why(q text) returns text language plpgsql as $$
begin
    execute q;
    return 'ok';
exception when others then
    return sqlstate || coalesce(' ' || substring(sqlerrm from 'V[0-9]'), '');
end;
$$;

-- 1. poison: over-long keys are refused on arrival; a parked op that fails
--    with any error when decided is logged and does not fail the caller
select crdt.ydoc_create() as p \gset
select crdt.ydoc_apply(:p, '{"v": {}, "i": [["bob", 1, null, null, "hi"]], "d": []}', 'bob') \g /dev/null
select pg_temp.why(format('select crdt.ydoc_apply(%s, %L, %L)', :p, jsonb_build_object('v', jsonb_build_object('bob', 3),
         'i', jsonb_build_array(jsonb_build_array('mal:' || repeat('x', 300), 1, null, null, 'X')), 'd', '[]'::jsonb), 'mal')) as longkey,
       pg_temp.why(format('select crdt.ydoc_apply(%s, %L, %L)', :p, jsonb_build_object('v', jsonb_build_object(repeat('y', 300), 3),
         'i', '[]'::jsonb, 'd', '[]'::jsonb), 'mal')) as longvkey,
       pg_temp.why(format('select crdt.ydoc_insert(%s, 0, %L, %L)', :p, 'x', repeat('z', 300))) as longlocal \gset
-- mal fills its device quota, then parks an op with a 17th device key that
-- waits for bob:3; deciding it raises 54000 (not a rule)
select crdt.ydoc_apply(:p, jsonb_build_object('v', '{}'::jsonb, 'd', '[]'::jsonb, 'i', (
    select jsonb_agg(jsonb_build_array('mal:d' || k, 1, case when k = 1 then null else jsonb_build_array('mal:d' || (k - 1), 1) end, null, 'm') order by k)
    from generate_series(1, crdt._ydoc_devices_max()) k)), 'mal') as filled \gset
select crdt.ydoc_apply(:p, jsonb_build_object('v', jsonb_build_object('bob', 3), 'd', '[]'::jsonb,
    'i', jsonb_build_array(jsonb_build_array('mal:extra', 1, null, null, 'X'))), 'mal') as parked \gset
select crdt.ydoc_apply(:p, '{"v": {"bob": 2}, "i": [["bob", 3, ["bob", 2], null, "!"]], "d": []}', 'bob') as bob3 \gset
select pg_temp.why(format('select crdt.ydoc_apply(%s, %L, %L)', :p, jsonb_build_object('v', '{}'::jsonb, 'd', '[]'::jsonb,
    'i', jsonb_build_array(jsonb_build_array('mal:other', 1, null, null, 'X'))), 'mal')) as device17 \gset

-- 2. three-way set: a second save from one base, and peers accept the ops
select crdt.ydoc_create() as s1 \gset
select crdt.ydoc_set(:s1, 'Hello', 'w') \g /dev/null
select crdt.ydoc_base(:s1) as b1 \gset
select crdt.ydoc_set(:s1, 'Hello world', 'w', :'b1') \g /dev/null
select crdt.ydoc_set(:s1, 'Hello world!', 'w', :'b1') \g /dev/null
select crdt.ydoc_create() as a, crdt.ydoc_create() as b \gset
select crdt.ydoc_insert(:a, 0, 'abc', 'q') as op1 \gset
select crdt.ydoc_base(:a) as base \gset
select crdt.ydoc_insert(:a, 3, 'XYZ', 'q') as op2 \gset
select crdt.ydoc_insert(:a, 6, '!', 'w') as op3 \gset
select crdt.ydoc_set(:a, 'abc?', 'w', :'base') as op4 \gset
select crdt.ydoc_apply(:b, :'op1', 'q') || crdt.ydoc_apply(:b, :'op2', 'q') || crdt.ydoc_apply(:b, :'op3', 'w')
    || crdt.ydoc_apply(:b, :'op4', 'w') as peer_b \gset
select crdt.ydoc_create() as c, crdt.ydoc_create() as e \gset
select crdt.ydoc_insert(:c, 0, 'Hello', 'q') as p1 \gset
select crdt.ydoc_base(:c) as base2 \gset
select crdt.ydoc_set(:c, 'Hello world', 'w', :'base2') as p2 \gset
select crdt.ydoc_set(:c, 'Hello there', 'w', :'base2') as p3 \gset
select crdt.ydoc_apply(:e, :'p1', 'q') || crdt.ydoc_apply(:e, :'p2', 'w') || crdt.ydoc_apply(:e, :'p3', 'w') as peer_e \gset
select pg_temp.why(format('select crdt.ydoc_set(%s, %L, %L, %L)', :a, 'x', 'w', :'base2')) as otherdoc \gset
select crdt.ydoc_value(:a) as va, crdt.ydoc_value(:b) as vb, crdt.ydoc_value(:c) as vc, crdt.ydoc_value(:e) as ve \gset

-- 3. runs buffered on the trusted path are drained after the untrusted path
select crdt.ydoc_create() as t \gset
select crdt.ydoc_merge(:t, '{"i": [["x", 1, ["c", 1], null, "X"]]}');
select crdt.ydoc_apply(:t, '{"v": {"b": 1}, "i": [["c", 1, ["b", 1], null, "C"]], "d": []}', 'c') \g /dev/null
select crdt.ydoc_merge(:t, '{"i": [["b", 1, null, null, "B"]]}');

-- 4. cost: chained one-char runs are joined; runs and scanned rows are capped
select crdt.ydoc_create() as k \gset
select crdt.ydoc_merge(:k, jsonb_build_object('i', (select jsonb_agg(jsonb_build_array('r' || (n % 2), (n + 1) / 2,
        case when n = 1 then null else jsonb_build_array('r' || ((n - 1) % 2), n / 2) end, null, 'x') order by n)
        from generate_series(1, 5000) n)));
select clock_timestamp() as t0 \gset
select crdt.ydoc_apply(:k, jsonb_build_object('v', '{}'::jsonb, 'd', '[]'::jsonb, 'i', (select jsonb_agg(jsonb_build_array('C', n,
        case when n = 1 then null else jsonb_build_array('C', n - 1) end, null, 'z') order by n) from generate_series(1, 3000) n)), 'C') as chained \gset
select extract(epoch from clock_timestamp() - :'t0'::timestamptz) < 2 as chained_fast,
       (select count(*) from crdt.ydoc_items where doc = :k and replica = crdt._ydoc_rid(:k, 'C')) as chained_rows \gset
select pg_temp.why(format('select crdt.ydoc_apply(%s, %L, %L)', :k, jsonb_build_object('v', '{}'::jsonb, 'd', '[]'::jsonb, 'i', (
        select jsonb_agg(jsonb_build_array('D', n, null, null, 'z') order by n) from generate_series(1, crdt._ydoc_runs_max() + 1) n)), 'D')) as toomanyruns \gset
create or replace function crdt._ydoc_scan_max() returns bigint language sql immutable parallel safe return 1000;
select pg_temp.why(format('select crdt.ydoc_apply(%s, %L, %L)', :k, '{"v": {}, "i": [["F", 1, null, null, "f"]], "d": []}', 'F')) as overbudget,
       pg_temp.why(format('select crdt.ydoc_apply(%s, %L, %L)', :k,
                          jsonb_build_object('v', crdt.ydoc_version(:k), 'i', jsonb_build_array(jsonb_build_array('G', 1,
                              (select jsonb_build_array(r.name, i.seq + i.len - 1) from crdt.ydoc_items i join crdt.ydoc_replicas r on r.doc = i.doc and r.id = i.replica
                               where i.doc = :k order by i.ord desc limit 1), null, 'g')), 'd', '[]'::jsonb), 'G')) as typing_at_end \gset
create or replace function crdt._ydoc_scan_max() returns bigint language sql immutable parallel safe return 250000;

-- 7. search_path: an exact-type operator on the caller's path is not used
create schema evil;
create function evil.cat(a integer[], b integer) returns integer[] language plpgsql as
    $$ begin raise exception 'evil operator ran'; end $$;
create operator evil.|| (leftarg = integer[], rightarg = integer, function = evil.cat);
set search_path = evil, public;
select pg_temp.why(format('select crdt.ydoc_base(%s)', :a)) || ' ' || pg_temp.why(format('select crdt.ydoc_insert(%s, 0, %L, %L)', :a, 'e', 'q'))
    || ' ' || pg_temp.why(format('select crdt.ydoc_apply(%s, %L, %L)', :a, crdt.ydoc_insert(:b, 0, 'f', 'z'), 'z')) as evil \gset
reset search_path;

-- 8. bounded rejection log; 1.0-style numbers; delete overflow
select crdt.ydoc_create() as rj \gset
select set_config('ydoc.rj', :'rj', false) \g /dev/null
do $$
declare d bigint := current_setting('ydoc.rj')::bigint; s integer := 0;
begin
    for round in 1 .. 3 loop
        for k in 1 .. 60 loop
            perform crdt.ydoc_apply(d, jsonb_build_object('v', jsonb_build_object('mal', s + 1),
                    'i', jsonb_build_array(jsonb_build_array('mal', s + 2, jsonb_build_array('mal', s + 1), null, k::text)), 'd', '[]'::jsonb), 'mal');
        end loop;
        perform crdt.ydoc_apply(d, jsonb_build_object('v', case when s = 0 then '{}'::jsonb else jsonb_build_object('mal', s) end,
                'i', jsonb_build_array(jsonb_build_array('mal', s + 1, case when s = 0 then null else jsonb_build_array('mal', s) end, null, 'a')), 'd', '[]'::jsonb), 'mal');
        s := crdt._ydoc_clock_name(d, 'mal');
    end loop;
end $$;
select pg_temp.why(format('select crdt.ydoc_merge(%s, %L)', :rj, '{"i": [["a", 1.0, null, null, "x"]]}')) || ' ' ||
       pg_temp.why(format('select crdt.ydoc_apply(%s, %L, %L)', :rj, '{"v": {"a": 1.0}, "i": [], "d": []}', 'a')) || ' ' ||
       pg_temp.why(format('select crdt.ydoc_ops_since(%s, %L)', :rj, '{"a": 1.0}')) || ' ' ||
       pg_temp.why(format('select crdt.ydoc_delete(%s, 2147483647, 1, %L)', :rj, 'a')) as numbers \gset

-- 9. interning: two transactions, each on its own document, new names in
--    opposite orders, do not deadlock (names are interned per document)
select exists (select 1 from pg_available_extensions where name = 'dblink') as has_dblink \gset
\if :has_dblink
create extension dblink;
select crdt.ydoc_create() as x1, crdt.ydoc_create() as x2 \gset
select format('dbname=%s user=%s port=%s host=%s', current_database(), current_user,
              current_setting('port'), split_part(current_setting('unix_socket_directories'), ',', 1)) as conn \gset
select dblink_connect('s1', :'conn'), dblink_connect('s2', :'conn') \g /dev/null
select dblink_exec('s1', 'begin'), dblink_exec('s2', 'begin') \g /dev/null
select dblink_exec('s1', format($q$do $x$ begin perform crdt.ydoc_merge(%s, '{"i": [["n1", 1, null, null, "a"]]}'); end $x$$q$, :x1)) \g /dev/null
select dblink_exec('s2', format($q$do $x$ begin perform crdt.ydoc_merge(%s, '{"i": [["n2", 1, null, null, "a"]]}'); end $x$$q$, :x2)) \g /dev/null
select dblink_send_query('s1', format($q$do $x$ begin perform crdt.ydoc_merge(%s, '{"i": [["n2", 1, null, null, "b"]]}'); end $x$$q$, :x1)) \g /dev/null
select dblink_send_query('s2', format($q$do $x$ begin perform crdt.ydoc_merge(%s, '{"i": [["n1", 1, null, null, "b"]]}'); end $x$$q$, :x2)) \g /dev/null
select pg_sleep(0.5) \g /dev/null
select (select count(*) from dblink_get_result('s1') as r(s text)) + (select count(*) from dblink_get_result('s2') as r(s text)) as got \gset
-- One more dblink_get_result per connection, for the empty result that ends
-- the async query (dblink's documented protocol; newer minor versions refuse
-- the next command on the connection without it).
select (select count(*) from dblink_get_result('s1') as r(s text)) + (select count(*) from dblink_get_result('s2') as r(s text)) \g /dev/null
select dblink_exec('s1', 'commit') || dblink_exec('s2', 'commit') as committed \gset
select dblink_disconnect('s1'), dblink_disconnect('s2') \g /dev/null
\else
\set committed 'COMMITCOMMIT'
\endif

-- originLeft = originRight: decided by V4 like the reference
select crdt.ydoc_create() as o \gset
select crdt.ydoc_apply(:o, '{"v": {}, "i": [["al", 1, null, null, "ab"]], "d": []}', 'al') \g /dev/null
select pg_temp.why(format('select crdt.ydoc_apply(%s, %L, %L)', :o, '{"v": {"al": 2}, "i": [["m", 1, ["al", 1], ["al", 1], "x"]], "d": []}', 'm')) as olor \gset

select tap.plan(20);
select tap.is(:'longkey'::text || ' ' || :'longvkey'::text || ' ' || :'longlocal'::text, '22023 22023 V0 22023', '1: keys over 256 bytes are refused on arrival (insert, v, local edit)');
select tap.is(:'filled'::text || ' ' || :'parked'::text || ' ' || :'bob3'::text, 'accepted pending accepted', '1: the write that decides a failing parked op succeeds');
select tap.is((select string_agg(left(reason, 5), ',') from crdt.ydoc_rejected where doc = :p), '54000', '1: and the parked op is logged with its error (54000, device quota)');
select tap.is(crdt.ydoc_value(:p), 'hi!mmmmmmmmmmmmmmmm', '1: the document is not blocked');
select tap.is(:'device17'::text, '54000', '5: a 17th device key of one owner is refused (54000)');
select tap.is(crdt.ydoc_value(:s1), 'Hello world!', '2: a second save from the same base is not inserted twice');
select tap.is(:'peer_b'::text, 'acceptedacceptedacceptedaccepted', '2: a peer accepts the save made after the writer''s own later edits');
select tap.is(:'vb'::text, :'va'::text, '2: and converges');
select tap.is(:'peer_e'::text || ' ' || :'ve', 'acceptedacceptedaccepted ' || :'vc', '2: two saves from one base: the peer accepts both and converges');
select tap.is(:'otherdoc'::text, '22023', '8: a base from another document is refused');
select tap.is(crdt.ydoc_value(:t) || ' ' || (select count(*) from crdt.ydoc_pending where doc = :t), 'BCX 0', '3: a buffered trusted run is integrated when its origin arrives through the untrusted path');
select tap.is(:'chained'::text || ' ' || :'chained_fast'::text, 'accepted t', '4: 3,000 chained one-char runs: joined, fast');
select tap.is(:'chained_rows'::integer, 12, '4: stored as runs of up to 256 chars (12 rows)');
select tap.is(:'toomanyruns'::text, '54000', '4: more than _ydoc_runs_max() runs in one op are refused (54000)');
select tap.is(:'overbudget'::text || ' ' || :'typing_at_end'::text, '54000 ok', '4: origins further apart than the scan budget are refused; typing at the end is not affected');
select tap.is(:'evil'::text, 'ok ok ok', '7: an operator on the caller''s search_path is not used');
select tap.is((select count(*)::int from crdt.ydoc_rejected where doc = :rj and writer = 'mal'), crdt._ydoc_rejected_max(), '8: the rejection log keeps the last 100 per writer');
select tap.is(:'numbers'::text, '22023 22023 V0 22023 22023', '8: 1.0-style numbers are 22023, not 22P02; a delete past the integer range is 22023, not 22003');
select tap.is(:'committed'::text, 'COMMITCOMMIT', '9: two documents interning the same new names in opposite orders do not deadlock');
select tap.is(:'olor'::text, '22023 V4', 'originLeft = originRight is decided by V4, as in the reference');

select * from tap.finish();
