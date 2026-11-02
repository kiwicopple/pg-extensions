# Design C: compiled model

> **History.** This guide is for prototype C. Prototype C is a historical design, and this guide is the original text of it. The extension is design D. The user docs are at [Using pg_permissions](../../docs/README.md). For the extension, also read [The OpenFGA model](../../docs/fga.md) and [RLS with both models](../../docs/rls.md).

This page is for an app developer who has picked design C. It shows how to use design C and lists every public function. The shared guides have these topics, and this page does not repeat them:

- Install: [install.md](../../docs/install.md).
- Identity (JWT `sub`, `permissions.subject_id`) and the general RLS rules: [rls.md](../../docs/rls.md).
- The split of privileges between client and admin, and the function reference: [reference.md](../../docs/reference.md).
- The `rbac` preset reference: [rbac.md](../../docs/rbac.md).

Every example with an observable result is also a test. The file [`../../test/spec/c/90_usage_examples.sql`](../../test/spec/c/90_usage_examples.sql) follows this page section by section, and its comments carry the section numbers. Run it against the prototype with `./test/run.sh 90 --impl prototypes/c-compiled-model.sql`. For design background, see [`designs/c-compiled-model.md`](../designs/c-compiled-model.md). For the comparison with the other designs, see [`../decision.md`](../decision.md).

Contents

1. [Mental model](#1-mental-model)
2. [Quick start](#2-quick-start)
3. [How-to guides](#3-how-to-guides)
4. [API reference](#4-api-reference)
5. [Performance notes](#5-performance-notes)
6. [Warnings and limits](#6-warnings-and-limits)

## 1. Mental model

Write your authorization model once, as JSON. Give it to `permissions.apply_model()`. The model declares these items:

- The **types** (`org`, `team`, `document`).
- The **relations** that each type can have (`document.editor`).
- Who can hold a relation: a user, every user, or a group such as `team#member`.
- The relations that **imply** other relations (`editor` implies `viewer`).
- The named **permissions** that your policies check (`document.edit`). These include exclusions (`but_not`) and inheritance from a **parent** (`parent->view`).

`apply_model()` compiles the model into lookup tables. After that, these rules apply:

- A **grant** is a row: this object, this relation, this subject. Subjects and objects are typed `uuid` ids. Grant relations (`editor`). Never grant permissions (`edit`).
- **Group membership is precomputed.** Triggers write one membership row for each affected user and group. They do this when you add a user to a team or put a team in another team. When you move a folder, the design rewrites the closure of its sub-folders. Documents never get closure rows.
- A **check** (`can`) or a **list** (`accessible`) is then a fixed number of index lookups. There is no recursion at read time.

This table shows what you get and what you pay:

| You get | You pay |
| --- | --- |
| Fast reads. Reads change little with group depth or with the number of groups of a user. `accessible()` returns a `uuid[]` that RLS can use as an index condition. | Writes that change group membership or move a folder take **one global advisory lock**. They write rows for every affected user. A write that nests a 1,000-member team takes about 58 ms, with 4 clients in the queue for the lock. Plain object grants take no lock and cost about 0.2 ms. |
| Typed validation. A write raises an error for an unknown type, relation or subject. | The design **refuses** `repeatable read` for the writes that take the lock (`0A000`). An ORM that uses it by default needs a different isolation level for permission writes (3.10). |
| One place to read the whole model (`permissions.model()`). | The derived tables can **drift** from the grants if a command bypasses the triggers. `verify()` finds drift. `rebuild()` repairs it (3.10). |
| The design handles cycles in group nests and in parent links. | Group nests and parent chains have a limit of **10 levels** (`54001`). The design **rejects** parent cycles on write (`23514`). It accepts group cycles, and they cause no harm. |
| Native `uuid` everywhere. Policies need no casts. | **IDs are uuid only.** An app with `bigint` or `text` keys needs a mapping (3.13). |

The design does not support group memberships that expire (`0A000`). A model change that touches groups rebuilds all memberships under the lock (3.1).

## 2. Quick start

The reference scenario is from section 5 of [plan.md](../plan.md). The org is `acme`. Alice is an admin and Carol is a member. Admins can edit and members can view every acme document.

Bob is not in the org. Bob is an editor of the `readme` document. The members of team `eng` (Carol and Dave) are viewers of `readme`. `editor` implies `viewer`.

The ids are psql variables, to make the examples easy to read. Any uuid works. In application code, use bind parameters. These are the ids that the tests use.

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

Keep the model in a file in your repository, for example `model.json`. It is the source of truth. The database keeps a history of what you applied.

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

Read the model in this way. A team has members. A member is a user or the members of another team (a nested team). An org has admins and members.

An admin is also a member. A document has editors and viewers. Each editor or viewer is a user or all members of a team. An editor is also a viewer. `view` and `edit` are the names that your policies will use.

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

A dry run does the whole compile inside a subtransaction. Then it rolls back the subtransaction. Thus validation errors also show in a dry run. The version number that you get depends on the number of earlier dry runs (3.1).

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

`accessible(type, permission)` returns every id of that type on which the current user has the permission, as a `uuid[]`. The `(select ...)::uuid[]` wrapper makes Postgres evaluate the function once for each query. Postgres then uses the array as an index condition. The `::uuid[]` cast does nothing here, because the function already returns `uuid[]`. But the cast tells the parser to treat the subquery as an array. Keep the cast.

The first arm says "documents of orgs where I can view documents". The second arm says "documents shared with me". For single-row writes, use the per-row `can()`.

### Step 4: grants

Run these statements as the table owner or as another admin role. Clients cannot call `grant`.

```sql
select permissions.grant('org',      :'acme',        'admin',  'user', :'alice');
select permissions.grant('org',      :'acme',        'member', 'user', :'carol');
select permissions.grant('team',     :'eng',         'member', 'user', :'carol');
select permissions.grant('team',     :'eng',         'member', 'user', :'dave');
select permissions.grant('document', :'acme_readme', 'editor', 'user', :'bob');
select permissions.grant('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');
```

The last call grants `viewer` to the userset `team:eng#member`. For this reason `grant` has a sixth argument for the relation of the subject. The result is 6 grants and 2 membership rows (Carol and Dave in `team:eng#member`). Org roles are not groups in this model, so they need no membership rows.

### Step 5: the three questions

**Can Bob update readme?**

```sql
select permissions.can_for('user', :'bob', 'document', :'acme_readme', 'edit');   -- true
select permissions.can_for('user', :'bob', 'document', :'acme_plan',   'edit');   -- false
```

To do the check through RLS as Bob, use this code. PostgREST does this for you from the JWT. The second line is the fallback for plain Postgres (see the [RLS guide](../../docs/rls.md)):

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

As Alice or Carol, the same query returns both acme documents, through the org arm of the policy. Bob and Dave see only `readme`. Erin has no grants, so she sees nothing.

**Who can view readme?**

```sql
select * from permissions.who_can('document', :'acme_readme', 'view');   -- Bob, Carol, Dave
```

Alice is not in that list. She sees `readme` through the `org_id` arm of the policy. The design cannot see that arm. Give the design the org link with a parent (3.5). Then `who_can` includes everyone who inherits access from the org. You can also remove the hand-written arm.


## 3. How-to guides

Each recipe starts from a small complete model, so that it runs on its own. `apply_model()` **replaces** your model with the model that you pass (except the preset types `app` and `tenant`). Merge the parts that you need into your own `model.json`.

The recipes use the ids from section 2. Client-side checks use the pattern from step 5.

### 3.1 Evolve the model safely

Treat `model.json` like a migration. Before you apply a change, do these checks.

**Do a dry run.** Use `p_dry_run => true`. The function returns the plan and changes nothing. It adds no new row to `permissions.models`. It reports validation errors in the same way as a real run.

```sql
select * from permissions.apply_model(:'model', p_dry_run => true);
```

The plan has one row for each change. The row types are `add type`, `add relation`, `add permission`, `remove relation`, `remove type`, `rebuild memberships`, `rebuild ancestors`, `delete tuples` and `delete parent links`. The last row is `version` (or `dry run`). A dry run reports a rebuild but does not do it.

**Know what is cheap.** A change that adds a type, a relation or a permission writes only catalog rows. A change to the items of a permission also writes only catalog rows. Two kinds of change start a rebuild. Both rebuilds run under the global lock, in the same transaction:

| Change | Plan row | Cost |
| --- | --- | --- |
| A relation becomes a group (`org#member` appears in the subject list of some relation). Or an `implies` link changes what feeds a group. Or a principal type changes. | `rebuild memberships` | Recomputes every membership row. |
| A `parent` list changes | `rebuild ancestors` | Recomputes the ancestor closure of every container. |

```sql
-- shows 'rebuild memberships' but does not do the rebuild
select * from permissions.apply_model(
    jsonb_set(:'model'::jsonb, '{types,document,relations,viewer}', '["user", "team#member", "org#member"]'),
    p_dry_run => true);

-- shows 'rebuild ancestors'
select * from permissions.apply_model(
    jsonb_set(:'model'::jsonb, '{types,document,parent}', '["org"]'), p_dry_run => true);
```

A rebuild of millions of membership rows needs a maintenance window. Do the rebuild at a quiet time.

**Removal needs `force`.** Some model changes drop a type or a relation that has grants. Other changes make the subject list of a relation narrower, so that some grants no longer fit. For these changes, `apply_model()` raises `2BP01`. The message gives the number of rows that the call would delete:

```sql
-- the active model has document.commenter with one grant; :'model' does not have the relation
select * from permissions.apply_model(:'model');
-- ERROR:  removing document.commenter would delete 1 tuples; pass force => true

select * from permissions.apply_model(:'model', p_force => true);   -- deletes the grant, then the relation
```

Use the count in that error message as your signal. The dry-run plan is not a reliable list of removals. In the prototype, the plan omits the `remove ...` rows unless the same change also adds a type (see 6). A dry run never raises `2BP01`. Thus a clean dry run does not mean that the real run will pass without `force`.

**A rename is a drop and an add.** The design has no rename hints. When you rename a relation, the design deletes the grants of the relation (with `force`). Add the new relation. Make the grants again from your own data with `grant_many` (3.9). Then remove the old relation.

**Versions.** Each applied change is a row in `permissions.models` (owner only). Dry runs use version numbers, so the sequence has gaps. `permissions.model()` returns the active definition.

The definition includes the `app` and `tenant` types of the preset. `apply_model()` refuses a definition that contains these types. To roll back to an older version, remove them:

```sql
select version, applied_at, applied_by from permissions.models order by version;

select a.*
from (select definition as d from permissions.models where version = 3) old,
     lateral permissions.apply_model(jsonb_set(old.d, '{types}', (old.d -> 'types') - 'app' - 'tenant')) a;
```

If you apply the active model again, the function returns one row, `unchanged`. If you define `app` or `tenant` yourself, the function raises `22023`. You can name `tenant` as a `parent` (3.5).

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

A second identical grant is harmless. These mistakes raise `22023`:

```sql
select permissions.grant('document', :'acme_plan', 'view', 'user', :'erin');
-- ERROR:  document.view is a permission; grant one of the relations that satisfy it
select permissions.grant('document', :'acme_plan', 'owner', 'user', :'erin');
-- ERROR:  unknown relation document.owner
select permissions.grant('document', :'acme_plan', 'viewer', 'org', :'acme');
-- ERROR:  document.viewer does not accept subjects of type org
```

The design does not know your objects. It accepts a grant on an id that is not in your table, with no error. Check the id first.

**Let end users share.** Clients cannot call `grant`. Put `grant` in a function that runs as the owner. First, the function checks the access of the caller. `permissions.can()` inside a `security definer` function still sees the identity of the caller. The identity comes from the JWT or from the session parameter, not from the current role.

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

RLS needs no change. The `accessible('document', 'view')` arm finds the new grant in the next query.

### 3.3 Groups and nested teams

Groups are usersets. The model says that a relation accepts `team#member`. You grant the members of a team.

```sql
select permissions.grant('team', :'eng',      'member', 'user', :'dave');
select permissions.grant('team', :'platform', 'member', 'team', :'eng', 'member');        -- eng is nested in platform
select permissions.grant('document', :'acme_plan', 'viewer', 'team', :'platform', 'member');

select permissions.can_for('user', :'dave', 'document', :'acme_plan', 'view');            -- true
select permissions.revoke('team', :'platform', 'member', 'team', :'eng', 'member');       -- remove the nest
select permissions.can_for('user', :'dave', 'document', :'acme_plan', 'view');            -- false
```

When you add a member or nest a team, the design takes the global lock. It writes a membership row for each affected user and each group above. When you remove a member or a nest, the design recomputes the affected users. Policies need no change.

- **Depth.** The design accepts a chain of 10 levels. A write that makes an 11th level raises `54001` and leaves nothing behind.
- **Cycles.** The design accepts `eng` in `platform` in `eng`. Each user keeps the shortest path to every group. Nobody outside the cycle gets access. `verify()` stays clean.
- **Other usersets.** You can use any relation as a group if you list it. One example is sharing with every member of an org. This is a model change. It starts `rebuild memberships` (3.1). The implication carries over: an org `admin` implies `member`, so admins are in `org#member`.

```sql
-- document.viewer: ["user", "team#member", "org#member"]
select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'user', :'carol');
select permissions.grant('document', :'acme_plan', 'viewer', 'org', :'acme', 'member');
-- Carol and Alice (admin implies member) can view the plan; Bob cannot
```

### 3.4 Grants that expire

Give `expires_at` to `grant`. An expired grant gives no access in `can`, `accessible` and `who_can`.

```sql
select permissions.grant('document', :'acme_plan', 'viewer', 'user', :'erin', null, now() + interval '7 days');
-- make the time longer, or make the grant permanent, with a new grant:
select permissions.grant('document', :'acme_plan', 'viewer', 'user', :'erin', null, now() + interval '30 days');
select permissions.grant('document', :'acme_plan', 'viewer', 'user', :'erin');            -- no expiry
```

**Group memberships cannot expire.** A grant of a relation that is used as a group raises `0A000` if it has an expiry. A grant of a relation that implies such a relation does the same:

```sql
select permissions.grant('team', :'eng', 'member', 'user', :'erin', null, now() + interval '1 day');
-- ERROR:  grants of team.member change group membership and cannot expire
```

The same rule applies to a model change that would make a current grant that expires feed a group. For example, you add `org#member` to a relation while a grant of `org.member` that expires exists. In this case `apply_model()` raises `22023` until you revoke those grants. If you need team membership with a time limit, run a job that calls `revoke` at the correct time.

Expired rows stay in `permissions.tuples`. The design ignores them. There is no purge function. The owner can delete them directly. This is safe, because grants that expire never feed memberships:

```sql
delete from permissions.tuples where expires_at < now();
```

The design decides expiry at `now()`, the start time of the transaction.

### 3.5 Parent inheritance

A parent link says "this object is under that object". A permission that lists `parent->P` passes `P` down. Whoever has `P` on the parent has `P` on the child. Chains work (document, folder, folder, org). Each object has one parent at most.

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

Set the links. Then make the grants in the usual way:

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

**Two RLS shapes.** Both shapes give the same rows (the tests compare them), with different costs.

*Single branch.* The design returns every visible document id. There is no hand-written arm. The org and folder rules are in the design. This shape needs a parent link for each document.

```sql
create policy documents_select on public.documents for select to authenticated using (
    id = any ((select permissions.accessible('document', 'view'))::uuid[])
);
```

*Projection.* This shape uses shares by id, and a column of your own that points at the parent. Here the design returns only a few folder ids.

```sql
create policy documents_select on public.documents for select to authenticated using (
    id        = any ((select permissions.accessible('document', 'viewer'))::uuid[])   -- direct shares
    or folder_id = any ((select permissions.accessible('folder', 'view'))::uuid[])      -- folders I can view
);
```

`accessible('document', 'viewer')` takes a relation. It returns only the documents that you share directly (no parent expansion). `accessible('folder', 'view')` includes folders that you reach through org roles and through parent folders. A document that is directly in an org has no folder. If you have such documents, add `or org_id = any ((select permissions.accessible('org', 'view'))::uuid[])`.

These are the measurements with 1M documents and about 20,000 visible documents for each user. The setup is PG 18 in Docker, after optimization, 4 clients, p50. The source is [OPTIMIZATIONS.md](../benchmarks/OPTIMIZATIONS.md).

| Shape | First page of 50 | `count(*)` |
| --- | --- | --- |
| Single branch | 4.94 ms | 11.9 ms |
| Projection (two arms) | 1.05 ms | 7.88 ms |

The projection is about 4.7 times cheaper for the page. The single branch builds an array of 20k elements to return 50 rows. Its count does one index descent for each visible id. The count for the projection is at the same minimum heap-read cost that every design reaches on current Postgres releases. In the wide shape (50 teams for each user, 100k documents), the two shapes are close. The single branch takes 8.06 ms and the projection takes 8.73 ms.

An admin of an org with 1M documents gets an array of 1M elements from the single branch in every query. Use the projection for large tenants. The single branch costs one `parents` row for each document. It takes 17.6 s to load 1M links and uses about 160 MB of storage (22 MB to 182 MB).

**Keep the parent link and your column the same.** `set_parent` stores a copy of the data that your table already has. A trigger keeps the two equal. The trigger must run with the privileges of the owner, because `set_parent` is admin-only.

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

When you move a document, the change to who inherits access is immediate. When you move the document back, the access returns.

```sql
select permissions.unset_parent('document', :'acme_readme');   -- true; false if there was no link
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');
```

**Rules and errors.**

- The design rejects a cycle. `set_parent('folder', specs, 'folder', plans)` raises `23514` if `plans` is already under `specs`.
- A chain of more than 10 levels raises `54001`.
- A parent of a type that the model does not list in `parent` raises `22023`.
- A move of a **document** (a leaf) writes one row and takes no lock. A move of a **folder** takes the global lock and rewrites the closure of its sub-folders. A folder is a type that is in some `parent` list (a *container*). The design refuses this move under `repeatable read` (3.10).
- The all-or-nothing rule: if `document.view` contains `parent->view`, every parent type of `document` must define `view`. Each of those types that has a parent must also contain `parent->view`. A model that breaks this rule raises `22023` when you apply it.

**The `tenant` of the preset as a parent.** If you started with the `rbac` preset, objects can inherit the roles that you assign on a tenant. Name `tenant` as a parent. Use the permission names that your roles grant (here `documents.read`; for roles, see the [RBAC guide](../../docs/rbac.md)).

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

`tenant` must define the permission. It does this when a role grants `documents.read`.


### 3.6 Public access

A relation can accept `user:*`, which means every user. Grant it with `grant_public`. This is a separate function. Thus a null id from a failed lookup can never make an object public by accident.

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

The policy is the usual `id = any ((select permissions.accessible('document', 'view'))::uuid[])`. It includes public grants.

**Public means every user with a subject. It does not mean anonymous callers.** The design denies a request with no subject (no JWT `sub` and no `permissions.subject_id`). This includes public documents. To give anonymous reads, add an arm that does not use the design, such as `or is_public`.

**`who_can` returns one null row for public access.** It does not list every user.

```sql
select * from permissions.who_can('document', :'announcement', 'view');   -- Bob, and one NULL row
```

Be careful with membership tests. For a user that only the public row covers, `:'frank'::uuid = any (array(select permissions.who_can(...)))` gives `null`, not `true`. Test for the public row directly:

```sql
select exists (select 1 from permissions.who_can('document', :'announcement', 'view') w where w is null);
```

Other things to know:

- `grant('document', id, 'viewer', 'user', null)` raises `22004`. It never means public.
- `grant_public` on a relation that does not list `user:*` raises `22023`.
- `apply_model()` rejects `user:*` on a relation that feeds a group, with `22023`. It would make every user a group member.
- `grant_public` and `revoke_public` take an optional last argument, the subject type. The default is `user`.
- The null row does not include per-user forbids. A blocked user is not in the concrete rows. But you cannot list the blocked user as an exception to "everyone". A public forbid makes the whole list empty (3.7).

### 3.7 Forbid with `but_not`

A permission can name relations that **veto** it. A forbid is an ordinary grant of such a relation. Thus it is admin-only, like every grant.

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

The policy does not change: `id = any ((select permissions.accessible('document', 'view'))::uuid[])`. Make the scenario. Alice is an org admin. Carol and Dave are in team `eng`. Team `eng` can view `readme`.

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

Check the permission (`view`), not the relation (`viewer`). The forbid vetoes the permission only. A forbid can also name a team. `grant(..., 'blocked', 'team', :'eng', 'member')` blocks every member. A forbid also overrides access that the document inherits from a parent. It does this on that document only:

```sql
select permissions.grant('document', :'acme_readme', 'blocked', 'user', :'alice');
select permissions.can_for('user', :'alice', 'document', :'acme_readme', 'edit');    -- false, though she is an org admin
select permissions.can_for('user', :'alice', 'document', :'acme_plan',   'edit');    -- true
```

**Deny overrides along the whole chain.** A `but_not` relation of permission `P` on an object in the chain vetoes `P` for everything that inherits `P` from that object. In this model a forbid on a *folder* blocks its documents. It blocks them also for a user who has a direct grant on a document:

```sql
select permissions.grant('document', :'acme_readme', 'viewer',  'user', :'erin');
select permissions.grant('folder',   :'specs',       'blocked', 'user', :'erin');
select permissions.can_for('user', :'erin', 'document', :'acme_readme', 'view');   -- false
```

This is Cedar-style. It is not the exact `but not` of OpenFGA. The `but not` of OpenFGA would subtract the `blocked` of the folder from the folder-derived part only. Exclusion relations must be relations of the same type as the permission.

An exclusion cannot be `parent->...`. A forbid for "everyone" (`blocked` accepts `user:*`, and you use `grant_public`) makes `who_can` empty. This includes the public row.

### 3.8 Conditions with RLS

Conditions about the object (a status column, an owner, a date) stay in your policy. Combine them with `accessible()`. The design answers the question "can this user touch this object at all". The policy adds "and is the object in the right state". Grant expiry (3.4) is the one condition that the design holds.

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

Link the documents to their org with `set_parent('document', id, 'org', org_id)`. Grant `org` roles. Then an org member sees published documents. An org editor also sees drafts.

A member whose grant has expired sees nothing. When you publish a draft (`update ... set status = 'published'`), members see it immediately. The update makes no design call.

There is one limit. `can_for` and `who_can` do not know your conditions. `can_for` says true for a draft that RLS hides from that member.

### 3.9 Bulk load with `grant_many`

`grant_many` grants one relation for many (object, subject) pairs in one statement. The function pairs the two arrays by position.

```sql
select permissions.grant_many('team', 'member', 'user',
    array[:'eng', :'eng', :'eng']::uuid[], array[:'bob', :'carol', :'dave']::uuid[]);     -- 3, the new grants
-- the same call again returns 0: pairs that already exist are skipped

-- import a legacy sharing table
select permissions.grant_many('document', 'viewer', 'user', array_agg(document_id), array_agg(user_id))
from public.shares;

-- nests: the last argument is the relation of the subject
select permissions.grant_many('team', 'member', 'team', array[:'platform']::uuid[], array[:'eng']::uuid[], 'member');
```

The function validates the names once. The membership trigger runs once for the whole batch, not once for each grant. A variant of the wide benchmark seed (306k grants) loaded in 7.9 s with five `grant_many` calls. The same load took 27.6 s with one `grant()` for each row on the same database (local PG 16.4).

The memberships were identical. The order did not matter: the load of nests first or members first took 7.1 s and 7.9 s. Set your own limit on the size of the array.

`grant_many` is different from `grant` in these ways:

- It has no `expires_at`.
- It does not overwrite a current grant.
- The call is atomic (one bad pair rolls back everything).
- Arrays of different lengths, or arrays with null elements, raise `22004`.
- Like `grant`, it is admin-only.

### 3.10 Operations

The examples use the quick-start model.

**`verify()` and `rebuild()`.** Memberships and ancestors are derived data. `verify()` recomputes them from the grants with an independent walk. It compares the result to the stored rows. If it returns no rows, there is no drift.

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

`problem` is `missing`, `extra` or `depth N, should be M`. `kind` is `membership` or `ancestor`. Both functions recompute everything. The cost grows with the number of all membership rows. `rebuild()` holds the global lock for its whole run. Use them as maintenance tools, not for each request.

Run `verify()` in these cases:

- You change the `permissions` tables and the triggers do not run. This happens with direct DML, `session_replication_role = replica`, `pg_restore --disable-triggers`, and logical replication that copies some of the tables but not all of them.
- You restore a backup or clone a database partially.
- On a schedule. Send an alert if it returns a row (`select count(*) from permissions.verify()`). This is the safety net for bugs in the write path that no test covered.

If `verify()` reports drift, call `rebuild()`.

**The lock.** Each write that changes memberships or the container closure takes `pg_advisory_xact_lock(1885697139, 1)`. These writes are: userset grants and revokes, `set_parent`, `unset_parent` and `forget_object` on a container, `rebuild()`, and model changes that start a rebuild. The design holds the lock **until the transaction ends**. Keep permission writes in short transactions. These operations do not take the lock: object grants and revokes, the move of a document, and grants that expire.

```sql
begin;
select permissions.grant('team', :'eng', 'member', 'user', :'erin');
select count(*) from pg_locks
where locktype = 'advisory' and classid = 1885697139 and objid = 1 and pid = pg_backend_pid();   -- 1
commit;
```

**Isolation levels, for ORMs.** Under `repeatable read`, the snapshot is fixed before the design takes the lock. Thus the committed rows of a concurrent writer would stay invisible, and the derived rows would drift. The design refuses with `0A000`:

| Level | Membership and container writes | Object grants |
| --- | --- | --- |
| `read committed` (Postgres default) | Accepted | Accepted |
| `repeatable read` | **Refused, `0A000`** | Accepted |
| `serializable` | Accepted. If two writers conflict, one of them fails with `40001`. Retry the write. | Accepted |

```sql
begin isolation level repeatable read;
select permissions.grant('team', :'eng', 'member', 'user', :'frank');
-- ERROR:  pg_permissions: group membership and parent changes are not allowed in repeatable read transactions
-- HINT:  Run this write in read committed (the default) or serializable.
rollback;
```

Your framework or connection pool can set `repeatable read` globally. In this case, run permission writes on a connection or a role that uses `read committed`. For example, run `alter role app_admin set default_transaction_isolation = 'read committed'`. Or start the transaction with `set transaction isolation level read committed` before its first query.

The same rule applies to `set_parent` on a folder. `apply_model()` takes the lock and does not check the isolation level. But a rebuild inside it raises `0A000` under `repeatable read`. Apply models in `read committed`.

### 3.11 Graduate from the rbac preset

An app that started with the `rbac` preset (see the [RBAC guide](../../docs/rbac.md)) can add per-object sharing. Make one `apply_model()` call that contains only the own types of the app. The design keeps the `app` and `tenant` types of the preset. Thus roles and assignments stay the same. Every preset answer stays the same.

```sql
-- before: roles, assignments, and a policy on the tenant column
select permissions.assign_role(:'alice', 'admin',  :'acme');
select permissions.assign_role(:'bob',   'editor', :'acme');
create policy documents_select on public.documents for select to authenticated using (
    permissions.has_permission('documents.read', org_id)
);

-- move up: add the document type
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

-- the policy has one more arm
drop policy documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated using (
    org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
    or id  = any ((select permissions.accessible('document', 'view'))::uuid[])
);
```

Dave sees only the shared document. Bob still sees everything that his roles give him. To let preset roles flow down to folders and documents, use `tenant` as a parent (3.5). Each `create_role` or `drop_role` creates a model version. Thus create roles in migrations, not for each request.

### 3.12 Clean up

There are no foreign keys to your tables. Thus a deleted user or object leaves grants behind unless you clean up. These calls work with any model.

```sql
select permissions.forget_subject(:'erin');                  -- grants to Erin, returns how many
select permissions.forget_object('document', :'acme_plan');  -- grants on the object and grants to its usersets
```

`forget_subject(uuid)` deletes every grant where the principal is the subject. If these grants include team memberships, the design updates the derived memberships under the lock. `forget_object(type, id)` deletes three things: the grants on the object, the grants whose subject is one of its usersets, and its parent link. Thus `forget_object('team', eng)` also removes the access that you gave to `team:eng#member`. For a container, its children become roots. The design rewrites the closure under the lock.

To do this on delete, attach the trigger functions that the extension includes to your tables. They read the id column from the deleted row. They use no dynamic SQL.

```sql
create trigger profiles_permissions_cleanup after delete on public.profiles
    for each row execute function permissions.on_subject_deleted('id');
create trigger documents_permissions_cleanup after delete on public.documents
    for each row execute function permissions.on_object_deleted('document', 'id');
```

The design revokes execute on these functions from public. Thus only roles that you trust can attach them. The id column must hold a uuid. The functions return `old`, so they work as `AFTER DELETE` row triggers.

### 3.13 Non-uuid app keys

Every id that the design sees is a `uuid`. This includes the user id. The design treats a JWT `sub` that is not a uuid as no subject, so every check is false. If your keys are `bigint` or `text`, you have two options.

**Derive a uuid from the key.** `md5(...)::uuid` is deterministic and is part of Postgres. Put the type before the key, so that different kinds of object cannot collide. The design assumes that ids are unique across principal types. A generated column keeps the uuid next to the key. It also lets RLS compare uuids without casts:

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
-- identify the caller in the same way (your auth layer sets this for each request)
select set_config('permissions.subject_id', md5('user:' || 42)::uuid::text, true);
```

**Keep a mapping table** if you do not want the ids to be a function of the key. An example is a case where keys can be used again:

```sql
create table public.perm_keys (key text primary key, id uuid not null unique default gen_random_uuid());
create function public.perm_id(p_key text) returns uuid language sql as $$
    insert into public.perm_keys (key) values (p_key) on conflict (key) do update set key = excluded.key
    returning id $$;
```

Convert the md5 result with `::uuid::text` before you put it in `permissions.subject_id` or in a JWT `sub`. Plain `md5()` output has no dashes. The design treats a subject that is not a uuid with dashes as no subject. In both cases, make an index on the uuid column that you compare.


## 4. API reference

All functions are in schema `permissions`. "Admin" means the owner of the extension, or any role that you give execute to (for example `service_role`). "Client" means that `authenticated` and `anon` can call the function. For the privilege model, see the [function reference](../../docs/reference.md).

The list of installed functions comes from `pg_proc` (names that do not start with an underscore). It has 33 signatures and 31 names. `has_permission` and `has_role` each have a text-scope form and a uuid-scope form.

| Function | Caller | Volatility | Purpose |
| --- | --- | --- | --- |
| [`apply_model`](#apply_model) | admin | volatile | Compile a model |
| [`model`](#model) | admin | stable | Get the active definition |
| [`can`](#can) | client | stable | Test if the current subject has a permission on an object |
| [`accessible`](#accessible) | client | stable | Get the ids on which the current subject has a permission |
| [`current_subject_id`](#current_subject_id), [`current_subject_type`](#current_subject_type) | client | stable | Identify the caller |
| [`can_for`](#can_for) | admin | stable | `can` for any subject |
| [`accessible_for`](#accessible_for) | admin | stable | `accessible` for any subject |
| [`who_can`](#who_can) | admin | stable | Get the subjects that have a permission on an object |
| [`grant`](#grant) | admin | volatile | Grant a relation |
| [`grant_many`](#grant_many) | admin | volatile | Bulk grant |
| [`revoke`](#revoke) | admin | volatile | Remove a grant |
| [`grant_public`](#grant_public), [`revoke_public`](#revoke_public) | admin | volatile | Public (`type:*`) grants |
| [`set_parent`](#set_parent), [`unset_parent`](#unset_parent) | admin | volatile | Parent links |
| [`forget_subject`](#forget_subject), [`forget_object`](#forget_object) | admin | volatile | Remove everything about a subject or an object |
| [`on_subject_deleted`](#on_subject_deleted), [`on_object_deleted`](#on_object_deleted) | admin (attach) | volatile | Cleanup trigger functions |
| [`verify`](#verify) | admin | stable | Detect drift in derived data |
| [`rebuild`](#rebuild) | admin | volatile | Recompute derived data |
| [`create_role`](#rbac-preset-functions), [`drop_role`](#rbac-preset-functions), [`assign_role`](#rbac-preset-functions), [`unassign_role`](#rbac-preset-functions) | admin | volatile | `rbac` preset: roles |
| [`has_permission`](#rbac-preset-functions), [`has_role`](#rbac-preset-functions), [`scopes_with_permission`](#scopes_with_permission) | client | stable | `rbac` preset: checks |
| [`user_permissions`](#rbac-preset-functions), [`users_with_role`](#rbac-preset-functions) | admin | stable | `rbac` preset: debug tools |

A client gets `42501` (permission denied) from an admin function. A client cannot read the tables. Each function except the two identity functions is `security definer`. All functions set an empty `search_path`.

**Reads never raise an error for unknown names.** `can`, `accessible`, `can_for`, `accessible_for` and `who_can` return false, an empty array or no rows for an unknown type or permission. Thus a policy that names a dropped permission denies access. It does not break every query.

It also means that a typo in a policy fails with no error. Test your policies. Writes validate everything and raise errors.

### The model JSON

This is the grammar, with every key. `{...}` is an object. `[...]` is an array of strings.

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

Type names match `^[a-z][a-z0-9_]{0,62}$`. Relation and permission names match `^[a-z][a-z0-9_.]{0,62}$`. You can use dots, so `documents.read` works. Subjects match `^[a-z][a-z0-9_]{0,62}(#[a-z][a-z0-9_.]{0,62}|:\*)?$`.

| Key | Description |
| --- | --- |
| `types` | This object is necessary. The design rejects unknown keys inside a type. |
| `principal` | `true` marks the type as end subjects (what `current_subject_id()` identifies). The design assumes that uuids are unique across principal types. If you omit `user`, the design adds it with `principal: true`. If you include it, it must be a principal. |
| `parent` | The types that an object of this type can have as its parent, set with `set_parent`. Parent types must exist and must not be principals. A type that is in some `parent` list is a **container**. |
| `relations` | What the design can grant, and to whom. Each list must have an item. A plain subject must be a principal type. A `type#relation` subject makes that relation a **userset** (group). `relation` must be a relation of `type`, not a permission. `type:*` is public access, and `type` must be a principal. |
| `implies` | A holder of the key relation also satisfies the listed relations. The relations are of the same type. They must be relations, not permissions. The rule is transitive. The design rejects a cycle. |
| `permissions` | Named checks. You cannot grant them. They cannot list other permissions. |
| `any` | The items that satisfy the permission. At least one item is necessary. |
| `but_not` | Relations of the same type that veto the permission. Do not use `parent->` here. |
| `parent->P` | Valid only inside a permission with the name `P`, on a type that has `parent`. |

`apply_model()` raises `22023` in these cases. The message names the items that cause the error.

- The definition is not an object with a `types` object. Or a name is not valid, a type has unknown keys, or a value has the wrong shape.
- A name is both a relation and a permission on the same type. The preset uses this rule to make sure that role names and permission names do not overlap.
- A relation has an empty subject list. Or a subject names an unknown type, a non-principal type without `#`, an unknown relation after `#`, or `type:*` on a non-principal type.
- `implies` names an item that is not a relation of the same type, or has a cycle.
- A `parent` names an unknown type or a principal type.
- A permission item is not a relation of the same type or `parent->P`, or a permission has no `any` item. For `parent->P`, `P` must be the name of the permission itself, on a type that has `parent`.
- **Inheritance is not all-or-nothing.** `X.P` contains `parent->P`, but some parent type of `X` does not define `P`. Or the parent type defines `P` and has parents itself, but does not contain `parent->P`.
- `type:*` is on a relation that feeds a userset. Every user would become a group member, and the design cannot materialize this.
- A current grant that expires would start to feed a userset.
- The definition defines or redefines `app` or `tenant`, or defines `user` without `principal: true`.

It raises `2BP01` if the apply would delete grants or parent links and `p_force` is false. This happens for a removed type, a removed relation or a narrower subject list.

### Functions

#### apply_model

```sql
permissions.apply_model(p_definition jsonb, p_dry_run boolean default false, p_force boolean default false)
  returns table (change text, detail text)
```

Admin. The function validates the model, compiles it, rebuilds derived data if necessary and records a new version. It returns the plan. The plan has these rows: `add type`, `add relation`, `add permission`, `remove type`, `remove relation`, `remove permission`, `change principal`, `change <kind> to <kind>`, `delete tuples`, `delete parent links`, `rebuild memberships`, `rebuild ancestors`, then `version | N`.

With `p_dry_run`, the last row is `dry run | nothing was changed`, and the function changes nothing. An identical definition returns `unchanged | version N`. The function keeps `app` and `tenant` from the active model, and it adds `user` if it is not there. It takes the global lock when the definition changed. See 3.1.

Errors:

- `22023`.
- `2BP01` (needs force).
- `0A000` (a rebuild is necessary under `repeatable read`).
- `54001` (a rebuild finds a nest of more than 10 levels).

```sql
select * from permissions.apply_model(:'model', p_dry_run => true);
```

#### model

```sql
permissions.model() returns jsonb
```

Admin. Returns the active definition. The definition includes the `app` and `tenant` types of the preset. Remove those types before you pass the definition back to `apply_model`.

```sql
select permissions.model() -> 'types' -> 'document';
```

#### can

```sql
permissions.can(p_object_type text, p_object_id uuid, p_permission text) returns boolean
```

Client. Tests if the current subject has the permission, or the relation, on the object. The result is true when some grant gives access and no forbid vetoes it. The grant can be direct, through a group, public, or from a parent.

The result is false for no subject, a null id, or an unknown type or name. It is one indexed query. Use it for single-row checks (`update` policies, `with check`). The permission argument also accepts a relation: `can('document', id, 'viewer')`.

```sql
select permissions.can('document', :'acme_readme', 'edit');
```

#### accessible

```sql
permissions.accessible(p_object_type text, p_permission text) returns uuid[]
```

Client. Returns every id of the type on which the current subject has the permission. The ids are sorted and distinct, and the forbids are removed. A grant on a container expands to the objects below it.

This applies to permissions with `parent->`. A relation name does not expand. The result is empty for no subject or an unknown name. This is the RLS fast path, in the form `id = any ((select permissions.accessible('document', 'view'))::uuid[])`. The array can be large for a user who sees most of a table (3.5).

```sql
select cardinality(permissions.accessible('document', 'view'));
```

#### current_subject_id

```sql
permissions.current_subject_id() returns uuid
```

Client. Returns the JWT `sub` if there is one. Otherwise it returns the `permissions.subject_id` parameter, or null. A value that is not a uuid gives null. The JWT has priority. For details, see the [RLS guide](../../docs/rls.md).

```sql
select set_config('permissions.subject_id', :'bob', false);
select permissions.current_subject_id();   -- bob
```

#### current_subject_type

```sql
permissions.current_subject_type() returns text
```

Client. Returns the `permissions.subject_type` parameter. The default is `'user'`. It is important only if you have more than one principal type.

#### can_for

```sql
permissions.can_for(p_subject_type text, p_subject_id uuid, p_object_type text, p_object_id uuid, p_permission text) returns boolean
```

Admin. `can` for any subject. It is admin-only, because it would let a client ask about other users. A null subject or object gives false.

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

Admin. Returns the principals that have the permission on the object, through direct grants, groups and parents, minus the vetoed principals. **A public grant is one `null` row.** It means every principal of the type of the grant.

The function never lists the users. The null row does not include per-principal forbids. A public forbid makes the list empty. The function ignores expired grants. Use `is null` to test for the public row (3.6).

```sql
select * from permissions.who_can('document', :'acme_readme', 'view');
```

#### grant

```sql
permissions.grant(p_object_type text, p_object_id uuid, p_relation text, p_subject_type text, p_subject_id uuid,
                  p_subject_relation text default null, p_expires_at timestamptz default null) returns void
```

Admin. Grants a relation on an object to a principal. If `p_subject_relation` is given, it grants the relation to a userset (an empty string counts as null). If the grant exists, the call updates its expiry (a null expiry makes it permanent). Otherwise the call does nothing. It takes the global lock when the relation feeds a group.

Errors:

- `22023` (unknown type or relation, the name is a permission, or the relation does not accept this subject).
- `22004` (null object id or subject id).
- `0A000` (an expiry on a relation that feeds a group, or `repeatable read` when the lock is necessary).
- `54001` (a nest of more than 10 levels).

```sql
select permissions.grant('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');
```

#### grant_many

```sql
permissions.grant_many(p_object_type text, p_relation text, p_subject_type text,
                       p_object_ids uuid[], p_subject_ids uuid[], p_subject_relation text default null) returns bigint
```

Admin. Bulk `grant`. It pairs `p_object_ids[i]` with `p_subject_ids[i]`. It returns the number of new grants. It skips pairs that exist, it has no expiry, and the whole call is atomic. See 3.9.

Errors:

- `22023` as for `grant`.
- `22004` (different lengths or null elements).
- `0A000` and `54001` from the lock rules and depth rules.

```sql
select permissions.grant_many('team', 'member', 'user', array[:'eng', :'eng']::uuid[], array[:'bob', :'carol']::uuid[]);
```

#### revoke

```sql
permissions.revoke(p_object_type text, p_object_id uuid, p_relation text, p_subject_type text, p_subject_id uuid,
                   p_subject_relation text default null) returns boolean
```

Admin. Removes one grant. Returns true if the grant existed. Unknown names raise `22023`. It takes the global lock when the relation feeds a group (the design recomputes the affected users).

```sql
select permissions.revoke('document', :'acme_readme', 'viewer', 'team', :'eng', 'member');
```

#### grant_public

```sql
permissions.grant_public(p_object_type text, p_object_id uuid, p_relation text, p_subject_type text default 'user') returns void
```

Admin. Grants the relation to every principal of the subject type. The relation must list `type:*`. If it does not, the function raises `22023`.

```sql
select permissions.grant_public('document', :'announcement', 'viewer');
```

#### revoke_public

```sql
permissions.revoke_public(p_object_type text, p_object_id uuid, p_relation text, p_subject_type text default 'user') returns boolean
```

Admin. Removes the public grant. Returns true if it existed.

#### set_parent

```sql
permissions.set_parent(p_object_type text, p_object_id uuid, p_parent_type text, p_parent_id uuid) returns void
```

Admin. Sets or moves the parent of the object (one parent for each object). For a container, it takes the global lock and rewrites the closure of the sub-folders. A move of a leaf takes no lock.

Errors:

- `22004` (null id).
- `22023` (the model does not accept that parent type).
- `23514` (the new parent is the object or one of its descendants).
- `54001` (a chain of more than 10 levels).
- `0A000` (a container move under `repeatable read`).

```sql
select permissions.set_parent('document', :'acme_readme', 'folder', :'specs');
```

#### unset_parent

```sql
permissions.unset_parent(p_object_type text, p_object_id uuid) returns boolean
```

Admin. Removes the parent link. Returns true if there was a link. It takes the lock for a container.

#### forget_subject

```sql
permissions.forget_subject(p_subject_id uuid) returns bigint
```

Admin. Deletes every grant to the principal and returns the number of grants. Membership changes follow under the lock. It takes only the id, not a type. Thus ids must not collide across types.

```sql
select permissions.forget_subject(:'erin');
```

#### forget_object

```sql
permissions.forget_object(p_object_type text, p_object_id uuid) returns bigint
```

Admin. Deletes the grants on the object, the grants to its usersets and its parent link. It returns the number of grants that it deleted. For a container, its children become roots, and the design rewrites the closure.

```sql
select permissions.forget_object('document', :'acme_plan');
```

#### on_subject_deleted

```sql
permissions.on_subject_deleted() returns trigger        -- argument: the id column name
```

Trigger function, for `AFTER DELETE ... FOR EACH ROW` on your users table or profiles table. It calls `forget_subject`. The design revokes execute from public, so the role that creates the trigger needs execute. The column must hold a uuid.

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

Admin. Recomputes memberships and the ancestor closure from the grants and parent links. It compares them to the stored rows. No rows means no drift.

`kind` is `membership` or `ancestor`. `set_key` is `type:id#relation` for memberships and `type:id` for ancestors. `problem` is `missing`, `extra` or `depth N, should be M`. The function is read-only, but its cost is O(all memberships).

```sql
select * from permissions.verify();
```

#### rebuild

```sql
permissions.rebuild() returns bigint
```

Admin. Deletes and recomputes `memberships` and `ancestors`. Returns the number of rows that it wrote. It takes the global lock for the whole run.

Errors:

- `0A000` under `repeatable read`.
- `54001` if the grants contain a nest of more than 10 levels.

```sql
select permissions.rebuild();
```

#### scopes_with_permission

```sql
permissions.scopes_with_permission(p_permission text, p_unfold boolean default permissions._unfolded_null()) returns text[]
```

Client. `rbac` preset: returns the tenant ids on which the current subject has the permission, as text. **Do not give the second argument.** The function ignores it. It exists so that Postgres cannot evaluate the call at plan time.

The planner evaluates a STABLE function with constant arguments, and then the call would run twice for each query. If you give both arguments as constants, the planner folds the call again. Use it in policies as 3.11 shows: `org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))`. The function has two arguments. Thus a grant must name the two-argument signature.

#### rbac preset functions

The `rbac` preset has the same signatures on every design, and it works in the same way. Its reference is in the [RBAC guide](../../docs/rbac.md). These are the notes for design C:

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

- The preset takes **text** ids for users and scopes (the same signatures as the other designs) and casts them to uuid. A text id that is not a uuid raises `22P02` on writes (`assign_role`). On reads, it gives false or empty. The `uuid` overloads of `has_permission` and `has_role` let a policy pass a `uuid` column without a cast.
- Each `create_role` and `drop_role` applies a new model version. `create_role` raises `23505` if the role exists. `drop_role` raises `2BP01` while another role inherits the role. It raises `22023` if the role does not exist. It also deletes the assignments of the role.
- `assign_role` raises `22023` for an unknown role. `unassign_role` ignores an unknown role.
- Roles are on the preset types `app` (app-wide, one object with the nil uuid) and `tenant` (one object for each scope). You cannot define these types in your own model. But your types can name `tenant` as a parent (3.5).

```sql
select permissions.create_role('editor', '{documents.edit}', '{viewer}');
select permissions.assign_role(:'bob', 'editor', :'acme');
select permissions.has_permission('documents.edit', :'acme'::uuid);   -- as Bob
```

### Tables

Ten tables hold the model and the data. All tables have `revoke all from public` and row level security with no policies. Thus clients cannot read them. The owner can read them to debug, and the specs do this. For all other tasks, use the functions.

| Table | Contents |
| --- | --- |
| `models` | One row for each applied version: the full `definition`, `applied_at` and `applied_by`. The latest row is the active row. |
| `types` | One row for each type, with a stable `smallint` id and the `principal` and `container` flags. |
| `relations` | One row for each relation or permission: `kind`, `is_userset` and `feeds_userset`. |
| `allowed_subjects` | The compiled subject lists of each relation. |
| `parent_types` | The compiled `parent` lists. |
| `satisfies` | The compiled relation axis. It shows which relations satisfy or veto which permission, on the object or through an ancestor. |
| `tuples` | One row for each grant. A null `subject_id` means a public grant. The table is immutable except for `expires_at`. `truncate` is blocked. |
| `parents` | One row for each object that has a parent. |
| `memberships` | Derived. Each principal in each group that it belongs to, transitively, with the shortest depth. |
| `ancestors` | Derived. Container to ancestors. Only containers have rows. |

### SQLSTATE summary

| SQLSTATE | Raised by | Description |
| --- | --- | --- |
| `22023` | `apply_model`, `grant`, `revoke`, `grant_public`, `set_parent`, preset functions | Invalid model, unknown name, or a subject or parent that the model does not accept |
| `22004` | `grant`, `grant_many`, `set_parent` | Null id or array element |
| `22P02` | preset functions | A text id that is not a uuid |
| `2BP01` | `apply_model`, `drop_role` | Needs `force`, or another role still inherits the role |
| `0A000` | `grant`, `revoke`, `set_parent`, `rebuild`, `apply_model` | `repeatable read` for a write that takes the lock; an expiry on a group grant |
| `23514` | `set_parent`, raw inserts | Parent cycle; a tuple that does not match the model |
| `54001` | group and parent writes, `rebuild` | Depth of more than 10 levels |
| `55000` | direct DML on `tuples` | Updates (other than `expires_at`) and `truncate` |
| `23505` | `create_role` | The role already exists |
| `40001` | any write that takes the lock, under `serializable` | Serialization failure. Retry the write. |
| `42501` | a client that calls an admin function or reads an admin table | Permission denied |


## 5. Performance notes

All figures are from [`../benchmarks/OPTIMIZATIONS.md`](../benchmarks/OPTIMIZATIONS.md). The setup is PostgreSQL 18.6 in Docker, after the session 3 optimizations, 4 pgbench clients, p50, one laptop. "Large" is 1M documents, 10k users and 500 teams. "Wide" is a medium-scale shape with 50 teams for each user.

[`VERSIONS.md`](../benchmarks/VERSIONS.md) has the same matrix on PG 16 and 17, with the same order. Absolute numbers will be different on your hardware. Read them as relative costs.

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

**The wide-read lead.** The reads of C change little with the group shape. `share_select_page` takes 0.66 ms in the deep shape (teams nested 9 levels) and 8.20 ms in the wide shape. On wide, A takes 14.4 ms and B takes 17.8 ms.

The lead of C over A was 12 times. It is now 1.8 times, because A was optimized. `share_list_objects` on wide takes 3.41 ms (A 4.44, B 8.41).

**Single-branch parents.** The single-branch policy returns every visible document id. At large, a page takes 4.94 ms and a count takes 11.9 ms (A 45.6 and 75.1 ms, B 13.7 and 21.6 ms). This is the cheapest single-branch implementation of the three. But the two-arm projection is still about 4.7 times cheaper for the page (1.05 ms). Use the projection for large tenants (3.5).

**Expensive in C**

| Operation | Cost |
| --- | --- |
| Nest a 1,000-member team (`write_nest_team`, large, 4 clients) | **57.7 ms**, 67 tps. Deep: 75.1 ms. Wide: 61.2 ms. |
| The same, one client (local PG 16.4, earlier measurement) | About 15.5 ms. The figure for 4 clients is about 4 times more, because concurrent writers wait in the queue for the global lock. |
| Remove a nest (recompute the affected users) | A nest and then a removal of the nest of the 1,000-member team took 25 to 30 ms at large (local PG 16.4). Deletes recompute the users. They are not a delta. |
| `grant()` of a membership | About 0.1 ms (trigger, transition table, one delta statement). An object grant takes about 0.04 ms. Local PG 16.4. |
| Seed of wide sharing with one `grant()` for each row (306k grants) | 24.7 s (A 5.9 s, B 12.6 s). With `grant_many`, about 8 s, local. |
| Parent links for 1M documents | 17.6 s, +160 MB |

A nest writes `members x (1 + groups above)` rows under the lock. The nest of the benchmark writes 5,000 rows, and the insert takes about 10 ms of the time. This is the minimum cost of materialized memberships. A lock for each key would not change this benchmark, because every nest touches the same members. The design does not have such a lock.

Size the concurrency. One lock serializes every membership write and container write. Thus 67 nests each second is the limit for nests of team size. A directory sync that nests many teams at the same time waits in a queue behind itself.

Plain object grants, document moves and RBAC role assignments are not affected. C misses only two budgets. `write_nest_team` has a p95 of 64 to 115 ms against a budget of 1 ms. `parents_proj_select_count` is missed by every design (about 8 ms, the minimum heap-read cost).

**Storage.** At large, after the parents seed, C uses 182 MB (A 404 MB, B 378 MB). In the wide shape, C uses the most, 191.6 MB (A 97 MB, B 105 MB). The reason is that the design stores memberships for each user. 100k users in 50 groups is 5M rows.

**Planner notes for your own policies.**

- Use the `(select accessible(...))::uuid[]` form. The test used 1M documents and a user with 300 grants, on a busy machine. Read the ratios. For a page of 50, this form takes 0.36 to 0.48 ms. The alternatives are: 0.55 to 0.7 ms for `array(select unnest(...))`, 47 ms for `id in (select unnest(...))`, and an error for `id = any ((select f()))`.
- The planner does not evaluate `scopes_with_permission` and `accessible` at plan time in the policy forms that this page shows. The plan time stays under 0.3 ms.
- Use `can()` for single-row checks only. In a `select` policy, it runs once for each row.

## 6. Warnings and limits

**Write path and concurrency**

- **One global lock** for every membership change, container move and rebuild. Bulk directory syncs (SCIM) and concurrent team edits wait in a queue behind it. The design holds the lock until the transaction ends. Thus a long transaction that touches a group blocks all other group writes.
- **The design refuses `repeatable read`** (`0A000`) for those writes. This surprises ORMs and poolers that set it by default (3.10).
- **The latency is in your transaction.** A write that nests a team of 10,000 members writes more than 10,000 rows synchronously. There is no background worker.
- **A model change that touches groups rebuilds all memberships** under the lock, in one transaction.
- **Deletes recompute.** When you revoke a membership or a nest, the design recomputes each affected user from the start.

**Model and data**

- **The maximum depth is 10** for group nests and for parent chains (`54001`). The design rejects parent cycles. It accepts group cycles.
- **IDs are uuid only.** Uuids must not collide across principal types (`memberships` and `forget_subject` use the uuid alone as the key). Object ids must be unique for each type.
- **The design does not know your objects.** It accepts a grant on an id that is not in your table. Nothing removes the grant when the row goes away, unless you attach the cleanup triggers (3.12).
- **Parent links duplicate your data.** You must keep the `folder_id` of the app and `set_parent()` the same (3.5 shows a trigger). Each object has one parent.
- **`apply_model` replaces the model.** If you leave a type out, the design removes it. A rename is a drop and an add. With force, it deletes grants.
- **Inheritance is all-or-nothing** along a hierarchy. `parent->P` must have the same name `P` at every level.
- **Forbid is deny-overrides.** It is not the exact `but not` of OpenFGA. Exclusion relations are relations of the same type only. The forbid vetoes the permission, not the relation. The null row in `who_can` does not include per-user forbids.
- **Group memberships cannot expire.** The design rejects them on write and when you apply a model. It does not give wrong results silently.
- **No provenance.** Memberships say that Carol is in `platform`. They do not say why. `explain()` is not built. No function tells you why a check is true or false.
- **No policy generation, rename hints or per-key locks.**
- **No function lists raw grants.** `who_can` returns principals. `accessible` returns ids. To list the grants on an object, read `permissions.tuples` as the owner.

**Reads**

- **Unknown names return false or empty.** A typo in a policy denies everything and raises no error. Run each policy as a test user.
- **The design denies a request with no subject.** This includes public documents.
- **`accessible()` can return a very large array** for a user who sees most of a table. `count(*)` does one index probe for each id.
- **`can_for` and `who_can` do not apply your RLS conditions** (such as status columns). They also do not apply org arms that are only in your policy.
- **Do not give the second argument of `scopes_with_permission`.**
- **Checks are not compiled SQL.** They use generic PL/pgSQL functions. Thus the gains are no recursion and typed keys.

**Plan output (prototype quirk).** The plan that `apply_model` returns can omit rows. In the prototype, the plan omits the `remove ...` rows, unless the same change also adds a type or a relation. If no relation is added, the plan also omits the `add type` rows.

The reason is that the code that appends additions to the plan array resets the array when there is nothing to add. The changes themselves are not affected. The `rebuild`, `delete` and `version` rows are not affected. Use the `2BP01` message to find what `force` would delete.

For the comparison with the other designs and the open questions (uuid-only keys, the global lock, `repeatable read`), see [`../decision.md`](../decision.md).
