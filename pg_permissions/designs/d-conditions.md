# Design D: OpenFGA conditions (CEL) in PL/pgSQL

> Status: implemented in phase 4 of session 5 ([`PLAN.md`](../PLAN.md), "Phase 4", steps 3 to 6), in [`pg_permissions--0.0.1.sql`](../pg_permissions--0.0.1.sql). Written as the design (steps 1 and 2), then reviewed: the open questions of section 11 were decided ([`DECISION.md`](../DECISION.md), "Decisions for conditions (session 5)") and section 13 says where the implementation differs from the design. The abac oracle passes in both runs (302 of 302 stored, 271 of 271 contextual assertions; 9 cases skipped as `inline-expression`). Companion to [`d-per-model.md`](./d-per-model.md), whose sections 2, 4, 7 and 8 describe the result.

Sources: openfga/openfga at `44054f5` (tag v1.22.1, the commit the vendored suites come from; cel-go v0.31.0, `go.mod:19`), openfga/api at `f153694bfc20` (the commit its `go.mod` pins), the docs page [openfga.dev/docs/modeling/conditions](https://openfga.dev/docs/modeling/conditions) (read 2026-10-29), and answers from the pinned server image (`openfga/openfga:v1.22.1@sha256:b852071...`, memory datastore, default flags) collected by [`test/fga_abac/probe.sh`](../test/fga_abac/probe.sh). Paths like `condition.go:218` are in openfga/openfga unless they say otherwise.

## 1. Oracle and inventory

### 1.1 The oracle

[`test/fga_abac/`](../test/fga_abac/) vendors `assets/tests/abac_tests.yaml` at the same SHA as the consolidated suite, with the same pinned CLI image, the same two runs, the same TAP names and the same skip file format (`vendor.sh`, `generate.py`, `skip.tsv`, `cases.json`, `upstream/`). Upstream's harness runs this file with the same code as the consolidated one (`tests/check/check.go:63-67`), with the `inline_expressions` flag on (`tests/check/check_test.go:99`).

| | Cases | Assertions | Run | Skipped |
| --- | --- | --- | --- | --- |
| upstream | 33 (3 multi-stage) | 331 (152 Check, 82 ListObjects, 97 ListUsers) | | |
| stored | 33 | 331 | 24 cases, 302 assertions | 9 cases, 29 assertions: `inline-expression` |
| contextual | 30 | 300 | 21 cases, 271 assertions | the same 9 |

`generate.py --suite` writes the specs as `test/spec/d/63_fga_abac_*` and `64_fga_abac_ctx_*` (without `--suite`, to the git-ignored `test/fga_abac/spec/`). They call `fga_check`, `fga_list_objects` and `fga_list_users` with the `context` argument through helpers in `test/fixtures/fga_abac.sql`. Red before phase 4's steps 3 to 6 (0 of 302 and 0 of 271: every model write raised 0A000), green after (302 and 271).

Two vendoring details: the YAML has an out-of-range double (`1.797...e+309`, case `handles_floats`) that Ruby reads as Infinity, so `yaml2json.rb` keeps unquoted floats as their source text (jsonb holds it exactly; `vendor.sh` refuses a jq that rounds it). Upstream's own harness (sigs.k8s.io/yaml) turns that unquoted scalar into a string, and the server rejects the number form at request parsing (probe P12); both are 2000, which is what the case expects. The 8 `conditions` skips in [`test/fga_lang/skip.tsv`](../test/fga_lang/skip.tsv) join this phase's oracle (section 10).

### 1.2 CEL features: what the cases reach, what only the docs list

The named-condition cases (24) define 14 conditions (13 names; one is redefined in a later stage); the 9 inline-expression cases add 8 expressions. Everything they use:

| Feature | Reached by the cases | Docs or source only |
| --- | --- | --- |
| Parameter types | `int` (14 cases), `timestamp` (7), `string` (2), `bool` (1), `double` (1), `ipaddress` (1); inline: `string`, `int`, `timestamp`, `ipaddress` | `uint`, `duration`, `any`, `map<T>`, `list<T>`; `bytes` (in the docs table, rejected by the server: P1) |
| Literals | int (`100`, `50`, `10`, `200`), double (`0.0`), string with `"..."` and `'...'`, `true` | uint (`5u`), hex, exponent doubles, raw/triple-quoted strings, bytes, `null`, list `[...]`, map `{k: v}` |
| Operators | `<`, `>`, `==`, `\|\|`; a bare bool parameter as the whole expression (`ok`) | `&&`, `!`, `!=`, `<=`, `>=`, `+ - * / %`, unary `-`, `? :`, `in`, `[ ]`, field select on maps |
| Functions | `timestamp(string)` on a literal; `ipaddress.in_cidr(string)` | `ipaddress(string)`; CEL's standard library (docs link to the CEL spec and show `current_time < grant_time + grant_duration`): `size`, `contains`, `startsWith`, `endsWith`, `matches`, `int/uint/double/string/bool/duration/timestamp()`, timestamp and duration accessors (`getHours()`, ...), `has()`, macros `all`, `exists`, `exists_one`, `map`, `filter`; `type`, `dyn`, `bytes` |
| Timestamps and durations | `ts < timestamp("2023-10-11T10:00:00.000Z")`; RFC 3339 context values with milliseconds | timestamp ± duration, timestamp − timestamp, duration arithmetic, time zones in accessors |
| Context | request context on every kind of assertion; tuple context (`cidr` stored, `user_ip` from the request); contextual tuples carrying `condition` (the contextual run, 21 cases) | a request key overriding a tuple key (P5), map and list values |

So the cases need a small language (5 operators, 2 functions, 6 types). The rest is in scope because OpenFGA documents the types and points at CEL; section 4 says which part D implements.

### 1.3 Error expectations in the cases

| Code | When | Cases |
| --- | --- | --- |
| 2000 | a parameter the condition declares is in neither context (Check, ListObjects, ListUsers) | 17 named cases, 60 assertions; includes `x < 100 \|\| y < 50` with only `x` given (`direct_relations_with_condition`): a missing parameter is an error even when CEL's `\|\|` would already be true (`eval.go:131-138`) |
| 2000 | a double parameter out of float64 range, as a string or a number | `handles_floats` (10) |
| 2000 | a conditioned edge errors and no branch is true | `relation_through_ttu_with_condition` (`s == "foo"` false, `x` missing on the other parent) |
| 2000 | ListUsers: any conditioned edge on the walk errors, even when the user is reachable through a true edge | `relation_through_ttu_with_condition` (8 LU assertions) |
| 2027 | Check: a contextual tuple whose condition the relation doesn't allow for that facet (`user with isOk` where only `user:* with isOk` is) | `condition_bound_to_correct_type_restriction_facet` s1 (2) |
| 2000 | ListObjects and ListUsers: the same contextual tuple | same case (2) |
| none: ignored | a stored tuple whose condition the current model no longer allows for its facet (no error, the edge is absent) | `prior_conditions_ignored` s1, `wildcard_with_condition` s1 |
| none: true | a malformed timestamp in the request on one path, a true unconditioned path elsewhere | `ttu_mix_with_userset_member_condition_mixed_parents` (`"2023-10-11T11:00.000Z"`) |

No case writes a model or a tuple that must be rejected; those come from `test/fga_lang` (2056 undefined condition) and the probes (section 2).

### 1.4 OpenFGA's parameter types and functions

| Type | Value accepted in a context (source) |
| --- | --- |
| `any` | anything, as is (`converters.go:74-76`) |
| `bool`, `string` | exactly that JSON type (`converters.go:10-17`) |
| `int`, `uint`, `double` | a JSON number or a base-10 numeric string, parsed as a 64-bit big float (`converters.go:19-72`): `int` and `uint` must be integral and are clamped silently to int64 (`1e30` is 9223372036854775807; P10), `uint` rejects negatives; `double` rejects a value that doesn't round-trip exactly, so the string `"0.1"` is an error and the number `0.1` is not (P32) |
| `duration` | a Go duration string, `"1h30m"`, `"300ms"` (`converters.go:78-90`, `time.ParseDuration`); `"1d"` is an error |
| `timestamp` | RFC 3339, `time.Parse(time.RFC3339)` (`converters.go:92-104`): fractional seconds and offsets yes, lower-case `t`/`z` or missing seconds no |
| `ipaddress` | `netip.ParseAddr`, IPv4-mapped IPv6 unmapped (`ipaddress.go:61-69`) |
| `map<T>`, `list<T>` | a JSON object (string keys) or array, each value converted as T (`generic.go:11-61`) |

The type list is `primitives.go:11-62` plus `ipaddress.go:41-52`, and the proto enum (openfga/api `authzmodel.proto:239-252`): no `bytes` there, so the docs table's `bytes` row describes nothing the server accepts. The CEL environment is cel-go's default (standard library, no extensions such as `strings` or `math`), plus `ipaddress(string)` and `IPAddress.in_cidr(string)` (`condition.go:28-42`, `ipaddress.go:16-52`). The output must be `bool` (`condition.go:138-143`). Limits: condition names `^[^:#@\s]{1,50}$`, at most 25 parameters with names of the same pattern, expressions up to 512 bytes (openfga/api `authzmodel.proto:202-227`); a tuple's condition name `^[^\s]{2,256}$` (`openfga.proto:88-100`), its context up to 32 KB (docs, "Limitations"); evaluation cost at most 100 (`pkg/server/config/config.go:67`, docs).

## 2. What the server says

`test/fga_abac/probe.sh`, against the pinned image. Each answer is a behavior to pin with an in-house spec in step 3 or 4.

| # | Request | OpenFGA v1.22.1 |
| --- | --- | --- |
| P1 | model with a `bytes` parameter (JSON; the DSL has no `bytes`) | 2056 unknown condition parameter type |
| P2 | condition key differs from its `name` | 2056 |
| P3 | `map` parameter without a generic type | 2056 |
| P4 | CEL syntax error; undeclared identifier; non-bool result; `x < "a"`; `x < 1.5` with `x: int` | 2056 each (`failed to compile expression on condition 'cx' - ...`): CEL is type-checked at model write and has no implicit int/double conversion |
| P5 | tuple context `{x: 10}`, request `{x: 200}`, `x < 100` | true: **the tuple's context wins** (`eval.go:112-125`: request first, tuple appended; `condition.go:218-223`: the last map wins; docs: "the context values written in the relationship tuple take precedence") |
| P6 | Write: undefined condition; a context key that isn't a parameter; a wrongly typed context value; no condition where only `with cx` is allowed; a condition on an unconditioned restriction | 2000 each, `Invalid tuple '...'. Reason: ...` (`validation.go:213-311`, `InvalidConditionalTupleError` → `validation_error`, `pkg/server/errors/errors.go:158-162`) |
| P7 | Write the same key again with another context | 2017; with `on_duplicate: ignore` HTTP 409 `Aborted` "attempted to write a tuple which already exists with a different condition" |
| P8 | Read | the tuple key includes `condition: {name, context}` |
| P9 | Delete without naming the condition | deletes (the key is user, relation, object) |
| P10 | `int` given `"10"`, `10.0`, `-5`, `"1e1"`; `1e30` | true; `1e30` false (clamped) |
| P11 | `int` given `10.5`, `true`, `"0x10"`, `null` | 2000 each |
| P12 | `double` given `1.8e+309` as a JSON number | 2000 at request parsing (`invalid google.protobuf.Value`) |
| P13 | request context with keys no condition uses | ignored |
| P14 | Check `user:jon viewer doc:2`, where `doc:2#viewer@group:x#member` (condition, no context) and jon is not in group:x | **2000**: an erroring edge off the user's path still fails a Check that finds nothing true |
| P15 | ListObjects for `user:ann`, who has no tuples (doc:2's edge exists) | `[]`: the edge isn't on the walk |
| P16 | ListObjects for `group:x#member`; ListUsers on `doc:2` | 2000, 2000 |
| P17 | `x < 100 \|\| 10 / y == 1` and `10 / y == 1 \|\| x < 100`, `x = 10, y = 0` | true, true: CEL's `\|\|` absorbs an error from either side |
| P18 | the same with `x = 200` | 2000 (division by zero) |
| P19 | `l.exists(e, e == "zzz")` over 3 strings; over 50 | true; 2000 "actual cost limit exceeded" |
| P20 | `list<string>` with a number element | 2000 |
| P21 | `t + d > timestamp(...)`, `d = "1h"`, `"1h30m"`; offsets `+02:00` | true |
| P22 | `d = "1d"`; `t` without seconds; lower-case `t`/`z` | 2000 each |
| P23 | `m.a` on `map<int>` with the key absent | 2000 "no such key" |
| P24 | `a == 1` with `a: any` given `1`; given `"1"` | true; false (no error: CEL's heterogeneous equality) |
| P25 | Check, contextual tuple with an undefined condition or a wrongly typed context | 2027 (Check wraps every contextual tuple error, `pkg/server/commands/errors.go:100-104`) |
| P26 | ListObjects, the same contextual tuple | 2000 |
| P27 | contextual tuple context `{x: 1}`, request `{x: 500}` | true (tuple wins here too) |
| P28 | stored context `{x: 10}`, then a model where the condition takes `x: string`: Check | false (the tuple is ignored: `FilterInvalidTuples`, `validation.go:60-83, 379-384`) |
| P29 | the same data: ListObjects | **2000** (its iterator evaluates instead of filtering) |
| P30 | stored context key `x`, then a model where the condition has only `y`: Check | false (ignored) |
| P31 | `uint` given `-1`; given `1e19` | 2000; true (clamped to int64 max) |
| P32 | `double` given the number `0.1`, the string `"1.5"`; the string `"0.1"`, `"1e400"` | true, true; 2000, 2000 (`number cannot be represented as a float64`) |
| P33 | model: a condition name with `:`; an expression over 512 bytes; 26 parameters | 2000 each (`invalid Condition.Name`, `...Expression ... at most 512 bytes`, `...Parameters ... no more than 25 pair(s)`): the request's validation |
| P34 | `(x > 1 ? 1 : "a") == 1` | 2056 (`found no matching overload for '_?_:_' applied to '(bool, int, string)'`) |
| P35 | `a` alone, `a: any` | 2056 (`expected a bool condition expression output, but got 'google.protobuf.Any'`) |
| P36 | `size([1, "a"]) == x` | accepted: a list literal of mixed types is a list of dyn |
| P37 | `dyn(x) < 1.5` | accepted (D refuses `dyn()`, decision 10) |
| P38 | `l.exists(e, e == "zzz")` over 10, 20, 25, 30, 40 strings; a 35-term `\|\|` chain of `x == n`, all false | false, then 2000 from 20 on (`actual cost limit exceeded`); false |
| P39 | a condition with no parameters (`true`), empty context; context `{z: 1}` | true; 2000 (`no parameters defined for the condition`) |
| P40 | `t.getHours("Europe/Paris") == 12 && t.getHours("+02:00") == 12 && t.getDayOfWeek() == 0 && t.getMonth() == 6`, `t = 2024-07-07T10:00:00Z` | true (`+02:00` is two hours east) |
| P41 | `a < 5`, `a: any`, given 3 | true (a double compares with an int at run time) |
| P42 | Read of a tuple written with a condition and no context | `condition: {name, context: {}}` |
| P43 | Write: a tuple condition named `c` (one character) | 2000 (`RelationshipCondition.Name` must match `^[^\s]{2,256}$`) |
| P44 | Write the same key with the same condition, `on_duplicate: ignore` | written (skipped) |

## 3. Semantics D adopts

1. **Context merge**: the request's `context` first, the tuple's condition context on top; the tuple wins on a shared key (P5, P27). Stored and contextual tuples alike.
2. **Typing at write**: a model's conditions are parsed and type-checked when the model is written; a syntax error, an unknown identifier, a type error, a non-bool result, an unknown parameter type or a missing generic, a key that differs from the name, or a restriction naming an undefined condition is 2056 (P1-P4, fga_lang). A tuple's condition name, its facet, its context keys and value types are checked by `fga_write` (2000, P6) and for contextual tuples (Check 2027, lists 2000; P25, P26, the `condition_bound` case).
3. **Missing parameters**: after the merge, a declared parameter with no value makes the edge an **error** (2000), whatever the expression would give (`direct_relations_with_condition`). Checked before evaluating, so the evaluator never sees unknowns.
4. **Conversions** follow `converters.go` exactly, quirks included (section 1.4; P10, P11, P32, P31). A request value that fails conversion makes the edge an error; JSON numbers are read through float8, as OpenFGA reads them through float64 (jsonb would otherwise keep digits OpenFGA drops).
5. **Stored tuples the model no longer accepts are ignored**, not errors: a condition the restriction doesn't allow for the tuple's facet (cases), and, as OpenFGA's Check does, a stored context with a key that isn't a parameter or a value that no longer converts (P28, P30). OpenFGA's ListObjects raises 2000 on the latter (P29); D ignores it in every API, so the lists stay consistent with Check (deviation; open question 4).
6. **CEL inside an expression**: `&&` and `||` are commutative and absorb errors (`true || error` is true, `false && error` is false, otherwise the error; P17, P18); `? :` evaluates only the chosen branch; everything else propagates the first error. Values are never unknown (rule 3).
7. **Errors across the graph**, as OpenFGA, per API:
   - **Check**: true if a path of true edges exists. Otherwise 2000 if OpenFGA's top-down search would have evaluated an erroring edge: one in the backward closure from the object (userset and tupleset tuples of the nodes it reaches, and the user's own direct tuples), even off the user's path (P14); else false. An error loses to a branch that decides (`relation_through_ttu...`, `mixed_parents`); in an intersection a false branch decides, in a difference a false base or a true subtract decides. A depth error (2002) outranks a condition error (`pkg/server/commands/errors.go:111-117`).
   - **ListObjects**: 2000 if any edge the forward walk takes errors (P15, P16, cases); otherwise the objects.
   - **ListUsers**: 2000 if any edge the backward walk takes errors, even when every user is also reachable through true edges (`relation_through_ttu...`); plain-user tuples of a type the filters exclude are not evaluated.
   - **Current-subject functions** (`fga_check_current`, `fga_list_objects_current`, `fga_list_object_ids_current`): no request context (they take none, like contextual tuples, section 4 of d-per-model.md) and they never fail on a condition: an answer that depends on an evaluation error is a deny (deviation; decision 4). In the positive walks an erroring edge is not taken; under a subtract it is taken (so it removes the object), and `_fga_rec` reports it (result 4), which counts as false. A condition true from the tuple's stored context alone counts.

## 4. Language subset, tokens, AST

**Implemented** (the cases plus what the docs list, in three tiers, each with in-house specs):

- Tier 1, the cases: parameters of types `int`, `double`, `string`, `bool`, `timestamp`, `ipaddress`; int, double, string (both quotes) and bool literals; `<`, `>`, `==`, `||`; `timestamp(string)`; `x.in_cidr(string)`.
- Tier 2, the documented types and CEL's standard operators over them: `uint`, `duration`, `any`, `map<T>`, `list<T>`; `null`, uint, hex and exponent literals, raw and triple-quoted strings, list and map literals (string, int, uint and bool keys); `&&`, `!`, `!=`, `<=`, `>=`, `+ - * / %` (int64 and uint64 overflow and division by zero are errors), unary `-`, `? :`, `in`, `[ ]`, `.field` on maps, `has()`; `size`, `contains`, `startsWith`, `endsWith`, `matches`; conversions `int`, `uint`, `double`, `string`, `bool`, `timestamp`, `duration`; timestamp ± duration, timestamp − timestamp, duration ± duration, comparisons; timestamp accessors with an optional time zone and duration accessors; macros `all`, `exists`, `exists_one`, `map`, `filter`; `ipaddress(string)`.
- Tier 3, **rejected at model write** with 2056 and a HINT naming the feature: `bytes` (literals and `bytes()`), `type()`, `dyn()`, type names used as values, message construction, CEL optional syntax. OpenFGA accepts these (except a `bytes` parameter); no case or doc example uses them. Deviation, listed in d-per-model.md section 8.

**Tokens** (`_fga_cel_tokens(expr) returns table(pos int, kind "char", text text)`, one regex-driven loop): identifier, int, uint, double, string (value with escapes decoded), and the punctuators `|| && ! == != < <= > >= + - * / % ? : . , [ ] ( ) { }`. Keywords `true false null in`; CEL's reserved words (`as break const continue else for function if import let loop package namespace return var void while`) are a syntax error, as in cel-go.

**Grammar** (CEL's, by precedence climbing):

```
Expr     = Or [ "?" Or ":" Expr ]
Or       = And { "||" And }
And      = Rel { "&&" Rel }
Rel      = Add { ("<" | "<=" | ">=" | ">" | "==" | "!=" | "in") Add }
Add      = Mul { ("+" | "-") Mul }
Mul      = Unary { ("*" | "/" | "%") Unary }
Unary    = Member | "!" {"!"} Member | "-" {"-"} Member
Member   = Primary { "." IDENT [ "(" [Args] ")" ] | "[" Expr "]" }
Primary  = IDENT [ "(" [Args] ")" ] | "(" Expr ")" | "[" [Args] [","] "]" | "{" [Inits] [","] "}" | LITERAL
```

**AST** (jsonb, one object per node; every node carries its static type `t` from the checker):

| Node | Shape |
| --- | --- |
| literal | `{"k":"lit","t":"int","v":100}` (timestamps as RFC 3339 text, durations as integer nanoseconds, uint and int as numbers kept exactly) |
| parameter | `{"k":"id","t":"timestamp","n":"ts"}` |
| call | `{"k":"call","t":"bool","f":"_<_timestamp","a":[...]}`: `f` is the **overload** the checker resolved (`_<_int`, `_+_timestamp_duration`, `in_cidr`, `size_string`, ...), so evaluation dispatches on one text compare, no type inspection |
| logic | `{"k":"or","a":[x,y]}`, `{"k":"and",...}`, `{"k":"cond","a":[c,x,y]}` (kept apart from calls: their evaluation rules differ, section 3 rule 6) |
| select, index | `{"k":"sel","f":"a","a":[m]}`, `{"k":"has","f":"a","a":[m]}`, `{"k":"idx","a":[x,i]}` |
| list, map | `{"k":"list","a":[...]}`, `{"k":"map","a":[k1,v1,k2,v2,...]}` |
| comprehension | `{"k":"comp","m":"exists","v":"e","a":[range, body]}` |

Compilation at model write: tokens → parser → macro expansion (`has`, comprehensions) → type checker (parameter types, overload resolution, bool result) → folding of calls on literals that can't fail (`timestamp("2023-...")` becomes a timestamp literal; an invalid literal is left for evaluation, since cel-go accepts the model and errors at evaluation) → jsonb. A type `dyn` (from `any`, or a list or map of `any`) makes the checker emit a generic overload (`_==_dyn`) that dispatches on the runtime kind.

## 5. Storage of the compiled form

No parsing at Check time in any option. Options:

| | S1: jsonb AST in a table | S2: AST as rows | S3: generated SQL per condition |
| --- | --- | --- | --- |
| Shape | `fga_conditions(model_id, name, expression, parameters jsonb, ast jsonb)` | `fga_condition_nodes(model_id, condition, node, op, args int[], literal, type)`, like `fga_rewrite_nodes` | at model write, `create function permissions._fga_cond_<model>_<n>(ctx jsonb) returns boolean` (or a SQL text column run with `EXECUTE`) |
| Evaluation | the walk joins `fga_conditions` and passes `ast` to the interpreter | the interpreter loads the rows (or arrays) per call | a function call; the plan is cached |
| Measured (section 8) | 1.8-3.0 µs per evaluation | 3.5-4.5 µs with the arrays loaded in one row; a query per node would be slower | 0.1-0.6 µs (SQL or PL/pgSQL function); `EXECUTE` 3.4 µs |
| Error semantics (section 3) | in the interpreter | in the interpreter | every node that can fail needs a value-or-error encoding in SQL (`CASE` per operand), or an exception block per call (a subtransaction) |
| Runtime DDL | none | none | one function per condition per model version, created by a SECURITY DEFINER function from user-supplied text (section 9) |

**Recommendation: S1.** It is the fastest of the forms that keep the evaluator data-driven, it keeps model writes free of DDL, and a model's conditions stay data (dumped and restored with the other `fga_*` rows). The tree is small (an expression is at most 512 bytes) so jsonb's per-node lookups are cheap. S3 is the fallback if phase 5 shows condition evaluation dominating a real workload, and only for expressions in the error-free fragment (comparisons and logic over converted parameters), where SQL's semantics and CEL's coincide.

## 6. Evaluator

| | E1: tree-walking interpreter | E2: compile to a SQL expression | E3: interpreter with per-request memo |
| --- | --- | --- | --- |
| How | `_fga_cel_eval(ast jsonb, ctx jsonb) returns fga_cel_value`, recursive PL/pgSQL, one `case` on the node kind and overload | S3 above, spliced into the walks or called per row | E1, called once per distinct (condition, tuple context) per walk step instead of once per tuple |
| CEL semantics | exact: errors are values, `&&`/`\|\|` absorb them, comprehension cost counted | approximate unless every operand is wrapped | as E1 |
| Cost | 2-3 µs per evaluation for the case expressions (section 8) | 0.1-0.3 µs | E1 × distinct contexts: in the cases and the common shapes (expiry, IP, "condition with only request parameters") the tuple contexts are few or identical, so a step evaluates a condition a handful of times however many tuples match |

**Recommendation: E1 with E3's dedupe in the set-based steps.** Correctness lives in one interpreter, which every walk and evaluator calls; the dedupe is a SQL `distinct` over (condition, context) in the step, no state across calls.

**Values**: a composite `permissions.fga_cel_value(k "char", b boolean, i bigint, u numeric, d float8, s text, ts timestamptz, du bigint, ip inet, j jsonb, et text)`: one field per kind (`ts` microseconds, `du` nanoseconds, `ip` core `inet`, `j` the payload of a list or map with `et` its element type), and kind `E` with the message in `s` for an error value. A composite can't contain itself, hence jsonb for list and map payloads, with elements in a canonical encoding per static element type. Exceptions are avoided on the hot path: int arithmetic checks bounds before computing, timestamp and duration input is matched by a regex before the cast; the one exception block left is the RE2-vs-ARE regex compile in `matches`.

**Parameters**: `_fga_cel_params(params jsonb, ctx jsonb)` merges, checks presence (rule 3) and converts each value by its declared type (rule 4), returning the typed activation as jsonb or an error value. Done once per (condition, merged context). The two sides fail differently (rule 5): a stored context with a key that isn't a parameter or a value that doesn't convert makes the tuple ignored (false); a request value that doesn't convert, or a missing parameter, makes it an error.

**Cost limit**: cel-go's cost model (each call and each comprehension step costs, strings by size) is approximated with a counter of evaluated nodes plus one per comprehension iteration, limit 100. It catches runaway comprehensions; the exact threshold won't match cel-go's (P19 passes; a list of 30 elements might not match). Deviation; open question 5.

**Precision**: timestamps are microseconds (CEL: nanoseconds; sub-microsecond digits are truncated), within 0001-01-01 to 9999-12-31; double arithmetic that overflows gives an error (Postgres raises; CEL gives ±Inf); `matches` uses Postgres regular expressions (RE2 syntax mostly agrees; lookarounds don't exist in RE2 and do in Postgres); IPv6 zones (`fe80::1%eth0`) are rejected (`inet` has none). Deviations, listed with the others.

## 7. Tables, API, walks

### 7.1 Tables

- `fga_conditions (model_id, name, expression text, parameters jsonb, ast jsonb)`, primary key `(model_id, name)`, written by `fga_write_authorization_model`.
- `fga_type_restrictions` gains `condition text collate "C" not null default ''` in its primary key (`[user, user with c]` is two rows).
- `fga_edges` (`d` and `t`) and `fga_walk_steps` gain `condition` (`''` none): for `d`, the restriction's; for `t`, the tupleset restriction's. An edge per allowed condition, so a tuple matches exactly one edge (`e.condition = tu.condition_name`), and a tuple whose condition the model doesn't allow for its facet matches none: rule 5 for free, the same way D already ignores tuples of a type the model dropped.
- `fga_relations` gains `conditional boolean`: some conditioned edge is in the relation's positive closure (or its subtract's). False means today's code path, unchanged.
- `fga_tuples` gains `condition_name text collate "C" not null default ''` and `condition_context jsonb` (null when none). Not in the key (P7, P9). The composite `fga_tuple` (contextual tuples) gains the same two fields at the end.

### 7.2 API

`fga_check`, `fga_list_objects`, `fga_list_users` get a last parameter `context jsonb default null` (OpenFGA's request `context`; last so existing positional calls keep working). `fga_write` accepts `condition: {name, context}` on a tuple key; `fga_read` returns it in `key` (P8); deletes ignore it (P9); a write of an existing key with a different condition is 2017, also with `on_duplicate: ignore` (OpenFGA's 409 `Aborted` has no numeric code; open question 6). The current-subject functions take no context (rule 7).

### 7.3 Evaluation call

Every tuple read in a walk becomes, for a conditioned row only:

```sql
tu.condition_name = ''
or permissions._fga_cond(c.ast, c.parameters, p_req, tu.condition_context, p_mode, <tuple for the message>)
```

with `c` joined from `fga_conditions` on `(p_m, tu.condition_name)`. `p_mode` is `r` (raise 2000 on an error), `d` (an error is false) or `t` (return null for an error: SQL's unknown is the third value). An unconditioned row never calls it. A walk whose target relation is not `conditional` runs today's statement, with one more equality on the edge join and no join to `fga_conditions` (the step functions branch on the flag in PL/pgSQL, so each branch keeps its own cached plan): that is the unconditioned fast path.

### 7.4 Each evaluator

| Evaluator | Change |
| --- | --- |
| `_fga_fstep`, `_fga_bstep` (Check's bidirectional steps) | the edge join adds `e.condition = tu.condition_name`; conditioned hits go through `_fga_cond` in mode `d`, deduplicated per (condition, context) in the step |
| `_fga_bidi` | runs as today with errors counting as false (mode `d`). True: done. False on a `conditional` relation in mode `t`: one more walk, the backward closure from the object (`_fga_bstep` without subjects, plus the user's own direct tuples) in mode `r`; it raises 2000 if OpenFGA's top-down search would have met an erroring edge (rule 7, P14), else false. Returns a new code 4 for that case when called from `_fga_rec` |
| `_fga_rec`, `_fga_rec_node` | top-down like OpenFGA, so conditions are evaluated where OpenFGA evaluates them: the user's direct tuple and wildcard, each userset tuple, each tupleset tuple. A false condition skips the tuple, an error sets a new result code 4 (condition error) next to 3 (depth); union, intersection and difference combine 4 like 3, and 3 outranks 4 when both occur |
| `_fga_forward`, `_fga_forward_ids` (ListObjects) | the step probes add the condition match; conditioned hits in mode `r` (`fga_list_objects`) or `d` (the `_current` RLS functions) |
| `_fga_backward`, `_fga_list_users` | the same, mode `r`; plain-user hits are evaluated only for types the filters name |
| set-based `but not` (ListObjects and ListUsers) | both walks in the request's mode; `diff_recheck` and the per-candidate path call `_fga_rec`, whose code 4 raises 2000 in the lists |
| `_fga_check_impl` | `_fga_rec` code 4 or `_fga_bidi` code 4 raises 2000 with the first error's message; mode `d` from `fga_check_current` returns false |
| `_fga_ctx` (contextual tuples) | validates condition, facet and context (Check 2027, lists 2000); the composite carries the condition |

Depth is unchanged: a condition is a filter on an edge, not a level.

## 8. Performance

Throwaway measurement (tag `cond-eval-micro`): [`d-conditions/measure.sql`](./d-conditions/measure.sql), run by `d-conditions/measure.sh` on a throwaway cluster, PostgreSQL 16.4 (Postgres.app), Apple silicon, 2026-10-29, nothing else running but the idle Docker stacks (Supabase, freereps, an openfga container). 100,000 rows, one evaluation per row, best of 5:

| Expression | none (loop) | SQL inline | SQL function | PL/pgSQL function | EXECUTE | interpreter, jsonb AST (S1/E1) | interpreter, array AST (S2) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `x < 100` | 1.8 ms | 11.0 | 10.8 | 23.1 | 342 | 184 | 352 |
| `ts < timestamp("...")` | | 19.2 | 58.6 | 30.3 | | 256 | 451 |
| `x < 100 \|\| y < 50` | | | 11.1 | 23.2 | | 296 | 414 |

So: an interpreted evaluation costs 2-3 µs (the prototype interpreter is smaller than the real one, which also converts parameters fully and tracks cost: expect 3-6 µs), a generated function 0.1-0.6 µs, `EXECUTE` is no faster than interpreting, and arrays lose to jsonb in PL/pgSQL (each recursive call copies them).

Expectations, to measure in phase 4 step 5 and phase 5 (same benchmark, tagged runs, one at a time):

- **Unconditioned data and models**: within noise of opt2 for Check and ListObjects (one extra equality on the edge join; no condition call; `conditional = false` keeps today's plans).
- **Conditioned edges**: one evaluation per distinct (condition, tuple context) per walk step, plus one jsonb merge. A Check through a few conditioned edges adds tens of µs to a ~0.3 ms check; a wide ListObjects whose 10,000 tuples share one condition and no stored context adds one evaluation per step, not 10,000; with 10,000 distinct stored contexts (per-tuple expiry) about 30-60 ms.
- **False Check on a conditional relation** (API only, not RLS): the extra backward closure walk of rule 7, about the cost of the backward half of today's bidi.
- **Model write**: tokenizing, parsing and checking a 512-byte expression in PL/pgSQL, a few ms per condition, once.

## 9. pg_tle and runtime DDL

The design adds tables, PL/pgSQL functions and one composite type, and uses only core types (`inet`, `timestamptz`, `jsonb`): plain SQL and PL/pgSQL, installable by `pgtle.install_extension` like the rest (spec `03_tle_install`).

S3 would mean `CREATE FUNCTION` at runtime from `fga_write_authorization_model`. pg_tle doesn't forbid it (an extension function may run DDL with its owner's rights), but:

- The model writer's text becomes function source, run as the SECURITY DEFINER owner. Any quoting bug in the compiler is SQL injection with the extension owner's privileges: a "may write a model" grant becomes "may run code as the owner".
- Those functions are not extension members: `pg_dump` dumps them as ordinary objects next to the extension, `DROP EXTENSION` doesn't remove them (or fails on the dependency), and `ALTER EXTENSION ... ADD` is needed to adopt each one, which itself needs ownership.
- One function per condition per model version accumulates (models are immutable); `fga_delete_store` would have to drop them.
- DDL on every model write fires event triggers; on Supabase that includes PostgREST's schema-reload trigger.

S1 needs none of this: a model write is DML only.

## 10. The design against every case

Run cases (24); "edge" means a tuple read by a walk. Every case also runs contextual (except the 3 multi-stage ones), which exercises the same rules through `fga_tuple` rows carrying the condition.

| Case | Features | How the design handles it |
| --- | --- | --- |
| direct_relation_with_condition | int, `<`; missing param | rule 3 (2000 in all three APIs); `_fga_bidi` false + backward closure raises; lists in mode `r` |
| indirect_relation_with_condition | timestamp, `timestamp()` literal (folded); condition on a userset edge | edge per condition on `d`; LU with filter `group#member` evaluates the userset edge (false → excluded) |
| userset_child_with_condition | condition on the child's plain-user tuple | LU `group#member`: the plain-user edge is not evaluated (filter), so `group:eng#member` stays |
| userset_parent_with_condition | condition on the userset edge | as indirect |
| nested_indirect_relation_with_condition | ipaddress, `in_cidr`; **tuple context + request context** | rule 1 merge; `inet` containment with mapped-address unmapping |
| computed_userset_with_condition | condition under a computed relation | computed closure unchanged; the `d` edge carries the condition |
| tuple_to_userset_with_condition | condition on a tupleset tuple | `t` edges and walk steps carry the tupleset restriction's condition |
| direct_relations_with_condition_through_intersection | two conditions, intersection; LO/LU without context | `_fga_rec` intersection (code 4 with no false branch → 2000); lists in mode `r` |
| simple_userset_with_condition | condition on userset edge; userset user | `_fga_bidi` from a userset user; LO for `folder:a#viewer` |
| simple_userset_with_condition_in_child | condition in child | as userset_child |
| simple_userset_with_and_without_condition_in_child | `[user with xcond, user]` | two restriction rows, two edges; an unconditioned tuple never calls the evaluator (bob, no context: true) |
| simple_ttu_with_condition | conditioned tupleset | `t` edge condition |
| simple_ttu_with_and_without_condition | mixed child restrictions; LO for the unconditioned user with no context | LO walks only the user's own edges (none conditioned) → no error; LU touches the conditioned edge → 2000 |
| simple_ttu_with_multiple_conditions | `[user with xcond, user with ycond]`; each user's own condition | edge per condition; a context with only `y` for the `xcond` user → missing `x` → 2000 |
| simple_ttu_with_condition_in_child | | as above |
| relation_through_ttu_with_condition | two conditions on two parents, union with `[user]`; string literal; a contextual tuple making it true | rule 7: Check true if one parent is true, 2000 if none true and one errors; LU 2000 whenever an edge on the walk errors |
| direct_relations_with_condition | `x < 100 \|\| y < 50` | rule 3 (missing → 2000 despite `\|\|`); `\|\|` otherwise |
| prior_conditions_ignored | stages: condition renamed, then redefined with a new expression | edges are per model: a tuple whose condition isn't allowed matches no edge (ignored); stage 2 evaluates `oldcondition` with the stage-2 expression (`fga_conditions` per model) |
| handles_floats | double; out-of-range string and number | rule 4: float8 conversion of jsonb numeric (overflow → error), big-float string parse |
| ttu_mix_with_userset_member_condition | conditioned members, `user:*` unconditioned, TTU; checks with no context through the public path | bidi finds the true unconditioned path first (true); LU/LO with context |
| ttu_mix_with_userset_member_condition_mixed_parents | as above with two group types; **malformed timestamp** | the malformed value errors only the `group1` edge; `group2`'s true path decides (rule 7) |
| ttu_mixed_parents_public_wildcard | `user:* with ts_less_than` | wildcard tuples carry conditions like any tuple; LU returns `user:*` when true |
| wildcard_with_condition | unconditioned `user:*` tuple, then a model allowing only `user:* with ...` | the old tuple matches no edge (ignored: false); the new conditioned wildcard evaluates |
| condition_bound_to_correct_type_restriction_facet | facets: concrete, wildcard, userset with the condition on one facet; `group with isOk`; bool param as expression; invalid contextual tuples | restriction rows per facet and condition; contextual validation: Check 2027, lists 2000 (rule 2) |

Skipped (9, `inline-expression`): `inline_expression_exclusion_subtract_missing_param`, `_basic`, `_inferred_string_param`, `_alongside_named_condition`, `_int_param`, `_timestamp_param`, `_ipaddress_param`, `_userset_subject`, `_ttu`. They need `$expression` (open question 1). Their expressions use only Tier 1 features, so supporting them later is a storage question (compile at tuple write, deduplicated by expression), not a language one.

openfga/language cases now skipped as `conditions` (8), run again in step 3:

| Case | Server | D after step 3 |
| --- | --- | --- |
| condition not defined (3 cases) | 2056 | 2056 (rule 2) |
| extraneous condition; unused condition whose name is a prefix | 201 | accepted (an unused condition is compiled and stored) |
| handle single name duplicated type and unused condition | 2056 (duplicate type) | 2056: the condition is valid, the duplicate type check raises |
| inline expression mixed with plain and named condition; inline expression on userset | 2000 (`$expression` needs the flag) | 2000 if `$expression` stays out of scope (open question 1), with a HINT saying so |

## 11. Open questions for the user (decided)

Decided on 2026-10-29 and 2026-10-30, as recommended below except where noted: [`DECISION.md`](../DECISION.md), "Decisions for conditions (session 5)". 1: out of scope, 2000. 2: deny, no trusted context yet (`usage/rls.md` shows a `security definer` wrapper that passes `now()`). 3: OpenFGA's rule. 4: ignored everywhere. 5: the counter, limit 100. 6: 2017 with a HINT. 7: refused at model write (2056).


1. **Inline expressions (`$expression`)**: experimental in OpenFGA, off by default; upstream's ABAC suite turns the flag on (9 cases). Recommendation: out of scope for phase 4; reject `$expression` with 2000 as the default server does (the fga_lang cases agree). Supporting them later reuses the compiler: compile at tuple write, store the AST once per distinct expression.
2. **Conditions in RLS**: the current-subject functions take no request context, so a condition that needs a request parameter can never be true in a policy; D denies (rule 7). Should they get a trusted server-side context, for example `{"current_time": now()}` or values from `request.jwt.claims`, under fixed names? Recommendation: deny in phase 4, decide the names afterwards; expiry ("tuple context `expires`, request `current_time`") is the common case it would unlock.
3. **Check's error rule**: D follows OpenFGA (an erroring edge anywhere in the object's backward closure fails a Check that finds nothing true, P14), at the cost of one backward walk on false answers of `conditional` relations. The alternative is a path rule (an error only matters if the user is reachable through it): cheaper and independent of search order, but it answers false where OpenFGA answers 2000. Recommendation: OpenFGA's rule.
4. **Stale stored contexts** (a value the current model's parameter type rejects): OpenFGA's Check ignores the tuple, its ListObjects raises 2000 (P28, P29). Recommendation: ignore everywhere (consistent lists; a deviation for ListObjects).
5. **Cost limit**: approximate cel-go's limit of 100 with a node and iteration counter (threshold differs from cel-go), or enforce none (D has no other per-request budget except `statement_timeout`)? Recommendation: the counter.
6. **Same tuple key, different condition, `on_duplicate: ignore`**: OpenFGA answers HTTP 409 `Aborted` with no numeric code. Recommendation: 2017 with a message saying the condition differs.
7. **Tier 3** (bytes, `type()`, `dyn()`): reject at model write as proposed, or implement? Recommendation: reject; nothing in the cases or docs uses them.

## 12. Steps 3 to 6, spec-first (done)

- Step 3 (model write): specs for P1-P4, the fga_lang 8, the name and size limits (section 1.4), Tier 3 rejection; then tokenizer, parser, checker, `fga_conditions`, restriction and edge rows with conditions; `0A000` removed; `d/35_error_hints` rows for each new raise site.
- Step 4 (evaluation and tuples): specs for P5-P13, P17-P32 and rules 1-6 against `_fga_cond` directly and through `fga_check`; then values, parameters, interpreter, `fga_write`/`fga_read`/contextual tuples.
- Step 5 (walks): `generate.py --suite`, the abac suite red then green in both runs; P14-P16 and the rule-7 cases as specs; the consolidated suite still 933/746; mutants from PLAN.md (ignore the condition, missing parameter as false, swap the merge, skip the type check) plus "evaluate errors as false in Check" (should fail `relation_through_ttu...` and P14's spec); before/after timings on the benchmark, tagged.
- Step 6: d-per-model.md sections 2, 4, 7, 8 (deviation 2 replaced by the deviations above), `usage/` conditions page (expiry, IP range) with specs.

## 13. As implemented (phase 4, steps 3 to 6)

### 13.1 Where it lives

In [`pg_permissions--0.0.1.sql`](../pg_permissions--0.0.1.sql), section "Conditions (CEL): compiler and evaluator": `_fga_cel_tokens`, `_fga_cel_parse` (one recursive function, CEL's precedence levels), `_fga_cel_check` (types, overloads, macros, folding), `_fga_cel_compile`; `_fga_cel_convert` and the parsers of timestamps, durations and ip addresses (OpenFGA's converters); `_fga_cel_eval` (the interpreter); `_fga_cond_eval` (one tuple's condition: merge, presence, conversion, evaluation), `_fga_cond` (a filter, by mode), `_fga_conds_ok` (the true ones among distinct (condition, context) pairs) and `_fga_cond_fail` (the one 2000 raise site for an evaluation error). The model write fills `fga_conditions`, the `condition` columns of restrictions, edges and walk steps, and `fga_relations.conditional`. The walks of [`d-per-model.md`](./d-per-model.md) section 5 take `p_req` (the request's context) and `p_mode`.

### 13.2 Where it differs from the design above

1. **Values are jsonb**, in one canonical form per static type, instead of a composite with a field per kind (section 6): numbers for int, uint and double (a double through float8's shortest text), integer nanoseconds for durations, `YYYY-MM-DDTHH:MI:SS.USZ` in UTC for timestamps (so text order is time order), the text of an ip address, arrays and objects for lists and maps (a map keyed by its key's text). Equality is jsonb equality (CEL's heterogeneous equality included: `1 == 1.0` in a dyn); the evaluator returns `fga_cel_result(v, e, c)`: the value, an error message, the cost so far. Types only matter at run time for dyn, and dyn values are JSON from `any` parameters, whose numbers are doubles as in OpenFGA's JSON context.
2. **Mixed literals.** OpenFGA accepts `[1, "a"]` as a list of dyn (P36); so does D, but an int or uint in it, or in a map literal of mixed types, behaves as a double afterwards (`[1, "a"][0] + 1` is "no such overload" here, 2 in cel-go). A conditional with branches of two types is refused, as by the server (P34).
3. **Modes.** Besides r (fail with 2000), d (an error is false) and t (report it: `_fga_rec`'s result 4), two more: e, in which `_fga_bstep` returns the error as a row (Check's error walk, `_fga_bidi_errors`, which returns the message rather than raising), and n, in which an error counts as true: the RLS helpers' subtract walks (set-based `but not` lists), so that an error removes an object instead of granting it. For the RLS helpers `_fga_rec` runs in mode t and 4 is false. Decision 4 says "deny"; mode d alone would have let a user through a `but not` whose subtract errors, which `d/39` pins.
4. **One evaluation per distinct context** (decision 2) in `_fga_fstep`, `_fga_bstep`, Check's error walk, and the leaves of `_fga_forward` and `_fga_forward_ids` (the last join, where a wide walk's thousands of objects are): `_fga_conds_ok` over `jsonb_agg(distinct [name, context])`. `d/39` checks that a ListObjects over 50 tuples sharing one condition and context evaluates it once. Inside the recursive term of the forward walk (the expandable nodes: teams, folders) a conditioned tuple is evaluated per row, because a recursive term can't aggregate: a walk through many conditioned memberships with distinct contexts pays one evaluation per membership per level reached. Phase 5 can move that walk to a loop if it matters.
5. **Cost**: 1 per identifier, call, operator, field selection, index and list or map literal evaluated, nothing for literals and for `||`, `&&` and `? :` (as cel-go), 3 per comprehension iteration; past 100, the evaluation fails ("operation cancelled: actual cost limit exceeded"). `l.exists(e, e == "zzz")` passes over 19 elements and fails over 20, the server somewhere between 11 and 20 (P38: 10 passes, 20 fails); the 35-term chain of P38 costs 70; the abac cases cost at most a handful.
6. **Check's error walk** follows the object's backward closure up to depth 25 (deeper, OpenFGA would hit its depth limit first).
7. **Write**: a conditioned tuple written without a context is stored and read back with `{}` (P42); a one-character condition name in a tuple is 2000 (P43), as in OpenFGA, so a condition named with one character can be declared but not used in a tuple.
8. **Compile errors** name the column of the operator or token, as cel-go does (`... applied to '(int, string)' (column 3)`).
9. **The request's validation** of conditions (2000) covers the condition name, expression size, parameter count and parameter names (P33) and inline `$expression` (decision 8).

### 13.3 Deviations, the full list

From OpenFGA v1.22.1, all documented in [`d-per-model.md`](./d-per-model.md) section 8 (deviation 2):

- inline `$expression` conditions are refused (2000, as the default server; OpenFGA's flag turns them on);
- `bytes`, `type()`, `dyn()`, type names as values, message construction and optional syntax are refused at model write (2056);
- the cost limit is approximate (section 13.2, item 5);
- a stored context the current model no longer accepts makes the tuple ignored in ListObjects and ListUsers too (OpenFGA's lists fail with 2000, P29);
- the RLS helpers take no request context and deny whenever an answer depends on an evaluation error;
- timestamps are microseconds (sub-microsecond digits are dropped) within years 1 to 9999; double overflow and division by zero are errors (CEL gives infinities and NaN); `matches` uses Postgres regular expressions; IPv6 zones are refused;
- in values of type `any` and in mixed literals, ints are doubles (section 13.2, item 2);
- dyn ordering compares numbers of different kinds (`a < 5` with `a` any given 3 is true, as the server, P41).

### 13.4 Tests

`test/spec/d/37_fga_conditions_model` (51 assertions), `38_fga_cel` (142), `39_fga_conditions_eval` (64), `90_usage_conditions` (29), four more in `90_usage_rls`, and eight rows in `35_error_hints` for the eight new raise sites (the three 0A000 rows are gone: 63 sites before, 68 now). Red before the implementation: 6 of 51, 0 of 142 and 4 of 64 passed (the ones that pass hold without conditions). The abac oracle: 302 of 302 and 271 of 271. Mutants: [`d-per-model.md`](./d-per-model.md) section 9.

### 13.5 Performance

**The unconditioned fast path.** `bench/run.sh --scale large --only share_list_objects,share_select_page,parents_select_page,nest_check` (local Postgres 16.4, Postgres.app, Apple silicon, 4 clients, 10 s per workload; the large default shape of [`bench/baselines/D.md`](../bench/baselines/D.md), run locally rather than in its Docker setup), twice before (`--tag cond-before`, the extension at commit `5c0951e`) and twice after (`--tag cond-after`), strictly one at a time and never with tests running, on 2026-10-30. Also running: the idle Docker stacks (Supabase, freereps, an unrelated container), a browser; load average 3 to 7 on 10 cores. `--only` runs write no baseline JSON.

| workload | before p50 / p95 (ms), run 1; run 2 | after p50 / p95 (ms), run 1; run 2 |
| --- | --- | --- |
| `share_list_objects` (ListObjects for RLS, `fga_list_object_ids_current`) | 0.28 / 0.39; 0.28 / 0.43 | 0.28 / 0.38; 0.28 / 0.38 |
| `share_select_page` (RLS page) | 0.82 / 1.05; 0.84 / 1.08 | 0.81 / 1.24; 0.81 / 1.01 |
| `parents_select_page` (RLS page over 1M documents) | 0.93 / 10.51; 0.96 / 11.64 | 0.85 / 8.18; 0.89 / 9.23 |
| `nest_check` (Check, `fga_check_current`) | 0.38 / 0.58; 0.37 / 0.52 | 0.38 / 0.48; 0.38 / 0.50 |

Within noise: the p50s match to 0.01 ms except `parents_select_page`, whose p95 swings by 10 to 20 % between runs of the same build. The unconditioned path adds one equality to each edge join and reads `conditional` with the flags it already read.

**Conditioned edges** (throwaway measurement, same machine, a scratch database, 1,000 tuples per user on one relation, warm): one evaluation of `x < 100` costs about 9 µs through `_fga_cond_eval` (2 µs of it in the interpreter, the rest the condition lookup, the merge and the conversions); a timestamp comparison about 18 µs and `in_cidr` 16 µs (the RFC 3339 and address parsing). ListObjects over 1,000 unconditioned tuples took 2.0 ms; over 1,000 tuples sharing one condition and context 2.8 ms (one evaluation); over 1,000 tuples with 1,000 distinct stored contexts 21.8 ms (about 20 µs each). Check took 68 µs per call unconditioned, 74 µs through a true conditioned edge, and about 160 to 180 µs when false on a conditional relation, the error walk of rule 7 included. Phase 5 is where to cut these.
