# Quickstart: check permissions

Give Alice permission to read documents in Acme. Then ask the same question about Alice and Bob. The only data you need are a role and an assignment.

## Before you start

[Install the extension](../install.md) in an empty test database. Work through the JavaScript examples in a single Node.js module (for example, `quickstart.mjs`), or select SQL and run those examples in one psql session. Use the extension owner for this walkthrough so you can create the role and assignment.

For JavaScript, set `DATABASE_URL` to your test database's connection string and install the client and driver:

```sh
npm install permissions pg
```

## Create a permission and assign it

Create a `viewer` role with permission to read documents. Assign Alice that role in the `acme` scope.

```js tab="JavaScript"
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL })
const permissions = createServerClient(pool, { throwOnError: true })

await permissions.rbac.admin.createRole({
  role: 'viewer',
  permissions: ['documents.read'],
})
await permissions.rbac.admin.assignRole({
  userId: 'alice',
  role: 'viewer',
  scope: 'acme',
})
```

```sql tab="SQL"
select permissions.rbac_create_role(
  role => 'viewer',
  permissions => '{documents.read}'
);
select permissions.rbac_assign_role(
  user_id => 'alice',
  role => 'viewer',
  scope => 'acme'
);
```

The `viewer` role belongs to your application. Postgres database roles control which connections may run the admin functions. In the JavaScript example, `throwOnError` stops the script if either write fails.

## Check Alice's permission

Ask whether Alice can read documents in Acme. On the server, `as({ id })` sets the subject for one client call in its own transaction. In SQL, set the subject inside the same transaction as the check.

```js tab="JavaScript"
const { data: aliceCanRead } = await permissions
  .as({ id: 'alice' })
  .rbac.hasPermission({ permission: 'documents.read', scope: 'acme' })

console.log(aliceCanRead) // true
```

```sql tab="SQL"
begin;
select set_config('permissions.subject_id', 'alice', true);
select permissions.rbac_has_permission(
  permission => 'documents.read',
  scope => 'acme'
);
-- true
commit;
```

## Check Bob's permission

Run the same check for Bob. He has no role in Acme.

```js tab="JavaScript"
const { data: bobCanRead } = await permissions
  .as({ id: 'bob' })
  .rbac.hasPermission({ permission: 'documents.read', scope: 'acme' })

console.log(bobCanRead) // false
await pool.end()
```

```sql tab="SQL"
begin;
select set_config('permissions.subject_id', 'bob', true);
select permissions.rbac_has_permission(
  permission => 'documents.read',
  scope => 'acme'
);
-- false
commit;
```

If you saved the JavaScript blocks to `quickstart.mjs`, run `node quickstart.mjs`. The two checks print `true` and `false`.

## Connect your application

In a request handler, take the user ID from your authentication system and the organization from the requested resource. Check that user’s permission before fetching or changing protected data. Your server can use the decision directly. [Check access in your application](../integrations/checks.md) shows the handler and how to handle errors.

A PostgREST or Supabase browser client gets the subject from the signed-in user's JWT. See [JavaScript setup](../integrations/javascript.md) and [Identity and request context](../integrations/identity.md).

## Optional: enforce access on a table

If you want Postgres to filter table queries automatically, add an RLS policy. This section creates its own `quickstart_reader` database role; your application can use its existing request role instead. Use a connection that can create roles and switch to them. Test the final queries as `quickstart_reader`, since superusers and table owners normally bypass RLS.

### Create the table and policy

```sql
create role quickstart_reader nologin;
grant usage on schema public to quickstart_reader;

create table public.documents (
  id text primary key,
  org_id text not null,
  title text not null
);
create index on public.documents (org_id);
insert into public.documents values
  ('roadmap', 'acme', 'Acme roadmap'),
  ('budget', 'globex', 'Globex budget');

alter table public.documents enable row level security;
grant select on public.documents to quickstart_reader;

create policy documents_select
  on public.documents
  for select
  to quickstart_reader
  using (
    org_id = any (
      array(
        select unnest(
          permissions.rbac_scopes_with_permission(
            permission => 'documents.read'
          )
        )
      )
    )
  );
```

The policy computes Alice's accessible scopes once per query. The database can then use the index on `org_id`. See [read and write policies](../rls/policies.md) for UUID keys and write access.

### Query as Alice

Set the subject inside the same transaction as the query. The `true` argument makes the setting transaction-local, so it cannot leak to another request through a pooled connection.

```sql
begin;
set local role quickstart_reader;
select set_config('permissions.subject_id', 'alice', true);
select id, title
from public.documents
order by id;
-- roadmap | Acme roadmap
commit;
```

Alice sees the Acme document. The Globex document is hidden because she has no role in that scope.

### Query as Bob

```sql
begin;
set local role quickstart_reader;
select set_config('permissions.subject_id', 'bob', true);
select count(*)
from public.documents;
-- 0
commit;
```

Bob has no assignment, so the query returns no documents. The subject setting ends with the transaction.

## Next steps

[Choose a model](choose-a-model.md), explore [tenant-scoped roles](../models/rbac/tenants.md), or [use checks in your backend](../integrations/checks.md). If you use RLS, you can also [combine roles and individual shares on a table](../rls/combine-models.md).
