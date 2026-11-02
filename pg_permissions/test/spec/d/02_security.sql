-- Goal: clients can't read or write permission data, or act on other users (research/plan.md §3, §4)
-- Checked through the catalog, so it holds for any engine's table names.
-- The extension's copy of test/spec/02_security.sql (the prototypes' version,
-- in their unprefixed API): the same assertions, with the rbac_* names.
\ir ../../fixtures/ids.sql
\ir ../../fixtures/d/rbac_roles.sql
select permissions.rbac_assign_role(:'alice', 'admin');
-- Cedar: only alice may view Doc::"secret"
select permissions.cedar_put_policy(policy_id => 'secret',
    policy => format('permit (principal == user::"%s", action == Action::"view", resource == Doc::"secret");', :'alice'));

select tap.plan(28);

-- tables
select tap.is(
    (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'permissions' and c.relkind in ('r', 'v', 'm', 'p')),
    (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'permissions' and c.relkind in ('r', 'v', 'm', 'p')
       and not has_table_privilege('authenticated', c.oid, 'select, insert, update, delete')),
    'authenticated has no privileges on any table in the permissions schema');
select tap.is(
    (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'permissions' and c.relkind in ('r', 'v', 'm', 'p')
       and has_table_privilege('anon', c.oid, 'select, insert, update, delete')),
    0, 'anon has no privileges on any table in the permissions schema');

-- security definer hygiene
select tap.is(
    (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'permissions' and p.prosecdef
       and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')),
    0, 'every security definer function pins its search_path');

-- grants: PUBLIC may run exactly the current-subject functions (and the
-- plan-time guard); this holds for a fresh install and, under
-- test/run.sh --upgrade-from, for an upgraded one (its Privileges DO block)
select tap.set_eq(
    (select array_agg(p.oid::regprocedure::text) from pg_proc p
     where p.pronamespace = 'permissions'::regnamespace
       and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))),
    array['permissions.current_subject_id()', 'permissions.current_subject_type()', 'permissions._unfolded_null()',
          'permissions.rbac_has_permission(text,text)', 'permissions.rbac_has_role(text,text)',
          'permissions.rbac_scopes_with_permission(text,boolean)',
          'permissions.fga_check_current(text,text)', 'permissions.fga_list_objects_current(text,text)',
          'permissions.fga_list_object_ids_current(text,text)',
          'permissions.cedar_is_authorized_current(text,text,jsonb,boolean)', 'permissions.cedar_list_resources_current(text,text)'],
    'PUBLIC can execute exactly the current-subject functions and _unfolded_null');
select tap.is(
    (select array_agg(p.oid::regprocedure::text order by 1) from pg_proc p
     where p.pronamespace = 'permissions'::regnamespace and p.proname ~ '^cedar_'
       and not (p.prosecdef and 'search_path=""' = any(p.proconfig))),
    null, 'every public cedar_* function is security definer with search_path ''''');
select tap.is(
    (select array_agg(p.oid::regprocedure::text order by 1) from pg_proc p
     where p.pronamespace = 'permissions'::regnamespace and p.proname ~ '^_?cedar_'
       and p.proname not in ('cedar_is_authorized_current', 'cedar_list_resources_current')
       and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))),
    null, 'authenticated and anon can execute no cedar_* or _cedar_* function but the two current-subject helpers');
select tap.ok(
    (select count(*) from pg_class c where c.relnamespace = 'permissions'::regnamespace and c.relkind = 'r' and c.relname ~ '^cedar_') = 5
    and not exists (select 1 from pg_class c where c.relnamespace = 'permissions'::regnamespace and c.relkind = 'r' and c.relname ~ '^cedar_'
                    and (has_table_privilege('authenticated', c.oid, 'select, insert, update, delete, truncate')
                         or has_table_privilege('anon', c.oid, 'select, insert, update, delete, truncate'))),
    'authenticated and anon have no privileges on the five cedar_* tables');

-- management functions are admin only
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.throws_ok($$ select permissions.rbac_create_role('hacker', '{documents.read}') $$, '42501', 'authenticated cannot create roles');
select tap.throws_ok($$ select permissions.rbac_drop_role('viewer') $$, '42501', 'authenticated cannot drop roles');
select tap.throws_ok(format($$ select permissions.rbac_assign_role(%L, 'admin') $$, :'bob'), '42501', 'authenticated cannot assign roles, even as an admin');
select tap.throws_ok(format($$ select permissions.rbac_unassign_role(%L, 'admin') $$, :'alice'), '42501', 'authenticated cannot unassign roles');

-- explicit-subject functions are admin only (they'd leak other users' access)
select tap.throws_ok(format($$ select permissions.rbac_user_permissions(%L) $$, :'alice'), '42501', 'authenticated cannot read another user''s permissions');
select tap.throws_ok($$ select * from permissions.rbac_users_with_role('admin') $$, '42501', 'authenticated cannot list role holders');

-- client-facing checks work
select tap.lives_ok($$ select permissions.rbac_has_permission('documents.read') $$, 'authenticated can call rbac_has_permission');
select tap.lives_ok($$ select permissions.rbac_has_role('admin') $$, 'authenticated can call rbac_has_role');
select tap.lives_ok($$ select permissions.rbac_scopes_with_permission('documents.read') $$, 'authenticated can call rbac_scopes_with_permission');
select tap.is(permissions.rbac_has_permission('users.manage'), true, 'and they answer for the current subject');

-- Cedar: the current-subject helpers only; explicit principals and writes are admin only
select tap.lives_ok($$ select permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"d1"') $$, 'authenticated can call cedar_is_authorized_current');
select tap.lives_ok($$ select * from permissions.cedar_list_resources_current('Action::"view"', 'Doc') $$, 'authenticated can call cedar_list_resources_current');
select tap.throws_ok($$ select permissions.cedar_is_authorized('User::"alice"', 'Action::"view"', 'Doc::"d1"') $$, '42501', 'authenticated cannot authorize another principal');
select tap.throws_ok($$ select permissions.cedar_put_policy('p', 'permit (principal, action, resource);') $$, '42501', 'authenticated cannot put Cedar policies');
select tap.throws_ok($$ select * from permissions.cedar_entities $$, '42501', 'authenticated cannot read cedar_entities');
select tap.throws_ok($$ select permissions._cedar_current_filter('user', 'x', 'Action', 'view') $$, '42501',
                     'authenticated cannot call the internal _cedar_* functions');

-- The statement filter of cedar_is_authorized_current lives in a
-- transaction-local setting (research/designs/e-cedar.md section 15.2), which
-- a client that runs SQL can write. CURRENT BEHAVIOUR, for the phase 9
-- review: a forged entry with the right key grants access. The design's
-- argument is that such a client can also set permissions.subject_id and be
-- any subject (docs: Identity); PostgREST clients can set neither. Repeatable
-- read keeps pg_current_snapshot(), part of the key, fixed while other spec
-- files run on the same cluster.
select set_config('permissions.subject_id', :'bob', false);
begin isolation level repeatable read;
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"secret"'), false,
              'cache forgery: bob may not view Doc::"secret"');
select set_config('permissions.cedar_filter_' || md5('Action::"view"'),
                  format('%s %L %L %L %L %L', pg_current_snapshot(), current_setting('request.jwt.claims', true),
                         current_setting('permissions.subject_id', true), current_setting('permissions.subject_type', true),
                         coalesce(current_setting('permissions.cedar_generation', true), '') || 'stale', 'Action::"view"')
                  || chr(29) || chr(30) || 'A:*' || chr(30) || chr(28), true) is not null as forged_stale \gset
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"secret"'), false,
              'cache forgery: an entry whose key does not match the request (here cedar_generation) is ignored');
select set_config('permissions.cedar_filter_' || md5('Action::"view"'),
                  format('%s %L %L %L %L %L', pg_current_snapshot(), current_setting('request.jwt.claims', true),
                         current_setting('permissions.subject_id', true), current_setting('permissions.subject_type', true),
                         current_setting('permissions.cedar_generation', true), 'Action::"view"')
                  || chr(29) || chr(30) || 'A:*' || chr(30) || chr(28), true) is not null as forged \gset
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"secret"'), true,
              'cache forgery, CURRENT BEHAVIOUR: a client that writes an entry with the right key gets access no policy gives it');
commit;
begin isolation level repeatable read;
select set_config('permissions.subject_id', :'alice', true);
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"secret"'), true,
              'the same client can as well set permissions.subject_id and act as alice (the trust argument of e-cedar.md 15.2)');
commit;

reset role;
set role anon;
select tap.throws_ok(format($$ select permissions.rbac_assign_role(%L, 'admin') $$, :'erin'), '42501', 'anon cannot assign roles');
reset role;

select * from tap.finish();
