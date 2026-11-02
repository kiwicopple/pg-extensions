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

select tap.plan(43);

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
          'permissions.cedar_is_authorized_current(text,text,jsonb,boolean)', 'permissions.cedar_list_resources_current(text,text)',
          'permissions.cedar_uid(text,text)'],
    'PUBLIC can execute exactly the current-subject functions, cedar_uid and _unfolded_null');
select tap.is(
    (select array_agg(p.oid::regprocedure::text order by 1) from pg_proc p
     where p.pronamespace = 'permissions'::regnamespace and p.proname ~ '^cedar_'
       and not (p.prosecdef and 'search_path=""' = any(p.proconfig))),
    null, 'every public cedar_* function is security definer with search_path ''''');
select tap.is(
    (select array_agg(p.oid::regprocedure::text order by 1) from pg_proc p
     where p.pronamespace = 'permissions'::regnamespace and p.proname ~ '^_?cedar_'
       and p.proname not in ('cedar_is_authorized_current', 'cedar_list_resources_current', 'cedar_uid')
       and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))),
    null, 'authenticated and anon can execute no cedar_* or _cedar_* function but the two current-subject helpers and cedar_uid');
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
-- a client that runs SQL can write. The helper trusts only entries it wrote
-- (MACs under the owner-only permissions._cedar_secret) under the request's
-- key, so every forgery below is a miss: the answer is the policies'. The
-- rows: a policy permits Doc with level < 5 for anyone; only alice may view
-- Doc::"secret" (level 9); bob may edit anything. Repeatable read keeps
-- pg_current_snapshot(), part of the key, fixed while other spec files run
-- on the same cluster, so each statement reuses the entry before it.
reset role;
select permissions.cedar_put_policy(policy_id => 'low', policy => 'permit (principal, action == Action::"view", resource is Doc) when { resource.level < 5 };');
select permissions.cedar_put_policy(policy_id => 'bob_edit',
    policy => format('permit (principal == user::"%s", action == Action::"edit", resource);', :'bob'));
create view public.cedar_forge_rows as
    select array_agg(d.id order by d.id) as ids
    from (values ('secret', 9), ('open', 0), ('x', 1)) d(id, level)
    where permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"' || d.id || '"',
                                                  resource_attrs => jsonb_build_object('level', d.level));
grant select on public.cedar_forge_rows to authenticated;
set role authenticated;
select set_config('permissions.subject_id', :'bob', false);
select 'permissions.cedar_filter_' || md5('Action::"view"') as g, 'permissions.cedar_filter_' || md5('Action::"edit"') as ge \gset
select tap.throws_ok($$ select * from permissions._cedar_secret $$, '42501', 'authenticated cannot read the MAC secret');
select tap.throws_ok($$ select permissions._cedar_changed() $$, '42501', 'authenticated cannot call the generation trigger function');

begin isolation level repeatable read;
select tap.is((select ids from public.cedar_forge_rows), '{open,x}', 'bob sees open and x, not secret');
select tap.ok(starts_with(current_setting(:'g'), current_database() || ' ')
              and strpos(current_setting(:'g'), format(' NULL %L NULL 0 %L', :'bob', 'Action::"view"') || chr(29)) > 0
              and split_part(current_setting(:'g'), chr(29), 2) ~ '^[0-9a-f]{64}',
              'the entry: the key (database, snapshot, subject settings, generation 0, action), then mac1');
-- 1. part 1 replaced by A:* (any resource, no conditions), mac1 kept
select set_config(:'g', split_part(current_setting(:'g'), chr(29), 1) || chr(29) || left(split_part(current_setting(:'g'), chr(29), 2), 64)
                        || chr(30) || 'A:*' || chr(30) || chr(28), true) is not null as forged \gset
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"secret"'), false,
              'cache forgery: an entry with the right key and a forged part 1 (A:*) does not let bob view Doc::"secret"');
select set_config(:'g', split_part(current_setting(:'g'), chr(29), 1) || chr(29) || repeat('0', 64)
                        || chr(30) || 'A:*' || chr(30) || chr(28) || repeat('0', 64), true) is not null as forged \gset
select tap.is((select ids from public.cedar_forge_rows), '{open,x}', 'cache forgery: a forged A:* entry gives the policies'' rows');
-- 2. truncated
select set_config(:'g', left(current_setting(:'g'), length(current_setting(:'g')) / 2), true) is not null as truncated \gset
select tap.is((select ids from public.cedar_forge_rows), '{open,x}', 'cache forgery: a truncated entry is a miss');
select set_config(:'g', left(current_setting(:'g'), strpos(current_setting(:'g'), chr(29)) + 10), true) is not null as truncated \gset
select tap.is((select ids from public.cedar_forge_rows), '{open,x}', 'cache forgery: an entry cut inside mac1 is a miss');
-- 3. part 2 swapped (the permit "low" without its condition), mac1 and
-- part 1 valid: Doc::"secret" reads part 2
select tap.ok(split_part(current_setting(:'g'), chr(28), 2) ~ ('^[0-9a-f]{64}' || chr(31) || '\{.*"t": \{"Doc": \[\{"a": \{'),
              'the entry has mac2 and a part 2 with the condition of "low"');
select set_config(:'g', split_part(current_setting(:'g'), chr(28), 1) || chr(28) || split_part(split_part(current_setting(:'g'), chr(28), 2), chr(31), 1)
                        || chr(31) || jsonb_set(split_part(split_part(current_setting(:'g'), chr(28), 2), chr(31), 2)::jsonb, '{pf,t,Doc,0,a}', 'null')::text, true)
       is not null as swapped \gset
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"secret"', resource_attrs => '{"level": 9}'), false,
              'cache forgery: a swapped part 2 with a valid mac1 does not let bob view Doc::"secret"');
select tap.is((select ids from public.cedar_forge_rows), '{open,x}', 'cache forgery: and the rows stay the policies'' rows');
-- 4. an entry of another action (edit: bob may edit anything, A:*) under
-- the view key, and the whole edit entry in the view setting
select permissions.cedar_is_authorized_current(action => 'Action::"edit"', resource => 'Doc::"secret"') as edit_secret \gset
select tap.is(:'edit_secret'::boolean, true, 'bob may edit Doc::"secret"');
select set_config(:'g', split_part(current_setting(:'g'), chr(29), 1) || chr(29)
                        || substr(current_setting(:'ge'), strpos(current_setting(:'ge'), chr(29)) + 1), true) is not null as copied \gset
select tap.is((select ids from public.cedar_forge_rows), '{open,x}', 'cache forgery: the edit entry under the view key gives the view rows');
select set_config(:'g', current_setting(:'ge'), true) is not null as copied \gset
select tap.is((select ids from public.cedar_forge_rows), '{open,x}', 'cache forgery: the edit entry as it is gives the view rows');
-- 5. no stored subject at all
select set_config('permissions.subject_id', 'nobody-at-all', true) is not null as nobody \gset
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"secret"'), false, 'a subject that is not stored');
select set_config(:'g', split_part(current_setting(:'g'), chr(29), 1) || chr(29) || left(split_part(current_setting(:'g'), chr(29), 2), 64)
                        || chr(30) || 'A:*' || chr(30) || chr(28), true) is not null as forged \gset
select tap.is((select ids from public.cedar_forge_rows), '{open,x}', 'cache forgery: a forged entry for a subject that is not stored gives the policies'' rows');
commit;

-- Replay. A Cedar write in the transaction ends its entries: the key holds
-- the generation of the transaction's last Cedar write, which only the
-- owner writes (permissions._cedar_write_gen). An entry read before the
-- write and written back after it is stale and is a miss.
select set_config('permissions.subject_id', :'bob', false);
begin isolation level repeatable read;
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"secret"'), false,
              'replay: bob may not view Doc::"secret"');
select current_setting(:'g') as stale \gset
reset role;
select permissions.cedar_put_policy(policy_id => 'bob_secret',
    policy => format('permit (principal == user::"%s", action == Action::"view", resource == Doc::"secret");', :'bob'));
set local role authenticated;
select set_config(:'g', :'stale', true) is not null as replayed \gset
select tap.is(permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"secret"'), true,
              'replay: after a Cedar write in the same transaction, the entry read before it is a miss, and bob may view Doc::"secret"');
select tap.ok(current_setting(:'g') !~ (' 0 ''Action::"view"''' || chr(29)), 'replay: the new entry''s key holds a generation');
commit;
reset role;
select permissions.cedar_delete_policy(policy_id => 'bob_secret') is not null as deleted \gset
drop view public.cedar_forge_rows;

reset role;
set role anon;
select tap.throws_ok(format($$ select permissions.rbac_assign_role(%L, 'admin') $$, :'erin'), '42501', 'anon cannot assign roles');
reset role;

select * from tap.finish();
