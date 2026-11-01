-- Goal: attribute conditions: document status and expired grants (research/plan.md §10 G13)
-- Design B: the status rule is a policy condition on a resource attribute
-- (resource.status). apply_rls compiles it into the RLS expression as a SQL
-- predicate on documents.status next to its own ids() group, so it stays on
-- the fast path. Grant expiry is a column on the grant (role_grants.expires_at).
\ir ../../fixtures/ids.sql
\set gina      '00000000-0000-0000-0001-000000000007'
\set draft_doc '00000000-0000-0000-0003-000000000006'

select permissions.define_role('org', 'member');
select permissions.define_role('org', 'editor', '{member}');
select permissions.define_role('org', 'admin',  '{editor}');

select permissions.permit('org members view published docs', '{select}', 'document', roles => '{member}', via => 'org',
                          condition => '{"op": "==", "left": {"var": "resource.status"}, "right": "published"}');
select permissions.permit('org editors view all docs',       '{select}', 'document', roles => '{editor}', via => 'org');

select permissions.grant_role('user', :'carol', 'member', 'org', :'acme');
select permissions.grant_role('user', :'bob',   'editor', 'org', :'acme');
select permissions.grant_role('user', :'alice', 'admin',  'org', :'acme');
select permissions.grant_role('user', :'gina',  'member', 'org', :'acme', now() - interval '1 day');

create table public.documents (id uuid primary key, org_id uuid not null, status text not null, title text not null);
insert into public.documents values
    (:'acme_readme', :'acme', 'published', 'readme'),
    (:'draft_doc',   :'acme', 'draft',     'draft');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
select permissions.apply_rls('public.documents', 'select', 'document', 'id', '{"org": "org_id"}');

select tap.plan(6);

set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'RLS as Carol (member) shows only published documents');
select set_config('permissions.subject_id', :'bob', false);
select tap.set_eq(array(select title from public.documents), '{readme,draft}', 'RLS as Bob (editor) shows drafts too');
select set_config('permissions.subject_id', :'alice', false);
select tap.set_eq(array(select title from public.documents), '{readme,draft}', 'RLS as Alice (admin) shows drafts too');
select set_config('permissions.subject_id', :'gina', false);
select tap.set_eq(array(select title from public.documents), '{}', 'RLS as Gina (expired grant) shows nothing');
select set_config('permissions.subject_id', :'carol', false);
select tap.is((select count(*)::int from public.documents where id = :'draft_doc'), 0, 'Carol selecting the draft by id gets no rows');
reset role;

update public.documents set status = 'published' where id = :'draft_doc';
set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.is((select count(*)::int from public.documents where id = :'draft_doc'), 1, 'once it is published, Carol sees it');
reset role;

select * from tap.finish();
