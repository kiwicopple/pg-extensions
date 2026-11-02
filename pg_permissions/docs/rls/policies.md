# Read and write policies

Use RLS to enforce permissions when application clients query a table. For reads, compute accessible scopes or object IDs once per query. For writes, check the row being changed.

The examples below form a separate SQL walkthrough. Start in a fresh database with the extension installed. They define their own roles and data; do not combine them with the earlier RBAC walkthrough in the same database.

## Before you start

Run the examples in order, in an empty database, as the extension owner (the admin). Examples that start with `set local role authenticated` show what a client sees. The [RBAC page](../models/rbac/overview.md#before-you-start) explains the `anon`, `authenticated` and `service_role` roles.

The examples use these IDs. `:'alice'` is the ID of Alice:

```sql
\set alice  '11111111-1111-1111-1111-111111111111'
\set bob    '22222222-2222-2222-2222-222222222222'
\set carol  '33333333-3333-3333-3333-333333333333'
\set dave   '44444444-4444-4444-4444-444444444444'
\set erin   '55555555-5555-5555-5555-555555555555'
\set gina   '77777777-7777-7777-7777-777777777777'
\set hugo   '88888888-8888-8888-8888-888888888888'
\set ivan   '99999999-9999-9999-9999-999999999999'
\set jane   '10101010-1010-1010-1010-101010101010'
\set acme   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
\set globex 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
\set eng    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
\set plan   'd0000000-0000-0000-0000-000000000001'
\set readme 'd0000000-0000-0000-0000-000000000002'
\set notes  'd0000000-0000-0000-0000-000000000003'
\set draft  'd0000000-0000-0000-0000-000000000004'
\set diary  'd0000000-0000-0000-0000-000000000005'
```

The examples need the Supabase role names. Create them on plain Postgres, and then create two roles:

```sql
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;

select permissions.rbac_create_role(
  role => 'viewer',
  permissions => '{documents.read}'
);
select permissions.rbac_create_role(
  role => 'editor',
  permissions => '{documents.edit}',
  inherits => '{viewer}'
);
```

## Policies for RBAC

### Tenant tables: the fast path

For a table with a tenant column, write a read policy in exactly this form:

```text
org_id = any (
  array(
    select unnest(
      permissions.rbac_scopes_with_permission(
        permission => 'documents.read'
      )
    )::uuid
  )
)
```

Postgres computes the list of scopes of the user once for each query, as an InitPlan. Then it uses the index on `org_id`. `EXPLAIN` shows an InitPlan and no per-row SubPlan.

Three other forms look correct, but they are worse. These are fragments:

```text
-- 1. Does not work
org_id = any (
  (
    select permissions.rbac_scopes_with_permission(
      permission => 'documents.read'
    )
  )
)
-- ERROR:  operator does not exist: uuid = text[]

-- 2. Works, but is slower on a big table
org_id = any (
  (
    select permissions.rbac_scopes_with_permission(
      permission => 'documents.read'
    )
  )::uuid[]
)

-- 3. Works, but the index of the table is not used
org_id in (
  select unnest(
    permissions.rbac_scopes_with_permission(
      permission => 'documents.read'
    )
  )::uuid
)
```

- Form 1: Postgres reads `any ((select ...))` as a subquery comparison. It fails even with the double parentheses.
- Form 2: Postgres applies the `::uuid[]` cast again to each row that it filters. On Postgres 16 with 1 million rows, a page of 50 documents took 3.64 ms instead of 0.73 ms.
- Form 3: `in (select ...)` becomes a hashed subquery, and the index on `org_id` is not used. To count the documents that one user sees took 88.8 ms instead of 2.2 ms.

Forms 2 and 3 return the same rows as the fast path. They cost more.

### Writes: check the row

For UPDATE, DELETE and INSERT, check the one row that the statement writes. Use the per-row form. These are fragments:

```text
using (
  permissions.rbac_has_permission(
    permission => 'documents.edit',
    scope => org_id::text
  )
)
-- update, delete
with check (
  permissions.rbac_has_permission(
    permission => 'documents.edit',
    scope => org_id::text
  )
)
-- insert
```

A write touches few rows, so one call for each row is cheap. The policy then reads like the rule. The fast path would build the whole list of scopes of the user for each statement. For UPDATE, `with check` defaults to the `using` expression.

Scopes are text. Pass the scope as `org_id::text`.

### App-wide or scoped checks

`rbac_has_permission` without a `scope` looks only at app-wide roles. With a `scope`, it looks only at that scope. To let app-wide roles also work on a tenant table, use both checks in the policy.

This example uses a `projects` table. The role assignments below give each user a different access:

```sql
create table public.projects (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  name text not null
);
create index on public.projects (org_id);
insert into public.projects (org_id, name)
values (:'acme', 'apollo'), (:'globex', 'gemini');

alter table public.projects enable row level security;
grant select, update on public.projects to authenticated;

create policy projects_select
  on public.projects
  for select
  to authenticated
  using (
    (
      select permissions.rbac_has_permission(
        permission => 'documents.read'
      )
    )
    or org_id = any (
      array(
        select unnest(
          permissions.rbac_scopes_with_permission(
            permission => 'documents.read'
          )
        )::uuid
      )
    )
  );
create policy projects_update
  on public.projects
  for update
  to authenticated
  using (
    (
      select permissions.rbac_has_permission(
        permission => 'documents.edit'
      )
    )
    or permissions.rbac_has_permission(
      permission => 'documents.edit',
      scope => org_id::text
    )
  );

select permissions.rbac_assign_role(
  user_id => :'gina',
  role => 'viewer'
);
select permissions.rbac_assign_role(
  user_id => :'hugo',
  role => 'viewer',
  scope => :'globex'
);
select permissions.rbac_assign_role(
  user_id => :'ivan',
  role => 'editor',
  scope => :'acme'
);
select permissions.rbac_assign_role(
  user_id => :'ivan',
  role => 'viewer',
  scope => :'globex'
);
select permissions.rbac_assign_role(
  user_id => :'jane',
  role => 'editor'
);
```

The policy wraps the app-wide check in `(select ...)`. The check does not depend on the row, so it runs once. This table shows what each user can do:

| User | Roles | `projects` |
| --- | --- | --- |
| Gina | viewer, app-wide | reads both rows, updates none |
| Hugo | viewer of `globex` | reads `gemini` |
| Ivan | editor of `acme`, viewer of `globex` | reads both rows, updates `apollo` only |
| Jane | editor, app-wide | reads and updates both rows |
| Anyone else | no role | reads nothing |

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'hugo', true);
select name from public.projects;
-- gemini
select permissions.rbac_has_permission(permission => 'documents.read');
-- false: Hugo has no app-wide role
select permissions.rbac_has_permission(
  permission => 'documents.read',
  scope => :'globex'
);
-- true
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'ivan', true);
update public.projects set name = upper(name);
-- UPDATE 1: apollo only
commit;
```

The `or` has a cost. Postgres cannot use the `org_id` index for the scoped arm. A test on Postgres 16 used 500,000 rows in 200 organizations. A user who sees 7,500 rows counted them in about 1 ms with the single-check policy. The policy with two checks took about 20 ms. A page of 50 rows took about 1 ms with both policies.

If a table does not need app-wide roles, use the single check.

### Other rules

- **Do not fix plan-time evaluation yourself.** `rbac_scopes_with_permission` is `STABLE`, with a last argument that makes the planner skip the call at plan time. Do not pass that argument, and do not mark your own wrapper functions `VOLATILE`. In `read committed`, a volatile function reads the grants at a later time than the rows that it filters.
- **Give each policy a role.** Write `to authenticated`, or the role that your requests use, and run `alter table ... enable row level security`. A superuser, or an owner without `force row level security`, bypasses each policy.
- **Clients never write permission data.** Clients have no privilege on the tables. The functions that write are admin-only.

## Next step

Continue with [Combine permission models](combine-models.md).
