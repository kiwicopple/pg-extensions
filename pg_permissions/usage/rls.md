# RLS with both models

How to use the `rbac` preset and the OpenFGA model together in row-level security: one table, roles per organization for most access, and per-document sharing on top. The models are separate (a role grants no relation and a tuple grants no role); they meet in the policies. Permissive policies OR together and restrictive policies AND, so adding sharing to an app that started on roles is one more policy, with nothing to migrate.

Every example on this page runs as written in [`test/spec/d/90_usage_rls.sql`](../test/spec/d/90_usage_rls.sql), in the same order. The general RLS rules (the fast path for tenant tables, checking the row on writes, testing as the client role) are in the [README](README.md#writing-rls-policies); this page adds the FGA side. The model's own functions are in [The OpenFGA model](fga.md).

The examples use these IDs:

```sql
\set alice  '11111111-1111-1111-1111-111111111111'
\set bob    '22222222-2222-2222-2222-222222222222'
\set carol  '33333333-3333-3333-3333-333333333333'
\set dave   '44444444-4444-4444-4444-444444444444'
\set erin   '55555555-5555-5555-5555-555555555555'
\set acme   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
\set globex 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
\set eng    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
\set plan   'd0000000-0000-0000-0000-000000000001'
\set readme 'd0000000-0000-0000-0000-000000000002'
\set notes  'd0000000-0000-0000-0000-000000000003'
\set draft  'd0000000-0000-0000-0000-000000000004'
\set diary  'd0000000-0000-0000-0000-000000000005'
```

## Setup

Two roles, as in the README:

```sql
select permissions.rbac_create_role(role => 'viewer', permissions => '{documents.read}');
select permissions.rbac_create_role(role => 'editor', permissions => '{documents.edit}', inherits => '{viewer}');
```

And a model. `banned` will be a deny across both models; `published` and `reader` are for [row attributes](#row-attributes-that-only-rls-sees):

```
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
    define viewer: [user, team#member] or editor
    define published: [user:*]
    define reader: (viewer and published) or editor
```

```sql
-- model.json is the output of: fga model transform --file model.fga > model.json
\set model `cat model.json`
select permissions.fga_write_authorization_model(model => :'model');
```

The table. `org_id` is null for a personal document:

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

Roles and tuples. Object and user IDs in tuples are text, so a UUID goes in as `'document:' || id`:

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

## The current-subject functions

Clients and policies can't call `fga_check`, which takes the user as an argument ([Privileges](fga.md#privileges)). They call these, which ask for the current subject, `user:<current_subject_id()>` (the type is `current_subject_type()`, `user` by default; [Identity](README.md#identity)):

| Function | Returns | Use it for |
| --- | --- | --- |
| `fga_check_current(relation, object)` | `boolean` | one row: update, delete, insert policies |
| `fga_list_object_ids_current(type, relation)` | `setof text`, bare ids | read policies: `id = any (array(select ...::uuid))` |
| `fga_list_objects_current(type, relation)` | `setof text`, `type:id` | clients that want OpenFGA's form |

```sql
-- as Bob
select permissions.fga_check_current(relation => 'editor', object => 'document:' || :'readme');  -- true
select permissions.fga_list_object_ids_current(type => 'document', relation => 'viewer');        -- the readme, notes and draft ids
select permissions.fga_list_objects_current(type => 'document', relation => 'viewer');           -- the same as document:<id>
```

With no subject they return false and nothing, and the same with no model yet or a subject type the model doesn't define: a policy denies instead of failing. Unlike `fga_list_objects`, the list functions have no 1,000 cap: a cap in a policy would hide rows without an error.

## Policies

```sql
-- reads: permissive policies OR together
create policy documents_select_rbac on public.documents for select to authenticated
    using (org_id = any (array(select unnest(permissions.rbac_scopes_with_permission(permission => 'documents.read'))::uuid)));
create policy documents_select_fga on public.documents for select to authenticated
    using (id = any (array(select permissions.fga_list_object_ids_current(type => 'document', relation => 'viewer')::uuid)));
-- a restrictive policy ANDs: nobody sees the documents of an org they are banned from
create policy documents_not_banned on public.documents as restrictive for select to authenticated
    using (org_id is null or org_id <> all (array(select permissions.fga_list_object_ids_current(type => 'org', relation => 'banned')::uuid)));
-- writes: check the row
create policy documents_update_rbac on public.documents for update to authenticated
    using (permissions.rbac_has_permission(permission => 'documents.edit', scope => org_id::text));
create policy documents_update_fga on public.documents for update to authenticated
    using (permissions.fga_check_current(relation => 'editor', object => 'document:' || id));
```

What each user sees:

| User | Holds | Sees | Updates |
| --- | --- | --- | --- |
| Alice | `viewer` in acme | acme plan, acme readme | nothing |
| Bob | no role; team eng; editor of the acme readme | acme readme, globex notes, globex draft | acme readme |
| Carol | `editor` in acme | acme plan, acme readme | both acme documents |
| Dave | `viewer` in acme; banned from acme; owner of his diary; viewer of the globex notes | globex notes, dave's diary | |
| Erin | nothing | nothing | nothing |

Dave's acme role is overridden by the ban, because the restrictive policy applies to every row whatever the permissive ones said. That is how a deny works across models. Inside the FGA model a deny is `but not` ([Check](fga.md#check)), and it holds wherever that relation is used. But a `but not` on `document#viewer` doesn't stop an RBAC arm that grants the same row; only a restrictive policy does. Likewise, if a read policy has a second arm for a parent (`folder_id = any (... 'folder', 'viewer' ...)`), a `but not` on the document isn't seen by that arm. List the relation that contains the deny.

Write `org_id is null or` in a restrictive policy on a nullable column. A comparison with null is null, RLS treats null as false, and without it Dave would lose his personal diary because he is banned from an org it doesn't belong to:

```sql
select null::uuid <> all (array[:'acme'::uuid]);   -- null, not true
```

## Plan-time evaluation

A read policy's list must be computed once per query, not once per row, and not while the query is planned, which would run it a second time ([PLAN.md](../PLAN.md) §4). The form above does that: the `fga_list_object_ids_current` list functions return a set, and Postgres never calls a set-returning function while planning. `EXPLAIN` shows one InitPlan per list policy and no per-row SubPlan:

```sql
explain select * from public.documents;   -- as Bob: three InitPlans, no SubPlan
```

Keep it that way:

- Use `id = any (array(select f(...)::uuid))`, with the cast inside. `id in (select ...)` stops the table's index from being used, as for `rbac_scopes_with_permission` ([README](README.md#tenant-tables-the-fast-path)).
- Call the set-returning function directly. Don't wrap it in your own function that returns an array: Postgres can evaluate a STABLE function with constant arguments while planning (that is why `rbac_scopes_with_permission` has a trailing parameter that isn't yours to pass), and marking the wrapper VOLATILE has its own problem ([README](README.md#other-rules)).
- Use `fga_check_current` only in write policies, which touch a few rows. In a read policy it runs once per row.

## Typos raise

A misspelled relation or type in an FGA call is an error, not a silent "no access", in policies too:

```sql
select permissions.fga_check_current(relation => 'editr', object => 'document:x');
-- ERROR:  relation 'document#editr' not found
-- DETAIL:  openfga:2000 validation_error
-- HINT:  Did you mean 'editor'? Relations on type 'document': editor, owner, published, reader, viewer.
select permissions.fga_list_object_ids_current(type => 'documnt', relation => 'viewer');   -- ERROR, openfga:2000
```

The `rbac` preset is the other way round: an unknown permission is false ([README](README.md#function-reference)), so a policy that names a dropped permission denies instead of breaking every query:

```sql
select permissions.rbac_has_permission(permission => 'documents.reed');   -- false
```

## Row attributes that only RLS sees

A rule on a column of the row, such as "drafts are visible to editors only", belongs in RLS:

```sql
create policy documents_published on public.documents as restrictive for select to authenticated
    using (status = 'published' or id = any (array(select permissions.fga_list_object_ids_current(type => 'document', relation => 'editor')::uuid)));
```

The check functions don't read your tables, so they don't know about it. Bob views the draft through his team; RLS hides it, but `fga_check_current` still says yes:

```sql
-- as Bob
select title from public.documents;                                                             -- acme readme, globex notes: no draft
select permissions.fga_check_current(relation => 'viewer', object => 'document:' || :'draft');  -- true
```

So treat the check functions as advisory and RLS as final. Use the checks to decide what to show in a UI, and let the query, under RLS, decide what is returned. If a check must take the attribute into account, pass the attribute in. With the model's `published` and `reader` relations, a backend sends the row's status as a contextual tuple, which is never written:

```sql
select permissions.fga_check(subject => 'user:' || :'bob', relation => 'reader', object => 'document:' || d.id,
    contextual_tuples => case when d.status = 'published'
        then jsonb_build_array(jsonb_build_object('user', 'user:*', 'relation', 'published', 'object', 'document:' || d.id))
    end)
from public.documents d where d.id = :'notes';   -- true
-- the same for :'draft' is false: no published tuple, and Bob doesn't edit it
```

This needs `fga_check`, which is admin-only: the current-subject functions take no contextual tuples, because a client could pass any. Attributes on a relationship rather than on a row (an expiry, an IP range) are [OpenFGA conditions](conditions.md); the next section is about them in policies.

## Conditions in policies

The current-subject functions take no request `context` either, for the same reason: a client could claim any time or address. A conditioned tuple counts in a policy when its condition is true from the context stored in the tuple alone. One whose condition needs a request parameter is denied, and so is any answer that depends on a condition that can't be evaluated: an erroring `but not` denies rather than lets the user through. A policy never fails because of a condition.

A new version of the model gives `viewer` a time-limited grant (`[user, user with non_expired_grant, team#member] or editor`, with the condition from [OpenFGA conditions](conditions.md#a-model-with-conditions)), and Erin gets 30 days on the acme plan:

```sql
-- model.json is the model above with the viewer line and the condition changed
\set model `cat model.json`
select permissions.fga_write_authorization_model(model => :'model');
select permissions.fga_write(writes => jsonb_build_array(jsonb_build_object(
    'user', 'user:' || :'erin', 'relation', 'viewer', 'object', 'document:' || :'plan',
    'condition', jsonb_build_object('name', 'non_expired_grant',
        'context', jsonb_build_object('grant_time', now() - interval '1 day', 'grant_duration', '720h')))));

-- as Erin
select id from public.documents;                                                               -- nothing: the policies have no current_time
select permissions.fga_check_current(relation => 'viewer', object => 'document:' || :'plan');  -- false, not an error
```

A value the server can vouch for, such as the time, can be passed by a function of your own that calls `fga_check` (admin-only, so the function is `security definer`, like the trigger below) and supplies it:

```sql
create function public.fga_check_now(relation text, object text) returns boolean
language plpgsql stable security definer set search_path = ''
as $$
begin
    return permissions.fga_check(subject => 'user:' || permissions.current_subject_id(),
                                 relation => relation, object => object,
                                 context => jsonb_build_object('current_time', now()));
exception when invalid_parameter_value then
    return false;   -- no subject, or a condition that still can't be evaluated (openfga:2000): deny
end;
$$;
revoke all on function public.fga_check_now(text, text) from public;
grant execute on function public.fga_check_now(text, text) to authenticated;

create policy documents_select_timed on public.documents for select to authenticated
    using (public.fga_check_now('viewer', 'document:' || id));

-- as Erin
select id from public.documents;   -- the acme plan, for 29 more days
```

That is one Check per row, each in an exception block (a subtransaction): fine for a single row or a short list, slow for a wide one. Whether the extension should give the RLS helpers trusted values such as the time itself is an open question ([`designs/d-conditions.md`](../designs/d-conditions.md), open question 2).

## Cleaning up when a user is deleted

The extension doesn't know about your users table. `delete_subject(type, id)` removes a subject from both models: its role assignments (for `user`) and every tuple that names it as user, as a userset or as object. Call it from a trigger:

```sql
create table public.users (id uuid primary key);
insert into public.users values (:'alice'), (:'bob'), (:'carol'), (:'dave'), (:'erin');

create function public.forget_user() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
    perform permissions.delete_subject(subject_type => 'user', subject_id => old.id::text);
    return old;
end;
$$;
create trigger forget_user after delete on public.users
    for each row execute function public.forget_user();

delete from public.users where id = :'dave';
-- his acme role and his three tuples are gone
```

The trigger function is `security definer` because `delete_subject` is admin-only. It works for any type and returns how many rows it removed: `delete_subject(subject_type => 'team', subject_id => :'eng')` removes the team's two viewer tuples and Bob's membership (3).
