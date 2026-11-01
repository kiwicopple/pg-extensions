# RLS policies

This page shows how to write row level security (RLS) policies with `pg_permissions`. First it gives the rules for policies that use [RBAC](rbac.md). Then it shows how to use RBAC and the [OpenFGA model](fga.md) together on one table.

The two models are separate. A role does not give a relation, and a tuple does not give a role. They meet in the policies. Permissive policies combine with OR. Restrictive policies combine with AND.

To give access to single objects in an app that started with roles, add one more policy. You do not need to migrate data.

## Before you start

Run the examples in order, in an empty database, as the role that installed the extension (the admin). Examples that start with `set local role authenticated` show what a client sees. The [RBAC page](rbac.md#before-you-start) explains the `anon`, `authenticated` and `service_role` roles.

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

select permissions.rbac_create_role(role => 'viewer', permissions => '{documents.read}');
select permissions.rbac_create_role(role => 'editor', permissions => '{documents.edit}', inherits => '{viewer}');
```

## Policies for RBAC

### Tenant tables: the fast path

For a table with a tenant column, write a read policy in exactly this form:

```text
org_id = any (array(select unnest(permissions.rbac_scopes_with_permission(permission => 'documents.read'))::uuid))
```

Postgres computes the list of scopes of the user once for each query, as an InitPlan. Then it uses the index on `org_id`. `EXPLAIN` shows an InitPlan and no per-row SubPlan.

Three other forms look correct, but they are worse. These are fragments:

```text
-- 1. Does not work
org_id = any ((select permissions.rbac_scopes_with_permission(permission => 'documents.read')))
-- ERROR:  operator does not exist: uuid = text[]

-- 2. Works, but is slower on a big table
org_id = any ((select permissions.rbac_scopes_with_permission(permission => 'documents.read'))::uuid[])

-- 3. Works, but the index of the table is not used
org_id in (select unnest(permissions.rbac_scopes_with_permission(permission => 'documents.read'))::uuid)
```

- Form 1: Postgres reads `any ((select ...))` as a subquery comparison. It fails even with the double parentheses.
- Form 2: Postgres applies the `::uuid[]` cast again to each row that it filters. On Postgres 16 with 1 million rows, a page of 50 documents took 3.64 ms instead of 0.73 ms.
- Form 3: `in (select ...)` becomes a hashed subquery, and the index on `org_id` is not used. To count the documents that one user sees took 88.8 ms instead of 2.2 ms.

Forms 2 and 3 return the same rows as the fast path. They cost more.

### Writes: check the row

For UPDATE, DELETE and INSERT, check the one row that the statement writes. Use the per-row form. These are fragments:

```text
using (permissions.rbac_has_permission(permission => 'documents.edit', scope => org_id::text))       -- update, delete
with check (permissions.rbac_has_permission(permission => 'documents.edit', scope => org_id::text))  -- insert
```

A write touches few rows, so one call for each row is cheap. The policy then reads like the rule. The fast path would build the whole list of scopes of the user for each statement. For UPDATE, `with check` defaults to the `using` expression.

Scopes are text. Pass the scope as `org_id::text`.

### App-wide or scoped checks

`rbac_has_permission` without a `scope` looks only at app-wide roles. With a `scope`, it looks only at that scope. To let app-wide roles also work on a tenant table, use both checks in the policy.

This example uses a `projects` table. The role assignments below give each user a different access:

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
        (select permissions.rbac_has_permission(permission => 'documents.read'))
        or org_id = any (array(select unnest(permissions.rbac_scopes_with_permission(permission => 'documents.read'))::uuid))
    );
create policy projects_update on public.projects for update to authenticated
    using (
        (select permissions.rbac_has_permission(permission => 'documents.edit'))
        or permissions.rbac_has_permission(permission => 'documents.edit', scope => org_id::text)
    );

select permissions.rbac_assign_role(user_id => :'gina', role => 'viewer');
select permissions.rbac_assign_role(user_id => :'hugo', role => 'viewer', scope => :'globex');
select permissions.rbac_assign_role(user_id => :'ivan', role => 'editor', scope => :'acme');
select permissions.rbac_assign_role(user_id => :'ivan', role => 'viewer', scope => :'globex');
select permissions.rbac_assign_role(user_id => :'jane', role => 'editor');
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
select name from public.projects;                                                          -- gemini
select permissions.rbac_has_permission(permission => 'documents.read');                    -- false: Hugo has no app-wide role
select permissions.rbac_has_permission(permission => 'documents.read', scope => :'globex');  -- true
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'ivan', true);
update public.projects set name = upper(name);                                             -- UPDATE 1: apollo only
commit;
```

The `or` has a cost. Postgres cannot use the `org_id` index for the scoped arm. A test on Postgres 16 used 500,000 rows in 200 organizations. A user who sees 7,500 rows counted them in about 1 ms with the single-check policy. The policy with two checks took about 20 ms. A page of 50 rows took about 1 ms with both policies.

If a table does not need app-wide roles, use the single check.

### Other rules

- **Do not fix plan-time evaluation yourself.** `rbac_scopes_with_permission` is `STABLE`, with a last argument that makes the planner skip the call at plan time. Do not pass that argument, and do not mark your own wrapper functions `VOLATILE`. In `read committed`, a volatile function reads the grants at a later time than the rows that it filters.
- **Give each policy a role.** Write `to authenticated`, or the role that your requests use, and run `alter table ... enable row level security`. A superuser, or an owner without `force row level security`, bypasses each policy.
- **Clients never write permission data.** Clients have no privilege on the tables. The functions that write are admin-only.

## Policies for both models

The rest of this page builds one table with both models. Most access comes from roles for each organization. Some access comes from shares of single documents.

### Write the models

The model has teams, organizations and documents. The relation `banned` will be a deny across both models. The relations `published` and `reader` are for [row attributes](#row-attributes-that-only-rls-sees). The condition `non_expired_grant` is for [conditions in policies](#conditions-in-policies).

```text
model
  schema 1.1

type user

type team
  relations
    define member: [user]

type org
  relations
    define banned: [user]

type document
  relations
    define owner: [user]
    define editor: [user] or owner
    define viewer: [user, user with non_expired_grant, team#member] or editor
    define published: [user:*]
    define reader: (viewer and published) or editor

condition non_expired_grant(current_time: timestamp, grant_time: timestamp, grant_duration: duration) {
  current_time < grant_time + grant_duration
}
```

Write the model as JSON. This JSON is the output of `fga model transform` for the model above:

```sql
select permissions.fga_write_authorization_model(model => $json$
{"schema_version":"1.1","type_definitions":[
 {"type":"user"},
 {"type":"team",
  "relations":{
   "member":{"this":{}}
  },
  "metadata":{"relations":{
   "member":{"directly_related_user_types":[{"type":"user"}]}
  }}},
 {"type":"org",
  "relations":{
   "banned":{"this":{}}
  },
  "metadata":{"relations":{
   "banned":{"directly_related_user_types":[{"type":"user"}]}
  }}},
 {"type":"document",
  "relations":{
   "editor":{"union":{"child":[{"this":{}},{"computedUserset":{"relation":"owner"}}]}},
   "owner":{"this":{}},
   "published":{"this":{}},
   "reader":{"union":{"child":[{"intersection":{"child":[{"computedUserset":{"relation":"viewer"}},{"computedUserset":{"relation":"published"}}]}},{"computedUserset":{"relation":"editor"}}]}},
   "viewer":{"union":{"child":[{"this":{}},{"computedUserset":{"relation":"editor"}}]}}
  },
  "metadata":{"relations":{
   "editor":{"directly_related_user_types":[{"type":"user"}]},
   "owner":{"directly_related_user_types":[{"type":"user"}]},
   "published":{"directly_related_user_types":[{"type":"user","wildcard":{}}]},
   "reader":{},
   "viewer":{"directly_related_user_types":[{"type":"user"},{"condition":"non_expired_grant","type":"user"},{"relation":"member","type":"team"}]}
  }}}
],
"conditions":{"non_expired_grant":{"expression":"current_time < grant_time + grant_duration","name":"non_expired_grant","parameters":{"current_time":{"type_name":"TYPE_NAME_TIMESTAMP"},"grant_duration":{"type_name":"TYPE_NAME_DURATION"},"grant_time":{"type_name":"TYPE_NAME_TIMESTAMP"}}}}}
$json$::jsonb);
```

### Create the table and the data

The table has an `org_id` column. The value is null for a personal document:

```sql
create table public.documents (
    id     uuid primary key,
    org_id uuid,                 -- null: a personal document
    status text not null default 'published',
    title  text not null
);
create index on public.documents (org_id);
insert into public.documents (id, org_id, status, title) values
    (:'plan',   :'acme',   'published', 'acme plan'),
    (:'readme', :'acme',   'published', 'acme readme'),
    (:'notes',  :'globex', 'published', 'globex notes'),
    (:'draft',  :'globex', 'draft',     'globex draft'),
    (:'diary',  null,      'published', 'dave''s diary');
alter table public.documents enable row level security;
grant select, update on public.documents to authenticated;
```

Now add the roles and the tuples. The IDs in tuples are text. A UUID goes in as `'document:' || id`:

```sql
-- RBAC: Alice reads acme, Carol edits acme, Dave reads acme
select permissions.rbac_assign_role(user_id => :'alice', role => 'viewer', scope => :'acme');
select permissions.rbac_assign_role(user_id => :'carol', role => 'editor', scope => :'acme');
select permissions.rbac_assign_role(user_id => :'dave',  role => 'viewer', scope => :'acme');
-- FGA: team eng (Bob) views the globex notes and the draft, Bob edits the acme
-- readme, Dave owns his diary, views the globex notes and is banned from acme
select permissions.fga_write(writes => jsonb_build_array(
    jsonb_build_object('user', 'user:' || :'bob',  'relation', 'member', 'object', 'team:' || :'eng'),
    jsonb_build_object('user', 'team:' || :'eng' || '#member', 'relation', 'viewer', 'object', 'document:' || :'notes'),
    jsonb_build_object('user', 'team:' || :'eng' || '#member', 'relation', 'viewer', 'object', 'document:' || :'draft'),
    jsonb_build_object('user', 'user:' || :'bob',  'relation', 'editor', 'object', 'document:' || :'readme'),
    jsonb_build_object('user', 'user:' || :'dave', 'relation', 'owner',  'object', 'document:' || :'diary'),
    jsonb_build_object('user', 'user:' || :'dave', 'relation', 'viewer', 'object', 'document:' || :'notes'),
    jsonb_build_object('user', 'user:' || :'dave', 'relation', 'banned', 'object', 'org:' || :'acme')));
```

### Current-subject functions

Clients and policies cannot call `fga_check`, because it takes the user as an argument. It is admin-only. Clients call these functions instead. They ask for the current subject, `user:<current_subject_id()>`. The type is `current_subject_type()`, which is `user` by default. See [Identity](rbac.md#identity).

| Function | Returns | Use it for |
| --- | --- | --- |
| `fga_check_current(relation, object)` | `boolean` | one row: update, delete and insert policies |
| `fga_list_object_ids_current(type, relation)` | `setof text`, bare IDs | read policies: `id = any (array(select ...::uuid))` |
| `fga_list_objects_current(type, relation)` | `setof text`, as `type:id` | clients that want the form of OpenFGA |

The [function reference](reference.md) has the full signatures. This example runs as Bob:

```sql
begin;
select set_config('permissions.subject_id', :'bob', true);
select permissions.fga_check_current(relation => 'editor', object => 'document:' || :'readme');  -- true
select permissions.fga_list_object_ids_current(type => 'document', relation => 'viewer');        -- the IDs of the readme, notes and draft
select permissions.fga_list_objects_current(type => 'document', relation => 'viewer');           -- the same, as document:<id>
commit;
```

These functions return false or no rows in three cases. There is no subject, there is no model yet, or the model does not define the subject type. A policy then denies access and does not fail.

The list functions have no limit of 1,000 rows. `fga_list_objects` has that limit. A limit in a policy would hide rows without an error.

### Write the policies

```sql
-- reads: permissive policies combine with OR
create policy documents_select_rbac on public.documents for select to authenticated
    using (org_id = any (array(select unnest(permissions.rbac_scopes_with_permission(permission => 'documents.read'))::uuid)));
create policy documents_select_fga on public.documents for select to authenticated
    using (id = any (array(select permissions.fga_list_object_ids_current(type => 'document', relation => 'viewer')::uuid)));
-- a restrictive policy combines with AND: nobody sees the documents of an org that bans them
create policy documents_not_banned on public.documents as restrictive for select to authenticated
    using (org_id is null or org_id <> all (array(select permissions.fga_list_object_ids_current(type => 'org', relation => 'banned')::uuid)));
-- writes: check the row
create policy documents_update_rbac on public.documents for update to authenticated
    using (permissions.rbac_has_permission(permission => 'documents.edit', scope => org_id::text));
create policy documents_update_fga on public.documents for update to authenticated
    using (permissions.fga_check_current(relation => 'editor', object => 'document:' || id));
```

This table shows what each user sees:

| User | Holds | Sees | Updates |
| --- | --- | --- | --- |
| Alice | `viewer` in acme | acme plan, acme readme | none |
| Bob | no role; team eng; editor of the acme readme | acme readme, globex notes, globex draft | acme readme |
| Carol | `editor` in acme | acme plan, acme readme | both acme documents |
| Dave | `viewer` in acme; banned from acme; owner of his diary; viewer of the globex notes | globex notes, diary of Dave | diary of Dave |
| Erin | nothing | nothing | none |

The ban overrides the acme role of Dave. The restrictive policy applies to each row, whatever the permissive policies said. This is how a deny works across models.

Inside the OpenFGA model, a deny is `but not`. It holds wherever the model uses that relation. But a `but not` on `document#viewer` does not stop an RBAC policy that gives access to the same row. Only a restrictive policy stops it. A second read arm for a parent, such as `folder_id = any (...)`, also does not see a `but not` on the document. List the relation that holds the deny.

To check the table, run a count as each user:

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'dave', true);
select title from public.documents order by title;   -- dave's diary, globex notes
commit;

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'carol', true);
select title from public.documents order by title;   -- acme plan, acme readme
update public.documents set title = title;           -- UPDATE 2
commit;
```

In a restrictive policy on a nullable column, write `org_id is null or`. A comparison with null gives null, and RLS treats null as false. Without it, Dave would lose his personal diary. An org bans him, and the diary does not belong to that org:

```sql
select null::uuid <> all (array[:'acme'::uuid]);   -- null, not true
```

### Plan-time evaluation

A read policy must compute its list once for each query. It must not compute the list once for each row. It must not compute the list while Postgres plans the query, because that runs it a second time.

The form above does this. The `fga_list_object_ids_current` functions return a set. Postgres never calls a function that returns a set at plan time. `EXPLAIN` shows one InitPlan for each list policy and no per-row SubPlan:

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
explain select * from public.documents;   -- three InitPlans, no SubPlan
commit;
```

To keep it this way, follow these rules:

- Use `id = any (array(select f(...)::uuid))`, with the cast inside. The form `id in (select ...)` makes Postgres skip the index of the table. This is the same as for `rbac_scopes_with_permission` (see [Tenant tables](#tenant-tables-the-fast-path)).
- Call the function that returns a set directly. Do not wrap it in your own function that returns an array. Postgres can evaluate a `STABLE` function with constant arguments while it plans. That is why `rbac_scopes_with_permission` has a last argument that you must not pass. If you mark the wrapper `VOLATILE`, you get another problem (see [Other rules](#other-rules)).
- Use `fga_check_current` only in write policies, which touch few rows. In a read policy, it runs once for each row.

### Mistakes in names raise errors

In an OpenFGA call, a misspelled relation or type is an error. It is not a silent "no access". This is also true in policies. The error needs a subject, because a call with no subject returns false first:

```sql
begin;
select set_config('permissions.subject_id', :'bob', true);
select permissions.fga_check_current(relation => 'editr', object => 'document:x');
-- ERROR:  relation 'document#editr' not found
-- DETAIL:  openfga:2000 validation_error
-- HINT:  Did you mean 'editor'? Relations on type 'document': editor, owner, published, reader, viewer.
rollback;

begin;
select set_config('permissions.subject_id', :'bob', true);
select permissions.fga_list_object_ids_current(type => 'documnt', relation => 'viewer');
-- ERROR:  type 'documnt' not found
-- DETAIL:  openfga:2000 validation_error
rollback;
```

RBAC works the other way. An unknown permission gives false. A policy that names a dropped permission denies access, and does not break each query:

```sql
select permissions.rbac_has_permission(permission => 'documents.reed');   -- false
```

### Row attributes that only RLS sees

A rule on a column of the row belongs in RLS. For example: drafts are visible to editors only.

```sql
create policy documents_published on public.documents as restrictive for select to authenticated
    using (status = 'published' or id = any (array(select permissions.fga_list_object_ids_current(type => 'document', relation => 'editor')::uuid)));
```

The check functions do not read your tables, so they do not know this rule. Bob views the draft through his team. RLS hides the draft, but `fga_check_current` still returns true:

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select title from public.documents order by title;                                              -- acme readme, globex notes: no draft
select permissions.fga_check_current(relation => 'viewer', object => 'document:' || :'draft');  -- true
commit;
```

Treat the check functions as advisory and RLS as final. Use a check to decide what to show in a UI. Let the query, under RLS, decide what it returns.

If a check must use the attribute, pass the attribute in. The model has the relations `published` and `reader`. A backend sends the status of the row as a contextual tuple. The extension never writes a contextual tuple:

```sql
select permissions.fga_check(subject => 'user:' || :'bob', relation => 'reader', object => 'document:' || d.id,
    contextual_tuples => case when d.status = 'published'
        then jsonb_build_array(jsonb_build_object('user', 'user:*', 'relation', 'published', 'object', 'document:' || d.id))
    end)
from public.documents d where d.id = :'notes';   -- true
-- the same query for :'draft' is false: no published tuple, and Bob does not edit it
```

This needs `fga_check`, which is admin-only. The current-subject functions take no contextual tuples, because a client could pass any tuple. An attribute on a relationship, such as an expiry or an IP range, is an [OpenFGA condition](conditions.md). The next section shows conditions in policies.

### Conditions in policies

The current-subject functions take no request `context` either. A client could claim any time or address. In a policy, a conditioned tuple counts when its condition is true with the context stored in the tuple only.

The policy denies a tuple whose condition needs a request value. It also denies an answer that depends on a condition that the extension cannot evaluate. For example, a `but not` that fails denies access. It does not let the user through. A policy never fails because of a condition.

Erin gets 30 days of access to the acme plan. The condition `non_expired_grant` needs `current_time`. The tuple stores `grant_time` and `grant_duration`, but not `current_time`:

```sql
select permissions.fga_write(writes => jsonb_build_array(jsonb_build_object(
    'user', 'user:' || :'erin', 'relation', 'viewer', 'object', 'document:' || :'plan',
    'condition', jsonb_build_object('name', 'non_expired_grant',
        'context', jsonb_build_object('grant_time', now() - interval '1 day', 'grant_duration', '720h')))));

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'erin', true);
select id from public.documents;                                                               -- no rows: the policies have no current_time
select permissions.fga_check_current(relation => 'viewer', object => 'document:' || :'plan');  -- false, not an error
commit;
```

A value that the server can trust, such as the time, can come from a function of your own. The function calls `fga_check` and adds the value. `fga_check` is admin-only, so the function is `security definer`, like the trigger in [RBAC](rbac.md#clean-up-with-delete_subject):

```sql
create function public.fga_check_now(relation text, object text) returns boolean
language plpgsql stable security definer set search_path = ''
as $$
begin
    return permissions.fga_check(subject => 'user:' || permissions.current_subject_id(),
                                 relation => relation, object => object,
                                 context => jsonb_build_object('current_time', now()));
exception when invalid_parameter_value then
    return false;   -- no subject, or a condition that still cannot be evaluated (openfga:2000): deny
end;
$$;
revoke all on function public.fga_check_now(text, text) from public;
grant execute on function public.fga_check_now(text, text) to authenticated;

create policy documents_select_timed on public.documents for select to authenticated
    using (public.fga_check_now(relation => 'viewer', object => 'document:' || id));

begin;
set local role authenticated;
select set_config('permissions.subject_id', :'erin', true);
select title from public.documents;   -- acme plan, for 29 more days
commit;
```

This policy runs one Check for each row, and each Check has an exception block (a subtransaction). Use it for one row or a short list. It is slow for a wide table.

## Clean up when a user is deleted

When you delete a user, call `delete_subject`. It removes the role assignments and the tuples of the user from both models. [RBAC](rbac.md#clean-up-with-delete_subject) shows the trigger.
