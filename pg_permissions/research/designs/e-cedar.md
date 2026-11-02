# Design E: the Cedar model (`cedar_*`) in PL/pgSQL

> Status: phase 0 of [`plan-cedar.md`](../plan-cedar.md), approved with its deviations (static limits, the `ast` column, errors as SQL null, the verbatim principal type, `resource_attrs` replacing attributes). Phases 2 and 3 are implemented in `pg_permissions--0.1.0.sql`: the core evaluator and the text parser. Section 12 has the phase 2 measurements and decisions, and section 13 the decisions of phase 3. The oracle is vendored in [`test/cedar/`](../../test/cedar/README.md).

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

Phase 3 runs the oracle with `generate.py --phase 3`, which includes `--check-est`. It covers 3,359 tests and 26,791 requests, plus one EST assertion for each policy. `--parse-est` checks the parser alone on all 5,708 text policies, including those with extension types (section 13.4).

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
| ipaddr | `{"__extn":{"fn":"ip","arg":"10.0.0.1/24"}}` | `{"__extn":{"fn":"ip","v":"10.0.0.1/24"}}`: the `inet` text, so equality keeps the host bits and the prefix length |
| datetime | `{"__extn":{"fn":"datetime","arg":"2024-01-01T00:00:00Z"}}` | `{"__extn":{"fn":"datetime","v":1704067200000}}`: i64 milliseconds since the epoch |
| duration | `{"__extn":{"fn":"duration","arg":"1h30m"}}` | `{"__extn":{"fn":"duration","v":5400000}}`: i64 milliseconds |

The rules are:

- **Long and overflow.** `jsonb` numbers have arbitrary precision, so a Long stays a JSON number and is never a string. Input is checked when an entity or context is put: the value must be an integral number in the i64 range. The check uses `scale(v::numeric) = 0`, so `1.0` is rejected. Cedar also rejects `1.0`. `jsonb` turns `1e3` into `1000` before the check sees it, so `1e3` is accepted. This is a divergence. `+`, `-`, `*` and `neg` compute in `numeric` and then compare the result with the i64 bounds. Out of range, the result is an `overflow` error value. A `bigint` operation would raise an exception, and an exception means a subtransaction in the hot path.
- **datetime and duration** are i64 milliseconds, as in Cedar (RFC 80). They are not `timestamptz`. `offset` can leave the range of `timestamptz`, which Cedar allows until the i64 limit. A datetime is converted to `timestamptz` only for parsing and for `toDate` and `toTime`. The CEL helpers of phase 1 parse the text forms.
- **ipaddr.** The text is the canonical `inet` text. `isInRange`, `isLoopback` and the other methods use `inet` operators. The constructor accepts what Cedar's `ip()` grammar accepts, and the corpus judges the details. The CEL helper of phase 1 rejects IPv6 zones, so phase 4a must check that Cedar does the same.
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
- **Comparisons.** `<`, `<=`, `>` and `>=` need two Longs, two datetimes or two durations. Other types give a type error. The decimal comparisons are methods (`lessThan` and the others). Phase 4a checks against the corpus whether Cedar 4.14 also lets these operators compare decimals.
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
| `cedar:template_in_use template_id='…'` | `2BP01` | `cedar_delete_template` | Links exist. The hint names some of them. |
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

`resource_attrs` overlay. When an RLS policy passes `resource_attrs`, those attributes replace the `attrs` of the request resource. The parents and tags of the resource still come from the stored entity, if it exists. A row can therefore be authorized without being synced. A relation to a folder goes through an entity-valued attribute, for example `resource.folder in Folder::"x"` with `resource_attrs => jsonb_build_object('folder', <entity json>)`. Rows do not need to be stored entities.

### 7.3 `cedar_list_resources_current(action, resource_type)`

This function works over stored entities only. It reuses the same prefilter, and it is uncapped, with a `rows` estimate.

1. Take the candidate resources from the permit policies of the prefilter:
   - `==` gives that UID.
   - `in X` gives the descendants of `X` of the type, which needs a reverse lookup (`cedar_entity_parents` on `(parent)`).
   - `All` and `is` give every stored entity of the type.
2. Evaluate the remaining permit conditions for each candidate.
3. Remove the candidates where a `forbid` is satisfied or gives an error (fail closed).

Partial evaluation is not in v1, so the cost is the number of candidates times the number of policies. Phase 5 measures it.

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
| 4c | `--phase 4c` (`--templatize`) | 3,360 / 26,793, with 1,276 links |
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
| The `_current` helpers fail closed when a `forbid` errors | Plan, decision 1 | In-house specs (phase 5) |
| No function takes a whole policy set (section 13.3) | Ids by position are unstable under upserts | None: the oracle splits the corpus sets |
| Error messages differ | Only the policy ids are compared | `cedar_test.authz` compares ids only |
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

## 13. Phase 3 integration

Phase 3 moved the text parser into the Cedar section of `pg_permissions--0.1.0.sql`. The decisions:

### 13.1 One raise path and one set of limits

The parser raised through its own helper, `_cedar_parse_raise`. It now raises through `_cedar_error`, like the rest of the model, with the same codes and SQLSTATEs: `parse_error` (`42601`), `limit_exceeded` (`54000`) and `unsupported` (`0A000`). The two parser helpers `_cedar_syntax_error` and `_cedar_parse_fail` build the position and the default hint, and each is one raise site in `35_error_hints.sql`. `55_cedar_parse.sql` checks the position and the hint of the parser's many calls to them.

The parser's limits now come from `_cedar_limits()` and use its names: `policy_bytes` (the text of one policy), `policy_nodes` and `policy_depth`. The standalone parser called them `policy_text` and `expression_depth`. For a text put, `policy_bytes` limits the text. The EST of a text can be larger than its text, so the compiler does not check the EST size again.

### 13.2 Text puts and `@id`

`cedar_put_policy(policy => text)` parses the text with `_cedar_parse_policy`, which takes exactly one policy. No policy, or a second one, is a `parse_error` at that position, and the hint says to put each policy with its own call. The text is stored as `source`, the parsed EST as `est`, and the annotations come from the EST.

**The `policy_id` argument names the policy.** An `@id("x")` annotation in the text stays an annotation and does not rename the policy, and a disagreement is not an error. Reasons:

1. The JSON format has no id field: an id is always the caller's. Text and JSON puts should name a policy the same way.
2. Cedar's own API for one policy, `Policy::parse(id, text)`, takes the id as an argument. Only the parse of a whole policy set derives ids, and this API has no such function (section 13.3).
3. The specs and the oracle reason in policy ids. One rule, "the reason is the `policy_id` you put", is simpler to explain than an override.

### 13.3 No policy-set loader

The plan's API has no function that takes a whole policy set, and phase 3 does not add one (`cedar_put_policies(policies text)` was the candidate). The CLI names the policies of a set by position, `policy0`, `policy1` and so on, unless they have `@id`. Cedar loads a set as a whole, so position ids are stable there. This API upserts by id. With an upsert loader, a policy inserted at the top of a file would shift every later id and silently overwrite other policies. A loader that replaced the whole set would delete the links and the policies that other code put. An application can split its file and call `cedar_put_policy` once per policy, with stable ids. `_cedar_parse_policies` stays as an internal function: the parser oracle checks the CLI's ids with it, and a later loader can build on it.

### 13.4 Oracle results

| Run | Assertions | Result |
| --- | --- | --- |
| `--phase 3` (text puts, stored entities, `--check-est`) | 26,791 requests and 3,367 stored ESTs | all pass |
| `--format text --parse-est` (the parser on every text policy of the corpus, and the 5 sets with several policies) | 5,713 | all pass |

Both are in `SUITE`, so `test/run.sh` runs them (`71_` and `77_cedar_oracle`). The five `SUITE` runs now write 91 files and 71 MB in about 4 seconds (`test/spec/d/.gitignore` ignores `7[0-7]_cedar_oracle*.sql`). `--parse-est` replaces `wip/check_parser.sh`, the standalone parity check. The text oracle covers only the core features: the parser already handles the extension functions (the parse oracle covers them), but the compiler still refuses them until phases 4a and 4b.

Parse cost. The largest corpus policy is 37,773 bytes of text after the U+0000 substitution (section 1.3). It parses in 12.2 ms, and `cedar_put_policy` with its text takes 17.6 ms; with its EST as `policy_json`, 5.2 ms.
