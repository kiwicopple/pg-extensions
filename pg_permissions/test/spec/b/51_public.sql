-- Goal: public access, user:* (research/plan.md §10 G11)
-- Design B: public access is a policy with no role requirement on one
-- resource (Cedar's `permit (principal, action, resource == Document::"x")`).
-- It applies to every non-null user subject; revoking it is drop_policy.
-- RLS comes from apply_rls (the generated permit/forbid expression).
\ir ../../fixtures/ids.sql
\set frank        '00000000-0000-0000-0001-000000000006'
\set announcement '00000000-0000-0000-0003-000000000005'

select permissions.define_role('document', 'viewer');
select permissions.define_role('document', 'editor', '{viewer}');
select permissions.permit('doc viewers view', '{select}', 'document', roles => '{viewer}');
select permissions.permit('doc editors edit', '{update}', 'document', roles => '{editor}');
select permissions.grant_role('user', :'bob', 'editor', 'document', :'acme_readme');

select permissions.permit('announcement is public', '{select}', 'document', resource_id => :'announcement');

create table public.documents (id uuid primary key, title text not null);
insert into public.documents values
    (:'acme_readme',  'readme'),
    (:'acme_plan',    'plan'),
    (:'announcement', 'announcement');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
select permissions.apply_rls('public.documents', 'select', 'document');

select tap.plan(7);

select tap.is(permissions.can_for('user', :'frank', 'select', 'document', :'announcement'), true,  'Frank (no data) can view the announcement');
select tap.is(permissions.can_for('user', :'frank', 'update', 'document', :'announcement'), false, 'but cannot edit it');
select tap.ok(:'announcement' = any (permissions.ids_for('user', :'frank', 'select', 'document')), 'the announcement is in Frank''s viewable objects');

set role authenticated;
select set_config('permissions.subject_id', :'frank', false);
select tap.set_eq(array(select title from public.documents), '{announcement}', 'RLS as Frank returns only the announcement');
select set_config('permissions.subject_id', '', false);
select tap.is(permissions.can('select', 'document', :'announcement'), false, 'a null subject is denied');
reset role;

select permissions.drop_policy('announcement is public');
select tap.is(permissions.can_for('user', :'frank', 'select', 'document', :'announcement'), false, 'after revoking public access Frank cannot view it');

set role authenticated;
select set_config('permissions.subject_id', :'frank', false);
select tap.set_eq(array(select title from public.documents), '{}', 'RLS as Frank returns nothing');
reset role;

select * from tap.finish();
