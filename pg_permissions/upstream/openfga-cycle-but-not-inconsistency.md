# Check, ListObjects and ListUsers disagree for `[user] but not blocked` when `blocked` is a self-referencing userset cycle (v1.22.1)

## Summary

With a model where a relation subtracts a self-recursive userset relation (`define blocked: [user, document#blocked]`, `define viewer: [user] but not blocked`) and tuples that form a cycle of `blocked` usersets, Check and ListObjects on `viewer` include the object, while ListUsers on the same object returns no users.

A second observation is stronger evidence of a problem. If the model gets an additional path to `user` in `blocked` that no tuple uses (`team#member` -> `group#member` -> `user`), with the same tuples, Check on `viewer` flips from `true` to `false`, while ListObjects does not change.

We do not claim to know which outcome (`true` or `false`) is intended for the first shape. We are reporting that the APIs, and the resolver strategies behind Check, do not agree with each other.

## Environment

- OpenFGA v1.22.1, `openfga/openfga:v1.22.1`, image digest `sha256:b852071314f1fda1194d341a6ebac0a4f619b3cd87a6626d2ccc7048af4ec671` (source commit `44054f5`).
- `run --datastore-engine memory`, HTTP API, no other flags unless noted below.
- Independently reproduced with the official v1.22.1 release binary (commit `44054f5`, in-memory datastore).

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

DSL (control model, same as the original plus an unused path to `user` in `blocked`):

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

The same four tuples are used with both models. No `team` or `group` tuples exist.

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

Create a store, write the original model and the tuples:

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

The script [`openfga-cycle-but-not-repro.sh`](openfga-cycle-but-not-repro.sh) runs the original model, the control model and the two cycle-breaking variants below, each in a fresh store, and prints the results. It needs docker, curl and jq, takes an optional port argument, removes its container on exit, and exits 1 if Check, ListObjects and ListUsers disagree in any scenario, or if the original and control models give different answers to any query (exit 1 means the inconsistency was reproduced). Setup failures (missing tool, `docker run`, health wait, store or model creation, API errors) exit 2.

## Results

All queries ask about `user:jon` and `document:1` (ListObjects over type `document`, ListUsers with filter `user`).

Every value in the table, and in the cycle-breaking variants below, is reproduced by the attached script at both `MINIMIZE_LATENCY` (the default) and `HIGHER_CONSISTENCY`.

| Query | Original model | Control model |
|---|---|---|
| Check(`blocked`, `document:1`) | `false` | `false` |
| Check(`viewer`, `document:1`) | `true` | **`false`** |
| ListObjects(`viewer`) | includes `document:1` (and `document:3`) | **still includes `document:1`** (and `document:3`) |
| ListUsers(`document:1`, `viewer`) | no users | no users |

The control model differs from the original only by the unused `team#member` -> `group#member` -> `user` path in `blocked`; the tuples are identical and no tuple touches `team` or `group`.

Two inconsistencies follow:

1. Original model: for one store, model and set of tuples, Check and ListObjects say `user:jon` is a viewer of `document:1`, and ListUsers says `document:1` has no user viewers.
2. Control model: adding a relation path that no tuple uses changes the Check answer for `viewer` from `true` to `false`, while ListObjects does not change. Check and ListObjects now disagree with each other.

Further observations:

- The results were identical with `consistency: HIGHER_CONSISTENCY` (`CONSISTENCY=HIGHER_CONSISTENCY ./openfga-cycle-but-not-repro.sh`).
- The original-model results were identical in every run: more than 600 runs, each against a fresh container and a fresh store. They were also identical with the server's default settings, with `--experimentals enable-check-optimizations`, and with `--listObjects-pipeline-enabled=false`. We also tried `enable-list-objects-optimizations`, but the container did not start with that flag in our setup and we did not find out why, so that setting is untested.
- 1,000 consecutive Check calls for `viewer` on `document:1` on the original model all returned `true`, in a shell loop against one fresh `openfga/openfga:v1.22.1` container (not part of the script), and again in an independent Python loop against the official release binary. We did not observe the answer flipping over time. That it could change over time is a hypothesis from the planner's probabilistic strategy selection (`internal/planner/plan.go`, see below), not something we saw.

### Cycle-breaking variants (original model)

- Removing one of the two `blocked` userset tuples (the cycle is gone): Check, ListObjects and ListUsers agree that `user:jon` has access to `document:1`.
- Keeping the cycle and explicitly blocking `user:jon` on `document:2` (`user:jon` `blocked` `document:2`): Check, ListObjects and ListUsers agree that `user:jon` does not have access to `document:1`.

## Semantics

The cycle in `blocked` is positive recursion beneath an exclusion: `blocked(document:1)` contains `blocked(document:2)`, which contains `blocked(document:1)`. It is not recursion through the negation itself.

Under least-fixed-point set semantics, the set `blocked(document:1)` = `blocked(document:2)` is the smallest set satisfying those two equations, and that set contains no users. Then `user:jon` is not blocked, remains a `viewer` through the `[user]` base, and `true` is a defensible answer for Check and ListObjects. On the other hand, a rule of "a cycle in the subtracted operand denies" gives `false`, which is what the default Check path and ListUsers do (see the suspected cause). We think both can be argued, and we leave the intended outcome to the maintainers.

The closest upstream test, `true_butnot_cycle_return_false` (`assets/tests/consolidated_1_1_tests.yaml`, around line 8133 at v1.22.1), uses `define restricted: [user, document#viewer]` and `define viewer: [user] but not restricted`, with `document:1#viewer` as a `restricted` userset on `document:1`. There the loop goes back through `viewer` itself (`viewer` -> subtract `restricted` -> `viewer`), which is recursion through negation. It therefore does not settle the shape in this report, where the loop is inside the subtracted relation only. We searched the YAML for a case where the subtracted relation is self-referencing (`define X: [..., T#X]` with `but not X`) and found none (a text match, not a parse of the models).

OpenFGA's blog post on upcoming weighted-graph changes (https://openfga.dev/blog/weighted-graph-upcoming-changes) treats a recursive relation that carries the exclusion itself (`define member: [user, group#member] but not blocked`) as a "circular dependency" that cannot be resolved deterministically. Its recommended pattern keeps the recursion a pure union and puts the exclusion on a separate non-recursive relation (`# Pure union recursion (allowed)`, `define allowed_member: member but not blocked  # Exclusion at leaf level only`). The model in this report has the second shape (`blocked` is recursive, `viewer` applies the exclusion and is not), so the post does not call it broken, but it does not say what the answer should be for it either. The post describes upcoming changes, not v1.22.1.

## Expected

Check, ListObjects and ListUsers should give the same answer for the same store, model and tuples, and the different Check resolver strategies should agree with each other. Adding a relation path that no tuple uses should not change the answer.

Whether the answer should be `true` (jon is a viewer) or `false` (jon is not) is for the maintainers to decide; we have no strong claim on it.

## Suspected cause

This section comes from reading the source at tag v1.22.1 (commit `44054f5`). The code paths below were checked by reading; we did not instrument resolver selection at runtime, so it is a hypothesis.

- `checkDirectUsersetTuples` ([`internal/graph/check.go` L648](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L648)) builds a planner key from the store, model, type, relation and user type. If `typesys.UsersetUseRecursiveResolver(objectType, relation, userType)` is true ([L690](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L690)), it offers two strategies, the default resolver and the recursive resolver, and picks one through `keyPlan.Select` ([L716](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L716); `internal/planner/plan.go`, Thompson sampling).
- `UsersetUseRecursiveResolver` is defined at [`pkg/typesystem/typesystem.go` L679](https://github.com/openfga/openfga/blob/v1.22.1/pkg/typesystem/typesystem.go#L679). It also has an `IsPartOfTupleCycle()` condition ([L695](https://github.com/openfga/openfga/blob/v1.22.1/pkg/typesystem/typesystem.go#L695)) that we did not trace for this model.
- The cold-start priors favour the recursive resolver: `recursivePlan` has `InitialGuess: 150 * time.Millisecond` ([`internal/graph/recursive_resolver.go` L30](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/recursive_resolver.go#L30)), and `defaultRecursivePlan` has `InitialGuess: 500 * time.Millisecond` ([`internal/graph/default_resolver.go` L37](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/default_resolver.go#L37)). With those priors the recursive resolver may be the one picked on a fresh server, which would match the repeatable results. We did not observe which strategy was chosen in any run.
- Optimized recursive Check: `recursiveFastPath` ([`internal/graph/recursive_resolver.go` L82](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/recursive_resolver.go#L82)) returns `Allowed: false` immediately when it finds no user-side starting memberships ([L133-L134](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/recursive_resolver.go#L133-L134)), and also when there is no object-side userset at all ([L106](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/recursive_resolver.go#L106)). These returns do not set `CycleDetected`, and they happen before the cycle is traversed. In this model no user is a direct member of `blocked`, so the first return would apply. The exclusion then sees a subtract operand that is plainly false, and Check on `viewer` returns `true`.
- Default Check: `hasCycle` ([`internal/graph/check.go` L475](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L475)) detects the repeated request and the response carries `CycleDetected: true` ([L425](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L425)). `exclusion` ([L295](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L295)) treats a cycle in either operand as a denial: `Allowed: false` at [L341-L342](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L341-L342) (base) and [L358-L359](https://github.com/openfga/openfga/blob/v1.22.1/internal/graph/check.go#L358-L359) (subtract). So the default path answers `false` for this shape.
- ListUsers: `expandExclusion` ([`pkg/server/commands/listusers/list_users_rpc.go` L771](https://github.com/openfga/openfga/blob/v1.22.1/pkg/server/commands/listusers/list_users_rpc.go#L771)) returns no users when the subtracted branch reports a cycle ([L811](https://github.com/openfga/openfga/blob/v1.22.1/pkg/server/commands/listusers/list_users_rpc.go#L811)).
- In the control model, `UsersetUseRecursiveResolver` should be false for `user` because `blocked` also has an additional multi-hop path to `user` (`document#blocked` -> `team#member` -> `group#member` -> `user`). In OpenFGA's weighted graph each direct edge adds one to its destination's weight ([calculation](https://github.com/openfga/language/blob/pkg/go/v0.3.2/pkg/go/graph/weighted_graph.go#L526)), so `group#member` -> `user` has weight 1, `team#member` -> `group#member` -> `user` has weight 2, and `document#blocked` -> `team#member` -> `group#member` -> `user` has weight 3. That path exceeds the recursive resolver's weight-1 requirement for any entry other than the recursive one ([eligibility check](https://github.com/openfga/openfga/blob/v1.22.1/pkg/typesystem/typesystem.go#L733)), so the default resolver would be the only candidate. That fits the `false` result for Check, but we have not traced it.
- `docs/check/README.md` ("Cycle Detection") describes the default path's handling of cycles.

If this is right, the Check answer for this shape depends on which resolver is used, and the resolvers (and ListUsers) treat a cycle under a subtract differently. ListObjects returning `document:1` in both models is not explained by the code paths above; we did not trace it.

## Impact

- Consumers that use Check, ListObjects and ListUsers for the same access decision get different answers for the same store, model and tuples.
- An unrelated model change (adding a relation path that no tuple uses) changes Check results.
- If the planner picks a different resolver (for example after it has collected enough timing samples for the key, or if the priors change), Check on the same data might answer differently from one moment to the next. We did not observe this; it follows from the suspected cause.

## Notes

We found this while implementing OpenFGA semantics in another system and cross-checking against the reference server. It was independently reproduced with the release binary. We are happy to run further experiments or test a patch.
