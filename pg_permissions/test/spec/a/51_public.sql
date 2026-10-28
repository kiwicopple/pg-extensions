-- Goal: public access with a `user:*` wildcard subject; a null subject is denied (PLAN.md §10 G11)
-- PROVISIONAL: uses Design A's zanzibar-level API. A tuple whose subject is
-- `user:*` is reached by every non-null `user` subject.
\ir ../../fixtures/ids.sql
\set frank        '00000000-0000-0000-0001-000000000006'
\set announcement '00000000-0000-0000-0003-000000000005'

select permissions.define_type('user');
select permissions.define_type('document');
select permissions.define_relation('document', 'editor');
select permissions.define_relation('document', 'viewer', '{editor}');

create table public.documents (id uuid primary key, title text not null);
insert into public.documents values
    (:'announcement', 'announcement'),
    (:'acme_readme',  'readme');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);

select permissions.grant('document', :'acme_readme', 'editor', 'user', :'bob');
select permissions.grant('document', :'announcement', 'viewer', 'user', '*');

select tap.plan(7);

-- Frank has no tuples of his own
select tap.is(permissions.check_for('user', :'frank', 'document', :'announcement', 'viewer'), true,  'Frank (no data) can view the announcement');
select tap.is(permissions.check_for('user', :'frank', 'document', :'announcement', 'editor'), false, 'Frank cannot edit the announcement');
select tap.set_eq(permissions.list_objects_for('user', :'frank', 'document', 'viewer'), array[:'announcement'], 'the announcement is in Frank''s viewable objects');

set role authenticated;
select set_config('permissions.subject_id', :'frank', false);
select tap.set_eq(array(select title from public.documents), '{announcement}', 'RLS as Frank returns only the announcement');
select set_config('permissions.subject_id', '', false);
select tap.is(permissions.check('document', :'announcement', 'viewer'), false, 'a null subject is denied');
reset role;

select permissions.revoke('document', :'announcement', 'viewer', 'user', '*');
select tap.is(permissions.check_for('user', :'frank', 'document', :'announcement', 'viewer'), false, 'after revoking the public grant, Frank cannot view the announcement');

set role authenticated;
select set_config('permissions.subject_id', :'frank', false);
select tap.is((select count(*)::int from public.documents), 0, 'RLS as Frank returns nothing');
reset role;

select * from tap.finish();
