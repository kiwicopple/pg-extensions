# Quickstart: protect a table

Give Alice access to Acme's documents and verify that Bob cannot read them. This example uses tenant-scoped RBAC and enforces access with RLS.

## Before you start

[Install the extension](../install.md) in an empty test database. Run the SQL blocks below in order in psql as the database administrator. The setup creates a database role, so use a connection that can create roles and switch to them. This walkthrough uses its own `quickstart_reader` role; your application can use its existing request role instead.

Do not test the final queries as a superuser or table owner. Those roles normally bypass RLS.

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

## Create the table and policy

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

## Query as Alice

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

## Query as Bob

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

## Connect your application

A trusted request handler sets the subject from the authenticated user. Do not let an untrusted caller choose another user's ID. PostgREST and Supabase supply identity through JWT claims; direct Postgres connections use transaction-local settings. [Identity and request context](../integrations/identity.md) explains both paths.

For JavaScript, follow [client setup](../integrations/javascript.md), then use the SQL/JavaScript examples in the [RBAC guide](../models/rbac/overview.md). The client checks permissions; the policies above enforce which rows a query returns.

Next, [choose a model](choose-a-model.md), explore [tenant-scoped roles](../models/rbac/tenants.md), or [add individual shares](../rls/combine-models.md).
