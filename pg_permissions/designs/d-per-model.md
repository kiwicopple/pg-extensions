# Design D: Per-model tables (`rbac_*` and OpenFGA `fga_*`)

> Status: the extension, [`pg_permissions--0.0.1.sql`](../pg_permissions--0.0.1.sql) (built as a prototype in session 4, `prototypes/d-per-model.sql`, and promoted to the extension file in phase 1 of session 5). Built in session 4 after the direction change in [`PLAN.md`](../PLAN.md) ("Current plan (session 4): per-model tables") and [`DECISION.md`](../DECISION.md) ("Session 4 direction"). Passes every shared spec unchanged and OpenFGA's own consolidated test suite: all 138 cases, 933 assertions with stored tuples and 746 with contextual tuples (section 9). Since phase 4 of session 5 it has OpenFGA conditions (CEL), designed and described in [`d-conditions.md`](./d-conditions.md), with OpenFGA's ABAC suite as their oracle (302 and 271 assertions, section 9). Benchmarked against A, B and C in [`bench/baselines/D.md`](../bench/baselines/D.md): unoptimized (`opt` runs), then after a second pass (`opt2`: target-pruned recursive-CTE ListObjects, set-based `but not` lists, least fixpoint under subtracts; section 5).

## 1. Idea

There is no generic API. The `permissions` schema holds one set of tables per model, and each set follows an existing spec as closely as it can:

- `rbac_*`: roles, permissions and scoped assignments. The blessed path, as first-class tables. The functions are the `rbac` API every earlier design had (`create_role`, `assign_role`, `has_permission`, ...), with the same signatures, so the shared specs run unchanged.
- `fga_*`: [OpenFGA](https://openfga.dev). Authorization models are OpenFGA's schema 1.1 JSON, tuples are OpenFGA tuple keys, and the functions mirror OpenFGA's API (Check, ListObjects, ListUsers, Read, Write, WriteAuthorizationModel) with its semantics and its error codes. OpenFGA's test suite is the oracle.

The two models share only a small toolkit: subject identity (`current_subject_id()`, G1), the plan-time guard (`_unfolded_null()`, PLAN §4), `collate "C"` on ids, and the grants. They compose in RLS: permissive policies OR, restrictive policies AND (section 6). Graduating from RBAC to fine-grained sharing means adding FGA policies next to the RBAC ones, not migrating.

Design A was the starting point for `fga_*`: the bidirectional Check is A's `check_for` driven by the compiled model instead of `implied_by`/`from_parent` lists.

## 2. Tables

All ids, types and relations are `text collate "C"`.

### RBAC

| Table | Rows |
| --- | --- |
| `rbac_roles` | one per role |
| `rbac_role_permissions` | (role, permission) |
| `rbac_role_inherits` | (role, inherited role); the inherited role can't be dropped while referenced |
| `rbac_role_closure` | (role, every role it includes, itself too); written by `create_role`. Roles are immutable and can only inherit roles that exist, so a new role's closure is its parents' closures plus itself and no other row changes. |
| `rbac_assignments` | (user_id, role, scope); scope null is app-wide. `unique nulls not distinct (user_id, scope, role)` (Postgres 15+). |

`has_permission(p, scope)` is one statement: `rbac_assignments` (by user and scope) → `rbac_role_closure` → `rbac_role_permissions`. App-wide and scoped lookups are separate statements so each probes the unique index directly. Roles are held by `user` subjects only: another `permissions.subject_type` has none.

### OpenFGA

| Table | Rows |
| --- | --- |
| `fga_models` | one per model version: ULID id, a sequence for "latest", the JSON as written |
| `fga_types`, `fga_relations` | the model's types and relations; a relation records `monotone`, `is_tupleset`, for a `but not` that lists evaluate set-based its subtract (`diff_relation`, `diff_tupleset`, `diff_recheck`; section 5), and `conditional`: a conditioned restriction is reachable from it, so its evaluations take the conditional path (false keeps the unconditioned statements) |
| `fga_type_restrictions` | `directly_related_user_types`: (type, relation) allows (user_type, user_relation, wildcard, condition); `[user, user with c]` is two rows |
| `fga_conditions` | the model's conditions: name, expression, parameters as CEL types, and the compiled, type-checked tree (jsonb) the evaluator walks ([`d-conditions.md`](./d-conditions.md) sections 4 and 5) |
| `fga_rewrite_nodes` | each relation's rewrite tree in preorder: `this`, `computed`, `ttu`, `union`, `intersection`, `difference`; `in_subtract` marks the subtract side of a difference |
| `fga_edges` | the positive graph (every operand except a subtract) as edges between (type, relation) pairs: `d` a direct tuple, `c` a computed relation on the same object, `t` a tupleToUserset; `condition` is the restriction's (for `t`, the tupleset restriction's), one edge per allowed condition, so a tuple matches exactly the edge of its own condition |
| `fga_computed_closure` | transitive closure of the `c` edges |
| `fga_paths` | OpenFGA's `PathExists`: which user types (`user`, `user:*`, `group#member`) each relation can reach through any operand |
| `fga_reach` | reachability between (type, relation) pairs in the positive graph, per target relation; `strict` when through at least one edge (a reflexive strict row is on a cycle) |
| `fga_walk_steps` | ListObjects' forward walk compiled per target relation: each `d`/`t` edge joined with the computed closure of its destination, kept only if the node it yields can reach the target; `expand` when that node has steps of its own toward the target |
| `fga_tuples` | the tuples: (object_type, object_id, relation, user_type, user_id, user_relation); user_id `*` is a typed wildcard, user_relation is `''` unless the user is a userset. `condition_name` (`''` for none) and `condition_context` (jsonb) are not part of the key, as in OpenFGA. Primary key in that order; a second index on (user_type, user_id, user_relation, object_type, relation). `seq` (identity, unique index) is the insertion order, Read's page order and continuation token (section 4); added in phase 2 of session 5, since OpenFGA's ULID has no counterpart in the key. |

Everything but `fga_tuples` is written once by `fga_write_authorization_model`, which validates the JSON and compiles it, conditions included (parsed and type-checked there; no parsing at Check time). No check reads model JSON. Tuples don't belong to a model: like OpenFGA, every read joins them with the type restrictions of the model in use, so tuples left over from an earlier model that no longer type-check are ignored (upstream case `check_with_invalid_tuple_in_store`); so are tuples whose condition the model no longer allows for their facet, or whose stored context no longer fits the condition's parameters ([`d-conditions.md`](./d-conditions.md) section 3, rule 5).

## 3. RBAC API

Unchanged from PLAN.md §6 and design A: `create_role`, `drop_role`, `assign_role`, `unassign_role` (admin only); `has_permission`, `has_role`, `scopes_with_permission(permission, p_unfold boolean default _unfolded_null())` (clients and RLS); `user_permissions`, `users_with_role` (admin). Same error codes as A (23505, 22023, 2BP01). `delete_subject(type, id)` removes a subject from both models (its assignments and every tuple naming it as user or object), with A's signature so `90_usage_rbac`'s cleanup step finds it.

## 4. OpenFGA API

Strings use OpenFGA's forms: objects `type:id`, users `type:id`, `type:*` or `type:id#relation`. Tuple keys are OpenFGA's JSON `{"user", "relation", "object"}`. Every function takes an optional `authorization_model_id`; without it the latest model is used.

| OpenFGA endpoint | SQL | Notes |
| --- | --- | --- |
| WriteAuthorizationModel | `fga_write_authorization_model(model jsonb) returns text` | The body of the request: `{schema_version: "1.1", type_definitions, conditions}` as `fga model transform --output-format json` prints it. Returns the new ULID; it becomes the latest. |
| ReadAuthorizationModel(s) | `fga_read_authorization_model(id default null) returns jsonb`, `fga_read_authorization_models() returns table(id, created_at)` | |
| Write | `fga_write(writes jsonb, deletes jsonb, authorization_model_id)` | Each side an array of tuple keys, or `{"tuple_keys": [...], "on_duplicate": "ignore"}` / `{"tuple_keys": [...], "on_missing": "ignore"}`. One transaction. At most 100 tuple keys, writes and deletes together (Limits below). A written key may carry `"condition": {"name", "context"}`, validated against the model (2000); deletes ignore it; a key that exists with another condition is 2017, with `on_duplicate: ignore` too (OpenFGA: HTTP 409). |
| (convenience) | `fga_write_tuple(user, relation, object)`, `fga_delete_tuple(user, relation, object)` | Idempotent: `on_duplicate`/`on_missing` ignore. |
| Read | `fga_read(p_object, p_relation, p_user, p_page_size int, p_continuation_token text) returns (tuples jsonb, continuation_token text)` | One page, OpenFGA's ReadResponse as one row: `tuples` is `[{"key": {"user", "relation", "object"[, "condition": {"name", "context"}]}, "timestamp"}, ...]` in insertion order, `continuation_token` is `''` on the last page. `p_object` may be `type:` for every object of a type. |
| Check | `fga_check(user, relation, object, contextual_tuples jsonb, authorization_model_id, context jsonb) returns boolean` | `context`: OpenFGA's request context, the condition parameters as a JSON object (last, so positional calls without it keep working). |
| ListObjects | `fga_list_objects(user, type, relation, contextual_tuples, authorization_model_id, context) returns setof text` | `type:id` strings, unordered, at most 1,000. |
| ListUsers | `fga_list_users(object, relation, user_filters text[], contextual_tuples, authorization_model_id, context) returns setof text` | Filters `'user'` or `'group#member'`. Returns `type:id`, `type:*`, `type:id#relation`, at most 1,000. |
| DeleteStore | `fga_delete_store()` | Every model and tuple of the one store. |
| (current subject) | `fga_check_current(relation, object)`, `fga_list_objects_current(type, relation)`, `fga_list_object_ids_current(type, relation)` | Clients and RLS. The user is `current_subject_type():current_subject_id()`. The lists are uncapped. |

Contextual tuples are an array of tuple keys or OpenFGA's `{"tuple_keys": [...]}`. They are validated like writes (2027; an invalid condition on one is 2027 in Check and 2000 in the lists, as OpenFGA) and behave exactly like stored tuples, conditions included, in the walks.

Conditions are evaluated where OpenFGA evaluates them, with its rules for errors: a missing parameter or a failed evaluation fails Check with 2000 when no path of true edges exists, and fails ListObjects and ListUsers when their walk takes the edge ([`d-conditions.md`](./d-conditions.md) section 3; [`usage/conditions.md`](../usage/conditions.md)).

### Limits

The API functions follow OpenFGA v1.22.1's default limits and what it does when one is hit (DECISION.md, end of session 4, point 4). The limits are fixed constants in one function, `_fga_limits()`: OpenFGA makes each of them configurable (for example `OPENFGA_MAX_TUPLES_PER_WRITE`), this extension doesn't (the blessed path, no extra settings). Sources are openfga/openfga at tag v1.22.1 and openfga/api at the commit its go.mod pins (`f153694bfc20`); `test/spec/d/34_fga_limits.sql` checks each behavior below.

| Limit | OpenFGA v1.22.1 | pg_permissions |
| --- | --- | --- |
| ListObjects results | at most 1,000 (`pkg/server/config/config.go:28`); more are dropped silently, no error and no flag in the response (`pkg/server/commands/list_objects.go:637-639`); which ones survive is whichever were found first, not deterministic | the same: `fga_list_objects` returns at most 1,000, silently. The spec asserts the count and that each one is in the true set, never which ones. |
| ListUsers results | at most 1,000 unique users, dropped silently (`config.go:31`, `commands/listusers/list_users_rpc.go:245-257`) | the same: `fga_list_users` returns at most 1,000. |
| ListObjects and ListUsers deadline | 3 s, after which the results so far are returned and the error swallowed (`list_objects.go:645-646`, `list_users_rpc.go:286-289`) | none (deviation 4): set `statement_timeout`, which raises instead of returning a partial list. |
| Write size | at most 100 tuple keys, writes and deletes together (`config.go:19`), counted after the duplicate check (2004): over it is 2053 `exceeded_entity_limit`, `The number of write operations exceeds the allowed limit of 100` (`commands/write.go:195-212`). A `writes` or `deletes` given with no tuple keys is 2000 (proto `min_items: 1`). | the same codes and order. The message adds the count: `... allowed limit of 100: got 101 tuple keys (101 writes, 0 deletes)`; the hint says to split into batches of at most 100, which can share one transaction. An empty array (or `{"tuple_keys": []}`) given for either side is 2000; neither given is 2003. |
| Read page size | 50 when absent (`pkg/storage/storage.go:29`), else 1 to 100 or 2000 (`openfga/v1/openfga_service.proto:1174-1180`) | the same: `p_page_size` null is 50, outside 1..100 is 2000. |
| Read continuation token | base64url (padded) of `<ulid>\|`, the ULID of the first tuple of the next page, found by reading `page_size + 1` (`token_serializer.go:25-35`, `read.go:118`); `''` on the last page, also when it is exactly full. Proto: at most 5,120 bytes and `^$\|^[A-Za-z0-9-_]+={0,2}$`, else 2000. Matching that but not decoding to the shape is 2007 `invalid_continuation_token` (`read.go:79-88`). A well-formed token for a ULID that doesn't exist seeks past it. Pages are in ULID order (insertion order). | the same, with `fga_tuples.seq` for the ULID: the token is base64url of `<seq>\|`, pages are in `seq` order, the next page starts at `seq >= token`. Treat the token as opaque. |

Read's return shape changed in phase 2 of session 5, an API break: it was `table(object, relation, user, inserted_at)`, every match unpaginated. It is now one row of `(tuples jsonb, continuation_token text)`, mirroring OpenFGA's ReadResponse; a tuple's `key` is the tuple key `fga_write` takes, so a page can be fed back as deletes. For rows: `select t #>> '{key,object}' from permissions.fga_read('document:1') r, jsonb_array_elements(r.tuples) t`.

`seq` is assigned at insert, so a transaction that commits after a reader has paged past its `seq` is missed by that walk. OpenFGA's ULID, assigned at write time, has the same property.

The RLS helpers (`fga_list_objects_current`, `fga_list_object_ids_current`) are **uncapped**: a cap there would silently hide rows a user may see. The list functions are split for this: `_fga_list_object_ids` and `_fga_list_users` are uncapped and internal; `fga_list_objects` and `fga_list_users` apply the cap; the RLS helpers call the uncapped one. A cap only truncates the output; the walk still computes the whole set.

Privileges (G2): clients get only the three current-subject FGA functions and the client-facing RBAC functions. Everything that takes an explicit user (`fga_check`, `fga_list_objects`, `fga_list_users`, `fga_read`) is admin-only, like every earlier design's explicit-subject functions: a client could otherwise ask what any user can access. The current-subject functions take no contextual tuples and no condition context, since a client could vouch for itself with them: a conditioned tuple counts there when its condition is true from its stored context alone, and an answer that depends on a condition that can't be evaluated is a deny, never an error ([`usage/rls.md`](../usage/rls.md), "Conditions in policies"). With no subject, no model yet, or a subject type the model doesn't define, they return false or nothing, so RLS denies instead of failing; an unknown object type or relation still raises.

## 5. Evaluation

A relation is **monotone** when neither it nor anything it depends on (computed relations, tupleset targets, usersets in its type restrictions) uses `intersection` or `difference`. Computed on model write from `fga_paths`.

- **Monotone relations** (all of stage 1, and the common case): Check is reachability in the positive graph. `_fga_bidi` is a bidirectional search, A's `check_for` generalized: forwards from the user (tuples whose user is a reached node, tupleToUserset parents, computed relations via `fga_computed_closure`), backwards from the object (usersets and tupleset parents in its tuples, relations it is computed from), each step expanding the smaller frontier, until they meet. ListUsers walks backwards from the object (`_fga_backward`).
- **ListObjects' forward walk** (`_fga_forward`) is one recursive CTE, A's `_reach` shape, over `fga_walk_steps` for the requested type and relation, compiled at model write. A step is one probe of `fga_tuples` (or the contextual tuples) that already yields the computed closure of its hit, so the recursive term is a single join. The steps are **pruned to the target**: only nodes that can reach the requested relation are produced (an empty folder list no longer walks every team and document the user reaches). The recursion only produces nodes with steps of their own toward the target; the leaves (in a wide walk, thousands of documents) come from one final join of the reached nodes, each at its lowest level, to the steps that yield the target. A node is a row per level it is reached at, so a node reached through paths of different lengths is expanded once per level and a cycle goes around until level 25, where the recursion stops expanding; below 25 every node's lowest level is exact. If an expandable node is first reached at level 25, the walk stopped short of what lies behind it: `_fga_forward_ids` (the same walk without levels, one row per node) finishes it, and any target found only there counts as 25 levels deep. `_fga_forward_ids` is also the candidate walk for non-monotone relations.
- **Other relations**: `_fga_rec` evaluates the rewrite tree the way OpenFGA's `LocalChecker.ResolveCheck` does: depth limit, cycle detection on the path, a userset user is in itself, `PathExists`, then `this` / `computedUserset` / `tupleToUserset` / `union` / `intersection` / `difference` with OpenFGA's rules for combining results (a branch error loses to a branch that decides; a cycle under a subtract makes the difference false). Every monotone subproblem, under a subtract or not, goes back to `_fga_bidi` (its least fixpoint; see Cycles), so the path only ever holds non-monotone relations. Check always uses `_fga_rec` for these relations.
- **ListObjects and ListUsers on `base but not subtract`, set-based.** When the base is a positive expression over monotone relations that doesn't include the relation itself (so the positive walk to the relation is exactly the base) and the subtract is `r` or `r from ts` with `r` monotone on every type it names (`fga_relations.diff_relation`, compiled), ListObjects is the walk to the relation minus the walk to the subtract (for `r from ts`, the objects whose `ts` is a parent the user reaches through `r`), and ListUsers is the backward walk from the object minus the backward walk from its subtract (a plain user is also removed by its type's wildcard). The results follow `_fga_rec`'s rules: a base 25 levels deep is an error unless the subtract removes it, a userset user always has its own relation. The subtract's walk decides membership exactly, but not the depth limit on a long subtract: if `r` can recurse (a relation it depends on is on a cycle) or depends on 24 relations or more, `diff_recheck` is set and only the objects (users) the subtract removes are checked one by one with `_fga_rec`, typically a handful. On the wide benchmark data this is 2.1 s → about 4 ms per ListObjects (`bench/baselines/D.md`, opt2).
- **Every other non-monotone relation** (an intersection, a union or nested subtract, a base that depends on a non-monotone relation): ListObjects and ListUsers take the candidates from the positive-graph walk (a superset: every true answer has a derivation that uses no subtract) and check each one with `_fga_rec`, without memoization (subproblems shared by candidates are re-evaluated).

**Depth**: OpenFGA's resolve node limit is 25. Following a userset tuple or a tupleToUserset costs one level; a computed relation and matching the user directly cost none (`dispatch` vs `ResolveCheck` in `internal/graph/check.go`). The walks track levels the same way. A Check or ListObjects answer that needs 25 levels or more raises 2002; ListUsers raises when its walk reaches a node 25 levels deep, as upstream does.

**Cycles**: OpenFGA marks a subproblem that is already being resolved higher up the same path as false-with-a-cycle. In a union that is just false, but under the subtract of a difference it makes the whole difference false (upstream cases `true_butnot_cycle_return_false`, `list_objects_with_subcheck_encounters_cycle`). `_fga_rec` carries the path and the flag. D applies that rule only to **recursion through negation**, a cycle through a non-monotone relation (a relation that reaches itself through a subtract, as in those upstream cases). A **monotone** relation, positively recursive or not, is evaluated by its least fixpoint wherever it appears, under a subtract too: a cycle of usersets contributes nobody. So for `define blocked: [user, document#blocked]` with `document:1#blocked@document:2#blocked`, `document:2#blocked@document:1#blocked` and no user, `blocked` is empty and `viewer: [user] but not blocked` holds for `user:jon` on `document:1`; Check, ListObjects and ListUsers agree (`test/spec/d/31_fga_cycles.sql`). This is a decision (session 4): before it, D followed OpenFGA's default strategy and answered false. OpenFGA v1.22.1 (the vendored suite's commit 44054f5, image `sha256:b852071314f1fda1194d341a6ebac0a4f619b3cd87a6626d2ccc7048af4ec671`, memory datastore) answers Check and ListObjects true for this model (its planner picks the recursive resolver, `UsersetUseRecursiveResolver`, which never reports a cycle), but its ListUsers on `document:1` returns nothing, and a control model that only adds an unused path to users (`blocked` also takes `team#member`, `team#member: [group#member]`, `group#member: [user]`, no team or group tuples) flips its Check to false. D answers the same for both models. Reported upstream: [`../upstream/openfga-cycle-but-not-inconsistency.md`](../upstream/openfga-cycle-but-not-inconsistency.md). The upstream suite has no cycle inside a monotone subtract, so both rules pass it.

## 6. Composing with RLS

`test/spec/d/40_rbac_fga_rls.sql`, condensed:

```sql
-- permissive: OR
create policy documents_select_rbac on documents for select to authenticated
    using (org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid)));
create policy documents_select_fga on documents for select to authenticated
    using (id = any (array(select permissions.fga_list_object_ids_current('document', 'viewer')::uuid)));
-- restrictive: AND
create policy documents_not_banned on documents as restrictive for select to authenticated
    using (org_id <> all (array(select permissions.fga_list_object_ids_current('org', 'banned')::uuid)));
-- per-row checks for single-row writes
create policy documents_update_rbac on documents for update to authenticated
    using (permissions.has_permission('documents.edit', org_id::text));
create policy documents_update_fga on documents for update to authenticated
    using (permissions.fga_check_current('editor', 'document:' || id));
```

Each list policy is one InitPlan per query. The spec checks the exact rows five users see: RBAC only, FGA only, both, an RBAC role overridden by an FGA ban, and nothing.

**The FGA list functions return `setof text`, not `text[]`, and need no `_unfolded_null()` argument.** PLAN §4's plan-time problem comes from `unnest(f())`: to estimate the unnest's row count the planner evaluates a STABLE `f` with constant arguments. A set-returning function is never evaluated at plan time; its estimate comes from `rows` (100 here). `test/spec/d/41_no_plan_time_eval.sql` pins it with the call-count probe of `22_no_plan_time_eval`: EXPLAIN doesn't run `fga_list_object_ids_current`, and a query runs it once. The RLS form is `id = any (array(select f(...)::uuid))`. `scopes_with_permission` keeps its `text[]` form and dummy argument because the shared specs pin both.

## 7. Errors

Invalid input raises where OpenFGA returns an error, with OpenFGA's numeric code in `DETAIL` as `openfga:<code> <name>`:

| SQLSTATE | DETAIL | When |
| --- | --- | --- |
| `22023` | `openfga:2000 validation_error` | Check: malformed or unknown user, object, relation. ListObjects: invalid user. Write: malformed delete key, bad `on_duplicate`/`on_missing`, an empty `writes` or `deletes` list. Read: `page_size` outside 1..100, a token outside the base64url pattern or over 5,120 bytes. |
| `22023` | `openfga:2001`, `2020` | unknown model id; no model written yet |
| `54001` (statement_too_complex) | `openfga:2002 authorization_model_resolution_too_complex` | depth 25 (section 5) |
| `22023` | `openfga:2003`, `2004`, `2017` | a write with neither writes nor deletes; the same tuple twice in one request; writing a tuple that exists or deleting one that doesn't |
| `22023` | `openfga:2007 invalid_continuation_token` | a Read token that matches the pattern but doesn't decode to a position |
| `22023` | `openfga:2021 type_not_found`, `2022 relation_not_found` | ListObjects and ListUsers: unknown type or relation in the request or a filter |
| `22023` | `openfga:2027 invalid_tuple` | a written or contextual tuple the model doesn't allow (unknown type or relation, user type not in the restrictions, wildcard or userset where not allowed, wildcard or userset on a tupleset relation) |
| `22023` | `openfga:2053 exceeded_entity_limit` | a Write of more than 100 tuple keys (section 4, Limits) |
| `22023` | `openfga:2047 type_invalid_pattern`, `2050 relations_invalid_pattern` | model: a type or relation name that doesn't match OpenFGA's pattern (the request's validation) |
| `22023` | `openfga:2056 invalid_authorization_model` | model: anything OpenFGA's `typesystem.NewAndValidate` rejects: a type defined twice, `self` or `this` as a name, an undefined type or relation in a rewrite or type restriction, a bad tupleset, a direct relation without type restrictions (or the reverse), a relation with no entrypoint, a cycle of computed relations, schema version 1.0 |
| `22023` | `openfga:2000`, `2057` | model: a schema version other than 1.0, 1.1 and 1.2 (2000, the request's validation); 1.2 (modular models), which OpenFGA accepts and this extension doesn't (2057) |
| `22023` | `openfga:2056 invalid_authorization_model` | model: a condition that doesn't compile (syntax, an undeclared name, no matching overload, not a bool, an unknown parameter type or a missing generic, a key that differs from the name), a restriction naming an undefined condition, and what pg_permissions' CEL leaves out (bytes, `type()`, `dyn()`) |
| `22023` | `openfga:2000 validation_error` | model: a condition name, expression size (512 bytes) or parameter count (25) outside the request's limits, an inline `$expression` condition; Write: a tuple's condition undefined, not allowed for its facet, missing where only conditioned restrictions exist, or a context key or value that doesn't fit; Check, ListObjects, ListUsers: a `context` that is not a JSON object, a condition that can't be evaluated (missing parameter, wrong type, evaluation error, cost limit) |

The `rbac_*` functions raise with no DETAIL: `23505` a role that exists, `22023` an unknown role or a role name that is also a permission, `2BP01` dropping a role another role inherits, `22004` `assign_role` with a null user.

The SQLSTATE says what kind of failure it is to any Postgres client; the DETAIL is the machine-checkable OpenFGA code (PostgREST returns it as `details`). The order of validation follows OpenFGA's, so the same request gets the same code: Check validates user, object, relation, then contextual tuples; ListObjects contextual tuples, then type and relation, then user; ListUsers contextual tuples, filters, then the target; Write the options, the lists, the model, each tuple, duplicates, then the size.

**Messages and hints** (DECISION.md, end of session 4, point 5). The MESSAGE names the offending values: the type, relation, user string, tuple, model id, count or token. Where OpenFGA has a message for the case it is kept as the start of ours (`The number of write operations exceeds the allowed limit of 100`, `Authorization Model '<id>' not found`). Every error, `rbac_*` included, has a non-empty HINT that says how to fix it:

| Error | HINT |
| --- | --- |
| an unknown type, relation or role | the nearest existing name, if one is within a third of the input's length (1 to 3 edits), then the list (at most 20): `Did you mean 'viewer'? Relations on type 'document': editor, parent, viewer.` |
| a tuple whose user type the relation doesn't allow (2027) | the allowed user types: `'document#editor' allows users of type: user.` |
| an unknown model id (2001) | the valid ids, newest first (at most 10) |
| no model yet (2020), no roles yet | the call to make first: `fga_write_authorization_model(...)`, `create_role(...)` |
| 2017, 2053, 2003, Read's token and page size | the option or call that fixes it: `on_duplicate`/`on_missing` `ignore`, batches of at most 100, the default page size, pass the token back unchanged |
| a malformed user, object or tuple key | the expected form, with an example |

The nearest name uses a Levenshtein distance written in PL/pgSQL (`_edit_distance`, case-insensitive): the extension stays plain SQL and PL/pgSQL for pg_tle, so no `fuzzystrmatch` or `pg_trgm`. Hints are computed only on the error path.

`test/spec/d/35_error_hints.sql` triggers every raise site (68: 7 in `rbac_*`, 61 calls of `_fga_error`; until phase 4 there were also 3 calls of `_fga_unsupported`, the 0A000 helper, now removed), one row each with the statement, SQLSTATE, DETAIL, a pattern for the MESSAGE and, for most, the HINT. A guard scans the function bodies in `pg_proc.prosrc` and fails if any `raise` or error-helper call passes no hint, or if the number of raise sites differs from the number of rows, so a new raise site needs a hint and a row. `_fga_error` takes the hint as a required argument. Removing one hint fails the guard and that site's row (checked on a copy of the extension, one `_fga_error` call and one `rbac_*` raise).

## 8. Deviations from OpenFGA

Deliberate:

1. **One implicit store per database.** No CreateStore/ListStores/store ids; `fga_delete_store()` clears the one store. A second store would be a second database or schema.
2. **Conditions, with a PL/pgSQL CEL evaluator** ([`d-conditions.md`](./d-conditions.md); since phase 4 of session 5). Where it differs from OpenFGA: inline `$expression` conditions are refused (2000, as the default server); `bytes`, `type()` and `dyn()` are refused at model write; the cost limit is approximate (a counter of nodes and iterations, limit 100); a stored context the current model no longer accepts is ignored in ListObjects and ListUsers as in Check (OpenFGA's lists fail with 2000); the RLS helpers get no request context and deny when an answer depends on a condition error; timestamps are microseconds; double overflow and division by zero are errors (CEL: infinities); `matches` uses Postgres regular expressions; IPv6 zones are refused; in a value of type `any` (JSON), and in a list or map literal of mixed types, numbers are doubles. The full list, with the reasons, is in [`d-conditions.md`](./d-conditions.md) section 13.
3. **Errors are Postgres exceptions** (section 7), not gRPC/HTTP statuses.
4. **Limits are OpenFGA's defaults, fixed, with no deadline** (section 4, Limits). ListObjects and ListUsers return at most 1,000, Write takes at most 100 tuple keys and Read is paginated, as OpenFGA does; but the limits can't be configured, and there is no ListObjects/ListUsers deadline (OpenFGA: 3 s, then partial results): use `statement_timeout`, which raises instead of returning part of the list. The RLS helpers are uncapped. ReadAuthorizationModels isn't paginated, and models have no size or type-count limit.
5. **Consistency is Postgres's**: every read uses the statement's snapshot, so there is no `consistency` parameter and no cache.
6. **The current-subject functions take no contextual tuples** and deny instead of raising when the subject or the model is missing (section 4).
7. **Strings, not structured users**: ListUsers returns `type:id#relation` strings, not `User` objects, and no `excluded_users`.

Simplifications that could differ from OpenFGA in corner cases, none of them hit by the suite:

8. **Model validation follows OpenFGA v1.22.1's `typesystem.NewAndValidate`** (since phase 3 of session 5), with the server's error codes (section 7): names and duplicate types, unknown types and relations in rewrites and restrictions, tupleset relations (direct, plain types only, the computed relation defined on at least one of them), `this` iff type restrictions, every relation has an entrypoint (`hasEntrypoints`, computed here as a least fixpoint over the rewrite nodes: `this` needs a plain type, a wildcard or a userset whose relation has one; a union needs one child, an intersection and a difference every child), and no cycle of computed relations on a type, through any operator, even when each has a type restriction (`HasCycle`). openfga/language's validation cases are the oracle (section 9). Known differences, none of which the DSL transformer produces: a union or intersection with one child (OpenFGA rejects it when its entrypoint search reaches that node; D accepts it), a type restriction with an empty relation (`{"type": "user", "relation": ""}`: OpenFGA 2056, D reads it as `user`), an empty `type_definitions` (OpenFGA 2045 `type_definitions_too_few_items`, D 2056), and OpenFGA's model size and type-count limits (deviation 4). Before phase 3 a type defined twice was 2005 and a schema version other than 1.1 was 2057; OpenFGA's WriteAuthorizationModel returns neither (`pkg/server/commands/write_authzmodel.go:84-86` maps every validation error to 2056).
9. **Depth on false answers**: a Check on a monotone relation that is false is false, even where OpenFGA's top-down search would have hit depth 25 on some irrelevant branch and returned 2002. This now includes a monotone relation under a subtract. When the true answer needs 25 levels or more the result matches (2002). In `_fga_bidi` the depth of the first meeting point is used; a shorter path found later would not change a 2002 back to true.
10. **Malformed delete keys** raise 2000 for any field (OpenFGA checks only the user's format). Until phase 2 of session 5 a malformed user or object in a delete gave 2017 instead (the check counted the rows of a function that always returns one); `d/35_error_hints` found it.
13. **Read's filter** is any combination of `p_object` (`type:id` or `type:`), `p_relation` and `p_user`, or none. OpenFGA requires the object type and either the object id or the user when a tuple key is given (2000 otherwise).
11. Not implemented: Expand, BatchCheck, StreamedListObjects, ReadChanges, assertions, the modular-model (`fga.mod`) format and its schema version 1.2 (2057).
12. **A cycle inside a monotone subtract** contributes nobody (least fixpoint), in Check, ListObjects and ListUsers alike. OpenFGA v1.22.1 answers true in Check and ListObjects when its recursive resolver applies, false when an unused path in the model rules that resolver out, and nothing in ListUsers. Recursion through negation keeps OpenFGA's cycle rule. Section 5.

## 9. Testing

### OpenFGA's suite as an oracle

[`test/fga/`](../test/fga/): `vendor.sh` clones openfga/openfga at a pinned commit into an empty temp directory, copies `assets/tests/consolidated_1_1_tests.yaml`, its LICENSE and a SOURCE file (Apache-2.0 attribution), converts each stage's DSL model to JSON with the official transformer (the `openfga/cli` Docker image, pinned by digest, no network), and writes `cases.json`. Nothing from the clone is executed. `generate.py` (run with `python3 -I`) turns the cases into TAP files under `test/spec/d/` (`60_fga_oracle_*`, `61_fga_oracle_ctx_*`), so `test/run.sh` and the Docker matrix run them unchanged. Each upstream assertion is one TAP test named `<mode>:<case>:s<stage>:<check|lo|lu><index>`. Like upstream's harness, the list assertions also check every returned object or user with Check. `skip.tsv` lists cases not run with a reason; `generate.py report <run.sh -v output>` tallies the results.

Two runs, as upstream does: **stored** (each stage writes its model and tuples; stages of a case share the store) and **contextual** (single-stage cases with at most 100 tuples: nothing is written, every tuple is sent as a contextual tuple).

| Run | Cases | Assertions | Passed | Skipped |
| --- | --- | --- | --- | --- |
| stored | 138 | 933 | 933 | 0 |
| contextual | 116 | 746 | 746 | 0 |

The other 22 cases are multi-stage, which upstream doesn't run with contextual tuples either. Upstream has 138 cases (22 multi-stage; one case name appears twice, the second is reported as `immediate_cycle_through_computed_userset~2`); 59 use `intersection` or `but not`. No case uses conditions or modular models.

Mutants confirm the suite bites: ignoring wildcards fails 13 assertions, no depth limit 2, ignoring the subtract of a difference 159, ignoring the cycle flag under a subtract 4, treating a cycle as true in an intersection 8. Using the set-based search for monotone relations under a subtract too (losing the cycle flag) fails nothing in the suite, which has no cycle inside a monotone subtract; D now does exactly that (section 5), and `d/31_fga_cycles` pins the answer. Ignoring the subtract in the set-based ListObjects and ListUsers fails 37 suite assertions (both subtract forms, wildcards, contextual tuples); dropping ListObjects' depth check or its finish-the-walk-behind-level-25 step fails nothing upstream; `d/33` and `d/32` catch them (7 and 4 assertions).

### openfga/language's validation cases as an oracle

[`test/fga_lang/`](../test/fga_lang/): `vendor.sh` fetches openfga/language at `f558baa` (tag `pkg/go/v0.3.2`, the language version both openfga v1.22.1 and openfga/cli v0.8.2 require) into an empty temp directory, copies `tests/data/dsl-semantic-validation-cases.yaml` with its LICENSE and a SOURCE file, converts each case's DSL to JSON with the same pinned CLI image (the transformer validates nothing, so every case converts), and also writes each JSON model to OpenFGA v1.22.1's own server (the pinned `openfga/openfga` image, memory datastore) and records its answer. `generate.py` writes `test/spec/d/62_fga_lang_oracle.sql`: a case with no expected errors must be accepted; one with expected errors must be rejected with the code the server returned and a non-empty HINT. Messages aren't compared (they are the language library's). The generator refuses a case whose expectation the server contradicts unless `skip.tsv` lists it.

| Cases | Run | Passed | Skipped |
| --- | --- | --- | --- |
| 93 | 70 (4 accepted, 66 rejected: 60 with 2056, 4 with 2000, one each 2047 and 2050) | 70 | 23: 16 `server-accepts` (duplicate type restrictions and operands, and unused conditions, which the language validator flags and the server accepts), 2 `inline-expression` (`$expression` conditions, which the server refuses without its feature flag, as does this extension), 2 `schema-1.2` (modular models), 3 `upstream-skip` (skipped by upstream's harness; they expect acceptance and the server rejects them as cycles) |

Until phase 4 the 8 condition cases were all skipped and 66 ran; 4 of them now run (three undefined conditions and a duplicate type next to a condition).

Before phase 3, 33 of the 66 passed. Four cases marked `skip: true` upstream are run, since the server agrees with their expectation (rejection): they are the only oracle cases that catch the cycle check. Mutants, each new check disabled on a copy of the extension (failed assertions: oracle cases / `d/36` / `d/35` / `d/30`): no entrypoint check 11 / 6 / 1 / 0; intersection and difference treated like a union in the entrypoint fixpoint 4 / 2 / 0 / 0; no cycle check 4 / 4 / 10 / 0; the cycle check ignoring subtracts 1 / 1 / 0 / 0; no reserved type names 3 / 2 / 11 / 0; no reserved relation names 3 / 1 / 1 / 0; schema versions always 2057 4 / 3 / 1 / 1; a duplicate type as 2005 2 / 1 / 1 / 1; name patterns as 2056 2 / 3 / 2 / 0. In `d/35` the 10 and 11 include rows that fail only because the model it expected refused was accepted and became the latest. The stricter validator rejects no model in the consolidated suite (933/933 and 746/746 still pass) and none of the benchmark's.

### OpenFGA's ABAC (conditions) suite as an oracle

[`test/fga_abac/`](../test/fga_abac/): `abac_tests.yaml` from the same commit, vendored and generated the same way (`63_fga_abac_*`, `64_fga_abac_ctx_*`), with a request `context` on assertions and conditions on tuples ([`d-conditions.md`](./d-conditions.md) section 1). `probe.sh` asks the pinned server what the cases don't pin (P1 to P44), and the in-house specs pin those answers.

| Run | Cases | Assertions | Passed | Skipped |
| --- | --- | --- | --- | --- |
| stored | 33 | 331 | 302 of 302 run | 9 cases, 29 assertions: `inline-expression` |
| contextual | 30 | 300 | 271 of 271 run | the same 9 |

The 8 openfga/language cases that were skipped as `conditions` now run where the server and the expectation agree (4: three undefined conditions and a duplicate type next to a condition) and stay skipped where they don't (2 unused conditions the server accepts, 2 inline expressions it refuses): 70 of 70 run, 23 skipped. Mutants, each on a copy of the extension (failed assertions: abac stored / contextual / in-house specs `d/35`, `d/37`, `d/38`, `d/39`, `d/90_usage_conditions`, `d/90_usage_rls`): ignore the condition 148 / 140 / 1, 0, 55, 20, 9, 2; a missing parameter as false 60 / 60 / 1, 0, 1, 11, 4, 0; the request's context wins over the tuple's 18 / 18 / 0, 0, 16, 6 (and 10 not run), 1 (and 11 not run), 1; no type check of context values 10 / 10 / 0, 0, 32, 2, 0 (5 not run), 0 (1 not run); no type check of operators at model write 0 / 0 / 10, 3, 0, 0, 3, 0; Check without OpenFGA's error rule (errors are false) 27 / 27 / 1, 0, 39, 4, 3, 0; the `conditional` flag never set 123 / 119 / 1, 2, 39, 18, 4, 2; always set 0 / 0 / 0, 3 (the flag's own assertions), 0, 0, 0, 0: the always-conditional path gives the same answers, only slower.

### Other specs

- Shared specs (`test/spec/*.sql`): all pass unchanged.
- `d/30_fga_api`: writes and their errors, model validation and versioning (an old model id still evaluates with that model; tuples a newer model doesn't allow are ignored but can be deleted), Read, the current-subject functions, privileges, `delete_subject`.
- `d/34_fga_limits`: the limits (section 4): 1,050 objects and users against the 1,000 cap (count, no duplicates, each in the uncapped set) while the RLS helpers return all 1,050; Write at 100 and 101 tuple keys, writes and deletes counted together, duplicates before the count, empty lists; Read walked page by page (every tuple once, in insertion order, an exactly full last page, filters), page sizes, bad tokens (2000, 2007), a token whose tuple was deleted.
- `d/35_error_hints`: every raise site with its SQLSTATE, DETAIL, MESSAGE and HINT, and the `prosrc` guard (section 7).
- `d/36_fga_model_validation`: the entrypoint and cycle checks and the model error codes, each case checked against the OpenFGA v1.22.1 image (deviation 8).
- `d/37_fga_conditions_model`: conditions at model write: accepted, stored and compiled; refused with 2056 or 2000 as OpenFGA (P1 to P4, P33 to P37), and what pg_permissions' CEL leaves out; restriction and edge rows per condition; the `conditional` flag; a tuple whose condition a new model doesn't allow is ignored on the unconditioned path.
- `d/38_fga_cel`: the CEL language through the API, 142 expressions (literals, operators, strings, conversions, timestamps and durations, macros, ip addresses, error absorption, OpenFGA's context conversions, the cost limit, parameters), each against the probed server where it answered.
- `d/39_fga_conditions_eval`: Write, Read and Delete with conditions; contextual tuples; the error rule per API (P14 to P16); `but not` and `and` with condition errors; the RLS helpers; Check, ListObjects and ListUsers agreeing on 96 questions; one evaluation per distinct context; stale contexts (P28 to P30).
- `d/90_usage_fga`, `d/90_usage_conditions`, `d/90_usage_rls`: every example in `usage/fga.md`, `usage/conditions.md` and `usage/rls.md`.
- `d/31_fga_cycles`: a userset cycle inside a monotone subtract contributes nobody (least fixpoint), with a control model that OpenFGA answers differently, a cycle that does block a user, and the cycle broken (section 5).
- `d/32_fga_set_based`: set-based `but not` ListObjects and ListUsers against Check (one `_fga_rec` per object or user) and against the per-candidate path on the same store, for computed and tupleToUserset subtracts, recursive subtracts (rechecked, including one too deep), a cyclic base, wildcards, userset users, contextual tuples and the depth limit; and which relations compile to the set-based form.
- `d/33_fga_walk_pruning`: the pruned forward walk against Check for every relation of a model with several targets, cycles, a wildcard, tupleToUserset and userset users; the depth limit at 24/25 levels, for a userset user, and behind the level-25 stop.
- `d/40_rbac_fga_rls`: one table, RBAC and FGA policies (section 6).
- `d/41_no_plan_time_eval`: the FGA list functions are STABLE, not run while planning, run once per query.

## 10. Performance notes (written before benchmarking; measured in [`bench/baselines/D.md`](../bench/baselines/D.md))

The second pass (opt2) acted on that diagnosis: the forward walk is now one recursive CTE over compiled, target-pruned steps, and `but not` lists are set-based (section 5). The notes below are the original ones; the ListObjects and non-monotone items describe the opt version.

What to watch in the benchmark:

- **Check on monotone relations** is A's bidirectional search; each step is one PL/pgSQL call (`_fga_fstep`/`_fga_bstep`) with a 4-way `union all` (stored and contextual tuples, direct and tupleToUserset edges) joined to `fga_edges`. With no contextual tuples the `unnest('{}')` branches are empty but still planned. A's version had 3 branches and no edge join.
- **ListObjects** for RLS is a forward walk in a PL/pgSQL loop with array frontiers and a visited set (`not exists` over `unnest`). A's `_reach` was one recursive CTE. Wide users (thousands of objects) pay for growing arrays each step.
- **Non-monotone relations** (`and`, `but not`) run `_fga_rec`: one PL/pgSQL call per subproblem, two or three statements each, no memoization within a request. Top-down, so a userset fan-out (a group with many nested subgroups) is walked group by group. ListObjects/ListUsers on such relations check every candidate. This is the path to optimize if exclusions are common (for example a set-based difference when the subtract is monotone).
- Every call resolves the latest model (`order by seq desc limit 1`, an index probe) and re-validates the object type and relation.
- No memberships or closures are materialized: writes are one row (`fga_write` validates each tuple against the model, a few index probes). C's materialized memberships remain the option if wide reads need them.

## 11. Choices to review

1. **List functions return `setof text`.** It removes the dummy argument from the FGA RLS functions (section 6). `fga_list_objects` returns OpenFGA's `type:id`; for RLS there is `fga_list_object_ids_current` with bare ids, so policies cast without string surgery. Alternatively one function with a flag, or only ids.
2. **Error encoding**: two SQLSTATEs plus `DETAIL 'openfga:<code> <name>'`. Alternatives: one custom SQLSTATE class per OpenFGA code (machine-checkable without DETAIL, but unfamiliar to clients), or the code in the message.
3. **Model versioning**: models are immutable and the latest wins; old ids keep working. No way to pin "the model the app expects" other than passing the id. Tuples are never migrated; ones a new model rejects are ignored until deleted.
4. **Current-subject functions deny on a missing subject type** and take no contextual tuples (section 4). OpenFGA itself would raise for an unknown user type.
5. **`delete_subject` spans both models.** Per-model cleanup functions (`rbac_forget_user`, `fga_delete_tuples_for`) would fit the per-model principle better; it is kept for the shared usage spec.
6. **Monotone fast path**: two evaluators that must agree. The suite passes through both (59 cases go through `_fga_rec`), but a change to one should be run against the whole suite. Set-based `but not` lists add a third (`d/32` compares it with the other two).
7. **Least fixpoint for positive recursion under a subtract** (section 5): decided in session 4. D differs from OpenFGA's default strategy, and agrees with OpenFGA v1.22.1's Check and ListObjects only when its recursive resolver applies.
8. **Compiled walk steps per target relation** (`fga_walk_steps`): rows grow with relations x reachable steps, per model version. Tiny for the benchmark model (13 rows); a model with hundreds of interlinked relations would store more.
9. **Fixed limits** (section 4, phase 2 of session 5): OpenFGA's defaults as constants in `_fga_limits()`, not settings. A GUC per limit would be the configurable alternative. The cap truncates the output only; the walk still computes every result, so it bounds the response, not the work.
10. **Read returns one row of `(tuples jsonb, continuation_token text)`**, OpenFGA's ReadResponse, rather than rows with the token repeated on each. Rows read more naturally in SQL (`jsonb_array_elements` is needed now); the JSON keeps one token per page and round-trips into `fga_write`. Its filter arguments keep the `p_` prefix because an output column is named `continuation_token`.
11. **`fga_tuples.seq`** for Read's order: an identity column and a unique index on every tuple (8 bytes plus an index entry, written on every insert), for a function the RLS path never calls. Paginating on the primary key instead would need no column but give key order, not OpenFGA's insertion order, and a token encoding the six-column key.
