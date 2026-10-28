-- Goal: conditions: document status and expired grants, asserted through RLS (PLAN.md §10 G13)
-- PROVISIONAL: uses Design A's zanzibar-level API. A has no condition evaluator:
-- the status rule is RLS composition over the app's own `status` column, and
-- expiry is the grant's `expires_at`. The document -> org parent link comes from
-- documents.org_id through the permissions.sync_parent() trigger.
\ir ../../fixtures/ids.sql
\set gina      '00000000-0000-0000-0001-000000000007'
\set draft_doc '00000000-0000-0000-0003-000000000006'

select permissions.define_type('user');
select permissions.define_type('org');
select permissions.define_type('document');

select permissions.define_relation('org', 'admin');
select permissions.define_relation('org', 'member', '{admin}');
select permissions.define_relation('org', 'editor', '{admin}');
select permissions.define_relation('org', 'viewer', '{member,editor}');
select permissions.define_relation('document', 'parent');
select permissions.define_relation('document', 'editor', from_parent => '{editor}');
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}');

create table public.documents (
    id     uuid primary key,
    org_id uuid not null,
    status text not null check (status in ('draft', 'published')),
    title  text not null
);
create trigger documents_parent after insert or update of org_id or delete on public.documents
    for each row execute function permissions.sync_parent('document', 'org', 'org_id');
insert into public.documents values
    (:'acme_readme', :'acme', 'published', 'readme'),
    (:'draft_doc',   :'acme', 'draft',     'draft doc');

alter table public.documents enable row level security;
grant select on public.documents to authenticated;
-- viewers see published documents; editors (and so admins) see drafts too
create policy documents_select on public.documents for select to authenticated using (
    (status = 'published' and id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid)))
    or id = any (array(select unnest(permissions.list_objects('document', 'editor'))::uuid))
);

select permissions.grant('org', :'acme', 'member', 'user', :'carol');
select permissions.grant('org', :'acme', 'editor', 'user', :'bob');
select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'user', :'gina', '', now() - interval '1 day');

select tap.plan(6);

set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'RLS as Carol (member) returns only the published document');
select set_config('permissions.subject_id', :'bob', false);
select tap.set_eq(array(select title from public.documents), '{readme,draft doc}', 'RLS as Bob (org editor) returns both documents');
select set_config('permissions.subject_id', :'alice', false);
select tap.set_eq(array(select title from public.documents), '{readme,draft doc}', 'RLS as Alice (org admin) returns both documents');
select set_config('permissions.subject_id', :'gina', false);
select tap.is((select count(*)::int from public.documents), 0, 'RLS as Gina (expired membership) returns nothing');
select set_config('permissions.subject_id', :'carol', false);
select tap.is((select count(*)::int from public.documents where id = :'draft_doc'), 0, 'Carol selecting draft_doc by id gets 0 rows');
reset role;

update public.documents set status = 'published' where id = :'draft_doc';
set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.is((select count(*)::int from public.documents where id = :'draft_doc'), 1, 'after draft_doc is published, Carol sees it');
reset role;

select * from tap.finish();
