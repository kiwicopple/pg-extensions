-- Goal: public document ids. A document is named by text the client may
-- choose (a UUID, "post:123", a room name, unicode); crdt.ydoc_create() with
-- no argument makes a random UUID. The id is non-empty, at most 256 bytes,
-- without control characters (22023). Creating an id that exists is 23505
-- and never hands back the existing document (so a predictable id cannot be
-- squatted), including when two sessions create the same id at once. Ids are
-- compared byte for byte ("Post" and "post" are two documents). A base token
-- names its document by its public id.
-- The concurrent part needs dblink (contrib); without it those assertions SKIP.
\i :ext_dir/test/lib/text-helpers.sql

create function pg_temp.why(q text) returns text language plpgsql as $$
begin
    execute q;
    return 'ok';
exception when others then
    return sqlstate;
end;
$$;

-- generated ids
select crdt.ydoc_create() as g1, crdt.ydoc_create() as g2 \gset
select pg_typeof(crdt.ydoc_create())::text as gtype \gset

-- client-chosen ids
select crdt.ydoc_create('0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d') as c_uuid,
       crdt.ydoc_create('post:123') as c_key,
       crdt.ydoc_create('héllo wörld 😀 日本語') as c_uni,
       crdt.ydoc_create(id => 'named-arg') as c_named \gset
select crdt.ydoc_insert('post:123', 0, 'abc', 'alice') \g /dev/null
select crdt.ydoc_insert('héllo wörld 😀 日本語', 0, 'unicode', 'alice') \g /dev/null

-- case and byte-for-byte comparison
select crdt.ydoc_create('post') as lc, crdt.ydoc_create('Post') as uc, crdt.ydoc_create('post ') as sp \gset
select crdt.ydoc_insert('post', 0, 'lower', 'alice') \g /dev/null
select crdt.ydoc_insert('Post', 0, 'UPPER', 'alice') \g /dev/null

-- limits: 256 bytes is fine (also as 128 two-byte characters), 257 is not
select crdt.ydoc_create(repeat('x', 256)) = repeat('x', 256) as ok256 \gset
select crdt.ydoc_create(repeat('é', 128)) = repeat('é', 128) as ok256_multibyte \gset

-- a creation that finds the id taken: message, hint, and the document is untouched
select crdt.ydoc_insert('named-arg', 0, 'mine', 'alice') \g /dev/null
do $$
declare h text;
begin
    perform crdt.ydoc_create('named-arg');
exception when unique_violation then
    get stacked diagnostics h = pg_exception_hint;
    perform set_config('crdt_test.dup_msg', sqlerrm, false);
    perform set_config('crdt_test.dup_hint', h, false);
end;
$$;
select current_setting('crdt_test.dup_msg') as dup_msg, current_setting('crdt_test.dup_hint') as dup_hint \gset

-- the default is evaluated in the caller's context: a function of the same
-- name earlier on the search_path must not be picked up
create schema evil;
create function evil.gen_random_uuid() returns uuid language sql as $$ select '00000000-0000-0000-0000-000000000000'::uuid $$;
set search_path = evil, pg_catalog, public;
select crdt.ydoc_create() as sp_default \gset
reset search_path;

-- another document's base
select crdt.ydoc_base('post:123') as base_key \gset
select crdt.ydoc_base('post') as base_lc \gset

select exists (select 1 from pg_available_extensions where name = 'dblink') as has_dblink \gset
\if :has_dblink
select tap.plan(49);
\else
select tap.plan(43);
\endif
select tap.ok(:'g1'::text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', 'the default id is a UUID in text form');
select tap.isnt(:'g1'::text, :'g2'::text, 'two generated ids differ');
select tap.is(:'gtype'::text, 'text', 'ydoc_create returns text');
select tap.is(crdt.ydoc_value(:'g1'), '', 'a generated id names an empty document');
select tap.is(:'c_uuid'::text, '0192f1c4-7b3e-7c1a-9d52-3f6a8e1b2c4d', 'a UUID chosen by the client works as the id (returned as given)');
select tap.is(:'c_key'::text, 'post:123', 'an application key works as the id');
select tap.is(:'c_uni'::text, 'héllo wörld 😀 日本語', 'a unicode id works');
select tap.is(:'c_named'::text, 'named-arg', 'the argument is named id');
select tap.is(crdt.ydoc_value('post:123'), 'abc', 'edits go to the document named by the id');
select tap.is(crdt.ydoc_value('héllo wörld 😀 日本語'), 'unicode', 'edits go to the unicode-named document');
select tap.is(pg_temp.ydoc_check('post:123') || pg_temp.ydoc_check('héllo wörld 😀 日本語'), '', 'invariants hold');
select tap.is((select count(*)::int from crdt.ydoc_blocks where doc = pg_temp.did('post:123')), 1, 'creating a document makes its first block');

select tap.is(crdt.ydoc_value('post'), 'lower', '"post" and "Post" are different documents (lower)');
select tap.is(crdt.ydoc_value('Post'), 'UPPER', '"post" and "Post" are different documents (upper)');
select tap.is(crdt.ydoc_value('post '), '', 'a trailing space makes another id');
select tap.is(:'ok256'::text, 't', '256 bytes is allowed');
select tap.is(:'ok256_multibyte'::text, 't', '128 two-byte characters (256 bytes) are allowed');

select tap.is(pg_temp.why($$select crdt.ydoc_create('post:123')$$), '23505', 'an existing id raises 23505');
select tap.is(pg_temp.why($$select crdt.ydoc_create('POST:123')$$), 'ok', 'ids are case sensitive: another id is free');
select tap.is(:'dup_msg'::text, 'crdt.ydoc_create: document ''named-arg'' already exists', '23505 carries the extension''s message, not the constraint''s');
select tap.is(crdt.ydoc_value('named-arg'), 'mine', 'the existing document is not returned, replaced or reset');
select tap.is(pg_temp.why($$select crdt.ydoc_create(id => 'named-arg')$$), '23505', 'an existing id raises 23505 with the argument named too');
select tap.ok((:'dup_hint'::text) like '%not created idempotently%', '23505 has a hint that says why');

select tap.is(pg_temp.why($$select crdt.ydoc_create('')$$), '22023', 'empty id: 22023');
select tap.is(pg_temp.why($$select crdt.ydoc_create(null)$$), '22023', 'null id: 22023');
select tap.is(pg_temp.why(format('select crdt.ydoc_create(%L)', repeat('x', 257))), '22023', '257 bytes: 22023');
select tap.is(pg_temp.why(format('select crdt.ydoc_create(%L)', repeat('é', 129))), '22023', '129 two-byte characters (258 bytes): 22023');
select tap.is(pg_temp.why(format('select crdt.ydoc_create(%L)', E'a\tb')), '22023', 'tab: 22023');
select tap.is(pg_temp.why(format('select crdt.ydoc_create(%L)', E'a\nb')), '22023', 'newline: 22023');
select tap.is(pg_temp.why(format('select crdt.ydoc_create(%L)', E'a\x1bb')), '22023', 'escape character: 22023');
select tap.is(pg_temp.why(format('select crdt.ydoc_create(%L)', E'a\x7fb')), '22023', 'DEL: 22023');
select tap.is(pg_temp.why(format('select crdt.ydoc_create(%L)', E'a\u0085b')), '22023', 'C1 control character: 22023');
select tap.is(pg_temp.why($$insert into crdt.ydoc_docs (uid) values ('')$$), '23514', 'the table refuses an empty uid too (check constraint)');
select tap.is(pg_temp.why(format('insert into crdt.ydoc_docs (uid) values (%L)', E'a\tb')), '23514', 'the table refuses a control character too (check constraint)');

select tap.is(:'sp_default'::text, (select uid from crdt.ydoc_docs where uid = :'sp_default'), 'the default ran in the extension''s schema context');
select tap.isnt(:'sp_default'::text, '00000000-0000-0000-0000-000000000000', 'a function of the same name earlier on the search_path is not used for the default');

select tap.is(:'base_key'::jsonb ->> 'd', 'post:123', 'the base token carries the public id');
select tap.throws_ok(format('select crdt.ydoc_set(%L, %L, %L, %L)', 'post', 'x', 'alice', :'base_key'), '22023', 'a base token from another document is refused');
select tap.lives_ok(format('select crdt.ydoc_set(%L, %L, %L, %L)', 'post', 'lower!', 'alice', :'base_lc'), 'a base token from the same document is accepted');
select tap.throws_ok(format('select crdt.ydoc_set(%L, %L, %L, %L)', 'post', 'x', 'alice', '{"d": 1, "g": 1, "v": {}}'), '22023', 'a base token naming the document by a number is refused');

-- unknown documents
select tap.is(pg_temp.why($$select crdt.ydoc_insert('nope', 0, 'x', 'alice')$$) || ' ' || pg_temp.why($$select crdt.ydoc_delete('nope', 0, 0, 'alice')$$)
              || ' ' || pg_temp.why($$select crdt.ydoc_set('nope', 'x', 'alice')$$) || ' ' || pg_temp.why($$select crdt.ydoc_apply('nope', '{"v": {}, "i": [["alice", 1, null, null, "x"]]}', 'alice')$$)
              || ' ' || pg_temp.why($$select crdt.ydoc_merge('nope', '{}')$$) || ' ' || pg_temp.why($$select crdt.ydoc_compact('nope')$$)
              || ' ' || pg_temp.why($$select crdt.ydoc_drop('nope')$$) || ' ' || pg_temp.why($$select crdt.ydoc_ops_since('nope')$$),
              'P0002 P0002 P0002 P0002 P0002 P0002 P0002 P0002', 'an unknown document: every write and ops_since raise P0002');
select tap.is(crdt.ydoc_value('nope') is null and crdt.ydoc_length('nope') is null and crdt.ydoc_base('nope') is null
              and crdt.ydoc_version('nope') = '{}'::jsonb, true, 'an unknown document: value, length and base are null, version is empty');

-- concurrent creates of one id

\if :has_dblink
create extension dblink;

create function pg_temp.settle(conn text) returns text language plpgsql as $$
declare r text;
begin
    begin
        select x.id into r from dblink_get_result(conn) as x(id text);
    exception when others then
        r := sqlstate;
    end;
    -- consume the rest of the results
    begin
        perform 1 from dblink_get_result(conn) as x(id text);
    exception when others then
        null;
    end;
    return r;
end;
$$;

select format('dbname=%s user=%s port=%s host=%s', current_database(), current_user,
              current_setting('port'), split_part(current_setting('unix_socket_directories'), ',', 1)) as conn \gset
select dblink_connect('a', :'conn');
select dblink_connect('b', :'conn');

-- 1. A creates the id in an open transaction; B's create of the same id
--    waits, and when A commits B gets 23505 with the extension's message.
select dblink_exec('a', 'begin');
select dblink_send_query('a', $$select crdt.ydoc_create('race:1')$$);
select pg_temp.settle('a') as a1 \gset
select dblink_send_query('b', $$select crdt.ydoc_create('race:1')$$);
select pg_sleep(0.3);
select dblink_is_busy('b') = 1 as b_waited \gset
select dblink_exec('a', 'commit');
select pg_temp.settle('b') as b1 \gset

-- 2. A creates the id and rolls back; B's waiting create then succeeds.
select dblink_exec('a', 'begin');
select dblink_send_query('a', $$select crdt.ydoc_create('race:2')$$);
select pg_temp.settle('a') as a2 \gset
select dblink_send_query('b', $$select crdt.ydoc_create('race:2')$$);
select pg_sleep(0.3);
select dblink_exec('a', 'rollback');
select pg_temp.settle('b') as b2 \gset

-- 3. Both at once, no transaction held open: exactly one succeeds, the other
--    gets 23505. Repeated for 30 ids.
create temp table race (n int, ra text, rb text);
do $$
declare ra text; rb text;
begin
    for n in 1 .. 30 loop
        perform dblink_send_query('a', format('select crdt.ydoc_create(%L)', 'race:x' || n));
        perform dblink_send_query('b', format('select crdt.ydoc_create(%L)', 'race:x' || n));
        ra := pg_temp.settle('a');
        rb := pg_temp.settle('b');
        insert into race values (n, ra, rb);
    end loop;
end;
$$;
select dblink_disconnect('a');
select dblink_disconnect('b');

select tap.is(:'a1'::text, 'race:1', 'concurrent create: the first session creates the id');
select tap.ok(:'b_waited', 'concurrent create: the second session waited on the first');
select tap.is(:'b1'::text, '23505', 'concurrent create: the second session gets 23505 once the first commits');
select tap.is(:'b2'::text, 'race:2', 'concurrent create: the second session creates the id when the first rolls back');
select tap.is((select count(*)::int from race where (ra = 'race:x' || n) <> (rb = 'race:x' || n) and (ra = '23505' or rb = '23505')), 30,
              'two sessions creating one id at once: exactly one succeeds and the other gets 23505 (30 ids)');
select tap.is((select count(*)::int from crdt.ydoc_docs where uid = 'race:1' or uid = 'race:2' or uid like 'race:x%'), 32, 'one document per raced id');
select tap.is((select count(*)::int from crdt.ydoc_blocks b join crdt.ydoc_docs d on d.id = b.doc where d.uid like 'race:%'), 32, 'each raced document has exactly one first block');
\else
\echo '# dblink is not available on this server; concurrent creates were NOT tested'
select tap.pass('SKIP dblink not available: concurrent creates');
\endif

select * from tap.finish();
