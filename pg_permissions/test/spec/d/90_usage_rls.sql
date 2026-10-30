-- Goal: every example in usage/rls.md ("RLS with both models") works as written.
--
-- This file mirrors that page, section by section and in the same order, so the
-- state one section builds is what the next one uses. When you change an
-- example on the page, change it here, and the other way round. Statements
-- without a result are copied from the page; queries that return something
-- appear as tap.is(<the same expression>, <the documented answer>).
--
-- The page's own IDs: it defines them in its first code block.
\ir ../../fixtures/fga_suite.sql
\set alice  '11111111-1111-1111-1111-111111111111'
\set bob    '22222222-2222-2222-2222-222222222222'
\set carol  '33333333-3333-3333-3333-333333333333'
\set dave   '44444444-4444-4444-4444-444444444444'
\set erin   '55555555-5555-5555-5555-555555555555'
\set acme   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
\set globex 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
\set eng    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
\set plan   'd0000000-0000-0000-0000-000000000001'
\set readme 'd0000000-0000-0000-0000-000000000002'
\set notes  'd0000000-0000-0000-0000-000000000003'
\set draft  'd0000000-0000-0000-0000-000000000004'
\set diary  'd0000000-0000-0000-0000-000000000005'

select tap.plan(36);

-- ============================================================================
-- Setup
-- ============================================================================

select permissions.rbac_create_role(role => 'viewer', permissions => '{documents.read}');
select permissions.rbac_create_role(role => 'editor', permissions => '{documents.edit}', inherits => '{viewer}');

-- model.fga, transformed with `fga model transform`:
--   type user
--   type team
--     relations
--       define member: [user]
--   type org
--     relations
--       define banned: [user]
--   type document
--     relations
--       define owner: [user]
--       define editor: [user] or owner
--       define viewer: [user, team#member] or editor
--       define published: [user:*]
--       define reader: (viewer and published) or editor
\set model '{"schema_version":"1.1","type_definitions":[{"type":"user"},{"metadata":{"relations":{"member":{"directly_related_user_types":[{"type":"user"}]}}},"relations":{"member":{"this":{}}},"type":"team"},{"metadata":{"relations":{"banned":{"directly_related_user_types":[{"type":"user"}]}}},"relations":{"banned":{"this":{}}},"type":"org"},{"metadata":{"relations":{"editor":{"directly_related_user_types":[{"type":"user"}]},"owner":{"directly_related_user_types":[{"type":"user"}]},"published":{"directly_related_user_types":[{"type":"user","wildcard":{}}]},"reader":{},"viewer":{"directly_related_user_types":[{"type":"user"},{"relation":"member","type":"team"}]}}},"relations":{"editor":{"union":{"child":[{"this":{}},{"computedUserset":{"relation":"owner"}}]}},"owner":{"this":{}},"published":{"this":{}},"reader":{"union":{"child":[{"intersection":{"child":[{"computedUserset":{"relation":"viewer"}},{"computedUserset":{"relation":"published"}}]}},{"computedUserset":{"relation":"editor"}}]}},"viewer":{"union":{"child":[{"this":{}},{"computedUserset":{"relation":"editor"}}]}}},"type":"document"}]}'
select permissions.fga_write_authorization_model(model => :'model');

create table public.documents (
    id     uuid primary key,
    org_id uuid,                 -- null: a personal document
    status text not null default 'published',
    title  text not null
);
create index on public.documents (org_id);
insert into public.documents (id, org_id, status, title) values
    (:'plan',   :'acme',   'published', 'acme plan'),
    (:'readme', :'acme',   'published', 'acme readme'),
    (:'notes',  :'globex', 'published', 'globex notes'),
    (:'draft',  :'globex', 'draft',     'globex draft'),
    (:'diary',  null,      'published', 'dave''s diary');
alter table public.documents enable row level security;
grant select, update on public.documents to authenticated;

-- RBAC: Alice reads acme, Carol edits acme, Dave reads acme
select permissions.rbac_assign_role(user_id => :'alice', role => 'viewer', scope => :'acme');
select permissions.rbac_assign_role(user_id => :'carol', role => 'editor', scope => :'acme');
select permissions.rbac_assign_role(user_id => :'dave',  role => 'viewer', scope => :'acme');
-- FGA: team eng (Bob) views the globex notes and the draft, Bob edits the acme
-- readme, Dave owns his diary, views the globex notes and is banned from acme
select permissions.fga_write(writes => jsonb_build_array(
    jsonb_build_object('user', 'user:' || :'bob',  'relation', 'member', 'object', 'team:' || :'eng'),
    jsonb_build_object('user', 'team:' || :'eng' || '#member', 'relation', 'viewer', 'object', 'document:' || :'notes'),
    jsonb_build_object('user', 'team:' || :'eng' || '#member', 'relation', 'viewer', 'object', 'document:' || :'draft'),
    jsonb_build_object('user', 'user:' || :'bob',  'relation', 'editor', 'object', 'document:' || :'readme'),
    jsonb_build_object('user', 'user:' || :'dave', 'relation', 'owner',  'object', 'document:' || :'diary'),
    jsonb_build_object('user', 'user:' || :'dave', 'relation', 'viewer', 'object', 'document:' || :'notes'),
    jsonb_build_object('user', 'user:' || :'dave', 'relation', 'banned', 'object', 'org:' || :'acme')));
select tap.pass('setup: roles, model, table and tuples');

-- ============================================================================
-- The current-subject functions
-- ============================================================================

begin;
select set_config('permissions.subject_id', :'bob', true);
select tap.is(permissions.fga_check_current(relation => 'editor', object => 'document:' || :'readme'), true, 'current subject: fga_check_current asks for user:<current_subject_id()>');
select tap.set_eq(array(select permissions.fga_list_object_ids_current(type => 'document', relation => 'viewer')),
                  array[:'readme', :'notes', :'draft'], 'current subject: fga_list_object_ids_current returns bare ids');
select tap.set_eq(array(select permissions.fga_list_objects_current(type => 'document', relation => 'viewer')),
                  array['document:' || :'readme', 'document:' || :'notes', 'document:' || :'draft'], 'current subject: fga_list_objects_current returns type:id');
commit;
select tap.is(permissions.fga_check_current(relation => 'editor', object => 'document:' || :'readme'), false, 'current subject: no subject, false');
select tap.set_eq(array(select permissions.fga_list_object_ids_current(type => 'document', relation => 'viewer')), '{}'::text[], 'current subject: no subject, nothing');

-- ============================================================================
-- Policies
-- ============================================================================

-- reads: permissive policies OR together
create policy documents_select_rbac on public.documents for select to authenticated
    using (org_id = any (array(select unnest(permissions.rbac_scopes_with_permission(permission => 'documents.read'))::uuid)));
create policy documents_select_fga on public.documents for select to authenticated
    using (id = any (array(select permissions.fga_list_object_ids_current(type => 'document', relation => 'viewer')::uuid)));
-- a restrictive policy ANDs: nobody sees the documents of an org they are banned from
create policy documents_not_banned on public.documents as restrictive for select to authenticated
    using (org_id is null or org_id <> all (array(select permissions.fga_list_object_ids_current(type => 'org', relation => 'banned')::uuid)));
-- writes: check the row
create policy documents_update_rbac on public.documents for update to authenticated
    using (permissions.rbac_has_permission(permission => 'documents.edit', scope => org_id::text));
create policy documents_update_fga on public.documents for update to authenticated
    using (permissions.fga_check_current(relation => 'editor', object => 'document:' || id));

set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.set_eq(array(select title from public.documents), '{acme plan,acme readme}', 'policies: Alice, acme through RBAC');
select set_config('permissions.subject_id', :'bob', false);
select tap.set_eq(array(select title from public.documents), '{acme readme,globex notes,globex draft}', 'policies: Bob, through FGA only');
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{acme plan,acme readme}', 'policies: Carol, through RBAC');
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.documents), '{globex notes,dave''s diary}', 'policies: Dave, his acme role overridden by the ban');
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents), '{}'::text[], 'policies: Erin, nothing');

select set_config('permissions.subject_id', :'bob', false);
update public.documents set title = title || '!';
select tap.set_eq(array(select title from public.documents where title like '%!'), '{acme readme!}', 'policies: Bob updates the document he edits');
select set_config('permissions.subject_id', :'carol', false);
update public.documents set title = title || '?';
select tap.set_eq(array(select title from public.documents where title like '%?'), '{acme plan?,acme readme!?}', 'policies: Carol updates acme');
reset role;
select set_config('permissions.subject_id', '', false);

-- why `org_id is null or`: a comparison with null is null, and RLS treats null as false
select tap.is((select null::uuid <> all (array[:'acme'::uuid])), null::boolean, 'policies: null <> all (...) is null, not true');

-- ============================================================================
-- Plan-time evaluation
-- ============================================================================

create temp table plan_lines (line text);
grant all on plan_lines to authenticated;
set role authenticated;
select set_config('permissions.subject_id', :'bob', false);
do $$
declare l text;
begin
    for l in execute 'explain select * from public.documents' loop
        insert into plan_lines values (l);
    end loop;
end $$;
select tap.is((select count(*)::int from plan_lines where ltrim(line) like 'InitPlan%'), 3, 'plan: the three list policies are InitPlans');
select tap.ok(not exists (select 1 from plan_lines where line ~* 'SubPlan'), 'plan: no per-row SubPlan');
reset role;
select set_config('permissions.subject_id', '', false);
select tap.is((select provolatile from pg_proc where oid = 'permissions.fga_list_object_ids_current(text, text)'::regprocedure), 's',
              'plan: fga_list_object_ids_current is STABLE');
select tap.is((select proretset from pg_proc where oid = 'permissions.fga_list_object_ids_current(text, text)'::regprocedure), true,
              'plan: and returns a set, so the planner never calls it');

-- ============================================================================
-- Typos raise
-- ============================================================================

begin;
select set_config('permissions.subject_id', :'bob', true);
select tap.is((fga_test.error_of($$ select permissions.fga_check_current(relation => 'editr', object => 'document:x') $$)).msg,
              'relation ''document#editr'' not found', 'typos: an unknown relation raises');
select tap.is((fga_test.error_of($$ select permissions.fga_check_current(relation => 'editr', object => 'document:x') $$)).hint,
              'Did you mean ''editor''? Relations on type ''document'': editor, owner, published, reader, viewer.', 'typos: with a hint');
select tap.is((fga_test.error_of($$ select permissions.fga_list_object_ids_current(type => 'documnt', relation => 'viewer') $$)).detail,
              'openfga:2000 validation_error', 'typos: an unknown type too');
select tap.is(permissions.rbac_has_permission(permission => 'documents.reed'), false, 'typos: an unknown RBAC permission is false');
commit;

-- ============================================================================
-- Row attributes that only RLS sees
-- ============================================================================

create policy documents_published on public.documents as restrictive for select to authenticated
    using (status = 'published' or id = any (array(select permissions.fga_list_object_ids_current(type => 'document', relation => 'editor')::uuid)));

set role authenticated;
select set_config('permissions.subject_id', :'bob', false);
select tap.set_eq(array(select title from public.documents), '{acme readme!?,globex notes}', 'attributes: RLS hides the draft from Bob');
select tap.is(permissions.fga_check_current(relation => 'viewer', object => 'document:' || :'draft'), true, 'attributes: fga_check_current still says Bob views it');
reset role;
select set_config('permissions.subject_id', '', false);

-- pass the attribute in, from a backend
select tap.is(permissions.fga_check(subject => 'user:' || :'bob', relation => 'reader', object => 'document:' || :'draft'), false,
              'attributes: reader, with no published tuple for the draft');
select tap.is(permissions.fga_check(subject => 'user:' || :'bob', relation => 'reader', object => 'document:' || d.id,
                  contextual_tuples => case when d.status = 'published'
                      then jsonb_build_array(jsonb_build_object('user', 'user:*', 'relation', 'published', 'object', 'document:' || d.id))
                  end), true, 'attributes: reader of the notes, published passed in')
from public.documents d where d.id = :'notes';
select tap.is(permissions.fga_check(subject => 'user:' || :'bob', relation => 'reader', object => 'document:' || d.id,
                  contextual_tuples => case when d.status = 'published'
                      then jsonb_build_array(jsonb_build_object('user', 'user:*', 'relation', 'published', 'object', 'document:' || d.id))
                  end), false, 'attributes: not reader of the draft')
from public.documents d where d.id = :'draft';

-- ============================================================================
-- Conditions in policies
-- ============================================================================

-- `fga model transform` of the page's model with the viewer line and the condition changed (openfga/cli v0.8.2;
-- its \u003c written as <, which psql's \set would mangle):
\set model '{"schema_version":"1.1","type_definitions":[{"type":"user"},{"metadata":{"relations":{"member":{"directly_related_user_types":[{"type":"user"}]}}},"relations":{"member":{"this":{}}},"type":"team"},{"metadata":{"relations":{"banned":{"directly_related_user_types":[{"type":"user"}]}}},"relations":{"banned":{"this":{}}},"type":"org"},{"metadata":{"relations":{"editor":{"directly_related_user_types":[{"type":"user"}]},"owner":{"directly_related_user_types":[{"type":"user"}]},"published":{"directly_related_user_types":[{"type":"user","wildcard":{}}]},"reader":{},"viewer":{"directly_related_user_types":[{"type":"user"},{"condition":"non_expired_grant","type":"user"},{"relation":"member","type":"team"}]}}},"relations":{"editor":{"union":{"child":[{"this":{}},{"computedUserset":{"relation":"owner"}}]}},"owner":{"this":{}},"published":{"this":{}},"reader":{"union":{"child":[{"intersection":{"child":[{"computedUserset":{"relation":"viewer"}},{"computedUserset":{"relation":"published"}}]}},{"computedUserset":{"relation":"editor"}}]}},"viewer":{"union":{"child":[{"this":{}},{"computedUserset":{"relation":"editor"}}]}}},"type":"document"}],"conditions":{"non_expired_grant":{"expression":"current_time < grant_time + grant_duration","name":"non_expired_grant","parameters":{"current_time":{"type_name":"TYPE_NAME_TIMESTAMP"},"grant_duration":{"type_name":"TYPE_NAME_DURATION"},"grant_time":{"type_name":"TYPE_NAME_TIMESTAMP"}}}}}'
select permissions.fga_write_authorization_model(model => :'model');
select permissions.fga_write(writes => jsonb_build_array(jsonb_build_object(
    'user', 'user:' || :'erin', 'relation', 'viewer', 'object', 'document:' || :'plan',
    'condition', jsonb_build_object('name', 'non_expired_grant',
        'context', jsonb_build_object('grant_time', now() - interval '1 day', 'grant_duration', '720h')))));

set role authenticated;
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select id::text from public.documents), '{}'::text[], 'conditions: Erin sees nothing, the policies have no current_time');
select tap.is(permissions.fga_check_current(relation => 'viewer', object => 'document:' || :'plan'), false, 'conditions: fga_check_current is false, not an error');
reset role;

create function public.fga_check_now(relation text, object text) returns boolean
language plpgsql stable security definer set search_path = ''
as $$
begin
    return permissions.fga_check(subject => 'user:' || permissions.current_subject_id(),
                                 relation => relation, object => object,
                                 context => jsonb_build_object('current_time', now()));
exception when invalid_parameter_value then
    return false;   -- no subject, or a condition that still can't be evaluated (openfga:2000): deny
end;
$$;
revoke all on function public.fga_check_now(text, text) from public;
grant execute on function public.fga_check_now(text, text) to authenticated;

create policy documents_select_timed on public.documents for select to authenticated
    using (public.fga_check_now('viewer', 'document:' || id));

set role authenticated;
select tap.set_eq(array(select id::text from public.documents), array[:'plan'], 'conditions: with the time passed by fga_check_now, Erin sees the acme plan');
select set_config('permissions.subject_id', '', false);
select tap.set_eq(array(select id::text from public.documents), '{}'::text[], 'conditions: no subject, nothing (fga_check_now denies)');
reset role;

-- ============================================================================
-- Cleaning up when a user is deleted
-- ============================================================================

create table public.users (id uuid primary key);
insert into public.users values (:'alice'), (:'bob'), (:'carol'), (:'dave'), (:'erin');

create function public.forget_user() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
    perform permissions.delete_subject(subject_type => 'user', subject_id => old.id::text);
    return old;
end;
$$;
create trigger forget_user after delete on public.users
    for each row execute function public.forget_user();

select tap.set_eq(permissions.rbac_user_permissions(user_id => :'dave', scope => :'acme'), '{documents.read}', 'cleanup: Dave holds a role');
select tap.is((select jsonb_array_length(tuples) from permissions.fga_read(subject => 'user:' || :'dave')), 3, 'cleanup: and three tuples');
delete from public.users where id = :'dave';
select tap.set_eq(permissions.rbac_user_permissions(user_id => :'dave', scope => :'acme'), '{}'::text[], 'cleanup: deleting the user removes his roles');
select tap.is((select jsonb_array_length(tuples) from permissions.fga_read(subject => 'user:' || :'dave')), 0, 'cleanup: and his tuples');
select tap.is(permissions.delete_subject(subject_type => 'team', subject_id => :'eng'), 3::bigint, 'cleanup: delete_subject works for any type: team eng''s two viewer tuples and its member');

select * from tap.finish();
