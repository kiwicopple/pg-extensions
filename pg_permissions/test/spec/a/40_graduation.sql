-- Goal: an rbac app adds per-object sharing without migrating anything (PLAN.md §6, RBAC scenario step 4)
-- PROVISIONAL: the sharing half uses Design A's zanzibar-level API.
\ir ../../fixtures/ids.sql
\ir ../../fixtures/rbac_roles.sql

create table public.documents (id uuid primary key, org_id uuid not null, title text not null);
insert into public.documents values
    (:'acme_plan',    :'acme',   'acme plan'),
    (:'acme_readme',  :'acme',   'acme readme'),
    (:'globex_notes', :'globex', 'globex notes');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;

select permissions.assign_role(:'alice', 'admin',  :'acme');
select permissions.assign_role(:'bob',   'editor', :'acme');
select permissions.assign_role(:'bob',   'viewer', :'globex');

-- answers before graduating
create temp table before as
select u, s, permissions.user_permissions(u, s) as perms
from unnest(array[:'alice', :'bob']) u, unnest(array[:'acme', :'globex']) s;

-- graduate: share the acme readme with Dave, who is in no org
select permissions.define_type('document');
select permissions.define_relation('document', 'editor');
select permissions.define_relation('document', 'viewer', '{editor}');
select permissions.grant('document', :'acme_readme', 'editor', 'user', :'dave');

-- the select policy gains one branch
create policy documents_select on public.documents for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
    or id  = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);

select tap.plan(5);

select tap.is(
    (select count(*)::int from before b where b.perms is distinct from permissions.user_permissions(b.u, b.s)),
    0, 'every rbac answer is unchanged after adding sharing');

set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.documents), '{acme readme}', 'Dave sees only the document shared with him');
select tap.is(permissions.has_permission('documents.read', :'acme'), false, 'sharing a document does not make Dave an org member');

select set_config('permissions.subject_id', :'bob', false);
select tap.is((select count(*)::int from public.documents), 3, 'Bob still sees everything his roles allow');

select set_config('permissions.subject_id', :'erin', false);
select tap.is((select count(*)::int from public.documents), 0, 'users with neither roles nor shares see nothing');
reset role;

select * from tap.finish();
