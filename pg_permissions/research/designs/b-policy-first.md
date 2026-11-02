# Design B: Policy-first

> Status: this design is history. The team built it and measured it, but did not choose it. Design D is the extension. See [`d-per-model.md`](./d-per-model.md).

> One of three candidate designs. See [the plan](../plan.md) for the shared goals, requirements and evaluation criteria.
>
> Status: **built** as [`../../prototypes/b-policy-first.sql`](../../prototypes/b-policy-first.sql). This document describes what the prototype does. The build changed the original design in some places. [Deviations from the original design](#deviations-from-the-original-design) lists each change and its reason.

## Summary

One small policy table makes every decision. A policy has the shape of a Cedar policy. It has a principal scope, actions, a resource type, an optional "role on anchor" requirement, an optional condition, and an effect (`permit` or `forbid`).

Roles, group memberships and parent links are facts. Policies read these facts. The design stores group and parent membership as a closure that it computes on write. Thus a decision is a small number of flat joins with no recursion.

The RLS fast path is a partial evaluation. It answers one question: "which resource ids or parent ids does this policy set let me reach?" A parent id is the id of a folder or an org. The design computes the answer once for each query.

## Core idea

A tuple store with a read-time graph walk puts the authorization logic inside the graph. The rule `editor` implies `viewer` is a rewrite rule. The rule "org admins can edit org documents" is a tupleset rewrite. The answer to "can X do Y" comes out of a recursive CTE. This design moves that logic into explicit policies. It keeps the data simple:

- **Facts** say who is in what group and who holds which role on what. The table `parents` holds membership (Carol is in team `eng`, folder `specs` is in org `acme`). The table `role_grants` holds roles (Alice holds `admin` on org `acme`). The table `role_implies` holds implication (`editor` implies `viewer` on documents).
- **Policies** say what those facts give permission to do. Examples: "anyone who holds `member` on the org of a document can `select` the document", "Dave cannot `select` readme".
- **One evaluator** answers every question. It matches the policies against the facts. RBAC, ReBAC, public access, forbid and attribute rules are different policy shapes. They are not different designs.

This design can be better than a tuple store with a read-time walk, for these reasons:

1. **Documents never enter the permission store.** The org or folder of a document is a column of the document. A policy with `via => 'folder'` gives access through that column. RLS matches `folder_id` against the folder ids that the caller can reach. In the tests and benchmarks, no document row exists in a permissions table, unless the document has its own grant.
2. **No recursion at read time.** The design precomputes the nesting of groups and folders into `ancestors` (depth 10 at most, and the write rejects cycles). It precomputes role implication into `role_closure`.
3. **Policy changes are cheap and auditable.** To add "members can view", add one row. This needs no backfill. `explain()` answers "why can Dave see this?" with the name of a policy and the grant that matched.
4. **Forbid and conditions have an obvious place:** the `effect` and `condition` columns of a policy. They are not a new tuple semantic.

The trade-off is that a policy can have only a shape that the design can partially evaluate into an SQL filter. This limit is deliberate. What we can index decides the shape of the policy language.

## Schema (as built)

All objects are in the fixed schema `permissions`. Entity ids are `text`, so uuid, bigint and slug keys all fit.

| Table | Holds | Written by |
| --- | --- | --- |
| `entities(type, id, attrs jsonb)` | Attributes of principals. Conditions read them (`principal.attrs.*`) | `set_attrs` |
| `parents(child_type, child_id, parent_type, parent_id)` | User in team, team in team, folder in org, folder in folder | `add_parent`, `remove_parent` |
| `ancestors(child, ancestor, depth)` | Transitive closure of `parents` for **inner nodes** (entities that are the parent of something). `depth` is the shortest path, 1-10 | triggers on `parents` only |
| `closure` (view) | Every (descendant, ancestor) pair: the direct `parents` rows plus the stored rows of each direct parent. The read paths use it | nothing (a view) |
| `roles(resource_type, role)` | Roles that the design declares for each resource type, so a typo fails when the grant is made | `define_role` |
| `role_implies(resource_type, role, implies)` | `editor` implies `viewer` | `define_role` |
| `role_closure(resource_type, role, implied)` | Reflexive transitive closure of `role_implies` | `define_role` rebuilds it for each type |
| `role_grants(principal, role, resource, expires_at)` | A principal (user or group) holds a role on a resource, optionally until a time | `grant_role`, `revoke_role` |
| `policies` | Permit and forbid rules (below) | `permit`, `forbid`, `drop_policy` |

A policy row has these columns:

- `effect` (`permit` or `forbid`).
- A principal scope: `principal_type` (default `'user'`, null = any). It has an optional `principal_id` for one principal. It has optional `principal_in_type` and `principal_in_id` for "member of this group".
- `actions text[]`, `resource_type`, and an optional `resource_id`.
- Optional `roles` plus `via` (the anchor).
- The `condition` as written, plus its two halves `principal_condition` and `resource_condition` (the write splits them).
- `managed_by` (`'rbac'` for the policies that the preset generates) and `enabled`.

The columns for ids, types and roles are `collate "C"` (opaque keys; see [Optimizations](#optimizations-session-3)). These indexes matter:

- The `role_grants` primary key `(principal_type, principal_id, resource_type, resource_id, role)`. Every check probes it by subject and anchor.
- `role_grants (resource_type, resource_id, principal_type, principal_id)`, for `who_can`. It is also an exact probe for checks.
- The `parents` primary key, for "my parents".
- `parents (parent_type, parent_id, child_type, child_id)`, for "children of this folder" (index-only).
- The `ancestors` primary key, for the ancestors of an inner node.
- `ancestors (ancestor_type, ancestor_id, child_type, child_id)`, for "inner nodes under this org".

### Closure maintenance and concurrency

`ancestors` holds rows only for inner nodes: a team with members, a folder with documents, an org with folders. A leaf (a user, a document) is one hop away. Its ancestors are its `parents` rows plus their stored rows. The `closure` view joins these (no recursion).

A row-level `before insert` trigger and an `after delete` trigger on `parents` maintain the table. The triggers reject updates. To change a row, remove it and add it again. Each trigger that does work first takes one transaction-scoped advisory lock, `pg_advisory_xact_lock(hashtext('permissions.closure'))`. Thus the closure writers run one at a time.

- **Insert `c -> p`:** Reject the insert if `p` is already below `c` (a cycle, SQLSTATE `23514`). Reject it if any new path is deeper than 10 (`23514`). If `p` has no stored rows (this is its first child), store its ancestors. If `c` is itself an inner node, every inner descendant-or-self of `c` gets every ancestor-or-self of `p` (`on conflict ... depth = least(...)`).

  A leaf child writes no closure rows. The trigger runs *before* the insert. Thus a multi-row insert sees only the rows that the statement inserted before it. The original after-trigger, which never read `parents`, had the same effect. The insert skips a row that already exists (ON CONFLICT drops it).
- **Delete `c -> p`:** Only `c` and its descendants can change, and only the inner nodes have rows. The trigger deletes their rows and rebuilds them from `parents` with a depth-bounded recursive walk. A parent that has no children loses its rows.
- **Isolation:** The trigger computes the closure from what the transaction sees *after* it gets the lock. Under read committed, each statement takes a new snapshot. Thus it sees the rows that the previous writer committed. Under serializable, a stale read is a serialization failure, which aborts the transaction.

  Under **repeatable read**, the snapshot is older than the lock. The closure would silently miss an edge of a concurrent writer. So the writes to parents and role definitions raise `0A000` there. (Design C makes the same decision.)
- `role_closure` is rebuilt for one resource type under a second advisory lock (`permissions.roles`). It has the same isolation guard.

The write enforces the depth cap. The read does not truncate at the cap. Thus a check never gives a partial answer without an error.

## Link to identity

The extension stores no users. A subject is a `(type, id)` pair. The file `test/spec/01_identity.sql` fixes the contract. `permissions.current_subject_id()` returns the JWT `sub` (`request.jwt.claims`).

If there is no `sub`, it returns the `permissions.subject_id` setting. If there is no setting, it returns null. `current_subject_type()` is `'user'` by default.

- **No subject**: every check returns false, and every `ids` call returns `'{}'`. This is default deny (asserted in `b/51_public`).
- **Explicit subject**: every client function has a `*_for` variant. It takes `subject_type, subject_id`. The design revokes these functions from `public`. Otherwise any client could ask "what can Alice see?".
- **User deletion**: `permissions.delete_entity(type, id)` removes the attributes of the entity and the grants that it holds. It removes the grants on the entity and its `parents` edges (the triggers update the closure). It also removes the unmanaged policies that name the entity. For automatic cleanup, attach `permissions.on_entity_deleted('user', 'id')` as an `after delete` trigger on the identity table of the app. It reads `to_jsonb(old) ->> tg_argv[1]`, so there is no dynamic SQL. The design revokes execute from `public`.

## Public API (as built)

Read functions are `stable security definer set search_path = ''`. They must be `security definer` because callers have no `select` on the tables.

```sql
-- current subject: granted to public, safe in RLS
permissions.can(action, resource_type, resource_id, resource jsonb default '{}') returns boolean
permissions.ids(action, resource_type, via default null, resource_condition jsonb default null) returns text[]
permissions.denied_ids(action, resource_type, via default null, resource_condition jsonb default null) returns text[]
permissions.allows_all(action, resource_type, resource_condition jsonb default null) returns boolean
permissions.denies_all(action, resource_type, resource_condition jsonb default null) returns boolean

-- explicit subject and debug: admin only
permissions.can_for(subject_type, subject_id, action, resource_type, resource_id, resource jsonb default '{}')
permissions.ids_for / denied_ids_for / allows_all_for / denies_all_for(subject_type, subject_id, ...)
permissions.who_can(action, resource_type, resource_id, resource jsonb default '{}')
    returns table (subject_type, subject_id, policy)
permissions.explain(subject_type, subject_id, action, resource_type, resource_id, resource jsonb default '{}')
    returns table (effect, policy, matched_grant jsonb)
permissions.is_in(child_type, child_id, parent_type, parent_id) returns boolean    -- Cedar's `in`

-- facts: admin only
permissions.define_role(resource_type, role, implies text[] default '{}')
permissions.grant_role(principal_type, principal_id, role, resource_type, resource_id, expires_at default null)
permissions.revoke_role(principal_type, principal_id, role, resource_type, resource_id) returns boolean
permissions.add_parent(child_type, child_id, parent_type, parent_id)
permissions.remove_parent(child_type, child_id, parent_type, parent_id) returns boolean
permissions.set_attrs(type, id, attrs jsonb)
permissions.delete_entity(type, id) returns bigint

-- policies: admin only
permissions.permit(name, actions text[], resource_type,
                   roles => null, via => null, principal_in_type => null, principal_in_id => null,
                   resource_id => null, condition => null, principal_id => null, principal_type => 'user') returns bigint
permissions.forbid(...same arguments...) returns bigint
permissions.drop_policy(name) returns boolean          -- refuses policies managed by the rbac preset

-- RLS tooling: admin only
permissions.rls_expression(action, resource_type, id_column default 'id', via_columns jsonb default '{}', id_type regtype default 'uuid') returns text
permissions.apply_rls(table regclass, command, resource_type, id_column default 'id', via_columns jsonb default '{}', to_role default 'authenticated')
permissions.lint() returns table (problem, policy)
```

## Evaluation

### Anchors

A policy with `roles` needs the principal, or a group of the principal (through `ancestors`), to hold one of those roles on an **anchor**. The principal holds the role directly or through `role_closure`. The grant must not be expired.

- `via => null`: the anchor is the resource itself.
- `via => 'folder'`: the anchor is any `folder` among the parents of the resource, strictly above the resource. The parents of a resource are:
  1. the values in the `resource` jsonb argument (the columns of the row). Every key is an attribute. A key that names a type is also a parent of that type: `{"folder": "<id>"}` says that the folder of the document is `<id>`. A key that names a **principal type** is an exception.

     A principal type is a type that a policy uses to scope principals (`principal_type` or `principal_in_type`), or a type that holds a grant. Such a key is only an attribute, unless a policy on the resource type anchors `via` that type. Principals are in `parents` as group members (user in team in org). If the design read `{"user": "<author>"}` as a parent, the teams and orgs of the author would become anchors of the row (`b/54_fail_closed`). A null value names no parent;
  2. its rows in `parents`, for resources that are entities (the org of a folder);
  3. transitively, every ancestor of either, from `ancestors`.

Take folder `specs` in org `acme`, and `folder_id = specs` for readme. A policy with `via => 'org'` reaches readme through `acme`. The design stores nothing about readme itself (`b/50_parents`).

A policy with no `roles` needs no grant. It matches every principal in its scope. It matches either one resource (`resource_id`, which is how public access works) or every resource of the type (allow-all).

### Decision

`can()` evaluates `_matches()`. This is the only place that matches policies against one concrete resource. `can()` returns **true if a permit matches and no forbid matches**. Forbid always wins.

There are no priorities, as in Cedar (`b/52_forbid`). The evaluation of conditions uses the attributes of the row. `_candidate_policies()` gives the principal scope and the row-independent condition. `ids()` and `who_can()` also use it.

**Missing inputs fail closed.** `can()` knows the row only through its `resource` argument. A forbid can read a parent or an attribute that the caller did not give. Then the forbid would silently not match, and the answer would be "allowed".

So `_matches()` raises `22023` instead. The error names the forbid and the missing input. It raises when a forbid that can apply to the subject needs an input that is not there. These rules apply:

- A forbid can apply when three conditions are true. Its principal scope and principal condition match. It names this resource or none. It needs no role, or the subject or a group holds one of its roles on a resource of its anchor type.
- A resource condition needs every `resource.<attr>` that it reads to be a key of `resource`.
- `via => T` needs a `T` key in `resource`, or a `T` ancestor that is known from the facts. The facts are the `parents` rows of the resource, or the ancestors of a parent key. The stored org of a folder counts, so `{"folder": specs}` covers a `via => 'org'` forbid.

A key with a null value counts as given: `{"folder": null}` says that the row has no folder. A null folder gives no information about the org. So a `via => 'org'` forbid then needs `"org"` too. A forbid that cannot apply costs nothing.

For example, take a forbid that needs the `blocked` role on a folder. A user who holds no `blocked` role anywhere can call `can()` without the folder. `who_can` and `explain` go through `_matches()`. Thus they raise in the same way (`b/54_fail_closed`).

The design raises an error instead of two other options. The first option is to resolve the missing inputs from the facts. The design already does this where it can (stored parents and ancestors). But the folder column and the attributes of a document are not facts in B, so there is nothing to resolve them from. If `can()` read `entities.attrs` for the resource, `can()` and RLS (which reads the columns) could disagree.

The second option is to treat the forbid as a match. This also fails closed. But it turns a caller bug into a silent "denied" that looks like a policy decision. It also makes `who_can` return nobody without a signal. The error names the policy and the key to pass.

This is the same position as the schema validation of Cedar, where a request without an attribute that it must have is an error. Cedar has a runtime alternative: skip a policy that errors. That alternative is exactly the fail-open behavior for forbids that this design avoids. RLS is not affected. `apply_rls` never calls `can()`, and a hand-written per-row `can()` policy passes the real columns, null or not.

### Partial evaluation for RLS: `ids()`

`ids(action, type)` returns the ids of the resources that match through their own grants, through ancestors in the parents table, or through a `resource_id` policy. `ids(action, type, 'folder')` is a **projection onto the parent column**. It returns the folder ids `F` such that a resource with the direct parent `F` would match. The result has two parts.

The first part is the folders where the caller holds a role that matches (`via => 'folder'`). The second part is every folder below an anchor that the caller holds (`via => 'folder'` on a parent folder, `via => 'org'` on the org). With this, one RLS branch, `folder_id = any(...)`, covers org-level and folder-level access together (G10).

`ids_for` is net of unconditioned forbids in the same projection. A forbid on readme removes readme from the id list. A forbid on a folder removes the folder. Thus it also works as "list what I can see" (`b/52_forbid` assertion 3). This holds for the forbids that it can evaluate without the row (see [Weaknesses](#weaknesses-and-risks)). `denied_ids` and `denies_all` give the forbid side separately, for RLS.

`can()` and `ids()` are two implementations of one semantics. This is the risk that the original doc warned about. During the build, the team checked them against each other on random data. The data had 20 users, 60 documents in 12 nested folders under 3 orgs, groups and two forbids.

The team checked every user × document × action (2,400 cases). There were **0 disagreements** between `can_for(...)` and `(id ∈ ids ∨ folder ∈ ids(folder)) ∧ ¬(id ∈ denied_ids ∨ folder ∈ denied_ids(folder))`. There were 0 between `who_can` and `can_for`. This was an ad-hoc check. It is not a committed spec file.

### Conditions

A condition is a jsonb AST. PL/pgSQL interprets it with no `execute`:

```json
{"op": "==", "left": {"var": "resource.status"}, "right": "published"}
```

Operators: `and`/`or` (`args`), `not` (`arg`), `has` (`var`), `==`, `!=`, `<`, `<=`, `>`, `>=`, `in`. Variables: `principal.id`, `principal.type`, `principal.attrs.*`, `resource.<attr>`, `context.*` (the `permissions.context` setting, plus `context.jwt` = JWT claims) and `now`. Comparisons use the jsonb order. A missing or null operand makes a comparison false.

On write, the design splits the top-level `and` into two halves. The **principal half** has the principal, context and now terms, and `ids()` evaluates it once for each query. The **resource half** has the `resource.*` terms. A term that mixes the two cannot be partially evaluated. The write rejects it with `22023`.

- `can()` evaluates the resource half against its `resource` jsonb.
- `ids()` includes only the policies whose resource condition equals its `resource_condition` argument (null = unconditioned).
- `rls_expression` emits one more group for each distinct resource condition, `(<condition compiled to SQL> and (id = any(ids(..., cond)) or folder_id = any(...)))`. The compiler maps `resource.status` to column `status`. It compares through `to_jsonb(col)`, so the SQL means exactly what the interpreter means (`b/53_conditions`).

Grant expiry is a column on `role_grants`. It is not a condition, so it costs nothing.

## RLS

The fast path rule from section 4 of [the plan](../plan.md) is `col = any (array(select unnest(f())::uuid))`. Every call is an uncorrelated `(select ...)`. So Postgres runs it once for each query as an InitPlan. The work for each row is an array membership test. This test can use the index of the column.

`rls_expression('select', 'document', 'id', '{"folder": "folder_id"}')` produces:

```sql
(
    id = any (array(select unnest(permissions.ids('select', 'document'))::uuid))
    or folder_id = any (array(select unnest(permissions.ids('select', 'document', 'folder'))::uuid))
) and not (
    (select permissions.denies_all('select', 'document'))
    or id = any (array(select unnest(permissions.denied_ids('select', 'document'))::uuid))
    or folder_id = any (array(select unnest(permissions.denied_ids('select', 'document', 'folder'))::uuid))
)
```

The expression also has one group for each resource condition. It has an `allows_all` arm when an allow-all permit exists. `apply_rls` runs it through `create policy` for `select` (`using`), `update` (`using` and `with check`), `delete` and `insert` (`with check`). It uses the InitPlan form for writes too, because the InitPlan runs once for each statement and not once for each row. The per-row `can()` stays available for hand-written policies.

**Result: a boolean arm breaks index use.** The first version always emitted `(select permissions.allows_all(...)) or id = any(...) or ...`. In an OR with the id arms, a boolean InitPlan prevents a BitmapOr over the indexes. On the 10k-document benchmark data, a count changed from a bitmap/index scan to a Seq Scan.

This is the same class of trap as the hashed subquery in section 4 of [the plan](../plan.md). Now the permit side emits `allows_all` only if an allow-all policy exists when the generator makes the expression. (The generator joins the forbid side with AND. So `denies_all` is always present and is harmless.) `lint()` reports the allow-all permits that no RLS policy includes.

Hand-written policies are also correct. `b/50_parents` uses the single branch `folder_id = any (array(select unnest(permissions.ids('select', 'document', 'folder'))::uuid))`. The benchmark uses the two-branch shape of A.

## Reference scenario end to end

This scenario is from `test/spec/b/30_zanzibar_reference.sql` (the fixture UUIDs are abbreviated):

```sql
select permissions.define_role('org', 'member');
select permissions.define_role('org', 'admin', '{member}');
select permissions.define_role('org', 'owner', '{admin}');
select permissions.define_role('document', 'viewer');
select permissions.define_role('document', 'editor', '{viewer}');

select permissions.permit('org members view docs', '{select}',        'document', roles => '{member}', via => 'org');
select permissions.permit('org admins edit docs',  '{update,delete}', 'document', roles => '{admin}',  via => 'org');
select permissions.permit('doc viewers view',      '{select}',        'document', roles => '{viewer}');
select permissions.permit('doc editors edit',      '{update}',        'document', roles => '{editor}');

select permissions.grant_role('user', :'alice', 'admin',  'org', :'acme');
select permissions.grant_role('user', :'carol', 'member', 'org', :'acme');
select permissions.add_parent('user', :'carol', 'team', :'eng');
select permissions.add_parent('user', :'dave',  'team', :'eng');
select permissions.grant_role('user', :'bob',  'editor', 'document', :'acme_readme');
select permissions.grant_role('team', :'eng',  'viewer', 'document', :'acme_readme');

-- RLS
select permissions.apply_rls('public.documents', 'select', 'document', 'id', '{"org": "org_id"}');
select permissions.apply_rls('public.documents', 'update', 'document', 'id', '{"org": "org_id"}');
```

- **Can Bob update readme?** `can_for('user', bob, 'update', 'document', readme, '{"org": acme}')` is true. The policy "doc editors edit" matches the `editor` grant of Bob on readme.
- **Which documents can Dave select?** `ids_for('user', dave, 'select', 'document')` = `{readme}` (through `team:eng`), and `ids_for(..., 'org')` = `{}`. Carol gets `{readme}` and `{acme}`. So through RLS she sees every Acme document.
- **Who can view readme?** `who_can('select', 'document', readme)` with no row attributes gives Bob, Carol and Dave from the grants on readme. (The `list_subjects` function of A answers the same question.) With `'{"org": acme}'` it also returns Alice and Carol through "org members view docs".

## v0.0.2 scenarios (section 10 of the plan)

| Goal | How B expresses it | Spec |
| --- | --- | --- |
| G10 parents | Folders are entities in `parents` under their org. The folder of a document is its `folder_id` column. The policies use `via => 'org'` or `via => 'folder'`. RLS is one branch on `folder_id`. To move a document, `update` its column. The write rejects cycles (`23514`). | `b/50_parents` 13/13 |
| G11 public | `permit('announcement is public', '{select}', 'document', resource_id => ...)`: no role is necessary. To revoke it, use `drop_policy`. A null subject matches nothing. | `b/51_public` 7/7 |
| G12 forbid | `forbid('block dave on readme', '{select,update,delete}', 'document', resource_id => readme, principal_id => dave)`. It beats the permits that come from the team and the org. `apply_rls` makes the RLS deny side. Clients get `42501`. A forbid that depends on the row (`via`, resource condition) raises `22023` when the caller leaves its input out of `can()`. It does not fail to match. | `b/52_forbid` 9/9, `b/54_fail_closed` 16/16 |
| G13 conditions | `permit(..., roles => '{member}', via => 'org', condition => resource.status == 'published')` plus an unconditioned editors policy. `apply_rls` compiles the condition into the RLS expression. Expiry is `grant_role(..., expires_at)`. | `b/53_conditions` 6/6 |

B has translations of the zanzibar-level files of A (`b/30`, `b/31`, `b/40`). They keep the assertion count and the words of A. Two assertions must have a different meaning. Both are in `b/31`:

- **Cycles:** A asserts that a check over a cyclic membership graph ends. B never stores a cycle. So the assertion checks that the write rejects the cycle edge with `23514` *and* that checks still give an answer.
- **Undefined userset:** B has no usersets (`team#lead`). The assertion uses the nearest validation instead: the write rejects a policy that needs a role that is not declared on its anchor type.

## Blessed path: the `rbac` preset

The preset API from section 6 of [the plan](../plan.md) maps one to one onto B. Two built-in resource types hold the roles: `app` (one resource, `app:global`) and `tenant` (one for each scope).

| Preset call | Design call |
| --- | --- |
| `create_role('editor', '{documents.edit}', '{viewer}')` | On `app` and `tenant`: `define_role(t, 'editor', '{viewer}')` plus a policy `rbac:<t>:editor` (actions `{documents.edit}`, roles `{editor}`, `managed_by = 'rbac'`) |
| `assign_role('bob', 'editor', 'acme')` | a `role_grants` row on `tenant:acme` |
| `has_permission('documents.edit', 'acme')` | `can_for(current subject, 'documents.edit', 'tenant', 'acme')` |
| `scopes_with_permission('documents.read')` | `ids_for(current subject, 'documents.read', 'tenant')` |
| `users_with_role('admin', 'acme')` | grants on `tenant:acme` joined to `role_closure`, with the group grantees expanded |

The RBAC scenario stores 6 `roles` rows, 4 `role_implies` rows, the `role_closure` rows that match, 6 generated policies, and one `role_grants` row for each assignment. `parents` and `ancestors` stay empty, so no closure triggers run. `drop_policy` refuses the `managed_by` policies (`55000`), so a hand edit cannot break a role.

Graduation (`b/40_graduation`) adds `define_role('document', ...)`, two `permit` calls and a `grant_role`. The select policy gains one branch, `id = any(... permissions.ids('select', 'document') ...)`, and every RBAC answer is unchanged. Graduation is where the second concept of B appears: on the share side, the developer writes policies. RBAC users never had to do this.

## Performance

> The numbers in this section are the baselines of session 2. See [Optimizations (session 3)](#optimizations-session-3) for what changed and for the interleaved before/after measurements.

**Large and medium scale.** The runs were serial, one design at a time. Each workload ran for 10 s with 4 pgbench clients. [COMPARISON.md](../benchmarks/COMPARISON.md) has the full tables, plans and checksums. The checksums of the visible documents for each user match A and C at every scale. The table shows p50 ms (`COMPARISON.md` has p95):

| workload | large (1M docs) | medium (100k docs) |
| --- | --- | --- |
| `rbac_check` | 0.33 | 0.33 |
| `rbac_select_page` | 0.62 | 0.48 |
| `rbac_update_one` | 0.79 | 0.80 |
| `share_select_page` | 1.21 | 0.89 |
| `parents_proj_select_page` (two-arm projection) | 1.44 | 1.05 |
| `parents_select_page` (single branch, per-document parents rows) | 197 | 28.8 |
| `write_nest_team` (4 clients, global lock) | 285 | 220 |
| `nest_check` | 2.60 | 2.36 |

- The RBAC reads and the `share_*` reads are between A and C. At large scale, `share_select_page` of B is 1.21 ms. This is faster than A (2.02 ms) and slower than C (0.95 ms).
- With the two-arm projection (the form that this design recommends), parents cost about the same as the `share_*` workloads. The single-branch form needs a `parents` row and closure rows for each document. It costs 197 ms at large scale (about 140× the projection). The seed for it took 167 s and added about 736 MB (1M `parents` rows plus 2M closure rows).
- When a team of 1,000 members is nested, the design writes closure rows under the global lock. So concurrent nests wait in a queue (285 ms p50 at large scale, 4 clients). A writes one tuple in 0.15 ms.
- `nest_check` is the slowest check of the three designs. It takes 1.2 ms at small scale and 2.4-2.8 ms at medium and large scale. These numbers are after the `_parent_keys` row-estimate fix.
- Deep and wide shapes (medium): `share_select_page` of B is 2.04 ms for deep and 70 ms for wide.

**Small scale, early sanity check (the numbers above replace it).** The data was 10k documents, 1k users, 20 orgs and 50 teams. The command was `./bench/run.sh --impl prototypes/b-policy-first.sql --duration 3`. It used 4 clients on a laptop that other test runs shared. So use these numbers as a sanity check, not as a result. All were within budget:

| workload | p50 ms | p95 ms |
| --- | --- | --- |
| rbac_check | 0.30 | 0.52 |
| rbac_select_page | 0.41 | 0.84 |
| rbac_select_count | 0.34 | 0.62 |
| rbac_update_one | 0.68 | 0.78 |
| write_assign_role | 0.08 | 0.12 |
| share_list_objects | 0.31 | 0.56 |
| share_select_page | 0.73 | 0.89 |
| write_share | 0.08 | 0.14 |

The B share seed (`bench/designs/b/`) produces the same set of visible documents as the seed of A for all 1,000 users. The checksum over the RLS result of every user is identical.

**Why the RBAC of the stand-in was about 3× slower than A** (rbac_update_one p95 3.27 ms against 1.04 ms). The cause was the implementation, not the design:

1. The `can_for` of the stand-in computed the whole `ids_for` set of the caller and then tested membership.
2. `ids_for` matched the principal with `(principal = me) or (principal) in (select ... from ancestors)`. Because of that OR, Postgres did not use the prefix of the `role_grants` primary key. EXPLAIN showed a bitmap scan of every grant of the role in `tenant`, with a filter afterwards. This was about 334 rows for each role at small scale. The cost grew with the total number of users, not with the grants of the caller.

The built evaluator drives every check from `subject (+ its groups) × anchor` into the `role_grants` primary key. Single-client rbac_update_one changed from 2.5 ms (stand-in) to 0.56 ms, and rbac_check from 0.41 ms to 0.20 ms.

**Parents, indicative only.** The same small data had folders added (10 folders for each org, a `via => 'tenant'` policy, single-branch RLS on `folder_id`). Page and count ran at about 0.43 ms with one client. The InitPlan returned 20 folder ids and not 1,000 document ids.

The plan was an index-only scan on `folder_id`. This test was ad hoc. It is not a committed benchmark.

**What is cheap:** The cost of `ids()` and `can()` grows with the grants and the group count of the caller, not with the table size. Access at org level or folder level costs one array element for each folder. Policy edits and role grants need no maintenance writes.

**What needs care:**

- **Number of InitPlans.** The generated expression has one function call for each arm. A table with one parent column and no conditions has 5. With one resource condition, it has 7. Each is a function call (tens of microseconds). The team did not measure this at scale.
- **Large id arrays.** `id = any($1)` is a linear scan of the array for each row that the planner checks. With an index on the column, this works well. The team did not measure a caller with tens of thousands of direct grants. Do not change to the hashed `in (select ...)` form (section 4 of [the plan](../plan.md): 40× slower for counts).
- **Bulk updates** through a hand-written per-row `can()` policy call it once for each row. `apply_rls` uses the InitPlan form instead.
- **`who_can`** fans out through the descendants of groups and checks each candidate again. It is a debug function, not an RLS function.

**Write cost**

| Write | Cost |
| --- | --- |
| `grant_role`, `revoke_role`, `set_attrs`, `permit`, `forbid` | one row; no closure work |
| `define_role` | rebuild `role_closure` for one resource type (tens of rows) |
| `add_parent(c, p)` | `|inner descendants-or-self(c)| × |ancestors-or-self(p)|` closure rows if `c` has children, none for a leaf (plus the rows of `p` itself on its first child). This is after the cycle and depth checks |
| `remove_parent(c, p)` | delete and rebuild the closure for `c` and its inner descendants; nothing for a leaf |

All parent writes wait for one advisory lock. (These numbers are from session 2, before the inner-node closure. The share seed, with 1,047 parent edges and 2,722 closure rows, loaded in about 1 s at small scale.)

## Optimizations (session 3)

Goal: cut the measured weak spots of B without a change to the policy model, the closure-on-write approach or the concurrency rules. The semantics are the same. The suite still passes (18/18 files, 189 assertions after step 7; it was 15/15 files, 172/172 assertions before steps 6 and 7 added specs). The checksums for each user of all four read policies match A and C at small, medium (default, deep, wide) and large scale.

**How the team measured it.** Two other agents ran benchmarks on the same machine. So the absolute numbers are noisy, and **every before/after below is interleaved**. The team kept the original prototype as `bench/results/optb/b-orig.sql` (git-ignored).

It loaded the original and each step into separate databases of one private cluster. The seeds were the same, and the `VACUUM FULL ANALYZE` steps were the same as in `bench/run.sh`. Then pgbench alternated between the databases with the workload files of the bench. Each run took 5-10 s, with at least two rounds.

Values are p50 ms with 1 client, unless marked "4c". The team also checked each step with `EXPLAIN (ANALYZE, BUFFERS)` and with auto_explain on the nested statements of the functions. This was after a warm-up, so the plan cache had chosen its steady-state plan. The seed times and sizes are single runs on a loaded machine. They are not interleaved.

**Correctness checks beyond the suite.** Two differential fuzzers compared the original design with the new design (the scripts are in `bench/results/optb/`):

- *closure*: 168k random operations on graphs of up to 30 nodes with long chains. The operations were `add_parent`, `remove_parent`, `delete_entity` and multi-row inserts into `parents`. They caused 720 depth-cap rejections and 6.6k cycle rejections. After every operation, the fuzzer compares the outcome (`ok`, or SQLSTATE plus message with the reported depth).

  It compares the full closure (every pair with its shortest depth). It also checks that the stored rows are exactly the closure of the inner nodes. 0 differences.
- *reads*: 120 random worlds. The worlds had nested teams, folders in orgs, documents with and without `parents` rows, and expired grants. They had permits and forbids through a folder or an org, `principal_in` and public documents. The fuzzer compares `can_for` with and without the row, `ids_for` (resource ids and every projection), `denied_ids_for`, `allows_all_for`, `denies_all_for`, `explain` (with multiplicity), `who_can`, `is_in` and `users_with_role`. The fuzzer compared 119k results. 0 differences.

### What changed, step by step

**1. `collate "C"` on every id, type and role column** (`entities`, `parents`, `ancestors`, `roles`, `role_implies`, `role_closure`, `role_grants`). The default collation of the cluster is `en_SG.UTF-8`. So every B-tree comparison, join and sort on a uuid-as-text went through `strcoll`.

In wide `ids()`, the `distinct` sort of 6.7k ids took 19 of 29 ms. Equality does not change under a deterministic collation. Only the order of the `ids()` arrays changes (the specs compare sets). The `strcoll` of glibc is slower than the `strcoll` of macOS, so Docker or Linux can gain more.

| workload | before | after |
| --- | --- | --- |
| `share_list_objects` medium wide | 24.5-25.3 | 6.8 |
| `share_select_page` medium wide | 66-69 | 30.6 |
| `write_nest_team` medium | 55 | 18 |
| `parents_select_page` medium | 28-30 | 7.8 |
| `nest_check` medium | 2.2 | 0.79 |

**2. Read the right grants, once, by primary key.**

- `_ids`: a policy-role list (`pr`) drives `held`. `pr` has each role policy, its anchor type and every role that satisfies it, from `role_closure`. `held` probes the `role_grants` primary key with `resource_type = any(anchor types)` and `role = any(roles that satisfy)`. Before, `held` read every grant of the subject and its groups.

  This was 6.7k document grants for each user in the wide shape, even for the `scopes_with_permission` arm that uses only tenants. It joined them to `role_closure` with a nested loop of 100k comparisons. `distinct` now runs as its own step, so it can hash.
- `_matches`: the function computes the groups of the subject, the anchors of the resource and `_parent_keys` (before: called twice) once into arrays. It probes the grants with one `lateral (... offset 0)` primary-key lookup for each (subject or group, anchor), with the `role_closure` check inside it.
- `role_grants (resource_type, resource_id)` became `(resource_type, resource_id, principal_type, principal_id)`. The generic plan always chose the resource index. That index reads every grant on a tenant (one for each member, about 80-200) and filters by subject. With the principal columns, either index is an exact probe. +2.1 MB at large scale.

| workload | before | after |
| --- | --- | --- |
| `share_list_objects` medium wide | 6.9 | 3.7 |
| `share_select_page` medium wide | 31.8 | 16.8 |
| `nest_check` medium | 0.80 | 0.40 |
| `rbac_check` medium | 0.50 | 0.40 |

**3. PL/pgSQL instead of SQL for the hot wrappers** (`can`, `can_for`, `ids`, `denied_ids`, `allows_all(_for)`, `denies_all(_for)`, `denied_ids_for`, `_all`, `_parent_keys`, `has_permission`, `has_role`, `scopes_with_permission`, `current_subject_id/type`). Postgres never inlines a SQL function with a `SET` clause or `security definer`. In Postgres 16, it parses and plans the body again for every outer query.

`_parent_keys` alone cost 0.08-0.2 ms for each call. PL/pgSQL caches the plans for each session. `nest_check` 0.39 → 0.33, `rbac_check` 0.39 → 0.29, wide `share_list_objects` 3.9 → 3.7.

**4. Closure rows for inner nodes only** (the change behind `write_nest_team` and the parents storage). `ancestors` keeps rows only for entities that have children. The ancestors of a leaf are its `parents` rows plus their stored rows (the `closure` view, one join, no recursion).

When the 1,000-member team is nested, the design writes 1 × (1 + ancestors) rows for the team, and not 1,001 × (1 + ancestors). To file a document in a folder, the design writes only its `parents` row. To remove a member, the design rebuilds nothing.

C already stores "containers only". This is what the change needed:

- The cycle and depth checks have the same meaning. The deepest descendant is the deepest stored inner descendant plus one level of children, computed exactly.
- The insert trigger runs `before insert`, so multi-row inserts stay edge by edge. An `after` trigger would see the rows of the whole statement while the closure is half updated. The fuzzer found this, with duplicate-upsert `21000` errors and missing rows.
- The `closure` view leaves out the pairs that are more than 10 apart, which matches the original. See the latent bug under hard limits that remain.
- Every read that joins the view uses `cross join lateral (... offset 0)` (see the planner trap in Weaknesses). Before this fix, `nest_check` was 22 ms and `parents_select_page` 100 ms.
- `_matches` and `_ids` pin `plan_cache_mode = force_generic_plan`. The plan cache kept planning them again with custom plans: 0.66 → 0.11 ms for each `can()`.
- `parents (parent_type, parent_id)` became `(parent_type, parent_id, child_type, child_id)` for index-only reads of descendants. The old index was 7 MB at large scale because of B-tree deduplication. The new index is 120 MB. But the new index makes the single-branch reads faster at large scale (interleaved). `parents_select_page` is 18.7 against 26.7 ms, and `parents_select_count` is 29.5 against 55 ms. So the new index stays.

| workload | before (step 3) | after |
| --- | --- | --- |
| `write_nest_team` medium | 19.7 | 0.17-0.21 |
| `write_nest_team` medium, 4c | 75-84 | 0.65-0.70 |
| `nest_check` medium | 0.33 | 0.23 |
| `parents_select_page` medium | 8.5 | 6.4 |
| `share_list_objects` / `share_select_page` medium wide | 3.9 / 16.6 | 4.05 / 18.0 (worse, see below) |

Storage and seed time (not interleaved): medium parents phase 86.3 → 46.4 MB, seed 15.5 → 4.2 s. Medium wide after the share seed 225.9 → 105.3 MB, seed 37 → 13 s. Large after the single-branch parents seed 762.8 → 377.9 MB, seed 252 → 51 s on the loaded machine. (The baseline of session 2 measured 167 s.)

A document with a parent link now costs one `parents` row plus its two index entries, and not 3 rows. The cost: the groups of a user are one hop further away. So wide reads (50 direct teams for each user) are about 5-8% slower than after step 3.

**5. `_all()` skips `_candidate_policies` when no allow-all or deny-all policy exists.** `ids_for` asks `_all()` about forbids on every call. `scopes_with_permission` 87 → 78 µs for each call.

**6. `ids()` and `denied_ids()` no longer run at plan time.** RLS uses `= any (array(select unnest(permissions.ids(...))::uuid))`. To estimate the rows of `unnest()`, the planner evaluates its argument when it can (`estimate_expression_value` in `array_unnest_support`). A STABLE function with constant arguments qualifies. So every RLS query ran `ids()` twice: on the original wide share page, planning took 30 of 68 ms.

(The agent that worked on A found the same problem independently.) The fix: the default of the last argument, `p_resource_condition`, is now `permissions._unfolded_null()`. This is a trivial VOLATILE function that returns null. The planner does not fold a call with a non-constant argument. `ids()` stays STABLE and reads the snapshot of the query that calls it, and the signature is the same.

The team did not mark `ids()` VOLATILE (the fix of A). Under read committed, a volatile function takes a new snapshot for each query that it runs. Then the grants would be read at a later instant than the rows that they filter. This weakens the single-snapshot guarantee in a statement.

Policies get the default when you create them. So this applies to policies that you create after you install this version. Wide page planning time 4.7 → 1.35 ms.

| workload | before (step 5) | after |
| --- | --- | --- |
| `share_select_page` medium wide | 18.8 | 14.4 |
| `parents_select_page` medium | 6.1 | 5.1 |
| `parents_select_count` medium | 5.6 | 4.1 |
| `parents_proj_select_page` medium | 0.80 | 0.60 |

**7. `scopes_with_permission` and the conditioned RLS groups no longer run at plan time.** Step 6 had two gaps. The team found them with an EXPLAIN of the share policy and with a call-count probe (`test/spec/b/56_no_plan_time_eval.sql`).

- `scopes_with_permission(p_permission text, p_unfold jsonb default permissions._unfolded_null())` has the same ignored last argument as `ids()`. So the one-argument form that section 6 of [the plan](../plan.md) and the policies use still works, and the function stays STABLE. The grant is now `scopes_with_permission(text, jsonb)`. Evidence: `EXPLAIN (ANALYZE, BUFFERS)` as user 1, medium default, with the bench share policy (`org_id = any (array(select unnest(scopes_with_permission('documents.read'))::uuid)) or id = any (array(select unnest(ids('select', 'document'))::uuid))`).

  Before: `Planning: Buffers: shared hit=1000`, Planning Time 3.9 ms. After: `Planning: Buffers: shared hit=112` (catalog lookups only), Planning Time 0.24 ms. The total of buffers for planning plus execution is about the same (2,530 before, 2,500 after). The work that ran twice now runs once.
- `rls_expression` wrote a resource condition into the policy as a constant (`ids('select', 'document', null, '{...}'::jsonb)`). So every argument was constant, and `ids()` and `denied_ids()` ran at plan time for each conditioned group. The planner made 2 `ids` calls and 2 `denied_ids` calls when it planned a table with one conditioned permit and one conditioned forbid, with `via`. Now it emits `coalesce(permissions._unfolded_null(), '{...}'::jsonb)` for that argument.

  This is not constant and costs nothing. `allows_all` and `denies_all` do not need it. They are boolean `(select ...)` InitPlans, which the planner does not evaluate in advance. The policies that `apply_rls` created before this version need regeneration.
- The team checked these and found them correct without a change: `has_permission`, `has_role`, `can` (boolean quals, even with all-constant arguments) and `allows_all`/`denies_all`. With `track_functions = 'all'`, `EXPLAIN` of a policy that uses each of them left their call counts at 0, and a run of the query counted 1.
- Test: set `track_functions = 'all'`. Then, in one transaction, run `EXPLAIN (costs off)` (nothing executes) and read `pg_stat_get_xact_function_calls` before and after it. The count must not change, and a run of the query must raise it. The test detects the calls that the planner makes (the version before the fix fails it, with the exact numbers). The test reads the counter as a difference, because the counter also includes the earlier unflushed transactions of the session. If you remove the default from `ids`, `denied_ids` or `scopes_with_permission`, or the `coalesce` in `rls_expression`, a named assertion turns red each time.

### Original and final (interleaved)

| workload | original | final | C (session-2 baseline, 4c) |
| --- | --- | --- | --- |
| `write_nest_team` large, 4c | 307 | 0.57-0.65 | 333 |
| `write_nest_team` large, 1c | 71-80 | 0.17 | |
| `write_nest_team` medium wide / deep, 4c | 338 / 330-386 | 1.5-2.5 / 0.6 | 145 / 354 |
| `nest_check` large, 4c | 3.3-3.9 | 0.37 (0.81 in a noisy rerun) | 0.26 |
| `nest_check` large, 1c | 2.5 | 0.22 | |
| `nest_check` medium wide / deep, 4c | 3.4 / 3.2-3.7 | 0.34 / 0.35 | 0.28 / 0.27 |
| `share_list_objects` medium wide | 25 | 3.9 | 3.76 |
| `share_select_page` medium wide | 70.5 (4c 73.7) | 15.1 (4c 15.7) | 10.72 |
| `parents_select_page` large | 183-198 | 12-14 | 9.57 |
| `parents_select_count` large | 206-220 | 24-25 | 22.08 |
| `rbac_check` / `rbac_update_one` medium | 0.26 / 0.76 | 0.17 / 0.51 | |
| `share_select_page` / `share_list_objects` medium | 0.82 / 0.25 | 0.66 / 0.20 | |
| `parents_proj_select_page` medium | 0.98 | 0.60 | |

`rbac_select_page`, `rbac_select_count`, `write_assign_role` and `write_share` did not change beyond noise. The medium-default rows, except `parents_proj_select_page`, compare the original with step 5. Step 6 affects only the queries whose RLS calls `ids()` with default arguments.

### Tried and dropped

- **A forced primary-key probe in `_matches` with only `lateral ... offset 0`.** The generic plan still used the `(resource_type, resource_id)` index inside the lateral, and the probe ran 270 times: `nest_check` 0.80 → 2.7 ms, `rbac_check` 0.50 → 0.91. The wider index fixed this (step 2).
- **A direct join of the `closure` view.** `nest_check` was 22 ms and `parents_select_page` 100 ms (the view-join planner trap). Lateral joins fixed this (step 4).
- **The narrow `parents (parent_type, parent_id)` index with the inner-node closure.** It saves 113 MB at large scale but makes single-branch reads 40-90% slower (step 4).
- **`enable_hashjoin = off` for the group expansion of the subject in wide** (a hash join over the small inner-node `ancestors` against 50 primary-key probes): no difference.
- **`ids()` marked VOLATILE**: rejected without a measurement, for the snapshot reason in step 6.
- **A cache of `ids()` between plan time and execution** (in a setting with the statement as key): rejected. Planning and execution can use different snapshots under read committed, and keys can collide.
- **Statement-level triggers with transition tables**: not useful here. `add_parent` inserts one row for each statement, so a seed of 1M calls fires 1M statement triggers anyway. The inner-node closure removed the per-row closure work instead.

### Hard limits that remain

- **The RLS form costs what the array costs.** With 6.7k-20k ids, `unnest` plus `::uuid` takes 1.5-4.5 ms. `id = any($1)` is a linear scan of the array for every row that a filter checks. This is 8 ms of the 15 ms of the wide page. The policy of C casts the whole array (`(select f())::uuid[]`). B cannot change the policy text of the seeds.
- **Explicitly passed constant arguments still fold.** If you call `ids('select', 'document', null, '{}'::jsonb)` by hand, with every argument constant, the planner evaluates it at plan time again. `rls_expression` no longer does this (step 7).
- **One global closure lock.** A nest now takes about 0.2 ms when the members of the nested group are leaves. So the design holds the lock for a short time. When a sub-tree with many inner nodes is nested, the design still writes `inner descendants × ancestors` rows under the lock.
- **Wide memberships cost a hop.** The groups of a user are `parents` rows plus their stored rows. With 50 teams for each user, this is about 0.3 ms more for each `ids()` call than a fully stored closure.
- **Latent bug kept for compatibility (it exists in the original):** A delete can remove a shortcut edge. Then the shortest path that is left between two entities can become longer than 10. The delete rebuild of the original stops at depth 10 and silently drops that pair. This is a partial answer, against "the depth cap is enforced on write".

  The new design reproduces this exactly, through the `depth < 10` filter of the view and the capped depth computation, because the fuzzer compares against the original. The right fix is to reject such a delete with `23514` (or to accept any depth). That is a semantic change. The team left it as a decision.

## Weaknesses and risks

- **Two concepts to learn.** A developer writes policies and facts. The reference scenario needs 5 role definitions and 4 policies on top of the grants.
- **RLS must mirror the policies.** `apply_rls` fixes the generated expression when it runs:
  - You name the `via` columns in the call.
  - `apply_rls` includes the resource-conditioned groups and the `allows_all` arm only if such policies exist at that moment.

  If you later add a policy `via => 'project'`, a new resource condition or an allow-all permit, you must regenerate the RLS of the table. If you do not, the policy silently grants nothing on select. This fails closed for permits. `lint()` flags these cases, but it checks the text of `pg_policy`, which is brittle. Forbids that you add later need no regeneration for unconditioned shapes.
- **`can()` needs the row.** Outside RLS, the caller must pass the parent columns and the attributes of the row in `resource`. If the caller passes too little, permits fail closed. For forbids, this used to **fail open**.

  A forbid `via => 'folder'`, or with a resource condition, did not match if the caller left out the folder or the attribute. Now it raises `22023` (see [Decision](#decision)). The cost: you can add a forbid that depends on the row. Then existing `can()` calls that pass too little can start to raise an error for the subjects that the forbid can apply to. This is the intended failure, but it is a runtime failure, not a lint warning.
- **`can()` trusts its `resource` argument.** It is an oracle over the facts that the caller supplies. A client that calls `can()` with a made-up folder fools only itself (RLS reads the real columns). But server code must not give client-supplied row data to `can()` and use the answer as a gate.
- **Which jsonb keys are parents is implicit.** Every key that names a type is a candidate parent, except principal types (above). A key that collides with a non-principal entity type is still read as a parent. An example is `{"status": "draft"}`, when an app also uses `status` as an entity type with parents.

  This matters only if that entity has ancestors of a type that some policy anchors on. That is, the app declared "draft is in org acme". The principal-type rule closes the realistic case. An author column with the name `user` pulled in the org of the author, and `can()` said yes where RLS said no. But the design derives the rule from policies and grants.

  So if you grant a role *to* a folder, `folder` becomes a principal type. Then `{"folder": ...}` is no longer a parent, unless a policy anchors `via => 'folder'` (this fails closed). The explicit fix is open question 4: declared parent types for each resource type, as Cedar does with `memberOfTypes`. That changes how every B spec calls `can()`, so the team did not do it here.
- **`ids_for` as a list is not fail-closed for forbids that depend on the row.** `ids()` is a projection that RLS uses as one arm. It is net only of the forbids that it can evaluate in that projection. `ids_for(subject, 'select', 'document')` (resource ids) still lists a document with a direct grant when a forbid would block it through its folder column or a resource condition.

  Neither is known without the row. RLS is exact: its deny side checks `denied_ids` for each parent column and compiles the resource conditions. To make the list exact, the design must split the RLS permit arm (which must not subtract conditioned forbids) from a separate list function. Use RLS, or `can()` with the row, for decisions.
- **The `('*', '*')` row of `who_can` is not net of forbids.** A no-role permit with no principal restriction (public access) returns one wildcard row. A forbid on one user cannot be an exception to it. The `list_subjects` row for `user:*` of A and the null row of C behave in the same way. Unlike A, B labels the row `('*', '*')` even when the `principal_type` of the policy is `user`.
- **A document without a value in the RLS parent column** (for example `folder_id is null`) is reachable only through its own grants. The policy can also have an `org_id` branch to reach it.
- **`ids()` is exact only for unconditioned policies.** With resource-conditioned permits or forbids, `ids_for` used as a "list" is an approximation. RLS is exact because it compiles the conditions.
- **Pinned plans.** `_matches` and `_ids` set `plan_cache_mode = force_generic_plan`. Otherwise the plan cache kept the custom plans. It planned the lateral and view queries again on every call (0.66 ms against 0.11 ms for each `can()`).
- **Planner trap in `_matches`: set-returning helpers need a `rows` estimate.** The planner estimates a function scan at 1000 rows by default. `_parent_keys()` returns about one row. But after `ANALYZE` ran on `ancestors` with real data (92k rows), the planner hash-joined a full seq scan of `ancestors` against it.

  Then `can()` changed from about 1.3 ms to 17-22 ms (wide shape, `nest_check`). `_parent_keys` is now declared `rows 1`, the plan probes the `ancestors` primary key again, and the `nest_check` p50 is 0.79 ms. Any new set-returning helper that joins to `ancestors` or `role_grants` needs the same.
- **Closure write amplification and one global lock.** When a group is nested, the design writes `inner descendants × ancestors` rows. Nesting a team of 1,000 users writes about 5 rows (0.2 ms). But nesting a team that contains hundreds of sub-teams still writes the product.

  To remove members (leaves) rebuilds nothing. All closure writers still wait for one lock. So a slow nest of a deep sub-tree blocks every other membership write. The design refuses repeatable read for these writes.
- **Planner trap in the `closure` view.** Its second branch is a join. So Postgres cannot flatten it into an append, and it cannot push a join condition from an outer relation into it. It computes the descendants of every inner node and filters (`nest_check` changed from 0.3 to 22 ms when it was first joined). Every read joins it as `cross join lateral (... offset 0)` or with parameters only. New read paths must do the same.
- **Text ids and casts.** `::uuid` in RLS fails the whole query if any stored id for that type is not a uuid. An id type for each resource type, validated in `grant_role`, would fix this.
- **Security definer everywhere.** A bug in the read functions is a privilege bug. `search_path = ''` and no dynamic SQL in the read path limit the damage. The functions are not `leakproof` (this needs a superuser).
- **Context from settings.** Any session on plain Postgres can set `permissions.context` and `permissions.subject_id`. On Supabase the JWT wins. But conditions on `context.*` must use only JWT claims or values that the server sets.
- **Condition semantics are jsonb semantics.** `now` and timestamps compare as ISO strings. This works for values with the same offset only.
- **The policy language is restricted.** A policy has a principal scope, a role on the resource or on a parent of one named type, and a condition. "The author of the document" (an `owner_id` column) needs either a role grant for each row or a condition that compares `resource.owner_id` with `principal.id`. That comparison mixes resource and principal variables, which the splitter rejects now (open question 7). A generic Cedar engine would accept such policies and be slow. B refuses them.

## Deviations from the original design

1. **Identity names** follow the shared contract: `current_subject_id()` and the `permissions.subject_id` setting. The original doc said `current_subject()` and `permissions.subject`, and it read the old `request.jwt.claim.sub`.
2. **`via` resolution** (original open question 2): both the `resource` jsonb (columns) and `parents` rows count as parents, and anchors are transitive through `ancestors`. Anchors for `via` are strictly above the resource.
3. **`ids(..., via)` is a projection onto the parent column.** It is not "the anchor ids where I hold the role". The original version could not give G10 a single RLS branch, because org-level grants needed a separate `org_id` arm.
4. **The design implements forbid** (the check constraint is gone). The design added `principal_id`, so a forbid (or permit) can name one principal, as `principal == User::"dave"` does in Cedar. `ids_for` is net of forbids. `denied_ids`, `denies_all` and their `_for` variants are new, for the RLS deny side.
5. **Public access** is a no-role policy with `resource_id`. It is not a wildcard grant. No new mechanism was necessary.
6. **Resource conditions run on the RLS fast path now.** They did not wait for "v0.0.3". The write splits conditions into principal and resource halves, and rejects mixed terms. `rls_expression` compiles the resource halves to SQL, each with its own `ids(..., resource_condition)` group.
7. **The design removes the advice for the hashed subquery.** The fast path is `= any (array(select unnest(...)::uuid))` (section 4 of [the plan](../plan.md)).
8. **`allows_all` is not always emitted** (see the BitmapOr result above).
9. **`apply_rls` uses the InitPlan expression for update, delete and insert,** and not a per-row `can()`. It runs as security invoker, so only the table owner can use it. It returns the policy name `permissions_<command>`.
10. **Closure details:** `depth` is the shortest path. The design refuses repeatable read and accepts serializable. `parents` rows are immutable.
11. **Additions:** `is_in` (Cedar `in`). `explain` also returns the effect. `who_can` filters candidates through the same matcher as `can`, so the two agree by construction. `delete_entity` returns a row count. `managed_by` exists, and `drop_policy` enforces it. `lint()` checks undeclared roles, forbids that RLS does not enforce, missing allow-all arms, and resource conditions that are missing from RLS.
12. **Parameter names:** `permit` and `forbid` take named arguments without a prefix (`roles =>`, `via =>`, `resource_id =>`, `condition =>`, `principal_id =>`). This matches the examples in the original doc.
13. **`can()` fails closed on missing forbid inputs** (added after a review, 2026-10-28). A forbid that can apply can need a parent or an attribute that is not in `resource`. Then `can()` raises `22023`. It does not fail to match. `who_can` and `explain` inherit this.
14. **Keys with a principal type are not parents** (same review). `{"user": ...}` or `{"team": ...}` is an attribute, unless a policy on the resource type anchors `via` that type. Before, every key was a parent, and an author column with the name `user` made the orgs of the author anchors of the row.
15. **Closure rows for inner nodes only** (session 3). `ancestors` stores rows only for entities with children. The `closure` view adds the leaves, and the insert trigger is `before insert`. The answers and the cycle and depth checks are the same. See [Optimizations (session 3)](#optimizations-session-3).

## Open questions

These questions are from the build. B is history, so they stay open.

1. Must role implication stay a table, or must it be only policies (`roles => '{viewer,editor}'`)? The table is shorter for apps, but it is a second place where meaning lives.
2. Can `rls_expression` be regenerated automatically (an event trigger or a policy-table trigger that runs `apply_rls` again), so that `lint()` does not have to report drift? This needs DDL from a trigger, which TLE can refuse.
3. Explicit subject: is `revoke` on the `*_for` functions enough, or must they check membership of a dedicated `permissions_admin` role?
4. Must the parent keys in the `resource` jsonb be explicit? This means declared parent types for each resource type (`memberOfTypes` in Cedar), and not "every key except principal types". The recommendation is to make them explicit. This would replace the derived principal-type rule, and `can()` would name exactly which keys a call must pass.
5. Must `apply_rls` exist at all (it is the only `execute` in the extension), or must the extension ship only `rls_expression`?
6. Is one global advisory lock acceptable for closure maintenance, or do we need locks for each component? After session 3, the design holds the lock for about 0.2 ms when a group of users is nested (inner-node closure). So this matters mainly when a large sub-tree is nested.
7. Principal-to-resource conditions (`resource.owner_id == principal.id`): can the design accept them as a compiled SQL predicate that compares a column with `current_subject_id()`? Postgres can partially evaluate this, but the splitter rejects it now.
