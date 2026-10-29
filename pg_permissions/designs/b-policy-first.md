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
| `ancestors(child, ancestor, depth)` | Transitive closure of `parents` for **inner nodes** (entities that are the parent of something); `depth` is the shortest path, 1–10 | triggers on `parents` only |
| `closure` (view) | Every (descendant, ancestor) pair: direct `parents` rows plus the stored rows of each direct parent. What the read paths use | nothing (a view) |
| `roles(resource_type, role)` | Roles declared per resource type, so typos fail at grant time | `define_role` |
| `role_implies(resource_type, role, implies)` | `editor` implies `viewer` | `define_role` |
| `role_closure(resource_type, role, implied)` | Reflexive transitive closure of `role_implies` | rebuilt per type by `define_role` |
| `role_grants(principal, role, resource, expires_at)` | Principal (user or group) holds role on resource, optionally until a time | `grant_role`, `revoke_role` |
| `policies` | Permit and forbid rules (below) | `permit`, `forbid`, `drop_policy` |

A policy row has `effect` (`permit` / `forbid`), a principal scope (`principal_type`, default `'user'`, null = any; optional `principal_id` for one principal; optional `principal_in_type/id` for "member of this group"), `actions text[]`, `resource_type`, optional `resource_id`, optional `roles` plus `via` (the anchor), the `condition` as written plus its two halves `principal_condition` and `resource_condition` (split on write), `managed_by` (`'rbac'` for preset-generated policies) and `enabled`.

Id, type and role columns are `collate "C"` (opaque keys; see [Optimizations](#optimizations-session-3)). Indexes that matter: `role_grants` primary key `(principal_type, principal_id, resource_type, resource_id, role)`, which every check probes by subject and anchor; `role_grants (resource_type, resource_id, principal_type, principal_id)` for `who_can`, also an exact probe for checks; `parents` primary key for "my parents" and `parents (parent_type, parent_id, child_type, child_id)` for "children of this folder" (index-only); `ancestors` primary key for an inner node's ancestors and `ancestors (ancestor_type, ancestor_id, child_type, child_id)` for "inner nodes under this org".

### Closure maintenance and concurrency

`ancestors` holds rows only for inner nodes: a team with members, a folder with documents, an org with folders. A leaf (a user, a document) is one hop away: its ancestors are its `parents` rows plus their stored rows, which the `closure` view joins (no recursion). It is maintained by a row-level `before insert` and an `after delete` trigger on `parents` (updates are rejected; remove and add instead). Every trigger that does work first takes one transaction-scoped advisory lock, `pg_advisory_xact_lock(hashtext('permissions.closure'))`, so closure writers are serialized.

- **Insert `c -> p`:** reject if `p` is already below `c` (cycle, SQLSTATE `23514`), reject if any new path would be deeper than 10 (`23514`). If `p` has no stored rows yet (its first child), store its ancestors. If `c` is itself inner, every inner descendant-or-self of `c` gets every ancestor-or-self of `p` (`on conflict ... depth = least(...)`). A leaf child writes no closure rows. The trigger runs *before* the insert so that a multi-row insert sees only the rows inserted before it, as the original after-trigger (which never read `parents`) effectively did; a row that already exists is skipped (ON CONFLICT drops it).
- **Delete `c -> p`:** only `c` and its descendants can change, and only inner ones have rows: theirs are deleted and rebuilt from `parents` with a depth-bounded recursive walk. A parent left without children loses its rows.
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

> The numbers in this section are the session 2 baselines. See [Optimizations (session 3)](#optimizations-session-3) for what changed and the interleaved before/after measurements.

**Large and medium scale.** Serial runs, one engine at a time, 10 s per workload, 4 pgbench clients; full tables, plans and checksums are in [bench/baselines/COMPARISON.md](../bench/baselines/COMPARISON.md). Per-user visible-document checksums match A and C at every scale. p50 ms (p95 in `COMPARISON.md`):

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

- RBAC and sharing reads sit between A and C: B is faster than A on sharing (large `share_select_page` 1.21 ms vs A's 2.02) and slower than C (0.95).
- With the two-arm projection (the form this design recommends), parents cost about what sharing costs. The single-branch form needs a `parents` row and closure rows per document and costs 197 ms at large (about 140× the projection). The seed for it took 167 s and added about 736 MB (1M `parents` rows plus 2M closure rows).
- Nesting a 1,000-member team writes closure rows under the global lock, so concurrent nests queue (285 ms p50 at large, 4 clients; A writes one tuple in 0.15 ms).
- `nest_check` is the slowest check of the three engines (1.2 ms small, 2.4-2.8 ms medium and large) after the `_parent_keys` row-estimate fix.
- Deep and wide shapes (medium): B's `share_select_page` is 2.04 ms deep and 70 ms wide.

**Small scale, early sanity check (superseded by the numbers above).** 10k documents, 1k users, 20 orgs, 50 teams; `./bench/run.sh --impl prototypes/b-policy-first.sql --duration 3`; 4 clients on a laptop shared with other test runs, so treat these as a sanity check, not a result. All within budget:

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

The B sharing seed (`bench/designs/b/`) produces the same visible document set as A's for all 1,000 users (identical checksum over every user's RLS result).

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
| `add_parent(c, p)` | `|inner descendants-or-self(c)| × |ancestors-or-self(p)|` closure rows if `c` has children, none for a leaf (plus `p`'s own rows on its first child), after cycle and depth checks |
| `remove_parent(c, p)` | delete and rebuild closure for `c` and its inner descendants; nothing for a leaf |

All parent writes serialize on one advisory lock. (Session 2 numbers, before the inner-node closure: the sharing seed, 1,047 parent edges and 2,722 closure rows, loaded in about 1 s at small scale.)

## Optimizations (session 3)

Goal: cut B's measured weak spots without changing the policy model, the closure-on-write approach or the concurrency rules. Semantics are unchanged: the suite still passes (15/15 files, 172/172 assertions) and the per-user checksums of all four read policies match A and C at small, medium (default, deep, wide) and large.

**How it was measured.** Two other agents were benchmarking on the same machine, so absolute numbers are noisy and **every before/after below is interleaved**: the original prototype (kept as `bench/results/optb/b-orig.sql`, git-ignored) and each step were loaded into separate databases of one private cluster with the same seeds and the same `VACUUM FULL ANALYZE` steps as `bench/run.sh`. pgbench then alternated between them with the bench's own workload files, 5-10 s per run, at least two rounds each. Values are p50 ms, 1 client unless marked "4c". Each step was also checked with `EXPLAIN (ANALYZE, BUFFERS)` and with auto_explain on the functions' nested statements, after warming up so the plan cache had chosen its steady-state plan. Seed times and sizes are single runs on a loaded machine and are not interleaved.

**Correctness checks beyond the suite.** Two differential fuzzers, original against new engine (scripts in `bench/results/optb/`):
- *closure*: 168k random `add_parent` / `remove_parent` / `delete_entity` / multi-row inserts into `parents` on graphs of up to 30 nodes with long chains (720 depth-cap rejections, 6.6k cycle rejections). After every operation it compares the outcome (`ok`, or SQLSTATE plus message, including the reported depth) and the full closure (every pair with its shortest depth), and checks that the stored rows are exactly the inner nodes' closure. 0 differences.
- *reads*: 120 random worlds (nested teams, folders in orgs, documents with and without `parents` rows, expired grants, permits and forbids via folder or org, `principal_in`, public documents) comparing `can_for` with and without the row, `ids_for` (resource ids and every projection), `denied_ids_for`, `allows_all_for`, `denies_all_for`, `explain` (with multiplicity), `who_can`, `is_in` and `users_with_role`. 119k compared results, 0 differences.

### What changed, in order

**1. `collate "C"` on every id, type and role column** (`entities`, `parents`, `ancestors`, `roles`, `role_implies`, `role_closure`, `role_grants`). The cluster's default collation is `en_SG.UTF-8`, so every B-tree comparison, join and sort on a uuid-as-text went through `strcoll`. In wide `ids()`, the `distinct` sort of 6.7k ids took 19 of 29 ms. Equality doesn't change under a deterministic collation; only the order of `ids()` arrays does (the specs compare sets). glibc's `strcoll` is slower than macOS's, so Docker or Linux should gain more.

| workload | before | after |
| --- | --- | --- |
| `share_list_objects` medium wide | 24.5-25.3 | 6.8 |
| `share_select_page` medium wide | 66-69 | 30.6 |
| `write_nest_team` medium | 55 | 18 |
| `parents_select_page` medium | 28-30 | 7.8 |
| `nest_check` medium | 2.2 | 0.79 |

**2. Read the right grants, once, by primary key.**
- `_ids`: a policy-role list (`pr`: each role policy, its anchor type and every role that satisfies it, from `role_closure`) drives `held`, which probes the `role_grants` primary key with `resource_type = any(anchor types)` and `role = any(satisfying roles)`. Before, `held` read every grant of the subject and its groups (6.7k document grants per user in the wide shape, even for the tenant-only `scopes_with_permission` arm) and joined them to `role_closure` with a 100k-comparison nested loop. `distinct` now runs as its own step, so it can hash.
- `_matches`: the subject's groups, the resource's anchors and `_parent_keys` (before: called twice) are computed once into arrays. Grants are probed with one `lateral (... offset 0)` primary-key lookup per (subject or group, anchor), with the `role_closure` check inside it.
- `role_grants (resource_type, resource_id)` became `(resource_type, resource_id, principal_type, principal_id)`. The generic plan kept picking the resource index, which reads every grant on a tenant (one per member, about 80-200) and filters by subject. With the principal columns, either index is an exact probe. +2.1 MB at large.

| workload | before | after |
| --- | --- | --- |
| `share_list_objects` medium wide | 6.9 | 3.7 |
| `share_select_page` medium wide | 31.8 | 16.8 |
| `nest_check` medium | 0.80 | 0.40 |
| `rbac_check` medium | 0.50 | 0.40 |

**3. PL/pgSQL instead of SQL for the hot wrappers** (`can`, `can_for`, `ids`, `denied_ids`, `allows_all(_for)`, `denies_all(_for)`, `denied_ids_for`, `_all`, `_parent_keys`, `has_permission`, `has_role`, `scopes_with_permission`, `current_subject_id/type`). A SQL function with a `SET` clause or `security definer` is never inlined, and in Postgres 16 its body is parsed and planned again on every outer query; `_parent_keys` alone cost 0.08-0.2 ms per call. PL/pgSQL caches the plans per session. `nest_check` 0.39 → 0.33, `rbac_check` 0.39 → 0.29, wide `share_list_objects` 3.9 → 3.7.

**4. Closure rows for inner nodes only** (the change behind `write_nest_team` and the parents storage). `ancestors` keeps rows only for entities that have children; a leaf's ancestors are its `parents` rows plus their stored rows (the `closure` view, one join, no recursion). Nesting the 1,000-member team writes the team's 1 × (1 + ancestors) rows instead of 1,001 × (1 + ancestors). Filing a document in a folder writes only its `parents` row, and removing a member rebuilds nothing. C already stores "containers only". What it took:
- the cycle and depth checks are unchanged in meaning; the deepest descendant is the deepest stored inner descendant plus one level of children, computed exactly;
- the insert trigger runs `before insert`, so multi-row inserts stay edge-by-edge (an `after` trigger would see the whole statement's rows while the closure is half updated; the fuzzer caught it, with duplicate-upsert `21000` errors and missing rows);
- the `closure` view leaves out pairs more than 10 apart, which matches the original. See the latent bug under remaining limits;
- every read that joins the view uses `cross join lateral (... offset 0)` (see the planner trap in Weaknesses; before that fix `nest_check` was 22 ms and `parents_select_page` 100 ms);
- `_matches` and `_ids` pin `plan_cache_mode = force_generic_plan` (the plan cache kept re-planning them with custom plans: 0.66 → 0.11 ms per `can()`);
- `parents (parent_type, parent_id)` became `(parent_type, parent_id, child_type, child_id)` for index-only descendant reads. The old index was 7 MB at large thanks to B-tree deduplication, the new one 120 MB, but at large single-branch `parents_select_page` is 18.7 vs 26.7 ms and `parents_select_count` 29.5 vs 55 ms with it (interleaved), so it stays.

| workload | before (step 3) | after |
| --- | --- | --- |
| `write_nest_team` medium | 19.7 | 0.17-0.21 |
| `write_nest_team` medium, 4c | 75-84 | 0.65-0.70 |
| `nest_check` medium | 0.33 | 0.23 |
| `parents_select_page` medium | 8.5 | 6.4 |
| `share_list_objects` / `share_select_page` medium wide | 3.9 / 16.6 | 4.05 / 18.0 (worse, see below) |

Storage and seed time (not interleaved): medium parents phase 86.3 → 46.4 MB, seed 15.5 → 4.2 s; medium wide after sharing 225.9 → 105.3 MB, seed 37 → 13 s; large after the single-branch parents seed 762.8 → 377.9 MB, seed 252 → 51 s on the loaded machine (the session-2 baseline measured 167 s). A document with a parent link now costs one `parents` row plus its two index entries, instead of 3 rows. The cost: a user's groups are one hop further away, so wide reads (50 direct teams per user) are about 5-8% slower than after step 3.

**5. `_all()` skips `_candidate_policies` when no allow-all or deny-all policy exists.** `ids_for` asks it about forbids on every call. `scopes_with_permission` 87 → 78 µs per call.

**6. `ids()` and `denied_ids()` are no longer run at plan time.** RLS uses `= any (array(select unnest(permissions.ids(...))::uuid))`. To estimate `unnest()`'s rows, the planner evaluates its argument when it can (`estimate_expression_value` in `array_unnest_support`), and a STABLE function with constant arguments qualifies. So every RLS query ran `ids()` twice: on the original wide sharing page, planning took 30 of 68 ms. (The A agent found the same thing independently.) Fix: the default of the last argument, `p_resource_condition`, is now `permissions._unfolded_null()`, a trivial VOLATILE function that returns null. A call with a non-constant argument isn't folded, `ids()` stays STABLE and reads the calling query's snapshot, and the signature is unchanged. I didn't simply mark `ids()` VOLATILE (A's fix): under read committed a volatile function takes a fresh snapshot for each query it runs, so the grants would be read at a later instant than the rows they filter, which weakens the single-snapshot guarantee within a statement. Policies get the default when they are created, so this applies to policies created after this version is installed. Wide page planning time 4.7 → 1.35 ms.

| workload | before (step 5) | after |
| --- | --- | --- |
| `share_select_page` medium wide | 18.8 | 14.4 |
| `parents_select_page` medium | 6.1 | 5.1 |
| `parents_select_count` medium | 5.6 | 4.1 |
| `parents_proj_select_page` medium | 0.80 | 0.60 |

### Original vs final (interleaved)

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

`rbac_select_page`, `rbac_select_count`, `write_assign_role` and `write_share` didn't change beyond noise. Medium-default rows other than `parents_proj_select_page` are original vs step 5; step 6 only affects queries whose RLS calls `ids()` with default arguments.

### Tried and dropped

- **Forcing the primary-key probe in `_matches` with `lateral ... offset 0` alone.** The generic plan still used the `(resource_type, resource_id)` index inside the lateral, and the probe ran 270 times: `nest_check` 0.80 → 2.7 ms, `rbac_check` 0.50 → 0.91. Fixed by widening that index (step 2).
- **Joining the `closure` view directly.** `nest_check` 22 ms and `parents_select_page` 100 ms (the view-join planner trap). Fixed with lateral joins (step 4).
- **The narrow `parents (parent_type, parent_id)` index with the inner-node closure.** It saves 113 MB at large but makes single-branch reads 40-90% slower (step 4).
- **`enable_hashjoin = off` for the subject's group expansion in wide** (hash join over the small inner-node `ancestors` vs 50 primary-key probes): no difference.
- **Marking `ids()` VOLATILE**: rejected without measuring, for the snapshot reason in step 6.
- **Caching `ids()` between plan time and execution** (in a setting keyed by statement): rejected. Planning and execution can use different snapshots under read committed, and keys can collide.
- **Statement-level triggers with transition tables**: not useful here. `add_parent` inserts one row per statement, so a seed of 1M calls fires 1M statement triggers anyway. The inner-node closure removed the per-row closure work instead.

### Remaining hard limits

- **The RLS form costs what the array costs.** With 6.7k-20k ids, `unnest` plus `::uuid` takes 1.5-4.5 ms, and `id = any($1)` is a linear scan of the array for every row a filter checks (8 ms of the wide page's 15). C's policy casts the whole array (`(select f())::uuid[]`). B can't change the seeds' policy text.
- **`scopes_with_permission` is still evaluated at plan time** (one argument, no default to hang the trick on). It costs about 1 ms in the wide shape. Fixing it needs a new parameter on a shared preset function.
- **Explicitly passed constant arguments still fold**, e.g. `rls_expression`'s resource-conditioned groups (all four arguments). `rls_expression` could emit `(select permissions.ids(...))::uuid[]` instead, which is never folded. That changes the PLAN §4 fast-path form for all engines, so it isn't done here.
- **One global closure lock.** Nesting is now about 0.2 ms when the nested group's members are leaves, so the lock is held briefly. Nesting a sub-tree with many inner nodes still writes `inner descendants × ancestors` rows under it.
- **Wide memberships cost a hop.** A user's groups are `parents` rows plus their stored rows. With 50 teams per user that is about 0.3 ms per `ids()` call more than a fully stored closure.
- **Latent bug kept for compatibility (pre-existing in the original):** removing a shortcut edge can make the shortest remaining path between two entities longer than 10. The original's delete rebuild stops at depth 10 and silently drops that pair (a partial answer, against "the depth cap is enforced on write"). The new engine reproduces this exactly, through the view's `depth < 10` filter and the capped depth computation, because the fuzzer compares against the original. The right fix is to reject such a delete with `23514` (or allow any depth). That is a semantic change, left as a decision.

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
- **Plan pinning.** `_matches` and `_ids` set `plan_cache_mode = force_generic_plan`: the plan cache otherwise kept choosing custom plans, re-planning the lateral and view queries on every call (0.66 ms vs 0.11 ms per `can()`).
- **Planner trap in `_matches`: set-returning helpers need a `rows` estimate.** A function scan is estimated at 1000 rows by default. `_parent_keys()` returns about one row, but once `ancestors` had been analyzed with real data (92k rows) the planner hash-joined a full seq scan of `ancestors` against it, and `can()` went from about 1.3 ms to 17-22 ms (wide shape, `nest_check`). `_parent_keys` is now declared `rows 1`, the plan probes the `ancestors` primary key again, and `nest_check` p50 is 0.79 ms. Any new set-returning helper joined to `ancestors` or `role_grants` needs the same.
- **Closure write amplification and one global lock.** Nesting a group writes `inner descendants × ancestors` rows: nesting a 1,000-member team of users writes about 5 rows (0.2 ms), but nesting a team that contains hundreds of sub-teams still writes the product. Removing members (leaves) rebuilds nothing. All closure writers still serialize on one lock, so a slow nest of a deep sub-tree blocks every other membership write. Repeatable read is refused for these writes.
- **Planner trap in the `closure` view.** Its second branch is a join, so Postgres can't flatten it into an append or push a join condition from an outer relation into it; it computes every inner node's descendants and filters (`nest_check` went from 0.3 to 22 ms when it was first joined). Every read joins it as `cross join lateral (... offset 0)` or with parameters only. New read paths must do the same.
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
15. **Closure rows for inner nodes only** (session 3): `ancestors` stores rows only for entities with children, the `closure` view adds the leaves, and the insert trigger is `before insert`. Same answers, cycle and depth checks; see [Optimizations (session 3)](#optimizations-session-3).

## Open questions

1. Should role implication stay a table, or just be policies (`roles => '{viewer,editor}'`)? The table is shorter for apps but is a second place where meaning lives.
2. Should `rls_expression` be regenerated automatically (an event trigger or a policy-table trigger that re-runs `apply_rls`), instead of `lint()` reporting drift? That needs DDL from a trigger, which TLE may not allow.
3. Explicit subject: is `revoke` on `*_for` functions enough, or should they check membership of a dedicated `permissions_admin` role?
4. Should parent keys in the `resource` jsonb be explicit (declared parent types per resource type, Cedar's `memberOfTypes`) rather than "every key except principal types"? Recommended: it would replace the derived principal-type rule and let `can()` name exactly which keys a call must pass.
5. Should `apply_rls` exist at all (it is the only `execute` in the extension), or should we ship only `rls_expression`?
6. Is one global advisory lock acceptable for closure maintenance, or do we need per-component locks? Since session 3 the lock is held for about 0.2 ms when a group of users is nested (inner-node closure), so this matters mainly for nesting large sub-trees.
7. Principal-to-resource conditions (`resource.owner_id == principal.id`): allow them as a compiled SQL predicate comparing a column with `current_subject_id()`? That's partially evaluable, but the splitter rejects it today.
