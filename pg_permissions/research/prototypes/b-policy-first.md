# Design B: policy-first

> **History.** This guide is for the historical prototype B. Prototype B is one of the three designs that we compared before the extension became design D. The extension is D.
>
> The user docs of the extension are at [Using pg_permissions](../../docs/README.md). This guide describes [`../../prototypes/`](../../prototypes/) and not the extension. It stays as it was. For the extension, see also [The OpenFGA model](../../docs/fga.md) and [RLS with both models](../../docs/rls.md).

This guide shows how to use `pg_permissions` with design B. B keeps two kinds of data. **Facts** say who is in which group and who holds which role on what. **Policies** are Cedar-style `permit` and `forbid` rules.

They say what the facts give permission for. The function `apply_rls` generates the RLS policies on your tables from the policy table. You can also write the RLS policies by hand, with the list functions.

This guide covers design B only. Some topics are the same on every design, and the [shared guide](../../docs/README.md) describes them:

- the install
- the identity of the user (JWT `sub`, `permissions.subject_id`)
- the split of privileges between client and admin
- the `rbac` preset, in [the RBAC guide](../../docs/rbac.md)
- the general RLS rules, in [the RLS guide](../../docs/rls.md)

Read the sections "Identity" and "Roles and privileges" of the shared guide first. This guide assumes that you know them. The design of B and its trade-offs are in [`designs/b-policy-first.md`](../designs/b-policy-first.md). The code is in [`../../prototypes/b-policy-first.sql`](../../prototypes/b-policy-first.sql).

Every example that shows a result runs in [`../../test/spec/b/90_usage_examples.sql`](../../test/spec/b/90_usage_examples.sql). The spec has the same order as this guide and uses one database. The how-to guides use the data of the quick start. To run the spec, use this command:

```bash
./test/run.sh 90_usage_examples --impl prototypes/b-policy-first.sql
```

Contents: [1 Mental model](#1-mental-model) · [2 Quick start](#2-quick-start) · [3 How-to guides](#3-how-to-guides) · [4 API reference](#4-api-reference) · [5 Performance notes](#5-performance-notes) · [6 Warnings and limits](#6-warnings-and-limits)

The IDs are psql variables, as in the shared guide (`:'alice'` and the others from its list). This guide adds some more variables. The spec uses the same names with the values in [`../../test/fixtures/ids.sql`](../../test/fixtures/ids.sql):

```sql
\set gina         '77777777-7777-7777-7777-777777777777'
\set acme_readme  'cccccccc-0000-0000-0000-000000000002'   -- document ids
\set acme_plan    'cccccccc-0000-0000-0000-000000000001'
\set globex_notes 'cccccccc-0000-0000-0000-000000000003'
\set eng          'eeeeeeee-0000-0000-0000-000000000001'   -- team ids
\set platform     'eeeeeeee-0000-0000-0000-000000000002'
\set contractors  'eeeeeeee-0000-0000-0000-000000000003'
\set specs        'ffffffff-0000-0000-0000-000000000001'   -- folder ids
\set plans        'ffffffff-0000-0000-0000-000000000002'
\set announcement 'cccccccc-0000-0000-0000-000000000005'   -- more documents, one for each guide
\set scratch      'cccccccc-0000-0000-0000-000000000009'
\set report1      'dddddddd-0000-0000-0000-000000000001'   -- reports, in 3.11
\set report2      'dddddddd-0000-0000-0000-000000000002'
```

In the examples, "as Dave" means the code below, with `reset role;` at the end. In an app, set the subject for each transaction with `set_config(..., true)`, as the shared guide says.

```sql
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
```

## 1. Mental model

### Facts

Facts are rows that you write with the admin functions. No fact says what a user can do.

| Fact | Means | Written with |
| --- | --- | --- |
| Entity attributes | A jsonb of attributes for a user (or for any entity). Conditions read it as `principal.attrs.*` | `set_attrs` |
| Parent edge | "Child is in parent": a user in a team, a team in a team, a folder in an org, or (optional) a document in a folder | `add_parent`, `remove_parent` |
| Role definition | "`editor` implies `viewer` on documents". Roles belong to a resource type, so a typo fails when you grant | `define_role` |
| Role grant | "This user, or this group, holds this role on this resource", with an optional end time | `grant_role`, `revoke_role` |

A **group** is any entity that has members. It is the parent in a parent edge. Types are free text (`team`, `org`, `folder`), and the type decides nothing by itself. A group can hold role grants. Everything that the group holds goes to its members, also through nested groups.

Your own rows (a document, a project) are not facts. The org or folder of a document is a column of the document. It enters the permission tables only if the document has a grant of its own.

### Policies

A policy is one row in `permissions.policies`:

| Field | Meaning |
| --- | --- |
| `effect` | `permit` or `forbid`. You write it with `permit()` and `forbid()` |
| principal scope | The principals that the policy covers. `principal_type` is the type (default `user`, null for any type). `principal_id` (optional) is one principal. `principal_in_type` and `principal_in_id` (optional) mean "members of this group" |
| `actions`, `resource_type` | What the policy covers: free-text action names (`select`, `update`, `documents.edit`, `comment`) on one resource type |
| `resource_id` | Optional: one specific resource. This is how public access works |
| `roles` | Optional: the principal, or a group of the principal, must hold one of these roles. A role implies the roles below it |
| `via` | Optional: where the principal must hold the role. Null means on the resource itself. `via => 'org'` means on an org that contains the resource |
| `condition` | Optional: a jsonb expression about the principal, the row and the request ([conditions](#37-conditions)) |

A policy with no `roles` needs no grant. It applies to every principal in its scope.

### How a decision is computed

The call `can(action, type, id, row)` does these steps:

1. Take the enabled policies for that resource type and action. Keep the policies whose principal scope matches the subject (its type, its id, its groups). Their principal-side condition must be true.
2. Keep the policies that name this resource (or name no resource). Their resource-side condition must be true for the row.
3. A policy with `roles` matches only if the subject, or a group of the subject, holds a granted role that has not expired. The role must imply one of the roles of the policy. It must be on the **anchor**. The anchor is the resource itself or, with `via`, a parent of that type above the resource.
4. The answer is **true if any permit matches and no forbid matches**. There are no priorities. A forbid always wins.

The parents of the resource are these. First, the keys of the `row` jsonb that name a type (`{"folder": "..."}`). Second, the rows of the resource in `parents`. Last, everything above those.

There is one more rule. Sometimes a forbid can apply to the subject, but it needs an input that the caller did not pass (the folder, an attribute). Then `can()` raises `22023`. It does not quietly skip the forbid ([can() outside RLS](#38-call-can-outside-rls)).

For RLS, the design runs the same policies in reverse, one time for each query. `ids('select', 'document')` returns the ids of the documents that the subject can access through the facts. `ids('select', 'document', 'folder')` returns the ids of the folders whose documents the subject can access. The RLS policy then reads `id = any(<list>) or folder_id = any(<list>)`. Postgres runs each list as an InitPlan and answers from the index of the column. You never write the logic of the lists yourself.

### What the closures mean for you

B stores group and parent membership as a transitive closure (`ancestors`, depth 10 at most). The closure updates when you write a parent edge. Thus a read of a decision never recurses. This has these costs:

- **Parent writes cost more.** `add_parent(c, p)` writes one closure row for each pair of an inner descendant-or-self of `c` and an ancestor-or-self of `p`. A leaf writes no rows (a user that joins a team, a document that goes in a folder). A nested team that holds users writes a few rows. A nested sub-tree of many teams writes the product. Grants, policies and attributes are single-row writes.
- **One advisory lock.** Every parent write takes `pg_advisory_xact_lock(hashtext('permissions.closure'))`. Role definitions take a second lock. Thus the closure writers wait in a queue. The lock lasts until the transaction that writes ends.
- **`repeatable read` is refused.** Parent writes and role-definition writes raise `0A000` under `repeatable read`. The snapshot is older than the lock, so the closure would miss a concurrent edge and give no error. `read committed` and `serializable` are safe.
- **Depth cap 10, cycles rejected.** The function checks both when you write the edge, and it raises `23514`. Depth never causes a partial answer in a check.
- **Parent edges are immutable.** Remove the edge and add it again. An `update` raises `0A000`.

## 2. Quick start

The scenario is the reference scenario in [../plan.md](../plan.md), section 5. Org `acme` has Alice as an admin and Carol as a member. Admins can edit every document. Members can view every document.

A `documents` table holds the documents. Bob is not in the org, and he is an editor of document `readme`. Team `eng` (Carol and Dave) are viewers of `readme`. The role `editor` implies `viewer`.

**1. Declare the roles.** Roles belong to a resource type. `org` and `document` are names that you choose.

```sql
select permissions.define_role('org', 'member');
select permissions.define_role('org', 'admin', '{member}');         -- admin implies member
select permissions.define_role('document', 'viewer');
select permissions.define_role('document', 'editor', '{viewer}');   -- editor implies viewer
```

**2. Write the policies.** Say what the roles give permission for. The policies for the org roles use `via => 'org'`. The principal holds the role on the org of the document, not on the document.

```sql
select permissions.permit('org members view docs', '{select}',        'document', roles => '{member}', via => 'org');
select permissions.permit('org admins edit docs',  '{update,delete}', 'document', roles => '{admin}',  via => 'org');
select permissions.permit('doc viewers view',      '{select}',        'document', roles => '{viewer}');
select permissions.permit('doc editors edit',      '{update}',        'document', roles => '{editor}');
select permissions.permit('org members add docs',  '{insert}',        'document', roles => '{member}', via => 'org');
```

The first three arguments of `permit` and `forbid` are positional (name, actions, resource type). The other arguments are named.

**3. Write the facts.**

```sql
select permissions.grant_role('user', :'alice', 'admin',  'org', :'acme');
select permissions.grant_role('user', :'carol', 'member', 'org', :'acme');
select permissions.add_parent('user', :'carol', 'team', :'eng');
select permissions.add_parent('user', :'dave',  'team', :'eng');
select permissions.grant_role('user', :'bob', 'editor', 'document', :'acme_readme');
select permissions.grant_role('team', :'eng', 'viewer', 'document', :'acme_readme');
```

**4. Create the table and generate its RLS.** `apply_rls` writes one RLS policy for each command. The name of each RLS policy is `permissions_<command>`. The last arguments say which columns hold the parents. Here the org of the document is in `org_id`.

`apply_rls` does not enable RLS and does not grant privileges. Do both yourself. The function runs with your rights, so the owner of the table calls it.

```sql
create table public.documents (
    id     uuid primary key,
    org_id uuid not null,
    title  text not null
);
insert into public.documents values
    (:'acme_readme',  :'acme',   'readme'),
    (:'acme_plan',    :'acme',   'plan'),
    (:'globex_notes', :'globex', 'notes');
alter table public.documents enable row level security;
grant select, update, insert on public.documents to authenticated;

select permissions.apply_rls('public.documents', 'select', 'document', 'id', '{"org": "org_id"}');
select permissions.apply_rls('public.documents', 'update', 'document', 'id', '{"org": "org_id"}');
select permissions.apply_rls('public.documents', 'insert', 'document', 'id', '{"org": "org_id"}');
```

For `select` and `delete`, the expression is the `using` clause. For `insert`, it is the `with check` clause. For `update`, it is both. The function `rls_expression` returns the text that `apply_rls` generated for `select`:

```sql
select permissions.rls_expression('select', 'document', 'id', '{"org": "org_id"}');
```

```sql
(
    id = any (array(select unnest(permissions.ids('select', 'document'))::uuid))
    or org_id = any (array(select unnest(permissions.ids('select', 'document', 'org'))::uuid))
) and not (
    (select permissions.denies_all('select', 'document'))
    or id = any (array(select unnest(permissions.denied_ids('select', 'document'))::uuid))
    or org_id = any (array(select unnest(permissions.denied_ids('select', 'document', 'org'))::uuid))
)
```

The first half is the permit side. It lists the documents that I can access through their own grants, or through an org that I am in. The second half is the forbid side. It is always present, so a forbid that you add later needs no new RLS.

Each call is an uncorrelated subquery. Thus Postgres runs each call one time for each query. The work for each row is an array lookup on the index of the column.

**Or write the RLS by hand.** Use a second table. Postgres combines the policies for one command with OR, so do not add these policies next to the generated policies. The example has the permit side only, with no forbid side. It is correct when you have no forbids. For writes of single rows, a `can()` call for each row is simpler:

```sql
create table public.documents_hand (like public.documents including all);
insert into public.documents_hand select * from public.documents;
alter table public.documents_hand enable row level security;
grant select, update on public.documents_hand to authenticated;

create policy documents_select on public.documents_hand for select to authenticated using (
    id     = any (array(select unnest(permissions.ids('select', 'document'))::uuid))
    or org_id = any (array(select unnest(permissions.ids('select', 'document', 'org'))::uuid))
);
create policy documents_update on public.documents_hand for update to authenticated
    using (permissions.can('update', 'document', id::text, jsonb_build_object('org', org_id)));
```

Use the `id = any (array(select unnest(...)::uuid))` form exactly. The shared guide explains why. For text or bigint keys, pass `id_type` to `rls_expression` ([API](#rls-tools-admin)).

**5. The three questions.**

*Can Bob update readme?* `can_for` takes an explicit subject, and only an admin can use it. The last argument is the row. Here the row has only its org:

```sql
select permissions.can_for('user', :'bob', 'update', 'document', :'acme_readme',
                           jsonb_build_object('org', :'acme'));    -- true: "doc editors edit"
```

*Which documents can Dave see?* Ask RLS, as Dave:

```sql
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select title from public.documents;                                  -- readme (through team eng)
select permissions.can('select', 'document', :'acme_readme',
                       jsonb_build_object('org', :'acme'));         -- true
select permissions.can('select', 'document', :'acme_plan',
                       jsonb_build_object('org', :'acme'));         -- false
update public.documents set title = 'readme v2'
where id = :'acme_readme';                                          -- UPDATE 0: a viewer cannot edit
reset role;
```

The other users get these results through the same RLS. Bob sees `readme` and can update it (`UPDATE 1`). Carol and Alice see `readme` and `plan`. Alice can update `plan`. Erin has no grants and sees nothing.

Carol can insert a document into `acme`. She gets `42501` for `globex`. Dave is in no org and cannot insert at all.

*Who can view readme?* `who_can` is for admins only. Without the row, it finds the people who hold grants on `readme`, from its own policies. Pass the org to find the org members also:

```sql
select distinct subject_id from permissions.who_can('select', 'document', :'acme_readme')
where subject_type = 'user';                                         -- Bob, Carol, Dave

select distinct subject_id from permissions.who_can('select', 'document', :'acme_readme',
                                                    jsonb_build_object('org', :'acme'))
where subject_type = 'user';                                         -- Alice, Bob, Carol, Dave
```

The function `explain` says why Dave is in the list:

```sql
select * from permissions.explain('user', :'dave', 'select', 'document', :'acme_readme');
--  effect | policy           | matched_grant
--  permit | doc viewers view | {"on": "document:<readme>", "role": "viewer", "principal": "team:<eng>"}
```

## 3. How-to guides

Each guide continues from the data of the quick start. When a guide adds a demo policy that a later guide must not see, the guide ends with an undo step.

### 3.1 Share one object

To share a document, grant a role on it. The type must declare the role. A policy must say what the role gives permission for (the quick start has `doc viewers view` and `doc editors edit`).

```sql
select permissions.grant_role('user', :'erin', 'viewer', 'document', :'acme_readme');
```

Erin can now see `readme` through RLS. The call `permissions.ids('select', 'document')` as Erin returns `{readme}`. That is the list "what is shared with me". Erin cannot update `readme`. Grants add up. When you also grant `editor`, she can update `readme`, and the viewer grant stays.

```sql
select permissions.grant_role('user', :'erin', 'editor', 'document', :'acme_readme');
select permissions.can_for('user', :'erin', 'update', 'document', :'acme_readme');   -- true
```

This query shows who has access, and through which policy:

```sql
select subject_id, policy from permissions.who_can('select', 'document', :'acme_readme')
where subject_type = 'user';
-- Bob, Carol, Dave and Erin, each with 'doc viewers view'
```

Use `revoke_role` to revoke a grant. It returns true if it removed a grant. A grant of a role that the type does not declare raises `22023`:

```sql
select permissions.revoke_role('user', :'erin', 'editor', 'document', :'acme_readme');   -- true
select permissions.revoke_role('user', :'erin', 'viewer', 'document', :'acme_readme');   -- true
select permissions.revoke_role('user', :'erin', 'viewer', 'document', :'acme_readme');   -- false
select permissions.grant_role('user', :'erin', 'owner', 'document', :'acme_readme');     -- ERROR 22023: unknown role owner on document
```

The RLS needs no change, because the `id = any(ids(...))` arm already reads grants. To share with a group, make the same call with the group as the principal. The quick start shares `readme` with team `eng`.

### 3.2 Groups and nested teams

Use `add_parent('user', ..., 'team', ...)` to add a user to a team. Use the same call to nest a team in another team. Whatever the outer team holds goes to the members of the inner team.

```sql
select permissions.add_parent('team', :'eng', 'team', :'platform');     -- eng is in platform
select permissions.grant_role('team', :'platform', 'viewer', 'document', :'acme_plan');
select permissions.is_in('user', :'dave', 'team', :'platform');          -- true
select permissions.is_in('user', :'erin', 'team', :'platform');          -- false
```

As Dave, RLS now shows `readme` (through `eng`) and `plan` (through `platform`). The closure table has a row for the inner node `eng` and no rows for the users. The `closure` view adds them:

```sql
select ancestor_type, ancestor_id, depth from permissions.closure
where child_type = 'user' and child_id = :'dave';
--  team | <eng>      | 1
--  team | <platform> | 2
```

The function refuses cycles, depth beyond 10 and `repeatable read` when you write the edge:

```sql
select permissions.add_parent('team', :'platform', 'team', :'eng');
-- ERROR 23514: permissions: team <eng> is inside team <platform>, so making it a parent would create a cycle

-- a chain of 10 edges is fine, an 11th level is not
select permissions.add_parent('chain', 'c' || i, 'chain', 'c' || (i + 1)) from generate_series(1, 10) i;
select permissions.add_parent('chain', 'c11', 'chain', 'c12');
-- ERROR 23514: permissions: nesting chain c11 in chain c12 would be 11 levels deep (max 10)

set default_transaction_isolation = 'repeatable read';
select permissions.add_parent('chain', 'x1', 'chain', 'x2');
-- ERROR 0A000: permissions: changing parents or roles is not supported under repeatable read
-- (define_role raises the same)
reset default_transaction_isolation;
```

`remove_parent` returns true if the edge existed. Dave loses what `eng` and `platform` gave him:

```sql
select permissions.remove_parent('user', :'dave', 'team', :'eng');      -- true
select permissions.can_for('user', :'dave', 'select', 'document', :'acme_plan');   -- false
select permissions.remove_parent('user', :'dave', 'team', :'eng');      -- false
select permissions.add_parent('user', :'dave', 'team', :'eng');         -- add Dave again
```

The guide then undoes its demo with `revoke_role('team', :'platform', ...)` and `remove_parent('team', :'eng', 'team', :'platform')`.

Membership has no expiry. Only role grants have an expiry (next section).

### 3.3 Expiry

A grant can end at a time. The time is the last argument of `grant_role`. It is a column of `role_grants`, so it costs nothing at read time and needs no policy:

```sql
select permissions.grant_role('user', :'erin', 'viewer', 'document', :'acme_readme', now() + interval '7 days');
select permissions.can_for('user', :'erin', 'select', 'document', :'acme_readme');   -- true until then
```

If you call `grant_role` again for the same principal, role and resource, it replaces the date. A later date extends the grant. A `null` makes the grant permanent. The next example uses a date in the past, as if the week passed:

```sql
select permissions.grant_role('user', :'erin', 'viewer', 'document', :'acme_readme', now() - interval '1 minute');
select permissions.can_for('user', :'erin', 'select', 'document', :'acme_readme');   -- false
```

RLS also hides the row. As Erin, `select title from public.documents` returns nothing. Expired rows stay in the table. Delete them from time to time:

```sql
delete from permissions.role_grants where expires_at < now();
```

### 3.4 Parent inheritance with `via`

A policy with `via => 'org'` or `via => 'folder'` gives permission through a **parent** of the resource. B can learn the parents of a resource in two ways. You choose the way for each resource type:

- **From the columns of the row.** The document says which folder it is in (`folder_id`). The document never appears in the permission tables. `can()` receives the column in its `row` argument as `{"folder": <id>}`. RLS gets the column name as a `via` column.
- **From `parents` facts.** The folder is an entity. `add_parent('folder', :'specs', 'org', :'acme')` says that folder `specs` is in `acme`. Thus a policy with `via => 'org'` gives access to a document through its folder. You can do the same for the document itself (`add_parent('document', id, 'folder', folder_id)`). This has a cost, which this section describes below.

Put folders in orgs and give the document a `folder_id` column:

```sql
select permissions.define_role('folder', 'viewer');
select permissions.add_parent('folder', :'specs', 'org', :'acme');
select permissions.add_parent('folder', :'plans', 'org', :'acme');
select permissions.permit('folder viewers view docs', '{select}', 'document', roles => '{viewer}', via => 'folder');
select permissions.grant_role('user', :'erin', 'viewer', 'folder', :'specs');

alter table public.documents add column folder_id uuid;
update public.documents set folder_id = :'specs' where id = :'acme_readme';
update public.documents set folder_id = :'plans' where id = :'acme_plan';
```

`can()` answers from the folder of the row. The org of the folder comes from the stored edge. Thus Carol, an org member, has access to `plan` through folder `plans`, and the caller does not pass the org. You can also pass the org directly:

```sql
select permissions.can_for('user', :'erin',  'select', 'document', :'acme_readme', jsonb_build_object('folder', :'specs'));  -- true
select permissions.can_for('user', :'erin',  'select', 'document', :'acme_plan',   jsonb_build_object('folder', :'plans'));  -- false
select permissions.can_for('user', :'carol', 'select', 'document', :'acme_plan',   jsonb_build_object('folder', :'plans'));  -- true
select permissions.can_for('user', :'carol', 'select', 'document', :'acme_plan',   jsonb_build_object('org', :'acme'));      -- true
```

**RLS shape 1: projection onto the parent column.** `ids(action, type, via)` does not list documents. It lists the **parent ids** whose documents the caller can access. These are the folders where the caller holds a role, and every folder below an org or folder where the caller holds a role. Thus one branch on `folder_id` covers org-level access and folder-level access together.

```sql
select permissions.ids_for('user', :'erin',  'select', 'document', 'folder');   -- {specs}
select permissions.ids_for('user', :'carol', 'select', 'document', 'folder');   -- {specs, plans}  (every folder in her org)
select permissions.ids_for('user', :'carol', 'select', 'document', 'org');      -- {acme}
select permissions.ids_for('user', :'erin',  'select', 'document', 'org');      -- {}
```

RLS that you wrote before the folder policy existed does not know the policy. Erin sees nothing, because the RLS fails closed. `lint()` does not report it. Regenerate the RLS with the new `via` column. Here, use both columns ([3.10](#310-regenerate-rls-when-policies-change-shape)):

```sql
select permissions.apply_rls('public.documents', 'select', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
select permissions.apply_rls('public.documents', 'update', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
```

Erin now sees `readme`, and Carol still sees both documents. We measured this shape on 1M documents (PG 18, Docker, p50). A page of 50 takes **1.15 ms**. A count takes 8.20 ms. About 8 ms is the floor of that count for all three designs. To move a document, use `update` on its column.

**RLS shape 2: single branch from `parents` rows.** If every document has a row in `parents`, `ids('select', 'document')` itself lists every document that the caller can access. Thus the policy has one branch and no column names:

```sql
select permissions.add_parent('document', id::text, 'folder', folder_id::text)
from public.documents where folder_id is not null;

create table public.documents_flat (like public.documents including all);
insert into public.documents_flat select * from public.documents;
alter table public.documents_flat enable row level security;
grant select on public.documents_flat to authenticated;
create policy documents_select on public.documents_flat for select to authenticated using (
    id = any (array(select unnest(permissions.ids('select', 'document'))::uuid))
);
select permissions.ids_for('user', :'carol', 'select', 'document');   -- {readme, plan}
```

Carol sees `readme` and `plan` from `documents_flat`. Erin sees `readme`. When the `parents` row is stored, `can()` does not need the folder in its row now.

The cost is the main point of the choice. You need one `parents` row for each document, and you must keep the rows in step with your column. We measured both shapes on 1M documents (PG 18, Docker, p50):

| | projection (shape 1) | single branch (shape 2) |
| --- | --- | --- |
| page of 50 | 1.15 ms | 13.7 ms (about 12x) |
| count | 8.20 ms | 21.6 ms |
| seed (1M `parents` rows) | none | 44.8 s |
| storage added | none | about 357 MB |

At medium scale with wide memberships (100k documents, 50 teams for each user), the two shapes are close. A page takes 15.1 ms and 13.7 ms. Use shape 1 if you can. Use shape 2 when you cannot name the parent columns in the policy. Also use shape 2 when you want `can()` and `who_can` to work from the facts alone.

The rows must follow the column. If you move a document in the column only, it keeps its old `parents` row. That stale row continues to feed `ids()` on every table, shape 1 included. In the example, `readme` moves to `plans` in the column. Erin holds `specs`, and she still sees `readme` until the `parents` row moves also:

```sql
update public.documents set folder_id = :'plans' where id = :'acme_readme';
-- as Erin: select title from public.documents  ->  readme   (stale parents row)
select permissions.remove_parent('document', :'acme_readme', 'folder', :'specs');
select permissions.add_parent('document', :'acme_readme', 'folder', :'plans');
-- as Erin: select title from public.documents  ->  nothing
```

Use a trigger on the table to keep the rows in step. Or do not store document edges. For shape 2, every document needs a `parents` row, also a document with no folder. Point such a document at the org. The guide undoes its demo: it moves `readme` back, drops `documents_flat`, and removes the document edges.

### 3.5 Public access

Public access is a policy with no roles on one resource. It applies to every subject that is signed in:

```sql
insert into public.documents (id, org_id, title) values (:'announcement', :'globex', 'announcement');
select permissions.permit('announcement is public', '{select}', 'document', resource_id => :'announcement');
```

As Frank, who has no grants at all, `select title from public.documents` returns `announcement`. He cannot update it. With no subject, RLS returns nothing and `can()` is false. "Public" means every user that the design identifies.

It does not mean `anon`. Drop the policy to revoke the access. `drop_policy` returns true if the policy existed:

```sql
select permissions.drop_policy('announcement is public');   -- true
select permissions.drop_policy('announcement is public');   -- false
```

The generated RLS needs no change for a `resource_id` policy, because the id arm lists it. For "everyone in a group can see every document" (a policy with no roles and no `resource_id`), see [3.10](#310-regenerate-rls-when-policies-change-shape).

### 3.6 Forbid policies

`forbid` has the same arguments as `permit`. A forbid that matches beats every permit, also a permit that comes from an org or a team.

**On one user.**

```sql
select permissions.forbid('block dave on readme', '{select,update,delete}', 'document',
                          resource_id => :'acme_readme', principal_id => :'dave');
```

Dave is in team `eng`, which can view `readme`, and the forbid refuses Dave. Carol is in the same team, and the forbid does not refuse her. As Dave, RLS hides `readme`. The generated RLS already has a forbid side, so you do not regenerate it. `drop_policy('block dave on readme')` removes the forbid.

**On a group.** `principal_in_type` and `principal_in_id` limit a policy to the members of a group, nested members included. In this example, contractors have read-only access to every document:

```sql
select permissions.add_parent('user', :'erin', 'team', :'contractors');
select permissions.grant_role('user', :'erin', 'editor', 'document', :'acme_readme');
select permissions.forbid('contractors are read only', '{update,delete}', 'document',
                          principal_in_type => 'team', principal_in_id => :'contractors');
```

Erin was an editor of `readme` and could update it. Now `can_for('user', :'erin', 'update', 'document', :'acme_readme', jsonb_build_object('folder', :'specs'))` is false. As Erin, `update public.documents ... where id = :'acme_readme'` touches no rows (`UPDATE 0`). `select` still works. Bob is not a contractor, and he can still update.

**Through a role.** Keep the deny in the facts. Declare a `blocked` role, and forbid every principal that holds it on a folder.

```sql
select permissions.define_role('folder', 'blocked');
select permissions.forbid('blocked folders', '{select}', 'document', roles => '{blocked}', via => 'folder');
select permissions.grant_role('user', :'carol', 'blocked', 'folder', :'specs');
```

Carol is an org member and a viewer through `eng`. She now sees `plan` but not `readme`. `denied_ids_for('user', :'carol', 'select', 'document', 'folder')` is `{specs}`.

This forbid reads the folder of the document. Thus every `can()` call for a subject that holds `blocked` must pass the folder ([3.8](#38-call-can-outside-rls)). The parent column must be a `via` column in the RLS ([3.4](#34-parent-inheritance-with-via)). A row with a null folder is hidden from such a subject ([warnings](#6-warnings-and-limits)).

The RLS generator compiles a forbid that has a condition (`condition => ...`) into the RLS. Thus when you add such a forbid, regenerate the RLS ([3.10](#310-regenerate-rls-when-policies-change-shape)). A forbid with a role on a new `via` type needs the name of that `via` column also.

### 3.7 Conditions

A condition is a jsonb expression tree. The design evaluates it (no `execute`). Your SQL never evaluates it. You can put conditions on `permit` and `forbid`.

**On the row.** In this example, org guests can view published documents only:

```sql
alter table public.documents add column status text not null default 'published';
update public.documents set status = 'draft' where id = :'acme_plan';
select permissions.define_role('org', 'guest');
select permissions.permit('org guests view published docs', '{select}', 'document', roles => '{guest}', via => 'org',
                          condition => '{"op": "==", "left": {"var": "resource.status"}, "right": "published"}');
select permissions.grant_role('user', :'gina', 'guest', 'org', :'acme');
```

`can()` takes the attribute from the row. Gina can view a published `readme` and cannot view a draft `plan`.

```sql
select permissions.can_for('user', :'gina', 'select', 'document', :'acme_readme',
                           jsonb_build_object('org', :'acme', 'status', 'published'));   -- true
select permissions.can_for('user', :'gina', 'select', 'document', :'acme_plan',
                           jsonb_build_object('org', :'acme', 'status', 'draft'));       -- false
```

The RLS must contain the condition, so regenerate it. Until then, Gina sees nothing and `lint()` says so (`resource condition on select/document is not in any RLS policy; re-run apply_rls`). `apply_rls` compiles the condition into SQL on the `status` column of the table. It gives the condition its own `ids(...)` group:

```sql
select permissions.apply_rls('public.documents', 'select', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
select permissions.apply_rls('public.documents', 'update', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
```

```sql
-- the extra group in the permit side
or (coalesce(to_jsonb(status) = '"published"'::jsonb, false)
    and (id = any (array(select unnest(permissions.ids('select', 'document', null, coalesce(permissions._unfolded_null(), '{...}'::jsonb)))::uuid))
         or folder_id = any (...) or org_id = any (...)))
```

As Gina, RLS now shows `readme` only. After `plan` is published (`update ... set status = 'published'`), she sees both. Carol is not a guest, and the change does not affect her.

**On the principal.** Attributes are in `permissions.entities`. Set them with `set_attrs`, which replaces the whole object. In this example, only verified users can comment (`comment` is only an action name, used with `can()`):

```sql
select permissions.set_attrs('user', :'erin', '{"verified": true}');
select permissions.permit('verified viewers comment', '{comment}', 'document', roles => '{viewer}',
                          condition => '{"op": "==", "left": {"var": "principal.attrs.verified"}, "right": true}');
select permissions.can_for('user', :'erin', 'comment', 'document', :'acme_readme');   -- true
select permissions.can_for('user', :'bob',  'comment', 'document', :'acme_readme');   -- false: no attributes
select permissions.set_attrs('user', :'bob', '{"verified": true}');
select permissions.can_for('user', :'bob',  'comment', 'document', :'acme_readme');   -- true
```

**On the request.** `context.jwt.<claim>` reads the JWT in `request.jwt.claims`. In this example, an edit needs a second factor. The forbid has no roles and no resource, so it is a deny for everyone while the condition holds. A claim that is absent makes `==` false, so `not` makes it a deny (fail closed):

```sql
insert into public.documents (id, org_id, title) values (:'scratch', :'acme', 'scratch');   -- a throwaway acme document
select permissions.forbid('editing needs mfa', '{update}', 'document',
                          condition => '{"op": "not", "arg": {"op": "==", "left": {"var": "context.jwt.aal"}, "right": "aal2"}}');

set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'alice', 'aal', 'aal1')::text, false);
update public.documents set title = 'scratch 2' where id = :'scratch';   -- UPDATE 0: Alice is an org admin, but the token is aal1
select set_config('request.jwt.claims', json_build_object('sub', :'alice', 'aal', 'aal2')::text, false);
update public.documents set title = 'scratch 2' where id = :'scratch';   -- UPDATE 1
reset role;
select permissions.drop_policy('editing needs mfa');   -- the guide then deletes scratch again
```

The generated update policy already has a forbid side. A policy with a principal-side condition only needs no regeneration, because `denies_all` evaluates it one time for each query.

**Which part runs when.** On write, the design splits a condition into two halves at the top-level `and`:

| Half | Terms | Runs |
| --- | --- | --- |
| principal half | `principal.*`, `context.*`, `now` | One time for each query, inside `ids()`, `denied_ids()`, `allows_all()` and `denies_all()` |
| resource half | `resource.<column>` | For each row. In RLS the design compiles it to SQL on the column. In `can()` the design evaluates it against the `row` jsonb |

`resource.status` means the column `status` of the table. The design compares it through `to_jsonb(status)`, so the SQL has the same meaning as the interpreter. The attribute names must be column names.

**The AST.** The spec checks each example against a throwaway policy:

| Operator | Example |
| --- | --- |
| `==` `!=` `<` `<=` `>` `>=` | `{"op": ">=", "left": {"var": "resource.score"}, "right": 5}` |
| `in` | `{"op": "in", "left": {"var": "resource.status"}, "right": ["draft", "review"]}` |
| `has` | `{"op": "has", "var": "resource.status"}` (the variable is present and not null) |
| `and`, `or` | `{"op": "and", "args": [<term>, <term>]}` |
| `not` | `{"op": "not", "arg": <term>}` |

An operand that is absent or null makes a comparison false, also `!=`. The full grammar is in the [API reference](#condition-ast-grammar).

**The design rejects these conditions** when you write the policy. All raise `22023`:

```sql
-- a term that reads both the row and the principal cannot be partially evaluated
select permissions.permit('authors edit own docs', '{update}', 'document',
    condition => '{"op": "==", "left": {"var": "resource.owner_id"}, "right": {"var": "principal.id"}}');
-- ERROR 22023: permissions: a condition term mixes resource and non-resource variables

-- the same for an "or" across both, and for a column compared with now
-- an unknown variable
select permissions.permit('x', '{update}', 'document', condition => '{"op": "==", "left": {"var": "user.id"}, "right": "x"}');
-- ERROR 22023: permissions: unknown condition variable user.id
-- resource attributes are flat column names: resource.meta.kind is refused the same way
-- via without roles
select permissions.permit('x', '{select}', 'document', via => 'org');
-- ERROR 22023: permissions: a policy with via needs roles (the role held on the org parent)
```

The design does not check the operators and the shape of the AST on write. A misspelled operator raises `22023` when the design first evaluates the policy, and then `apply_rls` produces broken SQL. Run `can_for` against a new conditional policy one time.

**"Authors edit their own documents"** needs `resource.owner_id == principal.id`, and the design refuses it. Make it a fact: grant the author a role on the new row. A `security definer` trigger can do this, because clients cannot call `grant_role`:

```sql
create function public.documents_grant_author() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
    perform permissions.grant_role('user', permissions.current_subject_id(), 'editor', 'document', new.id::text);
    return new;
end $$;
create trigger documents_grant_author after insert on public.documents
    for each row execute function public.documents_grant_author();
```

Carol is an org member who can insert. She inserts a document into folder `plans`. She can then update that document, but she cannot update `readme`.

### 3.8 Call `can()` outside RLS

`can()` knows the row only through its fourth argument. Give it what a policy can read. That is the parent ids of the row under the **type name** (`"folder"`, `"org"`, not `folder_id`), and any attributes that a condition reads. Build the argument from the row one time, in a function:

```sql
create function public.doc_ctx(d public.documents) returns jsonb language sql stable as $$
    select jsonb_build_object('org', d.org_id, 'folder', d.folder_id, 'status', d.status)
$$;

select permissions.can_for('user', :'bob', 'update', 'document', d.id::text, public.doc_ctx(d))
from public.documents d where d.id = :'acme_readme';                    -- true
-- as Bob, with the current subject: permissions.can('update', 'document', d.id::text, public.doc_ctx(d))
```

A null value means that the row has no value. It counts as given.

**Fail closed.** A forbid that can apply to the subject needs its inputs. If the call leaves out something that the forbid reads, `can()` raises `22023`. It does not treat the forbid as a forbid that does not match, because that would give access:

```sql
-- 'blocked folders' (3.6) reads the folder, and Carol holds blocked on a folder
select permissions.can_for('user', :'carol', 'select', 'document', :'acme_plan');
-- ERROR 22023: permissions: forbid "blocked folders" needs a folder parent of document:<plan>, which the resource argument does not include
-- HINT:  Pass the row's parent columns and the attributes forbids read in resource; a null value means the row has none.

select permissions.can_for('user', :'carol', 'select', 'document', :'acme_plan',   jsonb_build_object('folder', :'plans'));   -- true
select permissions.can_for('user', :'carol', 'select', 'document', :'acme_readme', jsonb_build_object('folder', :'specs'));   -- false: blocked in specs
select permissions.can_for('user', :'carol', 'select', 'document', :'acme_plan',   '{"folder": null, "org": null}');          -- false: no folder, no org, nothing admits her
select permissions.can_for('user', :'bob',  'select', 'document', :'acme_readme');   -- true: Bob holds no blocked role, so the same bare call is fine
```

These rules say what a forbid needs:

- A resource condition needs every `resource.<attr>` that it reads to be a key of the row.
- `via => T` needs a `T` key, or a `T` ancestor that is known from `parents`. The stored org of a folder counts. Thus `{"folder": ...}` covers a forbid with `via => 'org'`. But `{"folder": null}` does not vouch for the org.
- A forbid that cannot apply to the subject needs nothing. For example, the subject holds no `blocked` role, or the subject is not in the group.

`who_can` and `explain` raise the same error. RLS never calls `can()` and never raises. It reads the real columns.

Sometimes you add a forbid that depends on the row. Then a `can()` call that passes too little can start to raise for the subjects that the forbid can apply to. This is the intended failure, but it is a failure at run time.

`can()` trusts its `row` argument. A client that passes a false folder fools only itself, because RLS reads the columns. Server code must not give row data from a client to `can()` and use the answer as a gate.

### 3.9 `who_can`, `explain`, `lint`

All three functions are for admins only. Use them to debug and to review. `who_can` and `explain` use the same matcher as `can()`, so they agree with it.

```sql
-- who can view readme? Pass the row, so the folder, org and status policies count
select distinct w.subject_id
from public.documents d
cross join lateral permissions.who_can('select', 'document', d.id::text, public.doc_ctx(d)) w
where d.id = :'acme_readme' and w.subject_type = 'user';
-- Alice, Bob, Dave, Erin, Gina.  Carol is blocked (3.6), so she is not listed.

-- why can Carol not see it?  every policy that matches, with the grant behind it
select e.effect, e.policy, e.matched_grant
from public.documents d
cross join lateral permissions.explain('user', :'carol', 'select', 'document', d.id::text, public.doc_ctx(d)) e
where d.id = :'acme_readme';
--  permit | doc viewers view      | {"on": "document:<readme>", "role": "viewer",  "principal": "team:<eng>"}
--  permit | org members view docs | {"on": "org:<acme>",        "role": "member",  "principal": "user:<carol>"}
--  forbid | blocked folders       | {"on": "folder:<specs>",    "role": "blocked", "principal": "user:<carol>"}
```

`explain` lists permits first, then forbids. No rows means that nothing matched. A permit can show twice when two routes lead to its anchor (an org key in the row and the stored org of the folder). `who_can` is not for RLS. It goes out through the descendants of groups and checks each candidate again.

`lint()` returns `(problem, policy)` rows for the problems that it can see. It reads the text of `pg_policy`, so it helps a review but it is not a proof. Right after the contractors forbid of 3.6, it reports a forbid that no RLS policy enforces:

```sql
select * from permissions.lint();
--  forbid on delete/document is not enforced by any RLS policy (no denied_ids branch); can() still applies it | contractors are read only
grant delete on public.documents to authenticated;
select permissions.apply_rls('public.documents', 'delete', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
select * from permissions.lint();   -- no rows
```

`lint()` checks four things:

- a role that is not declared on the anchor type of a policy
- a forbid whose action has no `denied_ids` branch in any RLS policy
- an allow-all permit that no RLS policy includes
- a resource condition that no RLS policy includes

`lint()` does not notice a new `via` type or a new `via` column.

The guide ends: it drops `blocked folders` and revokes the `blocked` grant of Carol.

### 3.10 Regenerate RLS when policies change shape

The expression that `apply_rls` writes is fixed when the function runs. It contains what the policies of that moment say. Thus some changes need a new run:

| You change | Regenerate? |
| --- | --- |
| a grant, a parent edge, an attribute, an expiry | no |
| a permit or forbid with a role, a `resource_id` or a principal scope, on a shape that the RLS already has | no |
| a new `via` type, or a new parent column | **yes**, with the column in `via_columns`. `lint()` does not notice |
| a policy with a `condition` (permit or forbid) | **yes**. `lint()` notices |
| an allow-all permit (no roles, no `resource_id`) | **yes**. `lint()` notices |
| a forbid on an action that has no RLS policy yet | **yes**: apply it for that command. `lint()` notices |

Permits fail closed. If you forget to regenerate, the policy grants nothing on `select`. **Forbids with a condition fail open in RLS.** Until you regenerate, the table does not deny, but `can()` does deny. In this example, archived documents become read-only:

```sql
select permissions.forbid('archived is read only', '{update}', 'document',
                          condition => '{"op": "==", "left": {"var": "resource.status"}, "right": "archived"}');
select * from permissions.lint();
--  resource condition on update/document is not in any RLS policy; re-run apply_rls | archived is read only
update public.documents set status = 'archived' where id = :'acme_plan';
```

`can_for('user', :'alice', 'update', 'document', :'acme_plan', <row with status archived>)` is false. But as Alice, `update public.documents set title = title where id = :'acme_plan'` still says `UPDATE 1` until you run `apply_rls(... 'update' ...)` again. It then says `UPDATE 0`. The guide drops the forbid and publishes the plan again.

The next example is an allow-all permit. Members of `eng` can view every document:

```sql
select permissions.permit('eng views everything', '{select}', 'document',
                          principal_in_type => 'team', principal_in_id => :'eng');
select * from permissions.lint();
--  allow-all permit on select/document is not in any RLS policy (no allows_all branch); re-run apply_rls | eng views everything
```

As Dave, RLS still shows only `readme`. Run the same calls again. They are idempotent, because each call drops and creates `permissions_<command>` again. Keep them in one migration file. Run the file after every policy change:

```sql
do $$
declare c text;
begin
    foreach c in array array['select', 'update', 'delete', 'insert'] loop
        perform permissions.apply_rls('public.documents', c, 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
    end loop;
end $$;
```

`lint()` is quiet again, and Dave sees every document. `allows_all_for('user', :'dave', 'select', 'document')` is true (false for Bob). The generator writes the `allows_all` arm only when an allow-all permit exists at generation time. A boolean InitPlan that you combine with the id arms through OR stops Postgres from using the indexes. It is safe to drop the permit later. The arm then returns false.

`lint()` does not see a policy with a new `via` type:

```sql
select permissions.define_role('project', 'viewer');
select permissions.permit('project viewers view docs', '{select}', 'document', roles => '{viewer}', via => 'project');
select * from permissions.lint();   -- no rows, but the select policy does not know about projects
```

When the column exists, regenerate with `'{"org": "org_id", "folder": "folder_id", "project": "project_id"}'`.

### 3.11 Graduate from the `rbac` preset

The [RBAC guide](../../docs/rbac.md) describes the preset, graduation included. On B, the preset is two built-in resource types: `app` (one resource, `app:global`) and `tenant` (one for each scope). It has one generated policy for each role and type. `create_role('editor', '{reports.edit}', '{viewer}')` declares `editor` on both types, with the implication. It writes the policies `rbac:app:editor` and `rbac:tenant:editor`. `assign_role` is a role grant on `tenant:<scope>`.

Start with the preset:

```sql
select permissions.create_role('viewer', '{reports.read}');
select permissions.create_role('editor', '{reports.edit}', '{viewer}');
select permissions.create_role('admin',  '{reports.delete}', '{editor}');
select permissions.assign_role(:'alice', 'admin',  :'acme');
select permissions.assign_role(:'bob',   'editor', :'acme');

create table public.reports (id uuid primary key, org_id uuid not null, title text not null);
insert into public.reports values (:'report1', :'acme', 'q1'), (:'report2', :'acme', 'q2');
alter table public.reports enable row level security;
grant select on public.reports to authenticated;
create policy reports_select on public.reports for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('reports.read'))::uuid))
);
```

Bob sees both reports. Dave is in no org and sees none. To share one report with Dave, add the second concept of B: a policy. You need four things: a role on the report, a policy for the role, a grant and one more `or` arm in the RLS. The policy says what the role gives permission for. Nothing that the preset wrote changes.

```sql
select permissions.define_role('report', 'viewer');
select permissions.permit('report viewers view', '{select}', 'report', roles => '{viewer}');
select permissions.grant_role('user', :'dave', 'viewer', 'report', :'report1');

drop policy reports_select on public.reports;
create policy reports_select on public.reports for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('reports.read'))::uuid))
    or id  = any (array(select unnest(permissions.ids('select', 'report'))::uuid))
);
```

Dave sees `q1`. `has_permission('reports.read', :'acme')` is still false for him. Bob still sees both reports. `user_permissions(:'alice', :'acme')` is still `{reports.read, reports.edit, reports.delete}`. `users_with_role('admin', :'acme')` is Alice.

The six policies of the preset (three roles, two types) have `managed_by = 'rbac'`. `drop_policy('rbac:tenant:admin')` raises `55000`. `unassign_role` removes the grant. Keep the arm of the preset as it is, and add the shared arm next to it. The single-branch form is slower on large tables (see [3.4](#34-parent-inheritance-with-via)).

### 3.12 Clean up

The extension stores no users, so when you delete a user, the grants of the user stay. `delete_entity(type, id)` removes everything that names an entity. It returns the number of rows that it removed:

```sql
select permissions.delete_entity('user', :'erin');   -- 4: 2 grants, 1 parents edge, 1 attributes row
select permissions.ids_for('user', :'erin', 'select', 'document');   -- {}
select permissions.delete_entity('user', :'erin');   -- 0
```

The function deletes these items:

- the attributes of the entity
- the grants that the entity holds, and the grants on the entity
- the `parents` edges of the entity, as child and as parent (the closures follow)
- the **unmanaged policies that name the entity**: a public policy with `resource_id`, and a policy with `principal_id` or `principal_in` (forbids too)

To do this automatically, attach `on_entity_deleted(type, column)` as an `after delete` trigger on the tables of the app. The first argument is the entity type. The second argument is the column that holds its id. This example is for users and documents:

```sql
create trigger cleanup_permissions after delete on public.profiles
    for each row execute function permissions.on_entity_deleted('user', 'id');
create trigger cleanup_permissions after delete on public.documents
    for each row execute function permissions.on_entity_deleted('document', 'id');
```

When you delete the profile of Frank, the trigger removes his grants. When you delete a document, the trigger removes the grants on it and the policies that name it:

```sql
insert into public.documents (id, org_id, title) values (:'scratch', :'acme', 'scratch');
select permissions.grant_role('user', :'gina', 'viewer', 'document', :'scratch');
select permissions.permit('scratch is public', '{select}', 'document', resource_id => :'scratch');
-- as Alice, an org admin:
delete from public.documents where id = :'scratch';   -- DELETE 1: the grant and 'scratch is public' are gone
```

The trigger function is `security definer`. Only the role that creates the trigger needs `execute` on it. Clients that delete rows need no extra privilege.

When you delete a group, the policies that name the group go too. In the spec, `delete_entity('team', :'contractors')` deletes the `contractors are read only` forbid. This is correct when a team is gone for good. It is wrong if you wanted to rename the team.

## 4. API reference

The prototype has 38 public functions in `permissions` (names that do not start with an underscore). The read functions are `stable security definer set search_path = ''`. "Client" means that the function is granted to `public`, so `anon` and `authenticated` can call it. All other functions are for admins only.

An admin is the role that installs the extension, or a role that you gave `grant execute`. See the shared guide. Clients have no privilege on any table.

| | Functions |
| --- | --- |
| Client | `can`, `ids`, `denied_ids`, `allows_all`, `denies_all`, `current_subject_id`, `current_subject_type`, `has_permission`, `has_role`, `scopes_with_permission` (and `_unfolded_null`, an internal default) |
| Admin, explicit subject | `can_for`, `ids_for`, `denied_ids_for`, `allows_all_for`, `denies_all_for`, `who_can`, `explain`, `is_in` |
| Admin, facts | `define_role`, `grant_role`, `revoke_role`, `add_parent`, `remove_parent`, `set_attrs`, `delete_entity`, `on_entity_deleted` |
| Admin, policies | `permit`, `forbid`, `drop_policy` |
| Admin, RLS tools | `rls_expression`, `apply_rls`, `lint` |
| Admin, rbac preset | `create_role`, `drop_role`, `assign_role`, `unassign_role`, `user_permissions`, `users_with_role` |

**The last dummy argument.** `ids`, `denied_ids` and `scopes_with_permission` end with a parameter (`resource_condition jsonb` for the first two, `p_unfold jsonb` for the last). Its default is `permissions._unfolded_null()`, a volatile function that returns null. The functions are stable.

Postgres evaluates a stable function at plan time when all its arguments are constants. This made every RLS query run the list two times. A default that is not a constant stops this, and the function still reads the snapshot of the query.

Thus **do not pass the argument of `scopes_with_permission`** (the function ignores its value). Call `ids(action, type)` and `ids(action, type, via)` in the short forms. Pass `resource_condition` only in the way that `rls_expression` does. If you call `ids('select', 'document', null, '{...}'::jsonb)` with every argument constant, Postgres evaluates it at plan time again.

`_unfolded_null()` is granted to `public` because defaults run as the caller. The grants of the three functions name the full signature (`ids(text, text, text, jsonb)`).

### Checks for the current subject (client)

The subject is `current_subject_id()` and `current_subject_type()`. With no subject, every check is false and every list is empty.

#### `can(action text, resource_type text, resource_id text, resource jsonb default '{}') returns boolean`

Does the current subject have permission? The function evaluates the policies as in [How a decision is computed](#how-a-decision-is-computed). `resource` is the row: parents under their type name, attributes under their column name. The function raises `22023` when a forbid that can apply needs an input that the row lacks ([3.8](#38-call-can-outside-rls)). Use it for checks of single rows, and for RLS that you write by hand for each row.

```sql
select permissions.can('select', 'document', :'acme_readme', jsonb_build_object('org', :'acme'));   -- as Dave: true
```

#### `ids(action text, resource_type text, via text default null, resource_condition jsonb default _unfolded_null()) returns text[]`

This is the partial evaluation that RLS uses. With no `via`, it returns the ids of the resources that the subject can access. The subject has access through its own grants (and the grants of its groups). It can also have access through `parents` rows (a document filed in a folder), or through a `resource_id` policy. With `via => 'folder'`, it returns the **folder ids** such that a resource directly in that folder would have permission.

`resource_condition` selects the policies whose condition equals it (null: the policies with no condition). The list excludes the ids that the unconditioned forbids deny in the same projection. The function returns `'{}'` with no subject.

```sql
select permissions.ids('select', 'document');             -- as Erin, after 3.1: {readme}
select permissions.ids('select', 'document', 'folder');
```

#### `denied_ids(action text, resource_type text, via text default null, resource_condition jsonb default _unfolded_null()) returns text[]`

This is the forbid side of `ids`. It returns the ids (or parent ids) that the forbid policies name, for the forbids that apply to the subject. It subtracts nothing. RLS uses it on the deny side.

```sql
select permissions.denied_ids('select', 'document');   -- as Frank, with a forbid on plan: {plan}
```

#### `allows_all(action text, resource_type text, resource_condition jsonb default null) returns boolean`

True if an allow-all permit (no roles, no `resource_id`) applies to the subject and no allow-all forbid applies. It is the `allows_all` arm of RLS. The generator emits the arm only when such a permit exists.

```sql
select permissions.allows_all('select', 'document');   -- false unless an allow-all permit covers this subject
```

#### `denies_all(action text, resource_type text, resource_condition jsonb default null) returns boolean`

True if a forbid with no roles and no `resource_id` applies to the subject. This includes a forbid on a group that contains the subject, and a forbid with a principal-side condition that holds. The deny side of RLS always includes this function.

```sql
select permissions.denies_all('select', 'document');   -- false for Frank
```

#### `current_subject_id() returns text`, `current_subject_type() returns text`

The id comes from the JWT `sub`, then from the `permissions.subject_id` setting, else null. The type is `'user'` by default. You can set the type with `permissions.subject_type`. See the shared guide.

```sql
select permissions.current_subject_id();    -- the JWT sub, or the setting
select permissions.current_subject_type();  -- 'user', or the permissions.subject_type setting
```

#### `has_permission(permission text, scope text default null)`, `has_role(role text, scope text default null)`, `scopes_with_permission(permission text, p_unfold jsonb default _unfolded_null()) returns text[]`

These are the checks of the `rbac` preset. The shared guide describes the behavior. On B, `has_permission` is `can_for(current subject, permission, 'tenant', scope)` (`'app'` and `'global'` with no scope). `scopes_with_permission` is `ids_for(current subject, permission, 'tenant')`.

```sql
select permissions.has_permission('reports.edit', :'acme');         -- as Bob: true
select permissions.scopes_with_permission('reports.read');          -- as Bob: {acme}
```

### Checks for an explicit subject (admin)

These functions take `subject_type, subject_id` first. They are for admins only, because a client that could call them could ask what anyone can see.

#### `can_for(subject_type text, subject_id text, action text, resource_type text, resource_id text, resource jsonb default '{}') returns boolean`

This is `can()` for any subject. A null `subject_id` returns false.

```sql
select permissions.can_for('user', :'bob', 'update', 'document', :'acme_readme', jsonb_build_object('org', :'acme'));   -- true
```

#### `ids_for(subject_type text, subject_id text, action text, resource_type text, via text default null, resource_condition jsonb default null) returns text[]`

This is `ids()` for any subject (with no dummy argument). It returns `'{}'` for a null subject. As a **list**, it is exact only for unconditioned policies ([warnings](#6-warnings-and-limits)).

```sql
select permissions.ids_for('user', :'carol', 'select', 'document', 'org');    -- {acme}
select permissions.ids_for('user', :'gina', 'select', 'document', 'org', null); -- {}: her only policy has a condition
select permissions.ids_for('user', :'gina', 'select', 'document', 'org',
    '{"op": "==", "left": {"var": "resource.status"}, "right": "published"}');  -- {acme}
```

#### `denied_ids_for(subject_type text, subject_id text, action text, resource_type text, via text default null, resource_condition jsonb default null) returns text[]`

This is `denied_ids()` for any subject.

```sql
select permissions.denied_ids_for('user', :'frank', 'select', 'document');   -- {plan} with 'block frank on plan'
```

#### `allows_all_for(subject_type text, subject_id text, action text, resource_type text, resource_condition jsonb default null) returns boolean`, `denies_all_for(...same arguments...) returns boolean`

These are `allows_all()` and `denies_all()` for any subject.

```sql
select permissions.allows_all_for('user', :'gina', 'select', 'document');   -- false
select permissions.denies_all_for('user', :'gina', 'select', 'document');   -- true with a 'block gina' forbid (no roles, no resource)
```

#### `who_can(action text, resource_type text, resource_id text, resource jsonb default '{}') returns table (subject_type text, subject_id text, policy text)`

This function returns the subjects that can do the action on one resource, with the permit policy that admits each subject. It runs each permit in reverse: grants on the anchors, with groups expanded to their members of the `principal_type` of the policy. It then keeps only the subjects that `can_for` agrees with, so forbids and conditions apply.

A subject appears one time for each policy. A policy with no principal restriction (public access) returns one `('*', '*', policy)` row. That row does not subtract forbids. The function raises `22023` like `can()`.

```sql
select * from permissions.who_can('select', 'probe', 'p1');
-- with permit('probe for everyone', '{select}', 'probe'): one row, ('*', '*', 'probe for everyone')
```

#### `explain(subject_type text, subject_id text, action text, resource_type text, resource_id text, resource jsonb default '{}') returns table (effect text, policy text, matched_grant jsonb)`

This function returns every policy that matches, permits first, then forbids. `matched_grant` is `{"principal": "type:id", "role": ..., "on": "type:id"}` for a policy with a role, and null for other policies. An empty result means that nothing matched. The function raises `22023` like `can()`.

```sql
select * from permissions.explain('user', :'dave', 'select', 'document', :'acme_readme');
```

#### `is_in(child_type text, child_id text, parent_type text, parent_id text) returns boolean`

Is the child inside the parent, directly or through any number of levels (the `in` of Cedar)? The function reads the stored edges only.

```sql
select permissions.is_in('user', :'dave', 'team', :'platform');   -- true while eng is in platform
```

### Facts (admin)

#### `define_role(resource_type text, role text, implies text[] default '{}') returns void`

Declares a role for a type, and what the role implies. The function is idempotent. It adds the role and any new implications. It rebuilds the role closure of that type under the `permissions.roles` lock. It raises `22023` for an implied role that the type does not declare. It raises `0A000` under `repeatable read`.

No function removes an implication, or undeclares a role. (The `drop_role` of the preset covers `app` and `tenant` only.)

```sql
select permissions.define_role('document', 'editor', '{viewer}');
```

#### `grant_role(principal_type text, principal_id text, role text, resource_type text, resource_id text, expires_at timestamptz default null) returns void`

The principal (a user, or a group of any type) holds the role on the resource. The key is (principal, resource, role), so a repeated call replaces `expires_at`. The function raises `22023` if the resource type does not declare the role. It does not check that the resource exists.

```sql
select permissions.grant_role('user', :'erin', 'viewer', 'document', :'acme_readme', now() + interval '7 days');
```

#### `revoke_role(principal_type text, principal_id text, role text, resource_type text, resource_id text) returns boolean`

Removes the grant. It returns true if the grant existed.

```sql
select permissions.revoke_role('user', :'erin', 'viewer', 'document', :'acme_readme');   -- true, then false
```

#### `add_parent(child_type text, child_id text, parent_type text, parent_id text) returns void`

Adds "child is in parent". The function is idempotent. It takes the closure lock and maintains the closure. It raises `23514` for a cycle, a path deeper than 10 levels, or a self-edge. It raises `0A000` under `repeatable read`.

```sql
select permissions.add_parent('user', :'dave', 'team', :'eng');
```

#### `remove_parent(child_type text, child_id text, parent_type text, parent_id text) returns boolean`

Removes the edge and rebuilds the closure of the child and of its inner descendants (nothing for a leaf). It returns true if the edge existed. It raises `0A000` under `repeatable read`. See the [depth cap on delete](#6-warnings-and-limits).

```sql
select permissions.remove_parent('user', :'dave', 'team', :'eng');   -- true
```

#### `set_attrs(type text, id text, attrs jsonb) returns void`

Sets the attributes of an entity and replaces the whole object (null becomes `{}`). Conditions read the attributes as `principal.attrs.*`.

```sql
select permissions.set_attrs('user', :'erin', '{"verified": true}');
```

#### `delete_entity(type text, id text) returns bigint`

Removes everything that names the entity (the grants that it holds and the grants on it, parent edges, attributes, unmanaged policies that name it). It returns the number of rows. See [3.12](#312-clean-up).

```sql
select permissions.delete_entity('user', :'erin');   -- 4
```

#### `on_entity_deleted() returns trigger`

An `after delete` row trigger function. Its arguments are the entity type, and the column that holds the id (`to_jsonb(old) ->> column`). It calls `delete_entity`.

```sql
create trigger cleanup_permissions after delete on public.profiles
    for each row execute function permissions.on_entity_deleted('user', 'id');
```

### Policies (admin)

#### `permit(name, actions, resource_type, roles, via, principal_in_type, principal_in_id, resource_id, condition, principal_id, principal_type) returns bigint`, `forbid(...same...)`

Creates a policy and returns its id. `name` (unique), `actions` and `resource_type` are positional. The other arguments are named. They default to null, except `principal_type`, which defaults to `'user'`.

| Argument | Meaning |
| --- | --- |
| `actions text[]` | Action names. You need at least one |
| `roles text[]` | The principal must hold one of these roles on the anchor. The anchor type must declare each role |
| `via text` | The anchor type. It needs `roles`. You cannot combine it with `resource_id` |
| `principal_in_type`, `principal_in_id` | Members of a group. Give both or neither |
| `principal_id text` | One principal |
| `principal_type text` | The type of the subject. Null for any type |
| `resource_id text` | One resource |
| `condition jsonb` | An [AST](#condition-ast-grammar). The design splits it on write |

The function raises these errors:

- `22023`: a role that the anchor type does not declare, `via` without `roles`, `via` with `resource_id`, a bad condition
- `23514`: empty `actions`, `principal_in_type` without its id
- `23505`: the name is taken

To switch a policy off without a drop, set `enabled = false` as the owner.

```sql
select permissions.permit('announcement is public', '{select}', 'document', resource_id => :'announcement');
select permissions.forbid('contractors are read only', '{update,delete}', 'document',
                          principal_in_type => 'team', principal_in_id => :'contractors');
select permissions.permit('probe for services', '{select}', 'probe', resource_id => 'p1', principal_type => 'service');
```

#### `drop_policy(name text) returns boolean`

Deletes the policy. It returns true if the policy existed. It raises `55000` for a policy that the `rbac` preset manages.

```sql
select permissions.drop_policy('announcement is public');   -- true
```

### RLS tools (admin)

#### `rls_expression(action text, resource_type text, id_column text default 'id', via_columns jsonb default '{}', id_type regtype default 'uuid') returns text`

Returns the `using` or `with check` expression, as the quick start shows. `via_columns` maps a parent type to the column that holds it: `{"org": "org_id", "folder": "folder_id"}`. `id_type` is the cast for text, bigint or other keys. The expression has one extra group for each distinct resource condition of the policies that exist now. It has an `allows_all` arm if an allow-all permit exists now.

```sql
select permissions.rls_expression('select', 'ticket', 'id', '{"org": "org_id"}', 'bigint'::regtype);   -- ids cast with ::bigint
select permissions.rls_expression('select', 'nothing_defined');   -- an id arm only
```

#### `apply_rls(table regclass, command text, resource_type text, id_column text default 'id', via_columns jsonb default '{}', to_role name default 'authenticated') returns text`

Drops and creates the RLS policy `permissions_<command>` of the table from `rls_expression`, and returns its name. `command` is `select`, `insert`, `update` or `delete` (`22023` otherwise). This is the one place where the extension runs dynamic SQL. It runs with the rights of the caller: the owner of the table.

The function does not enable RLS, does not grant table privileges, and does not touch your other policies. Its parameters are named `p_table`, `p_command`, ...

```sql
select permissions.apply_rls('public.documents', 'select', 'document', 'id', '{"org": "org_id"}');   -- 'permissions_select'
```

#### `lint() returns table (problem text, policy text)`

See [3.9](#39-who_can-explain-lint).

```sql
select * from permissions.lint();
```

### rbac preset functions (admin unless noted)

The [RBAC guide](../../docs/rbac.md) documents the preset. It has the same behavior and error codes on every design. On B:

| Function | On B |
| --- | --- |
| `create_role(role text, permissions text[], inherits text[] default '{}')` | `define_role` on `app` and `tenant`, plus the policies `rbac:app:<role>` and `rbac:tenant:<role>`. `23505` if the role exists |
| `drop_role(role text)` | Removes the policies and the role on both types. `2BP01` while another role inherits it, `22023` if the role is unknown |
| `assign_role(user_id text, role text, scope text default null)` | A `role_grants` row on `app:global` or `tenant:<scope>`. `22023` for an unknown role |
| `unassign_role(user_id text, role text, scope text default null)` | Deletes that row |
| `user_permissions(user_id text, scope text default null) returns text[]` | `can_for` over every action that the policies of the preset name |
| `users_with_role(role text, scope text default null) returns setof text` | The holders of the role (or of a role that implies it), with group members expanded |

```sql
select permissions.create_role('viewer', '{reports.read}');
select permissions.assign_role(:'alice', 'admin', :'acme');
select permissions.user_permissions(:'alice', :'acme');     -- {reports.read, reports.edit, reports.delete}
```

### Tables and the `closure` view

All tables are in schema `permissions`, and clients have no privilege on them. Write facts through the functions. Triggers maintain the closure tables. Do not edit them. The columns for id, type and role are `collate "C"`.

| Table | Columns | Notes |
| --- | --- | --- |
| `entities` | `type`, `id`, `attrs jsonb` | Attributes. `set_attrs` writes them |
| `parents` | `child_type`, `child_id`, `parent_type`, `parent_id` | Immutable rows. Triggers maintain `ancestors` |
| `ancestors` | `child_type`, `child_id`, `ancestor_type`, `ancestor_id`, `depth` (1-10) | Closure rows for **inner nodes** only (entities that have children) |
| `roles` | `resource_type`, `role` | Declared roles |
| `role_implies` | `resource_type`, `role`, `implies` | Direct implications |
| `role_closure` | `resource_type`, `role`, `implied` | Reflexive closure. `define_role` rebuilds it |
| `role_grants` | `principal_type`, `principal_id`, `role`, `resource_type`, `resource_id`, `expires_at` | Primary key `(principal_type, principal_id, resource_type, resource_id, role)` |
| `policies` | `id`, `name`, `effect`, `principal_type`, `principal_id`, `principal_in_type`, `principal_in_id`, `actions`, `resource_type`, `resource_id`, `roles`, `via`, `condition`, `principal_condition`, `resource_condition`, `managed_by`, `enabled` | The table stores the condition as written, and also its two halves |

`closure` is a view with `(child_type, child_id, ancestor_type, ancestor_id, depth)`. It has every pair: the direct edges plus the stored rows of each direct parent, so leaves are included. A pair that has several paths appears one time for each path. Use `distinct` or `min(depth)`. When you query the view, join it with parameters or as `cross join lateral (... offset 0)`. If you join it directly, the planner first computes the descendants of every inner node.

### Condition AST grammar

```
condition := term
term      := {"op": "and" | "or", "args": [term, ...]}
           | {"op": "not", "arg": term}
           | {"op": "has", "var": VAR}
           | {"op": "==" | "!=" | "<" | "<=" | ">" | ">=" | "in", "left": operand, "right": operand}
operand   := {"var": VAR} | JSON literal      -- for "in", right is an array
VAR       := principal.id | principal.type | principal.attrs.<path>
           | resource.<column>                -- one flat column name
           | context.<path>                   -- context.jwt.<claim>, or a key of the permissions.context setting
           | now                              -- to_jsonb(now())
```

Comparisons use the jsonb order. Timestamps are ISO strings, so compare them only between values with the same offset. An operand that is absent or null makes a comparison false.

The design splits the condition on write at the top-level `and`. A term that reads only `resource.*` is the resource half. A term that reads no `resource.*` is the principal half. A term that reads both (a column against `now` included) raises `22023`. An unknown variable raises `22023` also.

### Errors

| SQLSTATE | When |
| --- | --- |
| `22023` | A role that is not declared; a bad condition variable or a mixed term; the `via` rules; a bad `apply_rls` command; `can()`, `who_can` or `explain` without an input that a forbid needs; an unknown operator when the design evaluates it |
| `23514` | A cycle, depth over 10 or self-edge in `add_parent`; empty `actions`; `principal_in_*` without its pair |
| `23505` | A policy name that is already used; `create_role` of the preset for a role that exists |
| `0A000` | A parent write or role-definition write under `repeatable read`; an update of a `parents` row |
| `55000` | `drop_policy` on a policy that the preset manages |
| `42501` | A client that calls an admin function or reads a table; RLS that rejects an insert |

## 5. Performance notes

The numbers are from [`../benchmarks/OPTIMIZATIONS.md`](../benchmarks/OPTIMIZATIONS.md). The setup is Postgres 18.6 in Docker, 4 pgbench clients, p50 in ms, one run for each configuration. Workloads under one millisecond repeat within about 5%. Heavier workloads repeat within about 20%.

"Large" is 1M documents and 10k users. "Medium" is 100k documents. Each workload runs as `authenticated` under RLS, and writes roll back.

**Cheap**

| What | Large |
| --- | --- |
| `rbac_check` (one `has_permission`) | 0.27 |
| `rbac_select_page` / `rbac_select_count` / `rbac_update_one` | 0.73 / 0.78 / 0.47 |
| `share_list_objects` (the list function) / `share_select_page` (a share of one object, with nested teams) | 0.29 / 1.00 |
| parents, projection shape: page / count | 1.15 / 8.20 |
| `write_assign_role`, `write_share` (a grant) | 0.14, 0.14 |
| `write_nest_team` (nest a 1,000-member team of users) | 0.62 (1.47 on wide memberships) |
| `nest_check` (a check through a nested team) | 0.32 |

A check or a list costs what the grants and groups of the caller cost, not what the tables hold. An org-level or folder-level grant is one array element. Policy edits and grants need no maintenance writes. The plan step for a policy costs about 0.24 ms (catalog lookups only). The reason is that Postgres does not evaluate the `ids()` calls at plan time ([the dummy argument](#4-api-reference)).

**Expensive**

- **The single-branch parents shape.** A page takes 13.7 ms and a count takes 21.6 ms (large). This is about 12x the projection shape. The seed takes 44.8 s, and the storage grows about 357 MB for 1M documents ([3.4](#34-parent-inheritance-with-via)). The projection costs nothing extra.
- **Wide memberships.** At medium wide (50 teams for each user), `share_select_page` is 17.8 ms and `share_list_objects` is 8.41 ms. B is the slowest design here (A 14.4 / 4.44, C 8.20 / 3.41). Deep trees of nested teams are cheap: medium deep is 0.72 / 0.32.
- **Nested sub-trees of many teams.** A team of users writes a few closure rows. A team that contains hundreds of sub-teams writes (inner descendants x ancestors) rows under the global lock. We did not benchmark this.
- **`who_can`.** It is a debug function.
- **Large id arrays.** `id = any ($1)` scans the array for each row that it checks. This is fast with an index. We did not measure a caller with tens of thousands of direct grants. Do not change to a hashed `in (select ...)`: the counts were 40x slower.
- **Number of InitPlans.** There is one function call for each arm: 5 for a table with one parent column, 7 with one resource condition.

Storage at large after the parents seed is 377.9 MB (A 404.3, C 182.4). For the budgets (`--check`, p95), B misses only `parents_proj_select_count` at large. All three designs miss it, because of the heap-fetch floor of that count. On medium wide, B also misses `share_list_objects` and `write_nest_team`.

## 6. Warnings and limits

- **You must regenerate RLS when policies change shape** ([3.10](#310-regenerate-rls-when-policies-change-shape)). These changes are a new `via` type, a condition, an allow-all permit, and a forbid on a new command. A permit that you forgot grants nothing, so it fails closed. A **forbid** with a condition (or on a `via` column that the RLS lacks) that you forgot to regenerate does not deny in RLS.

  But `can()` still applies it. `lint()` covers conditions, allow-all permits and forbids that nothing enforces. It does not cover new `via` columns. Thus run the regenerate step on every policy change.
- **`ids_for` as a list does not subtract all forbids.** `ids_for('user', :'frank', 'select', 'document')` still lists a document that Frank holds a direct grant on. This is true when a forbid blocks the document through its folder or an attribute. RLS is exact, and `can()` with the row is exact.

  Use them for decisions. The list is for display and debug. Also, `ids()` is exact only for unconditioned policies, and the `('*', '*')` row of `who_can` does not subtract forbids.
- **A row with a null parent column is hidden from a subject that has a forbid on that column.** The forbid side is `not (... folder_id = any(denied_ids))`. This is null for a null folder, so the row disappears for Frank, even though `can()` says yes. Keep parent columns `not null`, or give such rows a real parent. Without a forbid, a row with a null parent is still accessible, but only through its own grants or through another arm (an `org_id` arm).
- **The design does not enforce the depth cap on delete.** An insert rejects paths deeper than 10. But when you remove a shortcut edge, the shortest path that is left can be longer than 10, and the rebuild silently drops that pair. After the removal, `u` is still in `t0`, and `m1` is still in `t6`.

  But `u` is no longer in `t6`, though a path of 11 hops exists. This is a known issue. We kept it for compatibility ([../decision.md](../decision.md), open question 8). The fix is to reject such a delete with `23514`.
- **The design reads jsonb keys as parents.** In the `row` of `can()`, every key that names a type is a candidate parent of that type. Thus `{"folder": ...}` works. A key that names a principal type is only an attribute. A principal type is a type that a policy uses to scope principals, or a type that holds a grant, such as `user` or `team`.

  The exception is a policy on the resource type that anchors `via` that type. A key that collides with an entity type is still read as a parent. The design derives the keys that count from your policies and grants. Thus when you grant a role to a folder, `folder` becomes a principal type. The explicit parent declarations of Cedar would fix this (open question 4).
- **Constant arguments fold at plan time.** The dummy argument stops Postgres from evaluating `ids()` and `scopes_with_permission` when it makes the plan. If you pass every argument as a constant, Postgres folds the call again. `apply_rls` and `rls_expression` write the safe form. Copy it.
- **Document edges go stale.** If you store `parents` rows for documents, they feed `ids()` for every RLS shape. Keep them in step with the column ([3.4](#34-parent-inheritance-with-via)).
- **Closure writes.** There is one global advisory lock. `repeatable read` raises `0A000`. A nested large sub-tree writes many rows. You cannot update parent edges. If your ORM uses `repeatable read` by default, set the isolation level for permission writes explicitly.
- **`::uuid` in generated RLS fails the whole query** if any stored id for that type is not a uuid. For other keys, pass `id_type` (`'bigint'::regtype`, `'text'::regtype`) to `rls_expression`. `apply_rls` itself has no `id_type` argument. Thus for non-uuid keys, use `rls_expression` and `create policy` yourself.
- **`apply_rls` owns the policy name.** There is one RLS policy for each table and command, named `permissions_<command>`. A second call with another resource type replaces the first. `apply_rls` is security invoker, so run it as the owner of the table.
- **The design checks conditions less than it seems.** It validates variable names and mixed terms on write. It does not validate operator names and shape: a typo raises `22023` on the first evaluation and breaks `apply_rls`. `now` and timestamps compare as ISO strings.

  `context.*` comes from `request.jwt.claims` and from the `permissions.context` setting. Any session can set that setting on plain Postgres, so use JWT claims or values that the server sets. `resource.owner_id == principal.id` is refused. Use a role grant on the row ([3.7](#37-conditions)).
- **You cannot undefine a role or switch off a policy**, except with SQL on the tables as the owner. `delete_entity` on a group deletes the forbids that name it.
- **`explain` can repeat a row** when two routes lead to one anchor.
- **Security definer everywhere.** A bug in a read function is a privilege bug. `search_path = ''` and no dynamic SQL in the read path limit the risk. The functions are not `leakproof`.
- **No upgrade path.** You cannot run the prototype again over an installed copy.
