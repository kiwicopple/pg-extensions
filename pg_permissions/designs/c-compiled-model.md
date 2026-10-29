# Design C: Compiled model

> One of three candidate designs. See [../PLAN.md](../PLAN.md) for the shared goals, requirements and evaluation criteria.
>
> **Status (2026-10-28):** built as [`prototypes/c-compiled-model.sql`](../prototypes/c-compiled-model.sql). It passes every shared spec file and its own `test/spec/c/` files (30–33, 40, 50–55): 18 files, 217 assertions. This document describes what was built. Section 13 lists where the build departed from the earlier draft, and why; section 15 lists the session 3 optimizations (2026-10-29).

## 1. Summary

The developer declares an authorization model once, as JSON, and passes it to `permissions.apply_model()`. The model lists types, relations, implications, permissions, parent types, exclusions (forbid) and which subjects may hold each relation. The extension compiles the model into lookup tables, and triggers keep two derived tables up to date: a materialized "who is in which group" table, and the ancestor closure of container objects such as folders. Every read is then a fixed number of indexed lookups with no recursion. All IDs are native `uuid`. Apart from the install script, the extension runs no DDL and no dynamic SQL.

## 2. Core idea

A generic tuple store with a read-time graph walk does all the work on every check: resolve implied relations, expand groups, recurse through nested groups and parent chains. In an RLS policy that walk runs once per query (fast path) or once per row (per-row check).

An authorization graph has three axes, and each changes at a different rate:

| Axis | Example | Changes | Size | This design |
| --- | --- | --- | --- | --- |
| Relation axis | `admin` implies `member`, `edit` = `editor` or the parent's `edit` | Rarely (model changes) | Tiny | **Compiled** into the `satisfies` table by `apply_model()` |
| Subject axis | Carol is in `eng`, `eng` is in `platform` | Occasionally | principals × groups | **Materialized** into `memberships` by triggers |
| Container axis | folder `plans` is in folder `specs`, which is in org `acme` | Occasionally | containers × depth | **Materialized** into `ancestors` by `set_parent()` |
| Object axis | Bob is editor of `readme`; `readme` is in folder `specs` | Constantly | Large | **Stored as written** (`tuples`, `parents`), looked up by index |

The key choice is what *not* to materialize. A full "effective permissions" table (user × object × permission) makes a check a single index probe, but its size is the product of the axes: one org admin over 1M documents is 1M rows. Materializing only group membership and the closure of *containers* keeps write amplification proportional to group size or folder-tree size, never to the number of documents.

| Option | Verdict |
| --- | --- |
| Full effective-permissions table | Rejected. Product blow-up for org-wide roles and team grants; a hierarchy change rewrites everything. |
| Generated typed tables per object type | Rejected. Runtime DDL from a security-definer function, ownership problems, couples the extension to app migrations. |
| Extension creates RLS policies itself | Rejected. Same DDL and ownership problems. |
| **Static schema, compiled data, materialized memberships and container closure** (built) | All tables exist at install time. A model compiles to rows, not code. |

## 3. Model format

JSON, because PL/pgSQL can validate `jsonb` without a parser. An OpenFGA-style DSL could be a client-side tool that emits this JSON. The model below is the one in `test/spec/c/50_parents.sql` and `52_forbid.sql` combined:

```json
{
  "types": {
    "user": { "principal": true },
    "team": { "relations": { "member": ["user", "team#member"] } },
    "org": {
      "relations":   { "admin": ["user"], "member": ["user", "team#member"] },
      "implies":     { "admin": ["member"] },
      "permissions": { "edit": ["admin"], "view": ["member"] }
    },
    "folder": {
      "parent":      ["org", "folder"],
      "relations":   { "editor": ["user", "team#member"], "viewer": ["user", "team#member"] },
      "implies":     { "editor": ["viewer"] },
      "permissions": { "edit": ["editor", "parent->edit"], "view": ["viewer", "parent->view"] }
    },
    "document": {
      "parent":      ["folder", "org"],
      "relations":   { "editor": ["user", "team#member"], "viewer": ["user", "user:*", "team#member"],
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

| Key | Meaning |
| --- | --- |
| `principal: true` | IDs of this type are end subjects (`current_subject_id()` returns one). UUIDs are assumed unique across principal types. |
| `relations` | What can be granted, and to whom: a principal type (`user`), every principal of a type (`user:*`, public access), or a userset (`team#member`). Plain non-principal subjects (`"org"`) are rejected; use a userset. |
| `implies` | Holding the key relation also satisfies the listed relations of the same type. Transitive. Cycles are rejected. |
| `permissions` | Named checks. An array is "any of these". `{"any": [...], "but_not": [...]}` adds exclusions: holding a `but_not` relation vetoes the permission (forbid). Items are relations of the same type, or `parent->P`. Permissions can't be granted directly and can't list other permissions. |
| `parent` | The types an object of this type may have as its parent. Each object has at most one parent, set with `set_parent()`. Types that appear in some `parent` list are **containers**. |
| `parent->P` | Inside permission `P` only: whoever has `P` on the parent has `P` here. |

### Compile-time rules

`apply_model()` rejects a model, with the offending names in the message (SQLSTATE `22023`), when:

- a type, relation or permission name is invalid (types `^[a-z][a-z0-9_]{0,62}$`; relations and permissions also allow dots, so `documents.read` works), a type has unknown keys, or a value has the wrong shape;
- a name is both a relation and a permission on the same type (this is also how the `rbac` preset gets "role and permission names can't overlap" for free);
- a subject names an unknown type, an unknown relation, or a non-principal type without `#relation`, or uses `type:*` on a non-principal type;
- `implies` names something that isn't a relation of the same type, or has a cycle;
- a permission has no granting item, an item is not a relation of the same type, or `parent->X` appears inside a permission not named `X`, or in a type without `parent`;
- **parent inheritance isn't all-or-nothing:** if `X.P` contains `parent->P`, every parent type of `X` must define `P`, and if that parent type has parents of its own, its `P` must contain `parent->P` too;
- `type:*` is allowed on a relation that feeds a userset (it would make every user a group member, which can't be materialized);
- the model would make an existing expiring grant feed a userset;
- it defines or redefines the preset-owned types `app` or `tenant` (see section 8). Naming one as a parent (`"parent": ["tenant"]`) is allowed.

The all-or-nothing rule is what makes the compiled form exact. Without it, "`P` on any ancestor" could over-grant. For example, if `folder.view` didn't inherit but `document.view` did, a document's grandparent org would wrongly count. With the rule, the permission checked at every hop up the chain is the same `P`, so one flat set of `(type, relation)` pairs describes every ancestor.

## 4. Schema

Ten tables in schema `permissions`. All have `revoke all ... from public` and RLS enabled with no policies, so they are reachable only through the extension's security-definer functions.

| Table | Rows | Notes |
| --- | --- | --- |
| `models` | One per applied model version | Full definition (including the preset's types), `applied_at`, `applied_by`. The latest row is active. |
| `types` | One per type | `smallint` id that stays the same across versions; `principal`, `container`. |
| `relations` | One per relation or permission | `kind`, `is_userset` (appears as `type#rel`), `feeds_userset` (granting it changes memberships, e.g. `org.admin` when `admin` implies `member` and `org#member` is a userset). |
| `allowed_subjects` | Compiled `relations` lists | `(relation, subject_type, subject_relation, wildcard)`. |
| `parent_types` | Compiled `parent` lists | |
| `satisfies` | The compiled relation axis | `(grants_id, relation_id, via_parent, forbid)`: a tuple with `relation_id` on the object itself (`via_parent = false`) or on any ancestor (`true`) satisfies, or with `forbid` vetoes, `grants_id`. |
| `tuples` | One per grant | `(object_type, object_id uuid, relation, subject_type, subject_id uuid, subject_relation, expires_at)`. `subject_id` null = public grant. Unique on `(object_id, relation, subject_type, subject_id, subject_relation)` with `nulls not distinct`. Partial covering indexes for direct, userset and public lookups. |
| `parents` | One per object that has a parent | Primary key `(object_id, object_type)`: one parent per object. Indexed by parent. |
| `memberships` | principal × transitive userset | `(principal_id, set_type, set_id, set_relation, depth)`, where `depth` is the shortest path (1 = direct). Indexed by principal (PK) and by set. |
| `ancestors` | container × ancestors | Only for objects of **container** types. Leaf objects (documents) store just their parent link. |

For the `document` type of the model above, `satisfies` holds (relation names shown instead of ids):

| grants | relation | via_parent | forbid |
| --- | --- | --- | --- |
| `document.view` | `document.viewer`, `document.editor` | false | false |
| `document.view` | `document.blocked` | false | true |
| `document.view` | `folder.viewer`, `folder.editor`, `org.member`, `org.admin` | true | false |
| `document.edit` | `document.editor` | false | false |
| `document.edit` | `document.blocked` | false | true |
| `document.edit` | `folder.editor`, `org.admin` | true | false |
| `document.viewer` | `document.viewer`, `document.editor` | false | false |

If `folder.view` had its own `but_not`, those rows would appear for `document.view` too, with `via_parent = true, forbid = true`.

### Compilation (`apply_model`)

1. Validate shape, names, references and the rules in section 3 (nothing is touched yet).
2. If the definition equals the active one, return `unchanged`.
3. Take the graph advisory lock. Remove types and relations that are gone, along with their tuples and parent links. This needs `p_force => true` if any exist; otherwise the call raises `2BP01` and names how many rows would go.
4. Upsert types and relations by name (ids are stable). Rewrite `allowed_subjects`, `parent_types`, `container`, `is_userset`.
5. Rewrite `satisfies`: implication closure for relations (recursive CTE), then each permission's own-type rows (permit and forbid), then the `via_parent` rows. Those are the own-type rows of `P` on every type reachable up the `parent_types` graph.
6. Set `feeds_userset`. Check the post-compile rules (public on userset feeders, expiring feeders). Delete tuples and parent links the new model no longer accepts (needs force).
7. If what memberships depend on changed (the userset relations and what feeds them, or the principal types), rebuild `memberships`. If `parent_types` changed, rebuild `ancestors`.
8. Insert a `models` row. Return the plan: `(change, detail)` rows such as `add relation | document.blocked`, `rebuild memberships | ...`, `version | 7`.

`p_dry_run => true` runs the same code inside a subtransaction and rolls it back at the end, so the plan it returns is exact, including validation errors. The one shortcut: it reports a rebuild without performing it.

## 5. Maintaining derived data

### Memberships

Statement-level `after insert` and `after delete` triggers on `tuples`, with transition tables:

1. Type-check every new row against `allowed_subjects` and `relations` (right type, relation not a permission, allowed subject, no expiry on userset feeders). Even the owner can't insert an ill-typed tuple (`23514`).
2. If no changed row has a `feeds_userset` relation, stop. Object grants end here: one insert, no lock.
3. Take the graph lock (below).
4. **Insert:** apply a delta (since session 3, section 15). The new rows are (members of each new tuple's subject, from the stored memberships) × (the tuple object's usersets and every set above them, one upward walk over the current tuples), with depth = depth in the subject + 1 + distance above the object. Each row is upserted keeping the smaller depth; nothing is deleted. If a new shortest path would be longer than 10, raise `54001` (the write is rejected; this resolves the old open question 3).
5. **Delete:** affected principals `P` = principal subjects of deleted rows, plus current members of any userset subject of a deleted row (at this point `memberships` still reflects the state before the statement). Recompute every principal in `P` (direct sets from the principals' own tuples, then one upward walk per distinct direct set, capped at 10 hops), then apply the difference: delete rows no longer derived, upsert new rows and changed depths.

Cycles are harmless because the walks stop revisiting at the depth cap, and a set reachable at depth ≤ 10 keeps that depth. Diamonds are handled: an insert keeps the least depth over every path, and a delete recomputes each affected principal from scratch. Updates are rejected by a row trigger, except for `expires_at`, which re-granting changes (expiry can't affect memberships, see section 9). `truncate` is rejected.

Why the insert delta is complete: take any new path from a principal to a set, and the first new tuple on it (subject S, object O). The part before it uses only old tuples, so the principal is S or was already a stored member of S; the part after it is an upward walk from O. Every candidate is a real path, so nothing is over-granted. Why `P` is complete for a delete: take any principal whose membership changes, and the changed tuple closest to it on the path. Either that tuple's subject is the principal, or the prefix of the path before it uses only unchanged tuples, so the principal was already in that tuple's subject set.

### Ancestors (container closure)

`set_parent(type, id, parent_type, parent_id)` upserts the parent link. For a container object it also takes the graph lock and computes the object's subtree (itself plus its container descendants, from the current closure). It rejects the move if the new parent is in that subtree (a cycle, `23514`), then recomputes the closure rows of the subtree. A chain deeper than 10 raises `54001`. `unset_parent` and `forget_object` do the same. Moving a leaf object (a document) is one upsert, with no lock and no closure rows.

So moving a folder rewrites rows only for its sub-folders. Documents under it are found at read time through `parents` (one index lookup), so they never get closure rows.

### Concurrency

Every write that changes memberships or the container closure (userset grants and revokes, container moves, model changes that trigger a rebuild, `rebuild()`) runs `_lock_graph()`:

- It raises `0A000` under **repeatable read**. The snapshot is fixed before the lock is taken, so a concurrent writer's committed rows would stay invisible and the derived rows would drift.
- Otherwise it takes one transaction-level advisory lock. In **read committed**, each statement after the lock sees fresh data. **Serializable** is allowed: SSI aborts one of two conflicting writers (`40001`, retry).

Checked with two real sessions (session 1 adds Carol to `eng` and holds the transaction open; session 2 nests `eng` into `platform` meanwhile). With the lock, `verify()` reports no drift afterwards. With the lock removed from a copy of the prototype, the same race leaves Carol's `platform` membership missing, and `verify()` reports it. Plain object grants take no lock.

### Drift: `verify()` and `rebuild()`

`verify()` recomputes all memberships and the full container closure from `tuples` and `parents` and diffs them against the stored rows. It returns `(kind, member_id, set_key, problem)` with `problem` in `missing`, `extra`, or a depth mismatch. No rows means no drift. `rebuild()` takes the lock, throws both derived tables away and recomputes them. Both are full recomputes, so they cost O(all memberships) and are maintenance tools, not something to run per request.

## 6. Identity

```sql
permissions.current_subject_id() returns uuid   -- JWT sub, else permissions.subject_id setting, else null
permissions.current_subject_type() returns text -- permissions.subject_type setting, else 'user'
```

The JWT wins over the setting (PLAN.md §3). A value that isn't a uuid counts as no subject, and every check for a null subject is false. Nothing references the `auth` schema.

Cleanup: there are no FKs to app tables. The app attaches the shipped trigger functions, which read the id column through `to_jsonb(old)` (no dynamic SQL):

```sql
create trigger profiles_permissions_cleanup after delete on public.profiles
  for each row execute function permissions.on_subject_deleted('id');
create trigger documents_permissions_cleanup after delete on public.documents
  for each row execute function permissions.on_object_deleted('document', 'id');
```

They call `forget_subject(uuid)` (deletes every grant to the principal) and `forget_object(type, uuid)` (deletes grants on the object, grants to its usersets, and its parent links; its children become roots). Execute on them is revoked from public, so only roles the app trusts can attach them.

## 7. Public API

```sql
-- model (admin)
permissions.apply_model(p_definition jsonb, p_dry_run boolean default false, p_force boolean default false)
  returns table (change text, detail text)
permissions.model() returns jsonb                                   -- active full definition

-- reads for the current subject (clients, RLS): stable, security definer
permissions.can(object_type text, object_id uuid, permission text) returns boolean
permissions.accessible(object_type text, permission text) returns uuid[]

-- reads for any subject (admin only: they would leak other users' access)
permissions.can_for(subject_type text, subject_id uuid, object_type text, object_id uuid, permission text) returns boolean
permissions.accessible_for(subject_type text, subject_id uuid, object_type text, permission text) returns uuid[]
permissions.who_can(object_type text, object_id uuid, permission text) returns setof uuid   -- null row = public (user:*)

-- writes (admin)
permissions.grant(object_type, object_id uuid, relation, subject_type, subject_id uuid,
                  subject_relation text default null, expires_at timestamptz default null)
permissions.revoke(object_type, object_id uuid, relation, subject_type, subject_id uuid,
                   subject_relation text default null) returns boolean
permissions.grant_many(object_type, relation, subject_type, object_ids uuid[], subject_ids uuid[],
                       subject_relation text default null) returns bigint   -- bulk load, session 3
permissions.grant_public(object_type, object_id uuid, relation, subject_type text default 'user')
permissions.revoke_public(object_type, object_id uuid, relation, subject_type text default 'user') returns boolean
permissions.set_parent(object_type, object_id uuid, parent_type, parent_id uuid)
permissions.unset_parent(object_type, object_id uuid) returns boolean
permissions.forget_subject(subject_id uuid) returns bigint
permissions.forget_object(object_type, object_id uuid) returns bigint

-- maintenance (admin)
permissions.verify() returns table (kind text, member_id uuid, set_key text, problem text)
permissions.rebuild() returns bigint
```

- "permission" in the read functions accepts relations too (`can('document', x, 'viewer')`).
- **Unknown names in reads return false or empty**, they don't raise. This matches the `rbac` preset rule (PLAN.md §6): a policy naming a dropped permission denies instead of breaking every query. Writes validate everything and raise on unknown names.
- A forbid is a grant of a `but_not` relation, so it is admin-only like every grant (tested: `authenticated` gets `42501`).
- `grant_public` is a separate function so a null `subject_id` from a failed lookup can never grant public access (`grant` raises on null).
- **`who_can` reports a public grant as one null row**, meaning "every principal of the grant's type". It never enumerates users. This is the counterpart of A's `('user', '*')` row from `list_subjects`, encoded as C stores it (`tuples.subject_id` null) because `who_can` returns bare uuids. As in A, the null row is not net of per-principal forbids: a blocked user is dropped from the concrete rows, but can't be listed as an exception to "everyone". A public forbid (`blocked: ["user:*"]`) empties the whole list, null row included. Public grants on a parent count. Callers that test membership with `x = any (...)` ignore the null row; check for it explicitly (`c/54_who_can_public`). Until 2026-10-28 public grants were silently left out, so `who_can` under-reported who had access.
- `can` is used rather than `check` because `check` is a reserved word: `permissions.check(...)` works schema-qualified, but a bare `check(...)` is a syntax error.

Reads have no recursion. `can()` is one statement: resolve the permission's `satisfies` rows; build the candidate objects (the object itself, its parent from `parents`, and the parent's rows in `ancestors`); then probe `tuples` for a direct grant, a public grant, or a grant to a userset the subject is in (`memberships` joined on the unique index). The result is "some permit and no forbid". `accessible()` runs the same three branches from the subject side, then expands grants on containers to the target type's objects through `ancestors` and `parents`. It returns permitted minus forbidden. `who_can()` starts from the object and expands usersets through `memberships_by_set`.

### RLS fast path

`accessible()` returns `uuid[]` natively. The fastest correct policy form is:

```sql
id = any ((select permissions.accessible('document', 'view'))::uuid[])
```

The `::uuid[]` is a no-op, because the type already matches, so no cast node remains. Its only job is to make Postgres treat the subquery as an array expression. The plan shows `InitPlan 1` and `Index Cond: (id = ANY ($0))`. Measured against 1M documents and a user with 300 grants, 100–400 pgbench runs per form, on a busy machine (other agents were running tests, so read the ratios, not the absolute numbers):

| Policy form | Page of 50 | Count | Notes |
| --- | --- | --- | --- |
| `id = any ((select f())::uuid[])` | 0.36–0.48 ms | 0.47–0.62 ms | **Use this.** No cast and no re-array. |
| `id = any (array(select unnest(f())))` | 0.55–0.69 ms | 0.66–0.78 ms | Correct; pays for unnest and rebuilding the array. |
| `id = any (array(select unnest(f())::uuid))` | 0.55–0.71 ms | 0.66–0.82 ms | The PLAN.md §4 form for `text[]` functions; same as above here. |
| `id = any (f())` | 0.53–0.57 ms | 0.68–0.77 ms | Works only while it lands in an `Index Cond`, where it is evaluated once. In a filter it would run once per row. Don't rely on it. |
| `id = any ((select f()))` | error | error | `operator does not exist: uuid = uuid[]`: parsed as a subquery comparison. |
| `id in (select unnest(f()))` | 47 ms | 57 ms | Hashed subplan, seq scan of every row. |

PLAN.md §4's warning about `((select f())::uuid[])` (a per-row cast) applies only when `f()` returns `text[]`. For a `uuid[]` function the cast disappears. `scopes_with_permission` returns `text[]` (it's part of the shared preset API), so tenant policies keep the §4 form.

## 8. Blessed path: the `rbac` preset

The preset API from PLAN.md §6 is a set of functions that edit the active model and recompile it. The developer never sees the JSON. Two preset-owned types hold the roles: `app` (one object, the nil uuid, for app-wide roles) and `tenant` (one object per scope). `apply_model()` refuses definitions that define or redefine `app` or `tenant` (it checks the top-level type keys), and carries them over from the active model. A type can still name `tenant` as a parent: `"parent": ["tenant"]` on `folder`, with `set_parent('folder', f, 'tenant', acme)`, lets `parent->documents.read` reach the roles assigned on `acme`, so preset roles flow down to per-object resources. The usual all-or-nothing parent rule applies: `tenant` must define the permission, which it does once `create_role` has put it in a role. `test/spec/c/55_tenant_parent.sql` covers this. So graduating to per-object sharing is one `apply_model()` call with only the app's own types, and the roles are untouched. `user` is added if the developer's model omits it.

| Preset call | What happens |
| --- | --- |
| `create_role('editor', '{documents.edit}', '{viewer}')` | Adds relation `editor` (subjects `user`), `"editor": ["viewer"]` in `implies`, and `editor` to permission `documents.edit`, on both `app` and `tenant`. Recompiles (one new model version). |
| `drop_role('editor')` | Fails (`2BP01`) while another role's `implies` lists it. Otherwise removes the relation, removes it from permission lists, drops permissions left empty, and recompiles with force, which deletes its assignments. |
| `assign_role(bob, 'editor', acme)` | `grant('tenant', acme, 'editor', 'user', bob)`. Unknown role raises `22023`. |
| `has_permission('documents.edit', acme)` | `can` restricted to `kind = 'permission'` on `tenant:acme`. |
| `has_role('viewer')` | `can` restricted to `kind = 'relation'` on `app`, so inherited roles count and permission names don't. |
| `scopes_with_permission('documents.read')` | `accessible('tenant', ...)` as `text[]`. |
| `user_permissions(bob, acme)` | The `permission`-kind relations on `tenant` for which `can_for` is true. |
| `users_with_role('admin', acme)` | `who_can('tenant', acme, 'admin')` as text. |

**Signatures take `text` IDs, exactly as in PLAN.md §6, not `uuid`.** The shared specs require it: they compare `scopes_with_permission` and `users_with_role` with `text[]` arrays (`tap.set_eq` needs the same element type on both sides), and they pass `org_id::text` and `md5(...)::uuid::text`. Text-to-uuid is an explicit-only cast, so a `uuid` parameter would fail with "function does not exist". Underneath, everything is uuid. On reads, a scope that isn't a uuid gives false; on writes it raises `22P02`. `has_permission(text, uuid)` and `has_role(text, uuid)` overloads exist so policies can pass a uuid column without a cast. An unknown literal still resolves to the `text` version, so there is no ambiguity.

Roles aren't usersets, so `memberships` stays empty for an RBAC-only app and none of the trigger machinery runs past step 2. The RBAC scenario (PLAN.md §6) and graduation (`c/40_graduation`) pass unchanged; every RBAC answer is identical before and after adding sharing.

- **A model version per `create_role`.** Fine for migrations. An app that creates roles at runtime churns versions; a batch `define_roles(jsonb)` would fit better.
- **UUID only.** Apps with `bigint` or `text` user IDs need a mapping table.

## 9. v0.0.2 features (PLAN.md §10), as built

| Goal | How C does it | Spec |
| --- | --- | --- |
| G10 parents | `"parent": [...]` + `"parent->P"`; `set_parent()`; container closure. The RLS policy is a single branch: `id = any ((select permissions.accessible('document', 'view'))::uuid[])`. `who_can` includes parent-derived subjects. Cycles are **rejected on write** (`23514`). | `c/50_parents` 13/13 |
| G11 public | `"viewer": ["user", "user:*"]`, `grant_public()` / `revoke_public()`. Null subject is denied. `who_can` returns one null row for public access (section 7). | `c/51_public` 7/7, `c/54_who_can_public` 8/8 |
| G12 forbid | `{"any": [...], "but_not": ["blocked"]}`; the forbid is `grant(..., 'blocked', ...)`. Forbid beats parent-derived access. | `c/52_forbid` 9/9 |
| G13 conditions | Resource conditions stay in RLS on the app's column: `id = any (accessible('document','edit')) or (status = 'published' and id = any (accessible('document','view')))`. Grant expiry is `expires_at` on the tuple. | `c/53_conditions` 6/6 |

**Forbid semantics are deny-overrides across the inheritance chain (Cedar-like), not OpenFGA's exact `but not`.** A `but_not` relation of permission `P` on any type in the chain vetoes `P` for everything that inherits `P` from that object. A forbid on a folder therefore blocks its documents even for someone who is a direct viewer of a document. In OpenFGA, `document.view = (viewer or view from parent) but not blocked` would subtract the folder's `blocked` only from the folder-derived part. The flat compiled form can't express that difference, and "forbid always wins" is easier to reason about. Exclusion relations must be relations of the permission's own type.

**Expiry** works on any grant that doesn't feed a userset. Expiring group memberships (or anything that implies one) are rejected at `grant()` (`0A000`) and at compile time. A principal's membership would expire at the max over paths of the min along each path, which the materialized table doesn't model.

**Not built:** `explain()` (a provenance walk for debugging), `policy_sql()` (generated policy text), rename hints in `apply_model()`, per-key locking. CEL would compile into SQL text at model time rather than be interpreted per row; Cedar `when`/`unless` over arbitrary attributes doesn't compile to lookups. Both are unchanged from the earlier draft.

## 10. Reference scenario

The model in section 3 without `folder`, `parent` and `blocked` (it's spelled out in `test/spec/c/30_zanzibar_reference.sql`), then:

```sql
select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'dave');
select permissions.grant('document', :'readme', 'editor', 'user', :'bob');
select permissions.grant('document', :'readme', 'viewer', 'team', :'eng', 'member');
```

Result: 6 tuples, 2 membership rows (Carol and Dave in `team:eng#member`).

- **Can Bob update readme?** `can_for('user', bob, 'document', readme, 'editor')`: one probe, true.
- **Which documents can Dave select?** `accessible_for('user', dave, 'document', 'viewer')`: his one membership joins the userset grant, giving `{readme}`.
- **Who can view readme?** `who_can('document', readme, 'viewer')`: Bob, Carol and Dave.

With parents (`c/50_parents`), `set_parent('document', readme, 'org', acme)` (or through a folder) makes Alice and Carol appear in `who_can`. The policy then collapses to the single branch shown in section 9 instead of a hand-written `org_id` arm. At scale the two-arm policy on the app's `org_id` column is still the faster form for org-wide roles (section 11).

## 11. Performance

### Reads

| Operation | Work |
| --- | --- |
| `can()` | `satisfies` rows (a few) × candidate objects (1 + parent chain, ≤ 11) × unique-index probes, plus memberships (typically < 50) × probes. |
| `accessible()` | Range scans of `tuples_direct`, `tuples_public`, and `tuples_userset` per membership; then, for grants on containers, `ancestors` and `parents` lookups. The output size dominates. |
| `who_can()` | Object-side probes plus `memberships_by_set` per userset grant. |

Small-scale benchmark (`./bench/run.sh --impl prototypes/c-compiled-model.sql --duration 3`: 10k documents, 1,000 users, 50 teams; machine shared with other test runs, so this is a sanity check, not a comparison):

| Workload | p50 ms | p95 ms | Budget (p95) |
| --- | --- | --- | --- |
| `rbac_check` | 0.23 | 0.31 | 1 |
| `rbac_select_page` | 0.40 | 0.53 | 2 |
| `rbac_select_count` | 0.36 | 0.51 | 2 |
| `rbac_update_one` | 0.67 | 0.87 | 4 |
| `write_assign_role` | 0.13 | 0.17 | 1 |
| `share_list_objects` | 0.22 | 0.35 | 2 |
| `share_select_page` | 0.52 | 0.63 | 5 |
| `write_share` | 0.10 | 0.14 | 1 |

Large-scale comparison (serial runs, 4 pgbench clients; full tables and checksums in [bench/baselines/COMPARISON.md](../bench/baselines/COMPARISON.md)). Per-user visible-document checksums match A and B at every scale. p50 ms at large (1M documents, 10k users):

| Workload | A | B | C |
| --- | --- | --- | --- |
| `rbac_check` | 0.28 | 0.33 | 0.23 |
| `share_select_page` | 2.02 | 1.21 | 0.95 |
| `parents_proj_select_page` (two-arm projection) | 3.20 | 1.44 | 1.01 |
| `parents_select_page` (single branch) | 509 | 197 | 9.57 |
| `write_nest_team` (4 clients) | 0.15 | 285 | 333 |
| `nest_check` | 0.70 | 2.60 | 0.26 |

These are the session 2 serial baselines, measured before the session 3 optimizations. Section 15 has interleaved before/after numbers for the writes, the single-branch parents policy and the wide seed; a serial rerun hasn't been done yet.

C has the fastest reads on every sharing and parents workload and is flat on `nest_check` (0.22-0.28 ms at every scale and shape). RBAC is a wash across engines. In the wide shape (medium, 50 teams per user) `share_select_page` is A 221, B 70, C 10.7 ms, but C's wide sharing seed took 183 s against 35 s for B and 10 s for A. C's per-document parents seed at large took 16 s and added about 160 MB (A 44 s / 378 MB, B 167 s / 736 MB).

**Org-wide access through parents** makes `accessible()` return every document id under the org. For an admin of an org with 1M documents that's a 1M-element array per query, the same cost A or B pay for an equivalent single-branch policy. The two-arm policy (`org_id = any (scopes...) or id = any (accessible(...))`) avoids it and stays the recommended form for large tenants. Measured at large scale (about 20k visible documents per user): the single-branch `parents_select_page` is 9.57 ms p50 for C, against 1.01 ms for the two-arm projection (about 9×). A pays 509 ms and B 197 ms for the same single-branch shape, so C's materialized `accessible()` degrades far less, but the projection is still the cheaper form.

### Writes

| Operation | Rows written | Lock |
| --- | --- | --- |
| Grant or revoke on a document or org (not a userset feeder) | 1 tuple | none |
| Add a user to team `eng` (eng in k ancestor usersets) | 1 tuple + (1 + k) memberships | global |
| Nest team A (n members) into team B (k ancestors) | 1 tuple + n × (1 + k) memberships, written as a delta (section 15) | global |
| Move a document | 1 parent link | none |
| Move a folder with s sub-folders | 1 parent link + closure rows of s + 1 folders | global |
| Model change touching usersets or what feeds them | full `memberships` rebuild | global |
| Model change touching `parent` lists | full `ancestors` rebuild | global |
| Other model changes (roles, permissions, new types) | catalog rows only | global (brief) |

`write_nest_team` (nest the 1,000-member team `nest-src` into a random team of the 50-team tree, rolled back each time; small scale): **about 14 ms per nest with 1 client** (3,000 membership rows for a 3-level target; single-client, small scale). **With 4 clients, latency is about 61 ms and tps stays flat at 65–70**: the global lock serializes them. A plain object grant (`write_share`) is about 0.1 ms. This is the write where C pays and A doesn't. At large scale with 4 clients the measured `write_nest_team` is **333 ms p50** (A 0.15 ms, B 285 ms), because concurrent nests queue on the global lock; `COMPARISON.md` has no single-client large-scale figure.

## 12. Weaknesses and risks

1. **The write path is the bulk of the code and where bugs live.** The prototype is about 1,990 lines (A is about 620): compiler about 590, derived-data maintenance about 400, preset about 250 (session 3 added the insert delta and `grant_many`, about 120 lines). A missed case causes silent drift. `verify()` and `rebuild()` mitigate this; a read-time walk has no drift by construction. Four deliberately broken copies (no propagation on nesting, forbid ignored, parent traversal cut to one hop, `verify()` blind) were each caught by the specs, but drift bugs outside the tested shapes would not be.
2. **One global lock** for every membership, container-move and rebuild write. Bulk directory syncs (SCIM) and concurrent team edits queue: nesting a 1,000-member team holds it for about 14 ms (single client, small scale; 4 clients at large scale queue to a 333 ms p50). Since the session 3 delta it holds it for about 15 ms at large too, and 4 clients queue to about 60 ms (section 15). Per-key locking needs careful lock ordering and is deferred; section 15 explains why it wouldn't help the benchmark's nest.
3. **`repeatable read` is refused for those writes.** It surprises users. ORMs that default to it would have to switch for permission writes.
4. **Write latency lands in the app's transaction.** Nesting a 10k-member team writes 10k+ rows synchronously. A TLE can't ship a background worker.
5. **Model changes that touch usersets rebuild all memberships** under the lock, in one transaction. Fine for small apps; at 5M membership rows it's a maintenance window.
6. **Parent links duplicate app data.** The app's `folder_id` column and `set_parent()` must be kept in sync (the specs do both by hand). A helper trigger could read the column like `on_object_deleted` does, but it isn't built. One parent per object.
7. **Single-branch parent policies materialize large arrays** for org-wide roles (section 11).
8. **Forbid is deny-overrides** (section 9), not OpenFGA's exact `but not`; exclusions are same-type relations only.
9. **No expiring group memberships.** Rejected rather than silently wrong.
10. ~~**`who_can` omits public grants.**~~ Fixed: `who_can` returns one null row for a public grant (section 7; `c/54_who_can_public`).
11. **uuid only**, and uuids are assumed unique across principal types (memberships key on the uuid alone).
12. **Storage:** memberships grow as principals × transitive groups (100k users in 50 groups is 5M rows).
13. **Provenance is lost.** Memberships say *that* Carol is in `platform`, not why (only the shortest depth). `explain()` isn't built.
14. **"Compiled" only partly.** Checks still go through generic PL/pgSQL functions the planner can't see into. The gains are no recursion and typed keys, not SQL inlined per type.

## 13. Deviations from the earlier draft

| Earlier draft | Built | Why |
| --- | --- | --- |
| Read functions take `subject_id uuid default current_subject()` | Separate admin-only `can_for`, `accessible_for`; `who_can` admin-only | A defaulted parameter lets any client ask about any user (PLAN.md §3). |
| `current_subject()` | `current_subject_id()` (uuid) and `current_subject_type()` | Shared identity contract (`01_identity`). |
| `can`, `accessible`, `who_can` raise on unknown names | Return false or empty | Same rule as the preset (PLAN.md §6); resolves open question 6. Writes still validate. |
| Preset takes `uuid` IDs | `text` IDs as in PLAN.md §6, plus `uuid` overloads for `has_permission` and `has_role` | The shared specs and the bench seed need the text signatures (section 8). |
| Preset edits "the active model" | `app` and `tenant` are reserved (can be parents, not defined); `apply_model()` carries them over | Otherwise graduating with a model that omits them would drop every role. |
| `accessible()` returns `setof uuid` | Returns `uuid[]`, used as `= any ((select f())::uuid[])` | Measured fastest (section 7). |
| Parent link as a tuple (`document:readme#org@org:acme`), syntax `org->view_documents` | Dedicated `parents` table (one parent per object), `"parent": [...]` + `parent->P` inside `P` only, all-or-nothing up the hierarchy | Single parent makes a move one upsert and the closure a chain. The same-name rule keeps the flat compiled form exact (section 3). |
| Recursive parents reuse the memberships machinery | Separate `ancestors` table, for container types only | Leaf objects never get closure rows, so moving a folder doesn't fan out to documents. |
| Forbid as `excludes` table | `forbid` flag on `satisfies`, deny-overrides along the chain | One table; semantics in section 9. |
| `user:*` was an open question | `type:*` in the model, `grant_public`, `tuples.subject_id` null; `who_can` returns a null row for it | G11. Separate function so a null can't grant public access. The null row matches A's `user:*` row in `list_subjects` without changing `who_can`'s `setof uuid` type. |
| Membership expiry deferred | Rejected on write and at compile time | Fail loudly instead of drifting. |
| Max depth: reject or truncate (open question) | Reject (`54001`); `memberships.depth` stores the shortest path | Open question 3. |
| `tuples` immutable | Only `expires_at` can change (re-granting updates it); `truncate` blocked | `31_zanzibar_groups` re-grants with a new expiry. |
| `verify()` returns `(principal_id, set_key, problem)` | `(kind, member_id, set_key, problem)`, covering memberships and ancestors | Two derived tables. |
| `explain()`, `policy_sql()` | Not built | Not needed by any goal; open question 8 stands. |

## 14. Open questions

1. Is uuid-only acceptable, or do we need a per-type key kind (`uuid` | `text`)?
2. JSON only, or also an OpenFGA-style DSL (client-side)?
3. Global lock, or per-key locking now? Measured: `write_nest_team` is 333 ms p50 with 4 clients at large scale (`COMPARISON.md`), about 60 ms after session 3 (section 15); no per-key locking prototype exists to compare against.
4. Should `memberships` hold a reflexive row per principal so `can()` needs one branch instead of two? That costs a row per principal and requires knowing principals the extension doesn't otherwise track.
5. How should `apply_model()` express renames, so they don't drop and re-add tuples?
6. Is deny-overrides the forbid semantics we want, or do we need OpenFGA's exact `but not`?
7. Should the extension ship a trigger that keeps `parents` in sync with an app column (`folder_id`)?
8. Is `policy_sql()` worth shipping, given the developer still pastes the result into a migration?

## 15. Optimizations (session 3)

Goal: improve C's weak spots without changing its semantics or its character (materialized memberships, `verify()`/`rebuild()`, typed model, one global lock). Workloads, seeds and the benchmark seed's API are unchanged.

**How it was measured.** Two other agents were optimizing A and B on the same laptop at the same time, so absolute numbers are noisy. Every figure below is **interleaved**: the original prototype (kept as `bench/results/optc/c-orig.sql`, git-ignored) and the new one were run alternately, old, new, new, old, with `bench/run.sh --only <workloads> --tag opt-c` (Postgres 16.4, local, no Docker). Each cell gives the two runs. Reads and writes use `--clients 1` unless marked 4 clients. The big gaps (several times) are far outside the noise; the small ones (under about 10%) are not. Internal breakdowns come from `EXPLAIN (ANALYZE, BUFFERS)` and `auto_explain` (nested statements) on a persistent large-scale database, plus pgbench runs that alternated between an old and a new copy of it.

| Workload (p50 ms unless noted) | Before | After | Change |
| --- | --- | --- | --- |
| `write_nest_team`, large, 1 client | 90.2, 91.1 | 15.5, 15.9 | 5.8× faster |
| `write_nest_team`, large, 4 clients | 367, 351 (10-11 tps) | 58.2, 60.5 (59-67 tps) | 6× faster |
| `write_nest_team`, medium wide, 1 client | 41.1, 41.6 | 15.8, 15.4 | 2.7× faster |
| `write_nest_team`, medium deep, 1 client (one pair) | 119.5 | 21.6 | 5.5× faster |
| `parents_select_page` (single branch), large | 9.41, 9.52 | 4.98, 4.87 | 1.9× faster |
| `parents_select_count` (single branch), large | 23.7, 18.6 | 14.1, 13.9 | 1.3-1.7× faster |
| Wide sharing seed, medium (seconds) | 185.1, 198.1 | 24.6, 24.2 | 7.8× faster |
| Default sharing seed, large (seconds; all 4 runs each) | 4.2-6.0 | 2.0-2.3 | about 2× faster |
| `share_select_page`, medium wide | 11.42, 11.50 | 11.23, 10.85 | not slower (within noise) |
| `share_list_objects`, medium wide | 3.65, 3.56 | 3.37, 3.25 | about 8% faster |
| `nest_check`, medium deep (one pair) | 0.26 | 0.30 | unchanged (`can()` wasn't touched) |

Checksums: every run, old and new, printed the same per-phase checksums (rbac, sharing, parents_proj, parents) and reported "same" against A's and B's latest equivalence files, at large default, medium wide and medium deep. On the persistent database, the new `_accessible()` returned the same sorted id set as the old one for all 10,000 users and three permissions (`documents.read`, `viewer`, `editor`). After the wide seed, the `memberships` table (657,256 rows) had the same md5 over `(principal, set, depth)` for the old code, the new code and the new bulk API.

### 15.1 Insert trigger: a delta instead of a recompute

**What.** `_tuples_after_insert` no longer recomputes the affected principals. Insertions only add paths, so memberships can only gain rows or get shorter. The trigger now writes (members of the new tuple's subject, read from the stored memberships) × (the object's usersets and every set above them, from one upward walk), with depth = depth in the subject + 1 + distance above the object. It upserts with `on conflict ... do update ... where excluded.depth < memberships.depth` and deletes nothing. Section 5 has the completeness argument (the first new tuple on any new path). It also covers multi-row inserts, and the depth limit: the walk goes 10 hops up, so a set first reachable at depth 11 shows up as a candidate of 11 and the write raises `54001`, as before. Deletes still recompute the affected principals, because a delete can lengthen or remove paths, and knowing that needs path counts C doesn't store.

**Why.** Nesting the 1,000-member `nest-src` at large spent 83 ms in the per-principal recursive walk, re-deriving 1,000 × 6 rows, 1,000 of which already existed. In that plan the recursive term ran a seq scan of `satisfies` 30,000 times and threw away 160,833 joined rows: a team's document grants share `tuples_userset` with its nestings. Then the diff's delete scanned `memberships_pkey` for the 1,000 principals and visited 244,087 index entries to find 1,000 live rows. The other 243k were dead rows left by the benchmark's earlier rolled-back nests, and bitmap scans never mark entries dead. The delta skips both: no per-principal walk and no delete. What's left is the walk from the target team (5 rows, under 0.1 ms) and inserting 5,000 new rows (about 10 ms; 67k buffer hits for heap plus two indexes). That is the floor for materialized memberships.

For the wide seed, adding a user to their k-th team used to recompute all k of their teams, so 50 teams per user cost about 50²/2 walks per user. Now each grant upserts the 5-6 rows above that one team.

### 15.2 Set-level walks, filtered in the index

**What.** Both remaining walks (the insert delta, and `_memberships_for` on the delete path) walk between usersets, not between (principal, userset) pairs. `_memberships_for` takes each principal's direct sets from its own tuples, walks up once per distinct direct set, and joins back. The recursive step restricts `tuples.relation` to the relations that feed a userset, as an index condition on `tuples_userset` (whose last key column is `relation`), so a team's document grants are never visited. `_memberships_for` became PL/pgSQL so its plan is cached: Postgres 16 plans a non-inlined SQL function body on every call, and the `set search_path` clause prevents inlining.

**Why.** The delete path had the same per-principal walk. Nest and then un-nest `nest-src` at large (pgbench, alternating old and new copies of one database): 102, 104 ms before, 30, 25 ms after.

**Kept separate on purpose.** `_memberships_all()`, which `verify()` and `rebuild()` use, keeps its own per-principal walk. `verify()` is the oracle for the incremental code, so it doesn't share code with it.

### 15.3 `accessible()`: one sort, sorted output

**What.** `_accessible()` resolves the relation and type ids into variables first, filters container expansions with a plain `object_type = v_type` (no join with a CTE), and builds the result with `distinct on (object_id) ... order by object_id, forbid desc`. That single sort dedups and applies the forbid veto (a vetoed id sorts its forbid row first and is dropped). The output is sorted. The result set is unchanged; only the order of the array is new, and nothing depended on it. With an unknown subject type it still returns membership-derived ids, as before.

**Why.** For the single-branch policy at large (user 1, 20,007 ids), the old version materialized every reachable id in a CTE, ran a hashed `except`, then `array_agg`. Then the documents index scan sorted the 20k-element array again before its first probe (`_bt_preprocess_array_keys`). That gap before the first row was 5.3 ms in the old plan and 0.5 ms in the new one, because an already sorted array costs a single pass. The InitPlan (the `accessible()` call itself) went from 9.1 to 6.5 ms under EXPLAIN ANALYZE, with the same buffers (277 vs 272 hits). `count(*)` keeps its 60.3k buffer hits: 20k separate index descents into `documents_pkey`, which is now most of what's left (15.6).

### 15.4 Bulk load: `grant_many()` (new, optional)

**What.** `permissions.grant_many(object_type, relation, subject_type, object_ids uuid[], subject_ids uuid[], subject_relation default null) returns bigint`. It grants one relation for many (object, subject) pairs, paired by position, in one statement. Names are checked once. Pairs that already exist are skipped (no expiry; use `grant()` for that). The insert trigger maintains memberships once for the whole batch. Admin-only, like `grant()`. Tested in `c/33`.

**Why.** Real apps import data. The multi-row delta makes a batch cost about one walk per distinct target set plus the rows it writes. The benchmark seed still uses `grant()`, so the table above doesn't include this. A variant of the wide sharing seed that uses `grant_many` (five calls instead of 306k `grant()` calls; not committed) loaded in **7.9 s**, or 7.1 s with nestings loaded before members, against 27.6 s for the per-row seed on the same database (A's per-row seed: 10 s). It produced the same memberships.

### 15.5 Tests

New `test/spec/c/33_incremental_memberships.sql` (13 assertions): a shortcut lowering a stored depth, closing a cycle, a multi-row insert of a whole chain, an implied userset (`admin` implies `member`), the depth limit reached through a delta (and nothing left behind), `grant_many`, and 400 seeded random grants, revokes, multi-row inserts and multi-row deletes over 10 teams and 12 users, with `verify()` clean after every one. Its membership cases (all but `grant_many`, which is new) also pass on the original prototype. Four deliberately broken copies of the delta were each caught: members of a userset subject ignored (`c/31`, `c/32`, `c/33`), no upward walk (`c/32`, `c/33`), depth never lowered (only `c/33`), no depth check (`c/32`, `c/33`). Full suite: 18/18 files, 217/217 assertions.

**Lock: unchanged.** It is still one global advisory lock. The new insert path reads the stored memberships and walks the tuples after taking the lock, like the old one. Re-checked with two real sessions in both orders (session 1 adds Carol to `eng` and holds its transaction open; session 2 nests `eng` into `platform`, and the reverse). `verify()` was clean and Carol was in `platform` both times. With `_lock_graph()` replaced by a no-op, both orders left Carol's `platform` membership missing, and `verify()` reported it.

### 15.6 Tried and dropped

| Idea | Result |
| --- | --- |
| Plain `insert ... where not exists` plus a separate `update` for shorter depths, instead of `on conflict` (safe under the global lock) | Not faster: `write_nest_team` 17.0, 17.3 ms with `on conflict`, against 18.6, 21.3 ms (1 client, large, alternating). Dropped. |
| The upward walk as a shared helper function (`_sets_up`) called from the trigger | As a SQL function it was planned on every call. As PL/pgSQL with custom plans it was re-planned too; `force_generic_plan` fixed that (5,000 user-to-team grants: 1.9 s to 0.93 s). Writing the walk inline in the trigger statement was another 20% faster (145 to 117 µs per grant), so the helper was dropped. |
| First `accessible()` rewrite: `group by ... having not bool_or(forbid)` + `array_agg(... order by ...)` | Page 10.5-11.0 to 7.2-8.6 ms, but the plan hashed and then sorted. Replaced by the single `distinct on` sort (4.6-5.2 ms on the same database). |
| Narrower locks (per-team advisory locks in a consistent order) | Not built: it wouldn't help this workload, and it isn't simple. Every `write_nest_team` nests the same `nest-src`, and every target sits under one of three tree roots. So concurrent nests insert the same (member, root) membership keys, and the second waits on the first's uncommitted index entry whatever the advisory lock does. A sound per-key scheme also needs shared locks on what a write reads (the members of S, the sets above O) and exclusive locks on what it changes (the sets above O, the sets below S). Those sets come from the graph read before locking, so it needs re-checks or `40001` retries. A write that only adds paths could take shared locks against other adders, but not against deletes or container moves. |
| Doing the work before taking the lock | Not possible. The delta must read memberships and tuples as of after the lock, or a concurrent committed write would be missed (the race above). The type check and the tuple insert already run before the lock. |
| A set-to-set closure table, so adding a member becomes one index lookup | Not built. The walk costs about 26 µs per grant. A third derived table would need its own maintenance, `verify()` coverage and drift risk. |

### 15.7 Remaining hard limits

- **A nest writes members × (1 + ancestors) rows under the lock.** That is 5,000 rows, about 10 ms, for the benchmark's nest. With 4 clients the latency is about 4 × the single-client time (58-60 ms against 15.5-15.9 ms), and per-key locks wouldn't change that here (15.6). A still writes one tuple.
- **The single-branch count does one index descent per visible id.** About 20k probes into `documents_pkey` at large, 60k buffer hits, about 9 ms of the 14 ms. The projection policy reads a few contiguous `folder_id` ranges instead (2.7 ms). Postgres 17 skips repeated descents for nearby array keys, which may help, but that hasn't been measured here.
- **The single-branch page builds the whole id array** (20k ids, about 4-5 ms) to return 50 rows. The projection policy is still about 5× cheaper (1.0 ms) and stays the recommended form for large tenants.
- **Per-row `grant()` of memberships costs about 0.1 ms** (trigger, transition table, one delta statement), against about 0.04 ms for an object grant. The wide seed at 24 s is still about 2.4× A's 10 s; `grant_many` loads it in 7-8 s.
- **Deletes recompute.** Revoking a nesting recomputes every member of the subject (now with a set-level walk). A delta delete would need per-path counts, a bigger change to the derived data.

**Expected in the serial confirmation run** (4 clients, as in `COMPARISON.md`): `write_nest_team` large from 333 to about 55-65 ms (11 to about 60 tps), wide from 145 to about 60 ms, small from 62 to about 15-25 ms. `parents_select_page` large from 9.6 to about 5 ms; `parents_select_count` from 22 to about 14-16 ms. Wide sharing seed from 183 s to about 25 s. Wide reads and `nest_check` unchanged within noise. Checksums identical to A and B.

### 15.8 `scopes_with_permission` isn't pre-evaluated (the STABLE double-execution trap)

**Finding.** While optimizing A, `list_objects` turned out to run twice per query: once while planning, once while executing (`designs/a-tuple-core.md` §13). The policies call these functions with constant arguments inside `array(select unnest(...))`. To estimate the unnest's row count, the planner pre-evaluates STABLE functions with constant arguments (`estimate_expression_value`). Marking them VOLATILE removed the plan-time run (A's wide `share_select_page` went from 207 to 110 ms on that change alone).

**Does C have it? Yes, for `scopes_with_permission`; not for `accessible()` in the policy form.** `EXPLAIN (ANALYZE, BUFFERS)` as user 1 on medium wide, with the sharing policy `org_id = any (array(select unnest(scopes_with_permission('documents.read'))::uuid)) or id = any ((select accessible('document', 'viewer'))::uuid[])`:
- `Planning: Buffers: shared hit=1422` is exactly the buffer count of the `scopes_with_permission` InitPlan at execution (1,422). Planning Time was 1.27 ms (7.7 ms on the first, cold run) against 11.3 ms execution.
- The `accessible()` arm doesn't appear in the planning buffers: `(select accessible(...))::uuid[]` is a scalar subquery, which the planner doesn't pre-evaluate.
- After `VOLATILE`, the planning buffers are gone and Planning Time is 0.03 ms (0.3 ms cold).
- The same call outside the blessed form does double-execute: `id = any (array(select unnest(accessible(...))))` and the bare `id = any (accessible(...)::uuid[])` both show the plan-time evaluation (about 1,213 extra planning buffers, 3-4 ms of planning). Those aren't the documented policy form, so `accessible()` stays STABLE: VOLATILE would also stop the bare form from being an index qual. Use `(select accessible(...))::uuid[]`, as in section 7.
- `has_permission`, `has_role` and `can` (boolean quals, shown as One-Time Filter) and the single-branch / projection policies (`parents_select_*`, `parents_proj_*`, which only call `accessible()` as a subquery) show no plan-time evaluation, so nothing changed for them.

**Change (first version: VOLATILE).** `scopes_with_permission` was made `language sql volatile` (it still only reads). The planner then assumes 10 elements for the unnest instead of the real count; the plans didn't change in any workload. The measurements below are for this version.

**Final version: STABLE with a volatile default argument.** Design B pointed out the cost of VOLATILE: under read committed a volatile function takes a fresh snapshot for each query it runs, so the grants it reads can be from a later instant than the rows the statement filters. That weakens single-snapshot consistency inside one statement. STABLE functions read the statement's snapshot. So `scopes_with_permission(p_permission text, p_unfold boolean default permissions._unfolded_null())` is `stable` again. `_unfolded_null()` is a VOLATILE plpgsql function that returns null; a volatile argument isn't a constant, so the planner can't pre-evaluate the call, and the function body still sees the statement's snapshot. `p_unfold` is ignored and callers use the same one-argument form as before. `_unfolded_null()` is granted to public, because a default expression runs as the caller. (Passing every argument as a constant, `scopes_with_permission('x', true)`, would be folded again.) `test/spec/c/56_volatility.sql` asserts via `pg_proc.provolatile` that `can`, `accessible`, `has_permission`, `has_role` and `scopes_with_permission` are STABLE. This is B's technique (its `ids()`).

Re-check of the final version, `EXPLAIN (ANALYZE, BUFFERS)` as user 1, medium default, the sharing policy (scopes arm plus `(select accessible(...))::uuid[]`):

| version | Planning Time | Planning buffers |
| --- | --- | --- |
| STABLE, no dummy argument (folded) | 3.2-3.4 ms | 1,122 |
| VOLATILE | 0.24-0.26 ms | 109 |
| STABLE + `_unfolded_null()` default | 0.27 ms | 112 |

The 109-112 buffers are catalog lookups. Checksums are unchanged (sharing `9b43a472...` at medium default, same as A and B).

**Measured.** Interleaved old/new/new/old/old/new, 3 rounds each, `bench/run.sh --only ... --clients 1 --tag opt-c2`, Postgres 16.4 local, 10 s per run. The old file is kept as `bench/results/optc2/c-orig.sql`, git-ignored. Other agents were benchmarking on the same machine; one old run (round 3) and one new run (round 2) were visibly disturbed, so medians matter more than means. p50 ms, per round (old | new):

| Workload | Old | New | Median old / new |
| --- | --- | --- | --- |
| medium default `rbac_select_page` | 0.41, 0.62, 1.98 | 0.33, 0.35, 0.33 | 0.62 / 0.33 (best-of: 0.41 / 0.33) |
| medium default `rbac_select_count` | 0.36, 0.50, 0.37 | 0.28, 0.26, 0.27 | 0.37 / 0.27 (best-of: 0.36 / 0.26) |
| medium wide `share_select_page` | 10.84, 11.95, 11.21 | 10.52, 14.97, 11.52 | 11.21 / 11.52 (best-of: 10.84 / 10.52) |
| medium wide `share_list_objects` (no scopes call) | 3.31, 3.34, 3.35 | 3.29, 3.77, 3.42 | 3.34 / 3.42 (control) |

RBAC reads get 20-30% faster, because planning was a big part of a 0.4 ms query. The wide sharing page gains about 1.2 ms of 11 (the plan-time call), which is inside the noise of this machine; the best-of figures agree with it but don't prove it. C gains little there because its `scopes_with_permission` is a lookup in materialized memberships (about 1.2 ms), where A's was a 100 ms walk. `parents_*` workloads don't call `scopes_with_permission`, so they were not re-run.

**Checks.** The runs printed identical checksums for old and new (rbac `d394663f...`, sharing `6f7c008d...`), and "same" against A's and B's latest equivalence files. The full suite is unchanged: 18/18 files, 217/217 assertions.
