# Design C: Compiled model

> Status: this design is history. The team built it and measured it, but did not choose it. Design D is the extension. See [`d-per-model.md`](./d-per-model.md).

> This document describes one of three candidate designs. See [`../plan.md`](../plan.md) for the shared goals, the requirements and the evaluation criteria.
>
> **Status (2026-10-28):** the team built the design as [`../../prototypes/c-compiled-model.sql`](../../prototypes/c-compiled-model.sql). It passes every shared spec file and its own `test/spec/c/` files (30–33, 40, 50–57). That is 21 files and 229 assertions. Before the session 3 specs, it was 18 files and 217 assertions.
>
> This document describes what the team built. Section 13 lists where the build differed from the earlier draft, and why. Section 15 lists the session 3 optimizations (2026-10-29).

## 1. Summary

The developer declares an authorization model once, as JSON, and passes it to `permissions.apply_model()`. The model lists types, relations, implications, permissions, parent types, exclusions (forbid) and the subjects that can hold each relation. The extension compiles the model into lookup tables. Triggers keep two derived tables up to date. One is a materialized "who is in which group" table. The other is the ancestor closure of container objects, such as folders.

Every read is then a fixed number of indexed lookups, with no recursion. All IDs are native `uuid`. The extension runs no DDL and no dynamic SQL, apart from the install script.

## 2. Core idea

A generic tuple store with a read-time graph walk does all the work on every check. It resolves implied relations, expands groups, and recurses through nested groups and parent chains. In an RLS policy, that walk runs once for each query (fast path) or once for each row (per-row check).

An authorization graph has four axes, and each axis changes at a different rate:

| Axis | Example | Changes | Size | This design |
| --- | --- | --- | --- | --- |
| Relation axis | `admin` implies `member`. `edit` is `editor` or the `edit` of the parent. | Rarely (model changes) | Tiny | `apply_model()` **compiles** it into the `satisfies` table |
| Subject axis | Carol is in `eng`. `eng` is in `platform`. | Sometimes | principals × groups | Triggers **materialize** it into `memberships` |
| Container axis | Folder `plans` is in folder `specs`. Folder `specs` is in org `acme`. | Sometimes | containers × depth | `set_parent()` **materializes** it into `ancestors` |
| Object axis | Bob is editor of `readme`. `readme` is in folder `specs`. | Constantly | Large | The design **stores it as written** (`tuples`, `parents`) and looks it up by index |

The key choice is what *not* to materialize. A full "effective permissions" table (user × object × permission) makes a check a single index probe. But its size is the product of the axes. For example, one org admin over 1M documents gives 1M rows. The design materializes only group membership and the closure of *containers*. Thus the write amplification is proportional to the group size or the folder-tree size, and never to the number of documents.

| Option | Verdict |
| --- | --- |
| Full effective-permissions table | Rejected. The size is a product of the axes for org-wide roles and team grants. A hierarchy change rewrites everything. |
| Generated typed tables for each object type | Rejected. A security-definer function must run DDL at run time. This causes ownership problems and ties the extension to the app migrations. |
| The extension creates RLS policies itself | Rejected. It has the same DDL and ownership problems. |
| **Static schema, compiled data, materialized memberships and container closure** (built) | All tables exist at install time. A model compiles to rows, not to code. |

## 3. Model format

The format is JSON, because PL/pgSQL can validate `jsonb` without a parser. An OpenFGA-style DSL can be a client-side tool that writes this JSON. The model below combines the models in `test/spec/c/50_parents.sql` and `52_forbid.sql`:

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

| Key | Meaning |
| --- | --- |
| `principal: true` | IDs of this type are end subjects. `current_subject_id()` returns one of them. The design assumes that UUIDs are unique across principal types. |
| `relations` | What a grant can give, and to whom. The subject can be a principal type (`user`), every principal of a type (`user:*`, public access), or a userset (`team#member`). The design rejects plain non-principal subjects (`"org"`). Use a userset. |
| `implies` | A subject that holds the key relation also satisfies the listed relations of the same type. This is transitive. The design rejects cycles. |
| `permissions` | Named checks. An array means "any of these". `{"any": [...], "but_not": [...]}` adds exclusions. A subject that holds a `but_not` relation loses the permission (forbid). Items are relations of the same type, or `parent->P`. A grant cannot give a permission directly. A permission cannot list other permissions. |
| `parent` | The types that an object of this type can have as its parent. Each object has one parent at most. `set_parent()` sets it. Types that appear in a `parent` list are **containers**. |
| `parent->P` | Valid only inside permission `P`. A subject that has `P` on the parent has `P` here. |

### Compile-time rules

`apply_model()` rejects a model when one of the conditions below is true. The error message has the names that cause the error, and the SQLSTATE is `22023`.

- A type, relation or permission name is not valid. Type names must match `^[a-z][a-z0-9_]{0,62}$`. Relation names and permission names can also have dots, so `documents.read` works. Or a type has unknown keys, or a value has the wrong shape.
- A name is both a relation and a permission on the same type. This is also how the `rbac` preset gets the rule "role and permission names cannot overlap" at no cost.
- A subject names an unknown type, an unknown relation, or a non-principal type without `#relation`. Or it uses `type:*` on a non-principal type.
- `implies` names something that is not a relation of the same type, or it has a cycle.
- A permission has no item that gives it, or an item is not a relation of the same type. Or `parent->X` appears inside a permission that is not named `X`, or in a type without `parent`.
- **Parent inheritance is all-or-nothing.** If `X.P` contains `parent->P`, every parent type of `X` must define `P`. If that parent type has parents of its own, its `P` must also contain `parent->P`.
- A relation that feeds a userset has `type:*` as a subject. This would make every user a group member, and the design cannot materialize that.
- The model would make a grant that has an expiry feed a userset.
- The model defines or redefines the preset-owned types `app` or `tenant` (see section 8). A model can name one of them as a parent (`"parent": ["tenant"]`).

The all-or-nothing rule makes the compiled form exact. Without it, "`P` on any ancestor" can give too much access. For example, assume that `folder.view` does not inherit but `document.view` does. Then the grandparent org of a document wrongly counts. With the rule, the permission that the design checks at each step up the chain is the same `P`. Thus one flat set of `(type, relation)` pairs describes every ancestor.

## 4. Schema

The schema `permissions` has ten tables. All of them have `revoke all ... from public` and RLS enabled with no policies. Thus only the security-definer functions of the extension can reach them.

| Table | Rows | Notes |
| --- | --- | --- |
| `models` | One for each applied model version | The full definition (with the types of the preset), `applied_at` and `applied_by`. The latest row is the active model. |
| `types` | One for each type | A `smallint` id that stays the same across versions. Columns `principal` and `container`. |
| `relations` | One for each relation or permission | `kind`. `is_userset` (the relation appears as `type#rel`). `feeds_userset` (a grant of the relation changes memberships, for example `org.admin` when `admin` implies `member` and `org#member` is a userset). |
| `allowed_subjects` | The compiled `relations` lists | `(relation, subject_type, subject_relation, wildcard)`. |
| `parent_types` | The compiled `parent` lists | |
| `satisfies` | The compiled relation axis | `(grants_id, relation_id, via_parent, forbid)`. A tuple with `relation_id` on the object itself (`via_parent = false`) or on any ancestor (`true`) satisfies `grants_id`. With `forbid`, the tuple vetoes `grants_id`. |
| `tuples` | One for each grant | `(object_type, object_id uuid, relation, subject_type, subject_id uuid, subject_relation, expires_at)`. A null `subject_id` is a public grant. The table is unique on `(object_id, relation, subject_type, subject_id, subject_relation)` with `nulls not distinct`. Partial covering indexes serve direct, userset and public lookups. |
| `parents` | One for each object that has a parent | The primary key is `(object_id, object_type)`, so each object has one parent. The table has an index on the parent. |
| `memberships` | principal × transitive userset | `(principal_id, set_type, set_id, set_relation, depth)`. `depth` is the shortest path (1 means direct). Indexes: by principal (primary key) and by set. |
| `ancestors` | container × ancestors | Only for objects of **container** types. Leaf objects (documents) store only their parent link. |

For the `document` type of the model above, `satisfies` holds these rows. The table shows relation names, not ids.

| grants | relation | via_parent | forbid |
| --- | --- | --- | --- |
| `document.view` | `document.viewer`, `document.editor` | false | false |
| `document.view` | `document.blocked` | false | true |
| `document.view` | `folder.viewer`, `folder.editor`, `org.member`, `org.admin` | true | false |
| `document.edit` | `document.editor` | false | false |
| `document.edit` | `document.blocked` | false | true |
| `document.edit` | `folder.editor`, `org.admin` | true | false |
| `document.viewer` | `document.viewer`, `document.editor` | false | false |

Assume that `folder.view` has its own `but_not`. Then those rows also appear for `document.view`, with `via_parent = true, forbid = true`.

### Compilation (`apply_model`)

1. Validate the shape, the names, the references and the rules in section 3. The function does not change any data yet.
2. If the definition is equal to the active definition, return `unchanged`.
3. Take the graph advisory lock. Remove the types and relations that are gone, with their tuples and parent links. This needs `p_force => true` if any exist. Otherwise the call raises `2BP01` and gives the number of rows that it would remove.
4. Upsert types and relations by name (the ids are stable). Rewrite `allowed_subjects`, `parent_types`, `container` and `is_userset`.
5. Rewrite `satisfies`. First write the implication closure for relations (a recursive CTE). Then write the own-type rows of each permission (permit and forbid). Last, write the `via_parent` rows. These are the own-type rows of `P` on every type that you can reach up the `parent_types` graph.
6. Set `feeds_userset`. Check the post-compile rules (public grants on userset feeders, feeders that have an expiry). Delete the tuples and parent links that the new model does not accept (this needs force).
7. If data that memberships depend on changed, rebuild `memberships`. This data is the userset relations, the relations that feed them, and the principal types. If `parent_types` changed, rebuild `ancestors`.
8. Insert a `models` row. Return the plan as `(change, detail)` rows, for example `add relation | document.blocked`, `rebuild memberships | ...` and `version | 7`.

`p_dry_run => true` runs the same code inside a subtransaction and rolls it back at the end. Thus the plan that it returns is exact, and it includes validation errors. There is one shortcut: the dry run reports a rebuild but does not do it.

## 5. Maintenance of derived data

### Memberships

Statement-level `after insert` and `after delete` triggers on `tuples` use transition tables. They work in these steps:

1. Type-check every new row against `allowed_subjects` and `relations`. The row must have the right type. The relation must not be a permission. The subject must be one that the relation lets in.

   Userset feeders cannot have an expiry. Even the owner cannot insert a tuple with a wrong type (`23514`).
2. If no changed row has a `feeds_userset` relation, stop. Object grants end here: one insert, no lock.
3. Take the graph lock (see below).
4. **Insert:** apply a delta (session 3 added this, section 15). Each new row pairs a member with a set. The members are the members of the subject of the new tuple (from the stored memberships). The sets are the usersets of the tuple object and every set above them (one upward walk over the current tuples). The depth is the depth in the subject, plus 1, plus the distance above the object.

   The trigger upserts each row and keeps the smaller depth. It deletes nothing. If a new shortest path is longer than 10, the trigger raises `54001` and the write fails. This resolves the old open question 3.
5. **Delete:** the affected principals `P` are the principal subjects of the deleted rows. They also include the current members of any userset subject of a deleted row. At this point `memberships` still shows the state before the statement.

   Recompute every principal in `P`. First compute the direct sets from the own tuples of the principals. Then do one upward walk for each distinct direct set, with a cap of 10 hops. Then apply the difference: delete the rows that are no longer derived, and upsert the new rows and the rows with a changed depth.

Cycles are harmless, because the walks stop when they reach the depth cap. A set that is reachable at depth 10 or less keeps that depth. The design handles diamonds. An insert keeps the least depth over every path, and a delete recomputes each affected principal from the start.

A row trigger rejects updates, except for `expires_at`, which a new grant changes. Expiry cannot affect memberships (see section 9). The design rejects `truncate`.

The insert delta is complete for this reason. Take any new path from a principal to a set, and the first new tuple on the path (subject S, object O). The part before that tuple uses only old tuples. Thus the principal is S, or the principal was already a stored member of S. The part after the tuple is an upward walk from O. Every candidate is a real path, so the design never gives too much access.

`P` is complete for a delete for this reason. Take any principal whose membership changes, and the changed tuple that is closest to it on the path. Either the subject of that tuple is the principal, or the prefix of the path before it uses only unchanged tuples. In the second case, the principal was already in the subject set of that tuple.

### Ancestors (container closure)

`set_parent(type, id, parent_type, parent_id)` upserts the parent link. For a container object, it also takes the graph lock. It computes the subtree of the object (the object and its container descendants, from the current closure).

It rejects the move if the new parent is in that subtree (a cycle, `23514`). Then it recomputes the closure rows of the subtree. A chain that is deeper than 10 raises `54001`. `unset_parent` and `forget_object` do the same. A move of a leaf object (a document) is one upsert, with no lock and no closure rows.

Thus a move of a folder rewrites rows only for its sub-folders. Reads find the documents under the folder through `parents` (one index lookup), so the documents never get closure rows.

### Concurrency

Some writes change memberships or the container closure. These are userset grants and revokes, container moves, model changes that cause a rebuild, and `rebuild()`. Each of them runs `_lock_graph()`:

- It raises `0A000` under **repeatable read**. The snapshot is fixed before the lock is taken. Thus the committed rows of a concurrent writer stay invisible, and the derived rows drift.
- Otherwise it takes one transaction-level advisory lock. In **read committed**, each statement after the lock sees fresh data. **Serializable** is valid. SSI aborts one of two writers that conflict (`40001`, retry).

The team checked this with two real sessions. Session 1 adds Carol to `eng` and holds the transaction open. Meanwhile, session 2 nests `eng` into `platform`. With the lock, `verify()` reports no drift afterwards.

The team removed the lock from a copy of the prototype. In that copy, the same race leaves out the `platform` membership of Carol, and `verify()` reports it. Plain object grants take no lock.

### Drift: `verify()` and `rebuild()`

`verify()` recomputes all memberships and the full container closure from `tuples` and `parents`. It compares the result with the stored rows. It returns `(kind, member_id, set_key, problem)`. `problem` is `missing`, `extra`, or a depth mismatch. No rows means no drift.

`rebuild()` takes the lock, throws both derived tables away and recomputes them. Both are full recomputes, so they cost O(all memberships). They are maintenance tools. Do not run them for each request.

## 6. Identity

```sql
permissions.current_subject_id() returns uuid   -- JWT sub, else permissions.subject_id setting, else null
permissions.current_subject_type() returns text -- permissions.subject_type setting, else 'user'
```

The JWT wins over the setting (see [section 3 of the plan](../plan.md)). A value that is not a uuid counts as no subject, and every check for a null subject is false. Nothing references the `auth` schema.

For cleanup, there are no FKs to app tables. The app attaches the trigger functions that the extension supplies. These functions read the id column through `to_jsonb(old)` (no dynamic SQL):

```sql
create trigger profiles_permissions_cleanup after delete on public.profiles
  for each row execute function permissions.on_subject_deleted('id');
create trigger documents_permissions_cleanup after delete on public.documents
  for each row execute function permissions.on_object_deleted('document', 'id');
```

They call `forget_subject(uuid)` and `forget_object(type, uuid)`. `forget_subject(uuid)` deletes every grant to the principal. `forget_object(type, uuid)` deletes the grants on the object, the grants to its usersets, and its parent links. The children of the object become roots. The extension revokes execute on these functions from public. Thus only roles that the app trusts can attach them.

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

- "permission" in the read functions also accepts relations (`can('document', x, 'viewer')`).
- **Reads return false or empty for unknown names.** They do not raise. This matches the `rbac` preset rule (see [section 6 of the plan](../plan.md)). A policy that names a dropped permission denies, and does not break every query. Writes validate everything and raise on unknown names.
- A forbid is a grant of a `but_not` relation. Thus it is admin-only, like every grant. The tests show that `authenticated` gets `42501`.
- `grant_public` is a separate function. Thus a null `subject_id` from a failed lookup can never grant public access (`grant` raises on null).
- **`who_can` reports a public grant as one null row.** The null row means "every principal of the type of the grant". The function never lists the users. This is the counterpart of the `('user', '*')` row of A from `list_subjects`. C encodes it as it stores it (`tuples.subject_id` is null), because `who_can` returns bare uuids.

  As in A, the null row is not net of the forbids of single principals. The function drops a blocked user from the concrete rows, but it cannot list that user as an exception to "everyone". A public forbid (`blocked: ["user:*"]`) empties the whole list, with the null row. Public grants on a parent count.

  Callers that test membership with `x = any (...)` ignore the null row. They must check for the null row explicitly (`c/54_who_can_public`). Until 2026-10-28, the function silently left out public grants, so `who_can` reported too few subjects.
- The function is `can` and not `check`, because `check` is a reserved word. `permissions.check(...)` works with the schema name, but a bare `check(...)` is a syntax error.

Reads have no recursion. `can()` is one statement. It resolves the `satisfies` rows of the permission. Then it builds the candidate objects: the object itself, its parent from `parents`, and the rows of the parent in `ancestors`.

Then it probes `tuples` for three kinds of grant: direct, public, and to a userset that has the subject. For the last kind, it joins `memberships` on the unique index. The result is "some permit and no forbid".

`accessible()` runs the same three branches from the subject side. Then it expands the grants on containers to the objects of the target type through `ancestors` and `parents`. It returns the permitted objects minus the forbidden objects. `who_can()` starts from the object and expands usersets through `memberships_by_set`.

### RLS fast path

`accessible()` returns `uuid[]` natively. The fastest correct policy form is:

```sql
id = any ((select permissions.accessible('document', 'view'))::uuid[])
```

The `::uuid[]` has no effect, because the type already matches, so no cast node remains. Its only purpose is to make Postgres treat the subquery as an array expression. The plan shows `InitPlan 1` and `Index Cond: (id = ANY ($0))`. The team measured against 1M documents and a user with 300 grants. They did 100–400 pgbench runs for each form, on a busy machine. Other agents ran tests at the same time, so read the ratios and not the absolute numbers.

| Policy form | Page of 50 | Count | Notes |
| --- | --- | --- | --- |
| `id = any ((select f())::uuid[])` | 0.36–0.48 ms | 0.47–0.62 ms | **Use this.** It has no cast and no re-array. |
| `id = any (array(select unnest(f())))` | 0.55–0.69 ms | 0.66–0.78 ms | Correct. It pays for `unnest` and for the rebuild of the array. |
| `id = any (array(select unnest(f())::uuid))` | 0.55–0.71 ms | 0.66–0.82 ms | This is the form in [section 4 of the plan](../plan.md) for `text[]` functions. Here it is the same as the form above. |
| `id = any (f())` | 0.53–0.57 ms | 0.68–0.77 ms | It works only while it lands in an `Index Cond`, where Postgres evaluates it once. In a filter, it would run once for each row. Do not rely on it. |
| `id = any ((select f()))` | error | error | `operator does not exist: uuid = uuid[]`. Postgres parses it as a subquery comparison. |
| `id in (select unnest(f()))` | 47 ms | 57 ms | Hashed subplan, sequential scan of every row. |

The warning in [section 4 of the plan](../plan.md) about `((select f())::uuid[])` (a cast for each row) applies only when `f()` returns `text[]`. For a function that returns `uuid[]`, the cast disappears. `scopes_with_permission` returns `text[]`, because it is part of the shared preset API. Thus tenant policies keep the form from section 4 of the plan.

## 8. Blessed path: the `rbac` preset

The preset API from [section 6 of the plan](../plan.md) is a set of functions that edit the active model and recompile it. The developer never sees the JSON. Two preset-owned types hold the roles. `app` has one object, the nil uuid, for app-wide roles. `tenant` has one object for each scope.

`apply_model()` refuses definitions that define or redefine `app` or `tenant`. It checks the top-level type keys. It carries both types over from the active model.

A type can still name `tenant` as a parent. For example, put `"parent": ["tenant"]` on `folder` and call `set_parent('folder', f, 'tenant', acme)`. Then `parent->documents.read` reaches the roles that the app assigned on `acme`, so preset roles flow down to resources of single objects.

The usual all-or-nothing parent rule applies. `tenant` must define the permission, and it does so when `create_role` puts the permission in a role. `test/spec/c/55_tenant_parent.sql` covers this. Thus a move to sharing of single objects is one `apply_model()` call with only the own types of the app. The roles stay as they are. The design adds `user` if the model of the developer does not have it.

| Preset call | What happens |
| --- | --- |
| `create_role('editor', '{documents.edit}', '{viewer}')` | Adds relation `editor` (subjects `user`), `"editor": ["viewer"]` in `implies`, and `editor` in permission `documents.edit`, on both `app` and `tenant`. Recompiles (one new model version). |
| `drop_role('editor')` | Fails (`2BP01`) while the `implies` of another role lists it. Otherwise it removes the relation, removes it from the permission lists, and drops permissions that are now empty. Then it recompiles with force, which deletes the assignments of the role. |
| `assign_role(bob, 'editor', acme)` | `grant('tenant', acme, 'editor', 'user', bob)`. An unknown role raises `22023`. |
| `has_permission('documents.edit', acme)` | `can` restricted to `kind = 'permission'` on `tenant:acme`. |
| `has_role('viewer')` | `can` restricted to `kind = 'relation'` on `app`. Thus inherited roles count and permission names do not. |
| `scopes_with_permission('documents.read')` | `accessible('tenant', ...)` as `text[]`. |
| `user_permissions(bob, acme)` | The relations of kind `permission` on `tenant` for which `can_for` is true. |
| `users_with_role('admin', acme)` | `who_can('tenant', acme, 'admin')` as text. |

**The signatures take `text` IDs, exactly as in [section 6 of the plan](../plan.md), and not `uuid`.** The shared specs need it. They compare `scopes_with_permission` and `users_with_role` with `text[]` arrays (`tap.set_eq` needs the same element type on both sides). They also pass `org_id::text` and `md5(...)::uuid::text`.

A cast from text to uuid is explicit-only, so a `uuid` parameter would fail with "function does not exist". Underneath, everything is uuid. On reads, a scope that is not a uuid gives false. On writes, it raises `22P02`.

The overloads `has_permission(text, uuid)` and `has_role(text, uuid)` exist. Thus policies can pass a uuid column without a cast. An unknown literal still resolves to the `text` version, so there is no ambiguity.

Roles are not usersets. Thus `memberships` stays empty for an app that has only RBAC, and none of the trigger machinery runs past step 2. The RBAC scenario ([section 6 of the plan](../plan.md)) and the graduation test (`c/40_graduation`) pass unchanged. Every RBAC answer is the same before and after the app adds sharing.

- **One model version for each `create_role`.** This is fine for migrations. An app that creates roles at run time churns versions. A batch function `define_roles(jsonb)` would fit better.
- **UUID only.** Apps with `bigint` or `text` user IDs need a table that maps the IDs.

## 9. v0.0.2 features (plan section 10), as built

The features come from [section 10 of the plan](../plan.md).

| Goal | How C does it | Spec |
| --- | --- | --- |
| G10 parents | `"parent": [...]` and `"parent->P"`. `set_parent()`. Container closure. The RLS policy is a single branch: `id = any ((select permissions.accessible('document', 'view'))::uuid[])`. `who_can` includes the subjects that come from parents. The design **rejects cycles on write** (`23514`). | `c/50_parents` 13/13 |
| G11 public | `"viewer": ["user", "user:*"]`, `grant_public()` and `revoke_public()`. A null subject is denied. `who_can` returns one null row for public access (section 7). | `c/51_public` 7/7, `c/54_who_can_public` 8/8 |
| G12 forbid | `{"any": [...], "but_not": ["blocked"]}`. The forbid is `grant(..., 'blocked', ...)`. A forbid beats access that comes from a parent. | `c/52_forbid` 9/9 |
| G13 conditions | Resource conditions stay in RLS on the column of the app: `id = any (accessible('document','edit')) or (status = 'published' and id = any (accessible('document','view')))`. Grant expiry is `expires_at` on the tuple. | `c/53_conditions` 6/6 |

**Forbid semantics are deny-overrides across the inheritance chain (like Cedar). They are not the exact `but not` of OpenFGA.** A `but_not` relation of permission `P` on any type in the chain vetoes `P` for everything that inherits `P` from that object. Thus a forbid on a folder blocks its documents, even for a subject who is a direct viewer of a document. In OpenFGA, `document.view = (viewer or view from parent) but not blocked` would subtract the `blocked` of the folder only from the part that comes from the folder.

The flat compiled form cannot express that difference. Also, "forbid always wins" is easier to reason about. Exclusion relations must be relations of the own type of the permission.

**Expiry** works on any grant that does not feed a userset. `grant()` (`0A000`) and the compiler reject group memberships that have an expiry, and anything that implies one. The membership of a principal would expire at the maximum, over the paths, of the minimum along each path. The materialized table does not model this.

**Not built:** `explain()` (a provenance walk to debug access), `policy_sql()` (generated policy text), rename hints in `apply_model()`, and per-key locks. CEL would compile into SQL text at model time, and not be interpreted for each row. Cedar `when`/`unless` over arbitrary attributes does not compile to lookups. Both are the same as in the earlier draft.

## 10. Reference scenario

The scenario uses the model in section 3 without `folder`, `parent` and `blocked`. `test/spec/c/30_zanzibar_reference.sql` has the full text of that model. Then run these grants:

```sql
select permissions.grant('org', :'acme', 'admin',  'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'carol');
select permissions.grant('team', :'eng', 'member', 'user', :'dave');
select permissions.grant('document', :'readme', 'editor', 'user', :'bob');
select permissions.grant('document', :'readme', 'viewer', 'team', :'eng', 'member');
```

Result: 6 tuples and 2 membership rows (Carol and Dave in `team:eng#member`).

- **Can Bob update readme?** `can_for('user', bob, 'document', readme, 'editor')` needs one probe. The answer is true.
- **Which documents can Dave select?** `accessible_for('user', dave, 'document', 'viewer')` joins his one membership to the userset grant. The result is `{readme}`.
- **Who can view readme?** `who_can('document', readme, 'viewer')` returns Bob, Carol and Dave.

Now use parents (`c/50_parents`). `set_parent('document', readme, 'org', acme)` (or a call through a folder) makes Alice and Carol appear in `who_can`. The policy then collapses to the single branch in section 9. It does not need a hand-written `org_id` arm. At scale, the two-arm policy on the `org_id` column of the app is still the faster form for org-wide roles (section 11).

## 11. Performance

### Reads

| Operation | Work |
| --- | --- |
| `can()` | The `satisfies` rows (a few) × the candidate objects (1 + the parent chain, 11 at most) × unique-index probes. Also the memberships (typically fewer than 50) × probes. |
| `accessible()` | Range scans of `tuples_direct`, `tuples_public`, and `tuples_userset` for each membership. Then, for grants on containers, lookups in `ancestors` and `parents`. The output size dominates. |
| `who_can()` | Object-side probes, plus `memberships_by_set` for each userset grant. |

The next table shows the small-scale benchmark. The command is `./bench/run.sh --impl prototypes/c-compiled-model.sql --duration 3`, with 10k documents, 1,000 users and 50 teams. Other test runs shared the machine. Thus this is a sanity check and not a comparison.

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

The large-scale comparison used serial runs and 4 pgbench clients. [`../benchmarks/COMPARISON.md`](../benchmarks/COMPARISON.md) has the full tables and the checksums. The checksums of the visible documents for each user match A and B at every scale. The next table shows p50 ms at large scale (1M documents, 10k users):

| Workload | A | B | C |
| --- | --- | --- | --- |
| `rbac_check` | 0.28 | 0.33 | 0.23 |
| `share_select_page` | 2.02 | 1.21 | 0.95 |
| `parents_proj_select_page` (two-arm projection) | 3.20 | 1.44 | 1.01 |
| `parents_select_page` (single branch) | 509 | 197 | 9.57 |
| `write_nest_team` (4 clients) | 0.15 | 285 | 333 |
| `nest_check` | 0.70 | 2.60 | 0.26 |

These are the serial baselines of session 2. The team measured them before the session 3 optimizations. Section 15 has interleaved before and after numbers for the writes, the single-branch parents policy and the wide seed. The team has not yet done a serial rerun.

C has the fastest reads on every sharing workload and every parents workload. It is flat on `nest_check` (0.22–0.28 ms at every scale and shape). On RBAC, the designs are about equal.

In the wide shape (medium, 50 teams for each user), `share_select_page` is 221 ms for A, 70 ms for B and 10.7 ms for C. But the wide sharing seed of C took 183 s, against 35 s for B and 10 s for A. The seed of C for parents of each document at large scale took 16 s and added about 160 MB. A took 44 s and 378 MB. B took 167 s and 736 MB.

**Org-wide access through parents** makes `accessible()` return every document id under the org. An admin of an org with 1M documents gets a 1M-element array for each query. A and B pay the same cost for an equivalent single-branch policy.

The two-arm policy (`org_id = any (scopes...) or id = any (accessible(...))`) avoids this cost. It stays the recommended form for large tenants. The team measured at large scale (about 20k visible documents for each user). The single-branch `parents_select_page` is 9.57 ms p50 for C, against 1.01 ms for the two-arm projection (about 9×). For the same single-branch shape, A pays 509 ms and B pays 197 ms. Thus the materialized `accessible()` of C degrades much less, but the projection is still the cheaper form.

### Writes

| Operation | Rows written | Lock |
| --- | --- | --- |
| Grant or revoke on a document or org (not a userset feeder) | 1 tuple | none |
| Add a user to team `eng` (`eng` is in k ancestor usersets) | 1 tuple + (1 + k) memberships | global |
| Nest team A (n members) into team B (k ancestors) | 1 tuple + n × (1 + k) memberships, written as a delta (section 15) | global |
| Move a document | 1 parent link | none |
| Move a folder with s sub-folders | 1 parent link + closure rows of s + 1 folders | global |
| Model change that touches usersets or what feeds them | full `memberships` rebuild | global |
| Model change that touches `parent` lists | full `ancestors` rebuild | global |
| Other model changes (roles, permissions, new types) | catalog rows only | global (brief) |

`write_nest_team` nests the 1,000-member team `nest-src` into a random team of the 50-team tree, and rolls back each time. At small scale with 1 client, a nest takes **about 14 ms** (3,000 membership rows for a target with 3 levels). **With 4 clients, the latency is about 61 ms and tps stays flat at 65–70.** The global lock serializes the clients.

A plain object grant (`write_share`) takes about 0.1 ms. In this write, C pays a cost and A does not. At large scale with 4 clients, the measured `write_nest_team` is **333 ms p50** (A 0.15 ms, B 285 ms). Concurrent nests queue on the global lock. `COMPARISON.md` has no single-client figure for large scale.

## 12. Weaknesses and risks

1. **The write path is most of the code, and bugs live there.** The prototype has about 1,990 lines (A has about 620). The compiler has about 590 lines, the maintenance of derived data about 400, and the preset about 250. Session 3 added the insert delta and `grant_many`, about 120 lines.

   A case that the code misses causes silent drift. `verify()` and `rebuild()` reduce this risk. A read-time walk has no drift by construction.

   The team made four copies with deliberate breaks: no propagation when a team nests, forbid ignored, parent traversal cut to one hop, and `verify()` blind. The specs caught each break. But the specs would not catch drift bugs outside the tested shapes.
2. **One global lock** for every membership write, container-move write and rebuild write. Bulk directory syncs (SCIM) and concurrent team edits queue. A nest of a 1,000-member team holds the lock for about 14 ms (single client, small scale).

  At large scale, 4 clients queue to a 333 ms p50. After the session 3 delta, the nest holds the lock for about 15 ms at large scale too. Then 4 clients queue to about 60 ms (section 15).

   Per-key locks need a careful lock order, and the team deferred it. Section 15 explains why it would not help the nest in the benchmark.
3. **The design refuses `repeatable read` for those writes.** This surprises users. ORMs that use it by default must switch for permission writes.
4. **Write latency lands in the transaction of the app.** A nest of a 10k-member team writes 10k or more rows synchronously. A TLE cannot ship a background worker.
5. **Model changes that touch usersets rebuild all memberships** under the lock, in one transaction. This is fine for small apps. At 5M membership rows, it needs a maintenance window.
6. **Parent links duplicate app data.** The `folder_id` column of the app and `set_parent()` must stay in sync (the specs do both by hand). A helper trigger can read the column, as `on_object_deleted` does, but the team did not build it. Each object has one parent.
7. **Single-branch parent policies materialize large arrays** for org-wide roles (section 11).
8. **Forbid is deny-overrides** (section 9). It is not the exact `but not` of OpenFGA. Exclusions are relations of the same type only.
9. **No group memberships with an expiry.** The design rejects them. It does not give silent wrong results.
10. ~~**`who_can` omits public grants.**~~ Fixed: `who_can` returns one null row for a public grant (section 7; `c/54_who_can_public`).
11. **uuid only.** The design assumes that uuids are unique across principal types (memberships use the uuid alone as key).
12. **Storage:** memberships grow as principals × transitive groups (100k users in 50 groups give 5M rows).
13. **Provenance is lost.** Memberships say *that* Carol is in `platform`, but not why (they keep only the shortest depth). The team did not build `explain()`.
14. **"Compiled" only in part.** Checks still go through generic PL/pgSQL functions, and the planner cannot see into them. The gains are no recursion and typed keys. The design does not inline SQL for each type.

## 13. Deviations from the earlier draft

| Earlier draft | Built | Why |
| --- | --- | --- |
| Read functions take `subject_id uuid default current_subject()` | Separate admin-only `can_for` and `accessible_for`. `who_can` is admin-only. | A parameter with a default lets any client ask about any user (see [`../plan.md`](../plan.md) section 3). |
| `current_subject()` | `current_subject_id()` (uuid) and `current_subject_type()` | Shared identity contract (`01_identity`). |
| `can`, `accessible` and `who_can` raise on unknown names | They return false or empty | Same rule as the preset (plan section 6). This resolves open question 6. Writes still validate. |
| The preset takes `uuid` IDs | `text` IDs as in plan section 6, and `uuid` overloads for `has_permission` and `has_role` | The shared specs and the seed of the benchmark need the text signatures (section 8). |
| The preset edits "the active model" | `app` and `tenant` are reserved (a model can name them as parents but cannot define them). `apply_model()` carries them over. | Otherwise a graduation with a model that omits them would drop every role. |
| `accessible()` returns `setof uuid` | It returns `uuid[]`. The policy uses it as `= any ((select f())::uuid[])`. | This was the fastest form in the measurements (section 7). |
| The parent link is a tuple (`document:readme#org@org:acme`), with syntax `org->view_documents` | A dedicated `parents` table (one parent for each object). `"parent": [...]` and `parent->P` inside `P` only. All-or-nothing up the hierarchy. | A single parent makes a move one upsert and the closure a chain. The same-name rule keeps the flat compiled form exact (section 3). |
| Recursive parents reuse the memberships machinery | A separate `ancestors` table, for container types only | Leaf objects never get closure rows, so a move of a folder does not fan out to documents. |
| Forbid as an `excludes` table | A `forbid` flag on `satisfies`, with deny-overrides along the chain | One table. Section 9 describes the semantics. |
| `user:*` was an open question | `type:*` in the model, `grant_public`, null `tuples.subject_id`. `who_can` returns a null row for it. | G11. A separate function, so a null cannot grant public access. The null row matches the `user:*` row of A in `list_subjects`, and the `setof uuid` type of `who_can` does not change. |
| Membership expiry deferred | The design rejects it on write and at compile time | The design fails loudly and does not drift. |
| Maximum depth: reject or truncate (open question) | Reject (`54001`). `memberships.depth` stores the shortest path. | Open question 3. |
| `tuples` immutable | Only `expires_at` can change (a new grant updates it). `truncate` is blocked. | `31_zanzibar_groups` grants again with a new expiry. |
| `verify()` returns `(principal_id, set_key, problem)` | `(kind, member_id, set_key, problem)`, for memberships and ancestors | There are two derived tables. |
| `explain()`, `policy_sql()` | Not built | No goal needs them. Open question 8 stands. |

## 14. Open questions

These questions are from the time of the build. [`d-per-model.md`](./d-per-model.md) and [`../decision.md`](../decision.md) record the choice of D.

1. Is uuid-only acceptable, or does the design need a key kind for each type (`uuid` or `text`)?
2. Must the design use JSON only, or also an OpenFGA-style DSL (client-side)?
3. Must the design use a global lock, or per-key locks now? The measured `write_nest_team` is 333 ms p50 with 4 clients at large scale (`COMPARISON.md`). After session 3 it is about 60 ms (section 15). No prototype of per-key locks exists to compare against.
4. Must `memberships` hold a reflexive row for each principal, so that `can()` needs one branch and not two? That costs a row for each principal. It also needs the extension to know principals that it does not track now.
5. How must `apply_model()` express renames, so that they do not drop and add tuples again?
6. Is deny-overrides the forbid semantics that the team wants, or does it need the exact `but not` of OpenFGA?
7. Must the extension ship a trigger that keeps `parents` in sync with a column of the app (`folder_id`)?
8. Is `policy_sql()` worth a place in the extension, when the developer still pastes the result into a migration?

## 15. Optimizations (session 3)

The goal was to improve the weak spots of C. The team did not change its semantics or its character: materialized memberships, `verify()` and `rebuild()`, a typed model, and one global lock. The workloads, the seeds and the API of the benchmark seed are the same.

**How the team measured.** Two other agents optimized A and B on the same laptop at the same time, so the absolute numbers are noisy. Every figure below is **interleaved**. The team ran the original prototype (kept as `bench/results/optc/c-orig.sql`, git-ignored) and the new prototype in turns: old, new, new, old.

The command was `bench/run.sh --only <workloads> --tag opt-c` (Postgres 16.4, local, no Docker). Each cell shows the two runs. Reads and writes use `--clients 1` unless the row says 4 clients.

The big gaps (some times larger) are far outside the noise. The small gaps (under about 10%) are not.

The internal breakdowns come from `EXPLAIN (ANALYZE, BUFFERS)` and `auto_explain` (nested statements) on a persistent large-scale database. They also come from pgbench runs that alternated between an old copy and a new copy of that database.

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
| `nest_check`, medium deep (one pair) | 0.26 | 0.30 | unchanged (the team did not touch `can()`) |

Checksums: every run, old and new, printed the same checksums for each phase (rbac, sharing, parents_proj, parents). Every run reported "same" against the latest equivalence files of A and B, at large default, medium wide and medium deep. On the persistent database, the new `_accessible()` returned the same sorted id set as the old one. This held for all 10,000 users and three permissions (`documents.read`, `viewer`, `editor`). After the wide seed, the `memberships` table had 657,256 rows. The md5 over `(principal, set, depth)` was the same for the old code, the new code and the new bulk API.

### 15.1 Insert trigger: a delta instead of a recompute

**What.** `_tuples_after_insert` no longer recomputes the affected principals. Inserts only add paths, so memberships can only gain rows or get shorter. The trigger now writes one row for each pair of a member and a set.

The members are the members of the subject of the new tuple (read from the stored memberships). The sets are the usersets of the object and every set above them (from one upward walk). The depth is the depth in the subject, plus 1, plus the distance above the object.

It upserts with `on conflict ... do update ... where excluded.depth < memberships.depth`, and it deletes nothing.

Section 5 has the completeness argument (the first new tuple on any new path). The argument also covers multi-row inserts and the depth limit. The walk goes 10 hops up. Thus a set that is first reachable at depth 11 shows up as a candidate of 11, and the write raises `54001`, as before.

Deletes still recompute the affected principals. A delete can make paths longer or remove them, and to know this the design needs path counts that C does not store.

**Why.** At large scale, the nest of the 1,000-member `nest-src` spent 83 ms in the recursive walk for each principal. The walk derived 1,000 × 6 rows again, and 1,000 of them already existed. In that plan, the recursive term ran a sequential scan of `satisfies` 30,000 times and threw away 160,833 joined rows. The reason is that the document grants of a team share `tuples_userset` with its nestings.

Then the delete of the diff scanned `memberships_pkey` for the 1,000 principals. It visited 244,087 index entries to find 1,000 live rows. The other 243k entries were dead rows from earlier nests that the benchmark rolled back. Bitmap scans never mark entries dead.

The delta skips both costs: no walk for each principal, and no delete. Two costs remain. The first is the walk from the target team (5 rows, under 0.1 ms). The second is the insert of 5,000 new rows (about 10 ms, with 67k buffer hits for the heap and two indexes). That is the floor for materialized memberships.

For the wide seed, a user who joined the k-th team caused a recompute of all k teams of the user. Thus 50 teams for each user cost about 50²/2 walks for each user. Now each grant upserts the 5 or 6 rows above that one team.

### 15.2 Set-level walks, filtered in the index

**What.** The two walks that remain are the insert delta and `_memberships_for` on the delete path. Both walk between usersets, not between (principal, userset) pairs. `_memberships_for` takes the direct sets of each principal from its own tuples. It walks up once for each distinct direct set, and joins back.

The recursive step restricts `tuples.relation` to the relations that feed a userset. This is an index condition on `tuples_userset` (its last key column is `relation`), so the walk never visits the document grants of a team. `_memberships_for` became PL/pgSQL, so Postgres caches its plan. Postgres 16 plans the body of a SQL function on every call if it does not inline the function. The `set search_path` clause blocks the inline expansion.

**Why.** The delete path had the same walk for each principal. The team nested and un-nested `nest-src` at large scale (pgbench, with old and new copies of one database in turns). The time was 102 and 104 ms before, and 30 and 25 ms after.

**Kept separate on purpose.** `_memberships_all()` keeps its own walk for each principal. `verify()` and `rebuild()` use it. `verify()` is the oracle for the incremental code, so it does not share code with that code.

### 15.3 `accessible()`: one sort, sorted output

**What.** `_accessible()` first resolves the relation ids and type ids into variables. It filters container expansions with a plain `object_type = v_type` (no join with a CTE). It builds the result with `distinct on (object_id) ... order by object_id, forbid desc`.

This single sort removes duplicates and applies the forbid veto. A vetoed id sorts its forbid row first, and the function drops it.

The output is sorted. The result set is the same, and only the order of the array is new. Nothing depended on the order. With an unknown subject type, the function still returns ids from memberships, as before.

**Why.** Take the single-branch policy at large scale (user 1, 20,007 ids). The old version materialized every reachable id in a CTE, ran a hashed `except`, and then ran `array_agg`. Then the index scan of the documents sorted the 20k-element array again before its first probe (`_bt_preprocess_array_keys`). The gap before the first row was 5.3 ms in the old plan and 0.5 ms in the new plan. The reason is that an array that is already sorted costs a single pass.

Under EXPLAIN ANALYZE, the InitPlan (the `accessible()` call itself) went from 9.1 ms to 6.5 ms, with the same buffers (277 against 272 hits). `count(*)` keeps its 60.3k buffer hits. These are 20k separate index descents into `documents_pkey`, which is now most of the cost that remains (15.6).

### 15.4 Bulk load: `grant_many()` (new, optional)

**What.** The signature is `permissions.grant_many(object_type, relation, subject_type, object_ids uuid[], subject_ids uuid[], subject_relation default null) returns bigint`. It grants one relation for many (object, subject) pairs in one statement. The pairs match by position. The function checks the names once. It skips pairs that already exist (with no expiry, so use `grant()` for that).

The insert trigger maintains memberships once for the whole batch. It is admin-only, like `grant()`. `c/33` tests it.

**Why.** Real apps import data. The multi-row delta makes a batch cost about one walk for each distinct target set, plus the rows that it writes. The seed of the benchmark still uses `grant()`, so the table above does not include this function.

The team tested a variant of the wide sharing seed that uses `grant_many` (five calls and not 306k `grant()` calls, not committed). It loaded in **7.9 s**, or 7.1 s when the nestings load before the members. The per-row seed took 27.6 s on the same database (the per-row seed of A takes 10 s). The variant produced the same memberships.

### 15.5 Tests

The new file `test/spec/c/33_incremental_memberships.sql` has 13 assertions. It covers these cases:

- a shortcut that lowers a stored depth;
- a cycle that closes;
- a multi-row insert of a whole chain;
- an implied userset (`admin` implies `member`);
- the depth limit that a delta reaches (and nothing left behind);
- `grant_many`;
- 400 seeded random grants, revokes, multi-row inserts and multi-row deletes over 10 teams and 12 users, with a clean `verify()` after every one.

Its membership cases also pass on the original prototype. The exception is `grant_many`, which is new. The team made four copies of the delta with deliberate breaks, and the tests caught each break. The breaks, and the specs that caught them, were:

- members of a userset subject ignored (`c/31`, `c/32`, `c/33`);
- no upward walk (`c/32`, `c/33`);
- depth never lowered (only `c/33`);
- no depth check (`c/32`, `c/33`).

The full suite at that time was 18/18 files and 217/217 assertions (now 21/21 files and 229 assertions).

**Lock: unchanged.** It is still one global advisory lock. The new insert path reads the stored memberships and walks the tuples after it takes the lock, like the old path. The team checked again with two real sessions, in both orders.

In the first order, session 1 adds Carol to `eng` and holds its transaction open, and session 2 nests `eng` into `platform`. The second order is the reverse. `verify()` was clean, and Carol was in `platform` both times.

The team replaced `_lock_graph()` with a no-op. Then both orders left out the `platform` membership of Carol, and `verify()` reported it.

### 15.6 Tried and dropped

| Idea | Result |
| --- | --- |
| A plain `insert ... where not exists` and a separate `update` for shorter depths, in place of `on conflict` (safe under the global lock) | Not faster. `write_nest_team` took 17.0 and 17.3 ms with `on conflict`, against 18.6 and 21.3 ms (1 client, large, old and new in turns). Dropped. |
| The upward walk as a shared helper function (`_sets_up`) that the trigger calls | As a SQL function, Postgres planned it on every call. As PL/pgSQL with custom plans, Postgres also planned it again. `force_generic_plan` fixed that (5,000 user-to-team grants: 1.9 s to 0.93 s). When the team wrote the walk inline in the trigger statement, it was 20% faster again (145 to 117 µs for each grant). Thus the team dropped the helper. |
| The first `accessible()` rewrite: `group by ... having not bool_or(forbid)` and `array_agg(... order by ...)` | The page time went from 10.5-11.0 ms to 7.2-8.6 ms, but the plan hashed and then sorted. The single `distinct on` sort replaced it (4.6-5.2 ms on the same database). |
| Narrower locks (advisory locks for each team, in a consistent order) | Not built. It would not help this workload, and it is not simple. Every `write_nest_team` nests the same `nest-src`, and every target is under one of three tree roots. Thus concurrent nests insert the same (member, root) membership keys. The second nest waits on the uncommitted index entry of the first, whatever the advisory lock does. A sound per-key scheme also needs shared locks on what a write reads (the members of S, the sets above O). It needs exclusive locks on what a write changes (the sets above O, the sets below S). Those sets come from the graph that the write reads before it locks. Thus the scheme needs re-checks or `40001` retries. A write that only adds paths can take shared locks against other writes that add paths. It cannot do this against deletes or container moves. |
| Work before the lock is taken | Not possible. The delta must read memberships and tuples as they are after the lock. Otherwise it misses a concurrent committed write (the race above). The type check and the tuple insert already run before the lock. |
| A set-to-set closure table, so that the addition of a member is one index lookup | Not built. The walk costs about 26 µs for each grant. A third derived table needs its own maintenance, its own `verify()` coverage and its own drift risk. |

### 15.7 Hard limits that remain

- **A nest writes members × (1 + ancestors) rows under the lock.** This is 5,000 rows, about 10 ms, for the nest in the benchmark. With 4 clients, the latency is about 4 × the single-client time (58-60 ms against 15.5-15.9 ms). Per-key locks would not change that here (15.6). A still writes one tuple.
- **The single-branch count does one index descent for each visible id.** At large scale, this is about 20k probes into `documents_pkey`, 60k buffer hits, and about 9 ms of the 14 ms. The projection policy reads a few contiguous `folder_id` ranges instead (2.7 ms). Postgres 17 skips repeated descents for array keys that are near each other. This can help, but the team has not measured it here.
- **The single-branch page builds the whole id array** (20k ids, about 4-5 ms) to return 50 rows. The projection policy is still about 5× cheaper (1.0 ms). It stays the recommended form for large tenants.
- **A `grant()` of memberships for each row costs about 0.1 ms** (trigger, transition table, one delta statement). An object grant costs about 0.04 ms. The wide seed at 24 s is still about 2.4× the 10 s of A. `grant_many` loads it in 7-8 s.
- **Deletes recompute.** A revoke of a nest recomputes every member of the subject (now with a set-level walk). A delta delete would need counts for each path. This is a bigger change to the derived data.

**Expected in the serial confirmation run** (4 clients, as in `COMPARISON.md`):

- `write_nest_team` at large scale goes from 333 to about 55-65 ms (11 to about 60 tps). Wide goes from 145 to about 60 ms. Small goes from 62 to about 15-25 ms.
- `parents_select_page` at large scale from 9.6 to about 5 ms, and `parents_select_count` from 22 to about 14-16 ms.
- The wide sharing seed from 183 s to about 25 s.
- Wide reads and `nest_check` unchanged within noise.
- Checksums identical to A and B.

### 15.8 `scopes_with_permission` does not get pre-evaluated (the STABLE double-execution trap)

**Observation.** During the optimization of A, `list_objects` turned out to run twice for each query. It ran once during planning and once during execution (see [`a-tuple-core.md`](./a-tuple-core.md) section 13). The policies call these functions with constant arguments inside `array(select unnest(...))`.

To estimate the row count of the unnest, the planner pre-evaluates STABLE functions that have constant arguments (`estimate_expression_value`). The team marked the functions VOLATILE, and this removed the run at plan time. On that change alone, the wide `share_select_page` of A went from 207 ms to 110 ms.

**Does C have it? Yes for `scopes_with_permission`. No for `accessible()` in the policy form.** The team ran `EXPLAIN (ANALYZE, BUFFERS)` as user 1 on medium wide. The sharing policy was `org_id = any (array(select unnest(scopes_with_permission('documents.read'))::uuid)) or id = any ((select accessible('document', 'viewer'))::uuid[])`.

- `Planning: Buffers: shared hit=1422` is exactly the buffer count of the `scopes_with_permission` InitPlan at execution (1,422). Planning Time was 1.27 ms (7.7 ms on the first, cold run), against 11.3 ms for execution.
- The `accessible()` arm does not appear in the planning buffers. `(select accessible(...))::uuid[]` is a scalar subquery, and the planner does not pre-evaluate it.
- After the change to `VOLATILE`, the planning buffers are gone. Planning Time is 0.03 ms (0.3 ms cold).
- The same call outside the blessed form does execute twice. `id = any (array(select unnest(accessible(...))))` and the bare `id = any (accessible(...)::uuid[])` both show the evaluation at plan time (about 1,213 extra planning buffers, 3-4 ms of planning). These are not the documented policy form, so `accessible()` stays STABLE. VOLATILE would also mean that the bare form is not an index qual. Use `(select accessible(...))::uuid[]`, as in section 7.
- `has_permission`, `has_role` and `can` (boolean quals, shown as One-Time Filter) show no evaluation at plan time. The single-branch policies and the projection policies (`parents_select_*`, `parents_proj_*`) also show none, because they call `accessible()` only as a subquery. Thus nothing changed for them.

**Change (first version: VOLATILE).** The team made `scopes_with_permission` `language sql volatile` (it still only reads). The planner then assumes 10 elements for the unnest, and not the real count. The plans did not change in any workload. The measurements below are for this version.

**Final version: STABLE with a volatile default argument.** Design B showed the cost of VOLATILE. Under read committed, a volatile function takes a fresh snapshot for each query that it runs. Thus the grants that it reads can be from a later time than the rows that the statement filters. This weakens the consistency of a single snapshot inside one statement.

STABLE functions read the snapshot of the statement. So `scopes_with_permission(p_permission text, p_unfold boolean default permissions._unfolded_null())` is `stable` again.

`_unfolded_null()` is a VOLATILE plpgsql function that returns null. A volatile argument is not a constant. Thus the planner cannot pre-evaluate the call, and the body of the function still sees the snapshot of the statement. The function ignores `p_unfold`, and callers use the same one-argument form as before.

The extension grants `_unfolded_null()` to public, because a default expression runs as the caller. (If a call passes every argument as a constant, for example `scopes_with_permission('x', true)`, the planner folds it again.) The spec `test/spec/c/56_volatility.sql` checks `pg_proc.provolatile`. It asserts that `can`, `accessible`, `has_permission`, `has_role` and `scopes_with_permission` are STABLE. This is the technique of B (its `ids()`).

The team checked the final version again with `EXPLAIN (ANALYZE, BUFFERS)` as user 1, medium default, and the sharing policy (scopes arm plus `(select accessible(...))::uuid[]`):

| Version | Planning Time | Planning buffers |
| --- | --- | --- |
| STABLE, no dummy argument (folded) | 3.2-3.4 ms | 1,122 |
| VOLATILE | 0.24-0.26 ms | 109 |
| STABLE + `_unfolded_null()` default | 0.27 ms | 112 |

The 109-112 buffers are catalog lookups. The checksums are the same (sharing `9b43a472...` at medium default, the same as A and B).

**Measured.** The team ran the old and new files in the order old, new, new, old, old, new, 3 rounds each. The command was `bench/run.sh --only ... --clients 1 --tag opt-c2` on local Postgres 16.4, 10 s for each run. The old file is kept as `bench/results/optc2/c-orig.sql`, git-ignored.

Other agents ran benchmarks on the same machine. One old run (round 3) and one new run (round 2) were clearly disturbed, so the medians matter more than the means. The table shows p50 ms for each round (old | new):

| Workload | Old | New | Median old / new |
| --- | --- | --- | --- |
| medium default `rbac_select_page` | 0.41, 0.62, 1.98 | 0.33, 0.35, 0.33 | 0.62 / 0.33 (best of: 0.41 / 0.33) |
| medium default `rbac_select_count` | 0.36, 0.50, 0.37 | 0.28, 0.26, 0.27 | 0.37 / 0.27 (best of: 0.36 / 0.26) |
| medium wide `share_select_page` | 10.84, 11.95, 11.21 | 10.52, 14.97, 11.52 | 11.21 / 11.52 (best of: 10.84 / 10.52) |
| medium wide `share_list_objects` (no scopes call) | 3.31, 3.34, 3.35 | 3.29, 3.77, 3.42 | 3.34 / 3.42 (control) |

RBAC reads are 20-30% faster, because planning was a big part of a 0.4 ms query. The wide sharing page gains about 1.2 ms of 11 ms (the call at plan time). This is inside the noise of this machine. The best-of figures agree with it, but they do not prove it.

C gains little there, because its `scopes_with_permission` is a lookup in materialized memberships (about 1.2 ms). The same function in A was a walk of 100 ms. The `parents_*` workloads do not call `scopes_with_permission`, so the team did not run them again.

**Checks.** The runs printed identical checksums for old and new (rbac `d394663f...`, sharing `6f7c008d...`). They reported "same" against the latest equivalence files of A and B. At the time of that run, the full suite was unchanged: 18/18 files and 217/217 assertions. The suite is now 21/21 files and 229 assertions, after the plan-time specs and the volatility specs.
