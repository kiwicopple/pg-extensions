-- Goal: every example in usage/b-policy-first.md gives the answer the page shows.
-- This file mirrors that page, section by section: the "-- §" comments are the
-- page's headings. Change an example here and on the page together.
-- Design B only. The world is built once (the quick start) and the how-tos
-- extend it, undoing their demo policies where a later section needs a clean slate.
\ir ../../fixtures/ids.sql
\set frank        '00000000-0000-0000-0001-000000000006'
\set gina         '00000000-0000-0000-0001-000000000007'
\set specs        '00000000-0000-0000-0005-000000000001'
\set plans        '00000000-0000-0000-0005-000000000002'
\set contractors  '00000000-0000-0000-0004-000000000003'
\set announcement '00000000-0000-0000-0003-000000000005'
\set scratch      '00000000-0000-0000-0003-000000000009'

-- run a statement, return the number of rows it touched (for update/delete under RLS)
create function pg_temp.dml(p_sql text) returns int language plpgsql as $$
declare n int;
begin
    execute p_sql;
    get diagnostics n = row_count;
    return n;
end $$;

select tap.plan(229);

-- ============================================================================
-- § 2 Quick start
-- ============================================================================

select permissions.define_role('org', 'member');
select permissions.define_role('org', 'admin', '{member}');
select permissions.define_role('document', 'viewer');
select permissions.define_role('document', 'editor', '{viewer}');

select permissions.permit('org members view docs', '{select}',        'document', roles => '{member}', via => 'org');
select permissions.permit('org admins edit docs',  '{update,delete}', 'document', roles => '{admin}',  via => 'org');
select permissions.permit('doc viewers view',      '{select}',        'document', roles => '{viewer}');
select permissions.permit('doc editors edit',      '{update}',        'document', roles => '{editor}');
select permissions.permit('org members add docs',  '{insert}',        'document', roles => '{member}', via => 'org');

select permissions.grant_role('user', :'alice', 'admin',  'org', :'acme');
select permissions.grant_role('user', :'carol', 'member', 'org', :'acme');
select permissions.add_parent('user', :'carol', 'team', :'eng');
select permissions.add_parent('user', :'dave',  'team', :'eng');
select permissions.grant_role('user', :'bob', 'editor', 'document', :'acme_readme');
select permissions.grant_role('team', :'eng', 'viewer', 'document', :'acme_readme');

create table public.documents (
    id     uuid primary key,
    org_id uuid not null,
    title  text not null
);
insert into public.documents values
    (:'acme_readme',  :'acme',   'readme'),
    (:'acme_plan',    :'acme',   'plan'),
    (:'globex_notes', :'globex', 'notes');
alter table public.documents enable row level security;
grant select, update, insert on public.documents to authenticated;

select permissions.apply_rls('public.documents', 'select', 'document', 'id', '{"org": "org_id"}');
select permissions.apply_rls('public.documents', 'update', 'document', 'id', '{"org": "org_id"}');
select permissions.apply_rls('public.documents', 'insert', 'document', 'id', '{"org": "org_id"}');

select tap.is(
    permissions.apply_rls('public.documents', 'select', 'document', 'id', '{"org": "org_id"}'),
    'permissions_select', 'apply_rls returns the policy name and can be re-run');
select tap.is(permissions.rls_expression('select', 'document', 'id', '{"org": "org_id"}'),
$expr$(
    id = any (array(select unnest(permissions.ids('select', 'document'))::uuid))
    or org_id = any (array(select unnest(permissions.ids('select', 'document', 'org'))::uuid))
) and not (
    (select permissions.denies_all('select', 'document'))
    or id = any (array(select unnest(permissions.denied_ids('select', 'document'))::uuid))
    or org_id = any (array(select unnest(permissions.denied_ids('select', 'document', 'org'))::uuid))
)$expr$,
    'rls_expression: permit side, then the forbid side');

-- Hand-written policies on a copy of the table
create table public.documents_hand (like public.documents including all);
insert into public.documents_hand select * from public.documents;
alter table public.documents_hand enable row level security;
grant select, update on public.documents_hand to authenticated;

create policy documents_select on public.documents_hand for select to authenticated using (
    id     = any (array(select unnest(permissions.ids('select', 'document'))::uuid))
    or org_id = any (array(select unnest(permissions.ids('select', 'document', 'org'))::uuid))
);
create policy documents_update on public.documents_hand for update to authenticated
    using (permissions.can('update', 'document', id::text, jsonb_build_object('org', org_id)));

-- Can Bob update readme?
select tap.is(
    permissions.can_for('user', :'bob', 'update', 'document', :'acme_readme', jsonb_build_object('org', :'acme')),
    true, 'quick start: Bob can update readme');

-- Which documents can Dave see?
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'quick start: RLS as Dave shows readme');
select tap.set_eq(array(select title from public.documents_hand), '{readme}', 'quick start: the hand-written policy gives the same');
select tap.is(permissions.can('select', 'document', :'acme_readme', jsonb_build_object('org', :'acme')), true, 'quick start: can() as Dave');
select tap.is(permissions.can('select', 'document', :'acme_plan',   jsonb_build_object('org', :'acme')), false, 'quick start: Dave cannot view plan');
select tap.is(pg_temp.dml($$ update public.documents set title = 'readme v2' where id = '$$ || :'acme_readme' || $$' $$), 0,
              'quick start: Dave cannot update readme');

select set_config('permissions.subject_id', :'bob', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'quick start: RLS as Bob shows readme');
select tap.is(pg_temp.dml($$ update public.documents set title = 'readme v2' where id = '$$ || :'acme_readme' || $$' $$), 1,
              'quick start: Bob can update readme through RLS');
select tap.is(pg_temp.dml($$ update public.documents_hand set title = 'readme v2' where id = '$$ || :'acme_readme' || $$' $$), 1,
              'quick start: and through the hand-written update policy');
select tap.is(pg_temp.dml($$ update public.documents set title = 'readme' where id = '$$ || :'acme_readme' || $$' $$), 1, 'quick start: Bob puts the title back');
select tap.is(pg_temp.dml($$ update public.documents_hand set title = 'readme' where id = '$$ || :'acme_readme' || $$' $$), 1, 'quick start: (hand-written copy too)');

select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{readme,plan}', 'quick start: RLS as Carol (org member) shows readme and plan');
select set_config('permissions.subject_id', :'alice', false);
select tap.set_eq(array(select title from public.documents), '{readme,plan}', 'quick start: RLS as Alice (org admin) shows readme and plan');
select tap.is(pg_temp.dml($$ update public.documents set title = 'plan' where id = '$$ || :'acme_plan' || $$' $$), 1, 'quick start: Alice can update plan');
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents), '{}', 'quick start: RLS as Erin (no grants) shows nothing');

-- creating documents: the new row's org has to be one where the user holds a role the insert policy asks for
select set_config('permissions.subject_id', :'carol', false);
select tap.is(pg_temp.dml(format($$ insert into public.documents values (gen_random_uuid(), %L, 'carol draft') $$, :'acme')), 1,
              'quick start: Carol (org member) can insert a document into acme');
select tap.throws_ok(format($$ insert into public.documents values (gen_random_uuid(), %L, 'carol draft') $$, :'globex'),
                     '42501', 'quick start: but not into globex (42501)');
select set_config('permissions.subject_id', :'dave', false);
select tap.throws_ok(format($$ insert into public.documents values (gen_random_uuid(), %L, 'dave draft') $$, :'acme'),
                     '42501', 'quick start: and Dave, who is not in acme, cannot insert at all');
reset role;
delete from public.documents where title = 'carol draft';

-- Who can view readme?
select tap.set_eq(
    array(select distinct subject_id from permissions.who_can('select', 'document', :'acme_readme') where subject_type = 'user'),
    array[:'bob', :'carol', :'dave'],
    'quick start: who_can without the row: the people with grants on readme');
select tap.set_eq(
    array(select distinct subject_id from permissions.who_can('select', 'document', :'acme_readme', jsonb_build_object('org', :'acme'))
          where subject_type = 'user'),
    array[:'alice', :'bob', :'carol', :'dave'],
    'quick start: who_can with the org: adds the org members');

-- Why can Dave view it?
select tap.is(
    (select jsonb_agg(to_jsonb(e)) from permissions.explain('user', :'dave', 'select', 'document', :'acme_readme') e),
    jsonb_build_array(jsonb_build_object('effect', 'permit', 'policy', 'doc viewers view',
        'matched_grant', jsonb_build_object('on', 'document:' || :'acme_readme', 'role', 'viewer', 'principal', 'team:' || :'eng'))),
    'quick start: explain names the policy and the grant (team eng holds viewer on readme)');

-- ============================================================================
-- § 3.1 Per-object sharing
-- ============================================================================

-- share readme with Erin as a viewer
select permissions.grant_role('user', :'erin', 'viewer', 'document', :'acme_readme');
set role authenticated;
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'sharing: Erin sees the document shared with her');
select tap.set_eq(permissions.ids('select', 'document'), array[:'acme_readme'], 'sharing: ids() is "what is shared with me"');
select tap.is(pg_temp.dml($$ update public.documents set title = 'x' where id = '$$ || :'acme_readme' || $$' $$), 0, 'sharing: a viewer cannot update');
reset role;

-- upgrade: grant a stronger role. Grants add up, the viewer grant stays.
select permissions.grant_role('user', :'erin', 'editor', 'document', :'acme_readme');
select tap.is(permissions.can_for('user', :'erin', 'update', 'document', :'acme_readme'), true, 'sharing: after granting editor, Erin can update');

-- who has access to readme, and why
select tap.set_eq(
    array(select subject_id || '/' || policy from permissions.who_can('select', 'document', :'acme_readme') where subject_type = 'user'),
    array[:'bob' || '/doc viewers view', :'carol' || '/doc viewers view', :'dave' || '/doc viewers view', :'erin' || '/doc viewers view'],
    'sharing: who_can lists each person with the policy that admits them');

-- revoke
select tap.is(permissions.revoke_role('user', :'erin', 'editor', 'document', :'acme_readme'), true, 'sharing: revoke_role returns true when it removed a grant');
select tap.is(permissions.revoke_role('user', :'erin', 'viewer', 'document', :'acme_readme'), true, 'sharing: (the viewer grant too)');
select tap.is(permissions.revoke_role('user', :'erin', 'viewer', 'document', :'acme_readme'), false, 'sharing: and false when there was nothing to remove');
select tap.is(permissions.can_for('user', :'erin', 'select', 'document', :'acme_readme'), false, 'sharing: Erin is out again');
select tap.throws_ok(format($$ select permissions.grant_role('user', %L, 'owner', 'document', %L) $$, :'erin', :'acme_readme'),
                     '22023', 'sharing: granting a role that is not declared on the type raises 22023');

-- ============================================================================
-- § 3.2 Groups and nested teams
-- ============================================================================

-- eng (Carol, Dave) is in platform; platform can view the plan
select permissions.add_parent('team', :'eng', 'team', :'platform');
select permissions.grant_role('team', :'platform', 'viewer', 'document', :'acme_plan');
select tap.is(permissions.is_in('user', :'dave', 'team', :'platform'), true, 'groups: members of a nested team are in the parent team');
select tap.is(permissions.is_in('user', :'erin', 'team', :'platform'), false, 'groups: is_in is false for outsiders');
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.documents), '{readme,plan}', 'groups: RLS as Dave: readme (team eng) and plan (team platform)');
reset role;

-- what is stored: ancestors has rows for team eng (it has members), none for the users; the closure view adds them
select tap.set_eq(
    array(select ancestor_type || ':' || ancestor_id || ':' || depth from permissions.ancestors where child_type = 'team' and child_id = :'eng'),
    array['team:' || :'platform' || ':1'], 'groups: ancestors holds a row for the inner node eng');
select tap.is((select count(*)::int from permissions.ancestors where child_type = 'user'), 0, 'groups: and none for users');
select tap.set_eq(
    array(select ancestor_type || ':' || ancestor_id || ':' || depth from permissions.closure where child_type = 'user' and child_id = :'dave'),
    array['team:' || :'eng' || ':1', 'team:' || :'platform' || ':2'], 'groups: the closure view lists Dave''s teams with their depth');

-- a cycle is refused
select tap.throws_ok(format($$ select permissions.add_parent('team', %L, 'team', %L) $$, :'platform', :'eng'),
                     '23514', 'groups: a membership cycle raises 23514');
-- so is nesting deeper than 10 levels
select permissions.add_parent('chain', 'c' || i, 'chain', 'c' || (i + 1)) from generate_series(1, 10) i;
select tap.throws_ok($$ select permissions.add_parent('chain', 'c11', 'chain', 'c12') $$,
                     '23514', 'groups: an 11th level raises 23514');
-- permission writes are refused under repeatable read
set default_transaction_isolation = 'repeatable read';
select tap.throws_ok($$ select permissions.add_parent('chain', 'x1', 'chain', 'x2') $$,
                     '0A000', 'groups: add_parent raises 0A000 under repeatable read');
select tap.throws_ok($$ select permissions.define_role('document', 'owner') $$,
                     '0A000', 'groups: so does define_role');
reset default_transaction_isolation;
select tap.throws_ok($$ update permissions.parents set parent_id = 'x' where child_type = 'chain' $$,
                     '0A000', 'groups: parents rows cannot be updated');

-- remove a member, add him back
select tap.is(permissions.remove_parent('user', :'dave', 'team', :'eng'), true, 'groups: remove_parent returns true');
select tap.is(permissions.can_for('user', :'dave', 'select', 'document', :'acme_plan'), false, 'groups: Dave left eng, so the access through eng and platform is gone');
select tap.is(permissions.remove_parent('user', :'dave', 'team', :'eng'), false, 'groups: remove_parent returns false for a missing edge');
select permissions.add_parent('user', :'dave', 'team', :'eng');

-- the platform grant goes away again
select permissions.revoke_role('team', :'platform', 'viewer', 'document', :'acme_plan');
select permissions.remove_parent('team', :'eng', 'team', :'platform');

-- ============================================================================
-- § 3.3 Expiry
-- ============================================================================

select permissions.grant_role('user', :'erin', 'viewer', 'document', :'acme_readme', now() + interval '7 days');
select tap.is(permissions.can_for('user', :'erin', 'select', 'document', :'acme_readme'), true, 'expiry: before the expiry the grant works');
-- the same call again moves the date (here: into the past, as if a week had gone by)
select permissions.grant_role('user', :'erin', 'viewer', 'document', :'acme_readme', now() - interval '1 minute');
select tap.is(permissions.can_for('user', :'erin', 'select', 'document', :'acme_readme'), false, 'expiry: after it, the grant gives nothing');
set role authenticated;
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents), '{}', 'expiry: and RLS hides the row');
reset role;
select tap.is((select count(*)::int from permissions.role_grants where expires_at < now()), 1, 'expiry: the expired row is still stored');
delete from permissions.role_grants where expires_at < now();
select tap.is((select count(*)::int from permissions.role_grants where expires_at < now()), 0, 'expiry: and can be swept');

-- ============================================================================
-- § 3.4 Parent inheritance with via
-- ============================================================================

-- folders live in orgs: facts in the parents table
select permissions.define_role('folder', 'viewer');
select permissions.add_parent('folder', :'specs', 'org', :'acme');
select permissions.add_parent('folder', :'plans', 'org', :'acme');
select permissions.permit('folder viewers view docs', '{select}', 'document', roles => '{viewer}', via => 'folder');
select permissions.grant_role('user', :'erin', 'viewer', 'folder', :'specs');

-- a document's folder is a column of the document
alter table public.documents add column folder_id uuid;
update public.documents set folder_id = :'specs' where id = :'acme_readme';
update public.documents set folder_id = :'plans' where id = :'acme_plan';

-- can(): the parent comes from the row (a folder key), the org from the stored folder -> org edge
select tap.is(permissions.can_for('user', :'erin', 'select', 'document', :'acme_readme', jsonb_build_object('folder', :'specs')), true,
              'via: Erin (viewer of folder specs) can view readme');
select tap.is(permissions.can_for('user', :'erin', 'select', 'document', :'acme_plan', jsonb_build_object('folder', :'plans')), false,
              'via: but not plan, which is in another folder');
select tap.is(permissions.can_for('user', :'carol', 'select', 'document', :'acme_plan', jsonb_build_object('folder', :'plans')), true,
              'via: Carol (org member) reaches plan through folder plans, which is in acme');
select tap.is(permissions.can_for('user', :'carol', 'select', 'document', :'acme_plan', jsonb_build_object('org', :'acme')), true,
              'via: the org can also be passed directly');

-- the projection: ids(..., via) lists parent ids
select tap.set_eq(permissions.ids_for('user', :'erin',  'select', 'document', 'folder'), array[:'specs'], 'via: ids_for(..., folder) as Erin is her folder');
select tap.set_eq(permissions.ids_for('user', :'carol', 'select', 'document', 'folder'), array[:'specs', :'plans'], 'via: as Carol it is every folder in her org');
select tap.set_eq(permissions.ids_for('user', :'carol', 'select', 'document', 'org'), array[:'acme'], 'via: ids_for(..., org) as Carol is her org');
select tap.set_eq(permissions.ids_for('user', :'erin',  'select', 'document', 'org'), '{}', 'via: and empty for Erin');

-- RLS written before the folder policy existed does not know it: Erin sees nothing (fails closed), and lint stays silent
select tap.is((select count(*)::int from permissions.lint()), 0, 'via: lint does not notice the missing folder column');
set role authenticated;
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents), '{}', 'via: RLS generated before the folder policy: Erin sees nothing');
reset role;
-- regenerate with the new parent column
select permissions.apply_rls('public.documents', 'select', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
select permissions.apply_rls('public.documents', 'update', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
set role authenticated;
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'via: after apply_rls with the folder column: Erin sees readme');
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{readme,plan}', 'via: Carol still sees both');
reset role;

-- single branch: link every document to its folder in the parents table
select permissions.add_parent('document', id::text, 'folder', folder_id::text) from public.documents where folder_id is not null;
create table public.documents_flat (like public.documents including all);
insert into public.documents_flat select * from public.documents;
alter table public.documents_flat enable row level security;
grant select on public.documents_flat to authenticated;
create policy documents_select on public.documents_flat for select to authenticated using (
    id = any (array(select unnest(permissions.ids('select', 'document'))::uuid))
);
select tap.set_eq(permissions.ids_for('user', :'carol', 'select', 'document'), array[:'acme_readme', :'acme_plan'],
                  'via: with document parents rows, ids() alone lists every document Carol can reach');
set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents_flat), '{readme,plan}', 'via: single-branch RLS as Carol');
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents_flat), '{readme}', 'via: single-branch RLS as Erin');
reset role;
-- a stored parent row also lets can() leave the folder out
select tap.is(permissions.can_for('user', :'erin', 'select', 'document', :'acme_readme'), true, 'via: with the parents row, can() needs no row for the folder');

-- the parents rows have to follow the column: move readme in the column only
update public.documents set folder_id = :'plans' where id = :'acme_readme';
set role authenticated;
select set_config('permissions.subject_id', :'erin', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'via: a stale parents row keeps feeding ids(): Erin still sees the moved readme');
reset role;
select permissions.remove_parent('document', :'acme_readme', 'folder', :'specs');
select permissions.add_parent('document', :'acme_readme', 'folder', :'plans');
set role authenticated;
select tap.set_eq(array(select title from public.documents), '{}', 'via: after moving the parents row too, she does not');
reset role;

-- undo: move readme back, drop the single-branch table and the document parents rows
update public.documents set folder_id = :'specs' where id = :'acme_readme';
drop table public.documents_flat;
select permissions.remove_parent('document', :'acme_readme', 'folder', :'plans');
select permissions.remove_parent('document', :'acme_plan', 'folder', :'plans');

-- ============================================================================
-- § 3.5 Public access
-- ============================================================================

insert into public.documents (id, org_id, title) values (:'announcement', :'globex', 'announcement');
select permissions.permit('announcement is public', '{select}', 'document', resource_id => :'announcement');
set role authenticated;
select set_config('permissions.subject_id', :'frank', false);
select tap.set_eq(array(select title from public.documents), '{announcement}', 'public: Frank, who has no grants, sees the announcement');
select tap.is(pg_temp.dml($$ update public.documents set title = 'x' where id = '$$ || :'announcement' || $$' $$), 0, 'public: but cannot update it');
select set_config('permissions.subject_id', '', false);
select tap.set_eq(array(select title from public.documents), '{}', 'public: no subject, no rows');
select tap.is(permissions.can('select', 'document', :'announcement'), false, 'public: and can() is false without a subject');
reset role;
select tap.is(permissions.drop_policy('announcement is public'), true, 'public: drop_policy returns true');
select tap.is(permissions.drop_policy('announcement is public'), false, 'public: and false for a name that does not exist');
set role authenticated;
select set_config('permissions.subject_id', :'frank', false);
select tap.set_eq(array(select title from public.documents), '{}', 'public: after dropping the policy Frank sees nothing');
reset role;

-- ============================================================================
-- § 3.6 Forbid policies
-- ============================================================================

-- a forbid on one user, for one document
select permissions.forbid('block dave on readme', '{select,update,delete}', 'document',
                          resource_id => :'acme_readme', principal_id => :'dave');
select tap.is(permissions.can_for('user', :'dave', 'select', 'document', :'acme_readme', jsonb_build_object('folder', :'specs')), false,
              'forbid: Dave is in team eng, which can view readme, and is still refused');
select tap.is(permissions.can_for('user', :'carol', 'select', 'document', :'acme_readme', jsonb_build_object('folder', :'specs')), true,
              'forbid: Carol, in the same team, is not');
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.documents), '{}', 'forbid: RLS as Dave hides readme');
reset role;
select tap.is(permissions.drop_policy('block dave on readme'), true, 'forbid: dropping the policy lifts it');

-- a forbid on a group: contractors are read-only on every document
select permissions.add_parent('user', :'erin', 'team', :'contractors');
select permissions.grant_role('user', :'erin', 'editor', 'document', :'acme_readme');
select tap.is(permissions.can_for('user', :'erin', 'update', 'document', :'acme_readme', jsonb_build_object('folder', :'specs')), true,
              'forbid: Erin is an editor of readme and can update it');
select permissions.forbid('contractors are read only', '{update,delete}', 'document',
                          principal_in_type => 'team', principal_in_id => :'contractors');
select tap.is(permissions.can_for('user', :'erin', 'update', 'document', :'acme_readme', jsonb_build_object('folder', :'specs')), false,
              'forbid: once her team is forbidden she cannot');
set role authenticated;
select set_config('permissions.subject_id', :'erin', false);
select tap.is(pg_temp.dml($$ update public.documents set title = 'x' where id = '$$ || :'acme_readme' || $$' $$), 0, 'forbid: RLS update as Erin touches no rows');
select tap.set_eq(array(select title from public.documents), '{readme}', 'forbid: she can still select');
select set_config('permissions.subject_id', :'bob', false);
select tap.is(pg_temp.dml($$ update public.documents set title = 'readme' where id = '$$ || :'acme_readme' || $$' $$), 1, 'forbid: Bob, not a contractor, can');
reset role;

-- a role-based forbid: whoever holds "blocked" on a folder is refused its documents
select permissions.define_role('folder', 'blocked');
select permissions.forbid('blocked folders', '{select}', 'document', roles => '{blocked}', via => 'folder');
select permissions.grant_role('user', :'carol', 'blocked', 'folder', :'specs');
set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{plan}', 'forbid: Carol, blocked in specs, loses readme but keeps plan');
reset role;
select tap.set_eq(permissions.denied_ids_for('user', :'carol', 'select', 'document', 'folder'), array[:'specs'], 'forbid: denied_ids lists the blocked folder');

-- ============================================================================
-- § 3.7 Conditions
-- ============================================================================

-- a resource condition: guests may view published documents only
alter table public.documents add column status text not null default 'published';
update public.documents set status = 'draft' where id = :'acme_plan';
select permissions.define_role('org', 'guest');
select permissions.permit('org guests view published docs', '{select}', 'document', roles => '{guest}', via => 'org',
                          condition => '{"op": "==", "left": {"var": "resource.status"}, "right": "published"}');
select permissions.grant_role('user', :'gina', 'guest', 'org', :'acme');
select tap.is(permissions.can_for('user', :'gina', 'select', 'document', :'acme_readme', jsonb_build_object('org', :'acme', 'status', 'published')), true,
              'conditions: can() with the row: a guest can view a published document');
select tap.is(permissions.can_for('user', :'gina', 'select', 'document', :'acme_plan', jsonb_build_object('org', :'acme', 'status', 'draft')), false,
              'conditions: and not a draft');
select tap.is((select count(*)::int from permissions.lint() where policy = 'org guests view published docs'), 1,
              'conditions: lint() notices that no RLS policy has the condition yet');
set role authenticated;
select set_config('permissions.subject_id', :'gina', false);
select tap.set_eq(array(select title from public.documents), '{}', 'conditions: before apply_rls, RLS as Gina shows nothing');
reset role;
select permissions.apply_rls('public.documents', 'select', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
select permissions.apply_rls('public.documents', 'update', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
select tap.is((select count(*)::int from permissions.lint() where policy = 'org guests view published docs'), 0,
              'conditions: after apply_rls the lint warning is gone');
set role authenticated;
select set_config('permissions.subject_id', :'gina', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'conditions: RLS as Gina shows the published document only');
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{plan}', 'conditions: Carol is not a guest and is still blocked from specs');
reset role;
update public.documents set status = 'published' where id = :'acme_plan';
set role authenticated;
select set_config('permissions.subject_id', :'gina', false);
select tap.set_eq(array(select title from public.documents), '{readme,plan}', 'conditions: once plan is published, Gina sees it');
reset role;

-- a principal condition: only verified users may comment (evaluated once per query)
select permissions.set_attrs('user', :'erin', '{"verified": true}');
select permissions.permit('verified viewers comment', '{comment}', 'document', roles => '{viewer}',
                          condition => '{"op": "==", "left": {"var": "principal.attrs.verified"}, "right": true}');
select tap.is(permissions.can_for('user', :'erin', 'comment', 'document', :'acme_readme'), true, 'conditions: Erin is verified and can comment');
select tap.is(permissions.can_for('user', :'bob',  'comment', 'document', :'acme_readme'), false, 'conditions: Bob has no attributes and cannot');
select permissions.set_attrs('user', :'bob', '{"verified": true}');
select tap.is(permissions.can_for('user', :'bob',  'comment', 'document', :'acme_readme'), true, 'conditions: once Bob is verified he can');

-- a context condition: editing needs a second factor, read from the JWT
insert into public.documents (id, org_id, title) values (:'scratch', :'acme', 'scratch');
select permissions.forbid('editing needs mfa', '{update}', 'document',
                          condition => '{"op": "not", "arg": {"op": "==", "left": {"var": "context.jwt.aal"}, "right": "aal2"}}');
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'alice', 'aal', 'aal1')::text, false);
select tap.is(pg_temp.dml($$ update public.documents set title = 'scratch 2' where id = '$$ || :'scratch' || $$' $$), 0, 'conditions: Alice (org admin) cannot update with an aal1 token');
select set_config('request.jwt.claims', json_build_object('sub', :'alice', 'aal', 'aal2')::text, false);
select tap.is(pg_temp.dml($$ update public.documents set title = 'scratch 2' where id = '$$ || :'scratch' || $$' $$), 1, 'conditions: with an aal2 token she can');
select set_config('request.jwt.claims', '', false);
reset role;
select permissions.drop_policy('editing needs mfa');
delete from public.documents where id = :'scratch';

-- every operator, checked against a throwaway policy on a type of its own
create function pg_temp.holds(p_cond jsonb, p_row jsonb) returns boolean language plpgsql as $$
declare r boolean;
begin
    perform permissions.permit('probe', '{select}', 'probe', condition => p_cond);
    r := permissions.can_for('user', 'anyone', 'select', 'probe', 'p1', p_row);
    perform permissions.drop_policy('probe');
    return r;
end $$;
select tap.is(pg_temp.holds('{"op": "==", "left": {"var": "resource.status"}, "right": "draft"}', '{"status": "draft"}'), true, 'conditions: == on a string');
select tap.is(pg_temp.holds('{"op": "!=", "left": {"var": "resource.status"}, "right": "draft"}', '{"status": "draft"}'), false, 'conditions: !=');
select tap.is(pg_temp.holds('{"op": ">=", "left": {"var": "resource.score"}, "right": 5}', '{"score": 7}'), true, 'conditions: >= on a number');
select tap.is(pg_temp.holds('{"op": "<", "left": {"var": "resource.score"}, "right": 5}', '{"score": 7}'), false, 'conditions: <');
select tap.is(pg_temp.holds('{"op": "in", "left": {"var": "resource.status"}, "right": ["draft", "review"]}', '{"status": "review"}'), true, 'conditions: in a list');
select tap.is(pg_temp.holds('{"op": "has", "var": "resource.status"}', '{"status": "draft"}'), true, 'conditions: has, present');
select tap.is(pg_temp.holds('{"op": "has", "var": "resource.status"}', '{"status": null}'), false, 'conditions: has, null');
select tap.is(pg_temp.holds('{"op": "==", "left": {"var": "resource.status"}, "right": "draft"}', '{"status": null}'), false, 'conditions: a null operand makes a comparison false');
select tap.is(pg_temp.holds('{"op": "and", "args": [{"op": "==", "left": {"var": "resource.status"}, "right": "draft"}, {"op": ">", "left": {"var": "resource.score"}, "right": 5}]}',
                            '{"status": "draft", "score": 7}'), true, 'conditions: and');
select tap.is(pg_temp.holds('{"op": "or", "args": [{"op": "==", "left": {"var": "resource.status"}, "right": "draft"}, {"op": ">", "left": {"var": "resource.score"}, "right": 5}]}',
                            '{"status": "final", "score": 7}'), true, 'conditions: or');
select tap.is(pg_temp.holds('{"op": "not", "arg": {"op": "==", "left": {"var": "resource.status"}, "right": "draft"}}', '{"status": "final"}'), true, 'conditions: not');
select tap.is(pg_temp.holds('{"op": "==", "left": {"var": "resource.status"}, "right": "draft"}', '{"status": "final"}'), false, 'conditions: no match, no permit');

-- what is rejected when the policy is written
select tap.throws_ok($$ select permissions.permit('authors edit own docs', '{update}', 'document',
    condition => '{"op": "==", "left": {"var": "resource.owner_id"}, "right": {"var": "principal.id"}}') $$,
    '22023', 'conditions: a term that reads the resource and the principal raises 22023');
select tap.throws_ok($$ select permissions.permit('x', '{update}', 'document',
    condition => '{"op": "or", "args": [{"op": "==", "left": {"var": "resource.a"}, "right": 1}, {"op": "==", "left": {"var": "principal.id"}, "right": "x"}]}') $$,
    '22023', 'conditions: so does an or across both');
select tap.throws_ok($$ select permissions.permit('x', '{update}', 'document',
    condition => '{"op": "<=", "left": {"var": "resource.publish_at"}, "right": {"var": "now"}}') $$,
    '22023', 'conditions: and a comparison of a column with now');
select tap.throws_ok($$ select permissions.permit('x', '{update}', 'document',
    condition => '{"op": "==", "left": {"var": "user.id"}, "right": "x"}') $$,
    '22023', 'conditions: an unknown variable raises 22023');
select tap.throws_ok($$ select permissions.permit('x', '{update}', 'document',
    condition => '{"op": "==", "left": {"var": "resource.meta.kind"}, "right": "x"}') $$,
    '22023', 'conditions: resource attributes are flat column names');
select tap.throws_ok($$ select permissions.permit('x', '{select}', 'document', via => 'org') $$,
    '22023', 'conditions: (and via needs roles)');

-- "authors edit their own documents" can't be a condition (it compares a column with the principal).
-- Make it a fact: grant the author a role on the new row.
\set carol_note '00000000-0000-0000-0003-00000000000a'
create function public.documents_grant_author() returns trigger language plpgsql security definer set search_path = '' as $$
begin
    perform permissions.grant_role('user', permissions.current_subject_id(), 'editor', 'document', new.id::text);
    return new;
end $$;
create trigger documents_grant_author after insert on public.documents
    for each row execute function public.documents_grant_author();
set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.is(pg_temp.dml(format($$ insert into public.documents (id, org_id, folder_id, title) values (%L, %L, %L, 'carol note') $$, :'carol_note', :'acme', :'plans')), 1,
              'authors: Carol (org member) inserts a document');
select tap.is(pg_temp.dml(format($$ update public.documents set title = 'carol note v2' where id = %L $$, :'carol_note')), 1,
              'authors: and can edit it, because the trigger made her its editor');
select tap.is(pg_temp.dml(format($$ update public.documents set title = 'x' where id = %L $$, :'acme_readme')), 0,
              'authors: but not readme, which she did not write');
reset role;
drop trigger documents_grant_author on public.documents;
delete from public.documents where id = :'carol_note';
select permissions.delete_entity('document', :'carol_note');

-- ============================================================================
-- § 3.8 Calling can() outside RLS
-- ============================================================================

create function public.doc_ctx(d public.documents) returns jsonb language sql stable as $$
    select jsonb_build_object('org', d.org_id, 'folder', d.folder_id, 'status', d.status)
$$;
select tap.is(
    (select permissions.can_for('user', :'bob', 'update', 'document', d.id::text, public.doc_ctx(d))
     from public.documents d where d.id = :'acme_readme'),
    true, 'can: the row goes in as one jsonb built from its columns');
set role authenticated;
select set_config('permissions.subject_id', :'bob', false);
select tap.is(
    (select permissions.can('update', 'document', d.id::text, public.doc_ctx(d)) from public.documents d where d.id = :'acme_readme'),
    true, 'can: the current-subject form');
reset role;
-- Carol is blocked in folder specs: the forbid reads the folder
select tap.throws_ok(format($$ select permissions.can_for('user', %L, 'select', 'document', %L) $$, :'carol', :'acme_plan'),
                     '22023', 'can: a forbid that could apply to Carol needs the folder, and raises without it');
select tap.is(permissions.can_for('user', :'carol', 'select', 'document', :'acme_plan', jsonb_build_object('folder', :'plans')), true,
              'can: with the folder it answers (plan is in plans)');
select tap.is(permissions.can_for('user', :'carol', 'select', 'document', :'acme_readme', jsonb_build_object('folder', :'specs')), false,
              'can: and readme, in specs, is refused');
select tap.is(permissions.can_for('user', :'carol', 'select', 'document', :'acme_plan', '{"folder": null, "org": null}'), false,
              'can: a null says "the row has none" (a document with no folder and no org: nothing admits Carol)');
select tap.is(permissions.can_for('user', :'bob', 'select', 'document', :'acme_readme'), true,
              'can: for Bob, who holds no blocked role, the same call needs nothing');

-- ============================================================================
-- § 3.9 who_can, explain, lint
-- ============================================================================

-- who can view readme? Pass the row so the folder and org policies count. Carol is blocked, so she is not listed.
select tap.set_eq(
    array(select distinct w.subject_id
          from public.documents d
          cross join lateral permissions.who_can('select', 'document', d.id::text, public.doc_ctx(d)) w
          where d.id = :'acme_readme' and w.subject_type = 'user'),
    array[:'alice', :'bob', :'dave', :'erin', :'gina'],
    'who_can: with the row, everyone who can view readme, minus the blocked');

-- why can't Carol? every matching policy, forbids included
select tap.set_eq(
    array(select e.effect || ': ' || e.policy
          from public.documents d
          cross join lateral permissions.explain('user', :'carol', 'select', 'document', d.id::text, public.doc_ctx(d)) e
          where d.id = :'acme_readme'),
    array['permit: doc viewers view', 'permit: org members view docs', 'forbid: blocked folders'],
    'explain: the permits that match and the forbid that beats them');
select tap.is(
    (select e.matched_grant from public.documents d
     cross join lateral permissions.explain('user', :'carol', 'select', 'document', d.id::text, public.doc_ctx(d)) e
     where d.id = :'acme_readme' and e.effect = 'forbid'),
    jsonb_build_object('principal', 'user:' || :'carol', 'role', 'blocked', 'on', 'folder:' || :'specs'),
    'explain: the forbid row carries the grant behind it');
select tap.is((select count(*)::int from permissions.explain('user', :'frank', 'select', 'document', :'acme_plan', jsonb_build_object('folder', :'plans'))), 0,
              'explain: no rows means nothing matched, so the answer is no');

-- lint: the contractors forbid names delete, and no RLS policy covers delete yet
select tap.is((select problem from permissions.lint() where policy = 'contractors are read only'),
              'forbid on delete/document is not enforced by any RLS policy (no denied_ids branch); can() still applies it',
              'lint: a forbid on delete, with no delete RLS policy');
select tap.is((select count(*)::int from permissions.lint()), 1, 'lint: and that is the only problem');
grant delete on public.documents to authenticated;
select permissions.apply_rls('public.documents', 'delete', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
select tap.is((select count(*)::int from permissions.lint()), 0, 'lint: apply_rls for delete clears it');

-- the blocked-folders demo ends here
select permissions.drop_policy('blocked folders');
select permissions.revoke_role('user', :'carol', 'blocked', 'folder', :'specs');

-- ============================================================================
-- § 3.10 Regenerating RLS when policies change shape
-- ============================================================================

-- a forbid with a resource condition that the RLS does not have yet does not deny in RLS (can() does)
select permissions.forbid('archived is read only', '{update}', 'document',
                          condition => '{"op": "==", "left": {"var": "resource.status"}, "right": "archived"}');
select tap.is((select problem from permissions.lint() where policy = 'archived is read only'),
              'resource condition on update/document is not in any RLS policy; re-run apply_rls',
              'regenerate: lint reports the conditioned forbid');
update public.documents set status = 'archived' where id = :'acme_plan';
select tap.is(permissions.can_for('user', :'alice', 'update', 'document', :'acme_plan', jsonb_build_object('org', :'acme', 'folder', :'plans', 'status', 'archived')), false,
              'regenerate: can() refuses to update an archived document');
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.is(pg_temp.dml($$ update public.documents set title = title where id = '$$ || :'acme_plan' || $$' $$), 1,
              'regenerate: but the old RLS still lets Alice update it');
reset role;
select permissions.apply_rls('public.documents', 'update', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.is(pg_temp.dml($$ update public.documents set title = title where id = '$$ || :'acme_plan' || $$' $$), 0,
              'regenerate: after apply_rls it does not');
reset role;
select permissions.drop_policy('archived is read only');
update public.documents set status = 'published' where id = :'acme_plan';
select permissions.apply_rls('public.documents', 'update', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');

-- a new allow-all permit: members of eng may view every document
select permissions.permit('eng views everything', '{select}', 'document', principal_in_type => 'team', principal_in_id => :'eng');
select tap.is((select problem from permissions.lint() where policy = 'eng views everything'),
              'allow-all permit on select/document is not in any RLS policy (no allows_all branch); re-run apply_rls',
              'regenerate: lint reports an allow-all permit that no RLS policy has');
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'regenerate: before re-running apply_rls Dave sees only readme');
reset role;
do $$
declare c text;
begin
    foreach c in array array['select', 'update', 'delete', 'insert'] loop
        perform permissions.apply_rls('public.documents', c, 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
    end loop;
end $$;
select tap.is((select count(*)::int from permissions.lint()), 0, 'regenerate: lint is quiet again');
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.documents), '{readme,plan,notes,announcement}', 'regenerate: Dave now sees every document');
reset role;
select tap.is(permissions.allows_all_for('user', :'dave', 'select', 'document'), true, 'regenerate: allows_all is true for Dave');
select tap.is(permissions.allows_all_for('user', :'bob', 'select', 'document'), false, 'regenerate: and false for Bob');
select permissions.drop_policy('eng views everything');

-- a new via type: lint has no check for it, so regenerate by habit
select permissions.define_role('project', 'viewer');
select permissions.permit('project viewers view docs', '{select}', 'document', roles => '{viewer}', via => 'project');
select tap.is((select count(*)::int from permissions.lint()), 0, 'regenerate: lint does not notice a policy via a new parent type');
select permissions.drop_policy('project viewers view docs');

-- ============================================================================
-- § 3.11 Graduating from the rbac preset
-- ============================================================================

\set report1 '00000000-0000-0000-0006-000000000001'
\set report2 '00000000-0000-0000-0006-000000000002'

select permissions.create_role('viewer', '{reports.read}');
select permissions.create_role('editor', '{reports.edit}', '{viewer}');
select permissions.create_role('admin',  '{reports.delete}', '{editor}');
select permissions.assign_role(:'alice', 'admin', :'acme');
select permissions.assign_role(:'bob',   'editor', :'acme');

create table public.reports (id uuid primary key, org_id uuid not null, title text not null);
insert into public.reports values (:'report1', :'acme', 'q1'), (:'report2', :'acme', 'q2');
alter table public.reports enable row level security;
grant select on public.reports to authenticated;
create policy reports_select on public.reports for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('reports.read'))::uuid))
);

create temp table before as
select u, permissions.user_permissions(u, :'acme') as perms from unnest(array[:'alice', :'bob']) u;

set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.reports), '{}', 'graduate: Dave, in no org, sees no reports');
select set_config('permissions.subject_id', :'bob', false);
select tap.set_eq(array(select title from public.reports), '{q1,q2}', 'graduate: Bob (org editor) sees both');
reset role;

-- share one report with Dave: a role on the report, a policy that uses it, a grant, one more OR arm
select permissions.define_role('report', 'viewer');
select permissions.permit('report viewers view', '{select}', 'report', roles => '{viewer}');
select permissions.grant_role('user', :'dave', 'viewer', 'report', :'report1');
drop policy reports_select on public.reports;
create policy reports_select on public.reports for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('reports.read'))::uuid))
    or id  = any (array(select unnest(permissions.ids('select', 'report'))::uuid))
);

set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.reports), '{q1}', 'graduate: Dave sees the one report shared with him');
select tap.is(permissions.has_permission('reports.read', :'acme'), false, 'graduate: sharing did not make him an org member');
select set_config('permissions.subject_id', :'bob', false);
select tap.set_eq(array(select title from public.reports), '{q1,q2}', 'graduate: Bob still sees both');
select tap.is(permissions.has_permission('reports.edit', :'acme'), true, 'graduate: has_permission as Bob');
select tap.is(permissions.has_role('viewer', :'acme'), true, 'graduate: has_role sees the inherited viewer role');
select tap.set_eq(permissions.scopes_with_permission('reports.read'), array[:'acme'], 'graduate: scopes_with_permission lists the org');
reset role;
select tap.is((select count(*)::int from before b where b.perms is distinct from permissions.user_permissions(b.u, :'acme')), 0,
              'graduate: every rbac answer is unchanged');
select tap.set_eq(permissions.user_permissions(:'alice', :'acme'), '{reports.read,reports.edit,reports.delete}', 'graduate: user_permissions');
select tap.set_eq(array(select permissions.users_with_role('admin', :'acme')), array[:'alice'], 'graduate: users_with_role');
select tap.is((select count(*)::int from permissions.policies where managed_by = 'rbac'), 6, 'graduate: the preset wrote 6 policies (3 roles, app and tenant)');
select tap.throws_ok($$ select permissions.drop_policy('rbac:tenant:admin') $$, '55000', 'graduate: drop_policy refuses a policy the preset manages');
select permissions.unassign_role(:'bob', 'editor', :'acme');
select tap.is(permissions.can_for('user', :'bob', 'reports.edit', 'tenant', :'acme'), false, 'graduate: unassign_role');

-- ============================================================================
-- § 3.12 Cleaning up
-- ============================================================================

-- delete_entity: everything that names the entity
select tap.is(permissions.delete_entity('user', :'erin'), 4::bigint,
              'cleanup: delete_entity counts what it removed (2 grants, 1 parents edge, 1 attributes row)');
select tap.set_eq(permissions.ids_for('user', :'erin', 'select', 'document'), '{}', 'cleanup: Erin has no access left');
select tap.is(permissions.delete_entity('user', :'erin'), 0::bigint, 'cleanup: a second call removes nothing');

-- the same, automatically, from the app's own tables
create table public.profiles (id uuid primary key, name text);
create trigger cleanup_permissions after delete on public.profiles
    for each row execute function permissions.on_entity_deleted('user', 'id');
create trigger cleanup_permissions after delete on public.documents
    for each row execute function permissions.on_entity_deleted('document', 'id');
insert into public.profiles values (:'frank', 'Frank');
select permissions.grant_role('user', :'frank', 'viewer', 'document', :'acme_readme');
select tap.is(permissions.can_for('user', :'frank', 'select', 'document', :'acme_readme', jsonb_build_object('folder', :'specs')), true, 'cleanup: Frank has a grant');
delete from public.profiles where id = :'frank';
select tap.is((select count(*)::int from permissions.role_grants where principal_id = :'frank'), 0, 'cleanup: deleting his profile row removed it');
insert into public.documents (id, org_id, title) values (:'scratch', :'acme', 'scratch');
select permissions.grant_role('user', :'gina', 'viewer', 'document', :'scratch');
select permissions.permit('scratch is public', '{select}', 'document', resource_id => :'scratch');
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.is(pg_temp.dml($$ delete from public.documents where id = '$$ || :'scratch' || $$' $$), 1, 'cleanup: Alice (org admin) deletes the document through RLS');
reset role;
select tap.is((select count(*)::int from permissions.role_grants where resource_id = :'scratch'), 0, 'cleanup: deleting a document removes the grants on it');
select tap.is((select count(*)::int from permissions.policies where name = 'scratch is public'), 0, 'cleanup: and the policies that name it');
-- a deleted group takes the policies that name it along
select tap.is((select count(*)::int from permissions.policies where name = 'contractors are read only'), 1, 'cleanup: the contractors forbid exists');
select permissions.delete_entity('team', :'contractors');
select tap.is((select count(*)::int from permissions.policies where name = 'contractors are read only'), 0, 'cleanup: deleting the team deleted the forbid that named it');

-- ============================================================================
-- § 4 API reference
-- ============================================================================

-- identity helpers
select set_config('permissions.subject_id', :'dave', false);
select tap.is(permissions.current_subject_id(), :'dave', 'api: current_subject_id() reads the permissions.subject_id setting');
select tap.is(permissions.current_subject_type(), 'user', 'api: current_subject_type() defaults to user');
select set_config('permissions.subject_type', 'service', false);
select tap.is(permissions.current_subject_type(), 'service', 'api: and reads permissions.subject_type');
select set_config('permissions.subject_type', '', false);
select set_config('request.jwt.claims', json_build_object('sub', :'alice')::text, false);
select tap.is(permissions.current_subject_id(), :'alice', 'api: a JWT sub beats the setting');
select set_config('request.jwt.claims', '', false);

-- who may call what
select tap.set_eq(
    array(select p.proname::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'permissions' and p.proname !~ '^_' and has_function_privilege('authenticated', p.oid, 'execute')),
    array['allows_all', 'can', 'current_subject_id', 'current_subject_type', 'denied_ids', 'denies_all',
          'has_permission', 'has_role', 'ids', 'scopes_with_permission'],
    'api: clients can execute these ten functions and no others');
set role authenticated;
select tap.throws_ok($$ select permissions.can_for('user', 'x', 'select', 'document', 'y') $$, '42501', 'api: clients cannot call can_for');
select tap.throws_ok($$ select permissions.grant_role('user', 'x', 'viewer', 'document', 'y') $$, '42501', 'api: or grant_role');
select tap.throws_ok($$ select permissions.who_can('select', 'document', 'y') $$, '42501', 'api: or who_can');
select tap.throws_ok($$ select permissions.apply_rls('public.documents', 'select', 'document') $$, '42501', 'api: or apply_rls');
select tap.throws_ok($$ select * from permissions.policies $$, '42501', 'api: and cannot read the tables');
reset role;

-- the trailing dummy argument
select tap.is(
    (select pg_get_expr(p.proargdefaults, 0) like '%permissions._unfolded_null()'
     from pg_proc p where p.oid = 'permissions.ids(text, text, text, jsonb)'::regprocedure),
    true, 'api: the last default of ids() is _unfolded_null()');
select tap.is(
    (select pg_get_expr(p.proargdefaults, 0) like '%permissions._unfolded_null()'
     from pg_proc p where p.oid = 'permissions.scopes_with_permission(text, jsonb)'::regprocedure),
    true, 'api: and of scopes_with_permission()');
select tap.is(
    (select array_agg(p.provolatile::text order by p.proname)
     from pg_proc p where p.oid in ('permissions.ids(text, text, text, jsonb)'::regprocedure,
                                    'permissions.denied_ids(text, text, text, jsonb)'::regprocedure,
                                    'permissions.can(text, text, text, jsonb)'::regprocedure)),
    array['s', 's', 's'], 'api: ids, denied_ids and can are STABLE');

-- facts
select tap.lives_ok($$ select permissions.define_role('document', 'viewer') $$, 'api: define_role is idempotent');
select tap.throws_ok($$ select permissions.define_role('document', 'owner', '{nonesuch}') $$, '22023', 'api: define_role with an undeclared implied role raises 22023');
select permissions.grant_role('user', :'frank', 'viewer', 'document', :'acme_plan', now() - interval '1 minute');
select tap.is(permissions.can_for('user', :'frank', 'select', 'document', :'acme_plan', jsonb_build_object('folder', :'plans')), false, 'api: an expired grant');
select permissions.grant_role('user', :'frank', 'viewer', 'document', :'acme_plan', null);
select tap.is(permissions.can_for('user', :'frank', 'select', 'document', :'acme_plan', jsonb_build_object('folder', :'plans')), true, 'api: grant_role again with a null date makes it permanent');
select tap.is(permissions.revoke_role('user', :'frank', 'viewer', 'document', :'acme_plan'), true, 'api: revoke_role');
select tap.lives_ok(format($$ select permissions.add_parent('team', %L, 'org', %L) $$, :'eng', :'acme'), 'api: add_parent');
select tap.lives_ok(format($$ select permissions.add_parent('team', %L, 'org', %L) $$, :'eng', :'acme'), 'api: add_parent is idempotent');
select tap.throws_ok($$ select permissions.add_parent('team', 'x', 'team', 'x') $$, '23514', 'api: add_parent of an entity to itself raises 23514');
select tap.is((select depth from permissions.closure where child_type = 'user' and child_id = :'dave' and ancestor_type = 'org' and ancestor_id = :'acme'), 2,
              'api: the closure view: Dave is two hops from acme (user -> team -> org)');
select permissions.remove_parent('team', :'eng', 'org', :'acme');
select permissions.set_attrs('user', :'gina', '{"a": 1}');
select permissions.set_attrs('user', :'gina', '{"b": 2}');
select tap.is((select attrs from permissions.entities where type = 'user' and id = :'gina'), '{"b": 2}'::jsonb, 'api: set_attrs replaces the whole object');

-- policies
select tap.ok(permissions.permit('probe policy', '{select}', 'probe', resource_id => 'p1') > 0, 'api: permit returns the policy id');
select tap.throws_ok($$ select permissions.permit('probe policy', '{select}', 'probe') $$, '23505', 'api: policy names are unique (23505)');
select tap.throws_ok($$ select permissions.permit('x', '{}', 'probe') $$, '23514', 'api: an empty action list raises 23514');
select tap.throws_ok($$ select permissions.permit('x', '{select}', 'probe', principal_in_type => 'team') $$, '23514', 'api: principal_in_type without principal_in_id raises 23514');
select tap.throws_ok($$ select permissions.permit('x', '{select}', 'document', roles => '{viewer}', via => 'org', resource_id => 'p1') $$, '22023', 'api: via and resource_id together raise 22023');
select tap.throws_ok($$ select permissions.permit('x', '{select}', 'document', roles => '{owner}') $$, '22023', 'api: a role that is not declared on the anchor type raises 22023');
select tap.is(permissions.can_for('user', 'u1', 'select', 'probe', 'p1'), true, 'api: a policy with no roles applies to every user');
select tap.is(permissions.can_for('service', 's1', 'select', 'probe', 'p1'), false, 'api: principal_type defaults to user, so a service is not covered');
select permissions.drop_policy('probe policy');
select permissions.permit('probe for services', '{select}', 'probe', resource_id => 'p1', principal_type => 'service');
select tap.is(permissions.can_for('service', 's1', 'select', 'probe', 'p1'), true, 'api: principal_type => service');
select tap.is(permissions.can_for('user', 'u1', 'select', 'probe', 'p1'), false, 'api: and users are not');
select permissions.drop_policy('probe for services');
select permissions.permit('probe for everyone', '{select}', 'probe');
select tap.is(
    (select array_agg(subject_type || '/' || subject_id || '/' || policy) from permissions.who_can('select', 'probe', 'p1')),
    array['*/*/probe for everyone'], 'api: who_can returns one wildcard row for a policy with no principal restriction');
select permissions.drop_policy('probe for everyone');

-- the list functions and the forbid side
select tap.set_eq(permissions.ids_for('user', :'gina', 'select', 'document', 'org', null), '{}',
                  'api: ids_for with no condition ignores conditioned policies');
select tap.set_eq(
    permissions.ids_for('user', :'gina', 'select', 'document', 'org',
                        '{"op": "==", "left": {"var": "resource.status"}, "right": "published"}'),
    array[:'acme'], 'api: ids_for with the condition lists the policies that have it');
select tap.is(permissions.allows_all_for('user', :'gina', 'select', 'document'), false, 'api: allows_all_for without an allow-all permit');
select permissions.forbid('block gina', '{select}', 'document', principal_id => :'gina');
select permissions.forbid('block frank on plan', '{select}', 'document', resource_id => :'acme_plan', principal_id => :'frank');
select tap.is(permissions.denies_all_for('user', :'gina', 'select', 'document'), true, 'api: denies_all_for: a forbid with no resource and no role');
select tap.is(permissions.denies_all_for('user', :'frank', 'select', 'document'), false, 'api: and for someone else');
select tap.set_eq(permissions.denied_ids_for('user', :'frank', 'select', 'document'), array[:'acme_plan'], 'api: denied_ids_for lists the forbidden resource ids');
set role authenticated;
select set_config('permissions.subject_id', :'frank', false);
select tap.set_eq(permissions.denied_ids('select', 'document'), array[:'acme_plan'], 'api: denied_ids for the current subject');
select tap.is(permissions.denies_all('select', 'document'), false, 'api: denies_all for the current subject');
select tap.is(permissions.allows_all('select', 'document'), false, 'api: allows_all for the current subject');
reset role;
select permissions.drop_policy('block gina');
select permissions.drop_policy('block frank on plan');

-- RLS tooling
select tap.ok(position('::bigint' in permissions.rls_expression('select', 'ticket', 'id', '{"org": "org_id"}', 'bigint'::regtype)) > 0,
              'api: rls_expression with id_type bigint casts to bigint');
select tap.throws_ok($$ select permissions.apply_rls('public.documents', 'truncate', 'document') $$, '22023', 'api: apply_rls accepts select, insert, update and delete only');
select tap.is(permissions.rls_expression('select', 'nothing_defined'),
$expr$(
    id = any (array(select unnest(permissions.ids('select', 'nothing_defined'))::uuid))
) and not (
    (select permissions.denies_all('select', 'nothing_defined'))
    or id = any (array(select unnest(permissions.denied_ids('select', 'nothing_defined'))::uuid))
)$expr$, 'api: rls_expression with no via columns has an id arm only');

-- rbac preset functions (the shared guide has the details)
select tap.throws_ok($$ select permissions.create_role('viewer', '{x.read}') $$, '23505', 'api: create_role of an existing role raises 23505');
select tap.throws_ok($$ select permissions.drop_role('viewer') $$, '2BP01', 'api: drop_role raises 2BP01 while another role inherits it');
select tap.throws_ok($$ select permissions.assign_role('u', 'nonesuch') $$, '22023', 'api: assign_role of an unknown role raises 22023');
select set_config('permissions.subject_id', :'frank', false);
select tap.is(permissions.has_permission('reports.read', :'acme'), false, 'api: has_permission is false for a subject with no role in the scope (Frank)');

-- ============================================================================
-- § 6 Gotchas and limits
-- ============================================================================

-- ids_for as a list is not net of folder or condition forbids; RLS is
select permissions.grant_role('user', :'frank', 'viewer', 'document', :'acme_readme');
select permissions.forbid('blocked folders', '{select}', 'document', roles => '{blocked}', via => 'folder');
select permissions.grant_role('user', :'frank', 'blocked', 'folder', :'specs');
select tap.ok(:'acme_readme' = any (permissions.ids_for('user', :'frank', 'select', 'document')), 'gotcha: ids_for still lists readme for Frank');
select tap.is(permissions.can_for('user', :'frank', 'select', 'document', :'acme_readme', jsonb_build_object('folder', :'specs')), false, 'gotcha: can() with the row says no');
set role authenticated;
select set_config('permissions.subject_id', :'frank', false);
select tap.set_eq(array(select title from public.documents), '{}', 'gotcha: and so does RLS');
reset role;
select permissions.drop_policy('blocked folders');
select permissions.revoke_role('user', :'frank', 'blocked', 'folder', :'specs');
select permissions.revoke_role('user', :'frank', 'viewer', 'document', :'acme_readme');

-- a row with a null parent column is hidden from anyone who has a forbid on that column's parents
\set orphan '00000000-0000-0000-0003-00000000000b'
insert into public.documents (id, org_id, title) values (:'orphan', :'acme', 'orphan');
select permissions.forbid('blocked folders', '{select}', 'document', roles => '{blocked}', via => 'folder');
select permissions.grant_role('user', :'frank', 'blocked', 'folder', :'specs');
select permissions.grant_role('user', :'frank', 'viewer', 'document', :'orphan');
select tap.is(permissions.can_for('user', :'frank', 'select', 'document', :'orphan', jsonb_build_object('folder', null, 'org', :'acme')), true,
              'gotcha: can() says Frank can view the orphan, which has no folder');
set role authenticated;
select set_config('permissions.subject_id', :'frank', false);
select tap.set_eq(array(select title from public.documents), '{}', 'gotcha: RLS hides it, because folder_id is null and the forbid side is "not null"');
reset role;
update public.documents set folder_id = :'plans' where id = :'orphan';
set role authenticated;
select tap.set_eq(array(select title from public.documents), '{orphan}', 'gotcha: with a folder it is visible again');
reset role;
select permissions.drop_policy('blocked folders');
select permissions.revoke_role('user', :'frank', 'blocked', 'folder', :'specs');
select permissions.delete_entity('document', :'orphan');
delete from public.documents where id = :'orphan';

-- depth cap on delete: removing a shortcut can leave a path longer than 10, and the delete drops the pair
select permissions.add_parent('y', 'u', 'y', 'm1');
select permissions.add_parent('y', 'm1', 'y', 'm2');
select permissions.add_parent('y', 'm2', 'y', 'm3');
select permissions.add_parent('y', 'm3', 'y', 'm4');
select permissions.add_parent('y', 'm4', 'y', 't0');
select permissions.add_parent('y', 'u', 'y', 't0');
select permissions.add_parent('y', 't' || i, 'y', 't' || (i + 1)) from generate_series(0, 5) i;
select tap.is(permissions.is_in('y', 'u', 'y', 't6'), true, 'gotcha: u reaches t6 over the shortcut u -> t0');
select permissions.remove_parent('y', 'u', 'y', 't0');
select tap.is(
    permissions.is_in('y', 'u', 'y', 't0') and permissions.is_in('y', 'm1', 'y', 't6') and not permissions.is_in('y', 'u', 'y', 't6'),
    true, 'gotcha: after removing it u is still in t0 and m1 in t6, but u is no longer in t6 (its remaining path is 11 hops; known bug)');

select * from tap.finish();
