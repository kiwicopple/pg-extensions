-- Goal: one table whose RLS combines both models (PLAN.md "Current plan").
-- Permissive policies OR: a document is visible with documents.read in its
-- org (rbac_*) or as its viewer (fga_*). A restrictive policy ANDs: nobody
-- sees the documents of an org that FGA says they are banned from. Updates:
-- documents.edit in the org (RBAC) or editor of the document (FGA).
\ir ../../fixtures/ids.sql
\ir ../../fixtures/d/rbac_roles.sql

-- model:
--   type user
--   type team
--     relations
--       define member: [user]
--   type org
--     relations
--       define banned: [user]
--   type document
--     relations
--       define editor: [user]
--       define viewer: [user, team#member] or editor
select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "team", "relations": {"member": {"this": {}}},
     "metadata": {"relations": {"member": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "org", "relations": {"banned": {"this": {}}},
     "metadata": {"relations": {"banned": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "document",
     "relations": {
       "editor": {"this": {}},
       "viewer": {"union": {"child": [{"this": {}}, {"computedUserset": {"relation": "editor"}}]}}},
     "metadata": {"relations": {
       "editor": {"directly_related_user_types": [{"type": "user"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]}}}}
  ]}$m$::jsonb);

create table public.documents (id uuid primary key, org_id uuid not null, title text not null);
insert into public.documents values
    (:'acme_plan',    :'acme',   'acme plan'),
    (:'acme_readme',  :'acme',   'acme readme'),
    (:'globex_notes', :'globex', 'globex notes');
alter table public.documents enable row level security;
grant select, update on public.documents to authenticated;

create policy documents_select_rbac on public.documents for select to authenticated
    using (org_id = any (array(select unnest(permissions.rbac_scopes_with_permission('documents.read'))::uuid)));
create policy documents_select_fga on public.documents for select to authenticated
    using (id = any (array(select permissions.fga_list_object_ids_current('document', 'viewer')::uuid)));
create policy documents_not_banned on public.documents as restrictive for select to authenticated
    using (org_id <> all (array(select permissions.fga_list_object_ids_current('org', 'banned')::uuid)));
create policy documents_update_rbac on public.documents for update to authenticated
    using (permissions.rbac_has_permission('documents.edit', org_id::text));
create policy documents_update_fga on public.documents for update to authenticated
    using (permissions.fga_check_current('editor', 'document:' || id));

-- RBAC: Alice reads acme, Carol edits acme, Dave reads acme
select permissions.rbac_assign_role(:'alice', 'viewer', :'acme');
select permissions.rbac_assign_role(:'carol', 'editor', :'acme');
select permissions.rbac_assign_role(:'dave',  'viewer', :'acme');
-- FGA: team eng (Bob) views the globex notes, Carol views them directly,
-- Bob edits the acme readme, Dave views the globex notes but is banned from acme
select permissions.fga_write(jsonb_build_array(
    jsonb_build_object('user', 'user:' || :'bob',   'relation', 'member', 'object', 'team:' || :'eng'),
    jsonb_build_object('user', 'team:' || :'eng' || '#member', 'relation', 'viewer', 'object', 'document:' || :'globex_notes'),
    jsonb_build_object('user', 'user:' || :'carol', 'relation', 'viewer', 'object', 'document:' || :'globex_notes'),
    jsonb_build_object('user', 'user:' || :'bob',   'relation', 'editor', 'object', 'document:' || :'acme_readme'),
    jsonb_build_object('user', 'user:' || :'dave',  'relation', 'viewer', 'object', 'document:' || :'globex_notes'),
    jsonb_build_object('user', 'user:' || :'dave',  'relation', 'banned', 'object', 'org:' || :'acme')));

select tap.plan(13);

set role authenticated;

select set_config('permissions.subject_id', :'alice', false);
select tap.set_eq(array(select title from public.documents), '{acme plan,acme readme}', 'Alice: acme through RBAC only');

select set_config('permissions.subject_id', :'bob', false);
select tap.set_eq(array(select title from public.documents), '{acme readme,globex notes}',
                  'Bob: no role; the globex notes through his team and the acme readme as its FGA editor');

select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{acme plan,acme readme,globex notes}',
                  'Carol: acme through RBAC, the globex notes through FGA (permissive policies OR)');

select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.documents), '{globex notes}',
                  'Dave: his acme role is overridden by the FGA ban (restrictive policy ANDs)');

select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents), '{}'::text[], 'Erin: nothing');

select set_config('permissions.subject_id', '', false);
select tap.set_eq(array(select title from public.documents), '{}'::text[], 'no subject: nothing');

-- updates: RBAC documents.edit in the org, or FGA editor of the row
select set_config('permissions.subject_id', :'bob', false);
update public.documents set title = title || '!';
select tap.set_eq(array(select title from public.documents where title like '%!'), '{acme readme!}', 'Bob updates only the document he is FGA editor of');

select set_config('permissions.subject_id', :'carol', false);
update public.documents set title = title || '?';
select tap.set_eq(array(select title from public.documents where title like '%?'), '{acme plan?,acme readme!?}',
                  'Carol updates the acme documents (RBAC), not the globex notes she only views');

select set_config('permissions.subject_id', :'alice', false);
update public.documents set title = title || '#';
select tap.is((select count(*)::int from public.documents where title like '%#'), 0, 'Alice (viewer) updates nothing');

-- the JWT identifies the subject inside both models' policies
select set_config('permissions.subject_id', '', false);
select set_config('request.jwt.claims', json_build_object('sub', :'carol')::text, false);
select tap.is((select count(*)::int from public.documents), 3, 'identity from the JWT works for RBAC and FGA policies');
select set_config('request.jwt.claims', '', false);

-- every list policy runs once per query
reset role;
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
-- `InitPlan n` heads a line; Postgres 17+ also names it inside filters, as (InitPlan n).col1
select tap.is((select count(*)::int from plan_lines where ltrim(line) like 'InitPlan%'), 3, 'the three select policies are InitPlans');
select tap.ok(not exists (select 1 from plan_lines where line ~* 'SubPlan'), 'and none is a per-row SubPlan');
reset role;

-- the RBAC data is untouched by the FGA writes, and the other way round
select tap.ok(permissions.rbac_user_permissions(:'bob', :'acme') = '{}' and permissions.fga_check('user:' || :'carol', 'viewer', 'document:' || :'acme_plan') = false,
              'the models are separate: FGA grants no roles, RBAC grants no relations');

select * from tap.finish();
