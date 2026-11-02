-- Goal: preset roles flow to per-object resources through parents (graduation)
-- Design C: a type may name the preset's `tenant` type as a parent. A folder
-- whose parent is a tenant inherits the roles assigned on that tenant through
-- "parent->documents.read". Defining or redefining `app` or `tenant` is still
-- refused.
\ir ../../fixtures/ids.sql
\ir ../../fixtures/rbac_roles.sql
\set specs '00000000-0000-0000-0005-000000000001'
\set plans '00000000-0000-0000-0005-000000000002'

select permissions.assign_role(:'alice', 'admin',  :'acme');
select permissions.assign_role(:'bob',   'viewer', :'globex');

select count(*) from permissions.apply_model($json$
{
  "types": {
    "folder": {
      "parent":      ["tenant"],
      "relations":   { "viewer": ["user"] },
      "permissions": { "documents.read": ["viewer", "parent->documents.read"] }
    }
  }
}
$json$);
select permissions.set_parent('folder', :'specs', 'tenant', :'acme');
select permissions.set_parent('folder', :'plans', 'tenant', :'globex');
select permissions.grant('folder', :'plans', 'viewer', 'user', :'dave');

select tap.plan(9);

select tap.is(permissions.can_for('user', :'alice', 'folder', :'specs', 'documents.read'), true, 'an acme admin reads an acme folder through its tenant parent');
select tap.is(permissions.can_for('user', :'alice', 'folder', :'plans', 'documents.read'), false, 'but not a globex folder');
select tap.is(permissions.can_for('user', :'bob', 'folder', :'plans', 'documents.read'), true, 'a globex viewer reads the globex folder');
select tap.is(permissions.can_for('user', :'bob', 'folder', :'specs', 'documents.read'), false, 'but not the acme folder');
select tap.is(permissions.can_for('user', :'dave', 'folder', :'plans', 'documents.read'), true, 'a direct folder grant still works');
select tap.is(permissions.can_for('user', :'dave', 'folder', :'specs', 'documents.read'), false, 'and says nothing about other folders');
select tap.set_eq(array(select x::text from unnest(permissions.accessible_for('user', :'alice', 'folder', 'documents.read')) x), array[:'specs'], 'accessible() lists the folders under the admin''s tenants');

select tap.throws_ok($$ select * from permissions.apply_model('{"types": {"tenant": {"relations": {"owner": ["user"]}}}}') $$, '22023', 'redefining tenant is refused');
select tap.throws_ok($$ select * from permissions.apply_model('{"types": {"app": {}}}') $$, '22023', 'redefining app is refused');

select * from tap.finish();
