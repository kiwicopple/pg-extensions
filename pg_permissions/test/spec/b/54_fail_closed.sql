-- Goal: can() outside RLS fails closed when a forbid's inputs are missing (PLAN.md §10 G12, G13)
-- Design B: can() takes the row's parents and attributes in `resource`. A
-- forbid that could apply to the subject and reads a parent (via) or an
-- attribute (resource condition) the caller left out raises 22023 instead of
-- silently not matching. A key with a null value means "the row has none".
-- Parents that the parents table already knows (a folder's org) count as given.
-- Also: a key naming a principal type ({"user": <author>}) is an attribute, not
-- a parent, so the author's teams and orgs don't become the row's anchors.
\ir ../../fixtures/ids.sql
\set frank   '00000000-0000-0000-0001-000000000006'
\set specs   '00000000-0000-0000-0005-000000000001'
\set roadmap '00000000-0000-0000-0003-000000000004'
\set contractors '00000000-0000-0000-0004-000000000003'

select permissions.define_role('document', 'viewer');
select permissions.define_role('folder', 'blocked');
select permissions.define_role('org', 'member');
select permissions.define_role('org', 'blocked');

select permissions.permit('doc viewers view',      '{select}',  'document', roles => '{viewer}');
select permissions.permit('doc viewers comment',   '{comment}', 'document', roles => '{viewer}');
select permissions.permit('org members view docs', '{select}',  'document', roles => '{member}', via => 'org');
select permissions.forbid('blocked in folder', '{select}', 'document', roles => '{blocked}', via => 'folder');
select permissions.forbid('blocked in org',    '{select}', 'document', roles => '{blocked}', via => 'org');
select permissions.forbid('contractors never see archived', '{select}', 'document',
                          principal_in_type => 'team', principal_in_id => :'contractors',
                          condition => '{"op": "==", "left": {"var": "resource.status"}, "right": "archived"}');

select permissions.add_parent('folder', :'specs', 'org', :'acme');
select permissions.add_parent('user', :'erin', 'team', :'contractors');
select permissions.grant_role('user', :'bob',   'viewer',  'document', :'acme_readme');
select permissions.grant_role('user', :'dave',  'viewer',  'document', :'acme_readme');
select permissions.grant_role('user', :'erin',  'viewer',  'document', :'acme_readme');
select permissions.grant_role('user', :'frank', 'viewer',  'document', :'acme_readme');
select permissions.grant_role('user', :'carol', 'member',  'org',      :'acme');
select permissions.grant_role('user', :'dave',  'blocked', 'folder',   :'specs');
select permissions.grant_role('user', :'frank', 'blocked', 'org',      :'acme');
-- Alice is in team eng, which is in org acme (principal membership, not containment)
select permissions.add_parent('user', :'alice', 'team', :'eng');
select permissions.add_parent('team', :'eng', 'org', :'acme');

-- readme is in folder specs (in org acme) and is a draft
\set row '{"folder": "00000000-0000-0000-0005-000000000001", "status": "draft"}'

select tap.plan(16);

-- forbid via a parent (folder)
select tap.is(permissions.can_for('user', :'dave', 'select', 'document', :'acme_readme', :'row'), false,
              'Dave (blocked in folder specs) with the full row: denied');
select tap.throws_ok(format($$ select permissions.can_for('user', %L, 'select', 'document', %L, '{}') $$, :'dave', :'acme_readme'),
                     '22023', 'Dave without the folder: raises instead of allowing');
select tap.is(permissions.can_for('user', :'dave', 'select', 'document', :'acme_readme', '{"folder": null}'), true,
              'Dave on a row with no folder (explicit null): allowed');

-- forbid via a grandparent (org), resolved from the stored folder -> org edge
select tap.is(permissions.can_for('user', :'frank', 'select', 'document', :'acme_readme', :'row'), false,
              'Frank (blocked in org acme): the folder''s stored org counts, denied');
select tap.throws_ok(format($$ select permissions.can_for('user', %L, 'select', 'document', %L, '{"folder": null}') $$, :'frank', :'acme_readme'),
                     '22023', 'Frank with a null folder and no org: raises (a missing folder does not vouch for the org)');
select tap.is(permissions.can_for('user', :'frank', 'select', 'document', :'acme_readme', '{"folder": null, "org": null}'), true,
              'Frank on a row with neither folder nor org: allowed');

-- forbid with a resource condition (attribute)
select tap.is(permissions.can_for('user', :'erin', 'select', 'document', :'acme_readme',
                                  jsonb_set(:'row'::jsonb, '{status}', '"archived"')), false,
              'Erin (contractor) on an archived row: denied');
select tap.is(permissions.can_for('user', :'erin', 'select', 'document', :'acme_readme', :'row'), true,
              'Erin on a draft row: allowed');
select tap.throws_ok(format($$ select permissions.can_for('user', %L, 'select', 'document', %L, %L) $$,
                            :'erin', :'acme_readme', '{"folder": "' || :'specs' || '"}'),
                     '22023', 'Erin without the status: raises instead of allowing');

-- forbids that can't apply need no inputs
select tap.is(permissions.can_for('user', :'bob', 'select', 'document', :'acme_readme', '{}'), true,
              'Bob (no blocked role, not a contractor) without the row: still allowed');
select tap.is(permissions.can_for('user', :'dave', 'comment', 'document', :'acme_readme', '{}'), true,
              'Dave commenting (no forbid on comment) without the row: still allowed');

-- the current-subject variant
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select tap.throws_ok(format($$ select permissions.can('select', 'document', %L) $$, :'acme_readme'),
                     '22023', 'can() as Dave without the row: raises');
reset role;

-- who_can goes through the same matcher
select tap.throws_ok(format($$ select * from permissions.who_can('select', 'document', %L) $$, :'acme_readme'),
                     '22023', 'who_can without the row: raises');
select tap.set_eq(
    array(select distinct subject_id from permissions.who_can('select', 'document', :'acme_readme', :'row') where subject_type = 'user'),
    array[:'bob', :'carol', :'erin'],
    'who_can with the row: Bob, Carol and Erin; not Dave or Frank');

-- a principal-typed key is not a parent: {"user": alice} doesn't put roadmap in acme
select tap.is(permissions.can_for('user', :'carol', 'select', 'document', :'roadmap', jsonb_build_object('user', :'alice')), false,
              'Carol (acme member) on a row whose "user" attribute is Alice (in eng, in acme): not allowed');
select tap.is(permissions.can_for('user', :'carol', 'select', 'document', :'roadmap', jsonb_build_object('folder', :'specs', 'user', :'alice')), true,
              'with the row''s real folder (in acme): allowed');

select * from tap.finish();
