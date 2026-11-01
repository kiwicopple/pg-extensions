-- Goal: a forbid beats every grant, including parent-derived ones (research/plan.md §10 G12)
-- PROVISIONAL: uses Design A's zanzibar-level API. Forbid is an OpenFGA-style
-- exclusion: `unless => '{blocked}'` on a relation means a subject with a direct
-- `blocked` tuple on the object never reaches that relation there, whatever the path.
\ir ../../fixtures/ids.sql
\set roadmap '00000000-0000-0000-0003-000000000004'
\set specs   '00000000-0000-0000-0005-000000000001'
\set plans   '00000000-0000-0000-0005-000000000002'

select permissions.define_type('user');
select permissions.define_type('team');
select permissions.define_type('org');
select permissions.define_type('folder');
select permissions.define_type('document');

select permissions.define_relation('team', 'member');
select permissions.define_relation('org', 'admin');
select permissions.define_relation('org', 'member', '{admin}');
select permissions.define_relation('org', 'editor', '{admin}');
select permissions.define_relation('org', 'viewer', '{member,editor}');
select permissions.define_relation('folder', 'parent');
select permissions.define_relation('folder', 'editor', from_parent => '{editor}');
select permissions.define_relation('folder', 'viewer', '{editor}', from_parent => '{viewer}');
select permissions.define_relation('document', 'parent');
select permissions.define_relation('document', 'blocked');
select permissions.define_relation('document', 'editor', from_parent => '{editor}', unless => '{blocked}');
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}', unless => '{blocked}');

select permissions.set_parent('folder', :'specs', 'org', :'acme');
select permissions.set_parent('folder', :'plans', 'org', :'acme');
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');
select permissions.set_parent('document', :'roadmap', 'folder', :'plans');

-- reference scenario (research/plan.md §5)
select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'dave');
select permissions.grant('document', :'acme_readme', 'editor', 'user', :'bob');
select permissions.grant('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');

create table public.documents (id uuid primary key, org_id uuid not null, folder_id uuid, title text not null);
insert into public.documents values
    (:'acme_readme', :'acme', :'specs', 'readme'),
    (:'roadmap',     :'acme', :'plans', 'roadmap');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);

select tap.plan(9);

select tap.is(permissions.check_for('user', :'dave', 'document', :'acme_readme', 'viewer'), true, 'before the forbid, Dave can view readme (team eng)');

select permissions.grant('document', :'acme_readme', 'blocked', 'user', :'dave');
select tap.is(permissions.check_for('user', :'dave', 'document', :'acme_readme', 'viewer'), false, 'after the forbid, Dave cannot view readme');
select tap.ok(not (:'acme_readme' = any (permissions.list_objects_for('user', :'dave', 'document', 'viewer'))), 'readme is not in Dave''s list of viewable documents');
select tap.ok(
    (select not (:'dave' = any (s)) and :'carol' = any (s)
     from (select array(select subject_id from permissions.list_subjects('document', :'acme_readme', 'viewer') where subject_type = 'user') s) x),
    'Dave is not in readme''s subject list, Carol still is');

set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.ok(not exists (select 1 from public.documents where title = 'readme'), 'RLS as Dave excludes readme');
reset role;

-- a forbid beats parent-derived (org admin) access
select permissions.grant('document', :'acme_readme', 'blocked', 'user', :'alice');
select tap.is(
    permissions.check_for('user', :'alice', 'document', :'acme_readme', 'editor')
    or permissions.check_for('user', :'alice', 'document', :'acme_readme', 'viewer'),
    false, 'a forbid on Alice for readme: Alice can neither edit nor view readme');
select tap.is(permissions.check_for('user', :'alice', 'document', :'roadmap', 'editor'), true, 'Alice can still edit roadmap (forbids are per object)');

select permissions.revoke('document', :'acme_readme', 'blocked', 'user', :'dave');
select tap.is(permissions.check_for('user', :'dave', 'document', :'acme_readme', 'viewer'), true, 'removing Dave''s forbid restores his access');

set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.throws_ok(format($$ select permissions.grant('document', %L, 'blocked', 'user', %L) $$, :'acme_readme', :'carol'), '42501', 'clients cannot create forbids');
reset role;

select * from tap.finish();
