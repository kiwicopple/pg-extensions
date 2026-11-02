# Design E: the Cedar model (`cedar_*`) in PL/pgSQL

> Status: phase 0 of [`plan-cedar.md`](../plan-cedar.md), approved with its deviations (static limits, the `ast` column, errors as SQL null, the verbatim principal type, `resource_attrs` replacing attributes). Phases 2, 3, 4a, 4b, 4c, 5 and 6 are implemented in `pg_permissions--0.1.0.sql`: the core evaluator, the text parser, the extension types, templates, the policy index and RLS helpers, and the integration (`delete_subject`, grants, the upgrade path). Section 12 has the phase 2 measurements and decisions, section 13 the decisions of phases 3 and 4c, section 14 those of the extension types, section 15 those of phase 5, and section 16 those of phase 6. The whole corpus passes. The oracle is vendored in [`test/cedar/`](../../test/cedar/README.md).

The sources for this page are:

- cedar-policy/cedar-integration-tests at `b157547` (tag `v4.14.0`, 2026-10-19). The corpus came from cedar `bcb8bd93` and cedar-spec `4748ff09`, which are the submodule pointers of that commit.
- cedar-policy-cli 4.14.0 from crates.io. It was built in `rust:1.89-slim-bookworm@sha256:d7fc7de…` and ran with `--network none`.
- cedar `v4.14.0`, `cedar-testing/src/integration_testing.rs`. This file is the harness that Cedar runs on the same tests.
- cedar `v4.14.0`, `cedar-policy-core/src/entities/json/entities.rs`. This file shows how Cedar parses entities with a schema.
- [docs.cedarpolicy.com: JSON policy format](https://docs.cedarpolicy.com/policies/json-format.html) and [entities and context syntax](https://docs.cedarpolicy.com/auth/entities-syntax.html), read on 2026-11-02.

Section 8 has a measurement. [`e-cedar/measure.sql`](./e-cedar/measure.sql) runs it, and the measurement has the tag `cedar-eval-micro`.

## 1. The oracle

### 1.1 What is vendored

`test/cedar/vendor.sh` fetches the pinned commit and checks the SHA-256 of `corpus-tests.tar.gz`. It then builds the CLI of the same release and translates every Cedar-text policy file and schema to JSON. Finally, it runs `convert.py`. The script is reproducible: a second run gave byte-identical files.

| Committed | Size |
| --- | --- |
| `cases/corpus-01..08.jsonl.gz`: the 5,677 corpus tests in normalized form, gzip with `mtime` 0 | 3.2 MB, at most 0.5 MB for each shard |
| `cases/handwritten.jsonl`: the 24 handwritten tests | 97 KB |
| `upstream/tests/`, `upstream/sample-data/`, `LICENSE`, `NOTICE` and `SOURCE`, verbatim | 240 KB |

The extracted corpus is 188 MB, so it is not committed. Each case line holds these fields:

- The policies, split for each policy id. Each policy has its Cedar text and its EST from the CLI.
- The entities.
- The requests, with the expected decision, reasons and errors.
- `schemaDependent`, which lists the changes that convert.py made for schema-free parsing (section 1.3).

Two checks confirmed the conversion:

1. Each of the 5,708 text policies was split out of its file and translated again with the CLI. U+0000 was substituted first (section 1.3). Every policy gave back exactly the EST in `cases/`.
2. A stub `cedar_*` API ran every generated file for each format and mode. The stub returns `deny` with no reasons. Each file ran with no SQL error and with exactly its planned number of assertions. The number of passing assertions was 14,375, which equals the number of requests that expect `deny` with no reasons and no errors.

### 1.2 Counts

`python3 -I test/cedar/generate.py --stats` prints these tables. The plan estimated about 7,500 files and 60,000 requests. The real counts are smaller.

| | Tests | Requests |
| --- | --- | --- |
| Corpus | 5,677 | 45,416 |
| Handwritten | 24 | 78 |
| **Total** | **5,701** | **45,494** |
| Expected decision `allow` / `deny` | | 24,164 / 21,330 |
| Requests that expect errors | | 3,408 (539 of them in the phase 2 subset) |
| Requests with a non-empty `context` | | 6,417 |

| `policyFormat` | Tests | Requests |
| --- | --- | --- |
| `cedar` (text) | 5,700 | 45,492 |
| `json` | 1 (handwritten) | 2 |

| `shouldValidate` | Tests | Requests |
| --- | --- | --- |
| true | 4,523 | 36,070 |
| false | 1,178 | 9,424 |

**Every corpus test is in Cedar text.** The JSON-format oracle for phase 2 therefore comes from the CLI translations in `cases/`. These translations also give phase 3 a parser oracle: the text of each policy must parse to its EST (`--check-est`).

In the next table, each test counts once for each feature that it uses. A feature can come from a policy or from the data. For example, `decimal` counts a `decimal(...)` call, a decimal method, or a decimal `__extn` value in an entity or the context.

| Feature | Tests | Requests | | Feature | Tests | Requests |
| --- | --- | --- | --- | --- | --- | --- |
| `ipaddr` | 1,155 | 9,224 | | `has` | 356 | 2,829 |
| `datetime` | 948 | 7,584 | | `compare` (`<` and the others) | 337 | 2,685 |
| `duration` | 579 | 4,632 | | `like` | 172 | 1,376 |
| `decimal` | 478 | 3,813 | | `arith` (`+`, `-`, `*`, `neg`) | 91 | 728 |
| `logic` (`&&`, `\|\|`, `!`) | 2,308 | 18,431 | | `annotations` | 938 | 7,504 |
| `if` (if-then-else) | 870 | 6,960 | | template (slots, templates, links) | **0** | **0** |
| `set` (literals and set methods) | 871 | 6,963 | | U+0000 in any string | 2,137 | 17,096 |
| `record` (literals) | 768 | 6,144 | | expected errors | 640 | 5,120 |
| `in` (expression) | 709 | 5,672 | | schema-dependent JSON | 24 | 78 |
| `is` (scope or expression) | 690 | 5,520 | | | | |
| tags (`hasTag`, `getTag` or entity tags) | 534 | 4,272 | | | | |

Of the 5,701 tests, 3,360 tests (26,793 requests) use no extension type. Of the 5,709 policies:

- Effect: 3,570 are `permit` and 2,139 are `forbid`.
- Principal scope: `All` 3,435, `==` 785, `in` 1,094, `is` 135, and `is ... in` 260.
- Resource scope: `All` 3,406, `==` 745, `in` 1,056, `is` 229, and `is ... in` 273.
- Action scope: `All` 3,140, `==` 748, `in` one entity 982, and `in` a set 839.
- Conditions: 5,692 policies have one `when`, 15 have none, and 2 have two. There are 3 `unless` conditions in total.

| Size (maximum over the tests; p99 in brackets) | Value |
| --- | --- |
| Policies in a test | 4 [1] |
| Text of one policy | 14,517 bytes [1,960] |
| EST of one policy | 34,520 bytes [3,883] |
| Expression nesting depth | 14 [11] |
| Expression nodes in one policy | 489 [140] |
| Entities in a test | 151 [117] |
| Entity JSON of a test | 606 KB [318 KB] |
| Depth of the entity hierarchy | 117 [53] |
| Attributes of one entity | 147 |
| Nesting of a value (records and sets) in data | 4 |
| Long values | the full i64 range, including −2^63 |
| Requests in a test | 8 [8] |

### 1.3 What the corpus does not test, and the data transformations

The corpus does not cover these areas. The listed phases add in-house specs for them, in the normal spec files:

- **Templates.** No test has a template or a link. For phase 4c, `generate.py --templatize` turns each policy whose principal or resource scope names an entity into a template and a link. The link reuses the original policy id, so the expectations still hold. This gives 1,276 links. In-house specs cover slot errors and the template admin API.
- **Transitive `in`.** Every corpus entity JSON lists all ancestors in `parents`, because Cedar writes entities with the closure already computed. A broken closure would still pass the corpus. Phase 2 adds specs that store only the direct parents. A later option, `--reduce-parents`, could remove the implied parents from the corpus data. The corpus has no cycles. It has 888 parent references to entities that are not defined. Cedar accepts these references, and so must we.
- **Parse errors.** Every corpus policy parses. Phase 3 writes the negative cases itself.
- **Admin API errors.** Unknown ids, bad entity JSON, limits and null arguments need in-house specs, as for `rbac` and `fga`.

Schema-based parsing. Cedar's harness parses entities and context with the test's schema. In `integration_testing.rs`, the harness calls `Entities::from_json_file(json, Some(schema))` and `Context::from_json_value(json, Some((schema, action)))`. The schema has two effects:

1. It adds the action entities that the schema declares (`entities.rs:212`).
2. It accepts implicit forms: an extension value without `__extn`, even a bare string, and an entity reference without `__entity`.

`convert.py` applies both effects to the vendored data. The cases therefore hold what Cedar sees, in the schema-free form with explicit escapes. The counts are:

| Change | Corpus tests | Handwritten tests |
| --- | --- | --- |
| Action entities taken from the schema | 0 | 24 |
| An entity reference without `__entity` | 0 | 10 |
| An extension value without `__extn` | 0 | 0 |

U+0000. Postgres `text` and `jsonb` cannot hold U+0000, but 2,137 tests use it. The tests use it in entity ids, attribute names, record keys, strings and `like` patterns. The generator replaces U+0000 with U+E000 in every string of the case, including the escapes in Cedar text. Cedar has no string length, string ordering or string indexing. Equality, `like`, `has`, `getTag` and record keys therefore give the same answers. No test contains U+E000.

## 2. Policies: the EST

### 2.1 The stored form: Cedar's JSON policy format, verbatim

`cedar_policies.est` holds one policy in the [JSON policy format](https://docs.cedarpolicy.com/policies/json-format.html), exactly as Cedar defines it. The column holds the policy object, not the policy-set wrapper. The fields are:

- `effect`: `"permit"` or `"forbid"`.
- `principal` and `resource`, each with an `op`:
  - `{"op":"All"}`
  - `{"op":"==","entity":E}` or `{"op":"==","slot":"?principal"}`
  - `{"op":"in","entity":E}`, or `in` with a slot
  - `{"op":"is","entity_type":"T"}`, with an optional `"in":{"entity":E}` or `"in":{"slot":…}`
- `action`, with one of these forms:
  - `{"op":"All"}`
  - `{"op":"==","entity":E}`
  - `{"op":"in","entity":E}`
  - `{"op":"in","entities":[E,…]}`
- `conditions`: a list of `{"kind":"when"|"unless","body":Expr}`.
- `annotations`: an object of string values. A value of `null` is the same as `""`.

In scope, an entity reference is `E = {"type":"T","id":"x"}`.

An expression is an object with one key:

| Key | Value |
| --- | --- |
| `Value` | A Cedar JSON value. An entity is written as `{"__entity":…}`. |
| `Var` | `"principal"`, `"action"`, `"resource"` or `"context"`. |
| `Slot` | `"?principal"` or `"?resource"`. |
| `!`, `neg`, `isEmpty` | `{"arg":…}` |
| A binary operator: `==`, `!=`, `in`, `<`, `<=`, `>`, `>=`, `&&`, `\|\|`, `+`, `-`, `*`, `contains`, `containsAll`, `containsAny`, `hasTag`, `getTag` | `{"left":…,"right":…}` |
| `.`, `has` | `{"left":…,"attr":"a"}` |
| `is` | `{"left":…,"entity_type":"T","in":…}`, where `in` is optional |
| `like` | `{"left":…,"pattern":["Wildcard",{"Literal":"…"},…]}` |
| `if-then-else` | `{"if":…,"then":…,"else":…}` |
| `Set` | `[…]` |
| `Record` | `{"k":…}` |
| An extension function or method, for example `decimal`, `ip`, `isInRange`, `offset` or `toDays` | `[receiver, args…]` |

Reasons:

1. It is the official interchange format. `cedar_put_policy(policy_json => …)` accepts what Cedar emits. `cedar_policies()` returns what Cedar accepts. The JS client has nothing to translate.
2. The CLI emits it for every corpus policy, so `cases/` holds the exact expected parse for each text policy.

`policy_json` input is checked for its shape on put, and it is then stored as given. Any error raises `cedar:invalid_policy` with a JSON path. The check rejects unknown keys, a wrong `op`, a slot in a static policy, and a static form in `cedar_put_template`.

### 2.2 Text parses into the same EST

The text parser must produce exactly what the CLI produces, so that `jsonb` equality is the phase 3 oracle. These CLI forms were observed in `cases/`:

- A negative integer literal is folded into `Value`. For example, `-8463800223671044554` becomes `{"Value":-8463800223671044554}`. `-` before any other expression gives `neg`.
- `Var` has a plain string value.
- An entity literal in an expression is `{"Value":{"__entity":{"type","id"}}}`.
- Extension calls are nodes named after the function.
- The `has` form for a single attribute is `{"has":{"left","attr":"a"}}`.
- `like` patterns are a list of `"Wildcard"` and `{"Literal":"…"}` items.
- Annotations go to `annotations`, and `@id("x")` does not set the policy id of a put (section 13.2).

Phase 3 runs the oracle with `generate.py --phase 3`, which includes `--check-est`. It covers 3,359 tests and 26,791 requests, plus one EST assertion for each policy. `--parse-est` checks the parser alone on all 5,708 text policies, including those with extension types (section 13.5).

### 2.3 The compiled form: a second column, `ast`

The evaluator does not walk the EST. At put time, the EST is compiled into `cedar_policies.ast`:

- Each node has a `k` field for its kind.
- Literals are converted to the internal values of section 3.
- `like` patterns become SQL `LIKE` patterns.
- Set and record literals of constants are folded into one literal.
- An extension constructor whose argument is a valid string literal is folded into a literal. An invalid literal is kept as a call, so the error happens at evaluation, as in Cedar.
- The conditions are joined in order into one `and` chain. `unless c` becomes `not c`.

The measurement in section 8 shows why. With one walker and one expression, the EST costs 17.3 µs and the compiled tree costs 8.0 µs. The EST walker must find the only key of each node with `jsonb_object_keys`.

| `ast` node | Shape |
| --- | --- |
| Literal | `{"k":"lit","v":<internal value>}` |
| Variable | `{"k":"var","n":"principal"}` |
| `&&`, `\|\|` | `{"k":"and","a":x,"b":y}` and `{"k":"or",…}` |
| if-then-else | `{"k":"if","c":c,"t":t,"e":e}` |
| Unary | `{"k":"not"\|"neg"\|"isEmpty","a":x}` |
| Binary | `{"k":"eq"\|"ne"\|"lt"\|"le"\|"gt"\|"ge"\|"add"\|"sub"\|"mul"\|"in"\|"contains"\|"containsAll"\|"containsAny"\|"hasTag"\|"getTag","a":x,"b":y}` |
| Attribute | `{"k":"get","a":x,"f":"name"}`, `{"k":"has","a":x,"f":"name"}` |
| `is` | `{"k":"is","a":x,"t":"T"}`, with `"in":y` |
| `like` | `{"k":"like","a":x,"p":"<LIKE pattern with \\ escapes>"}` |
| Set, record | `{"k":"set","a":[…]}`, `{"k":"rec","a":{"key":x}}` |
| Extension | `{"k":"call","f":"isInRange","a":[x,y]}` |

The scope is not in `ast`. It goes into indexed columns of `cedar_policies`:

- The principal scope: the operator, the type and the UID.
- The action UIDs, as an array.
- The resource scope: the operator, the type and the UID.

The authorizer matches the scope in SQL. It evaluates `ast` only for the policies whose scope matches.

A template link stores its template id and the slot values. It also stores the `ast` and the scope columns of the template, with the slots filled in at link time. The evaluator never sees a slot.

## 3. Value model

The evaluator passes all values as `jsonb`. Each Cedar value has one canonical internal form. As a result, Cedar `==` is `jsonb` equality, and a comparison of different types is `false` with no extra code.

| Cedar type | Entity and context JSON (input, and `cedar_read_entities` output) | Internal (`ast` literals, stored `attrs` and `tags`, evaluation) |
| --- | --- | --- |
| Bool | `true` | `true` |
| Long | a JSON integer | a JSON number. Input must be an integer from −2^63 to 2^63−1. |
| String | `"s"` | `"s"`. U+0000 raises `cedar:unsupported`. |
| Entity | `{"__entity":{"type":"T","id":"x"}}`, or `{"type","id"}` in `uid` and `parents` | `{"__entity":{"type":"T","id":"x"}}` |
| Set | `[…]` | A sorted array with no duplicates, ordered by `jsonb` order. Inner values are also canonical. |
| Record | `{…}` | An object whose values are canonical |
| decimal | `{"__extn":{"fn":"decimal","arg":"1.23"}}` | `{"__extn":{"fn":"decimal","v":12300}}`: the i64 value × 10^4 |
| ipaddr | `{"__extn":{"fn":"ip","arg":"10.0.0.1/24"}}` | `{"__extn":{"fn":"ip","v":"10.0.0.1/24"}}`: the `inet` text with the prefix length always written (`10.0.0.1/32` for `ip("10.0.0.1")`), so equality keeps the host bits and the prefix length |
| datetime | `{"__extn":{"fn":"datetime","arg":"2024-01-01T00:00:00Z"}}` | `{"__extn":{"fn":"datetime","v":1704067200000}}`: i64 milliseconds since the epoch |
| duration | `{"__extn":{"fn":"duration","arg":"1h30m"}}` | `{"__extn":{"fn":"duration","v":5400000}}`: i64 milliseconds |

The rules are:

- **Long and overflow.** `jsonb` numbers have arbitrary precision, so a Long stays a JSON number and is never a string. Input is checked when an entity or context is put: the value must be an integral number in the i64 range. The check uses `scale(v::numeric) = 0`, so `1.0` is rejected. Cedar also rejects `1.0`. `jsonb` turns `1e3` into `1000` before the check sees it, so `1e3` is accepted. This is a divergence. `+`, `-`, `*` and `neg` compute in `numeric` and then compare the result with the i64 bounds. Out of range, the result is an `overflow` error value. A `bigint` operation would raise an exception, and an exception means a subtransaction in the hot path.
- **datetime and duration** are i64 milliseconds, as in Cedar (RFC 80). They are not `timestamptz`. `offset` can leave the range of `timestamptz`, which Cedar allows until the i64 limit. Parsing, `toDate` and `toTime` are integer arithmetic on the milliseconds, with no `timestamptz` at all, because Cedar's years run from 0000. Cedar's own parsers read the text forms; the toolkit helpers follow Go and differ (section 14.2).
- **ipaddr.** The text is the canonical `inet` text. `isInRange`, `isLoopback` and the other methods use `inet` operators. The constructor accepts exactly what Cedar's `ip()` accepts (section 14.2): no zones, and no IPv4 embedded in IPv6.
- **Sets.** A set is canonicalized when it is built: in a literal at compile time, in data at put time, and in the context once for each request. Equality is then `jsonb` equality. Do not use `jsonb @>` for `contains`, because it matches records partially. `contains`, `containsAll` and `containsAny` compare whole elements in SQL.
- **The escape ambiguity.** In this model, a record whose only key is `__entity` or `__extn` would read as an entity or an extension value. Cedar's own JSON format has the same ambiguity. Such a record can still come from a record literal in a policy, for example `{"__entity": …}`. The compiler rejects it with `cedar:unsupported`.
- **The form of extension values.** Internal extension values have the key `v`, and the input form has the key `arg`. A value can therefore never be in the wrong form without an error. Input is converted once, when it is put or when the request starts. Output (`cedar_read_entities`) converts it back to the text form.

## 4. Evaluator

### 4.1 Shape

There is one recursive PL/pgSQL function, `_cedar_eval(ast jsonb, env jsonb) returns jsonb`. SQL `NULL` is an error.

- The hot path never builds an error message.
- When a policy returns `NULL`, the authorizer evaluates that policy once more with `_cedar_eval_why`. This variant has the same code with an extra flag. It raises at the first error with the message. The authorizer catches the exception and stores the message. Evaluation is deterministic, so the second run fails at the same node.
- Errors are rare. A subtransaction per error is cheap, and a subtransaction per evaluation is not.
- This replaces the composite `fga_cel_value` of CEL, which costs 9.5 µs where the `jsonb`-or-`NULL` form costs 8.0 µs (section 8).

`env` is built once for each request. It holds `principal`, `action`, `resource` and `context` as internal values. It also holds an `overlay` map from the UID key to an entity, built from the `entities` argument. In RLS, it holds `resource_attrs` too. The UID key is the Cedar text form, `T::"id"`, with Cedar escapes. This key is unique.

### 4.2 Evaluation rules

These rules are Cedar's. The corpus judges them.

- **`&&` and `||`.** The left side is evaluated first. If the left side is an error or not a Bool, the result is an error. If the left side decides the result, the right side is not evaluated. Otherwise the right side must be a Bool, or the result is an error.
- **if-then-else.** The condition must be a Bool. Only the chosen branch is evaluated.
- **Other operators** evaluate every operand from left to right. The first error is the result.
- **`==` and `!=`** never give an error. Values of different types are not equal.
- **Comparisons.** `<`, `<=`, `>` and `>=` need two Longs, two datetimes or two durations. Other types give a type error. The decimal comparisons are methods (`lessThan` and the others): Cedar 4.14 overloads the operators for datetime and duration only, so `decimal("1.0") < decimal("2.0")` is a type error.
- **`in`.**
  - The left side must be an entity. The right side must be an entity or a set of entities.
  - `A in B` is true if `A == B` or if `B` is an ancestor of `A`.
  - An entity that does not exist has no ancestors. This is not an error.
- **`.`, `has`, `getTag` and `hasTag` on an entity.** These look the entity up in this order:
  1. The request overlay.
  2. The `resource_attrs` overlay, which applies to the request resource only, in the RLS helpers.
  3. The stored entities.

  On a missing entity or attribute, `.` and `getTag` give an error, and `has` and `hasTag` give `false`. This is how Cedar's evaluator behaves, as far as we know, and the corpus confirms it in phase 2.
- **`like`** runs SQL `LIKE` with `collate "C"`. `*` becomes `%`. The characters `%`, `_` and `\` are escaped. `\*` is a literal star.
- **`is`** compares the entity type exactly. `is T in X` is `is T` and `in X`.

### 4.3 Cost and depth

Cedar has no loops and no comprehensions. Evaluation time is therefore linear in the size of the tree plus the size of the values that the set operations touch. **This design replaces the plan's runtime cost counter with static limits** (section 6):

- A maximum number of nodes in each policy and a maximum nesting depth, checked at put time.
- Size limits on the entity and context input.

There is no counter in the evaluation loop, so there is no cost for each node. The nesting depth also bounds the PL/pgSQL recursion, and `max_stack_depth` is never reached. If a later phase finds a slow input that the limits do not cover, a counter can be added to `env` then.

### 4.4 The authorization algorithm

1. Parse and check the request:
   - The UID text of principal, action and resource.
   - The context, which must be a record. Its values are converted to the internal form.
   - The overlay entities.

   Bad input raises an API error (section 5). It is not an evaluation error.
2. Select the candidate policies by the scope columns. The action must match: `All`, `==` the action, or `in` an entity that is the action or one of its ancestors. The principal and resource scopes must match: `==` the UID, `in` the UID or one of its ancestors, or `is` the type.
3. Evaluate `ast` for each candidate. True adds the policy to the satisfied set. An error adds the policy to `errors`.
4. The decision:
   - If any `forbid` is satisfied, the decision is `deny`, and the reasons are the satisfied forbids.
   - Else, if any `permit` is satisfied, the decision is `allow`, and the reasons are the satisfied permits.
   - Else, the decision is `deny` with no reasons.
5. Return `{"decision","reasons":[ids],"errors":[{"policy_id","message"}]}`. The ids are sorted with `collate "C"`.

### 4.5 Ancestors: candidates for the phase 2 measurement

| Candidate | Read | Write | Overlay |
| --- | --- | --- | --- |
| A. Closure table `cedar_entity_ancestors`, maintained on put and delete | one index probe for each `in` | Recomputes the descendants. B needed a global advisory lock to stay correct under concurrent writes. A lock for each connected component is the candidate fix, but it is not proven. | An overlay entity overrides its stored parents, so `in` still has to walk when there is an overlay |
| B. A recursive CTE over `cedar_entity_parents` with an index on `(type, id)`, for each `in` | O(depth) probes. The corpus reaches depth 117. | none | natural: each step checks the overlay first |
| C. B, plus the ancestors of the principal and the resource computed once for each request and kept in `env` | one lookup for most `in` tests, because the left side is usually `principal` or `resource` | none | natural |

Phase 2 measures A and C at depths 1, 10 and 117, measures the write throughput under concurrency, and measures the RLS cost for each row. The rule of the plan applies: use the faster option that has no global lock. Cedar rejects a hierarchy with a cycle (to confirm against `transitive_closure.rs` in phase 2). The put must reject a cycle too (`cedar:invalid_entity`), across stored entities.

**Decided in phase 2: C** (section 12.1).

## 5. Error model

API and argument errors raise. The `DETAIL` is `cedar:<code>`, followed by context in the `key='value'` form. The `MESSAGE` names the values. The `HINT` gives the fix in one sentence. It adds "Did you mean …?" from `_did_you_mean` where a name could be misspelt: policy and template ids, entity types in `cedar_read_entities`, and extension functions and methods in parse errors.

| `DETAIL` | SQLSTATE | Raised by | Cause |
| --- | --- | --- | --- |
| `cedar:parse_error line=<n> column=<n>` | `42601` | `cedar_put_policy`, `cedar_put_template` (text) | The text is not one Cedar policy. Also when the text has no policy or more than one. |
| `cedar:invalid_policy path='<json path>'` | `22023` | the same functions (JSON) | The `policy_json` does not have the shape of the format. Also a slot in a static policy, or no slot in a template. |
| `cedar:unknown_policy policy_id='…'` | `22023` | `cedar_delete_policy` | No policy has this id. |
| `cedar:unknown_template template_id='…'` | `22023` | `cedar_link_template`, `cedar_delete_template` | No template has this id. |
| `cedar:template_in_use template_id='…'` | `2BP01` | `cedar_delete_template`, `cedar_put_template` | Links exist. The hint names some of them. A replacement template must keep the slots its links fill. |
| `cedar:id_in_use id='…'` | `23505` | the put and link functions | The id belongs to the other kind: a static policy, a template or a link. |
| `cedar:invalid_link slot='…'` | `22023` | `cedar_link_template` | A slot of the template has no value, or a value has no slot. |
| `cedar:invalid_uid value='…'` | `22023` | every function that takes a UID | The text is not `Type::"id"`. |
| `cedar:invalid_entity index=<n>` | `22023` | `cedar_put_entities`, the `entities` argument | The entity JSON is wrong: a duplicate UID, a value that is not a Long, a bad extension literal, or a cycle. |
| `cedar:invalid_context` | `22023` | `cedar_is_authorized` | The context is not a record, or a value is wrong. |
| `cedar:unsupported feature='…'` | `0A000` | puts and requests | U+0000 in a string, or a record whose only key is `__entity` or `__extn`. |
| `cedar:null_argument argument='…'` | `22004` | all functions | A required argument is `null`. |
| `cedar:limit_exceeded limit='…'` | `54000` | puts and requests | A limit of section 6 is exceeded. |

Evaluation errors never raise. In `cedar_is_authorized`, each one is `{"policy_id","message"}`. The message starts with a code that follows Cedar's `EvaluationError` kinds, then a colon and a detail:

- `entity_does_not_exist: User::"x"`
- `attribute_not_found: "level" on User::"x"`
- `tag_not_found`
- `type_error: expected Long, got String`
- `overflow: 9223372036854775807 + 1`
- `extension_error: invalid decimal "1.23456"`

The oracle compares only policy ids. Cedar's own harness does the same (`ErrorComparisonMode::PolicyIds`). The message text is ours.

## 6. Limits

The limits are fixed. Each one is set well above the corpus maximum:

| Limit | Value | Corpus maximum | Error |
| --- | --- | --- | --- |
| Text of one policy or template | 64 KiB | 14.5 KB | `limit_exceeded` (put) |
| Nodes in one policy | 4,096 | 489 | `limit_exceeded` (put) |
| Expression nesting depth | 64 | 14 | `limit_exceeded` (put). The parser checks it too. |
| Value nesting in entity data and context | 32 | 4 | `limit_exceeded` |
| Entities in one `cedar_put_entities` call | 10,000 | 151 | `limit_exceeded` |
| Entities in a request overlay | 1,000 | 151 | `limit_exceeded` |
| Depth of the entity hierarchy | none. Cycles are rejected. | 117 | — |

There is no cap on the number of policies, and the `_current` helpers do not cap their results, as for FGA. `statement_timeout` bounds the time.

## 7. The current subject, RLS and lists

### 7.1 The principal type

The recommendation is **verbatim**. The principal is `current_subject_type()::"current_subject_id()"`, and no new setting is added. `current_subject_type()` already reads the `permissions.subject_type` setting. Its default is `user`. Reasons:

1. "Blessed path, no extra generality." The types in a Cedar policy must match the stored entities and the subject type. One spelling, chosen by the application, works for every model. An application that uses Cedar style sets `permissions.subject_type = 'User'`, or writes `principal is user`. Both are valid Cedar.
2. A mapping setting would give two names to one subject type in one database. FGA would see one name and Cedar another. `delete_subject` and the docs would have to explain the difference.
3. A namespaced type (`App::User`) works through the same setting.

The docs must state that a missing subject (`current_subject_id()` is null) makes every `_current` helper return false or empty.

### 7.2 `cedar_is_authorized_current(action, resource, resource_attrs)`

The function evaluates the request without context and fails closed: it returns true only if the decision is `allow` and no applicable `forbid` gave an error. The plan-time guard is the same as in FGA, `_unfolded_null()`. Spec `22`/`41` prove that no policy evaluation runs at plan time.

Each statement does the principal work once:

- The SQL-language wrapper is `STABLE` and not `SECURITY DEFINER`, so Postgres can inline it.
- The wrapper passes a scalar subquery, `(select permissions._cedar_prefilter_current(action, resource_type))`, to the per-row function. The resource type comes from the call, so the subquery has only constant arguments. Postgres runs it once, as an InitPlan.
- The prefilter computes the principal's ancestors. It keeps the policies whose action scope matches, whose principal scope matches the current subject, and whose resource scope can match the type. It returns them as one `jsonb` array of `{id, effect, resource scope, ast}`.
- Each row then checks only the resource scope and the remaining conditions.

Phase 5 compares this InitPlan design with a cache in a transaction-local setting keyed by the statement, and keeps the faster one.

**Phase 5 outcome:** the InitPlan design cannot work. Postgres never inlines a SQL function whose body has a subquery, so the prefilter would run once per row. The helper keeps its statement-level work in a transaction-local setting instead (section 15.2).

`resource_attrs` overlay. When an RLS policy passes `resource_attrs`, those attributes replace the `attrs` of the request resource. The parents and tags of the resource still come from the stored entity, if it exists. A row can therefore be authorized without being synced. A relation to a folder goes through an entity-valued attribute, for example `resource.folder in Folder::"x"` with `resource_attrs => jsonb_build_object('folder', <entity json>)`. Rows do not need to be stored entities.

### 7.3 `cedar_list_resources_current(action, resource_type)`

This function works over stored entities only. It reuses the same prefilter, and it is uncapped, with a `rows` estimate.

1. Take the candidate resources from the permit policies of the prefilter:
   - `==` gives that UID.
   - `in X` gives the descendants of `X` of the type, which needs a reverse lookup (`cedar_entity_parents` on `(parent)`).
   - `All` and `is` give every stored entity of the type.
2. Evaluate the remaining permit conditions for each candidate.
3. Remove the candidates where a `forbid` is satisfied or gives an error (fail closed).

Partial evaluation is not in v1, so the cost is the number of candidates times the number of policies. Phase 5 measures it (section 15.3).

## 8. Measurement: one condition, interpreted

The measurement is throwaway, with the tag `cedar-eval-micro`. It ran on PostgreSQL 16.4 (Postgres.app) on Apple silicon, on 2026-11-02, with only idle Docker containers running. One condition, typical of the corpus, is evaluated for each of 100,000 rows. Each row has its own principal and resource. The table shows the best of 5 runs:

```
principal.department == "Eng" && principal.level >= 3
  && resource has owner && resource.owner == principal
```

| Variant | ms per 100k | µs per evaluation |
| --- | --- | --- |
| no condition (the loop) | 8.0 | 0.08 |
| inline SQL (the floor; no Cedar semantics) | 20.0 | 0.20 |
| compiled `ast`, `jsonb`-or-`NULL` result | 804 | 8.0 |
| compiled `ast`, composite (value, error) result | 951 | 9.5 |
| compiled `ast`, `jsonb` result, attributes from the indexed entity table | 1,342 | 13.4 |
| the EST as stored, composite result | 1,731 | 17.3 |

These are the conclusions:

- The compiled tree costs half as much as the verbatim EST, which is the reason for the `ast` column (section 2.3).
- `NULL` for an error saves about 15% compared with a composite.
- Each entity attribute lookup from the table costs about 1.3 µs. Four lookups take this condition from 8.0 µs to 13.4 µs. A cache of entities for each request is a candidate optimization for phase 2.
- The condition has 15 nodes, so the cost is about 0.5 µs for each node. The p99 corpus policy (140 nodes) would cost about 70 µs.

These figures make the risk in the plan concrete. RLS that evaluates a large policy set for each row is expensive. The prefilter of section 7.2, which skips the policies that cannot match, is necessary. It is not an optional optimization.

## 9. Test targets for each phase

The oracle commands are in [`test/cedar/README.md`](../../test/cedar/README.md). The pass criterion is the same for each target: every selected request passes, except entries in `skip.tsv` that have a documented reason. Each target also needs its in-house specs (section 1.3).

| Phase | Oracle run | Tests / requests |
| --- | --- | --- |
| 2 | `--phase 2` (json, stored), and `--phase 2 --mode overlay` | 3,360 / 26,793. Overlay covers the tests whose entity JSON is at most 1 KB. |
| 3 | `--phase 3` (text, with `--check-est`), and `--format text --parse-est` | 3,359 / 26,791, plus 3,367 stored ESTs; the parser on 5,708 policies and 5 policy sets |
| 4a | `--phase 4a`, both formats | 4,442 / 35,422 |
| 4b | `--phase 4b`, both formats | 4,231 / 33,761 |
| 4c | `--phase 4c` (`--templatize`) | 1,273 / 10,111, with 1,276 links (only the cases that get a link) |
| 4 done | `--phase all`, both formats and both modes | 5,701 / 45,494 |
| 5, 6 | The full matrix keeps the phase 4 result on PG 16, 17 and 18. | |

The size of the suite matters. A run with `--phase all` writes 59 files and 76 MB of SQL (json) or 58 files and 75 MB (text). Phase 2 alone writes 27 files and 23 MB. The FGA oracle files are committed, but these files are too large to commit (section 10, question 1).

## 10. Open questions

1. **Generated corpus specs in git.** The proposal is to not commit them:
   - Ignore `test/spec/d/7[0-3]_cedar_oracle*.sql` in git.
   - `test/run.sh` runs `generate.py --suite --phase <current>` before it collects the files. This takes about 2 seconds.

   The alternative is a separate runner for `test/cedar/spec/`. Phase 2 must decide, because it is the first phase that runs these files.

   **Decided in phase 2:** not committed (`test/spec/d/.gitignore` ignores `7[0-5]_cedar_oracle*.sql`). `test/run.sh` runs `generate.py suite` (the runs in its `SUITE` list) before it collects the files, and `--no-cedar-oracle` skips them (section 12.4).
2. **A runtime cost counter.** The plan asks for one. This design proposes static limits instead (section 4.3).
3. **The principal type.** The proposal is verbatim, with no mapping setting (section 7.1).
4. **The `ast` column** beside `est` (section 2.3). It changes the table list of the plan.
5. **`resource_attrs`** replaces the attributes of the resource. It does not merge them (section 7.2).
6. **Ancestors.** Phase 2 measures A and C (section 4.5). **Decided: C** (section 12.1).

## 11. Divergences from Cedar so far

| Divergence | Why | Handling in tests |
| --- | --- | --- |
| No string can hold U+0000 (`cedar:unsupported`) | A limit of Postgres `text` and `jsonb` | The harness substitutes U+E000 (section 1.3). |
| No schema-based parsing of entities or context. Write `__extn` and `__entity` explicitly, and store the action entities with `cedar_put_entities`. | The extension does not read schemas (plan, "Not in v1") | convert.py normalizes the data (section 1.3). |
| `1e3` is accepted as the Long `1000` | `jsonb` does not keep the original number text | None in the corpus |
| A record with the key `__entity` or `__extn` is rejected: in a policy `cedar:unsupported`, in entity data or the context `cedar:invalid_entity` or `cedar:invalid_context` | The escape ambiguity of the value model | `51_cedar_errors.sql`; none in the corpus |
| A cycle that only the request overlay makes is not rejected: `in` still ends, and treats the entities of the cycle as each other's ancestors | Checking every overlay for cycles would cost every request a walk | None in the corpus |
| Two concurrent `cedar_put_entities` calls can make a cycle that neither sees (there is no lock); `in` still ends | No global lock (section 12.1) | None |
| The `_current` helpers fail closed when a `forbid` errors | Plan, decision 1 | `58_cedar_rls.sql` |
| `cedar_list_resources_current` lists stored entities only: a resource that a policy names but nobody stored is not listed, though `cedar_is_authorized_current` allows it | Plan, decision 3 (section 15.3) | `58_cedar_rls.sql` |
| `cedar_link_template` with the id of an existing link replaces that link; Cedar's `link` rejects a duplicate id | Every put in this API is an upsert by id | `56_cedar_templates.sql` |
| Two concurrent puts can give a static policy and a template the same id (the check is not locked) | Ids live in two tables; a lock on every policy put is not worth it | None |
| No function takes a whole policy set (section 13.3) | Ids by position are unstable under upserts | None: the oracle splits the corpus sets |
| Error messages differ | Only the policy ids are compared | `cedar_test.authz` compares ids only |
| `__extn` in entity data or the context with a bad value raises `invalid_entity` or `invalid_context` | Cedar also rejects the entities or the context, with its own error | `51_cedar_errors.sql`, `57_cedar_extensions.sql` |
| `cedar_read_entities` writes extension values in their canonical text (`decimal` `"1.5000"`, `ip` `"10.0.0.1/32"`, `duration` `"5400000ms"`), not the text that was put | One canonical value (section 3) | `57_cedar_extensions.sql`: Cedar reads it back to the same values |
| The limits of section 6 | The size of the work in PL/pgSQL | None in the corpus |

## 12. Phase 2 measurements

Phase 2 built the core evaluator: the Cedar section of `pg_permissions--0.1.0.sql`. The measurements are throwaway, with the tags `cedar-ancestors` and `cedar-requests`. [`e-cedar/phase2.sh`](./e-cedar/phase2.sh) runs [`ancestors.sql`](./e-cedar/ancestors.sql), a concurrent-write test with pgbench, and [`requests.sql`](./e-cedar/requests.sql). They ran on PostgreSQL 16.4 (Postgres.app) on Apple silicon on 2026-11-02, with nothing else running. Each figure is the best of 5 runs, in µs per operation.

### 12.1 Ancestors: C, the recursive walk

The data has chains of groups with only direct parents stored: 1,000 chains for depths 1 and 10, and 100 chains for depth 117. A user sits under the bottom group of each chain.

| Operation | Depth 1 | Depth 10 | Depth 117 |
| --- | --- | --- | --- |
| A: ancestors of a user (closure lookup) | 1.1 | 3.6 | 33.0 |
| C: ancestors of a user (recursive walk) | 5.9 | 17.1 | 144.4 |
| A: one `in` test (index probe) | 0.9 | 1.2 | 1.4 |
| C: `cedar_is_authorized`, scope `principal in` the top group | 49.0 | 61.7 | 194.7 |
| C: the same, plus `resource.owner in` the top group in a condition | 58.9 | 71.7 | 205.3 |
| A: write a new leaf (closure rows, global lock) | 17.4 | 44.2 | 436.8 |
| C: write a new leaf (`cedar_put_entities`) | 57.5 | 56.3 | 58.0 |
| A: link a chain's top group under a new root (every descendant's closure) | 176.8 | 2,838 | 34,500 |
| C: bulk load, per entity (1,000 per call) | 36.6 | 32.2 | 29.2 |
| A: closure rebuild after that load, per entity | 2.0 | 8.8 | 149.8 |
| Rows: A closure / C parents | 2,000 / 2,000 | 56,000 / 11,000 | 690,400 / 11,800 |

Concurrent writes, at depth 10 with 8 clients for 10 s, each putting a new leaf under a random chain: **C 24,564 tps**, and A 8,944 tps. A needs its global lock, so its writes are serialized.

**The decision is C**, the recursive walk over `cedar_entity_parents`.

- Reads favour A only in deep hierarchies. At depths 1 and 10, a whole request costs 49 to 72 µs, and the walks cost 6 to 17 µs of that. The request computes the ancestors of principal, action and resource once, in one query, and keeps them in `env`. Each further `in` on another entity walks once more.
- Writes favour C. A closure's write cost grows with depth: a re-parent costs 35 ms at depth 117. A also needs the global lock that the plan rules out. C writes the direct parents only, at about 57 µs for a new leaf at any depth.
- C keeps no derived state. A delete or a re-parent takes effect at once, and the overlay needs no special case: the walk reads the overlay's parents first.

Three details made C this fast:

1. Each step of the walk is a `lateral (... offset 0)` index probe. With a plain join, the planner hashed the whole parents table, because it guesses 10 rows for the work table. That cost 105 µs at depth 1.
2. `cedar_put_entities` reaches the tables through index probes from the put entities. A cycle is only possible when a put entity is already the parent of another entity, so a new leaf skips the cycle check. Other puts run one depth-first search over the put entities and their ancestors, O(V + E).
3. With an overlay, the walk is breadth first in PL/pgSQL (`_cedar_ancestors`). The recursive query re-planned on every call and cost 180 µs.

Cycles are rejected, as Cedar does (`compute_tc` with `enforce_dag`). The walk uses `UNION`, so it ends even on a cycle that two concurrent puts made (section 11).

The corpus check: `generate.py --reduce-parents` keeps only the direct parents of each entity, which removes the implied parent links that Cedar's JSON lists. The 6,424 phase 2 requests of the cases that lose a link all pass. `52_cedar_hierarchy.sql` covers depth 120, deletes and re-parenting.

### 12.2 Requests

`requests.sql` uses 1,000 users in 50 groups, 1,000 documents in 20 folders, and actions with groups. Each request asks for a different user and document.

| Case | µs per request |
| --- | --- |
| 1 policy, scope only (`principal in` Org, `action in` a group, `resource in` Folder) | 55 |
| 10 policies with conditions (attributes, `has`, `contains`, `==`, `>=`) | 79 |
| the same, with a context of 3 values | 94 |
| the same 10 policies, with the principal and resource only in the overlay | 263 |
| the same 10 policies, for a principal that is not stored, so 4 policies err (the second pass builds their messages) | 150 |

The fixed cost is about 50 µs: parsing three uids, one walk query, one entity query and the scope query. Each condition adds a few µs, about 0.5 µs per node as in section 8. The overlay costs the most because its entity JSON is checked and converted on every request. Phase 5 should measure the RLS path against these figures.

### 12.3 Oracle

| Run | Requests | Result |
| --- | --- | --- |
| `--phase 2` (json, stored) | 26,793 | all pass |
| `--phase 2 --mode overlay` | 19,688 | all pass |
| `--phase 2 --reduce-parents` | 6,424 | all pass |

`skip.tsv` has no entries.

### 12.4 How the suite runs the oracle

The generated files are not committed. `test/spec/d/.gitignore` ignores `7[0-5]_cedar_oracle*.sql`. Before each run of the extension, `test/run.sh` calls `generate.py suite`, which writes the runs in the `SUITE` list of `generate.py`. That takes about 3 seconds, and the files add about 35 seconds to the run. `--no-cedar-oracle` skips them. `docker/run-matrix.sh test` generates the files on the host, because the client containers have no Python.

## 13. Phase 3 integration and phase 4c (templates)

Phase 3 moved the text parser into the Cedar section of `pg_permissions--0.1.0.sql`, and phase 4c added templates and links. The decisions:

### 13.1 One raise path and one set of limits

The parser raised through its own helper, `_cedar_parse_raise`. It now raises through `_cedar_error`, like the rest of the model, with the same codes and SQLSTATEs: `parse_error` (`42601`), `limit_exceeded` (`54000`) and `unsupported` (`0A000`). The two parser helpers `_cedar_syntax_error` and `_cedar_parse_fail` build the position and the default hint, and each is one raise site in `35_error_hints.sql`. `55_cedar_parse.sql` checks the position and the hint of the parser's many calls to them.

The parser's limits now come from `_cedar_limits()` and use its names: `policy_bytes` (the text of one policy), `policy_nodes` and `policy_depth`. The standalone parser called them `policy_text` and `expression_depth`. For a text put, `policy_bytes` limits the text. The EST of a text can be larger than its text, so the compiler does not check the EST size again.

### 13.2 Text puts and `@id`

`cedar_put_policy(policy => text)` parses the text with `_cedar_parse_policy`, which takes exactly one policy. No policy, or a second one, is a `parse_error` at that position, and the hint says to put each policy with its own call. The text is stored as `source`, the parsed EST as `est`, and the annotations come from the EST. `cedar_put_template(template => text)` works the same way.

**The `policy_id` argument names the policy.** An `@id("x")` annotation in the text stays an annotation and does not rename the policy, and a disagreement is not an error. Reasons:

1. The JSON format has no id field: an id is always the caller's. Text and JSON puts should name a policy the same way.
2. Cedar's own API for one policy, `Policy::parse(id, text)`, takes the id as an argument. Only the parse of a whole policy set derives ids, and this API has no such function (section 13.3).
3. The specs and the oracle reason in policy ids. One rule, "the reason is the `policy_id` you put", is simpler to explain than an override.

### 13.3 No policy-set loader

The plan's API has no function that takes a whole policy set, and phase 3 does not add one (`cedar_put_policies(policies text)` was the candidate). The CLI names the policies of a set by position, `policy0`, `policy1` and so on, unless they have `@id`. Cedar loads a set as a whole, so position ids are stable there. This API upserts by id. With an upsert loader, a policy inserted at the top of a file would shift every later id and silently overwrite other policies. A loader that replaced the whole set would delete the links and the policies that other code put. An application can split its file and call `cedar_put_policy` once per policy, with stable ids. `_cedar_parse_policies` stays as an internal function: the parser oracle checks the CLI's ids with it, and a later loader can build on it.

### 13.4 Templates and links

| Function | What it does |
| --- | --- |
| `cedar_put_template(template_id, template text default null, template_json jsonb default null)` | Upsert. Exactly one of the two. A template has `?principal` in its principal scope, `?resource` in its resource scope, or both. A slot anywhere else is `invalid_policy`, and so is a template with no slot. |
| `cedar_link_template(policy_id, template_id, principal text default null, resource text default null)` | Fills the slots with uids in Cedar text. A value for each slot of the template and nothing else, or `invalid_link slot='?…'` with the slots in the hint. Linking an existing link's id again replaces the link. |
| `cedar_delete_template(template_id)` | `template_in_use` while links exist; the hint names up to five. |
| `cedar_templates()` | `table(template_id, source, est, annotations)`, by id. |
| `cedar_policies()` | Now also returns `template_id` and `slots` (`{"?principal": {"type", "id"}, ...}`); both are null for a static policy. |
| `cedar_delete_policy(policy_id)` | Deletes a static policy or a link. On a template id, the hint points to `cedar_delete_template`. |

Static policies, links and templates share one set of ids, as in a Cedar policy set. A put may replace an id of its own kind, and an id of another kind raises `id_in_use`.

**Slots are filled at link time.** A link is a row of `cedar_policies`: the template's EST with the slots filled, the template's compiled `ast` (Cedar allows slots only in the scope, so the conditions do not depend on the slot values), the template's annotations, and the scope columns compiled from the filled scope. `cedar_is_authorized` matches and evaluates a link exactly like a static policy, and never sees a slot. Resolving slots at evaluation time would add a lookup of the link's values to every scope match. Link-time filling costs nothing at check time:

| Measurement (PostgreSQL 16.4, Apple silicon, best of 5) | µs |
| --- | --- |
| `cedar_is_authorized`, 1,000 users in 50 teams, 1,000 documents in 20 folders: 2 links of `permit (principal in ?principal, action == Action::"view", resource in ?resource) when { principal.level >= 0 }` | 69 |
| the same with 1 static policy | 67 |
| the same with 1,001 links, one for each team and folder | 240 |
| the same with 1,000 static policies | 240 |
| `cedar_link_template` (one link) | 92 to 99 |
| `cedar_put_policy` of the same policy as static text | 258 to 277 |

The 1,000-policy rows show the cost of the unindexed scope match over many policies, the same for links and static policies. Phase 5 indexes the scope.

When a template is replaced, its links are filled again from the new template, in the same transaction. The new template must keep the slots that its links fill; otherwise the put raises `template_in_use` and names the links and their slots.

### 13.5 Oracle results

| Run | Assertions | Result |
| --- | --- | --- |
| `--phase 3` (text puts, stored entities, `--check-est`) | 26,791 requests and 3,367 stored ESTs | all pass |
| `--format text --parse-est` (the parser on every text policy of the corpus, and the 5 sets with several policies) | 5,713 | all pass |
| `--phase 4c` (`--templatize`) | 10,111 requests in the 1,273 cases that get a link, through 1,276 links | all pass |

All three are in `SUITE`, so `test/run.sh` runs them (`71_`, `77_` and `76_cedar_oracle`). The six `SUITE` runs now write 102 files and 77 MB in about 4 seconds, and add about 60 seconds to a run of the suite (`test/spec/d/.gitignore` ignores `7[0-7]_cedar_oracle*.sql`). `--parse-est` replaces `wip/check_parser.sh`, the standalone parity check. The text oracle covers only the core features: the parser already handles the extension functions (the parse oracle covers them), but the compiler still refuses them until phases 4a and 4b.

Parse cost. The largest corpus policy is 37,773 bytes of text after the U+0000 substitution (section 1.3). It parses in 12.2 ms, and `cedar_put_policy` with its text takes 17.6 ms; with its EST as `policy_json`, 5.2 ms.

## 14. Phases 4a and 4b: the extension types

Phases 4a and 4b added `decimal`, `ipaddr`, `datetime` and `duration`. Cedar 4.14's source (`cedar-policy-core`, `src/extensions/`) gave the rules, and the corpus and the Cedar 4.14 CLI (`cedar evaluate`, `cedar authorize`) judged them. Each expectation in `57_cedar_extensions.sql` was checked with the CLI first.

### 14.1 Representations

| Type | Internal `v` (section 3) | `cedar_read_entities` writes |
| --- | --- | --- |
| decimal | the i64 value × 10^4 | `"12.5000"`: four digits after the point |
| ipaddr | the `inet` text with the prefix length always written; IPv6 always in hex groups | the same text, `"10.0.0.1/32"` |
| datetime | i64 milliseconds since the epoch | `"2024-10-15T09:35:00.000Z"`; outside the years 0000 to 9999, Cedar's own form, `{"fn": "offset", "args": [datetime("1970-01-01"), duration("<ms>ms")]}` |
| duration | i64 milliseconds | `"5400000ms"`, as Cedar prints it |

- **The JSON form.** `{"__extn": {"fn", "arg"}}` and `{"__extn": {"fn", "args": [...]}}` are read in entity data, tags, the context and the request overlay. As in Cedar, `fn` can be any extension function, applied to its arguments: `{"fn": "toDate", "arg": {"__extn": ...}}` holds a datetime. The function must be named as in a policy: `ip`, not `ipaddr`. The corpus uses only `{"fn", "arg"}` with the four constructors. A value Cedar would fail to build raises `invalid_entity` or `invalid_context`, with Cedar's message and a hint that shows the form.
- **The output.** Every value has one canonical text, so the output can differ from the text that was put (`"1.5"` comes back as `"1.5000"`). The Cedar 4.14 CLI reads `cedar_read_entities` output back to the same values (`cedar authorize` with a policy that compares each one), and a put of the output changes nothing.
- **Compile time.** Cedar checks a constructor's string only when it evaluates the call: `true || decimal("x") == decimal("1.0")` is allowed. So the compiler folds `decimal("1.50")` into a literal and keeps `decimal("x")` as a call, which errs when it is evaluated. A `Value` in the EST that holds an `__extn` Cedar cannot build is compiled the same way, as a call. The arity is checked at evaluation too, after the arguments, as Cedar does.
- **Evaluation.** One `call` node, evaluated by `_cedar_call`: the arguments left to right, then the arity, then the types, then the function. `<`, `<=`, `>` and `>=` compare two datetimes or two durations by their milliseconds.

### 14.2 Cedar's semantics, and where they differ from the toolkit helpers

The toolkit helpers `_ip_canon`, `_ts_canon` and `_duration_ns` follow Go for FGA's CEL conditions, so Cedar has its own parsers (`_cedar_ip`, `_cedar_datetime`, `_cedar_duration`, `_cedar_decimal`). The helpers are unchanged.

| | Cedar 4.14 | The toolkit helper (Go) |
| --- | --- | --- |
| ipaddr: IPv4-mapped IPv6 | `::ffff:a00:1` is an IPv6 address: `isIpv6()`, not equal to `ip("10.0.0.1")`, and `::ffff:7f00:1` is not loopback | `_ip_canon` unmaps it to the IPv4 address |
| ipaddr: IPv4 in dotted form inside IPv6 | rejected: any text with two colons and two dots (`::ffff:1.2.3.4`, `::1.2.3.4`) | accepted |
| ipaddr: CIDR | `/prefix` in decimal, no leading zeros, at most 2 (IPv4) or 3 (IPv6) characters, at most 32 or 128; the host bits are kept and count for `==` | `_ip_canon` takes addresses only |
| ipaddr: other | no leading zeros in an octet, no zone (`%eth0`), no brackets, at most 43 bytes; `::` may stand for one group | the same, except the length |
| datetime: format | `YYYY-MM-DD`, or with `Thh:mm:ss`, an optional `.SSS` (exactly 3 digits), and `Z` or `+hhmm` / `-hhmm` (no colon; hh < 24, mm < 60) | RFC 3339 as Go reads it: seconds required, any fraction, `Z` or `+hh:mm` |
| datetime: range | years 0000 to 9999 (proleptic Gregorian, year 0 a leap year); no leap second; `offset` reaches the full i64 range of milliseconds | years from 0001, through `timestamptz` |
| duration: format | integers with units `d`, `h`, `m`, `s`, `ms`, in that order, each at most once, an optional leading `-`; `0` alone, `+`, fractions and other units are invalid | Go's: `ns`, `us`, `µs`, fractions, any order, `0` |
| duration: unit | milliseconds | nanoseconds |

Other behaviour that the corpus or the CLI confirmed:

- **`isInRange` takes exactly one range.** Cedar's source declares it variadic, but only behind the experimental feature `variadic-is-in-range`, which a release build does not enable. Eight corpus cases pass more than one range and expect the arity error.
- **The operators.** `<` and the others work on datetimes and durations (Cedar's `supports_operator_overloading`), not on decimals or ipaddrs. Mixed types are a type error, and `==` across types is false.
- **`isLoopback` and `isMulticast`** look at the address and need a prefix at least as long as the range: `ip("127.0.0.1/7").isLoopback()` is false, and so is `ip("::1/127").isLoopback()`.
- **The conversions truncate toward zero**, as Rust's `/`: `duration("-1999ms").toSeconds() == -1` and `duration("-23h59m").toDays() == 0`. `toTime` is the Euclidean remainder of a day, so a datetime before 1970 has a positive time of day, and `toDate` subtracts it. `toDate` of the smallest datetime overflows, as do `offset` and `durationSince` beyond i64; each overflow is an `extension_error`.
- **decimal** reads `-?digits.digits`, with 1 to 4 digits after the point, leading zeros allowed, no `+`, within -922337203685477.5808 and 922337203685477.5807. `decimal("-0.0") == decimal("0.0")`.

Beyond the corpus, about 130 constructor strings at these edges were run through the CLI and through the new parsers, with no difference.

### 14.3 Oracle

| Run | Assertions | Result |
| --- | --- | --- |
| `--phase 2 --features decimal,ipaddr,datetime,duration` (json, stored) | 45,494 requests: the whole corpus | all pass |
| the same, `--mode overlay` | 31,872 | all pass |
| the same, `--reduce-parents` | 11,976 | all pass |
| `--phase 3 --features decimal,ipaddr,datetime,duration` (text, `--check-est`) | 45,492 requests and 5,708 stored ESTs | all pass |
| `--format text --parse-est` | 5,713 | all pass |
| `--phase 4c --features all` (`--templatize`) | 19,156 | all pass |

`skip.tsv` has no entries. These six runs are the `SUITE` of `generate.py`, so `test/run.sh` runs them.

### 14.4 Cost

`_cedar_eval` on one compiled condition, with the values in the context, best of 5 runs of 20,000 (PostgreSQL 16.4, Apple silicon):

| Condition | µs |
| --- | --- |
| `context.n > 3` (Long, for comparison) | 2.7 |
| `context.t < datetime("2025-01-01")` (folded constructor, operator) | 2.9 |
| `context.d.greaterThan(decimal("1.5"))` | 4.8 |
| `context.ip.isInRange(ip("10.0.0.0/8"))` | 4.6 |
| `context.u.toMinutes() == 90` | 5.4 |
| `context.t.toTime() == duration("12h")` | 6.1 |
| `context.t.offset(context.u) > datetime("2024-06-01")` | 8.6 |
| `ip(context.s).isInRange(ip("10.0.0.0/8"))` (the constructor at run time) | 10.9 |

A method call costs about 2 µs over an operator, and a constructor that is not folded about 6 µs. Converting one value of the context or the overlay costs about 8 µs for a Long, and 10 to 20 µs more for an extension value: decimal 17.7, ipaddr 16.4, duration 20.2 and datetime 28.6 µs. Stored entity data is converted once, when it is put.

### 14.5 The size of the suite

The six runs write 190 files and 197 MB in about 9 seconds. The whole suite went from about 85 to about 163 seconds on Apple silicon (`test/run.sh` uses 17% of the CPU: it runs one file at a time). That is under the 3 minutes at which a faster default was to be built. The cheapest next step is to run the spec files in parallel in `test/run.sh`, each already in its own database; a sampled default with `--full` for CI is the alternative.

## 15. Phase 5: the policy index and the RLS helpers

Phase 5 added the scope index, `cedar_is_authorized_current` and `cedar_list_resources_current`. The measurements are throwaway, with the tag `cedar-phase5`: [`e-cedar/phase5.sh`](./e-cedar/phase5.sh) runs [`phase5.sql`](./e-cedar/phase5.sql) against the working tree and, for the "before" column, against a git revision (here `0845531`, the end of phase 4). They ran on PostgreSQL 16.4 (Postgres.app) on Apple silicon on 2026-11-02. Each figure is the best of 5 runs, in µs. The benchmarks are in section 15.4 and [`research/benchmarks/cedar.md`](../benchmarks/cedar.md). The specs are `58_cedar_rls.sql` and the updated `02`, `04`, `35` and `50`.

### 15.1 The scope index

`cedar_policy_scopes` has one row for each policy and each action of its action scope, with three keys:

| Column | `All` | `==`, `in` | `is T` | `is T in U` |
| --- | --- | --- | --- | --- |
| `action_key` | `*` | each action uid of the scope | | |
| `principal_key`, `resource_key` | `*` | the uid | `T` | `U` |

A uid key always holds `::"` and a type name never does, so the three kinds of key cannot collide. `_cedar_store_policy` writes the rows of a static policy or a link; a policy's rows go with it (`on delete cascade`). `action in []` has no row, because it matches no request.

A request probes the principal's own key, its ancestors' keys, its type and `*`, and the same for the action and the resource. That finds every policy whose scope can match, plus a few that cannot: a `==` on an ancestor, or an `is ... in` of another type. The exact scope predicate of phase 2 then runs on the candidates only (`_cedar_candidates`), so the semantics do not change. The oracle passes unchanged: 256 files and 169,738 assertions.

There are two indexes, `(action_key, principal_key, resource_key)` and `(action_key, resource_key, principal_key)`. The probe takes one index scan for each action key and each key of the side that has fewer keys, with the other side's keys in the index condition. For a per-row check that is usually the resource side: a document and its folder, against a user, two roles and a chain of teams. Two planner details:

- The probes are lateral subqueries with `offset 0`. With all three arrays in one `= any(...)` scan, the planner scanned the whole table on 1,000 policies and tested each row against the arrays. That cost 323 µs; even with `enable_seqscan` off it chose a plan that cost 280 µs.
- `cedar_is_authorized` now has `plan_cache_mode = force_generic_plan`. Without it, PL/pgSQL kept choosing custom plans for the array arguments and planned the candidate query on every call, which cost about 100 µs.

| `cedar_is_authorized` (2,000 requests, a different user and document each) | before | after |
| --- | --- | --- |
| 2 links | 48.4 | 61.2 |
| 1,002 links: one for each of 50 teams and 20 folders | 242.7 | 78.9 |
| 1,000 static policies of the same shape | 254.3 | 78.3 |
| 1,001 policies with `principal` All: 50 actions × 20 resource types | 181.3 | 70.4 |

With 1,000 policies, a request is three times faster. With 2 policies it costs about 13 µs more: the generic plan, the extra walk function and up to a dozen index probes instead of a scan of two rows. A request now costs about the same at any number of policies; only the candidates it finds cost more.

### 15.2 `cedar_is_authorized_current`: the statement-level work in a setting

`cedar_is_authorized_current(action text, resource text, resource_attrs jsonb default null, plan_time_guard boolean default permissions._unfolded_null()) returns boolean` is `STABLE`, `SECURITY DEFINER` and granted to PUBLIC.

**No InitPlan.** Section 7.2 planned an inlinable SQL wrapper that passes `(select _cedar_prefilter_current(...))` to the per-row function, so that Postgres would run the prefilter once as an InitPlan. Postgres does not inline a SQL function whose body has a subquery (`inline_function` gives up on `hasSubLinks`). The wrapper is then an ordinary function call, and the subquery runs on every call. A probe showed it: a SQL wrapper with `(select pf(a))` called on 5 rows ran `pf` 5 times, and `EXPLAIN` showed the wrapper as a plain filter. No other way to get an InitPlan exists without asking the policy author to write the subquery.

**The setting.** The doc's alternative, a transaction-local setting keyed by the statement, is what the helper does. On the first row of a statement, `_cedar_current_filter` walks the principal's and the action's ancestors, collects the candidate policies of the scope index (principal and action match, any resource), and stores the result with `set_config(..., true)` in `permissions.cedar_filter_<md5(action)>`. Each action has its own setting, so a statement that checks two actions (a select and an update policy) does not evict its own entry. The value starts with a key:

- `pg_current_snapshot()`. A commit by another transaction changes the snapshot text, so a new statement in read committed recomputes. Statements that share a snapshot see the same committed data.
- the raw values of `request.jwt.claims`, `permissions.subject_id` and `permissions.subject_type`: the settings the subject comes from.
- `permissions.cedar_generation`: statement-level triggers on `cedar_policies`, `cedar_entities` and `cedar_entity_parents` set it to a new uuid, so the transaction's own writes end its cache at once. A rolled-back subtransaction rolls the setting back with the data.
- the action text.

**Trust.** A client that can write a setting could forge this cache. It is not a new hole: such a client can also write `request.jwt.claims` or `permissions.subject_id`, the settings `current_subject_id()` trusts, and be any subject. The cache is exactly as trusted as the subject itself (docs, "Identity"). PostgREST clients cannot set these settings at all. Phase 9 should review this argument.

**Layout and the per-row decision.** The value has two parts:

1. Flags, then one entry for each permit that matches the principal and the action: its resource scope in upper case when the permit has no conditions (`E:<uid>`, `I:<uid>`, `T:<type>`, `A:*`), in lower case otherwise (and for `is ... in`). The flag `F` says that a forbid matches the principal and the action.
2. Only when a forbid or a lower-case permit exists: those policies grouped by resource scope, with the environment of the request without its resource (principal and action data and ancestors), as jsonb text.

For each row the helper parses the resource uid inline (the common case without escapes) and finds the entries that match the resource with `strpos`. It walks the resource's ancestors once, and only if an `in` entry needs them. Then:

- No entry matches: false. No query runs.
- An upper-case entry matches and there is no `F`: true. No query runs; this is the common case of a share or a folder link.
- Otherwise `_cedar_decide` parses part 2, evaluates the matching forbids first (one that holds or errs denies: fail closed), then the matching permits (one that errs is skipped).

Part 2 is capped at 8 KiB. jsonb parses at about 5 ns a byte, so 8 KiB costs about 40 µs, close to a check from scratch. Above the cap part 2 is dropped (flag `X`) and the rows that need it are checked from scratch by `_cedar_current_check`, which runs the walks, `_cedar_candidates` with the resource's keys, and the evaluation. `58_cedar_rls.sql` covers both paths and compares every answer with `cedar_is_authorized` under the fail-closed rule.

`resource_attrs` replaces the resource's stored attrs. Its tags and parents still come from storage. A record whose values are all Strings, Bools, Longs or entity references is already in the internal form, and `_cedar_attrs_plain` checks that in about 6 µs instead of converting it (`_cedar_value_in`, 14 µs for one entity reference). A value Cedar cannot hold denies the row. Bad action or resource text raises `cedar:invalid_uid`, like `fga_check_current` raises on an unknown type or relation (phase 6 narrowed this for resource ids, section 16.2).

**Evidence that the work runs once.** No plan node shows it, because the helper is a plain filter. The call counts show it. This is one statement over 1,000 rows, with 5 shares:

```
Aggregate (actual rows=1 loops=1)
  ->  Seq Scan on docs (actual rows=5 loops=1)
        Filter: permissions.cedar_is_authorized_current('Action::"view"'::text, (('Doc::"'::text || id) || '"'::text), NULL::jsonb, permissions._unfolded_null())
        Rows Removed by Filter: 995
cedar_is_authorized_current 1000 calls, _cedar_current_filter 1, _cedar_keys 1, _cedar_decide 0, _cedar_current_check 0
```

`58_cedar_rls.sql` asserts the same thing: one `_cedar_current_filter` call for 200 rows, a reuse in the next statement of the same snapshot, and new answers after the subject changes or the transaction writes.

| Per row, 1,000 rows | µs |
| --- | --- |
| 5 of 1,000 documents shared: the other rows are denied from the setting | 4.0 |
| `resource_attrs` from the row, a condition on every row (`resource.level <= principal.level`) | 36.6 |
| 20 folder links, each with a condition: every row walks to its folder and evaluates the link | 78.5 |
| for comparison: `cedar_is_authorized` on the same requests | 77.1 |

The last case parses about 3 KB of part 2 on every row and evaluates a condition, so it is no faster than a request from scratch. A list view over many rows should use `cedar_list_resources_current` when its policies are on stored entities.

### 15.3 `cedar_list_resources_current`: the strategy

`cedar_list_resources_current(action text, resource_type text) returns setof text` is `STABLE`, `SECURITY DEFINER`, `rows 100`, uncapped and granted to PUBLIC. It returns ids without the type, for `id = any(array(select ...::uuid))`, which runs it once as an InitPlan. A `type::"id"` form would only repeat the type the caller passed, so there is no second variant.

1. The walks and `_cedar_principal_candidates` run once per call. Only the policies whose resource scope can hold the type are kept: `All`, every `in`, `is T`, and `==` on a uid of the type.
2. The candidates come from the permits' scopes and are stored entities only (plan, decision 3): `==` gives the uid if it is stored; `in X` gives X and its descendants of the type, walked over `cedar_entity_parents (parent_type, parent_id)` (a child in that table is always stored, so only X needs a check); `All` and `is T` give every stored entity of the type.
3. If no forbid matches and every permit has no conditions, the candidates are the answer, in one query.
4. Otherwise each candidate is evaluated with `_cedar_eval_resource`, forbids first and failing closed. A candidate named by a permit without conditions is not evaluated when no forbid matches.

| `cedar_list_resources_current('Action::"view"', 'Doc')`, 1,000 documents | µs per call |
| --- | --- |
| 5 shares, no conditions: the uids, one query | 73.9 |
| 20 folder links with a condition: 1,000 documents walked and evaluated | 23,302 |
| `resource is Doc` with a condition: every document evaluated | 15,336 |

A condition costs about 15 to 23 µs for each candidate. The first benchmark runs found two planner traps in `_cedar_list_candidates`, both of the kind B met (section 12.1, `research/designs/b-policy-first.md`):

- The check that the root X of `in X` is stored, written as `exists (...)`, became a hashed subplan that scanned every stored entity. It is a lateral primary-key probe now. The org list at medium scale went from 0.85 to 0.23 ms.
- The branch for `All` and `is T`, written as a join, could become a hash join over every stored entity of the type, 1 million documents at large scale, even when no such permit existed. It is a lateral subquery now, run only for those permits.
- JIT. The generic plan of the candidate query is costed for every branch, and with a million documents its cost passed `jit_above_cost` (100,000). Postgres 18 in Docker, which has JIT, compiled it on every call: 10 ms for a query that runs in 0.2 ms. Postgres.app 16.4 has no JIT, so the local measurements never showed it. The function now has `set jit = off`; the document list at large scale went from about 10 ms to 0.15 ms on Postgres 18. Phase 6 should check the other helpers on a server with JIT. The walk of `in X` follows every descendant of X, of any type, because Cedar has no schema here to prune it. For example, `resource in Org::"x"` walks every member of a role that is in the org. The benchmark seeds keep roles out of their orgs for that reason (`bench/designs/e/seed_rbac.sql`).

### 15.4 Benchmarks

`bench/designs/e/` is design E in the harness: `bench/run.sh --design e` with the extension file, or `docker/run-matrix.sh bench --designs e`. Its seeds write the shared data shape as Cedar entities and template links, and a design-E-only phase 8 (`rowcheck`) puts one per-row select policy on the table. The checksums equal those of designs A to D at every scale. The runs (Postgres 18.6, Docker, tag `p5`) and the comparison with D are in [`research/benchmarks/cedar.md`](../benchmarks/cedar.md). In short:

| p50 / p95, ms | small | medium | large |
| --- | --- | --- | --- |
| `share_select_page` (list, InitPlan), D | 0.39 / 0.54 | 0.57 / 1.18 | 1.05 / 2.38 |
| `share_select_page`, E | 0.56 / 0.91 | 0.78 / 1.05 | 1.19 / 1.84 |
| `nest_check` (one per-row check), D | 0.37 / 0.99 | 0.38 / 0.51 | 0.38 / 0.66 |
| `nest_check`, E | 0.34 / 0.58 | 0.36 / 0.51 | 0.40 / 0.63 |
| `row_select_page` (per row, every row evaluated), E | 39.9 / 59.6 | 107.8 / 162.4 | 225.5 / 312.5 |

Every workload is within its budget except `write_nest_team` (p95 1.5 to 1.8 ms against 1 ms at every scale): it re-parents the same entity in every transaction, and the 4 clients serialize on its row lock; with one client p95 is 0.41 ms. The budget stays. `row_select_page` has no equivalent in another engine; its budget is 3x its own p95.

### 15.5 For phases 6 to 9

- **Security review (phase 9).** The setting cache of section 15.2 rests on the argument that a client who can write settings can already choose the subject. Review it, and the triggers that end the cache on the transaction's own writes.
- **Not in the plan's API:** `cedar_is_authorized_current` has a fourth argument, `plan_time_guard`, as `rbac_scopes_with_permission` has. The JS client (phase 7) should not pass it.
- **Resource text.** A resource is Cedar text, so an id with `"` or `\` must be escaped, or the call raises `cedar:invalid_uid`. RLS policies on uuid or integer ids are safe; the docs (phase 8) should say so, and could offer an escaping helper.
- **`delete_subject` (phase 6)** must also delete the `cedar_entities` row of the subject; its links (`cedar_policies` with a principal slot of that uid) are a decision for phase 6.
- **The docs site** accepts bench designs `a` to `d` only and skips E's JSON with a warning (`site/src/lib/bench.ts`).
- **JIT.** Only `cedar_list_resources_current` has `set jit = off`. Check the other helpers on a server with JIT, and the FGA list helpers too.
- **Per-row cost.** A policy on row attributes costs about 37 µs a row on the laptop, and the benchmark's worst case about 80 µs on Docker. A further step would be a cheaper walk of the resource's ancestors and no jsonb parse for small statement parts; compiling Cedar to SQL is still out of v1.

## 16. Phase 6: integration and release

### 16.1 `delete_subject`

`delete_subject(subject_type, subject_id)` also forgets the Cedar entity `<subject_type>::"<subject_id>"` (the principal type is the subject type verbatim, section 7.1). It deletes, and counts in its result with the RBAC assignments and FGA tuples:

- the template links whose `?principal` or `?resource` slot names the entity (their scope rows go with them), so an id that is reused later gets none of their access;
- the entity's parent edges (its memberships) and the edges that name it as a parent (the memberships in it), so nothing stays `in` a deleted group. `cedar_delete_entities` keeps the second kind, as Cedar does: a parent need not be stored. `delete_subject` means "forget everywhere", as it does for FGA tuples that name the subject as the object;
- the entity row.

Static policies and templates stay: they are the application's code. A static `principal == User::"x"` therefore still applies to a reused id, and references to the entity in other entities' attrs and tags stay too. Spec `59_cedar_delete_subject.sql` covers each case, ids with `"` and `\`, and a current-subject check in the same transaction (the `cedar_changed` triggers end the cached filter). In the upgrade script the function sits in a synced `cleanup` section with `create or replace`, which keeps 0.0.1's privileges.

### 16.2 Ids are data

Subject ids and stored entity ids were already handled raw: the helpers pass `(type, id)` pairs and build keys with `_cedar_key`, never uid text, so `"`, `\` and control characters in them work (spec `58_cedar_rls_ids.sql`). Two gaps were in `cedar_is_authorized_current`:

1. **A row id concatenated without escaping.** `'Document::"' || id || '"'` with an id that holds `"` or `\` is not a Cedar string, and the helper raised `cedar:invalid_uid` on that row: one bad row made the table unreadable for everyone. Now resource text of the shape `Type::"..."` that does not parse denies the row; any other text, and a bad action, still raise as the caller's typo. This follows `fga_check_current`, which raises on a malformed object and never on an id. An unescaped id can still be read as a different id when its backslashes form a valid escape (`a\nb` becomes a newline): the policy must escape such ids, `'Doc::"' || replace(replace(id, '\', '\\'), '"', '\"') || '"'`, or use uuid or integer ids. A public escaping helper is a phase 8 decision.
2. **The separators of the statement filter.** Part 1 of the filter (section 15.2) delimits entries with chr(30) and ends at chr(28). A resource id that spelled `x"<chr(30)>E:Doc::"y` matched two adjacent allowed entries and was allowed; a policy uid with chr(28) cut the filter. Now a resource or ancestor key with chr(30) is decided from scratch (`_cedar_current_check`), and a filter whose policies hold chr(28) or chr(30) in a resource uid sends every row there (flag `X`, entry `a:*`). The common path gains one `strpos` per row: 4.2 µs per row before and after in the phase 5 measurement.

### 16.3 Grants, specs and the upgrade

`02_security.sql` pins PUBLIC's execute grants to the eleven current-subject functions (`_unfolded_null` included) and checks that every `cedar_*` function is security definer with `search_path=''`, that clients can execute no `cedar_*` or `_cedar_*` function but the two helpers, and that they have no privilege on the five `cedar_*` tables. `04_api_naming` and `35_error_hints` already covered every Cedar function and raise site.

It also documents the cache-forgery behaviour for the phase 9 review: a client that can run `set_config` computes the key (`pg_current_snapshot()`, the subject settings, `cedar_generation`, the action) and writes `permissions.cedar_filter_<md5(action)>` = key `chr(29)` `chr(30)` `A:*` `chr(30)` `chr(28)`; `cedar_is_authorized_current` then returns true for a resource no policy allows. An entry with a stale key is ignored. The same client can as well set `permissions.subject_id` and act as another subject, the argument of section 15.2.

`test/run.sh --upgrade-from 0.0.1` runs the whole suite on 0.0.1 plus the upgrade script: 259 files and 169,777 assertions pass, as on a fresh install. Every run of the extension's suite starts with `tools/sync-upgrade.sh --check`. `03_tle_install.sql` updates a pg_tle install of 0.0.1 as a non-superuser with `pgtle_admin` and checks `pgtle.set_default_version`.

### 16.4 JIT

Measured on Postgres 18.6 in Docker (4 CPUs, `jit = on`, `jit_above_cost = 100000`), the large scale of the benchmark (1 million documents, 10,000 users), seeded by `bench/run.sh --scale large` for design D and then design E. Each figure is the mean of 30 calls with different users (5 for the page), best of two rounds, with the session's `jit` on and off. `auto_explain` with nested statements showed no JIT in any of these helpers: the most expensive inner plan cost about 10,000.

| ms per call | `jit` on | `jit` off |
| --- | --- | --- |
| `rbac_has_permission` | 0.019 | 0.018 |
| `rbac_has_role` | 0.017 | 0.017 |
| `rbac_scopes_with_permission` | 0.020 | 0.019 |
| `fga_check_current` (viewer, nested team) | 0.237 | 0.238 |
| `fga_check_current` (conditioned) | 0.414 | 0.355 |
| `fga_list_object_ids_current` (viewer) | 0.289 | 0.281 |
| `fga_list_objects_current` (viewer) | 0.320 | 0.279 |
| `fga_list_object_ids_current` (conditioned) | 0.386 | 0.383 |
| `cedar_is_authorized_current` (`nest_check`) | 0.275 | 0.237 |
| `cedar_is_authorized_current` (`rbac_check`) | 0.136 | 0.114 |
| `cedar_is_authorized` | 0.157 | 0.169 |
| `row_select_page` (the per-row policy, 50 rows) | 196.5 | 180.9 |
| `cedar_list_resources_current` (`share_list_objects`) | 0.52 | 0.47 |
| the same without its `set jit = off` | 12.27 | 0.51 |

Only `cedar_list_resources_current` needs `set jit = off`, which it has; the last row confirms the phase 5 finding on this data. No other function gets the setting. The FGA list helpers were measured at the default shape only; a wider shape could raise their plan costs.

### 16.5 For phases 8 and 9

- **Phase 9:** the cache forgery above; the separator handling of 16.2; the unescaped-backslash ambiguity.
- **Phase 8:** document the resource-id rule of 16.2 and the escaping expression, or add a helper; the `delete_subject` semantics (the reference and `docs/integrations/cleanup.md` have a minimal update); `site/scripts/sync.mjs` still calls Cedar a future direction.
