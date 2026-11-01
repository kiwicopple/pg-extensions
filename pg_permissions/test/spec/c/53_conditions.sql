-- Goal: conditions: document status and expired grants (research/plan.md §10, G13)
-- Design C: resource conditions stay in the RLS policy on the app's own column
-- (status), composed with two fast-path arms; grant expiry is expires_at on the tuple.
\ir ../../fixtures/ids.sql
\set gina      '00000000-0000-0000-0001-000000000007'
\set draft_doc '00000000-0000-0000-0003-000000000006'
\set readme    :acme_readme

select count(*) from permissions.apply_model($json$
{
  "types": {
    "org": {
      "relations":   { "admin": ["user"], "editor": ["user"], "member": ["user"] },
      "implies":     { "admin": ["editor"], "editor": ["member"] },
      "permissions": { "edit": ["editor"], "view": ["member"] }
    },
    "document": {
      "parent":      ["org"],
      "relations":   { "editor": ["user"], "viewer": ["user"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "edit": ["editor", "parent->edit"], "view": ["viewer", "parent->view"] }
    }
  }
}
$json$);

create table public.documents (
    id uuid primary key, org_id uuid not null, title text not null,
    status text not null check (status in ('draft', 'published'))
);
insert into public.documents values
    (:'readme',    :'acme', 'readme', 'published'),
    (:'draft_doc', :'acme', 'draft',  'draft');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
-- editors see everything; viewers see published documents only
create policy documents_select on public.documents for select to authenticated using (
    id = any ((select permissions.accessible('document', 'edit'))::uuid[])
    or (status = 'published' and id = any ((select permissions.accessible('document', 'view'))::uuid[]))
);

select permissions.set_parent('document', :'readme',    'org', :'acme');
select permissions.set_parent('document', :'draft_doc', 'org', :'acme');
select permissions.grant('org', :'acme', 'member', 'user', :'carol');
select permissions.grant('org', :'acme', 'editor', 'user', :'bob');
select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'user', :'gina', null, now() - interval '1 day');

select tap.plan(6);

set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'RLS as Carol (member): only published documents');
select set_config('permissions.subject_id', :'bob', false);
select tap.set_eq(array(select title from public.documents), '{readme,draft}', 'RLS as Bob (org editor): drafts too');
select set_config('permissions.subject_id', :'alice', false);
select tap.set_eq(array(select title from public.documents), '{readme,draft}', 'RLS as Alice (org admin): drafts too');
select set_config('permissions.subject_id', :'gina', false);
select tap.is((select count(*)::int from public.documents), 0, 'RLS as Gina (expired membership): nothing');
select set_config('permissions.subject_id', :'carol', false);
select tap.is((select count(*)::int from public.documents where id = :'draft_doc'), 0, 'Carol selecting the draft by id gets no rows');
reset role;

update public.documents set status = 'published' where id = :'draft_doc';
set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{readme,draft}', 'after the draft is published, Carol sees it');
reset role;

select * from tap.finish();
