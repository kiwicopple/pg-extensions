# Design D: Per-model tables (`rbac_*` and OpenFGA `fga_*`)

> Status: design D is the extension. It is in [`pg_permissions--0.0.1.sql`](../../pg_permissions--0.0.1.sql). To use the extension, read the [user documentation](../../docs/README.md). This page is the design record.
>
> The team built D in session 4 as a prototype (`prototypes/d-per-model.sql`). Phase 1 of session 5 promoted it to the extension file. The team built it after the direction change in [`plan.md`](../plan.md) ("Current plan (session 4): per-model tables") and [`decision.md`](../decision.md) ("Session 4 direction").
>
> D passes every shared spec without change. It also passes the consolidated test suite of OpenFGA. This is all 138 cases, with 933 assertions for stored tuples and 746 for contextual tuples (section 9). From phase 4 of session 5, D has OpenFGA conditions (CEL).
>
> That work is done. [`d-conditions.md`](./d-conditions.md) describes the design. The ABAC suite of OpenFGA is the oracle (302 and 271 assertions, section 9).
>
> The full suite now has 56 spec files and 3,638 assertions. It runs on PG 16, 17 and 18. The team benchmarked D against A, B and C in [`benchmarks/D.md`](../benchmarks/D.md). The first runs are unoptimized (`opt` runs).
>
> The second pass (`opt2`) has three changes. ListObjects uses a recursive CTE that prunes to the target. The `but not` lists are set-based. A least fixpoint runs under subtracts (section 5).

## 1. Idea

There is no generic API. The `permissions` schema holds one set of tables for each model. Each set follows one specification as closely as it can.

- `rbac_*`: roles, permissions and scoped assignments. This is the blessed path, as first-class tables. The functions are the `rbac` API of every earlier design, with the same signatures and behavior. From session 5 they have the `rbac_` prefix (`rbac_create_role`, `rbac_assign_role`, `rbac_has_permission` and more). Section 3 has the details.. The extension runs its own copies of the shared specs with those names.
- `fga_*`: [OpenFGA](https://openfga.dev). Authorization models are the schema 1.1 JSON of OpenFGA, and tuples are OpenFGA tuple keys. The functions copy the API of OpenFGA (Check, ListObjects, ListUsers, Read, Write, WriteAuthorizationModel) with its semantics and its error codes. The test suite of OpenFGA is the oracle.

The two models share only a small toolkit:

- the subject identity (`current_subject_id()`, G1 in [`goals.md`](../goals.md))
- the plan-time guard (`_unfolded_null()`, [`plan.md`](../plan.md) section 4)
- `collate "C"` on ids
- the grants

The models work together in RLS. Permissive policies combine with OR. Restrictive policies combine with AND (section 6). To move from RBAC to fine-grained access, add FGA policies next to the RBAC policies. You do not need to migrate.

Design A is the base of `fga_*`. The bidirectional Check is the `check_for` function of A. The compiled model drives it, in place of the `implied_by` and `from_parent` lists.

## 2. Tables

All ids, types and relations are `text collate "C"`.

### RBAC

| Table | Rows |
| --- | --- |
| `rbac_roles` | one for each role |
| `rbac_role_permissions` | (role, permission) |
| `rbac_role_inherits` | (role, inherited role). Postgres does not let you drop an inherited role if a row refers to it. |
| `rbac_role_closure` | (role, every role it includes, itself too). `rbac_create_role` writes it. Roles do not change after creation, and a role can inherit only roles that exist. So the closure of a new role is the closures of its parents plus the role itself. No other row changes. |
| `rbac_assignments` | (user_id, role, scope). A null scope is app-wide. The constraint is `unique nulls not distinct (user_id, scope, role)` (Postgres 15 and later). |

`rbac_has_permission(permission, scope)` is one statement. It goes from `rbac_assignments` (by user and scope) to `rbac_role_closure`, then to `rbac_role_permissions`. App-wide and scoped lookups are separate statements, so each one probes the unique index directly. Only `user` subjects hold roles. Another `permissions.subject_type` has none.

### OpenFGA

| Table | Rows |
| --- | --- |
| `fga_models` | one for each model version: a ULID id, a sequence for "latest", and the JSON as written |
| `fga_types`, `fga_relations` | the types and relations of the model. A relation also records the flags in the list below this table. |
| `fga_type_restrictions` | the `directly_related_user_types` of OpenFGA. Each row gives the user (user_type, user_relation, wildcard, condition) that a (type, relation) takes. `[user, user with c]` is two rows. |
| `fga_conditions` | the conditions of the model. Each has a name, an expression, parameters as CEL types, and the compiled, type-checked tree (jsonb) that the evaluator walks ([`d-conditions.md`](./d-conditions.md) sections 4 and 5) |
| `fga_rewrite_nodes` | the rewrite tree of each relation, in preorder: `this`, `computed`, `ttu`, `union`, `intersection`, `difference`. `in_subtract` marks the subtract side of a difference. |
| `fga_edges` | the positive graph (every operand except a subtract) as edges between (type, relation) pairs. `d` is a direct tuple, `c` is a computed relation on the same object, and `t` is a tupleToUserset. `condition` is the condition of the restriction (for `t`, the condition of the tupleset restriction). There is one edge for each condition of a restriction, so a tuple matches exactly the edge of its own condition. |
| `fga_computed_closure` | the transitive closure of the `c` edges |
| `fga_paths` | the `PathExists` of OpenFGA: the user types (`user`, `user:*`, `group#member`) that each relation can reach through any operand |
| `fga_reach` | the reachability between (type, relation) pairs in the positive graph, for each target relation. `strict` means the path has at least one edge. A reflexive strict row is on a cycle. |
| `fga_walk_steps` | the forward walk of ListObjects, compiled for each target relation. Each `d` or `t` edge joins with the computed closure of its destination. The row stays only if the node it yields can reach the target. `expand` means that node has steps of its own toward the target. |
| `fga_tuples` | the tuples: (object_type, object_id, relation, user_type, user_id, user_relation). See the notes below this table. |

A relation records these flags:

- `monotone`.
- `is_tupleset`.
- `diff_relation`, `diff_tupleset` and `diff_recheck`, for a `but not`. The lists use them to evaluate the subtract as a set (section 5).
- `conditional`. A restriction with a condition is reachable from the relation. So its evaluations take the conditional path. On this path, a false result keeps the statements that have no condition.
- `set_eval`. The relation is not monotone, and ListObjects evaluates its rewrite tree over sets (section 5, phase 5 of session 5).

Notes on `fga_tuples`:

- A user_id of `*` is a typed wildcard. The user_relation is `''` unless the user is a userset.
- `condition_name` (`''` for none) and `condition_context` (jsonb) are not part of the key, as in OpenFGA.
- The primary key has the columns in the order above.
- A second index is on (user_type, user_id, user_relation, object_type, relation).
- A partial index is on (object_type, object_id, relation, user_type, user_relation), for the userset tuples only (`fga_tuples_userset_idx`, phase 5 of session 5). The backward step of Check uses it to read the nested teams of a team without its plain members.
- `seq` (identity, unique index) is the insertion order. It is the page order and the continuation token of Read (section 4). The team added it in phase 2 of session 5, because the ULID of OpenFGA has no counterpart in the key.

`fga_write_authorization_model` writes every table except `fga_tuples`, one time. It validates the JSON and compiles it, with the conditions. The function parses and type-checks the conditions at that time, so Check does not parse them. No check reads the model JSON.

Tuples do not belong to a model. As in OpenFGA, every read joins the tuples with the type restrictions of the model in use. So a read ignores these tuples:

- Tuples that remain from an earlier model and no longer type-check (upstream case `check_with_invalid_tuple_in_store`).
- Tuples with a condition that the model no longer accepts for their facet.
- Tuples with a stored context that no longer fits the parameters of the condition ([`d-conditions.md`](./d-conditions.md) section 3, rule 5).

## 3. RBAC API

The RBAC API is the preset of [`plan.md`](../plan.md) section 6. It has the behavior of design A, with the `rbac_` prefix (session 5, "API names" below). The functions are:

- `rbac_create_role(role, permissions text[], inherits text[] default '{}')`, `rbac_drop_role(role)`, `rbac_assign_role(user_id, role, scope default null)` and `rbac_unassign_role(user_id, role, scope default null)`. They are for admins only.
- `rbac_has_permission(permission, scope default null)`, `rbac_has_role(role, scope default null)` and `rbac_scopes_with_permission(permission, plan_time_guard boolean default _unfolded_null())`. Clients and RLS use them. The function ignores `plan_time_guard`, and the caller never passes it ([`plan.md`](../plan.md) section 4).
- `rbac_user_permissions(user_id, scope default null)` and `rbac_users_with_role(role, scope default null)`. They are for admins.

The error codes are the same as in A (23505, 22023, 2BP01). `delete_subject(subject_type, subject_id)` removes a subject from both models. It removes the assignments of the subject and every tuple that names the subject as user or object.

**API names** (section "API naming (session 5)" of [`decision.md`](../decision.md)). The test `d/04_api_naming` pins these rules:

- A prefix means the function is for one model (`rbac_*`, `fga_*`). No prefix means that both models share the function (`current_subject_id`, `current_subject_type`, `delete_subject`). A name that starts with `_` is internal.
- Parameters have one vocabulary across both models (`role`, `permission`, `scope`, `user_id`, `subject`, `object`, `relation`, `type`, `model_id`, `context` and more). No parameter has a `p_` prefix. No parameter name needs quotes in named notation. So you can write every call as `f(name => value)`, and the [user documentation](../../docs/README.md) does so.
- `user` is a reserved word in SQL. So the `user` field of OpenFGA is the parameter `subject`. The JSON tuple keys keep `"user"`.
- A body can have a parameter and a column with the same name. Then the body qualifies the parameter with the name of the function (`rbac_has_role.role`). It qualifies the column with its table alias. The default `variable_conflict = error` of PL/pgSQL turns a clash that slips through into an error, not a wrong answer. Two SQL-language functions are different (`rbac_user_permissions`, `rbac_users_with_role`), because a column wins silently there. They qualify every reference.

## 4. OpenFGA API

Strings use the forms of OpenFGA. An object is `type:id`. A user is `type:id`, `type:*` or `type:id#relation`. The parameter for the OpenFGA user is `subject`, because `user` is reserved in SQL.

Tuple keys are the OpenFGA JSON `{"user", "relation", "object"}`. Every function takes an optional `model_id` (the `authorization_model_id` of OpenFGA). Without it, the function uses the latest model.

| OpenFGA endpoint | SQL | Notes |
| --- | --- | --- |
| WriteAuthorizationModel | `fga_write_authorization_model(model jsonb) returns text` | The body of the request: `{schema_version: "1.1", type_definitions, conditions}`, as `fga model transform --output-format json` prints it. It returns the new ULID. That ULID becomes the latest model. |
| ReadAuthorizationModel(s) | `fga_read_authorization_model(model_id default null) returns jsonb`, `fga_read_authorization_models() returns table(id, created_at)` | |
| Write | `fga_write(writes jsonb, deletes jsonb, model_id)` | Each side is an array of tuple keys, or `{"tuple_keys": [...], "on_duplicate": "ignore"}` or `{"tuple_keys": [...], "on_missing": "ignore"}`. It runs in one transaction. It takes at most 100 tuple keys, with writes and deletes together (Limits below). A written key can have `"condition": {"name", "context"}`. The function validates it against the model (2000). Deletes ignore the condition. A key that exists with another condition is 2017, also with `on_duplicate: ignore` (OpenFGA: HTTP 409). |
| (convenience) | `fga_write_tuple(subject, relation, object)`, `fga_delete_tuple(subject, relation, object)` | They are idempotent: `on_duplicate` and `on_missing` ignore. They are typed (phase 5 of session 5). If a type restriction without a condition accepts the key, the function writes the key with one lookup (`_fga_write_key_ok`). It does not build JSON for `fga_write`. Any other key goes through `fga_write`, so the errors are the errors of `fga_write` (`d/42_fga_write_paths`). `fga_write` itself accepts a key without a condition with that one lookup, in place of six. |
| Read | `fga_read(object, relation, subject, page_size int, continuation_token text) returns (tuples jsonb, continuation_token text)` | The function returns one page, the ReadResponse of OpenFGA, as one row. `tuples` is `[{"key": {"user", "relation", "object"[, "condition": {"name", "context"}]}, "timestamp"}, ...]` in insertion order. `continuation_token` is `''` on the last page. `object` can be `type:` to match every object of a type. `continuation_token` is an `inout` parameter. The input and the output column share the OpenFGA name, and PL/pgSQL gives one variable to each name. So the signature lists it after `out tuples`. The positional order and the output columns are as this table shows. |
| Check | `fga_check(subject, relation, object, contextual_tuples jsonb, model_id, context jsonb) returns boolean` | `context` is the request context of OpenFGA: the condition parameters as a JSON object. It is the last argument, so positional calls without it still work. |
| ListObjects | `fga_list_objects(subject, type, relation, contextual_tuples, model_id, context) returns setof text` | It returns `type:id` strings with no order. It returns at most 1,000. |
| ListUsers | `fga_list_users(object, relation, user_filters text[], contextual_tuples, model_id, context) returns setof text` | The filters are `'user'` or `'group#member'`. It returns `type:id`, `type:*` and `type:id#relation`, at most 1,000. |
| DeleteStore | `fga_delete_store()` | It deletes every model and tuple of the one store. |
| (current subject) | `fga_check_current(relation, object)`, `fga_list_objects_current(type, relation)`, `fga_list_object_ids_current(type, relation)` | Clients and RLS use them. The user is `current_subject_type():current_subject_id()`. The lists have no cap. |

Contextual tuples are an array of tuple keys, or the `{"tuple_keys": [...]}` of OpenFGA. The functions validate them like writes (2027). An invalid condition on a contextual tuple is 2027 in Check and 2000 in the lists, as in OpenFGA. In the walks, contextual tuples behave exactly like stored tuples, conditions included.

The functions evaluate conditions where OpenFGA evaluates them, with its rules for errors. A parameter that the request omits, or a failed evaluation, fails Check with 2000 when no path of true edges exists. It fails ListObjects and ListUsers when their walk takes the edge. See [`d-conditions.md`](./d-conditions.md) section 3 and [`conditions.md`](../../docs/conditions.md).

### Limits

The API functions follow the default limits of OpenFGA v1.22.1. They also do what OpenFGA does when a request hits a limit ([`decision.md`](../decision.md), end of session 4, point 4). The limits are fixed constants in one function, `_fga_limits()`. OpenFGA makes each limit configurable (for example `OPENFGA_MAX_TUPLES_PER_WRITE`).

This extension does not, because the blessed path has no extra settings. The sources are openfga/openfga at tag v1.22.1 and openfga/api at the commit that its go.mod pins (`f153694bfc20`). `test/spec/d/34_fga_limits.sql` checks each behavior below.

| Limit | OpenFGA v1.22.1 | pg_permissions |
| --- | --- | --- |
| ListObjects results | At most 1,000 (`pkg/server/config/config.go:28`). The server drops more results silently, with no error and no flag in the response (`pkg/server/commands/list_objects.go:637-639`). The results that remain are the first results found, so they are not deterministic. | The same. `fga_list_objects` returns at most 1,000, silently. The spec asserts the count and that each result is in the true set. It never asserts which results. |
| ListUsers results | At most 1,000 unique users. The server drops more users silently (`config.go:31`, `commands/listusers/list_users_rpc.go:245-257`). | The same: `fga_list_users` returns at most 1,000. |
| ListObjects and ListUsers deadline | 3 s. After that, the server returns the results so far and swallows the error (`list_objects.go:645-646`, `list_users_rpc.go:286-289`). | None (deviation 4). Set `statement_timeout`. It raises an error and does not return a partial list. |
| Write size | At most 100 tuple keys, with writes and deletes together (`config.go:19`). The server counts them after the duplicate check (2004). More than 100 is 2053 `exceeded_entity_limit`, `The number of write operations exceeds the allowed limit of 100` (`commands/write.go:195-212`). A `writes` or `deletes` with no tuple keys is 2000 (proto `min_items: 1`). | The same codes in the same order. The message adds the count: `... allowed limit of 100: got 101 tuple keys (101 writes, 0 deletes)`. The hint says to split the keys into batches of at most 100, which can share one transaction. An empty array (or `{"tuple_keys": []}`) for either side is 2000. If you give neither side, the error is 2003. |
| Read page size | 50 if absent (`pkg/storage/storage.go:29`). Otherwise 1 to 100, or the error 2000 (`openfga/v1/openfga_service.proto:1174-1180`). | The same: a null `page_size` is 50, and a value outside 1..100 is 2000. |
| Read continuation token | The base64url (padded) of `<ulid>\|`. The ULID is the ULID of the first tuple of the next page. The server finds it when it reads `page_size + 1` tuples (`token_serializer.go:25-35`, `read.go:118`). On the last page the token is `''`, also when the last page is exactly full. The proto limit is at most 5,120 bytes and `^$\|^[A-Za-z0-9-_]+={0,2}$`, else 2000. A token that matches the pattern but does not decode to the shape is 2007 `invalid_continuation_token` (`read.go:79-88`). A well-formed token for a ULID that does not exist seeks past it. Pages are in ULID order (insertion order). | The same, with `fga_tuples.seq` in place of the ULID. The token is the base64url of `<seq>\|`. Pages are in `seq` order. The next page starts at `seq >= token`. Treat the token as opaque. |

The return shape of Read changed in phase 2 of session 5. This was an API break. It was `table(object, relation, user, inserted_at)`, with every match unpaginated. Now it is one row of `(tuples jsonb, continuation_token text)`, as the ReadResponse of OpenFGA.

The `key` of a tuple is the tuple key that `fga_write` takes. So you can feed a page back as deletes. To get rows, run `select t #>> '{key,object}' from permissions.fga_read(object => 'document:1') r, jsonb_array_elements(r.tuples) t`.

The insert assigns `seq`. So a walk misses a transaction that commits after a reader pages past its `seq`. The ULID of OpenFGA has the same property, because OpenFGA assigns it at write time.

The RLS helpers (`fga_list_objects_current`, `fga_list_object_ids_current`) are **uncapped**. A cap there would hide rows that a user can see, with no error. For this reason the list functions are split. `_fga_list_object_ids` and `_fga_list_users` are uncapped and internal.

`fga_list_objects` and `fga_list_users` apply the cap. The RLS helpers call the uncapped function. A cap truncates only the output. The walk still computes the whole set.

Privileges (G2): clients get only the three current-subject FGA functions and the RBAC functions for clients. Only admins can use a function that takes an explicit user (`fga_check`, `fga_list_objects`, `fga_list_users`, `fga_read`). This is the same as the explicit-subject functions of every earlier design. If a client could use them, it could ask what any user can access.

The current-subject functions take no contextual tuples and no condition context, because a client could vouch for itself with them. In these functions, a tuple with a condition counts when its condition is true from its stored context alone. If an answer depends on a condition that the function cannot evaluate, the answer is a deny. It is never an error (see "Conditions in policies" in [`rls.md`](../../docs/rls.md)).

The functions return false or nothing in three cases: no subject, no model yet, or a subject type that the model does not define. So RLS denies and does not fail. An unknown object type or relation still raises an error.

## 5. Evaluation

A relation is **monotone** when neither it nor anything that it depends on uses `intersection` or `difference`. The things that it depends on are computed relations, tupleset targets and usersets in its type restrictions. The model write computes this flag from `fga_paths`.

**Monotone relations** (all of stage 1, and the common case). Check is reachability in the positive graph. `_fga_bidi` is a bidirectional search. It generalizes `check_for` of A. The forward search starts from the user. It follows tuples whose user is a reached node, tupleToUserset parents, and computed relations (through `fga_computed_closure`).

The backward search starts from the object. It follows usersets and tupleset parents in the tuples of the object, and the relations that the object is computed from. Each step expands the smaller frontier, until the two searches meet. For a plain user, the meet test waits for the first forward step, because until then the forward side holds only the user. The user's own tuples on each backward frontier are one probe. The backward step reads usersets through `fga_tuples_userset_idx` (phase 5 of session 5).

ListUsers walks backwards from the object (`_fga_backward`).

**The forward walk of ListObjects** (`_fga_forward`) is one recursive CTE, the `_reach` shape of A. It runs over `fga_walk_steps` for the requested type and relation, compiled at model write. A step is one probe of `fga_tuples` (or of the contextual tuples). The probe already yields the computed closure of its hit, so the recursive term is a single join.

The steps are **pruned to the target**. The walk produces only nodes that can reach the requested relation. So an empty folder list no longer walks every team and document that the user reaches. The recursion produces only nodes that have steps of their own toward the target. The leaves (in a wide walk, thousands of documents) come from one final join. That join takes the reached nodes, each at its lowest level, and the steps that yield the target.

A node is a row for each level at which the walk reaches it. So the walk expands a node that paths of different lengths reach one time for each level. A cycle goes around until level 25, where the recursion stops the expansion. Below level 25, the lowest level of every node is exact.

If the walk first reaches an expandable node at level 25, it stops short of what lies behind that node. `_fga_forward_ids` finishes the walk. It is the same walk without levels, with one row for each node. A target that the walk finds only there counts as 25 levels deep. `_fga_forward_ids` is also the candidate walk for non-monotone relations.

**Other relations.** `_fga_rec` evaluates the rewrite tree as the `LocalChecker.ResolveCheck` of OpenFGA does. It applies these rules in this order:

1. The depth limit.
2. Cycle detection on the path.
3. A userset user is in itself.
4. `PathExists`.
5. The node types `this`, `computedUserset`, `tupleToUserset`, `union`, `intersection` and `difference`.

`_fga_rec` combines results with the rules of OpenFGA. A branch error loses to a branch that decides. A cycle under a subtract makes the difference false. Every monotone subproblem, under a subtract or not, goes back to `_fga_bidi` (its least fixpoint, see Cycles). So the path holds only non-monotone relations. Check always uses `_fga_rec` for these relations.

**ListObjects and ListUsers on `base but not subtract`, set-based.** This path applies when two conditions are true. First, the base is a positive expression over monotone relations, and it does not include the relation itself. So the positive walk to the relation is exactly the base. Second, the subtract is `r` or `r from ts`, and `r` is monotone on every type that it names (`fga_relations.diff_relation`, compiled).

In this case, ListObjects is the walk to the relation minus the walk to the subtract. For `r from ts`, the walk to the subtract finds the objects whose `ts` is a parent that the user reaches through `r`. ListUsers is the backward walk from the object minus the backward walk from its subtract. The wildcard of its type also removes a plain user.

The results follow the rules of `_fga_rec`. A base 25 levels deep is an error, unless the subtract removes it. A userset user always has its own relation. The walk of the subtract decides membership exactly.

But it does not decide the depth limit on a long subtract. Suppose `r` can recurse (a relation that it depends on is on a cycle), or `r` depends on 24 relations or more. Then the compiler sets `diff_recheck`.

In that case, the walk checks only the objects (users) that the subtract removes, one by one, with `_fga_rec`. This is typically a handful. On the wide benchmark data, ListObjects goes from 2.1 s to about 4 ms ([`benchmarks/D.md`](../benchmarks/D.md), opt2).

**ListObjects on the other non-monotone relations, set-based over the rewrite tree.** Phase 5 of session 5 added this path. The compiled flag is `fga_relations.set_eval`. The functions are `_fga_set_rel` and `_fga_set_node`.

The path evaluates every node for all objects at once, as a set of (object, level). Level 25 means 25 or more. The node types work as follows:

- `this` is the direct tuples on the relation of the forward walk (`_fga_forward` with `p_direct`).
  > **Status:** the API naming pass of session 5 removed the `p_` prefix from public parameters only. The internal function `_fga_forward` still has `p_direct`, because a leading `_` marks an internal function. See "API naming (session 5)" in [`../decision.md`](../decision.md).
- A computed relation is its own set. For a monotone relation, this is its forward walk.
- `r from ts` is the sets of the parents, through the `ts` tuples, one level deeper.
- Union, intersection and difference combine the children by the rules of `_fga_rec`. A true branch decides a union (the lowest level). A false branch decides an intersection (the highest level). A subtract below level 25 removes. A base or subtract at level 25 or deeper is too deep.

A relation qualifies when all of these are true:

- Every userset in its `this` restrictions is monotone, so the direct walk is exact.
- Every relation that it names is monotone or qualifies itself. This includes the computed relations and the tupleToUserset relation on every parent type.
- It does not reach itself in the positive graph.

The fixpoint at model write never marks a cycle through a subtract. Under a subtract, the RLS helpers count an evaluation error as true (`n`), as the set-based difference does. A relation with `diff_relation` keeps that path for its own ListObjects, and it qualifies as an operand of other relations.

On the wide benchmark data (pgbench p50), ListObjects on `viewer but not (blocked or muted)` went from 5,246 to 7.6 ms. On `editor and viewer` it went from 621 to 6.1 ms ([`benchmarks/D.md`](../benchmarks/D.md), opt3). `d/43_fga_set_eval` compares this path with Check and with the per-candidate path.

**Every other non-monotone relation, and ListUsers on non-monotone relations outside the set-based difference.** A relation is in the first group if it recurses through itself, or if it names a relation that does not qualify. For these cases, the candidates come from the walk of the positive graph. The candidates are a superset, because every true answer has a derivation that uses no subtract. The path checks each candidate with `_fga_rec`, without memoization. It evaluates again the subproblems that candidates share.

**Depth.** The resolve node limit of OpenFGA is 25. Each userset tuple or tupleToUserset that the walk follows costs one level. A computed relation costs none, and a direct match of the user costs none (`dispatch` and `ResolveCheck` in `internal/graph/check.go`).

The walks track levels in the same way. A Check or ListObjects answer that needs 25 levels or more raises 2002. ListUsers raises when its walk reaches a node 25 levels deep, as upstream does.

**Cycles.** OpenFGA gives a subproblem the result false, with a cycle flag, when the same path already resolves that subproblem higher up. In a union, this result is false. Under the subtract of a difference, it makes the whole difference false (upstream cases `true_butnot_cycle_return_false` and `list_objects_with_subcheck_encounters_cycle`). `_fga_rec` carries the path and the flag.

D applies that rule only to **recursion through negation**. This is a cycle through a non-monotone relation, which is a relation that reaches itself through a subtract, as in those upstream cases. D evaluates a **monotone** relation by its least fixpoint wherever the relation appears, under a subtract too. This applies to positively recursive relations and to other relations. So a cycle of usersets contributes nobody.

Take `define blocked: [user, document#blocked]` with `document:1#blocked@document:2#blocked`, `document:2#blocked@document:1#blocked` and no user. Then `blocked` is empty, and `viewer: [user] but not blocked` holds for `user:jon` on `document:1`. Check, ListObjects and ListUsers agree (`test/spec/d/31_fga_cycles.sql`).

This is a decision from session 4. Before it, D followed the default strategy of OpenFGA and answered false. OpenFGA v1.22.1 answers true in Check and ListObjects for this model. The vendored suite uses commit 44054f5, image `sha256:b852071314f1fda1194d341a6ebac0a4f619b3cd87a6626d2ccc7048af4ec671`, and the memory datastore. The planner of OpenFGA picks the recursive resolver (`UsersetUseRecursiveResolver`), which never reports a cycle. But its ListUsers on `document:1` returns nothing.

A control model flips the Check of OpenFGA to false. The control model only adds an unused path to users. In it, `blocked` also takes `team#member`, `team#member: [group#member]` and `group#member: [user]`, and there are no team or group tuples. D answers the same for both models. The team reported this upstream ([`openfga-cycle-but-not-inconsistency.md`](../upstream/openfga-cycle-but-not-inconsistency.md)). The upstream suite has no cycle inside a monotone subtract, so both rules pass it.

## 6. Composition with RLS

This is `test/spec/d/40_rbac_fga_rls.sql`, in short form:

```sql
-- permissive: OR
create policy documents_select_rbac on documents for select to authenticated
    using (org_id = any (array(select unnest(permissions.rbac_scopes_with_permission(permission => 'documents.read'))::uuid)));
create policy documents_select_fga on documents for select to authenticated
    using (id = any (array(select permissions.fga_list_object_ids_current(type => 'document', relation => 'viewer')::uuid)));
-- restrictive: AND
create policy documents_not_banned on documents as restrictive for select to authenticated
    using (org_id <> all (array(select permissions.fga_list_object_ids_current(type => 'org', relation => 'banned')::uuid)));
-- per-row checks for single-row writes
create policy documents_update_rbac on documents for update to authenticated
    using (permissions.rbac_has_permission(permission => 'documents.edit', scope => org_id::text));
create policy documents_update_fga on documents for update to authenticated
    using (permissions.fga_check_current(relation => 'editor', object => 'document:' || id));
```

Each list policy is one InitPlan for each query. The spec checks the exact rows that five users see. The five cases are: RBAC only, FGA only, both, an RBAC role that an FGA ban overrides, and nothing.

**The FGA list functions return `setof text`, not `text[]`. They need no `_unfolded_null()` argument.** The plan-time problem of [`plan.md`](../plan.md) section 4 comes from `unnest(f())`. To estimate the row count of the unnest, the planner evaluates a STABLE `f` with constant arguments. The planner never evaluates at plan time a function that returns a set. Its estimate comes from `rows` (100 here).

`test/spec/d/41_no_plan_time_eval.sql` pins this with the call-count probe of `22_no_plan_time_eval`. EXPLAIN does not run `fga_list_object_ids_current`, and a query runs it one time. The RLS form is `id = any (array(select f(...)::uuid))`. `rbac_scopes_with_permission` keeps its `text[]` form and its ignored last argument, `plan_time_guard`. `d/22_no_plan_time_eval` pins both, as the shared spec does for the prototypes.

## 7. Errors

Invalid input raises an error where OpenFGA returns an error. The `DETAIL` has the numeric code of OpenFGA, as `openfga:<code> <name>`:

| SQLSTATE | DETAIL | When |
| --- | --- | --- |
| `22023` | `openfga:2000 validation_error` | Check: a malformed or unknown user, object or relation. ListObjects: an invalid user. Write: a malformed delete key, a bad `on_duplicate` or `on_missing`, or an empty `writes` or `deletes` list. Read: a `page_size` outside 1..100, or a token outside the base64url pattern or over 5,120 bytes. |
| `22023` | `openfga:2001`, `2020` | an unknown model id. No model written yet. |
| `54001` (statement_too_complex) | `openfga:2002 authorization_model_resolution_too_complex` | depth 25 (section 5) |
| `22023` | `openfga:2003`, `2004`, `2017` | a write with neither writes nor deletes. The same tuple twice in one request. A write of a tuple that exists, or a delete of a tuple that does not exist. |
| `22023` | `openfga:2007 invalid_continuation_token` | a Read token that matches the pattern but does not decode to a position |
| `22023` | `openfga:2021 type_not_found`, `2022 relation_not_found` | ListObjects and ListUsers: an unknown type or relation in the request or in a filter |
| `22023` | `openfga:2027 invalid_tuple` | a written or contextual tuple that the model does not accept. The causes are: an unknown type or relation. A user type that is not in the restrictions. A wildcard or userset where the model does not accept it. A wildcard or userset on a tupleset relation. |
| `22023` | `openfga:2053 exceeded_entity_limit` | a Write of more than 100 tuple keys (section 4, Limits) |
| `22023` | `openfga:2047 type_invalid_pattern`, `2050 relations_invalid_pattern` | model: a type or relation name that does not match the pattern of OpenFGA (the validation of the request) |
| `22023` | `openfga:2056 invalid_authorization_model` | model: anything that `typesystem.NewAndValidate` of OpenFGA rejects. The cases are: a type defined twice. `self` or `this` as a name. An undefined type or relation in a rewrite or type restriction. A bad tupleset. A direct relation without type restrictions, or the reverse. A relation with no entrypoint. A cycle of computed relations. Schema version 1.0. |
| `22023` | `openfga:2000`, `2057` | model: a schema version other than 1.0, 1.1 and 1.2 (2000, the validation of the request). Schema version 1.2 (modular models) is 2057, because OpenFGA accepts it and this extension does not. |
| `22023` | `openfga:2056 invalid_authorization_model` | model: a condition that does not compile. Also a restriction that names an undefined condition, and a part that the CEL of pg_permissions leaves out (bytes, `type()`, `dyn()`). The compile errors are: a syntax error. An undeclared name. An overload that does not fit. A result that is not a bool. An unknown parameter type. A generic type that has no argument. A key that differs from the name. |
| `22023` | `openfga:2000 validation_error` | model: a condition name, expression size (512 bytes) or parameter count (25) outside the limits of the request. Also an inline `$expression` condition. Write: the condition of a tuple is undefined, not accepted for its facet, or absent where only restrictions with a condition exist. A context key or value does not fit. Check, ListObjects, ListUsers: the `context` is not a JSON object. Or a condition cannot be evaluated (an absent parameter, a wrong type, an evaluation error or the cost limit). |

The `rbac_*` functions raise errors with no DETAIL:

- `23505`: a role that exists.
- `22023`: an unknown role, or a role name that is also a permission.
- `2BP01`: a drop of a role that another role inherits.
- `22004`: `rbac_assign_role` with a null user.

The SQLSTATE tells any Postgres client what kind of failure it is. The DETAIL is the OpenFGA code, which a machine can check (PostgREST returns it as `details`). The order of validation follows OpenFGA, so the same request gets the same code. The orders are:

- Check validates the user, the object, the relation, and then the contextual tuples.
- ListObjects validates the contextual tuples, then the type and relation, then the user.
- ListUsers validates the contextual tuples, the filters, and then the target.
- Write validates the options, the lists, the model, each tuple, the duplicates, and then the size.

**Messages and hints** ([`decision.md`](../decision.md), end of session 4, point 5). The MESSAGE names the values that cause the error: the type, relation, user string, tuple, model id, count or token. Where OpenFGA has a message for the case, the message of the extension starts with it (`The number of write operations exceeds the allowed limit of 100`, `Authorization Model '<id>' not found`). Every error, `rbac_*` included, has a HINT that says how to fix the error. The HINT is never empty:

| Error | HINT |
| --- | --- |
| an unknown type, relation or role | The nearest name that exists, if one is within a third of the length of the input (1 to 3 edits). Then the list of names (at most 20): `Did you mean 'viewer'? Relations on type 'document': editor, parent, viewer.` |
| a tuple whose user type the relation does not accept (2027) | the accepted user types: `'document#editor' allows users of type: user.` |
| an unknown model id (2001) | the valid ids, newest first (at most 10) |
| no model yet (2020), no roles yet | the call to make first: `fga_write_authorization_model(model => ...)`, `rbac_create_role(role => ..., permissions => ...)` |
| 2017, 2053, 2003, the token and page size of Read | the option or call that fixes the error: `on_duplicate` or `on_missing` `ignore`, batches of at most 100, the default page size, or pass the token back unchanged |
| a malformed user, object or tuple key | the expected form, with an example |

The nearest name uses a Levenshtein distance in PL/pgSQL (`_edit_distance`, not case-sensitive). The extension stays in plain SQL and PL/pgSQL for pg_tle, so it does not use `fuzzystrmatch` or `pg_trgm`. The code computes hints only on the error path.

`test/spec/d/35_error_hints.sql` triggers every raise site. There are 68: 7 in `rbac_*` and 61 calls of `_fga_error`. Until phase 4 there were also 3 calls of `_fga_unsupported`, the 0A000 helper, which is now removed. The spec has one row for each site. Each row has the statement, the SQLSTATE, the DETAIL, a pattern for the MESSAGE and, for most rows, the HINT.

A guard scans the function bodies in `pg_proc.prosrc`. It fails if a `raise` or an error-helper call passes no hint. It also fails if the number of raise sites differs from the number of rows. So a new raise site needs a hint and a row.

`_fga_error` must get the hint as an argument. If you remove one hint, the guard fails and the row of that site fails. The team checked this on a copy of the extension, with one `_fga_error` call and one `rbac_*` raise.

## 8. Deviations from OpenFGA

These deviations are deliberate:

1. **One implicit store for each database.** There is no CreateStore, ListStores or store id. `fga_delete_store()` clears the one store. A second store is a second database or schema.
2. **Conditions, with a PL/pgSQL CEL evaluator** ([`d-conditions.md`](./d-conditions.md), from phase 4 of session 5). The differences from OpenFGA are:
   - The extension refuses inline `$expression` conditions (2000, as the default server does).
   - It refuses `bytes`, `type()` and `dyn()` at model write.
   - The cost limit is approximate: a counter of nodes and iterations, with a limit of 100.
   - ListObjects and ListUsers ignore a stored context that the current model no longer accepts, as Check does. The lists of OpenFGA fail with 2000.
   - The RLS helpers get no request context. They deny when an answer depends on a condition error.
   - Timestamps are microseconds.
   - A double overflow and a division by zero are errors (CEL: infinities).
   - `matches` uses Postgres regular expressions.
   - The extension refuses IPv6 zones.
   - In a value of type `any` (JSON), and in a list or map literal of mixed types, numbers are doubles.

   [`d-conditions.md`](./d-conditions.md) section 13 has the full list, with the reasons.
3. **Errors are Postgres exceptions** (section 7), not gRPC or HTTP statuses.
4. **The limits are the defaults of OpenFGA. They are fixed, and there is no deadline** (section 4, Limits). ListObjects and ListUsers return at most 1,000. Write takes at most 100 tuple keys.

   Read is paginated. OpenFGA does the same. But you cannot configure the limits. There is no deadline for ListObjects and ListUsers (OpenFGA: 3 s, then partial results). Use `statement_timeout`.

   It raises an error and does not return part of the list. The RLS helpers are uncapped. ReadAuthorizationModels is not paginated. Models have no limit on size or on the number of types.
5. **Consistency is the consistency of Postgres.** Every read uses the snapshot of the statement. So there is no `consistency` parameter and no cache.
6. **The current-subject functions take no contextual tuples.** They deny, and do not raise an error, when the subject or the model is absent (section 4).
7. **Strings, not structured users.** ListUsers returns `type:id#relation` strings, not `User` objects, and no `excluded_users`.

These simplifications can differ from OpenFGA in corner cases. The suite does not reach any of them:

8. **Model validation follows `typesystem.NewAndValidate` of OpenFGA v1.22.1** (from phase 3 of session 5), with the error codes of the server (section 7). It checks these things:
   - Names and duplicate types.
   - Unknown types and relations in rewrites and restrictions.
   - Tupleset relations: they are direct, they have plain types only, and the computed relation is defined on at least one of the types.
   - `this` if and only if the relation has type restrictions.
   - Every relation has an entrypoint (`hasEntrypoints`). D computes it as a least fixpoint over the rewrite nodes. `this` needs a plain type, a wildcard or a userset whose relation has an entrypoint. A union needs one child that has an entrypoint. An intersection and a difference need every child to have one.
   - No cycle of computed relations on a type, through any operator, even when each relation has a type restriction (`HasCycle`).

   The validation cases of openfga/language are the oracle (section 9). These known differences exist. The DSL transformer produces none of them:
   - A union or intersection with one child. OpenFGA rejects it when its entrypoint search reaches that node. D accepts it.
   - A type restriction with an empty relation (`{"type": "user", "relation": ""}`). OpenFGA returns 2056. D reads it as `user`.
   - An empty `type_definitions`. OpenFGA returns 2045 `type_definitions_too_few_items`. D returns 2056.
   - The limits of OpenFGA on model size and on the number of types (deviation 4).

   Before phase 3, a type defined twice was 2005, and a schema version other than 1.1 was 2057. WriteAuthorizationModel of OpenFGA returns neither. It maps every validation error to 2056 (`pkg/server/commands/write_authzmodel.go:84-86`).
9. **Depth on false answers.** A Check on a monotone relation with a false answer returns false. The top-down search of OpenFGA can hit depth 25 on an irrelevant branch and return 2002. D does not.

   This now includes a monotone relation under a subtract. When the true answer needs 25 levels or more, the result matches (2002). `_fga_bidi` uses the depth of the first point where the two searches meet. A shorter path that it finds later would not change a 2002 back to true.
10. **Malformed delete keys** raise 2000 for any field (OpenFGA checks only the format of the user). Until phase 2 of session 5, a malformed user or object in a delete gave 2017. The check counted the rows of a function that always returns one. `d/35_error_hints` found this.
11. **Not implemented:** Expand, BatchCheck, StreamedListObjects, ReadChanges, assertions, the modular-model (`fga.mod`) format and its schema version 1.2 (2057).
12. **A cycle inside a monotone subtract** contributes nobody (least fixpoint), in Check, ListObjects and ListUsers. OpenFGA v1.22.1 answers true in Check and ListObjects when its recursive resolver applies. It answers false when an unused path in the model rules out that resolver. It answers nothing in ListUsers. Recursion through negation keeps the cycle rule of OpenFGA. See section 5.
13. **The filter of Read** is any combination of `object` (`type:id` or `type:`), `relation` and `subject`, or none. When a tuple key is given, OpenFGA needs the object type and either the object id or the user (2000 otherwise).

## 9. Tests

### OpenFGA's suite as an oracle

[`test/fga/`](../../test/fga/) has the tools for this oracle. The steps are:

1. `vendor.sh` clones openfga/openfga at a pinned commit into an empty temporary directory.
2. It copies `assets/tests/consolidated_1_1_tests.yaml`, its LICENSE and a SOURCE file (Apache-2.0 attribution).
3. It converts the DSL model of each stage to JSON with the official transformer (the `openfga/cli` Docker image, pinned by digest, no network).
4. It writes `cases.json`.

Nothing from the clone runs. `generate.py` (run with `python3 -I`) turns the cases into TAP files under `test/spec/d/` (`60_fga_oracle_*`, `61_fga_oracle_ctx_*`). So `test/run.sh` and the Docker matrix run them without change. Each upstream assertion is one TAP test with the name `<mode>:<case>:s<stage>:<check|lo|lu><index>`.

As the upstream harness does, the list assertions also check every returned object or user with Check. `skip.tsv` lists the cases that the suite does not run, with a reason. `generate.py report <run.sh -v output>` tallies the results.

There are two runs, as upstream has. In the **stored** run, each stage writes its model and tuples, and the stages of a case share the store. In the **contextual** run, only single-stage cases with at most 100 tuples run. The run writes nothing, and it sends every tuple as a contextual tuple.

| Run | Cases | Assertions | Passed | Skipped |
| --- | --- | --- | --- | --- |
| stored | 138 | 933 | 933 | 0 |
| contextual | 116 | 746 | 746 | 0 |

The other 22 cases are multi-stage. Upstream does not run them with contextual tuples either. Upstream has 138 cases (22 multi-stage). One case name appears twice, and the second is reported as `immediate_cycle_through_computed_userset~2`. 59 cases use `intersection` or `but not`. No case uses conditions or modular models.

Mutants confirm that the suite catches errors. The numbers are failed assertions:

- Wildcards ignored: 13.
- No depth limit: 2.
- The subtract of a difference ignored: 159.
- The cycle flag under a subtract ignored: 4.
- A cycle treated as true in an intersection: 8.

A mutant that uses the set-based search for monotone relations under a subtract too (it loses the cycle flag) fails nothing in the suite. The suite has no cycle inside a monotone subtract. D now does exactly that (section 5), and `d/31_fga_cycles` pins the answer. A mutant that ignores the subtract in the set-based ListObjects and ListUsers fails 37 suite assertions (both subtract forms, wildcards, contextual tuples). A mutant that drops the depth check of ListObjects, or its step that finishes the walk behind level 25, fails nothing upstream. `d/33` and `d/32` catch them (7 and 4 assertions).

### openfga/language's validation cases as an oracle

[`test/fga_lang/`](../../test/fga_lang/) has the tools. The steps are:

1. `vendor.sh` gets openfga/language at `f558baa` into an empty temporary directory. This is tag `pkg/go/v0.3.2`, the language version that both openfga v1.22.1 and openfga/cli v0.8.2 use.
2. It copies `tests/data/dsl-semantic-validation-cases.yaml` with its LICENSE and a SOURCE file.
3. It converts the DSL of each case to JSON with the same pinned CLI image. The transformer validates nothing, so every case converts.
4. It writes each JSON model to the server of OpenFGA v1.22.1 (the pinned `openfga/openfga` image, memory datastore), and records the answer of the server.

`generate.py` writes `test/spec/d/62_fga_lang_oracle.sql`. A case with no expected errors must be accepted. A case with expected errors must be rejected, with the code that the server returned and a HINT that is not empty. The spec does not compare messages, because the language library owns them. The generator refuses a case if the server contradicts its expectation, unless `skip.tsv` lists the case.

| Cases | Run | Passed | Skipped |
| --- | --- | --- | --- |
| 93 | 70 (4 accepted and 66 rejected. Of the 66, 60 return 2056, 4 return 2000, and one each return 2047 and 2050) | 70 | 23. See the list below this table. |

The 23 skipped cases are:

- 16 `server-accepts`: duplicate type restrictions and operands, and unused conditions. The language validator flags them, and the server accepts them.
- 2 `inline-expression`: `$expression` conditions. The server refuses them without its feature flag, and this extension does the same.
- 2 `schema-1.2`: modular models.
- 3 `upstream-skip`: the upstream harness skips them. They expect acceptance, and the server rejects them as cycles.

Until phase 4, the suite skipped all 8 condition cases, and 66 cases ran. Now 4 of the 8 run (three undefined conditions, and a duplicate type next to a condition).

Before phase 3, 33 of the 66 passed. The suite runs four cases that are marked `skip: true` upstream, because the server agrees with their expectation (rejection). They are the only oracle cases that catch the cycle check.

The team disabled each new check on a copy of the extension to make mutants. The numbers are failed assertions, in this order: oracle cases / `d/36` / `d/35` / `d/30`.

- No entrypoint check: 11 / 6 / 1 / 0.
- Intersection and difference treated like a union in the entrypoint fixpoint: 4 / 2 / 0 / 0.
- No cycle check: 4 / 4 / 10 / 0.
- The cycle check ignores subtracts: 1 / 1 / 0 / 0.
- No reserved type names: 3 / 2 / 11 / 0.
- No reserved relation names: 3 / 1 / 1 / 0.
- Schema versions always 2057: 4 / 3 / 1 / 1.
- A duplicate type as 2005: 2 / 1 / 1 / 1.
- Name patterns as 2056: 2 / 3 / 2 / 0.

In `d/35`, the 10 and 11 include some rows that fail only for one reason. The row expected the extension to refuse a model. The extension accepted the model, and it became the latest model. The stricter validator rejects no model in the consolidated suite (933/933 and 746/746 still pass) and none of the models of the benchmark.

### OpenFGA's ABAC (conditions) suite as an oracle

[`test/fga_abac/`](../../test/fga_abac/) has `abac_tests.yaml` from the same commit. The team vendored it and generated the specs in the same way (`63_fga_abac_*`, `64_fga_abac_ctx_*`). Assertions have a request `context`, and tuples have conditions ([`d-conditions.md`](./d-conditions.md) section 1). `probe.sh` asks the pinned server the questions that the cases do not pin (P1 to P44). The in-house specs pin those answers.

| Run | Cases | Assertions | Passed | Skipped |
| --- | --- | --- | --- | --- |
| stored | 33 | 331 | 302 of 302 run | 9 cases, 29 assertions: `inline-expression` |
| contextual | 30 | 300 | 271 of 271 run | the same 9 |

The suite skipped 8 openfga/language cases as `conditions`. Now 4 of them run, where the server and the expectation agree (three undefined conditions, and a duplicate type next to a condition). The other 4 stay skipped, because they do not agree (2 unused conditions that the server accepts, 2 inline expressions that it refuses). The result is 70 of 70 run, and 23 skipped.

The team made mutants on a copy of the extension. The numbers are failed assertions, in this order: abac stored / contextual / in-house specs `d/35`, `d/37`, `d/38`, `d/39`, `d/90_usage_conditions`, `d/90_usage_rls`.

- Ignore the condition: 148 / 140 / 1, 0, 55, 20, 9, 2.
- An absent parameter treated as false: 60 / 60 / 1, 0, 1, 11, 4, 0.
- Request context wins over tuple context: 18 / 18 / 0, 0, 16, 6 (and 10 not run), 1 (and 11 not run), 1.
- No type check of context values: 10 / 10 / 0, 0, 32, 2, 0 (5 not run), 0 (1 not run).
- No type check of operators at model write: 0 / 0 / 10, 3, 0, 0, 3, 0.
- Check without the error rule of OpenFGA (errors are false): 27 / 27 / 1, 0, 39, 4, 3, 0.
- The `conditional` flag never set: 123 / 119 / 1, 2, 39, 18, 4, 2.
- The `conditional` flag always set: 0 / 0 / 0, 3 (the assertions of the flag), 0, 0, 0, 0. The always-conditional path gives the same answers, but it is slower.

### Other specs

- Shared specs (`test/spec/*.sql`): all pass without change.
- `d/30_fga_api` tests writes and their errors, model validation and model versions, Read, the current-subject functions, privileges and `delete_subject`. An old model id still evaluates with that model. A newer model can refuse tuples. The function ignores them, but you can delete them.
- `d/34_fga_limits` tests the limits (section 4). It checks 1,050 objects and users against the cap of 1,000. It checks the count, that there are no duplicates, and that each result is in the uncapped set. The RLS helpers return all 1,050.

  It checks Write at 100 and 101 tuple keys, with writes and deletes counted together, duplicates before the count, and empty lists. It reads page by page: every tuple once, in insertion order, a last page that is exactly full, and filters. It also checks page sizes, bad tokens (2000, 2007), and a token whose tuple a delete removed.
- `d/35_error_hints` checks every raise site with its SQLSTATE, DETAIL, MESSAGE and HINT, and the `prosrc` guard (section 7).
- `d/36_fga_model_validation` tests the entrypoint and cycle checks and the model error codes. Each case is checked against the OpenFGA v1.22.1 image (deviation 8).
- `d/37_fga_conditions_model` tests conditions at model write. The cases are: conditions that the model accepts, stores and compiles. Conditions that the model refuses with 2056 or 2000, as OpenFGA does (P1 to P4, P33 to P37). What the CEL of pg_permissions leaves out.

  The restriction and edge rows for each condition. The `conditional` flag. A tuple whose condition a new model does not accept is ignored on the path without conditions.
- `d/38_fga_cel` tests the CEL language through the API with 142 expressions. The groups are: literals, operators, strings, conversions, timestamps and durations, macros, ip addresses, error absorption, the context conversions of OpenFGA, the cost limit and parameters. Each expression is checked against the probed server where it answered.
- `d/39_fga_conditions_eval` tests Write, Read and Delete with conditions, and contextual tuples. It tests the error rule for each API (P14 to P16). It tests `but not` and `and` with condition errors, and the RLS helpers. Check, ListObjects and ListUsers must agree on 96 questions. It tests one evaluation for each distinct context, and stale contexts (P28 to P30).
- `d/90_usage_fga`, `d/90_usage_conditions` and `d/90_usage_rls` test every example in [`fga.md`](../../docs/fga.md), [`conditions.md`](../../docs/conditions.md) and [`rls.md`](../../docs/rls.md).
- `d/31_fga_cycles` tests that a userset cycle inside a monotone subtract contributes nobody (least fixpoint). It has a control model that OpenFGA answers differently. It also has a cycle that does block a user, and the same cycle broken (section 5).
- `d/32_fga_set_based` tests set-based `but not` ListObjects and ListUsers against Check (one `_fga_rec` for each object or user) and against the per-candidate path on the same store. The cases are: computed and tupleToUserset subtracts. Recursive subtracts (rechecked, and one that is too deep). A cyclic base, wildcards, userset users, contextual tuples and the depth limit. It also tests which relations compile to the set-based form.
- `d/33_fga_walk_pruning` tests the pruned forward walk against Check. It tests every relation of a model that has more than one target, cycles, a wildcard, tupleToUserset and userset users. It also tests the depth limit at 24 and 25 levels, for a userset user, and behind the stop at level 25.
- `d/40_rbac_fga_rls` tests one table with RBAC and FGA policies (section 6).
- `d/41_no_plan_time_eval` tests that the FGA list functions are STABLE, do not run at plan time, and run one time for each query.

## 10. Performance notes (written before the benchmark, measured in [`benchmarks/D.md`](../benchmarks/D.md))

The second pass (opt2) acted on that diagnosis. The forward walk is now one recursive CTE over compiled steps that prune to the target. The `but not` lists are set-based (section 5). The notes below are the original notes. The ListObjects and non-monotone items describe the `opt` version.

The third pass (opt3, phase 5 of session 5) took the hotspots that remained. It has four changes:

- ListObjects on the other non-monotone relations evaluates the rewrite tree over sets (section 5).
- Writes skip the JSON round trip (section 4).
- Check reads the usersets of a node through a partial index.
- The conditional forward walk evaluates each distinct (condition, context) one time.

The team measured these changes and did not adopt them:

- The covering user index. It waits for a decision from the user: +120 MB at large scale, and no gain through pgbench on the shapes of the benchmark.
- One tuplestore fewer, and a `distinct` in place of the lowest-level `group by`. Each gives 8% or less in the server.
- A fix for userset cycles. The leveled walk costs 3.3x on a tree with a 2-cycle at every inner team, and the team found no exact alternative.

The numbers are in [`benchmarks/D.md`](../benchmarks/D.md), opt3.

Watch these items in the benchmark:

- **Check on monotone relations** is the bidirectional search of A. Each step is one PL/pgSQL call (`_fga_fstep`, `_fga_bstep`) with a 4-way `union all` that joins `fga_edges`. The four branches are stored and contextual tuples, with direct and tupleToUserset edges. With no contextual tuples, the `unnest('{}')` branches are empty, but the planner still plans them. The version of A had 3 branches and no edge join.
- **ListObjects** for RLS is a forward walk in a PL/pgSQL loop with array frontiers and a visited set (`not exists` over `unnest`). The `_reach` of A was one recursive CTE. Wide users (thousands of objects) pay for arrays that grow at each step.
- **Non-monotone relations** (`and`, `but not`) run `_fga_rec`. This is one PL/pgSQL call for each subproblem, with two or three statements each, and no memoization within a request. The search is top-down, so the walk visits a userset fan-out (a group with many nested subgroups) group by group. ListObjects and ListUsers on such relations check every candidate. This is the path to optimize if exclusions are common (for example a set-based difference when the subtract is monotone).
- Every call resolves the latest model (`order by seq desc limit 1`, an index probe) and validates the object type and relation again.
- No memberships or closures are materialized. A write is one row (`fga_write` validates each tuple against the model, with a few index probes). The materialized memberships of C remain the option if wide reads need them.

## 11. Choices to review

Status: these choices are the record from the time of the design. The extension in [`pg_permissions--0.0.1.sql`](../../pg_permissions--0.0.1.sql) is the final result. [`decision.md`](../decision.md) has the later decisions.

1. **List functions return `setof text`.** This removes the dummy argument from the FGA RLS functions (section 6). `fga_list_objects` returns the `type:id` of OpenFGA. For RLS, `fga_list_object_ids_current` returns bare ids, so policies cast the ids without string changes. The alternatives are one function with a flag, or only ids.
2. **Error format.** Two SQLSTATEs plus `DETAIL 'openfga:<code> <name>'`. The alternatives are one custom SQLSTATE class for each OpenFGA code, or the code in the message. A machine can check a custom SQLSTATE without DETAIL, but clients do not know it.
3. **Model versions.** Models do not change after the write, and the latest model wins. Old ids still work. The only way to pin "the model that the app expects" is to pass the id. The extension never migrates tuples. A tuple that a new model rejects stays ignored until someone deletes it.
4. **The current-subject functions deny when the subject type is absent**, and they take no contextual tuples (section 4). OpenFGA itself would raise an error for an unknown user type.
5. **`delete_subject` spans both models.** Per-model cleanup functions (`rbac_forget_user`, `fga_delete_tuples_for`) would fit the per-model principle better. The extension keeps `delete_subject` for the shared usage spec.
6. **Monotone fast path.** There are two evaluators, and they must agree. The suite passes through both (59 cases go through `_fga_rec`). But you must run the whole suite after a change to one of them. Set-based `but not` lists add a third evaluator (`d/32` compares it with the other two).
7. **Least fixpoint for positive recursion under a subtract** (section 5). The team decided this in session 4. D differs from the default strategy of OpenFGA. It agrees with Check and ListObjects of OpenFGA v1.22.1 only when its recursive resolver applies.
8. **Compiled walk steps for each target relation** (`fga_walk_steps`). The rows grow with relations x reachable steps, for each model version. This is tiny for the benchmark model (13 rows). A model with hundreds of interlinked relations would store more.
9. **Fixed limits** (section 4, phase 2 of session 5). They are the defaults of OpenFGA as constants in `_fga_limits()`, not settings. A GUC for each limit would be the configurable alternative. The cap truncates only the output. The walk still computes every result, so the cap bounds the response, not the work.
10. **Read returns one row of `(tuples jsonb, continuation_token text)`**, the ReadResponse of OpenFGA, not rows with the token on each row. Rows read more naturally in SQL (`jsonb_array_elements` is necessary now). The JSON keeps one token for each page and round-trips into `fga_write`. Its filter arguments keep the `p_` prefix because an output column has the name `continuation_token`.

    > **Status:** the API naming pass of session 5 later removed the `p_` prefix from every public parameter, including the filter arguments of `fga_read`. The text above is the record of the choice at that time. See the section "API naming (session 5)" in [`../decision.md`](../decision.md).
11. **`fga_tuples.seq`** for the order of Read. It is an identity column with a unique index. Every tuple pays for it: 8 bytes plus an index entry, written on every insert. The RLS path never calls the function that uses it. Pagination on the primary key would need no column. But it would give key order, not the insertion order of OpenFGA, and the token would encode the key of six columns.
