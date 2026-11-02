-- Goal: clients can't read or write permission data, or act on other users (research/plan.md §3, §4)
-- Checked through the catalog, so it holds for any engine's table names.
\ir ../fixtures/ids.sql
\ir ../fixtures/rbac_roles.sql
select permissions.assign_role(:'alice', 'admin');

select tap.plan(14);

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

-- management functions are admin only
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.throws_ok($$ select permissions.create_role('hacker', '{documents.read}') $$, '42501', 'authenticated cannot create roles');
select tap.throws_ok($$ select permissions.drop_role('viewer') $$, '42501', 'authenticated cannot drop roles');
select tap.throws_ok(format($$ select permissions.assign_role(%L, 'admin') $$, :'bob'), '42501', 'authenticated cannot assign roles, even as an admin');
select tap.throws_ok(format($$ select permissions.unassign_role(%L, 'admin') $$, :'alice'), '42501', 'authenticated cannot unassign roles');

-- explicit-subject functions are admin only (they'd leak other users' access)
select tap.throws_ok(format($$ select permissions.user_permissions(%L) $$, :'alice'), '42501', 'authenticated cannot read another user''s permissions');
select tap.throws_ok($$ select * from permissions.users_with_role('admin') $$, '42501', 'authenticated cannot list role holders');

-- client-facing checks work
select tap.lives_ok($$ select permissions.has_permission('documents.read') $$, 'authenticated can call has_permission');
select tap.lives_ok($$ select permissions.has_role('admin') $$, 'authenticated can call has_role');
select tap.lives_ok($$ select permissions.scopes_with_permission('documents.read') $$, 'authenticated can call scopes_with_permission');
select tap.is(permissions.has_permission('users.manage'), true, 'and they answer for the current subject');

reset role;
set role anon;
select tap.throws_ok(format($$ select permissions.assign_role(%L, 'admin') $$, :'erin'), '42501', 'anon cannot assign roles');
reset role;

select * from tap.finish();
