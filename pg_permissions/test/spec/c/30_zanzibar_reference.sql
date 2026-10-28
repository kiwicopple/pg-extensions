-- Goal: the reference scenario (PLAN.md §5)
-- Design C's native API: apply_model (JSON model), grant, can_for, accessible_for,
-- who_can. Same scenario and assertions as a/30_zanzibar_reference.sql.
\ir ../../fixtures/ids.sql

select count(*) from permissions.apply_model($json$
{
  "types": {
    "user": { "principal": true },
    "team": { "relations": { "member": ["user", "team#member"] } },
    "org": {
      "relations":   { "owner": ["user"], "admin": ["user"], "member": ["user", "team#member"] },
      "implies":     { "owner": ["admin"], "admin": ["member"] },
      "permissions": { "edit_documents": ["admin"], "view_documents": ["member"] }
    },
    "document": {
      "relations": { "editor": ["user", "team#member"], "viewer": ["user", "team#member"] },
      "implies":   { "editor": ["viewer"] }
    }
  }
}
$json$);

select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'dave');
select permissions.grant('document', :'acme_readme', 'editor', 'user', :'bob');
select permissions.grant('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');

select tap.plan(14);

-- Can Bob update readme?
select tap.is(permissions.can_for('user', :'bob', 'document', :'acme_readme', 'editor'), true,  'Bob is an editor of readme');
select tap.is(permissions.can_for('user', :'bob', 'document', :'acme_readme', 'viewer'), true,  'editor implies viewer');
select tap.is(permissions.can_for('user', :'bob', 'document', :'acme_plan',   'viewer'), false, 'Bob has no access to other documents');
select tap.is(permissions.can_for('user', :'bob', 'org', :'acme', 'view_documents'),     false, 'Bob is not in the org');

-- Which documents can Dave select?
select tap.set_eq(permissions.accessible_for('user', :'dave', 'document', 'viewer'), array[:'acme_readme']::uuid[], 'Dave can view readme through team eng');
select tap.set_eq(permissions.accessible_for('user', :'dave', 'document', 'editor'), '{}', 'but cannot edit anything');
select tap.set_eq(permissions.accessible_for('user', :'dave', 'org', 'view_documents'), '{}', 'and has no org-wide access');

-- Who can view readme?
select tap.set_eq(
    array(select permissions.who_can('document', :'acme_readme', 'viewer')),
    array[:'bob', :'carol', :'dave']::uuid[],
    'viewers of readme: Bob (editor), Carol and Dave (team eng)');

-- org roles
select tap.is(permissions.can_for('user', :'alice', 'org', :'acme', 'edit_documents'), true,  'org admins can edit documents');
select tap.is(permissions.can_for('user', :'alice', 'org', :'acme', 'view_documents'), true,  'admin implies member, so admins can view');
select tap.is(permissions.can_for('user', :'carol', 'org', :'acme', 'view_documents'), true,  'org members can view documents');
select tap.is(permissions.can_for('user', :'carol', 'org', :'acme', 'edit_documents'), false, 'org members cannot edit documents');

-- current-subject variants
select set_config('permissions.subject_id', :'dave', false);
select tap.is(permissions.can('document', :'acme_readme', 'viewer'), true, 'can() uses the current subject');
select tap.set_eq(permissions.accessible('document', 'viewer'), array[:'acme_readme']::uuid[], 'accessible() uses the current subject');

select * from tap.finish();
