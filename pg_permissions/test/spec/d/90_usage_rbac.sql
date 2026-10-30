-- Goal: every example in usage/README.md ("Using pg_permissions") works as written.
--
-- This file mirrors that page, section by section and in the same order, so the
-- state built by one section (roles, assignments, tables) is what the next one
-- uses. When you change an example in the page, change it here, and the other
-- way round. Statements without a result are copied from the page. Queries that
-- return something appear as `tap.is(<the same expression>, <the documented
-- answer>)`. Everything that is only about the `rbac` preset and the common
-- surface (identity, privileges, RLS rules).
-- The extension's copy of test/spec/90_usage_rbac.sql (the prototypes' version,
-- in their unprefixed API): the same assertions, with the rbac_* names. Calls
-- pass arguments by name, as in usage/README.md.
--
-- The page's own IDs, not fixtures/ids.sql: the page defines them in its first
-- code block.
\set alice  '11111111-1111-1111-1111-111111111111'
\set bob    '22222222-2222-2222-2222-222222222222'
\set carol  '33333333-3333-3333-3333-333333333333'
\set dave   '44444444-4444-4444-4444-444444444444'
\set erin   '55555555-5555-5555-5555-555555555555'
\set frank  '66666666-6666-6666-6666-666666666666'
\set acme   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
\set globex 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'

select tap.plan(86);

-- ============================================================================
-- Identity
-- ============================================================================

select tap.is(permissions.current_subject_id()::text, null, 'identity: no JWT and no setting means no subject');
select tap.is(permissions.current_subject_type(), 'user', 'identity: the subject type defaults to user');
select tap.is(permissions.rbac_has_permission(permission => 'documents.read'), false, 'identity: no subject, no access (even before any role exists)');

-- plain Postgres: one setting per transaction
begin;
select set_config('permissions.subject_id', :'alice', true);
select tap.is(permissions.current_subject_id()::text, :'alice', 'identity: permissions.subject_id names the subject inside the transaction');
commit;
select tap.is(permissions.current_subject_id()::text, null, 'identity: a transaction-local setting is gone after commit');

-- Supabase / PostgREST: the JWT sub claim, and it wins over the setting
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'alice', 'role', 'authenticated')::text, true);
select tap.is(permissions.current_subject_id()::text, :'alice', 'identity: the JWT sub claim names the subject');
select set_config('permissions.subject_id', :'bob', true);
select tap.is(permissions.current_subject_id()::text, :'alice', 'identity: the JWT wins over permissions.subject_id');
commit;

-- the subject type
begin;
select set_config('permissions.subject_type', 'service', true);
select tap.is(permissions.current_subject_type(), 'service', 'identity: permissions.subject_type changes the subject type');
commit;

-- ============================================================================
-- Roles and privileges
-- ============================================================================

-- client roles can call the checks
begin;
set local role authenticated;
select tap.lives_ok($$ select permissions.current_subject_id() $$, 'privileges: authenticated can call current_subject_id');
select tap.lives_ok($$ select permissions.rbac_has_permission(permission => 'documents.read') $$, 'privileges: authenticated can call rbac_has_permission');
select tap.lives_ok($$ select permissions.rbac_has_role(role => 'admin') $$, 'privileges: authenticated can call rbac_has_role');
select tap.lives_ok($$ select permissions.rbac_scopes_with_permission(permission => 'documents.read') $$, 'privileges: authenticated can call rbac_scopes_with_permission');
-- and nothing that takes a subject or changes data
select tap.throws_ok($$ select permissions.rbac_create_role(role => 'hacker', permissions => '{documents.read}') $$, '42501', 'privileges: authenticated cannot rbac_create_role');
select tap.throws_ok($$ select permissions.rbac_drop_role(role => 'viewer') $$, '42501', 'privileges: authenticated cannot rbac_drop_role');
select tap.throws_ok(format($$ select permissions.rbac_assign_role(user_id => %L, role => 'admin') $$, :'bob'), '42501', 'privileges: authenticated cannot rbac_assign_role');
select tap.throws_ok(format($$ select permissions.rbac_unassign_role(user_id => %L, role => 'admin') $$, :'bob'), '42501', 'privileges: authenticated cannot rbac_unassign_role');
select tap.throws_ok(format($$ select permissions.rbac_user_permissions(user_id => %L) $$, :'alice'), '42501', 'privileges: authenticated cannot call rbac_user_permissions');
select tap.throws_ok($$ select * from permissions.rbac_users_with_role(role => 'admin') $$, '42501', 'privileges: authenticated cannot call rbac_users_with_role');
commit;

begin;
set local role anon;
select tap.lives_ok($$ select permissions.rbac_has_permission(permission => 'documents.read') $$, 'privileges: anon can call rbac_has_permission (and gets false: no subject)');
select tap.throws_ok(format($$ select permissions.rbac_assign_role(user_id => %L, role => 'admin') $$, :'bob'), '42501', 'privileges: anon cannot rbac_assign_role');
commit;

-- a trusted backend role gets the admin functions by explicit grant
grant execute on function
    permissions.rbac_create_role(text, text[], text[]),
    permissions.rbac_drop_role(text),
    permissions.rbac_assign_role(text, text, text),
    permissions.rbac_unassign_role(text, text, text),
    permissions.rbac_user_permissions(text, text),
    permissions.rbac_users_with_role(text, text)
to service_role;

begin;
set local role service_role;
select tap.is(permissions.rbac_user_permissions(user_id => :'alice'), '{}'::text[], 'privileges: service_role can call rbac_user_permissions after the grant');
commit;

-- ============================================================================
-- The rbac preset: setup
-- ============================================================================

select permissions.rbac_create_role(role => 'viewer', permissions => '{documents.read}');
select permissions.rbac_create_role(role => 'editor', permissions => '{documents.edit}', inherits => '{viewer}');
select permissions.rbac_create_role(role => 'admin',  permissions => '{documents.delete,users.manage}', inherits => '{editor}');

select permissions.rbac_assign_role(user_id => :'alice', role => 'admin');
select permissions.rbac_assign_role(user_id => :'bob',   role => 'editor');
select permissions.rbac_assign_role(user_id => :'carol', role => 'viewer');

-- rbac_create_role
select tap.set_eq(permissions.rbac_user_permissions(user_id => :'alice'), '{documents.read,documents.edit,documents.delete,users.manage}', 'rbac_create_role: admin gets its own permissions and everything it inherits');
select tap.throws_ok($$ select permissions.rbac_create_role(role => 'viewer', permissions => '{documents.read}') $$, '23505', 'rbac_create_role: a role that exists fails with 23505');
select tap.throws_ok($$ select permissions.rbac_create_role(role => 'auditor', permissions => '{audit.read}', inherits => '{nonexistent}') $$, '22023', 'rbac_create_role: inheriting an unknown role fails with 22023');
select tap.throws_ok($$ select permissions.rbac_create_role(role => 'documents.read', permissions => '{x.y}') $$, '22023', 'rbac_create_role: a role cannot be named like a permission');
select tap.throws_ok($$ select permissions.rbac_create_role(role => 'moderator', permissions => '{viewer}') $$, '22023', 'rbac_create_role: a permission cannot be named like a role');

-- rbac_assign_role, rbac_unassign_role
select permissions.rbac_assign_role(user_id => :'bob', role => 'editor');
select tap.set_eq(permissions.rbac_user_permissions(user_id => :'bob'), '{documents.read,documents.edit}', 'rbac_assign_role: assigning a role twice changes nothing');
select tap.throws_ok(format($$ select permissions.rbac_assign_role(user_id => %L, role => 'nonexistent') $$, :'bob'), '22023', 'rbac_assign_role: an unknown role fails with 22023');
select permissions.rbac_unassign_role(user_id => :'dave', role => 'editor');
select tap.lives_ok(format($$ select permissions.rbac_unassign_role(user_id => %L, role => 'nonexistent') $$, :'dave'), 'rbac_unassign_role: removing a role the user does not hold is a no-op');

-- rbac_has_permission, rbac_has_role
begin;
select set_config('permissions.subject_id', :'carol', true);
select tap.is(permissions.rbac_has_permission(permission => 'documents.read'), true, 'rbac_has_permission: Carol (viewer) can read');
select tap.is(permissions.rbac_has_permission(permission => 'documents.edit'), false, 'rbac_has_permission: Carol (viewer) cannot edit');
select tap.is(permissions.rbac_has_permission(permission => 'documents.nonexistent'), false, 'rbac_has_permission: an unknown permission is false, not an error');
select tap.is(permissions.rbac_has_role(role => 'viewer'), true, 'rbac_has_role: Carol holds viewer');
select tap.is(permissions.rbac_has_role(role => 'documents.read'), false, 'rbac_has_role: a permission name is not a role');
select tap.is(permissions.rbac_has_role(role => 'nonexistent'), false, 'rbac_has_role: an unknown role is false, not an error');
select set_config('permissions.subject_id', :'bob', true);
select tap.is(permissions.rbac_has_role(role => 'viewer'), true, 'rbac_has_role: Bob (editor) holds viewer through inheritance');
select tap.is(permissions.rbac_has_role(role => 'admin'), false, 'rbac_has_role: but not admin, which inherits editor, not the other way round');
select set_config('permissions.subject_id', :'alice', true);
select tap.is(permissions.rbac_has_permission(permission => 'documents.read', scope => :'acme'), false, 'rbac_has_permission: an app-wide role gives nothing inside a scope');
select set_config('permissions.subject_type', 'service', true);
select tap.is(permissions.rbac_has_permission(permission => 'users.manage'), false, 'rbac_has_permission: roles are held by user subjects, so another subject type has none');
commit;

-- rbac_user_permissions, rbac_users_with_role
select tap.set_eq(permissions.rbac_user_permissions(user_id => :'bob'), '{documents.read,documents.edit}', 'rbac_user_permissions: Bob (editor)');
select tap.set_eq(permissions.rbac_user_permissions(user_id => :'dave'), '{}', 'rbac_user_permissions: a user with no roles gets an empty array');
select tap.set_eq(array(select permissions.rbac_users_with_role(role => 'editor')), array[:'alice', :'bob'], 'rbac_users_with_role: includes holders through inheritance');

-- rbac_drop_role
select permissions.rbac_create_role(role => 'auditor', permissions => '{audit.read}', inherits => '{viewer}');
select permissions.rbac_assign_role(user_id => :'dave', role => 'auditor');
select tap.set_eq(permissions.rbac_user_permissions(user_id => :'dave'), '{audit.read,documents.read}', 'rbac_drop_role: Dave holds auditor and inherits viewer');
select tap.throws_ok($$ select permissions.rbac_drop_role(role => 'viewer') $$, '2BP01', 'rbac_drop_role: a role another role inherits cannot be dropped (2BP01)');
select tap.throws_ok($$ select permissions.rbac_drop_role(role => 'nonexistent') $$, '22023', 'rbac_drop_role: an unknown role fails with 22023');
select permissions.rbac_drop_role(role => 'auditor');
select tap.set_eq(permissions.rbac_user_permissions(user_id => :'dave'), '{}', 'rbac_drop_role: the role''s assignments go with it');
select tap.lives_ok($$ select permissions.rbac_create_role(role => 'auditor', permissions => '{audit.read}') $$, 'rbac_drop_role: the name can be reused');
select permissions.rbac_drop_role(role => 'auditor');

-- ============================================================================
-- Scenario 1: app-wide roles
-- ============================================================================

create table public.documents (
    id    uuid primary key default gen_random_uuid(),
    title text not null
);
insert into public.documents (title) values ('welcome'), ('holidays'), ('expenses');

alter table public.documents enable row level security;
grant select, update, delete on public.documents to authenticated;

create policy documents_select on public.documents for select to authenticated
    using ((select permissions.rbac_has_permission(permission => 'documents.read')));
create policy documents_update on public.documents for update to authenticated
    using ((select permissions.rbac_has_permission(permission => 'documents.edit')));
create policy documents_delete on public.documents for delete to authenticated
    using ((select permissions.rbac_has_permission(permission => 'documents.delete')));

-- Carol, a viewer
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'carol', true);
select tap.is((select count(*)::int from public.documents), 3, 'app-wide: Carol (viewer) sees all 3 documents');
update public.documents set title = upper(title);
select tap.is((select count(*)::int from public.documents where title = upper(title)), 0, 'app-wide: Carol''s update changes nothing');
select tap.is(permissions.rbac_has_permission(permission => 'documents.edit'), false, 'app-wide: can Carol edit documents? No');
commit;

-- Bob, an editor
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
update public.documents set title = upper(title);
select tap.is((select count(*)::int from public.documents where title = upper(title)), 3, 'app-wide: Bob (editor) can update every document');
delete from public.documents where title = 'EXPENSES';
select tap.is((select count(*)::int from public.documents), 3, 'app-wide: Bob cannot delete');
commit;

-- Alice, an admin
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'alice', true);
delete from public.documents where title = 'EXPENSES';
select tap.is((select count(*)::int from public.documents), 2, 'app-wide: Alice (admin) can delete');
commit;

-- Dave has no role, and a request with no subject is denied
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'dave', true);
select tap.is((select count(*)::int from public.documents), 0, 'app-wide: Dave (no role) sees nothing');
select set_config('permissions.subject_id', '', true);
select tap.is((select count(*)::int from public.documents), 0, 'app-wide: no subject sees nothing');
commit;

-- the app-wide check runs once per query
create temp table plan_lines (line text);
grant all on plan_lines to authenticated;
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'carol', true);
do $$
declare l text;
begin
    for l in execute 'explain select * from public.documents' loop
        insert into plan_lines values (l);
    end loop;
end $$;
commit;
select tap.ok(exists (select 1 from plan_lines where line like '%InitPlan%') and not exists (select 1 from plan_lines where line ~* 'SubPlan'),
              'app-wide: (select rbac_has_permission(...)) is an InitPlan, not a per-row SubPlan');

-- ============================================================================
-- Scenario 2: roles scoped to a tenant
-- ============================================================================

select permissions.rbac_assign_role(user_id => :'alice', role => 'admin',  scope => :'acme');
select permissions.rbac_assign_role(user_id => :'bob',   role => 'editor', scope => :'acme');
select permissions.rbac_assign_role(user_id => :'bob',   role => 'viewer', scope => :'globex');

create table public.org_documents (
    id     uuid primary key default gen_random_uuid(),
    org_id uuid not null,
    title  text not null
);
create index on public.org_documents (org_id);
insert into public.org_documents (org_id, title) values
    (:'acme',   'acme plan'),
    (:'acme',   'acme readme'),
    (:'globex', 'globex notes');

alter table public.org_documents enable row level security;
grant select, insert, update on public.org_documents to authenticated;

create policy org_documents_select on public.org_documents for select to authenticated
    using (org_id = any (array(select unnest(permissions.rbac_scopes_with_permission(permission => 'documents.read'))::uuid)));
create policy org_documents_update on public.org_documents for update to authenticated
    using (permissions.rbac_has_permission(permission => 'documents.edit', scope => org_id::text));
create policy org_documents_insert on public.org_documents for insert to authenticated
    with check (permissions.rbac_has_permission(permission => 'documents.edit', scope => org_id::text));

-- the questions from the scenario
begin;
select set_config('permissions.subject_id', :'bob', true);
select tap.is(permissions.rbac_has_permission(permission => 'documents.edit', scope => :'acme'), true, 'tenant: Bob can edit in acme');
select tap.is(permissions.rbac_has_permission(permission => 'documents.edit', scope => :'globex'), false, 'tenant: Bob cannot edit in globex');
select tap.is(permissions.rbac_has_permission(permission => 'documents.read', scope => :'globex'), true, 'tenant: Bob can read in globex');
select tap.set_eq(permissions.rbac_scopes_with_permission(permission => 'documents.read'), array[:'acme', :'globex'], 'tenant: rbac_scopes_with_permission(permission => read) for Bob is acme and globex');
select tap.set_eq(permissions.rbac_scopes_with_permission(permission => 'documents.edit'), array[:'acme'], 'tenant: rbac_scopes_with_permission(permission => edit) for Bob is acme');
select set_config('permissions.subject_id', :'carol', true);
select tap.set_eq(permissions.rbac_scopes_with_permission(permission => 'documents.read'), '{}'::text[], 'tenant: an app-wide role is not a scope (empty array, not null)');
commit;
select tap.set_eq(permissions.rbac_user_permissions(user_id => :'bob', scope => :'globex'), '{documents.read}', 'tenant: what Bob can do in globex');
select tap.set_eq(array(select permissions.rbac_users_with_role(role => 'admin', scope => :'acme')), array[:'alice'], 'tenant: who are the admins of acme');

-- Bob: reads both orgs, writes only acme
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select tap.is((select count(*)::int from public.org_documents), 3, 'tenant: Bob sees the acme and globex documents');
update public.org_documents set title = upper(title);
select tap.set_eq(array(select title from public.org_documents where title = upper(title)), '{"ACME PLAN","ACME README"}'::text[], 'tenant: Bob''s update only reaches acme');
insert into public.org_documents (org_id, title) values (:'acme', 'budget');
select tap.is((select count(*)::int from public.org_documents), 4, 'tenant: Bob can insert into acme');
commit;
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select tap.throws_ok(format($$ insert into public.org_documents (org_id, title) values (%L, 'nope') $$, :'globex'), '42501', 'tenant: Bob cannot insert into globex (row-level security violation)');
commit;

-- Alice and Carol hold app-wide roles too, which a scoped policy ignores
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'alice', true);
select tap.is((select count(*)::int from public.org_documents), 3, 'tenant: Alice (admin of acme) sees only acme documents');
select set_config('permissions.subject_id', :'carol', true);
select tap.is((select count(*)::int from public.org_documents), 0, 'tenant: Carol''s app-wide viewer role does not reach a tenant table');
commit;

-- ============================================================================
-- Writing RLS policies
-- ============================================================================

-- the fast path is an InitPlan
truncate plan_lines;
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
do $$
declare l text;
begin
    for l in execute 'explain select * from public.org_documents' loop
        insert into plan_lines values (l);
    end loop;
end $$;
commit;
select tap.ok(exists (select 1 from plan_lines where line like '%InitPlan%') and not exists (select 1 from plan_lines where line ~* 'SubPlan'),
              'rls: org_id = any (array(select unnest(...)::uuid)) is an InitPlan, not a per-row SubPlan');

-- the forms that look right
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select tap.throws_ok($$ select * from public.org_documents where org_id = any ((select permissions.rbac_scopes_with_permission(permission => 'documents.read'))) $$, '42883', 'rls: org_id = any ((select f())) does not parse (operator does not exist)');
select tap.is((select count(*)::int from public.org_documents where org_id = any ((select permissions.rbac_scopes_with_permission(permission => 'documents.read'))::uuid[])), 4, 'rls: org_id = any ((select f())::uuid[]) returns the same rows (slower)');
select tap.is((select count(*)::int from public.org_documents where org_id in (select unnest(permissions.rbac_scopes_with_permission(permission => 'documents.read'))::uuid)), 4, 'rls: org_id in (select unnest(f())::uuid) returns the same rows (slower)');
commit;

-- app-wide or scoped: two checks
create table public.projects (
    id     uuid primary key default gen_random_uuid(),
    org_id uuid not null,
    name   text not null
);
create index on public.projects (org_id);
insert into public.projects (org_id, name) values (:'acme', 'apollo'), (:'globex', 'gemini');

alter table public.projects enable row level security;
grant select, update on public.projects to authenticated;

create policy projects_select on public.projects for select to authenticated
    using (
        (select permissions.rbac_has_permission(permission => 'documents.read'))
        or org_id = any (array(select unnest(permissions.rbac_scopes_with_permission(permission => 'documents.read'))::uuid))
    );
create policy projects_update on public.projects for update to authenticated
    using (
        (select permissions.rbac_has_permission(permission => 'documents.edit'))
        or permissions.rbac_has_permission(permission => 'documents.edit', scope => org_id::text)
    );

select permissions.rbac_assign_role(user_id => :'dave', role => 'editor', scope => :'acme');
select permissions.rbac_assign_role(user_id => :'dave', role => 'viewer', scope => :'globex');
select permissions.rbac_assign_role(user_id => :'erin', role => 'viewer', scope => :'globex');

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'carol', true);
select tap.is((select count(*)::int from public.projects), 2, 'two checks: Carol (app-wide viewer) sees every org''s projects');
select set_config('permissions.subject_id', :'erin', true);
select tap.is(permissions.rbac_has_permission(permission => 'documents.read'), false, 'two checks: Erin''s role in globex gives no app-wide permission');
select tap.is(permissions.rbac_has_permission(permission => 'documents.read', scope => :'globex'), true, 'two checks: but it does inside globex');
select tap.set_eq(array(select name from public.projects), '{gemini}'::text[], 'two checks: Erin (viewer of globex only) sees globex''s projects');
select set_config('permissions.subject_id', :'frank', true);
select tap.is((select count(*)::int from public.projects), 0, 'two checks: Frank (no role) sees nothing');
select set_config('permissions.subject_id', :'dave', true);
select tap.is((select count(*)::int from public.projects), 2, 'two checks: Dave (editor of acme, viewer of globex) sees both');
update public.projects set name = upper(name);
select tap.set_eq(array(select name from public.projects order by name), '{APOLLO,gemini}'::text[], 'two checks: Dave can update acme''s projects only');
select set_config('permissions.subject_id', :'alice', true);
update public.projects set name = name || '!';
select tap.set_eq(array(select name from public.projects order by name), '{APOLLO!,gemini!}'::text[], 'two checks: Alice (app-wide admin) can update every org''s projects');
commit;

-- ============================================================================
-- Cleaning up when a user is deleted
-- ============================================================================

select permissions.rbac_assign_role(user_id => :'frank', role => 'viewer');
select tap.set_eq(permissions.rbac_user_permissions(user_id => :'frank'), '{documents.read}', 'cleanup: Frank holds viewer before he is deleted');

select to_regprocedure('permissions.delete_subject(text, text)') is not null as engine_a,
       to_regprocedure('permissions.delete_entity(text, text)') is not null as engine_b,
       to_regprocedure('permissions.forget_subject(uuid)') is not null as engine_c \gset

\if :engine_a
    select permissions.delete_subject(subject_type => 'user', subject_id => :'frank');
\elif :engine_b
    select permissions.delete_entity('user', :'frank');
\elif :engine_c
    select permissions.forget_subject(:'frank');
\else
    select tap.fail('cleanup: no known cleanup function');
\endif

select tap.set_eq(permissions.rbac_user_permissions(user_id => :'frank'), '{}', 'cleanup: the engine''s cleanup function removes the deleted user''s role assignments');

-- ============================================================================
-- Gotchas
-- ============================================================================

-- the short form is the one to call (no dummy argument), and it answers the same
select tap.set_eq(permissions.rbac_scopes_with_permission(permission => 'documents.read'), '{}'::text[], 'gotchas: rbac_scopes_with_permission takes only the permission name');
select tap.is(
    (select count(*)::int from pg_proc where pronamespace = 'permissions'::regnamespace
       and proname = 'rbac_scopes_with_permission' and provolatile = 's' and pronargs = 2),
    1, 'gotchas: rbac_scopes_with_permission is STABLE and has one trailing parameter that is not yours to pass');

select * from tap.finish();
