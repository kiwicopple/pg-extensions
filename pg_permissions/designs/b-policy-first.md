# Design B: Policy-first

> One of three candidate designs. See [../PLAN.md](../PLAN.md) for the shared goals, requirements and evaluation criteria.

## Summary

Every decision comes from one small policy table. A policy is Cedar-shaped: principal scope, actions, resource type, an optional "role on anchor" requirement, an optional condition, and an effect. Roles, group memberships and parent links are entity data that policies read, and group membership is kept as a precomputed closure at write time. Because of that, a decision is a flat join with no recursion, and the RLS fast path is a partial evaluation: "which resource IDs, or which org IDs, does this policy set let me reach?", computed once per query.

## Core idea

A tuple store with a read-time graph walk puts the authorization logic inside the graph: `editor` implies `viewer` is a rewrite rule, "org admins can edit org documents" is a tupleset rewrite, and the answer to "can X do Y" comes out of a recursive CTE. This design moves that logic into explicit policies and keeps the data simple:

- **Entity data** says who is in what and who holds which role on what: `parents` (Carol is in team `eng`), `role_grants` (Alice holds `admin` on org `acme`), `role_implies` (`editor` implies `viewer` on documents).
- **Policies** say what those facts allow: "anyone holding `member` on a document's org may `select` the document".
- **One evaluator** answers every question by matching policies against the facts. RBAC, ReBAC and attribute rules are different policy shapes, not different engines.

Why this might beat a generic tuple store with a read-time walk:

1. **The 1M documents never enter the permission store.** A policy with `via = 'org'` grants access through the document's `org_id` column. The fast path returns the caller's org IDs, and RLS matches them against `org_id`. A tuple design has to either write one `document#org` tuple per row or special-case this.
2. **No recursion at read time.** Group nesting is precomputed into `ancestors` (depth at most 10, cycles rejected on write). Role implication is precomputed into `role_closure`. A check is a handful of index lookups.
3. **Policy changes are cheap and auditable.** Adding "members can view" is one row and needs no backfill. "Why can Dave see this?" has an answer: a policy name plus the grant that matched.
4. **Forbid, conditions, CEL and Cedar have an obvious home:** the `effect` and `condition` columns of a policy, rather than a new tuple semantic.

The trade-off is that policies are restricted to shapes we know how to partially evaluate into SQL filters. That restriction is deliberate: the policy language is shaped by what we can index.

## Schema

All objects live in a fixed schema `permissions`. Entity IDs are `text` so uuid, bigint and slug keys all fit.

```sql
create schema permissions;

-- optional: attributes for principals (and later resources). only needed for conditions.
create table permissions.entities (
  type  text  not null,
  id    text  not null,
  attrs jsonb not null default '{}',
  primary key (type, id)
);

-- "child is in parent": user in team, team in team, user in global role group.
-- from v0.0.2 also resource hierarchy (document in folder, folder in folder).
create table permissions.parents (
  child_type  text not null,
  child_id    text not null,
  parent_type text not null,
  parent_id   text not null,
  primary key (child_type, child_id, parent_type, parent_id),
  check ((child_type, child_id) <> (parent_type, parent_id))
);
create index on permissions.parents (parent_type, parent_id);

-- transitive closure of parents, maintained by triggers on parents. never written by apps.
create table permissions.ancestors (
  child_type    text     not null,
  child_id      text     not null,
  ancestor_type text     not null,
  ancestor_id   text     not null,
  depth         smallint not null check (depth between 1 and 10),
  primary key (child_type, child_id, ancestor_type, ancestor_id)
);
create index on permissions.ancestors (ancestor_type, ancestor_id);

-- roles are declared per resource type, so typos fail at grant time
create table permissions.roles (
  resource_type text not null,
  role          text not null,
  primary key (resource_type, role)
);

create table permissions.role_implies (
  resource_type text not null,
  role          text not null,   -- holding this role ...
  implies       text not null,   -- ... also gives this one
  primary key (resource_type, role, implies),
  foreign key (resource_type, role)    references permissions.roles,
  foreign key (resource_type, implies) references permissions.roles
);

-- reflexive transitive closure of role_implies. tiny; rebuilt in full on change.
create table permissions.role_closure (
  resource_type text not null,
  role          text not null,   -- granted role
  implied       text not null,   -- role it satisfies (includes itself)
  primary key (resource_type, implied, role)
);

-- "principal holds role on resource". principal may be a user or a group.
create table permissions.role_grants (
  principal_type text not null,
  principal_id   text not null,
  role           text not null,
  resource_type  text not null,
  resource_id    text not null,
  expires_at     timestamptz,
  primary key (principal_type, principal_id, resource_type, resource_id, role),
  foreign key (resource_type, role) references permissions.roles
);
create index on permissions.role_grants (resource_type, resource_id);

create table permissions.policies (
  id               bigint generated always as identity primary key,
  name             text not null unique,
  effect           text not null default 'permit' check (effect in ('permit', 'forbid')),
  -- principal scope
  principal_type   text default 'user',     -- null = any type
  principal_in_type text,                   -- optional: principal must be in this group
  principal_in_id   text,
  -- action and resource scope
  actions          text[] not null,
  resource_type    text not null,
  resource_id      text,                    -- optional: one specific resource
  -- relationship requirement
  roles            text[],                  -- principal must hold one of these roles on the anchor
  via              text,                    -- anchor: null = the resource itself, else a parent type, e.g. 'org'
  -- attribute condition (v0.0.1: jsonb AST; later CEL source in condition_src)
  condition        jsonb,
  condition_src    text,
  enabled          boolean not null default true,
  check (effect = 'permit'),                -- forbid is reserved; constraint dropped in v0.0.2
  check ((principal_in_type is null) = (principal_in_id is null)),
  check (via is null or roles is not null)
);
create index on permissions.policies using gin (actions);

revoke all on all tables in schema permissions from public;
grant usage on schema permissions to public;
```

Closure maintenance (`ancestors`, `role_closure`) is done by `after insert or delete` triggers on `parents` and `role_implies`, under `pg_advisory_xact_lock(hashtext('permissions.closure'))` so concurrent writers can't produce a stale closure. Inserting edge `c -> p` rejects the write if `p = c` or `p` is already a descendant of `c` (cycle), or if any new path would be deeper than 10. Deleting an edge deletes the closure rows for descendants-or-self of `c` and rebuilds just those rows from `parents` with a depth-bounded recursive CTE. The cap is enforced on write, not by truncating at read time, so a check never silently gives a partial answer.

## Linking to identity

The extension stores no users. A subject is a `(type, id)` pair, `type` defaulting to `'user'`.

```sql
create function permissions.current_subject() returns text
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub',  -- postgrest / supabase
    nullif(current_setting('request.jwt.claim.sub', true), ''),                -- older postgrest
    nullif(current_setting('permissions.subject', true), '')                   -- plain postgres
  )
$$;

create function permissions.current_subject_type() returns text
language sql stable as $$
  select coalesce(nullif(current_setting('permissions.subject_type', true), ''), 'user')
$$;
```

- **Supabase**: works with no configuration; `sub` is the same value `auth.uid()` returns, as text. The `auth` schema is never referenced.
- **Plain Postgres**: the app runs `set local permissions.subject = '<user id>'` at the start of each transaction. Any session can set this, so it is exactly as trustworthy as the code that owns the connection, which is also true of the JWT setting.
- **No subject** (`anon`, missing setting): every check returns false and every `ids` call returns `'{}'`. Default deny.
- **Explicit subject**: every check has a `*_for` variant that takes `subject_type, subject_id`. These are `revoke`d from `public`, because otherwise any client could ask "what can Alice see?". The app grants them to trusted roles (on Supabase, `service_role`).
- **User deletion**: `permissions.delete_entity(type, id)` removes the entity, its grants, its `parents` edges (closure follows via trigger) and any policies that name it. For automatic cleanup the app attaches a trigger to its own identity table:

```sql
create trigger cleanup_permissions after delete on public.profiles
  for each row execute function permissions.on_entity_deleted('user', 'id');
-- the function reads to_jsonb(old) ->> tg_argv[1]; no dynamic sql needed.
```

Execute on `on_entity_deleted` is revoked from `public` (Postgres checks it at `create trigger` time), so nobody can attach it to a throwaway table to wipe someone else's grants.

## Public API

Read functions are `stable security definer set search_path = ''`. They have to be `security definer` because callers have no `select` on the tables, and granting `select` would leak everyone's memberships.

```sql
-- per-row check (writes, single rows). resource carries row values the policies may need, e.g. {"org": "<org id>"}
permissions.can(action text, resource_type text, resource_id text, resource jsonb default '{}') returns boolean

-- fast path: ids of resources (via is null) or of anchors (via = 'org') the caller can reach for action
permissions.ids(action text, resource_type text, via text default null) returns text[]
permissions.allows_all(action text, resource_type text) returns boolean   -- policies with no role/resource restriction

-- explicit subject; revoked from public
permissions.can_for(subject_type text, subject_id text, action text, resource_type text, resource_id text, resource jsonb default '{}') returns boolean
permissions.ids_for(subject_type text, subject_id text, action text, resource_type text, via text default null) returns text[]
permissions.who_can(action text, resource_type text, resource_id text, resource jsonb default '{}')
  returns table (subject_type text, subject_id text, policy text)
permissions.explain(subject_type text, subject_id text, action text, resource_type text, resource_id text, resource jsonb default '{}')
  returns table (policy text, matched_grant jsonb)

-- management (security definer, revoked from public)
permissions.define_role(resource_type text, role text, implies text[] default '{}') returns void
permissions.grant_role(principal_type text, principal_id text, role text, resource_type text, resource_id text, expires_at timestamptz default null) returns void
permissions.revoke_role(principal_type text, principal_id text, role text, resource_type text, resource_id text) returns void
permissions.add_parent(child_type text, child_id text, parent_type text, parent_id text) returns void
permissions.remove_parent(child_type text, child_id text, parent_type text, parent_id text) returns void
permissions.set_attrs(type text, id text, attrs jsonb) returns void
permissions.permit(name text, actions text[], resource_type text, roles text[] default null, via text default null,
                   principal_in_type text default null, principal_in_id text default null,
                   resource_id text default null, condition jsonb default null) returns bigint
permissions.drop_policy(name text) returns void
permissions.delete_entity(type text, id text) returns void

-- rls helpers (see "dynamic sql" below)
permissions.rls_expression(action text, resource_type text, id_column text, via_columns jsonb default '{}', id_type regtype default 'uuid') returns text
permissions.apply_rls(tbl regclass, command text, resource_type text, id_column text, via_columns jsonb default '{}', to_role name default 'authenticated') returns void
permissions.lint() returns table (problem text, policy text)
```

**Dynamic SQL.** The evaluator itself uses none. Only `apply_rls` runs `execute`, to create a policy on a table. It is run by the table owner at migration time, builds its statement with `format('create policy %I on %s for %s to %I using (%s)', ...)` where the table is a `regclass` (quoted by its output function), `command` is checked against `select|insert|update|delete`, column names go through `%I` and the action and type go through `%L`. `rls_expression` only returns text, so developers who don't want any `execute` can paste its output into their migration.

**Conditions** in v0.0.1 are a jsonb AST, interpreted in PL/pgSQL with no `execute`: `{"op": "==", "left": {"var": "principal.attrs.plan"}, "right": "pro"}`, with `and`, `or`, `not`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `in`, `has`. Variables are `principal.attrs.*`, `context.*` (from `permissions.context` setting plus `context.jwt` = JWT claims) and `now`. Comparisons use jsonb ordering. Grant expiry is a column on `role_grants`, not a condition, so it costs nothing.

## Reference scenario end to end

IDs: org `acme` = `'00000000-0000-0000-0000-0000000000a1'`, document `readme` = `'00000000-0000-0000-0000-0000000000d1'`. Users are `'alice'`, `'bob'`, `'carol'`, `'dave'` for readability; in Supabase they would be auth user UUIDs.

```sql
create table public.documents (
  id     uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  title  text
);
create index on public.documents (org_id);

-- 1. roles and implication (entity data)
select permissions.define_role('org', 'member');
select permissions.define_role('org', 'admin', '{member}');
select permissions.define_role('org', 'owner', '{admin}');
select permissions.define_role('document', 'viewer');
select permissions.define_role('document', 'editor', '{viewer}');

-- 2. policies (the only place decisions are defined)
select permissions.permit('org members view docs', '{select}',        'document', roles => '{member}', via => 'org');
select permissions.permit('org admins edit docs',  '{update,delete}', 'document', roles => '{admin}',  via => 'org');
select permissions.permit('doc viewers view',      '{select}',        'document', roles => '{viewer}');
select permissions.permit('doc editors edit',      '{update}',        'document', roles => '{editor}');

-- 3. facts
select permissions.grant_role('user', 'alice', 'admin',  'org', '00000000-0000-0000-0000-0000000000a1');
select permissions.grant_role('user', 'carol', 'member', 'org', '00000000-0000-0000-0000-0000000000a1');
select permissions.grant_role('user', 'bob',   'editor', 'document', '00000000-0000-0000-0000-0000000000d1');
select permissions.add_parent('user', 'carol', 'team', 'eng');
select permissions.add_parent('user', 'dave',  'team', 'eng');
select permissions.grant_role('team', 'eng',   'viewer', 'document', '00000000-0000-0000-0000-0000000000d1');

insert into public.documents (id, org_id, title)
values ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1', 'readme');
```

Admins can view because `admin` implies `member` on orgs, so "org members view docs" matches Alice. There is no document row in any permissions table except where a document has its own grant (`readme`).

RLS (this is what `permissions.apply_rls` would generate, written out by hand):

```sql
alter table public.documents enable row level security;

create policy documents_select on public.documents for select to authenticated using (
  (select permissions.allows_all('select', 'document'))
  or id     = any (array(select unnest(permissions.ids('select', 'document'))::uuid))
  or org_id = any (array(select unnest(permissions.ids('select', 'document', 'org'))::uuid))
);

create policy documents_update on public.documents for update to authenticated
  using      (permissions.can('update', 'document', id::text, jsonb_build_object('org', org_id)))
  with check (permissions.can('update', 'document', id::text, jsonb_build_object('org', org_id)));

create policy documents_delete on public.documents for delete to authenticated
  using (permissions.can('delete', 'document', id::text, jsonb_build_object('org', org_id)));
```

Each `(select ...)` is an uncorrelated scalar subquery, so Postgres runs it once as an InitPlan and the per-row work is an array membership test.

**Can Bob update `readme`?** `permissions.can_for('user', 'bob', 'update', 'document', '…d1', '{"org": "…a1"}')`. Candidate policies for `(update, document)`: "org admins edit docs" (anchor = org `…a1`; Bob and his ancestors hold no role there, no match) and "doc editors edit" (anchor = `readme`; Bob holds `editor`, which satisfies `editor` in `role_closure`). Result: true. In RLS, Bob's `update documents set title = ... where id = '…d1'` passes `using` and `with check`.

**Which documents can Dave select?** As Dave, `select * from documents`. `ids('select', 'document')`: Dave's set is `{user:dave, team:eng}` (one lookup in `ancestors`); "doc viewers view" needs `viewer` on the document; `team:eng` holds `viewer` on `…d1`, so the result is `{…d1}`. `ids('select', 'document', 'org')` is `{}`: Dave holds no org role. Dave sees only `readme`. Carol gets `{…d1}` from the first call and `{…a1}` from the second, so she sees every Acme document.

**Who can view `readme`?** `permissions.who_can('select', 'document', '…d1', '{"org": "…a1"}')` runs each matching policy in reverse: find grants on the anchor whose role satisfies the policy roles, then expand group principals downward through `ancestors`.

| subject | policy | via |
| --- | --- | --- |
| alice | org members view docs | `admin` on acme implies `member` |
| carol | org members view docs | `member` on acme |
| bob | doc viewers view | `editor` on readme implies `viewer` |
| carol | doc viewers view | in `team:eng`, which holds `viewer` |
| dave | doc viewers view | in `team:eng`, which holds `viewer` |

A policy with no role or group requirement returns a single `('*', '*')` row instead of enumerating every user.

## Blessed path: the `rbac` preset

The preset API from [PLAN.md §6](../PLAN.md) maps onto B's own concepts almost one to one. Two built-in resource types hold the roles: `app` (one resource, `app:global`, for app-wide roles) and `tenant` (one resource per scope). A role's inheritance is `role_implies`, and a role's permissions become one generated policy per resource type.

### How it maps

| Preset call | Engine call |
| --- | --- |
| `create_role('editor', '{documents.edit}', '{viewer}')` | On both `app` and `tenant`: `define_role(t, 'editor', '{viewer}')` and `permit('rbac:<t>:editor', '{documents.edit}', t, roles => '{editor}')` |
| `assign_role('bob', 'editor')` | `grant_role('user', 'bob', 'editor', 'app', 'global')` |
| `assign_role('bob', 'editor', 'acme')` | `grant_role('user', 'bob', 'editor', 'tenant', 'acme')` |
| `has_permission('documents.edit', 'acme')` | `can('documents.edit', 'tenant', 'acme')` |
| `scopes_with_permission('documents.read')` | `ids('documents.read', 'tenant')` |
| `users_with_role('admin', 'acme')` | `role_grants` joined to `role_closure` on `tenant:acme` |

Inheritance works the way B already defines it: `editor` implies `viewer` in `role_closure`, so the generated `rbac:app:viewer` policy (`documents.read`, roles `{viewer}`) also matches editors and admins. Permissions are B's actions, so nothing new is needed in the evaluator.

### RBAC scenario

What the developer writes is the same in every design:

```sql
select permissions.create_role('viewer', '{documents.read}');
select permissions.create_role('editor', '{documents.edit}', '{viewer}');
select permissions.create_role('admin',  '{documents.delete,users.manage}', '{editor}');

select permissions.assign_role('alice', 'admin');
select permissions.assign_role('bob',   'editor');
select permissions.assign_role('carol', 'viewer');

create policy documents_select on documents for select using ((select permissions.has_permission('documents.read')));
create policy documents_update on documents for update using ((select permissions.has_permission('documents.edit')));
create policy documents_delete on documents for delete using ((select permissions.has_permission('documents.delete')));

-- tenant-scoped variant
create policy documents_select on documents for select
  using (org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid)));
create policy documents_update on documents for update
  using (permissions.has_permission('documents.edit', org_id::text));
```

What's stored underneath: 6 `roles` rows and 4 `role_implies` rows (3 roles and 2 implications on each of `app` and `tenant`), the matching `role_closure`, 6 generated `policies` (one per role per type), and one `role_grants` row per assignment. `parents` and `ancestors` stay empty, so none of the closure triggers run.

Graduation, sharing one `acme` document with Dave:

```sql
select permissions.define_role('document', 'viewer');
select permissions.define_role('document', 'editor', '{viewer}');
select permissions.permit('doc viewers view', '{select}', 'document', roles => '{viewer}');
select permissions.permit('doc editors edit', '{update}', 'document', roles => '{editor}');
select permissions.grant_role('user', 'dave', 'editor', 'document', '<doc id>');

-- select policy gains one branch
create policy documents_select on documents for select using (
  org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid))
  or id  = any (array(select unnest(permissions.ids('select', 'document'))::uuid))
);
```

The RBAC rows are untouched. Graduating is where B's second concept appears: on the `zanzibar` side the developer writes policies explicitly, which RBAC users never had to do.

Queries:

- **Can Carol edit documents?** No. Only `rbac:app:editor` grants `documents.edit`, and Carol's `viewer` doesn't satisfy `editor` in `role_closure`.
- **What permissions does Bob have in `globex`?** `{documents.read}`.
- **Who are the admins of `acme`?** Alice.

### Tested (partly)

This doc only describes the evaluator, so the test used a minimal `can`/`ids` written from the rules above: permit policies with no `via`, `role_closure`, and `ancestors`. It ran on Postgres 16 against the schema and identity functions from this doc. Every answer matched: Carol can't edit; Bob gets `{documents.read}` in `globex`, edit scopes `{acme}`, read scopes `{acme, globex}`; the admins of `acme` are `{alice}`; 6 policies were generated. The test checks the mapping, not B's real evaluator.

### Fit

- **Better than expected.** `role_implies` is exactly "inherits", and permissions are just actions. The preset is a thin layer like Design A's.
- **Generated policies sit next to hand-written ones.** The preset owns the `rbac:*` policies, so `policies` needs a `managed_by` column (or a name convention the management functions enforce), so that `drop_policy` can't break a role. Changing a role's permissions rewrites its two generated policies.
- **RBAC checks are flat joins**, with no recursion and no closure maintenance.
- **The second concept is deferred, not removed.** RBAC users never see policies, but the moment they graduate they meet both facts and policies at once.

## RLS performance

**What is fast**

- `ids()` cost depends on how many grants the caller holds, not on table size. It is one query: subject plus its ancestors (index on `ancestors` PK), joined to `role_grants` (PK prefix on principal), `role_closure` and the few matching `policies`. No recursion. Expected well under a millisecond for a user with tens of grants.
- `can()` is the same join restricted to one anchor: a handful of index probes. Fine for single-row `update`/`delete` and `with check`.
- Org-level access costs one array element (the org id) no matter how many documents the org has. That's the case where tuple designs hurt most.
- Policy edits and role grants need no maintenance writes.

**What is slow or needs care**

- **Large ID arrays.** `id = any($1)` over an InitPlan param is a linear scan of the array for each row the planner checks (hashed `= any` only applies to constant arrays). If the planner uses an index on `id` this is fine; on a seq scan with a 50k-element array it is not. For big sets the generated expression could switch to `id in (select unnest(...)::uuid)`, which Postgres runs as a hashed SubPlan, O(1) per row. **Measured, this is a trap for small sets:** in the Design A benchmark (1M documents, 20k visible per user) the hashed form stopped Postgres using the `org_id` index, and counting visible documents went from 2.2 ms to 88.8 ms. Any cut-off has to be measured with `bench/run.sh`.
- **Bulk updates** with the per-row `can()` call it once per row. For `update ... where org_id = X` across many rows, apps should use the `ids` form in the `using` clause too.
- **Resource-attribute conditions** (for example `resource.status == 'published'`) can't be partially evaluated into an id set in v0.0.1. Those policies are only honoured by `can()`, and `lint()` flags them. v0.0.3 compiles them to SQL predicates inside `rls_expression`.
- **`who_can`** fans out through group descendants. It is an admin and debugging function, not an RLS function.

**Write cost**

| write | cost |
| --- | --- |
| `grant_role`, `revoke_role`, `set_attrs`, `permit` | one row; no closure work |
| `define_role` | rebuild `role_closure` for one resource type (tens of rows) |
| `add_parent(c, p)` | inserts `|descendants-or-self(c)| x |ancestors-or-self(p)|` closure rows; cycle and depth check first |
| `remove_parent` | deletes and rebuilds closure for descendants of `c` |

All parent writes serialize on one advisory lock. That's fine for membership churn in the tens per second, not for thousands.

**On a 1M-row `documents` table**: index `org_id` and `id`. A user in 3 orgs with 20 direct document grants gets `org_id = any('{3 ids}')` (bitmap index scan on `org_id`) or `id = any('{20 ids}')` (index scan on `id`). Postgres reads only the rows it will return. Reading 300k rows a user can legitimately see is still 300k rows; the filter adds an array test per row, not a function call per row. What we must avoid is a plain `using (permissions.can(...))` on select, which costs about 1M x (several index probes) and is the trap every policy engine falls into. Docs and `lint()` should say so.

## How later features fit

**Parent inheritance (v0.0.2).** Documents are put in folders with `parents` edges (or a `folder_id` column), folders nest via `parents`, and a policy says `roles => '{viewer}', via => 'folder'`. The anchor becomes "any ancestor folder". `ids('select', 'document', 'folder')` returns the folders where the caller holds `viewer` plus all their descendant folders (one join on `ancestors` by `ancestor_id`). RLS matches `folder_id = any(...)`. If documents are linked by `parents` edges instead of a column, `ids` returns document ids directly, at the cost of one closure row per document per level. The evaluator only changes in how it resolves the anchor; no new tables.

**Attribute conditions.** Principal and context conditions are evaluated once per query inside `ids()` (they don't depend on the row), so they stay on the fast path. Expiring grants use `role_grants.expires_at`. Resource conditions: see above.

**Forbid.** Drop the `check (effect = 'permit')` constraint. `can()` returns false if any forbid matches (forbid wins, no priority ordering, the same as Cedar). The fast path gains a deny side: `rls_expression` adds `and not (id = any(denied_ids) or org_id = any(denied_org_ids))`. A forbid with a resource-attribute condition forces the per-row path for that table, and `lint()` must say so.

**CEL.** `condition_src` stores CEL text. A small PL/pgSQL parser for a CEL subset (field access, comparisons, `in`, `&&`, `||`, `!`, `has()`) compiles it to the same jsonb AST at write time. The evaluator doesn't change, and a parse error rejects the policy on insert rather than at query time.

**Cedar compatibility.** A policy row maps to one Cedar policy. `principal_in` becomes `principal in Team::"eng"`. `roles` + `via` maps by exporting each `(resource, role)` pair as a synthetic entity `Role::"org/acme/member"`, `role_implies` as `Role::"org/acme/admin" in Role::"org/acme/member"`, and adding an attribute on the anchor: `permit (principal, action == Action::"select", resource is Document) when { principal in resource.org.member };`. Export of our subset to Cedar is feasible. Import of arbitrary Cedar is not: only policies that fit our shapes (scope + role-on-anchor + condition) can be loaded, and the rest are rejected with a reason.

## Weaknesses and risks

- **Two concepts to learn.** A developer has to write policies and facts, where a tuple design only needs tuples (plus a schema). For the reference scenario that is 4 policies and 5 role definitions on top of the grants.
- **RLS has to mirror the policies' `via` values.** If someone adds a policy `via => 'project'`, the `documents` RLS policy must gain `or project_id = any(...)` or the new policy silently grants nothing on select. It fails closed, but it is confusing. `apply_rls` and `lint()` (which flags `via` values with no column mapping) reduce this, but it is a real coupling between data in a table and DDL.
- **`can()` and `ids()` are two implementations of one semantics.** If they disagree, select and update behave differently. Phase 1 needs a property test: for random data, `can(x) = x in ids()`.
- **The policy language is restricted.** Principal scope, role on the resource or one named anchor, condition. Anything else (for example "the author of the document", an `owner_id` column) is either a role grant per row or a per-row `can()` with `resource => {"owner": owner_id}` plus a condition, which is off the fast path in v0.0.1. A generic Cedar engine would accept such policies and just be slow; we refuse or flag them instead.
- **Closure write amplification.** Adding a big group into another big group writes the product of their sizes. Moving a subtree rebuilds it. The single advisory lock serializes all membership writes. Groups of thousands of users nested a few levels deep are fine; org-chart-sized graphs with constant churn are not.
- **Text IDs and casts.** `(...)::uuid[]` fails the whole query if any stored id for that type isn't a uuid. We should record an id type per resource type and validate on `grant_role`.
- **Large id arrays** when a user has tens of thousands of direct grants. Mitigated by the hashed-subplan form, but unmeasured.
- **Security definer everywhere.** The read functions run as the extension owner. A bug in them is a privilege bug. `search_path = ''` and the absence of dynamic SQL in that path limit the damage. The functions are also not `leakproof` (that needs a superuser), which can restrict some planner optimizations around RLS quals.
- **Context from settings.** `permissions.context` and `permissions.subject` can be set by any session on plain Postgres. On Supabase the JWT wins, but a condition on `context.*` should only use JWT claims or values the server sets.

## Implementation phases

1. **Core (v0.0.1).** Identity functions; `entities`, `parents`, `ancestors` with triggers, cycle and depth checks; `roles`, `role_implies`, `role_closure`; `role_grants` with expiry; `policies` (permit only); jsonb condition interpreter; `can`, `ids`, `allows_all` and `_for` variants; `who_can`, `explain`; management functions; privileges. Tests: the reference scenario, the `can`/`ids` agreement property test, cycles, depth 10 and 11, user deletion, a client trying to write tables directly.
2. **RLS tooling.** `rls_expression`, `apply_rls`, `lint`; pgbench comparison on 1M rows of the `= any` form vs the hashed-subplan form vs a naive per-row `can()`.
3. **v0.0.2.** Parent inheritance via `via => '<parent type>'` with transitive anchors; `forbid` policies with deny sets in the fast path.
4. **v0.0.3.** Resource-attribute conditions compiled to SQL predicates in `rls_expression`; CEL subset parser into the AST.
5. **Later.** Cedar export, and import of the supported subset; action groups (`edit` implies `select`) as Cedar action hierarchies.

## Open questions

1. Should role implication stay a table, or should it just be policies (`roles => '{viewer,editor}'`)? The table is shorter for apps but is a second place where meaning lives.
2. Should `via` resolve only through the `resource` jsonb argument and the RLS column mapping, or also through `parents` edges for resources? Allowing both gives two sources of truth for "which org is this document in".
3. Explicit subject: is `revoke` on `*_for` functions enough, or should they check membership of a dedicated `permissions_admin` role?
4. Where is the cut-off between emitting `= any(array)` and the hashed-subplan form, and can `rls_expression` pick it, or must the developer?
5. Should `apply_rls` exist at all (it is the only `execute` in the extension), or should we ship only `rls_expression` and leave DDL to migrations?
6. Is one global advisory lock acceptable for closure maintenance, or do we need per-component locks from day one?
