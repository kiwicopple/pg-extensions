# Using pg_permissions

How to use `pg_permissions` in an application: install it, tell it who the current user is, define roles, share single objects, and write RLS policies that use both.

The extension, [`pg_permissions--0.0.1.sql`](../pg_permissions--0.0.1.sql), has two permission models side by side in the schema `permissions` ([`designs/d-per-model.md`](../designs/d-per-model.md)):

- **The `rbac` preset** (`rbac_*` tables): roles that grant permissions, app-wide or per tenant. Most apps start here. This page.
- **The OpenFGA model** (`fga_*` tables): [OpenFGA](https://openfga.dev)'s modeling language, tuples, Check, ListObjects, ListUsers and Read, for per-object sharing, nested teams and folders. [The OpenFGA model](fga.md).

The two meet in RLS policies, where permissive policies OR together and restrictive ones AND: [RLS with both models](rls.md). Adding sharing to an app that started on roles is one more policy, with nothing to migrate.

| Page | Covers | Tested by |
| --- | --- | --- |
| This page | install, identity, privileges, the `rbac` preset, RLS rules | [`test/spec/90_usage_rbac.sql`](../test/spec/90_usage_rbac.sql) |
| [The OpenFGA model](fga.md) | writing a model, tuples, Check, ListObjects, ListUsers, Read, contextual tuples, errors and limits, privileges | [`test/spec/d/90_usage_fga.sql`](../test/spec/d/90_usage_fga.sql) |
| [RLS with both models](rls.md) | the current-subject functions, combining both models in policies, denies, plan-time evaluation, row attributes, cleanup | [`test/spec/d/90_usage_rls.sql`](../test/spec/d/90_usage_rls.sql) |

Every SQL example on these pages runs as written in the spec next to it. This page's examples also run against the prototypes A, B and C, which share the `rbac` preset ([Prototypes](#prototypes-a-b-and-c-history)).

Examples use psql variables for IDs. `:'alice'` is Alice's user ID, and so on:

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

In your application these are parameters. The extension takes any text as an ID; they are UUIDs here because the tables in the examples use `uuid` keys (and prototype C required them).

Statements that change roles run as the role that installed the extension (the "admin" below). Examples that start with `set local role authenticated` show what a client sees.

## Install

The extension needs no other extensions and no C. It was tested on Postgres 16, 17 and 18.

### Plain psql

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f pg_permissions--0.0.1.sql
```

This creates the schema `permissions`, its tables and its functions, all owned by the role you connected as. Run it once per database: the files aren't re-runnable (a second run fails with `relation ... already exists`), and there is no upgrade path yet.

On Supabase, paste the file into the SQL editor, or run it with `psql` as the `postgres` role. `anon`, `authenticated` and `service_role` already exist. On plain Postgres they don't, and nothing in the install needs them; create the role your requests run as (the examples use Supabase's names).

### Non-superuser install

The installing role needs no superuser rights. It needs `CREATE` on the database (the file creates the schema `permissions`); owning the database is not required. Everything it creates is owned by that role, and that role is the "admin" in this page. [`03_tle_install.sql`](../test/spec/03_tle_install.sql) checks this on the extension and on every prototype: a non-superuser that owns the database installs it, every object ends up owned by that role, and no function is written in C.

### pg_tle

With [pg_tle](https://github.com/aws/pg_tle) loaded (`shared_preload_libraries = 'pg_tle'`), a superuser enables it once per database and lets the installing role use it:

```sql
create extension pg_tle;
grant pgtle_admin to app_owner;   -- the role that installs
```

Then, as that role in psql:

```sql
\set body `cat pg_permissions--0.0.1.sql`
select pgtle.install_extension('pg_permissions', '0.0.1', 'pg_permissions', :'body');
create extension pg_permissions;
```

Write `create extension pg_permissions;` without `with schema`: the file creates the schema `permissions` itself and every function is called as `permissions.name(...)`. (Whether the schema name should be configurable is open: [PLAN.md](../PLAN.md) §9.) This is the sequence `03_tle_install.sql` runs, on PG 16, 17 and 18 with pg_tle 1.5.3.

### Docker

[`docker/`](../docker/README.md) has Postgres 16, 17 and 18 images with pg_tle preloaded, which is the quickest way to try the pg_tle path:

```bash
cd docker
docker compose build
docker compose up -d --wait pg17
cd ..
psql -h localhost -p 54317 -U postgres -v ON_ERROR_STOP=1 -f pg_permissions--0.0.1.sql
```

The containers use `trust` authentication on 127.0.0.1. They are for local testing.

### The extension file

`pg_permissions--0.0.1.sql` and `pg_permissions.control` are the extension: install them as above. `dbdev install kiwicopple-pg_permissions` is not available yet (not published).

## Identity

Every check answers for "the current subject". The extension never stores users and never reads the `auth` schema. Two functions say who that is:

- `permissions.current_subject_id()` returns the subject's ID, or null when there is none.
- `permissions.current_subject_type()` returns the type of the subject, `'user'` unless you say otherwise.

The ID comes from the first of these that is present:

1. The `sub` claim of the JWT in `request.jwt.claims`. Supabase and PostgREST set this on every request. On Supabase this is the whole setup, and it is the same value `auth.uid()` returns.
2. The `permissions.subject_id` setting. This is how plain Postgres tells the extension who is asking.
3. Otherwise null, and then every check is false.

```sql
select permissions.current_subject_id();    -- null: no JWT, no setting
select permissions.current_subject_type();  -- 'user'
select permissions.has_permission('documents.read');  -- false: no subject, no access
```

### Plain Postgres

Set `permissions.subject_id` at the start of each request, in the transaction that serves it:

```sql
begin;
select set_config('permissions.subject_id', :'alice', true);   -- true: local to this transaction
select permissions.current_subject_id();                       -- alice
commit;
select permissions.current_subject_id();                       -- null again
```

The third argument of `set_config` must be `true`. With `false` the setting lasts for the whole session. Behind a pooler in transaction mode the next client to get that server connection inherits it and acts as the previous user. The transaction-local setting disappears at commit or rollback, so there is nothing to clean up.

From an application, that is one extra statement at the start of the transaction. In node-postgres:

```js
const client = await pool.connect();
try {
  await client.query('begin');
  await client.query('set local role app_user');   // a role without BYPASSRLS, so policies apply
  await client.query("select set_config('permissions.subject_id', $1, true)", [userId]);
  // ... this request's queries ...
  await client.query('commit');
} catch (e) {
  await client.query('rollback');
  throw e;
} finally {
  client.release();
}
```

Use `set_config` with a bound parameter. `SET LOCAL permissions.subject_id = ...` can't take parameters. The `set local role` line matters: a superuser, or the owner of a table, bypasses row-level security, and then no policy runs (see [Gotchas](#gotchas)).

### Supabase and PostgREST

PostgREST sets `request.jwt.claims` itself, so a client that sends a user's JWT is already identified. You can set the claim yourself, for example from a backend that connects directly. This is what the extension sees:

```sql
begin;
select set_config('request.jwt.claims', json_build_object('sub', :'alice', 'role', 'authenticated')::text, true);
select permissions.current_subject_id();   -- alice
select set_config('permissions.subject_id', :'bob', true);
select permissions.current_subject_id();   -- still alice: the JWT wins
commit;
```

The JWT wins on purpose. Nothing else in a session can change the subject of a request that carries a JWT. A JWT without a `sub` (the `anon` role) and no setting means no subject.

### Subject type

`permissions.current_subject_type()` returns `'user'` unless the `permissions.subject_type` setting says otherwise:

```sql
begin;
select set_config('permissions.subject_type', 'service', true);
select permissions.current_subject_type();   -- 'service'
commit;
```

Leave it alone for the `rbac` preset. Roles are held by `user` subjects, so a request with another subject type holds none. The setting matters for the OpenFGA model, where the current subject is `<current_subject_type()>:<current_subject_id()>`, so a service can act as `service:<id>` ([RLS with both models](rls.md#the-current-subject-functions)).

### The type of `current_subject_id()`

It returns `text`, so any `sub` works, including non-UUID IDs such as `user_2abc` (a Clerk-style ID). Cast when comparing with a `uuid` column: `current_subject_id() = owner_id::text`.

## Roles and privileges

The extension has two kinds of functions.

| Kind | Functions | Who can call them |
| --- | --- | --- |
| Client-facing: answer for the current subject only | `current_subject_id`, `current_subject_type`, `has_permission`, `has_role`, `scopes_with_permission`, `fga_check_current`, `fga_list_objects_current`, `fga_list_object_ids_current` | Everyone (granted to `PUBLIC`), so `anon` and `authenticated` too |
| Admin-only: change data, or take a subject as an argument | `create_role`, `drop_role`, `assign_role`, `unassign_role`, `user_permissions`, `users_with_role`, `delete_subject`, and every other `fga_*` function (`fga_write`, `fga_check`, `fga_list_objects`, ...) | The installing role. Anyone else needs an explicit `grant execute` |

The tables are closed to clients: no role but the owner has any privilege on them ([`02_security.sql`](../test/spec/02_security.sql) checks every table in the schema). Functions that read them are `security definer`, with a pinned `search_path`.

Why the functions that take a subject are admin-only: `user_permissions(user_id)` and `users_with_role(role)` would let any signed-in user ask what anyone else can do. The client-facing checks have no subject argument, so a client can only ask about itself. The same goes for `assign_role` and its siblings: a client that could call them could make itself an admin.

```sql
set role authenticated;
select permissions.has_permission('documents.read');   -- fine
select permissions.assign_role(:'bob', 'admin');       -- ERROR:  permission denied for function assign_role
select permissions.user_permissions(:'alice');         -- ERROR:  permission denied for function user_permissions
reset role;
```

A trusted backend role such as `service_role` gets the admin functions with an explicit grant. For the `rbac` preset (the `fga_*` grants are in [The OpenFGA model](fga.md#privileges)):

```sql
grant execute on function
    permissions.create_role(text, text[], text[]),
    permissions.drop_role(text),
    permissions.assign_role(text, text, text),
    permissions.unassign_role(text, text, text),
    permissions.user_permissions(text, text),
    permissions.users_with_role(text, text)
to service_role;
```

On Supabase `service_role` bypasses RLS but not function privileges, which is why the grant is needed. Grant only what the backend does.

## The `rbac` preset

Roles grant permissions, roles can inherit other roles, and users hold roles, either app-wide or inside a scope (a tenant or an organization). That is all a developer using the preset sees. There are no tuples, relations or policies in the API.

### Setup

Define the roles once, as the admin, and assign them. This is the scenario from [PLAN.md](../PLAN.md) §6. `editor` inherits `viewer`, `admin` inherits `editor`:

```sql
select permissions.create_role('viewer', '{documents.read}');
select permissions.create_role('editor', '{documents.edit}', '{viewer}');
select permissions.create_role('admin',  '{documents.delete,users.manage}', '{editor}');

select permissions.assign_role(:'alice', 'admin');
select permissions.assign_role(:'bob',   'editor');
select permissions.assign_role(:'carol', 'viewer');
```

Permission names are free-form strings (`documents.read`). A role is defined once and works both app-wide and in any scope.

### Function reference

| Function | Returns | Who | What it does |
| --- | --- | --- | --- |
| `create_role(role text, permissions text[], inherits text[] default '{}')` | `void` | admin | Defines a role, the permissions it grants and the roles it inherits |
| `drop_role(role text)` | `void` | admin | Removes a role and its assignments |
| `assign_role(user_id text, role text, scope text default null)` | `void` | admin | Gives a user a role, app-wide (`scope` null) or in a scope |
| `unassign_role(user_id text, role text, scope text default null)` | `void` | admin | Takes it away |
| `has_permission(permission text, scope text default null)` | `boolean` | everyone | Does the current subject hold the permission? |
| `has_role(role text, scope text default null)` | `boolean` | everyone | Does the current subject hold the role? |
| `scopes_with_permission(permission text)` | `text[]` | everyone | Scopes where the current subject holds the permission. The RLS fast path |
| `user_permissions(user_id text, scope text default null)` | `text[]` | admin | Everything a given user can do |
| `users_with_role(role text, scope text default null)` | `setof text` | admin | Everyone who holds a role |

Behaviour, including the error codes (checked in the spec, on the extension and on the prototypes):

- **Scopes are separate.** `has_permission(p)` looks only at app-wide roles and `has_permission(p, scope)` only at that scope. There is no hidden inheritance between them. An app that wants "app-wide admins can do anything in any tenant" writes both checks ([below](#app-wide-or-scoped-two-checks)).
- **Unknown names return false.** An unknown permission or role in `has_permission` or `has_role` is false, never an error, so a policy that names a dropped permission denies instead of breaking every query. The flip side: a typo in a policy denies silently.
- **No subject returns false.** And `scopes_with_permission` returns an empty array, not null.
- **Inheritance counts.** `has_role` is true for a role held directly or through inheritance. An editor has viewer. An admin is not implied by an editor.
- **Role names and permission names can't overlap.** A role can't be named like an existing permission and a permission can't be named like an existing role.

#### `create_role`

```sql
select permissions.create_role('viewer', '{documents.read}');
-- ERROR (23505): the role already exists
select permissions.create_role('auditor', '{audit.read}', '{nonexistent}');
-- ERROR (22023): unknown role in inherits
select permissions.create_role('documents.read', '{x.y}');
-- ERROR (22023): a role named like a permission
select permissions.create_role('moderator', '{viewer}');
-- ERROR (22023): a permission named like a role
```

Inheritance is transitive: `admin` has what `editor` grants, and what `viewer` grants through `editor`.

```sql
select permissions.user_permissions(:'alice');
-- {documents.read,documents.edit,documents.delete,users.manage}  (order not guaranteed)
```

#### `assign_role` and `unassign_role`

Assigning twice is harmless. An unknown role raises. Unassigning a role the user doesn't hold, or a role that doesn't exist, does nothing.

```sql
select permissions.assign_role(:'bob', 'editor');             -- already held: no change
select permissions.assign_role(:'bob', 'nonexistent');        -- ERROR (22023): unknown role
select permissions.unassign_role(:'dave', 'editor');          -- Dave doesn't hold it: no-op
select permissions.unassign_role(:'dave', 'nonexistent');     -- no-op
```

With a scope, the role applies inside that scope only. A scope is any ID you choose, normally the ID of an organization row. `unassign_role` with the same scope removes it, and removing an app-wide assignment leaves the same role in other scopes alone.

#### `has_permission` and `has_role`

Both answer for the current subject. As Carol, a viewer (`set_config('permissions.subject_id', :'carol', true)` in a transaction):

```sql
select permissions.has_permission('documents.read');         -- true
select permissions.has_permission('documents.edit');         -- false
select permissions.has_permission('documents.nonexistent');  -- false, not an error
select permissions.has_role('viewer');                       -- true
select permissions.has_role('documents.read');               -- false: a permission name is not a role
select permissions.has_role('nonexistent');                  -- false
```

As Bob, an editor:

```sql
select permissions.has_role('viewer');   -- true: inherited through editor
select permissions.has_role('admin');    -- false
```

As Alice, an app-wide admin, a scope sees nothing of her app-wide role:

```sql
select permissions.has_permission('documents.read', :'acme');   -- false
```

Both functions look at the subject whose type is `current_subject_type()`. Roles are held by `user` subjects, so with another subject type they are false.

#### `scopes_with_permission`

Returns the IDs of the scopes where the current subject holds the permission, as `text[]`. App-wide assignments don't appear. This is the function RLS policies use for tenant tables ([below](#writing-rls-policies)). Call it with the permission only:

```sql
select permissions.scopes_with_permission('documents.read');
-- {} for a user who holds nothing in any scope
```

There is a second, hidden parameter, which you must not pass ([Gotchas](#gotchas)).

#### `user_permissions` and `users_with_role`

For admin screens and debugging:

```sql
select permissions.user_permissions(:'bob');            -- {documents.read,documents.edit}
select permissions.user_permissions(:'dave');           -- {}: no roles
select * from permissions.users_with_role('editor');    -- alice (through admin) and bob
```

`users_with_role` includes users who hold the role through a role that inherits it, and it lists user IDs only.

#### `drop_role`

A role that another role inherits can't be dropped. Dropping a role deletes its assignments.

```sql
select permissions.create_role('auditor', '{audit.read}', '{viewer}');
select permissions.assign_role(:'dave', 'auditor');
select permissions.user_permissions(:'dave');    -- {audit.read,documents.read}

select permissions.drop_role('viewer');          -- ERROR (2BP01): viewer is inherited by another role
select permissions.drop_role('nonexistent');     -- ERROR (22023): unknown role

select permissions.drop_role('auditor');
select permissions.user_permissions(:'dave');    -- {}: the assignment went with the role
```

The name of a dropped role can be reused straight away. Treat role definitions as admin-time work, like a migration. There is no call that changes an existing role's permissions or inherited roles: drop it and create it again, and assign it again, since `drop_role` removes its assignments.

### Scenario 1: app-wide roles

Alice is an `admin`, Bob an `editor`, Carol a `viewer`, all app-wide, as set up above. The rule: SELECT needs `documents.read`, UPDATE needs `documents.edit`, DELETE needs `documents.delete`.

```sql
create table public.documents (
    id    uuid primary key default gen_random_uuid(),
    title text not null
);
insert into public.documents (title) values ('welcome'), ('holidays'), ('expenses');

alter table public.documents enable row level security;
grant select, update, delete on public.documents to authenticated;

create policy documents_select on public.documents for select to authenticated
    using ((select permissions.has_permission('documents.read')));
create policy documents_update on public.documents for update to authenticated
    using ((select permissions.has_permission('documents.edit')));
create policy documents_delete on public.documents for delete to authenticated
    using ((select permissions.has_permission('documents.delete')));
```

The check doesn't depend on the row, so it is wrapped in `(select ...)`. Postgres runs it once per query, as an InitPlan, not once per row. `EXPLAIN` shows an `InitPlan` and no `SubPlan`.

What each user sees (every block starts with the same two lines):

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'carol', true);
select count(*) from public.documents;                        -- 3: viewers read everything
update public.documents set title = upper(title);             -- 0 rows: Carol can't edit
select permissions.has_permission('documents.edit');          -- false: can Carol edit documents? No
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
update public.documents set title = upper(title);             -- 3 rows: editors can update
delete from public.documents where title = 'EXPENSES';        -- 0 rows: editors can't delete
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'alice', true);
delete from public.documents where title = 'EXPENSES';        -- 1 row: admins can delete
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'dave', true);   -- Dave holds no role
select count(*) from public.documents;                        -- 0
select set_config('permissions.subject_id', '', true);        -- no subject at all
select count(*) from public.documents;                        -- 0
commit;
```

In production the `set_config` line is your request setup ([Identity](#identity)), or the JWT on Supabase.

### Scenario 2: roles scoped to a tenant

Same roles, assigned per organization. Alice is an admin of `acme`, Bob is an editor of `acme` and a viewer of `globex`. The table has an `org_id`, and the policies use it:

```sql
select permissions.assign_role(:'alice', 'admin',  :'acme');
select permissions.assign_role(:'bob',   'editor', :'acme');
select permissions.assign_role(:'bob',   'viewer', :'globex');

create table public.org_documents (
    id     uuid primary key default gen_random_uuid(),
    org_id uuid not null,
    title  text not null
);
create index on public.org_documents (org_id);
insert into public.org_documents (org_id, title) values
    (:'acme',   'acme plan'),
    (:'acme',   'acme readme'),
    (:'globex', 'globex notes');

alter table public.org_documents enable row level security;
grant select, insert, update on public.org_documents to authenticated;

create policy org_documents_select on public.org_documents for select to authenticated
    using (org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid)));
create policy org_documents_update on public.org_documents for update to authenticated
    using (permissions.has_permission('documents.edit', org_id::text));
create policy org_documents_insert on public.org_documents for insert to authenticated
    with check (permissions.has_permission('documents.edit', org_id::text));
```

SELECT uses the fast path, which lists the user's scopes once per query. UPDATE and INSERT check the one row being written. [Writing RLS policies](#writing-rls-policies) explains the two shapes.

The questions from the scenario, as Bob:

```sql
select permissions.has_permission('documents.edit', :'acme');     -- true
select permissions.has_permission('documents.edit', :'globex');   -- false
select permissions.has_permission('documents.read', :'globex');   -- true
select permissions.scopes_with_permission('documents.read');      -- {acme, globex}, as IDs
select permissions.scopes_with_permission('documents.edit');      -- {acme}
```

And as Carol, who holds a role app-wide only, `scopes_with_permission('documents.read')` is `{}`. Admin queries, as the admin:

```sql
select permissions.user_permissions(:'bob', :'globex');       -- {documents.read}: what can Bob do in globex?
select * from permissions.users_with_role('admin', :'acme');  -- alice: who are the admins of acme?
```

And through the policies, as Bob:

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select count(*) from public.org_documents;                    -- 3: acme and globex
update public.org_documents set title = upper(title);         -- 2 rows: only acme's
insert into public.org_documents (org_id, title) values (:'acme', 'budget');    -- ok
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
insert into public.org_documents (org_id, title) values (:'globex', 'nope');
-- ERROR:  new row violates row-level security policy for table "org_documents"
commit;
```

Alice, an admin of `acme` (and an app-wide admin from scenario 1), sees the 3 `acme` documents and none of `globex`'s. Carol is an app-wide viewer and sees none: a scoped policy never looks at app-wide roles.

## Writing RLS policies

These are the rules from [PLAN.md](../PLAN.md) §4, as practical advice. The measurements are from that section: Postgres 16, 1M rows.

### Tenant tables: the fast path

Use this form, exactly:

```sql
org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
```

Postgres computes the list of the user's scopes once per query (an InitPlan) and then uses the index on `org_id`. In the spec `EXPLAIN` shows an InitPlan and no per-row SubPlan.

Three other ways of writing it look right. None is as good:

```sql
-- 1. Doesn't work
org_id = any ((select permissions.scopes_with_permission('documents.read')))
-- ERROR:  operator does not exist: uuid = text[]

-- 2. Works, but slower on a big table
org_id = any ((select permissions.scopes_with_permission('documents.read'))::uuid[])

-- 3. Works, but the table's index stops being used
org_id in (select unnest(permissions.scopes_with_permission('documents.read'))::uuid)
```

1. Postgres reads `any ((select ...))` as a subquery comparison, and fails even with the double parentheses. The original Zanzibar RFC has this bug.
2. Postgres applies the `::uuid[]` cast again on every row it filters. A page of 50 documents took 3.64 ms instead of 0.73 ms.
3. `in (select ...)` becomes a hashed subquery, and the index on `org_id` isn't used. Counting one user's visible documents took 88.8 ms instead of 2.2 ms.

Forms 2 and 3 return the same rows as the fast path (the spec checks that); they cost more.

### Writes: check the row

For UPDATE, DELETE and INSERT, check the single row being written, with the per-row form:

```sql
using (permissions.has_permission('documents.edit', org_id::text))      -- update, delete
with check (permissions.has_permission('documents.edit', org_id::text))  -- insert
```

A write touches a few rows, so a call per row is cheap and the policy reads like the rule. The fast path would build the user's whole list of scopes for every statement. For UPDATE, `with check` defaults to the `using` expression.

Pass the scope as text with `org_id::text`: scopes are text.

### App-wide or scoped: two checks

`has_permission(p)` never looks at scopes and `has_permission(p, scope)` never looks at app-wide roles. If app-wide roles should also work on a tenant table, a policy needs both:

```sql
create table public.projects (
    id     uuid primary key default gen_random_uuid(),
    org_id uuid not null,
    name   text not null
);
create index on public.projects (org_id);
insert into public.projects (org_id, name) values (:'acme', 'apollo'), (:'globex', 'gemini');

alter table public.projects enable row level security;
grant select, update on public.projects to authenticated;

create policy projects_select on public.projects for select to authenticated
    using (
        (select permissions.has_permission('documents.read'))
        or org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
    );
create policy projects_update on public.projects for update to authenticated
    using (
        (select permissions.has_permission('documents.edit'))
        or permissions.has_permission('documents.edit', org_id::text)
    );
```

The app-wide check is wrapped in `(select ...)`: it doesn't depend on the row, so it runs once. Here the users from before behave like this:

```sql
select permissions.assign_role(:'dave', 'editor', :'acme');
select permissions.assign_role(:'dave', 'viewer', :'globex');
select permissions.assign_role(:'erin', 'viewer', :'globex');
```

| User | Roles | `projects` |
| --- | --- | --- |
| Carol | app-wide viewer | reads both |
| Erin | viewer of `globex` only | reads `gemini` (and `has_permission('documents.read')` is false for her, true with `:'globex'`) |
| Frank | none | reads nothing |
| Dave | editor of `acme`, viewer of `globex` | reads both, updates `apollo` only |
| Alice | app-wide admin | updates both |

The cost: with `or`, Postgres can't use the `org_id` index for the scoped arm. On 500,000 rows in 200 orgs, a user who sees 7,500 of them counted them in 2.2 to 3.2 ms with the single-check policy and 19 to 20 ms with the two-check policy, on all three prototypes (not re-measured on the extension). A page of 50 rows was unaffected (about 1 to 2 ms either way). These numbers were measured ad hoc while writing this page (local Postgres 16.4); they aren't in the benchmark suite. If a table doesn't need app-wide roles, use the single check.

### Other rules

- **Don't fix plan-time evaluation yourself.** `scopes_with_permission` is STABLE and has a trailing parameter that keeps the planner from running the whole call while planning. Don't pass that argument, and don't mark your own wrapper functions VOLATILE: under read committed a volatile function reads grants at a later instant than the rows being filtered. [PLAN.md](../PLAN.md) §4 has the measurements.
- **Policies need a role to apply to.** `to authenticated` (or your own request role) and `alter table ... enable row level security`. A superuser, or an owner without `force row level security`, bypasses every policy.
- **Clients never write permission data.** They have no privileges on the tables, and the functions that write are admin-only.

## Cleaning up when a user is deleted

The extension doesn't know about your users table, so deleting a user doesn't remove their role assignments. Orphans are harmless while IDs are never reused, but they pile up. `permissions.delete_subject('user', id)` removes a user's role assignments, scoped ones included, and every OpenFGA tuple that names them, in one call (for Frank, who holds `viewer`, `user_permissions` goes from `{documents.read}` to `{}`; the spec checks that). Call it from a trigger on your users table: [RLS with both models](rls.md#cleaning-up-when-a-user-is-deleted) has the trigger.

## Graduating from RBAC to per-object sharing

An app that starts on roles often needs "Dave can edit this one document". That is per-object sharing, and it is the OpenFGA model's job. Graduating doesn't migrate anything: the role assignments stay as they are, you write an OpenFGA model and tuples next to them ([The OpenFGA model](fga.md)), and the RLS of the shared table gains one more permissive policy, the list of the documents the current user can view:

```sql
create policy documents_select_fga on public.documents for select to authenticated
    using (id = any (array(select permissions.fga_list_object_ids_current('document', 'viewer')::uuid)));
```

[RLS with both models](rls.md) builds this table and its policies step by step, with a deny that overrides a role. Keep the shared arm as a separate policy (or a second `or` branch), not a replacement for the role arm: the single-branch form is much slower on large tables ([DECISION.md](../DECISION.md), "Hybrids worth considering").

## Gotchas

- **Don't pass the second argument of `scopes_with_permission`.** The signature is `(text, boolean)`. The extra parameter exists so the planner can't evaluate the call at plan time; passing a constant folds the call again, and every query runs the list twice. Call it with the permission name only. It also means `grant` and `drop function` statements need the full signature.
- **A typo in a permission name denies, silently.** Unknown names are false in the `rbac` preset, by design. Keep permission names in one place in your code. The OpenFGA functions are the other way round: an unknown type or relation raises ([RLS with both models](rls.md#typos-raise)).
- **Superusers and owners skip RLS.** Test policies as the role your clients use (`set role authenticated`), not as `postgres`.
- **Set the subject per transaction.** `set_config(..., true)`, never a session-level setting behind a pooler.
- **The check functions don't see row attributes.** A rule on a column (`status = 'published'`) lives in RLS, and `fga_check_current` doesn't know about it: treat checks as advisory and RLS as final ([RLS with both models](rls.md#row-attributes-that-only-rls-sees)).
- **`fga_list_objects` and `fga_list_users` stop at 1,000 results**, as OpenFGA does. The RLS functions (`fga_list_object_ids_current`) have no cap ([The OpenFGA model](fga.md#errors-and-limits)).
- **No upgrade path yet.** The extension file can't be re-run on an existing install.


## Where to go next

- [The OpenFGA model](fga.md) and [RLS with both models](rls.md).
- [`designs/d-per-model.md`](../designs/d-per-model.md): how the extension works, its error codes, its limits, and where it differs from OpenFGA.
- [`PLAN.md`](../PLAN.md): the goals, the `rbac` preset API and the RLS requirements these examples come from.
- [`test/spec/90_usage_rbac.sql`](../test/spec/90_usage_rbac.sql): the tested version of every example here. Run it with `./test/run.sh 90_usage_rbac` (the extension), or add `--impl prototypes/<engine>.sql` for a prototype.

## Prototypes A, B and C (history)

Before the extension was design D, three engines were built as prototypes and compared ([`DECISION.md`](../DECISION.md)). They stay in [`prototypes/`](../prototypes/) as measured history, and their usage guides are kept as they were: they describe those prototypes, not the extension.

All three have this page's `rbac` preset, and `test/spec/90_usage_rbac.sql` still runs against each. Where they differ from the extension:

- `current_subject_id()` is `uuid` on C, and a non-UUID `sub` means no subject there. C raises `22P02` in `assign_role` for a non-UUID user or scope, and has `uuid` overloads of `has_permission` and `has_role`.
- `scopes_with_permission` is `(text, jsonb)` on B.
- The cleanup call is `delete_subject` on A (as on the extension, without OpenFGA tuples), `delete_entity` on B (trigger helper `on_entity_deleted`) and `forget_subject` on C (trigger helper `on_subject_deleted`).
- B refuses `create_role` and `drop_role` under `repeatable read` (`0A000`).
- A names its generic check `check`, a reserved word: write `permissions.check(...)` with the schema.
- Sharing is relationships on A and C and policies on B, each with its own API (the engine pages).

The choice as it stood before D, kept for the record:

| Engine | Pick it if | Usage page (history) |
| --- | --- | --- |
| **A: tuple core** | Your sharing graphs are shallow, or you mostly use RBAC. You want the smallest thing to maintain (871 lines, nothing derived, no locks) and team edits are frequent. You know OpenFGA or SpiceDB. | [Engine A: tuple core](a-tuple-core.md) |
| **B: policy-first** | You need forbid on groups or conditions evaluated by the engine, your roadmap is Cedar-like policies, or your keys are text or bigint. You want generated RLS. | [Engine B: policy-first](b-policy-first.md) |
| **C: compiled model** | Reads dominate and groups are wide or deep. Your IDs are UUIDs and you want typed validation (unknown names raise on write). Nesting teams is rare. | [Engine C: compiled model](c-compiled-model.md) |

The `rbac` preset had the same functions, answers and error codes on all three, with latency within about 0.1 ms across engines ([DECISION.md](../DECISION.md)).
