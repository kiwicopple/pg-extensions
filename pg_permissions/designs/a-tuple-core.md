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
permissions.define_relation(object_type text, relation text, implied_by text[] default '{}')
```

Writing tuples:

```sql
permissions.grant(object_type, object_id, relation, subject_type, subject_id, subject_relation default '', expires_at default null)
permissions.revoke(object_type, object_id, relation, subject_type, subject_id, subject_relation default '')
permissions.delete_subject(subject_type, subject_id)   -- removes all tuples for that subject
permissions.delete_object(object_type, object_id)      -- removes all tuples on that object
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
- **Who can view `readme`?** `list_subjects('document', 'readme', 'viewer')` returns Bob (editor implies viewer), Carol and Dave (via `team:eng`). It does **not** return Alice, even though she can view it via the org: that path lives in the RLS policy, not in the tuples. See §9.

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

- **Parent inheritance (v0.0.2):** add a tuple `(document:readme, org, org:acme)` and a rule on `relations` such as "`viewer` also comes from `org#view_documents`" (Zanzibar's tuple-to-userset). The evaluator gets a third step in the `lateral`. The RLS policy then needs only the document path.
- **Attribute conditions (Model 3):** evaluate `tuples.condition` against `entities.attributes` and request context. Tuples with a false condition are skipped during the walk.
- **CEL (#9):** an alternative format for `condition`. It's a parser plus evaluator in the policy layer, not a separate extension. The JWT helpers fold into the identity layer.
- **Cedar (#10):** `entity_parents` maps onto tuples (`member` relations). Permit/forbid with priority is a policy-layer feature on top.
- **ABAC (#8):** subject and resource attributes live in `entities`. Rules become conditions.

## 9. Weaknesses and risks

- **Org-level access lives in RLS policies until v0.0.2.** Until parent inheritance exists, "admins can edit all org documents" is half model and half policy SQL. `list_subjects` gives incomplete answers in the meantime (it misses Alice in the scenario).
- **Parent links duplicate app data.** Parent inheritance needs a `(document, org, org:acme)` tuple that mirrors `documents.org_id`. Apps need a trigger to keep them in sync, or they will drift.
- **No foreign keys to app tables.** IDs are `text`, so deleting a document doesn't delete its tuples unless the app calls `delete_object`. Orphaned tuples are harmless but accumulate.
- **Read-time cost grows with nesting.** Deep or wide group hierarchies make every check walk more rows. Zanzibar systems solve this with caching and precomputed indexes, which this design doesn't have.
- **Unions only.** The graph walk can only add access. `forbid` (Cedar) and "deny if" rules don't fit naturally and need a separate pass in the policy layer. That layer is the least designed part of this proposal.
- **Weak validation.** Nothing stops granting `document#viewer` to a subject type that makes no sense (e.g. `org:acme` with no relation). OpenFGA's type restrictions would need an extra column on `relations`.

## 10. Implementation phases

1. **Core and identity**: schema, `define_*`, `grant`/`revoke`/`delete_*`, `current_subject_id()`.
2. **Relationship evaluator**: `check` with implied relations and usersets, then `list_objects` and `list_subjects`.
3. **Examples and tests**: an `examples/` folder with the reference scenario. SQL tests run against the local Supabase stack (`make reset && make tle.install.pg_permissions`) and against plain Postgres, to prove there's no Supabase dependency.
4. **Docs**: the README covers install, both models end to end, RLS patterns, and the identity sync recipe.
5. **Stretch: Model 3 conditions**: `condition` and `entities` evaluation in `check`.

## 11. Open questions

1. **Text IDs**: every RLS call casts `id::text`. Fine for the PoC, but worth benchmarking on a 1M-row table before v0.1.
2. **Wildcard subjects** (`user:*` for public access, as in OpenFGA): include in v0.0.1 or defer?
3. **SECURITY DEFINER inside a TLE**: confirm the function owner on Supabase/dbdev installs has read access to `permissions.*` while clients don't.
4. **Name `check`**: `check` is a reserved word. `permissions.check(...)` works, but a bare `check(...)` (for example with `permissions` on the `search_path`) is a syntax error. Rename to `can`, or document that it must always be schema-qualified?
5. **Subject type restrictions**: add an `allowed_subjects` column to `relations` in v0.0.1 for validation, or wait?
