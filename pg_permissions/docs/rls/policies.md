# Read and write policies

RLS is an optional integration for enforcing permissions when application clients query a table. You can use all permission models through [application checks](../integrations/checks.md) without it. Choose RLS when you want Postgres to filter reads and constrain writes using table policies. For reads, compute accessible scopes or object IDs once per query. For writes, check the row being changed.

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

The examples need the Supabase role names. Create them on plain Postgres, before creating the permission roles:

```sql
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;
```

Create the two application roles. For the JavaScript examples on these RLS pages, connect a [server client](../integrations/javascript.md) named `permissions` to the same database with `throwOnError: true`. Keep the psql session open for the table and policy definitions.

```js tab="JavaScript"
await permissions.rbac.admin.createRole({
  role: 'viewer', permissions: ['documents.read'],
})
await permissions.rbac.admin.createRole({
  role: 'editor', permissions: ['documents.edit'], inherits: ['viewer'],
})
```

```sql tab="SQL"
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

## Policies for Cedar

Use Cedar when the rule depends on attributes, groups or a deny that beats every grant. A Cedar policy is data in the database, so you change a rule without a migration of your RLS policies.

Start in a fresh database. Complete the walkthrough of [Policies (Cedar)](../models/cedar/overview.md) first: [write policies](../models/cedar/policies.md), [store entities](../models/cedar/entities.md) and [check requests](../models/cedar/checks.md). The examples below use its policies and entities, and the roles `anon`, `authenticated` and `service_role`. Do not run them in the database of the RBAC examples above.

The principal of a policy is the current subject, `current_subject_type()::"current_subject_id()"`. The default type is `user`, so the principal of Alice is `user::"alice"`. A subject that has no stored entity is a valid principal. A policy that tests the groups of the principal needs the stored entity.

The two policies below need one more Cedar policy. It lets the owner of a document view it:

```js tab="JavaScript"
await permissions.cedar.admin.putPolicy({
  policyId: 'owner-view',
  policy: 'permit (principal, action == Action::"view", resource) when { resource.owner == principal };',
})
```

```sql tab="SQL"
select permissions.cedar_put_policy(
  policy_id => 'owner-view',
  policy => 'permit (
  principal,
  action == Action::"view",
  resource
)
when { resource.owner == principal };'
);
```

The table has the documents of the app. It has the owner and the level of each document as columns. The entities of `q3` and `salaries` exist from the walkthrough. The entity of `draft` is new. Keep the entities in step with the rows (see [Keep entities in sync](../models/cedar/entities.md#keep-entities-in-sync)):

```sql
select permissions.cedar_put_entities(
  entities => '[
    {
      "uid": {"type": "Document", "id": "draft"},
      "attrs": {
        "owner": {"__entity": {"type": "user", "id": "alice"}},
        "level": "internal"
      }
    }
  ]'
);

create table public.documents (
  id text primary key,
  title text not null,
  owner_id text not null,
  level text not null
);
insert into public.documents (id, title, owner_id, level)
values
  ('q3', 'Q3 report', 'bob', 'internal'),
  ('salaries', 'Salaries', 'alice', 'confidential'),
  ('draft', 'Draft', 'alice', 'internal');
grant select, update on public.documents to authenticated;
alter table public.documents enable row level security;
```

### Reads: list the ids once

For a read policy, use `cedar_list_resources_current`. It returns the ids of the stored entities that the current subject can view. Postgres runs it once for each query, as an InitPlan, and then uses the index of the table:

```sql
create policy documents_select
  on public.documents
  for select
  to authenticated
  using (
    id = any (
      array(
        select permissions.cedar_list_resources_current(
          action => 'Action::"view"',
          resource_type => 'Document'
        )
      )
    )
  );
```

If the column `id` is a `uuid`, cast inside: `select permissions.cedar_list_resources_current(...)::uuid`. The function returns text. Use the same form as for the other lists (see [Performance](performance.md#plan-time-evaluation)).

The list contains stored entities only. A row whose entity is not stored is not visible. A row of the table that has no entity is hidden for every user. To see what each user gets:

| User | Why | `documents` |
| --- | --- | --- |
| Alice | She is in `eng`, and `q3` is in the folder `reports`. She owns `draft`. `no-confidential` forbids `salaries`. | `q3`, `draft` |
| Bob | He owns `q3`. | `q3` |
| Carol | She is in `design`, which is in `eng`. | `q3` |

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', 'alice', true);
select id from public.documents order by id;
-- draft
-- q3
commit;
```

### Writes: check the row

For a write policy, check the row that changes with `cedar_is_authorized_current`. Build the uid of the resource with `cedar_uid`. Pass the columns that the policies read as `resource_attrs`. They replace the stored attributes for this check, so the row does not need an entity, and a stale entity does not matter:

```sql
create policy documents_update
  on public.documents
  for update
  to authenticated
  using (
    permissions.cedar_is_authorized_current(
      action => 'Action::"edit"',
      resource => permissions.cedar_uid('Document', id),
      resource_attrs => jsonb_build_object(
        'owner', jsonb_build_object(
          '__entity', jsonb_build_object(
            'type', 'user',
            'id', owner_id
          )
        ),
        'level', level
      )
    )
  );
```

An attribute that is an entity needs the form `{"__entity": {"type", "id"}}`. The other values are strings, numbers, booleans, sets and records. A value that Cedar cannot hold denies the row.

Alice updates the rows that she owns and can see. `owner-edit` allows `draft`. She does not own `q3`, and she cannot see `salaries`:

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', 'alice', true);
update public.documents set title = title || '!';
-- UPDATE 1: draft only
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', 'bob', true);
update public.documents set title = title || '!';
-- UPDATE 1: q3 only
commit;
```

A check for one row costs more than one entry of a list (see [Performance](performance.md#cedar-policies)). Use it for writes, which touch few rows, and for rules on the columns of a row. If a read policy needs the columns of the row, check each row with `cedar_is_authorized_current`, and keep the number of rows small.

### Always use `cedar_uid` for row ids

The resource is Cedar text. Build it with `cedar_uid(type, id)`, which escapes the id:

| Form | An id with a `"` or a `\` |
| --- | --- |
| `permissions.cedar_uid('Document', id::text)` | Works. It is the same id that the policies name. |
| `'Document::"' \|\| id \|\| '"'` | An id with a `"` is not a Cedar string. The check returns `false` for that row. An id with a backslash can read as another id: `a\nb` reads as `a`, a line break, and `b`. The check is then for another resource than the row. |

A row id that is a `uuid` or a number has no such characters, but use `cedar_uid` anyway. An id that comes from users does not need a rule to check it.

### Fail closed

The two functions deny when they cannot decide. This keeps a mistake in a policy from giving access:

- Without a subject, `cedar_is_authorized_current` returns `false`, and the list is empty.
- A `forbid` that applies and gives an error denies the row. The row is left out of the list.
- A `permit` that gives an error is skipped. It gives no access.

The next policy forbids flagged documents. It reads `resource.flagged`. The documents of the example have no attribute `flagged`, so the policy gives an error for every one of them, and every row is denied:

```sql
select permissions.cedar_put_policy(
  policy_id => 'block-flagged',
  policy => 'forbid (principal, action, resource)
when { resource.flagged };'
);
begin;
set local role authenticated;
select set_config('permissions.subject_id', 'alice', true);
select id from public.documents order by id;
-- (0 rows)
commit;
```

`cedar_is_authorized` shows the cause. It lists `block-flagged` in `errors`. Test an attribute with `has` before you read it:

```sql
select permissions.cedar_put_policy(
  policy_id => 'block-flagged',
  policy => 'forbid (principal, action, resource)
when { resource has flagged && resource.flagged };'
);
begin;
set local role authenticated;
select set_config('permissions.subject_id', 'alice', true);
select id from public.documents order by id;
-- draft
-- q3
commit;
```

After a change to a policy or an entity, the next statement of the same transaction sees it. A statement that starts after another transaction commits sees the commit.

### Which function to use

| Need | Use |
| --- | --- |
| Show a page or a count of the rows that a user can read | `cedar_list_resources_current`, in a `select` policy |
| Check one row for an update or a delete | `cedar_is_authorized_current`, in an `update` or `delete` policy |
| A rule on the columns of a row, with few rows | `cedar_is_authorized_current` with `resource_attrs` |
| A rule on the columns of a row, with many rows | Store the column in the entity, and use the list. Or keep the rule in a plain SQL policy. |
| A check for a row that is not an entity | `cedar_is_authorized_current` with `resource_attrs` |

The list does the work once for each query. The check does part of the work once for each query, and the rest for each row. [Performance](performance.md#cedar-policies) has measurements.

## Next step

Continue with [Combine permission models](combine-models.md).
