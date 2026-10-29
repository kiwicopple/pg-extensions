# Check and ListObjects return true, ListUsers returns nothing, for `[user] but not blocked` when `blocked` is a self-referencing userset cycle (v1.22.1)

## Summary

With a model where a relation subtracts a self-recursive userset relation (`define blocked: [user, document#blocked]`, `define viewer: [user] but not blocked`) and tuples that form a cycle of `blocked` usersets in which no user is ever blocked, Check and ListObjects on `viewer` include the object, while ListUsers on the same object returns no users. The result is the same on every run against a fresh server. Adding a second way to reach `user` in `blocked` (see the control experiment) makes Check return false.

## Environment

- OpenFGA v1.22.1, `openfga/openfga:v1.22.1`, image digest `sha256:b852071314f1fda1194d341a6ebac0a4f619b3cd87a6626d2ccc7048af4ec671` (source commit `44054f5`).
- `run --datastore-engine memory`, HTTP API, no other flags unless noted below.

## Model

DSL:

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

## Tuples

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

Create a store, write the model and the tuples:

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

The same steps are in the script [`openfga-cycle-but-not-repro.sh`](openfga-cycle-but-not-repro.sh) (needs docker, curl and jq; optional port argument; removes its container on exit; prints actual against expected).

## Actual

| Query | Result |
|---|---|
| Check(`user:jon`, `blocked`, `document:1`) | `false` |
| Check(`user:jon`, `viewer`, `document:1`) | **`true`** |
| Check(`user:jon`, `viewer`, `document:3`) | `true` |
| ListObjects(`user:jon`, `document`, `viewer`) | **`document:1`, `document:3`** |
| ListUsers(`document:1`, `viewer`, filter `user`) | **no users** |

So for one store, one model and one set of tuples, Check and ListObjects say `user:jon` is a viewer of `document:1`, and ListUsers says `document:1` has no user viewers.

The results were identical in every run: more than 600 runs, each against a fresh container and a fresh store. They were also identical with the server's default settings, with `--experimentals enable-check-optimizations`, and with `--listObjects-pipeline-enabled=false`. We also tried `enable-list-objects-optimizations`, but the container did not start with that flag in our setup and we did not find out why, so that setting is untested.

## Expected

`user:jon` is not blocked on `document:1`. `blocked` on `document:1` is a pure cycle of usersets (`document:1#blocked` contains `document:2#blocked`, which contains `document:1#blocked`) and no user is ever a member of it. By the consolidated test suite (see below) a cycle under the subtract of a `but not` makes the difference false, so we expected Check(`viewer`, `document:1`) to be `false`, and ListObjects to return only `document:3`. That is also what ListUsers returns, and what Check returns for `blocked` alone and in the control experiment below.

At a minimum, we would expect Check, ListObjects and ListUsers to agree with each other for the same store, model and tuples.

For comparison, the repository's own cases with a cycle under a `but not` in `assets/tests/consolidated_1_1_tests.yaml` expect `false`: `true_butnot_cycle_return_false` (closest to this report: `define restricted: [user, document#viewer]`, `define viewer: [user] but not restricted`, with `document:1#viewer` as a `restricted` userset on `document:1`), `false_butnot_cycle_return_false` and `cycle_butnot_false_return_false`. In those cases the cycle goes through `viewer`, or the subtracted relation is not itself a self-referencing userset. We searched the YAML for a case where the subtracted relation is self-referencing (`define X: [..., T#X]` with `but not X`) and found none, so this exact shape does not appear to be covered by the suite. (The search was a text match, not a parse of the models.)

## Control experiment

Same tuples, same `viewer`, but `blocked` also allows a second path to users:

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

With the same four tuples, Check(`user:jon`, `viewer`, `document:1`) returned `false` in 100 of 100 runs, and we did not record the other queries for it. The only relevant change is that `blocked` now reaches `user` through `team#member` -> `group#member` as well as directly. The DSL above is written from the description of that experiment; it has not been re-run in preparing this report, so please treat it as a sketch of the shape rather than a verified artifact.

## Suspected cause

This section comes from reading the source at commit `44054f5`. We did not trace it at runtime, so it is a hypothesis.

- `checkDirectUsersetTuples` (`internal/graph/check.go`, around lines 648-720) builds a planner key from the store, model, type, relation and user type. If `typesys.UsersetUseRecursiveResolver(objectType, relation, userType)` is true (`pkg/typesystem/typesystem.go`, around line 679), it offers two strategies, the default resolver and the recursive resolver, and picks one through `keyPlan.Select` (`internal/planner/plan.go`, Thompson sampling).
- The cold-start priors favour the recursive resolver: `recursivePlan` has `InitialGuess: 150 * time.Millisecond` (`internal/graph/recursive_resolver.go`, around line 28), and `defaultRecursivePlan` has `InitialGuess: 500 * time.Millisecond` (`internal/graph/default_resolver.go`, around line 34). With those priors, the recursive resolver looks like the one that is chosen essentially every time on a fresh server, which would match the repeatable results above. We did not see which strategy was chosen in any run.
- The default path evaluates the subproblem through `LocalChecker.ResolveCheck`, where `hasCycle` (`check.go`, around line 475) returns a response with `CycleDetected: true`, and `exclusion` (`check.go`, around line 295) turns a cycle in either operand into `Allowed: false`. The recursive resolver (`recursiveUserset`, `breadthFirstRecursiveMatch` in `recursive_resolver.go`) tracks visited usersets in its own `visitedUserset` set, and as far as we can see never sets `CycleDetected`. Our guess is that in the subtract, `blocked` therefore evaluates to a plain "not found" (false, no cycle flag), `viewer` is true from the `[user]` base, and Check returns true.
- `docs/check/README.md` ("Cycle Detection") describes the default path's handling of cycles.
- In the control model, `UsersetUseRecursiveResolver` should be false for `user` because `blocked` also has a weight-2 path to `user` (the function's doc comment says any other entry must have weight 1), so the default resolver is the only candidate. That fits the false result, but again we have not traced it.

If this is right, the answer to Check on this shape depends on which resolver the planner picks, and the two resolvers treat a cycle under a subtract differently.

## Impact

- The same question gets different answers depending on the API: Check and ListObjects say `user:jon` can view `document:1`, ListUsers says nobody can.
- If the planner picks a different resolver (for example after it has collected enough timing samples for the key, or if the priors change), Check on the same data may answer differently from one moment to the next. We did not observe this; it follows from the suspected cause.
- Anything that uses Check for access decisions and ListUsers (or an audit built on it) to report who has access will reach different conclusions about the same object.

## Notes

We found this while implementing the OpenFGA check/list semantics in another system and cross-checking our results against the reference server, using the consolidated test suite as the oracle. Our implementation passes all of the suite's cases and still differs from the server on this shape. We do not know which answer is intended; the `*_butnot_cycle_return_false` cases and ListUsers suggest `false`. We are happy to run further experiments or test a patch.
