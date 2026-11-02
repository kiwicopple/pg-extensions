-- Goal: ids are data, so the Cedar current-subject helpers never raise for
-- them (research/plan-cedar.md, phase 6). A subject id, a stored entity id
-- or a resource id may hold any character, " and \ and control characters
-- included. A resource argument in Cedar text with escapes parses as Cedar;
-- a resource Type::"..." whose id is not a Cedar string (a row's id
-- concatenated without escaping) denies the row instead of raising. Text
-- that is not Type::"..." at all, and a bad action, are the caller's typos
-- and raise cedar:invalid_uid, as fga_check_current raises on a malformed
-- object. An id that holds a separator of the statement filter's layout
-- (chr(28), chr(30)) gets the same answer as cedar_is_authorized.
\ir ../../fixtures/ids.sql

select set_config('permissions.subject_id', 'a"b\c', false);

select permissions.cedar_put_entities(entities => jsonb_build_array(
    jsonb_build_object('uid', jsonb_build_object('type', 'Team', 'id', 't"1')),
    jsonb_build_object('uid', jsonb_build_object('type', 'user', 'id', 'a"b\c'), 'parents', '[{"type": "Team", "id": "t\"1"}]'::jsonb),
    jsonb_build_object('uid', jsonb_build_object('type', 'user', 'id', 'r' || chr(30) || 's' || chr(29) || 't')),
    jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'x"y'), 'attrs', '{"level": 1}'::jsonb),
    jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'p\q'), 'attrs', '{"level": 1}'::jsonb),
    jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'open'), 'attrs', '{"level": 0}'::jsonb),
    jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'open2'), 'attrs', '{"level": 0}'::jsonb)));

select permissions.cedar_put_policy(policy_id => 'team-xy', policy => 'permit (principal in Team::"t\"1", action == Action::"view", resource == Doc::"x\"y");');
select permissions.cedar_put_policy(policy_id => 'open', policy => 'permit (principal, action == Action::"view", resource == Doc::"open");');
select permissions.cedar_put_policy(policy_id => 'open2', policy => 'permit (principal, action == Action::"view", resource == Doc::"open2");');
select permissions.cedar_put_policy(policy_id => 'list', policy => 'permit (principal == user::"a\"b\\c", action == Action::"list", resource is Doc);');
select permissions.cedar_put_policy(policy_id => 'read', policy => 'permit (principal, action == Action::"read", resource) when { resource.level > 0 };');

-- the decision of cedar_is_authorized for the current subject, as the
-- helper's reference
create function pg_temp.reference(p_action text, p_resource text) returns boolean
language sql as $$
    select permissions.cedar_is_authorized(principal => 'user::"a\"b\\c"', action => p_action, resource => p_resource) ->> 'decision' = 'allow'
$$;

create table public.docs (id text primary key);
insert into public.docs values ('x"y'), ('p\q'), ('open'), ('n\tl');
alter table public.docs enable row level security;
grant select on public.docs to authenticated;
-- unescaped, as most policies on uuid or integer ids are written
create policy docs_concat on public.docs for select to authenticated
    using (permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"' || id || '"'));
create table public.docs_escaped (id text primary key);
insert into public.docs_escaped select id from public.docs;
alter table public.docs_escaped enable row level security;
grant select on public.docs_escaped to authenticated;
-- escaped: \ and " in the id get a backslash
create policy docs_escaped on public.docs_escaped for select to authenticated
    using (permissions.cedar_is_authorized_current('Action::"view"',
                                                   'Doc::"' || replace(replace(id, '\', '\\'), '"', '\"') || '"'));

select tap.plan(21);

set role authenticated;

-- a subject id with " and \, in a group whose id has a "
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"x\"y"'), true,
              'escaped resource text parses as Cedar: the subject a"b\c in Team::"t\"1" may view Doc::"x\"y"');
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"read"', resource => 'Doc::"p\\q"'), true,
              'escaped \ in the resource text, with a condition on the stored attrs');
select tap.set_eq(array(select permissions.cedar_list_resources_current(action => 'Action::"list"', resource_type => 'Doc')),
                  array['x"y', 'p\q', 'open', 'open2'], 'cedar_list_resources_current returns stored ids with " and \ as they are');
select tap.set_eq(array(select permissions.cedar_list_resources_current(action => 'Action::"read"', resource_type => 'Doc')),
                  array['x"y', 'p\q'], 'and evaluates conditions for them');

-- unescaped data denies, never raises
select tap.lives_ok($$ select permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"' || 'x"y' || '"') $$,
                    'a row id with " concatenated unescaped does not raise');
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"' || 'x"y' || '"'), false,
              'it denies the row');
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"' || 'p\' || '"'), false,
              'a row id that ends with \ denies the row');
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"' || 'p\q' || '"'), false,
              'a row id with an invalid escape (\q) denies the row');
select tap.is((select array_agg(id order by id) from public.docs), '{open}',
              'RLS over ids with " and \: the unescaped policy shows the plain id only, and raises nothing');
select tap.is((select array_agg(id order by id) from public.docs_escaped), '{open,"x\"y"}',
              'the policy that escapes \ and " shows every allowed row');

-- the caller's typos raise
select tap.throws_ok($$ select permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc:"open"') $$,
                     '22023', 'a resource that is not Type::"..." raises cedar:invalid_uid');
select tap.throws_ok($$ select permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'doc open') $$,
                     '22023', 'so does a resource without a type');
select tap.throws_ok($$ select permissions.cedar_is_authorized_current(action => 'view', resource => 'Doc::"open"') $$,
                     '22023', 'so does an action that is not a uid');

-- the separators of the statement filter's layout, in ids
reset role;
select pg_temp.reference('Action::"view"', 'Doc::"open\"' || chr(30) || 'E:Doc::\"open2"') as forged_ref \gset
set role authenticated;
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"',
                                                      resource => 'Doc::"open\"' || chr(30) || 'E:Doc::\"open2"'),
              :'forged_ref'::boolean,
              'a resource id that spells two allowed entries around chr(30) is not allowed by them (as cedar_is_authorized)');
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"open"'), true,
              'the plain id is still allowed in the same statement filter');
reset role;
select permissions.cedar_put_policy(policy_id => 'sep', policy => 'permit (principal, action == Action::"view", resource == Doc::"s\u{1c}t\u{1e}u");');
select permissions.cedar_put_entities(entities => jsonb_build_array(
    jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'child'), 'parents',
                       jsonb_build_array(jsonb_build_object('type', 'Folder', 'id', 'f' || chr(30) || 'g')))));
select permissions.cedar_put_policy(policy_id => 'folder', policy => 'permit (principal, action == Action::"edit", resource in Folder::"f\u{1e}g");');
set role authenticated;
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"s\u{1c}t\u{1e}u"'), true,
              'a policy whose resource uid holds chr(28) and chr(30) still allows it');
select tap.is(array[permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"open"'),
                    permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"zzz"')],
              array[true, false], 'and the other answers of that statement filter are unchanged');
select tap.is(array[permissions.cedar_is_authorized_current(action => 'Action::"edit"', resource => 'Doc::"child"'),
                    permissions.cedar_is_authorized_current(action => 'Action::"edit"', resource => 'Doc::"open"')],
              array[true, false], 'an ancestor whose id holds chr(30): resource in Folder::"f\u{1e}g"');

-- a subject id with the separators of the cache key and the filter
reset role;
select permissions.cedar_put_policy(policy_id => 'ctl', policy_json => jsonb_build_object(
    'effect', 'permit', 'principal', jsonb_build_object('op', '==', 'entity', jsonb_build_object('type', 'user', 'id', 'r' || chr(30) || 's' || chr(29) || 't')),
    'action', '{"op": "==", "entity": {"type": "Action", "id": "view"}}'::jsonb, 'resource', '{"op": "All"}'::jsonb, 'conditions', '[]'::jsonb));
set role authenticated;
select set_config('permissions.subject_id', 'r' || chr(30) || 's' || chr(29) || 't', false);
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"zzz"'), true,
              'a subject id with chr(29) and chr(30): its policy applies');
select tap.is(array(select permissions.cedar_list_resources_current(action => 'Action::"view"', resource_type => 'Doc') order by 1),
              array['child', 'open', 'open2', 'p\q', 'x"y'],
              'and cedar_list_resources_current lists every stored Doc for it');
select set_config('permissions.subject_id', 'a"b\c', false);
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"zzz"'), false,
              'the previous subject gets its own statement filter again');
reset role;

select * from tap.finish();
