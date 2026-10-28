-- Goal: the reference scenario (PLAN.md §5)
-- Design B's native API: roles declared per resource type (define_role), facts
-- (grant_role, add_parent), and policies that say what the facts allow (permit).
-- Same scenario and assertions as a/30_zanzibar_reference.sql. A's org relations
-- edit_documents / view_documents are B policies with via => 'org'; "has
-- org-wide access" is the org-id projection ids_for(..., 'org').
\ir ../../fixtures/ids.sql

select permissions.define_role('org', 'member');
select permissions.define_role('org', 'admin', '{member}');
select permissions.define_role('org', 'owner', '{admin}');
select permissions.define_role('document', 'viewer');
select permissions.define_role('document', 'editor', '{viewer}');

select permissions.permit('org members view docs', '{select}',        'document', roles => '{member}', via => 'org');
select permissions.permit('org admins edit docs',  '{update,delete}', 'document', roles => '{admin}',  via => 'org');
select permissions.permit('doc viewers view',      '{select}',        'document', roles => '{viewer}');
select permissions.permit('doc editors edit',      '{update}',        'document', roles => '{editor}');

select permissions.grant_role('user', :'alice', 'admin',  'org', :'acme');
select permissions.grant_role('user', :'carol', 'member', 'org', :'acme');
select permissions.add_parent('user', :'carol', 'team', :'eng');
select permissions.add_parent('user', :'dave',  'team', :'eng');
select permissions.grant_role('user', :'bob',  'editor', 'document', :'acme_readme');
select permissions.grant_role('team', :'eng',  'viewer', 'document', :'acme_readme');

-- can_for's last argument is the row's attributes; RLS would pass documents.org_id as "org"
select tap.plan(14);

-- Can Bob update readme?
select tap.is(permissions.can_for('user', :'bob', 'update', 'document', :'acme_readme', jsonb_build_object('org', :'acme')), true,  'Bob is an editor of readme');
select tap.is(permissions.can_for('user', :'bob', 'select', 'document', :'acme_readme', jsonb_build_object('org', :'acme')), true,  'editor implies viewer');
select tap.is(permissions.can_for('user', :'bob', 'select', 'document', :'acme_plan',   jsonb_build_object('org', :'acme')), false, 'Bob has no access to other documents');
select tap.is(:'acme' = any (permissions.ids_for('user', :'bob', 'select', 'document', 'org')),        false, 'Bob is not in the org');

-- Which documents can Dave select?
select tap.set_eq(permissions.ids_for('user', :'dave', 'select', 'document'),        array[:'acme_readme'], 'Dave can view readme through team eng');
select tap.set_eq(permissions.ids_for('user', :'dave', 'update', 'document'),        '{}', 'but cannot edit anything');
select tap.set_eq(permissions.ids_for('user', :'dave', 'select', 'document', 'org'), '{}', 'and has no org-wide access');

-- Who can view readme? (its own grants, as in A; with the org passed in,
-- who_can also returns Alice and Carol through "org members view docs")
select tap.set_eq(
    array(select distinct subject_id from permissions.who_can('select', 'document', :'acme_readme') where subject_type = 'user'),
    array[:'bob', :'carol', :'dave'],
    'viewers of readme: Bob (editor), Carol and Dave (team eng)');

-- org roles
select tap.is(:'acme' = any (permissions.ids_for('user', :'alice', 'update', 'document', 'org')), true,  'org admins can edit documents');
select tap.is(:'acme' = any (permissions.ids_for('user', :'alice', 'select', 'document', 'org')), true,  'admin implies member, so admins can view');
select tap.is(:'acme' = any (permissions.ids_for('user', :'carol', 'select', 'document', 'org')), true,  'org members can view documents');
select tap.is(:'acme' = any (permissions.ids_for('user', :'carol', 'update', 'document', 'org')), false, 'org members cannot edit documents');

-- current-subject variants
select set_config('permissions.subject_id', :'dave', false);
select tap.is(permissions.can('select', 'document', :'acme_readme'), true, 'can() uses the current subject');
select tap.set_eq(permissions.ids('select', 'document'), array[:'acme_readme'], 'ids() uses the current subject');

select * from tap.finish();
