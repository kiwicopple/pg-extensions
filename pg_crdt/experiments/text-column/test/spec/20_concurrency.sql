-- Goal: concurrent writers on one row lose nothing under READ COMMITTED
-- (mirrors test/spec/20_concurrency.sql for pn_). Two dblink sessions:
--   1. Two editors load the same post, change different paragraphs, and
--      save with yseq_set(body, text, replica, base => loaded). A holds the
--      row lock; B's save waits, then applies to A's committed version:
--      both changes survive.
--   2. The same two saves without base: B's save overwrites the span it
--      changed, including A's paragraph (pinned, documented behaviour).
--   3. 200 single-statement transactions per session at the same time:
--      in-place inserts (yseq_insert at the end), set() against the current
--      text, and merges of each session's own replica states. Nothing lost.
--   4. Negative control: a client read-modify-write loses A's edit.
-- Needs dblink (contrib). Without it the file passes with SKIP assertions.

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

create table posts (id int primary key, body crdt.yseq not null default crdt.yseq_empty());
insert into posts (id, body) values
    (1, crdt.yseq_insert(crdt.yseq_empty(), 0, E'Para one.\nPara two.\nPara three.', 'author')),
    (2, crdt.yseq_insert(crdt.yseq_empty(), 0, E'Para one.\nPara two.\nPara three.', 'author')),
    (3, crdt.yseq_empty()), (4, crdt.yseq_empty()), (5, crdt.yseq_empty()),
    (6, crdt.yseq_insert(crdt.yseq_empty(), 0, 'Hello', 'author'));

select body as loaded from posts where id = 1 \gset

select format('dbname=%s user=%s port=%s host=%s', current_database(), current_user,
              current_setting('port'), split_part(current_setting('unix_socket_directories'), ',', 1)) as conn \gset
select dblink_connect('a', :'conn');
select dblink_connect('b', :'conn');

-- 1. with base: A edits paragraph one, B paragraph three
select dblink_exec('a', 'begin');
select dblink_exec('a', format($$update posts set body = crdt.yseq_set(body, %L, 'alice', base => %L) where id = 1$$,
                               E'Paragraph ONE.\nPara two.\nPara three.', :'loaded'));
select dblink_send_query('b', format($$update posts set body = crdt.yseq_set(body, %L, 'bob', base => %L) where id = 1$$,
                                     E'Para one.\nPara two.\nPara three, edited by Bob.', :'loaded'));
select pg_sleep(0.3);
select dblink_is_busy('b') = 1 as b_waited \gset
select dblink_exec('a', 'commit');
select pg_temp.drain('b');

-- 2. without base
select dblink_exec('a', format($$update posts set body = crdt.yseq_set(body, %L, 'alice') where id = 2$$,
                               E'Paragraph ONE.\nPara two.\nPara three.'));
select dblink_exec('b', format($$update posts set body = crdt.yseq_set(body, %L, 'bob') where id = 2$$,
                               E'Para one.\nPara two.\nPara three, edited by Bob.'));

-- 3. 200 transactions per session, at the same time
create table steps (who text, i int, st crdt.yseq);
do $$
declare
    s crdt.yseq := crdt.yseq_empty();
    w text;
begin
    foreach w in array array['a', 'b'] loop
        s := crdt.yseq_empty();
        for i in 1..200 loop
            s := crdt.yseq_insert(s, crdt.yseq_length(s), w, 'm' || w);
            insert into steps values (w, i, s);
        end loop;
    end loop;
end;
$$;
select string_agg(format($$begin; update posts set body = crdt.yseq_insert(body, crdt.yseq_length(body), 'a', 'alice') where id = 3; commit; $$
                       || $$begin; update posts set body = crdt.yseq_set(body, crdt.yseq_value(body) || 'a', 'alice') where id = 4; commit; $$
                       || $$begin; update posts set body = crdt.yseq_merge(body, %L) where id = 5; commit; $$, st), '' order by i)
       as script_a from steps where who = 'a' \gset
select string_agg(format($$begin; update posts set body = crdt.yseq_insert(body, 0, 'b', 'bob') where id = 3; commit; $$
                       || $$begin; update posts set body = crdt.yseq_set(body, 'b' || crdt.yseq_value(body), 'bob') where id = 4; commit; $$
                       || $$begin; update posts set body = crdt.yseq_merge(body, %L) where id = 5; commit; $$, st), '' order by i)
       as script_b from steps where who = 'b' \gset
select dblink_send_query('a', :'script_a');
select dblink_send_query('b', :'script_b');
select pg_temp.drain('a') as stmts_a \gset
select pg_temp.drain('b') as stmts_b \gset

-- 4. negative control
select body as stale from posts where id = 6 \gset
select dblink_exec('a', $$update posts set body = crdt.yseq_insert(body, 5, ' world', 'alice') where id = 6$$);
update posts set body = crdt.yseq_insert(:'stale', 0, '> ', 'bob') where id = 6;

select dblink_disconnect('a');
select dblink_disconnect('b');

select tap.plan(10);
select tap.ok(:'stmts_a' = 1800 and :'stmts_b' = 1800, 'each session ran 600 transactions');
select tap.ok(:'b_waited', 'B''s save waited on A''s row lock');
select tap.is((select crdt.yseq_value(body) from posts where id = 1), E'Paragraph ONE.\nPara two.\nPara three, edited by Bob.',
              'with base: both editors'' paragraphs survive');
select tap.is((select crdt.yseq_value(body) from posts where id = 2), E'Para one.\nPara two.\nPara three, edited by Bob.',
              'without base: the later save overwrites the span it changed (A''s paragraph is reverted)');
select tap.is((select crdt.yseq_value(body) from posts where id = 3), repeat('b', 200) || repeat('a', 200),
              '400 concurrent yseq_insert: none lost');
select tap.is((select length(crdt.yseq_value(body)) - length(replace(crdt.yseq_value(body), 'a', '')) from posts where id = 4), 200,
              '400 concurrent yseq_set against the current text: all of A''s characters');
select tap.is((select crdt.yseq_value(body) from posts where id = 4), repeat('b', 200) || repeat('a', 200), 'and all of B''s');
select tap.is((select crdt.yseq_version(body) from posts where id = 5), '{"ma": 200, "mb": 200}'::jsonb,
              '400 concurrent merges of replica states: both sessions'' final states are in');
select tap.ok((select crdt.yseq_is_valid(body) from posts where id = 3) and (select crdt.yseq_is_valid(body) from posts where id = 5), 'the states are valid');
select tap.is((select crdt.yseq_value(body) from posts where id = 6), '> Hello',
              'negative control: a client read-modify-write overwrote A''s edit (the unsafe pattern)');
\else
\echo '# dblink is not available on this server; concurrency was NOT tested'
select tap.plan(1);
select tap.pass('SKIP dblink not available');
\endif

select * from tap.finish();
