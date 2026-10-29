# Engine B: policy-first

How to use `pg_permissions` when you have picked engine B. B keeps two kinds of data: **facts** (who is in which group, who holds which role on what) and **policies** (Cedar-style `permit` and `forbid` rules that say what those facts allow). RLS policies on your tables are generated from the policy table, or written by hand against a few list functions.

This page covers engine B only. Install, identity (JWT `sub`, `permissions.subject_id`), the client and admin privilege split, the `rbac` preset and the general RLS rules are the same on every engine and live in the [shared guide](./README.md). Read its "Identity" and "Roles and privileges" sections first; this page assumes them. The design and its trade-offs are in [`designs/b-policy-first.md`](../designs/b-policy-first.md), and the code is [`prototypes/b-policy-first.sql`](../prototypes/b-policy-first.sql).

Every example with a result runs in [`test/spec/b/90_usage_examples.sql`](../test/spec/b/90_usage_examples.sql), in the order of this page, on one database: the how-tos build on the quick start's data. Run it with:

```bash
./test/run.sh 90_usage_examples --impl prototypes/b-policy-first.sql
```

Contents: [1 Mental model](#1-mental-model) · [2 Quick start](#2-quick-start) · [3 How-to guides](#3-how-to-guides) · [4 API reference](#4-api-reference) · [5 Performance notes](#5-performance-notes) · [6 Gotchas and limits](#6-gotchas-and-limits)

IDs are psql variables, as in the shared guide (`:'alice'` and the others from its list). This page adds a few more. The spec uses the same names with the values in [`test/fixtures/ids.sql`](../test/fixtures/ids.sql):

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
\set announcement 'cccccccc-0000-0000-0000-000000000005'   -- more documents, each used by one guide
\set scratch      'cccccccc-0000-0000-0000-000000000009'
\set report1      'dddddddd-0000-0000-0000-000000000001'   -- reports, in 3.11
\set report2      'dddddddd-0000-0000-0000-000000000002'
```

"As Dave" in the examples means this, with `reset role;` at the end. In an app, set the subject per transaction with `set_config(..., true)`, as the shared guide says.

```sql
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
```

## 1. Mental model

### Facts

Facts are rows you write with the admin functions. None of them says what anyone may do.

| Fact | Means | Written with |
| --- | --- | --- |
| Entity attributes | a jsonb of attributes for a user (or any entity), read by conditions as `principal.attrs.*` | `set_attrs` |
| Parent edge | "child is in parent": a user in a team, a team in a team, a folder in an org, optionally a document in a folder | `add_parent`, `remove_parent` |
| Role definition | "`editor` implies `viewer` on documents". Roles are declared per resource type, so a typo fails when you grant | `define_role` |
| Role grant | "this user, or this group, holds this role on this resource", optionally until a time | `grant_role`, `revoke_role` |

A **group** is any entity that has members: it is the parent in a parent edge. Types are free text (`team`, `org`, `folder`), and the type decides nothing by itself. A group can hold role grants, and everything the group holds reaches its members, through nested groups too.

Your own rows (a document, a project) are not facts. A document's org or folder is its own column. It enters the permission tables only if the document has its own grant.

### Policies

A policy is one row in `permissions.policies`:

| Field | Meaning |
| --- | --- |
| `effect` | `permit` or `forbid`. Written with `permit()` and `forbid()` |
| principal scope | who the policy is about: `principal_type` (default `user`, null for any type), optionally `principal_id` (one principal), optionally `principal_in_type` + `principal_in_id` ("members of this group") |
| `actions`, `resource_type` | what it covers: free-text action names (`select`, `update`, `documents.edit`, `comment`) on one resource type |
| `resource_id` | optional: one specific resource (this is how public access works) |
| `roles` | optional: the principal, or a group it is in, must hold one of these roles. A role implies the roles below it |
| `via` | optional: where the role must be held. Null means on the resource itself. `via => 'org'` means on an org the resource is in |
| `condition` | optional: a jsonb expression over the principal, the row and the request ([conditions](#37-conditions)) |

A policy with no `roles` needs no grant: it applies to every principal in its scope.

### How a decision is computed

`can(action, type, id, row)` does this:

1. Take the enabled policies for that resource type and action whose principal scope matches the subject (its type, its id, its groups) and whose principal-side condition is true.
2. Keep those that name this resource (or none) and whose resource-side condition is true for the row.
3. A policy with `roles` matches only if the subject, or a group it is in, holds a granted, unexpired role that implies one of them on the **anchor**: the resource itself, or, with `via`, a parent of that type above the resource. The resource's parents are the keys of the `row` jsonb that name a type (`{"folder": "..."}`), its own rows in `parents`, and everything above those.
4. The answer is **true if any permit matches and no forbid matches**. There are no priorities: forbid always wins.

One more rule: a forbid that could apply to the subject but needs an input the caller did not pass (the folder, an attribute) makes `can()` raise `22023` instead of quietly not matching ([can() outside RLS](#38-calling-can-outside-rls)).

For RLS the same policies are run in reverse, once per query. `ids('select', 'document')` returns the ids of the documents this subject can reach through the facts, and `ids('select', 'document', 'folder')` returns the folder ids whose documents it can reach. The policy then reads `id = any(<list>) or folder_id = any(<list>)`, which Postgres runs as an InitPlan and answers from the column's index. You never write the lists' logic yourself.

### What the closures mean for you

Group and parent membership is stored as a transitive closure (`ancestors`, depth at most 10), updated when you write a parent edge. Reading a decision therefore never recurses. In exchange:

- **Parent writes cost more.** `add_parent(c, p)` writes one closure row per (inner descendant-or-self of `c`, ancestor-or-self of `p`) pair. A leaf (a user joining a team, a document filed in a folder) writes none. Nesting a team that holds users writes a handful of rows; nesting a sub-tree of many teams writes the product. Grants, policies and attributes are single-row writes.
- **One advisory lock.** Every parent write takes `pg_advisory_xact_lock(hashtext('permissions.closure'))` (role definitions take a second one), so closure writers queue up. The lock lasts for the writing transaction.
- **`repeatable read` is refused.** Parent and role-definition writes raise `0A000` under `repeatable read`, because its snapshot predates the lock and the closure would silently miss a concurrent edge. `read committed` and `serializable` are fine.
- **Depth cap 10, cycles rejected.** Both are checked when you write the edge and raise `23514`. A check never gives a partial answer because of depth.
- **Parent edges are immutable.** Remove and add instead (`0A000` on `update`).

## 2. Quick start

The reference scenario from [PLAN.md](../PLAN.md) §5: org `acme`, where Alice is an admin and Carol a member and admins can edit every document while members can view them. A `documents` table. Document `readme`: Bob, who is not in the org, is an editor, and team `eng` (Carol and Dave) are viewers. `editor` implies `viewer`.

**1. Declare the roles.** Roles belong to a resource type. `org` and `document` are just names you choose.

```sql
select permissions.define_role('org', 'member');
select permissions.define_role('org', 'admin', '{member}');         -- admin implies member
select permissions.define_role('document', 'viewer');
select permissions.define_role('document', 'editor', '{viewer}');   -- editor implies viewer
```

**2. Write the policies.** Say what the roles allow. The first two use `via => 'org'`: the role is held on the document's org, not on the document.

```sql
select permissions.permit('org members view docs', '{select}',        'document', roles => '{member}', via => 'org');
select permissions.permit('org admins edit docs',  '{update,delete}', 'document', roles => '{admin}',  via => 'org');
select permissions.permit('doc viewers view',      '{select}',        'document', roles => '{viewer}');
select permissions.permit('doc editors edit',      '{update}',        'document', roles => '{editor}');
select permissions.permit('org members add docs',  '{insert}',        'document', roles => '{member}', via => 'org');
```

The first three arguments of `permit` and `forbid` are positional (name, actions, resource type). The rest are named.

**3. Write the facts.**

```sql
select permissions.grant_role('user', :'alice', 'admin',  'org', :'acme');
select permissions.grant_role('user', :'carol', 'member', 'org', :'acme');
select permissions.add_parent('user', :'carol', 'team', :'eng');
select permissions.add_parent('user', :'dave',  'team', :'eng');
select permissions.grant_role('user', :'bob', 'editor', 'document', :'acme_readme');
select permissions.grant_role('team', :'eng', 'viewer', 'document', :'acme_readme');
```

**4. Create the table and generate its RLS.** `apply_rls` writes one RLS policy per command, named `permissions_<command>`. The last arguments say which columns hold the parents: here the document's org is `org_id`. It does not enable RLS or grant privileges, so do both yourself. It runs with your rights, so the table's owner calls it.

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

`select` and `delete` use the expression as `using`, `insert` as `with check`, `update` as both. What `apply_rls` generated for `select` is what `rls_expression` returns:

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

The first half is the permit side: the documents I reach through their own grants, or through an org I am in. The second half is the forbid side, which is always present, so a forbid added later needs no new RLS. Every call is an uncorrelated subquery, so Postgres runs each once per query and the per-row work is an array lookup on the column's index.

**Or write the RLS by hand.** On a second table (policies for the same command are OR'd, so you would not add these next to the generated ones). This is the permit side only, with no forbid side, and it is fine when you have no forbids. For writes of single rows, a per-row `can()` is simpler:

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

Use the `id = any (array(select unnest(...)::uuid))` form exactly (the shared guide explains why). For text or bigint keys pass `id_type` to `rls_expression` ([API](#rls-tooling)).

**5. The three questions.**

*Can Bob update readme?* `can_for` takes an explicit subject, which only an admin may do. The last argument is the row, here only its org:

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

The other users, through the same RLS: Bob sees `readme` and can update it (`UPDATE 1`), Carol and Alice see `readme` and `plan`, Alice can update `plan`, and Erin, who has no grants, sees nothing. Carol can insert a document into `acme` and gets `42501` for `globex`; Dave, in no org, cannot insert at all.

*Who can view readme?* `who_can` is admin-only. Without the row it finds the people who hold grants on readme, from its own policies. Pass the org and it also finds the org members:

```sql
select distinct subject_id from permissions.who_can('select', 'document', :'acme_readme')
where subject_type = 'user';                                         -- Bob, Carol, Dave

select distinct subject_id from permissions.who_can('select', 'document', :'acme_readme',
                                                    jsonb_build_object('org', :'acme'))
where subject_type = 'user';                                         -- Alice, Bob, Carol, Dave
```

And `explain` says why Dave is in:

```sql
select * from permissions.explain('user', :'dave', 'select', 'document', :'acme_readme');
--  effect | policy           | matched_grant
--  permit | doc viewers view | {"on": "document:<readme>", "role": "viewer", "principal": "team:<eng>"}
```

## 3. How-to guides

Each guide continues from the quick start's data. Where a guide adds a demo policy that a later one must not see, it ends by undoing it.

### 3.1 Per-object sharing

Share a document by granting a role on it. The role must be declared for the type, and a policy must say what the role allows (the quick start has `doc viewers view` and `doc editors edit`).

```sql
select permissions.grant_role('user', :'erin', 'viewer', 'document', :'acme_readme');
```

Erin now sees readme through RLS, `permissions.ids('select', 'document')` as Erin is `{readme}` (that is "what is shared with me"), and she cannot update it. Grants add up: granting `editor` as well lets her update, and the viewer grant stays.

```sql
select permissions.grant_role('user', :'erin', 'editor', 'document', :'acme_readme');
select permissions.can_for('user', :'erin', 'update', 'document', :'acme_readme');   -- true
```

Who has access, and through which policy:

```sql
select subject_id, policy from permissions.who_can('select', 'document', :'acme_readme')
where subject_type = 'user';
-- Bob, Carol, Dave and Erin, each with 'doc viewers view'
```

Revoke with `revoke_role`, which returns whether it removed anything. Granting a role the type doesn't declare raises `22023`:

```sql
select permissions.revoke_role('user', :'erin', 'editor', 'document', :'acme_readme');   -- true
select permissions.revoke_role('user', :'erin', 'viewer', 'document', :'acme_readme');   -- true
select permissions.revoke_role('user', :'erin', 'viewer', 'document', :'acme_readme');   -- false
select permissions.grant_role('user', :'erin', 'owner', 'document', :'acme_readme');     -- ERROR 22023: unknown role owner on document
```

The RLS needs no change: the `id = any(ids(...))` arm already reads grants. Sharing with a group is the same call with a group as the principal (the quick start shares readme with team `eng`).

### 3.2 Groups and nested teams

A user joins a team with `add_parent('user', ..., 'team', ...)`, and a team nests in another the same way. Whatever the outer team holds reaches the inner team's members.

```sql
select permissions.add_parent('team', :'eng', 'team', :'platform');     -- eng is in platform
select permissions.grant_role('team', :'platform', 'viewer', 'document', :'acme_plan');
select permissions.is_in('user', :'dave', 'team', :'platform');          -- true
select permissions.is_in('user', :'erin', 'team', :'platform');          -- false
```

As Dave, RLS now shows `readme` (through eng) and `plan` (through platform). The closure holds a row for the inner node `eng` and none for the users; the `closure` view adds them:

```sql
select ancestor_type, ancestor_id, depth from permissions.closure
where child_type = 'user' and child_id = :'dave';
--  team | <eng>      | 1
--  team | <platform> | 2
```

Cycles, depth beyond 10 and `repeatable read` are all refused when the edge is written:

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

Removing a member returns whether the edge existed. Dave loses what eng and platform gave him:

```sql
select permissions.remove_parent('user', :'dave', 'team', :'eng');      -- true
select permissions.can_for('user', :'dave', 'select', 'document', :'acme_plan');   -- false
select permissions.remove_parent('user', :'dave', 'team', :'eng');      -- false
select permissions.add_parent('user', :'dave', 'team', :'eng');         -- put him back
```

(The guide undoes its demo next: `revoke_role('team', :'platform', ...)` and `remove_parent('team', :'eng', 'team', :'platform')`.)

Membership has no expiry. Only role grants do (next section).

### 3.3 Expiry

A grant can end at a time. It is the last argument of `grant_role`, a column of `role_grants`, so it costs nothing at read time and needs no policy:

```sql
select permissions.grant_role('user', :'erin', 'viewer', 'document', :'acme_readme', now() + interval '7 days');
select permissions.can_for('user', :'erin', 'select', 'document', :'acme_readme');   -- true until then
```

Calling `grant_role` again for the same principal, role and resource replaces the date: a later date extends the grant, `null` makes it permanent. Here, a date in the past, as if the week had gone by:

```sql
select permissions.grant_role('user', :'erin', 'viewer', 'document', :'acme_readme', now() - interval '1 minute');
select permissions.can_for('user', :'erin', 'select', 'document', :'acme_readme');   -- false
```

RLS hides the row too: as Erin, `select title from public.documents` returns nothing. Expired rows stay in the table. Sweep them from time to time:

```sql
delete from permissions.role_grants where expires_at < now();
```

### 3.4 Parent inheritance with `via`

A policy with `via => 'org'` or `via => 'folder'` grants through a **parent** of the resource. B can learn a resource's parents in two ways, and you choose which per resource type:

- **From the row's columns.** The document says which folder it is in (`folder_id`). The document never appears in the permission tables. `can()` receives the column in its `row` argument as `{"folder": <id>}`, and RLS is given the column name as a via column.
- **From `parents` facts.** The folder is an entity: `add_parent('folder', :'specs', 'org', :'acme')` says folder `specs` is in `acme`, so a policy `via => 'org'` reaches a document through its folder. The same can be done for the document itself (`add_parent('document', id, 'folder', folder_id)`), at a cost described below.

Set up folders in orgs and give the document a `folder_id` column:

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

`can()` answers from the row's folder. The folder's own org comes from the stored edge, so Carol, an org member, reaches `plan` through folder `plans` without the caller passing the org. Passing the org directly works as well:

```sql
select permissions.can_for('user', :'erin',  'select', 'document', :'acme_readme', jsonb_build_object('folder', :'specs'));  -- true
select permissions.can_for('user', :'erin',  'select', 'document', :'acme_plan',   jsonb_build_object('folder', :'plans'));  -- false
select permissions.can_for('user', :'carol', 'select', 'document', :'acme_plan',   jsonb_build_object('folder', :'plans'));  -- true
select permissions.can_for('user', :'carol', 'select', 'document', :'acme_plan',   jsonb_build_object('org', :'acme'));      -- true
```

**RLS shape 1: projection onto the parent column.** `ids(action, type, via)` does not list documents. It lists the **parent ids** whose documents the caller can reach: the folders where the caller holds a role, plus every folder below an org or folder it holds one on. One branch on `folder_id` therefore covers org-level and folder-level access together.

```sql
select permissions.ids_for('user', :'erin',  'select', 'document', 'folder');   -- {specs}
select permissions.ids_for('user', :'carol', 'select', 'document', 'folder');   -- {specs, plans}  (every folder in her org)
select permissions.ids_for('user', :'carol', 'select', 'document', 'org');      -- {acme}
select permissions.ids_for('user', :'erin',  'select', 'document', 'org');      -- {}
```

RLS written before the folder policy existed does not know it. Erin sees nothing (it fails closed), and `lint()` does not report it. Regenerate with the new via column, here both columns ([3.10](#310-regenerating-rls-when-policies-change-shape)):

```sql
select permissions.apply_rls('public.documents', 'select', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
select permissions.apply_rls('public.documents', 'update', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
```

Erin now sees `readme`, and Carol still sees both documents. Measured, on 1M documents (PG 18, Docker, p50): a page of 50 through this shape takes **1.15 ms**, and a count 8.20 ms (about 8 ms is the floor for all three engines on that count). Moving a document is an `update` of its column.

**RLS shape 2: single branch from `parents` rows.** If every document has a row in `parents`, `ids('select', 'document')` itself lists every document the caller can reach, so the policy has one branch and no column names:

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

Carol sees `readme` and `plan` from `documents_flat`, Erin sees `readme`. With the parents row stored, `can()` does not need the folder in its row any more.

The cost is the point of choosing: one `parents` row per document, kept in step with your column. Measured on 1M documents (PG 18, Docker, p50):

| | projection (shape 1) | single branch (shape 2) |
| --- | --- | --- |
| page of 50 | 1.15 ms | 13.7 ms (about 12x) |
| count | 8.20 ms | 21.6 ms |
| seed (1M `parents` rows) | none | 44.8 s |
| storage added | none | about 357 MB |

At medium scale with wide memberships (100k documents, 50 teams per user) the two are close: 15.1 and 13.7 ms for a page. Prefer shape 1. Use shape 2 when you can't name the parent columns in the policy, or you want `can()` and `who_can` to work from the facts alone.

The rows must follow the column. A document moved in the column only keeps its old `parents` row, and that stale row keeps feeding `ids()` on every table, including shape 1. Here readme moves to `plans` in the column, and Erin, who holds `specs`, still sees it until the `parents` row moves too:

```sql
update public.documents set folder_id = :'plans' where id = :'acme_readme';
-- as Erin: select title from public.documents  ->  readme   (stale parents row)
select permissions.remove_parent('document', :'acme_readme', 'folder', :'specs');
select permissions.add_parent('document', :'acme_readme', 'folder', :'plans');
-- as Erin: select title from public.documents  ->  nothing
```

Keep them in step with a trigger on the table, or don't store document edges at all. Every document also needs a `parents` row for shape 2 to see it, including documents with no folder (point them at the org). The guide undoes its demo: moves readme back, drops `documents_flat`, and removes the document edges.

### 3.5 Public access

Public access is a policy with no roles on one resource. It applies to every signed-in subject:

```sql
insert into public.documents (id, org_id, title) values (:'announcement', :'globex', 'announcement');
select permissions.permit('announcement is public', '{select}', 'document', resource_id => :'announcement');
```

As Frank, who has no grants at all, `select title from public.documents` returns `announcement`. He cannot update it. With no subject, RLS returns nothing and `can()` is false: "public" means every identified user, not `anon`. Revoke it by dropping the policy; `drop_policy` returns whether it existed:

```sql
select permissions.drop_policy('announcement is public');   -- true
select permissions.drop_policy('announcement is public');   -- false
```

The generated RLS needs no change for a `resource_id` policy: the id arm lists it. For "everyone in a group may see every document" (a policy with no roles and no `resource_id`), see [3.10](#310-regenerating-rls-when-policies-change-shape).

### 3.6 Forbid policies

`forbid` has the same arguments as `permit`. A matching forbid beats every permit, including one derived from an org or a team.

**On one user.**

```sql
select permissions.forbid('block dave on readme', '{select,update,delete}', 'document',
                          resource_id => :'acme_readme', principal_id => :'dave');
```

Dave is in team eng, which can view readme, and is refused. Carol, in the same team, is not. As Dave, RLS hides readme. The generated RLS already has a forbid side, so nothing is regenerated. `drop_policy('block dave on readme')` lifts it.

**On a group.** `principal_in_type` and `principal_in_id` scope a policy to the members of a group, nested members included. Contractors are read-only on every document:

```sql
select permissions.add_parent('user', :'erin', 'team', :'contractors');
select permissions.grant_role('user', :'erin', 'editor', 'document', :'acme_readme');
select permissions.forbid('contractors are read only', '{update,delete}', 'document',
                          principal_in_type => 'team', principal_in_id => :'contractors');
```

Erin was an editor of readme and could update it. Now `can_for('user', :'erin', 'update', 'document', :'acme_readme', jsonb_build_object('folder', :'specs'))` is false, and as Erin `update public.documents ... where id = :'acme_readme'` touches no rows (`UPDATE 0`) while `select` still works. Bob, not a contractor, can still update.

**Through a role.** Keep the deny in the facts: declare a `blocked` role and forbid whoever holds it on a folder.

```sql
select permissions.define_role('folder', 'blocked');
select permissions.forbid('blocked folders', '{select}', 'document', roles => '{blocked}', via => 'folder');
select permissions.grant_role('user', :'carol', 'blocked', 'folder', :'specs');
```

Carol, an org member and a viewer through eng, now sees `plan` but not `readme`. `denied_ids_for('user', :'carol', 'select', 'document', 'folder')` is `{specs}`. This forbid reads the document's folder, so every `can()` call for a subject who holds `blocked` has to pass it ([3.8](#38-calling-can-outside-rls)). The parent column has to be a via column in the RLS ([3.4](#34-parent-inheritance-with-via)), and a row whose folder is null is hidden from such a subject ([gotchas](#6-gotchas-and-limits)).

Forbids with a condition (`condition => ...`) are compiled into the RLS when it is generated, so adding one means regenerating ([3.10](#310-regenerating-rls-when-policies-change-shape)). Forbids with a role on a new `via` type also need that via column named.

### 3.7 Conditions

A condition is a jsonb expression tree. It is evaluated by the engine (no `execute`), never by your SQL. Conditions go on `permit` and `forbid`.

**On the row.** Org guests may view published documents only:

```sql
alter table public.documents add column status text not null default 'published';
update public.documents set status = 'draft' where id = :'acme_plan';
select permissions.define_role('org', 'guest');
select permissions.permit('org guests view published docs', '{select}', 'document', roles => '{guest}', via => 'org',
                          condition => '{"op": "==", "left": {"var": "resource.status"}, "right": "published"}');
select permissions.grant_role('user', :'gina', 'guest', 'org', :'acme');
```

`can()` takes the attribute from the row: Gina can view a published readme and not a draft plan.

```sql
select permissions.can_for('user', :'gina', 'select', 'document', :'acme_readme',
                           jsonb_build_object('org', :'acme', 'status', 'published'));   -- true
select permissions.can_for('user', :'gina', 'select', 'document', :'acme_plan',
                           jsonb_build_object('org', :'acme', 'status', 'draft'));       -- false
```

The RLS has to contain the condition, so regenerate it. Until then Gina sees nothing and `lint()` says so (`resource condition on select/document is not in any RLS policy; re-run apply_rls`). `apply_rls` compiles the condition into SQL on the table's `status` column and gives it its own `ids(...)` group:

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

As Gina, RLS now shows `readme` only; once `plan` is published (`update ... set status = 'published'`) she sees both. Carol, who is no guest, is unaffected.

**On the principal.** Attributes live in `permissions.entities`, set with `set_attrs`, which replaces the whole object. Only verified users may comment (`comment` is just an action name, used with `can()`):

```sql
select permissions.set_attrs('user', :'erin', '{"verified": true}');
select permissions.permit('verified viewers comment', '{comment}', 'document', roles => '{viewer}',
                          condition => '{"op": "==", "left": {"var": "principal.attrs.verified"}, "right": true}');
select permissions.can_for('user', :'erin', 'comment', 'document', :'acme_readme');   -- true
select permissions.can_for('user', :'bob',  'comment', 'document', :'acme_readme');   -- false: no attributes
select permissions.set_attrs('user', :'bob', '{"verified": true}');
select permissions.can_for('user', :'bob',  'comment', 'document', :'acme_readme');   -- true
```

**On the request.** `context.jwt.<claim>` reads the JWT in `request.jwt.claims`. Editing needs a second factor; the forbid has no roles and no resource, so it is a deny for everyone while the condition holds. A claim that is missing makes `==` false, so `not` makes it a deny (fail closed):

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

The generated update policy already had a forbid side, and a policy with only a principal-side condition needs no regeneration: `denies_all` evaluates it once per query.

**Which part runs when.** A condition is split on write into two halves at the top-level `and`:

| Half | Terms | Runs |
| --- | --- | --- |
| principal half | `principal.*`, `context.*`, `now` | once per query, inside `ids()` / `denied_ids()` / `allows_all()` / `denies_all()` |
| resource half | `resource.<column>` | per row. In RLS it is compiled to SQL on the column. In `can()` it is evaluated against the `row` jsonb |

`resource.status` means the table's column `status`, compared through `to_jsonb(status)`, so the SQL means what the interpreter means. The attribute names must be column names.

**The AST.** Examples, each checked in the spec against a throwaway policy:

| Operator | Example |
| --- | --- |
| `==` `!=` `<` `<=` `>` `>=` | `{"op": ">=", "left": {"var": "resource.score"}, "right": 5}` |
| `in` | `{"op": "in", "left": {"var": "resource.status"}, "right": ["draft", "review"]}` |
| `has` | `{"op": "has", "var": "resource.status"}` (present and not null) |
| `and`, `or` | `{"op": "and", "args": [<term>, <term>]}` |
| `not` | `{"op": "not", "arg": <term>}` |

A missing or null operand makes a comparison false, `!=` included. The full grammar is in the [API reference](#condition-ast-grammar).

**What is rejected** when you write the policy, all with `22023`:

```sql
-- a term that reads both the row and the principal can't be partially evaluated
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

Operators and the shape of the AST are not checked on write: a misspelled operator raises `22023` when the policy is first evaluated, and `apply_rls` then produces broken SQL. Run `can_for` against a new conditional policy once.

**"Authors edit their own documents"** needs `resource.owner_id == principal.id`, which is refused. Make it a fact: grant the author a role on the new row. A `security definer` trigger does it, because clients can't call `grant_role`:

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

As Carol, an org member who may insert, inserts a document into folder `plans` and can then update it, but not readme.

### 3.8 Calling `can()` outside RLS

`can()` only knows the row through its fourth argument. Give it what a policy could read: the row's parent ids under the **type name** (`"folder"`, `"org"`, not `folder_id`) and any attributes a condition reads. Build it from the row once, in a function:

```sql
create function public.doc_ctx(d public.documents) returns jsonb language sql stable as $$
    select jsonb_build_object('org', d.org_id, 'folder', d.folder_id, 'status', d.status)
$$;

select permissions.can_for('user', :'bob', 'update', 'document', d.id::text, public.doc_ctx(d))
from public.documents d where d.id = :'acme_readme';                    -- true
-- as Bob, with the current subject: permissions.can('update', 'document', d.id::text, public.doc_ctx(d))
```

A null value says "the row has none" and counts as given.

**Fail closed.** A forbid that could apply to the subject needs its inputs. If the call leaves out something the forbid reads, `can()` raises `22023` instead of treating the forbid as not matching, which would have allowed:

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

Rules for what is "needed": a resource condition needs every `resource.<attr>` it reads to be a key of the row; `via => T` needs a `T` key or a `T` ancestor known from `parents` (a folder's stored org counts, so `{"folder": ...}` covers a `via => 'org'` forbid, but `{"folder": null}` does not vouch for the org). A forbid that can't apply to the subject (it holds no `blocked` role, it isn't in the group) needs nothing. `who_can` and `explain` raise the same way. RLS never calls `can()` and never raises: it reads the real columns.

Adding a row-dependent forbid can make existing `can()` calls that pass too little start raising for the subjects it could apply to. That is the intended failure, but it is a runtime one.

`can()` trusts its `row` argument. A client passing a made-up folder only fools itself (RLS reads the columns), but server code must not feed client-supplied row data to `can()` and treat the answer as a gate.

### 3.9 `who_can`, `explain`, `lint`

All three are admin-only, for debugging and review. `who_can` and `explain` go through the same matcher as `can()`, so they agree with it.

```sql
-- who can view readme? Pass the row, so the folder, org and status policies count
select distinct w.subject_id
from public.documents d
cross join lateral permissions.who_can('select', 'document', d.id::text, public.doc_ctx(d)) w
where d.id = :'acme_readme' and w.subject_type = 'user';
-- Alice, Bob, Dave, Erin, Gina.  Carol is blocked (3.6), so she is not listed.

-- why can't Carol?  every policy that matches, with the grant behind it
select e.effect, e.policy, e.matched_grant
from public.documents d
cross join lateral permissions.explain('user', :'carol', 'select', 'document', d.id::text, public.doc_ctx(d)) e
where d.id = :'acme_readme';
--  permit | doc viewers view      | {"on": "document:<readme>", "role": "viewer",  "principal": "team:<eng>"}
--  permit | org members view docs | {"on": "org:<acme>",        "role": "member",  "principal": "user:<carol>"}
--  forbid | blocked folders       | {"on": "folder:<specs>",    "role": "blocked", "principal": "user:<carol>"}
```

`explain` lists permits first, then forbids; no rows means nothing matched. A permit can show up twice when its anchor is reachable by two routes (an org key in the row and the folder's stored org). `who_can` is not for RLS: it fans out through group descendants and re-checks each candidate.

`lint()` returns `(problem, policy)` rows for what it can see. It reads `pg_policy` text, so it is a review aid, not a proof. Right after the contractors forbid of 3.6 it reports a forbid that no RLS policy enforces:

```sql
select * from permissions.lint();
--  forbid on delete/document is not enforced by any RLS policy (no denied_ids branch); can() still applies it | contractors are read only
grant delete on public.documents to authenticated;
select permissions.apply_rls('public.documents', 'delete', 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
select * from permissions.lint();   -- no rows
```

It checks four things: a role not declared on a policy's anchor type, a forbid whose action has no `denied_ids` branch in any RLS policy, an allow-all permit that no RLS policy includes, and a resource condition that no RLS policy includes. It does not notice a new `via` type or a new via column.

The guide ends by dropping `blocked folders` and revoking Carol's `blocked` grant.

### 3.10 Regenerating RLS when policies change shape

The expression `apply_rls` writes is fixed when it runs. What it contains comes from the policies of that moment, so some changes need a re-run:

| You change | Regenerate? |
| --- | --- |
| a grant, a parent edge, an attribute, an expiry | no |
| a permit or forbid with a role, a `resource_id` or a principal scope, on a shape the RLS already has | no |
| a new `via` type, or a new parent column | **yes**, with the column in `via_columns`. `lint()` does not notice |
| a policy with a `condition` (permit or forbid) | **yes**. `lint()` notices |
| an allow-all permit (no roles, no `resource_id`) | **yes**. `lint()` notices |
| a forbid on an action that has no RLS policy yet | **yes**: apply it for that command. `lint()` notices |

Permits fail closed: forget and the policy grants nothing on `select`. **Forbids with a condition fail open in RLS**: until you regenerate, the table does not deny, though `can()` does. Here archived documents become read-only:

```sql
select permissions.forbid('archived is read only', '{update}', 'document',
                          condition => '{"op": "==", "left": {"var": "resource.status"}, "right": "archived"}');
select * from permissions.lint();
--  resource condition on update/document is not in any RLS policy; re-run apply_rls | archived is read only
update public.documents set status = 'archived' where id = :'acme_plan';
```

`can_for('user', :'alice', 'update', 'document', :'acme_plan', <row with status archived>)` is false, but as Alice `update public.documents set title = title where id = :'acme_plan'` still says `UPDATE 1` until you run `apply_rls(... 'update' ...)` again, and then `UPDATE 0`. (The guide drops the forbid and republishes the plan.)

Now an allow-all permit: members of `eng` may view every document:

```sql
select permissions.permit('eng views everything', '{select}', 'document',
                          principal_in_type => 'team', principal_in_id => :'eng');
select * from permissions.lint();
--  allow-all permit on select/document is not in any RLS policy (no allows_all branch); re-run apply_rls | eng views everything
```

As Dave, RLS still shows only readme. Re-run the same calls. They are idempotent (each drops and recreates `permissions_<command>`), so keep them in one migration file and run it after every policy change:

```sql
do $$
declare c text;
begin
    foreach c in array array['select', 'update', 'delete', 'insert'] loop
        perform permissions.apply_rls('public.documents', c, 'document', 'id', '{"org": "org_id", "folder": "folder_id"}');
    end loop;
end $$;
```

`lint()` is quiet again, and Dave sees every document: `allows_all_for('user', :'dave', 'select', 'document')` is true (false for Bob). The `allows_all` arm is only emitted when an allow-all permit exists at generation time, because a boolean InitPlan OR'd with the id arms stops Postgres from using the indexes. Dropping the permit later is harmless: the arm just returns false.

A policy via a new type is the case `lint()` misses:

```sql
select permissions.define_role('project', 'viewer');
select permissions.permit('project viewers view docs', '{select}', 'document', roles => '{viewer}', via => 'project');
select * from permissions.lint();   -- no rows, but the select policy does not know about projects
```

Regenerate with `'{"org": "org_id", "folder": "folder_id", "project": "project_id"}'` once the column exists.

### 3.11 Graduating from the `rbac` preset

The preset is described in the [shared guide](./README.md#the-rbac-preset), including graduation. On B it is two built-in resource types, `app` (one resource, `app:global`) and `tenant` (one per scope), with one generated policy per role and type. `create_role('editor', '{reports.edit}', '{viewer}')` declares `editor` on both, with the implication, and writes the policies `rbac:app:editor` and `rbac:tenant:editor`. `assign_role` is a role grant on `tenant:<scope>`.

Start on the preset:

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

Bob sees both reports and Dave, in no org, sees none. To share one report with Dave you add B's second concept, a policy: a role on the report, a policy that says what it allows, a grant, and one more `or` arm in the RLS. Nothing the preset wrote changes.

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

Dave sees `q1`, and `has_permission('reports.read', :'acme')` is still false for him. Bob still sees both, `user_permissions(:'alice', :'acme')` is still `{reports.read, reports.edit, reports.delete}`, and `users_with_role('admin', :'acme')` is Alice. The preset's six policies (three roles, two types) are `managed_by = 'rbac'`: `drop_policy('rbac:tenant:admin')` raises `55000`. `unassign_role` removes the grant. Keep the preset's arm as it is and add the shared arm beside it; the single-branch form is slower on large tables (see 3.4).

### 3.12 Cleaning up

The extension stores no users, so deleting yours does not remove their grants. `delete_entity(type, id)` removes everything that names an entity and returns how many rows it removed:

```sql
select permissions.delete_entity('user', :'erin');   -- 4: 2 grants, 1 parents edge, 1 attributes row
select permissions.ids_for('user', :'erin', 'select', 'document');   -- {}
select permissions.delete_entity('user', :'erin');   -- 0
```

It deletes the entity's attributes, the grants it holds and grants on it, its `parents` edges as child or parent (closures follow), and the **unmanaged policies that name it**: a `resource_id` public policy, a `principal_id` or `principal_in` policy (forbids too).

To do it automatically, attach `on_entity_deleted(type, column)` as an `after delete` trigger on the app's own tables. The first argument is the entity type, the second the column holding its id. Users and documents:

```sql
create trigger cleanup_permissions after delete on public.profiles
    for each row execute function permissions.on_entity_deleted('user', 'id');
create trigger cleanup_permissions after delete on public.documents
    for each row execute function permissions.on_entity_deleted('document', 'id');
```

Deleting Frank's profile removes his grants. Deleting a document removes the grants on it and the policies that name it:

```sql
insert into public.documents (id, org_id, title) values (:'scratch', :'acme', 'scratch');
select permissions.grant_role('user', :'gina', 'viewer', 'document', :'scratch');
select permissions.permit('scratch is public', '{select}', 'document', resource_id => :'scratch');
-- as Alice, an org admin:
delete from public.documents where id = :'scratch';   -- DELETE 1: the grant and 'scratch is public' are gone
```

The trigger function is `security definer`. Only the role that creates the trigger needs `execute` on it; clients that delete rows need nothing extra.

A deleted group takes the policies that name it. In the spec, `delete_entity('team', :'contractors')` deletes the `contractors are read only` forbid. That is right when a team is gone for good, and wrong if you meant to rename it.

## 4. API reference

Every public function in `permissions` (no leading underscore): 38 in the prototype. Read functions are `stable security definer set search_path = ''`. "Client" means granted to `public`, so `anon` and `authenticated` can call it; everything else is admin-only (the installing role, or a role you `grant execute` to; see the shared guide). Clients have no privilege on any table.

| | Functions |
| --- | --- |
| Client | `can`, `ids`, `denied_ids`, `allows_all`, `denies_all`, `current_subject_id`, `current_subject_type`, `has_permission`, `has_role`, `scopes_with_permission` (and `_unfolded_null`, an internal default) |
| Admin, explicit subject | `can_for`, `ids_for`, `denied_ids_for`, `allows_all_for`, `denies_all_for`, `who_can`, `explain`, `is_in` |
| Admin, facts | `define_role`, `grant_role`, `revoke_role`, `add_parent`, `remove_parent`, `set_attrs`, `delete_entity`, `on_entity_deleted` |
| Admin, policies | `permit`, `forbid`, `drop_policy` |
| Admin, RLS tooling | `rls_expression`, `apply_rls`, `lint` |
| Admin, rbac preset | `create_role`, `drop_role`, `assign_role`, `unassign_role`, `user_permissions`, `users_with_role` |

**The trailing dummy argument.** `ids`, `denied_ids` and `scopes_with_permission` end with a parameter (`resource_condition jsonb` for the first two, `p_unfold jsonb` for the last) whose default is `permissions._unfolded_null()`, a volatile function that returns null. The functions are stable, and Postgres evaluates a stable function at plan time when all its arguments are constants, which made every RLS query run the list twice. A default that is not a constant stops that, while the function still reads the query's snapshot. So **don't pass `scopes_with_permission`'s argument** (its value is ignored), call `ids(action, type)` and `ids(action, type, via)` with the short forms, and pass `resource_condition` only the way `rls_expression` does. If you call `ids('select', 'document', null, '{...}'::jsonb)` with every argument constant, it is evaluated at plan time again. `_unfolded_null()` is granted to `public` because defaults run as the caller; the grants of the three functions name the full signature (`ids(text, text, text, jsonb)`).

### Checks for the current subject (client)

The subject is `current_subject_id()` and `current_subject_type()`; with no subject every check is false and every list is empty.

#### `can(action text, resource_type text, resource_id text, resource jsonb default '{}') returns boolean`

Is the current subject allowed? Evaluates the policies as in [How a decision is computed](#how-a-decision-is-computed). `resource` is the row: parents under their type name, attributes under their column name. Raises `22023` when a forbid that could apply needs an input the row lacks ([3.8](#38-calling-can-outside-rls)). Use it for single-row checks and hand-written per-row RLS.

```sql
select permissions.can('select', 'document', :'acme_readme', jsonb_build_object('org', :'acme'));   -- as Dave: true
```

#### `ids(action text, resource_type text, via text default null, resource_condition jsonb default _unfolded_null()) returns text[]`

The partial evaluation used by RLS. With no `via`: the ids of resources the subject reaches through its own grants (and groups'), through `parents` rows (a document filed in a folder), or through a `resource_id` policy. With `via => 'folder'`: the **folder ids** such that a resource directly in that folder would be permitted. `resource_condition` selects the policies whose condition equals it (null: the unconditioned ones). The list is net of unconditioned forbids in the same projection. Returns `'{}'` with no subject.

```sql
select permissions.ids('select', 'document');             -- as Erin, after 3.1: {readme}
select permissions.ids('select', 'document', 'folder');
```

#### `denied_ids(action text, resource_type text, via text default null, resource_condition jsonb default _unfolded_null()) returns text[]`

The forbid side of `ids`: the ids (or parent ids) named by forbid policies that apply to the subject. Not net of anything. Used on the deny side of RLS.

```sql
select permissions.denied_ids('select', 'document');   -- as Frank, with a forbid on plan: {plan}
```

#### `allows_all(action text, resource_type text, resource_condition jsonb default null) returns boolean`

True if an allow-all permit (no roles, no `resource_id`) applies to the subject and no allow-all forbid does. It is the `allows_all` arm of RLS, emitted only when such a permit exists.

```sql
select permissions.allows_all('select', 'document');   -- false unless an allow-all permit covers this subject
```

#### `denies_all(action text, resource_type text, resource_condition jsonb default null) returns boolean`

True if a forbid with no roles and no `resource_id` applies to the subject, which includes a forbid on a group the subject is in or with a principal-side condition that holds. The deny side of RLS always includes it.

```sql
select permissions.denies_all('select', 'document');   -- false for Frank
```

#### `current_subject_id() returns text`, `current_subject_type() returns text`

The id comes from the JWT `sub`, then the `permissions.subject_id` setting, else null. The type defaults to `'user'` and can be set with `permissions.subject_type`. See the shared guide.

```sql
select permissions.current_subject_id();    -- the JWT sub, or the setting
select permissions.current_subject_type();  -- 'user', or the permissions.subject_type setting
```

#### `has_permission(permission text, scope text default null)`, `has_role(role text, scope text default null)`, `scopes_with_permission(permission text, p_unfold jsonb default _unfolded_null()) returns text[]`

The `rbac` preset's checks; the behaviour is in the shared guide. On B, `has_permission` is `can_for(current subject, permission, 'tenant', scope)` (`'app'`/`'global'` with no scope), and `scopes_with_permission` is `ids_for(current subject, permission, 'tenant')`.

```sql
select permissions.has_permission('reports.edit', :'acme');         -- as Bob: true
select permissions.scopes_with_permission('reports.read');          -- as Bob: {acme}
```

### Checks for an explicit subject (admin)

These take `subject_type, subject_id` first. They are admin-only because a client able to call them could ask what anyone can see.

#### `can_for(subject_type text, subject_id text, action text, resource_type text, resource_id text, resource jsonb default '{}') returns boolean`

`can()` for any subject. Null `subject_id` returns false.

```sql
select permissions.can_for('user', :'bob', 'update', 'document', :'acme_readme', jsonb_build_object('org', :'acme'));   -- true
```

#### `ids_for(subject_type text, subject_id text, action text, resource_type text, via text default null, resource_condition jsonb default null) returns text[]`

`ids()` for any subject (and no dummy argument). Returns `'{}'` for a null subject. As a **list** it is exact only for unconditioned policies ([gotchas](#6-gotchas-and-limits)).

```sql
select permissions.ids_for('user', :'carol', 'select', 'document', 'org');    -- {acme}
select permissions.ids_for('user', :'gina', 'select', 'document', 'org', null); -- {}: her only policy has a condition
select permissions.ids_for('user', :'gina', 'select', 'document', 'org',
    '{"op": "==", "left": {"var": "resource.status"}, "right": "published"}');  -- {acme}
```

#### `denied_ids_for(subject_type text, subject_id text, action text, resource_type text, via text default null, resource_condition jsonb default null) returns text[]`

`denied_ids()` for any subject.

```sql
select permissions.denied_ids_for('user', :'frank', 'select', 'document');   -- {plan} with 'block frank on plan'
```

#### `allows_all_for(subject_type text, subject_id text, action text, resource_type text, resource_condition jsonb default null) returns boolean`, `denies_all_for(...same arguments...) returns boolean`

`allows_all()` and `denies_all()` for any subject.

```sql
select permissions.allows_all_for('user', :'gina', 'select', 'document');   -- false
select permissions.denies_all_for('user', :'gina', 'select', 'document');   -- true with a 'block gina' forbid (no roles, no resource)
```

#### `who_can(action text, resource_type text, resource_id text, resource jsonb default '{}') returns table (subject_type text, subject_id text, policy text)`

Subjects who can do the action on one resource, with the permit policy that admits them. Runs each permit in reverse (grants on the anchors, groups expanded to their members of the policy's `principal_type`), then keeps only subjects `can_for` agrees with, so forbids and conditions apply. A subject appears once per policy. A policy with no principal restriction (public access) returns one `('*', '*', policy)` row, which is not net of forbids. Raises `22023` like `can()`.

```sql
select * from permissions.who_can('select', 'probe', 'p1');
-- with permit('probe for everyone', '{select}', 'probe'): one row, ('*', '*', 'probe for everyone')
```

#### `explain(subject_type text, subject_id text, action text, resource_type text, resource_id text, resource jsonb default '{}') returns table (effect text, policy text, matched_grant jsonb)`

Every policy that matches, permits first, then forbids; `matched_grant` is `{"principal": "type:id", "role": ..., "on": "type:id"}` for a policy with a role, null otherwise. Empty means nothing matched. Raises `22023` like `can()`.

```sql
select * from permissions.explain('user', :'dave', 'select', 'document', :'acme_readme');
```

#### `is_in(child_type text, child_id text, parent_type text, parent_id text) returns boolean`

Is the child inside the parent, directly or through any number of levels (Cedar's `in`)? Reads the stored edges only.

```sql
select permissions.is_in('user', :'dave', 'team', :'platform');   -- true while eng is in platform
```

### Facts (admin)

#### `define_role(resource_type text, role text, implies text[] default '{}') returns void`

Declares a role for a type and what it implies. Idempotent: it adds the role and any new implications and rebuilds that type's role closure under the `permissions.roles` lock. Raises `22023` for an implied role not declared on the type, `0A000` under `repeatable read`. There is no function to remove an implication or an undeclared role (the preset's `drop_role` covers `app` and `tenant` only).

```sql
select permissions.define_role('document', 'editor', '{viewer}');
```

#### `grant_role(principal_type text, principal_id text, role text, resource_type text, resource_id text, expires_at timestamptz default null) returns void`

The principal (a user, or a group of any type) holds the role on the resource. The key is (principal, resource, role), so repeating the call replaces `expires_at`. Raises `22023` if the role is not declared on the resource type. It does not check that the resource exists.

```sql
select permissions.grant_role('user', :'erin', 'viewer', 'document', :'acme_readme', now() + interval '7 days');
```

#### `revoke_role(principal_type text, principal_id text, role text, resource_type text, resource_id text) returns boolean`

Removes the grant; true if it existed.

```sql
select permissions.revoke_role('user', :'erin', 'viewer', 'document', :'acme_readme');   -- true, then false
```

#### `add_parent(child_type text, child_id text, parent_type text, parent_id text) returns void`

Adds "child is in parent". Idempotent. Takes the closure lock and maintains the closure. Raises `23514` for a cycle, a path deeper than 10 levels, or a self-edge; `0A000` under `repeatable read`.

```sql
select permissions.add_parent('user', :'dave', 'team', :'eng');
```

#### `remove_parent(child_type text, child_id text, parent_type text, parent_id text) returns boolean`

Removes the edge and rebuilds the closure of the child and its inner descendants (nothing for a leaf). True if it existed. `0A000` under `repeatable read`. See the [depth cap on delete](#6-gotchas-and-limits).

```sql
select permissions.remove_parent('user', :'dave', 'team', :'eng');   -- true
```

#### `set_attrs(type text, id text, attrs jsonb) returns void`

Sets the attributes of an entity, replacing the whole object (null becomes `{}`). Read by conditions as `principal.attrs.*`.

```sql
select permissions.set_attrs('user', :'erin', '{"verified": true}');
```

#### `delete_entity(type text, id text) returns bigint`

Removes everything that names the entity (grants held and on it, parent edges, attributes, unmanaged policies naming it) and returns the row count. See [3.12](#312-cleaning-up).

```sql
select permissions.delete_entity('user', :'erin');   -- 4
```

#### `on_entity_deleted() returns trigger`

An `after delete` row trigger function. Arguments: the entity type, and the column holding the id (`to_jsonb(old) ->> column`). Calls `delete_entity`.

```sql
create trigger cleanup_permissions after delete on public.profiles
    for each row execute function permissions.on_entity_deleted('user', 'id');
```

### Policies (admin)

#### `permit(name, actions, resource_type, roles, via, principal_in_type, principal_in_id, resource_id, condition, principal_id, principal_type) returns bigint`, `forbid(...same...)`

Creates a policy and returns its id. `name` (unique), `actions` and `resource_type` are positional; the rest are named and default to null except `principal_type`, which defaults to `'user'`.

| Argument | Meaning |
| --- | --- |
| `actions text[]` | action names, at least one |
| `roles text[]` | the principal must hold one of these on the anchor. Each must be declared on the anchor type |
| `via text` | anchor type; needs `roles`; cannot be combined with `resource_id` |
| `principal_in_type`, `principal_in_id` | members of a group; both or neither |
| `principal_id text` | one principal |
| `principal_type text` | the subject's type; null for any |
| `resource_id text` | one resource |
| `condition jsonb` | [AST](#condition-ast-grammar), split on write |

Errors: `22023` (a role not declared on the anchor type, `via` without `roles`, `via` with `resource_id`, a bad condition), `23514` (empty `actions`, `principal_in_type` without its id), `23505` (name taken). To switch a policy off without dropping it, set `enabled = false` as the owner.

```sql
select permissions.permit('announcement is public', '{select}', 'document', resource_id => :'announcement');
select permissions.forbid('contractors are read only', '{update,delete}', 'document',
                          principal_in_type => 'team', principal_in_id => :'contractors');
select permissions.permit('probe for services', '{select}', 'probe', resource_id => 'p1', principal_type => 'service');
```

#### `drop_policy(name text) returns boolean`

Deletes the policy; true if it existed. Raises `55000` for a policy the rbac preset manages.

```sql
select permissions.drop_policy('announcement is public');   -- true
```

### RLS tooling (admin)

#### `rls_expression(action text, resource_type text, id_column text default 'id', via_columns jsonb default '{}', id_type regtype default 'uuid') returns text`

The `using` / `with check` expression, as shown in the quick start. `via_columns` maps a parent type to the column holding it: `{"org": "org_id", "folder": "folder_id"}`. `id_type` is the cast for text, bigint or other keys. It includes one extra group per distinct resource condition of the policies that exist now, and an `allows_all` arm if an allow-all permit exists now.

```sql
select permissions.rls_expression('select', 'ticket', 'id', '{"org": "org_id"}', 'bigint'::regtype);   -- ids cast with ::bigint
select permissions.rls_expression('select', 'nothing_defined');   -- an id arm only
```

#### `apply_rls(table regclass, command text, resource_type text, id_column text default 'id', via_columns jsonb default '{}', to_role name default 'authenticated') returns text`

Drops and creates the table's RLS policy `permissions_<command>` from `rls_expression`, and returns its name. `command` is `select`, `insert`, `update` or `delete` (`22023` otherwise). It is the one place the extension runs dynamic SQL, and it runs with the caller's rights: the table's owner. It does not enable RLS, grant table privileges, or touch your other policies. Its parameters are named `p_table`, `p_command`, ...

```sql
select permissions.apply_rls('public.documents', 'select', 'document', 'id', '{"org": "org_id"}');   -- 'permissions_select'
```

#### `lint() returns table (problem text, policy text)`

See [3.9](#39-who_can-explain-lint).

```sql
select * from permissions.lint();
```

### rbac preset functions (admin unless noted)

The preset is documented in the [shared guide](./README.md#the-rbac-preset), with the same behaviour and error codes on every engine. On B:

| Function | On B |
| --- | --- |
| `create_role(role text, permissions text[], inherits text[] default '{}')` | `define_role` on `app` and `tenant` plus the policies `rbac:app:<role>` and `rbac:tenant:<role>`. `23505` if the role exists |
| `drop_role(role text)` | removes the policies and the role on both types. `2BP01` while another role inherits it, `22023` if unknown |
| `assign_role(user_id text, role text, scope text default null)` | a `role_grants` row on `app:global` or `tenant:<scope>`. `22023` for an unknown role |
| `unassign_role(user_id text, role text, scope text default null)` | deletes it |
| `user_permissions(user_id text, scope text default null) returns text[]` | `can_for` over every action the preset's policies name |
| `users_with_role(role text, scope text default null) returns setof text` | holders of the role (or a role implying it), group members expanded |

```sql
select permissions.create_role('viewer', '{reports.read}');
select permissions.assign_role(:'alice', 'admin', :'acme');
select permissions.user_permissions(:'alice', :'acme');     -- {reports.read, reports.edit, reports.delete}
```

### Tables and the `closure` view

All in schema `permissions`; no client privileges. Write facts through the functions; the closure tables are maintained by triggers and must not be edited. Id, type and role columns are `collate "C"`.

| Table | Columns | Notes |
| --- | --- | --- |
| `entities` | `type`, `id`, `attrs jsonb` | attributes, written by `set_attrs` |
| `parents` | `child_type`, `child_id`, `parent_type`, `parent_id` | immutable rows; triggers maintain `ancestors` |
| `ancestors` | `child_type`, `child_id`, `ancestor_type`, `ancestor_id`, `depth` (1-10) | closure rows for **inner nodes** only (entities that have children) |
| `roles` | `resource_type`, `role` | declared roles |
| `role_implies` | `resource_type`, `role`, `implies` | direct implications |
| `role_closure` | `resource_type`, `role`, `implied` | reflexive closure, rebuilt by `define_role` |
| `role_grants` | `principal_type`, `principal_id`, `role`, `resource_type`, `resource_id`, `expires_at` | primary key `(principal_type, principal_id, resource_type, resource_id, role)` |
| `policies` | `id`, `name`, `effect`, `principal_type`, `principal_id`, `principal_in_type`, `principal_in_id`, `actions`, `resource_type`, `resource_id`, `roles`, `via`, `condition`, `principal_condition`, `resource_condition`, `managed_by`, `enabled` | the condition is stored as written and split into its two halves |

`closure` is a view with `(child_type, child_id, ancestor_type, ancestor_id, depth)`: every pair, direct edges plus the stored rows of each direct parent, so leaves are included. A pair reachable along several paths appears once per path; use `distinct` or `min(depth)`. If you query it, join it with parameters or as `cross join lateral (... offset 0)`: joined directly, the planner computes every inner node's descendants first.

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

Comparisons use jsonb ordering; timestamps are ISO strings, so compare them only between values with the same offset. A missing or null operand makes a comparison false. Split on write at the top-level `and`: a term reading only `resource.*` is the resource half, a term reading no `resource.*` is the principal half, a term reading both (including a column against `now`) raises `22023`, as does an unknown variable.

### Errors

| SQLSTATE | When |
| --- | --- |
| `22023` | undeclared role; bad condition variable or mixed term; `via` rules; bad `apply_rls` command; `can()`/`who_can`/`explain` missing a forbid's input; an unknown operator when evaluated |
| `23514` | cycle, depth over 10 or self-edge in `add_parent`; empty `actions`; unpaired `principal_in_*` |
| `23505` | policy name already used; the preset's `create_role` for an existing role |
| `0A000` | parent or role-definition write under `repeatable read`; updating a `parents` row |
| `55000` | `drop_policy` on a preset-managed policy |
| `42501` | a client calling an admin function or reading a table; RLS rejecting an insert |

## 5. Performance notes

Numbers are from [`bench/baselines/OPTIMIZATIONS.md`](../bench/baselines/OPTIMIZATIONS.md): Postgres 18.6 in Docker, 4 pgbench clients, p50 in ms, one run per configuration (sub-millisecond workloads repeat within about 5%, heavier ones within about 20%). "Large" is 1M documents and 10k users, "medium" 100k documents. Each runs as `authenticated` under RLS, and writes roll back.

**Cheap**

| What | Large |
| --- | --- |
| `rbac_check` (one `has_permission`) | 0.27 |
| `rbac_select_page` / `rbac_select_count` / `rbac_update_one` | 0.73 / 0.78 / 0.47 |
| `share_list_objects` (the list function) / `share_select_page` (per-object sharing with nested teams) | 0.29 / 1.00 |
| parents, projection shape: page / count | 1.15 / 8.20 |
| `write_assign_role`, `write_share` (a grant) | 0.14, 0.14 |
| `write_nest_team` (nest a 1,000-member team of users) | 0.62 (1.47 on wide memberships) |
| `nest_check` (a check through a nested team) | 0.32 |

A check or a list costs what the caller's grants and groups cost, not what the tables hold. An org- or folder-level grant is one array element. Policy edits and grants need no maintenance writes. Planning a policy costs about 0.24 ms (catalog lookups only), because the `ids()` calls are not evaluated at plan time ([the dummy argument](#4-api-reference)).

**Expensive**

- **The single-branch parents shape.** Page 13.7 ms, count 21.6 ms (large), about 12x the projection shape, plus a seed of 44.8 s and about 357 MB for 1M documents ([3.4](#34-parent-inheritance-with-via)). The projection costs nothing extra.
- **Wide memberships.** Medium wide (50 teams per user): `share_select_page` 17.8 ms, `share_list_objects` 8.41 ms. B is the slowest engine here (A 14.4 / 4.44, C 8.20 / 3.41). Deep nesting is cheap: medium deep is 0.72 / 0.32.
- **Nesting a sub-tree of many teams.** A team of users writes a few closure rows. A team that contains hundreds of sub-teams writes (inner descendants x ancestors) rows under the global lock. Not benchmarked.
- **`who_can`.** It is a debugging function.
- **Large id arrays.** `id = any ($1)` scans the array per row it checks. Fine with an index; a caller with tens of thousands of direct grants is not measured. Don't switch to a hashed `in (select ...)`: counts were 40x slower.
- **Number of InitPlans.** One function call per arm: 5 for a table with one parent column, 7 with one resource condition.

Storage at large after the parents seed: 377.9 MB (A 404.3, C 182.4). Budgets (`--check`, p95): B misses only `parents_proj_select_count` at large (all three engines do, the heap-fetch floor of that count) and, on medium wide, `share_list_objects` and `write_nest_team`.

## 6. Gotchas and limits

- **RLS must be regenerated when policies change shape** ([3.10](#310-regenerating-rls-when-policies-change-shape)): a new via type, a condition, an allow-all permit, a forbid on a new command. A permit you forgot grants nothing, so it fails closed. A **forbid** with a condition (or on a via column the RLS lacks) that you forgot to regenerate does not deny in RLS, though `can()` still applies it. `lint()` covers conditions, allow-all permits and unenforced forbids, not new via columns, so run the regenerate step on every policy change.
- **`ids_for` as a list is not net of folder or condition forbids.** `ids_for('user', :'frank', 'select', 'document')` still lists a document Frank holds a direct grant on when a forbid blocks it through its folder or an attribute. RLS is exact, and so is `can()` with the row. Use those for decisions; the list is for display and debugging. Likewise `ids()` is exact only for unconditioned policies, and `who_can`'s `('*', '*')` row is not net of forbids.
- **A row whose parent column is null is hidden from a subject with any forbid on that column's parents.** The forbid side is `not (... folder_id = any(denied_ids))`, which is null for a null folder, so the row disappears for Frank even though `can()` says yes. Keep parent columns `not null`, or give such rows a real parent. Without a forbid, a row with a null parent is still reachable only through its own grants or another arm (an `org_id` arm).
- **The depth cap is not enforced on delete.** Inserts reject paths deeper than 10, but removing a shortcut edge can leave a shortest remaining path longer than 10, and the rebuild silently drops that pair: after removing it, `u` is still in `t0` and `m1` is still in `t6`, but `u` is no longer in `t6`, though a path of 11 hops exists. Known, kept for compatibility ([DECISION.md](../DECISION.md) open question 8). The fix would be to reject such a delete with `23514`.
- **Jsonb keys are read as parents.** In `can()`'s `row`, every key that names a type is a candidate parent of that type, so `{"folder": ...}` works. A key naming a principal type (a type a policy scopes principals by, or that holds a grant, such as `user` or `team`) is only an attribute, unless a policy on the resource type anchors `via` that type. A key that collides with an entity type is still read as a parent. Which keys count is derived from your policies and grants, so granting a role to a folder makes `folder` a principal type. Cedar's explicit parent declarations would fix it (open question 4).
- **Constant arguments fold at plan time.** The dummy argument keeps `ids()` and `scopes_with_permission` from being evaluated while planning. Pass every argument as a constant and it is folded again. `apply_rls` and `rls_expression` write the safe form; copy it.
- **Document edges go stale.** If you store `parents` rows for documents, they feed `ids()` for every RLS shape. Keep them in step with the column ([3.4](#34-parent-inheritance-with-via)).
- **Closure writes.** One global advisory lock; `repeatable read` raises `0A000`; nesting a large sub-tree writes many rows; parent edges can't be updated. Set the isolation level for permission writes explicitly if your ORM defaults to `repeatable read`.
- **`::uuid` in generated RLS fails the whole query** if any stored id for that type is not a uuid. Pass `id_type` (`'bigint'::regtype`, `'text'::regtype`) to `rls_expression` and `apply_rls` equivalents for other keys; `apply_rls` itself has no `id_type` argument, so for non-uuid keys use `rls_expression` and `create policy` yourself.
- **`apply_rls` owns the policy name.** One policy per table and command named `permissions_<command>`; a second call with another resource type replaces the first. It is security invoker, so run it as the table owner.
- **Conditions are checked less than they look.** Variable names and term mixing are validated on write; operator names and shape are not (a typo raises `22023` on first evaluation and breaks `apply_rls`). `now` and timestamps compare as ISO strings. `context.*` comes from `request.jwt.claims` and the `permissions.context` setting, which any session can set on plain Postgres: use JWT claims or server-set values. `resource.owner_id == principal.id` is refused; use a role grant on the row ([3.7](#37-conditions)).
- **No way to undefine a role** or switch off a policy except SQL on the tables as the owner. `delete_entity` on a group deletes forbids that name it.
- **`explain` can repeat a row** when one anchor is reachable by two routes.
- **Security definer everywhere.** A bug in a read function is a privilege bug; `search_path = ''` and no dynamic SQL in the read path limit it. The functions are not `leakproof`.
- **No upgrade path.** The prototype can't be re-run over an existing install.
