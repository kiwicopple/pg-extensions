-- Goal: public access, user:* (PLAN.md §10, G11)
-- Design C: the model allows "user:*" on a relation; grant_public() writes it
-- (a separate function, so a null subject id can never grant public access).
\ir ../../fixtures/ids.sql
\set frank        '00000000-0000-0000-0001-000000000006'
\set announcement '00000000-0000-0000-0003-000000000005'

select count(*) from permissions.apply_model($json$
{
  "types": {
    "document": {
      "relations":   { "editor": ["user"], "viewer": ["user", "user:*"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "edit": ["editor"], "view": ["viewer"] }
    }
  }
}
$json$);

create table public.documents (id uuid primary key, title text not null);
insert into public.documents values (:'announcement', 'announcement'), (:'acme_readme', 'readme');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
create policy documents_select on public.documents for select to authenticated using (
    id = any ((select permissions.accessible('document', 'view'))::uuid[])
);

select permissions.grant('document', :'acme_readme', 'editor', 'user', :'bob');
select permissions.grant_public('document', :'announcement', 'viewer');

select tap.plan(7);

select tap.is(permissions.can_for('user', :'frank', 'document', :'announcement', 'view'), true,  'Frank (no data) can view the announcement');
select tap.is(permissions.can_for('user', :'frank', 'document', :'announcement', 'edit'), false, 'but cannot edit it');
select tap.ok(:'announcement' = any (permissions.accessible_for('user', :'frank', 'document', 'view')), 'the announcement is in Frank''s viewable objects');

set role authenticated;
select set_config('permissions.subject_id', :'frank', false);
select tap.set_eq(array(select title from public.documents), '{announcement}', 'RLS as Frank: only the announcement');
select set_config('permissions.subject_id', '', false);
select tap.is(permissions.can('document', :'announcement', 'view'), false, 'a request with no subject is denied');
reset role;

select permissions.revoke_public('document', :'announcement', 'viewer');
select tap.is(permissions.can_for('user', :'frank', 'document', :'announcement', 'view'), false, 'after revoking public access Frank cannot view it');

set role authenticated;
select set_config('permissions.subject_id', :'frank', false);
select tap.is((select count(*)::int from public.documents), 0, 'RLS as Frank: nothing');
reset role;

select * from tap.finish();
