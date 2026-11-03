-- Goal: permissions.cedar_uid(type, id) builds Type::"id" with Cedar's
-- string escapes, the same text as uid() in js/src/cedar/uid.ts, so a
-- policy builds a resource uid from a row id without a parse error or a
-- different id (research/plan-cedar.md, phase 8). The cases are the ids of
-- 58_cedar_rls_ids.sql: " and \, and the control characters chr(28) and
-- chr(30). The expected strings are what the JS helper returns.
select tap.plan(19);

-- parity with uid() in the JS client
select tap.is(permissions.cedar_uid('Doc', 'open'), 'Doc::"open"', 'a plain id');
select tap.is(permissions.cedar_uid('Doc', 'x"y'), 'Doc::"x\"y"', '" gets a backslash');
select tap.is(permissions.cedar_uid('Doc', 'p\q'), 'Doc::"p\\q"', '\ gets a backslash');
select tap.is(permissions.cedar_uid('Doc', 'a"b\c'), 'Doc::"a\"b\\c"', 'both together');
select tap.is(permissions.cedar_uid('Doc', 'a' || chr(10) || 'b'), 'Doc::"a\nb"', 'newline is \n');
select tap.is(permissions.cedar_uid('Doc', chr(13) || chr(9)), 'Doc::"\r\t"', 'CR and tab are \r and \t');
select tap.is(permissions.cedar_uid('Doc', 's' || chr(28) || 't' || chr(30) || 'u'), 'Doc::"s\u{1c}t\u{1e}u"',
              'chr(28) and chr(30) are \u{1c} and \u{1e}');
select tap.is(permissions.cedar_uid('Doc', chr(1) || chr(31) || chr(127)), 'Doc::"\u{1}\u{1f}\u{7f}"',
              'other control characters and DEL are \u{hex}');
select tap.is(permissions.cedar_uid('Doc', 'caf' || chr(233) || ' ' || chr(128512)), 'Doc::"caf' || chr(233) || ' ' || chr(128512) || '"',
              'other characters stay as they are');
select tap.is(permissions.cedar_uid('A::B', ''), 'A::B::""', 'an empty id and a namespaced type');
select tap.is(permissions.cedar_uid('Doc', null), null, 'a null id gives null');
select tap.is(permissions.cedar_uid(null, 'd1'), null, 'a null type gives null');

-- the text parses back to the same entity
select permissions.cedar_put_entities(entities => jsonb_build_array(
    jsonb_build_object('uid', jsonb_build_object('type', 'user', 'id', 'a"b\c')),
    jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'x"y')),
    jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'p\q')),
    jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'a' || chr(10) || 'b')),
    jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 's' || chr(28) || 't' || chr(30) || 'u')),
    jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'open'))));
select permissions.cedar_put_policy(policy_id => 'view-docs',
    policy => 'permit (principal, action == Action::"view", resource is Doc);');
select permissions.cedar_put_policy(policy_id => 'only-nl',
    policy => 'permit (principal, action == Action::"edit", resource == Doc::"a\nb");');
select tap.set_eq(
    (select array_agg(d.id)
     from (values ('open'), ('x"y'), ('p\q'), ('a' || chr(10) || 'b'), ('s' || chr(28) || 't' || chr(30) || 'u')) d(id)
     where permissions.cedar_is_authorized(
               principal => permissions.cedar_uid('user', 'a"b\c'),
               action => 'Action::"view"',
               resource => permissions.cedar_uid('Doc', d.id)) ->> 'decision' = 'allow'),
    array[E'a\nb', 'open', E's\x1ct\x1eu', 'p\q', 'x"y']::text[],
    'every uid from cedar_uid parses as its own entity');
select tap.set_eq(
    (select array_agg(d.id)
     from (values ('open'), ('x"y'), ('a' || chr(10) || 'b')) d(id)
     where permissions.cedar_is_authorized(
               principal => permissions.cedar_uid('user', 'a"b\c'),
               action => 'Action::"edit"',
               resource => permissions.cedar_uid('Doc', d.id)) ->> 'decision' = 'allow'),
    array[E'a\nb']::text[],
    'a newline id is its own id, not another one (unescaped text would be a parse error)');

-- the same ids as RLS rows, for a current subject
select set_config('permissions.subject_id', 'a"b\c', false);
create table public.docs (id text primary key);
insert into public.docs
select d.id
from (values ('open'), ('x"y'), ('p\q'), ('a' || chr(10) || 'b'), ('s' || chr(28) || 't' || chr(30) || 'u')) d(id);
alter table public.docs enable row level security;
grant select on public.docs to authenticated;
create policy docs_view on public.docs
    for select
    to authenticated
    using (permissions.cedar_is_authorized_current(
        action => 'Action::"view"',
        resource => permissions.cedar_uid('Doc', id)));
set role authenticated;
select tap.is((select count(*) from public.docs), 5::bigint,
              'RLS with cedar_uid shows every row, whatever its id holds');
select tap.is(permissions.cedar_is_authorized_current(
                  action => 'Action::"edit"',
                  resource => permissions.cedar_uid('Doc', 'a' || chr(10) || 'b')),
              true, 'authenticated can call cedar_uid in a check');
reset role;

-- catalog properties
select tap.ok(
    (select p.provolatile = 'i' and p.proparallel = 's' and p.proisstrict
            and 'search_path=pg_catalog, pg_temp' = any(p.proconfig)
     from pg_proc p where p.oid = 'permissions.cedar_uid(text,text)'::regprocedure),
    'cedar_uid is immutable, parallel safe, strict, with search_path pg_catalog, pg_temp');
select tap.ok(has_function_privilege('anon', 'permissions.cedar_uid(text,text)', 'execute'),
              'anon can execute cedar_uid');
select tap.ok(not has_function_privilege('anon', 'permissions._cedar_uid_text(text,text)', 'execute'),
              'but not the private function it calls');

select * from tap.finish();
