-- Goal: parent inheritance org -> folder -> document (PLAN.md §10, G10)
-- Design C: a type declares its parent types ("parent": [...]) and a permission
-- inherits itself from the parent with "parent->P". Parent links are set with
-- set_parent() (one parent per object). Reads stay flat: the object, its parent
-- and the parent's precomputed ancestors. Cycles are rejected when written.
\ir ../../fixtures/ids.sql
\set frank      '00000000-0000-0000-0001-000000000006'
\set roadmap    '00000000-0000-0000-0003-000000000004'
\set globex_doc '00000000-0000-0000-0003-000000000007'
\set specs      '00000000-0000-0000-0005-000000000001'
\set plans      '00000000-0000-0000-0005-000000000002'
\set readme     :acme_readme

select count(*) from permissions.apply_model($json$
{
  "types": {
    "team": { "relations": { "member": ["user", "team#member"] } },
    "org": {
      "relations":   { "admin": ["user"], "member": ["user", "team#member"] },
      "implies":     { "admin": ["member"] },
      "permissions": { "edit": ["admin"], "view": ["member"] }
    },
    "folder": {
      "parent":      ["org", "folder"],
      "relations":   { "editor": ["user", "team#member"], "viewer": ["user", "team#member"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "edit": ["editor", "parent->edit"], "view": ["viewer", "parent->view"] }
    },
    "document": {
      "parent":      ["folder", "org"],
      "relations":   { "editor": ["user", "team#member"], "viewer": ["user", "team#member"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "edit": ["editor", "parent->edit"], "view": ["viewer", "parent->view"] }
    }
  }
}
$json$);

create table public.documents (id uuid primary key, org_id uuid not null, folder_id uuid, title text not null);
insert into public.documents values
    (:'readme',     :'acme',   :'specs', 'readme'),
    (:'roadmap',    :'acme',   :'plans', 'roadmap'),
    (:'globex_doc', :'globex', null,     'globex doc');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
-- one fast-path branch: no hand-written org_id arm
create policy documents_select on public.documents for select to authenticated using (
    id = any ((select permissions.accessible('document', 'view'))::uuid[])
);

select permissions.set_parent('folder',   :'specs',      'org',    :'acme');
select permissions.set_parent('folder',   :'plans',      'org',    :'acme');
select permissions.set_parent('document', :'readme',     'folder', :'specs');
select permissions.set_parent('document', :'roadmap',    'folder', :'plans');
select permissions.set_parent('document', :'globex_doc', 'org',    :'globex');

select permissions.grant('org',    :'acme',  'admin',  'user', :'alice');
select permissions.grant('org',    :'acme',  'member', 'user', :'carol');
select permissions.grant('folder', :'specs', 'viewer', 'user', :'erin');

select tap.plan(13);

select tap.is(permissions.can_for('user', :'alice', 'document', :'readme',  'edit'), true,  'Alice (org admin) can edit readme');
select tap.is(permissions.can_for('user', :'alice', 'document', :'roadmap', 'edit'), true,  'Alice (org admin) can edit roadmap');
select tap.is(permissions.can_for('user', :'carol', 'document', :'readme',  'view'), true,  'Carol (org member) can view readme');
select tap.is(permissions.can_for('user', :'carol', 'document', :'readme',  'edit'), false, 'Carol (org member) cannot edit readme');
select tap.is(permissions.can_for('user', :'erin',  'document', :'readme',  'view'), true,  'Erin (viewer of folder specs) can view readme');
select tap.is(permissions.can_for('user', :'erin',  'document', :'roadmap', 'view'), false, 'Erin cannot view a document in another folder');
select tap.set_eq(array(select permissions.who_can('document', :'readme', 'view')),
                  array[:'alice', :'carol', :'erin']::uuid[], 'subjects who can view readme: Alice, Carol, Erin');

set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{readme,roadmap}', 'RLS as Carol: every acme document');
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'RLS as Erin: only the document in her folder');
reset role;

select permissions.revoke('folder', :'specs', 'viewer', 'user', :'erin');
select tap.is(permissions.can_for('user', :'erin', 'document', :'readme', 'view'), false, 'revoking Erin''s folder grant removes her access');

select permissions.grant('folder', :'specs', 'viewer', 'user', :'erin');
select permissions.set_parent('document', :'readme', 'folder', :'plans');
update public.documents set folder_id = :'plans' where id = :'readme';
select tap.is(permissions.can_for('user', :'erin', 'document', :'readme', 'view'), false, 'after moving readme to plans, Erin cannot view it');

select permissions.set_parent('document', :'readme', 'folder', :'specs');
update public.documents set folder_id = :'specs' where id = :'readme';
select tap.is(permissions.can_for('user', :'erin', 'document', :'readme', 'view'), true, 'after moving it back, Erin can');

-- cycles: C rejects them on write (closing specs <-> plans fails). Traversals
-- around the attempted cycle run under a timeout first, so a hang or error fails the file.
select permissions.set_parent('folder', :'plans', 'folder', :'specs');   -- plans under specs: fine
create function pg_temp.raises(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
set statement_timeout = '5s';
select permissions.can_for('user', :'erin', 'document', :'roadmap', 'view');   -- through specs -> plans
select count(*) from permissions.who_can('document', :'roadmap', 'view');
select tap.ok(
    pg_temp.raises(format($$ select permissions.set_parent('folder', %L, 'folder', %L) $$, :'specs', :'plans'))
    and not permissions.can_for('user', :'frank', 'document', :'readme', 'view')
    and permissions.can_for('user', :'erin', 'document', :'roadmap', 'view'),
    'a parent cycle (specs <-> plans) is rejected on write; a non-grantee still gets false');
reset statement_timeout;

select * from tap.finish();
