-- Goal: parent inheritance org -> folder -> document (research/plan.md §10 G10)
-- Design B: folders are entities with a parents edge to their org; a document's
-- folder is its own folder_id column (documents never enter the permission
-- tables). Policies with via => 'org' / via => 'folder' anchor on the
-- document's folder or any ancestor of it. RLS projects every policy onto the
-- folder_id column, so one fast-path branch covers org- and folder-level access.
\ir ../../fixtures/ids.sql
\set frank      '00000000-0000-0000-0001-000000000006'
\set specs      '00000000-0000-0000-0005-000000000001'
\set plans      '00000000-0000-0000-0005-000000000002'
\set roadmap    '00000000-0000-0000-0003-000000000004'
\set globex_doc '00000000-0000-0000-0003-000000000007'

select permissions.define_role('org', 'member');
select permissions.define_role('org', 'admin', '{member}');
select permissions.define_role('folder', 'viewer');

select permissions.permit('org members view docs',    '{select}',        'document', roles => '{member}', via => 'org');
select permissions.permit('org admins edit docs',     '{update,delete}', 'document', roles => '{admin}',  via => 'org');
select permissions.permit('folder viewers view docs', '{select}',        'document', roles => '{viewer}', via => 'folder');

select permissions.add_parent('folder', :'specs', 'org', :'acme');
select permissions.add_parent('folder', :'plans', 'org', :'acme');

select permissions.grant_role('user', :'alice', 'admin',  'org',    :'acme');
select permissions.grant_role('user', :'carol', 'member', 'org',    :'acme');
select permissions.grant_role('user', :'erin',  'viewer', 'folder', :'specs');

create table public.documents (id uuid primary key, org_id uuid not null, folder_id uuid, title text not null);
insert into public.documents values
    (:'acme_readme', :'acme',   :'specs', 'readme'),
    (:'roadmap',     :'acme',   :'plans', 'roadmap'),
    (:'globex_doc',  :'globex', null,     'globex doc');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;

-- a single fast-path branch
create policy documents_select on public.documents for select to authenticated using (
    folder_id = any (array(select unnest(permissions.ids('select', 'document', 'folder'))::uuid))
);

-- the row attributes can_for needs: the document's current folder
create function pg_temp.doc(p_id uuid) returns jsonb language sql as $$
    select jsonb_build_object('folder', folder_id) from public.documents where id = p_id
$$;
-- true if the statement raises check_violation (23514), B's cycle/depth error
create function pg_temp.rejects(p_sql text) returns boolean language plpgsql as $$
begin
    execute p_sql;
    return false;
exception when check_violation then
    return true;
end $$;

select tap.plan(13);

select tap.is(permissions.can_for('user', :'alice', 'update', 'document', :'acme_readme', pg_temp.doc(:'acme_readme')), true,  'Alice (acme admin) can edit readme');
select tap.is(permissions.can_for('user', :'alice', 'update', 'document', :'roadmap',     pg_temp.doc(:'roadmap')),     true,  'Alice can edit roadmap');
select tap.is(permissions.can_for('user', :'carol', 'select', 'document', :'acme_readme', pg_temp.doc(:'acme_readme')), true,  'Carol (acme member) can view readme');
select tap.is(permissions.can_for('user', :'carol', 'update', 'document', :'acme_readme', pg_temp.doc(:'acme_readme')), false, 'Carol cannot edit readme');
select tap.is(permissions.can_for('user', :'erin',  'select', 'document', :'acme_readme', pg_temp.doc(:'acme_readme')), true,  'Erin (viewer of folder specs) can view readme');
select tap.is(permissions.can_for('user', :'erin',  'select', 'document', :'roadmap',     pg_temp.doc(:'roadmap')),     false, 'Erin cannot view roadmap');

select tap.set_eq(
    array(select distinct subject_id from permissions.who_can('select', 'document', :'acme_readme', pg_temp.doc(:'acme_readme'))
          where subject_type = 'user'),
    array[:'alice', :'carol', :'erin'],
    'subjects who can view readme: exactly Alice, Carol and Erin');

set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{readme,roadmap}', 'RLS as Carol returns readme and roadmap');
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'RLS as Erin returns readme');
reset role;

select permissions.revoke_role('user', :'erin', 'viewer', 'folder', :'specs');
select tap.is(permissions.can_for('user', :'erin', 'select', 'document', :'acme_readme', pg_temp.doc(:'acme_readme')), false, 'after revoking her folder grant, Erin cannot view readme');

select permissions.grant_role('user', :'erin', 'viewer', 'folder', :'specs');
update public.documents set folder_id = :'plans' where id = :'acme_readme';
select tap.is(permissions.can_for('user', :'erin', 'select', 'document', :'acme_readme', pg_temp.doc(:'acme_readme')), false, 'after moving readme to plans, Erin cannot view it');
update public.documents set folder_id = :'specs' where id = :'acme_readme';
select tap.is(permissions.can_for('user', :'erin', 'select', 'document', :'acme_readme', pg_temp.doc(:'acme_readme')), true,  'after moving it back, Erin can');

-- B rejects the cycle on write, so a parent chain can never loop. Assert the
-- rejection itself (a non-grantee's check alone never reaches the cycle), then
-- run traversals that do pass through the folders under a timeout, unasserted:
-- a hang or error there fails the file.
select permissions.add_parent('folder', :'plans', 'folder', :'specs');
create temp table cycle_rejected as
select pg_temp.rejects(format($$ select permissions.add_parent('folder', %L, 'folder', %L) $$, :'specs', :'plans')) as ok;
set statement_timeout = '5s';
select permissions.can_for('user', :'erin', 'select', 'document', :'roadmap', pg_temp.doc(:'roadmap')) is not null as traversed;
select count(*) >= 0 as traversed from permissions.who_can('select', 'document', :'roadmap', pg_temp.doc(:'roadmap'));
reset statement_timeout;
select tap.ok(
    (select ok from cycle_rejected)
    and permissions.can_for('user', :'frank', 'select', 'document', :'acme_readme', pg_temp.doc(:'acme_readme')) = false,
    'a parent cycle (specs <-> plans) terminates (rejected on write) and a non-grantee still gets false');

select * from tap.finish();
