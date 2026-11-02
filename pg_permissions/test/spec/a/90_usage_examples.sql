-- Goal: every example in research/prototypes/a-tuple-core.md runs and gives the answer the page states.
-- This file mirrors research/prototypes/a-tuple-core.md, section by section and in the same order, so the
-- two stay in step: when you change an example on the page, change it here (and the other way
-- round). Sections share one database, as the page does, and each how-to leaves the data the
-- way it found it unless the page says otherwise.
-- Design A's native API. The `rbac` preset functions are covered by the shared specs; this file
-- only uses them in the graduation how-to.
\ir ../../fixtures/ids.sql
\set frank        '00000000-0000-0000-0001-000000000006'
\set gina         '00000000-0000-0000-0001-000000000007'
\set announcement '00000000-0000-0000-0003-000000000005'
\set draft_doc    '00000000-0000-0000-0003-000000000006'
\set specs        '00000000-0000-0000-0005-000000000001'
\set plans        '00000000-0000-0000-0005-000000000002'
\set note_acme    '00000000-0000-0000-0006-000000000001'
\set note_globex  '00000000-0000-0000-0006-000000000002'

select tap.plan(141);

-- ============================================================================
-- 2. Quick start (research/plan.md §5)
-- ============================================================================

select permissions.define_type('user');
select permissions.define_type('team');
select permissions.define_type('org');
select permissions.define_type('document');

select permissions.define_relation('team', 'member');

select permissions.define_relation('org', 'owner');
select permissions.define_relation('org', 'admin',          '{owner}');
select permissions.define_relation('org', 'member',         '{admin}');
select permissions.define_relation('org', 'edit_documents', '{admin}');
select permissions.define_relation('org', 'view_documents', '{member}');

select permissions.define_relation('document', 'editor');
select permissions.define_relation('document', 'viewer', '{editor}');

select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'user', :'carol');

select permissions.grant('team', :'eng', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'dave');

select permissions.grant('document', :'acme_readme', 'editor', 'user', :'bob');
select permissions.grant('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');

create table public.documents (
    id     uuid primary key,
    org_id uuid not null,
    title  text not null
);
insert into public.documents (id, org_id, title) values
    (:'acme_plan',    :'acme',   'plan'),
    (:'acme_readme',  :'acme',   'readme'),
    (:'globex_notes', :'globex', 'globex notes');

alter table public.documents enable row level security;
grant select, update on public.documents to authenticated;

create policy documents_select on public.documents for select to authenticated using (
    org_id = any (array(select unnest(permissions.list_objects('org', 'view_documents'))::uuid))
    or id  = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);

create policy documents_update on public.documents for update to authenticated using (
    permissions.check('org', org_id::text, 'edit_documents')
    or permissions.check('document', id::text, 'editor')
);

-- Can Bob update readme?
select tap.is(permissions.check_for('user', :'bob', 'document', :'acme_readme', 'editor'), true,
    'qs: Bob is an editor of readme');
select tap.is(permissions.check_for('user', :'bob', 'document', :'acme_plan', 'editor'), false,
    'qs: Bob is not an editor of the plan');
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
with u as (update public.documents set title = 'readme' where id = :'acme_readme' returning 1)
select count(*) as bob_readme from u \gset
with u as (update public.documents set title = 'plan' where id = :'acme_plan' returning 1)
select count(*) as bob_plan from u \gset
rollback;
select tap.is(:bob_readme, 1, 'qs: RLS lets Bob update readme');
select tap.is(:bob_plan, 0, 'qs: RLS does not let Bob update the plan');

-- Which documents can Dave see?
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'dave', true);
select array(select title from public.documents)::text as dave_titles \gset
rollback;
select tap.is(:'dave_titles'::text, '{readme}', 'qs: RLS as Dave returns readme only');
select tap.set_eq(permissions.list_objects_for('user', :'dave', 'document', 'viewer'), array[:'acme_readme'],
    'qs: list_objects_for Dave is readme');

-- Who can view readme?
select tap.set_eq(
    array(select subject_id from permissions.list_subjects('document', :'acme_readme', 'viewer')),
    array[:'bob', :'carol', :'dave'],
    'qs: viewers of readme are Bob, Carol and Dave, not Alice');

-- the org path is in the RLS policy, so Alice does see it
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.set_eq(array(select title from public.documents), '{plan,readme}', 'qs: RLS as Alice returns the acme documents');
with u as (update public.documents set title = title returning 1)
select tap.is((select count(*)::int from u), 2, 'qs: Alice can update both acme documents');
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{plan,readme}', 'qs: RLS as Carol returns the acme documents');
with u as (update public.documents set title = title returning 1)
select tap.is((select count(*)::int from u), 0, 'qs: Carol can update nothing');
select set_config('permissions.subject_id', :'erin', false);
select tap.is((select count(*)::int from public.documents), 0, 'qs: Erin, with no tuples, sees nothing');
reset role;

-- ============================================================================
-- 3.1 Per-object sharing
-- ============================================================================

select permissions.grant('document', :'globex_notes', 'editor', 'user', :'erin');

set role authenticated;
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents), '{globex notes}', 'share: Erin sees the document shared with her');
with u as (update public.documents set title = title returning 1)
select tap.is((select count(*)::int from u), 1, 'share: an editor can update it');
reset role;

select tap.is(permissions.revoke('document', :'globex_notes', 'editor', 'user', :'erin'), true, 'share: revoke returns true when it removed a tuple');
select tap.is(permissions.revoke('document', :'globex_notes', 'editor', 'user', :'erin'), false, 'share: and false when there was nothing to remove');
set role authenticated;
select set_config('permissions.subject_id', :'erin', false);
select tap.is((select count(*)::int from public.documents), 0, 'share: after the revoke Erin sees nothing');
reset role;

-- share with a team
select permissions.grant('document', :'acme_plan', 'viewer', 'team', :'eng', 'member');
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.documents), '{plan,readme}', 'share: team members see the shared document');
reset role;
select tap.is(permissions.revoke('document', :'acme_plan', 'viewer', 'team', :'eng'), false,
    'share: revoking a userset grant without its subject_relation removes nothing');
select tap.is(permissions.revoke('document', :'acme_plan', 'viewer', 'team', :'eng', 'member'), true,
    'share: revoking with the subject_relation does');

-- ============================================================================
-- 3.2 Groups and nested teams
-- ============================================================================

select permissions.grant('team', :'platform', 'member', 'team', :'eng', 'member');
select permissions.grant('document', :'acme_plan', 'viewer', 'team', :'platform', 'member');

select tap.is(permissions.check_for('user', :'dave', 'team', :'platform', 'member'), true,
    'groups: members of a nested team are members of the parent team');
select tap.is(permissions.check_for('user', :'dave', 'document', :'acme_plan', 'viewer'), true,
    'groups: access granted to the parent team reaches nested members');
select tap.is(permissions.check_for('user', :'erin', 'document', :'acme_plan', 'viewer'), false,
    'groups: and nobody outside the teams');
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.documents), '{plan,readme}', 'groups: RLS as Dave includes the plan');
reset role;

-- cycles terminate
select permissions.grant('team', :'eng', 'member', 'team', :'platform', 'member');
select tap.is(permissions.check_for('user', :'dave', 'document', :'acme_plan', 'viewer'), true,
    'groups: a membership cycle terminates and still answers');
select tap.is(permissions.check_for('user', :'erin', 'document', :'acme_plan', 'viewer'), false,
    'groups: a cycle does not grant access to outsiders');
select tap.is(
    (select count(*)::int from permissions.list_subjects('document', :'acme_plan', 'viewer')), 2,
    'groups: list_subjects walks a cycle too (Carol and Dave)');
select permissions.revoke('team', :'eng', 'member', 'team', :'platform', 'member');

-- leaving the nested team removes access
select permissions.revoke('team', :'platform', 'member', 'team', :'eng', 'member');
select tap.is(permissions.check_for('user', :'dave', 'document', :'acme_plan', 'viewer'), false,
    'groups: un-nesting a team removes the access it carried');
select permissions.revoke('document', :'acme_plan', 'viewer', 'team', :'platform', 'member');

-- ============================================================================
-- 3.3 Expiry
-- ============================================================================

select permissions.grant('document', :'acme_readme', 'viewer', 'user', :'frank',
                         p_expires_at => now() + interval '1 hour');
set role authenticated;
select set_config('permissions.subject_id', :'frank', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'expiry: an unexpired grant gives access');
reset role;

-- re-granting changes the expiry
select permissions.grant('document', :'acme_readme', 'viewer', 'user', :'frank',
                         p_expires_at => now() - interval '1 minute');
select tap.is(permissions.check_for('user', :'frank', 'document', :'acme_readme', 'viewer'), false,
    'expiry: an expired grant gives nothing');
select tap.is((select count(*)::int from permissions.tuples where object_id = :'acme_readme' and subject_id = :'frank'), 1,
    'expiry: the expired tuple is still stored');

-- grant is an upsert: without p_expires_at it makes the tuple permanent
select permissions.grant('document', :'acme_readme', 'viewer', 'user', :'frank');
select tap.is(
    (select expires_at is null from permissions.tuples where object_id = :'acme_readme' and subject_id = :'frank'),
    true, 'expiry: granting again without an expiry clears it');
select tap.is(permissions.check_for('user', :'frank', 'document', :'acme_readme', 'viewer'), true,
    'expiry: and the access is back');
select permissions.revoke('document', :'acme_readme', 'viewer', 'user', :'frank');

-- expiry works on every tuple, so memberships expire too
select permissions.grant('team', :'eng', 'member', 'user', :'gina', p_expires_at => now() - interval '1 day');
select tap.is(permissions.check_for('user', :'gina', 'document', :'acme_readme', 'viewer'), false,
    'expiry: an expired team membership carries nothing');

-- purge expired rows (admin)
with d as (delete from permissions.tuples where expires_at <= now() returning 1)
select tap.is((select count(*)::int from d), 1, 'expiry: purging expired tuples removes the stale membership');

-- ============================================================================
-- 3.4 Parent inheritance
-- ============================================================================

select permissions.define_type('folder');
select permissions.define_relation('folder', 'parent');
select permissions.define_relation('folder', 'editor', from_parent => '{edit_documents}');
select permissions.define_relation('folder', 'viewer', '{editor}', from_parent => '{view_documents}');

create table public.folders (
    id     uuid primary key,
    org_id uuid not null,
    name   text not null
);
create trigger folders_parent after insert or update of org_id or delete on public.folders
    for each row execute function permissions.sync_parent('folder', 'org', 'org_id');
insert into public.folders (id, org_id, name) values
    (:'specs', :'acme', 'specs'),
    (:'plans', :'acme', 'plans');

alter table public.documents add column folder_id uuid;
update public.documents set folder_id = :'specs' where id = :'acme_readme';
update public.documents set folder_id = :'plans' where id = :'acme_plan';

select tap.is(
    (select count(*)::int from permissions.tuples where object_type = 'folder' and relation = 'parent'), 2,
    'parents: the folders trigger wrote one parent tuple per folder');

select permissions.grant('folder', :'specs', 'viewer', 'user', :'erin');

-- two-arm projection policy
drop policy documents_select on public.documents;
drop policy documents_update on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    id           = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
    or folder_id = any (array(select unnest(permissions.list_objects('folder',   'viewer'))::uuid))
);
create policy documents_update on public.documents for update to authenticated using (
    permissions.check('document', id::text, 'editor')
    or permissions.check('folder', folder_id::text, 'editor')
);
-- clients may rename a document, but not move it
revoke update on public.documents from authenticated;
grant update (title) on public.documents to authenticated;

set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{plan,readme}', 'parents/two-arm: Carol (org member) sees the folders'' documents');
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'parents/two-arm: Erin (viewer of specs) sees readme only');
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'parents/two-arm: Dave still sees readme through team eng');
select set_config('permissions.subject_id', :'alice', false);
with u as (update public.documents set title = title returning 1)
select tap.is((select count(*)::int from u), 2, 'parents/two-arm: Alice (org admin) can update both');
select tap.throws_ok($$ update public.documents set folder_id = null $$, '42501', 'parents/two-arm: clients cannot change folder_id');
select set_config('permissions.subject_id', :'bob', false);
with u as (update public.documents set title = title returning 1)
select tap.is((select count(*)::int from u), 1, 'parents/two-arm: Bob can update only the document shared with him');
reset role;

-- single-branch policy: link every document to its folder
select permissions.define_relation('document', 'parent');
select permissions.define_relation('document', 'editor', from_parent => '{editor}');
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}');

create trigger documents_parent after insert or update of folder_id or delete on public.documents
    for each row execute function permissions.sync_parent('document', 'folder', 'folder_id');

-- the trigger only acts when folder_id changes, so backfill existing rows with set_parent
update public.documents set folder_id = folder_id;
select tap.is(
    (select count(*)::int from permissions.tuples where object_type = 'document' and relation = 'parent'), 0,
    'parents/single: an update that does not change folder_id writes nothing');
select permissions.set_parent('document', id::text, 'folder', folder_id::text)
from public.documents where folder_id is not null;
select tap.is(
    (select count(*)::int from permissions.tuples where object_type = 'document' and relation = 'parent'), 2,
    'parents/single: backfill wrote one parent tuple per linked document');

drop policy documents_select on public.documents;
drop policy documents_update on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);
create policy documents_update on public.documents for update to authenticated using (
    permissions.check('document', id::text, 'editor')
);

set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{plan,readme}', 'parents/single: Carol sees the same documents');
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'parents/single: Erin sees the same documents');
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'parents/single: Dave sees the same documents');
select set_config('permissions.subject_id', :'alice', false);
with u as (update public.documents set title = title returning 1)
select tap.is((select count(*)::int from u), 2, 'parents/single: Alice can update both');
select set_config('permissions.subject_id', :'bob', false);
with u as (update public.documents set title = title returning 1)
select tap.is((select count(*)::int from u), 1, 'parents/single: Bob can update readme only');
reset role;

-- the org path is now in the model, so list_subjects includes the org members
select tap.set_eq(
    array(select subject_id from permissions.list_subjects('document', :'acme_readme', 'viewer')),
    array[:'alice', :'bob', :'carol', :'dave', :'erin'],
    'parents/single: list_subjects includes the org admin and members and the folder viewer');
select tap.is(permissions.check_for('user', :'alice', 'document', :'acme_readme', 'editor'), true,
    'parents/single: check_for sees the org admin through folder and org');

-- moving a document changes who inherits (the trigger rewrites the parent tuple)
update public.documents set folder_id = :'plans' where id = :'acme_readme';
select tap.is(permissions.check_for('user', :'erin', 'document', :'acme_readme', 'viewer'), false,
    'parents/single: after moving readme to plans, the specs viewer cannot see it');
update public.documents set folder_id = :'specs' where id = :'acme_readme';
select tap.is(permissions.check_for('user', :'erin', 'document', :'acme_readme', 'viewer'), true,
    'parents/single: after moving it back, she can');

-- set_parent with a null parent clears the link
select permissions.set_parent('document', :'acme_readme', null, null);
select tap.is(permissions.check_for('user', :'erin', 'document', :'acme_readme', 'viewer'), false,
    'parents/single: set_parent(..., null, null) clears the parent');
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');
select tap.is(permissions.check_for('user', :'erin', 'document', :'acme_readme', 'viewer'), true,
    'parents/single: set_parent replaces it');

-- ============================================================================
-- 3.5 Public access
-- ============================================================================

insert into public.documents (id, org_id, title) values (:'announcement', :'acme', 'announcement');
select permissions.grant('document', :'announcement', 'viewer', 'user', '*');

select tap.is(permissions.check_for('user', :'frank', 'document', :'announcement', 'viewer'), true,
    'public: any user, even one with no tuples, can view');
select tap.is(permissions.check_for('user', :'frank', 'document', :'announcement', 'editor'), false,
    'public: but not edit');
set role authenticated;
select set_config('permissions.subject_id', :'frank', false);
select tap.set_eq(array(select title from public.documents), '{announcement}', 'public: RLS as Frank returns the announcement only');
select set_config('permissions.subject_id', '', false);
select tap.is((select count(*)::int from public.documents), 0, 'public: with no subject, nothing is visible');
select tap.is(permissions.check('document', :'announcement', 'viewer'), false, 'public: and check() is false for a null subject');
reset role;
select tap.is(
    (select count(*)::int from permissions.list_subjects('document', :'announcement', 'viewer') where subject_id = '*'), 1,
    'public: list_subjects reports the wildcard as (user, *)');
select permissions.revoke('document', :'announcement', 'viewer', 'user', '*');
select tap.is(permissions.check_for('user', :'frank', 'document', :'announcement', 'viewer'), false,
    'public: after revoking, nobody has it');

-- ============================================================================
-- 3.6 Forbid (unless)
-- ============================================================================

select permissions.define_relation('document', 'blocked');
select permissions.define_relation('document', 'editor', from_parent => '{editor}', unless => '{blocked}');
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}', unless => '{blocked}');

select permissions.grant('document', :'acme_readme', 'blocked', 'user', :'dave');

select tap.is(permissions.check_for('user', :'dave', 'document', :'acme_readme', 'viewer'), false,
    'forbid: Dave is blocked from readme');
select tap.ok(not (:'acme_readme' = any (permissions.list_objects_for('user', :'dave', 'document', 'viewer'))),
    'forbid: readme leaves his list of documents');
select tap.ok(
    (select not (:'dave' = any (s)) and :'carol' = any (s)
     from (select array(select subject_id from permissions.list_subjects('document', :'acme_readme', 'viewer')) s) x),
    'forbid: Dave leaves readme''s subject list, Carol stays');
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.is((select count(*)::int from public.documents), 0, 'forbid: RLS as Dave returns nothing');
reset role;

-- a forbid beats parent-derived access
select permissions.grant('document', :'acme_readme', 'blocked', 'user', :'alice');
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.set_eq(array(select title from public.documents), '{plan}', 'forbid: blocked on readme, the org admin still sees the plan only');
with u as (update public.documents set title = title returning 1)
select tap.is((select count(*)::int from u), 1, 'forbid: and can update only that one');
reset role;

-- limits
select tap.throws_ok(
    format($$ select permissions.grant('document', %L, 'blocked', 'team', %L, 'member') $$, :'acme_readme', :'eng'),
    '22023', 'forbid: a group cannot be blocked');
select tap.throws_ok(
    format($$ select permissions.grant('document', %L, 'blocked', 'user', '*') $$, :'acme_readme'),
    '22023', 'forbid: neither can the wildcard');
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.throws_ok(
    format($$ select permissions.grant('document', %L, 'blocked', 'user', %L) $$, :'acme_readme', :'carol'),
    '42501', 'forbid: clients cannot write forbids');
reset role;

-- a forbid on a folder hides what is inherited through it, but not a direct grant on a document below it
select permissions.define_type('vault');
select permissions.define_type('file');
select permissions.define_relation('vault', 'blocked');
select permissions.define_relation('vault', 'viewer', unless => '{blocked}');
select permissions.define_relation('file', 'parent');
select permissions.define_relation('file', 'viewer', from_parent => '{viewer}');
select permissions.set_parent('file', 'f1', 'vault', 'v1');
select permissions.grant('vault', 'v1', 'viewer', 'user', :'erin');
select permissions.grant('vault', 'v1', 'viewer', 'user', :'gina');
select permissions.grant('file', 'f1', 'viewer', 'user', :'gina');
select permissions.grant('vault', 'v1', 'blocked', 'user', :'erin');
select permissions.grant('vault', 'v1', 'blocked', 'user', :'gina');
select tap.is(permissions.check_for('user', :'erin', 'file', 'f1', 'viewer'), false,
    'forbid: a forbid on the folder hides what is inherited through it');
select tap.is(permissions.check_for('user', :'gina', 'file', 'f1', 'viewer'), true,
    'forbid: but a direct grant on the document below it still applies');

-- a userset forbid written before the unless list exists is accepted, then ignored
select permissions.define_relation('file', 'barred');
select permissions.grant('team', :'platform', 'member', 'user', :'frank');
select permissions.grant('file', 'f2', 'viewer', 'user', :'frank');
select permissions.grant('file', 'f2', 'barred', 'team', :'platform', 'member');
select permissions.define_relation('file', 'viewer', from_parent => '{viewer}', unless => '{barred}');
select tap.is(permissions.check_for('user', :'frank', 'file', 'f2', 'viewer'), true,
    'forbid: a userset forbid written before the unless list is ignored');
select permissions.revoke('team', :'platform', 'member', 'user', :'frank');

-- the two-arm policy does not look at the document node, so a document-level forbid does not hide it
drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    id           = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
    or folder_id = any (array(select unnest(permissions.list_objects('folder',   'viewer'))::uuid))
);
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.set_eq(array(select title from public.documents), '{plan,readme}',
    'forbid: with the two-arm policy a document-level forbid does not hide the document');
reset role;
drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);

select tap.is(permissions.revoke('document', :'acme_readme', 'blocked', 'user', :'alice'), true, 'forbid: revoke lifts it');
select permissions.revoke('document', :'acme_readme', 'blocked', 'user', :'dave');
select tap.is(permissions.check_for('user', :'dave', 'document', :'acme_readme', 'viewer'), true, 'forbid: Dave''s access is back');
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.set_eq(array(select title from public.documents), '{plan,readme}', 'forbid: and so is Alice''s');
reset role;

-- ============================================================================
-- 3.7 Conditions through RLS composition
-- ============================================================================

alter table public.documents
    add column status text not null default 'published' check (status in ('draft', 'published'));
insert into public.documents (id, org_id, folder_id, title, status)
values (:'draft_doc', :'acme', :'plans', 'draft doc', 'draft');

drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    (status = 'published' and id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid)))
    or id = any (array(select unnest(permissions.list_objects('document', 'editor'))::uuid))
);

set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{plan,readme}', 'conditions: a viewer (org member) sees published documents only');
select set_config('permissions.subject_id', :'alice', false);
select tap.set_eq(array(select title from public.documents), '{plan,readme,draft doc}', 'conditions: an editor (org admin) sees drafts too');
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'conditions: other users are unaffected');
reset role;
select tap.is(permissions.check_for('user', :'carol', 'document', :'draft_doc', 'viewer'), true,
    'conditions: the engine does not know about status, so check_for says true for the draft');
select tap.ok(:'carol' = any (array(select subject_id from permissions.list_subjects('document', :'draft_doc', 'viewer'))),
    'conditions: and list_subjects over-reports it');

update public.documents set status = 'published' where id = :'draft_doc';
set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.is((select count(*)::int from public.documents where id = :'draft_doc'), 1, 'conditions: once it is published, Carol sees it');
reset role;
update public.documents set status = 'draft' where id = :'draft_doc';

-- ============================================================================
-- 3.8 Graduating from the rbac preset
-- ============================================================================

select permissions.create_role('viewer', '{documents.read}');
select permissions.create_role('editor', '{documents.edit}', '{viewer}');
select permissions.create_role('admin',  '{documents.delete,users.manage}', '{editor}');

create table public.notes (
    id     uuid primary key,
    org_id uuid not null,
    title  text not null
);
insert into public.notes (id, org_id, title) values
    (:'note_acme',   :'acme',   'acme note'),
    (:'note_globex', :'globex', 'globex note');
alter table public.notes enable row level security;
grant select on public.notes to authenticated;

select permissions.assign_role(:'bob', 'editor', :'acme');

create policy notes_select on public.notes for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
);

select permissions.user_permissions(:'bob', :'acme') as bob_before \gset
set role authenticated;
select set_config('permissions.subject_id', :'bob', false);
select tap.set_eq(array(select title from public.notes), '{acme note}', 'graduate: before sharing, Bob sees his org''s notes');
select set_config('permissions.subject_id', :'dave', false);
select tap.is((select count(*)::int from public.notes), 0, 'graduate: and Dave sees none');
reset role;

-- graduate: share one note with Dave, who is in no org
select permissions.define_type('note');
select permissions.define_relation('note', 'editor');
select permissions.define_relation('note', 'viewer', '{editor}');
select permissions.grant('note', :'note_globex', 'viewer', 'user', :'dave');

drop policy notes_select on public.notes;
create policy notes_select on public.notes for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
    or id  = any (array(select unnest(permissions.list_objects('note', 'viewer'))::uuid))
);

set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.notes), '{globex note}', 'graduate: Dave sees only the shared note');
select tap.is(permissions.has_permission('documents.read', :'globex'), false, 'graduate: sharing does not make Dave a member of the org');
select set_config('permissions.subject_id', :'bob', false);
select tap.set_eq(array(select title from public.notes), '{acme note}', 'graduate: Bob''s access is unchanged');
reset role;
select tap.is(permissions.user_permissions(:'bob', :'acme')::text, :'bob_before', 'graduate: the rbac answers are unchanged');

-- or let the scoped roles reach the org's notes through the model
select permissions.define_relation('note', 'parent');
select permissions.define_relation('note', 'viewer', '{editor}', from_parent => '{documents.read}');
select permissions.set_parent('note', :'note_acme', 'tenant', :'acme');
select tap.is(permissions.check_for('user', :'bob', 'note', :'note_acme', 'viewer'), true,
    'graduate: with from_parent => documents.read, an org editor reaches the org''s notes through the model');
select tap.is(permissions.check_for('user', :'dave', 'note', :'note_acme', 'viewer'), false,
    'graduate: and Dave, who holds no role, does not');

-- ============================================================================
-- 3.9 Listing and debugging
-- ============================================================================

set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(permissions.list_objects('document', 'viewer'), array[:'acme_readme'],
    'debug: list_objects, as the current subject');
select tap.throws_ok(
    format($$ select permissions.check_for('user', %L, 'document', %L, 'viewer') $$, :'carol', :'acme_readme'),
    '42501', 'debug: clients cannot call check_for');
select tap.throws_ok(
    format($$ select permissions.list_objects_for('user', %L, 'document', 'viewer') $$, :'carol'),
    '42501', 'debug: or list_objects_for');
select tap.throws_ok(
    format($$ select * from permissions.list_subjects('document', %L, 'viewer') $$, :'acme_readme'),
    '42501', 'debug: or list_subjects');
reset role;

select tap.set_eq(permissions.list_objects_for('user', :'dave', 'document', 'viewer'), array[:'acme_readme'],
    'debug: list_objects_for, as an admin');
select tap.is(permissions.check_for('user', :'dave', 'document', :'acme_readme', 'vewer'), false,
    'debug: a mistyped relation name is false, not an error');
select tap.set_eq(array(select distinct subject_type from permissions.list_subjects('document', :'acme_readme', 'viewer')), '{user}',
    'debug: list_subjects returns the people, not the teams they came through');
select tap.is(
    (select count(*)::int from permissions.tuples
     where object_type = 'document' and object_id = :'acme_readme'),
    3, 'debug: the tuples on readme are the editor grant, the team grant and the parent link');
select tap.is(
    (select count(*)::int from permissions.tuples
     where subject_type = 'user' and subject_id = :'dave'),
    2, 'debug: and Dave''s own tuples are his team membership and the note shared with him');

-- reproduce a user's RLS in one transaction
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'dave', true);
select array(select title from public.documents)::text as dave_titles \gset
rollback;
select tap.is(:'dave_titles'::text, '{readme}', 'debug: the begin / set local role / set_config recipe reproduces Dave''s view');

-- ============================================================================
-- 3.10 Cleaning up
-- ============================================================================

create table public.app_users (id uuid primary key);
insert into public.app_users values (:'dave'), (:'carol');

create function public.cleanup_permissions() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
    perform permissions.delete_subject(tg_argv[0], old.id::text);
    return old;
end $$;

create trigger app_users_cleanup after delete on public.app_users
    for each row execute function public.cleanup_permissions('user');
create trigger documents_cleanup after delete on public.documents
    for each row execute function public.cleanup_permissions('document');
create trigger folders_cleanup after delete on public.folders
    for each row execute function public.cleanup_permissions('folder');

-- a user
delete from public.app_users where id = :'dave';
select tap.is(
    (select count(*)::int from permissions.tuples where subject_type = 'user' and subject_id = :'dave'), 0,
    'cleanup: deleting the user removed their tuples');
select tap.set_eq(permissions.list_objects_for('user', :'dave', 'document', 'viewer'), '{}', 'cleanup: and their access');

-- a document
delete from public.documents where id = :'acme_readme';
select tap.is(
    (select count(*)::int from permissions.tuples
     where (object_type = 'document' and object_id = :'acme_readme')
        or (subject_type = 'document' and subject_id = :'acme_readme')), 0,
    'cleanup: deleting the document removed every tuple on it');

-- a folder: delete_object leaves the children's parent links, delete_subject takes them
select tap.is(permissions.delete_object('folder', :'plans'), 1::bigint, 'cleanup: delete_object removes the tuples on the folder (its parent link)');
select tap.is(
    (select count(*)::int from permissions.tuples where subject_type = 'folder' and subject_id = :'plans'), 2,
    'cleanup: the documents'' parent links to the folder are still there');
delete from public.folders where id = :'plans';
select tap.is(
    (select count(*)::int from permissions.tuples where subject_type = 'folder' and subject_id = :'plans'), 0,
    'cleanup: delete_subject, called from the folders trigger, removed them');
select tap.is(permissions.delete_subject('user', 'nobody'), 0::bigint, 'cleanup: delete_subject returns the number of tuples it removed');

-- ============================================================================
-- 4. API reference
-- ============================================================================

-- define_type
select permissions.define_type('widget', 'A widget');
select permissions.define_type('widget');
select tap.is((select description from permissions.object_types where name = 'widget'), 'A widget',
    'api: define_type is idempotent and keeps the description');

-- define_relation
select tap.throws_ok($$ select permissions.define_relation('gadget', 'viewer') $$, '23503',
    'api: define_relation for an undefined type raises 23503');
select permissions.define_relation('widget', 'viewer');
select permissions.define_relation('widget', 'editor', '{viewer}');
select permissions.define_relation('widget', 'editor', '{ghost}');
select tap.is((select implied_by from permissions.relations where object_type = 'widget' and relation = 'editor'), '{ghost}'::text[],
    'api: define_relation replaces the lists, and does not check the names in them');

-- grant
select tap.throws_ok($$ select permissions.grant('widget', 'w1', 'owner', 'user', 'u1') $$, '23503',
    'api: grant on an undefined relation raises 23503');
select tap.throws_ok($$ select permissions.grant('widget', 'w1', 'viewer', 'team', 't1', 'ghost') $$, '22023',
    'api: grant to an undefined userset raises 22023');
select tap.throws_ok($$ select permissions.grant('widget', 'w1', 'viewer', 'team', '*', 'member') $$, '22023',
    'api: a wildcard with a subject relation raises 22023');
select tap.lives_ok($$ select permissions.grant('widget', 'w1', 'viewer', 'ghost', 'g1') $$,
    'api: the subject type is not validated');

-- set_parent, and the sync_parent id column argument
select permissions.define_type('box');
select permissions.define_relation('widget', 'parent');
select permissions.set_parent('widget', 'w1', 'box', 'b1');
select permissions.set_parent('widget', 'w1', 'box', 'b2');
select tap.is(
    (select array_agg(subject_id) from permissions.tuples where object_type = 'widget' and object_id = 'w1' and relation = 'parent'),
    array['b2'], 'api: set_parent replaces the parent');
select tap.throws_ok($$ select permissions.set_parent('widget', 'w1', 'box', '*') $$, '22023',
    'api: a wildcard parent raises 22023');
select permissions.set_parent('widget', 'w1', null, null);
select tap.is((select count(*)::int from permissions.tuples where object_type = 'widget' and object_id = 'w1' and relation = 'parent'), 0,
    'api: set_parent with a null parent clears it');
select tap.throws_ok($$ select permissions.set_parent('box', 'b1', 'box', 'b2') $$, '23503',
    'api: set_parent needs the parent relation defined on the type (23503)');

create table public.widgets (wid uuid primary key, box_id uuid);
create trigger widgets_parent after insert or update of box_id or delete on public.widgets
    for each row execute function permissions.sync_parent('widget', 'box', 'box_id', 'wid');
insert into public.widgets values (:'acme_plan', :'acme');
select tap.is(
    (select subject_id from permissions.tuples where object_type = 'widget' and object_id = :'acme_plan' and relation = 'parent'),
    :'acme', 'api: sync_parent takes the id column as its fourth argument');

-- clients and tables
select tap.is(has_table_privilege('authenticated', 'permissions.tuples', 'select'), false,
    'api: clients have no privileges on the tables');
set role authenticated;
select tap.throws_ok($$ select count(*) from permissions.tuples $$, '42501', 'api: and cannot read tuples');
select tap.throws_ok($$ select permissions.grant('document', 'x', 'viewer', 'user', 'y') $$, '42501', 'api: or call grant');
select tap.throws_ok($$ select permissions.delete_subject('user', 'x') $$, '42501', 'api: or delete_subject');
select tap.throws_ok($$ select permissions.define_type('hack') $$, '42501', 'api: or define_type');
reset role;

-- identity helpers
select set_config('permissions.subject_id', :'alice', false);
select set_config('permissions.subject_type', '', false);
select tap.is(permissions.current_subject_id(), :'alice', 'api: current_subject_id reads permissions.subject_id');
select tap.is(permissions.current_subject_type(), 'user', 'api: current_subject_type defaults to user');
select set_config('permissions.subject_type', 'service', false);
select tap.is(permissions.current_subject_type(), 'service', 'api: permissions.subject_type overrides it');
select set_config('permissions.subject_type', '', false);

-- the dummy argument
select tap.ok(
    pg_get_function_arguments('permissions.list_objects(text, text, boolean)'::regprocedure) like '%p_unfold boolean DEFAULT permissions._unfolded_null()%',
    'api: list_objects ends in p_unfold boolean default permissions._unfolded_null()');
select tap.is((select provolatile::text from pg_proc where oid = 'permissions.list_objects(text, text, boolean)'::regprocedure), 's',
    'api: and is still STABLE');

-- grants: the client-facing set
select tap.set_eq(
    array(select p.proname::text from pg_proc p
          where p.pronamespace = 'permissions'::regnamespace and p.proname !~ '^_'
            and has_function_privilege('authenticated', p.oid, 'execute')),
    array['current_subject_id', 'current_subject_type', 'check', 'list_objects', 'has_permission', 'has_role', 'scopes_with_permission'],
    'api: the client-callable public functions are the seven the page lists');

-- ============================================================================
-- 6. Gotchas
-- ============================================================================

-- check needs its schema
set search_path = permissions, public;
select tap.throws_ok($$ select check('document', 'x', 'viewer') $$, '42601',
    'gotcha: an unqualified check(...) is a syntax error');
reset search_path;
select tap.lives_ok($$ select permissions.check('document', 'x', 'viewer') $$, 'gotcha: permissions.check works');

-- a typo in from_parent is silent, and redefining a relation drops from_parent
select permissions.define_type('memo');
select permissions.define_relation('memo', 'parent');
select permissions.define_relation('memo', 'viewer', from_parent => '{view_documentz}');
select permissions.set_parent('memo', 'm1', 'org', :'acme');
select tap.is(permissions.check_for('user', :'carol', 'memo', 'm1', 'viewer'), false,
    'gotcha: a mistyped from_parent relation gives no access and no error');
select permissions.define_relation('memo', 'viewer', from_parent => '{view_documents}');
select tap.is(permissions.check_for('user', :'carol', 'memo', 'm1', 'viewer'), true,
    'gotcha: with the right name it works');
select permissions.define_relation('memo', 'viewer');
select tap.is(permissions.check_for('user', :'carol', 'memo', 'm1', 'viewer'), false,
    'gotcha: defining the relation again without from_parent removes it');

-- ids are compared as text: pass the canonical (lower-case) uuid text
select permissions.grant('memo', 'AAAAAAAA-0000-0000-0000-000000000001', 'viewer', 'user', :'erin');
select tap.is(permissions.check_for('user', :'erin', 'memo', 'aaaaaaaa-0000-0000-0000-000000000001', 'viewer'), false,
    'gotcha: an upper-case id is a different id from the lower-case one RLS passes (id::text)');
select tap.is(permissions.check_for('user', :'erin', 'memo', 'AAAAAAAA-0000-0000-0000-000000000001', 'viewer'), true,
    'gotcha: it only matches itself');

-- the uuid cast in RLS
select permissions.grant('document', 'not-a-uuid', 'viewer', 'user', :'erin');
set role authenticated;
select set_config('permissions.subject_id', :'erin', false);
select tap.throws_ok($$ select count(*) from public.documents $$, '22P02',
    'gotcha: one stored id that is not a uuid fails the whole query');
reset role;
select tap.is(permissions.delete_object('document', 'not-a-uuid'), 1::bigint, 'gotcha: delete_object clears the bad tuple');

select * from tap.finish();
