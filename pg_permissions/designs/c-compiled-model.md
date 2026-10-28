# Design C: Compiled model

> One of three candidate designs. See [../PLAN.md](../PLAN.md) for the shared goals, requirements and evaluation criteria.
>
> **Status (2026-10-28):** built as [`prototypes/c-compiled-model.sql`](../prototypes/c-compiled-model.sql). It passes every shared spec file and its own `test/spec/c/` files (30, 31, 32, 40, 50–53): 14 files, 178 assertions. This document describes what was built. Section 13 lists where the build departed from the earlier draft, and why.

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
- it names the preset-owned types `app` or `tenant` (see section 8).

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
4. Affected principals `P` = principal subjects of changed rows, plus current members of any userset subject of a changed row. At this point `memberships` still reflects the state before the statement.
5. Recompute every principal in `P` with one upward recursive CTE (`union` over `(principal, set, depth)`, capped at depth 11), then apply the difference: delete rows no longer derived, upsert new rows and changed depths. If any shortest path is longer than 10, raise `54001` (the write is rejected; this resolves the old open question 3).

The same code handles insert and delete. Cycles are harmless because the CTE stops revisiting at the depth cap, and a set reachable at depth ≤ 10 keeps that depth. Diamonds are handled because each principal's set is recomputed from scratch, not patched. Updates are rejected by a row trigger, except for `expires_at`, which re-granting changes (expiry can't affect memberships, see section 9). `truncate` is rejected.

Why `P` is complete: take any principal whose membership changes, and the changed tuple closest to it on the path. Either that tuple's subject is the principal, or the prefix of the path before it uses only unchanged tuples, so the principal was already in that tuple's subject set.

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
permissions.who_can(object_type text, object_id uuid, permission text) returns setof uuid

-- writes (admin)
permissions.grant(object_type, object_id uuid, relation, subject_type, subject_id uuid,
                  subject_relation text default null, expires_at timestamptz default null)
permissions.revoke(object_type, object_id uuid, relation, subject_type, subject_id uuid,
                   subject_relation text default null) returns boolean
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
- `who_can` can't enumerate public grants and doesn't list them. A public forbid empties the list.
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

The preset API from PLAN.md §6 is a set of functions that edit the active model and recompile it. The developer never sees the JSON. Two preset-owned types hold the roles: `app` (one object, the nil uuid, for app-wide roles) and `tenant` (one object per scope). `apply_model()` refuses definitions that mention `app` or `tenant`, and carries them over from the active model. So graduating to per-object sharing is one `apply_model()` call with only the app's own types, and the roles are untouched. `user` is added if the developer's model omits it.

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
| G11 public | `"viewer": ["user", "user:*"]`, `grant_public()` / `revoke_public()`. Null subject is denied. | `c/51_public` 7/7 |
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

The large-scale comparison with Design A is a later, serial step.

**Org-wide access through parents** makes `accessible()` return every document id under the org. For an admin of an org with 1M documents that's a 1M-element array per query, the same cost A or B pay for an equivalent single-branch policy. The two-arm policy (`org_id = any (scopes...) or id = any (accessible(...))`) avoids it and stays the recommended form for large tenants. This was not benchmarked.

### Writes

| Operation | Rows written | Lock |
| --- | --- | --- |
| Grant or revoke on a document or org (not a userset feeder) | 1 tuple | none |
| Add a user to team `eng` (eng in k ancestor usersets) | 1 tuple + (1 + k) memberships | global |
| Nest team A (n members) into team B (k ancestors) | 1 tuple + n × (1 + k) memberships; n principals recomputed | global |
| Move a document | 1 parent link | none |
| Move a folder with s sub-folders | 1 parent link + closure rows of s + 1 folders | global |
| Model change touching usersets or what feeds them | full `memberships` rebuild | global |
| Model change touching `parent` lists | full `ancestors` rebuild | global |
| Other model changes (roles, permissions, new types) | catalog rows only | global (brief) |

`write_nest_team` (nest the 1,000-member team `nest-src` into a random team of the 50-team tree, rolled back each time; small scale): **about 14 ms per nest with 1 client** (3,000 membership rows for a 3-level target). **With 4 clients, latency is about 61 ms and tps stays flat at 65–70**: the global lock serializes them. A plain object grant (`write_share`) is about 0.1 ms. This is the write where C pays and A doesn't.

## 12. Weaknesses and risks

1. **The write path is the bulk of the code and where bugs live.** The prototype is about 1,860 lines (A is about 620): compiler about 590, derived-data maintenance about 350, preset about 250. A missed case causes silent drift. `verify()` and `rebuild()` mitigate this; a read-time walk has no drift by construction. Four deliberately broken copies (no propagation on nesting, forbid ignored, parent traversal cut to one hop, `verify()` blind) were each caught by the specs, but drift bugs outside the tested shapes would not be.
2. **One global lock** for every membership, container-move and rebuild write. Bulk directory syncs (SCIM) and concurrent team edits queue: nesting a 1,000-member team holds it for about 14 ms. Per-key locking needs careful lock ordering and is deferred.
3. **`repeatable read` is refused for those writes.** It surprises users. ORMs that default to it would have to switch for permission writes.
4. **Write latency lands in the app's transaction.** Nesting a 10k-member team writes 10k+ rows synchronously. A TLE can't ship a background worker.
5. **Model changes that touch usersets rebuild all memberships** under the lock, in one transaction. Fine for small apps; at 5M membership rows it's a maintenance window.
6. **Parent links duplicate app data.** The app's `folder_id` column and `set_parent()` must be kept in sync (the specs do both by hand). A helper trigger could read the column like `on_object_deleted` does, but it isn't built. One parent per object.
7. **Single-branch parent policies materialize large arrays** for org-wide roles (section 11).
8. **Forbid is deny-overrides** (section 9), not OpenFGA's exact `but not`; exclusions are same-type relations only.
9. **No expiring group memberships.** Rejected rather than silently wrong.
10. **`who_can` omits public grants.**
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
| Preset edits "the active model" | `app` and `tenant` are reserved; `apply_model()` carries them over | Otherwise graduating with a model that omits them would drop every role. |
| `accessible()` returns `setof uuid` | Returns `uuid[]`, used as `= any ((select f())::uuid[])` | Measured fastest (section 7). |
| Parent link as a tuple (`document:readme#org@org:acme`), syntax `org->view_documents` | Dedicated `parents` table (one parent per object), `"parent": [...]` + `parent->P` inside `P` only, all-or-nothing up the hierarchy | Single parent makes a move one upsert and the closure a chain. The same-name rule keeps the flat compiled form exact (section 3). |
| Recursive parents reuse the memberships machinery | Separate `ancestors` table, for container types only | Leaf objects never get closure rows, so moving a folder doesn't fan out to documents. |
| Forbid as `excludes` table | `forbid` flag on `satisfies`, deny-overrides along the chain | One table; semantics in section 9. |
| `user:*` was an open question | `type:*` in the model, `grant_public`, `tuples.subject_id` null | G11. Separate function so a null can't grant public access. |
| Membership expiry deferred | Rejected on write and at compile time | Fail loudly instead of drifting. |
| Max depth: reject or truncate (open question) | Reject (`54001`); `memberships.depth` stores the shortest path | Open question 3. |
| `tuples` immutable | Only `expires_at` can change (re-granting updates it); `truncate` blocked | `31_zanzibar_groups` re-grants with a new expiry. |
| `verify()` returns `(principal_id, set_key, problem)` | `(kind, member_id, set_key, problem)`, covering memberships and ancestors | Two derived tables. |
| `explain()`, `policy_sql()` | Not built | Not needed by any goal; open question 8 stands. |

## 14. Open questions

1. Is uuid-only acceptable, or do we need a per-type key kind (`uuid` | `text`)?
2. JSON only, or also an OpenFGA-style DSL (client-side)?
3. Global lock, or per-key locking now? Measure `write_nest_team` with concurrent clients at large scale first.
4. Should `memberships` hold a reflexive row per principal so `can()` needs one branch instead of two? That costs a row per principal and requires knowing principals the extension doesn't otherwise track.
5. How should `apply_model()` express renames, so they don't drop and re-add tuples?
6. Is deny-overrides the forbid semantics we want, or do we need OpenFGA's exact `but not`?
7. Should the extension ship a trigger that keeps `parents` in sync with an app column (`folder_id`)?
8. Is `policy_sql()` worth shipping, given the developer still pastes the result into a migration?
