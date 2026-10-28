# Design A: Shared tuple core (Zanzibar-first)

> One of three candidate designs. See [../PLAN.md](../PLAN.md) for the shared goals, requirements and evaluation criteria.

**Summary:** every model is stored as Zanzibar-style relationship tuples in one generic table with `text` IDs. Decisions are computed at read time by a recursive CTE. Attribute rules, CEL and Cedar come later as a policy layer on top of the same store.

## 1. Core idea

The four earlier RFCs all store "subject is related to object" in some form: Zanzibar tuples, Cedar parents, ABAC role assignments. A tuple `(object_type, object_id, relation, subject_type, subject_id[, subject_relation])` can represent all of them. So the extension has one fact table and one evaluator, and RBAC is just ReBAC on an org object.

Why this might be the right call:

- It's the smallest possible core: four tables and one recursive query.
- It's proven. SpiceDB and OpenFGA use the same model, so developers can bring existing FGA knowledge.
- Writes are cheap and simple: one row per grant, nothing to recompute.

## 2. Core schema

Everything lives in a `permissions` schema. IDs are `text` so the extension works with UUIDs, integers or external IDs.

```sql
-- Which object types exist (user, team, org, document, ...)
create table permissions.object_types (
    name text primary key,
    description text
);

-- How relations on a type relate to each other (the "model definition")
create table permissions.relations (
    object_type text not null references permissions.object_types(name) on delete cascade,
    relation    text not null,
    implied_by  text[] not null default '{}',  -- e.g. viewer implied_by {editor}
    from_parent text[] not null default '{}',  -- v0.0.2: inherited from the parent's relation (§12.1)
    unless      text[] not null default '{}',  -- v0.0.2: excluded by these relations (§12.3)
    description text,
    primary key (object_type, relation)
);

-- Relationship tuples: the core fact table shared by every model
create table permissions.tuples (
    id               bigint generated always as identity primary key,
    object_type      text not null,
    object_id        text not null,
    relation         text not null,
    subject_type     text not null,
    subject_id       text not null,
    subject_relation text not null default '',  -- '' = direct; 'member' = userset team:eng#member
    condition        jsonb,                     -- Model 3, null = unconditional
    expires_at       timestamptz,
    created_at       timestamptz not null default now(),
    foreign key (object_type, relation) references permissions.relations(object_type, relation),
    unique (object_type, object_id, relation, subject_type, subject_id, subject_relation)
);

create index on permissions.tuples (subject_type, subject_id, subject_relation);  -- forward expansion (list_objects, check)
create index on permissions.tuples (object_type, object_id, relation);            -- reverse expansion (list_subjects)

-- Optional attributes for any entity (Model 3, and later Cedar/ABAC/CEL)
create table permissions.entities (
    entity_type text not null,
    entity_id   text not null,
    attributes  jsonb not null default '{}',
    primary key (entity_type, entity_id)
);
```

Notes:

- `subject_relation` defaults to `''` instead of `null` so the unique constraint works. With `null`, Postgres would allow duplicate tuples.
- The `relations` foreign key catches typos: you can't grant a relation that isn't defined.
- Tuples with a non-null `condition` are ignored (default deny) until Model 3 is implemented.

## 3. Linking to identity

The extension never stores users. It only needs to know **who the current subject is** and **what their ID is**.

### Resolving the current subject

`permissions.current_subject_id()` (STABLE) checks these in order and uses the first that is set:

1. `current_setting('request.jwt.claims', true)::jsonb ->> 'sub'`: the standard PostgREST claim. This is what Supabase's `auth.uid()` reads, so Supabase works with no configuration and no dependency on the `auth` schema.
2. `current_setting('permissions.subject_id', true)`: set explicitly by the app on plain Postgres, in tests, or in server-side jobs (`set local permissions.subject_id = '...'`).

The JWT comes first so that, when a request carries a JWT, nothing else in the session can override who the subject is.

`permissions.current_subject_type()` defaults to `'user'`, overridable with `permissions.subject_type`.

Every check has an explicit-subject variant (`check_for`, `list_objects_for`) for tests and server-side jobs. Those are admin-only: if clients could call them, any user could ask what any other user can access.

### Keeping tuples in sync with an identity table

There is deliberately no foreign key to `auth.users` or any other users table, because that would couple the extension to one identity source. The README will document a recipe instead:

```sql
-- Supabase example: remove a user's tuples when the user is deleted
create function public.on_auth_user_deleted() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform permissions.delete_subject('user', old.id::text);
  return old;
end $$;

create trigger on_auth_user_deleted after delete on auth.users
for each row execute function public.on_auth_user_deleted();
```

The same pattern works for any users table, Supabase or not.

## 4. Public API (v0.0.1)

Model definition:

```sql
permissions.define_type(name text, description text default null)
permissions.define_relation(object_type text, relation text, implied_by text[] default '{}',
                            from_parent text[] default '{}', unless text[] default '{}')  -- last two: v0.0.2, §12
```

Writing tuples:

```sql
permissions.grant(object_type, object_id, relation, subject_type, subject_id, subject_relation default '', expires_at default null)
permissions.revoke(object_type, object_id, relation, subject_type, subject_id, subject_relation default '')
permissions.delete_subject(subject_type, subject_id)   -- removes all tuples for that subject
permissions.delete_object(object_type, object_id)      -- removes all tuples on that object

-- v0.0.2 (§12.1): parents
permissions.set_parent(object_type, object_id, parent_type, parent_id)  -- replaces the parent; null clears it
permissions.sync_parent()  -- trigger function: keeps parent tuples in sync with an app column
```

Checks (STABLE, SECURITY DEFINER, `set search_path = ''`):

```sql
-- Client-facing: always the current subject
permissions.check(object_type, object_id, relation) returns boolean
permissions.list_objects(object_type, relation) returns text[]      -- RLS fast path

-- Admin only (execute revoked from public): explicit subject, or who has access
permissions.check_for(subject_type, subject_id, object_type, object_id, relation) returns boolean
permissions.list_objects_for(subject_type, subject_id, object_type, relation) returns text[]
permissions.list_subjects(object_type, object_id, relation)
    returns table (subject_type text, subject_id text)
```

A working version of all of this is in [`../prototypes/a-tuple-core.sql`](../prototypes/a-tuple-core.sql) and passes the test suite.

### Evaluation

`list_objects` and `check` share one recursive CTE. It starts from the subject and walks outward: through tuples where the current node is the subject (group membership and direct grants), and through `implied_by` rules on the same object. Both steps live in one `lateral` subquery because Postgres allows only one recursive reference.

```sql
with recursive reach(object_type, object_id, relation) as (
    select p_subject_type, p_subject_id, ''::text
  union
    select n.object_type, n.object_id, n.relation
    from reach r
    cross join lateral (
        -- 1. tuples where this node is the subject (direct grant or userset)
        select t.object_type, t.object_id, t.relation
        from permissions.tuples t
        where t.subject_type = r.object_type
          and t.subject_id = r.object_id
          and t.subject_relation = r.relation
          and t.condition is null
          and (t.expires_at is null or t.expires_at > now())
      union all
        -- 2. relations implied by this one on the same object (editor => viewer)
        select r.object_type, r.object_id, rel.relation
        from permissions.relations rel
        where rel.object_type = r.object_type
          and r.relation = any (rel.implied_by)
    ) n
)
select coalesce(array_agg(object_id), '{}')
from reach
where object_type = p_object_type and relation = p_relation;
```

`union` (not `union all`) removes duplicate rows, so cycles terminate: the set of reachable `(type, id, relation)` nodes is finite. `check` is the same query with `object_id = p_object_id` and `limit 1`. `list_subjects` walks the same edges in reverse.

v0.0.2 adds a third edge (parents), a second starting node (`user:*`) and a filter (exclusions) to the same query. See §12; the shape above is unchanged.

## 5. Reference scenario

IDs are shown as names for readability; in practice `readme` and `acme` would be the documents' and org's UUIDs as text.

### Model definition

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

### Data

```sql
select permissions.grant('org', 'acme', 'admin',  'user', 'alice');
select permissions.grant('org', 'acme', 'member', 'user', 'carol');

select permissions.grant('team', 'eng', 'member', 'user', 'carol');
select permissions.grant('team', 'eng', 'member', 'user', 'dave');

select permissions.grant('document', 'readme', 'editor', 'user', 'bob');
select permissions.grant('document', 'readme', 'viewer', 'team', 'eng', 'member');
```

### RLS policies

Org-wide access comes from `documents.org_id`. Per-document access comes from tuples. Without parent inheritance (v0.0.2), the policy combines the two paths:

```sql
alter table documents enable row level security;

create policy documents_select on documents for select
using (
    org_id = any (array(select unnest(permissions.list_objects('org', 'view_documents'))::uuid))
    or id  = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);

create policy documents_update on documents for update
using (
    permissions.check('org', org_id::text, 'edit_documents')
    or permissions.check('document', id::text, 'editor')
);
```

`array(select unnest(...)::uuid)` turns the function's `text[]` into a `uuid[]` once per query (an InitPlan), so the comparison can use the indexes on `id` and `org_id`. Two similar-looking forms are wrong: `x = any ((select f()))` is parsed as a subquery comparison and fails with `operator does not exist`, and `x = any ((select f())::uuid[])` re-applies the cast on every row, which made a page of documents 5× slower in the benchmark. See PLAN.md §4.

### Queries

- **Can Bob update `readme`?** Yes. `user:bob` reaches `document:readme#editor` directly, so `check_for('user', 'bob', 'document', 'readme', 'editor')` is true.
- **Which documents can Dave select?** `user:dave` reaches `team:eng#member`, which reaches `document:readme#viewer`. Dave isn't in `acme`, so the org path is empty. Result: `readme` only.
- **Who can view `readme`?** `list_subjects('document', 'readme', 'viewer')` returns Bob (editor implies viewer), Carol and Dave (via `team:eng`). It does **not** return Alice, even though she can view it via the org: in this v0.0.1 model that path lives in the RLS policy, not in the tuples. With parent inheritance (§12.1) the org path moves into the model and `list_subjects` includes her.

## 6. Blessed path: the `rbac` preset

The preset API from [PLAN.md §6](../PLAN.md) maps onto two built-in object types: `app` (a single object, `app:global`, for app-wide roles) and `tenant` (one object per scope). Roles and permissions both become relations on those types, and role inheritance becomes `implied_by`.

### How it maps

| Preset call | Engine call |
| --- | --- |
| `create_role('editor', '{documents.edit}', '{viewer}')` | On both `app` and `tenant`: `define_relation('editor')`, add `editor` to `implied_by` of `documents.edit` and of `viewer` |
| `assign_role('bob', 'editor')` | `grant('app', 'global', 'editor', 'user', 'bob')` |
| `assign_role('bob', 'editor', 'acme')` | `grant('tenant', 'acme', 'editor', 'user', 'bob')` |
| `has_permission('documents.edit', 'acme')` | `check('tenant', 'acme', 'documents.edit')` |
| `scopes_with_permission('documents.read')` | `list_objects('tenant', 'documents.read')` |

A small `permissions.rbac_roles(role, permissions[], inherits[])` table records what the developer declared. It's used to tell roles apart from permissions (both are relations underneath), to reject a role named like a permission, and to rebuild the relations if a role changes.

```sql
create function permissions.create_role(p_role text, p_permissions text[], p_inherits text[] default '{}')
returns void language plpgsql security definer set search_path = '' as $$
declare t text; x text;
begin
  if exists (select 1 from permissions.rbac_roles where p_role = any (permissions))
     or exists (select 1 from permissions.rbac_roles where role = any (p_permissions)) then
    raise exception 'role and permission names must not overlap';
  end if;
  insert into permissions.rbac_roles values (p_role, p_permissions, p_inherits);
  foreach t in array array['app', 'tenant'] loop
    perform permissions.define_relation(t, p_role);
    foreach x in array p_permissions loop perform permissions.add_implied_by(t, x, p_role); end loop;
    foreach x in array p_inherits    loop perform permissions.add_implied_by(t, x, p_role); end loop;
  end loop;
end $$;
```

### RBAC scenario

What the developer writes:

```sql
select permissions.create_role('viewer', '{documents.read}');
select permissions.create_role('editor', '{documents.edit}', '{viewer}');
select permissions.create_role('admin',  '{documents.delete,users.manage}', '{editor}');

-- app-wide
select permissions.assign_role('alice', 'admin');
select permissions.assign_role('bob',   'editor');
select permissions.assign_role('carol', 'viewer');

create policy documents_select on documents for select using ((select permissions.has_permission('documents.read')));
create policy documents_update on documents for update using ((select permissions.has_permission('documents.edit')));
create policy documents_delete on documents for delete using ((select permissions.has_permission('documents.delete')));
```

`has_permission` takes no row values, so wrapping it in `(select ...)` makes Postgres evaluate it once per query. That's the cheapest RLS check possible.

Tenant-scoped variant:

```sql
select permissions.assign_role('alice', 'admin',  'acme');
select permissions.assign_role('bob',   'editor', 'acme');
select permissions.assign_role('bob',   'viewer', 'globex');

create policy documents_select on documents for select
  using (org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid)));
create policy documents_update on documents for update
  using (permissions.has_permission('documents.edit', org_id::text));
```

What's stored underneath: 3 `rbac_roles` rows, 14 `relations` rows (7 on `app`, 7 on `tenant`), and one tuple per assignment (`app:global#admin@user:alice`, `tenant:acme#editor@user:bob`, ...).

Graduation, sharing one `acme` document with Dave:

```sql
select permissions.define_type('document');
select permissions.define_relation('document', 'editor');
select permissions.define_relation('document', 'viewer', '{editor}');
select permissions.grant('document', '<doc id>', 'editor', 'user', 'dave');

-- select policy gains one branch
create policy documents_select on documents for select using (
  org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
  or id  = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);
```

The RBAC tuples and relations are untouched. Dave's grant is just another tuple in the same table.

Queries:

- **Can Carol edit documents?** No. Carol holds `viewer` on `app:global`, which implies `documents.read` only.
- **What permissions does Bob have in `globex`?** `user_permissions('bob', 'globex')` returns `{documents.read}`.
- **Who are the admins of `acme`?** `users_with_role('admin', 'acme')` returns Alice.

### Tested

This preset was built on top of the §4 engine and run on Postgres 16 with a non-superuser role under RLS. Every answer above matched, including:
- Bob's `update` only touching `acme` documents;
- Dave seeing only the shared document after graduation;
- the RBAC tuples being unchanged by it;
- `explain` showing the permission lookups as InitPlans (run once per query).

### Fit

- **Clean.** The preset is about 50 lines of thin wrappers. RBAC is literally a subset of the engine, so graduation is free.
- **Role definitions are duplicated** across the `app` and `tenant` types (every role exists twice in `relations`). It's harmless, but `rbac_roles` has to stay the source of truth.
- **RBAC checks still run the recursive walk.** For RBAC it's tiny (one tuple plus a few `implied_by` steps), but it's more work than a flat lookup would be.

## 7. RLS performance

- **SELECT on 1M rows:** each `list_objects` runs once per statement. Cost is proportional to the number of tuples the subject can reach, not the table size. The table needs an index on `id` (and `org_id`) so `= any(array)` can use it, which is why the policy converts the array to `uuid` rather than casting the column to `text`. The cast fails the whole query if any stored ID for that type isn't a valid UUID, so `grant` should validate IDs per object type.
- **Single-row check:** one recursive query bounded by the subject's group memberships. Typically a few index lookups.
- **Writes:** one row insert or delete per grant. Nothing is recomputed.
- **Worst case:** a subject who can reach a very large number of objects gets a large array back on every query. The fix is to grant at a coarser scope (org instead of each document) rather than tuning the extension.

## 8. How later features fit

```
┌──────────────────────────────────────────────────────────┐
│ RLS policies: check() / list_objects()                   │
├──────────────────────────────────────────────────────────┤
│ Policy layer (later): conditions → CEL → Cedar           │
│   permit/forbid, priorities, expressions over attributes │
├──────────────────────────────────────────────────────────┤
│ Relationship evaluator (v0.0.1): implied relations,      │
│   usersets; v0.0.2: parent inheritance                   │
├──────────────────────────────────────────────────────────┤
│ Core store: object_types, relations, tuples, entities    │
├──────────────────────────────────────────────────────────┤
│ Identity: current_subject_id() (setting → JWT sub)       │
└──────────────────────────────────────────────────────────┘
```

- **Parent inheritance (v0.0.2, built, §12.1):** a tuple `document:readme#parent@folder:specs` and a rule on `relations` (`from_parent`), Zanzibar's tuple-to-userset. The evaluator got a third step in the `lateral`. The RLS policy can then use only the document path, at a cost (§12.1).
- **Attribute conditions (Model 3):** evaluate `tuples.condition` against `entities.attributes` and request context. Tuples with a false condition are skipped during the walk.
- **CEL (#9):** an alternative format for `condition`. It's a parser plus evaluator in the policy layer, not a separate extension. The JWT helpers fold into the identity layer.
- **Cedar (#10):** `entity_parents` maps onto tuples (`member` relations). Permit/forbid with priority is a policy-layer feature on top.
- **ABAC (#8):** subject and resource attributes live in `entities`. Rules become conditions.

## 9. Weaknesses and risks

- **Org-level access: model or speed, pick one.** With parent inheritance (§12.1) "admins can edit all org documents" lives in the model and `list_subjects` is complete. But a single-branch RLS policy then enumerates every visible document on every query (7 ms for 1,007 IDs at small scale). Keeping the `org_id = any(...)` branch is an order of magnitude cheaper but puts org access back in policy SQL.
- **Parent links duplicate app data.** Parent inheritance needs one `parent` tuple per child that mirrors `documents.folder_id` or `org_id`: 1M documents means 1M tuples (about 430 MB with indexes, extrapolated from 450 bytes per tuple at small scale). `permissions.sync_parent()` keeps them in sync from a trigger, but the data is still stored twice.
- **No foreign keys to app tables.** IDs are `text`, so deleting a document doesn't delete its tuples unless the app calls `delete_object`. Orphaned tuples are harmless but accumulate.
- **Read-time cost grows with nesting.** Deep or wide group hierarchies make every check walk more rows. Zanzibar systems solve this with caching and precomputed indexes, which this design doesn't have.
- **Exclusions are limited.** v0.0.2 adds OpenFGA-style `but not` (§12.3), but only against a direct `blocked` tuple on the subject itself, not a group. Cedar-style forbids over attributes or groups would still need a separate pass in the policy layer, which is the least designed part of this proposal.
- **No condition evaluator.** `tuples.condition` is still ignored (default deny). Rules over app columns such as `status` are RLS composition (§12.4), so `check()` and the RLS policy can give different answers for the same row.
- **Weak validation.** Nothing stops granting `document#viewer` to a subject type that makes no sense (e.g. `org:acme` with no relation). OpenFGA's type restrictions would need an extra column on `relations`.

## 10. Implementation phases

1. **Core and identity**: schema, `define_*`, `grant`/`revoke`/`delete_*`, `current_subject_id()`.
2. **Relationship evaluator**: `check` with implied relations and usersets, then `list_objects` and `list_subjects`.
3. **Examples and tests**: an `examples/` folder with the reference scenario. SQL tests run against the local Supabase stack (`make reset && make tle.install.pg_permissions`) and against plain Postgres, to prove there's no Supabase dependency.
4. **Docs**: the README covers install, both models end to end, RLS patterns, and the identity sync recipe.
5. **Stretch: Model 3 conditions**: `condition` and `entities` evaluation in `check`.

## 11. Open questions

1. **Text IDs**: every RLS call casts `id::text`. Fine for the PoC, but worth benchmarking on a 1M-row table before v0.1.
2. **Wildcard subjects** (`user:*` for public access, as in OpenFGA): built in v0.0.2 (§12.2).
3. **SECURITY DEFINER inside a TLE**: confirm the function owner on Supabase/dbdev installs has read access to `permissions.*` while clients don't.
4. **Name `check`**: `check` is a reserved word. `permissions.check(...)` works, but a bare `check(...)` (for example with `permissions` on the `search_path`) is a syntax error. Rename to `can`, or document that it must always be schema-qualified?
5. **Subject type restrictions**: add an `allowed_subjects` column to `relations` in v0.0.1 for validation, or wait?

## 12. v0.0.2: parents, public access, forbid, conditions

PLAN.md §10 goals G10–G13, built into [`../prototypes/a-tuple-core.sql`](../prototypes/a-tuple-core.sql) and tested by `test/spec/a/50_parents`, `51_public`, `52_forbid` and `53_conditions`. Everything stays in A's character: no derived data, the answer is computed at read time by the same recursive walk. Each feature borrows OpenFGA's construct for it, so FGA users will recognise the semantics.

The walk after v0.0.2 (one query, still one recursive reference):

```sql
with recursive
blocked(object_type, object_id, relation) as (     -- G12: nodes this subject is excluded from
    select t.object_type, t.object_id, rel.relation
    from permissions.tuples t
    join permissions.relations rel on rel.object_type = t.object_type and t.relation = any (rel.unless)
    where t.subject_type = p_subject_type and t.subject_id = p_subject_id and t.subject_relation = ''
      and t.condition is null and (t.expires_at is null or t.expires_at > now())
),
reach(object_type, object_id, relation) as (
    select p_subject_type, s, ''::text
    from unnest(array[p_subject_id, '*']) s            -- G11: also start from user:*
    where p_subject_id is not null
  union
    select n.object_type, n.object_id, n.relation
    from reach r
    cross join lateral (
        ... 1. tuples where this node is the subject (unchanged)
      union all
        ... 2. implied_by on the same object (unchanged)
      union all
        select c.object_type, c.object_id, rel.relation  -- G10: children inherit through `parent` tuples
        from permissions.tuples c
        join permissions.relations rel on rel.object_type = c.object_type and r.relation = any (rel.from_parent)
        where c.subject_type = r.object_type and c.subject_id = r.object_id and c.subject_relation = ''
          and c.relation = 'parent'
          and c.condition is null and (c.expires_at is null or c.expires_at > now())
    ) n
    where not exists (select 1 from blocked b              -- G12: never enter an excluded node
                      where (b.object_type, b.object_id, b.relation) = (n.object_type, n.object_id, n.relation))
)
select * from reach
```

`_reach` is now PL/pgSQL wrapping this query. Postgres 16 re-plans a SQL function body on every call, and the larger query made every check ~0.25 ms slower (`rbac_check` p50 0.32 → 0.58 ms, measured interleaved in one cluster). PL/pgSQL caches the plan per session, which brought it back to 0.34 ms. The same change on the v0.0.1 query would have made it faster than before (0.26 ms).

### 12.1 Parent inheritance (G10)

**API.** A child points at its parent with a tuple whose relation is always `parent`. A relation inherits from the parent with `from_parent`, which names relations **on the parent** (any parent type; the relation is looked up by name there). This is OpenFGA's `define viewer: viewer from parent`.

```sql
select permissions.define_relation('org', 'admin');
select permissions.define_relation('org', 'member', '{admin}');
select permissions.define_relation('org', 'editor', '{admin}');
select permissions.define_relation('org', 'viewer', '{member,editor}');
select permissions.define_relation('folder', 'parent');
select permissions.define_relation('folder', 'editor', from_parent => '{editor}');
select permissions.define_relation('folder', 'viewer', '{editor}', from_parent => '{viewer}');
select permissions.define_relation('document', 'parent');
select permissions.define_relation('document', 'editor', from_parent => '{editor}');
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}');

select permissions.set_parent('folder', 'specs', 'org', 'acme');      -- = grant('folder','specs','parent','org','acme') after removing the old parent

-- or keep parents in sync with an app column:
create trigger documents_parent after insert or update of folder_id or delete on public.documents
    for each row execute function permissions.sync_parent('document', 'folder', 'folder_id');

-- one fast-path branch covers org roles, folder grants and direct shares
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);
```

`set_parent` gives single-parent semantics (moving = replacing). Raw `grant(..., 'parent', ...)` allows several parents, and the test uses that to build a cycle. `sync_parent(object_type, parent_type, parent_column [, id_column])` reads the columns through `to_jsonb(new)`, so one function serves any table. It is SECURITY DEFINER with execute revoked from public. Postgres checks execute when the trigger is **created**, not when it fires, so only the owner can attach it to a table, while client inserts and updates still fire it.

Because the parent can be any type, the rbac preset graduates to parents without new types: `define_relation('document', 'viewer', '{editor}', from_parent => '{documents.read}')` plus `set_parent('document', id, 'tenant', org_id)` makes every scoped `viewer`/`editor`/`admin` role reach the org's documents (this is the benchmark seed, `bench/designs/a/seed_parents.sql`).

**How it evaluates.** Forwards: from a node `org:acme#viewer`, edge 3 finds tuples `X#parent@org:acme` and yields `X#R` for every relation `R` on X's type whose `from_parent` contains `viewer`. Backwards (`list_subjects`): from `document:readme#viewer`, it follows readme's `parent` tuples up to `folder:specs#viewer`. `union` deduplicates nodes, so parent cycles terminate. `50_parents` builds a `specs ↔ plans` cycle and walks into it both ways under a 5 s statement timeout. The plain "a non-grantee gets false" assertion doesn't prove termination for A: a forward walk from a user with no tuples never reaches the cycle. A `union all` mutant passed that assertion until the spec also walked into the cycle.

**Costs.**
- **Storage: one tuple per child.** 1M documents means 1M `parent` tuples mirroring a column the app already has. At small scale the tuples table averaged 450 bytes per row including its three indexes, so about 430 MB at 1M (extrapolated, not measured).
- **Reading the parent from the app's column instead** would avoid the copy, but the walk is generic SQL over `permissions.tuples`. Reading `documents.folder_id` needs either dynamic SQL per type (no plan caching, harder to secure) or a registry of app tables. That is the "bring your own data" design that was rejected for being slower and more confusing. `sync_parent` is the compromise: one source of truth (the app column), copied mechanically.
- **The single-branch policy enumerates every visible document.** `list_objects('document', 'viewer')` walks to each document one by one. At small scale (10k documents, 20 orgs, a user with roles in two orgs plus team shares) that is 1,007 IDs and **7.3 ms per call**, about 7 µs per visible document. Under pgbench (4 clients, busy machine) the first page took **18 ms p50** against 2.2 ms for the two-branch policy on the same data. At large scale a user sees ~20k documents, so expect on the order of 150 ms per query (extrapolated, not measured). The two-branch policy (`org_id = any(scopes) or id = any(shares)`) stays the fast option: parents then make `check` and `list_subjects` complete without being on the hot RLS path.
- **Every walk does one more probe per node** (edge 3), even for nodes with no children. Measured at small scale it costs ~0.1 ms per check before plan caching.

**Weaknesses.**
- Moving a document into a folder grants that folder's viewers access. If clients can update `folder_id`, the app's UPDATE policy needs a `with check` that the user may write into the target folder. The extension can't know that.
- `parent` is a reserved relation name, and `from_parent` matches relations by name on whatever type the parent is. There's no type check that an org actually has the relation a folder inherits. A typo yields no access rather than an error.
- `grant` rejects usersets and wildcards as parents (`document#parent@team:eng#member` has no meaning).
- `delete_object` on a folder doesn't remove its children's `parent` tuples pointing at it; `delete_subject('folder', id)` does.

### 12.2 Public access (G11)

**API.** OpenFGA's wildcard: the subject id `*`.

```sql
select permissions.grant('document', 'announcement', 'viewer', 'user', '*');
select permissions.revoke('document', 'announcement', 'viewer', 'user', '*');
```

**How it evaluates.** The walk starts from two nodes, `user:<id>` and `user:*`, so every non-null subject of type `user` reaches whatever `user:*` reaches, including through groups (`team:eng#member@user:*` makes everyone a member). A null subject starts from no nodes and is denied, so anonymous access stays out of scope. `list_subjects` returns `('user', '*')` as a subject, which is how OpenFGA reports it too. `grant` rejects `*` with a subject relation (`team:*#member`).

**Costs.** One extra starting node per walk; measured as no difference.

**Weaknesses.**
- A JWT whose `sub` is literally `*` is that wildcard. It only gets what everyone gets, but apps should never issue it.
- Public access is per subject type: `user:*` doesn't cover a `service` subject type.
- A public grant can't be scoped ("every member of an org" is a group, not a wildcard).

### 12.3 Forbid (G12)

**API.** OpenFGA's exclusion (`define viewer: ... but not blocked`), with the keyword `unless`. A forbid is an ordinary tuple on the excluding relation, written by admins only (`grant` isn't executable by clients, so `52_forbid` checks for `42501`).

```sql
select permissions.define_relation('document', 'blocked');
select permissions.define_relation('document', 'editor', from_parent => '{editor}', unless => '{blocked}');
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}', unless => '{blocked}');

select permissions.grant('document', 'readme', 'blocked', 'user', 'dave');   -- forbid
select permissions.revoke('document', 'readme', 'blocked', 'user', 'dave');  -- lift it
```

**How it evaluates.** Before walking, `blocked` collects the subject's own exclusion tuples (one index lookup on the subject). The walk then **never enters** an excluded node. Nothing derived through it is reached either: blocking Alice on readme removes `readme#editor`, and with it `readme#viewer` via `implied_by`, even though she arrived through org → folder parents. Blocking a folder relation hides everything inherited through that folder, but a direct grant on a document below it still applies (OpenFGA behaves the same). Because pruning happens during the walk, `check`, `list_objects` and the RLS policy all agree.

`list_subjects` walks backwards, and in that direction exclusions depend on the final subject, not the path, so it can't prune. It collects candidates as before and re-checks forwards only those that hold at least one exclusion tuple. Unblocked subjects cost one index probe each.

**Costs.** The `blocked` CTE and the anti-join on every step: ~0.13 ms per check before plan caching, small after. A subject with many forbids makes the anti-join larger, but forbids are expected to be rare.

**Weaknesses.**
- **Direct subjects only.** A forbid on a group (`team:contractors#member`) would need the walk itself to decide membership, which is negation inside recursion. `grant` rejects usersets and wildcards on any relation used in an `unless` list rather than silently ignoring them. Cedar's `forbid ... when { principal in Group }` isn't expressible.
- **The model has to opt in per relation.** A relation without `unless => '{blocked}'` ignores `blocked` tuples, and `editor` and `viewer` each need it. Forgetting it on one relation is a silent hole.
- Not an attribute rule: "deny if `resource.status = 'archived'`" is still RLS SQL (§12.4).

### 12.4 Conditions (G13)

**API.** Nothing new in the engine. Expiry is the grant's `expires_at` (already in v0.0.1). Rules over the app's own columns are RLS composition:

```sql
select permissions.grant('org', 'acme', 'member', 'user', 'gina', '', now() - interval '1 day');  -- grants nothing

-- viewers see published documents; editors (and so admins) see drafts too
create policy documents_select on public.documents for select to authenticated using (
    (status = 'published' and id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid)))
    or id = any (array(select unnest(permissions.list_objects('document', 'editor'))::uuid))
);
```

`53_conditions` links documents to the org through `sync_parent('document', 'org', 'org_id')`, so the parent tuple comes from the app's existing `org_id` column.

**How it evaluates.** Expired tuples are skipped on every edge of the walk, forwards and backwards. The status rule is plain SQL on the row; each `list_objects` call is an InitPlan, so the policy costs two walks per query, not one per row.

**Why not evaluate conditions in the engine.** It would mean mirroring `status` into `permissions.entities` (a second copy to keep in sync, like parents) and evaluating `tuples.condition` per step, which no longer fits one cached plan. With the status in the app's row, Postgres filters it for free.

**Weaknesses.**
- **The model and the policy disagree.** `check_for('user', 'carol', 'document', 'draft_doc', 'viewer')` is **true**, because the engine doesn't know about status. Only RLS hides the draft. Every app check outside RLS has to repeat the status rule, and `list_subjects` over-reports.
- The rule lives in each policy, so a second table with the same rule repeats it.
- `tuples.condition` and `entities` are still unused: a tuple with a condition is ignored (default deny).

### 12.5 Testing

`./test/run.sh --impl prototypes/a-tuple-core.sql`: 13/13 files, 147/147 assertions. Each new feature was broken once on purpose ("mutants"), and every mutant failed a spec:

| Mutant | Caught by |
| --- | --- |
| No parent edge in the walk | `50_parents` (7 failed), `52_forbid`, `53_conditions` |
| `sync_parent` ignores updates (moving a document) | `50_parents` (1 failed) |
| `union all` instead of `union` (cycles) | `50_parents` (statement timeout), but only after the spec walked into the cycle (§12.1) |
| No `user:*` starting node | `51_public` (3 failed) |
| No exclusion pruning in the walk | `52_forbid` (5 failed) |
| `list_subjects` doesn't re-check excluded subjects | `52_forbid` (1 failed) |
| Expiry ignored in the walk | `53_conditions` (Gina), `31_zanzibar_groups` |

The status rule lives in the spec's RLS policy, not the engine, so it has no engine mutant.
