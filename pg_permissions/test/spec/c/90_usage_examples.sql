-- Goal: every example with an observable result in research/prototypes/c-compiled-model.md
-- runs and gives the answer the guide states. This file mirrors that guide,
-- section by section (the "-- N.N" comments are the guide's section numbers).
-- Design C's native API. Each section starts from a clean model, so the
-- sections are independent of each other.
\ir ../../fixtures/ids.sql
\ir ../../fixtures/rbac_roles.sql
\set frank        '00000000-0000-0000-0001-000000000006'
\set announcement '00000000-0000-0000-0003-000000000005'
\set specs        '00000000-0000-0000-0005-000000000001'
\set plans        '00000000-0000-0000-0005-000000000002'

-- helpers (not in the guide) -------------------------------------------------
create function pg_temp.reset() returns void language plpgsql as $$
begin
    perform permissions.apply_model('{"types": {}}', p_force => true);
    drop table if exists public.documents, public.documents_b, public.documents_c, public.folders, public.shares, public.profiles, public.invoices, public.perm_keys cascade;
end $$;
create function pg_temp.raises(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
create function pg_temp.message_of(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return null; exception when others then return sqlerrm; end $$;
create function pg_temp.sqlstate_of(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return null; exception when others then return sqlstate; end $$;
-- not in pg_temp: the client role can't use the superuser's temp schema
create function public.titles(p_table text default 'documents') returns text[] language plpgsql as $$
declare r text[];
begin
    execute format('select coalesce(array_agg(title order by title), ''{}'') from public.%I', p_table) into r;
    return r;
end $$;
grant execute on function public.titles(text) to authenticated;

-- the quick-start model, kept in a table so later sections can re-apply it
create temp table qs as select $json$
{
  "types": {
    "user": { "principal": true },
    "team": { "relations": { "member": ["user", "team#member"] } },
    "org": {
      "relations":   { "admin": ["user"], "member": ["user"] },
      "implies":     { "admin": ["member"] },
      "permissions": { "edit_documents": ["admin"], "view_documents": ["member"] }
    },
    "document": {
      "relations":   { "editor": ["user", "team#member"], "viewer": ["user", "team#member"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "view": ["viewer"], "edit": ["editor"] }
    }
  }
}
$json$::jsonb as model;

select tap.plan(196);

-- ============================================================================
-- 2. Quick start
-- ============================================================================
create temp table qs_dry as select * from permissions.apply_model((select model from qs), p_dry_run => true);
select tap.ok(exists (select 1 from qs_dry where change = 'add type' and detail = 'document')
              and exists (select 1 from qs_dry where change = 'dry run')
              and not (permissions.model() -> 'types' ? 'document'),
              '2: a dry run returns the plan and changes nothing');

create temp table qs_plan as select * from permissions.apply_model((select model from qs));
select tap.ok((select change from qs_plan order by ctid desc limit 1) = 'version'
              and permissions.model() -> 'types' ? 'document',
              '2: apply_model compiles the model and records a version');
select tap.is((select change from permissions.apply_model((select model from qs))), 'unchanged',
              '2: applying the same model again is a no-op');

create table public.documents (id uuid primary key, org_id uuid not null, title text not null);
insert into public.documents values
    (:'acme_plan',    :'acme',   'acme plan'),
    (:'acme_readme',  :'acme',   'acme readme'),
    (:'globex_notes', :'globex', 'globex notes');
alter table public.documents enable row level security;
grant select, update on public.documents to authenticated;

create policy documents_select on public.documents for select to authenticated using (
    org_id = any ((select permissions.accessible('org', 'view_documents'))::uuid[])
    or id  = any ((select permissions.accessible('document', 'view'))::uuid[])
);
create policy documents_update on public.documents for update to authenticated using (
    org_id = any ((select permissions.accessible('org', 'edit_documents'))::uuid[])
    or permissions.can('document', id, 'edit')
);

select permissions.grant('org',      :'acme',        'admin',  'user', :'alice');
select permissions.grant('org',      :'acme',        'member', 'user', :'carol');
select permissions.grant('team',     :'eng',         'member', 'user', :'carol');
select permissions.grant('team',     :'eng',         'member', 'user', :'dave');
select permissions.grant('document', :'acme_readme', 'editor', 'user', :'bob');
select permissions.grant('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');

select tap.ok((select count(*) from permissions.tuples) = 6 and (select count(*) from permissions.memberships) = 2,
              '2: six grants and two membership rows (Carol and Dave in team eng)');
select tap.is(permissions.can_for('user', :'bob', 'document', :'acme_readme', 'edit'), true,  '2: Bob can edit readme');
select tap.is(permissions.can_for('user', :'bob', 'document', :'acme_plan',   'edit'), false, '2: Bob cannot edit the plan');
select tap.is(permissions.can_for('user', :'dave', 'document', :'acme_readme', 'view'), true,  '2: Dave can view readme through team eng');
select tap.is(permissions.can_for('user', :'dave', 'document', :'acme_readme', 'edit'), false, '2: but not edit it');
select tap.is(permissions.can_for('user', :'carol', 'org', :'acme', 'edit_documents'), false, '2: Carol, an org member, cannot edit org documents');

set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.is(public.titles(), '{"acme readme"}', '2: RLS as Dave: only readme');
select set_config('permissions.subject_id', :'bob', false);
select tap.is(public.titles(), '{"acme readme"}', '2: RLS as Bob: only readme');
select set_config('permissions.subject_id', :'alice', false);
select tap.is(public.titles(), '{"acme plan","acme readme"}', '2: RLS as Alice: every acme document');
select set_config('permissions.subject_id', :'carol', false);
select tap.is(public.titles(), '{"acme plan","acme readme"}', '2: RLS as Carol: every acme document');
select set_config('permissions.subject_id', :'erin', false);
select tap.is(public.titles(), '{}', '2: RLS as Erin: nothing');

select set_config('permissions.subject_id', :'bob', false);
with u as (update public.documents set title = 'readme v2' where id = :'acme_readme' returning 1)
select tap.is((select count(*)::int from u), 1, '2: Bob can update readme');
with u as (update public.documents set title = 'x' where id = :'acme_plan' returning 1)
select tap.is((select count(*)::int from u), 0, '2: Bob cannot update the plan (UPDATE 0)');
select set_config('permissions.subject_id', :'carol', false);
with u as (update public.documents set title = 'x' where id = :'acme_readme' returning 1)
select tap.is((select count(*)::int from u), 0, '2: Carol cannot update readme');
select set_config('permissions.subject_id', :'alice', false);
with u as (update public.documents set title = 'acme plan' where id = :'acme_plan' returning 1)
select tap.is((select count(*)::int from u), 1, '2: Alice can update the plan through the org arm');
reset role;
update public.documents set title = 'acme readme' where id = :'acme_readme';

select tap.set_eq(permissions.accessible_for('user', :'dave', 'document', 'view'), array[:'acme_readme']::uuid[],
                  '2: accessible_for(Dave) is readme');
select tap.set_eq(array(select permissions.who_can('document', :'acme_readme', 'view')), array[:'bob', :'carol', :'dave']::uuid[],
                  '2: who can view readme: Bob, Carol, Dave (the org arm lives in the policy, so Alice is not listed)');


-- ============================================================================
-- 3.1 Evolve the model safely
-- ============================================================================
-- add a relation: dry run first
create temp table ev_v1 as select permissions.model() as m;
select count(*) from permissions.apply_model(jsonb_set((select model from qs),
    '{types,document,relations,commenter}', '["user"]'), p_dry_run => true);
select tap.ok(permissions.model() = (select m from ev_v1), '3.1: a dry run leaves the active model alone');

create temp table ev_plan as select * from permissions.apply_model(
    jsonb_set(jsonb_set((select model from qs), '{types,document,relations,commenter}', '["user"]'),
              '{types,document,permissions,comment}', '["commenter", "editor"]'));
select tap.ok(exists (select 1 from ev_plan where (change, detail) = ('add relation', 'document.commenter'))
              and exists (select 1 from ev_plan where (change, detail) = ('add permission', 'document.comment'))
              and not exists (select 1 from ev_plan where change like 'rebuild%'),
              '3.1: adding a relation and a permission touches only catalog rows (no rebuild)');

-- removing a relation that has grants needs force
select permissions.grant('document', :'acme_readme', 'commenter', 'user', :'bob');
select tap.is(permissions.can_for('user', :'bob', 'document', :'acme_readme', 'comment'), true, '3.1: the new permission works');
select tap.throws_ok(format($$ select * from permissions.apply_model(%L) $$, (select model from qs)::text), '2BP01',
                     '3.1: removing a relation that has grants raises 2BP01 without force');
select tap.is(pg_temp.message_of(format($$ select * from permissions.apply_model(%L) $$, (select model from qs)::text)),
              'removing document.commenter would delete 1 tuples; pass force => true',
              '3.1: the 2BP01 message says how many grants force would delete');
create temp table ev_forced as select * from permissions.apply_model((select model from qs), p_force => true);
select tap.ok((select change from ev_forced order by ctid desc limit 1) = 'version'
              and not exists (select 1 from permissions.who_can('document', :'acme_readme', 'comment')),
              '3.1: with force the relation and its grants are gone');

-- what triggers a rebuild
create temp table ev_rb1 as select * from permissions.apply_model(
    jsonb_set((select model from qs), '{types,document,relations,viewer}', '["user", "team#member", "org#member"]'), p_dry_run => true);
create temp table ev_rb2 as select * from permissions.apply_model(
    jsonb_set((select model from qs), '{types,document,parent}', '["org"]'), p_dry_run => true);
select tap.ok(exists (select 1 from ev_rb1 where change = 'rebuild memberships')
              and not exists (select 1 from ev_rb1 where change = 'rebuild ancestors')
              and exists (select 1 from ev_rb2 where change = 'rebuild ancestors')
              and not exists (select 1 from ev_rb2 where change = 'rebuild memberships'),
              '3.1: a new userset rebuilds memberships; a new parent type rebuilds ancestors; a dry run only reports it');

-- versions and rollback
select tap.ok((select count(*) from permissions.models) >= 3
              and (select max(version) from permissions.models) > (select count(*) from permissions.models),
              '3.1: versions are recorded, and dry runs leave gaps in the numbering');
create temp table ev_old as select definition from permissions.models where version = (select max(version) from permissions.models) - 1;
select tap.ok(pg_temp.raises($$ select * from permissions.apply_model(permissions.model()) $$)
              and (select change from permissions.apply_model(
                       jsonb_set(permissions.model(), '{types}', (permissions.model() -> 'types') - 'app' - 'tenant'))) = 'unchanged',
              '3.1: model() includes the preset types, so strip app and tenant before passing it back');
select tap.throws_ok($$ select * from permissions.apply_model('{"types": {"tenant": {}}}') $$, '22023',
                     '3.1: defining the preset type tenant is refused');
-- roll back to the previous version (the one that still had document.commenter)
create temp table ev_roll as
select a.* from (select definition as d from permissions.models order by version desc offset 1 limit 1) old,
     lateral permissions.apply_model(jsonb_set(old.d, '{types}', (old.d -> 'types') - 'app' - 'tenant')) a;
select tap.ok((select change from ev_roll order by ctid desc limit 1) = 'version'
              and permissions.model() #> '{types,document,relations}' ? 'commenter',
              '3.1: an older version can be re-applied after stripping app and tenant');



-- ============================================================================
-- 3.2 Share one object
-- ============================================================================
select pg_temp.reset();
select count(*) from permissions.apply_model((select model from qs));
create table public.documents (id uuid primary key, org_id uuid not null, title text not null);
insert into public.documents values (:'acme_plan', :'acme', 'acme plan'), (:'acme_readme', :'acme', 'acme readme');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
create policy documents_select on public.documents for select to authenticated using (
    id = any ((select permissions.accessible('document', 'view'))::uuid[])
);

select permissions.grant('document', :'acme_plan', 'editor', 'user', :'erin');
select permissions.grant('team', :'eng', 'member', 'user', :'dave');
select permissions.grant('document', :'acme_plan', 'viewer', 'team', :'eng', 'member');
select tap.set_eq(array(select permissions.who_can('document', :'acme_plan', 'view')), array[:'erin', :'dave']::uuid[],
                  '3.2: a document shared with a user and a team: who_can lists both');
select tap.is(permissions.revoke('document', :'acme_plan', 'editor', 'user', :'erin'), true, '3.2: revoke returns true when a grant was removed');
select tap.is(permissions.revoke('document', :'acme_plan', 'editor', 'user', :'erin'), false, '3.2: and false when there was nothing to remove');
select permissions.grant('document', :'acme_plan', 'viewer', 'team', :'eng', 'member');   -- again: no error, no duplicate
select tap.is((select count(*)::int from permissions.who_can('document', :'acme_plan', 'view')), 1, '3.2: granting twice is harmless');

select tap.throws_ok(format($$ select permissions.grant('document', %L, 'view', 'user', %L) $$, :'acme_plan', :'erin'), '22023',
                     '3.2: granting a permission name raises 22023 (grant a relation)');
select tap.throws_ok(format($$ select permissions.grant('document', %L, 'viewer', 'org', %L) $$, :'acme_plan', :'acme'), '22023',
                     '3.2: granting to a subject type the relation does not accept raises 22023');
select tap.throws_ok(format($$ select permissions.grant('document', %L, 'owner', 'user', %L) $$, :'acme_plan', :'erin'), '22023',
                     '3.2: granting an unknown relation raises 22023');
select tap.is(pg_temp.message_of(format($$ select permissions.grant('document', %L, 'owner', 'user', %L) $$, :'acme_plan', :'erin')),
              'unknown relation document.owner', '3.2: the error names the relation');

-- let end users share, through a function that checks their own access first
create function public.share_document(p_doc uuid, p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = '' as $$
begin
    if not permissions.can('document', p_doc, 'edit') then
        raise exception 'you cannot share this document' using errcode = '42501';
    end if;
    if p_role not in ('viewer', 'editor') then
        raise exception 'unknown role %', p_role using errcode = '22023';
    end if;
    perform permissions.grant('document', p_doc, p_role, 'user', p_user);
end $$;
revoke all on function public.share_document(uuid, uuid, text) from public;
grant execute on function public.share_document(uuid, uuid, text) to authenticated;

select permissions.grant('document', :'acme_readme', 'editor', 'user', :'bob');
set role authenticated;
select set_config('permissions.subject_id', :'bob', false);
select tap.lives_ok(format($$ select public.share_document(%L, %L, 'viewer') $$, :'acme_readme', :'frank'), '3.2: Bob, an editor, can share readme');
select set_config('permissions.subject_id', :'frank', false);
select tap.is(public.titles(), '{"acme readme"}', '3.2: Frank now sees readme');
select tap.throws_ok(format($$ select public.share_document(%L, %L, 'viewer') $$, :'acme_readme', :'erin'), '42501',
                     '3.2: Frank, a viewer, cannot share it');
select tap.throws_ok(format($$ select permissions.grant('document', %L, 'viewer', 'user', %L) $$, :'acme_readme', :'erin'), '42501',
                     '3.2: and clients cannot call grant directly');
reset role;

-- ============================================================================
-- 3.3 Groups and nested teams
-- ============================================================================
select pg_temp.reset();
select count(*) from permissions.apply_model((select model from qs));
select permissions.grant('team', :'eng', 'member', 'user', :'dave');
select permissions.grant('team', :'platform', 'member', 'team', :'eng', 'member');
select permissions.grant('document', :'acme_plan', 'viewer', 'team', :'platform', 'member');
select tap.is(permissions.can_for('user', :'dave', 'document', :'acme_plan', 'view'), true,
              '3.3: Dave, in eng, reaches a document shared with platform, which eng is nested in');
select tap.is(permissions.can_for('user', :'dave', 'team', :'platform', 'member'), true, '3.3: and is a member of platform');
select permissions.revoke('team', :'platform', 'member', 'team', :'eng', 'member');
select tap.is(permissions.can_for('user', :'dave', 'document', :'acme_plan', 'view'), false, '3.3: un-nesting removes the inherited access');

-- cycles are accepted
select permissions.grant('team', :'platform', 'member', 'team', :'eng', 'member');
select permissions.grant('team', :'eng', 'member', 'team', :'platform', 'member');
select tap.ok(permissions.can_for('user', :'dave', 'team', :'platform', 'member')
              and not permissions.can_for('user', :'erin', 'team', :'platform', 'member')
              and (select count(*) = 0 from permissions.verify()),
              '3.3: a membership cycle is harmless');

-- the depth limit
select permissions.grant('team', md5('t1')::uuid, 'member', 'user', :'frank');
select permissions.grant('team', md5('t' || k)::uuid, 'member', 'team', md5('t' || (k - 1))::uuid, 'member')
from generate_series(2, 10) k;
select tap.is(pg_temp.sqlstate_of(format($$ select permissions.grant('team', %L, 'member', 'team', %L, 'member') $$,
                                          md5('t11')::uuid, md5('t10')::uuid)),
              '54001', '3.3: a chain of 10 levels is accepted, an 11th is rejected with 54001');

-- org members as a userset: model change, then one grant
select count(*) from permissions.apply_model(jsonb_set((select model from qs), '{types,document,relations}',
    '{"editor": ["user", "team#member"], "viewer": ["user", "team#member", "org#member"]}'));
select permissions.grant('org', :'acme', 'admin', 'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'user', :'carol');
select permissions.grant('document', :'acme_plan', 'viewer', 'org', :'acme', 'member');
select tap.ok(permissions.can_for('user', :'carol', 'document', :'acme_plan', 'view')
              and permissions.can_for('user', :'alice', 'document', :'acme_plan', 'view')
              and not permissions.can_for('user', :'bob', 'document', :'acme_plan', 'view'),
              '3.3: sharing with org#member reaches members and admins (admin implies member) but not outsiders');

-- ============================================================================
-- 3.4 Expiring grants
-- ============================================================================
select pg_temp.reset();
select count(*) from permissions.apply_model((select model from qs));
select permissions.grant('document', :'acme_plan', 'viewer', 'user', :'erin', null, now() + interval '7 days');
select tap.is(permissions.can_for('user', :'erin', 'document', :'acme_plan', 'view'), true, '3.4: before expiry the grant works');
select permissions.grant('document', :'acme_plan', 'viewer', 'user', :'erin', null, now() - interval '1 minute');
select tap.is(permissions.can_for('user', :'erin', 'document', :'acme_plan', 'view'), false, '3.4: after expiry it gives nothing');
select tap.ok(not exists (select 1 from permissions.who_can('document', :'acme_plan', 'view'))
              and permissions.accessible_for('user', :'erin', 'document', 'view') = '{}',
              '3.4: expired grants vanish from who_can and accessible too');
select permissions.grant('document', :'acme_plan', 'viewer', 'user', :'erin');
select tap.is(permissions.can_for('user', :'erin', 'document', :'acme_plan', 'view'), true, '3.4: granting again without a date makes it permanent');
select tap.is(pg_temp.sqlstate_of(format($$ select permissions.grant('team', %L, 'member', 'user', %L, null, now() + interval '1 day') $$, :'eng', :'dave')),
              '0A000', '3.4: a group membership cannot expire (0A000)');
select permissions.grant('org', :'acme', 'member', 'user', :'erin', null, now() + interval '1 day');
select tap.throws_ok(format($$ select * from permissions.apply_model(jsonb_set(%L::jsonb, '{types,document,relations,viewer}', '["user", "team#member", "org#member"]')) $$, (select model from qs)::text),
                     '22023', '3.4: a model change that would make an expiring grant feed a group raises 22023');
select permissions.revoke('org', :'acme', 'member', 'user', :'erin');
select permissions.grant('document', :'acme_plan', 'viewer', 'user', :'dave', null, now() - interval '1 day');
select tap.is((select count(*)::int from permissions.tuples where expires_at < now()), 1, '3.4: an expired grant stays in the tuples table');
delete from permissions.tuples where expires_at < now();
select tap.is((select count(*)::int from permissions.tuples where expires_at < now()), 0, '3.4: the owner can purge expired grants with a plain delete');
select tap.is((select count(*)::int from permissions.verify()), 0, '3.4: and verify() stays clean');


-- ============================================================================
-- 3.5 Parent inheritance
-- ============================================================================
select pg_temp.reset();
select count(*) from permissions.apply_model($json$
{
  "types": {
    "user": { "principal": true },
    "org": {
      "relations":   { "admin": ["user"], "member": ["user"] },
      "implies":     { "admin": ["member"] },
      "permissions": { "edit": ["admin"], "view": ["member"] }
    },
    "folder": {
      "parent":      ["org", "folder"],
      "relations":   { "editor": ["user"], "viewer": ["user"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "edit": ["editor", "parent->edit"], "view": ["viewer", "parent->view"] }
    },
    "document": {
      "parent":      ["folder", "org"],
      "relations":   { "editor": ["user"], "viewer": ["user"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "edit": ["editor", "parent->edit"], "view": ["viewer", "parent->view"] }
    }
  }
}
$json$);

create table public.documents (id uuid primary key, org_id uuid not null, folder_id uuid, title text not null);
alter table public.documents enable row level security;
grant select on public.documents to authenticated;

-- keep the engine's parent link in step with the app's own columns
create function public.documents_sync_parent() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
    if new.folder_id is not null then
        perform permissions.set_parent('document', new.id, 'folder', new.folder_id);
    else
        perform permissions.set_parent('document', new.id, 'org', new.org_id);
    end if;
    return null;
end $$;
create trigger documents_sync_parent after insert or update of folder_id, org_id on public.documents
    for each row execute function public.documents_sync_parent();

select permissions.set_parent('folder', :'specs', 'org', :'acme');
select permissions.set_parent('folder', :'plans', 'folder', :'specs');   -- folders nest
select permissions.set_parent('folder', :'plans', 'org', :'acme');       -- or move it back under the org
insert into public.documents (id, org_id, folder_id, title) values
    (:'acme_readme',  :'acme',   :'specs', 'readme'),
    (:'acme_plan',    :'acme',   :'plans', 'roadmap'),
    (:'globex_notes', :'globex', null,     'globex notes');

select permissions.grant('org',    :'acme',   'admin',  'user', :'alice');
select permissions.grant('org',    :'acme',   'member', 'user', :'carol');
select permissions.grant('org',    :'globex', 'member', 'user', :'frank');
select permissions.grant('folder', :'specs',  'viewer', 'user', :'erin');

-- shape 1: one branch, the engine does everything
create policy documents_select on public.documents for select to authenticated using (
    id = any ((select permissions.accessible('document', 'view'))::uuid[])
);

-- shape 2: two arms, shares by id plus the folders I can view (projected onto folder_id)
create table public.documents_b (like public.documents including all);
insert into public.documents_b select * from public.documents;
alter table public.documents_b enable row level security;
grant select on public.documents_b to authenticated;
create policy documents_select on public.documents_b for select to authenticated using (
    id        = any ((select permissions.accessible('document', 'viewer'))::uuid[])
    or folder_id = any ((select permissions.accessible('folder', 'view'))::uuid[])
);

-- shape 2 plus a third arm for documents that sit directly in an org
create table public.documents_c (like public.documents including all);
insert into public.documents_c select * from public.documents;
alter table public.documents_c enable row level security;
grant select on public.documents_c to authenticated;
create policy documents_select on public.documents_c for select to authenticated using (
    id        = any ((select permissions.accessible('document', 'viewer'))::uuid[])
    or folder_id = any ((select permissions.accessible('folder', 'view'))::uuid[])
    or org_id    = any ((select permissions.accessible('org', 'view'))::uuid[])
);

select tap.is(permissions.can_for('user', :'alice', 'document', :'acme_readme', 'edit'), true,  '3.5: an org admin can edit a document two levels down');
select tap.is(permissions.can_for('user', :'carol', 'document', :'acme_readme', 'view'), true,  '3.5: an org member can view it');
select tap.is(permissions.can_for('user', :'carol', 'document', :'acme_readme', 'edit'), false, '3.5: but not edit it');
select tap.is(permissions.can_for('user', :'erin',  'document', :'acme_readme', 'view'), true,  '3.5: a folder viewer can view the folder''s document');
select tap.is(permissions.can_for('user', :'erin',  'document', :'acme_plan',   'view'), false, '3.5: but not another folder''s');
select tap.set_eq(array(select permissions.who_can('document', :'acme_readme', 'view')), array[:'alice', :'carol', :'erin']::uuid[],
                  '3.5: who_can includes everyone who inherits access: Alice, Carol, Erin');

set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.is(public.titles('documents'), '{readme,roadmap}', '3.5: shape 1 as Alice');
select tap.is(public.titles('documents_c'), '{readme,roadmap}', '3.5: shape 2 + org arm as Alice');
select set_config('permissions.subject_id', :'carol', false);
select tap.is(public.titles('documents'), '{readme,roadmap}', '3.5: shape 1 as Carol');
select tap.is(public.titles('documents_b'), '{readme,roadmap}', '3.5: shape 2 as Carol (folder arm covers org roles)');
select set_config('permissions.subject_id', :'erin', false);
select tap.is(public.titles('documents'), '{readme}', '3.5: shape 1 as Erin');
select tap.is(public.titles('documents_b'), '{readme}', '3.5: shape 2 as Erin');
select tap.is(public.titles('documents_c'), '{readme}', '3.5: shape 2 + org arm as Erin');
select set_config('permissions.subject_id', :'frank', false);
select tap.is(public.titles('documents'), '{"globex notes"}', '3.5: shape 1 as Frank (document directly in an org)');
select tap.is(public.titles('documents_b'), '{}', '3.5: shape 2 misses a document that has no folder');
select tap.is(public.titles('documents_c'), '{"globex notes"}', '3.5: the org arm finds it');
reset role;

-- moving things
update public.documents set folder_id = :'plans' where id = :'acme_readme';
update public.documents_b set folder_id = :'plans' where id = :'acme_readme';
select tap.is(permissions.can_for('user', :'erin', 'document', :'acme_readme', 'view'), false,
              '3.5: moving a document (the trigger calls set_parent) changes who inherits access');
update public.documents set folder_id = :'specs' where id = :'acme_readme';
update public.documents_b set folder_id = :'specs' where id = :'acme_readme';
select tap.is(permissions.can_for('user', :'erin', 'document', :'acme_readme', 'view'), true, '3.5: and moving it back restores it');
select tap.is(permissions.unset_parent('document', :'acme_readme'), true, '3.5: unset_parent returns true when a link was removed');
select tap.is(permissions.can_for('user', :'carol', 'document', :'acme_readme', 'view'), false, '3.5: an object without a parent inherits nothing');
select tap.is(permissions.unset_parent('document', :'acme_readme'), false, '3.5: and false when there was no link');
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');

select permissions.set_parent('folder', :'plans', 'folder', :'specs');
select tap.is(permissions.can_for('user', :'erin', 'document', :'acme_plan', 'view'), true, '3.5: nest folder plans under specs: Erin now reaches its documents');
select tap.is(pg_temp.sqlstate_of(format($$ select permissions.set_parent('folder', %L, 'folder', %L) $$, :'specs', :'plans')),
              '23514', '3.5: a parent cycle is rejected with 23514');
select tap.is(pg_temp.sqlstate_of(format($$ select permissions.set_parent('document', %L, 'document', %L) $$, :'acme_readme', :'acme_plan')),
              '22023', '3.5: a parent of a type the model does not allow raises 22023');
select permissions.grant('folder', :'plans', 'viewer', 'user', :'erin');   -- later: let Erin be a plans viewer
select permissions.set_parent('folder', md5('f1')::uuid, 'org', :'acme');
select permissions.set_parent('folder', md5('f' || k)::uuid, 'folder', md5('f' || (k - 1))::uuid) from generate_series(2, 10) k;
select tap.is(pg_temp.sqlstate_of(format($$ select permissions.set_parent('folder', %L, 'folder', %L) $$, md5('f11')::uuid, md5('f10')::uuid)),
              '54001', '3.5: a chain deeper than 10 levels raises 54001');

-- a model that inherits only part of the way is rejected
select tap.throws_ok($$ select * from permissions.apply_model('{"types": {
        "org": {"relations": {"m": ["user"]}, "permissions": {"view": ["m"]}},
        "folder": {"parent": ["org"], "relations": {"v": ["user"]}, "permissions": {"read": ["v"]}},
        "document": {"parent": ["folder"], "relations": {"v": ["user"]}, "permissions": {"view": ["v", "parent->view"]}}}}') $$,
    '22023', '3.5: parent->view needs every parent type to define view');

-- the preset's tenant as a parent
select pg_temp.reset();
-- roles viewer, editor and admin exist (fixtures/rbac_roles.sql, loaded at the top)
select permissions.assign_role(:'alice', 'admin',  :'acme');
select permissions.assign_role(:'bob',   'viewer', :'globex');
select count(*) from permissions.apply_model($json$
{
  "types": {
    "folder": {
      "parent":      ["tenant"],
      "relations":   { "viewer": ["user"] },
      "permissions": { "documents.read": ["viewer", "parent->documents.read"] }
    },
    "document": {
      "parent":      ["folder"],
      "relations":   { "viewer": ["user"] },
      "permissions": { "documents.read": ["viewer", "parent->documents.read"] }
    }
  }
}
$json$);
select permissions.set_parent('folder', :'specs', 'tenant', :'acme');
select permissions.set_parent('folder', :'plans', 'tenant', :'globex');
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');
select permissions.set_parent('document', :'globex_notes', 'folder', :'plans');
select tap.is(permissions.can_for('user', :'alice', 'document', :'acme_readme', 'documents.read'), true,
              '3.5: an acme admin (a preset role on tenant acme) reads a document in an acme folder');
select tap.is(permissions.can_for('user', :'alice', 'document', :'globex_notes', 'documents.read'), false, '3.5: but not a globex one');
select tap.set_eq(permissions.accessible_for('user', :'bob', 'document', 'documents.read'), array[:'globex_notes']::uuid[],
                  '3.5: accessible() expands tenant roles to the documents below');
select tap.set_eq(array(select permissions.who_can('document', :'acme_readme', 'documents.read')), array[:'alice']::uuid[],
                  '3.5: who_can lists the preset role holders');


-- ============================================================================
-- 3.6 Public access
-- ============================================================================
select pg_temp.reset();
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
select permissions.grant('document', :'announcement', 'editor', 'user', :'bob');
select permissions.grant_public('document', :'announcement', 'viewer');

select tap.is(permissions.can_for('user', :'frank', 'document', :'announcement', 'view'), true, '3.6: Frank, who has no grants, can view the announcement');
select tap.is(permissions.can_for('user', :'frank', 'document', :'announcement', 'edit'), false, '3.6: but not edit it');
set role authenticated;
select set_config('permissions.subject_id', :'frank', false);
select tap.is(public.titles(), '{announcement}', '3.6: RLS as Frank: the announcement');
select set_config('permissions.subject_id', '', false);
select tap.is(public.titles(), '{}', '3.6: a request with no subject sees nothing, even public documents');
reset role;

select tap.set_eq(array(select permissions.who_can('document', :'announcement', 'view')), array[null, :'bob']::uuid[],
                  '3.6: who_can returns Bob and one null row meaning everyone');
select tap.ok((select :'frank'::uuid = any (array(select permissions.who_can('document', :'announcement', 'view')))) is null,
              '3.6: x = any(who_can(...)) is null, not true, for someone covered only by the public row');
select tap.ok(exists (select 1 from permissions.who_can('document', :'announcement', 'view') w where w is null)
              and not exists (select 1 from permissions.who_can('document', :'acme_readme', 'view') w where w is null),
              '3.6: test for the public row explicitly');
select tap.throws_ok(format($$ select permissions.grant('document', %L, 'viewer', 'user', null) $$, :'announcement'), '22004',
                     '3.6: grant() with a null subject raises 22004, it never means public');
select tap.throws_ok(format($$ select permissions.grant_public('document', %L, 'editor') $$, :'announcement'), '22023',
                     '3.6: grant_public on a relation that does not list user:* raises 22023');
select tap.is(permissions.revoke_public('document', :'announcement', 'viewer'), true, '3.6: revoke_public removes it');
select tap.is(permissions.can_for('user', :'frank', 'document', :'announcement', 'view'), false, '3.6: and Frank loses access');
select tap.throws_ok($$ select * from permissions.apply_model('{"types": {"team": {"relations": {"member": ["user", "user:*", "team#member"]}}}}', p_dry_run => true) $$,
                     '22023', '3.6: user:* on a relation that feeds a group is rejected when the model is applied');

-- ============================================================================
-- 3.7 Forbid with but_not
-- ============================================================================
select pg_temp.reset();
select count(*) from permissions.apply_model($json$
{
  "types": {
    "user": { "principal": true },
    "team": { "relations": { "member": ["user", "team#member"] } },
    "org": {
      "relations":   { "admin": ["user"], "member": ["user"] },
      "implies":     { "admin": ["member"] },
      "permissions": { "edit": ["admin"], "view": ["member"] }
    },
    "folder": {
      "parent":      ["org"],
      "relations":   { "editor": ["user", "team#member"], "viewer": ["user", "team#member"],
                       "blocked": ["user", "team#member"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": {
        "edit": { "any": ["editor", "parent->edit"], "but_not": ["blocked"] },
        "view": { "any": ["viewer", "parent->view"], "but_not": ["blocked"] }
      }
    },
    "document": {
      "parent":      ["folder", "org"],
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
create table public.documents (id uuid primary key, title text not null);
insert into public.documents values (:'acme_readme', 'readme'), (:'acme_plan', 'plan');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
create policy documents_select on public.documents for select to authenticated using (
    id = any ((select permissions.accessible('document', 'view'))::uuid[])
);
select permissions.set_parent('folder',   :'specs',      'org',    :'acme');
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');
select permissions.set_parent('document', :'acme_plan',   'org',    :'acme');
select permissions.grant('org', :'acme', 'admin', 'user', :'alice');
select permissions.grant('team', :'eng', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'dave');
select permissions.grant('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');

select tap.is(permissions.can_for('user', :'dave', 'document', :'acme_readme', 'view'), true, '3.7: before: Dave can view readme through eng');
select permissions.grant('document', :'acme_readme', 'blocked', 'user', :'dave');
select tap.is(permissions.can_for('user', :'dave', 'document', :'acme_readme', 'view'), false, '3.7: after a forbid on Dave: he cannot');
select tap.is(permissions.can_for('user', :'dave', 'document', :'acme_readme', 'viewer'), true,
              '3.7: the viewer relation itself is untouched; the forbid applies to the permission');
select tap.ok(not :'acme_readme' = any (permissions.accessible_for('user', :'dave', 'document', 'view')), '3.7: readme leaves Dave''s accessible() list');
select tap.set_eq(array(select permissions.who_can('document', :'acme_readme', 'view')), array[:'alice', :'carol']::uuid[],
                  '3.7: and Dave leaves who_can, while Carol (also in eng) stays');
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.is(public.titles(), '{}', '3.7: RLS as Dave: readme is hidden');
select tap.throws_ok(format($$ select permissions.grant('document', %L, 'blocked', 'user', %L) $$, :'acme_readme', :'carol'), '42501',
                     '3.7: clients cannot create forbids');
reset role;
select permissions.revoke('document', :'acme_readme', 'blocked', 'user', :'dave');
select tap.is(permissions.can_for('user', :'dave', 'document', :'acme_readme', 'view'), true, '3.7: revoking the forbid restores access');

select permissions.grant('document', :'acme_readme', 'blocked', 'user', :'alice');
select tap.ok(not permissions.can_for('user', :'alice', 'document', :'acme_readme', 'edit')
              and not permissions.can_for('user', :'alice', 'document', :'acme_readme', 'view')
              and permissions.can_for('user', :'alice', 'document', :'acme_plan', 'edit'),
              '3.7: a forbid beats access inherited from the org, on that document only');

select permissions.grant('document', :'acme_readme', 'blocked', 'team', :'eng', 'member');
select tap.ok(not permissions.can_for('user', :'carol', 'document', :'acme_readme', 'view')
              and not permissions.can_for('user', :'dave', 'document', :'acme_readme', 'view'),
              '3.7: a forbid can target a team: every member is blocked');

-- deny-overrides along the chain: a forbid on the folder blocks its documents
select pg_temp.reset();
select count(*) from permissions.apply_model($json$
{
  "types": {
    "user": { "principal": true },
    "folder": {
      "relations":   { "viewer": ["user"], "blocked": ["user"] },
      "permissions": { "view": { "any": ["viewer"], "but_not": ["blocked"] } }
    },
    "document": {
      "parent":      ["folder"],
      "relations":   { "viewer": ["user"] },
      "permissions": { "view": ["viewer", "parent->view"] }
    }
  }
}
$json$);
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');
select permissions.grant('document', :'acme_readme', 'viewer', 'user', :'erin');
select tap.is(permissions.can_for('user', :'erin', 'document', :'acme_readme', 'view'), true, '3.7: Erin is a direct viewer of readme');
select permissions.grant('folder', :'specs', 'blocked', 'user', :'erin');
select tap.is(permissions.can_for('user', :'erin', 'document', :'acme_readme', 'view'), false,
              '3.7: blocked on the folder, she loses the document even though her own grant is direct');

-- ============================================================================
-- 3.8 Conditions with RLS
-- ============================================================================
select pg_temp.reset();
select count(*) from permissions.apply_model($json$
{
  "types": {
    "org": {
      "relations":   { "admin": ["user"], "editor": ["user"], "member": ["user"] },
      "implies":     { "admin": ["editor"], "editor": ["member"] },
      "permissions": { "edit": ["editor"], "view": ["member"] }
    },
    "document": {
      "parent":      ["org"],
      "relations":   { "editor": ["user"], "viewer": ["user"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "edit": ["editor", "parent->edit"], "view": ["viewer", "parent->view"] }
    }
  }
}
$json$);
\set gina '00000000-0000-0000-0001-000000000007'
\set draft_doc '00000000-0000-0000-0003-000000000006'
create table public.documents (
    id uuid primary key, org_id uuid not null, title text not null,
    status text not null check (status in ('draft', 'published'))
);
insert into public.documents values
    (:'acme_readme', :'acme', 'readme', 'published'),
    (:'draft_doc',   :'acme', 'draft',  'draft');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
create policy documents_select on public.documents for select to authenticated using (
    id = any ((select permissions.accessible('document', 'edit'))::uuid[])
    or (status = 'published' and id = any ((select permissions.accessible('document', 'view'))::uuid[]))
);
select permissions.set_parent('document', :'acme_readme', 'org', :'acme');
select permissions.set_parent('document', :'draft_doc',   'org', :'acme');
select permissions.grant('org', :'acme', 'member', 'user', :'carol');
select permissions.grant('org', :'acme', 'editor', 'user', :'bob');
select permissions.grant('org', :'acme', 'member', 'user', :'gina', null, now() - interval '1 day');
set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.is(public.titles(), '{readme}', '3.8: a member sees published documents only');
select set_config('permissions.subject_id', :'bob', false);
select tap.is(public.titles(), '{draft,readme}', '3.8: an editor sees drafts too');
select set_config('permissions.subject_id', :'gina', false);
select tap.is(public.titles(), '{}', '3.8: a member whose grant has expired sees nothing');
reset role;
update public.documents set status = 'published' where id = :'draft_doc';
set role authenticated;
select set_config('permissions.subject_id', :'carol', false);
select tap.is(public.titles(), '{draft,readme}', '3.8: publishing the draft shows it to members, no engine call involved');
reset role;

-- ============================================================================
-- 3.9 Bulk loading with grant_many
-- ============================================================================
select pg_temp.reset();
select count(*) from permissions.apply_model((select model from qs));
select tap.is(permissions.grant_many('team', 'member', 'user',
                  array[:'eng', :'eng', :'eng']::uuid[], array[:'bob', :'carol', :'dave']::uuid[]),
              3::bigint, '3.9: grant_many returns the number of new grants');
select tap.is(permissions.grant_many('team', 'member', 'user',
                  array[:'eng', :'eng', :'eng']::uuid[], array[:'bob', :'carol', :'dave']::uuid[]),
              0::bigint, '3.9: running it again adds nothing');
create table public.shares (document_id uuid not null, user_id uuid not null);
insert into public.shares values (:'acme_plan', :'erin'), (:'acme_readme', :'erin'), (:'acme_readme', :'frank');
select tap.is((select permissions.grant_many('document', 'viewer', 'user', array_agg(document_id), array_agg(user_id)) from public.shares),
              3::bigint, '3.9: load a legacy sharing table in one call');
select tap.set_eq(permissions.accessible_for('user', :'erin', 'document', 'view'), array[:'acme_plan', :'acme_readme']::uuid[],
                  '3.9: the grants work');
select permissions.grant_many('team', 'member', 'team', array[:'platform']::uuid[], array[:'eng']::uuid[], 'member');
select tap.ok(permissions.can_for('user', :'bob', 'team', :'platform', 'member') and (select count(*) = 0 from permissions.verify()),
              '3.9: nestings load the same way (subject_relation is the last argument), and memberships stay consistent');
select tap.throws_ok(format($$ select permissions.grant_many('team', 'member', 'user', array[%L]::uuid[], '{}') $$, :'eng'), '22004',
                     '3.9: arrays of different lengths raise 22004');
select tap.throws_ok(format($$ select permissions.grant_many('team', 'member', 'user', array[%L, null]::uuid[], array[%L, %L]::uuid[]) $$, :'eng', :'bob', :'carol'), '22004',
                     '3.9: so do null elements');


-- ============================================================================
-- 3.10 Operations
-- ============================================================================
select pg_temp.reset();
select count(*) from permissions.apply_model((select model from qs));
select permissions.grant('team', :'eng', 'member', 'user', :'dave');
select permissions.grant('team', :'eng', 'member', 'user', :'carol');
select permissions.grant('team', :'platform', 'member', 'team', :'eng', 'member');
select tap.is((select count(*)::int from permissions.verify()), 0, '3.10: verify() returns no rows when nothing has drifted');

delete from permissions.memberships where principal_id = :'dave' and set_id = :'platform';   -- simulate drift
select tap.ok((select count(*) = 1 from permissions.verify())
              and exists (select 1 from permissions.verify()
                          where (kind, member_id, set_key, problem) = ('membership', :'dave'::uuid, 'team:' || :'platform' || '#member', 'missing')),
              '3.10: verify() names the principal, the group and the problem');
select tap.is(permissions.rebuild(), 4::bigint, '3.10: rebuild() recomputes everything and returns the number of rows written');
select tap.is((select count(*)::int from permissions.verify()), 0, '3.10: and verify() is clean again');

begin;
select permissions.grant('document', :'acme_plan', 'viewer', 'user', :'erin');
select tap.is((select count(*)::int from pg_locks where locktype = 'advisory' and classid = 1885697139 and objid = 1 and pid = pg_backend_pid()),
              0, '3.10: an object grant takes no lock');
select permissions.grant('team', :'eng', 'member', 'user', :'erin');
select tap.is((select count(*)::int from pg_locks where locktype = 'advisory' and classid = 1885697139 and objid = 1 and pid = pg_backend_pid() and granted),
              1, '3.10: a membership write holds the global advisory lock until the transaction ends');
commit;
select tap.is((select count(*)::int from pg_locks where locktype = 'advisory' and classid = 1885697139 and objid = 1 and pid = pg_backend_pid()),
              0, '3.10: the lock is gone after commit');

begin isolation level repeatable read;
select tap.is(pg_temp.sqlstate_of(format($$ select permissions.grant('team', %L, 'member', 'user', %L) $$, :'eng', :'frank')),
              '0A000', '3.10: repeatable read: a membership write raises 0A000');
select tap.lives_ok(format($$ select permissions.grant('document', %L, 'viewer', 'user', %L) $$, :'acme_plan', :'frank'),
                    '3.10: repeatable read: an object grant is fine');
commit;
begin isolation level serializable;
select tap.lives_ok(format($$ select permissions.grant('team', %L, 'member', 'user', %L) $$, :'eng', :'frank'),
                    '3.10: serializable: a membership write is allowed');
commit;
begin;
set transaction isolation level read committed;
select tap.lives_ok(format($$ select permissions.revoke('team', %L, 'member', 'user', %L) $$, :'eng', :'frank'),
                    '3.10: read committed: a membership write is allowed');
commit;

-- moving a leaf object is lock-free, moving a container is not (the model needs a parent type)
select pg_temp.reset();
select count(*) from permissions.apply_model($json$
{
  "types": {
    "user": { "principal": true },
    "folder": { "parent": ["folder"], "relations": { "viewer": ["user"] }, "permissions": { "view": ["viewer", "parent->view"] } },
    "document": { "parent": ["folder"], "relations": { "viewer": ["user"] }, "permissions": { "view": ["viewer", "parent->view"] } }
  }
}
$json$);
begin isolation level repeatable read;
select tap.lives_ok(format($$ select permissions.set_parent('document', %L, 'folder', %L) $$, :'acme_plan', :'specs'),
                    '3.10: repeatable read: moving a document is fine');
select tap.is(pg_temp.sqlstate_of(format($$ select permissions.set_parent('folder', %L, 'folder', %L) $$, :'plans', :'specs')),
              '0A000', '3.10: repeatable read: moving a folder raises 0A000');
commit;

-- ============================================================================
-- 3.11 Graduating from the rbac preset
-- ============================================================================
select pg_temp.reset();
select permissions.assign_role(:'alice', 'admin',  :'acme');
select permissions.assign_role(:'bob',   'editor', :'acme');
select permissions.assign_role(:'bob',   'viewer', :'globex');
create table public.documents (id uuid primary key, org_id uuid not null, title text not null);
insert into public.documents values
    (:'acme_plan', :'acme', 'acme plan'), (:'acme_readme', :'acme', 'acme readme'), (:'globex_notes', :'globex', 'globex notes');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
create policy documents_select on public.documents for select to authenticated using (
    permissions.has_permission('documents.read', org_id)
);
create temp table grad_before as
select u, s, permissions.user_permissions(u, s) as perms
from unnest(array[:'alice', :'bob']) u, unnest(array[:'acme', :'globex']) s;

select count(*) from permissions.apply_model($json$
{
  "types": {
    "document": {
      "relations": { "editor": ["user"], "viewer": ["user"] },
      "implies":   { "editor": ["viewer"] },
      "permissions": { "view": ["viewer"], "edit": ["editor"] }
    }
  }
}
$json$);
select permissions.grant('document', :'acme_readme', 'editor', 'user', :'dave');
drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
    or id  = any ((select permissions.accessible('document', 'view'))::uuid[])
);
select tap.is((select count(*)::int from grad_before b where b.perms is distinct from permissions.user_permissions(b.u, b.s)), 0,
              '3.11: every rbac answer is unchanged after adding the document type');
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.is(public.titles(), '{"acme readme"}', '3.11: Dave sees only the document shared with him');
select set_config('permissions.subject_id', :'bob', false);
select tap.is(public.titles(), '{"acme plan","acme readme","globex notes"}', '3.11: Bob still sees everything his roles allow');
reset role;

-- ============================================================================
-- 3.12 Cleaning up
-- ============================================================================
select pg_temp.reset();
select count(*) from permissions.apply_model($json$
{
  "types": {
    "user": { "principal": true },
    "team": { "relations": { "member": ["user", "team#member"] } },
    "folder": { "parent": ["folder"], "relations": { "viewer": ["user", "team#member"] }, "permissions": { "view": ["viewer", "parent->view"] } },
    "document": {
      "parent": ["folder"],
      "relations": { "viewer": ["user", "team#member"] }, "permissions": { "view": ["viewer", "parent->view"] }
    }
  }
}
$json$);
select permissions.grant('team', :'eng', 'member', 'user', :'erin');
select permissions.grant('document', :'acme_plan', 'viewer', 'user', :'erin');
select permissions.grant('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');
select tap.is(permissions.forget_subject(:'erin'), 2::bigint, '3.12: forget_subject returns how many grants it removed');
select tap.ok(permissions.accessible_for('user', :'erin', 'document', 'view') = '{}' and (select count(*) = 0 from permissions.verify()),
              '3.12: Erin has no access left, and her team membership is gone too');

select permissions.grant('team', :'eng', 'member', 'user', :'dave');
select tap.is(permissions.forget_object('team', :'eng'), 2::bigint,
              '3.12: forget_object on a team removes its members and the grants that named it');
select tap.ok(not permissions.can_for('user', :'dave', 'document', :'acme_readme', 'view') and (select count(*) = 0 from permissions.verify()),
              '3.12: and the access that went through it');

select permissions.set_parent('folder', :'specs', 'folder', :'plans');
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');
select permissions.grant('folder', :'plans', 'viewer', 'user', :'dave');
select tap.is(permissions.can_for('user', :'dave', 'document', :'acme_readme', 'view'), true, '3.12: before: Dave inherits through two folders');
select permissions.forget_object('folder', :'plans');
select tap.ok(not permissions.can_for('user', :'dave', 'document', :'acme_readme', 'view')
              and not exists (select 1 from permissions.parents p where p.parent_id = :'plans'),
              '3.12: forgetting a folder removes its grants; its children become roots');

create table public.profiles (id uuid primary key, name text);
create trigger profiles_permissions_cleanup after delete on public.profiles
    for each row execute function permissions.on_subject_deleted('id');
create table public.documents (id uuid primary key, title text);
create trigger documents_permissions_cleanup after delete on public.documents
    for each row execute function permissions.on_object_deleted('document', 'id');
insert into public.profiles values (:'frank', 'frank');
insert into public.documents values (:'acme_plan', 'plan');
select permissions.grant('document', :'acme_plan', 'viewer', 'user', :'frank');
delete from public.documents;
select tap.is((select count(*)::int from permissions.who_can('document', :'acme_plan', 'view')), 0, '3.12: deleting the row removes the object''s grants (on_object_deleted)');
select permissions.grant('document', :'acme_readme', 'viewer', 'user', :'frank');
delete from public.profiles;
select tap.is((select count(*)::int from permissions.who_can('document', :'acme_readme', 'view')), 0, '3.12: deleting the profile removes the user''s grants (on_subject_deleted)');

-- ============================================================================
-- 3.13 Non-uuid app keys
-- ============================================================================
select pg_temp.reset();
select count(*) from permissions.apply_model($json$
{
  "types": {
    "invoice": { "relations": { "viewer": ["user"] }, "permissions": { "view": ["viewer"] } }
  }
}
$json$);
create table public.invoices (
    id    bigint generated always as identity primary key,
    title text not null,
    uid   uuid generated always as (md5('invoice:' || id)::uuid) stored unique
);
insert into public.invoices (title) select 'invoice ' || i from generate_series(1, 3) i;
alter table public.invoices enable row level security;
grant select on public.invoices to authenticated;
create policy invoices_select on public.invoices for select to authenticated using (
    uid = any ((select permissions.accessible('invoice', 'view'))::uuid[])
);
select permissions.grant('invoice', md5('invoice:' || 2)::uuid, 'viewer', 'user', md5('user:' || 42)::uuid);
set role authenticated;
select set_config('permissions.subject_id', md5('user:' || 42)::uuid::text, false);
select tap.is(public.titles('invoices'), '{"invoice 2"}', '3.13: bigint keys, mapped to uuids with md5, work end to end');
select set_config('permissions.subject_id', md5('user:' || 42), false);
select tap.is(public.titles('invoices'), '{}', '3.13: plain md5() text has no dashes, so it is no subject: convert it with ::uuid::text');
select set_config('permissions.subject_id', '42', false);
select tap.is(public.titles('invoices'), '{}', '3.13: and neither is a bare bigint');
reset role;

create table public.perm_keys (key text primary key, id uuid not null unique default gen_random_uuid());
create function public.perm_id(p_key text) returns uuid language sql as $$
    insert into public.perm_keys (key) values (p_key) on conflict (key) do update set key = excluded.key returning id $$;
select tap.ok(public.perm_id('order:9') = public.perm_id('order:9') and public.perm_id('order:9') <> public.perm_id('order:10'),
              '3.13: a mapping table gives each key one stable uuid');


-- ============================================================================
-- 4. API reference
-- ============================================================================
select pg_temp.reset();
select count(*) from permissions.apply_model((select model from qs));

-- who can call what
select tap.set_eq(
    array(select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
          from pg_proc p where p.pronamespace = 'permissions'::regnamespace and p.proname !~ '^_'
            and has_function_privilege('authenticated', p.oid, 'execute')),
    array['accessible(p_object_type text, p_permission text)',
          'can(p_object_type text, p_object_id uuid, p_permission text)',
          'current_subject_id()', 'current_subject_type()',
          'has_permission(p_permission text, p_scope text)', 'has_permission(p_permission text, p_scope uuid)',
          'has_role(p_role text, p_scope text)', 'has_role(p_role text, p_scope uuid)',
          'scopes_with_permission(p_permission text, p_unfold boolean)'],
    '4: clients can execute exactly nine functions; the rest are admin-only');
select tap.is(
    (select count(distinct p.proname)::int from pg_proc p where p.pronamespace = 'permissions'::regnamespace and p.proname !~ '^_'),
    31, '4: the reference documents 31 public function names');

set role authenticated;
select tap.throws_ok($$ select * from permissions.apply_model('{"types": {}}') $$, '42501', '4: clients cannot call apply_model');
select tap.throws_ok(format($$ select permissions.can_for('user', %L, 'document', %L, 'view') $$, :'bob', :'acme_plan'), '42501', '4: nor can_for');
select tap.throws_ok(format($$ select * from permissions.who_can('document', %L, 'view') $$, :'acme_plan'), '42501', '4: nor who_can');
select tap.throws_ok($$ select * from permissions.verify() $$, '42501', '4: nor verify');
select tap.throws_ok($$ select count(*) from permissions.tuples $$, '42501', '4: clients cannot read the tables');
reset role;

-- identity
select set_config('permissions.subject_id', :'bob', false);
select tap.is(permissions.current_subject_id(), :'bob'::uuid, '4: current_subject_id() reads permissions.subject_id');
select set_config('request.jwt.claims', format('{"sub": "%s"}', :'carol'), false);
select tap.is(permissions.current_subject_id(), :'carol'::uuid, '4: the JWT sub wins over the setting');
select set_config('request.jwt.claims', '', false);
select set_config('permissions.subject_id', 'not-a-uuid', false);
select tap.is(permissions.current_subject_id(), null::uuid, '4: a value that is not a uuid is no subject');
select tap.is(permissions.current_subject_type(), 'user', '4: current_subject_type() defaults to user');

-- reads
select permissions.grant('org', :'acme', 'admin', 'user', :'alice');
select permissions.grant('document', :'acme_plan', 'editor', 'user', :'bob');
select set_config('permissions.subject_id', :'bob', false);
select tap.is(permissions.can('document', :'acme_plan', 'edit'), true, '4: can() checks the current subject');
select tap.is(permissions.can('document', :'acme_plan', 'viewer'), true, '4: can() accepts relations as well as permissions (editor implies viewer)');
select tap.is(permissions.can('document', :'acme_plan', 'nonsense'), false, '4: an unknown permission is false, not an error');
select tap.is(permissions.can('nonsense', :'acme_plan', 'edit'), false, '4: so is an unknown type');
select tap.set_eq(permissions.accessible('document', 'edit'), array[:'acme_plan']::uuid[], '4: accessible() lists the ids of the current subject');
select tap.is(permissions.accessible('document', 'nonsense'), '{}', '4: an unknown permission gives an empty array');
select tap.is(permissions.can_for('user', :'alice', 'org', :'acme', 'edit_documents'), true, '4: can_for() takes the subject explicitly');
select tap.is(permissions.can_for('user', null, 'org', :'acme', 'edit_documents'), false, '4: a null subject is false');
select set_config('permissions.subject_id', '', false);
select tap.is(permissions.can('document', :'acme_plan', 'edit'), false, '4: no subject, no access');

-- writes: the error messages and states the reference lists
select tap.is(pg_temp.sqlstate_of($$ select permissions.grant('nonsense', gen_random_uuid(), 'x', 'user', gen_random_uuid()) $$), '22023', '4: grant on an unknown type: 22023');
select tap.is(pg_temp.message_of(format($$ select permissions.grant('document', %L, 'view', 'user', %L) $$, :'acme_plan', :'erin')),
              'document.view is a permission; grant one of the relations that satisfy it', '4: the message for granting a permission');
select tap.is(pg_temp.message_of(format($$ select permissions.grant('document', %L, 'viewer', 'org', %L) $$, :'acme_plan', :'acme')),
              'document.viewer does not accept subjects of type org', '4: the message for a subject the relation does not accept');
select tap.is(pg_temp.sqlstate_of(format($$ select permissions.grant('document', null, 'viewer', 'user', %L) $$, :'erin')), '22004', '4: grant with a null id: 22004');
select tap.is(pg_temp.sqlstate_of(format($$ select permissions.set_parent('document', %L, 'org', %L) $$, :'acme_plan', :'acme')), '22023',
              '4: set_parent on a type that has no parent in the model: 22023');
select tap.is(pg_temp.sqlstate_of(format($$ insert into permissions.tuples (object_type, object_id, relation, subject_type, subject_id)
                                           select r.type_id, %L, r.id, r.type_id, %L from permissions.relations r
                                           join permissions.types t on t.id = r.type_id where t.name = 'team' and r.name = 'member' $$,
                                          :'eng', :'bob')), '23514',
              '4: even the owner cannot insert an ill-typed tuple: 23514');
select tap.is(pg_temp.sqlstate_of(format($$ update permissions.tuples set object_id = %L $$, :'eng')), '55000', '4: tuples cannot be updated in place: 55000');
select tap.is(pg_temp.sqlstate_of($$ truncate permissions.tuples $$), '55000', '4: or truncated: 55000');

-- model(): the active definition, including the preset types
select tap.ok(permissions.model() -> 'types' ?& array['app', 'tenant', 'user', 'document'], '4: model() returns the full active definition');
-- the SQLSTATE reference for model errors
select tap.is(pg_temp.sqlstate_of($$ select * from permissions.apply_model('{"types": {"doc": {"colour": "red"}}}') $$), '22023', '4: unknown key in a type: 22023');
select tap.is(pg_temp.sqlstate_of($$ select * from permissions.apply_model('{"types": {"Doc": {}}}') $$), '22023', '4: invalid type name: 22023');
select tap.is(pg_temp.sqlstate_of($$ select * from permissions.apply_model('{"types": {"doc": {"relations": {"a": ["user"]}, "permissions": {"a": ["a"]}}}}') $$), '22023',
              '4: a name that is both a relation and a permission: 22023');
select tap.is(pg_temp.sqlstate_of($$ select * from permissions.apply_model('{"types": {"doc": {"relations": {"a": ["org"]}}}}') $$), '22023',
              '4: a non-principal subject without #relation: 22023');
select tap.is(pg_temp.sqlstate_of($$ select * from permissions.apply_model('{"types": {"doc": {"relations": {"a": ["ghost"]}}}}') $$), '22023',
              '4: an unknown subject type: 22023');
select tap.is(pg_temp.sqlstate_of($$ select * from permissions.apply_model('{"types": {"doc": {"relations": {"a": ["user"]}, "permissions": {"p": ["a", "parent->p"]}}}}') $$), '22023',
              '4: parent->P on a type without parent: 22023');
select tap.is(pg_temp.sqlstate_of($$ select * from permissions.apply_model('{"types": {"doc": {"relations": {"a": ["user"]}, "permissions": {"p": []}}}}') $$), '22023',
              '4: a permission with nothing that grants it: 22023');
select tap.is(pg_temp.sqlstate_of($$ select * from permissions.apply_model('{"types": {"user": {}}}') $$), '22023', '4: user must be a principal: 22023');

-- preset functions
select permissions.create_role('temp_role', '{temp.perm}');
select permissions.assign_role(:'erin', 'temp_role', :'acme');
select tap.is(permissions.user_permissions(:'erin', :'acme'), array['temp.perm'], '4: create_role and assign_role, as in the shared guide (user_permissions)');
select tap.set_eq(array(select permissions.users_with_role('temp_role', :'acme')), array[:'erin'], '4: users_with_role');
select set_config('permissions.subject_id', :'erin', false);
select tap.is(permissions.has_permission('temp.perm', :'acme'), true, '4: has_permission with a text scope');
select tap.is(permissions.has_permission('temp.perm', :'acme'::uuid), true, '4: has_permission with a uuid scope (no cast needed in a policy)');
select tap.is(permissions.has_role('temp_role', :'acme'::uuid), true, '4: has_role');
select tap.is(permissions.scopes_with_permission('temp.perm'), array[:'acme'], '4: scopes_with_permission returns text[]');
select set_config('permissions.subject_id', '', false);
select permissions.unassign_role(:'erin', 'temp_role', :'acme');
select tap.is(permissions.user_permissions(:'erin', :'acme'), '{}', '4: unassign_role');
select permissions.drop_role('temp_role');
select tap.ok(not (permissions.model() #> '{types,app,relations}' ? 'temp_role'), '4: drop_role removes the role from the model');

select * from tap.finish();
