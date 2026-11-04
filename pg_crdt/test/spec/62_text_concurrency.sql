-- Goal: several sessions editing one document at the same time under READ
-- COMMITTED lose nothing and never deadlock. Every write locks the document
-- row first (FOR NO KEY UPDATE), so writes to one document are serialized:
--   1. A holds the lock in an open transaction; B's insert waits; after A
--      commits, B integrates against A's version and both edits are there.
--   2. Four sessions each run 150 single-statement transactions (inserts at
--      random positions, some deletes, some ydoc_set and ydoc_apply) on
--      the same document at once: every insert is integrated exactly once,
--      the length adds up, invariants hold.
-- Needs dblink (contrib). Without it the file passes with SKIP assertions.
\i :ext_dir/test/lib/text-helpers.sql

select exists (select 1 from pg_available_extensions where name = 'dblink') as has_dblink \gset

\if :has_dblink
create extension dblink;

create function pg_temp.drain(conn text) returns int language plpgsql as $$
declare
    n int := 0;
    got int;
begin
    loop
        select count(*) into got from dblink_get_result(conn) as x(status text);
        exit when got = 0;
        n := n + 1;
    end loop;
    return n;
end;
$$;

select crdt.ydoc_create() as d \gset
select crdt.ydoc_insert(:d, 0, 'start', 'base') \g /dev/null
select format('dbname=%s user=%s port=%s host=%s', current_database(), current_user,
              current_setting('port'), split_part(current_setting('unix_socket_directories'), ',', 1)) as conn \gset
select dblink_connect('a', :'conn');
select dblink_connect('b', :'conn');
select dblink_connect('c', :'conn');
select dblink_connect('e', :'conn');

-- 1. B waits on A's lock.
select dblink_exec('a', 'begin');
select dblink_exec('a', format('do $x$ begin perform crdt.ydoc_insert(%s, 5, %L, %L); end $x$', :d, ' A', 'sa'));
select dblink_send_query('b', format('select crdt.ydoc_insert(%s, 0, %L, %L)', :d, 'B ', 'sb'));
select pg_sleep(0.3);
select dblink_is_busy('b') = 1 as b_waited \gset
select dblink_exec('a', 'commit');
select pg_temp.drain('b');
select crdt.ydoc_value(:d) as v1 \gset

-- 2. Four sessions at once. Each statement is its own transaction.
create function pg_temp.script(d bigint, who text, n int) returns text language sql as $$
    -- DO blocks: one transaction each, and no result rows to fill the socket
    select string_agg('do $x$ begin perform ' ||
        case when i % 10 = 0 then format('crdt.ydoc_delete(%s, 0, 1, %L)', d, who)
             -- an untrusted op inserted at the start: v and the first item from
             -- the statement's snapshot; items committed after it are concurrent
             when i % 25 = 0 then format($f$crdt.ydoc_apply(%s, jsonb_build_object('v', crdt.ydoc_version(%s), 'i', jsonb_build_array(jsonb_build_array(%L,
                                             coalesce((crdt.ydoc_version(%s) ->> %L)::int, 0) + 1, null,
                                             (select jsonb_build_array(r.name, i.seq) from crdt.ydoc_items i join crdt.ydoc_replicas r on r.id = i.replica
                                              where i.doc = %s order by i.ord limit 1), 'Z'))), %L)$f$, d, d, who, d, who, d, who)
             when i % 15 = 0 then format('crdt.ydoc_set(%s, crdt.ydoc_value(%s) || %L, %L)', d, d, '#', who)
             else format('crdt.ydoc_insert(%s, (random() * crdt.ydoc_length(%s))::int, %L, %L)', d, d, chr(97 + i % 26), who)
        end || '; end $x$;', ' ')
    from generate_series(1, n) i
$$;
select pg_temp.script(:d, 'sa', 150) as sa, pg_temp.script(:d, 'sb', 150) as sb,
       pg_temp.script(:d, 'sc', 150) as sc, pg_temp.script(:d, 'se', 150) as se \gset
select crdt.ydoc_length(:d) as len0 \gset
select dblink_send_query('a', :'sa');
select dblink_send_query('b', :'sb');
select dblink_send_query('c', :'sc');
select dblink_send_query('e', :'se');
create temp table results (who text, stmts int, err text);
do $$
declare
    w text;
begin
    foreach w in array array['a', 'b', 'c', 'e'] loop
        begin
            insert into results values (w, pg_temp.drain(w), null);
        exception when others then
            insert into results values (w, null, sqlstate || ' ' || sqlerrm);
        end;
    end loop;
end;
$$;
select dblink_disconnect('a');
select dblink_disconnect('b');
select dblink_disconnect('c');
select dblink_disconnect('e');

select tap.plan(6);
select tap.ok(:'b_waited', 'B''s insert waited on A''s lock');
select tap.is(:'v1'::text, 'B start A', 'after A commits, B integrates against A''s version: both edits');
select tap.is((select string_agg(who || ': ' || coalesce(err, stmts::text), ', ' order by who) from results),
              'a: 150, b: 150, c: 150, e: 150', 'each session ran 150 transactions, no deadlock, no error');
-- per session: 15 deletes (i % 10 = 0), 6 applies (i % 25 = 0), 5 sets (i % 15 = 0, not % 10), 124 inserts
select tap.is(crdt.ydoc_version(:d), '{"base": 5, "sa": 137, "sb": 137, "sc": 135, "se": 135}'::jsonb,
              'every insert integrated exactly once (124 inserts + 5 set appends + 6 applies = 135 per session; +2 for sa and sb in step 1)');
select tap.is(crdt.ydoc_length(:d), 5 + 2 + 2 + 4 * (135 - 15), 'length adds up (15 deletes per session)');
select tap.is(pg_temp.ydoc_check(:d), '', 'invariants hold');
\else
\echo '# dblink is not available on this server; concurrency was NOT tested'
select tap.plan(1);
select tap.pass('SKIP dblink not available: concurrent edits');
\endif

select * from tap.finish();
