# Design D: Per-model tables (`rbac_*` and OpenFGA `fga_*`)

> Status: prototype, [`prototypes/d-per-model.sql`](../prototypes/d-per-model.sql). Built in session 4 after the direction change in [`PLAN.md`](../PLAN.md) ("Current plan (session 4): per-model tables") and [`DECISION.md`](../DECISION.md) ("Session 4 direction"). Passes every shared spec unchanged and OpenFGA's own consolidated test suite: all 138 cases, 933 assertions with stored tuples and 746 with contextual tuples (section 9). Benchmarked (unoptimized) against A, B and C in [`bench/baselines/D.md`](../bench/baselines/D.md).

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
| `fga_types`, `fga_relations` | the model's types and relations; a relation records `monotone` and `is_tupleset` |
| `fga_type_restrictions` | `directly_related_user_types`: (type, relation) allows (user_type, user_relation, wildcard) |
| `fga_rewrite_nodes` | each relation's rewrite tree in preorder: `this`, `computed`, `ttu`, `union`, `intersection`, `difference`; `in_subtract` marks the subtract side of a difference |
| `fga_edges` | the positive graph (every operand except a subtract) as edges between (type, relation) pairs: `d` a direct tuple, `c` a computed relation on the same object, `t` a tupleToUserset |
| `fga_computed_closure` | transitive closure of the `c` edges |
| `fga_paths` | OpenFGA's `PathExists`: which user types (`user`, `user:*`, `group#member`) each relation can reach through any operand |
| `fga_tuples` | the tuples: (object_type, object_id, relation, user_type, user_id, user_relation); user_id `*` is a typed wildcard, user_relation is `''` unless the user is a userset. Primary key in that order; a second index on (user_type, user_id, user_relation, object_type, relation). |

Everything but `fga_tuples` is written once by `fga_write_authorization_model`, which validates the JSON and compiles it. No check reads JSON. Tuples don't belong to a model: like OpenFGA, every read joins them with the type restrictions of the model in use, so tuples left over from an earlier model that no longer type-check are ignored (upstream case `check_with_invalid_tuple_in_store`).

## 3. RBAC API

Unchanged from PLAN.md §6 and design A: `create_role`, `drop_role`, `assign_role`, `unassign_role` (admin only); `has_permission`, `has_role`, `scopes_with_permission(permission, p_unfold boolean default _unfolded_null())` (clients and RLS); `user_permissions`, `users_with_role` (admin). Same error codes as A (23505, 22023, 2BP01). `delete_subject(type, id)` removes a subject from both models (its assignments and every tuple naming it as user or object), with A's signature so `90_usage_rbac`'s cleanup step finds it.

## 4. OpenFGA API

Strings use OpenFGA's forms: objects `type:id`, users `type:id`, `type:*` or `type:id#relation`. Tuple keys are OpenFGA's JSON `{"user", "relation", "object"}`. Every function takes an optional `authorization_model_id`; without it the latest model is used.

| OpenFGA endpoint | SQL | Notes |
| --- | --- | --- |
| WriteAuthorizationModel | `fga_write_authorization_model(model jsonb) returns text` | The body of the request: `{schema_version: "1.1", type_definitions, conditions}` as `fga model transform --output-format json` prints it. Returns the new ULID; it becomes the latest. |
| ReadAuthorizationModel(s) | `fga_read_authorization_model(id default null) returns jsonb`, `fga_read_authorization_models() returns table(id, created_at)` | |
| Write | `fga_write(writes jsonb, deletes jsonb, authorization_model_id)` | Each side an array of tuple keys, or `{"tuple_keys": [...], "on_duplicate": "ignore"}` / `{"tuple_keys": [...], "on_missing": "ignore"}`. One transaction. |
| (convenience) | `fga_write_tuple(user, relation, object)`, `fga_delete_tuple(user, relation, object)` | Idempotent: `on_duplicate`/`on_missing` ignore. |
| Read | `fga_read(p_object, p_relation, p_user) returns table(object, relation, user, inserted_at)` | `p_object` may be `type:` for every object of a type. |
| Check | `fga_check(user, relation, object, contextual_tuples jsonb, authorization_model_id) returns boolean` | |
| ListObjects | `fga_list_objects(user, type, relation, contextual_tuples, authorization_model_id) returns setof text` | `type:id` strings, unordered, all of them (no 1,000 cap). |
| ListUsers | `fga_list_users(object, relation, user_filters text[], contextual_tuples, authorization_model_id) returns setof text` | Filters `'user'` or `'group#member'`. Returns `type:id`, `type:*`, `type:id#relation`. |
| DeleteStore | `fga_delete_store()` | Every model and tuple of the one store. |
| (current subject) | `fga_check_current(relation, object)`, `fga_list_objects_current(type, relation)`, `fga_list_object_ids_current(type, relation)` | Clients and RLS. The user is `current_subject_type():current_subject_id()`. |

Contextual tuples are an array of tuple keys or OpenFGA's `{"tuple_keys": [...]}`. They are validated like writes (2027) and behave exactly like stored tuples, including in the walks.

Privileges (G2): clients get only the three current-subject FGA functions and the client-facing RBAC functions. Everything that takes an explicit user (`fga_check`, `fga_list_objects`, `fga_list_users`, `fga_read`) is admin-only, like every earlier design's explicit-subject functions: a client could otherwise ask what any user can access. The current-subject functions take no contextual tuples, since a client could vouch for itself with them. With no subject, no model yet, or a subject type the model doesn't define, they return false or nothing, so RLS denies instead of failing; an unknown object type or relation still raises.

## 5. Evaluation

A relation is **monotone** when neither it nor anything it depends on (computed relations, tupleset targets, usersets in its type restrictions) uses `intersection` or `difference`. Computed on model write from `fga_paths`.

- **Monotone relations** (all of stage 1, and the common case): Check is reachability in the positive graph. `_fga_bidi` is a bidirectional search, A's `check_for` generalized: forwards from the user (tuples whose user is a reached node, tupleToUserset parents, computed relations via `fga_computed_closure`), backwards from the object (usersets and tupleset parents in its tuples, relations it is computed from), each step expanding the smaller frontier, until they meet. ListObjects walks forwards from the user (`_fga_forward`), ListUsers backwards from the object (`_fga_backward`). Only nodes with an outgoing edge in the compiled model are ever expanded, so a document reached by a walk is a leaf (A's `expandable`, for free).
- **Other relations**: `_fga_rec` evaluates the rewrite tree the way OpenFGA's `LocalChecker.ResolveCheck` does: depth limit, cycle detection on the path, a userset user is in itself, `PathExists`, then `this` / `computedUserset` / `tupleToUserset` / `union` / `intersection` / `difference` with OpenFGA's rules for combining results (a branch error loses to a branch that decides; a cycle under a subtract makes the difference false). Monotone subproblems outside a subtract go back to `_fga_bidi`. ListObjects and ListUsers on such relations take the candidates from the positive-graph walk (a superset: every true answer has a derivation that uses no subtract) and check each one.

**Depth**: OpenFGA's resolve node limit is 25. Following a userset tuple or a tupleToUserset costs one level; a computed relation and matching the user directly cost none (`dispatch` vs `ResolveCheck` in `internal/graph/check.go`). The walks track levels the same way. A Check or ListObjects answer that needs 25 levels or more raises 2002; ListUsers raises when its walk reaches a node 25 levels deep, as upstream does.

**Cycles**: OpenFGA marks a subproblem that is already being resolved higher up the same path as false-with-a-cycle. In a union that is just false, but under the subtract of a difference it makes the whole difference false (upstream cases `true_butnot_cycle_return_false`, `list_objects_with_subcheck_encounters_cycle`). `_fga_rec` carries the path and the flag. The set-based walks compute the least fixpoint instead, which is the same answer whenever the flag can't matter, so they are only used for monotone relations outside a subtract. One difference, verified: for a recursive userset (`define blocked: [user, document#blocked]`) OpenFGA's planner (`UsersetUseRecursiveResolver`) picks its recursive resolver, which never reports a cycle, so OpenFGA answers a cycle inside a subtract true where D answers false. Run against openfga/openfga v1.22.1 (the vendored suite's commit 44054f5, image `sha256:b852071314f1fda1194d341a6ebac0a4f619b3cd87a6626d2ccc7048af4ec671`, memory datastore) with the model and tuples of `test/spec/d/31_fga_cycles.sql`: Check `viewer` on `document:1` is true in 600+ runs over fresh containers, with default settings and with `enable-check-optimizations` (no flag selects the resolver; the planner is a Thompson sampler whose cold-start priors, 150 ms for recursive against 500 ms for default, make it pick recursive until recursive runs slower than the default's prior). ListObjects returns `document:1` and `document:3` (D: `document:3`), ListUsers on `document:1` returns nothing (as D), so OpenFGA disagrees with itself between Check and ListUsers. `blocked` alone is false and `document:3` is true, as in D. A control model where the recursive resolver doesn't apply (`blocked` also takes `team#member`, which reaches users through `group#member`, a second weight for `user`) answers false, which is what D computes. D keeps the default strategy and `d/31_fga_cycles` pins D's answer, not OpenFGA's. Matching OpenFGA would mean detecting the same condition as `UsersetUseRecursiveResolver` (the subtracted relation is self-recursive through a userset and every other entry for that user type has weight 1) and evaluating that subproblem by the set-based least fixpoint (no cycle flag) inside `_fga_rec`; ListObjects would follow, ListUsers would need to return the viewer. The upstream suite has no such case.

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
| `22023` | `openfga:2000 validation_error` | Check: malformed or unknown user, object, relation. ListObjects: invalid user. Write: malformed delete key, bad `on_duplicate`. |
| `22023` | `openfga:2001`, `2020` | unknown model id; no model written yet |
| `54001` (statement_too_complex) | `openfga:2002 authorization_model_resolution_too_complex` | depth 25 (section 5) |
| `22023` | `openfga:2003`, `2004`, `2017` | empty write; the same tuple twice in one request; writing a tuple that exists or deleting one that doesn't |
| `22023` | `openfga:2021 type_not_found`, `2022 relation_not_found` | ListObjects and ListUsers: unknown type or relation in the request or a filter |
| `22023` | `openfga:2027 invalid_tuple` | a written or contextual tuple the model doesn't allow (unknown type or relation, user type not in the restrictions, wildcard or userset where not allowed, wildcard or userset on a tupleset relation) |
| `22023` | `openfga:2005`, `2056`, `2057` | model: a type defined twice; invalid model; schema version other than 1.1 |
| `0A000` | `pg_permissions:conditions_not_supported` | a condition on a tuple, a type restriction or the model |

The SQLSTATE says what kind of failure it is to any Postgres client; the DETAIL is the machine-checkable OpenFGA code (PostgREST returns it as `details`). The order of validation follows OpenFGA's, so the same request gets the same code: Check validates user, object, relation, then contextual tuples; ListObjects contextual tuples, then type and relation, then user; ListUsers contextual tuples, filters, then the target.

## 8. Deviations from OpenFGA

Deliberate:

1. **One implicit store per database.** No CreateStore/ListStores/store ids; `fga_delete_store()` clears the one store. A second store would be a second database or schema.
2. **No conditions yet** (stage 2 of the plan, CEL in SQL). A condition anywhere raises `0A000`.
3. **Errors are Postgres exceptions** (section 7), not gRPC/HTTP statuses.
4. **No limits and no pagination**: ListObjects and ListUsers return every result (OpenFGA caps them at 1,000 by default and has a deadline), Read and the model list aren't paginated, Write takes any number of tuples (OpenFGA: 100), and models have no size or type-count limit.
5. **Consistency is Postgres's**: every read uses the statement's snapshot, so there is no `consistency` parameter and no cache.
6. **The current-subject functions take no contextual tuples** and deny instead of raising when the subject or the model is missing (section 4).
7. **Strings, not structured users**: ListUsers returns `type:id#relation` strings, not `User` objects, and no `excluded_users`.

Simplifications that could differ from OpenFGA in corner cases, none of them hit by the suite:

8. **Model validation is a subset**: type and relation names, unknown types and relations in rewrites and restrictions, tupleset relations (direct, plain types only, the computed relation defined on at least one of them), `this` iff type restrictions. Not checked: relations with no entrypoint (`define a: b`, `define b: a`) and OpenFGA's other graph checks. Such a model is accepted and its relations are simply never satisfied.
9. **Depth on false answers**: a Check on a monotone relation that is false is false, even where OpenFGA's top-down search would have hit depth 25 on some irrelevant branch and returned 2002. When the true answer needs 25 levels or more the result matches (2002). In `_fga_bidi` the depth of the first meeting point is used; a shorter path found later would not change a 2002 back to true.
10. **Malformed delete keys** raise 2000 for any field (OpenFGA checks only the user's format).
11. Not implemented: Expand, BatchCheck, StreamedListObjects, ReadChanges, assertions, the modular-model (`fga.mod`) format.
12. **A cycle inside a monotone subtract** is always false-with-cycle (OpenFGA's default strategy). For a recursive userset OpenFGA v1.22.1 picks its recursive resolver and answers true (Check and ListObjects; its ListUsers answers like D). Verified, section 5.

## 9. Testing

### OpenFGA's suite as an oracle

[`test/fga/`](../test/fga/): `vendor.sh` clones openfga/openfga at a pinned commit into an empty temp directory, copies `assets/tests/consolidated_1_1_tests.yaml`, its LICENSE and a SOURCE file (Apache-2.0 attribution), converts each stage's DSL model to JSON with the official transformer (the `openfga/cli` Docker image, pinned by digest, no network), and writes `cases.json`. Nothing from the clone is executed. `generate.py` (run with `python3 -I`) turns the cases into TAP files under `test/spec/d/` (`60_fga_oracle_*`, `61_fga_oracle_ctx_*`), so `test/run.sh` and the Docker matrix run them unchanged. Each upstream assertion is one TAP test named `<mode>:<case>:s<stage>:<check|lo|lu><index>`. Like upstream's harness, the list assertions also check every returned object or user with Check. `skip.tsv` lists cases not run with a reason; `generate.py report <run.sh -v output>` tallies the results.

Two runs, as upstream does: **stored** (each stage writes its model and tuples; stages of a case share the store) and **contextual** (single-stage cases with at most 100 tuples: nothing is written, every tuple is sent as a contextual tuple).

| Run | Cases | Assertions | Passed | Skipped |
| --- | --- | --- | --- | --- |
| stored | 138 | 933 | 933 | 0 |
| contextual | 116 | 746 | 746 | 0 |

The other 22 cases are multi-stage, which upstream doesn't run with contextual tuples either. Upstream has 138 cases (22 multi-stage; one case name appears twice, the second is reported as `immediate_cycle_through_computed_userset~2`); 59 use `intersection` or `but not`. No case uses conditions or modular models.

Mutants confirm the suite bites: ignoring wildcards fails 13 assertions, no depth limit 2, ignoring the subtract of a difference 159, ignoring the cycle flag under a subtract 4, treating a cycle as true in an intersection 8. Using the set-based search for monotone relations under a subtract too (losing the cycle flag) fails nothing in the suite, which has no cycle inside a monotone subtract; `d/31_fga_cycles` catches it (section 5: upstream has no such case, and OpenFGA answers differently from D).

### Other specs

- Shared specs (`test/spec/*.sql`): all pass unchanged.
- `d/30_fga_api`: writes and their errors, model validation and versioning (an old model id still evaluates with that model; tuples a newer model doesn't allow are ignored but can be deleted), Read, the current-subject functions, privileges, `delete_subject`.
- `d/31_fga_cycles`: a cycle inside a monotone subtract makes the difference false (D differs from OpenFGA v1.22.1 here, which answers true; section 5).
- `d/40_rbac_fga_rls`: one table, RBAC and FGA policies (section 6).
- `d/41_no_plan_time_eval`: the FGA list functions are STABLE, not run while planning, run once per query.

## 10. Performance notes (written before benchmarking; measured in [`bench/baselines/D.md`](../bench/baselines/D.md))

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
6. **Monotone fast path**: two evaluators that must agree. The suite passes through both (59 cases go through `_fga_rec`), but a change to one should be run against the whole suite.
