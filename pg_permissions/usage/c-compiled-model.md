# Engine C: compiled model

This page is for an app developer who has picked engine C. It shows how to use it and lists every public function. Install, identity (JWT `sub`, `permissions.subject_id`), the client and admin privilege split, the `rbac` preset reference and the general RLS rules are in the shared guide, [README.md](./README.md). They are not repeated here.

Every example with an observable result is also a test: [`test/spec/c/90_usage_examples.sql`](../test/spec/c/90_usage_examples.sql) mirrors this page section by section (the comments carry the section numbers) and runs against the prototype with `./test/run.sh 90 --impl prototypes/c-compiled-model.sql`. Design background is in [`designs/c-compiled-model.md`](../designs/c-compiled-model.md); the comparison with the other engines is in [`DECISION.md`](../DECISION.md).

Contents

1. [Mental model](#1-mental-model)
2. [Quick start](#2-quick-start)
3. [How-to guides](#3-how-to-guides)
4. [API reference](#4-api-reference)
5. [Performance notes](#5-performance-notes)
6. [Gotchas and limits](#6-gotchas-and-limits)

## 1. Mental model

You write down your authorization model once, as JSON, and give it to `permissions.apply_model()`. The model declares **types** (`org`, `team`, `document`), the **relations** each type can have (`document.editor`), who may hold a relation (a user, every user, or a group such as `team#member`), which relations **imply** others (`editor` implies `viewer`), and the named **permissions** your policies check (`document.edit`), including exclusions (`but_not`) and inheritance from a **parent** (`parent->view`).

`apply_model()` compiles the model into lookup tables. After that:

- A **grant** is a row: this object, this relation, this subject. Subjects and objects are typed `uuid` ids. You grant relations (`editor`), never permissions (`edit`).
- **Group membership is precomputed.** When you add a user to a team, or nest a team in another team, triggers write one membership row per affected user and group. When you move a folder, the closure of its sub-folders is rewritten. Documents never get closure rows.
- A **check** (`can`) or a **list** (`accessible`) is then a fixed number of index lookups. There is no recursion at read time.

What that means for you:

| You get | You pay |
| --- | --- |
| Fast reads that barely change with group depth or how many groups a user is in. `accessible()` returns a `uuid[]` that RLS can use as an index condition. | Writes that change group membership or move a folder take **one global advisory lock** and write rows for every affected user. Nesting a 1,000-member team takes about 58 ms with 4 clients queued on the lock. Plain object grants take no lock and cost about 0.2 ms. |
| Typed validation. Unknown types, relations and subjects raise when you write. | `repeatable read` is **refused** for the writes that take the lock (`0A000`). ORMs that default to it need a different isolation level for permission writes (3.10). |
| One place to read the whole model (`permissions.model()`). | The derived tables can **drift** from the grants if something bypasses the triggers. `verify()` finds drift and `rebuild()` repairs it (3.10). |
| Cycles in group nesting and in parent links are handled. | Nesting and parent chains are limited to **10 levels** (`54001`). Parent cycles are **rejected** on write (`23514`); group cycles are accepted and harmless. |
| Native `uuid` everywhere, no casts in policies. | **IDs are uuid only.** Apps with `bigint` or `text` keys need a mapping (3.13). |

Group memberships that expire are not supported (`0A000`), and a model change that touches groups rebuilds all memberships under the lock (3.1).

## 2. Quick start

The reference scenario from PLAN.md section 5: org `acme`, Alice is an admin and Carol a member, so admins can edit and members can view every acme document. Bob, who is not in the org, is an editor of the `readme` document. Team `eng` (Carol and Dave) are viewers of `readme`. `editor` implies `viewer`.

The ids are psql variables so the examples read well. Any uuid works; in application code, bind parameters instead. These are the ids the tests use.

```sql
\set alice        '00000000-0000-0000-0001-000000000001'
\set bob          '00000000-0000-0000-0001-000000000002'
\set carol        '00000000-0000-0000-0001-000000000003'
\set dave         '00000000-0000-0000-0001-000000000004'
\set erin         '00000000-0000-0000-0001-000000000005'
\set frank        '00000000-0000-0000-0001-000000000006'
\set acme         '00000000-0000-0000-0002-000000000001'
\set globex       '00000000-0000-0000-0002-000000000002'
\set acme_plan    '00000000-0000-0000-0003-000000000001'
\set acme_readme  '00000000-0000-0000-0003-000000000002'
\set globex_notes '00000000-0000-0000-0003-000000000003'
\set announcement '00000000-0000-0000-0003-000000000005'
\set eng          '00000000-0000-0000-0004-000000000001'
\set platform     '00000000-0000-0000-0004-000000000002'
\set specs        '00000000-0000-0000-0005-000000000001'
\set plans        '00000000-0000-0000-0005-000000000002'
```

### Step 1: declare the model

Keep it in a file in your repository, for example `model.json`. It is the source of truth; the database keeps a history of what was applied.

```json
{
  "types": {
    "user": { "principal": true },
    "team": { "relations": { "member": ["user", "team#member"] } },
    "org": {
      "relations":   { "admin": ["user"], "member": ["user"] },
      "implies":     { "admin": ["member"] },
      "permissions": { "edit_documents": ["admin"], "view_documents": ["member"] }
    },
    "document": {
      "relations":   { "editor": ["user", "team#member"], "viewer": ["user", "team#member"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "view": ["viewer"], "edit": ["editor"] }
    }
  }
}
```

Read it as: a team has members, and a member is a user or another team's members (nesting). An org has admins and members, and an admin counts as a member. A document has editors and viewers, each a user or all members of a team, and an editor counts as a viewer. `view` and `edit` are the names your policies will use.

### Step 2: dry run, then apply

```sql
\set model `cat model.json`

select * from permissions.apply_model(:'model', p_dry_run => true);
--        change        |               detail
-- ---------------------+-------------------------------------
--  add type            | org
--  add type            | team
--  add type            | document
--  add permission      | document.edit
--  add relation        | document.editor
--  ...
--  rebuild memberships | usersets or what feeds them changed
--  dry run             | nothing was changed

select * from permissions.apply_model(:'model');   -- same plan, last row is: version | 3
select * from permissions.apply_model(:'model');   -- unchanged | version 3
```

A dry run runs the whole compile inside a subtransaction and rolls it back, so validation errors show up in it too. The version number you get depends on how many dry runs came before (3.1).

### Step 3: the table and its policies

```sql
create table public.documents (id uuid primary key, org_id uuid not null, title text not null);
insert into public.documents values
    (:'acme_plan',    :'acme',   'acme plan'),
    (:'acme_readme',  :'acme',   'acme readme'),
    (:'globex_notes', :'globex', 'globex notes');

alter table public.documents enable row level security;
grant select, update on public.documents to authenticated;

create policy documents_select on public.documents for select to authenticated using (
    org_id = any ((select permissions.accessible('org', 'view_documents'))::uuid[])
    or id  = any ((select permissions.accessible('document', 'view'))::uuid[])
);
create policy documents_update on public.documents for update to authenticated using (
    org_id = any ((select permissions.accessible('org', 'edit_documents'))::uuid[])
    or permissions.can('document', id, 'edit')
);
```

`accessible(type, permission)` returns every id of that type the current user holds the permission on, as a `uuid[]`. The `(select ...)::uuid[]` wrapper makes Postgres evaluate it once per query and use the array as an index condition. The `::uuid[]` cast does nothing here (the function already returns `uuid[]`); it is only what tells the parser to treat the subquery as an array, so keep it. The first arm says "documents of orgs where I can view documents", the second "documents shared with me". Single-row writes use the per-row `can()`.

### Step 4: grants

Run these as the table owner or another admin role (clients cannot call `grant`).

```sql
select permissions.grant('org',      :'acme',        'admin',  'user', :'alice');
select permissions.grant('org',      :'acme',        'member', 'user', :'carol');
select permissions.grant('team',     :'eng',         'member', 'user', :'carol');
select permissions.grant('team',     :'eng',         'member', 'user', :'dave');
select permissions.grant('document', :'acme_readme', 'editor', 'user', :'bob');
select permissions.grant('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');
```

The last call grants `viewer` to the userset `team:eng#member`, which is why `grant` has a sixth argument for the subject's relation. The result is 6 grants and 2 membership rows (Carol and Dave in `team:eng#member`). Org roles are not groups in this model, so they need no membership rows.

### Step 5: the three questions

**Can Bob update readme?**

```sql
select permissions.can_for('user', :'bob', 'document', :'acme_readme', 'edit');   -- true
select permissions.can_for('user', :'bob', 'document', :'acme_plan',   'edit');   -- false
```

Through RLS, as Bob (this is what PostgREST does for you from the JWT; the second line is the fallback for plain Postgres, see the shared guide):

```sql
set role authenticated;
select set_config('permissions.subject_id', :'bob', false);
update public.documents set title = 'readme v2' where id = :'acme_readme';   -- UPDATE 1
update public.documents set title = 'x'         where id = :'acme_plan';     -- UPDATE 0
reset role;
```

**Which documents can Dave see?**

```sql
set role authenticated;
select set_config('permissions.subject_id', :'dave', false);
select title from public.documents;      -- acme readme
reset role;

select permissions.accessible_for('user', :'dave', 'document', 'view');   -- {...readme id...}
```

As Alice or Carol the same query returns both acme documents, through the org arm of the policy. Bob and Dave see only `readme`. Erin, who has no grants, sees nothing.

**Who can view readme?**

```sql
select * from permissions.who_can('document', :'acme_readme', 'view');   -- Bob, Carol, Dave
```

Alice is not in that list. She sees `readme` through the `org_id` arm of the policy, which the engine cannot see. If you want `who_can` to include everyone who inherits access from the org, give the engine the org link with a parent (3.5). That also lets you drop the hand-written arm.

## 3. How-to guides

Each recipe starts from a small complete model so that it runs on its own. `apply_model()` **replaces** your model with the one you pass (apart from the preset types `app` and `tenant`), so merge the parts you need into your own `model.json`.

The recipes assume the ids from section 2. Client-side checks use the pattern from step 5.

### 3.1 Evolve the model safely

Treat `model.json` like a migration. Before applying a change:

**Dry run.** `p_dry_run => true` returns the plan and changes nothing, including no new row in `permissions.models`. It reports validation errors the same way a real run would.

```sql
select * from permissions.apply_model(:'model', p_dry_run => true);
```

The plan has one row per change: `add type`, `add relation`, `add permission`, `remove relation`, `remove type`, `rebuild memberships`, `rebuild ancestors`, `delete tuples`, `delete parent links`, then `version` (or `dry run`). A dry run reports a rebuild but does not perform it.

**Know what is cheap.** Adding a type, relation or permission, or changing a permission's items, only writes catalog rows. Two kinds of change trigger a rebuild, both under the global lock, in the same transaction:

| Change | Plan row | Cost |
| --- | --- | --- |
| A relation starts being used as a group (`org#member` appears in some relation's subject list), an `implies` link changes what feeds a group, or a principal type changes | `rebuild memberships` | Recomputes every membership row. |
| A `parent` list changes | `rebuild ancestors` | Recomputes the ancestor closure of every container. |

```sql
-- shows 'rebuild memberships' but does not run it
select * from permissions.apply_model(
    jsonb_set(:'model'::jsonb, '{types,document,relations,viewer}', '["user", "team#member", "org#member"]'),
    p_dry_run => true);

-- shows 'rebuild ancestors'
select * from permissions.apply_model(
    jsonb_set(:'model'::jsonb, '{types,document,parent}', '["org"]'), p_dry_run => true);
```

At millions of membership rows a rebuild is a maintenance window. Do it at a quiet time.

**Removing things needs `force`.** If a model change drops a type or relation that has grants, or narrows who may hold a relation so that existing grants no longer fit, `apply_model()` raises `2BP01` and tells you how many rows it would delete:

```sql
-- the active model has document.commenter with one grant; :'model' does not have the relation
select * from permissions.apply_model(:'model');
-- ERROR:  removing document.commenter would delete 1 tuples; pass force => true

select * from permissions.apply_model(:'model', p_force => true);   -- deletes the grant, then the relation
```

Take the count in that error message as your signal. The dry-run plan is not a reliable list of removals: in the prototype it drops the `remove ...` rows unless the same change also adds a type (see 6). A dry run never raises `2BP01`, so a clean dry run does not mean the real run will pass without `force`.

**Renames are drop and add.** There are no rename hints, so renaming a relation deletes its grants (with `force`). Add the new relation, re-create the grants from your own data with `grant_many` (3.9), then remove the old one.

**Versions.** Every applied change is a row in `permissions.models` (owner only). Dry runs consume version numbers, so the sequence has gaps. `permissions.model()` returns the active definition including the preset's `app` and `tenant` types. `apply_model()` refuses a definition that contains those, so strip them to roll back to an older version:

```sql
select version, applied_at, applied_by from permissions.models order by version;

select a.*
from (select definition as d from permissions.models where version = 3) old,
     lateral permissions.apply_model(jsonb_set(old.d, '{types}', (old.d -> 'types') - 'app' - 'tenant')) a;
```

Re-applying the model that is already active returns one row, `unchanged`. Defining `app` or `tenant` yourself raises `22023`. Naming `tenant` as a `parent` is allowed (3.5).

### 3.2 Share one object

Per-object sharing is a grant of a relation on the object. The subject can be a user or a group (`team#member`).

```sql
select permissions.grant('document', :'acme_plan', 'editor', 'user', :'erin');            -- one user
select permissions.grant('team',     :'eng',       'member', 'user', :'dave');
select permissions.grant('document', :'acme_plan', 'viewer', 'team', :'eng', 'member');   -- a whole team

select * from permissions.who_can('document', :'acme_plan', 'view');                      -- Erin, Dave
select permissions.revoke('document', :'acme_plan', 'editor', 'user', :'erin');           -- true
select permissions.revoke('document', :'acme_plan', 'editor', 'user', :'erin');           -- false, nothing to remove
```

Granting the same thing twice is harmless. Mistakes raise `22023`:

```sql
select permissions.grant('document', :'acme_plan', 'view', 'user', :'erin');
-- ERROR:  document.view is a permission; grant one of the relations that satisfy it
select permissions.grant('document', :'acme_plan', 'owner', 'user', :'erin');
-- ERROR:  unknown relation document.owner
select permissions.grant('document', :'acme_plan', 'viewer', 'org', :'acme');
-- ERROR:  document.viewer does not accept subjects of type org
```

The engine does not know your objects, so a grant on an id that is not in your table is accepted without complaint. Check the id first.

**Letting end users share.** Clients cannot call `grant`. Wrap it in a function that runs as the owner and checks the caller's own access first. `permissions.can()` inside a `security definer` function still sees the caller's identity, because it comes from the JWT or the session setting, not from the current role.

```sql
create function public.share_document(p_doc uuid, p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = '' as $$
begin
    if not permissions.can('document', p_doc, 'edit') then
        raise exception 'you cannot share this document' using errcode = '42501';
    end if;
    if p_role not in ('viewer', 'editor') then
        raise exception 'unknown role %', p_role using errcode = '22023';
    end if;
    perform permissions.grant('document', p_doc, p_role, 'user', p_user);
end $$;
revoke all on function public.share_document(uuid, uuid, text) from public;
grant execute on function public.share_document(uuid, uuid, text) to authenticated;
```

RLS needs no change: the `accessible('document', 'view')` arm picks the new grant up on the next query.

### 3.3 Groups and nested teams

Groups are usersets: the model says a relation accepts `team#member`, and you grant a team's members.

```sql
select permissions.grant('team', :'eng',      'member', 'user', :'dave');
select permissions.grant('team', :'platform', 'member', 'team', :'eng', 'member');        -- eng is nested in platform
select permissions.grant('document', :'acme_plan', 'viewer', 'team', :'platform', 'member');

select permissions.can_for('user', :'dave', 'document', :'acme_plan', 'view');            -- true
select permissions.revoke('team', :'platform', 'member', 'team', :'eng', 'member');       -- un-nest
select permissions.can_for('user', :'dave', 'document', :'acme_plan', 'view');            -- false
```

Adding a member or nesting a team takes the global lock and writes a membership row for each affected user and each group above. Removing a member or un-nesting recomputes the affected users. Policies need no change.

- **Depth.** A chain of 10 levels is accepted. The write that would create an 11th raises `54001` and leaves nothing behind.
- **Cycles.** `eng` in `platform` in `eng` is accepted. Each user keeps the shortest path to every group, nobody outside the cycle gains access, and `verify()` stays clean.
- **Other usersets.** Any relation can be used as a group if you list it, for example sharing with every member of an org. That is a model change (it triggers `rebuild memberships`, 3.1). The implication carries over: an org `admin` implies `member`, so admins are in `org#member`.

```sql
-- document.viewer: ["user", "team#member", "org#member"]
select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'user', :'carol');
select permissions.grant('document', :'acme_plan', 'viewer', 'org', :'acme', 'member');
-- Carol and Alice (admin implies member) can view the plan; Bob cannot
```

### 3.4 Expiring grants

Pass `expires_at` to `grant`. Expired grants give no access in `can`, `accessible` and `who_can`.

```sql
select permissions.grant('document', :'acme_plan', 'viewer', 'user', :'erin', null, now() + interval '7 days');
-- extend, or make permanent by granting again:
select permissions.grant('document', :'acme_plan', 'viewer', 'user', :'erin', null, now() + interval '30 days');
select permissions.grant('document', :'acme_plan', 'viewer', 'user', :'erin');            -- no expiry
```

**Group memberships cannot expire.** A grant of any relation that is used as a group, or that implies one, raises `0A000` if it has an expiry:

```sql
select permissions.grant('team', :'eng', 'member', 'user', :'erin', null, now() + interval '1 day');
-- ERROR:  grants of team.member change group membership and cannot expire
```

The same applies when a model change would make an existing expiring grant feed a group (for example by adding `org#member` to a relation while an expiring `org.member` grant exists): `apply_model()` raises `22023` until you revoke those grants. If you need time-limited team membership, run a job that calls `revoke` when the time comes.

Expired rows stay in `permissions.tuples`, they are just ignored. There is no purge function. As the owner you can delete them directly; it is safe because expiring grants never feed memberships:

```sql
delete from permissions.tuples where expires_at < now();
```

Expiry is judged at `now()`, the transaction start time.

### 3.5 Parent inheritance

A parent link says "this object lives under that one". Permissions that list `parent->P` pass `P` down: whoever has `P` on the parent has `P` here. Chains work (document, folder, folder, org), and each object has at most one parent.

```json
{
  "types": {
    "user": { "principal": true },
    "org": {
      "relations":   { "admin": ["user"], "member": ["user"] },
      "implies":     { "admin": ["member"] },
      "permissions": { "edit": ["admin"], "view": ["member"] }
    },
    "folder": {
      "parent":      ["org", "folder"],
      "relations":   { "editor": ["user"], "viewer": ["user"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "edit": ["editor", "parent->edit"], "view": ["viewer", "parent->view"] }
    },
    "document": {
      "parent":      ["folder", "org"],
      "relations":   { "editor": ["user"], "viewer": ["user"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "edit": ["editor", "parent->edit"], "view": ["viewer", "parent->view"] }
    }
  }
}
```

Set the links, then grant as usual:

```sql
select permissions.set_parent('folder',   :'specs',        'org',    :'acme');
select permissions.set_parent('document', :'acme_readme',  'folder', :'specs');
select permissions.set_parent('document', :'globex_notes', 'org',    :'globex');   -- directly under an org

select permissions.grant('org',    :'acme',   'admin',  'user', :'alice');
select permissions.grant('org',    :'acme',   'member', 'user', :'carol');
select permissions.grant('org',    :'globex', 'member', 'user', :'frank');
select permissions.grant('folder', :'specs',  'viewer', 'user', :'erin');

select permissions.can_for('user', :'alice', 'document', :'acme_readme', 'edit');   -- true, org admin
select permissions.can_for('user', :'carol', 'document', :'acme_readme', 'edit');   -- false
select permissions.can_for('user', :'erin',  'document', :'acme_readme', 'view');   -- true, folder viewer
select * from permissions.who_can('document', :'acme_readme', 'view');              -- Alice, Carol, Erin
```

`who_can` now includes everyone who inherits access.

**Two RLS shapes.** Both give the same rows (the tests compare them), with different costs.

*Single branch.* The engine returns every visible document id. No hand-written arm, and org and folder rules live in the engine. It needs a parent link per document.

```sql
create policy documents_select on public.documents for select to authenticated using (
    id = any ((select permissions.accessible('document', 'view'))::uuid[])
);
```

*Projection.* Shares by id, plus a column of your own that points at the parent. Here the engine only returns a few folder ids.

```sql
create policy documents_select on public.documents for select to authenticated using (
    id        = any ((select permissions.accessible('document', 'viewer'))::uuid[])   -- direct shares
    or folder_id = any ((select permissions.accessible('folder', 'view'))::uuid[])      -- folders I can view
);
```

`accessible('document', 'viewer')` takes a relation, so it returns only documents shared directly (no parent expansion). `accessible('folder', 'view')` includes folders reached through org roles and through parent folders. Documents that sit directly in an org have no folder, so add `or org_id = any ((select permissions.accessible('org', 'view'))::uuid[])` if you have any.

Measured with 1M documents and about 20,000 visible documents per user (PG 18 in Docker, after optimization, 4 clients, p50; [OPTIMIZATIONS.md](../bench/baselines/OPTIMIZATIONS.md)):

| Shape | First page of 50 | `count(*)` |
| --- | --- | --- |
| Single branch | 4.94 ms | 11.9 ms |
| Projection (two arms) | 1.05 ms | 7.88 ms |

The projection is about 4.7 times cheaper for the page. The single branch builds a 20k-element array to return 50 rows, and its count does one index descent per visible id. The count for the projection is the same heap-read floor that every engine hits on current Postgres releases. In the wide shape (50 teams per user, 100k documents) the two are close: 8.06 ms for the single branch against 8.73 ms for the projection. For an admin of an org with 1M documents the single branch returns a 1M-element array on every query, so use the projection for large tenants. The single branch costs one `parents` row per document: 17.6 s to load 1M links and about 160 MB of storage (22 MB to 182 MB).

**Keep the parent link in step with your column.** `set_parent` stores a copy of what your table already says. A trigger keeps them equal. It must run with the owner's privileges because `set_parent` is admin-only.

```sql
create function public.documents_sync_parent() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
    if new.folder_id is not null then
        perform permissions.set_parent('document', new.id, 'folder', new.folder_id);
    else
        perform permissions.set_parent('document', new.id, 'org', new.org_id);
    end if;
    return null;
end $$;
create trigger documents_sync_parent after insert or update of folder_id, org_id on public.documents
    for each row execute function public.documents_sync_parent();
```

Moving a document changes who inherits access straight away, and moving it back restores it.

```sql
select permissions.unset_parent('document', :'acme_readme');   -- true; false if there was no link
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');
```

**Rules and errors.**

- A cycle is rejected: `set_parent('folder', specs, 'folder', plans)` raises `23514` if `plans` is already under `specs`.
- A chain deeper than 10 levels raises `54001`.
- A parent of a type the model does not list in `parent` raises `22023`.
- Moving a **document** (a leaf) is one row, no lock. Moving a **folder** (a type that appears in some `parent` list, a *container*) takes the global lock and rewrites the closure of its sub-folders, so it is refused under `repeatable read` (3.10).
- The all-or-nothing rule: if `document.view` contains `parent->view`, every parent type of `document` must define `view`, and each of those that has a parent must contain `parent->view` too. A model that breaks this raises `22023` when you apply it.

**The preset's `tenant` as a parent.** If you started on the `rbac` preset, objects can inherit the roles assigned on a tenant. Name `tenant` as a parent and use the permission names your roles grant (here `documents.read`; roles as in the shared guide).

```json
{
  "types": {
    "folder": {
      "parent":      ["tenant"],
      "relations":   { "viewer": ["user"] },
      "permissions": { "documents.read": ["viewer", "parent->documents.read"] }
    },
    "document": {
      "parent":      ["folder"],
      "relations":   { "viewer": ["user"] },
      "permissions": { "documents.read": ["viewer", "parent->documents.read"] }
    }
  }
}
```

```sql
select permissions.assign_role(:'alice', 'admin',  :'acme');
select permissions.assign_role(:'bob',   'viewer', :'globex');
select permissions.set_parent('folder',   :'specs',        'tenant', :'acme');
select permissions.set_parent('folder',   :'plans',        'tenant', :'globex');
select permissions.set_parent('document', :'acme_readme',  'folder', :'specs');
select permissions.set_parent('document', :'globex_notes', 'folder', :'plans');

select permissions.can_for('user', :'alice', 'document', :'acme_readme',  'documents.read');   -- true
select permissions.can_for('user', :'alice', 'document', :'globex_notes', 'documents.read');   -- false
select permissions.accessible_for('user', :'bob', 'document', 'documents.read');               -- {globex_notes}
```

`tenant` must define the permission, which it does once a role grants `documents.read`.

### 3.6 Public access

A relation can accept `user:*`, meaning every user. Grant it with `grant_public`, a separate function so that a null id from a failed lookup can never make something public by accident.

```json
{
  "types": {
    "document": {
      "relations":   { "editor": ["user"], "viewer": ["user", "user:*"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "edit": ["editor"], "view": ["viewer"] }
    }
  }
}
```

```sql
select permissions.grant_public('document', :'announcement', 'viewer');
select permissions.can_for('user', :'frank', 'document', :'announcement', 'view');   -- true, Frank has no other grants
select permissions.can_for('user', :'frank', 'document', :'announcement', 'edit');   -- false
select permissions.revoke_public('document', :'announcement', 'viewer');             -- true
```

The policy is the usual `id = any ((select permissions.accessible('document', 'view'))::uuid[])`. Public grants are included.

**Public means every user with a subject, not anonymous callers.** A request with no subject (no JWT `sub`, no `permissions.subject_id`) is denied, public documents included. If you want anonymous reads, add an arm that does not involve the engine, such as `or is_public`.

**`who_can` returns one null row for public access.** It does not list every user.

```sql
select * from permissions.who_can('document', :'announcement', 'view');   -- Bob, and one NULL row
```

Careful with membership tests: `:'frank'::uuid = any (array(select permissions.who_can(...)))` gives `null`, not `true`, for someone who is covered only by the public row. Test for the public row explicitly:

```sql
select exists (select 1 from permissions.who_can('document', :'announcement', 'view') w where w is null);
```

Other things to know:

- `grant('document', id, 'viewer', 'user', null)` raises `22004`. It never means public.
- `grant_public` on a relation that does not list `user:*` raises `22023`.
- `user:*` on a relation that feeds a group (it would make every user a group member) is rejected by `apply_model()` with `22023`.
- `grant_public` and `revoke_public` take an optional last argument, the subject type, which defaults to `user`.
- The null row is not net of per-user forbids. A blocked user disappears from the concrete rows but cannot be listed as an exception to "everyone". A public forbid empties the whole list (3.7).

### 3.7 Forbid with `but_not`

A permission can name relations that **veto** it. The forbid is an ordinary grant of such a relation, so it is admin-only like every grant.

```json
{
  "types": {
    "user": { "principal": true },
    "team": { "relations": { "member": ["user", "team#member"] } },
    "org": {
      "relations":   { "admin": ["user"], "member": ["user"] },
      "implies":     { "admin": ["member"] },
      "permissions": { "edit": ["admin"], "view": ["member"] }
    },
    "folder": {
      "parent":      ["org"],
      "relations":   { "editor": ["user", "team#member"], "viewer": ["user", "team#member"],
                       "blocked": ["user", "team#member"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": {
        "edit": { "any": ["editor", "parent->edit"], "but_not": ["blocked"] },
        "view": { "any": ["viewer", "parent->view"], "but_not": ["blocked"] }
      }
    },
    "document": {
      "parent":      ["folder", "org"],
      "relations":   { "editor": ["user", "team#member"], "viewer": ["user", "team#member"],
                       "blocked": ["user", "team#member"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": {
        "edit": { "any": ["editor", "parent->edit"], "but_not": ["blocked"] },
        "view": { "any": ["viewer", "parent->view"], "but_not": ["blocked"] }
      }
    }
  }
}
```

The policy does not change: `id = any ((select permissions.accessible('document', 'view'))::uuid[])`. Set up the scenario: Alice is an org admin, Carol and Dave are in team `eng`, and team `eng` can view `readme`.

```sql
select permissions.set_parent('folder',   :'specs',       'org',    :'acme');
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');
select permissions.set_parent('document', :'acme_plan',   'org',    :'acme');
select permissions.grant('org',  :'acme', 'admin',  'user', :'alice');
select permissions.grant('team', :'eng',  'member', 'user', :'carol');
select permissions.grant('team', :'eng',  'member', 'user', :'dave');
select permissions.grant('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');
```

Block Dave:

```sql
select permissions.grant('document', :'acme_readme', 'blocked', 'user', :'dave');
select permissions.can_for('user', :'dave', 'document', :'acme_readme', 'view');     -- false
select permissions.can_for('user', :'dave', 'document', :'acme_readme', 'viewer');   -- true: the relation is untouched
select * from permissions.who_can('document', :'acme_readme', 'view');               -- Dave is gone, Carol stays
select permissions.revoke('document', :'acme_readme', 'blocked', 'user', :'dave');   -- access restored
```

Check the permission (`view`), not the relation (`viewer`): the forbid vetoes the permission only. A forbid can also name a team (`grant(..., 'blocked', 'team', :'eng', 'member')` blocks every member), and it beats access inherited from a parent, on that document only:

```sql
select permissions.grant('document', :'acme_readme', 'blocked', 'user', :'alice');
select permissions.can_for('user', :'alice', 'document', :'acme_readme', 'edit');    -- false, though she is an org admin
select permissions.can_for('user', :'alice', 'document', :'acme_plan',   'edit');    -- true
```

**Deny overrides along the whole chain.** A `but_not` relation of permission `P` on any object in the chain vetoes `P` for everything that inherits `P` from it. In this model a forbid on a *folder* blocks its documents even for someone who holds a direct grant on a document:

```sql
select permissions.grant('document', :'acme_readme', 'viewer',  'user', :'erin');
select permissions.grant('folder',   :'specs',       'blocked', 'user', :'erin');
select permissions.can_for('user', :'erin', 'document', :'acme_readme', 'view');   -- false
```

This is Cedar-style, not OpenFGA's exact `but not`, which would subtract the folder's `blocked` only from the folder-derived part. Exclusion relations must be relations of the permission's own type, and an exclusion cannot be `parent->...`. A forbid that targets "everyone" (`blocked` accepting `user:*`, granted with `grant_public`) empties `who_can`, public row included.

### 3.8 Conditions with RLS

Conditions about the object (a status column, an owner, a date) stay in your policy, composed with `accessible()`. The engine answers "may this user touch this object at all", and the policy adds "and is it in the right state". Grant expiry (3.4) is the one condition that lives in the engine.

```json
{
  "types": {
    "org": {
      "relations":   { "admin": ["user"], "editor": ["user"], "member": ["user"] },
      "implies":     { "admin": ["editor"], "editor": ["member"] },
      "permissions": { "edit": ["editor"], "view": ["member"] }
    },
    "document": {
      "parent":      ["org"],
      "relations":   { "editor": ["user"], "viewer": ["user"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "edit": ["editor", "parent->edit"], "view": ["viewer", "parent->view"] }
    }
  }
}
```

```sql
create table public.documents (
    id uuid primary key, org_id uuid not null, title text not null,
    status text not null check (status in ('draft', 'published'))
);
alter table public.documents enable row level security;
grant select on public.documents to authenticated;

-- editors see everything; viewers see published documents only
create policy documents_select on public.documents for select to authenticated using (
    id = any ((select permissions.accessible('document', 'edit'))::uuid[])
    or (status = 'published' and id = any ((select permissions.accessible('document', 'view'))::uuid[]))
);
```

Link the documents to their org with `set_parent('document', id, 'org', org_id)` and grant `org` roles. Then an org member sees published documents, an org editor sees drafts too, and a member whose grant has expired sees nothing. Publishing a draft (`update ... set status = 'published'`) shows it to members immediately, with no engine call.

One limit: `can_for` and `who_can` do not know your conditions. `can_for` says true for a draft that RLS hides from that member.

### 3.9 Bulk loading with `grant_many`

`grant_many` grants one relation for many (object, subject) pairs in one statement. The two arrays are paired by position.

```sql
select permissions.grant_many('team', 'member', 'user',
    array[:'eng', :'eng', :'eng']::uuid[], array[:'bob', :'carol', :'dave']::uuid[]);     -- 3, the new grants
-- the same call again returns 0: pairs that already exist are skipped

-- import a legacy sharing table
select permissions.grant_many('document', 'viewer', 'user', array_agg(document_id), array_agg(user_id))
from public.shares;

-- nestings: the last argument is the subject's relation
select permissions.grant_many('team', 'member', 'team', array[:'platform']::uuid[], array[:'eng']::uuid[], 'member');
```

Names are validated once, and the membership trigger runs once for the whole batch instead of once per grant. A variant of the wide benchmark seed (306k grants) loaded in 7.9 s with five `grant_many` calls, against 27.6 s with one `grant()` per row on the same database (local PG 16.4). The memberships were identical, and it did not matter whether nestings or members were loaded first (7.1 s and 7.9 s). Put your own cap on the array size.

Differences from `grant`: no `expires_at`, no overwrite of an existing grant, and the call is atomic (one bad pair rolls everything back). Arrays of different lengths, or with null elements, raise `22004`. Like `grant`, it is admin-only.

### 3.10 Operations

The examples use the quick-start model.

**`verify()` and `rebuild()`.** Memberships and ancestors are derived data. `verify()` recomputes them from the grants with an independent walk and diffs against the stored rows. No rows returned means no drift.

```sql
select * from permissions.verify();    -- no rows

-- simulate drift (do not do this in production)
delete from permissions.memberships where principal_id = :'dave' and set_id = :'platform';
select * from permissions.verify();
--    kind    | member_id |           set_key           | problem
--  ----------+-----------+-----------------------------+---------
--   membership | <Dave's id> | team:<platform id>#member | missing

select permissions.rebuild();          -- recomputes both derived tables; returns rows written
```

`problem` is `missing`, `extra`, or `depth N, should be M`. `kind` is `membership` or `ancestor`. Both functions are full recomputes: cost grows with all membership rows, and `rebuild()` holds the global lock for its whole run. Use them as maintenance tools, not per request.

Run `verify()` when:

- you change the `permissions` tables behind the triggers' back: direct DML, `session_replication_role = replica`, `pg_restore --disable-triggers`, logical replication that copies some of the tables but not others;
- after restoring a backup or cloning a database partially;
- on a schedule, with an alert if it returns any row (`select count(*) from permissions.verify()`). It is the safety net for bugs in the write path that no test covered.

If it reports drift, call `rebuild()`.

**The lock.** Every write that changes memberships or the container closure takes `pg_advisory_xact_lock(1885697139, 1)`: userset grants and revokes, `set_parent`/`unset_parent`/`forget_object` on a container, `rebuild()`, and model changes that trigger a rebuild. It is held **until the transaction ends**, so keep permission writes in short transactions. Object grants and revokes, moving a document, and expiring grants do not take it.

```sql
begin;
select permissions.grant('team', :'eng', 'member', 'user', :'erin');
select count(*) from pg_locks
where locktype = 'advisory' and classid = 1885697139 and objid = 1 and pid = pg_backend_pid();   -- 1
commit;
```

**Isolation levels, for ORMs.** Under `repeatable read` the snapshot is fixed before the lock is taken, so a concurrent writer's committed rows would stay invisible and the derived rows would drift. The engine refuses with `0A000`:

| Level | Membership and container writes | Object grants |
| --- | --- | --- |
| `read committed` (Postgres default) | Allowed | Allowed |
| `repeatable read` | **Refused, `0A000`** | Allowed |
| `serializable` | Allowed; one of two conflicting writers fails with `40001`, so retry | Allowed |

```sql
begin isolation level repeatable read;
select permissions.grant('team', :'eng', 'member', 'user', :'frank');
-- ERROR:  pg_permissions: group membership and parent changes are not allowed in repeatable read transactions
-- HINT:  Run this write in read committed (the default) or serializable.
rollback;
```

If your framework or connection pool sets `repeatable read` globally, run permission writes on a connection or role that uses `read committed`, for example `alter role app_admin set default_transaction_isolation = 'read committed'`, or start the transaction with `set transaction isolation level read committed` before its first query. The same applies to `set_parent` on a folder. `apply_model()` takes the lock without checking the isolation level, but a rebuild inside it raises `0A000` under `repeatable read`, so apply models in `read committed`.

### 3.11 Graduating from the rbac preset

An app that started on the `rbac` preset (shared guide) adds per-object sharing with one `apply_model()` call that contains only the app's own types. The preset's `app` and `tenant` types are carried over, so roles and assignments are untouched. Every preset answer stays the same.

```sql
-- before: roles, assignments, and a policy on the tenant column
select permissions.assign_role(:'alice', 'admin',  :'acme');
select permissions.assign_role(:'bob',   'editor', :'acme');
create policy documents_select on public.documents for select to authenticated using (
    permissions.has_permission('documents.read', org_id)
);

-- graduate: add the document type
select * from permissions.apply_model($json$
{
  "types": {
    "document": {
      "relations":   { "editor": ["user"], "viewer": ["user"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "view": ["viewer"], "edit": ["editor"] }
    }
  }
}
$json$);
select permissions.grant('document', :'acme_readme', 'editor', 'user', :'dave');

-- the policy gains one arm
drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
    or id  = any ((select permissions.accessible('document', 'view'))::uuid[])
);
```

Dave sees only the shared document; Bob still sees everything his roles allow. To let preset roles flow down to folders and documents, use `tenant` as a parent (3.5). Note that each `create_role` or `drop_role` creates a model version, so create roles in migrations, not per request.

### 3.12 Cleaning up

There are no foreign keys to your tables, so deleted users and objects leave grants behind unless you clean up. These calls work with any model.

```sql
select permissions.forget_subject(:'erin');                  -- grants to Erin, returns how many
select permissions.forget_object('document', :'acme_plan');  -- grants on the object and grants to its usersets
```

`forget_subject(uuid)` deletes every grant where the principal is the subject. If those included team memberships, the derived memberships are updated under the lock. `forget_object(type, id)` deletes grants on the object, grants whose subject is one of its usersets (so `forget_object('team', eng)` also removes access that was given to `team:eng#member`), and its parent link. For a container its children become roots, and the closure is rewritten under the lock.

Attach the shipped trigger functions to your tables to do this on delete. They read the id column from the deleted row, with no dynamic SQL.

```sql
create trigger profiles_permissions_cleanup after delete on public.profiles
    for each row execute function permissions.on_subject_deleted('id');
create trigger documents_permissions_cleanup after delete on public.documents
    for each row execute function permissions.on_object_deleted('document', 'id');
```

Execute on these functions is revoked from public, so only roles you trust can attach them. The id column must hold a uuid. They return `old`, so they work as `AFTER DELETE` row triggers.

### 3.13 Non-uuid app keys

Every id the engine sees is a `uuid`, including the user id. A JWT `sub` that is not a uuid counts as no subject, so every check is false. If your keys are `bigint` or `text` you have two options.

**Derive a uuid from the key.** `md5(...)::uuid` is deterministic and built in. Prefix the key with its type so that different kinds of thing cannot collide (ids are assumed unique across principal types). A generated column keeps it next to the key and lets RLS compare uuids without casts:

```sql
create table public.invoices (
    id    bigint generated always as identity primary key,
    title text not null,
    uid   uuid generated always as (md5('invoice:' || id)::uuid) stored unique
);
alter table public.invoices enable row level security;
create policy invoices_select on public.invoices for select to authenticated using (
    uid = any ((select permissions.accessible('invoice', 'view'))::uuid[])
);

select permissions.grant('invoice', md5('invoice:' || 2)::uuid, 'viewer', 'user', md5('user:' || 42)::uuid);
-- identify the caller the same way (your auth layer sets this for each request)
select set_config('permissions.subject_id', md5('user:' || 42)::uuid::text, true);
```

**Keep a mapping table** when you do not want ids to be a function of the key (for example when keys can be reused):

```sql
create table public.perm_keys (key text primary key, id uuid not null unique default gen_random_uuid());
create function public.perm_id(p_key text) returns uuid language sql as $$
    insert into public.perm_keys (key) values (p_key) on conflict (key) do update set key = excluded.key
    returning id $$;
```

Convert the md5 result with `::uuid::text` before putting it in `permissions.subject_id` or a JWT `sub`: plain `md5()` output has no dashes, and a subject that is not a dashed uuid is treated as no subject. In both cases index the uuid column you compare to.

## 4. API reference

All functions are in schema `permissions`. "Admin" means the owner of the extension, or any role you grant execute to (for example `service_role`). "Client" means callable by `authenticated` and `anon`. See the shared guide for the privilege model. The installed function list was taken from `pg_proc` (names not starting with an underscore): 33 signatures, 31 names (`has_permission` and `has_role` each have a text-scope and a uuid-scope form).

| Function | Caller | Volatility | Purpose |
| --- | --- | --- | --- |
| [`apply_model`](#apply_model) | admin | volatile | Compile a model |
| [`model`](#model) | admin | stable | The active definition |
| [`can`](#can) | client | stable | Does the current subject hold a permission on an object |
| [`accessible`](#accessible) | client | stable | Ids the current subject holds a permission on |
| [`current_subject_id`](#current_subject_id), [`current_subject_type`](#current_subject_type) | client | stable | Who is calling |
| [`can_for`](#can_for) | admin | stable | `can` for any subject |
| [`accessible_for`](#accessible_for) | admin | stable | `accessible` for any subject |
| [`who_can`](#who_can) | admin | stable | Subjects holding a permission on an object |
| [`grant`](#grant) | admin | volatile | Grant a relation |
| [`grant_many`](#grant_many) | admin | volatile | Bulk grant |
| [`revoke`](#revoke) | admin | volatile | Remove a grant |
| [`grant_public`](#grant_public), [`revoke_public`](#revoke_public) | admin | volatile | Public (`type:*`) grants |
| [`set_parent`](#set_parent), [`unset_parent`](#unset_parent) | admin | volatile | Parent links |
| [`forget_subject`](#forget_subject), [`forget_object`](#forget_object) | admin | volatile | Remove everything about a subject or object |
| [`on_subject_deleted`](#on_subject_deleted), [`on_object_deleted`](#on_object_deleted) | admin (attach) | volatile | Cleanup trigger functions |
| [`verify`](#verify) | admin | stable | Detect drift in derived data |
| [`rebuild`](#rebuild) | admin | volatile | Recompute derived data |
| [`create_role`](#rbac-preset-functions), [`drop_role`](#rbac-preset-functions), [`assign_role`](#rbac-preset-functions), [`unassign_role`](#rbac-preset-functions) | admin | volatile | `rbac` preset: roles |
| [`has_permission`](#rbac-preset-functions), [`has_role`](#rbac-preset-functions), [`scopes_with_permission`](#scopes_with_permission) | client | stable | `rbac` preset: checks |
| [`user_permissions`](#rbac-preset-functions), [`users_with_role`](#rbac-preset-functions) | admin | stable | `rbac` preset: debugging |

Clients get `42501` (permission denied) from an admin function, and cannot read the tables. Every function except the two identity functions is `security definer`, and all of them set an empty `search_path`.

**Reads never raise for unknown names.** `can`, `accessible`, `can_for`, `accessible_for` and `who_can` return false, an empty array or no rows for an unknown type or permission, so a policy that names a dropped permission denies instead of breaking every query. It also means a typo in a policy fails silently: test your policies. Writes validate everything and raise.

### The model JSON

The grammar, with every key. `{...}` is an object, `[...]` an array of strings.

```
model       := { "types": { <type name>: type, ... } }

type        := { "principal":   true | false,                          -- optional, default false
                 "parent":      [ <type name>, ... ],                  -- optional
                 "relations":   { <relation>: [ subject, ... ], ... }, -- optional
                 "implies":     { <relation>: [ <relation>, ... ], ... },   -- optional
                 "permissions": { <permission>: perm, ... } }          -- optional

subject     := <principal type>                -- one user:       "user"
             | <principal type> ":*"           -- every user:     "user:*"
             | <type> "#" <relation>           -- a userset:      "team#member"

perm        := [ item, ... ]                                           -- any of these
             | { "any": [ item, ... ], "but_not": [ <relation>, ... ] }  -- both keys optional

item        := <relation>                      -- a relation of the same type
             | "parent->" <permission>         -- the same permission on the parent
```

Names: type names match `^[a-z][a-z0-9_]{0,62}$`. Relation and permission names match `^[a-z][a-z0-9_.]{0,62}$` (dots are allowed, so `documents.read` works). Subjects match `^[a-z][a-z0-9_]{0,62}(#[a-z][a-z0-9_.]{0,62}|:\*)?$`.

| Key | Meaning |
| --- | --- |
| `types` | Required object. Unknown keys inside a type are rejected. |
| `principal` | `true` marks the type as end subjects (what `current_subject_id()` identifies). Uuids are assumed unique across principal types. `user` is added with `principal: true` if you omit it; if you include it, it must be a principal. |
| `parent` | The types an object of this type may have as its parent, set with `set_parent`. Parent types must exist and must not be principals. A type that appears in some `parent` list is a **container**. |
| `relations` | What can be granted and to whom. Each list must be non-empty. A plain subject must be a principal type. A `type#relation` subject makes that relation a **userset** (group) and `relation` must be a relation, not a permission, of `type`. `type:*` is public access and `type` must be a principal. |
| `implies` | Holding the key relation also satisfies the listed relations. Same type, relations only, transitive. A cycle is rejected. |
| `permissions` | Named checks. Cannot be granted. Cannot list other permissions. |
| `any` | The items that satisfy the permission. At least one is required. |
| `but_not` | Relations of the same type that veto the permission. `parent->` is not allowed here. |
| `parent->P` | Valid only inside a permission named `P`, on a type that has `parent`. |

`apply_model()` raises `22023`, naming the offending items, when:

- the definition is not an object with a `types` object, a name is invalid, a type has unknown keys, or a value has the wrong shape;
- a name is both a relation and a permission on the same type (this is how the preset enforces that role and permission names cannot overlap);
- a relation has an empty subject list, or a subject names an unknown type, a non-principal type without `#`, an unknown relation after `#`, or `type:*` on a non-principal type;
- `implies` names something that is not a relation of the same type, or has a cycle;
- a `parent` names an unknown or principal type;
- a permission item is not a relation of the same type or `parent->P` (with `P` equal to the permission's own name, on a type that has `parent`), or a permission has no `any` item;
- **inheritance is not all-or-nothing:** `X.P` contains `parent->P` but some parent type of `X` does not define `P`, or defines it but, having parents itself, does not contain `parent->P`;
- `type:*` appears on a relation that feeds a userset (every user would become a group member, which cannot be materialized);
- an existing expiring grant would start to feed a userset;
- it defines or redefines `app` or `tenant`, or `user` is defined without `principal: true`.

It raises `2BP01` when applying would delete grants or parent links (a removed type or relation, or a narrowed subject list) and `p_force` is false.

### Functions

#### apply_model

```sql
permissions.apply_model(p_definition jsonb, p_dry_run boolean default false, p_force boolean default false)
  returns table (change text, detail text)
```

Admin. Validates the model, compiles it, rebuilds derived data if needed, and records a new version. Returns the plan: `add type`, `add relation`, `add permission`, `remove type`, `remove relation`, `remove permission`, `change principal`, `change <kind> to <kind>`, `delete tuples`, `delete parent links`, `rebuild memberships`, `rebuild ancestors`, then `version | N`. With `p_dry_run` the last row is `dry run | nothing was changed` and nothing is changed. An identical definition returns `unchanged | version N`. `app` and `tenant` are carried over from the active model, and `user` is added if missing. Errors: `22023`, `2BP01` (needs force), `0A000` (a rebuild is needed under `repeatable read`), `54001` (a rebuild finds nesting deeper than 10). Takes the global lock when the definition changed. See 3.1.

```sql
select * from permissions.apply_model(:'model', p_dry_run => true);
```

#### model

```sql
permissions.model() returns jsonb
```

Admin. The active definition, including the preset's `app` and `tenant` types. Strip those before passing it back to `apply_model`.

```sql
select permissions.model() -> 'types' -> 'document';
```

#### can

```sql
permissions.can(p_object_type text, p_object_id uuid, p_permission text) returns boolean
```

Client. Does the current subject hold the permission, or relation, on the object. True when some grant permits it (directly, through a group, publicly, or from a parent) and no forbid vetoes it. False for no subject, a null id, or an unknown type or name. One indexed query; use it for single-row checks (`update` policies, `with check`). The permission argument accepts a relation too: `can('document', id, 'viewer')`.

```sql
select permissions.can('document', :'acme_readme', 'edit');
```

#### accessible

```sql
permissions.accessible(p_object_type text, p_permission text) returns uuid[]
```

Client. Every id of the type on which the current subject holds the permission, sorted and distinct, with forbids removed. Grants on containers expand to the objects below them (for permissions with `parent->`; a relation name does not expand). Empty for no subject or an unknown name. This is the RLS fast path, in the form `id = any ((select permissions.accessible('document', 'view'))::uuid[])`. The array can be large for people who see most of a table (3.5).

```sql
select cardinality(permissions.accessible('document', 'view'));
```

#### current_subject_id

```sql
permissions.current_subject_id() returns uuid
```

Client. The JWT `sub` if present, else the `permissions.subject_id` setting, else null. A value that is not a uuid is null. The JWT wins. Details in the shared guide.

```sql
select set_config('permissions.subject_id', :'bob', false);
select permissions.current_subject_id();   -- bob
```

#### current_subject_type

```sql
permissions.current_subject_type() returns text
```

Client. The `permissions.subject_type` setting, default `'user'`. Only relevant if you have more than one principal type.

#### can_for

```sql
permissions.can_for(p_subject_type text, p_subject_id uuid, p_object_type text, p_object_id uuid, p_permission text) returns boolean
```

Admin. `can` for any subject. Admin-only because it would let a client ask about other users. Null subject or object gives false.

```sql
select permissions.can_for('user', :'dave', 'document', :'acme_readme', 'view');
```

#### accessible_for

```sql
permissions.accessible_for(p_subject_type text, p_subject_id uuid, p_object_type text, p_permission text) returns uuid[]
```

Admin. `accessible` for any subject.

```sql
select permissions.accessible_for('user', :'dave', 'document', 'view');
```

#### who_can

```sql
permissions.who_can(p_object_type text, p_object_id uuid, p_permission text) returns setof uuid
```

Admin. The principals holding the permission on the object, through direct grants, groups and parents, minus the vetoed. **A public grant is one `null` row**, meaning every principal of the grant's type; users are never enumerated. The null row is not net of per-principal forbids, and a public forbid empties the list. Expired grants are ignored. Use `is null` to test for the public row (3.6).

```sql
select * from permissions.who_can('document', :'acme_readme', 'view');
```

#### grant

```sql
permissions.grant(p_object_type text, p_object_id uuid, p_relation text, p_subject_type text, p_subject_id uuid,
                  p_subject_relation text default null, p_expires_at timestamptz default null) returns void
```

Admin. Grants a relation on an object to a principal, or to a userset when `p_subject_relation` is given (an empty string counts as null). Granting an existing grant updates its expiry (a null expiry makes it permanent) and is otherwise a no-op. Takes the global lock when the relation feeds a group. Errors: `22023` (unknown type or relation, the name is a permission, the relation does not accept this subject), `22004` (null object or subject id), `0A000` (an expiry on a relation that feeds a group, or `repeatable read` when the lock is needed), `54001` (nesting deeper than 10).

```sql
select permissions.grant('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');
```

#### grant_many

```sql
permissions.grant_many(p_object_type text, p_relation text, p_subject_type text,
                       p_object_ids uuid[], p_subject_ids uuid[], p_subject_relation text default null) returns bigint
```

Admin. Bulk `grant`: pairs `p_object_ids[i]` with `p_subject_ids[i]`. Returns the number of new grants. Existing pairs are skipped, there is no expiry, and the whole call is atomic. Errors: `22023` as for `grant`, `22004` (different lengths or null elements), `0A000` and `54001` from the lock and depth rules. See 3.9.

```sql
select permissions.grant_many('team', 'member', 'user', array[:'eng', :'eng']::uuid[], array[:'bob', :'carol']::uuid[]);
```

#### revoke

```sql
permissions.revoke(p_object_type text, p_object_id uuid, p_relation text, p_subject_type text, p_subject_id uuid,
                   p_subject_relation text default null) returns boolean
```

Admin. Removes one grant. True if it existed. Unknown names raise `22023`. Takes the global lock when the relation feeds a group (affected users are recomputed).

```sql
select permissions.revoke('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');
```

#### grant_public

```sql
permissions.grant_public(p_object_type text, p_object_id uuid, p_relation text, p_subject_type text default 'user') returns void
```

Admin. Grants the relation to every principal of the subject type. The relation must list `type:*`, otherwise `22023`.

```sql
select permissions.grant_public('document', :'announcement', 'viewer');
```

#### revoke_public

```sql
permissions.revoke_public(p_object_type text, p_object_id uuid, p_relation text, p_subject_type text default 'user') returns boolean
```

Admin. Removes the public grant. True if it existed.

#### set_parent

```sql
permissions.set_parent(p_object_type text, p_object_id uuid, p_parent_type text, p_parent_id uuid) returns void
```

Admin. Sets or moves the object's parent (one parent per object). For a container it takes the global lock and rewrites the closure of its sub-folders. Errors: `22004` (null id), `22023` (the model does not allow that parent type), `23514` (the new parent is the object or one of its descendants), `54001` (chain deeper than 10), `0A000` (a container move under `repeatable read`). Moving a leaf takes no lock.

```sql
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');
```

#### unset_parent

```sql
permissions.unset_parent(p_object_type text, p_object_id uuid) returns boolean
```

Admin. Removes the parent link. True if there was one. Takes the lock for a container.

#### forget_subject

```sql
permissions.forget_subject(p_subject_id uuid) returns bigint
```

Admin. Deletes every grant to the principal and returns how many. Membership changes follow under the lock. Takes only the id, not a type, so ids must not collide across types.

```sql
select permissions.forget_subject(:'erin');
```

#### forget_object

```sql
permissions.forget_object(p_object_type text, p_object_id uuid) returns bigint
```

Admin. Deletes grants on the object, grants to its usersets, and its parent link, and returns the number of grants deleted. For a container its children become roots, and the closure is rewritten.

```sql
select permissions.forget_object('document', :'acme_plan');
```

#### on_subject_deleted

```sql
permissions.on_subject_deleted() returns trigger        -- argument: the id column name
```

Trigger function, for `AFTER DELETE ... FOR EACH ROW` on your users or profiles table. Calls `forget_subject`. Execute is revoked from public, so the role that creates the trigger needs it. The column must hold a uuid.

```sql
create trigger profiles_permissions_cleanup after delete on public.profiles
    for each row execute function permissions.on_subject_deleted('id');
```

#### on_object_deleted

```sql
permissions.on_object_deleted() returns trigger         -- arguments: the object type, the id column name
```

Trigger function that calls `forget_object(type, id)`.

```sql
create trigger documents_permissions_cleanup after delete on public.documents
    for each row execute function permissions.on_object_deleted('document', 'id');
```

#### verify

```sql
permissions.verify() returns table (kind text, member_id uuid, set_key text, problem text)
```

Admin. Recomputes memberships and the ancestor closure from the grants and parent links and diffs them against the stored rows. No rows means no drift. `kind` is `membership` or `ancestor`; `set_key` is `type:id#relation` for memberships and `type:id` for ancestors; `problem` is `missing`, `extra` or `depth N, should be M`. Read-only, but O(all memberships).

```sql
select * from permissions.verify();
```

#### rebuild

```sql
permissions.rebuild() returns bigint
```

Admin. Deletes and recomputes `memberships` and `ancestors`. Returns the number of rows written. Takes the global lock for the whole run. Errors: `0A000` under `repeatable read`, `54001` if the grants contain nesting deeper than 10.

```sql
select permissions.rebuild();
```

#### scopes_with_permission

```sql
permissions.scopes_with_permission(p_permission text, p_unfold boolean default permissions._unfolded_null()) returns text[]
```

Client. `rbac` preset: the tenant ids on which the current subject holds the permission, as text. **Do not pass the second argument.** It is ignored. It exists so that Postgres cannot evaluate the call at plan time (a STABLE function with constant arguments is evaluated by the planner, and the call would run twice per query). Passing both arguments as constants makes the planner fold the call again. Use it in policies as shown in 3.11: `org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))`. Because it takes two arguments, grants must name the two-argument signature.

#### rbac preset functions

The `rbac` preset has the same signatures and behaviour on every engine; its reference is in [README.md](./README.md). Engine C notes:

```sql
permissions.create_role(p_role text, p_permissions text[], p_inherits text[] default '{}') returns void   -- admin
permissions.drop_role(p_role text) returns void                                                           -- admin
permissions.assign_role(p_user_id text, p_role text, p_scope text default null) returns void              -- admin
permissions.unassign_role(p_user_id text, p_role text, p_scope text default null) returns void            -- admin
permissions.has_permission(p_permission text, p_scope text default null) returns boolean                  -- client
permissions.has_permission(p_permission text, p_scope uuid) returns boolean                               -- client
permissions.has_role(p_role text, p_scope text default null) returns boolean                              -- client
permissions.has_role(p_role text, p_scope uuid) returns boolean                                           -- client
permissions.user_permissions(p_user_id text, p_scope text default null) returns text[]                    -- admin
permissions.users_with_role(p_role text, p_scope text default null) returns setof text                    -- admin
```

- The preset takes **text** ids for users and scopes (the same signatures as the other engines) and casts them to uuid. A non-uuid id raises `22P02` on writes (`assign_role`) and gives false or empty on reads. The `uuid` overloads of `has_permission` and `has_role` let a policy pass a `uuid` column without a cast.
- Every `create_role` and `drop_role` applies a new model version. `create_role` raises `23505` if the role exists. `drop_role` raises `2BP01` while another role inherits it, `22023` if it does not exist, and deletes the role's assignments.
- `assign_role` raises `22023` for an unknown role. `unassign_role` ignores an unknown role.
- Roles live on the preset types `app` (app-wide, one object with the nil uuid) and `tenant` (one object per scope). You cannot define those types in your own model, but your types can name `tenant` as a parent (3.5).

```sql
select permissions.create_role('editor', '{documents.edit}', '{viewer}');
select permissions.assign_role(:'bob', 'editor', :'acme');
select permissions.has_permission('documents.edit', :'acme'::uuid);   -- as Bob
```

### Tables

Ten tables hold the model and the data. All have `revoke all from public` and row level security with no policies, so clients cannot read them. You can read them as the owner for debugging, and the specs do, but go through the functions for everything else.

| Table | Contents |
| --- | --- |
| `models` | One row per applied version: full `definition`, `applied_at`, `applied_by`. The latest row is active. |
| `types` | One per type, with a stable `smallint` id, and the `principal` and `container` flags. |
| `relations` | One per relation or permission: `kind`, `is_userset`, `feeds_userset`. |
| `allowed_subjects` | The compiled subject lists of each relation. |
| `parent_types` | The compiled `parent` lists. |
| `satisfies` | The compiled relation axis: which relations satisfy or veto which permission, on the object or through an ancestor. |
| `tuples` | One row per grant. `subject_id` null means a public grant. Immutable apart from `expires_at`; `truncate` is blocked. |
| `parents` | One row per object that has a parent. |
| `memberships` | Derived: each principal in each group it belongs to, transitively, with the shortest depth. |
| `ancestors` | Derived: container to ancestors. Only containers have rows. |

### SQLSTATE summary

| SQLSTATE | Raised by | Meaning |
| --- | --- | --- |
| `22023` | `apply_model`, `grant`, `revoke`, `grant_public`, `set_parent`, preset functions | Invalid model, unknown name, subject or parent not allowed by the model |
| `22004` | `grant`, `grant_many`, `set_parent` | Null id or array element |
| `22P02` | preset functions | A text id that is not a uuid |
| `2BP01` | `apply_model`, `drop_role` | Needs `force`, or the role is still inherited |
| `0A000` | `grant`, `revoke`, `set_parent`, `rebuild`, `apply_model` | `repeatable read` for a lock-taking write; an expiry on a group grant |
| `23514` | `set_parent`, raw inserts | Parent cycle; a tuple that does not match the model |
| `54001` | group and parent writes, `rebuild` | Depth over 10 levels |
| `55000` | direct DML on `tuples` | Updates (other than `expires_at`) and `truncate` |
| `23505` | `create_role` | The role already exists |
| `40001` | any lock-taking write under `serializable` | Serialization failure, retry |
| `42501` | any admin function or table, called by a client | Permission denied |

## 5. Performance notes

All figures are from [`bench/baselines/OPTIMIZATIONS.md`](../bench/baselines/OPTIMIZATIONS.md): PostgreSQL 18.6 in Docker, after the session 3 optimizations, 4 pgbench clients, p50, one laptop. "Large" is 1M documents, 10k users, 500 teams; "wide" is a medium-scale shape with 50 teams per user. The same matrix on PG 16 and 17 is in [`VERSIONS.md`](../bench/baselines/VERSIONS.md), with the same ordering. Absolute numbers will differ on your hardware. Read them as relative costs.

**Cheap in C**

| Operation | p50 |
| --- | --- |
| `can()` for a document (`rbac_check`, large) | 0.24 ms |
| `nest_check`: a check for a user who reaches a document only through a nested team | 0.30 ms, flat at every scale and shape |
| Sharing page of 50 under the two-arm policy (`share_select_page`, large) | 0.93 ms |
| `accessible()` for one user (`share_list_objects`, large) | 0.25 ms |
| Object grant (`write_share`) | 0.17 ms, no lock |
| `assign_role` | 0.17 ms |
| Projection parents policy, page of 50 (large) | 1.05 ms |

**The wide-read lead.** C's reads barely move with group shape: `share_select_page` is 0.66 ms in the deep shape (teams nested 9 levels) and 8.20 ms in the wide shape, against A 14.4 ms and B 17.8 ms on wide. That lead used to be 12 times A and is now 1.8 times, after A was optimized. `share_list_objects` on wide is 3.41 ms (A 4.44, B 8.41).

**Single-branch parents.** The single-branch policy returns every visible document id: 4.94 ms for a page and 11.9 ms for a count at large (A 45.6 and 75.1 ms, B 13.7 and 21.6 ms). That is the cheapest single-branch implementation of the three, but the two-arm projection is still about 4.7 times cheaper for the page (1.05 ms). Use the projection for large tenants (3.5).

**Expensive in C**

| Operation | Cost |
| --- | --- |
| Nest a 1,000-member team (`write_nest_team`, large, 4 clients) | **57.7 ms**, 67 tps. Deep: 75.1 ms. Wide: 61.2 ms. |
| The same, one client (local PG 16.4, earlier measurement) | about 15.5 ms. The 4-client figure is about 4 times that because concurrent writers queue on the global lock. |
| Un-nest (recompute the affected users) | A nest followed by an un-nest of the 1,000-member team took 25 to 30 ms at large (local PG 16.4). Deletes recompute, they are not a delta. |
| `grant()` of a membership | about 0.1 ms (trigger, transition table, one delta statement), against about 0.04 ms for an object grant. Local PG 16.4. |
| Seeding wide sharing with `grant()` per row (306k grants) | 24.7 s (A 5.9 s, B 12.6 s). With `grant_many`, about 8 s, local. |
| Parent links for 1M documents | 17.6 s, +160 MB |

A nest writes `members x (1 + groups above)` rows under the lock: 5,000 rows for the benchmark's nest, about 10 ms of that is the insert. That is the floor for materialized memberships. Per-key locking would not change this benchmark, because every nest touches the same members, and it was not built.

Concurrency is the thing to size. One lock serializes every membership and container write, so 67 nests per second is the ceiling for team-sized nests, and a directory sync that nests many teams at once queues behind itself. Plain object grants, document moves and RBAC role assignments are not affected. Budgets: C's only misses are `write_nest_team` (p95 64 to 115 ms against 1 ms) and `parents_proj_select_count`, which every engine misses (about 8 ms, the heap-read floor).

**Storage.** 182 MB at large after the parents seed (A 404 MB, B 378 MB). In the wide shape it is the largest, 191.6 MB (A 97 MB, B 105 MB), because memberships are stored per user: 100k users in 50 groups is 5M rows.

**Planner notes for your own policies.**

- Use the `(select accessible(...))::uuid[]` form. Measured against 1M documents and a user with 300 grants, on a busy machine, so read the ratios (page of 50): 0.36 to 0.48 ms, against 0.55 to 0.7 ms for `array(select unnest(...))`, 47 ms for `id in (select unnest(...))`, and an error for `id = any ((select f()))`.
- `scopes_with_permission` and `accessible` inside the policy forms shown here are not evaluated at plan time; planning stays under 0.3 ms.
- Keep `can()` for single-row checks. In a `select` policy it runs once per row.

## 6. Gotchas and limits

**Write path and concurrency**

- **One global lock** for every membership change, container move and rebuild. Bulk directory syncs (SCIM) and concurrent team edits queue behind it. The lock is held until the transaction ends, so a long transaction that touches a group blocks all other group writes.
- **`repeatable read` is refused** (`0A000`) for those writes, which surprises ORMs and poolers that set it by default (3.10).
- **Latency lands in your transaction.** Nesting a 10,000-member team writes more than 10,000 rows synchronously. There is no background worker.
- **A model change that touches groups rebuilds all memberships** under the lock, in one transaction.
- **Deletes recompute.** Revoking a membership or nesting recomputes each affected user from scratch.

**Model and data**

- **Max depth 10** for group nesting and for parent chains (`54001`). Parent cycles are rejected. Group cycles are accepted.
- **IDs are uuid only**, and uuids must not collide across principal types (`memberships` and `forget_subject` key on the uuid alone). Object ids must be unique per type.
- **The engine does not know your objects.** A grant on an id that is not in your table is accepted, and nothing removes it when the row goes away unless you attach the cleanup triggers (3.12).
- **Parent links duplicate your data.** The app's `folder_id` and `set_parent()` must be kept in sync (3.5 shows a trigger). One parent per object.
- **`apply_model` replaces the model.** Leaving a type out removes it. Renames are drop and add, and with force they delete grants.
- **Inheritance is all-or-nothing** along a hierarchy, and `parent->P` must have the same name `P` at every level.
- **Forbid is deny-overrides**, not OpenFGA's exact `but not`. Exclusion relations are same-type relations only. The forbid vetoes the permission, not the relation. The null row in `who_can` is not net of per-user forbids.
- **No expiring group memberships.** Rejected on write and when applying a model, rather than silently wrong.
- **No provenance.** Memberships say that Carol is in `platform`, not why. `explain()` is not built, so there is no function that tells you why a check is true or false.
- **No policy generation, rename hints or per-key locking.**
- **No function lists raw grants.** `who_can` returns principals, `accessible` returns ids. To list the grants on an object, read `permissions.tuples` as the owner.

**Reads**

- **Unknown names return false or empty.** A typo in a policy denies everything and raises nothing. Run each policy as a test user.
- **A request with no subject is denied**, including for public documents.
- **`accessible()` can return a very large array** for someone who sees most of a table, and `count(*)` does one index probe per id.
- **`can_for` and `who_can` do not apply your RLS conditions** (status columns and the like), nor org arms that live only in your policy.
- **Do not pass the second argument of `scopes_with_permission`.**
- **Checks are not compiled SQL.** They go through generic PL/pgSQL functions, so the gains are no recursion and typed keys.

**Plan output (prototype quirk).** The plan returned by `apply_model` can omit rows. In the prototype, `remove ...` rows (and, if no relation is added, the `add type` rows) are dropped from the plan unless the same change also adds a type or a relation, because the code that appends additions to the plan array resets it when there is nothing to add. The changes themselves and the `rebuild`, `delete` and `version` rows are not affected. Use the `2BP01` message to learn what `force` would delete.

For the comparison with the other engines and the open questions (uuid-only keys, the global lock, `repeatable read`), see [`DECISION.md`](../DECISION.md).
