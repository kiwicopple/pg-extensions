# RBAC: roles and permissions

The `rbac_*` functions manage roles. A role grants permissions. A role can inherit other roles. A user holds a role app-wide or in one scope, for example one tenant or one organization.

Use RBAC when access depends on what a user is, and not on one object. For access to single objects, use the [OpenFGA model](fga.md). The [function reference](reference.md) gives the full signature of each function.

## Before you start

[Install the extension](install.md) first. The examples use psql variables for IDs. For example, `:'alice'` is the ID of Alice:

```sql
\set alice  '11111111-1111-1111-1111-111111111111'
\set bob    '22222222-2222-2222-2222-222222222222'
\set carol  '33333333-3333-3333-3333-333333333333'
\set dave   '44444444-4444-4444-4444-444444444444'
\set erin   '55555555-5555-5555-5555-555555555555'
\set frank  '66666666-6666-6666-6666-666666666666'
\set acme   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
\set globex 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
```

In your application, these are arguments. The extension accepts any text as an ID. The examples use UUIDs because the example tables have `uuid` keys.

Statements that change roles run as the role that installed the extension. This page calls that role the admin. Examples that start with `set local role authenticated` show what a client sees.

The examples use the Supabase role names `anon`, `authenticated` and `service_role`. Supabase has these roles. Plain Postgres does not have them, so create them to run the examples. The extension does not need them.

```sql
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;
```

## Identity

Each check answers for the current subject. The extension does not store users. It does not read the `auth` schema. Two functions tell the extension who the subject is:

- `permissions.current_subject_id()` returns the ID of the subject, or null when there is no subject.
- `permissions.current_subject_type()` returns the type of the subject. The default is `'user'`.

The ID comes from the first source that has a value:

1. The `sub` claim of the JWT in the configuration parameter `request.jwt.claims`. Supabase and PostgREST set it on each request. It is the value that `auth.uid()` returns.
2. The configuration parameter `permissions.subject_id`. Plain Postgres uses this source.
3. If neither source has a value, the ID is null. Then each check returns false.

```sql
select permissions.current_subject_id();
-- null: no JWT, no parameter
select permissions.current_subject_type();
-- user
select permissions.rbac_has_permission(permission => 'documents.read');
-- false: no subject, no access
```

### Plain Postgres

Set `permissions.subject_id` at the start of each request, in the transaction that serves the request:

```sql
begin;
select set_config('permissions.subject_id', :'alice', true);
-- true: local to this transaction
select permissions.current_subject_id();
-- the ID of Alice
commit;
select permissions.current_subject_id();
-- null again
```

Do not set the third argument of `set_config` to `false`. The value then stays for the whole session. Behind a pooler in transaction mode, the next client gets the same server connection and acts as the previous user. A transaction-local value disappears at commit or rollback.

In an application, add one statement at the start of the transaction. This example uses node-postgres:

```js
const client = await pool.connect();
try {
  await client.query('begin');
  await client.query('set local role app_user');
  // a role without BYPASSRLS, so policies apply
  await client.query(
    "select set_config('permissions.subject_id', $1, true)",
    [userId]
  );
  // ... the queries of this request ...
  await client.query('commit');
} catch (e) {
  await client.query('rollback');
  throw e;
} finally {
  client.release();
}
```

Use `set_config` with a bound argument. The statement `SET LOCAL permissions.subject_id = ...` cannot take arguments. The `set local role` line is necessary. A superuser, or the owner of a table, bypasses row level security, and then no policy runs. See [Warnings and limits](#warnings-and-limits).

### Supabase and PostgREST

PostgREST sets `request.jwt.claims`. A client that sends the JWT of a user is already identified. A backend that connects directly can set the claim itself:

```sql
begin;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', :'alice',
    'role', 'authenticated'
  )::text,
  true
);
select permissions.current_subject_id();
-- the ID of Alice
select set_config('permissions.subject_id', :'bob', true);
select permissions.current_subject_id();
-- still the ID of Alice: the JWT wins
commit;
```

The JWT wins on purpose. Nothing else in the session can change the subject of a request that has a JWT. If the JWT has no `sub` claim (for example the `anon` role), the extension uses `permissions.subject_id`. If that is also empty, there is no subject.

### Subject type

`permissions.current_subject_type()` returns `'user'`, unless the configuration parameter `permissions.subject_type` has another value:

```sql
begin;
select set_config('permissions.subject_type', 'service', true);
select permissions.current_subject_type();                    -- service
commit;
```

Do not change the subject type for RBAC. Only `user` subjects hold roles. A request with another subject type holds no role. The subject type matters for the OpenFGA model. There the current subject is `<current_subject_type()>:<current_subject_id()>`. See [RLS with both models](rls.md#current-subject-functions).

### The type of `current_subject_id()`

The function returns `text`. Any `sub` value works. IDs that are not UUIDs, such as `user_2abc`, also work. To compare the ID with a `uuid` column, cast the column: `current_subject_id() = owner_id::text`.

## Privileges

The extension has two kinds of functions.

| Kind | Functions | Who can call them |
| --- | --- | --- |
| Client functions: answer for the current subject only | `current_subject_id`, `current_subject_type`, `rbac_has_permission`, `rbac_has_role`, `rbac_scopes_with_permission`, `fga_check_current`, `fga_list_objects_current`, `fga_list_object_ids_current` | Everyone (granted to `PUBLIC`), so `anon` and `authenticated` too |
| Admin functions: change data, or take a subject as an argument | `rbac_create_role`, `rbac_drop_role`, `rbac_assign_role`, `rbac_unassign_role`, `rbac_user_permissions`, `rbac_users_with_role`, `delete_subject`, and each other `fga_*` function | The role that installed the extension. Other roles need an explicit `grant execute` |

Clients have no privilege on the tables of the extension. The functions that read the tables are `security definer`, with a fixed `search_path`.

The admin functions are admin-only for a reason. `rbac_user_permissions` and `rbac_users_with_role` take a subject as an argument. If a client could call them, any signed-in user could ask what another user can do. A client that could call `rbac_assign_role` could make itself an admin. The client functions have no subject argument, so a client can only ask about itself.

```sql
set role authenticated;
select permissions.rbac_has_permission(permission => 'documents.read');
-- false: no subject, but no error
select permissions.rbac_assign_role(
  user_id => :'bob',
  role => 'admin'
);
-- ERROR:  permission denied for function rbac_assign_role
select permissions.rbac_user_permissions(user_id => :'alice');
-- ERROR:  permission denied for function rbac_user_permissions
reset role;
```

A trusted backend role, such as `service_role`, gets the admin functions with an explicit grant. This example is for RBAC. The grants for the `fga_*` functions are in [the OpenFGA model](fga.md).

```sql
grant execute on function
    permissions.rbac_create_role(text, text[], text[]),
    permissions.rbac_drop_role(text),
    permissions.rbac_assign_role(text, text, text),
    permissions.rbac_unassign_role(text, text, text),
    permissions.rbac_user_permissions(text, text),
    permissions.rbac_users_with_role(text, text),
    permissions.delete_subject(text, text)
to service_role;
```

On Supabase, `service_role` bypasses RLS but not function privileges. This is why the grant is necessary. Grant only the functions that the backend uses.

## Create roles

Define each role once, as the admin. A role has a name, a list of permissions, and a list of roles that it inherits. Here `editor` inherits `viewer`, and `admin` inherits `editor`:

```sql
select permissions.rbac_create_role(
  role => 'viewer',
  permissions => '{documents.read}'
);
select permissions.rbac_create_role(
  role => 'editor',
  permissions => '{documents.edit}',
  inherits => '{viewer}'
);
select permissions.rbac_create_role(
  role => 'admin',
  permissions => '{documents.delete,users.manage}',
  inherits => '{editor}'
);
```

A permission name is a free-form string, for example `documents.read`. A role works both app-wide and in any scope. Inheritance is transitive: `admin` has the permissions of `editor`, and the permissions that `editor` inherits from `viewer`.

Then assign the roles to users. These assignments are app-wide:

```sql
select permissions.rbac_assign_role(
  user_id => :'alice',
  role => 'admin'
);
select permissions.rbac_assign_role(
  user_id => :'bob',
  role => 'editor'
);
select permissions.rbac_assign_role(
  user_id => :'carol',
  role => 'viewer'
);
```

Ask what a user can do. The result lists each permission that the user holds, directly or through inheritance. The order is not defined:

```sql
select permissions.rbac_user_permissions(user_id => :'alice');
-- {documents.delete,documents.edit,documents.read,users.manage}
select permissions.rbac_user_permissions(user_id => :'dave');
-- {}: Dave has no role
```

## Scenario 1: app-wide roles

Alice is an `admin`, Bob is an `editor` and Carol is a `viewer`, all app-wide. The rule is: SELECT needs `documents.read`, UPDATE needs `documents.edit`, and DELETE needs `documents.delete`.

```sql
create table public.documents (
  id uuid primary key default gen_random_uuid(),
  title text not null
);
insert into public.documents (title)
values ('welcome'), ('holidays'), ('expenses');

alter table public.documents enable row level security;
grant select, update, delete on public.documents to authenticated;

create policy documents_select
  on public.documents
  for select
  to authenticated
  using (
    (
      select permissions.rbac_has_permission(
        permission => 'documents.read'
      )
    )
  );
create policy documents_update
  on public.documents
  for update
  to authenticated
  using (
    (
      select permissions.rbac_has_permission(
        permission => 'documents.edit'
      )
    )
  );
create policy documents_delete
  on public.documents
  for delete
  to authenticated
  using (
    (
      select permissions.rbac_has_permission(
        permission => 'documents.delete'
      )
    )
  );
```

The check does not depend on the row, so the policy wraps it in `(select ...)`. Postgres then runs the check once for each query, as an InitPlan, and not once for each row. `EXPLAIN` shows an `InitPlan` and no `SubPlan`.

Each block below starts with the same two statements. The first statement starts a transaction as a client. The second statement sets the subject. The comments show the result:

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'carol', true);
select count(*) from public.documents;
-- 3: viewers read all documents
update public.documents set title = upper(title);
-- UPDATE 0: Carol cannot edit
select permissions.rbac_has_permission(permission => 'documents.edit');
-- false
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
update public.documents set title = upper(title);
-- UPDATE 3: editors can update
delete from public.documents where title = 'EXPENSES';
-- DELETE 0: editors cannot delete
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'alice', true);
delete from public.documents where title = 'EXPENSES';
-- DELETE 1: admins can delete
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'dave', true);
-- Dave has no role
select count(*) from public.documents;                        -- 0
select set_config('permissions.subject_id', '', true);
-- no subject
select count(*) from public.documents;                        -- 0
commit;
```

In production, the `set_config` statement is part of your request setup (see [Identity](#identity)). On Supabase, the JWT does this.

## Scenario 2: roles scoped to a tenant

This scenario uses the same roles, but assigns them for each organization. Alice is an admin of `acme`. Bob is an editor of `acme` and a viewer of `globex`. The table has an `org_id` column, and the policies use it:

```sql
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

The SELECT policy uses the fast path. It lists the scopes of the user once for each query. The UPDATE and INSERT policies check the one row that the statement writes. [RLS policies](rls.md) explains the two forms.

A scope is any ID that you choose. Normally it is the ID of an organization row. Scopes are text, so cast a `uuid` column with `org_id::text`.

Ask the questions of the scenario as Bob. Run each statement in a transaction that sets the subject:

```sql
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

```sql
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

## Rules

- **Scopes are separate.** `rbac_has_permission(permission => p)` looks only at app-wide roles. With a `scope` argument, it looks only at that scope. No inheritance links them. To let app-wide roles work in a scope, write both checks. See [App-wide or scoped checks](rls.md#app-wide-or-scoped-checks).
- **Unknown names return false.** An unknown permission or role in `rbac_has_permission` or `rbac_has_role` gives false, not an error. A policy that names a dropped permission denies access, and does not break each query.
- **No subject returns false.** `rbac_scopes_with_permission` returns an empty array in this case, not null.
- **Inheritance counts.** `rbac_has_role` is true for a role that the user holds directly or through inheritance. An editor has `viewer`. An editor does not have `admin`.
- **Only users hold roles.** The functions look at the subject of type `current_subject_type()`. With a subject type other than `user`, they return false.
- **Role names and permission names must not overlap.** A role cannot have the same name as a permission. A permission cannot have the same name as a role.

Examples of the answers, for Carol (a viewer) and Bob (an editor):

```sql
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

## Change and remove roles

A role cannot change after you create it. To change the permissions of a role, drop the role and create it again. Then assign it again, because `rbac_drop_role` removes the assignments of the role. Treat role definitions as work for the admin, like a migration.

`rbac_assign_role` has no effect if the user already holds the role in that scope. `rbac_unassign_role` has no effect if the user does not hold the role. To remove a scoped assignment, pass the same `scope`. An app-wide unassignment does not remove the same role in a scope.

```sql
select permissions.rbac_assign_role(
  user_id => :'bob',
  role => 'editor'
);
-- already held: no change
select permissions.rbac_unassign_role(
  user_id => :'dave',
  role => 'editor'
);
-- Dave does not hold the role: no change
select permissions.rbac_unassign_role(
  user_id => :'dave',
  role => 'nonexistent'
);
-- no change, no error
```

You cannot drop a role that another role inherits. When you drop a role, the extension deletes its assignments. You can reuse the name of a dropped role at once.

```sql
select permissions.rbac_create_role(
  role => 'auditor',
  permissions => '{audit.read}',
  inherits => '{viewer}'
);
select permissions.rbac_assign_role(
  user_id => :'dave',
  role => 'auditor'
);
select permissions.rbac_user_permissions(user_id => :'dave');
-- {audit.read,documents.read}

select permissions.rbac_drop_role(role => 'viewer');
-- ERROR:  role 'viewer' is inherited by 'auditor', 'editor'

select permissions.rbac_drop_role(role => 'auditor');
select permissions.rbac_user_permissions(user_id => :'dave');
-- {}: the assignment went with the role
```

`rbac_users_with_role` lists user IDs. It includes users who hold the role through a role that inherits it:

```sql
select * from permissions.rbac_users_with_role(role => 'editor');
-- Alice (through admin) and Bob
```

## Errors

The RBAC functions raise these errors. Each error has a `DETAIL` code and a `HINT`. The code names the cause. The hint tells you what to do. [Errors and limits](errors-and-limits.md#rbac-errors) describes each code.

| Function | Cause | `DETAIL` code | SQLSTATE |
| --- | --- | --- | --- |
| `rbac_create_role` | The role exists | `rbac:role_exists` | `23505` |
| `rbac_create_role` | A role in `inherits` does not exist | `rbac:unknown_role` | `22023` |
| `rbac_create_role` | A role and a permission have the same name | `rbac:name_overlap` | `22023` |
| `rbac_create_role` | `role`, `permissions` or `inherits` is `null` | `rbac:null_argument` | `22004` |
| `rbac_unassign_role` | `user_id` or `role` is `null` | `rbac:null_argument` | `22004` |
| `rbac_assign_role` | The role does not exist | `rbac:unknown_role` | `22023` |
| `rbac_assign_role` | `user_id` is null | `rbac:null_argument` | `22004` |
| `rbac_drop_role` | The role does not exist | `rbac:unknown_role` | `22023` |
| `rbac_drop_role` | Another role inherits the role | `rbac:role_in_use` | `2BP01` |

```sql
select permissions.rbac_create_role(
  role => 'viewer',
  permissions => '{documents.read}'
);
-- ERROR:  role 'viewer' already exists
-- DETAIL:  rbac:role_exists role='viewer'
select permissions.rbac_create_role(
  role => 'reviewer',
  permissions => '{audit.read}',
  inherits => '{nonexistent}'
);
-- ERROR:  unknown role 'nonexistent' in inherits of role 'reviewer'
-- DETAIL:  rbac:unknown_role role='nonexistent'
select permissions.rbac_create_role(
  role => 'documents.read',
  permissions => '{x.y}'
);
-- ERROR:  role and permission names must not overlap: 'documents.read' is already a permission
-- DETAIL:  rbac:name_overlap
select permissions.rbac_create_role(
  role => 'moderator',
  permissions => '{viewer}'
);
-- ERROR:  role and permission names must not overlap: 'viewer' is already a role
-- DETAIL:  rbac:name_overlap
select permissions.rbac_assign_role(
  user_id => :'bob',
  role => 'nonexistent'
);
-- ERROR:  unknown role 'nonexistent'
-- DETAIL:  rbac:unknown_role role='nonexistent'
select permissions.rbac_drop_role(role => 'nonexistent');
-- ERROR:  unknown role 'nonexistent'
-- DETAIL:  rbac:unknown_role role='nonexistent'
```

## Clean up with `delete_subject`

The extension does not know your users table. When you delete a user, the role assignments of the user stay. They do no harm while IDs are not reused, but they accumulate.

`delete_subject` removes a subject from both models in one call. It removes the role assignments of the subject, scoped assignments too. It also removes each OpenFGA tuple that names the subject, as user, as userset or as object. It returns the number of rows that it removed.

```sql
select permissions.rbac_assign_role(
  user_id => :'frank',
  role => 'viewer'
);
select permissions.rbac_assign_role(
  user_id => :'frank',
  role => 'viewer',
  scope => :'acme'
);
select permissions.delete_subject(
  subject_type => 'user',
  subject_id => :'frank'
);
-- 2
select permissions.rbac_user_permissions(user_id => :'frank');
-- {}
```

Call `delete_subject` from a trigger on your users table. `delete_subject` is admin-only, so the trigger function is `security definer`:

```sql
create table public.users (id uuid primary key);
insert into public.users values (:'carol'), (:'dave');

create function public.forget_user() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform permissions.delete_subject(
    subject_type => 'user',
    subject_id => old.id::text
  );
  return old;
end;
$$;
create trigger forget_user after delete on public.users
    for each row execute function public.forget_user();

delete from public.users where id = :'carol';
select permissions.rbac_user_permissions(user_id => :'carol');
-- {}: the role of Carol is gone
```

`delete_subject` works for each subject type. For the OpenFGA model, `delete_subject(subject_type => 'team', subject_id => 'eng')` removes each tuple that names `team:eng`. See [the OpenFGA model](fga.md).

## Warnings and limits

- **Do not pass the second argument of `rbac_scopes_with_permission`.** The signature is `(permission text, plan_time_guard boolean)`. The extra argument makes Postgres call the function once for each query. If you pass a constant, each query calls the function twice. Call the function with the permission name only. A `grant` or `drop function` statement needs the full signature.
- **A mistake in a permission name denies access without an error.** Unknown names give false in RBAC. Keep the permission names in one place in your code. The OpenFGA functions work the other way: an unknown type or relation raises an error. See [Errors and limits](errors-and-limits.md).
- **Superusers and table owners skip RLS.** Test policies as the role that your clients use, for example `set role authenticated`, and not as `postgres`.
- **Set the subject for each transaction.** Use `set_config(..., true)`. Never use a session-level value behind a pooler.
- **Scoped and app-wide roles are separate.** A policy for a tenant table does not see app-wide roles. See [Rules](#rules).
