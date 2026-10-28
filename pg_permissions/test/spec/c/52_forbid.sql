-- Goal: forbid beats grants, including parent-derived ones (PLAN.md §10, G12)
-- Design C: a permission can list exclusion relations ("but_not"). A forbid is a
-- grant of such a relation (here document#blocked), so it is admin-only like
-- every grant. A forbid on an object also applies to everything that inherits
-- the permission from it (deny wins over the whole parent chain).
\ir ../../fixtures/ids.sql
\set roadmap '00000000-0000-0000-0003-000000000004'
\set readme  :acme_readme

select count(*) from permissions.apply_model($json$
{
  "types": {
    "team": { "relations": { "member": ["user", "team#member"] } },
    "org": {
      "relations":   { "admin": ["user"], "member": ["user", "team#member"] },
      "implies":     { "admin": ["member"] },
      "permissions": { "edit": ["admin"], "view": ["member"] }
    },
    "document": {
      "parent":      ["org"],
      "relations":   { "editor": ["user", "team#member"], "viewer": ["user", "team#member"],
                       "blocked": ["user", "team#member"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": {
        "edit": { "any": ["editor", "parent->edit"], "but_not": ["blocked"] },
        "view": { "any": ["viewer", "parent->view"], "but_not": ["blocked"] }
      }
    }
  }
}
$json$);

create table public.documents (id uuid primary key, org_id uuid not null, title text not null);
insert into public.documents values (:'readme', :'acme', 'readme'), (:'roadmap', :'acme', 'roadmap');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
create policy documents_select on public.documents for select to authenticated using (
    id = any ((select permissions.accessible('document', 'view'))::uuid[])
);

-- reference scenario, with documents under org acme
select permissions.set_parent('document', :'readme',  'org', :'acme');
select permissions.set_parent('document', :'roadmap', 'org', :'acme');
select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('team', :'eng', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'dave');
select permissions.grant('document', :'readme', 'editor', 'user', :'bob');
select permissions.grant('document', :'readme', 'viewer', 'team', :'eng', 'member');

select tap.plan(9);

select tap.is(permissions.can_for('user', :'dave', 'document', :'readme', 'view'), true, 'before: Dave can view readme through team eng');

select permissions.grant('document', :'readme', 'blocked', 'user', :'dave');
select tap.is(permissions.can_for('user', :'dave', 'document', :'readme', 'view'), false, 'after a forbid: Dave cannot');
select tap.ok(not :'readme' = any (permissions.accessible_for('user', :'dave', 'document', 'view')), 'readme is not in Dave''s list');
select tap.ok(
    (select not :'dave'::uuid = any (s) and :'carol'::uuid = any (s)
     from (select array(select permissions.who_can('document', :'readme', 'view')) s) x),
    'Dave is not in readme''s subject list; Carol still is');

set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.is((select count(*)::int from public.documents where id = :'readme'), 0, 'RLS as Dave excludes readme');
reset role;

select permissions.grant('document', :'readme', 'blocked', 'user', :'alice');
select tap.ok(not permissions.can_for('user', :'alice', 'document', :'readme', 'edit')
              and not permissions.can_for('user', :'alice', 'document', :'readme', 'view'),
              'a forbid on Alice beats her org-derived admin access: no edit, no view');
select tap.is(permissions.can_for('user', :'alice', 'document', :'roadmap', 'edit'), true, 'Alice can still edit roadmap');

select permissions.revoke('document', :'readme', 'blocked', 'user', :'dave');
select tap.is(permissions.can_for('user', :'dave', 'document', :'readme', 'view'), true, 'removing Dave''s forbid restores his access');

set role authenticated;
select tap.throws_ok(format($$ select permissions.grant('document', %L, 'blocked', 'user', %L) $$, :'readme', :'carol'),
                     '42501', 'clients cannot create forbids');
reset role;

select * from tap.finish();
