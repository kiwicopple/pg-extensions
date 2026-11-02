-- Goal: the Cedar current-subject helpers in real RLS policies
-- (research/plan-cedar.md, phase 5; research/designs/e-cedar.md sections 7
-- and 15). cedar_is_authorized_current decides per row for
-- current_subject_type()::"current_subject_id()" with an empty context;
-- resource_attrs from the row's columns replace the stored entity's attrs,
-- while its parents and tags come from storage; a forbid that holds or errs
-- denies (fail closed) where cedar_is_authorized would skip the error.
-- cedar_list_resources_current lists the stored entities the subject may
-- act on, the same set as per-row checks on those entities. No subject:
-- false or nothing, never an error. Cedar policies combine with rbac_* and
-- fga_* policies: permissive ones OR, a restrictive one ANDs. Neither helper
-- runs while a query is planned, and the statement-level work runs once per
-- statement.
\ir ../../fixtures/ids.sql
\ir ../../fixtures/d/rbac_roles.sql

-- The principal type is the subject type as it is: user (the default).
select permissions.cedar_put_entities(entities => jsonb_build_array(
    jsonb_build_object('uid', jsonb_build_object('type', 'Team', 'id', 'eng')),
    jsonb_build_object('uid', jsonb_build_object('type', 'Team', 'id', 'platform'), 'parents', '[{"type": "Team", "id": "eng"}]'::jsonb),
    jsonb_build_object('uid', jsonb_build_object('type', 'user', 'id', :'alice'), 'attrs', '{"level": 3}'::jsonb,
                       'parents', '[{"type": "Team", "id": "eng"}]'::jsonb),
    jsonb_build_object('uid', jsonb_build_object('type', 'user', 'id', :'bob'), 'attrs', '{"level": 1}'::jsonb),
    jsonb_build_object('uid', jsonb_build_object('type', 'user', 'id', :'carol'), 'attrs', '{"level": 2}'::jsonb,
                       'parents', '[{"type": "Team", "id": "platform"}]'::jsonb),
    jsonb_build_object('uid', jsonb_build_object('type', 'Folder', 'id', 'acme')),
    jsonb_build_object('uid', jsonb_build_object('type', 'Folder', 'id', 'globex'))));

create table public.documents (id uuid primary key, org_id uuid not null, folder text not null, owner uuid not null,
                               level int not null, title text not null);
insert into public.documents values
    (:'acme_plan',    :'acme',   'acme',   :'alice', 1, 'acme plan'),
    (:'acme_readme',  :'acme',   'acme',   :'bob',   3, 'acme readme'),
    (:'globex_notes', :'globex', 'globex', :'carol', 0, 'globex notes');
-- the app syncs its documents as entities: the folder as the parent, the
-- owner and the level as attrs; the first one also has a tag
select permissions.cedar_put_entities(entities => (
    select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'Document', 'id', d.id),
                                        'attrs', jsonb_build_object('owner', jsonb_build_object('__entity', jsonb_build_object('type', 'user', 'id', d.owner)),
                                                                    'level', d.level),
                                        'parents', jsonb_build_array(jsonb_build_object('type', 'Folder', 'id', d.folder)),
                                        'tags', case when d.title = 'acme plan' then '{"editable": "yes"}'::jsonb else '{}' end))
    from public.documents d));

select permissions.cedar_put_policy(policy_id => 'eng-acme',
    policy => 'permit (principal in Team::"eng", action == Action::"view", resource in Folder::"acme");');
select permissions.cedar_put_policy(policy_id => 'owner',
    policy => 'permit (principal, action == Action::"view", resource is Document) when { resource.owner == principal };');
select permissions.cedar_put_policy(policy_id => 'too-high',
    policy => 'forbid (principal, action == Action::"view", resource is Document) when { resource.level > principal.level };');
select permissions.cedar_put_template(template_id => 'share',
    template => 'permit (principal == ?principal, action == Action::"view", resource == ?resource);');
select permissions.cedar_link_template(policy_id => 'bob-globex', template_id => 'share',
    principal => 'user::"' || :'bob' || '"', resource => 'Document::"' || :'globex_notes' || '"');
-- dave is not a stored entity: too-high errs for him
select permissions.cedar_link_template(policy_id => 'dave-plan', template_id => 'share',
    principal => 'user::"' || :'dave' || '"', resource => 'Document::"' || :'acme_plan' || '"');
select permissions.cedar_put_policy(policy_id => 'tagged',
    policy => 'permit (principal, action == Action::"edit", resource) when { resource.hasTag("editable") };');

alter table public.documents enable row level security;
grant select, update on public.documents to authenticated;
-- per row, the row's owner and level as the resource's attributes
create policy documents_select on public.documents for select to authenticated using (
    permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || id || '"',
        resource_attrs => jsonb_build_object('owner', jsonb_build_object('__entity', jsonb_build_object('type', 'user', 'id', owner)),
                                             'level', level)));
create policy documents_update on public.documents for update to authenticated using (
    permissions.cedar_is_authorized_current('Action::"edit"', 'Document::"' || id || '"'));

-- the same visibility through the list, on a copy of the table
create table public.documents_listed as select * from public.documents;
alter table public.documents_listed enable row level security;
grant select on public.documents_listed to authenticated;
create policy documents_listed_select on public.documents_listed for select to authenticated using (
    id = any (array(select permissions.cedar_list_resources_current('Action::"view"', 'Document')::uuid)));

-- per-row checks of every stored document, without row attributes: what the list must equal
create function public.checked_ids() returns text[] language sql stable security definer as $$
    select coalesce(array_agg(e -> 'uid' ->> 'id' order by e -> 'uid' ->> 'id'), '{}')
    from jsonb_array_elements(permissions.cedar_read_entities(type => 'Document')) e
    where permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || (e -> 'uid' ->> 'id') || '"')
$$;
grant execute on function public.checked_ids() to authenticated;
-- rows updated, under the caller's RLS
create function public.touch(p_title text) returns int language plpgsql as $$
declare n int;
begin
    update public.documents set title = title where title = p_title;
    get diagnostics n = row_count;
    return n;
end $$;
grant execute on function public.touch(text) to authenticated;

select tap.plan(52);

-- the helpers are STABLE, security definer, and the per-row one has the plan-time guard
select tap.is((select array_agg(p.proname::text || ':' || p.provolatile::text || ':' || p.prosecdef::text order by p.proname) from pg_proc p
               where p.pronamespace = 'permissions'::regnamespace
                 and p.proname in ('cedar_is_authorized_current', 'cedar_list_resources_current')),
              '{cedar_is_authorized_current:s:true,cedar_list_resources_current:s:true}', 'both helpers are STABLE and security definer');
select tap.ok((select pg_get_function_arguments(p.oid) ~ 'plan_time_guard boolean DEFAULT permissions._unfolded_null\(\)' from pg_proc p
               where p.oid = 'permissions.cedar_is_authorized_current'::regproc), 'cedar_is_authorized_current has the plan-time guard');

set role authenticated;

-- alice: level 3, in eng
select set_config('permissions.subject_id', :'alice', false);
select tap.set_eq(array(select title from public.documents), '{acme plan,acme readme}',
                  'alice: the acme folder through Team::"eng" (resource in Folder), nothing too high');
select tap.set_eq(array(select title from public.documents_listed), '{acme plan,acme readme}', 'alice: the list sees the same');
select tap.is(array(select x from permissions.cedar_list_resources_current('Action::"view"', 'Document') x order by x),
              public.checked_ids(), 'alice: the list equals per-row checks of the stored documents');

-- carol: level 2, in platform under eng; owns globex notes; acme readme is too high
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.documents), '{acme plan,globex notes}',
                  'carol: acme through Team::"platform" in Team::"eng", her own document through resource_attrs, a forbid on acme readme');
select tap.set_eq(array(select title from public.documents_listed), '{acme plan,globex notes}', 'carol: the list sees the same');
select tap.is(array(select x from permissions.cedar_list_resources_current('Action::"view"', 'Document') x order by x),
              public.checked_ids(), 'carol: the list equals per-row checks');

-- bob: level 1, no team; a share of globex notes; owns acme readme, which is too high for him
select set_config('permissions.subject_id', :'bob', false);
select tap.set_eq(array(select title from public.documents), '{globex notes}', 'bob: the share (a template link), not his own document (forbidden)');
select tap.set_eq(array(select title from public.documents_listed), '{globex notes}', 'bob: the list sees the same');
select tap.is(array(select x from permissions.cedar_list_resources_current('Action::"view"', 'Document') x order by x),
              public.checked_ids(), 'bob: the list equals per-row checks');

-- dave: not stored; a share of acme plan, but the forbid errs for him (principal.level)
select set_config('permissions.subject_id', :'dave', false);
select tap.set_eq(array(select title from public.documents), '{}', 'dave: fail closed, the forbid errs, so his share does not count');
select tap.set_eq(array(select title from public.documents_listed), '{}', 'dave: the list fails closed too');
reset role;
select tap.is(permissions.cedar_is_authorized('user::"' || :'dave' || '"', 'Action::"view"', 'Document::"' || :'acme_plan' || '"')
                  -> 'decision', '"allow"', 'while cedar_is_authorized follows Cedar: the erring forbid is skipped');
set role authenticated;

-- resource_attrs replace the stored attrs; parents and tags still come from storage
select set_config('permissions.subject_id', :'alice', false);
select tap.is(permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || :'globex_notes' || '"'), false,
              'stored attrs: carol owns globex notes');
select tap.is(permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || :'globex_notes' || '"',
                  jsonb_build_object('owner', jsonb_build_object('__entity', jsonb_build_object('type', 'user', 'id', :'alice')), 'level', 0)), true,
              'resource_attrs replace them: alice owns it now');
select tap.is(permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || :'globex_notes' || '"', '{"level": 0}'), false,
              'replaced as a whole: no owner attribute now');
select tap.is(permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || :'acme_plan' || '"', '{"level": 9}'), false,
              'a row attribute can trigger a forbid that the stored attrs do not (level 9 > 3)');
select tap.is(permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || :'acme_plan' || '"', '{}'), false,
              'and a forbid that errs on a missing row attribute denies (fail closed)');
select tap.is(permissions.cedar_is_authorized_current('Action::"view"', 'Document::"not-stored"',
                  jsonb_build_object('owner', jsonb_build_object('__entity', jsonb_build_object('type', 'user', 'id', :'alice')), 'level', 0)), true,
              'a resource that is not stored counts, with those attrs');
select tap.is(permissions.cedar_is_authorized_current('Action::"view"', 'Document::"not-stored"', '{"level": 0}'), false,
              'and with no parents: not in Folder::"acme"');
select tap.is(permissions.cedar_is_authorized_current('Action::"edit"', 'Document::"' || :'acme_plan' || '"', '{"title": "x"}'), true,
              'the tags come from the stored entity');
select tap.is(permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || :'acme_plan' || '"', '{"level": 1.5}'), false,
              'an attribute Cedar cannot hold denies');
select tap.is(permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || :'acme_plan' || '"', '[1]'), false,
              'and so do resource_attrs that are not a record');
select tap.is((select count(*)::int from public.documents where title = 'acme plan'), 1, 'updates: alice sees acme plan');
select tap.is(public.touch('acme plan'), 1, 'and may update it: tagged editable (the edit policy)');
select tap.is(public.touch('acme readme'), 0, 'but not acme readme');

-- no subject: false and empty, never an error
select set_config('permissions.subject_id', '', false);
select tap.is((select count(*)::int from public.documents), 0, 'no subject: no rows');
select tap.is(permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || :'acme_plan' || '"'), false, 'no subject: false');
select tap.is((select count(*)::int from permissions.cedar_list_resources_current('Action::"view"', 'Document')), 0, 'no subject: an empty list');
-- the subject type is used as it is: Cedar's style User does not match the user entities
select set_config('permissions.subject_id', :'alice', false);
select set_config('permissions.subject_type', 'User', false);
select tap.is((select count(*)::int from public.documents), 0, 'subject type User: a different principal, no rows');
select set_config('permissions.subject_type', 'not a type', false);
select tap.is(permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || :'acme_plan' || '"'), false,
              'a subject type that is not a Cedar type name: false');
select set_config('permissions.subject_type', '', false);

-- mistakes in the policy text raise, like fga_check_current's unknown type
select tap.throws_ok($$ select permissions.cedar_is_authorized_current('view', 'Document::"x"') $$, '22023',
                     'an action that is not Type::"id" raises cedar:invalid_uid');
select tap.throws_ok($$ select permissions.cedar_is_authorized_current('Action::"view"', 'Document:x') $$, '22023',
                     'so does a resource');
select tap.throws_ok($$ select * from permissions.cedar_list_resources_current('Action::"view"', 'Document::"x"') $$, '22023',
                     'and a resource_type that is not a type name');

-- writes in the transaction are seen at once: the statement-level filter is not stale
begin;
reset role;
select permissions.cedar_link_template(policy_id => 'alice-globex', template_id => 'share',
    principal => 'user::"' || :'alice' || '"', resource => 'Document::"' || :'globex_notes' || '"');
set local role authenticated;
select array(select title from public.documents order by title)::text as after_link \gset
reset role;
select permissions.cedar_delete_policy(policy_id => 'alice-globex');
set local role authenticated;
select array(select title from public.documents order by title)::text as after_delete \gset
rollback;
select tap.is(:'after_link'::text, '{"acme plan","acme readme","globex notes"}', 'a share linked in this transaction counts in its next statement');
select tap.is(:'after_delete'::text, '{"acme plan","acme readme"}', 'and a deleted one stops counting');
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);

-- the statement-level cache is keyed by the settings the subject comes from:
-- one snapshot (repeatable read), two subjects, two answers; and the same
-- subject again reuses it
reset role;
begin isolation level repeatable read;
set local track_functions = 'all';
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select array(select title from public.documents order by title)::text as as_bob \gset
select set_config('permissions.subject_id', :'alice', true);
select array(select title from public.documents order by title)::text as as_alice \gset
select coalesce(pg_stat_get_xact_function_calls('permissions._cedar_current_filter'::regproc), 0) as ff0 \gset
select count(*) from public.documents;
select coalesce(pg_stat_get_xact_function_calls('permissions._cedar_current_filter'::regproc), 0) as ff1 \gset
commit;
select tap.is(:'as_bob'::text, '{"globex notes"}', 'one snapshot: bob sees his share');
select tap.is(:'as_alice'::text, '{"acme plan","acme readme"}', 'then alice, in the same snapshot, sees hers: the key holds the subject');
select tap.is((:ff1 - :ff0)::bigint, 0::bigint, 'and her next statement in the snapshot reuses the cached part');

-- combined with rbac_* and fga_*: permissive policies OR, a restrictive one ANDs
select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "document", "relations": {"viewer": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]}$m$::jsonb) is not null as model;
select permissions.fga_write_tuple('user:' || :'bob', 'viewer', 'document:' || :'acme_plan');
select permissions.rbac_assign_role(:'alice', 'viewer', :'acme');
select permissions.rbac_assign_role(:'alice', 'viewer', :'globex');
select permissions.rbac_assign_role(:'bob', 'viewer', :'globex');
select permissions.cedar_put_policy(policy_id => 'enter',
    policy => 'permit (principal, action == Action::"enter", resource is Org);');
select permissions.cedar_put_policy(policy_id => 'globex-senior',
    policy => format('forbid (principal, action == Action::"enter", resource == Org::"%s") when { principal.level < 2 };', :'globex'));
create table public.notes (id uuid primary key, org_id uuid not null, title text not null);
insert into public.notes select id, org_id, title from public.documents;
alter table public.notes enable row level security;
grant select on public.notes to authenticated;
create policy notes_rbac on public.notes for select to authenticated
    using (org_id = any (array(select unnest(permissions.rbac_scopes_with_permission('documents.read'))::uuid)));
create policy notes_fga on public.notes for select to authenticated
    using (id = any (array(select permissions.fga_list_object_ids_current('document', 'viewer')::uuid)));
create policy notes_cedar on public.notes as restrictive for select to authenticated
    using (permissions.cedar_is_authorized_current('Action::"enter"', 'Org::"' || org_id || '"'));
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.set_eq(array(select title from public.notes), '{acme plan,acme readme,globex notes}',
                  'alice: rbac in both orgs, and Cedar lets her enter both');
select set_config('permissions.subject_id', :'bob', false);
select tap.set_eq(array(select title from public.notes), '{acme plan}',
                  'bob: rbac in globex or his FGA share, AND Cedar: the forbid keeps him out of globex');
select set_config('permissions.subject_id', :'carol', false);
select tap.set_eq(array(select title from public.notes), '{}', 'carol: Cedar alone is restrictive, so it grants nothing');
select set_config('permissions.subject_id', :'alice', false);

-- parity: cedar_is_authorized_current equals cedar_is_authorized with the
-- fail-closed rule (allow, and no forbid in errors), for every subject,
-- document and action here; audit has is ... in scopes, a forbid without
-- conditions and a permit for any resource with a condition; bulk has 120
-- permits with conditions, more than the statement-level part keeps, so its
-- rows are checked from scratch
reset role;
select permissions.cedar_put_policy(policy_id => 'audit-eng',
    policy => 'permit (principal is user in Team::"eng", action == Action::"audit", resource is Document in Folder::"acme");');
select permissions.cedar_put_policy(policy_id => 'audit-not-readme',
    policy => format('forbid (principal, action == Action::"audit", resource == Document::"%s");', :'acme_readme'));
select permissions.cedar_put_policy(policy_id => 'audit-level-0',
    policy => 'permit (principal, action == Action::"audit", resource) when { resource has level && resource.level == 0 };');
select permissions.cedar_put_policy(policy_id => 'bulk-' || n,
    policy => format('permit (principal, action == Action::"bulk", resource is Document) when { resource.level == %s && principal.level >= 0 };', n))
from generate_series(0, 119) n;
select permissions.cedar_put_policy(policy_id => 'bulk-low',
    policy => 'forbid (principal, action == Action::"bulk", resource) when { principal.level < 2 };');
create temp table parity (subject text, action text, resource text, got boolean, want boolean);
create temp table full_checks (action text, n bigint);
set track_functions = 'all';
do $$
declare
    u text; act text; r text; want jsonb; c0 bigint;
begin
    foreach u in array array['00000000-0000-0000-0001-000000000001', '00000000-0000-0000-0001-000000000002',
                             '00000000-0000-0000-0001-000000000003', '00000000-0000-0000-0001-000000000004',
                             '00000000-0000-0000-0001-000000000005'] loop
        perform set_config('permissions.subject_id', u, true);
        foreach act in array array['view', 'edit', 'audit', 'bulk'] loop
            c0 := coalesce(pg_stat_get_xact_function_calls('permissions._cedar_current_check'::regproc), 0);
            foreach r in array array['00000000-0000-0000-0003-000000000001', '00000000-0000-0000-0003-000000000002',
                                     '00000000-0000-0000-0003-000000000003', 'not-stored'] loop
                want := permissions.cedar_is_authorized('user::"' || u || '"', 'Action::"' || act || '"', 'Document::"' || r || '"');
                insert into parity values (u, act, r,
                    permissions.cedar_is_authorized_current('Action::"' || act || '"', 'Document::"' || r || '"'),
                    want ->> 'decision' = 'allow' and not exists (
                        select 1 from jsonb_array_elements(want -> 'errors') e
                        join permissions.cedar_policies() p on p.policy_id = e ->> 'policy_id' where p.effect = 'forbid'));
            end loop;
            insert into full_checks values (act, coalesce(pg_stat_get_xact_function_calls('permissions._cedar_current_check'::regproc), 0) - c0);
        end loop;
    end loop;
end $$;
select tap.is((select array_agg(format('%s %s %s: %s', subject, action, resource, got)) from parity where got is distinct from want),
              null, 'parity with cedar_is_authorized and the fail-closed rule: 5 subjects x 4 actions x 4 documents');
select tap.ok((select count(*) filter (where want) > 4 and count(*) filter (where not want) > 4 from parity),
              'and the comparison has both answers');
reset track_functions;
select tap.is((select array_agg(distinct action order by action) from full_checks where n > 0), '{bulk}',
              'only bulk''s rows are checked from scratch: its statement-level part would be too large to keep');
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);

-- once per statement: the filter is computed once for a select of every row
reset role;
create table public.many as select g, 'd' || g as id from generate_series(1, 200) g;
alter table public.many enable row level security;
grant select on public.many to authenticated;
create policy many_select on public.many for select to authenticated
    using (permissions.cedar_is_authorized_current('Action::"view"', 'Page::"' || id || '"'));
begin;
set local track_functions = 'all';
set local role authenticated;
select set_config('permissions.subject_id', :'alice', true);
select coalesce(pg_stat_get_xact_function_calls('permissions._cedar_current_filter'::regproc), 0) as f0,
       coalesce(pg_stat_get_xact_function_calls('permissions._cedar_current_check'::regproc), 0) as k0 \gset
select count(*) from public.many;
select coalesce(pg_stat_get_xact_function_calls('permissions._cedar_current_filter'::regproc), 0) as f1,
       coalesce(pg_stat_get_xact_function_calls('permissions._cedar_current_check'::regproc), 0) as k1 \gset
commit;
select tap.is((:f1 - :f0)::bigint, 1::bigint, '200 rows: the statement-level filter runs once');
select tap.is((:k1 - :k0)::bigint, 0::bigint, 'and no row of many is in a permit''s scope, so no row is checked in full');

-- not at plan time: EXPLAIN (no ANALYZE) runs neither helper
create table public.orgs (id uuid primary key, title text not null);
insert into public.orgs values (:'acme', 'acme'), (:'globex', 'globex');
alter table public.orgs enable row level security;
grant select on public.orgs to authenticated;
-- a constant call: the plan-time guard keeps the planner from evaluating it
create policy orgs_select on public.orgs for select to authenticated
    using (permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || :'acme_plan' || '"'));
begin;
set local track_functions = 'all';
set local role authenticated;
select set_config('permissions.subject_id', :'alice', true);
select coalesce(pg_stat_get_xact_function_calls('permissions.cedar_is_authorized_current'::regproc), 0) as a0,
       coalesce(pg_stat_get_xact_function_calls('permissions.cedar_list_resources_current'::regproc), 0) as l0 \gset
do $$ declare l text; begin
    for l in execute 'explain (costs off) select * from public.orgs' loop null; end loop;
    for l in execute 'explain (costs off) select * from public.documents_listed' loop null; end loop;
end $$;
select coalesce(pg_stat_get_xact_function_calls('permissions.cedar_is_authorized_current'::regproc), 0) as a1,
       coalesce(pg_stat_get_xact_function_calls('permissions.cedar_list_resources_current'::regproc), 0) as l1 \gset
select count(*) from public.orgs;
select count(*) from public.documents_listed;
select coalesce(pg_stat_get_xact_function_calls('permissions.cedar_is_authorized_current'::regproc), 0) as a2,
       coalesce(pg_stat_get_xact_function_calls('permissions.cedar_list_resources_current'::regproc), 0) as l2 \gset
commit;
select tap.is((:a1 - :a0)::bigint, 0::bigint, 'cedar_is_authorized_current(constants): not executed while planning');
select tap.ok((:a2 - :a1)::bigint > 0, 'and executed when the query runs (the probe counts calls)');
select tap.is((:l1 - :l0)::bigint, 0::bigint, 'array(select cedar_list_resources_current(...)::uuid): not executed while planning');
select tap.is((:l2 - :l1)::bigint, 1::bigint, 'and executed once per query, not per row');

select * from tap.finish();
