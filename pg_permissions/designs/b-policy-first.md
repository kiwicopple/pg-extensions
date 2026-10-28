# Design B: Policy-first

> One of three candidate designs. See [../PLAN.md](../PLAN.md) for the shared goals, requirements and evaluation criteria.
>
> Status: **built** as [`prototypes/b-policy-first.sql`](../prototypes/b-policy-first.sql). This document describes what the prototype does. Where the build changed the original design, the change and the reason are listed in [Deviations from the original design](#deviations-from-the-original-design).

## Summary

Every decision comes from one small policy table. A policy is Cedar-shaped: a principal scope, actions, a resource type, an optional "role on anchor" requirement, an optional condition, and an effect (`permit` or `forbid`). Roles, group memberships and parent links are facts that policies read. Group and parent membership is kept as a precomputed closure on write, so a decision is a handful of flat joins with no recursion. The RLS fast path is a partial evaluation: "which resource ids, or which parent ids (a folder, an org), would this policy set let me reach?", computed once per query.

## Core idea

A tuple store with a read-time graph walk puts the authorization logic inside the graph: `editor` implies `viewer` is a rewrite rule, "org admins can edit org documents" is a tupleset rewrite, and the answer to "can X do Y" comes out of a recursive CTE. This design moves that logic into explicit policies and keeps the data simple:

- **Facts** say who is in what and who holds which role on what: `parents` (Carol is in team `eng`, folder `specs` is in org `acme`), `role_grants` (Alice holds `admin` on org `acme`), `role_implies` (`editor` implies `viewer` on documents).
- **Policies** say what those facts allow: "anyone holding `member` on a document's org may `select` the document", "Dave may not `select` readme".
- **One evaluator** answers every question by matching policies against the facts. RBAC, ReBAC, public access, forbid and attribute rules are different policy shapes, not different engines.

Why this might beat a tuple store with a read-time walk:

1. **Documents never enter the permission store.** A document's org or folder is its own column. A policy with `via => 'folder'` grants access through that column, and RLS matches `folder_id` against the folder ids the caller can reach. In the tests and benchmarks no document row exists in any permissions table unless the document has its own grant.
2. **No recursion at read time.** Group and folder nesting is precomputed into `ancestors` (depth at most 10, cycles rejected on write). Role implication is precomputed into `role_closure`.
3. **Policy changes are cheap and auditable.** Adding "members can view" is one row and needs no backfill. `explain()` answers "why can Dave see this?" with a policy name and the grant that matched.
4. **Forbid and conditions have an obvious home:** the `effect` and `condition` columns of a policy, rather than a new tuple semantic.

The trade-off is that policies are limited to shapes that can be partially evaluated into SQL filters. That limit is deliberate: the policy language is shaped by what we can index.

## Schema (as built)

All objects live in a fixed schema `permissions`. Entity ids are `text`, so uuid, bigint and slug keys all fit.

| Table | Holds | Written by |
| --- | --- | --- |
| `entities(type, id, attrs jsonb)` | Attributes for principals, read by conditions (`principal.attrs.*`) | `set_attrs` |
| `parents(child_type, child_id, parent_type, parent_id)` | User in team, team in team, folder in org, folder in folder | `add_parent`, `remove_parent` |
| `ancestors(child, ancestor, depth)` | Transitive closure of `parents`; `depth` is the shortest path, 1–10 | triggers on `parents` only |
| `roles(resource_type, role)` | Roles declared per resource type, so typos fail at grant time | `define_role` |
| `role_implies(resource_type, role, implies)` | `editor` implies `viewer` | `define_role` |
| `role_closure(resource_type, role, implied)` | Reflexive transitive closure of `role_implies` | rebuilt per type by `define_role` |
| `role_grants(principal, role, resource, expires_at)` | Principal (user or group) holds role on resource, optionally until a time | `grant_role`, `revoke_role` |
| `policies` | Permit and forbid rules (below) | `permit`, `forbid`, `drop_policy` |

A policy row has `effect` (`permit` / `forbid`), a principal scope (`principal_type`, default `'user'`, null = any; optional `principal_id` for one principal; optional `principal_in_type/id` for "member of this group"), `actions text[]`, `resource_type`, optional `resource_id`, optional `roles` plus `via` (the anchor), the `condition` as written plus its two halves `principal_condition` and `resource_condition` (split on write), `managed_by` (`'rbac'` for preset-generated policies) and `enabled`.

Indexes that matter: `role_grants` primary key `(principal_type, principal_id, resource_type, resource_id, role)`, which every check probes by subject and anchor; `role_grants (resource_type, resource_id)` for `who_can`; `ancestors` primary key `(child_type, child_id, ...)` for "my groups" and "this folder's ancestors"; `ancestors (ancestor_type, ancestor_id, child_type)` for "folders under this org".

### Closure maintenance and concurrency

`ancestors` is maintained by row-level `after insert` / `after delete` triggers on `parents` (updates are rejected; remove and add instead). Every trigger first takes one transaction-scoped advisory lock, `pg_advisory_xact_lock(hashtext('permissions.closure'))`, so closure writers are serialized.

- **Insert `c -> p`:** reject if `p` is already below `c` (cycle, SQLSTATE `23514`), reject if any new path would be deeper than 10 (`23514`), then insert `descendants-or-self(c) x ancestors-or-self(p)` with `on conflict ... depth = least(...)`.
- **Delete `c -> p`:** only `c` and its descendants can change. Their closure rows are deleted and rebuilt from `parents` with a depth-bounded recursive walk.
- **Isolation:** the closure is computed from what the transaction sees *after* it gets the lock. Under read committed each statement takes a fresh snapshot, so it sees the previous writer's committed rows. Under serializable, a stale read is a serialization failure, which aborts. Under **repeatable read** the snapshot predates the lock and the closure would silently miss a concurrent writer's edge, so parent and role-definition writes raise `0A000` there. (Design C makes the same call.)
- `role_closure` is rebuilt for one resource type under a second advisory lock (`permissions.roles`), with the same isolation guard.

The depth cap is enforced on write, not by truncating at read time, so a check never silently gives a partial answer.

## Linking to identity

The extension stores no users. A subject is a `(type, id)` pair. The contract is fixed by `test/spec/01_identity.sql`: `permissions.current_subject_id()` returns the JWT `sub` (`request.jwt.claims`), otherwise the `permissions.subject_id` setting, otherwise null. `current_subject_type()` defaults to `'user'`.

- **No subject**: every check returns false, every `ids` call returns `'{}'`. Default deny (asserted in `b/51_public`).
- **Explicit subject**: every client function has a `*_for` variant taking `subject_type, subject_id`. They are revoked from `public`, because otherwise any client could ask "what can Alice see?".
- **User deletion**: `permissions.delete_entity(type, id)` removes the entity's attributes, the grants it holds and grants on it, its `parents` edges (closures follow through the triggers) and unmanaged policies that name it. For automatic cleanup, attach `permissions.on_entity_deleted('user', 'id')` as an `after delete` trigger on the app's identity table. It reads `to_jsonb(old) ->> tg_argv[1]`, so there's no dynamic SQL. Execute is revoked from `public`.

## Public API (as built)

Read functions are `stable security definer set search_path = ''`. They have to be `security definer` because callers have no `select` on the tables.

```sql
-- current subject: granted to public, safe in RLS
permissions.can(action, resource_type, resource_id, resource jsonb default '{}') returns boolean
permissions.ids(action, resource_type, via default null, resource_condition jsonb default null) returns text[]
permissions.denied_ids(action, resource_type, via default null, resource_condition jsonb default null) returns text[]
permissions.allows_all(action, resource_type, resource_condition jsonb default null) returns boolean
permissions.denies_all(action, resource_type, resource_condition jsonb default null) returns boolean

-- explicit subject and debugging: admin only
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

A policy with `roles` requires the principal (or any group it is in, via `ancestors`) to hold one of those roles, directly or through `role_closure`, on an **anchor**, with an unexpired grant:

- `via => null`: the anchor is the resource itself.
- `via => 'folder'`: the anchor is any `folder` among the resource's parents, strictly above the resource. A resource's parents are:
  1. the values in the `resource` jsonb argument (the row's columns). Every key is an attribute, and a key that names a type is also read as a parent of that type: `{"folder": "<id>"}` says the document's folder is `<id>`. The exception is a key naming a **principal type** (a type a policy scopes principals by, `principal_type` or `principal_in_type`, or that holds a grant): it is only an attribute, unless some policy on the resource type anchors `via` that type. Principals are in `parents` as group members (user in team in org), so reading `{"user": "<author>"}` as a parent would make the author's teams and orgs the row's anchors (`b/54_fail_closed`). A null value names no parent;
  2. its rows in `parents`, for resources that are themselves entities (a folder's org);
  3. transitively, every ancestor of either, from `ancestors`.

So with folder `specs` in org `acme` and readme's `folder_id = specs`, a policy `via => 'org'` reaches readme through `acme`, with nothing stored about readme itself (`b/50_parents`).

A policy with no `roles` needs no grant: it matches every principal in its scope, either for one resource (`resource_id`, which is how public access works) or for every resource of the type (allow-all).

### Decision

`can()` evaluates `_matches()`, the single place that matches policies against one concrete resource, and returns **true if any permit matches and no forbid matches**. Forbid always wins and there are no priorities, as in Cedar (`b/52_forbid`). Conditions are evaluated with the row's attributes, and principal scope and the row-independent condition come from `_candidate_policies()`, which `ids()` and `who_can()` share.

**Missing inputs fail closed.** `can()` only knows the row through its `resource` argument, so a forbid that reads a parent or an attribute the caller left out would silently not match, and the answer would be "allowed". Instead, `_matches()` raises `22023` naming the forbid and the missing input when a forbid that could apply to the subject needs an input that isn't there:

- it could apply: its principal scope and principal condition match, it names this resource or none, and it needs no role or the subject (or a group it is in) holds one of its roles on some resource of its anchor type;
- a resource condition needs every `resource.<attr>` it reads to be a key of `resource`;
- `via => T` needs a `T` key in `resource`, or a `T` ancestor known from the facts: the resource's own `parents` rows, or the ancestors of a parent key (a folder's stored org counts, so `{"folder": specs}` covers a `via => 'org'` forbid).

A key with a null value counts as given: `{"folder": null}` says the row has no folder. A null folder doesn't vouch for the org, so a `via => 'org'` forbid then needs `"org"` too. Forbids that can't apply cost nothing: a user who holds no `blocked` role anywhere can call `can()` without the folder even when a `blocked`-via-folder forbid exists. `who_can` and `explain` go through `_matches()`, so they raise the same way (`b/54_fail_closed`).

Raising was chosen over the two alternatives. Resolving missing inputs from the facts already happens where it can (stored parents and ancestors), but a document's folder column and its attributes aren't facts in B, so there is nothing to resolve them from; reading `entities.attrs` for the resource would let `can()` and RLS (which reads the columns) disagree. Treating the forbid as matching also fails closed, but it turns a caller bug into a silent "denied" that looks like a policy decision and makes `who_can` quietly return nobody. The error names the policy and the key to pass. It's the same stance as Cedar's schema validation, where a request missing a required attribute is an error; Cedar's runtime alternative, skipping a policy that errors, is exactly the fail-open behaviour for forbids this avoids. RLS is unaffected: `apply_rls` never calls `can()`, and a hand-written per-row `can()` policy passes the real columns, null or not.

### Partial evaluation for RLS: `ids()`

`ids(action, type)` returns the ids of resources matched through their own grants, through parents-table ancestors, or by a `resource_id` policy. `ids(action, type, 'folder')` is a **projection onto the parent column**: the folder ids `F` such that a resource whose direct parent is `F` would be matched. That is the folders where the caller holds a matching role (`via => 'folder'`) plus every folder below an anchor the caller holds (`via => 'folder'` on a parent folder, `via => 'org'` on the org). This is what lets one RLS branch, `folder_id = any(...)`, cover org-level and folder-level access together (G10).

`ids_for` is net of unconditioned forbids in the same projection (a forbid on readme removes readme from the id list; a forbid on a folder removes the folder), so it doubles as "list what I can see" (`b/52_forbid` assertion 3), for forbids it can evaluate without the row (see [Weaknesses](#weaknesses-and-risks)). `denied_ids` / `denies_all` give the forbid side separately, for RLS.

`can()` and `ids()` are two implementations of one semantics, the risk the original doc warned about. During the build they were checked against each other on random data: 20 users, 60 documents in 12 nested folders under 3 orgs, groups, two forbids, every user × document × action (2,400 cases). There were **0 disagreements** between `can_for(...)` and `(id ∈ ids ∨ folder ∈ ids(folder)) ∧ ¬(id ∈ denied_ids ∨ folder ∈ denied_ids(folder))`, and 0 between `who_can` and `can_for`. This was an ad-hoc check, not a committed spec file.

### Conditions

A condition is a jsonb AST interpreted in PL/pgSQL with no `execute`:

```json
{"op": "==", "left": {"var": "resource.status"}, "right": "published"}
```

Operators: `and`/`or` (`args`), `not` (`arg`), `has` (`var`), `==`, `!=`, `<`, `<=`, `>`, `>=`, `in`. Variables: `principal.id`, `principal.type`, `principal.attrs.*`, `resource.<attr>`, `context.*` (the `permissions.context` setting, plus `context.jwt` = JWT claims) and `now`. Comparisons use jsonb ordering. A missing or null operand makes a comparison false.

On write, the top-level `and` is split into a **principal half** (principal/context/now terms, evaluated once per query inside `ids()`) and a **resource half** (`resource.*` terms). A term that mixes the two can't be partially evaluated and is rejected with `22023`.

- `can()` evaluates the resource half against its `resource` jsonb.
- `ids()` only includes policies whose resource condition equals its `resource_condition` argument (null = unconditioned).
- `rls_expression` emits one extra group per distinct resource condition, `(<condition compiled to SQL> and (id = any(ids(..., cond)) or folder_id = any(...)))`. The compiler maps `resource.status` to column `status` and compares through `to_jsonb(col)` so the SQL means exactly what the interpreter means (`b/53_conditions`).

Grant expiry is a column on `role_grants`, not a condition, so it costs nothing.

## RLS

The fast path rule from PLAN.md §4: `col = any (array(select unnest(f())::uuid))`. Every call is an uncorrelated `(select ...)`, so Postgres runs it once per query as an InitPlan, and the per-row work is an array membership test that can use the column's index.

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

plus one group per resource condition and an `allows_all` arm when an allow-all permit exists. `apply_rls` runs it through `create policy` for `select` (`using`), `update` (`using` and `with check`), `delete` and `insert` (`with check`). The InitPlan form is used for writes too, because it runs once per statement rather than once per row; the per-row `can()` stays available for hand-written policies.

**Finding: a boolean arm breaks index use.** The first version always emitted `(select permissions.allows_all(...)) or id = any(...) or ...`. A boolean InitPlan OR'd with the id arms stops Postgres from building a BitmapOr over the indexes. On the 10k-document benchmark data a count went from a bitmap/index scan to a Seq Scan. That's the same class of trap as the hashed subquery in PLAN.md §4. The permit side now emits `allows_all` only if an allow-all policy exists when the expression is generated (the forbid side is AND'd, so `denies_all` is always present and harmless). `lint()` reports allow-all permits that no RLS policy includes.

Hand-written policies are fine too: `b/50_parents` uses the single branch `folder_id = any (array(select unnest(permissions.ids('select', 'document', 'folder'))::uuid))`, and the benchmark uses A's two-branch shape.

## Reference scenario end to end

From `test/spec/b/30_zanzibar_reference.sql` (fixture UUIDs abbreviated):

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

- **Can Bob update readme?** `can_for('user', bob, 'update', 'document', readme, '{"org": acme}')` is true: "doc editors edit" matches his `editor` grant on readme.
- **Which documents can Dave select?** `ids_for('user', dave, 'select', 'document')` = `{readme}` (through `team:eng`), and `ids_for(..., 'org')` = `{}`. Carol gets `{readme}` and `{acme}`, so through RLS she sees every Acme document.
- **Who can view readme?** `who_can('select', 'document', readme)` with no row attributes gives Bob, Carol and Dave from readme's own grants (the same question A's `list_subjects` answers). With `'{"org": acme}'` it also returns Alice and Carol through "org members view docs".

## v0.0.2 scenarios (PLAN.md §10)

| Goal | How B expresses it | Spec |
| --- | --- | --- |
| G10 parents | Folders are entities in `parents` under their org; a document's folder is its `folder_id` column. `via => 'org'` / `via => 'folder'` policies. RLS is one branch on `folder_id`. Moving a document is an `update` of its column. Cycles are rejected on write (`23514`). | `b/50_parents` 13/13 |
| G11 public | `permit('announcement is public', '{select}', 'document', resource_id => ...)`: no role needed. Revoking is `drop_policy`. A null subject matches nothing. | `b/51_public` 7/7 |
| G12 forbid | `forbid('block dave on readme', '{select,update,delete}', 'document', resource_id => readme, principal_id => dave)`. Beats team and org-derived permits; RLS deny side via `apply_rls`. Clients get `42501`. A row-dependent forbid (`via`, resource condition) whose input the caller leaves out of `can()` raises `22023` instead of not matching. | `b/52_forbid` 9/9, `b/54_fail_closed` 16/16 |
| G13 conditions | `permit(..., roles => '{member}', via => 'org', condition => resource.status == 'published')` plus an unconditioned editors policy; `apply_rls` compiles the condition into the RLS expression. Expiry is `grant_role(..., expires_at)`. | `b/53_conditions` 6/6 |

Translations of A's zanzibar-level files (`b/30`, `b/31`, `b/40`) keep A's assertion count and wording. Two assertions had to change meaning, both in `b/31`:

- **Cycles:** A asserts that a check over a cyclic membership graph terminates. B never stores a cycle, so the assertion checks that the cycle edge is rejected with `23514` *and* that checks still answer.
- **Undefined userset:** B has no usersets (`team#lead`). The nearest validation, used in its place, is that a policy requiring a role not declared on its anchor type is rejected.

## Blessed path: the `rbac` preset

The preset API from [PLAN.md §6](../PLAN.md) maps onto B one to one. Two built-in resource types hold the roles: `app` (one resource, `app:global`) and `tenant` (one per scope).

| Preset call | Engine call |
| --- | --- |
| `create_role('editor', '{documents.edit}', '{viewer}')` | On `app` and `tenant`: `define_role(t, 'editor', '{viewer}')` plus a policy `rbac:<t>:editor` (actions `{documents.edit}`, roles `{editor}`, `managed_by = 'rbac'`) |
| `assign_role('bob', 'editor', 'acme')` | a `role_grants` row on `tenant:acme` |
| `has_permission('documents.edit', 'acme')` | `can_for(current subject, 'documents.edit', 'tenant', 'acme')` |
| `scopes_with_permission('documents.read')` | `ids_for(current subject, 'documents.read', 'tenant')` |
| `users_with_role('admin', 'acme')` | grants on `tenant:acme` joined to `role_closure`, group grantees expanded |

What's stored for the RBAC scenario: 6 `roles` rows, 4 `role_implies` rows, the matching `role_closure`, 6 generated policies, and one `role_grants` row per assignment. `parents` and `ancestors` stay empty, so no closure triggers run. `drop_policy` refuses `managed_by` policies (`55000`), so a hand edit can't break a role.

Graduation (`b/40_graduation`) adds `define_role('document', ...)`, two `permit` calls and a `grant_role`. The select policy gains one branch, `id = any(... permissions.ids('select', 'document') ...)`, and every RBAC answer is unchanged. Graduating is where B's second concept appears: on the sharing side the developer writes policies, which RBAC users never had to do.

## Performance

**Measured so far (small scale only).** 10k documents, 1k users, 20 orgs, 50 teams; `./bench/run.sh --impl prototypes/b-policy-first.sql --duration 3`; 4 clients on a laptop shared with other test runs, so treat these as a sanity check, not a result. All within budget:

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

The B sharing seed (`bench/designs/b/`) produces the same visible document set as A's for all 1,000 users (identical checksum over every user's RLS result). Large-scale numbers are pending a serial run.

**Why the stand-in's RBAC was ~3× slower than A** (rbac_update_one p95 3.27 ms vs 1.04 ms). It was the implementation, not the design:

1. The stand-in's `can_for` computed the caller's whole `ids_for` set and then tested membership.
2. `ids_for` matched the principal with `(principal = me) or (principal) in (select ... from ancestors)`. That OR stopped Postgres using the `role_grants` primary key prefix. EXPLAIN showed a bitmap scan of every grant of the role in `tenant` (~334 rows per role at small scale), filtered afterwards. The cost grew with the total number of users, not with the caller's grants.

The built evaluator drives every check from `subject (+ its groups) × anchor` into the `role_grants` primary key. Single-client rbac_update_one went from 2.5 ms (stand-in) to 0.56 ms, and rbac_check from 0.41 ms to 0.20 ms.

**Parents, indicative only.** On the same small data with folders added (10 folders per org, a `via => 'tenant'` policy, single-branch RLS on `folder_id`), page and count ran at about 0.43 ms single-client. The InitPlan returned 20 folder ids instead of 1,000 document ids, and the plan was an index-only scan on `folder_id`. This was ad hoc, not a committed benchmark.

**What is cheap:** `ids()` and `can()` cost grows with the caller's grants and group count, not the table size. Org- or folder-level access costs one array element per folder. Policy edits and role grants need no maintenance writes.

**What needs care:**

- **Number of InitPlans.** The generated expression has one function call per arm: 5 for a table with one parent column and no conditions, 7 with one resource condition. Each is a function call (tens of microseconds). This hasn't been measured at scale.
- **Large id arrays.** `id = any($1)` is a linear scan of the array per row the planner checks. With an index on the column this is fine. A caller with tens of thousands of direct grants hasn't been measured. Don't switch to the hashed `in (select ...)` form (PLAN.md §4: 40× slower for counts).
- **Bulk updates** through a hand-written per-row `can()` policy call it once per row; `apply_rls` uses the InitPlan form instead.
- **`who_can`** fans out through group descendants and re-checks each candidate. It's a debugging function, not an RLS function.

**Write cost**

| Write | Cost |
| --- | --- |
| `grant_role`, `revoke_role`, `set_attrs`, `permit`, `forbid` | one row; no closure work |
| `define_role` | rebuild `role_closure` for one resource type (tens of rows) |
| `add_parent(c, p)` | `|descendants-or-self(c)| × |ancestors-or-self(p)|` closure rows, after cycle and depth checks |
| `remove_parent(c, p)` | delete and rebuild closure for `c` and its descendants |

All parent writes serialize on one advisory lock. The sharing seed (1,047 parent edges, 2,722 closure rows) loads in about 1 s at small scale.

## Weaknesses and risks

- **Two concepts to learn.** A developer writes policies and facts. The reference scenario needs 5 role definitions and 4 policies on top of the grants.
- **RLS has to mirror the policies.** The generated expression is fixed when `apply_rls` runs:
  - `via` columns are named there;
  - resource-conditioned groups and the `allows_all` arm are included only if such policies exist at that moment.

  Add a policy `via => 'project'`, a new resource condition, or an allow-all permit later, and the table's RLS must be regenerated, or the policy silently grants nothing on select. It fails closed for permits. `lint()` flags these cases, but it checks `pg_policy` text, which is brittle. Forbids added later need no regeneration for unconditioned shapes.
- **`can()` needs the row.** Outside RLS, the caller must pass the row's parent columns and attributes in `resource`. Passing too little fails closed for permits. For forbids it used to **fail open** (a forbid `via => 'folder'` or with a resource condition didn't match if the caller omitted the folder or attribute); it now raises `22023` (see [Decision](#decision)). The cost: adding a row-dependent forbid can make existing `can()` calls that pass too little start raising for the subjects it could apply to. That is the intended failure, but it is a runtime failure, not a lint warning.
- **`can()` trusts its `resource` argument.** It is an oracle over the facts the caller supplies. A client calling `can()` with a made-up folder only fools itself (RLS reads the real columns), but server code must not feed client-supplied row data to `can()` and treat the answer as a gate.
- **Which jsonb keys are parents is implicit.** Every key that names a type is a candidate parent, except principal types (above). A key that collides with a non-principal entity type, such as `{"status": "draft"}` when some app also uses `status` as an entity type with parents, is still read as a parent. That only matters if that entity has ancestors of a type some policy anchors on, i.e. the app declared "draft is in org acme". The principal-type rule closes the realistic case (an author column named `user` pulling in the author's org: `can()` said yes where RLS said no), but it is derived from policies and grants, so granting a role *to* a folder would make `folder` a principal type and stop `{"folder": ...}` counting as a parent unless a policy anchors `via => 'folder'` (fails closed). The explicit fix is open question 4: declared parent types per resource type, as Cedar's schema does with `memberOfTypes`. That changes how every B spec calls `can()`, so it wasn't done here.
- **`ids_for` as a list is not fail-closed for row-dependent forbids.** `ids()` is a projection used as one arm of RLS, and it is net only of forbids it can evaluate in that projection. `ids_for(subject, 'select', 'document')` (resource ids) still lists a document granted directly when a forbid would block it through its folder column or a resource condition, because neither is known without the row. RLS is exact: its deny side checks `denied_ids` per parent column and compiles resource conditions. Making the list exact would mean splitting the RLS permit arm (which must not subtract conditioned forbids) from a separate list function. Use RLS, or `can()` with the row, for decisions.
- **`who_can`'s `('*', '*')` row is not net of forbids.** A no-role permit with no principal restriction (public access) returns one wildcard row; a forbid on one user can't be expressed as an exception to it. A's `list_subjects` row for `user:*` and C's null row behave the same way. Unlike A, B labels the row `('*', '*')` even when the policy's `principal_type` is `user`.
- **A document without a value in the RLS parent column** (e.g. `folder_id is null`) is reachable only through its own grants unless the policy also has an `org_id` branch.
- **`ids()` is exact only for unconditioned policies.** With resource-conditioned permits or forbids, `ids_for` used as a "list" is an approximation. RLS is exact because it compiles the conditions.
- **Planner trap in `_matches`: set-returning helpers need a `rows` estimate.** A function scan is estimated at 1000 rows by default. `_parent_keys()` returns about one row, but once `ancestors` had been analyzed with real data (92k rows) the planner hash-joined a full seq scan of `ancestors` against it, and `can()` went from about 1.3 ms to 17-22 ms (wide shape, `nest_check`). `_parent_keys` is now declared `rows 1`, the plan probes the `ancestors` primary key again, and `nest_check` p50 is 0.79 ms. Any new set-returning helper joined to `ancestors` or `role_grants` needs the same.
- **Closure write amplification and one global lock.** Nesting a big group in another writes the product of their sizes. Row-level triggers mean removing a 1,000-member team does 1,000 small rebuilds. Membership churn in the tens per second is fine; org-chart-sized graphs with constant churn are not. Repeatable read is refused for these writes.
- **Text ids and casts.** `::uuid` in RLS fails the whole query if any stored id for that type isn't a uuid. An id type per resource type, validated in `grant_role`, would fix this.
- **Security definer everywhere.** A bug in the read functions is a privilege bug. `search_path = ''` and no dynamic SQL in the read path limit the damage. The functions aren't `leakproof` (that needs a superuser).
- **Context from settings.** `permissions.context` and `permissions.subject_id` can be set by any session on plain Postgres. On Supabase the JWT wins, but conditions on `context.*` should only use JWT claims or server-set values.
- **Condition semantics are jsonb semantics.** `now` and timestamps compare as ISO strings, which works for same-offset values only.
- **The policy language is restricted:** principal scope, role on the resource or on a parent of one named type, condition. "The author of the document" (an `owner_id` column) needs either a role grant per row or a condition comparing `resource.owner_id` with `principal.id`. That comparison mixes resource and principal variables, which the splitter rejects today (open question 7). A generic Cedar engine would accept such policies and just be slow; B refuses them.

## Deviations from the original design

1. **Identity names** follow the shared contract: `current_subject_id()` and the `permissions.subject_id` setting (the original doc said `current_subject()` / `permissions.subject`, and read the old `request.jwt.claim.sub`).
2. **`via` resolution** (original open question 2): both the `resource` jsonb (columns) and `parents` rows count as parents, and anchors are transitive through `ancestors`. Anchors for `via` are strictly above the resource.
3. **`ids(..., via)` is a projection onto the parent column**, not "the anchor ids where I hold the role". The original version couldn't give G10 a single RLS branch, because org-level grants needed a separate `org_id` arm.
4. **Forbid is implemented** (the check constraint is gone). `principal_id` was added so a forbid (or permit) can name one principal, as Cedar's `principal == User::"dave"` does. `ids_for` is net of forbids. `denied_ids`, `denies_all` and their `_for` variants are new, for the RLS deny side.
5. **Public access** is a no-role policy with `resource_id`, not a wildcard grant. No new mechanism was needed.
6. **Resource conditions run on the RLS fast path now**, not in "v0.0.3". Conditions are split into principal and resource halves on write, mixed terms are rejected, and `rls_expression` compiles resource halves to SQL with their own `ids(..., resource_condition)` group.
7. **The hashed-subquery advice is removed.** The fast path is `= any (array(select unnest(...)::uuid))` (PLAN.md §4).
8. **`allows_all` is not always emitted** (the BitmapOr finding above).
9. **`apply_rls` uses the InitPlan expression for update, delete and insert** instead of a per-row `can()`. It runs as security invoker, so only the table owner can use it. It returns the policy name `permissions_<command>`.
10. **Closure details:** `depth` is the shortest path; repeatable read is refused (serializable is allowed); `parents` rows are immutable.
11. **Additions:** `is_in` (Cedar `in`); `explain` also returns the effect; `who_can` filters candidates through the same matcher as `can`, so the two agree by construction; `delete_entity` returns a row count; `managed_by` exists and `drop_policy` enforces it; `lint()` checks undeclared roles, unenforced forbids, missing allow-all arms and resource conditions missing from RLS.
12. **Parameter names:** `permit` and `forbid` take named arguments without a prefix (`roles =>`, `via =>`, `resource_id =>`, `condition =>`, `principal_id =>`), matching the examples in the original doc.
13. **`can()` fails closed on missing forbid inputs** (added after review, 2026-10-28): a forbid that could apply and reads a parent or attribute absent from `resource` raises `22023` instead of not matching. `who_can` and `explain` inherit it.
14. **Principal-typed jsonb keys are not parents** (same review): `{"user": ...}` or `{"team": ...}` is an attribute unless a policy on the resource type anchors `via` that type. Before, every key was a parent, and an author column named `user` made the author's orgs anchors of the row.

## Open questions

1. Should role implication stay a table, or just be policies (`roles => '{viewer,editor}'`)? The table is shorter for apps but is a second place where meaning lives.
2. Should `rls_expression` be regenerated automatically (an event trigger or a policy-table trigger that re-runs `apply_rls`), instead of `lint()` reporting drift? That needs DDL from a trigger, which TLE may not allow.
3. Explicit subject: is `revoke` on `*_for` functions enough, or should they check membership of a dedicated `permissions_admin` role?
4. Should parent keys in the `resource` jsonb be explicit (declared parent types per resource type, Cedar's `memberOfTypes`) rather than "every key except principal types"? Recommended: it would replace the derived principal-type rule and let `can()` name exactly which keys a call must pass.
5. Should `apply_rls` exist at all (it is the only `execute` in the extension), or should we ship only `rls_expression`?
6. Is one global advisory lock acceptable for closure maintenance, or do we need per-component locks? Statement-level triggers would also cut the per-row cost of big membership changes.
7. Principal-to-resource conditions (`resource.owner_id == principal.id`): allow them as a compiled SQL predicate comparing a column with `current_subject_id()`? That's partially evaluable, but the splitter rejects it today.
