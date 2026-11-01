# Check, ListObjects and ListUsers disagree for `[user] but not blocked` when `blocked` is a self-referencing userset cycle (v1.22.1)

**Status:** We sent this report upstream to OpenFGA. This file keeps a copy of the report text. The repro script `openfga-cycle-but-not-repro.sh` is in the same folder.

## Summary

A model has a relation that subtracts a self-recursive userset relation: `define blocked: [user, document#blocked]` and `define viewer: [user] but not blocked`. Tuples of `blocked` usersets form a cycle. In this case, Check and ListObjects on `viewer` include the object. ListUsers on the same object returns no users.

A second observation is stronger evidence of a problem. Add a path to `user` in `blocked` that no tuple uses (`team#member` -> `group#member` -> `user`), and keep the same tuples. Then Check on `viewer` changes from `true` to `false`. ListObjects does not change.

We do not claim to know which outcome (`true` or `false`) is intended for the first shape. We report that the APIs do not agree with each other. The resolver strategies behind Check also do not agree with each other.

## Environment

- OpenFGA v1.22.1, `openfga/openfga:v1.22.1`, image digest `sha256:b852071314f1fda1194d341a6ebac0a4f619b3cd87a6626d2ccc7048af4ec671` (source commit `44054f5`).
- `run --datastore-engine memory`, HTTP API, no other flags unless this report says so.
- We reproduced the result independently with the official v1.22.1 release binary (commit `44054f5`, in-memory datastore).

## Model

DSL (original model):

```
model
  schema 1.1

type user

type document
  relations
    define blocked: [user, document#blocked]
    define viewer: [user] but not blocked
```

JSON (as sent to `POST /stores/{id}/authorization-models`):

```json
{
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "document",
     "relations": {
       "blocked": {"this": {}},
       "viewer": {"difference": {"base": {"this": {}}, "subtract": {"computedUserset": {"relation": "blocked"}}}}},
     "metadata": {"relations": {
       "blocked": {"directly_related_user_types": [{"type": "user"}, {"type": "document", "relation": "blocked"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]
}
```

DSL (control model, the same as the original plus an unused path to `user` in `blocked`):

```
model
  schema 1.1

type user

type group
  relations
    define member: [user]

type team
  relations
    define member: [group#member]

type document
  relations
    define blocked: [user, document#blocked, team#member]
    define viewer: [user] but not blocked
```

JSON (control model):

```json
{
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "group",
     "relations": {"member": {"this": {}}},
     "metadata": {"relations": {
       "member": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "team",
     "relations": {"member": {"this": {}}},
     "metadata": {"relations": {
       "member": {"directly_related_user_types": [{"type": "group", "relation": "member"}]}}}},
    {"type": "document",
     "relations": {
       "blocked": {"this": {}},
       "viewer": {"difference": {"base": {"this": {}}, "subtract": {"computedUserset": {"relation": "blocked"}}}}},
     "metadata": {"relations": {
       "blocked": {"directly_related_user_types": [{"type": "user"}, {"type": "document", "relation": "blocked"}, {"type": "team", "relation": "member"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]
}
```

## Tuples

We use the same four tuples with both models. No `team` or `group` tuples exist.

| user | relation | object |
|---|---|---|
| `user:jon` | `viewer` | `document:1` |
| `user:jon` | `viewer` | `document:3` |
| `document:2#blocked` | `blocked` | `document:1` |
| `document:1#blocked` | `blocked` | `document:2` |

The last two tuples make `document:1#blocked` and `document:2#blocked` members of each other. No user is a direct member of `blocked` on any document.

## Steps to reproduce

Start a fresh server:

```sh
docker run -d --rm --name openfga-repro -p 8080:8080 \
  openfga/openfga:v1.22.1@sha256:b852071314f1fda1194d341a6ebac0a4f619b3cd87a6626d2ccc7048af4ec671 \
  run --datastore-engine memory
```

Create a store, then write the original model and the tuples:

```sh
B=http://localhost:8080
STORE=$(curl -s -XPOST $B/stores -d '{"name":"cycle-but-not"}' | jq -r .id)

MODEL=$(curl -s -XPOST $B/stores/$STORE/authorization-models -d '{
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "document",
     "relations": {
       "blocked": {"this": {}},
       "viewer": {"difference": {"base": {"this": {}}, "subtract": {"computedUserset": {"relation": "blocked"}}}}},
     "metadata": {"relations": {
       "blocked": {"directly_related_user_types": [{"type": "user"}, {"type": "document", "relation": "blocked"}]},
       "viewer": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]}' | jq -r .authorization_model_id)

curl -s -XPOST $B/stores/$STORE/write -d '{"authorization_model_id":"'$MODEL'","writes":{"tuple_keys":[
  {"user":"user:jon","relation":"viewer","object":"document:1"},
  {"user":"user:jon","relation":"viewer","object":"document:3"},
  {"user":"document:2#blocked","relation":"blocked","object":"document:1"},
  {"user":"document:1#blocked","relation":"blocked","object":"document:2"}]}}'
```

Run the queries:

```sh
chk() { curl -s -XPOST $B/stores/$STORE/check -d '{"authorization_model_id":"'$MODEL'","tuple_key":{"user":"user:jon","relation":"'$1'","object":"'$2'"}}'; echo; }

chk blocked document:1
chk viewer  document:1
chk viewer  document:3

curl -s -XPOST $B/stores/$STORE/list-objects \
  -d '{"authorization_model_id":"'$MODEL'","user":"user:jon","relation":"viewer","type":"document"}'; echo

curl -s -XPOST $B/stores/$STORE/list-users \
  -d '{"authorization_model_id":"'$MODEL'","object":{"type":"document","id":"1"},"relation":"viewer","user_filters":[{"type":"user"}]}'; echo
```

Clean up with `docker rm -f openfga-repro`.

The script [`openfga-cycle-but-not-repro.sh`](openfga-cycle-but-not-repro.sh) runs four scenarios, each in a fresh store: the original model, the control model and the two cycle-breaking variants below. It prints the results. It needs docker, curl and jq. It takes an optional port argument and removes its container on exit.

It exits 1 in two cases. In the first case, Check, ListObjects and ListUsers disagree in any scenario. In the second case, the original model and the control model give different answers to any query. Exit 1 means that the script reproduced the inconsistency.

A setup failure exits 2. Setup failures are: a missing tool, `docker run`, the health wait, the creation of a store or model, and an API error.

## Results

All queries ask about `user:jon` and `document:1` (ListObjects over type `document`, ListUsers with filter `user`).

The attached script reproduces every value in the table, and in the cycle-breaking variants below, at both `MINIMIZE_LATENCY` (the default) and `HIGHER_CONSISTENCY`.

| Query | Original model | Control model |
|---|---|---|
| Check(`blocked`, `document:1`) | `false` | `false` |
| Check(`viewer`, `document:1`) | `true` | **`false`** |
| ListObjects(`viewer`) | includes `document:1` (and `document:3`) | **still includes `document:1`** (and `document:3`) |
| ListUsers(`document:1`, `viewer`) | no users | no users |

The control model differs from the original only by the unused `team#member` -> `group#member` -> `user` path in `blocked`. The tuples are identical, and no tuple touches `team` or `group`.

Two inconsistencies follow:

1. Original model: for one store, one model and one set of tuples, Check and ListObjects say that `user:jon` is a viewer of `document:1`. ListUsers says that `document:1` has no user viewers.
2. Control model: when we add a relation path that no tuple uses, the Check answer for `viewer` changes from `true` to `false`. The ListObjects answer does not change. Check and ListObjects now disagree with each other.

Further observations:

- The results were identical with `consistency: HIGHER_CONSISTENCY` (`CONSISTENCY=HIGHER_CONSISTENCY ./openfga-cycle-but-not-repro.sh`).
- The results for the original model were identical in every run: more than 600 runs, each against a fresh container and a fresh store. They were also identical with the default settings of the server, with `--experimentals enable-check-optimizations`, and with `--listObjects-pipeline-enabled=false`. We also tried `enable-list-objects-optimizations`, but the container did not start with that flag in our setup. We did not find the reason, so we did not test that setting.
- 1,000 consecutive Check calls for `viewer` on `document:1` on the original model all returned `true`. We ran them in a shell loop against one fresh `openfga/openfga:v1.22.1` container (not part of the script). We ran them again in an independent Python loop against the official release binary. We did not see the answer change over time. That the answer can change over time is a hypothesis from the probabilistic strategy selection of the planner (`internal/planner/plan.go`, see below). We did not see it.

### Cycle-breaking variants (original model)

- We remove one of the two `blocked` userset tuples, so the cycle is gone. Then Check, ListObjects and ListUsers agree that `user:jon` has access to `document:1`.
- We keep the cycle and block `user:jon` explicitly on `document:2` (`user:jon` `blocked` `document:2`). Then Check, ListObjects and ListUsers agree that `user:jon` does not have access to `document:1`.

## Semantics

The cycle in `blocked` is positive recursion beneath an exclusion. `blocked(document:1)` contains `blocked(document:2)`, which contains `blocked(document:1)`. It is not recursion through the negation itself.

Under least-fixed-point set semantics, the set `blocked(document:1)` = `blocked(document:2)` is the smallest set that satisfies those two equations. That set contains no users. Then `user:jon` is not blocked and remains a `viewer` through the `[user]` base. So `true` is a defensible answer for Check and ListObjects.

On the other hand, the rule "a cycle in the subtracted operand denies" gives `false`. The default Check path and ListUsers give this answer (see the suspected cause). We think that both can be argued, and we leave the intended outcome to the maintainers.

The closest upstream test is `true_butnot_cycle_return_false` (`assets/tests/consolidated_1_1_tests.yaml`, around line 8133 at v1.22.1). It uses `define restricted: [user, document#viewer]` and `define viewer: [user] but not restricted`, with `document:1#viewer` as a `restricted` userset on `document:1`. There the loop goes back through `viewer` itself (`viewer` -> subtract `restricted` -> `viewer`), which is recursion through negation. So the test does not settle the shape in this report, where the loop is inside the subtracted relation only. We searched the YAML for a case where the subtracted relation is self-referencing (`define X: [..., T#X]` with `but not X`), and we found none. This was a text match, not a parse of the models.

The blog post of OpenFGA on upcoming weighted-graph changes (https://openfga.dev/blog/weighted-graph-upcoming-changes) treats a recursive relation that carries the exclusion itself (`define member: [user, group#member] but not blocked`) as a "circular dependency". It says that no one can resolve this deterministically. Its recommended pattern keeps the recursion a pure union and puts the exclusion on a separate non-recursive relation (`# Pure union recursion (allowed)`, `define allowed_member: member but not blocked  # Exclusion at leaf level only`).

The model in this report has the second shape: `blocked` is recursive, and `viewer` applies the exclusion and is not recursive. So the post does not call it broken, but it also does not say what the answer must be for it. The post describes upcoming changes, not v1.22.1.

## Expected

Check, ListObjects and ListUsers must give the same answer for the same store, model and tuples. The different Check resolver strategies must agree with each other. A relation path that no tuple uses must not change the answer.

The maintainers decide if the answer is `true` (jon is a viewer) or `false` (jon is not a viewer). We have no strong claim on it.

## Suspected cause

This section comes from the source at tag v1.22.1 (commit `44054f5`). We checked the code paths below in the source text. We did not instrument the resolver selection at runtime, so this is a hypothesis.

- `checkDirectUsersetTuples` ([`internal/graph/check.go` L648](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L648)) builds a planner key from the store, model, type, relation and user type. When `typesys.UsersetUseRecursiveResolver(objectType, relation, userType)` is true ([L690](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L690)), it offers two strategies: the default resolver and the recursive resolver. It picks one with `keyPlan.Select` ([L716](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L716); `internal/planner/plan.go`, Thompson sampling).
- `UsersetUseRecursiveResolver` is defined at [`pkg/typesystem/typesystem.go` L679](https://github.com/openfga/openfga/blob/v1.22.1/pkg/typesystem/typesystem.go#L679). It also has an `IsPartOfTupleCycle()` condition ([L695](https://github.com/openfga/openfga/blob/v1.22.1/pkg/typesystem/typesystem.go#L695)). We did not trace this condition for this model.
- The cold-start priors favor the recursive resolver. `recursivePlan` has `InitialGuess: 150 * time.Millisecond` ([`internal/graph/recursive_resolver.go` L30](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/recursive_resolver.go#L30)), and `defaultRecursivePlan` has `InitialGuess: 500 * time.Millisecond` ([`internal/graph/default_resolver.go` L37](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/default_resolver.go#L37)). With those priors, the planner can pick the recursive resolver on a fresh server. This would match the repeatable results. We did not see which strategy the planner chose in any run.
- Optimized recursive Check: `recursiveFastPath` ([`internal/graph/recursive_resolver.go` L82](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/recursive_resolver.go#L82)) returns `Allowed: false` immediately when it finds no user-side starting memberships ([L133-L134](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/recursive_resolver.go#L133-L134)). It also does this when there is no object-side userset at all ([L106](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/recursive_resolver.go#L106)). These returns do not set `CycleDetected`, and they happen before the code traverses the cycle. In this model no user is a direct member of `blocked`, so the first return applies. The exclusion then sees a subtract operand that is plainly false, and Check on `viewer` returns `true`.
- Default Check: `hasCycle` ([`internal/graph/check.go` L475](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L475)) detects the repeated request, and the response carries `CycleDetected: true` ([L425](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L425)). `exclusion` ([L295](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L295)) treats a cycle in either operand as a denial: `Allowed: false` at [L341-L342](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L341-L342) (base) and [L358-L359](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L358-L359) (subtract). So the default path answers `false` for this shape.
- ListUsers: `expandExclusion` ([`pkg/server/commands/listusers/list_users_rpc.go` L771](https://github.com/openfga/openfga/blob/v1.22.1/pkg/server/commands/listusers/list_users_rpc.go#L771)) returns no users when the subtracted branch reports a cycle ([L811](https://github.com/openfga/openfga/blob/v1.22.1/pkg/server/commands/listusers/list_users_rpc.go#L811)).
- In the control model, we expect `UsersetUseRecursiveResolver` to be false for `user`. The reason is that `blocked` also has an extra multi-hop path to `user` (`document#blocked` -> `team#member` -> `group#member` -> `user`). In the weighted graph of OpenFGA, each direct edge adds one to the weight of its destination ([calculation](https://github.com/openfga/language/blob/pkg/go/v0.3.2/pkg/go/graph/weighted_graph.go#L535-L543)). So `group#member` -> `user` has weight 1, `team#member` -> `group#member` -> `user` has weight 2, and `document#blocked` -> `team#member` -> `group#member` -> `user` has weight 3.

  That path exceeds the weight-1 requirement of the recursive resolver for any entry other than the recursive one ([eligibility check](https://github.com/openfga/openfga/blob/v1.22.1/pkg/typesystem/typesystem.go#L733)). So the default resolver would be the only candidate. This fits the `false` result for Check, but we did not trace it.
- `docs/check/README.md` ("Cycle Detection") describes how the default path handles cycles.

If this is right, the Check answer for this shape depends on the resolver in use. The resolvers (and ListUsers) treat a cycle under a subtract in different ways. The code paths above do not explain why ListObjects returns `document:1` in both models. We did not trace it.

## Impact

- Consumers that use Check, ListObjects and ListUsers for the same access decision get different answers for the same store, model and tuples.
- An unrelated model change (the addition of a relation path that no tuple uses) changes the Check results.
- If the planner picks a different resolver, Check on the same data can answer differently from one moment to the next. This can happen, for example, after the planner has collected enough timing samples for the key, or if the priors change. We did not see this. It follows from the suspected cause.

## Notes

We found this while we implemented the semantics of OpenFGA in another system and cross-checked against the reference server. We reproduced it independently with the release binary. We are glad to run more experiments or to test a patch.
