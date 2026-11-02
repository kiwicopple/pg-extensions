-- Goal: what is unique to Design C (research/designs/c-compiled-model.md §3, §10)
-- Materialized memberships and the ancestor closure stay correct through
-- nesting, un-nesting, removal and model changes; verify() finds drift and
-- rebuild() repairs it; the isolation rule and depth cap are enforced; the
-- compiler rejects bad models. White-box: reads permissions.* tables directly.
\ir ../../fixtures/ids.sql
\set frank  '00000000-0000-0000-0001-000000000006'
\set qa     '00000000-0000-0000-0004-000000000003'
\set allteam '00000000-0000-0000-0004-000000000004'
\set specs  '00000000-0000-0000-0005-000000000001'
\set plans  '00000000-0000-0000-0005-000000000002'
\set drafts '00000000-0000-0000-0005-000000000003'

\set model '{"types": {"team": {"relations": {"member": ["user", "team#member"]}}, "org": {"relations": {"admin": ["user"], "member": ["user", "team#member"]}}, "folder": {"parent": ["folder"], "relations": {"viewer": ["user", "team#member", "org#member"]}, "permissions": {"view": ["viewer", "parent->view"]}}, "document": {"parent": ["folder"], "relations": {"viewer": ["user", "team#member", "org#member"]}, "permissions": {"view": ["viewer", "parent->view"]}}}}'
select count(*) from permissions.apply_model(:'model');

create function pg_temp.teams_of(p uuid) returns uuid[] language sql as $$
    select coalesce(array_agg(m.set_id), '{}') from permissions.memberships m
    join permissions.types t on t.id = m.set_type where m.principal_id = p and t.name = 'team' $$;
create function pg_temp.raises(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;

select tap.plan(31);

-- ---- incremental maintenance -------------------------------------------
select permissions.grant('team', :'eng', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'dave');
select permissions.grant('team', :'platform', 'member', 'team', :'eng', 'member');
select tap.set_eq(pg_temp.teams_of(:'carol'), array[:'eng', :'platform']::uuid[], 'nesting eng into platform makes eng''s members members of platform');

select permissions.grant('team', :'allteam', 'member', 'team', :'platform', 'member');
select tap.is((select depth::int from permissions.memberships where principal_id = :'carol' and set_id = :'allteam'), 3,
              'a second level of nesting is recorded with its depth');

-- diamond: eng is also in qa, qa is in allteam
select permissions.grant('team', :'qa', 'member', 'team', :'eng', 'member');
select permissions.grant('team', :'allteam', 'member', 'team', :'qa', 'member');
select permissions.revoke('team', :'platform', 'member', 'team', :'eng', 'member');
select tap.set_eq(pg_temp.teams_of(:'dave'), array[:'eng', :'qa', :'allteam']::uuid[],
                  'un-nesting eng from platform drops platform but keeps allteam (still reachable through qa)');

select permissions.revoke('team', :'eng', 'member', 'user', :'carol');
select tap.set_eq(pg_temp.teams_of(:'carol'), '{}', 'removing a member removes every membership derived from it');
select tap.set_eq(pg_temp.teams_of(:'dave'), array[:'eng', :'qa', :'allteam']::uuid[], 'and leaves the other members alone');

select permissions.forget_object('team', :'qa');
select tap.set_eq(pg_temp.teams_of(:'dave'), array[:'eng']::uuid[], 'forget_object on a team removes the memberships that went through it');

-- org#member is a userset too; a direct org member is in it, an admin is not (yet)
select permissions.grant('org', :'acme', 'member', 'user', :'carol');
select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('document', :'acme_readme', 'viewer', 'org', :'acme', 'member');
select permissions.grant('team', :'platform', 'member', 'team', :'eng', 'member');

select tap.is((select count(*)::int from permissions.verify()), 0, 'verify() reports no drift after a series of writes');

-- ---- drift ---------------------------------------------------------------
select permissions.set_parent('folder', :'plans', 'folder', :'specs');
select permissions.set_parent('folder', :'drafts', 'folder', :'plans');
select permissions.set_parent('document', :'acme_plan', 'folder', :'drafts');

set session_replication_role = replica;   -- corrupt the derived tables directly
delete from permissions.memberships where principal_id = :'dave' and set_id = :'eng';
insert into permissions.memberships (principal_id, set_type, set_id, set_relation, depth)
select :'erin', set_type, set_id, set_relation, 1 from permissions.memberships where set_id = :'platform' limit 1;
delete from permissions.ancestors a using permissions.types t
where t.id = a.object_type and t.name = 'folder' and a.object_id = :'drafts' and a.ancestor_id = :'specs';
reset session_replication_role;

select tap.ok(exists (select 1 from permissions.verify() where kind = 'membership' and member_id = :'dave' and problem = 'missing'),
              'verify() detects a deleted membership row');
select tap.ok(exists (select 1 from permissions.verify() where kind = 'membership' and member_id = :'erin' and problem = 'extra'),
              'verify() detects a bogus membership row');
select tap.ok(exists (select 1 from permissions.verify() where kind = 'ancestor' and member_id = :'drafts' and problem = 'missing'),
              'verify() detects a deleted ancestor row');
select tap.is(permissions.can_for('user', :'erin', 'team', :'allteam', 'member'), true, '(and the bogus row is visible to checks: Erin looks like a member of allteam)');
select permissions.rebuild();
select tap.ok((select count(*) = 0 from permissions.verify())
              and not permissions.can_for('user', :'erin', 'team', :'allteam', 'member')
              and permissions.can_for('user', :'dave', 'team', :'allteam', 'member'),
              'rebuild() repairs all of it');

-- ---- ancestors: containers only ------------------------------------------
select permissions.grant('folder', :'specs', 'viewer', 'user', :'frank');
select tap.is(permissions.can_for('user', :'frank', 'document', :'acme_plan', 'view'), true, 'a viewer of specs can view a document two folders down');
select permissions.unset_parent('folder', :'plans');
select tap.ok(not permissions.can_for('user', :'frank', 'document', :'acme_plan', 'view')
              and not exists (select 1 from permissions.ancestors where object_id = :'drafts' and ancestor_id = :'specs'),
              'detaching a folder updates its sub-folders'' closure');
select tap.is((select count(*)::int from permissions.ancestors a join permissions.types t on t.id = a.object_type where t.name = 'document'), 0,
              'documents (leaf objects) have no closure rows: moving a folder never rewrites its documents');

-- ---- isolation rule --------------------------------------------------------
begin isolation level repeatable read;
select tap.throws_ok(format($$ select permissions.grant('team', %L, 'member', 'user', %L) $$, :'eng', :'erin'),
                     '0A000', 'a membership write is refused under repeatable read');
select tap.throws_ok(format($$ select permissions.set_parent('folder', %L, 'folder', %L) $$, :'plans', :'specs'),
                     '0A000', 'so is moving a container');
select tap.lives_ok(format($$ select permissions.grant('document', %L, 'viewer', 'user', %L) $$, :'acme_readme', :'erin'),
                    'an object grant is fine under repeatable read (no lock, nothing derived)');
commit;
begin isolation level serializable;
select tap.lives_ok(format($$ select permissions.grant('team', %L, 'member', 'user', %L) $$, :'eng', :'erin'),
                    'a membership write is allowed under serializable');
commit;

-- ---- write-time limits -----------------------------------------------------
select permissions.grant('team', md5('chain1')::uuid, 'member', 'user', :'frank');
select permissions.grant('team', md5('chain' || k)::uuid, 'member', 'team', md5('chain' || (k - 1))::uuid, 'member')
from generate_series(2, 10) k;
select tap.throws_ok(format($$ select permissions.grant('team', %L, 'member', 'team', %L, 'member') $$, md5('chain11')::uuid, md5('chain10')::uuid),
                     '54001', 'nesting deeper than 10 levels is rejected on write');
select tap.throws_ok(format($$ select permissions.grant('team', %L, 'member', 'user', %L, null, now() + interval '1 day') $$, :'eng', :'frank'),
                     '0A000', 'grants that change memberships cannot expire');
select tap.throws_ok(format($$ update permissions.tuples set subject_id = %L where subject_id = %L $$, :'bob', :'frank'),
                     '55000', 'tuples are immutable, even for the owner');
select tap.throws_ok($$ insert into permissions.tuples (object_type, object_id, relation, subject_type, subject_id)
                        select r.type_id, gen_random_uuid(), r.id, r.type_id, gen_random_uuid()
                        from permissions.relations r join permissions.types t on t.id = r.type_id
                        where t.name = 'team' and r.name = 'member' $$,
                     '23514', 'the triggers reject an ill-typed tuple, even from the owner');

-- ---- model changes and versions --------------------------------------------
select tap.is(permissions.can_for('user', :'alice', 'document', :'acme_readme', 'view'), false, 'before: an org admin is not in org#member');
create temp table plan as select * from permissions.apply_model(
    jsonb_set(:'model'::jsonb, '{types,org,implies}', '{"admin": ["member"]}'));
select tap.ok(exists (select 1 from plan where change = 'rebuild memberships')
              and permissions.can_for('user', :'alice', 'document', :'acme_readme', 'view')
              and (select count(*) = 0 from permissions.verify()),
              'after admin implies member, memberships are rebuilt and the admin can view');

create temp table v as select max(version) as n, permissions.model() as m from permissions.models;
select count(*) from permissions.apply_model(:'model', p_dry_run => true);
select tap.ok((select max(version) from permissions.models) = (select n from v) and permissions.model() = (select m from v)
              and permissions.can_for('user', :'alice', 'document', :'acme_readme', 'view'),
              'a dry run changes nothing and records no version');

select tap.throws_ok($$ select * from permissions.apply_model('{"types": {"team": {"relations": {"member": ["user", "team#member"]}}}}') $$,
                     '2BP01', 'removing types that still have grants needs force');
select tap.throws_ok($$ select * from permissions.apply_model('{"types": {"doc": {"relations": {"a": ["user"], "b": ["user"]}, "implies": {"a": ["b"], "b": ["a"]}}}}') $$,
                     '22023', 'an implies cycle is rejected');
select tap.ok(pg_temp.raises($$ select * from permissions.apply_model('{"types": {"folder": {"parent": ["org"], "relations": {"viewer": ["user"]}, "permissions": {"view": ["viewer", "parent->see"]}}, "org": {"relations": {"see": ["user"]}}}}') $$)
              and pg_temp.raises($$ select * from permissions.apply_model('{"types": {"org": {"relations": {"m": ["user"]}, "permissions": {"view": ["m"]}}, "folder": {"parent": ["org"], "relations": {"v": ["user"]}, "permissions": {"view": ["v"]}}, "document": {"parent": ["folder"], "relations": {"v": ["user"]}, "permissions": {"view": ["v", "parent->view"]}}}}') $$),
              'parent inheritance must use the same name, all the way up the hierarchy');
select tap.throws_ok($$ select * from permissions.apply_model('{"types": {"app": {}}}') $$, '22023', 'the rbac preset''s types are reserved');

-- ---- cleanup trigger ---------------------------------------------------------
create table public.documents (id uuid primary key, title text);
insert into public.documents values (:'acme_readme', 'readme');
create trigger documents_permissions_cleanup after delete on public.documents
    for each row execute function permissions.on_object_deleted('document', 'id');
delete from public.documents;
select tap.is((select count(*)::int from permissions.who_can('document', :'acme_readme', 'view')), 0,
              'on_object_deleted() removes an object''s grants when the app deletes the row');

select * from tap.finish();
