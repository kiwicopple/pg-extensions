# Design A: tuple core

> **History.** This guide is for the historical prototype A. It is one of the three designs that people compared before the extension became design D. The extension is D.
>
> It is not A. The user docs for the extension are at [Using pg_permissions](../../docs/README.md). This guide describes the prototype file [`prototypes/a-tuple-core.sql`](../../prototypes/a-tuple-core.sql). It does not describe the extension. For the extension, read also [The OpenFGA model](../../docs/fga.md) and [RLS with both models](../../docs/rls.md).

You chose the design that stores every permission as a relationship tuple. This is the style of Zanzibar, OpenFGA and SpiceDB. The design works out each answer when you ask for it. This page is for the app developer who uses the design. It has these parts: the mental model, a quick start, a how-to for each feature, the full API, the cost and the points to watch. You can run the quick start.

The [shared guide](../../docs/README.md) has everything that is the same on every design:

- [Install](../../docs/install.md).
- [How the design identifies the current user](../../docs/install.md) (JWT `sub`, `permissions.subject_id`).
- [Which functions clients can call and which functions are admin-only](../../docs/reference.md).
- The [`rbac` preset reference](../../docs/rbac.md) (`create_role`, `assign_role`, `has_permission`, and the other functions).
- The [general RLS rules](../../docs/rls.md).

This page does not repeat them. The design of the design and the measurements are in [the design doc](../designs/a-tuple-core.md) and in [the decision record](../decision.md).

Each example with an observable result on this page is also an assertion in [`../../test/spec/a/90_usage_examples.sql`](../../test/spec/a/90_usage_examples.sql). To run it, use `./test/run.sh 90 --impl prototypes/a-tuple-core.sql`. The page and the spec have the same order.

Contents:

- [1 Mental model](#1-mental-model)
- [2 Quick start](#2-quick-start)
- [3 How-to guides](#3-how-to-guides)
- [4 API reference](#4-api-reference)
- [5 Performance notes](#5-performance-notes)
- [6 Warnings and limits](#6-warnings-and-limits)

## 1. Mental model

### Tuples

A fact is one row, a **tuple**. You write it as `object#relation@subject`:

```
document:readme#editor@user:bob           Bob is an editor of readme
org:acme#admin@user:alice                 Alice is an admin of acme
team:eng#member@user:dave                 Dave is a member of eng
document:readme#viewer@team:eng#member    the members of eng are viewers of readme
document:readme#parent@folder:specs       readme lives in the folder specs
document:announcement#viewer@user:*       every user is a viewer of the announcement
```

Types (`user`, `team`, `org`, `document`) and IDs are text that you choose. IDs are usually your own UUIDs cast to text. The last two parts of the subject, `team:eng#member`, are a **userset**. A userset means "whoever holds `member` on `team:eng`".

This is how groups work. A team is an object with a `member` relation. You give a document to the userset, not to each person.

Use `permissions.grant(...)` to write tuples. Use `permissions.revoke(...)` to remove them. Nothing else stores access.

### Relation definitions

A relation definition says how the relations on one type relate to each other. The function `define_relation(type, relation, implied_by, from_parent, unless)` takes three lists. All three lists are optional:

| List | Meaning | Example |
| --- | --- | --- |
| `implied_by` | Relations **on the same object** that also give this relation | `define_relation('document', 'viewer', '{editor}')`: editors are viewers |
| `from_parent` | Relations **on the parent of the object** that give this relation (OpenFGA `viewer from parent`) | `define_relation('folder', 'viewer', from_parent => '{view_documents}')` |
| `unless` | Relations on the same object that **take this relation away** from a subject who holds them directly (OpenFGA `but not`) | `define_relation('document', 'viewer', unless => '{blocked}')` |

Define a relation before you give it. The function `grant` checks this.

### How the design evaluates a check: the walk

To answer "Can Dave view readme?", the design starts at Dave. It follows edges outward until it reaches `document:readme#viewer` or no more edges exist:

1. **Tuples where the current node is the subject.** From `user:dave`, the tuple `team:eng#member@user:dave` leads to the node `team:eng#member`. From `team:eng#member`, the tuple `document:readme#viewer@team:eng#member` leads to `document:readme#viewer`. Direct grants and group membership both use this step.
2. **`implied_by`.** The walk also goes from `document:readme#editor` to `document:readme#viewer`.
3. **`from_parent`.** The walk goes from `folder:specs#viewer` to `document:readme#viewer`, because readme has a `parent` tuple that points at `specs`.

The walk also starts from `user:*`, so it finds public grants. It skips tuples that expired. It never enters a node if `unless` excludes the subject from that node. The walk never expands a visited node twice, so cycles end. Cycles are, for example, team A in team B in team A, or folder loops.

The functions `check` and `check_for` search from both ends. They search from the subject and, backwards, from the target. They stop when the two searches meet, so a check costs about as much as the smaller side. The function `list_objects` walks forwards from the subject. It returns each node of the type and relation that you asked for. The function `list_subjects` walks backwards from an object.

### What "nothing derived" means for you

The only data is the tuples that you wrote and the relation definitions. The design keeps no membership tables, no closures and no caches. For you, this means:

- **No drift.** Nothing can get out of step with your grants. A deleted tuple is a complete revoke. A change to a relation definition applies to all tuples at once.
- **No locks.** A write is one row insert or one row delete. It uses no advisory locks. It puts no limit on the transaction isolation level. It causes no write amplification. To nest a team in another team, write one tuple.
- **Reads do the work.** The cost of `list_objects` grows with the amount that the subject can reach. It does not grow with the size of your tables. Checks stay cheap because they search from both ends. [Section 5](#5-performance-notes) gives the numbers.

## 2. Quick start

This is the reference scenario from [section 5 of the plan](../plan.md). The org `acme` has Alice as admin and Carol as member. The document `readme` has Bob as editor, but Bob is not in the org. The team `eng` (Carol and Dave) are viewers of `readme`.

Admins can edit all documents of the org. Members can view them. An editor is also a viewer.

The examples use psql variables for IDs. Define them one time. The values are the fixed UUIDs that the test suite uses. In another client, paste the UUIDs in place of `:'alice'` and so on.

```sql
\set alice        '00000000-0000-0000-0001-000000000001'
\set bob          '00000000-0000-0000-0001-000000000002'
\set carol        '00000000-0000-0000-0001-000000000003'
\set dave         '00000000-0000-0000-0001-000000000004'
\set erin         '00000000-0000-0000-0001-000000000005'
\set frank        '00000000-0000-0000-0001-000000000006'
\set gina         '00000000-0000-0000-0001-000000000007'
\set acme         '00000000-0000-0000-0002-000000000001'
\set globex       '00000000-0000-0000-0002-000000000002'
\set acme_plan    '00000000-0000-0000-0003-000000000001'
\set acme_readme  '00000000-0000-0000-0003-000000000002'
\set globex_notes '00000000-0000-0000-0003-000000000003'
\set eng          '00000000-0000-0000-0004-000000000001'
\set platform     '00000000-0000-0000-0004-000000000002'
```

Run the model and the data as the owner, or as any role that has the admin functions. See [roles and privileges](../../docs/reference.md).

### Model

```sql
select permissions.define_type('user');
select permissions.define_type('team');
select permissions.define_type('org');
select permissions.define_type('document');

select permissions.define_relation('team', 'member');

select permissions.define_relation('org', 'owner');
select permissions.define_relation('org', 'admin',          '{owner}');
select permissions.define_relation('org', 'member',         '{admin}');
select permissions.define_relation('org', 'edit_documents', '{admin}');
select permissions.define_relation('org', 'view_documents', '{member}');

select permissions.define_relation('document', 'editor');
select permissions.define_relation('document', 'viewer', '{editor}');
```

The third argument `'{admin}'` means that admins also hold `member`. So `admin` implies `member`, and `owner` implies `admin`. The relations `edit_documents` and `view_documents` are org-level permissions. Your policies ask about them.

### Data

```sql
select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'user', :'carol');

select permissions.grant('team', :'eng', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'dave');

select permissions.grant('document', :'acme_readme', 'editor', 'user', :'bob');
select permissions.grant('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');
```

The last line is a userset grant. The fifth and sixth arguments are the subject `team:eng#member`.

### Table and RLS

```sql
create table public.documents (
    id     uuid primary key,
    org_id uuid not null,
    title  text not null
);
insert into public.documents (id, org_id, title) values
    (:'acme_plan',    :'acme',   'plan'),
    (:'acme_readme',  :'acme',   'readme'),
    (:'globex_notes', :'globex', 'globex notes');

alter table public.documents enable row level security;
grant select, update on public.documents to authenticated;

create policy documents_select on public.documents for select to authenticated using (
    org_id = any (array(select unnest(permissions.list_objects('org', 'view_documents'))::uuid))
    or id  = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);

create policy documents_update on public.documents for update to authenticated using (
    permissions.check('org', org_id::text, 'edit_documents')
    or permissions.check('document', id::text, 'editor')
);
```

Org-wide access comes from the app column `org_id`. Tuples give the per-document access. The select policy uses the **list** form. The function `list_objects` returns, as `text[]`, the IDs that the current user can reach.

The expression `array(select unnest(...)::uuid)` casts them one time for each query. The expression `= any(...)` uses the indexes on `id` and `org_id`. Three similar forms are slower or wrong. The [shared guide](../../docs/rls.md#tenant-tables-the-fast-path) lists them.

The update policy uses the function `check` for each row. It is cheap (a few index lookups). It is correct for single-row writes.

The policies read the current user from the JWT or from `permissions.subject_id`. In the text below, "as Dave" means:

```sql
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
-- queries
reset role;
```

The session-level `false` is for tests in psql. In an app, set the subject for each transaction with `set_config(..., true)`. On Supabase, the JWT sets the subject. See [identity](../../docs/install.md).

### The three queries

**Can Bob update readme?** Yes. `user:bob` reaches `document:readme#editor` directly.

```sql
select permissions.check_for('user', :'bob', 'document', :'acme_readme', 'editor');   -- true
select permissions.check_for('user', :'bob', 'document', :'acme_plan',   'editor');   -- false

-- through RLS
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
update public.documents set title = 'readme' where id = :'acme_readme';   -- UPDATE 1
update public.documents set title = 'plan'   where id = :'acme_plan';     -- UPDATE 0
rollback;
```

**Which documents can Dave see?** Only readme. `user:dave` reaches `team:eng#member`, and that node reaches `document:readme#viewer`. He is not in acme, so the org arm of the policy is empty.

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'dave', true);
select title from public.documents;   -- readme
rollback;

select permissions.list_objects_for('user', :'dave', 'document', 'viewer');   -- {<readme's id>}
```

**Who can view readme?** Bob (an editor is a viewer), Carol and Dave (through `eng`).

```sql
select subject_id from permissions.list_subjects('document', :'acme_readme', 'viewer');
-- bob, carol, dave
```

Alice is **not** in that list, although she can view readme. That path is the `org_id` arm of the RLS policy, not tuples. As Alice, `select title from public.documents` returns `plan` and `readme`. She can update both. To make `list_subjects` include org members, move org access into the model with [parent inheritance](#34-parent-inheritance).

## 3. How-to guides

The sections build on the quick start and on each other, in order. Each section leaves the data as it was, unless the section says that it changes the model or the policy.

### 3.1 Share an object

To share one document with one person, give a relation on the document:

```sql
select permissions.grant('document', :'globex_notes', 'editor', 'user', :'erin');
```

```sql
-- as Erin
select title from public.documents;                    -- globex notes
update public.documents set title = title;             -- UPDATE 1 (editors can update)
```

A grant of `editor` also gives `viewer`. To take the grant back, use `revoke`:

```sql
select permissions.revoke('document', :'globex_notes', 'editor', 'user', :'erin');   -- true
select permissions.revoke('document', :'globex_notes', 'editor', 'user', :'erin');   -- false: nothing to remove
```

The function `revoke` returns `true` if it removed a row. To share with a group, grant to the userset of the team. When you revoke, pass the same `subject_relation`:

```sql
select permissions.grant('document', :'acme_plan', 'viewer', 'team', :'eng', 'member');
-- as Dave: plan and readme

select permissions.revoke('document', :'acme_plan', 'viewer', 'team', :'eng');             -- false: no such tuple
select permissions.revoke('document', :'acme_plan', 'viewer', 'team', :'eng', 'member');   -- true
```

The first revoke removes nothing, because `team:eng` and `team:eng#member` are different subjects. The RLS policy needs no change. The arm `id = any(list_objects('document', 'viewer'))` already finds the shared document.

### 3.2 Groups and nested teams

A team is an object with `member`. To put `eng` inside `platform`, write one tuple. Then the members of `eng` become members of `platform`:

```sql
select permissions.grant('team', :'platform', 'member', 'team', :'eng', 'member');
select permissions.grant('document', :'acme_plan', 'viewer', 'team', :'platform', 'member');
```

```sql
select permissions.check_for('user', :'dave', 'team', :'platform', 'member');         -- true
select permissions.check_for('user', :'dave', 'document', :'acme_plan', 'viewer');    -- true
select permissions.check_for('user', :'erin', 'document', :'acme_plan', 'viewer');    -- false

-- as Dave: plan and readme
```

The design has no limit on how deep you nest teams (the benchmark goes 9 levels deep). A membership cycle ends and still gives the correct answer. To make a cycle, add `team:eng#member` to `platform` as well. This is true for `check_for`, `list_objects` and `list_subjects`. Undo the cycle with `revoke`. When you remove a team from another team, you take back everything that the team carried:

```sql
select permissions.grant('team', :'eng', 'member', 'team', :'platform', 'member');    -- the cycle
select permissions.check_for('user', :'dave', 'document', :'acme_plan', 'viewer');    -- true
select count(*) from permissions.list_subjects('document', :'acme_plan', 'viewer');   -- 2: Carol and Dave
select permissions.revoke('team', :'eng', 'member', 'team', :'platform', 'member');

select permissions.revoke('team', :'platform', 'member', 'team', :'eng', 'member');   -- un-nest
select permissions.check_for('user', :'dave', 'document', :'acme_plan', 'viewer');    -- false
select permissions.revoke('document', :'acme_plan', 'viewer', 'team', :'platform', 'member');
```

A write is a single row for teams of all sizes. A deep or wide group graph makes only **reads** walk more rows. See [section 5](#5-performance-notes).

### 3.3 Expiry

Every tuple has an optional `expires_at`. After that time, every check, list and policy skips the tuple:

```sql
select permissions.grant('document', :'acme_readme', 'viewer', 'user', :'frank',
                         p_expires_at => now() + interval '1 hour');
-- as Frank: readme

select permissions.grant('document', :'acme_readme', 'viewer', 'user', :'frank',
                         p_expires_at => now() - interval '1 minute');
select permissions.check_for('user', :'frank', 'document', :'acme_readme', 'viewer');   -- false
```

The function `grant` is an upsert on the tuple. A second grant **replaces** the expiry. A second grant **without** `p_expires_at` makes the tuple permanent:

```sql
select permissions.grant('document', :'acme_readme', 'viewer', 'user', :'frank');
select permissions.check_for('user', :'frank', 'document', :'acme_readme', 'viewer');   -- true, no expiry
select permissions.revoke('document', :'acme_readme', 'viewer', 'user', :'frank');
```

Expiry also applies to memberships and parent links, so a temporary team member is one grant:

```sql
select permissions.grant('team', :'eng', 'member', 'user', :'gina', p_expires_at => now() - interval '1 day');
select permissions.check_for('user', :'gina', 'document', :'acme_readme', 'viewer');   -- false
```

Expired rows stay in the table until you remove them. They cost nothing in answers. To purge them, delete them as the owner. Nothing is derived, so a plain `delete` is a complete revoke:

```sql
delete from permissions.tuples where expires_at <= now();    -- DELETE 1 (Gina's membership)
```

`now()` is the start time of the transaction. So, inside one long transaction, an expiry does not tick.

### 3.4 Parent inheritance

Parents let access flow down a hierarchy. Org admins edit everything in the org. Folder viewers see the documents of the folder. A child points at its parent with a tuple. The relation of this tuple is always `parent`.

A relation inherits from the parent with `from_parent`. The list `from_parent` names relations **on the parent**. The parent can have any type. The design looks for the relation by name on the parent.

The example has the org, then the folder, then the document. First, define the folders. The folder inherits from `edit_documents` and `view_documents` of the org. You must define `parent` on every type that has parents:

```sql
select permissions.define_type('folder');
select permissions.define_relation('folder', 'parent');
select permissions.define_relation('folder', 'editor', from_parent => '{edit_documents}');
select permissions.define_relation('folder', 'viewer', '{editor}', from_parent => '{view_documents}');
```

To make sure that the two cannot drift, set the parent of the folder from your own column. Use the trigger function `sync_parent()`:

```sql
create table public.folders (
    id     uuid primary key,
    org_id uuid not null,
    name   text not null
);
create trigger folders_parent after insert or update of org_id or delete on public.folders
    for each row execute function permissions.sync_parent('folder', 'org', 'org_id');

\set specs '00000000-0000-0000-0005-000000000001'
\set plans '00000000-0000-0000-0005-000000000002'
insert into public.folders (id, org_id, name) values
    (:'specs', :'acme', 'specs'),
    (:'plans', :'acme', 'plans');

alter table public.documents add column folder_id uuid;
update public.documents set folder_id = :'specs' where id = :'acme_readme';
update public.documents set folder_id = :'plans' where id = :'acme_plan';

select permissions.grant('folder', :'specs', 'viewer', 'user', :'erin');   -- Erin views the specs folder
```

The function `sync_parent(object_type, parent_type, parent_column [, id_column])` runs after each insert, update and delete. It reads the columns with `to_jsonb(new)`, so one function serves every table. Then it calls `set_parent`. Only the table owner can attach it.

Without a trigger, call `set_parent(type, id, parent_type, parent_id)` yourself. It replaces the current parent. A null parent clears the parent.

Now write the RLS policy. It has two shapes. Both shapes give the same answers, but they differ in cost.

#### Shape 1: the two-arm projection (recommended)

Do **not** link documents to folders in the design. Keep `documents.folder_id` as an app column. Let the policy project the folders that you can see onto it:

```sql
drop policy documents_select on public.documents;
drop policy documents_update on public.documents;

create policy documents_select on public.documents for select to authenticated using (
    id           = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
    or folder_id = any (array(select unnest(permissions.list_objects('folder',   'viewer'))::uuid))
);

create policy documents_update on public.documents for update to authenticated using (
    permissions.check('document', id::text, 'editor')
    or permissions.check('folder', folder_id::text, 'editor')
);

-- clients may rename a document, but not move it (see below)
revoke update on public.documents from authenticated;
grant update (title) on public.documents to authenticated;
```

Each arm is its own walk. The folder arm walks to a few folders, not to every document. Results:

```sql
-- as Carol (org member): plan, readme     -- the org reaches both folders
-- as Erin (viewer of specs): readme
-- as Dave: readme                          -- still through team eng
-- as Alice (org admin): update both documents
-- as Bob: update readme only
-- as Alice: update public.documents set folder_id = null;   -- ERROR 42501 (column privilege)
```

When you move a document into a folder, the viewers of that folder get access to it. If clients can write `folder_id`, they can grant access when they move documents. The extension cannot know which moves you want. The column privilege above is the simplest fix: moves go through your backend. If clients must move documents, add a `with check` to the update policy. The `with check` must contain a test of `permissions.check('folder', folder_id::text, 'editor')` on the new folder.

#### Shape 2: the single branch

Use this shape if you want one call that covers org roles, folder grants and direct shares. Link each document to its folder. Then ask only about documents. Redefine the document relations to inherit from the folder, and attach the trigger:

```sql
select permissions.define_relation('document', 'parent');
select permissions.define_relation('document', 'editor', from_parent => '{editor}');
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}');

create trigger documents_parent after insert or update of folder_id or delete on public.documents
    for each row execute function permissions.sync_parent('document', 'folder', 'folder_id');

-- the trigger acts only when folder_id changes, so backfill the existing rows
update public.documents set folder_id = folder_id;          -- writes nothing
select permissions.set_parent('document', id::text, 'folder', folder_id::text)
from public.documents where folder_id is not null;          -- writes 2 parent tuples

drop policy documents_select on public.documents;
drop policy documents_update on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);
create policy documents_update on public.documents for update to authenticated using (
    permissions.check('document', id::text, 'editor')
);
```

The function `define_relation` replaces all three lists. Repeat `from_parent` (and `unless`) each time that you redefine a relation.

Carol, Erin, Dave, Alice and Bob get the same answers as in shape 1. The org path is now in the model. So `list_subjects` is complete, and `check_for` sees org admins:

```sql
select subject_id from permissions.list_subjects('document', :'acme_readme', 'viewer');
-- alice, bob, carol, dave, erin
select permissions.check_for('user', :'alice', 'document', :'acme_readme', 'editor');   -- true
```

When you move a document, the design rewrites its parent tuple. The viewers of the old folder lose access:

```sql
update public.documents set folder_id = :'plans' where id = :'acme_readme';
select permissions.check_for('user', :'erin', 'document', :'acme_readme', 'viewer');   -- false
update public.documents set folder_id = :'specs' where id = :'acme_readme';
select permissions.check_for('user', :'erin', 'document', :'acme_readme', 'viewer');   -- true

select permissions.set_parent('document', :'acme_readme', null, null);                 -- clear it
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');         -- or replace it
```

#### Which shape

**The single branch costs time in proportion to the number of documents that the user can see.** It costs this time on every query, because `list_objects` must produce each ID. The walk reaches the documents from a few folders. Then it gets one parent link for each document. The projection costs about the same as a policy for direct shares. The numbers below are for 1M documents, where a user sees about 20k (Postgres 18, 4 clients, p50; [OPTIMIZATIONS.md](../benchmarks/OPTIMIZATIONS.md)):

| Policy, large | First page of 50 | Count |
| --- | --- | --- |
| Two-arm projection | **1.33 ms** | 8.42 ms |
| Single branch | 45.6 ms | 75.1 ms |

The projection is about 34 times faster for the page. With small result sets, the gap closes. For medium deep, the page times of the projection and the single branch are 1.00 and 7.41 ms. For medium wide, they are 15.0 and 14.7 ms.

The single branch also costs **one parent tuple for each document**. At 1M documents, the `permissions` tables grew from 19.6 MB to 404 MB. The seed took about 31 s. Use the projection, unless a table is small or you need what only the single branch gives. The single branch gives document-level `unless` forbids ([3.6](#36-forbid-and-unless)) and a complete `list_subjects`.

The rest of this guide uses the single-branch policy, because forbid works there. Everything else carries over to the projection if you add the same condition to each arm.

### 3.5 Public access

The subject ID `*` means "every user". Anyone gets what a `user:*` grant gives. This includes a user with no tuples at all:

```sql
insert into public.documents (id, org_id, title) values (:'announcement', :'acme', 'announcement');
select permissions.grant('document', :'announcement', 'viewer', 'user', '*');
```

```sql
select permissions.check_for('user', :'frank', 'document', :'announcement', 'viewer');   -- true
select permissions.check_for('user', :'frank', 'document', :'announcement', 'editor');   -- false

-- as Frank: announcement      (the only row he sees)
```

A request with no subject at all gets no access to any document. This includes public documents. In such a request, `permissions.subject_id` is unset and no JWT exists. The wildcard covers users, not anonymous visitors.

```sql
-- no subject: select count(*) from public.documents      -- 0
select permissions.check('document', :'announcement', 'viewer');   -- false for a null subject
```

The function `list_subjects` reports the wildcard as the subject `('user', '*')`. To revoke, use the same arguments:

```sql
select count(*) from permissions.list_subjects('document', :'announcement', 'viewer')
where subject_id = '*';                                                                        -- 1
select permissions.revoke('document', :'announcement', 'viewer', 'user', '*');
select permissions.check_for('user', :'frank', 'document', :'announcement', 'viewer');   -- false
```

The wildcard also works through groups (`team:eng#member@user:*` makes everyone a member). It applies to one subject type: `user:*` does not cover a `service` subject.

### 3.6 Forbid and `unless`

A forbid takes access away from one subject, whichever path would give it. It is an ordinary tuple on a relation that excludes. You name that relation in the `unless` list of the relations that it must cut off. Both relations must opt in:

```sql
select permissions.define_relation('document', 'blocked');
select permissions.define_relation('document', 'editor', from_parent => '{editor}', unless => '{blocked}');
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}', unless => '{blocked}');

select permissions.grant('document', :'acme_readme', 'blocked', 'user', :'dave');   -- forbid
```

Dave got readme through team `eng`. Now the checks give:

```sql
select permissions.check_for('user', :'dave', 'document', :'acme_readme', 'viewer');   -- false
select :'acme_readme' = any (permissions.list_objects_for('user', :'dave', 'document', 'viewer'));   -- false
-- list_subjects('document', readme, 'viewer') no longer includes Dave; Carol stays
-- as Dave: select count(*) from public.documents      -- 0
```

The functions `check` and `list_objects` and the policy all agree. The walk never enters a node that blocks the subject, so it reaches nothing that the design derives through that node. A forbid also beats access that comes from a parent:

```sql
select permissions.grant('document', :'acme_readme', 'blocked', 'user', :'alice');
-- as Alice (org admin): sees only {plan}; update ... returns UPDATE 1 (the plan)
```

To lift a forbid, use `revoke`:

```sql
select permissions.revoke('document', :'acme_readme', 'blocked', 'user', :'alice');   -- true
select permissions.revoke('document', :'acme_readme', 'blocked', 'user', :'dave');
```

Clients cannot write forbids. The function `grant` is admin-only (`42501`).

**Limits.**

- **Direct subjects only.** You can block a user. You cannot block a team or the wildcard. The function `grant` raises `22023` for a userset or for `*` on any relation that an `unless` list names:

  ```sql
  select permissions.grant('document', :'acme_readme', 'blocked', 'team', :'eng', 'member');   -- ERROR 22023
  select permissions.grant('document', :'acme_readme', 'blocked', 'user', '*');                -- ERROR 22023
  ```

  Block each person, or take away the grant of the team.
- **Opt-in for each relation.** A relation without `unless => '{blocked}'` ignores `blocked` tuples. `editor` and `viewer` each need it. If you forget one, you leave a silent hole. Define the `unless` list **before** you write forbids. The design does not reject a userset forbid that you wrote earlier, and it ignores that forbid.
- **A forbid applies to one object and one relation.** A block of Alice on readme does not change other documents. A block on a folder relation hides everything that documents inherit through that folder. But a direct grant on a document below the folder still applies.
- **It needs the single-branch shape.** The folder arm of the two-arm policy never looks at the document node. So a document-level `blocked` tuple does not hide the document from someone who sees it through the folder arm. With the projection policy, Alice still sees readme, although she is blocked on it. Use the single branch for tables that need forbids on single documents.
- **Not an attribute rule.** "Deny if `status = 'archived'`" is RLS composition ([3.7](#37-conditions-through-rls-composition)).

### 3.7 Conditions through RLS composition

The design has no condition evaluator. Expiry is `expires_at` ([3.3](#33-expiry)). Put rules over your own columns in the policy, where Postgres filters them for free. In this example, viewers see only published documents. Editors, and so admins, also see drafts:

```sql
alter table public.documents
    add column status text not null default 'published' check (status in ('draft', 'published'));

\set draft_doc '00000000-0000-0000-0003-000000000006'
insert into public.documents (id, org_id, folder_id, title, status)
values (:'draft_doc', :'acme', :'plans', 'draft doc', 'draft');

drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    (status = 'published' and id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid)))
    or id = any (array(select unnest(permissions.list_objects('document', 'editor'))::uuid))
);
```

```sql
-- as Carol (org member): plan, readme              -- no draft
-- as Alice (org admin):  plan, readme, draft doc
-- as Dave:               readme

update public.documents set status = 'published' where id = :'draft_doc';
-- as Carol: the draft doc is now visible
```

Each `list_objects` is a subplan that runs one time for each query. So the policy costs two walks for each query, not one walk for each row. With the projection shape, put the status test in front of both viewer arms in the same way.

**The design and the policy can disagree.** The design does not know about `status`. So, outside RLS:

```sql
select permissions.check_for('user', :'carol', 'document', :'draft_doc', 'viewer');   -- true, although RLS hides it
select :'carol' = any (array(select subject_id from permissions.list_subjects('document', :'draft_doc', 'viewer')));   -- true: list_subjects over-reports
```

Any app code that decides access with `check` instead of a query on the table must repeat the status rule.

### 3.8 From the `rbac` preset to shared objects

The [`rbac` preset](../../docs/rbac.md) writes ordinary tuples on two built-in types, `app` and `tenant`. On this design, you define a type, give grants on it, and add **one `or` branch** to the policy. The role data does not change.

Start from tenant roles on a `notes` table:

```sql
select permissions.create_role('viewer', '{documents.read}');
select permissions.create_role('editor', '{documents.edit}', '{viewer}');
select permissions.create_role('admin',  '{documents.delete,users.manage}', '{editor}');

\set note_acme   '00000000-0000-0000-0006-000000000001'
\set note_globex '00000000-0000-0000-0006-000000000002'
create table public.notes (
    id     uuid primary key,
    org_id uuid not null,
    title  text not null
);
insert into public.notes (id, org_id, title) values
    (:'note_acme',   :'acme',   'acme note'),
    (:'note_globex', :'globex', 'globex note');
alter table public.notes enable row level security;
grant select on public.notes to authenticated;

select permissions.assign_role(:'bob', 'editor', :'acme');

create policy notes_select on public.notes for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
);
-- as Bob: acme note.  As Dave: nothing.
```

Share one note with Dave, who is in no org:

```sql
select permissions.define_type('note');
select permissions.define_relation('note', 'editor');
select permissions.define_relation('note', 'viewer', '{editor}');
select permissions.grant('note', :'note_globex', 'viewer', 'user', :'dave');

drop policy notes_select on public.notes;
create policy notes_select on public.notes for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
    or id  = any (array(select unnest(permissions.list_objects('note', 'viewer'))::uuid))
);
```

```sql
-- as Dave: globex note only.   has_permission('documents.read', :'globex') is still false for him.
-- as Bob: acme note, as before.
select permissions.user_permissions(:'bob', :'acme');    -- same answer as before: {documents.edit,documents.read}
```

To let the scoped roles reach the objects of the org through the model, give the type a `parent` relation. Then inherit the role permission from the `tenant` object that holds the scoped roles. This replaces the `org_id` arm:

```sql
select permissions.define_relation('note', 'parent');
select permissions.define_relation('note', 'viewer', '{editor}', from_parent => '{documents.read}');
select permissions.set_parent('note', :'note_acme', 'tenant', :'acme');

select permissions.check_for('user', :'bob', 'note', :'note_acme', 'viewer');    -- true: Bob is an editor of acme
select permissions.check_for('user', :'dave', 'note', :'note_acme', 'viewer');   -- false: Dave holds no role
```

The parents seed of the benchmark does exactly this. The same cost trade-off as in [3.4](#34-parent-inheritance) applies.

### 3.9 List and debug

**As the current user (clients can call these functions):**

```sql
-- as Dave
select permissions.list_objects('document', 'viewer');          -- {<readme's id>}
select permissions.check('document', :'acme_readme', 'viewer');  -- true
```

**As an admin, for any subject** (clients get `42501`, because these functions would let any user read the access of other users):

```sql
select permissions.list_objects_for('user', :'dave', 'document', 'viewer');                -- {<readme's id>}
select permissions.check_for('user', :'dave', 'document', :'acme_readme', 'viewer');       -- true
select * from permissions.list_subjects('document', :'acme_readme', 'viewer');             -- the people who can view it
```

Points to know when you debug:

- **A mistyped relation or type gives `false`, not an error.** The call `check_for('user', :'dave', 'document', :'acme_readme', 'vewer')` returns `false`. When an answer is wrong, check the names first.
- **`list_subjects` returns people, not the teams that they came through.** The rows are the leaf subjects (`user` IDs, and `('user', '*')` for public). The function follows usersets, `implied_by` and parents backwards. It checks forwards again the subjects that hold a forbid tuple, so it leaves out blocked users.
- **`list_objects_for` and `list_subjects` return unordered results.** Compare them as sets.
- **The tuples are the explanation.** No separate state exists to inspect. As the owner, run:

  ```sql
  select * from permissions.tuples where object_type = 'document' and object_id = :'acme_readme';
  -- 3 rows here: editor@bob, viewer@team:eng#member, parent@folder:specs
  select * from permissions.tuples where subject_type = 'user' and subject_id = :'dave';
  -- 2 rows: his team membership and the note shared with him
  ```

  Then follow the walk by hand from [section 1](#1-mental-model). Find the tuple that has the user as subject. Find the node that the tuple reaches. Find the tuple that has that node as subject.
- **Reproduce the view of a user of a table** in one transaction:

  ```sql
  begin;
  set local role authenticated;
  select set_config('permissions.subject_id', :'dave', true);
  select title from public.documents;      -- readme
  rollback;
  ```

  Add `explain` to see the policy. Each `list_objects` shows as an `InitPlan` that runs one time for each query. A `check` shows as a filter on each row.

### 3.10 Clean up when users or objects are deleted

No foreign keys exist between your tables and the tuples (IDs are text). So, when you delete a user or a document, the tuples stay. Orphan tuples are harmless, because nothing can reach a deleted ID. But a **reused** ID inherits them. Orphan tuples also accumulate. To clean up, use a trigger.

The function `delete_subject(type, id)` removes every tuple that mentions the entity, as the subject **and** as the object. It is the one call that works for users, teams, folders and documents:

```sql
create table public.app_users (id uuid primary key);   -- or your identity table; on Supabase, auth.users
insert into public.app_users values (:'dave'), (:'carol');

create function public.cleanup_permissions() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
    perform permissions.delete_subject(tg_argv[0], old.id::text);
    return old;
end $$;

create trigger app_users_cleanup after delete on public.app_users
    for each row execute function public.cleanup_permissions('user');
create trigger documents_cleanup after delete on public.documents
    for each row execute function public.cleanup_permissions('document');
create trigger folders_cleanup after delete on public.folders
    for each row execute function public.cleanup_permissions('folder');
```

On Supabase, put the `user` trigger on `auth.users` instead of `app_users`. The function is `security definer` and has an empty `search_path`, so it runs with the rights of the owner. Nothing else can call it, because nobody can call a trigger function directly.

```sql
delete from public.app_users where id = :'dave';
-- Dave's tuples are gone, and so is his access:
select permissions.list_objects_for('user', :'dave', 'document', 'viewer');    -- {}

delete from public.documents where id = :'acme_readme';
-- every tuple on readme (grants, parent link) is gone
```

Use `delete_subject` for folders, not `delete_object`. The function `delete_object(type, id)` removes only the tuples **on** the object. A folder is also the **subject** of the `parent` tuples of its children:

```sql
select permissions.delete_object('folder', :'plans');    -- 1: the folder's own parent link
select count(*) from permissions.tuples where subject_type = 'folder' and subject_id = :'plans';   -- 2: the documents' links, still there
delete from public.folders where id = :'plans';          -- the trigger calls delete_subject
select count(*) from permissions.tuples where subject_type = 'folder' and subject_id = :'plans';   -- 0
select permissions.delete_subject('user', 'nobody');     -- 0: both functions return the number of tuples removed
```

## 4. API reference

Everything is in the `permissions` schema. **Client** means that any role (`anon`, `authenticated`) can run the function. A client function answers only about the current subject. **Admin** means the owner and any role that you gave execute, usually `service_role`.

See [roles and privileges](../../docs/reference.md) for the grant. If a client calls an admin function, the function raises `42501`. All write functions are `security definer` with `search_path = ''`.

There are 24 public functions (names that do not start with an underscore) and 4 internal functions (`_reach`, `_unfolded_null`, `_scope_object`, `_add_implied_by`). In the signatures below, `argument default` means that the argument is optional.

| Function | Who | Returns |
| --- | --- | --- |
| [`define_type`](#define_type) | admin | `void` |
| [`define_relation`](#define_relation) | admin | `void` |
| [`grant`](#grant) | admin | `void` |
| [`revoke`](#revoke) | admin | `boolean` |
| [`set_parent`](#set_parent) | admin | `void` |
| [`sync_parent`](#sync_parent) | table owner (trigger) | `trigger` |
| [`delete_subject`](#delete_subject) | admin | `bigint` |
| [`delete_object`](#delete_object) | admin | `bigint` |
| [`check`](#check) | client | `boolean` |
| [`list_objects`](#list_objects) | client | `text[]` |
| [`current_subject_id`](#current_subject_id), [`current_subject_type`](#current_subject_type) | client | `text` |
| [`check_for`](#check_for) | admin | `boolean` |
| [`list_objects_for`](#list_objects_for) | admin | `text[]` |
| [`list_subjects`](#list_subjects) | admin | `table (subject_type, subject_id)` |
| [the `rbac` preset (9 functions)](#the-rbac-preset-functions) | see below | |

### Model definition

#### `define_type`

```sql
permissions.define_type(p_name text, p_description text default null) returns void
```

Admin. Defines an object type (`user`, `team`, and so on). The function is idempotent. If you call it again, it keeps the current description, unless you pass a new description. The types `user`, `app` and `tenant` are predefined. The `rbac` preset uses `app` and `tenant`.

```sql
select permissions.define_type('widget', 'A widget');
select permissions.define_type('widget');     -- keeps 'A widget'
```

#### `define_relation`

```sql
permissions.define_relation(object_type text, relation text,
                            implied_by text[] default '{}',
                            from_parent text[] default '{}',
                            unless text[] default '{}') returns void
```

Admin. Defines a relation on a type, or **replaces** all three lists of a relation that exists. It is an upsert: if you omit a list, the list becomes empty. The parameter names have no `p_` prefix, so you can write `from_parent => '{viewer}'`.

- `implied_by`: relations on the same object that imply this relation.
- `from_parent`: relations on the parent of the object (any type, found by name) that imply this relation.
- `unless`: relations on the same object that exclude this relation for a subject who holds them directly.

Errors: `23503` if `object_type` is not defined (foreign key). The design does **not** check the names inside the three lists. It accepts a typo, and the typo gives no access.

```sql
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}', unless => '{blocked}');
select permissions.define_relation('gadget', 'viewer');   -- ERROR 23503: type 'gadget' is not defined
```

### Write tuples

#### `grant`

```sql
permissions.grant(p_object_type text, p_object_id text, p_relation text,
                  p_subject_type text, p_subject_id text,
                  p_subject_relation text default '',
                  p_expires_at timestamptz default null) returns void
```

Admin. Writes the tuple `object_type:object_id#relation@subject_type:subject_id[#subject_relation]`. It is an **upsert**. If the tuple exists, the function updates only `expires_at`.

If you omit `p_expires_at`, the tuple becomes permanent. For a userset, pass `p_subject_relation` (`'member'` for `team:eng#member`). For public access, use `p_subject_id => '*'`.

Errors:

| SQLSTATE | When |
| --- | --- |
| `23503` | `(object_type, relation)` is not defined (foreign key to `relations`) |
| `22023` | `p_subject_relation` is not a defined relation of `p_subject_type` |
| `22023` | The subject is a wildcard (`'*'`) with a subject relation (`team:*#member`) |
| `22023` | The subject is a userset or a wildcard, and the relation is `parent` or a relation that some `unless` list names |
| `42501` | A client called the function |

The function does not validate the subject type. The call `grant(..., 'ghost', 'g1')` succeeds for a type that you never defined, so a typo in the subject type is silent.

```sql
select permissions.grant('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');
select permissions.grant('document', :'acme_readme', 'viewer', 'user', :'frank', p_expires_at => now() + interval '1 day');
select permissions.grant('document', :'announcement', 'viewer', 'user', '*');
```

#### `revoke`

```sql
permissions.revoke(p_object_type text, p_object_id text, p_relation text,
                   p_subject_type text, p_subject_id text,
                   p_subject_relation text default '') returns boolean
```

Admin. Deletes exactly that tuple. It returns `true` if the tuple existed. The subject relation is part of the identity of the tuple: a revoke of `team:eng` does not remove `team:eng#member`. For unknown relations, the function returns `false`.

```sql
select permissions.revoke('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');   -- true
select permissions.revoke('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');   -- false
```

#### `set_parent`

```sql
permissions.set_parent(p_object_type text, p_object_id text,
                       p_parent_type text, p_parent_id text) returns void
```

Admin. Writes the tuple `object#parent@parent_type:parent_id`. It **replaces** the current parent of that object, if any. A null `p_parent_id` clears the parent.

The relation `parent` must be defined on `p_object_type`. The errors are the errors of `grant`: `23503` if `parent` is not defined on the type, and `22023` for a `*` parent. To give an object more than one parent, use `grant(..., 'parent', ...)` directly.

```sql
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');
select permissions.set_parent('document', :'acme_readme', null, null);   -- clear
```

#### `sync_parent`

```sql
permissions.sync_parent() returns trigger
-- trigger arguments: object_type, parent_type, parent_column [, id_column default 'id']
```

A trigger function (`after insert or update of <parent_column> or delete`, `for each row`). It keeps the parent tuple in step with a column of your table. It reads both rows with `to_jsonb`. It does nothing when neither the ID nor the parent column changed. It clears the parent when the row is deleted or its ID changes. In all other cases, it calls `set_parent`.

The function has no execute privilege for `public`. Postgres checks this when you create the trigger, so only the owner can attach the trigger. Client inserts and updates still fire it. The function does not backfill rows that exist. It does not remove other tuples on a deleted row (see [3.10](#310-clean-up-when-users-or-objects-are-deleted)). The errors of `set_parent` apply: if `parent` is not defined, the function raises `23503` the first time that a row sets a parent.

```sql
create trigger documents_parent after insert or update of folder_id or delete on public.documents
    for each row execute function permissions.sync_parent('document', 'folder', 'folder_id');

create trigger widgets_parent after insert or update of box_id or delete on public.widgets
    for each row execute function permissions.sync_parent('widget', 'box', 'box_id', 'wid');   -- the id column is wid
```

#### `delete_subject`

```sql
permissions.delete_subject(p_subject_type text, p_subject_id text) returns bigint
```

Admin. Deletes every tuple where the entity is the subject **or** the object. It returns the number of deleted tuples. Use this call to clean up users, teams, folders and documents.

```sql
select permissions.delete_subject('user', :'dave');
```

#### `delete_object`

```sql
permissions.delete_object(p_object_type text, p_object_id text) returns bigint
```

Admin. Deletes the tuples **on** the object (where it is the object). It returns the number of deleted tuples. It leaves the tuples that name the object as a subject, such as the `parent` links of the children of a folder. For those tuples, use `delete_subject`.

```sql
select permissions.delete_object('document', :'acme_readme');
```

### Checks for the current subject

The subject is the JWT `sub`, or else the setting `permissions.subject_id`. The type is `user`, unless the setting `permissions.subject_type` says otherwise. With no subject, `check` gives `false` and `list_objects` gives `{}`.

#### `check`

```sql
permissions.check(p_object_type text, p_object_id text, p_relation text) returns boolean
```

Client, `stable`. It tells you if the current subject holds the relation on the object. Use it for each row, in write policies. Unknown names give `false`. Always write it with the schema name: `check` is a reserved word, and a bare `check(...)` is a syntax error ([6](#6-warnings-and-limits)).

```sql
create policy documents_update on public.documents for update to authenticated
    using (permissions.check('document', id::text, 'editor'));
```

#### `list_objects`

```sql
permissions.list_objects(p_object_type text, p_relation text,
                         p_unfold boolean default permissions._unfolded_null()) returns text[]
```

Client, `stable`. It returns the IDs of every object of that type on which the current subject holds the relation. The result is an **unordered** `text[]`. It is the fast path for `select` policies:

```sql
id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
```

**Do not pass the third argument.** The function ignores `p_unfold`. It exists so that the planner does not see the call as a constant. For a `stable` function whose arguments are all constants, Postgres evaluates the call at plan time (to estimate the row count of the `unnest`). Then it evaluates the call again when the query runs. So every query paid for two walks.

The default expression is a volatile function that returns null. This stops the plan-time evaluation and does not make `list_objects` volatile. A volatile function would read grants from a later snapshot than the rows that it filters. If you pass a constant yourself (`list_objects('document', 'viewer', true)`), Postgres folds the call again. The measurement on medium wide: the plan time was 11.7-12.8 ms and 3,564 buffers before the change, and 0.22 ms and 112 buffers after. `list_objects_for` and `scopes_with_permission` have the same argument.

#### `current_subject_id`

```sql
permissions.current_subject_id() returns text
```

Client, `stable`. It returns the JWT `sub` claim (`request.jwt.claims`) if it is present. Otherwise it returns the setting `permissions.subject_id`, or null. The JWT wins, so nothing else in a session can override the subject of a request that carries a JWT. See [identity](../../docs/install.md).

```sql
select set_config('permissions.subject_id', :'alice', false);
select permissions.current_subject_id();      -- alice's id
```

#### `current_subject_type`

```sql
permissions.current_subject_type() returns text
```

Client, `stable`. It returns the setting `permissions.subject_type`, or `'user'` if the setting is unset or empty. Set it for principals that are not users, such as a service.

```sql
select set_config('permissions.subject_type', 'service', false);
select permissions.current_subject_type();    -- service
```

### Checks for any subject (admin)

#### `check_for`

```sql
permissions.check_for(p_subject_type text, p_subject_id text,
                      p_object_type text, p_object_id text, p_relation text) returns boolean
```

Admin, `stable`. It works like `check`, for any subject. It searches from both ends and stops when they meet, so it stays cheap when the subject has a large reach. A null subject ID gives `false`. It applies expiry, `user:*`, parents and `unless`. It does not know about the conditions that you wrote in RLS.

```sql
select permissions.check_for('user', :'bob', 'document', :'acme_readme', 'editor');   -- true
```

#### `list_objects_for`

```sql
permissions.list_objects_for(p_subject_type text, p_subject_id text,
                             p_object_type text, p_relation text,
                             p_unfold boolean default permissions._unfolded_null()) returns text[]
```

Admin, `stable`. It works like `list_objects` for any subject. The result is unordered. Do not pass `p_unfold`.

```sql
select permissions.list_objects_for('user', :'dave', 'document', 'viewer');
```

#### `list_subjects`

```sql
permissions.list_subjects(p_object_type text, p_object_id text, p_relation text)
    returns table (subject_type text, subject_id text)
```

Admin, `stable`. It returns who holds the relation on the object. It walks backwards through usersets, `implied_by` and parents. It returns the leaf subjects (users, or the type that the direct tuples name), not the groups.

Public access appears as `('user', '*')`. It checks forwards again the subjects that hold an `unless` tuple, so it leaves out blocked subjects. It does not apply RLS-level conditions, so it reports too much for them.

```sql
select * from permissions.list_subjects('document', :'acme_readme', 'viewer');
```

### The `rbac` preset functions

The nine functions below are the `rbac` preset. The preset is identical on every design. The [shared guide](../../docs/rbac.md) documents it. This table is here so that the list is complete, and it adds what is specific to this design.

On A, the preset is a thin wrapper over the same tuples. Roles become relations on `app` and `tenant`. Assignments are tuples.

| Function | Who | Returns |
| --- | --- | --- |
| `create_role(p_role text, p_permissions text[], p_inherits text[] default '{}')` | admin | `void`. `23505` if the role exists, `22023` if names overlap or an inherited role is unknown |
| `drop_role(p_role text)` | admin | `void`. `22023` for an unknown role, `2BP01` if another role inherits the role |
| `assign_role(p_user_id text, p_role text, p_scope text default null)` | admin | `void`. `22023` for an unknown role |
| `unassign_role(p_user_id text, p_role text, p_scope text default null)` | admin | `void` |
| `has_permission(p_permission text, p_scope text default null)` | client | `boolean` |
| `has_role(p_role text, p_scope text default null)` | client | `boolean` |
| `scopes_with_permission(p_permission text, p_unfold boolean default permissions._unfolded_null())` | client | `text[]`. Do not pass `p_unfold` |
| `user_permissions(p_user_id text, p_scope text default null)` | admin | `text[]` |
| `users_with_role(p_role text, p_scope text default null)` | admin | `setof text` |

### Tables

All tables are in the `permissions` schema. **Clients have no privileges on any of them**, and `anon` has none too. Clients cannot read, insert, update or delete. They read and write only through the functions. As the owner, you can query the tables to debug ([3.9](#39-list-and-debug)) and to purge expired rows ([3.3](#33-expiry)).

| Table | Holds |
| --- | --- |
| `object_types (name, description)` | The types from `define_type` |
| `relations (object_type, relation, implied_by[], from_parent[], unless[], description)` | The model from `define_relation`. When you delete a type or a relation, the delete cascades to its tuples |
| `tuples (id, object_type, object_id, relation, subject_type, subject_id, subject_relation, condition, expires_at, created_at)` | One row for each fact. The first six columns are unique. `subject_relation = ''` for a direct subject. `condition` is unused: the design ignores a tuple with a non-null condition, and no function writes a condition |
| `entities (entity_type, entity_id, attributes)` | Unused in this version |
| `rbac_roles (role, permissions[], inherits[])` | What `create_role` defined |

The type, relation and ID columns use `collate "C"`, so array results come back in no meaningful order.

## 5. Performance notes

The measurements ran in Docker on Postgres 18.6, on one laptop, with 4 pgbench clients (p50). Every query ran through RLS as `authenticated`, after the session 3 optimizations. The source is [OPTIMIZATIONS.md](../benchmarks/OPTIMIZATIONS.md). It has the same matrix for Postgres 16 and 17.

"Large" is 1M documents, 10k users and 500 teams. "Deep" is teams nested 9 levels. "Wide" is 50 teams for each user and 50 shares for each team (medium, 100k documents).

### What is cheap

| Operation | p50 |
| --- | --- |
| One `grant` (`write_share`) | 0.15 ms |
| Nest a team of 1,000 members inside another team (`write_nest_team`), one tuple | 0.15 ms (large, deep and wide) |
| `check` through a nested team (`nest_check`) | 0.31 ms large, 0.34 deep, 0.37 wide |
| `has_permission` (`rbac_check`) | 0.30 ms |
| A page of 50 rows under a policy for shared objects (`share_select_page`) | 1.03 ms large, 0.76 deep |
| `list_objects` for a user (`share_list_objects`) | 0.29 ms large, 0.31 deep |
| Projection policy, page / count (`parents_proj_*`) | 1.33 / 8.42 ms large |

Checks and writes stay cheap whatever the graph looks like. A check searches from both ends. It does not walk everything that the subject can reach. The design notes give `has_permission` for a large user, on local Postgres 16 with one client. It takes about 0.13 ms with the search, and 25 ms as an `exists` over the full walk.

Writes are single rows with no locks. One `grant` sustains about 23.6k writes for each second with 4 clients. The 8 ms count is a floor that all three designs share. Current Postgres minor releases read every heap page of that count.

### What is expensive

- **The single-branch parents policy is O(visible documents).** At large, where a user sees about 20k documents, it takes 45.6 ms for a page and 75.1 ms for a count. At medium deep it takes 7.41 / 6.40 ms. At medium wide it takes 14.7 / 13.3 ms. A is the only design over the single-branch budgets. Use the two-arm projection ([3.4](#34-parent-inheritance)): 1.33 / 8.42 ms on the same data.
- **Wide groups.** The time of `list_objects` is linear in the number of nodes that the user reaches. Each node costs about 0.6 to 1 microsecond. The design notes give 4 ms for a walk of 6,795 nodes and 15-20 ms for 20,038 nodes. If you can, grant at a coarser level (an org or a team, not each document). This makes the reach smaller.
- **The medium wide data set.** A user is in 50 teams with 50 shares each, and reaches some thousands of documents. At this scale, `share_select_page` takes **14.4 ms**, against 1.03 ms at large default, and `share_list_objects` takes 4.44 ms. Two causes add up. Both `scopes_with_permission` and `list_objects` walk the whole graph of the user. Also, Postgres checks `id = any($1)` over an array of thousands of IDs linearly for each candidate row.
- **Deep teams are fine. Width is the problem.** A deep graph (9 levels) takes 0.76 ms for the page of the shared-objects policy, close to the default.
- **Storage with parent links.** The design writes one tuple for each child. At large, the `permissions` tables grow from 19.6 MB to 404 MB (about 385 bytes for each document, indexes included). The seed of 1M links takes about 31 s. The partial index `tuples_edge_kinds_idx` lets the walk skip leaves. It is 6.8 MB at large.
- **Plan time.** The walk uses only generic plans. They are right for these index-nested-loop shapes, and shifts in statistics do not affect them. But the design never switches to a hash join for a huge frontier. The dummy `p_unfold` argument ([`list_objects`](#list_objects)) makes sure that the walk runs one time.

A loses to the other designs in three cases (from [decision.md](../decision.md)):

- The single-branch policy: 45.6 ms against 13.7 for B and 4.94 for C at large.
- Wide reads: 14.4 ms against 17.8 for B and 8.20 for C.
- Storage at large: 404 MB against 378 and 182.

A wins in three cases:

- Writes that nest a team or add a member: 0.15 ms, no locks.
- Medium wide storage: 97 MB against 105 and 192.
- No drift.

## 6. Warnings and limits

**Names**

- **`check` must have the schema name.** `check` is a reserved word. `permissions.check(...)` works. If `permissions` is on your `search_path`, a bare `check(...)` is a syntax error (`42601`).
- **`parent` is a reserved relation name.** Parent links are tuples with the relation `parent`. You must define it (`define_relation('document', 'parent')`) on every type that has a parent. If you do not, the link fails with `23503`.
- **A typo in `from_parent` (or `implied_by`, `unless`) silently gives no access.** The design matches the names but does not validate them. It does not check that the parent type has the relation that you named. After you define the model, test it with `check_for`.
- **`define_relation` replaces all three lists.** If you redefine `viewer` without `from_parent`, you remove the inheritance. Repeat every list each time.
- **A mistyped relation or type in a check gives `false`.** The same is true for a subject type in `grant`: the design does not validate it.

**Identity and IDs**

- **IDs are text, and the design compares them as text.** Pass the canonical lower-case UUID text (`id::text` gives it). To the design, `AAAA...` and `aaaa...` are different IDs, although both cast to the same `uuid`.
- **A stored ID that is not a UUID breaks the policy.** The policy casts `list_objects` to `uuid[]`. One ID in the array can be not valid as a UUID. An example is a tuple written for `document:not-a-uuid`.

  Then the whole query fails for that user with `22P02`. Validate IDs when you grant. Clean up bad tuples with `delete_object`.
- **`list_objects` and `list_subjects` are unordered.** Compare them as sets.
- **Do not pass the `p_unfold` argument** of `list_objects`, `list_objects_for` and `scopes_with_permission`. A constant brings back plan-time evaluation (two walks for each query).
- **`permissions.subject_id` is a plain setting.** Any session that can run `set_config` can change it. On plain Postgres, you must trust the connection that sets it. On Supabase, the JWT wins.

  A JWT with `sub` equal to `*` is the public wildcard subject. It gets only what everyone gets, but apps must never issue it. See [identity](../../docs/install.md). The shared guide also says to set the subject for each transaction.
- **No subject means no access.** Anonymous requests get no access. This includes `user:*` documents.

**Writes**

- **`grant` is an upsert, and `revoke` is exact.** A second grant resets the expiry (to none, if you omit it). To revoke a userset, pass its `subject_relation`.
- **The design does not delete expired tuples.** They have no effect on answers. They stay until you purge them.
- **No foreign keys to your tables.** If you delete a user, document or folder, its tuples stay, unless you clean up ([3.10](#310-clean-up-when-users-or-objects-are-deleted)). A reused ID inherits the old grants.
- **Parent links duplicate a column of yours.** `sync_parent` copies it mechanically. It does not backfill. It ignores an update that leaves the column unchanged. If clients move rows by update, they can grant access to the viewers of a folder. Restrict the column or add a `with check`.
- **`set_parent` is single-parent. Raw `grant(..., 'parent', ...)` is not.** The function `grant` accepts more than one parent, and you can build a cycle (it ends).
- **Usersets and wildcards cannot be parents.** The function `grant` raises `22023`.
- **`delete_object` on a folder leaves the links of its children.** Use `delete_subject`.

**Forbid and conditions**

- **Forbid works for direct subjects only, and each relation must opt in** ([3.6](#36-forbid-and-unless)). You cannot block a group. A relation without `unless` ignores `blocked` tuples. The design ignores, and does not reject, a userset forbid that you wrote before the `unless` list existed.
- **A forbid on one document needs the single-branch policy.** The two-arm projection does not consult the document node.
- **Conditions are RLS composition**, so the design and the policy can disagree. `check_for` is `true` for a draft that RLS hides, and `list_subjects` reports too much. Any server-side check outside RLS must repeat the status rule. The design ignores a tuple with a non-null `condition`.

**Reads**

- **The cost grows with what a subject reaches.** Wide and deep graphs make `list_objects` walk more rows. Checks do not have this problem ([5](#5-performance-notes)).
- **`list_subjects` returns people, not groups.** It includes `('user', '*')` for public documents.
- **Weak validation.** Nothing stops you if you give `document#viewer` to a subject type that makes no sense. The model has no type restrictions on who can hold a relation.
