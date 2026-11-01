# Design A: Shared tuple core (Zanzibar-first)

> Status: this design is history. The team built it and measured it, but did not choose it. Design D is the extension. See [`d-per-model.md`](./d-per-model.md).

> This is one of three candidate designs. For the shared goals, requirements and evaluation criteria, see [plan.md](../plan.md).

**Summary:** every model is stored as Zanzibar-style relationship tuples in one generic table with `text` IDs. A recursive CTE computes decisions at read time. Attribute rules, CEL and Cedar come later as a policy layer on the same store.

## 1. Core idea

The four earlier RFCs all store "subject is related to object" in some form: Zanzibar tuples, Cedar parents, ABAC role assignments. A tuple `(object_type, object_id, relation, subject_type, subject_id[, subject_relation])` can represent all of them. So the extension has one fact table and one evaluator. RBAC is ReBAC on an org object.

Reasons why this can be the right choice:

- It is the smallest possible core: four tables and one recursive query.
- It is proven. SpiceDB and OpenFGA use the same model, so developers can use their FGA knowledge.
- Writes are cheap and simple: one row for each grant, and nothing to recompute.

## 2. Core schema

Everything is in a `permissions` schema. IDs are `text`, so the extension works with UUIDs, integers or external IDs.

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
    implied_by  text[] not null default '{}',  -- for example, viewer is implied by editor
    from_parent text[] not null default '{}',  -- v0.0.2: inherited from the parent's relation (section 12.1)
    unless      text[] not null default '{}',  -- v0.0.2: excluded by these relations (section 12.3)
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

- `subject_relation` defaults to `''` and not to `null`, so the unique constraint works. With `null`, Postgres treats two null values as different, so it accepts duplicate tuples.
- The foreign key on `relations` catches typos. You cannot grant a relation that is not defined.
- Postgres ignores tuples with a non-null `condition` (default deny) until the team builds Model 3.

## 3. Link to identity

The extension never stores users. It must know only **who the current subject is** and **what the ID of the subject is**.

### Resolve the current subject

`permissions.current_subject_id()` (STABLE) checks these sources in order. It uses the first source that has a value:

1. `current_setting('request.jwt.claims', true)::jsonb ->> 'sub'`: the standard PostgREST claim. The Supabase function `auth.uid()` reads the same claim. So Supabase works with no configuration and with no dependency on the `auth` schema.
2. `current_setting('permissions.subject_id', true)`: the app sets it on plain Postgres, in tests, or in server-side jobs (`set local permissions.subject_id = '...'`).

The JWT is first. When a request has a JWT, nothing else in the session can override who the subject is.

`permissions.current_subject_type()` defaults to `'user'`. You can override it with `permissions.subject_type`.

Every check has an explicit-subject variant (`check_for`, `list_objects_for`) for tests and server-side jobs. Only admins can call these variants. If clients can call them, any user can ask what any other user can access.

### Keep tuples in sync with an identity table

There is deliberately no foreign key to `auth.users` or to any other users table, because that ties the extension to one identity source. The README will document a recipe instead:

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

The same pattern works for any users table, with or without Supabase.

## 4. Public API (v0.0.1)

Model definition:

```sql
permissions.define_type(name text, description text default null)
permissions.define_relation(object_type text, relation text, implied_by text[] default '{}',
                            from_parent text[] default '{}', unless text[] default '{}')  -- last two: v0.0.2, section 12
```

Tuple writes:

```sql
permissions.grant(object_type, object_id, relation, subject_type, subject_id, subject_relation default '', expires_at default null)
permissions.revoke(object_type, object_id, relation, subject_type, subject_id, subject_relation default '')
permissions.delete_subject(subject_type, subject_id)   -- removes all tuples for that subject
permissions.delete_object(object_type, object_id)      -- removes all tuples on that object

-- v0.0.2 (section 12.1): parents
permissions.set_parent(object_type, object_id, parent_type, parent_id)  -- replaces the parent; null clears it
permissions.sync_parent()  -- trigger function: keeps parent tuples in sync with an app column
```

Checks are SECURITY DEFINER with `set search_path = ''`. All checks are STABLE. `list_objects`, `list_objects_for` and `scopes_with_permission` take a last argument, `p_unfold boolean default permissions._unfolded_null()`. Callers never pass it. Because of this argument, the planner cannot pre-evaluate the functions (section 13).

```sql
-- Client-facing: always the current subject
permissions.check(object_type, object_id, relation) returns boolean
permissions.list_objects(object_type, relation [, p_unfold]) returns text[]      -- RLS fast path

-- Admin only (execute revoked from public): explicit subject, or who has access
permissions.check_for(subject_type, subject_id, object_type, object_id, relation) returns boolean
permissions.list_objects_for(subject_type, subject_id, object_type, relation) returns text[]
permissions.list_subjects(object_type, object_id, relation)
    returns table (subject_type text, subject_id text)
```

A complete version of all of this is in [`../../prototypes/a-tuple-core.sql`](../../prototypes/a-tuple-core.sql). It passes the test suite.

### Evaluation

`list_objects` and `check` share one recursive CTE. It starts from the subject and walks outward. It follows tuples where the current node is the subject (group membership and direct grants). It also follows `implied_by` rules on the same object. Both steps are in one `lateral` subquery, because Postgres lets a query have only one recursive reference.

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

`union` (not `union all`) removes duplicate rows, so cycles end: the set of reachable `(type, id, relation)` nodes is finite. `check` was the same query with `object_id = p_object_id` and `limit 1`. From session 3, it searches from both ends (section 13). `list_subjects` walks the same edges in reverse.

v0.0.2 adds a third edge (parents), a second start node (`user:*`) and a filter (exclusions) to the same query. See section 12. The shape above does not change. Session 3 (section 13) expands only nodes that have an edge out of them.

## 5. Reference scenario

IDs are shown as names for readability. In practice, `readme` and `acme` are the UUIDs of the document and the org, as text.

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

`array(select unnest(...)::uuid)` turns the `text[]` of the function into a `uuid[]` one time for each query (an InitPlan). So the comparison can use the indexes on `id` and `org_id`.

Two forms that look similar are wrong. `x = any ((select f()))` is parsed as a subquery comparison and fails with `operator does not exist`. `x = any ((select f())::uuid[])` applies the cast again on every row. That made a page of documents 5× slower in the benchmark. See [plan.md, section 4](../plan.md).

### Queries

- **Can Bob update `readme`?** Yes. `user:bob` reaches `document:readme#editor` directly, so `check_for('user', 'bob', 'document', 'readme', 'editor')` is true.
- **Which documents can Dave select?** `user:dave` reaches `team:eng#member`, which reaches `document:readme#viewer`. Dave is not in `acme`, so the org path is empty. Result: `readme` only.
- **Who can view `readme`?** `list_subjects('document', 'readme', 'viewer')` returns Bob (editor implies viewer), Carol and Dave (through `team:eng`). It does **not** return Alice, although she can view it through the org. In this v0.0.1 model, that path is in the RLS policy and not in the tuples. With parent inheritance (section 12.1), the org path moves into the model and `list_subjects` includes her.

## 6. Blessed path: the `rbac` preset

The preset API from [plan.md, section 6](../plan.md) maps onto two built-in object types. The type `app` has one object, `app:global`, for app-wide roles. The type `tenant` has one object for each scope. Roles and permissions both become relations on those types. Role inheritance becomes `implied_by`.

### How it maps

| Preset call | Design call |
| --- | --- |
| `create_role('editor', '{documents.edit}', '{viewer}')` | On both `app` and `tenant`: `define_relation('editor')`, add `editor` to `implied_by` of `documents.edit` and of `viewer` |
| `assign_role('bob', 'editor')` | `grant('app', 'global', 'editor', 'user', 'bob')` |
| `assign_role('bob', 'editor', 'acme')` | `grant('tenant', 'acme', 'editor', 'user', 'bob')` |
| `has_permission('documents.edit', 'acme')` | `check('tenant', 'acme', 'documents.edit')` |
| `scopes_with_permission('documents.read')` | `list_objects('tenant', 'documents.read')` |

A small table, `permissions.rbac_roles(role, permissions[], inherits[])`, records what the developer declared. It has three uses. It tells roles apart from permissions (both are relations underneath). It rejects a role with the name of a permission. It rebuilds the relations if a role changes.

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

The developer writes this:

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

`has_permission` takes no row values. When you wrap it in `(select ...)`, Postgres evaluates it one time for each query. This is the cheapest RLS check possible.

Variant with tenant scope:

```sql
select permissions.assign_role('alice', 'admin',  'acme');
select permissions.assign_role('bob',   'editor', 'acme');
select permissions.assign_role('bob',   'viewer', 'globex');

create policy documents_select on documents for select
  using (org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid)));
create policy documents_update on documents for update
  using (permissions.has_permission('documents.edit', org_id::text));
```

The stored data is 3 `rbac_roles` rows, 14 `relations` rows (7 on `app`, 7 on `tenant`), and one tuple for each assignment (`app:global#admin@user:alice`, `tenant:acme#editor@user:bob`, ...).

Graduation, with one `acme` document shared with Dave:

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

The RBAC tuples and relations do not change. The grant to Dave is another tuple in the same table.

Queries:

- **Can Carol edit documents?** No. Carol holds `viewer` on `app:global`, which implies `documents.read` only.
- **What permissions does Bob have in `globex`?** `user_permissions('bob', 'globex')` returns `{documents.read}`.
- **Who are the admins of `acme`?** `users_with_role('admin', 'acme')` returns Alice.

### Tested

The team built this preset on the design of section 4. They ran it on Postgres 16 with a non-superuser role under RLS. Every answer above matched. The matches include these results:

- The `update` by Bob touched only `acme` documents.
- Dave saw only the shared document after graduation.
- Graduation did not change the RBAC tuples.
- `explain` showed the permission lookups as InitPlans (they run one time for each query).

### Fit

- **Clean.** The preset is about 50 lines of thin wrappers. RBAC is a subset of the design, so graduation is free.
- **Role definitions are duplicated** across the `app` and `tenant` types (every role exists twice in `relations`). This is harmless, but `rbac_roles` must stay the source of truth.
- **RBAC checks still run the recursive walk.** For RBAC the walk is tiny (one tuple plus some `implied_by` steps), but it is more work than a flat lookup.

## 7. RLS performance

- **SELECT on 1M rows:** each `list_objects` runs one time for each statement. Its cost is proportional to the number of tuples that the subject can reach, not to the table size. The table needs an index on `id` (and `org_id`), so `= any(array)` can use it. That is why the policy converts the array to `uuid` and does not cast the column to `text`.
- **Invalid IDs:** the cast fails the whole query if a stored ID for that type is not a valid UUID. So `grant` must validate IDs for each object type.
- **Single-row check:** a bidirectional search (section 13). The smaller of the two sides, the subject or the object, bounds it. It is typically a few index lookups.
- **Writes:** one row insert or delete for each grant. The extension recomputes nothing.
- **Worst case:** a subject who can reach a very large number of objects gets a large array back on every query. The fix is to grant at a coarser scope (the org and not each document). Do not tune the extension.

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

- **Parent inheritance (v0.0.2, built, section 12.1):** a tuple `document:readme#parent@folder:specs` and a rule on `relations` (`from_parent`). This is the tuple-to-userset of Zanzibar. The evaluator got a third step in the `lateral`. The RLS policy can then use the document path only, at a cost (section 12.1).
- **Attribute conditions (Model 3):** evaluate `tuples.condition` against `entities.attributes` and the request context. The walk skips tuples with a false condition.
- **CEL (#9):** an alternative format for `condition`. It is a parser plus an evaluator in the policy layer, not a separate extension. The JWT helpers fold into the identity layer.
- **Cedar (#10):** `entity_parents` maps onto tuples (`member` relations). `permit` and `forbid` with priority are a feature of the policy layer on top.
- **ABAC (#8):** subject and resource attributes are in `entities`. Rules become conditions.

> Status: design A did not build these later layers. Design D, the extension in [`pg_permissions--0.0.1.sql`](../../pg_permissions--0.0.1.sql), has OpenFGA conditions with CEL. They are done. See [`d-conditions.md`](./d-conditions.md).

## 9. Weaknesses and risks

- **Org-level access: model or speed, pick one.** With parent inheritance (section 12.1), "admins can edit all org documents" is in the model, and `list_subjects` is complete. But then a single-branch RLS policy lists every visible document on every query (7 ms for 1,007 IDs at small scale). The `org_id = any(...)` branch is much cheaper (about 160× at large scale, section 12.1), but it puts org access back in policy SQL.
- **Parent links duplicate app data.** Parent inheritance needs one `parent` tuple for each child. The tuple mirrors `documents.folder_id` or `org_id`. 1M documents mean 1M tuples (about 378 MB with indexes, measured at large scale; seed 44 s). `permissions.sync_parent()` keeps them in sync from a trigger, but the app and the extension still store the data twice.
- **No foreign keys to app tables.** IDs are `text`, so when you delete a document, its tuples stay unless the app calls `delete_object`. Orphaned tuples are harmless, but they accumulate.
- **Read-time cost grows with depth.** Deep or wide group hierarchies make every check walk more rows. Zanzibar systems solve this with caches and precomputed indexes. This design has neither.
- **Exclusions are limited.** v0.0.2 adds OpenFGA-style `but not` (section 12.3), but only against a direct `blocked` tuple on the subject itself, not a group. Cedar-style forbids over attributes or groups still need a separate pass in the policy layer. That layer is the least designed part of this proposal.
- **No condition evaluator.** Postgres still ignores `tuples.condition` (default deny). Rules over app columns such as `status` are RLS composition (section 12.4). So `check()` and the RLS policy can give different answers for the same row.
- **Weak validation.** Nothing stops a grant of `document#viewer` to a subject type that makes no sense (for example `org:acme` with no relation). OpenFGA type restrictions need an extra column on `relations`.

## 10. Implementation phases

1. **Core and identity**: schema, `define_*`, `grant`/`revoke`/`delete_*`, `current_subject_id()`.
2. **Relationship evaluator**: `check` with implied relations and usersets, then `list_objects` and `list_subjects`.
3. **Examples and tests**: an `examples/` folder with the reference scenario. SQL tests run against the local Supabase stack (`make reset && make tle.install.pg_permissions`) and against plain Postgres, to prove that there is no Supabase dependency.
4. **Docs**: the README covers install, both models from start to end, RLS patterns, and the identity sync recipe.
5. **Stretch: Model 3 conditions**: evaluation of `condition` and `entities` in `check`.

> Status: these phases are the plan for design A. Design D is now the extension, in [`pg_permissions--0.0.1.sql`](../../pg_permissions--0.0.1.sql). CEL conditions, the stretch phase, are done in D. The suite has 56 spec files and 3,638 assertions on PG 16, 17 and 18.

## 11. Open questions

1. **Text IDs**: every RLS call casts `id::text`. This is fine for the proof of concept, but benchmark it on a 1M-row table before v0.1.
2. **Wildcard subjects** (`user:*` for public access, as in OpenFGA): built in v0.0.2 (section 12.2).
3. **SECURITY DEFINER inside a TLE**: make sure that the function owner can read `permissions.*` on Supabase and dbdev installs. Make sure that clients cannot.
4. **Name `check`**: `check` is a reserved word. `permissions.check(...)` works, but a bare `check(...)` (for example with `permissions` on the `search_path`) is a syntax error. Do we rename it to `can`, or document that you must always write the schema name?
5. **Subject type restrictions**: do we add an `allowed_subjects` column to `relations` in v0.0.1 for validation, or do we wait?

## 12. v0.0.2: parents, public access, forbid, conditions

[plan.md, section 10](../plan.md) lists the goals G10–G13. The team built them into [`../../prototypes/a-tuple-core.sql`](../../prototypes/a-tuple-core.sql) and tested them with `test/spec/a/50_parents`, `51_public`, `52_forbid` and `53_conditions`. Everything stays in the character of A: no derived data. The same recursive walk computes the answer at read time. Each feature borrows the OpenFGA construct for it, so FGA users will recognise the semantics.

The walk after v0.0.2 is one query with one recursive reference:

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

`_reach` is now a PL/pgSQL function that contains this query. Postgres 16 plans a SQL function body again on every call. The larger query made every check about 0.25 ms slower (`rbac_check` p50 0.32 → 0.58 ms, measured interleaved in one cluster). PL/pgSQL caches the plan for each session. This brought the time back to 0.34 ms. The same change on the v0.0.1 query gives 0.26 ms, which is faster than before.

### 12.1 Parent inheritance (G10)

**API.** A child points at its parent with a tuple whose relation is always `parent`. A relation inherits from the parent with `from_parent`. `from_parent` names relations **on the parent** (any parent type). The extension looks up the relation by name on that type. This is `define viewer: viewer from parent` in OpenFGA.

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

`set_parent` gives single-parent semantics (a move replaces the parent). With a raw `grant(..., 'parent', ...)`, a child can have more than one parent. The test uses that to build a cycle.

`sync_parent(object_type, parent_type, parent_column [, id_column])` reads the columns with `to_jsonb(new)`, so one function serves any table. It is SECURITY DEFINER with execute revoked from public. Postgres checks execute when you **create** the trigger, not when the trigger fires. So only the owner can attach the trigger to a table, while client inserts and updates still fire it.

The parent can be any type. So the rbac preset graduates to parents without new types. `define_relation('document', 'viewer', '{editor}', from_parent => '{documents.read}')` plus `set_parent('document', id, 'tenant', org_id)` makes every scoped `viewer`, `editor` and `admin` role reach the documents of the org. This is the benchmark seed, `bench/designs/a/seed_parents.sql`.

**How it evaluates.** Forwards: from a node `org:acme#viewer`, edge 3 finds tuples `X#parent@org:acme`. It yields `X#R` for every relation `R` on the type of X whose `from_parent` contains `viewer`. Backwards (`list_subjects`): from `document:readme#viewer`, the walk follows the `parent` tuples of readme up to `folder:specs#viewer`. `union` removes duplicate nodes, so parent cycles end.

`50_parents` builds a `specs ↔ plans` cycle and walks into it in both directions under a 5 s statement timeout. The plain assertion "a non-grantee gets false" does not prove that the walk ends for A. A forward walk from a user with no tuples never reaches the cycle. A `union all` mutant passed that assertion until the spec also walked into the cycle.

**Costs.**

- **Storage: one tuple for each child.** 1M documents mean 1M `parent` tuples that mirror a column the app already has. We measured it at large scale. The seed took 44 s. The `permissions` tables grew by about 378 MB, from 19.6 MB to 397.6 MB with indexes ([COMPARISON.md](../benchmarks/COMPARISON.md)). The extrapolation from small scale, about 430 MB (450 bytes for each row), was about 14% too high.
- **Parent from the app column.** The walk can read the parent from the column of the app instead of a copy. This avoids the copy, but the walk is generic SQL over `permissions.tuples`. To read `documents.folder_id`, the walk needs dynamic SQL for each type (no plan cache, harder to secure) or a registry of app tables.

  That is the "bring your own data" design. The team rejected it because it was slower and harder to understand. `sync_parent` is the compromise: one source of truth (the app column), copied mechanically.
- **The single-branch policy lists every visible document.** `list_objects('document', 'viewer')` walks to each document one by one. The small-scale case has 10k documents, 20 orgs, and a user with roles in two orgs plus team shares. There the call returns 1,007 IDs in **7.3 ms**, about 7 µs for each visible document. Under pgbench (4 clients, busy machine) the first page took **18 ms p50**, against 2.2 ms for the two-branch policy on the same data.
- **At large scale** (1M documents) a user sees about 20k documents. The measured p50 for `parents_select_page` (4 clients) is **509 ms**, against **3.20 ms** for the two-arm projection policy on the same data (about 160×; [COMPARISON.md](../benchmarks/COMPARISON.md)). An earlier extrapolation of about 150 ms was too low.
- **The two-branch policy** (`org_id = any(scopes) or id = any(shares)`) stays the fast option. Parents then make `check` and `list_subjects` complete, and the hot RLS path does not need them.
- **Every walk does one more probe for each node** (edge 3), even for nodes with no children. Measured at small scale, it costs about 0.1 ms for each check before the plan cache.

**Weaknesses.**

- A move of a document into a folder gives access to the viewers of that folder. If clients can update `folder_id`, the UPDATE policy of the app needs a `with check` that the user can write into the target folder. The extension cannot know that.
- `parent` is a reserved relation name, and `from_parent` matches relations by name on whatever type the parent is. There is no type check that an org has the relation that a folder inherits. A typo gives no access and not an error.
- `grant` rejects usersets and wildcards as parents (`document#parent@team:eng#member` has no meaning).
- `delete_object` on a folder does not remove the `parent` tuples of its children that point at it. `delete_subject('folder', id)` does.

### 12.2 Public access (G11)

**API.** The OpenFGA wildcard: the subject id `*`.

```sql
select permissions.grant('document', 'announcement', 'viewer', 'user', '*');
select permissions.revoke('document', 'announcement', 'viewer', 'user', '*');
```

**How it evaluates.** The walk starts from two nodes, `user:<id>` and `user:*`. So every non-null subject of type `user` reaches whatever `user:*` reaches, also through groups (`team:eng#member@user:*` makes everyone a member). A null subject starts from no nodes and the extension denies it, so anonymous access stays out of scope. `list_subjects` returns `('user', '*')` as a subject, as OpenFGA does. `grant` rejects `*` with a subject relation (`team:*#member`).

**Costs.** One more start node for each walk. The measured difference is zero.

**Weaknesses.**

- A JWT whose `sub` is `*` is that wildcard. It gets only what everyone gets, but apps must never issue it.
- Public access is for each subject type: `user:*` does not cover a `service` subject type.
- A public grant cannot have a scope ("every member of an org" is a group, not a wildcard).

### 12.3 Forbid (G12)

**API.** The OpenFGA exclusion (`define viewer: ... but not blocked`), with the keyword `unless`. A forbid is an ordinary tuple on the relation of the exclusion. Only admins write it (clients cannot execute `grant`, so `52_forbid` checks for `42501`).

```sql
select permissions.define_relation('document', 'blocked');
select permissions.define_relation('document', 'editor', from_parent => '{editor}', unless => '{blocked}');
select permissions.define_relation('document', 'viewer', '{editor}', from_parent => '{viewer}', unless => '{blocked}');

select permissions.grant('document', 'readme', 'blocked', 'user', 'dave');   -- forbid
select permissions.revoke('document', 'readme', 'blocked', 'user', 'dave');  -- lift it
```

**How it evaluates.** Before the walk, `blocked` collects the exclusion tuples of the subject (one index lookup on the subject). The walk then **never enters** an excluded node. It does not reach anything derived through that node either.

A block of Alice on readme removes `readme#editor`, and with it `readme#viewer` through `implied_by`, although she arrived through org → folder parents. A block on a folder relation hides everything inherited through that folder. But a direct grant on a document below it still applies (OpenFGA behaves the same). Because the walk prunes excluded nodes, `check`, `list_objects` and the RLS policy all agree.

`list_subjects` walks backwards. In that direction, exclusions depend on the final subject and not on the path, so it cannot prune. It collects candidates as before. Then it checks again, forwards, only the candidates that hold at least one exclusion tuple. An unblocked subject costs one index probe.

**Costs.** The `blocked` CTE and the anti-join on every step: about 0.13 ms for each check before the plan cache, small after. A subject with many forbids makes the anti-join larger, but the design expects forbids to be rare.

**Weaknesses.**

- **Direct subjects only.** A forbid on a group (`team:contractors#member`) needs the walk itself to decide membership. That is negation inside recursion. `grant` rejects usersets and wildcards on any relation in an `unless` list, and does not ignore them silently. A Cedar `forbid ... when { principal in Group }` cannot be expressed.
- **The model must opt in for each relation.** A relation without `unless => '{blocked}'` ignores `blocked` tuples, and `editor` and `viewer` each need it. If you forget it on one relation, a silent hole results.
- This is not an attribute rule: "deny if `resource.status = 'archived'`" is still RLS SQL (section 12.4).

### 12.4 Conditions (G13)

**API.** Nothing is new in the design. Expiry is the `expires_at` of the grant (already in v0.0.1). Rules over the columns of the app are RLS composition:

```sql
select permissions.grant('org', 'acme', 'member', 'user', 'gina', '', now() - interval '1 day');  -- grants nothing

-- viewers see published documents; editors (and so admins) see drafts too
create policy documents_select on public.documents for select to authenticated using (
    (status = 'published' and id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid)))
    or id = any (array(select unnest(permissions.list_objects('document', 'editor'))::uuid))
);
```

`53_conditions` links documents to the org with `sync_parent('document', 'org', 'org_id')`, so the parent tuple comes from the `org_id` column that the app already has.

**How it evaluates.** The walk skips expired tuples on every edge, forwards and backwards. The status rule is plain SQL on the row. Each `list_objects` call is an InitPlan, so the policy costs two walks for each query, not one for each row.

**Why not evaluate conditions in the design.** It needs a mirror of `status` in `permissions.entities` (a second copy to keep in sync, like parents). It also needs an evaluation of `tuples.condition` at each step, which no longer fits one cached plan. With the status in the row of the app, Postgres filters it for free.

**Weaknesses.**

- **The model and the policy disagree.** `check_for('user', 'carol', 'document', 'draft_doc', 'viewer')` is **true**, because the design does not know about status. Only RLS hides the draft. Every app check outside RLS must repeat the status rule, and `list_subjects` returns too many subjects.
- The rule is in each policy, so a second table with the same rule repeats it.
- `tuples.condition` and `entities` are still unused: the walk ignores a tuple with a condition (default deny).

### 12.5 Tests

`./test/run.sh --impl prototypes/a-tuple-core.sql` gave 14/14 files and 156/156 assertions at the time of the v0.0.2 build. Now it gives 18/18 files and 199 assertions (see [goals.md](../goals.md)). The team broke each new feature one time on purpose ("mutants"). Every mutant failed a spec:

| Mutant | Caught by |
| --- | --- |
| No parent edge in the walk | `50_parents` (7 failed), `52_forbid`, `53_conditions` |
| `sync_parent` ignores updates (a document move) | `50_parents` (1 failed) |
| `union all` instead of `union` (cycles) | `50_parents` (statement timeout), but only after the spec walked into the cycle (section 12.1) |
| No `user:*` start node | `51_public` (3 failed) |
| The walk does not prune excluded nodes | `52_forbid` (5 failed) |
| `list_subjects` does not re-check excluded subjects | `52_forbid` (1 failed) |
| Expiry ignored in the walk | `53_conditions` (Gina), `31_zanzibar_groups` |

The status rule is in the RLS policy of the spec, not in the design, so it has no design mutant.

## 13. Optimizations (session 3)

Session 3 went after the weak spots in [COMPARISON.md](../benchmarks/COMPARISON.md): wide share reads, the single-branch parents policy, and `nest_check`. A had to stay A. Nothing is derived, and there are no closures, membership tables or triggers that maintain caches. Every answer still comes from `tuples` plus a walk at read time.

The semantics did not change. The suite passed at the time of that session (156/156 assertions; now 18/18 files and 199 assertions). The per-user checksums of all four read policies still match B and C at medium wide and large default. The team used fresh `bench/run.sh --only nest_check` seeds with the final prototype. An ad hoc graph gave the same `check_for`, `list_objects_for` and `list_subjects` answers as the design of session 2 for every user, object and relation. The graph had an exclusion in the middle of a parent chain, a wildcard reached through a parent, a group cycle and an expired membership.

**How it was measured.** The team used one throwaway cluster. `bench/run.sh --only ...` seeded the databases with the prototype of session 2. Between pgbench runs, the team swapped the function versions in place with `create or replace`. The data is identical, and the new partial index is present for every version.

Each run is 1 client and 10 s. The versions were interleaved (v0, v1, v2, ... then repeat) for 3 rounds. The tables show the median p50 over the rounds. Two other agents ran benchmarks on the same machine, so the absolute numbers are noisy, but the before and after pairs ran side by side. The baselines in COMPARISON.md used 4 clients, so compare numbers within this section only.

### 13.1 What changed

Each change is separable. The columns add one change at a time, left to right (p50 ms, single client, interleaved):

| workload | before | + VOLATILE lists | + no `distinct` | + pruned walk | + bidirectional check |
| --- | --- | --- | --- | --- | --- |
| medium wide `share_select_page` | 207 | 110 | 91 | 18.2 | 18.1 |
| medium wide `share_list_objects` | 59.4 | 59.4 | 41.6 | 5.05 | 4.98 |
| large `parents_select_page` | 505 | 245 | 178 | 34.6 | 35.5 |
| large `parents_select_count` | 491 | 251 | 193 | 50.6 | 52.2 |
| large `nest_check` | 0.60 | 0.59 | 0.59 | 0.25 | 0.24 |
| medium wide `nest_check` | 1.96 | | | 0.33 | 0.26 |
| medium wide `parents_select_page` | 240 | | | 17.4 | 17.0 |
| medium wide `parents_select_count` | 230 | | | 15.7 | 15.5 |

No other workload got slower (before → after, same method). Medium `rbac_check` went 0.24 → 0.23 and `rbac_select_page` went 0.55 → 0.43. Medium `rbac_select_count` went 0.45 → 0.37 and `rbac_update_one` went 0.71 → 0.54. `write_assign_role`, `write_share` and `write_nest_team` stayed at 0.10.

**1. `list_objects`, `list_objects_for` and `scopes_with_permission` are no longer evaluated at plan time.** EXPLAIN showed that the plan time was equal to the execution time (100 ms each for wide `share_select_page`), with the same buffer count.

The policies call these functions with constant arguments inside `array(select unnest(...))`. To estimate the row count of the unnest, `array_unnest_support` calls `estimate_expression_value`. In estimate mode, the planner pre-evaluates STABLE functions whose arguments are all constants. So the whole walk ran one time at plan time and again at execution. `check` and `has_permission` are not affected, because the planner does not pre-evaluate a boolean qual.

*What the team tried first: VOLATILE.* When you mark the three functions VOLATILE, the planner stops the pre-evaluation. The column "+ VOLATILE lists" above measures this (207 to 110 ms). The cost is that the planner assumes 10 elements and not the real count. No plan changed in these workloads.

But a VOLATILE function has a worse problem, which design B found. Under read committed, a volatile function takes a fresh snapshot for each query that it runs. The grants that it reads can be from a later instant than the rows that the statement filters. So the statement no longer sees one consistent snapshot. STABLE functions read the snapshot of the statement that calls them.

*What it is now: STABLE, plus a volatile default.* The three functions are STABLE again and take one more last argument, `p_unfold boolean default permissions._unfolded_null()`. `_unfolded_null()` is a VOLATILE plpgsql function that returns null. A volatile argument is not a constant, so the planner cannot fold the call. The function itself still reads the snapshot of the statement. `p_unfold` is ignored, and callers keep the old argument lists (`list_objects('document', 'viewer')`).

The team granted `_unfolded_null()` to public with the other functions that clients call, because a default expression runs as the caller. A call that passes all arguments as constants, `list_objects('d', 'v', true)`, is folded again, so nobody must pass the third argument. `test/spec/a/57_volatility.sql` asserts through `pg_proc.provolatile` that every function that an RLS policy calls is STABLE.

The team checked `EXPLAIN (ANALYZE, BUFFERS)` as user 1 on medium wide data. The policy was the share policy `org_id = any (array(select unnest(scopes_with_permission(...))::uuid)) or id = any (array(select unnest(list_objects(...))::uuid))`:

| version | Plan time | Plan buffers |
| --- | --- | --- |
| STABLE, no dummy argument (folded) | 11.7-12.8 ms | 3,564 |
| VOLATILE | 0.23 ms | 109 |
| STABLE + `_unfolded_null()` default | 0.22 ms | 112 |

The 109-112 buffers are catalog lookups, not the walk. At that time, an EXPLAIN on B showed that `scopes_with_permission(text)` of B had no dummy argument. So the wide share policy of B still folded it (3.7-4.1 ms of plan time, 1,000 buffers, medium default). The `ids()` of B did not fold. B fixed this later (`scopes_with_permission(text, jsonb default permissions._unfolded_null())`, [design B](./b-policy-first.md), optimization step 7). The plan buffers are now 112 and the plan time is 0.24 ms.

**2. `list_objects_for` drops `array_agg(distinct ...)`.** `_reach` returns each node one time, so the ids are already distinct. The `distinct` sorted them with the database collation (en_SG.UTF-8 here), which took 25 ms for 6,652 ids. The array is now unordered. The specs compare with `set_eq`, and the policies use only `= any`.

**2b. `collate "C"` on the type, relation and id columns** (`object_types.name`, `relations`, `tuples`, `entities`). The team added it in a later pass, after B found that the default collation en_SG.UTF-8 made text-id comparisons expensive. B-tree probes and joins on a uuid as text go through `strcoll`. Equality, `union` and `= any` do not change under a deterministic collation. Only the order of the arrays changes (the specs compare sets).

Once `distinct` is gone, the hot paths have no sort on collatable text. `_reach` removes duplicates with a hash (`union`), `check_for` works on arrays, and the only sort is the tiny `kinds` loose scan. So the gain is in the index probes. The recursive CTEs (`reach`, and `back` of `list_subjects`) had to mark their non-recursive terms `collate "C"`. Postgres refuses a recursive column when its collation differs from the non-recursive term.

The team measured this with 3 interleaved rounds, 1 client and 10 s (p50 ms). The "before" version is STABLE with the dummy argument. The "after" version has `collate "C"`:

| workload | before (per round) | after (per round) |
| --- | --- | --- |
| medium wide `share_select_page` | 18.09, 17.73, 18.75 | 16.21, 16.24, 16.24 |
| medium default `parents_select_page` | 7.78, 7.84, 7.65 | 7.59, 7.60, 7.59 |

The gain is about 9% on the wide share page (3 of 3 rounds, p95 also lower) and 2-3% on the parents page. The gain on the parents page is inside noise, but the result is never worse. The change stays. The `strcoll` of Linux glibc is slower than the `strcoll` of macOS, so Docker can gain more. C uses uuid columns, so it is not affected (its text columns are model names).

**3. The walk expands only nodes that can have an edge out of them.** Most of what a walk reaches is leaves: the 50 documents of each team, or the 1,000 documents of each folder. The walk of session 2 probed every node three times (tuples where it is the subject, implied relations, children through `parent`). Almost every probe found nothing. Now the walk expands a node only if its (type, relation) has an edge of some kind:

- usersets exist with that subject type and relation;
- it is in the `implied_by` of some relation;
- it is in the `from_parent` of some relation, and that type has parent links.

The usersets and the parent types come from a new partial index, `tuples_edge_kinds_idx` on `(subject_type, subject_relation) where subject_relation <> '' or relation = 'parent'`. A loose index scan reads it (the recursive `kinds` CTE, one index probe for each distinct pair, a handful in practice). Its keys deduplicate: 6.8 MB at large with 1M parent links (404 MB total, was 398) and under 1 MB at medium wide. The walk still returns leaves, and `union` still removes duplicates.

The walk is still one recursive CTE in one statement, close to the shape of session 2. The function is pinned to `plan_cache_mode = force_generic_plan`, because the plan cache always picked custom plans and so planned again on every call (about 0.3 ms). The `blocked` CTE is `materialized`. Without that, the generic plan turned the exclusion anti-join into one index probe for each reached node, after some rolled-back writes had shifted the statistics. Then the wide walk went from 5 ms to 85 ms in the middle of a benchmark run.

The walk alone went from 42 to 4 ms (wide user, 6,795 nodes) and from about 200 to 15–20 ms (large user, 20,038 nodes). A tiny RBAC walk costs about 25 µs more than before (the `kinds` and `expandable` CTEs). The end-to-end RBAC numbers absorb this.

**4. `check_for` is a bidirectional search.** Before, `check_for` was `exists (select from _reach(...))`. The walk runs to completion inside a PL/pgSQL function, so a check cost as much as a list of everything that the subject can reach.

The check of a wide user walked 2,500 documents (45 ms). `has_permission` of a large user walked 20k documents (174 ms) after the seed of the parent links. Now it is a PL/pgSQL breadth-first search from both ends:

- forwards from the subject, along the same edges as `_reach`;
- backwards from the target, through usersets granted the node, the relations in its `implied_by`, and the relations it inherits through its parent.

Each step expands the smaller frontier, with one set-based statement for each step. The frontiers are parallel `text[]` arrays. The search stops when the two sides meet, or when one side runs out. Both sides skip excluded nodes, so neither side finds a path through an excluded node. The tuples of the subject are read one time, for both its exclusions and the first forward step.

Backwards, the search drops direct subjects. They are either somebody else or the tuples of the subject itself. The 1,000 members of a team are dead ends. The first step already followed the tuples of the subject.

Wide `nest_check` went from 1.96 to 0.26 ms. In large `nest_check` the forward walk is already small, so the new walk alone gets it to 0.25 ms.

The search keeps checks cheap when the side of the subject is big. `has_permission` at large scale takes about 0.13 ms in-session. With the new walk and an `exists`, it takes 25 ms. The search is also pinned to generic plans: with custom plans each check cost 0.9 ms, all of it plan time.

### 13.2 Ideas that did not work

- **A level-by-level PL/pgSQL loop over arrays** (one set-based statement for each level of the search, `except` against the visited set) as the `_reach` design. Wide went from 42 to 30 ms, then to 8 ms when the loop classified leaves for each level. But large got worse (31 ms against 15–20 ms for the single statement). The statement overhead, the array unnests and the `except` against a visited set that grows cost more than they saved. The bidirectional check uses this style, because its frontiers stay small.
- **Correlated `exists` probes to classify leaves.** Under the generic plan, the planner estimated that 125k rows satisfy `subject_type = $1 and subject_relation = $2`, and chose a seq scan (900 ms for one large walk). `order by ... limit 1` did not force the index, because the order by is redundant with the equality on a parameter. Semi-joins fixed it, and the loose index scan replaced them.
- **Bidirectional check without forced generic plans:** 0.9 ms against 0.57 before (a new plan on every call).
- **Check by `exists` over the new walk** (no bidirectional search): this is fine for small subjects (large `nest_check` 0.25). It takes 7 ms for a random document check of a wide user. It takes 25 ms for `has_permission` at large scale after the seed of the parent links. The team kept it only as the reference to validate the bidirectional check.
- **Classification of leaves inside the forward step of the bidirectional check:** no measurable gain. The team dropped it for simplicity.
- **Removal of leaves that do not match the requested type** in `list_objects_for`. This needs a second walk function that takes the target, and the CTE never adds leaves of other types. Wide `share_select_page` went from 18.1 to 16.4 ms, because the `scopes_with_permission` arm no longer adds documents to its result. But `share_list_objects` went from 4.9 to 5.3 ms. Both differences are within noise, and the change needs a second walk to maintain. So the team did not keep it.
- **Not tried:** a covering subject index, so the walk can read parent links without heap fetches. An index-only scan still must check `condition` and `expires_at`. Also, the extra columns of such an index disable key deduplication (the subject index is 8 MB at large because of it).

### 13.3 What is left, and why

- **The single-branch parents policy is O(visible documents) by construction.** One `list_objects` call must produce every visible id (about 20k at large). The walk reaches them from 20 folder probes, but each parent link is a `heap fetch` (the subject index does not cover the object columns). The CTE deduplicates 20k rows, and then the policy unnests, casts and probes 20k ids.

  That leaves 35 ms (page) and 52 ms (count) at large, against 9.6 and 22 ms for the baseline of C (4 clients). The extra 17 ms of the count is the 20k-key index scan in the policy, which C pays as well. The projection policy (`folder_id = any(...)`) avoids all of it.
- **Wide `share_select_page` runs two full walks plus a linear filter.** `scopes_with_permission` walks the whole graph of the user to find 2 tenants. `list_objects` walks it again for 10k documents (about 5 ms each). Then the database checks `id = any($1)` against an array of 6.6k elements linearly for each of the about 540 rows that the index scan visits. This takes about 8 ms, measured in the baseline EXPLAIN. The last part is the shape of the policy, the same for every design.
- **Read cost still grows with what the subject reaches.** `list_objects` cost is linear in reached nodes, now with a much smaller constant. Only checks escape it.
- **Small fixed overheads:** a tiny walk pays about 25 µs for the edge-kind scan, and the bidirectional check runs 2–4 statements and not 1. The RBAC workloads did not get slower end to end, because the removal of the plan-time evaluation saved more.
- **Pinned plans are a trade-off.** Generic plans assume 10 elements for each array and a default number of reached rows. They are right for these index-nested-loop shapes and stable across statistics changes, but they never pick a hash join for a huge frontier.
