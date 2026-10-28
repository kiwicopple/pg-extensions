-- Goal: the reference scenario (PLAN.md §5)
-- PROVISIONAL: the zanzibar-level API isn't settled. These tests use Design A's
-- function names (define_type, define_relation, grant, check_for, list_objects_for,
-- list_subjects). Update them when the engine is chosen; keep the assertions.
\ir ../../fixtures/ids.sql

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

select tap.plan(14);

-- Can Bob update readme?
select tap.is(permissions.check_for('user', :'bob', 'document', :'acme_readme', 'editor'), true,  'Bob is an editor of readme');
select tap.is(permissions.check_for('user', :'bob', 'document', :'acme_readme', 'viewer'), true,  'editor implies viewer');
select tap.is(permissions.check_for('user', :'bob', 'document', :'acme_plan',   'viewer'), false, 'Bob has no access to other documents');
select tap.is(permissions.check_for('user', :'bob', 'org', :'acme', 'view_documents'),     false, 'Bob is not in the org');

-- Which documents can Dave select?
select tap.set_eq(permissions.list_objects_for('user', :'dave', 'document', 'viewer'), array[:'acme_readme'], 'Dave can view readme through team eng');
select tap.set_eq(permissions.list_objects_for('user', :'dave', 'document', 'editor'), '{}', 'but cannot edit anything');
select tap.set_eq(permissions.list_objects_for('user', :'dave', 'org', 'view_documents'), '{}', 'and has no org-wide access');

-- Who can view readme?
select tap.set_eq(
    array(select subject_id from permissions.list_subjects('document', :'acme_readme', 'viewer') where subject_type = 'user'),
    array[:'bob', :'carol', :'dave'],
    'viewers of readme: Bob (editor), Carol and Dave (team eng)');

-- org roles
select tap.is(permissions.check_for('user', :'alice', 'org', :'acme', 'edit_documents'), true,  'org admins can edit documents');
select tap.is(permissions.check_for('user', :'alice', 'org', :'acme', 'view_documents'), true,  'admin implies member, so admins can view');
select tap.is(permissions.check_for('user', :'carol', 'org', :'acme', 'view_documents'), true,  'org members can view documents');
select tap.is(permissions.check_for('user', :'carol', 'org', :'acme', 'edit_documents'), false, 'org members cannot edit documents');

-- current-subject variants
select set_config('permissions.subject_id', :'dave', false);
select tap.is(permissions.check('document', :'acme_readme', 'viewer'), true, 'check() uses the current subject');
select tap.set_eq(permissions.list_objects('document', 'viewer'), array[:'acme_readme'], 'list_objects() uses the current subject');

select * from tap.finish();
