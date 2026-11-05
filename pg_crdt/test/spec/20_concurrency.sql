-- Goal: `update t set s = crdt.pn_merge(s, $1) where id = $2` from two
-- concurrent sessions loses no update under READ COMMITTED
-- (sql-integration.md B1). Two dblink sessions write the same row:
--   1. A holds the row lock in an open transaction; B's merge waits; A
--      commits; B's merge must apply to A's new row version.
--   2. Both sessions run 300 single-statement transactions each, at the same
--      time: the increments in place and the delta merges all count.
--   3. The negative control: a client read-merge-write (read in one
--      statement, write the merged value back in another) does lose A's
--      update, so the test can see a lost update when there is one.
-- Needs dblink (contrib). Without it the file passes with SKIP assertions.

select exists (select 1 from pg_available_extensions where name = 'dblink') as has_dblink \gset

\if :has_dblink
create extension dblink;

-- Read every result of an async query (one per statement) until the
-- connection is idle; an error result raises here.
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

create table t (id int primary key, s crdt.pn not null default crdt.pn_empty());
insert into t (id) values (1), (2), (3);

select format('dbname=%s user=%s port=%s host=%s', current_database(), current_user,
              current_setting('port'), split_part(current_setting('unix_socket_directories'), ',', 1)) as conn \gset
select dblink_connect('a', :'conn');
select dblink_connect('b', :'conn');

-- 1. B waits on A's row lock, then merges into A's committed version.
select dblink_exec('a', 'begin');
select dblink_exec('a', $$update t set s = crdt.pn_merge(s, '{"t": "pn", "v": 1, "p": {"a": 5}, "n": {}}') where id = 1$$);
select dblink_send_query('b', $$update t set s = crdt.pn_merge(s, '{"t": "pn", "v": 1, "p": {"b": 7}, "n": {"b": 1}}') where id = 1$$);
select pg_sleep(0.3);
select dblink_is_busy('b') = 1 as b_waited \gset
select (select count(*) from pg_stat_activity where wait_event_type = 'Lock' and query like '%update t set s%') as lock_waiters \gset
select dblink_exec('a', 'commit');
select pg_temp.drain('b');

-- 2. 300 transactions per session, at the same time, on rows 2 and 3.
--    Row 2: increments in place (each session its own replica id).
--    Row 3: each session merges its own running total as a delta.
select string_agg(format($$begin; update t set s = crdt.pn_increment(s, 'a', 1) where id = 2; commit; $$
                       || $$begin; update t set s = crdt.pn_merge(s, '{"t": "pn", "v": 1, "p": {"a": %s}, "n": {}}') where id = 3; commit; $$, i), '')
       as script_a from generate_series(1, 300) i \gset
select string_agg(format($$begin; update t set s = crdt.pn_decrement(s, 'b', 1) where id = 2; commit; $$
                       || $$begin; update t set s = crdt.pn_merge(s, '{"t": "pn", "v": 1, "p": {"b": %s}, "n": {}}') where id = 3; commit; $$, i), '')
       as script_b from generate_series(1, 300) i \gset
select dblink_send_query('a', :'script_a');
select dblink_send_query('b', :'script_b');
select pg_temp.drain('a') as stmts_a \gset
select pg_temp.drain('b') as stmts_b \gset

-- 3. Negative control: read-merge-write in the client loses an update.
insert into t (id) values (4);
select s as stale from t where id = 4 \gset
select dblink_exec('a', $$update t set s = crdt.pn_increment(s, 'a', 10) where id = 4$$);
update t set s = crdt.pn_merge(:'stale', '{"t": "pn", "v": 1, "p": {"b": 1}, "n": {}}') where id = 4;

select dblink_disconnect('a');
select dblink_disconnect('b');

select tap.plan(8);
select tap.ok(:'stmts_a' = 1800 and :'stmts_b' = 1800,
              'each session ran 600 transactions (1,800 statements: begin, update, commit)');
select tap.ok(:'b_waited' and :'lock_waiters' >= 1, 'B''s merge waited on A''s row lock');
select tap.is((select s::jsonb from t where id = 1),
              '{"t": "pn", "v": 1, "p": {"a": 5, "b": 7}, "n": {"b": 1}}'::jsonb,
              'after A commits, B''s merge applies to A''s row version: both deltas are in the state');
select tap.is((select crdt.pn_value(s) from t where id = 1), 11::bigint, 'and the value counts both (5 + 7 - 1)');
select tap.is((select s::jsonb from t where id = 2),
              '{"t": "pn", "v": 1, "p": {"a": 300}, "n": {"b": 300}}'::jsonb,
              '600 concurrent in-place increments and decrements: none lost');
select tap.is((select s::jsonb from t where id = 3),
              '{"t": "pn", "v": 1, "p": {"a": 300, "b": 300}, "n": {}}'::jsonb,
              '600 concurrent delta merges: both sessions'' final totals are in the state');
select tap.is((select crdt.pn_value(s) from t where id = 3), 600::bigint, 'and the value is 600');
select tap.is((select s::jsonb from t where id = 4),
              '{"t": "pn", "v": 1, "p": {"b": 1}, "n": {}}'::jsonb,
              'negative control: a client read-merge-write overwrote A''s increment (the unsafe pattern)');
\else
\echo '# dblink is not available on this server; concurrency was NOT tested'
select tap.plan(1);
select tap.pass('SKIP dblink not available: concurrent merges');
\endif

select * from tap.finish();
