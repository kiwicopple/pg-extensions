# Quickstart: check permissions

Give Alice permission to read Acme's documents, then check access for Alice and Bob. This example uses tenant-scoped RBAC as an authorization store and check engine. The first checks need no application table or RLS policy. An optional section shows how to enforce the same permission on a table.

## Before you start

[Install the extension](../install.md) in an empty test database. Run the SQL blocks in order in psql as the extension owner. Only the optional RLS example needs a connection that can create database roles and switch to them.

## Create a permission and assign it

Create a role in the extension and give it to Alice in the `acme` scope:

```sql
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

The application permission role `viewer` is separate from a Postgres database role. The database role controls which tables and functions a connection can use.

## Check Alice's permission

Set the subject inside the same transaction as the check. The `true` argument makes the setting transaction-local, so it cannot leak to another request through a pooled connection.

```sql
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

```sql
begin;
select set_config('permissions.subject_id', 'bob', true);
select permissions.rbac_has_permission(
  permission => 'documents.read',
  scope => 'acme'
);
-- false
commit;
```

Bob has no assignment, so his check returns `false`. The subject setting ends with each transaction. Your backend can use these results to allow or reject a request. The function returns a decision; it does not block an application query by itself.

## Connect your application

A trusted request handler sets the subject from the authenticated user, runs the check, and proceeds only if access is allowed. Do not let an untrusted caller choose another user's ID. [Check access in your application](../integrations/checks.md) shows the backend flow, including JavaScript and error handling.

PostgREST and Supabase supply identity through JWT claims; direct Postgres connections use transaction-local settings. [Identity and request context](../integrations/identity.md) explains both paths.

You can stop here and use checks in your application. For JavaScript, follow [client setup](../integrations/javascript.md), then use the SQL/JavaScript examples in the [RBAC guide](../models/rbac/overview.md).

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
