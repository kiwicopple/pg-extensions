-- Goal: OpenFGA's limits on the API functions (research/decision.md, end of session 4,
-- point 4; research/designs/d-per-model.md section 4). ListObjects and ListUsers return
-- at most 1,000 results, silently truncated like OpenFGA (which ones survive is
-- unspecified, so only the count and membership in the true set are
-- asserted); the RLS helpers (fga_list_objects_current,
-- fga_list_object_ids_current) are uncapped. Write takes at most 100 tuple
-- keys (writes + deletes) per call: 2053 exceeded_entity_limit. Read is
-- paginated in insertion order: page_size (default 50, 1..100) and an opaque
-- continuation_token ('' on the last page); a malformed token is 2000, a
-- well-formed one that doesn't decode to a position is 2007.
\ir ../../fixtures/ids.sql
\ir ../../fixtures/fga_suite.sql

select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "document", "relations": {"viewer": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]}$m$::jsonb) as m \gset

-- 1,050 documents anne views, 1,000 bob views, 1,050 users viewing document:big;
-- loaded through fga_write in batches of 100 (the write cap)
select count(permissions.fga_write(keys)) from (
    select jsonb_agg(jsonb_build_object('user', 'user:anne', 'relation', 'viewer', 'object', 'document:' || g)) keys
    from generate_series(1, 1050) g group by (g - 1) / 100) b;
select count(permissions.fga_write(keys)) from (
    select jsonb_agg(jsonb_build_object('user', 'user:bob', 'relation', 'viewer', 'object', 'document:' || g)) keys
    from generate_series(1, 1000) g group by (g - 1) / 100) b;
select count(permissions.fga_write(keys)) from (
    select jsonb_agg(jsonb_build_object('user', 'user:u' || g, 'relation', 'viewer', 'object', 'document:big')) keys
    from generate_series(1, 1050) g group by (g - 1) / 100) b;

select tap.plan(49);

-- ListObjects: capped at 1,000, a subset of the true set
create temp table lo as select permissions.fga_list_objects('user:anne', 'document', 'viewer') o;
create temp table lo_all as
    select 'document:' || i o from permissions._fga_list_object_ids(:'m', 'document', 'viewer', 'user', 'anne', '', '{}') i;
select tap.is((select count(*)::int from lo_all), 1050, 'the uncapped ListObjects finds all 1,050 documents');
select tap.is((select count(*)::int from lo), 1000, 'fga_list_objects returns 1,000 of them (OpenFGA''s cap)');
select tap.is((select count(distinct o)::int from lo), 1000, 'with no duplicates');
select tap.is((select count(*)::int from lo where o not in (select o from lo_all)), 0, 'every one is in the true set');
select tap.is((select count(*)::int from permissions.fga_list_objects('user:bob', 'document', 'viewer')), 1000,
              'exactly 1,000 results come back whole');
select tap.is((select count(*)::int from permissions.fga_list_objects('user:anne', 'document', 'viewer',
                                                                      '[{"user": "user:anne", "relation": "viewer", "object": "document:extra"}]')),
              1000, 'contextual tuples do not lift the cap');

-- the RLS helpers are uncapped: a cap there would silently hide rows
select set_config('permissions.subject_id', 'anne', false);
select tap.is((select count(*)::int from permissions.fga_list_object_ids_current('document', 'viewer')), 1050,
              'fga_list_object_ids_current returns all 1,050');
select tap.is((select count(*)::int from permissions.fga_list_objects_current('document', 'viewer')), 1050,
              'fga_list_objects_current returns all 1,050');
select set_config('permissions.subject_id', '', false);

-- ListUsers: capped at 1,000, a subset of the true set
create temp table lu as select permissions.fga_list_users('document:big', 'viewer', '{user}') u;
create temp table lu_all as select permissions._fga_list_users('document:big', 'viewer', '{user}') u;
select tap.is((select count(*)::int from lu_all), 1050, 'the uncapped ListUsers finds all 1,050 users');
select tap.is((select count(*)::int from lu), 1000, 'fga_list_users returns 1,000 of them');
select tap.is((select count(distinct u)::int from lu), 1000, 'with no duplicates');
select tap.is((select count(*)::int from lu where u not in (select u from lu_all)), 0, 'every one is in the true set');

-- Write: at most 100 tuple keys per call, writes and deletes together
select tap.is(fga_test.code_of($$ select permissions.fga_write(
    (select jsonb_agg(jsonb_build_object('user', 'user:w' || g, 'relation', 'viewer', 'object', 'document:w')) from generate_series(1, 100) g)) $$),
    'ok', '100 writes in one call are allowed');
select tap.is(fga_test.code_of($$ select permissions.fga_write(
    (select jsonb_agg(jsonb_build_object('user', 'user:x' || g, 'relation', 'viewer', 'object', 'document:w')) from generate_series(1, 101) g)) $$),
    'openfga:2053 The number of write operations exceeds the allowed limit of 100: got 101 tuple keys (101 writes, 0 deletes)',
    '101 writes fail with 2053, naming the count and the limit');
select tap.is((select count(*)::int from permissions.fga_tuples where object_id = 'w'), 100, 'and write nothing');
select tap.ok(fga_test.code_of($$ select permissions.fga_write(
    (select jsonb_agg(jsonb_build_object('user', 'user:x' || g, 'relation', 'viewer', 'object', 'document:w')) from generate_series(1, 60) g),
    (select jsonb_agg(jsonb_build_object('user', 'user:w' || g, 'relation', 'viewer', 'object', 'document:w')) from generate_series(1, 41) g)) $$)
    like 'openfga:2053 % got 101 tuple keys (60 writes, 41 deletes)', 'writes and deletes count together');
select tap.is(fga_test.code_of($$ select permissions.fga_write(
    (select jsonb_agg(jsonb_build_object('user', 'user:x' || g, 'relation', 'viewer', 'object', 'document:w')) from generate_series(1, 50) g),
    (select jsonb_agg(jsonb_build_object('user', 'user:w' || g, 'relation', 'viewer', 'object', 'document:w')) from generate_series(1, 50) g)) $$),
    'ok', '50 writes and 50 deletes are allowed');
select tap.ok(fga_test.code_of($$ select permissions.fga_write(
    (select jsonb_agg(jsonb_build_object('user', 'user:y' || least(g, 100), 'relation', 'viewer', 'object', 'document:w')) from generate_series(1, 101) g)) $$)
    like 'openfga:2004 %', 'a duplicate is reported before the count (2004)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write(
    jsonb_build_object('tuple_keys', (select jsonb_agg(jsonb_build_object('user', 'user:z' || g, 'relation', 'viewer', 'object', 'document:w')) from generate_series(1, 101) g),
                       'on_duplicate', 'ignore')) $$)
    like 'openfga:2053 %', 'on_duplicate ignore does not lift the cap');
select tap.is(
    (select array[e.st, e.hint] from fga_test.error_of($$ select permissions.fga_write(
        (select jsonb_agg(jsonb_build_object('user', 'user:x' || g, 'relation', 'viewer', 'object', 'document:w')) from generate_series(1, 101) g)) $$) e),
    array['22023', 'Split the tuple keys into batches of at most 100 and call fga_write once per batch: calls in one transaction commit or roll back together.'],
    '2053 is SQLSTATE 22023 with a hint to split into batches');

-- Write: an empty list that is given is a validation error, as OpenFGA's
-- min_items; nothing given at all is 2003
select tap.ok(fga_test.code_of($$ select permissions.fga_write('[]') $$) like 'openfga:2000 %', 'an empty writes array fails (2000)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write('{"tuple_keys": []}') $$) like 'openfga:2000 %', 'empty writes tuple_keys fail (2000)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write('[{"user": "user:q", "relation": "viewer", "object": "document:q"}]', '[]') $$)
              like 'openfga:2000 %', 'an empty deletes array next to a write fails (2000)');
select tap.ok(fga_test.code_of($$ select permissions.fga_write() $$) like 'openfga:2003 %', 'no writes and no deletes fail (2003)');

-- Read: a fresh store, 120 tuples written in three calls, anne's and bob's interleaved
select permissions.fga_delete_store();
select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "document", "relations": {"viewer": {"this": {}}, "editor": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]},
                                "editor": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]}$m$::jsonb) as m \gset
create temp table written as
    select g, jsonb_build_object('user', case when g % 6 = 0 then 'user:bob' else 'user:anne' end,
                                 'relation', 'viewer', 'object', 'document:' || lpad(((g * 37) % 1000)::text, 3, '0')) k
    from generate_series(1, 120) g;
select count(permissions.fga_write(keys)) from (select jsonb_agg(k order by g) keys from written group by (g - 1) / 40 order by 1) b;

-- walks the whole store (with optional filters), returning page sizes and every key in order
create function pg_temp.walk(p_size int, p_object text default null, p_relation text default null, p_user text default null)
returns table (sizes int[], keys jsonb[], last_token text, pages int)
language plpgsql
as $$
declare
    tok text := '';
    r record;
begin
    sizes := '{}'; keys := '{}'; pages := 0;
    loop
        select * into r from permissions.fga_read(p_object, p_relation, p_user, p_size, tok);
        pages := pages + 1;
        sizes := sizes || jsonb_array_length(r.tuples);
        keys := keys || array(select t -> 'key' from jsonb_array_elements(r.tuples) with ordinality x(t, i) order by i);
        tok := r.continuation_token;
        exit when tok = '' or pages > 200;
    end loop;
    last_token := tok;
    return next;
end;
$$;

select tap.is((select sizes from pg_temp.walk(50)), '{50,50,20}', 'page_size 50: pages of 50, 50 and 20');
select tap.is((select keys from pg_temp.walk(50)), (select array_agg(k order by g) from written),
              'every tuple exactly once, in insertion order');
select tap.is((select sizes from pg_temp.walk(40)), '{40,40,40}', 'an exactly full last page ends the walk (no empty page)');
select tap.is((select sizes from pg_temp.walk(null)), '{50,50,20}', 'page_size null is 50');
select tap.is((select sizes from pg_temp.walk(100)), '{100,20}', 'page_size 100 is allowed');
select tap.is((select cardinality(sizes) from pg_temp.walk(1)), 120, 'page_size 1 walks one tuple at a time');
select tap.is((select keys from pg_temp.walk(7, 'document:', 'viewer', 'user:bob')),
              (select array_agg(k order by g) from written where k ->> 'user' = 'user:bob'),
              'a filtered walk returns the matching tuples once each, in insertion order');
select tap.is((select sizes from pg_temp.walk(7, 'document:', 'viewer', 'user:bob')), '{7,7,6}', 'in pages of the requested size');

select tuples, continuation_token from permissions.fga_read(null, null, null, 50) \gset first_
select tap.ok(:'first_continuation_token' ~ '^[A-Za-z0-9_-]+={0,2}$', 'the token is base64url');
select tap.is((select t #> '{key}' from jsonb_array_elements(:'first_tuples'::jsonb) t limit 1),
              (select k from written where g = 1), 'each tuple has OpenFGA''s key {user, relation, object}');
select tap.ok((select (t ->> 'timestamp')::timestamptz <= now() from jsonb_array_elements(:'first_tuples'::jsonb) t limit 1),
              'and a timestamp');
select tap.is((select tuples from permissions.fga_read(null, null, null, 50, '')), :'first_tuples'::jsonb, 'token '''' is the first page');
select tap.is((select continuation_token from permissions.fga_read('document:nope')), '', 'nothing matches: no tuples and token ''''');
select tap.is((select tuples from permissions.fga_read('document:nope')), '[]'::jsonb, 'and an empty array');

-- a token whose tuple was deleted in between: the next page starts after it
select permissions.fga_write(deletes => jsonb_build_array((select k from written where g = 51)));
select tap.is((select array(select t -> 'key' from jsonb_array_elements(tuples) t)
               from permissions.fga_read(null, null, null, 3, :'first_continuation_token')),
              (select array_agg(k order by g) from written where g in (52, 53, 54)),
              'a token for a tuple deleted since then seeks past it');
select tap.is((select tuples from permissions.fga_read(null, null, null, 3,
                 translate(encode(convert_to('999999999|', 'UTF8'), 'base64'), '+/', '-_'))),
              '[]'::jsonb, 'a well-formed token beyond the last tuple gives an empty page');

-- page_size and token validation
select tap.ok(fga_test.code_of($$ select permissions.fga_read(page_size => 0) $$) like 'openfga:2000 %', 'page_size 0 fails (2000)');
select tap.is(fga_test.code_of($$ select permissions.fga_read(page_size => 101) $$),
              'openfga:2000 invalid ReadRequest.PageSize: value must be inside range [1, 100], got 101', 'page_size 101 fails (2000)');
select tap.ok(fga_test.code_of($$ select permissions.fga_read(page_size => -5) $$) like 'openfga:2000 %', 'a negative page_size fails (2000)');
select tap.ok(fga_test.code_of($$ select permissions.fga_read(continuation_token => 'not a token!') $$) like 'openfga:2000 %',
              'a token outside the base64url alphabet fails (2000)');
select tap.ok(fga_test.code_of($$ select permissions.fga_read(continuation_token => repeat('A', 5121)) $$) like 'openfga:2000 %',
              'a token over 5,120 bytes fails (2000)');
select tap.ok(fga_test.code_of($$ select permissions.fga_read(continuation_token => 'AAAA') $$) like 'openfga:2007 %',
              'a token that decodes to the wrong shape fails (2007)');
select tap.ok(fga_test.code_of($$ select permissions.fga_read(continuation_token => 'A') $$) like 'openfga:2007 %',
              'a token that is not valid base64 fails (2007)');
select tap.ok(fga_test.code_of(format('select permissions.fga_read(continuation_token => %L)',
                                      translate(encode(convert_to('abc|', 'UTF8'), 'base64'), '+/', '-_'))) like 'openfga:2007 %',
              'a token with a non-numeric position fails (2007)');
select tap.is(
    (select array[e.st, e.hint] from fga_test.error_of($$ select permissions.fga_read(continuation_token => 'AAAA') $$) e),
    array['22023', 'Pass the continuation_token from the previous fga_read call unchanged, or '''' (or null) for the first page.'],
    '2007 is SQLSTATE 22023 with a hint');

select * from tap.finish();
