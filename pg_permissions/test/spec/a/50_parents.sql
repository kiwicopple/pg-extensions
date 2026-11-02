-- Goal: parent inheritance org -> folder -> document, one fast-path RLS branch, cycles terminate (research/plan.md §10 G10)
-- PROVISIONAL: uses Design A's zanzibar-level API. Parents are OpenFGA-style
-- tuple-to-userset rules: a `parent` tuple links a child to its parent, and
-- `from_parent` on a relation names the relation it inherits from the parent.
-- The document -> folder link is kept in sync with documents.folder_id by the
-- permissions.sync_parent() trigger; folder -> org links use set_parent().
\ir ../../fixtures/ids.sql
\set roadmap    '00000000-0000-0000-0003-000000000004'
\set globex_doc '00000000-0000-0000-0003-000000000007'
\set specs      '00000000-0000-0000-0005-000000000001'
\set plans      '00000000-0000-0000-0005-000000000002'

select permissions.define_type('user');
select permissions.define_type('org');
select permissions.define_type('folder');
select permissions.define_type('document');

select permissions.define_relation('org', 'admin');
select permissions.define_relation('org', 'member', '{admin}');
select permissions.define_relation('org', 'editor', '{admin}');
select permissions.define_relation('org', 'viewer', '{member,editor}');
select permissions.define_relation('folder', 'parent');
select permissions.define_relation('folder', 'editor', from_parent => '{editor}');
select permissions.define_relation('folder', 'viewer', '{editor}', from_parent => '{viewer}');
select permissions.define_relation('document', 'parent');
select permissions.define_relation('document', 'editor', from_parent => '{editor}');
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}');

select permissions.set_parent('folder', :'specs', 'org', :'acme');
select permissions.set_parent('folder', :'plans', 'org', :'acme');

create table public.documents (id uuid primary key, org_id uuid not null, folder_id uuid, title text not null);
create trigger documents_parent after insert or update of folder_id or delete on public.documents
    for each row execute function permissions.sync_parent('document', 'folder', 'folder_id');
insert into public.documents values
    (:'acme_readme', :'acme',   :'specs', 'readme'),
    (:'roadmap',     :'acme',   :'plans', 'roadmap'),
    (:'globex_doc',  :'globex', null,     'globex doc');
-- a document outside any folder hangs off its org directly
select permissions.set_parent('document', :'globex_doc', 'org', :'globex');

alter table public.documents enable row level security;
grant select on public.documents to authenticated;
-- one fast-path branch: org and folder access arrive through the parent links
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);

select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'user', :'carol');
select permissions.grant('folder', :'specs', 'viewer', 'user', :'erin');

select tap.plan(13);

select tap.is(permissions.check_for('user', :'alice', 'document', :'acme_readme', 'editor'), true,  'Alice (org admin) can edit readme');
select tap.is(permissions.check_for('user', :'alice', 'document', :'roadmap',     'editor'), true,  'Alice (org admin) can edit roadmap');
select tap.is(permissions.check_for('user', :'carol', 'document', :'acme_readme', 'viewer'), true,  'Carol (org member) can view readme');
select tap.is(permissions.check_for('user', :'carol', 'document', :'acme_readme', 'editor'), false, 'Carol (org member) cannot edit readme');
select tap.is(permissions.check_for('user', :'erin',  'document', :'acme_readme', 'viewer'), true,  'Erin (viewer of folder specs) can view readme');
select tap.is(permissions.check_for('user', :'erin',  'document', :'roadmap',     'viewer'), false, 'Erin cannot view roadmap (other folder)');

select tap.set_eq(
    array(select subject_id from permissions.list_subjects('document', :'acme_readme', 'viewer') where subject_type = 'user'),
    array[:'alice', :'carol', :'erin'],
    'subjects who can view readme: exactly Alice, Carol and Erin');

set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{readme,roadmap}', 'RLS as Carol returns readme and roadmap');
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'RLS as Erin returns readme only');
reset role;

-- removing the folder grant
select permissions.revoke('folder', :'specs', 'viewer', 'user', :'erin');
select tap.is(permissions.check_for('user', :'erin', 'document', :'acme_readme', 'viewer'), false, 'after revoking Erin''s folder grant, Erin cannot view readme');

-- moving the document changes who inherits (the trigger rewrites the parent tuple)
select permissions.grant('folder', :'specs', 'viewer', 'user', :'erin');
update public.documents set folder_id = :'plans' where id = :'acme_readme';
select tap.is(permissions.check_for('user', :'erin', 'document', :'acme_readme', 'viewer'), false, 'after moving readme to plans, Erin cannot view readme');
update public.documents set folder_id = :'specs' where id = :'acme_readme';
select tap.is(permissions.check_for('user', :'erin', 'document', :'acme_readme', 'viewer'), true, 'after moving readme back to specs, Erin can view it');

-- parent cycles terminate
select permissions.grant('folder', :'specs', 'parent', 'folder', :'plans');
select permissions.grant('folder', :'plans', 'parent', 'folder', :'specs');
set statement_timeout = '5s';
-- A walks forwards from the subject, so a non-grantee never enters the cycle.
-- Walk into it forwards (Erin views specs) and backwards (who can view readme)
-- first: if either didn't terminate it would hit the timeout and fail the file.
select cardinality(permissions.list_objects_for('user', :'erin', 'document', 'viewer')) as erin_docs,
       (select count(*) from permissions.list_subjects('document', :'acme_readme', 'viewer')) as readme_viewers \gset
select tap.is(permissions.check_for('user', :'dave', 'document', :'acme_readme', 'viewer'), false, 'a parent cycle (specs <-> plans) terminates and a non-grantee still gets false');
reset statement_timeout;

select * from tap.finish();
