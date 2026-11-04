# Tenant-scoped roles

Give a user different permissions in different organizations. A scope is a text ID chosen by your application.

First complete the [RBAC setup](overview.md), using the same roles, IDs and app-wide assignments. The checks below need no application table. Keeping the app-wide assignments lets the examples demonstrate that scoped checks do not include them.

## Scenario 2: roles scoped to a tenant

This scenario uses the same roles, but assigns them for each organization. Alice is an admin of `acme`. Bob is an editor of `acme` and a viewer of `globex`. Assign the roles with a scope:

```js tab="JavaScript"
const assignedAcmeAdmin = await permissions.rbac.admin.assignRole({
  userId: alice,
  role: 'admin',
  scope: acme,
})
if (assignedAcmeAdmin.error) throw assignedAcmeAdmin.error
const assignedAcmeEditor = await permissions.rbac.admin.assignRole({
  userId: bob,
  role: 'editor',
  scope: acme,
})
if (assignedAcmeEditor.error) throw assignedAcmeEditor.error
const assignedGlobexViewer = await permissions.rbac.admin.assignRole({
  userId: bob,
  role: 'viewer',
  scope: globex,
})
if (assignedGlobexViewer.error) throw assignedGlobexViewer.error
```

```sql tab="SQL"
select permissions.rbac_assign_role(
  user_id => :'alice',
  role => 'admin',
  scope => :'acme'
);
select permissions.rbac_assign_role(
  user_id => :'bob',
  role => 'editor',
  scope => :'acme'
);
select permissions.rbac_assign_role(
  user_id => :'bob',
  role => 'viewer',
  scope => :'globex'
);
```

## Check scoped permissions

Check as Bob, passing the organization ID with each request. The SQL example sets his subject for the transaction.

```js tab="JavaScript"
const asBob = permissions.as({ id: bob })

const { data: editAcme } = await asBob.rbac.hasPermission({
  permission: 'documents.edit',
  scope: acme,
})
// true
const { data: editGlobex } = await asBob.rbac.hasPermission({
  permission: 'documents.edit',
  scope: globex,
})
// false
const { data: readGlobex } = await asBob.rbac.hasPermission({
  permission: 'documents.read',
  scope: globex,
})
// true
const { data: readScopes } = await asBob.rbac.scopesWithPermission({
  permission: 'documents.read',
})
// [acme, globex], as IDs
const { data: editScopes } = await asBob.rbac.scopesWithPermission({
  permission: 'documents.edit',
})
// [acme]
```

```sql tab="SQL"
begin;
select set_config('permissions.subject_id', :'bob', true);
select permissions.rbac_has_permission(
  permission => 'documents.edit',
  scope => :'acme'
);
-- true
select permissions.rbac_has_permission(
  permission => 'documents.edit',
  scope => :'globex'
);
-- false
select permissions.rbac_has_permission(
  permission => 'documents.read',
  scope => :'globex'
);
-- true
select permissions.rbac_scopes_with_permission(
  permission => 'documents.read'
);
-- {acme,globex}, as IDs
select permissions.rbac_scopes_with_permission(
  permission => 'documents.edit'
);
-- {acme}
commit;
```

For Carol, who holds a role app-wide only, `rbac_scopes_with_permission(permission => 'documents.read')` returns `{}`. The admin can ask about any user:

```js tab="JavaScript"
const bobInGlobex = await permissions.rbac.admin.userPermissions({
  userId: bob,
  scope: globex,
})
// bobInGlobex.data: ['documents.read']
// What can Bob do in globex?
const admins = await permissions.rbac.admin.usersWithRole({
  role: 'admin',
  scope: acme,
})
// admins.data: [alice]
// Who are the admins of acme?
```

```sql tab="SQL"
select permissions.rbac_user_permissions(
  user_id => :'bob',
  scope => :'globex'
);
-- {documents.read}: what can Bob do in globex?
select * from permissions.rbac_users_with_role(
  role => 'admin',
  scope => :'acme'
);
-- Alice: who are the admins of acme?
```

## Rules

- **Scopes are separate.** `rbac_has_permission(permission => p)` looks only at app-wide roles. With a `scope` argument, it looks only at that scope. No inheritance links them. To let app-wide roles work in a scope, write both checks. See [App-wide or scoped checks](../../rls/policies.md#app-wide-or-scoped-checks).
- **Unknown names return false.** An unknown permission or role in `rbac_has_permission` or `rbac_has_role` gives false, not an error. A policy that names a dropped permission denies access, and does not break each query.
- **No subject returns false.** `rbac_scopes_with_permission` returns an empty array in this case, not null.
- **Inheritance counts.** `rbac_has_role` is true for a role that the user holds directly or through inheritance. An editor has `viewer`. An editor does not have `admin`.
- **Only users hold roles.** The functions look at the subject of type `current_subject_type()`. With a subject type other than `user`, they return false.
- **Role names and permission names must not overlap.** A role cannot have the same name as a permission. A permission cannot have the same name as a role.

Examples of the answers, for Carol (a viewer) and Bob (an editor):

```js tab="JavaScript"
const asCarol = permissions.as({ id: carol })

const { data: canRead } = await asCarol.rbac.hasPermission({
  permission: 'documents.read',
})
// true
const { data: canEdit } = await asCarol.rbac.hasPermission({
  permission: 'documents.edit',
})
// false
const { data: unknown } = await asCarol.rbac.hasPermission({
  permission: 'documents.nonexistent',
})
// false, not an error
const { data: isViewer } = await asCarol.rbac.hasRole({
  role: 'viewer',
})
// true
const { data: isPermission } = await asCarol.rbac.hasRole({
  role: 'documents.read',
})
// false: a permission name is not a role
const { data: isNone } = await asCarol.rbac.hasRole({
  role: 'nonexistent',
})
// false


const { data: bobViewer } = await asBob.rbac.hasRole({
  role: 'viewer',
})
// true: inherited through editor
const { data: bobAdmin } = await asBob.rbac.hasRole({
  role: 'admin',
})
// false
```

```sql tab="SQL"
begin;
select set_config('permissions.subject_id', :'carol', true);
select permissions.rbac_has_permission(permission => 'documents.read');
-- true
select permissions.rbac_has_permission(permission => 'documents.edit');
-- false
select permissions.rbac_has_permission(
  permission => 'documents.nonexistent'
);
-- false, not an error
select permissions.rbac_has_role(role => 'viewer');
-- true
select permissions.rbac_has_role(role => 'documents.read');
-- false: a permission name is not a role
select permissions.rbac_has_role(role => 'nonexistent');
-- false
commit;

begin;
select set_config('permissions.subject_id', :'bob', true);
select permissions.rbac_has_role(role => 'viewer');
-- true: inherited through editor
select permissions.rbac_has_role(role => 'admin');
-- false
commit;
```

## Optional: enforce access with RLS

To apply these permissions to table queries, create a table with an `org_id` column and the policies below:

```sql
create table public.org_documents (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  title text not null
);
create index on public.org_documents (org_id);
insert into public.org_documents (org_id, title)
values
  (:'acme', 'acme plan'),
  (:'acme', 'acme readme'),
  (:'globex', 'globex notes');

alter table public.org_documents enable row level security;
grant select, insert, update on public.org_documents to authenticated;

create policy org_documents_select
  on public.org_documents
  for select
  to authenticated
  using (
    org_id = any (
      array(
        select unnest(
          permissions.rbac_scopes_with_permission(
            permission => 'documents.read'
          )
        )::uuid
      )
    )
  );
create policy org_documents_update
  on public.org_documents
  for update
  to authenticated
  using (
    permissions.rbac_has_permission(
      permission => 'documents.edit',
      scope => org_id::text
    )
  );
create policy org_documents_insert
  on public.org_documents
  for insert
  to authenticated
  with check (
    permissions.rbac_has_permission(
      permission => 'documents.edit',
      scope => org_id::text
    )
  );
```

The SELECT policy uses the fast path. It lists the scopes of the user once for each query. The UPDATE and INSERT policies check the one row that the statement writes. [RLS policies](../../rls/policies.md) explains the two forms.

A scope is any ID that you choose. Normally it is the ID of an organization row. Scopes are text, so cast a `uuid` column with `org_id::text`.

Now use the policies. As Bob:

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select count(*) from public.org_documents;
-- 3: acme and globex
update public.org_documents set title = upper(title);
-- UPDATE 2: only acme
insert into public.org_documents (org_id, title)
values (:'acme', 'budget');
-- INSERT 0 1
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
insert into public.org_documents (org_id, title)
values (:'globex', 'nope');
-- ERROR:  new row violates row-level security policy for table "org_documents"
commit;
```

Alice is an admin of `acme`, and also an app-wide admin from scenario 1. She sees the 3 documents of `acme` and none of `globex`. Carol is an app-wide viewer. She sees none, because a scoped policy never looks at app-wide roles.

## Next step

Continue with [Manage roles and assignments](manage.md).
