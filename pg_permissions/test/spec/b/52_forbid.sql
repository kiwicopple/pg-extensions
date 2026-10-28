-- Goal: forbid beats every permit, including parent-derived ones (PLAN.md §10 G12)
-- Design B: forbid policies have the same shape as permits; any matching
-- forbid makes the decision false (Cedar semantics, no priorities). RLS from
-- apply_rls has a deny side (denies_all / denied_ids), so the fast path honours forbids.
\ir ../../fixtures/ids.sql
\set specs   '00000000-0000-0000-0005-000000000001'
\set plans   '00000000-0000-0000-0005-000000000002'
\set roadmap '00000000-0000-0000-0003-000000000004'

select permissions.define_role('org', 'member');
select permissions.define_role('org', 'admin', '{member}');
select permissions.define_role('document', 'viewer');
select permissions.define_role('document', 'editor', '{viewer}');

select permissions.permit('org members view docs', '{select}',        'document', roles => '{member}', via => 'org');
select permissions.permit('org admins edit docs',  '{update,delete}', 'document', roles => '{admin}',  via => 'org');
select permissions.permit('doc viewers view',      '{select}',        'document', roles => '{viewer}');
select permissions.permit('doc editors edit',      '{update}',        'document', roles => '{editor}');

select permissions.add_parent('folder', :'specs', 'org', :'acme');
select permissions.add_parent('folder', :'plans', 'org', :'acme');
select permissions.grant_role('user', :'alice', 'admin',  'org', :'acme');
select permissions.grant_role('user', :'carol', 'member', 'org', :'acme');
select permissions.add_parent('user', :'carol', 'team', :'eng');
select permissions.add_parent('user', :'dave',  'team', :'eng');
select permissions.grant_role('user', :'bob', 'editor', 'document', :'acme_readme');
select permissions.grant_role('team', :'eng', 'viewer', 'document', :'acme_readme');

create table public.documents (id uuid primary key, org_id uuid not null, folder_id uuid, title text not null);
insert into public.documents values
    (:'acme_readme', :'acme', :'specs', 'readme'),
    (:'roadmap',     :'acme', :'plans', 'roadmap');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
select permissions.apply_rls('public.documents', 'select', 'document', 'id', '{"folder": "folder_id"}');

create function pg_temp.doc(p_id uuid) returns jsonb language sql as $$
    select jsonb_build_object('folder', folder_id) from public.documents where id = p_id
$$;

select tap.plan(9);

select tap.is(permissions.can_for('user', :'dave', 'select', 'document', :'acme_readme', pg_temp.doc(:'acme_readme')), true, 'before: Dave can view readme (team eng)');

select permissions.forbid('block dave on readme', '{select,update,delete}', 'document',
                          resource_id => :'acme_readme', principal_id => :'dave');
select tap.is(permissions.can_for('user', :'dave', 'select', 'document', :'acme_readme', pg_temp.doc(:'acme_readme')), false, 'after the forbid: Dave cannot');
select tap.ok(not (:'acme_readme' = any (permissions.ids_for('user', :'dave', 'select', 'document'))), 'readme is not in Dave''s list');
select tap.ok(
    (select not (:'dave' = any (s)) and :'carol' = any (s)
     from (select array(select subject_id from permissions.who_can('select', 'document', :'acme_readme', pg_temp.doc(:'acme_readme'))) s) x),
    'Dave is not in readme''s subject list; Carol still is');

set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.is((select count(*)::int from public.documents where id = :'acme_readme'), 0, 'RLS as Dave excludes readme');
reset role;

select permissions.forbid('block alice on readme', '{select,update}', 'document',
                          resource_id => :'acme_readme', principal_id => :'alice');
select tap.ok(
    not permissions.can_for('user', :'alice', 'update', 'document', :'acme_readme', pg_temp.doc(:'acme_readme'))
    and not permissions.can_for('user', :'alice', 'select', 'document', :'acme_readme', pg_temp.doc(:'acme_readme')),
    'a forbid on Alice beats her org admin access: she can neither edit nor view readme');
select tap.is(permissions.can_for('user', :'alice', 'update', 'document', :'roadmap', pg_temp.doc(:'roadmap')), true, 'Alice can still edit roadmap');

select permissions.drop_policy('block dave on readme');
select tap.is(permissions.can_for('user', :'dave', 'select', 'document', :'acme_readme', pg_temp.doc(:'acme_readme')), true, 'removing Dave''s forbid restores his access');

set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.throws_ok(format($$ select permissions.forbid('x', '{select}', 'document', resource_id => %L, principal_id => %L) $$, :'acme_readme', :'bob'),
                     '42501', 'clients cannot create forbids');
reset role;

select * from tap.finish();
