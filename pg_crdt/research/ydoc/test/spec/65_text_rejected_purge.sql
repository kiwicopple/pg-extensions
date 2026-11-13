-- Goal: ydoc_rejected_purge(doc, writer default null). The rejection log
-- (ydoc_rejected) keeps the last 100 per writer and document; the app may
-- delete its rows, and this is the API for it: delete a document's rows for
-- one writer, or for all writers (writer null), returning the number deleted.
-- Other documents and other writers are untouched; the document's text and its
-- waiting ops are not. An unknown document is P0002, a null document 22004.
-- Like the other ydoc_ functions it is SECURITY INVOKER: a role without
-- privileges on the tables gets 42501.
\i :ext_dir/test/lib/text-helpers.sql

create function pg_temp.why(q text) returns text language plpgsql as $$
begin
    execute q;
    return 'ok';
exception when others then
    return sqlstate;
end;
$$;

-- Ops that wait for zed:1 and are rejected (V5) when it arrives, so that they
-- land in ydoc_rejected: writers w1 (two ops, two device keys), w2 (one op)
-- on document p; w1 (one op) on document q.
create function pg_temp.park(d text, writer text, key text, txt text) returns text language sql as $$
    select crdt.ydoc_apply(d, jsonb_build_object('v', '{"alice": 3, "zed": 1}'::jsonb,
               'i', jsonb_build_array(jsonb_build_array(key, 1, null, jsonb_build_array('alice', 2), txt)), 'd', '[]'::jsonb), writer)
$$;
select crdt.ydoc_create() as p, crdt.ydoc_create() as q, crdt.ydoc_create() as empty \gset
select crdt.ydoc_insert(:'p', 0, 'abc', 'alice') \g /dev/null
select crdt.ydoc_insert(:'q', 0, 'abc', 'alice') \g /dev/null
select pg_temp.park(:'p', 'w1', 'w1', 'a') as s1, pg_temp.park(:'p', 'w1', 'w1:d', 'b') as s2, pg_temp.park(:'p', 'w2', 'w2', 'c') as s3,
       pg_temp.park(:'q', 'w1', 'w1', 'd') as s4 \gset
select crdt.ydoc_apply(:'p', '{"v": {}, "i": [["zed", 1, null, null, "Z"]], "d": []}', 'zed') \g /dev/null
select crdt.ydoc_apply(:'q', '{"v": {}, "i": [["zed", 1, null, null, "Z"]], "d": []}', 'zed') \g /dev/null
select crdt.ydoc_value(:'p') as ptext, crdt.ydoc_version(:'p') as pvv \gset
-- a waiting op that is still waiting (needs zed:5) must survive a purge
select crdt.ydoc_apply(:'p', '{"v": {"zed": 5}, "i": [["w3", 1, null, null, "x"]], "d": []}', 'w3') as s5 \gset

select pg_temp.did(:'p') as pid, pg_temp.did(:'q') as qid \gset
select (select count(*) from crdt.ydoc_rejected where doc = :pid and writer = 'w1') as p_w1,
       (select count(*) from crdt.ydoc_rejected where doc = :pid and writer = 'w2') as p_w2,
       (select count(*) from crdt.ydoc_rejected where doc = :qid) as q_all \gset

-- purge one writer
select crdt.ydoc_rejected_purge(:'p', 'w1') as del_w1 \gset
select (select count(*) from crdt.ydoc_rejected where doc = :pid and writer = 'w1') as p_w1_after,
       (select count(*) from crdt.ydoc_rejected where doc = :pid and writer = 'w2') as p_w2_after,
       (select count(*) from crdt.ydoc_rejected where doc = :qid) as q_after \gset
-- a writer with no rows, then all writers
select crdt.ydoc_rejected_purge(:'p', 'nobody') as del_none \gset
select crdt.ydoc_rejected_purge(:'p') as del_all \gset
select crdt.ydoc_rejected_purge(:'p') as del_again, crdt.ydoc_rejected_purge(:'empty') as del_empty \gset
select (select count(*) from crdt.ydoc_rejected where doc = :pid) as p_left,
       (select count(*) from crdt.ydoc_rejected where doc = :qid) as q_left,
       (select count(*) from crdt.ydoc_pending_ops where doc = :pid) as p_waiting \gset
-- explicit null writer, and named arguments
select crdt.ydoc_rejected_purge(:'q', null) as del_null_writer \gset
select crdt.ydoc_rejected_purge(doc => :'q', writer => 'w1') as del_named \gset

-- the full log: more rows than the log keeps is purged in one call
select crdt.ydoc_create() as big \gset
select pg_temp.did(:'big') as bid \gset
insert into crdt.ydoc_rejected (doc, writer, op, reason)
select :bid, 'mal' || (n % 3), '{}', 'test' from generate_series(1, 90) n;
select crdt.ydoc_rejected_purge(:'big', 'mal1') as big1, crdt.ydoc_rejected_purge(:'big') as big_rest \gset

-- privileges: the gate is the tables
create role purge_nobody nologin;
grant usage on schema crdt to purge_nobody;
set role purge_nobody;
select pg_temp.why(format('select crdt.ydoc_rejected_purge(%L)', :'p')) as nopriv \gset
reset role;
drop owned by purge_nobody;
drop role purge_nobody;

select tap.plan(18);
select tap.is(:'s1'::text || ' ' || :'s2'::text || ' ' || :'s3'::text || ' ' || :'s4'::text, 'pending pending pending pending', 'setup: four ops wait for zed:1');
select tap.is(:'p_w1'::text || ' ' || :'p_w2' || ' ' || :'q_all', '2 1 1', 'setup: they were rejected when it arrived and logged (w1 twice, w2 once, and w1 on the other document)');
select tap.is(:'del_w1'::text, '2', 'purging one writer returns the number of rows deleted');
select tap.is(:'p_w1_after'::text || ' ' || :'p_w2_after' || ' ' || :'q_after', '0 1 1', 'only that writer''s rows on that document are gone');
select tap.is(:'del_none'::text, '0', 'a writer with no rows: 0');
select tap.is(:'del_all'::text, '1', 'a null writer (the default) purges every writer of the document');
select tap.is(:'del_again'::text || ' ' || :'del_empty', '0 0', 'nothing left, and a document with no log: 0');
select tap.is(:'p_left'::text || ' ' || :'q_left', '0 1', 'the other document keeps its rows');
select tap.is(:'del_null_writer'::text || ' ' || :'del_named', '1 0', 'an explicit null writer and named arguments work; the second call finds nothing');
select tap.is(:'big1'::text || ' ' || :'big_rest', '30 60', 'rows beyond a few are purged in one call: per writer, then the rest');
select tap.is((select count(*)::int from crdt.ydoc_rejected where doc = :bid), 0, 'the log of that document is empty');
select tap.is(:'p_waiting'::text, '1', 'waiting ops are not touched');
select tap.is(crdt.ydoc_value(:'p') || ' ' || crdt.ydoc_version(:'p')::text, :'ptext' || ' ' || :'pvv', 'the document text and version are not touched');
select tap.is(:'s5'::text, 'pending', 'setup: the waiting op was still waiting');
select tap.is(pg_temp.why(format('select crdt.ydoc_rejected_purge(%L)', 'nope')), 'P0002', 'an unknown document raises P0002');
select tap.is(pg_temp.why('select crdt.ydoc_rejected_purge(null)'), '22004', 'a null document raises 22004');
select tap.is(:'nopriv'::text, '42501', 'a role without privileges on the tables gets 42501');
select tap.is(crdt.ydoc_rejected_purge(:'big'), 0, 'purging twice is harmless');
select * from tap.finish();
