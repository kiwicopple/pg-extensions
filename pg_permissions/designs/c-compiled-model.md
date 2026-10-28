# Design C: Compiled model

> One of three candidate designs. See [../PLAN.md](../PLAN.md) for the shared goals, requirements and evaluation criteria.

## 1. Summary

The developer declares an authorization model once (types, relations, implications, permissions, which subjects may hold which relation) as JSON and passes it to `permissions.apply_model()`. The extension compiles that model into lookup tables and keeps a materialized "who is in which group" closure up to date with triggers, so every check at read time is two or three indexed lookups with no recursion. All IDs are native `uuid`, and the extension runs no DDL or dynamic SQL after install.

## 2. Core idea

A generic tuple store with a read-time graph walk does all the work on every check: resolve implied relations, expand groups, recurse through nested groups. In an RLS policy that walk runs once per query (fast path) or once per row (per-row check), and it is the part that is hardest to make cheap.

An authorization graph has three axes, and each changes at a different rate:

| Axis | Example | Changes | Size | This design |
| --- | --- | --- | --- | --- |
| Relation axis | `owner` > `admin` > `member`, `editor` implies `viewer`, `update` = `editor` | Rarely (model changes) | Tiny (per type) | **Compiled** into a `satisfies` lookup table at `apply_model()` time |
| Subject axis | Carol is in `eng`, `eng` is in `platform` | Occasionally | principals x groups | **Materialized** into `memberships`, maintained by triggers |
| Object axis | Bob is editor of `readme`; later, `readme` is in folder `docs` | Constantly | Large | **Stored as written**, looked up by index; no fan-out |

The key choice is what *not* to materialize. A full "effective permissions" table (one row per user per object per permission) makes a check a single index probe, but its size is the product of the axes: one org admin over 1M documents is 1M rows, and adding a user to a team that is granted access to 50k documents writes 50k rows inside the app's transaction. Materializing only the subject axis keeps write amplification proportional to *group size*, never to *object count*, and still removes all recursion from reads.

Why this might beat a read-time walk:

- **Reads are flat.** `can()` is: look up the compiled set of relations that satisfy the permission, then probe `tuples` for a direct grant, then join the principal's (pre-computed) groups against `tuples`. No recursive CTE, no depth loop, predictable plans.
- **Typed and validated at write time.** The compiled model rejects `grant('document', x, 'editr', ...)` or granting a `document` as a team member. A tuple store accepts anything and silently denies later.
- **Native `uuid`.** No `id::text` casts in policies, so `documents.id = any(...)` uses the primary key index directly.
- **Changing the role hierarchy is cheap.** Only `satisfies` changes; no grant rows are rewritten.

### Options weighed

| Option | Verdict |
| --- | --- |
| Full effective-permissions table (user x object x permission) | Rejected as default. Product blow-up for org-wide roles and team grants; a hierarchy change rewrites everything. Could be an opt-in later for a hot permission. |
| Generated typed tables per object type (`permissions.document_grants` with an FK to `public.documents`) | Rejected. Needs runtime DDL from a security-definer function, `references` privilege on app tables, and produces tables that `drop extension` does not own or remove. FKs couple the extension to app schema migrations. |
| Extension creates RLS policies itself (`apply_policies()`) | Rejected. Same DDL and ownership problems: the extension owner would need to own or alter app tables. |
| **Static schema, compiled data, materialized memberships** (chosen) | All tables exist at install time. A model compiles to *rows*, not code. The only generated SQL is returned as text by `policy_sql()` for the developer to paste into a migration. |

## 3. Schema

### Model definition format

JSON, because PL/pgSQL can validate `jsonb` without a parser. An OpenFGA-style DSL can be a client-side tool that emits this JSON.

```json
{
  "types": {
    "user": { "principal": true },
    "team": {
      "relations": { "member": ["user", "team#member"] }
    },
    "org": {
      "relations": { "owner": ["user"], "admin": ["user"], "member": ["user", "team#member"] },
      "implies": { "owner": ["admin"], "admin": ["member"] },
      "permissions": { "edit_documents": ["admin"], "view_documents": ["member"] }
    },
    "document": {
      "relations": { "editor": ["user", "team#member"], "viewer": ["user", "team#member"] },
      "implies": { "editor": ["viewer"] },
      "permissions": { "update": ["editor"], "select": ["viewer"] }
    }
  }
}
```

- `relations`: what can be granted, and which subjects may hold it (`user`, or a userset like `team#member`).
- `implies`: holding the key relation also satisfies the listed relations (transitive, cycles rejected).
- `permissions`: named checks, each satisfied by any of the listed relations (after implications). Permissions cannot be granted directly.
- `principal: true`: types whose IDs are end subjects (`current_subject()` returns one). UUIDs are assumed unique across principal types.

### Tables

```sql
create schema permissions;

-- model history; the latest row is the active model
create table permissions.models (
  version     int generated always as identity primary key,
  definition  jsonb not null,
  applied_at  timestamptz not null default now(),
  applied_by  name not null default current_user
);

-- compiled catalog: names map to small ids that never change across model versions
create table permissions.types (
  id         smallint generated always as identity primary key,
  name       text not null unique check (name ~ '^[a-z][a-z0-9_]{0,62}$'),
  principal  boolean not null default false
);

create table permissions.relations (
  id          smallint generated always as identity primary key,
  type_id     smallint not null references permissions.types,
  name        text not null check (name ~ '^[a-z][a-z0-9_.]{0,62}$'),  -- dots allowed: documents.read
  kind        text not null check (kind in ('relation', 'permission')),
  is_userset  boolean not null default false,  -- appears as type#relation somewhere in the model
  unique (type_id, name)
);

-- which subjects may hold a relation (compiled from "relations")
create table permissions.allowed_subjects (
  relation_id          smallint not null references permissions.relations,
  subject_type         smallint not null references permissions.types,
  subject_relation     smallint references permissions.relations,
  unique nulls not distinct (relation_id, subject_type, subject_relation)
);

-- compiled relation axis: holding relation_id satisfies grants_id (reflexive + implies* + permissions)
create table permissions.satisfies (
  grants_id    smallint not null references permissions.relations,
  relation_id  smallint not null references permissions.relations,
  primary key (grants_id, relation_id)
);

-- object axis: grants as written. immutable; change = revoke + grant
create table permissions.tuples (
  id                bigint generated always as identity primary key,
  object_type       smallint not null references permissions.types,
  object_id         uuid not null,
  relation          smallint not null references permissions.relations,
  subject_type      smallint not null references permissions.types,
  subject_id        uuid not null,
  subject_relation  smallint references permissions.relations,
  expires_at        timestamptz,  -- stretch goal, see section 9
  created_at        timestamptz not null default now(),
  unique nulls not distinct (object_type, object_id, relation, subject_type, subject_id, subject_relation)
);
create index tuples_direct on permissions.tuples (subject_id, object_type, relation)
  include (object_id) where subject_relation is null;
create index tuples_userset on permissions.tuples (subject_type, subject_id, subject_relation, object_type, relation)
  include (object_id) where subject_relation is not null;

-- subject axis, materialized: principal is (transitively) in userset set_type:set_id#set_relation
create table permissions.memberships (
  principal_id  uuid not null,
  set_type      smallint not null,
  set_id        uuid not null,
  set_relation  smallint not null,
  primary key (principal_id, set_type, set_id, set_relation)
);
create index memberships_by_set on permissions.memberships (set_type, set_id, set_relation) include (principal_id);
```

All tables: `revoke all ... from public`, and RLS enabled with no policies, so nothing is readable or writable except through the security-definer functions owned by the extension owner.

### Compilation

`apply_model()` validates the JSON (names, references, no `implies` cycles, permissions reference only relations of the same type), upserts `types` and `relations` by name, rewrites `allowed_subjects` and `satisfies`, marks `is_userset`, and inserts a `models` row. `satisfies` is a recursive CTE over `implies` plus one join for `permissions`. For the model above, the `document` rows are:

| grants | satisfied by |
| --- | --- |
| `viewer` | `viewer`, `editor` |
| `editor` | `editor` |
| `select` | `viewer`, `editor` |
| `update` | `editor` |

### Maintaining `memberships`

Only tuples whose relation satisfies an `is_userset` relation (here: `team#member`) touch `memberships`. Document and org grants never do; they are a plain insert.

Statement-level `after insert` / `after delete` triggers with transition tables on `tuples`:

1. Validate new rows against `allowed_subjects` (so even the owner cannot insert ill-typed tuples).
2. If no changed row affects a userset relation, stop.
3. Take `pg_advisory_xact_lock(<permissions constant>)`. If `transaction_isolation = 'repeatable read'`, raise (see section 10).
4. Affected principals `P` = the principal subjects of changed rows, plus current members of any userset subjects (read from `memberships`, which is still in its pre-change state).
5. For each principal in `P`, recompute its full membership set from `tuples` with an upward recursive CTE (`cycle` clause, `max_depth` default 10, raise if a path exceeds it), then delete rows no longer derived and insert new ones.

The same algorithm handles insert and delete, cycles are harmless (the CTE stops on revisits), and cost is `|P| x (memberships per principal)`. Updates to `tuples` are rejected by a trigger.

## 4. Linking to identity

```sql
create function permissions.current_subject() returns uuid
language sql stable
as $$
  select case
    when s ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then s::uuid
  end
  from (select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub',
    nullif(current_setting('permissions.subject_id', true), '')
  ) as s) x
$$;
```

- **Supabase / PostgREST**: no configuration; `sub` is what `auth.uid()` returns. Nothing references the `auth` schema.
- **Plain Postgres**: the app runs `set local permissions.subject_id = '<uuid>'` per transaction. This setting is only as trustworthy as whoever can run `set`, so it is meant for a trusted middle tier, not end users holding database logins.
- **No subject** (anon, missing or non-uuid `sub`): returns `null`, and every check returns `false`.
- **Explicit subject**: every read function takes `subject_id uuid default permissions.current_subject()`.
- **Cleanup**: no FKs to app tables, so the extension ships trigger functions the app attaches:

```sql
-- on the app's user table (on Supabase this could be auth.users; the app writes this, not the extension)
create trigger users_permissions_cleanup after delete on public.profiles
  for each row execute function permissions.on_subject_deleted('id');
-- on any object table
create trigger documents_permissions_cleanup after delete on public.documents
  for each row execute function permissions.on_object_deleted('document', 'id');
```

They read the id column via `to_jsonb(old) ->> tg_argv[n]` (no dynamic SQL) and call `permissions.forget_subject(uuid)` / `permissions.forget_object(text, uuid)`, which delete tuples and fire normal maintenance.

## 5. Public API

```sql
-- model
permissions.apply_model(definition jsonb, dry_run boolean default false, force boolean default false)
  returns table (change text, detail text)            -- the plan; executed unless dry_run
permissions.model() returns jsonb                     -- active definition

-- identity
permissions.current_subject() returns uuid

-- reads: stable, security definer, set search_path = ''
permissions.can(object_type text, object_id uuid, permission text,
                subject_id uuid default permissions.current_subject()) returns boolean
permissions.accessible(object_type text, permission text,
                       subject_id uuid default permissions.current_subject()) returns setof uuid
permissions.who_can(object_type text, object_id uuid, permission text) returns setof uuid
permissions.explain(object_type text, object_id uuid, permission text,
                    subject_id uuid default permissions.current_subject())
  returns table (path text)                           -- slow read-time walk, debugging only

-- writes: security definer, execute revoked from public
permissions.grant(object_type text, object_id uuid, relation text,
                  subject_type text, subject_id uuid, subject_relation text default null,
                  expires_at timestamptz default null) returns void
permissions.revoke(object_type text, object_id uuid, relation text,
                   subject_type text, subject_id uuid, subject_relation text default null) returns boolean
permissions.forget_subject(subject_id uuid) returns bigint
permissions.forget_object(object_type text, object_id uuid) returns bigint

-- maintenance (owner only)
permissions.verify() returns table (principal_id uuid, set_key text, problem text)  -- recompute and diff
permissions.rebuild() returns bigint                                                -- truncate + recompute memberships
permissions.policy_sql(tbl regclass, id_column name, object_type text,
                       select_permission text, update_permission text) returns text  -- text only, never executed
```

`check` is a reserved word in Postgres: `permissions.check(...)` works when schema-qualified, but a bare `check(...)` is a syntax error, so this design uses `can`. `can`, `accessible` and `who_can` raise on unknown type or permission names, so a typo in a policy fails loudly instead of denying silently.

`can()` in full, to show there is no recursion:

```sql
create function permissions.can(
  object_type text, object_id uuid, permission text,
  subject_id uuid default permissions.current_subject()
) returns boolean
language sql stable security definer set search_path = ''
as $$
  with p as (
    select r.type_id, s.relation_id
    from permissions.relations r
    join permissions.types t on t.id = r.type_id
    join permissions.satisfies s on s.grants_id = r.id
    where t.name = can.object_type and r.name = can.permission
  )
  select can.subject_id is not null and exists (
    select 1 from p
    join permissions.tuples t on t.object_type = p.type_id and t.relation = p.relation_id
    where t.object_id = can.object_id and t.subject_relation is null
      and t.subject_id = can.subject_id
      and (t.expires_at is null or t.expires_at > now())
    union all
    select 1 from p
    join permissions.tuples t on t.object_type = p.type_id and t.relation = p.relation_id
    join permissions.memberships m
      on m.set_type = t.subject_type and m.set_id = t.subject_id and m.set_relation = t.subject_relation
    where t.object_id = can.object_id and m.principal_id = can.subject_id
      and (t.expires_at is null or t.expires_at > now())
  )
$$;
```

`accessible()` is the same two branches selecting `t.object_id` with `union`; `who_can()` starts from the object and unions direct principals with `memberships_by_set` lookups.

## 6. Reference scenario

### Model

The JSON in section 3, applied once in a migration: `select * from permissions.apply_model($json$ ... $json$::jsonb);`

### Setup

```sql
\set acme   'ace00000-0000-0000-0000-000000000001'
\set eng    'e0000000-0000-0000-0000-000000000001'
\set readme 'd0c00000-0000-0000-0000-000000000001'
\set alice  'a11ce000-0000-0000-0000-000000000001'
\set bob    'b0b00000-0000-0000-0000-000000000001'
\set carol  'ca000000-0000-0000-0000-000000000001'
\set dave   'da000000-0000-0000-0000-000000000001'

create table public.documents (
  id     uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  title  text not null
);
create index on public.documents (org_id);
insert into public.documents (id, org_id, title) values (:'readme', :'acme', 'readme');

select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'dave');
select permissions.grant('document', :'readme', 'editor', 'user', :'bob');
select permissions.grant('document', :'readme', 'viewer', 'team', :'eng', 'member');
```

Resulting state: 6 rows in `tuples`, 2 rows in `memberships` (carol and dave in `team:eng#member`). The org and document grants wrote nothing else.

### RLS policies

Tenant RBAC is checked at the tenant, using the app's own `org_id` column. In v0.0.1 the extension does not know that a document belongs to an org (that is parent inheritance, section 9), so the policy has two arms.

```sql
alter table public.documents enable row level security;

create policy documents_select on public.documents for select
using (
  id = any (array(select permissions.accessible('document', 'select')))
  or org_id = any (array(select permissions.accessible('org', 'view_documents')))
);

create policy documents_update on public.documents for update
using (
  permissions.can('document', id, 'update')
  or permissions.can('org', org_id, 'edit_documents')
)
with check (permissions.can('org', org_id, 'edit_documents') or permissions.can('document', id, 'update'));

create policy documents_insert on public.documents for insert
with check (permissions.can('org', org_id, 'edit_documents'));
```

`select permissions.policy_sql('public.documents', 'id', 'document', 'select', 'update')` returns the document arm of these statements as text (identifiers quoted with `format('%I')`), for the developer to review and paste.

### The three queries

**Can Bob update `readme`?** `permissions.can('document', :'readme', 'update', :'bob')`. `satisfies(update) = {editor}`; probe `tuples` for (document, readme, editor, bob): found, `true`. The org arm (`edit_documents` on acme for Bob) is false and irrelevant. Through RLS, `update documents set title = 'x' where id = :'readme'` as Bob updates 1 row.

**Which documents can Dave select?** `set local permissions.subject_id = :'dave'; select id from documents;` The first initplan runs `accessible('document', 'select')`: `satisfies(select) = {viewer, editor}`; Dave has no direct tuples; his memberships are `{team:eng#member}`, which joins to the tuple (document, readme, viewer, team:eng#member). Result `{readme}`. The second initplan, `accessible('org', 'view_documents')`, is empty (`satisfies = {member, admin, owner}`, Dave holds none). Postgres does a BitmapOr of `documents_pkey` and the `org_id` index and returns `readme`.

**Who can view `readme`?** `permissions.who_can('document', :'readme', 'select')` returns Bob (direct editor), Carol and Dave (via `memberships_by_set` on `team:eng#member`). The org path is the app's second query in v0.0.1: `who_can('org', :'acme', 'view_documents')` returns Alice and Carol. The union is Alice, Bob, Carol, Dave. Having to union by hand is a real v0.0.1 limitation; parent inheritance removes it.

## 7. Blessed path: the `rbac` preset

The preset API from [PLAN.md §6](../PLAN.md) is a set of functions that edit the active model and call `apply_model()`. The developer never sees the JSON. Two built-in types hold the roles: `app` (one object, the nil UUID `00000000-0000-0000-0000-000000000000`, for app-wide roles) and `tenant` (one object per scope).

### How it maps

| Preset call | What happens |
| --- | --- |
| `create_role('editor', '{documents.edit}', '{viewer}')` | Adds `editor` to `relations` (subjects: `user`) on `app` and `tenant`, `"editor": ["viewer"]` to `implies`, and `editor` to `permissions.documents.edit`. Then calls `apply_model()`. |
| `assign_role(bob, 'editor', acme)` | `grant('tenant', acme, 'editor', 'user', bob)` |
| `has_permission('documents.edit', acme)` | `can('tenant', acme, 'documents.edit')` |
| `scopes_with_permission('documents.read')` | `array(select accessible('tenant', 'documents.read'))` |
| `user_permissions(bob, acme)` | The `permission`-kind relations on `tenant` for which `can()` is true |
| `users_with_role('admin', acme)` | `who_can('tenant', acme, 'admin')` |

The compiled model for the scenario (the `tenant` type is identical to `app`):

```json
{
  "types": {
    "user": { "principal": true },
    "app": {
      "relations": { "viewer": ["user"], "editor": ["user"], "admin": ["user"] },
      "implies": { "editor": ["viewer"], "admin": ["editor"] },
      "permissions": {
        "documents.read": ["viewer"], "documents.edit": ["editor"],
        "documents.delete": ["admin"], "users.manage": ["admin"]
      }
    }
  }
}
```

### RBAC scenario

What the developer writes is the same as in every design (see PLAN.md §6). The differences are UUIDs everywhere and no casts on the column side:

```sql
select permissions.create_role('viewer', '{documents.read}');
select permissions.create_role('editor', '{documents.edit}', '{viewer}');
select permissions.create_role('admin',  '{documents.delete,users.manage}', '{editor}');

select permissions.assign_role(:'alice', 'admin');
select permissions.assign_role(:'bob',   'editor');
select permissions.assign_role(:'carol', 'viewer');

create policy documents_select on documents for select using ((select permissions.has_permission('documents.read')));
create policy documents_update on documents for update using ((select permissions.has_permission('documents.edit')));
create policy documents_delete on documents for delete using ((select permissions.has_permission('documents.delete')));

-- tenant-scoped variant
create policy documents_select on documents for select
  using (org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid)));
create policy documents_update on documents for update
  using (permissions.has_permission('documents.edit', org_id));
```

What's stored underneath: one `models` row per `create_role` call; 14 `relations` rows (3 roles and 4 permissions on each of `app` and `tenant`); `satisfies` rows such as `documents.read` satisfied by `{viewer, editor, admin}`; and one tuple per assignment. Roles aren't usersets, so `memberships` stays empty and none of the trigger machinery runs.

Graduation: the preset adds a `document` type to the model (`editor`, `viewer`, `editor` implies `viewer`, permissions `select` and `update`), which writes catalog rows only. Then `grant('document', <doc id>, 'editor', 'user', dave)` and one extra branch in the select policy: `or id = any (array(select permissions.accessible('document', 'select')))`. The RBAC tuples are untouched.

Queries:

- **Can Carol edit documents?** No. `satisfies(documents.edit) = {editor, admin}` on `app`, and Carol holds `viewer`.
- **What permissions does Bob have in `globex`?** `{documents.read}`.
- **Who are the admins of `acme`?** `who_can('tenant', acme, 'admin')` returns Alice.

### Tested (partly)

`apply_model()` is only described in prose, so the catalog was compiled by hand with a recursive query that mimics it. The rest ran on Postgres 16: the §3 schema, `current_subject()`, the §5 `can()`, a matching `accessible()`, and the preset functions. Carol can't edit; Bob gets `{documents.read}` in `globex`; Bob's edit scopes are exactly `{acme}`. The original name rule (`^[a-z][a-z0-9_]{0,62}$`) rejected `documents.read`, so it now allows dots. Names are only stored as data in this design, never used as SQL identifiers, so dots are safe.

### Fit

- **RBAC is the cheapest case.** Role hierarchies compile into `satisfies`, so a permission check is one lookup plus one index probe. No closure maintenance, because roles aren't groups.
- **A model change per `create_role`.** Each call creates a new model version. That's fine for migrations, but an app that creates roles at runtime (for example customer-defined roles) churns model versions. The preset could also accept every role in one call (`permissions.define_roles(jsonb)`), which matches the model-file style better.
- **UUID only.** It fits Supabase (`auth.users.id` is a UUID), but apps with `bigint` or `text` user IDs can't use it without a mapping table.

## 8. RLS performance

### Read cost

| Operation | Work |
| --- | --- |
| `can()` | 1 `satisfies` lookup (a few rows) + 1 unique-index probe per satisfying relation + (principal's memberships, typically under 50) x index probes on `tuples_userset` |
| `accessible()` | 1 range scan on `tuples_direct` + memberships x range scans on `tuples_userset`; output size dominates |
| `who_can()` | object range scan on the unique index + `memberships_by_set` per userset grant |

No recursion and no depth loop at read time. Cost depends on the principal's group count and the size of the answer, not on graph depth.

### 1M-row `documents`

- Use `col = any(array(select permissions.accessible(...)))`. The array is an initplan computed once per query, and `= any($1)` is indexable, so each arm becomes an index or bitmap scan and the arms combine with BitmapOr. `id in (select ...)` also runs once (hashed subplan) but forces a scan of every row to probe the hash; prefer it only when the accessible set is very large (an admin of an org owning most rows, where a seq scan wins anyway).
- Index `documents (org_id)` for the tenant arm.
- Never put `can()` in a SELECT policy on a big table: it runs per row. Use it for UPDATE/DELETE/INSERT, where Postgres evaluates it on the few target rows.
- Rough expectation (to verify in phase 4): a user with a few hundred direct or team grants scans `tuples` in well under 1 ms; the `documents` side costs the same as `where id = any(...) or org_id = any(...)` written by hand.

### Write cost

| Operation | Rows written |
| --- | --- |
| Grant a user or a team on a document or org | 1 tuple |
| Revoke the same | 1 tuple delete |
| Add a user to team `eng` (eng nested in k ancestor usersets) | 1 tuple + (1 + k) memberships |
| Remove a user from a team | 1 tuple delete + recompute of 1 principal |
| Nest team A (n members) into team B (k ancestors) | 1 tuple + n x (1 + k) memberships, n principal recomputes |
| Change `implies` / `permissions` | rewrite `satisfies` (tens of rows); recompute principals of affected userset relations only |
| Add a relation or type to the model | catalog rows only |

The expensive cases are nesting or un-nesting a large group and changing the implications of a relation that is used as a userset. Both scale with group size, not with object count.

## 9. How later features fit

**Parent inheritance (v0.0.2).** Add tupleset-to-userset to the format: `"relations": {"org": ["org"]}, "permissions": {"select": ["viewer", "org->view_documents"]}`. The parent link is a tuple `(document:readme, org, org:acme)`. Because the model is static, the compiler knows each type's parent chain length. For fixed chains (document to org) `can()` adds one join per hop and `accessible()` adds "objects whose parent is in `accessible(parent_type, perm)`". No object fan-out is materialized. Self-recursive parents (folder in folder) reuse the `memberships` machinery as an ancestor closure (`folder:x` is "in" `folder:y#parent`). `who_can()` then covers the org path, and the two-arm policy can collapse to one arm, although the two-arm form using the app's `org_id` column stays faster for RLS.

**Attribute conditions.** Two kinds. Grant conditions such as expiry live on the tuple (`expires_at`, already in the schema). They work in v0.0.1 for direct object grants. Expiry on *membership* tuples is harder (a principal's membership expires at the max over paths of the min along each path) and is deferred. Resource conditions ("only published documents") belong in the RLS policy on the app's own columns (`and status = 'published'`), where the planner can use indexes. The extension should not copy app attributes.

**CEL.** The compiled approach suggests compiling CEL at `apply_model()` time into SQL text, delivered through `policy_sql()` for review, instead of interpreting CEL per row in PL/pgSQL. A per-row interpreter is possible but slow. Either way the parser is the expensive part and comes later.

**Cedar.** Cedar's entity hierarchy and `principal in Group::"eng"` map directly onto `memberships`, and Cedar actions map onto `permissions`. `forbid` fits as an exclusion list per permission (`"select": {"any": ["viewer"], "but_not": ["blocked"]}`) compiled into a second `excludes` table; `can()` becomes "satisfied and not excluded". Cedar `when`/`unless` clauses over arbitrary attributes do not compile to lookups, so full Cedar compatibility would need an expression evaluator, the same problem as CEL.

## 10. Weaknesses and risks

1. **The write path is the hard part, and the bulk of the code.** Incremental maintenance, isolation checks and model migration are where bugs will live. A missed case causes silent drift (wrong access, possibly a grant that should be gone). `verify()` and `rebuild()` mitigate this but do not remove it. A read-time walk has no drift by construction.
2. **Concurrency needs a global lock.** Two concurrent membership writes can each miss the other's uncommitted rows (Carol added to `eng` while `eng` is nested into `platform`), leaving Carol out of `platform`. v0.0.1 serializes all *membership-affecting* writes with one advisory lock. Plain object grants take no lock. Bulk directory syncs (SCIM) will queue behind each other. Per-key locking is possible but needs careful lock ordering and is deferred.
3. **`repeatable read` is unsupported for membership writes.** The snapshot is fixed before the trigger takes the lock, so the race above can't be fixed there; the trigger raises. `read committed` works (each statement after the lock sees fresh data) and `serializable` works (SSI detects the conflict and aborts one transaction). This surprises users.
4. **Write latency lands in the app's transaction.** Nesting a 10k-member team writes 10k+ rows synchronously. There is no async option without a background worker, which a TLE can't ship.
5. **uuid-only IDs.** Apps with `bigint` or `text` keys can't use it without a mapping table. Supporting other key types would bring back casts or need per-type columns.
6. **No real FKs.** Cleanup relies on triggers the app must remember to attach. Forgetting them leaves orphaned grants, which are harmless until an ID is reused (rare with uuids).
7. **Storage for `memberships`.** It grows as principals x transitive groups. 100k users in 50 groups each is 5M rows, roughly several hundred MB with indexes.
8. **Provenance is lost.** `memberships` says *that* Carol is in `platform`, not *why*. `explain()` has to redo the walk.
9. **Model changes can be heavy.** Changing `implies` on a userset relation, or removing a relation with `force`, recomputes many principals under the global lock in one transaction. Renames look like drop + add unless we add a rename hint.
10. **More SQL in policies in v0.0.1.** The app writes a document arm and an org arm, and unions `who_can()` by hand, until parent inheritance lands.
11. **Assumes uuids are unique across principal types.** `memberships` and direct grants key on the uuid alone.
12. **It is "compiled" only partly.** Checks still go through generic security-definer functions the planner can't see into. The gain is no recursion and typed keys, not inlined SQL per type.

## 11. Implementation phases

1. **Catalog and compiler.** Schema, `apply_model()` validation and `satisfies` compilation (no data yet), `model()`, `current_subject()`. Tests: rejected models (cycles, bad names, dangling references).
2. **Grants and reads without groups.** `grant`/`revoke` with type checking, `can`, `accessible`, `who_can` for direct grants and implications. Reference scenario for Alice and Bob.
3. **Memberships.** Statement triggers, upward recompute, advisory lock, isolation check, depth cap, `verify`, `rebuild`, `explain`. Concurrency tests with two sessions. Full reference scenario.
4. **Lifecycle.** Model diffing (`dry_run`, `force`), `forget_*` and cleanup triggers, `policy_sql`, `expires_at` on direct grants. 1M-row benchmark: SELECT, single-row UPDATE, team nesting writes.
5. **v0.0.2.** Parent inheritance (fixed chains first, then recursive folders), per-key locking if phase 4 benchmarks show lock contention.

## 12. Open questions

1. Is uuid-only acceptable for v0.0.1, or do we need a per-type key kind (`uuid` | `text`) from the start?
2. JSON only, or ship an OpenFGA-style DSL parser in PL/pgSQL as well?
3. When a membership path exceeds `max_depth`: reject the write (proposed) or silently truncate like a read-time walk would?
4. Global lock in v0.0.1, or invest in per-key locking now?
5. Should `memberships` hold a reflexive row per principal so `can()` needs one branch instead of two? That costs a row per principal and requires knowing principals the extension does not otherwise track.
6. Should unknown permission names in `can()` raise (proposed) or return `false`? Raising breaks a query after a model change that removes a permission still used in a policy.
7. How should `apply_model()` express renames, so they don't drop and re-add tuples?
8. Is `policy_sql()` worth shipping, given the developer still pastes the result into a migration?
