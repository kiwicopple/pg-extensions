# Engine A: tuple core

> **History.** This is the usage guide of prototype A, one of the three engines compared before the extension became design D. It describes [`prototypes/`](../prototypes/) and not the extension, and is kept as it was. For the extension, see [Using pg_permissions](README.md), [The OpenFGA model](fga.md) and [RLS with both models](rls.md).

You picked the engine that stores every permission as a relationship tuple, in the style of Zanzibar, OpenFGA and SpiceDB, and works out answers when you ask. This page is for the app developer using it: the mental model, a runnable quick start, a how-to for each feature, the full API, what it costs, and what to watch out for.

Everything that is the same on every engine lives in the [shared guide](./README.md): [installing](./README.md#install), [how the current user is identified](./README.md#identity) (JWT `sub`, `permissions.subject_id`), [which functions clients may call and which are admin-only](./README.md#roles-and-privileges), the [`rbac` preset reference](./README.md#the-rbac-preset) (`create_role`, `assign_role`, `has_permission`, ...) and the [general RLS rules](./README.md#writing-rls-policies). This page does not repeat them. The engine's design and measurements are in [designs/a-tuple-core.md](../designs/a-tuple-core.md) and [DECISION.md](../DECISION.md).

Every example with an observable result on this page is also an assertion in [`test/spec/a/90_usage_examples.sql`](../test/spec/a/90_usage_examples.sql), run with `./test/run.sh 90 --impl prototypes/a-tuple-core.sql`. The page and the spec go in the same order.

Contents: [1 Mental model](#1-mental-model) · [2 Quick start](#2-quick-start) · [3 How-to guides](#3-how-to-guides) · [4 API reference](#4-api-reference) · [5 Performance notes](#5-performance-notes) · [6 Gotchas and limits](#6-gotchas-and-limits)

## 1. Mental model

### Tuples

A fact is one row, a **tuple**, written `object#relation@subject`:

```
document:readme#editor@user:bob           Bob is an editor of readme
org:acme#admin@user:alice                 Alice is an admin of acme
team:eng#member@user:dave                 Dave is a member of eng
document:readme#viewer@team:eng#member    the members of eng are viewers of readme
document:readme#parent@folder:specs       readme lives in the folder specs
document:announcement#viewer@user:*       every user is a viewer of the announcement
```

Types (`user`, `team`, `org`, `document`) and ids are text you choose. Ids are usually your own uuids cast to text. The last two parts of the subject, `team:eng#member`, are a **userset**: "whoever holds `member` on `team:eng`". That is how groups work: a team is an object with a `member` relation, and you grant a document to the userset, not to each person.

You write tuples with `permissions.grant(...)` and remove them with `permissions.revoke(...)`. Nothing else stores access.

### Relation definitions

A relation definition says how relations on one type relate to each other. `define_relation(type, relation, implied_by, from_parent, unless)` takes three lists, all optional:

| List | Meaning | Example |
| --- | --- | --- |
| `implied_by` | relations **on the same object** that also give you this one | `define_relation('document', 'viewer', '{editor}')`: editors are viewers |
| `from_parent` | relations **on the object's parent** that give you this one (OpenFGA's `viewer from parent`) | `define_relation('folder', 'viewer', from_parent => '{view_documents}')` |
| `unless` | relations on the same object that **take this one away** from a subject who holds them directly (OpenFGA's `but not`) | `define_relation('document', 'viewer', unless => '{blocked}')` |

A relation you want to grant has to be defined first (`grant` checks it).

### How a check is evaluated: the walk

To answer "can Dave view readme?" the engine starts at Dave and follows edges outward until it reaches `document:readme#viewer`, or runs out of places to go:

1. **Tuples where the current node is the subject.** From `user:dave`, the tuple `team:eng#member@user:dave` leads to the node `team:eng#member`. From `team:eng#member`, the tuple `document:readme#viewer@team:eng#member` leads to `document:readme#viewer`. Direct grants and group membership are both this step.
2. **`implied_by`.** From `document:readme#editor` the walk also reaches `document:readme#viewer`.
3. **`from_parent`.** From `folder:specs#viewer` the walk reaches `document:readme#viewer`, because readme has a `parent` tuple pointing at `specs`.

It also starts from `user:*`, so public grants are found, skips tuples that have expired, and never enters a node the subject is excluded from by `unless`. A visited node is never expanded twice, so cycles (team A in team B in team A, folder loops) end.

`check` and `check_for` search from both ends (from the subject and backwards from the target) and stop when they meet, so a check costs about as much as the smaller side. `list_objects` walks forwards from the subject and returns everything it reached of the type and relation you asked for. `list_subjects` walks backwards from an object.

### What "nothing derived" means for you

The only data is the tuples you wrote and the relation definitions. The engine keeps no membership tables, no closures and no caches. For you that means:

- **No drift.** Nothing can get out of step with your grants. Deleting a tuple is a complete revoke. Changing a relation definition applies to all existing tuples at once.
- **No locks.** A write is one row insert or delete: no advisory locks, no restriction on transaction isolation level, no write amplification. Nesting a team inside another is one tuple.
- **Reads do the work.** The cost of `list_objects` grows with how much the subject can reach, not with the size of your tables. Checks stay cheap because they search from both ends. [Section 5](#5-performance-notes) has the numbers.

## 2. Quick start

This is the reference scenario from [PLAN.md §5](../PLAN.md): the org `acme` with Alice as admin and Carol as a member; document `readme`, where Bob (not in the org) is an editor and the team `eng` (Carol and Dave) are viewers. Admins can edit all of the org's documents, members can view them, and an editor is also a viewer.

The examples use psql variables for ids. Define them once (the values are the fixed uuids the test suite uses). In another client, paste the uuids in place of `:'alice'` and so on.

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

Run the model and data as the owner (or any role you gave the admin functions, see [roles and privileges](./README.md#roles-and-privileges)).

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

`'{admin}'` as the third argument reads "admins also hold `member`", so `member` is implied by `admin`, which is implied by `owner`. `edit_documents` and `view_documents` are org-level permissions that your policies ask about.

### Data

```sql
select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'user', :'carol');

select permissions.grant('team', :'eng', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'dave');

select permissions.grant('document', :'acme_readme', 'editor', 'user', :'bob');
select permissions.grant('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');
```

The last line is a userset grant: the fifth and sixth arguments are the subject `team:eng#member`.

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

Org-wide access comes from the app column `org_id`, per-document access from tuples. The select policy uses the **list** form: `list_objects` returns the ids the current user can reach as `text[]`, `array(select unnest(...)::uuid)` casts them once per query, and `= any(...)` uses the indexes on `id` and `org_id`. Three similar-looking forms are slower or wrong; the [shared guide](./README.md#tenant-tables-the-fast-path) lists them. The update policy uses the per-row `check`, which is cheap (a few index lookups) and right for single-row writes.

The policies read the current user from the JWT or from `permissions.subject_id`. Below, "as Dave" means:

```sql
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
-- queries
reset role;
```

That session-level `false` is for trying things out in psql. In an app, set the subject per transaction (`set_config(..., true)`), or let the JWT do it on Supabase; see [identity](./README.md#identity).

### The three queries

**Can Bob update readme?** Yes: `user:bob` reaches `document:readme#editor` directly.

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

**Which documents can Dave see?** Only readme: `user:dave` reaches `team:eng#member`, which reaches `document:readme#viewer`. He is not in acme, so the org arm of the policy is empty.

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

Alice is **not** in that list, although she can view readme: that path is the `org_id` arm of the RLS policy, not tuples. As Alice, `select title from public.documents` returns `plan` and `readme`, and she can update both. If you want `list_subjects` to include org members, move org access into the model with [parent inheritance](#34-parent-inheritance).

## 3. How-to guides

The sections build on the quick start and on each other, in order. Each leaves the data as it found it, except where it says it changes the model or the policy.

### 3.1 Per-object sharing

Share one document with one person by granting a relation on it:

```sql
select permissions.grant('document', :'globex_notes', 'editor', 'user', :'erin');
```

```sql
-- as Erin
select title from public.documents;                    -- globex notes
update public.documents set title = title;             -- UPDATE 1 (editors can update)
```

Granting `editor` gives `viewer` too. Take it back:

```sql
select permissions.revoke('document', :'globex_notes', 'editor', 'user', :'erin');   -- true
select permissions.revoke('document', :'globex_notes', 'editor', 'user', :'erin');   -- false: nothing to remove
```

`revoke` returns whether it removed a row. To share with a group, grant to the team's userset, and pass the same `subject_relation` when you revoke it:

```sql
select permissions.grant('document', :'acme_plan', 'viewer', 'team', :'eng', 'member');
-- as Dave: plan and readme

select permissions.revoke('document', :'acme_plan', 'viewer', 'team', :'eng');             -- false: no such tuple
select permissions.revoke('document', :'acme_plan', 'viewer', 'team', :'eng', 'member');   -- true
```

The first revoke removes nothing because `team:eng` and `team:eng#member` are different subjects. The RLS policy needs no change for sharing: the `id = any(list_objects('document', 'viewer'))` arm already picks it up.

### 3.2 Groups and nested teams

A team is an object with `member`. Putting `eng` inside `platform` is one tuple, and the members of `eng` become members of `platform`:

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

The engine has no nesting depth limit (the benchmark goes 9 levels deep), and a membership cycle (add `team:eng#member` to `platform` as well) terminates and still answers correctly, for `check_for`, `list_objects` and `list_subjects`. Undo it with `revoke`; un-nesting a team takes back everything it carried:

```sql
select permissions.grant('team', :'eng', 'member', 'team', :'platform', 'member');    -- the cycle
select permissions.check_for('user', :'dave', 'document', :'acme_plan', 'viewer');    -- true
select count(*) from permissions.list_subjects('document', :'acme_plan', 'viewer');   -- 2: Carol and Dave
select permissions.revoke('team', :'eng', 'member', 'team', :'platform', 'member');

select permissions.revoke('team', :'platform', 'member', 'team', :'eng', 'member');   -- un-nest
select permissions.check_for('user', :'dave', 'document', :'acme_plan', 'viewer');    -- false
select permissions.revoke('document', :'acme_plan', 'viewer', 'team', :'platform', 'member');
```

A write is a single row however big the teams are. A deep or wide group graph only makes **reads** walk more rows; see [section 5](#5-performance-notes).

### 3.3 Expiry

Every tuple has an optional `expires_at`. After it passes, the tuple is skipped by every check, list and policy:

```sql
select permissions.grant('document', :'acme_readme', 'viewer', 'user', :'frank',
                         p_expires_at => now() + interval '1 hour');
-- as Frank: readme

select permissions.grant('document', :'acme_readme', 'viewer', 'user', :'frank',
                         p_expires_at => now() - interval '1 minute');
select permissions.check_for('user', :'frank', 'document', :'acme_readme', 'viewer');   -- false
```

`grant` is an upsert on the tuple: granting again **replaces** the expiry, and granting again **without** `p_expires_at` makes the tuple permanent:

```sql
select permissions.grant('document', :'acme_readme', 'viewer', 'user', :'frank');
select permissions.check_for('user', :'frank', 'document', :'acme_readme', 'viewer');   -- true, no expiry
select permissions.revoke('document', :'acme_readme', 'viewer', 'user', :'frank');
```

Expiry applies to memberships and parent links as well, so a temporary team member is one grant:

```sql
select permissions.grant('team', :'eng', 'member', 'user', :'gina', p_expires_at => now() - interval '1 day');
select permissions.check_for('user', :'gina', 'document', :'acme_readme', 'viewer');   -- false
```

Expired rows stay in the table until you remove them, and they cost nothing in answers. To purge them, as the owner, delete them. Because nothing is derived, a plain `delete` is a complete revoke:

```sql
delete from permissions.tuples where expires_at <= now();    -- DELETE 1 (Gina's membership)
```

`now()` is the transaction's start time, so inside one long transaction an expiry does not tick.

### 3.4 Parent inheritance

Parents let access flow down a hierarchy: org admins edit everything in the org, folder viewers see the folder's documents. A child points at its parent with a tuple whose relation is always `parent`, and a relation inherits from the parent with `from_parent`, which names relations **on the parent**. The parent can be of any type; the relation is looked up by name there.

Here: org, then folder, then document. First the folders. The folder inherits from the org's `edit_documents` and `view_documents`, and `parent` has to be defined on every type that has parents:

```sql
select permissions.define_type('folder');
select permissions.define_relation('folder', 'parent');
select permissions.define_relation('folder', 'editor', from_parent => '{edit_documents}');
select permissions.define_relation('folder', 'viewer', '{editor}', from_parent => '{view_documents}');
```

Drive the folder's parent from your own column with the `sync_parent()` trigger, so the two cannot drift:

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

`sync_parent(object_type, parent_type, parent_column [, id_column])` runs after each insert, update and delete, reads the columns through `to_jsonb(new)` (so one function serves every table) and calls `set_parent`. Only the table owner can attach it. Without a trigger, call `set_parent(type, id, parent_type, parent_id)` yourself; it replaces the existing parent, and a null parent clears it.

Now the RLS policy. There are two shapes. Both give the same answers; they differ in cost.

#### Shape 1: the two-arm projection (recommended)

Do **not** link documents to folders in the engine. Keep `documents.folder_id` as an app column and let the policy project the folders you can see onto it:

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

Each arm is its own walk, and the folder arm walks to a few folders, not to every document. Results:

```sql
-- as Carol (org member): plan, readme     -- the org reaches both folders
-- as Erin (viewer of specs): readme
-- as Dave: readme                          -- still through team eng
-- as Alice (org admin): update both documents
-- as Bob: update readme only
-- as Alice: update public.documents set folder_id = null;   -- ERROR 42501 (column privilege)
```

Moving a document into a folder gives that folder's viewers access. If clients could write `folder_id`, they could grant access by moving documents, and the extension cannot know which moves are allowed. The column privilege above is the simplest fix: moves go through your backend. If clients must move documents, add a `with check` to the update policy that requires `permissions.check('folder', folder_id::text, 'editor')` for the new folder.

#### Shape 2: the single branch

If you want one call that covers org roles, folder grants and direct shares, link each document to its folder and ask only about documents. Redefine the document relations to inherit from the folder, and attach the trigger:

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

`define_relation` replaces all three lists, so repeat `from_parent` (and `unless`) whenever you redefine a relation.

Carol, Erin, Dave, Alice and Bob get the same answers as in shape 1. And because the org path is now in the model, `list_subjects` is complete and `check_for` sees org admins:

```sql
select subject_id from permissions.list_subjects('document', :'acme_readme', 'viewer');
-- alice, bob, carol, dave, erin
select permissions.check_for('user', :'alice', 'document', :'acme_readme', 'editor');   -- true
```

Moving a document rewrites its parent tuple, and the old folder's viewers lose it:

```sql
update public.documents set folder_id = :'plans' where id = :'acme_readme';
select permissions.check_for('user', :'erin', 'document', :'acme_readme', 'viewer');   -- false
update public.documents set folder_id = :'specs' where id = :'acme_readme';
select permissions.check_for('user', :'erin', 'document', :'acme_readme', 'viewer');   -- true

select permissions.set_parent('document', :'acme_readme', null, null);                 -- clear it
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');         -- or replace it
```

#### Which shape

**The single branch costs time proportional to the number of documents the user can see**, on every query, because `list_objects` has to produce each id (the walk reaches them from a few folders, but then fetches one parent link per document). The projection costs about what plain sharing costs. Measured at 1M documents, where a user sees about 20k (Postgres 18, 4 clients, p50; [OPTIMIZATIONS.md](../bench/baselines/OPTIMIZATIONS.md)):

| Policy, large | First page of 50 | Count |
| --- | --- | --- |
| Two-arm projection | **1.33 ms** | 8.42 ms |
| Single branch | 45.6 ms | 75.1 ms |

That is about 34x on the page. With small result sets the gap closes (medium deep: 1.00 vs 7.41 ms page; medium wide: 15.0 vs 14.7 ms). The single branch also costs **one parent tuple per document**: at 1M documents the `permissions` tables grew from 19.6 MB to 404 MB and the seed took about 31 s. Use the projection unless a table is small, or you need what only the single branch gives: document-level `unless` forbids ([3.6](#36-forbid-and-unless)) and a complete `list_subjects`.

The rest of this guide uses the single-branch policy from here on, because that is where forbid works. Everything else carries over to the projection by adding the same condition to each arm.

### 3.5 Public access

The subject id `*` means "every user". Anyone, including a user with no tuples at all, gets what a `user:*` grant gives:

```sql
insert into public.documents (id, org_id, title) values (:'announcement', :'acme', 'announcement');
select permissions.grant('document', :'announcement', 'viewer', 'user', '*');
```

```sql
select permissions.check_for('user', :'frank', 'document', :'announcement', 'viewer');   -- true
select permissions.check_for('user', :'frank', 'document', :'announcement', 'editor');   -- false

-- as Frank: announcement      (the only row he sees)
```

A request with no subject at all (`permissions.subject_id` unset and no JWT) is denied everything, including public documents: the wildcard covers users, not anonymous visitors.

```sql
-- no subject: select count(*) from public.documents      -- 0
select permissions.check('document', :'announcement', 'viewer');   -- false for a null subject
```

`list_subjects` reports the wildcard as the subject `('user', '*')`. Revoke with the same arguments:

```sql
select count(*) from permissions.list_subjects('document', :'announcement', 'viewer')
where subject_id = '*';                                                                        -- 1
select permissions.revoke('document', :'announcement', 'viewer', 'user', '*');
select permissions.check_for('user', :'frank', 'document', :'announcement', 'viewer');   -- false
```

The wildcard also works through groups (`team:eng#member@user:*` makes everyone a member). It is per subject type: `user:*` does not cover a `service` subject.

### 3.6 Forbid and `unless`

A forbid takes access away from one subject whichever path would have given it. It is an ordinary tuple on an "excluding" relation that you name in the `unless` list of the relations it should cut off. Both relations must opt in:

```sql
select permissions.define_relation('document', 'blocked');
select permissions.define_relation('document', 'editor', from_parent => '{editor}', unless => '{blocked}');
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}', unless => '{blocked}');

select permissions.grant('document', :'acme_readme', 'blocked', 'user', :'dave');   -- forbid
```

Dave got readme through team `eng`. Now:

```sql
select permissions.check_for('user', :'dave', 'document', :'acme_readme', 'viewer');   -- false
select :'acme_readme' = any (permissions.list_objects_for('user', :'dave', 'document', 'viewer'));   -- false
-- list_subjects('document', readme, 'viewer') no longer includes Dave; Carol stays
-- as Dave: select count(*) from public.documents      -- 0
```

`check`, `list_objects` and the policy all agree, because the walk never enters a node the subject is blocked from, so nothing derived through it is reached either. A forbid beats parent-derived access too:

```sql
select permissions.grant('document', :'acme_readme', 'blocked', 'user', :'alice');
-- as Alice (org admin): sees only {plan}; update ... returns UPDATE 1 (the plan)
```

Lift it with `revoke`:

```sql
select permissions.revoke('document', :'acme_readme', 'blocked', 'user', :'alice');   -- true
select permissions.revoke('document', :'acme_readme', 'blocked', 'user', :'dave');
```

Clients cannot write forbids: `grant` is admin-only (42501).

**Limits.**

- **Direct subjects only.** You can block a user, not a team or the wildcard. `grant` raises `22023` for a userset or `*` on any relation listed in an `unless`:

  ```sql
  select permissions.grant('document', :'acme_readme', 'blocked', 'team', :'eng', 'member');   -- ERROR 22023
  select permissions.grant('document', :'acme_readme', 'blocked', 'user', '*');                -- ERROR 22023
  ```

  Block each person, or take the team's grant away.
- **Opt-in per relation.** A relation without `unless => '{blocked}'` ignores `blocked` tuples. `editor` and `viewer` each need it; forgetting one is a silent hole. Define the `unless` list **before** you write forbids: a userset forbid written earlier is not rejected afterwards, and it is ignored.
- **A forbid is per object and per relation.** Blocking Alice on readme does not touch other documents. Blocking a folder relation hides everything inherited through that folder, but a direct grant on a document below it still applies.
- **It needs the single-branch shape.** The two-arm policy's folder arm never looks at the document node, so a document-level `blocked` tuple does not hide the document from someone who sees it through the folder arm. With the projection policy Alice, blocked on readme, still sees it. Use the single branch for tables that need per-document forbids.
- **Not an attribute rule.** "Deny if `status = 'archived'`" is RLS composition ([3.7](#37-conditions-through-rls-composition)).

### 3.7 Conditions through RLS composition

The engine has no condition evaluator. Expiry is `expires_at` ([3.3](#33-expiry)). Rules over your own columns go in the policy, where Postgres filters them for free. Example: viewers see only published documents, editors (and so admins) also see drafts:

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

Each `list_objects` is a once-per-query subplan, so the policy costs two walks per query, not one per row. With the projection shape, put the status test in front of both viewer arms in the same way.

**The engine and the policy can disagree.** The engine does not know about `status`, so outside RLS:

```sql
select permissions.check_for('user', :'carol', 'document', :'draft_doc', 'viewer');   -- true, although RLS hides it
select :'carol' = any (array(select subject_id from permissions.list_subjects('document', :'draft_doc', 'viewer')));   -- true: list_subjects over-reports
```

Any app code that decides access with `check` instead of querying the table must repeat the status rule.

### 3.8 Graduating from the `rbac` preset

The [`rbac` preset](./README.md#the-rbac-preset) writes ordinary tuples on two built-in types, `app` and `tenant`. On this engine, graduating to per-object sharing means defining a type, granting on it, and adding **one `or` branch** to the policy; the role data is untouched.

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

To let the scoped roles reach the org's objects through the model instead of through an `org_id` arm, give the type a `parent` relation and inherit the role permission from the `tenant` object that holds the scoped roles:

```sql
select permissions.define_relation('note', 'parent');
select permissions.define_relation('note', 'viewer', '{editor}', from_parent => '{documents.read}');
select permissions.set_parent('note', :'note_acme', 'tenant', :'acme');

select permissions.check_for('user', :'bob', 'note', :'note_acme', 'viewer');    -- true: Bob is an editor of acme
select permissions.check_for('user', :'dave', 'note', :'note_acme', 'viewer');   -- false: Dave holds no role
```

The benchmark's parents seed does exactly this. The same cost trade-off as in [3.4](#34-parent-inheritance) applies.

### 3.9 Listing and debugging

**As the current user (clients may call these):**

```sql
-- as Dave
select permissions.list_objects('document', 'viewer');          -- {<readme's id>}
select permissions.check('document', :'acme_readme', 'viewer');  -- true
```

**As an admin, for any subject** (clients get `42501`; these would let any user read others' access):

```sql
select permissions.list_objects_for('user', :'dave', 'document', 'viewer');                -- {<readme's id>}
select permissions.check_for('user', :'dave', 'document', :'acme_readme', 'viewer');       -- true
select * from permissions.list_subjects('document', :'acme_readme', 'viewer');             -- the people who can view it
```

Things to know when debugging:

- **A mistyped relation or type is `false`, not an error.** `check_for('user', :'dave', 'document', :'acme_readme', 'vewer')` returns `false`. When an answer is wrong, check the names first.
- **`list_subjects` returns people, not the teams they came through.** The rows are the leaf subjects (`user` ids, plus `('user', '*')` for public). It follows usersets, `implied_by` and parents backwards. Subjects that hold a forbid tuple are re-checked forwards, so blocked users are left out.
- **`list_objects_for` and `list_subjects` return unordered results.** Compare as sets.
- **The tuples are the explanation.** There is no separate state to inspect. As the owner:

  ```sql
  select * from permissions.tuples where object_type = 'document' and object_id = :'acme_readme';
  -- 3 rows here: editor@bob, viewer@team:eng#member, parent@folder:specs
  select * from permissions.tuples where subject_type = 'user' and subject_id = :'dave';
  -- 2 rows: his team membership and the note shared with him
  ```

  Then follow the walk by hand from [section 1](#1-mental-model): which tuple has him as subject, which node does it reach, which tuple has that node as subject.
- **Reproduce a user's view of a table** in one transaction:

  ```sql
  begin;
  set local role authenticated;
  select set_config('permissions.subject_id', :'dave', true);
  select title from public.documents;      -- readme
  rollback;
  ```

  Add `explain` to see the policy: each `list_objects` shows as an `InitPlan` that runs once per query, a `check` as a filter on each row.

### 3.10 Cleaning up when users or objects are deleted

There are no foreign keys between your tables and the tuples (ids are text), so deleting a user or a document does not delete its tuples. Orphans are harmless (nothing can reach a deleted id, though a **reused** id would inherit them), but they accumulate. Clean up from a trigger. `delete_subject(type, id)` removes every tuple that mentions the entity, as the subject **and** as the object, so it is the one call that works for users, teams, folders and documents:

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

On Supabase, put the `user` trigger on `auth.users` instead of `app_users`. The function is `security definer` and pinned to an empty `search_path`, so it runs with the owner's rights; nothing else may call it, because a trigger function cannot be called directly.

```sql
delete from public.app_users where id = :'dave';
-- Dave's tuples are gone, and so is his access:
select permissions.list_objects_for('user', :'dave', 'document', 'viewer');    -- {}

delete from public.documents where id = :'acme_readme';
-- every tuple on readme (grants, parent link) is gone
```

Use `delete_subject` for folders, not `delete_object`. `delete_object(type, id)` removes only the tuples **on** the object, and a folder is also the **subject** of its children's `parent` tuples:

```sql
select permissions.delete_object('folder', :'plans');    -- 1: the folder's own parent link
select count(*) from permissions.tuples where subject_type = 'folder' and subject_id = :'plans';   -- 2: the documents' links, still there
delete from public.folders where id = :'plans';          -- the trigger calls delete_subject
select count(*) from permissions.tuples where subject_type = 'folder' and subject_id = :'plans';   -- 0
select permissions.delete_subject('user', 'nobody');     -- 0: both functions return the number of tuples removed
```

## 4. API reference

Everything is in the `permissions` schema. **Client** means executable by any role (`anon`, `authenticated`): it only ever answers about the current subject. **Admin** means the owner and any role you grant execute to (typically `service_role`): see [roles and privileges](./README.md#roles-and-privileges) for the grant. Calling an admin function as a client raises `42501`. All write functions are `security definer`, pinned to `search_path = ''`.

There are 24 public functions (names without a leading underscore) and 4 internal ones (`_reach`, `_unfolded_null`, `_scope_object`, `_add_implied_by`). The shape `argument default` below means the argument is optional.

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

Admin. Declares an object type (`user`, `team`, ...). Idempotent: calling it again keeps the existing description unless you pass a new one. `user` is predefined, as are `app` and `tenant` (used by the `rbac` preset).

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

Admin. Declares a relation on a type, or **replaces** all three lists of an existing one (it is an upsert: omit a list and it becomes empty). Note the parameter names have no `p_` prefix, so you can write `from_parent => '{viewer}'`.

- `implied_by`: relations on the same object that imply this one.
- `from_parent`: relations on the object's parent (any type, looked up by name) that imply this one.
- `unless`: relations on the same object that exclude this one for a subject holding them directly.

Errors: `23503` if `object_type` is not defined (foreign key). The names inside the three lists are **not** checked: a typo is accepted and gives no access.

```sql
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}', unless => '{blocked}');
select permissions.define_relation('gadget', 'viewer');   -- ERROR 23503: type 'gadget' is not defined
```

### Writing tuples

#### `grant`

```sql
permissions.grant(p_object_type text, p_object_id text, p_relation text,
                  p_subject_type text, p_subject_id text,
                  p_subject_relation text default '',
                  p_expires_at timestamptz default null) returns void
```

Admin. Writes the tuple `object_type:object_id#relation@subject_type:subject_id[#subject_relation]`. It is an **upsert**: if the tuple exists, only `expires_at` is updated, and omitting `p_expires_at` makes it permanent. Pass `p_subject_relation` for a userset (`'member'` for `team:eng#member`); use `p_subject_id => '*'` for public access.

Errors:

| SQLSTATE | When |
| --- | --- |
| `23503` | `(object_type, relation)` is not defined (foreign key to `relations`) |
| `22023` | `p_subject_relation` is not a defined relation of `p_subject_type` |
| `22023` | a wildcard (`'*'`) subject with a subject relation (`team:*#member`) |
| `22023` | a userset or wildcard subject on the relation `parent`, or on any relation listed in some `unless` |
| `42501` | called by a client |

The subject type is not validated: `grant(..., 'ghost', 'g1')` succeeds for a type you never defined, so a typo in the subject type is silent.

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

Admin. Deletes exactly that tuple and returns `true` if there was one. The subject relation is part of the tuple's identity: revoking `team:eng` does not remove `team:eng#member`. Unknown relations simply return `false`.

```sql
select permissions.revoke('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');   -- true
select permissions.revoke('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');   -- false
```

#### `set_parent`

```sql
permissions.set_parent(p_object_type text, p_object_id text,
                       p_parent_type text, p_parent_id text) returns void
```

Admin. Writes the tuple `object#parent@parent_type:parent_id`, **replacing** any existing parent of that object. A null `p_parent_id` clears the parent. Needs the relation `parent` defined on `p_object_type`. Errors are `grant`'s: `23503` if `parent` is not defined on the type, `22023` for a `*` parent. To give an object several parents, use `grant(..., 'parent', ...)` directly.

```sql
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');
select permissions.set_parent('document', :'acme_readme', null, null);   -- clear
```

#### `sync_parent`

```sql
permissions.sync_parent() returns trigger
-- trigger arguments: object_type, parent_type, parent_column [, id_column default 'id']
```

A trigger function (`after insert or update of <parent_column> or delete`, `for each row`) that keeps the parent tuple in step with a column of your table. It reads both rows with `to_jsonb`, does nothing when neither the id nor the parent column changed, clears the parent when the row is deleted or its id changes, and otherwise calls `set_parent`. Execute is revoked from public, and Postgres checks that when the trigger is created, so only the owner can attach it, while client inserts and updates still fire it. It does not backfill existing rows and does not remove other tuples on a deleted row (see [3.10](#310-cleaning-up-when-users-or-objects-are-deleted)). `set_parent`'s errors apply (a missing `parent` relation raises `23503` the first time a row sets a parent).

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

Admin. Deletes every tuple where the entity is the subject **or** the object, and returns how many. This is the cleanup call for users, teams, folders and documents.

```sql
select permissions.delete_subject('user', :'dave');
```

#### `delete_object`

```sql
permissions.delete_object(p_object_type text, p_object_id text) returns bigint
```

Admin. Deletes the tuples **on** the object (where it is the object) and returns how many. It leaves tuples that name the object as a subject, such as the `parent` links of a folder's children; use `delete_subject` for those.

```sql
select permissions.delete_object('document', :'acme_readme');
```

### Checks for the current subject

The subject is the JWT `sub`, or else the `permissions.subject_id` setting; the type is `user` unless `permissions.subject_type` says otherwise. With no subject, `check` is `false` and `list_objects` is `{}`.

#### `check`

```sql
permissions.check(p_object_type text, p_object_id text, p_relation text) returns boolean
```

Client, `stable`. Whether the current subject holds the relation on the object. Per-row, for write policies. Unknown names give `false`. Always write it qualified: `check` is a reserved word, and a bare `check(...)` is a syntax error ([6](#6-gotchas-and-limits)).

```sql
create policy documents_update on public.documents for update to authenticated
    using (permissions.check('document', id::text, 'editor'));
```

#### `list_objects`

```sql
permissions.list_objects(p_object_type text, p_relation text,
                         p_unfold boolean default permissions._unfolded_null()) returns text[]
```

Client, `stable`. The ids of every object of that type on which the current subject holds the relation, as an **unordered** `text[]`. The fast path for `select` policies:

```sql
id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
```

**Do not pass the third argument.** `p_unfold` is ignored; it exists so that the call is not a constant to the planner. For a `stable` function whose arguments are all constants, Postgres evaluates the call while planning (to estimate the `unnest`'s row count), and then again when the query runs, so every query paid for two walks. The default expression is a volatile function that returns null, which stops that without making the function volatile (a volatile function would read grants from a later snapshot than the rows being filtered). If you pass a constant yourself (`list_objects('document', 'viewer', true)`), the call is folded again. Measured on medium wide: planning 11.7-12.8 ms and 3,564 buffers before, 0.22 ms and 112 buffers after. `list_objects_for` and `scopes_with_permission` have the same argument.

#### `current_subject_id`

```sql
permissions.current_subject_id() returns text
```

Client, `stable`. The JWT `sub` claim (`request.jwt.claims`) if present, else the `permissions.subject_id` setting, else null. The JWT wins, so nothing else in a session can override the subject of a request that carries one. See [identity](./README.md#identity).

```sql
select set_config('permissions.subject_id', :'alice', false);
select permissions.current_subject_id();      -- alice's id
```

#### `current_subject_type`

```sql
permissions.current_subject_type() returns text
```

Client, `stable`. The `permissions.subject_type` setting, or `'user'` when it is unset or empty. Set it for non-user principals such as a service.

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

Admin, `stable`. Like `check` for any subject. Searches from both ends and stops when they meet, so it stays cheap when the subject has a large reach. A null subject id gives `false`. Honours expiry, `user:*`, parents and `unless`. Does not know about conditions you wrote in RLS.

```sql
select permissions.check_for('user', :'bob', 'document', :'acme_readme', 'editor');   -- true
```

#### `list_objects_for`

```sql
permissions.list_objects_for(p_subject_type text, p_subject_id text,
                             p_object_type text, p_relation text,
                             p_unfold boolean default permissions._unfolded_null()) returns text[]
```

Admin, `stable`. `list_objects` for any subject; unordered. Do not pass `p_unfold`.

```sql
select permissions.list_objects_for('user', :'dave', 'document', 'viewer');
```

#### `list_subjects`

```sql
permissions.list_subjects(p_object_type text, p_object_id text, p_relation text)
    returns table (subject_type text, subject_id text)
```

Admin, `stable`. Who holds the relation on the object, walking backwards through usersets, `implied_by` and parents. Returns the leaf subjects (users, or whatever type the direct tuples name), not the groups. Public access appears as `('user', '*')`. Subjects that hold an `unless` tuple are re-checked forwards, so blocked subjects are left out. It does not apply RLS-level conditions, so it over-reports for them.

```sql
select * from permissions.list_subjects('document', :'acme_readme', 'viewer');
```

### The `rbac` preset functions

The nine functions below are the `rbac` preset, identical on every engine. They are documented in the [shared guide](./README.md#the-rbac-preset); this table is here so the list is complete, with what is specific to this engine. On A the preset is thin wrappers over the same tuples (roles become relations on `app` and `tenant`, assignments are tuples).

| Function | Who | Returns |
| --- | --- | --- |
| `create_role(p_role text, p_permissions text[], p_inherits text[] default '{}')` | admin | `void`. `23505` if the role exists, `22023` for overlapping names or an unknown inherited role |
| `drop_role(p_role text)` | admin | `void`. `22023` unknown role, `2BP01` while another role inherits it |
| `assign_role(p_user_id text, p_role text, p_scope text default null)` | admin | `void`. `22023` unknown role |
| `unassign_role(p_user_id text, p_role text, p_scope text default null)` | admin | `void` |
| `has_permission(p_permission text, p_scope text default null)` | client | `boolean` |
| `has_role(p_role text, p_scope text default null)` | client | `boolean` |
| `scopes_with_permission(p_permission text, p_unfold boolean default permissions._unfolded_null())` | client | `text[]`; do not pass `p_unfold` |
| `user_permissions(p_user_id text, p_scope text default null)` | admin | `text[]` |
| `users_with_role(p_role text, p_scope text default null)` | admin | `setof text` |

### Tables

All in the `permissions` schema. **Clients have no privileges on any of them**, and `anon` neither: they cannot read, insert, update or delete. They read and write only through the functions. As the owner you can query them to debug ([3.9](#39-listing-and-debugging)) and purge expired rows ([3.3](#33-expiry)).

| Table | Holds |
| --- | --- |
| `object_types (name, description)` | the types from `define_type` |
| `relations (object_type, relation, implied_by[], from_parent[], unless[], description)` | the model from `define_relation`; deleting a type or relation cascades to its tuples |
| `tuples (id, object_type, object_id, relation, subject_type, subject_id, subject_relation, condition, expires_at, created_at)` | one row per fact; unique on the first six columns; `subject_relation = ''` for a direct subject. `condition` is unused: a tuple with a non-null condition is ignored, and no function writes one |
| `entities (entity_type, entity_id, attributes)` | unused in this version |
| `rbac_roles (role, permissions[], inherits[])` | what `create_role` declared |

The type, relation and id columns use `collate "C"`, so array results come back in no meaningful order.

## 5. Performance notes

Measured in Docker on Postgres 18.6, one laptop, 4 pgbench clients, p50, every query through RLS as `authenticated`, after the session 3 optimizations. Source: [OPTIMIZATIONS.md](../bench/baselines/OPTIMIZATIONS.md) (the same matrix on 16 and 17 is in it). "Large" is 1M documents, 10k users, 500 teams; "deep" is teams nested 9 levels; "wide" is 50 teams per user and 50 shares per team (medium, 100k documents).

### What is cheap

| Operation | p50 |
| --- | --- |
| One `grant` (`write_share`) | 0.15 ms |
| Nest a team of 1,000 members inside another (`write_nest_team`), one tuple | 0.15 ms (large, deep and wide) |
| `check` through a nested team (`nest_check`) | 0.31 ms large, 0.34 deep, 0.37 wide |
| `has_permission` (`rbac_check`) | 0.30 ms |
| A page of 50 rows under a sharing policy (`share_select_page`) | 1.03 ms large, 0.76 deep |
| `list_objects` for a user (`share_list_objects`) | 0.29 ms large, 0.31 deep |
| Projection policy, page / count (`parents_proj_*`) | 1.33 / 8.42 ms large |

Checks and writes stay cheap whatever the graph looks like. A check searches from both ends and does not walk everything the subject can reach: in the design notes (local Postgres 16, one client), a large user's `has_permission` took about 0.13 ms with the search against 25 ms as an `exists` over the full walk. Writes are single rows with no locks (one `grant` sustains about 23.6k per second with 4 clients). The 8 ms count is a floor shared by all three engines: current Postgres minor releases read every heap page of that count.

### What is expensive

- **The single-branch parents policy is O(visible documents).** 45.6 ms for a page and 75.1 ms for a count at large, where a user sees about 20k documents; 7.41 / 6.40 ms at medium deep; 14.7 / 13.3 at medium wide. A is the only engine over the single-branch budgets. Use the two-arm projection ([3.4](#34-parent-inheritance)): 1.33 / 8.42 ms on the same data.
- **Wide groups.** `list_objects` costs time linear in the nodes the user reaches, about 0.6 to 1 microsecond each (design notes: 4 ms for a 6,795-node walk, 15-20 ms for 20,038). At medium wide, where a user is in 50 teams with 50 shares each and reaches several thousand documents, `share_select_page` takes **14.4 ms** against 1.03 ms at large default, and `share_list_objects` 4.44 ms. Two things add up there: `scopes_with_permission` and `list_objects` each walk the user's whole graph, and `id = any($1)` over an array of thousands of ids is checked linearly for each candidate row. If you can, grant at a coarser level (an org or a team, not each document), which shrinks the reach.
- **Deep nesting is fine; width is the problem.** Deep (9 levels) costs 0.76 ms for the sharing page, close to default.
- **Storage with parent links.** One tuple per child: at large, the `permissions` tables grow from 19.6 MB to 404 MB (about 385 bytes per document, indexes included) and the seed of 1M links takes about 31 s. The partial index `tuples_edge_kinds_idx` that lets the walk skip leaves is 6.8 MB at large.
- **Planning.** The walk is pinned to generic plans. They are right for these index-nested-loop shapes and immune to statistics shifts, but the engine will never switch to a hash join for a huge frontier. The dummy `p_unfold` argument ([`list_objects`](#list_objects)) is what keeps the walk from running twice.

Where A loses to the other engines (from [DECISION.md](../DECISION.md)): the single-branch policy (45.6 ms vs 13.7 for B and 4.94 for C at large), wide reads (14.4 ms vs 17.8 for B and 8.20 for C), and storage at large (404 MB vs 378 and 182). Where it wins: nesting and membership writes (0.15 ms, no locks), medium wide storage (97 MB vs 105 and 192), and no drift.

## 6. Gotchas and limits

**Names**

- **`check` must be schema-qualified.** `check` is a reserved word. `permissions.check(...)` works; with `permissions` on your `search_path`, a bare `check(...)` is a syntax error (`42601`).
- **`parent` is a reserved relation name.** Parent links are tuples with the relation `parent`, and it has to be defined (`define_relation('document', 'parent')`) on every type that has a parent, or the link fails with `23503`.
- **A typo in `from_parent` (or `implied_by`, `unless`) silently gives no access.** The names are matched, not validated: there is no check that the parent type has the relation you named. Test the model with `check_for` after you define it.
- **`define_relation` replaces all three lists.** Redefining `viewer` without `from_parent` removes the inheritance. Repeat every list each time.
- **A mistyped relation or type in a check is `false`.** The same goes for a subject type in `grant`: it is not validated.

**Identity and ids**

- **Ids are text and compared as text.** Pass the canonical lower-case uuid text (`id::text` gives it). `AAAA...` and `aaaa...` are different ids to the engine, although both cast to the same `uuid`.
- **A stored id that is not a uuid breaks the policy.** The policy casts `list_objects` to `uuid[]`, and one id in the array that is not a valid uuid (say a tuple written for `document:not-a-uuid`) fails the whole query for that user with `22P02`. Validate ids when you grant, and clean up bad tuples with `delete_object`.
- **`list_objects` and `list_subjects` are unordered.** Compare as sets.
- **Do not pass the `p_unfold` argument** of `list_objects`, `list_objects_for` and `scopes_with_permission`: a constant brings back plan-time evaluation (two walks per query).
- **`permissions.subject_id` is a plain setting.** Any session that can run `set_config` can change it, so on plain Postgres the connection that sets it must be trusted; on Supabase the JWT wins. A JWT whose `sub` is literally `*` is the public wildcard subject: it gets only what everyone gets, but apps should never issue it. See [identity](./README.md#identity); the shared guide also says to set the subject per transaction.
- **No subject means no access.** Anonymous requests are denied everything, including `user:*` documents.

**Writes**

- **`grant` is an upsert and `revoke` is exact.** Granting again resets the expiry (to none, if you omit it). Revoking a userset needs its `subject_relation`.
- **Expired tuples are not deleted.** They stop counting, and stay until you purge them.
- **No foreign keys to your tables.** Deleting a user, document or folder leaves its tuples unless you clean up ([3.10](#310-cleaning-up-when-users-or-objects-are-deleted)). A reused id inherits the old grants.
- **Parent links duplicate a column of yours.** `sync_parent` copies it mechanically, does not backfill, and ignores an update that leaves the column unchanged. Move-by-update by clients can grant access to a folder's viewers: restrict the column or add a `with check`.
- **`set_parent` is single-parent, raw `grant(..., 'parent', ...)` is not.** `grant` allows several parents, and you can build a cycle (it terminates).
- **Usersets and wildcards cannot be parents.** `grant` raises `22023`.
- **`delete_object` on a folder leaves its children's links.** Use `delete_subject`.

**Forbid and conditions**

- **Forbid is direct subjects only and opt-in per relation** ([3.6](#36-forbid-and-unless)). A group cannot be blocked, and a relation without `unless` ignores `blocked` tuples. A userset forbid written before the `unless` list existed is ignored, not rejected.
- **Document-level forbid needs the single-branch policy.** The two-arm projection does not consult the document node.
- **Conditions are RLS composition**, so the engine and the policy can disagree: `check_for` is `true` for a draft that RLS hides, and `list_subjects` over-reports. Any server-side check outside RLS must repeat the status rule. A tuple with a non-null `condition` is ignored.

**Reads**

- **Cost grows with what a subject reaches.** Wide and deep graphs make `list_objects` walk more rows; checks escape this ([5](#5-performance-notes)).
- **`list_subjects` returns people, not groups**, and includes `('user', '*')` for public documents.
- **Weak validation.** Nothing stops granting `document#viewer` to a subject type that makes no sense; the model has no type restrictions on who may hold a relation.
