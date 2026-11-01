# Design D: OpenFGA conditions (CEL) in PL/pgSQL

> Status: implemented in phase 4 of session 5 ([`plan.md`](../plan.md), "Phase 4", steps 3 to 6). The code is in [`pg_permissions--0.0.1.sql`](../../pg_permissions--0.0.1.sql). To use conditions, read the [user documentation](../../docs/README.md) and [`conditions.md`](../../docs/conditions.md). This page is the design record.
>
> The team wrote this page as the design (steps 1 and 2), and then reviewed it. The team decided the open questions of section 11 ([`decision.md`](../decision.md), "Decisions for conditions (session 5)"). Section 13 says where the implementation differs from the design. The abac oracle passes in both runs (302 of 302 stored assertions, 271 of 271 contextual assertions, and 9 cases skipped as `inline-expression`).
>
> The full suite has 56 spec files and 3,638 assertions. It runs on PG 16, 17 and 18. This page is the companion to [`d-per-model.md`](./d-per-model.md). Sections 2, 4, 7 and 8 of that page describe the result.

The sources are:

- openfga/openfga at `44054f5` (tag v1.22.1, the commit of the vendored suites, with cel-go v0.31.0 in `go.mod:19`).
- openfga/api at `f153694bfc20` (the commit that its `go.mod` pins).
- The docs page [openfga.dev/docs/modeling/conditions](https://openfga.dev/docs/modeling/conditions) (read 2026-10-29).
- Answers from the pinned server image (`openfga/openfga:v1.22.1@sha256:b852071...`, memory datastore, default flags). [`probe.sh`](../../test/fga_abac/probe.sh) collected them.

A path such as `condition.go:218` is in openfga/openfga, unless the text says otherwise.

## 1. Oracle and inventory

### 1.1 The oracle

[`test/fga_abac/`](../../test/fga_abac/) vendors `assets/tests/abac_tests.yaml` at the same SHA as the consolidated suite. It uses the same pinned CLI image, the same two runs and the same TAP names. It also uses the same skip file format (`vendor.sh`, `generate.py`, `skip.tsv`, `cases.json`, `upstream/`). The upstream harness runs this file with the same code as the consolidated file (`tests/check/check.go:63-67`), with the `inline_expressions` flag on (`tests/check/check_test.go:99`).

| | Cases | Assertions | Run | Skipped |
| --- | --- | --- | --- | --- |
| upstream | 33 (3 multi-stage) | 331 (152 Check, 82 ListObjects, 97 ListUsers) | | |
| stored | 33 | 331 | 24 cases, 302 assertions | 9 cases, 29 assertions: `inline-expression` |
| contextual | 30 | 300 | 21 cases, 271 assertions | the same 9 |

`generate.py --suite` writes the specs as `test/spec/d/63_fga_abac_*` and `64_fga_abac_ctx_*` (without `--suite`, it writes to the git-ignored `test/fga_abac/spec/`). They call `fga_check`, `fga_list_objects` and `fga_list_users` with the `context` argument, through helpers in `test/fixtures/fga_abac.sql`. The specs were red before steps 3 to 6 of phase 4 (0 of 302 and 0 of 271, because every model write raised 0A000). They are green after (302 and 271).

Two details of the vendor step:

- The YAML has an out-of-range double (`1.797...e+309`, case `handles_floats`). Ruby reads it as Infinity. So `yaml2json.rb` keeps unquoted floats as their source text (jsonb holds it exactly, and `vendor.sh` refuses a jq that rounds it).
- The upstream harness (sigs.k8s.io/yaml) turns that unquoted scalar into a string. The server rejects the number form at request parse time (probe P12). Both give 2000, which is what the case expects.

The 8 `conditions` skips in [`test/fga_lang/skip.tsv`](../../test/fga_lang/skip.tsv) join the oracle of this phase (section 10).

### 1.2 CEL features: what the cases reach, what only the docs list

The named-condition cases (24) define 14 conditions (13 names, and one is redefined in a later stage). The 9 inline-expression cases add 8 expressions. This table lists everything that they use:

| Feature | Reached by the cases | Docs or source only |
| --- | --- | --- |
| Parameter types | `int` (14 cases), `timestamp` (7), `string` (2), `bool` (1), `double` (1), `ipaddress` (1). Inline: `string`, `int`, `timestamp`, `ipaddress`. | `uint`, `duration`, `any`, `map<T>`, `list<T>`. `bytes` is in the table of the docs, but the server rejects it (P1). |
| Literals | int (`100`, `50`, `10`, `200`), double (`0.0`), string with `"..."` and `'...'`, `true` | uint (`5u`), hex, exponent doubles, raw and triple-quoted strings, bytes, `null`, list `[...]`, map `{k: v}` |
| Operators | `<`, `>`, `==`, `\|\|`. A bare bool parameter as the whole expression (`ok`). | `&&`, `!`, `!=`, `<=`, `>=`, `+ - * / %`, unary `-`, `? :`, `in`, `[ ]`, field select on maps |
| Functions | `timestamp(string)` on a literal. `ipaddress.in_cidr(string)`. | `ipaddress(string)`. The standard library of CEL (the docs link to the CEL specification and show `current_time < grant_time + grant_duration`): `size`, `contains`, `startsWith`, `endsWith`, `matches`, `int/uint/double/string/bool/duration/timestamp()`, the accessors of timestamp and duration (`getHours()` and more), `has()`, and the macros `all`, `exists`, `exists_one`, `map` and `filter`. Also `type`, `dyn` and `bytes`. |
| Timestamps and durations | `ts < timestamp("2023-10-11T10:00:00.000Z")`. RFC 3339 context values with milliseconds. | timestamp ± duration, timestamp − timestamp, duration arithmetic, time zones in accessors |
| Context | The request context on every kind of assertion. The tuple context (`cidr` stored, `user_ip` from the request). Contextual tuples that have a `condition` (the contextual run, 21 cases). | a request key that overrides a tuple key (P5), map and list values |

So the cases need a small language (5 operators, 2 functions, 6 types). The rest is in scope because OpenFGA documents the types and points at CEL. Section 4 says which part D implements.

### 1.3 Error expectations in the cases

| Code | When | Cases |
| --- | --- | --- |
| 2000 | a parameter that the condition declares is in neither context (Check, ListObjects, ListUsers) | 17 named cases, 60 assertions. This includes `x < 100 \|\| y < 50` with only `x` given (`direct_relations_with_condition`). An absent parameter is an error, even when the `\|\|` of CEL would already be true (`eval.go:131-138`). |
| 2000 | a double parameter out of float64 range, as a string or a number | `handles_floats` (10) |
| 2000 | a conditioned edge errors and no branch is true | `relation_through_ttu_with_condition` (`s == "foo"` false, `x` absent on the other parent) |
| 2000 | ListUsers: any conditioned edge on the walk errors, even when the user is reachable through a true edge | `relation_through_ttu_with_condition` (8 LU assertions) |
| 2027 | Check: a contextual tuple whose condition the relation does not accept for that facet (`user with isOk`, where only `user:* with isOk` is accepted) | `condition_bound_to_correct_type_restriction_facet` s1 (2) |
| 2000 | ListObjects and ListUsers: the same contextual tuple | same case (2) |
| none: ignored | a stored tuple whose condition the current model no longer accepts for its facet (no error, the edge is absent) | `prior_conditions_ignored` s1, `wildcard_with_condition` s1 |
| none: true | a malformed timestamp in the request on one path, and a true path without condition elsewhere | `ttu_mix_with_userset_member_condition_mixed_parents` (`"2023-10-11T11:00.000Z"`) |

No case writes a model or a tuple that the server must reject. Those cases come from `test/fga_lang` (2056 undefined condition) and from the probes (section 2).

### 1.4 OpenFGA's parameter types and functions

| Type | Value accepted in a context (source) |
| --- | --- |
| `any` | anything, as is (`converters.go:74-76`) |
| `bool`, `string` | exactly that JSON type (`converters.go:10-17`) |
| `int`, `uint`, `double` | A JSON number or a base-10 numeric string, parsed as a 64-bit big float (`converters.go:19-72`). `int` and `uint` must be integral, and the server clamps them silently to int64 (`1e30` is 9223372036854775807, P10). `uint` rejects negatives. `double` rejects a value that does not round-trip exactly, so the string `"0.1"` is an error and the number `0.1` is not (P32). |
| `duration` | A Go duration string, `"1h30m"`, `"300ms"` (`converters.go:78-90`, `time.ParseDuration`). `"1d"` is an error. |
| `timestamp` | RFC 3339, `time.Parse(time.RFC3339)` (`converters.go:92-104`). Fractional seconds and offsets work. A lower-case `t` or `z`, and a value without seconds, do not work. |
| `ipaddress` | `netip.ParseAddr`, with IPv4-mapped IPv6 unmapped (`ipaddress.go:61-69`) |
| `map<T>`, `list<T>` | a JSON object (string keys) or array, with each value converted as T (`generic.go:11-61`) |

The type list is `primitives.go:11-62` plus `ipaddress.go:41-52`, and the proto enum (openfga/api `authzmodel.proto:239-252`). It has no `bytes`, so the `bytes` row of the docs table describes nothing that the server accepts. The CEL environment is the default of cel-go (standard library, no extensions such as `strings` or `math`), plus `ipaddress(string)` and `IPAddress.in_cidr(string)` (`condition.go:28-42`, `ipaddress.go:16-52`). The output must be `bool` (`condition.go:138-143`).

The limits are:

- Condition names: `^[^:#@\s]{1,50}$`.
- At most 25 parameters, with names of the same pattern.
- Expressions of up to 512 bytes (openfga/api `authzmodel.proto:202-227`).
- The condition name of a tuple: `^[^\s]{2,256}$` (`openfga.proto:88-100`).
- The context of a tuple: up to 32 KB (docs, "Limitations").
- Evaluation cost: at most 100 (`pkg/server/config/config.go:67`, docs).

## 2. What the server says

`test/fga_abac/probe.sh` runs against the pinned image. Each answer is a behavior that an in-house spec pins in step 3 or 4.

| # | Request | OpenFGA v1.22.1 |
| --- | --- | --- |
| P1 | a model with a `bytes` parameter (JSON, because the DSL has no `bytes`) | 2056 unknown condition parameter type |
| P2 | a condition key that differs from its `name` | 2056 |
| P3 | a `map` parameter without a generic type | 2056 |
| P4 | A CEL syntax error. An undeclared identifier. A result that is not bool. `x < "a"`. `x < 1.5` with `x: int`. | 2056 each (`failed to compile expression on condition 'cx' - ...`). CEL is type-checked at model write and has no implicit int/double conversion. |
| P5 | tuple context `{x: 10}`, request `{x: 200}`, `x < 100` | true: **the context of the tuple wins**. In `eval.go:112-125`, the request goes first and the tuple goes after it. In `condition.go:218-223`, the last map wins. The docs say: "the context values written in the relationship tuple take precedence". |
| P6 | Write: an undefined condition. A context key that is not a parameter. A context value of the wrong type. No condition where only `with cx` is accepted. A condition on a restriction without a condition. | 2000 each, `Invalid tuple '...'. Reason: ...` (`validation.go:213-311`, `InvalidConditionalTupleError` to `validation_error`, `pkg/server/errors/errors.go:158-162`) |
| P7 | Write the same key again with another context | 2017. With `on_duplicate: ignore`, HTTP 409 `Aborted` "attempted to write a tuple which already exists with a different condition". |
| P8 | Read | the tuple key includes `condition: {name, context}` |
| P9 | Delete without the name of the condition | deletes (the key is user, relation, object) |
| P10 | `int` given `"10"`, `10.0`, `-5`, `"1e1"`. Then `1e30`. | true. `1e30` is false (clamped). |
| P11 | `int` given `10.5`, `true`, `"0x10"`, `null` | 2000 each |
| P12 | `double` given `1.8e+309` as a JSON number | 2000 at request parse time (`invalid google.protobuf.Value`) |
| P13 | a request context with keys that no condition uses | ignored |
| P14 | Check `user:jon viewer doc:2`, where `doc:2#viewer@group:x#member` has a condition and no context, and jon is not in group:x | **2000**: an edge with an error, off the path of the user, still fails a Check that finds nothing true |
| P15 | ListObjects for `user:ann`, who has no tuples (the edge of doc:2 exists) | `[]`: the edge is not on the walk |
| P16 | ListObjects for `group:x#member`. ListUsers on `doc:2`. | 2000, 2000 |
| P17 | `x < 100 \|\| 10 / y == 1` and `10 / y == 1 \|\| x < 100`, `x = 10, y = 0` | true, true: the `\|\|` of CEL absorbs an error from either side |
| P18 | the same with `x = 200` | 2000 (division by zero) |
| P19 | `l.exists(e, e == "zzz")` over 3 strings. Then over 50. | true. 2000 "actual cost limit exceeded". |
| P20 | `list<string>` with a number element | 2000 |
| P21 | `t + d > timestamp(...)`, `d = "1h"`, `"1h30m"`. Offsets `+02:00`. | true |
| P22 | `d = "1d"`. `t` without seconds. Lower-case `t` or `z`. | 2000 each |
| P23 | `m.a` on `map<int>` with the key absent | 2000 "no such key" |
| P24 | `a == 1` with `a: any` given `1`. Then given `"1"`. | true. false (no error, because CEL has heterogeneous equality). |
| P25 | Check, a contextual tuple with an undefined condition or a context of the wrong type | 2027 (Check wraps every contextual tuple error, `pkg/server/commands/errors.go:100-104`) |
| P26 | ListObjects, the same contextual tuple | 2000 |
| P27 | contextual tuple context `{x: 1}`, request `{x: 500}` | true (the tuple wins here too) |
| P28 | stored context `{x: 10}`, then a model where the condition takes `x: string`: Check | false (the check ignores the tuple: `FilterInvalidTuples`, `validation.go:60-83, 379-384`) |
| P29 | the same data: ListObjects | **2000** (its iterator evaluates in place of a filter) |
| P30 | stored context key `x`, then a model where the condition has only `y`: Check | false (ignored) |
| P31 | `uint` given `-1`. Then given `1e19`. | 2000. true (clamped to int64 max). |
| P32 | `double` given the number `0.1` and the string `"1.5"`. Then the string `"0.1"` and `"1e400"`. | true, true. 2000, 2000 (`number cannot be represented as a float64`). |
| P33 | model: a condition name with `:`. An expression over 512 bytes. 26 parameters. | 2000 each (`invalid Condition.Name`, `...Expression ... at most 512 bytes`, `...Parameters ... no more than 25 pair(s)`): the validation of the request |
| P34 | `(x > 1 ? 1 : "a") == 1` | 2056 (`found no matching overload for '_?_:_' applied to '(bool, int, string)'`) |
| P35 | `a` alone, `a: any` | 2056 (`expected a bool condition expression output, but got 'google.protobuf.Any'`) |
| P36 | `size([1, "a"]) == x` | accepted: a list literal of mixed types is a list of dyn |
| P37 | `dyn(x) < 1.5` | accepted (D refuses `dyn()`, decision 10) |
| P38 | `l.exists(e, e == "zzz")` over 10, 20, 25, 30, 40 strings. A 35-term `\|\|` chain of `x == n`, all false. | false, then 2000 from 20 on (`actual cost limit exceeded`). false. |
| P39 | a condition with no parameters (`true`) and an empty context. Then context `{z: 1}`. | true. 2000 (`no parameters defined for the condition`). |
| P40 | `t.getHours("Europe/Paris") == 12 && t.getHours("+02:00") == 12 && t.getDayOfWeek() == 0 && t.getMonth() == 6`, `t = 2024-07-07T10:00:00Z` | true (`+02:00` is two hours east) |
| P41 | `a < 5`, `a: any`, given 3 | true (a double compares with an int at run time) |
| P42 | Read of a tuple that a Write stored with a condition and no context | `condition: {name, context: {}}` |
| P43 | Write: a tuple condition with the name `c` (one character) | 2000 (`RelationshipCondition.Name` must match `^[^\s]{2,256}$`) |
| P44 | Write the same key with the same condition, `on_duplicate: ignore` | written (skipped) |

## 3. Semantics D adopts

1. **Context merge.** The `context` of the request goes first, and the condition context of the tuple goes on top. The tuple wins on a shared key (P5, P27). This applies to stored and contextual tuples.
2. **Types at write.** The model write parses and type-checks the conditions of the model. These cases give 2056 (P1 to P4, fga_lang). A syntax error.

   An unknown identifier. A type error. A result that is not bool. An unknown parameter type. A generic type that has no argument.

   A key that differs from the name. A restriction that names an undefined condition. `fga_write` checks the condition name of a tuple, its facet, its context keys and its value types (2000, P6). The same checks apply to contextual tuples (Check 2027, lists 2000, P25, P26, the `condition_bound` case).
3. **Absent parameters.** After the merge, a declared parameter with no value makes the edge an **error** (2000), whatever the expression would give (`direct_relations_with_condition`). The check happens before the evaluation, so the evaluator never sees unknowns.
4. **Conversions** follow `converters.go` exactly, with its quirks (section 1.4, P10, P11, P32, P31). A request value that fails conversion makes the edge an error. D reads JSON numbers through float8, as OpenFGA reads them through float64 (jsonb would otherwise keep digits that OpenFGA drops).
5. **The functions ignore stored tuples that the model no longer accepts.** This is not an error. There are two cases. The first case is a condition that the restriction does not accept for the facet of the tuple (cases).

   The second case is a stored context with a key that is not a parameter, or a value that no longer converts (P28, P30). The Check of OpenFGA ignores the second case too. The ListObjects of OpenFGA raises 2000 on it (P29). D ignores it in every API, so the lists stay consistent with Check (deviation, open question 4).
6. **CEL inside an expression.** `&&` and `||` are commutative and absorb errors. `true || error` is true, and `false && error` is false. In the other cases the result is the error (P17, P18).

   `? :` evaluates only the chosen branch. Everything else propagates the first error. Values are never unknown (rule 3).
7. **Errors across the graph**, as in OpenFGA, for each API:
   - **Check**: true if a path of true edges exists. Otherwise the result is 2000 if the top-down search of OpenFGA would have evaluated an edge with an error. This edge is in the backward closure from the object, even off the path of the user (P14). The closure has the userset and tupleset tuples of the nodes that the search reaches, and the direct tuples of the user.

     In the other cases the result is false. An error loses to a branch that decides (`relation_through_ttu...`, `mixed_parents`). In an intersection, a false branch decides. In a difference, a false base or a true subtract decides. A depth error (2002) has priority over a condition error (`pkg/server/commands/errors.go:111-117`).
   - **ListObjects**: 2000 if any edge that the forward walk takes has an error (P15, P16, cases). Otherwise the objects.
   - **ListUsers**: 2000 if any edge that the backward walk takes has an error, even when every user is also reachable through true edges (`relation_through_ttu...`). The walk does not evaluate plain-user tuples of a type that the filters exclude.
   - **Current-subject functions** (`fga_check_current`, `fga_list_objects_current`, `fga_list_object_ids_current`): They take no request context, like contextual tuples (section 4 of [`d-per-model.md`](./d-per-model.md)). They never fail on a condition: an answer that depends on an evaluation error is a deny (deviation, decision 4). In the positive walks, the walk does not take an edge with an error. Under a subtract, the walk takes it, so it removes the object. `_fga_rec` reports it (result 4), which counts as false. A condition that is true from the stored context of the tuple alone counts.

## 4. Language subset, tokens, AST

**Implemented** (the cases plus what the docs list, in three tiers, each with in-house specs):

- Tier 1, the cases. Parameters of the types `int`, `double`, `string`, `bool`, `timestamp` and `ipaddress`. Int, double, string (both quotes) and bool literals. `<`, `>`, `==`, `||`. `timestamp(string)`. `x.in_cidr(string)`.
- Tier 2, the documented types and the standard operators of CEL over them:
  - Types: `uint`, `duration`, `any`, `map<T>`, `list<T>`.
  - Literals: `null`, uint, hex and exponent literals, raw and triple-quoted strings, list and map literals (string, int, uint and bool keys).
  - Operators: `&&`, `!`, `!=`, `<=`, `>=`, `+ - * / %`, unary `-`, `? :`, `in`, `[ ]`, `.field` on maps, `has()`. Overflow of int64 and uint64, and division by zero, are errors.
  - String functions: `size`, `contains`, `startsWith`, `endsWith`, `matches`.
  - Conversions: `int`, `uint`, `double`, `string`, `bool`, `timestamp`, `duration`.
  - Time: timestamp ± duration, timestamp − timestamp, duration ± duration, and comparisons. Timestamp accessors with an optional time zone, and duration accessors.
  - Macros: `all`, `exists`, `exists_one`, `map`, `filter`.
  - `ipaddress(string)`.
- Tier 3, **rejected at model write** with 2056 and a HINT that names the feature. The features are `bytes` (literals and `bytes()`), `type()`, `dyn()`, type names used as values, message construction and the optional syntax of CEL. OpenFGA accepts these (except a `bytes` parameter). No case or doc example uses them. This is a deviation, listed in section 8 of [`d-per-model.md`](./d-per-model.md).

**Tokens** (`_fga_cel_tokens(expr) returns table(pos int, kind "char", text text)`, one loop that uses regular expressions): identifier, int, uint, double, string (the value, with escapes decoded), and the punctuators `|| && ! == != < <= > >= + - * / % ? : . , [ ] ( ) { }`. The keywords are `true false null in`. The reserved words of CEL (`as break const continue else for function if import let loop package namespace return var void while`) are a syntax error, as in cel-go.

**Grammar** (the grammar of CEL, parsed by precedence):

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

**AST** (jsonb, one object for each node. Every node carries its static type `t` from the checker):

| Node | Shape |
| --- | --- |
| literal | `{"k":"lit","t":"int","v":100}` (timestamps as RFC 3339 text, durations as integer nanoseconds, uint and int as numbers kept exactly) |
| parameter | `{"k":"id","t":"timestamp","n":"ts"}` |
| call | `{"k":"call","t":"bool","f":"_<_timestamp","a":[...]}`. `f` is the **overload** that the checker resolved (`_<_int`, `_+_timestamp_duration`, `in_cidr`, `size_string` and more), so evaluation dispatches on one text compare, with no type inspection. |
| logic | `{"k":"or","a":[x,y]}`, `{"k":"and",...}`, `{"k":"cond","a":[c,x,y]}` (kept apart from calls, because their evaluation rules differ, section 3 rule 6) |
| select, index | `{"k":"sel","f":"a","a":[m]}`, `{"k":"has","f":"a","a":[m]}`, `{"k":"idx","a":[x,i]}` |
| list, map | `{"k":"list","a":[...]}`, `{"k":"map","a":[k1,v1,k2,v2,...]}` |
| comprehension | `{"k":"comp","m":"exists","v":"e","a":[range, body]}` |

Compilation at model write has these steps:

1. Tokens.
2. Parser.
3. Macro expansion (`has`, comprehensions).
4. Type checker (parameter types, overload resolution, bool result).
5. Constant evaluation of calls on literals that cannot fail. `timestamp("2023-...")` becomes a timestamp literal. The compiler leaves an invalid literal for the evaluation, because cel-go accepts the model and gives the error at evaluation.
6. jsonb.

A type `dyn` comes from `any`, or from a list or map of `any`. It makes the checker emit a generic overload (`_==_dyn`) that dispatches on the kind at run time.

## 5. Storage of the compiled form

Check does not parse an expression at Check time, in any option. The options are:

| | S1: jsonb AST in a table | S2: AST as rows | S3: generated SQL for each condition |
| --- | --- | --- | --- |
| Shape | `fga_conditions(model_id, name, expression, parameters jsonb, ast jsonb)` | `fga_condition_nodes(model_id, condition, node, op, args int[], literal, type)`, like `fga_rewrite_nodes` | at model write, `create function permissions._fga_cond_<model>_<n>(ctx jsonb) returns boolean` (or a SQL text column that `EXECUTE` runs) |
| Evaluation | the walk joins `fga_conditions` and passes `ast` to the interpreter | the interpreter loads the rows (or arrays) for each call | a function call. The plan is cached. |
| Measured (section 8) | 1.8-3.0 µs for each evaluation | 3.5-4.5 µs with the arrays loaded in one row. A query for each node would be slower. | 0.1-0.6 µs (SQL or PL/pgSQL function). `EXECUTE` 3.4 µs. |
| Error semantics (section 3) | in the interpreter | in the interpreter | every node that can fail needs a representation of value-or-error in SQL (`CASE` for each operand), or an exception block for each call (a subtransaction) |
| Runtime DDL | none | none | one function for each condition for each model version, created by a SECURITY DEFINER function from text that the user supplies (section 9) |

**Recommendation: S1.** It is the fastest of the forms that keep the evaluator data-driven. It keeps model writes free of DDL. The conditions of a model stay data (dumped and restored with the other `fga_*` rows).

The tree is small (an expression is at most 512 bytes), so the jsonb lookups for each node are cheap. S3 is the fallback if phase 5 shows that condition evaluation dominates a real workload. It applies only to expressions in the error-free fragment (comparisons and logic over converted parameters), where the semantics of SQL and CEL coincide.

## 6. Evaluator

| | E1: interpreter that walks the tree | E2: compile to a SQL expression | E3: interpreter with a memo for each request |
| --- | --- | --- | --- |
| How | `_fga_cel_eval(ast jsonb, ctx jsonb) returns fga_cel_value`, recursive PL/pgSQL, one `case` on the node kind and overload | S3 above, spliced into the walks or called for each row | E1, called one time for each distinct (condition, tuple context) in each walk step, in place of one time for each tuple |
| CEL semantics | exact: errors are values, `&&` and `\|\|` absorb them, comprehension cost counted | approximate unless every operand is wrapped | as E1 |
| Cost | 2-3 µs for each evaluation for the case expressions (section 8) | 0.1-0.3 µs | E1 × distinct contexts. In the cases and the common shapes (expiry, IP, "condition with only request parameters"), the tuple contexts are few or identical. So a step evaluates a condition a few times, for any number of tuples that match. |

**Recommendation: E1 with the dedupe of E3 in the set-based steps.** The correctness is in one interpreter, which every walk and evaluator calls. The dedupe is a SQL `distinct` over (condition, context) in the step. There is no state across calls.

**Values.** A composite `permissions.fga_cel_value(k "char", b boolean, i bigint, u numeric, d float8, s text, ts timestamptz, du bigint, ip inet, j jsonb, et text)` has one field for each kind. `ts` is microseconds, `du` is nanoseconds, and `ip` is the core `inet`. `j` is the payload of a list or map, and `et` is its element type.

Kind `E` is an error value, with the message in `s`. A composite cannot contain itself, so lists and maps use jsonb payloads. Their elements have a canonical form for each static element type.

The hot path avoids exceptions. Int arithmetic checks bounds before it computes. A regex tests timestamp and duration input before the cast. The one exception block that remains is the compile of the regex in `matches` (RE2 against ARE).

**Parameters.** `_fga_cel_params(params jsonb, ctx jsonb)` merges the contexts, checks presence (rule 3) and converts each value by its declared type (rule 4). It returns the typed activation as jsonb, or an error value. It runs one time for each (condition, merged context).

The two sides fail in different ways (rule 5). A stored context with a key that is not a parameter, or a value that does not convert, makes the tuple ignored (false). A request value that does not convert, or an absent parameter, makes an error.

**Cost limit.** The cost model of cel-go (each call and each comprehension step costs, and strings cost by size) is approximate here. The approximation is a counter of evaluated nodes plus one for each comprehension iteration, with a limit of 100. It catches runaway comprehensions. The exact threshold does not match cel-go (P19 passes, but a list of 30 elements can differ). This is a deviation (open question 5).

**Precision.** Timestamps are microseconds (CEL: nanoseconds, and the function truncates sub-microsecond digits), within 0001-01-01 to 9999-12-31. A double operation that overflows gives an error (Postgres raises an error, and CEL gives ±Inf). `matches` uses Postgres regular expressions.

The RE2 syntax mostly agrees, but lookarounds do not exist in RE2 and do exist in Postgres. The function rejects IPv6 zones (`fe80::1%eth0`), because `inet` has none. These deviations are listed with the others.

## 7. Tables, API, walks

### 7.1 Tables

- `fga_conditions (model_id, name, expression text, parameters jsonb, ast jsonb)`, with the primary key `(model_id, name)`. `fga_write_authorization_model` writes it.
- `fga_type_restrictions` gets `condition text collate "C" not null default ''` in its primary key (`[user, user with c]` is two rows).
- `fga_edges` (`d` and `t`) and `fga_walk_steps` get `condition` (`''` for none). For `d`, it is the condition of the restriction. For `t`, it is the condition of the tupleset restriction. There is one edge for each accepted condition, so a tuple matches exactly one edge (`e.condition = tu.condition_name`). A tuple whose condition the model does not accept for its facet matches no edge. This gives rule 5 at no cost, in the same way that D already ignores tuples of a type that the model dropped.
- `fga_relations` gets `conditional boolean`. It is true when a conditioned edge is in the positive closure of the relation (or of its subtract). False means the code path of before, unchanged.
- `fga_tuples` gets `condition_name text collate "C" not null default ''` and `condition_context jsonb` (null when there is none). They are not in the key (P7, P9). The composite `fga_tuple` (contextual tuples) gets the same two fields at the end.

### 7.2 API

`fga_check`, `fga_list_objects` and `fga_list_users` get a last parameter `context jsonb default null`. This is the request `context` of OpenFGA. It is last, so calls with positional arguments still work. `fga_write` accepts `condition: {name, context}` on a tuple key.

`fga_read` returns it in `key` (P8). Deletes ignore it (P9). A write of a key that exists with a different condition is 2017, also with `on_duplicate: ignore`. The 409 `Aborted` of OpenFGA has no numeric code (open question 6). The current-subject functions take no context (rule 7).

### 7.3 Evaluation call

In a walk, each tuple read gets this test, for a row with a condition only:

```sql
tu.condition_name = ''
or permissions._fga_cond(c.ast, c.parameters, p_req, tu.condition_context, p_mode, <tuple for the message>)
```

`c` joins from `fga_conditions` on `(p_m, tu.condition_name)`. `p_mode` is one of three values. `r` raises 2000 on an error. `d` makes an error false. `t` returns null for an error, because the unknown of SQL is the third value. A row without a condition never calls it.

A walk whose target relation is not `conditional` runs the statement of before. It has one more equality on the edge join and no join to `fga_conditions`. The step functions branch on the flag in PL/pgSQL, so each branch keeps its own cached plan. This is the fast path for data without conditions.

### 7.4 Each evaluator

| Evaluator | Change |
| --- | --- |
| `_fga_fstep`, `_fga_bstep` (the bidirectional steps of Check) | The edge join adds `e.condition = tu.condition_name`. Hits with a condition go through `_fga_cond` in mode `d`, deduplicated for each (condition, context) in the step. |
| `_fga_bidi` | It runs as before, with an error counted as false (mode `d`). True: done. False on a `conditional` relation in mode `t`: one more walk. This walk is the backward closure from the object (`_fga_bstep` without subjects, plus the direct tuples of the user) in mode `r`. It raises 2000 if the top-down search of OpenFGA would have met an edge with an error (rule 7, P14). Otherwise it returns false. It returns a new code 4 for that case when `_fga_rec` calls it. |
| `_fga_rec`, `_fga_rec_node` | Top-down like OpenFGA, so conditions are evaluated where OpenFGA evaluates them: the direct tuple and wildcard of the user, each userset tuple, each tupleset tuple. A false condition skips the tuple. An error sets a new result code 4 (condition error) next to 3 (depth). Union, intersection and difference combine 4 like 3, and 3 outranks 4 when both occur. |
| `_fga_forward`, `_fga_forward_ids` (ListObjects) | The step probes add the condition match. Hits with a condition run in mode `r` (`fga_list_objects`) or `d` (the `_current` RLS functions). |
| `_fga_backward`, `_fga_list_users` | The same, in mode `r`. The walk evaluates hits of plain users only for types that the filters name. |
| set-based `but not` (ListObjects and ListUsers) | Both walks use the mode of the request. `diff_recheck` and the per-candidate path call `_fga_rec`, whose code 4 raises 2000 in the lists. |
| `_fga_check_impl` | `_fga_rec` code 4 or `_fga_bidi` code 4 raises 2000 with the message of the first error. Mode `d` from `fga_check_current` returns false. |
| `_fga_ctx` (contextual tuples) | It validates condition, facet and context (Check 2027, lists 2000). The composite carries the condition. |

Depth does not change: a condition is a filter on an edge, not a level.

## 8. Performance

This is a throwaway measurement (tag `cond-eval-micro`). [`d-conditions/measure.sql`](./d-conditions/measure.sql) is the test, and `d-conditions/measure.sh` runs it on a throwaway cluster. The conditions were PostgreSQL 16.4 (Postgres.app), Apple silicon, 2026-10-29. Nothing else ran, except the idle Docker stacks (Supabase, freereps, an openfga container). The test uses 100,000 rows, one evaluation for each row, best of 5:

| Expression | none (loop) | SQL inline | SQL function | PL/pgSQL function | EXECUTE | interpreter, jsonb AST (S1/E1) | interpreter, array AST (S2) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `x < 100` | 1.8 ms | 11.0 | 10.8 | 23.1 | 342 | 184 | 352 |
| `ts < timestamp("...")` | | 19.2 | 58.6 | 30.3 | | 256 | 451 |
| `x < 100 \|\| y < 50` | | | 11.1 | 23.2 | | 296 | 414 |

So an interpreted evaluation costs 2-3 µs. The prototype interpreter is smaller than the real one, which also converts parameters fully and tracks cost, so expect 3-6 µs. A generated function costs 0.1-0.6 µs. `EXECUTE` is no faster than interpretation. Arrays lose to jsonb in PL/pgSQL, because each recursive call copies them.

These are expectations. The team measures them in phase 4 step 5 and phase 5, with the same benchmark and tagged runs, one at a time:

- **Data and models without conditions**: within noise of opt2 for Check and ListObjects. The edge join has one more equality, there is no condition call, and `conditional = false` keeps the plans of before.
- **Edges with conditions**: one evaluation for each distinct (condition, tuple context) in each walk step, plus one jsonb merge. A Check through a few conditioned edges adds tens of µs to a check of about 0.3 ms. A wide ListObjects whose 10,000 tuples share one condition and no stored context adds one evaluation for each step, not 10,000. With 10,000 distinct stored contexts (expiry for each tuple), it adds about 30-60 ms.
- **False Check on a conditional relation** (API only, not RLS): the extra backward closure walk of rule 7. It costs about the same as the backward half of the bidi of before.
- **Model write**: the model write tokenizes, parses and checks a 512-byte expression in PL/pgSQL. This takes a few ms for each condition, one time.

Status: [section 13.5](#135-performance) has the measurements of phase 4 and phase 5.

## 9. pg_tle and runtime DDL

The design adds tables, PL/pgSQL functions and one composite type, and it uses only core types (`inet`, `timestamptz`, `jsonb`). It is plain SQL and PL/pgSQL, and `pgtle.install_extension` can install it like the rest (spec `03_tle_install`).

S3 would mean `CREATE FUNCTION` at runtime from `fga_write_authorization_model`. pg_tle does not forbid it (an extension function can run DDL with the rights of its owner). But S3 has these problems:

- The text of the model writer becomes function source, and the function runs as the SECURITY DEFINER owner. A bug in the quotes of the compiler is then SQL injection with the privileges of the extension owner. A grant to "write a model" becomes a grant to "run code as the owner".
- Those functions are not extension members. `pg_dump` dumps them as ordinary objects next to the extension. `DROP EXTENSION` does not remove them (or fails on the dependency). `ALTER EXTENSION ... ADD` must adopt each one, and that command needs ownership.
- One function for each condition for each model version accumulates (models do not change). `fga_delete_store` would have to drop them.
- DDL on every model write fires event triggers. On Supabase this includes the schema-reload trigger of PostgREST.

S1 has none of these problems. A model write is DML only.

## 10. The design against every case

The table lists the 24 run cases. In it, "edge" means a tuple that a walk reads. Every case also runs contextual, except the 3 multi-stage cases. The contextual run uses the same rules, through `fga_tuple` rows that carry the condition.

| Case | Features | How the design handles it |
| --- | --- | --- |
| direct_relation_with_condition | int, `<`. An absent parameter. | Rule 3 (2000 in all three APIs). `_fga_bidi` is false, and the backward closure raises. The lists use mode `r`. |
| indirect_relation_with_condition | timestamp, `timestamp()` literal (constant-evaluated). A condition on a userset edge. | One edge for each condition on `d`. LU with the filter `group#member` evaluates the userset edge (false, so the user is excluded). |
| userset_child_with_condition | a condition on the plain-user tuple of the child | LU `group#member`: the filter means that the walk does not evaluate the plain-user edge, so `group:eng#member` stays. |
| userset_parent_with_condition | a condition on the userset edge | as indirect |
| nested_indirect_relation_with_condition | ipaddress, `in_cidr`. **Tuple context and request context.** | Rule 1 merge. `inet` containment. IPv4-mapped addresses become plain IPv4 addresses first. |
| computed_userset_with_condition | a condition under a computed relation | The computed closure does not change. The `d` edge carries the condition. |
| tuple_to_userset_with_condition | a condition on a tupleset tuple | `t` edges and walk steps carry the condition of the tupleset restriction. |
| direct_relations_with_condition_through_intersection | two conditions, intersection. LO and LU without context. | `_fga_rec` intersection (code 4 with no false branch gives 2000). The lists use mode `r`. |
| simple_userset_with_condition | a condition on the userset edge. A userset user. | `_fga_bidi` from a userset user. LO for `folder:a#viewer`. |
| simple_userset_with_condition_in_child | a condition in the child | as userset_child |
| simple_userset_with_and_without_condition_in_child | `[user with xcond, user]` | Two restriction rows and two edges. A tuple without a condition never calls the evaluator (bob, no context: true). |
| simple_ttu_with_condition | a conditioned tupleset | `t` edge condition |
| simple_ttu_with_and_without_condition | mixed child restrictions. LO for the user without a condition, with no context. | LO walks only the own edges of the user (none has a condition), so there is no error. LU touches the edge with a condition, so it returns 2000. |
| simple_ttu_with_multiple_conditions | `[user with xcond, user with ycond]`. The own condition of each user. | One edge for each condition. A context with only `y` for the `xcond` user leaves `x` absent, so the result is 2000. |
| simple_ttu_with_condition_in_child | | as above |
| relation_through_ttu_with_condition | two conditions on two parents, union with `[user]`. A string literal. A contextual tuple that makes it true. | Rule 7. Check is true if one parent is true. It is 2000 if no parent is true and one has an error. LU is 2000 whenever an edge on the walk has an error. |
| direct_relations_with_condition | `x < 100 \|\| y < 50` | Rule 3 (an absent parameter gives 2000, despite `\|\|`). Otherwise `\|\|` applies. |
| prior_conditions_ignored | Stages: a condition renamed, then redefined with a new expression. | Edges belong to a model. A tuple whose condition the model does not accept matches no edge (ignored). Stage 2 evaluates `oldcondition` with the expression of stage 2 (`fga_conditions` for each model). |
| handles_floats | double. An out-of-range string and number. | Rule 4: float8 conversion of a jsonb numeric (overflow gives an error), and a big-float parse of the string. |
| ttu_mix_with_userset_member_condition | conditioned members, `user:*` without a condition, TTU. Checks with no context through the public path. | The bidi finds the true path without a condition first (true). LU and LO with context. |
| ttu_mix_with_userset_member_condition_mixed_parents | as above with two group types. **Malformed timestamp.** | The malformed value gives an error on the `group1` edge only. The true path of `group2` decides (rule 7). |
| ttu_mixed_parents_public_wildcard | `user:* with ts_less_than` | Wildcard tuples carry conditions like any tuple. LU returns `user:*` when true. |
| wildcard_with_condition | A `user:*` tuple without a condition, then a model that accepts only `user:* with ...`. | The old tuple matches no edge (ignored: false). The new wildcard with a condition evaluates. |
| condition_bound_to_correct_type_restriction_facet | Facets: concrete, wildcard, userset, with the condition on one facet. `group with isOk`. A bool parameter as the expression. Invalid contextual tuples. | Restriction rows for each facet and condition. Contextual validation: Check 2027, lists 2000 (rule 2). |

Skipped (9, `inline-expression`): `inline_expression_exclusion_subtract_missing_param`, `_basic`, `_inferred_string_param`, `_alongside_named_condition`, `_int_param`, `_timestamp_param`, `_ipaddress_param`, `_userset_subject`, `_ttu`. They need `$expression` (open question 1). Their expressions use only Tier 1 features. So support for them later is a question of storage, not of language. The storage design is: compile at tuple write, deduplicated by expression.

The 8 openfga/language cases that the suite skipped as `conditions` ran again in step 3:

| Case | Server | D after step 3 |
| --- | --- | --- |
| condition not defined (3 cases) | 2056 | 2056 (rule 2) |
| extraneous condition. Unused condition whose name is a prefix. | 201 | accepted (the model write compiles and stores an unused condition) |
| handle single name duplicated type and unused condition | 2056 (duplicate type) | 2056: the condition is valid, and the check for a duplicate type raises |
| inline expression mixed with plain and named condition. Inline expression on userset. | 2000 (`$expression` needs the flag) | 2000 if `$expression` stays out of scope (open question 1), with a HINT that says so |

## 11. Open questions for the user (decided)

The team decided these questions on 2026-10-29 and 2026-10-30, as recommended below except where noted ([`decision.md`](../decision.md), "Decisions for conditions (session 5)"). The decisions are:

- 1: out of scope, 2000.
- 2: deny, with no trusted context yet. [`rls.md`](../../docs/rls.md) shows a `security definer` wrapper that passes `now()`.
- 3: the rule of OpenFGA.
- 4: ignored everywhere.
- 5: the counter, limit 100.
- 6: 2017 with a HINT.
- 7: refused at model write (2056).

1. **Inline expressions (`$expression`)**: they are experimental in OpenFGA and off by default. The ABAC suite of upstream turns the flag on (9 cases). Recommendation: out of scope for phase 4. Reject `$expression` with 2000, as the default server does (the fga_lang cases agree). To support them later, reuse the compiler: compile at tuple write, and store the AST one time for each distinct expression.
2. **Conditions in RLS**: the current-subject functions take no request context, so a condition that needs a request parameter can never be true in a policy. D denies (rule 7). An option is to give them a trusted server-side context, for example `{"current_time": now()}` or values from `request.jwt.claims`, under fixed names. Recommendation: deny in phase 4, and decide the names afterwards. Expiry ("tuple context `expires`, request `current_time`") is the common case that this would unlock.
3. **Error rule of Check**: D follows OpenFGA. An edge with an error anywhere in the backward closure of the object fails a Check that finds nothing true (P14). The cost is one backward walk on false answers of `conditional` relations. The alternative is a path rule: an error matters only if the user is reachable through the edge. This is cheaper and does not depend on the search order, but it answers false where OpenFGA answers 2000. Recommendation: the rule of OpenFGA.
4. **Stale stored contexts**: a stored value can fail the parameter type of the current model. The Check of OpenFGA ignores the tuple. Its ListObjects raises 2000 (P28, P29). Recommendation: ignore everywhere (consistent lists, and a deviation for ListObjects).
5. **Cost limit**: approximate the limit of 100 of cel-go with a counter of nodes and iterations (the threshold differs from cel-go), or enforce no limit? D has no other budget for each request except `statement_timeout`. Recommendation: the counter.
6. **Same tuple key, different condition, `on_duplicate: ignore`**: OpenFGA answers HTTP 409 `Aborted` with no numeric code. Recommendation: 2017 with a message that says the condition differs.
7. **Tier 3** (bytes, `type()`, `dyn()`): reject at model write as proposed, or implement? Recommendation: reject, because nothing in the cases or docs uses them.

## 12. Steps 3 to 6, spec-first (done)

- Step 3 (model write): specs for P1-P4, the 8 fga_lang cases, the name and size limits (section 1.4) and the rejection of Tier 3. Then the tokenizer, parser, checker, `fga_conditions`, and the restriction and edge rows with conditions. The team removed `0A000` and added `d/35_error_hints` rows for each new raise site.
- Step 4 (evaluation and tuples): specs for P5-P13, P17-P32 and rules 1-6, against `_fga_cond` directly and through `fga_check`. Then values, parameters, the interpreter, `fga_write`, `fga_read` and contextual tuples.
- Step 5 (walks): `generate.py --suite`, with the abac suite red and then green in both runs. P14-P16 and the rule-7 cases as specs. The consolidated suite still passes 933 and 746. Mutants from [`plan.md`](../plan.md): ignore the condition, an absent parameter as false, swap the merge, and skip the type check.

  One more mutant: "evaluate errors as false in Check". This must fail `relation_through_ttu...` and the spec of P14. Before and after timings on the benchmark, tagged.
- Step 6: sections 2, 4, 7 and 8 of [`d-per-model.md`](./d-per-model.md) (deviation 2 replaced by the deviations above). Also the conditions page of the user documentation, with specs (expiry, IP range). This page is now [`conditions.md`](../../docs/conditions.md).

## 13. As implemented (phase 4, steps 3 to 6)

### 13.1 Where it lives

The section "Conditions (CEL): compiler and evaluator" of [`pg_permissions--0.0.1.sql`](../../pg_permissions--0.0.1.sql) has these functions:

- `_fga_cel_tokens`.
- `_fga_cel_parse` (one recursive function, with the precedence levels of CEL).
- `_fga_cel_check` (types, overloads, macros, constant evaluation).
- `_fga_cel_compile`.
- `_fga_cel_convert` and the parsers of timestamps, durations and ip addresses (the converters of OpenFGA).
- `_fga_cel_eval` (the interpreter).
- `_fga_cond_eval` (the condition of one tuple: merge, presence, conversion, evaluation).
- `_fga_cond` (a filter, by mode).
- `_fga_conds_ok` (the true ones among distinct (condition, context) pairs).
- `_fga_cond_fail` (the one 2000 raise site for an evaluation error).

The model write fills `fga_conditions`, the `condition` columns of restrictions, edges and walk steps, and `fga_relations.conditional`. The walks of [`d-per-model.md`](./d-per-model.md) section 5 take `p_req` (the context of the request) and `p_mode`.

### 13.2 Where it differs from the design above

1. **Values are jsonb**, in one canonical form for each static type, in place of a composite with one field for each kind (section 6). The forms are:
   - Numbers for int, uint and double (a double goes through the shortest text of float8).
   - Integer nanoseconds for durations.
   - `YYYY-MM-DDTHH:MI:SS.USZ` in UTC for timestamps, so the text order is the time order.
   - The text of an ip address.
   - Arrays and objects for lists and maps (a map has the text of its key as key).

   Equality is jsonb equality. This includes the heterogeneous equality of CEL (`1 == 1.0` in a dyn). The evaluator returns `fga_cel_result(v, e, c)`: the value, an error message, and the cost so far. Types matter at run time only for dyn. Dyn values are JSON from `any` parameters, and their numbers are doubles, as in the JSON context of OpenFGA.
2. **Mixed literals.** OpenFGA accepts `[1, "a"]` as a list of dyn (P36), and D does the same. But an int or uint in it, or in a map literal of mixed types, behaves as a double afterwards. `[1, "a"][0] + 1` is "no such overload" here, and 2 in cel-go. D refuses a conditional with branches of two types, as the server does (P34).
3. **Modes.** D has five modes. `r` fails with 2000, `d` makes an error false, and `t` reports it (the result 4 of `_fga_rec`). Two more modes exist. In mode `e`, `_fga_bstep` returns the error as a row. The error walk of Check (`_fga_bidi_errors`) returns the message and does not raise.

   In mode `n`, an error counts as true. The subtract walks of the RLS helpers (set-based `but not` lists) use mode `n`, so an error removes an object and does not grant it. For the RLS helpers, `_fga_rec` runs in mode `t` and 4 is false. Decision 4 says "deny". Mode `d` alone would let a user through a `but not` whose subtract has an error, and `d/39` pins this.
4. **One evaluation for each distinct context** (decision 2). This applies in `_fga_fstep`, `_fga_bstep`, the error walk of Check, and the leaves of `_fga_forward` and `_fga_forward_ids`. The leaves are the last join, where the thousands of objects of a wide walk are. The code is `_fga_conds_ok` over `jsonb_agg(distinct [name, context])`. `d/39` checks that a ListObjects over 50 tuples that share one condition and context evaluates it one time.

   Inside the recursive term of the forward walk, the walk evaluates a tuple with a condition for each row, because a recursive term cannot aggregate. The expandable nodes are teams and folders. A walk through many memberships with a condition and distinct contexts pays one evaluation for each membership for each level that it reaches. Phase 5 can move that walk to a loop if it matters.

   Phase 5 (session 5) measured this and changed it. On the wide benchmark data, a ListObjects through memberships with a condition evaluated the shared condition 205 times. Now the walk first runs its recursion without conditions and levels (a superset of the nodes that it reaches). It evaluates each distinct (condition, context) pair of the tuples with a condition there, one time (`_fga_conds_eval`).

The walk with levels takes a tuple through a lookup of its pair (`_fga_cond_take`). So an error still counts only on a tuple that the walk takes. The result is 2 evaluations.

   The same pass found that the filter of the leaves was quadratic in distinct contexts (a correlated `IS NOT DISTINCT FROM` subplan for each leaf). It is an equality join now. This also applies in `_fga_fstep`, `_fga_bstep` and `_fga_forward_ids`. A wide ListObjects with a context for each tuple went from 3.2 s to 166 ms. The numbers are in [`benchmarks/D.md`](../benchmarks/D.md), opt3.
5. **Cost.** The cost is 1 for each identifier, call, operator, field selection, index and list or map literal that the evaluator evaluates. Literals cost nothing, and `||`, `&&` and `? :` cost nothing (as in cel-go). Each comprehension iteration costs 3.

   Past 100, the evaluation fails ("operation cancelled: actual cost limit exceeded"). `l.exists(e, e == "zzz")` passes over 19 elements and fails over 20. The server fails somewhere between 11 and 20 (P38: 10 passes, 20 fails). The 35-term chain of P38 costs 70. The abac cases cost at most a handful.
6. **The error walk of Check** follows the backward closure of the object up to depth 25. (Deeper, OpenFGA would hit its depth limit first.)
7. **Write**: a tuple with a condition and no context is stored, and a read returns it with `{}` (P42). A one-character condition name in a tuple is 2000 (P43), as in OpenFGA. So a model can declare a condition with a one-character name, but a tuple cannot use it.
8. **Compile errors** name the column of the operator or token, as cel-go does (`... applied to '(int, string)' (column 3)`).
9. **The validation of the request** for conditions (2000) covers the condition name, expression size, parameter count and parameter names (P33), and inline `$expression` (decision 8).

### 13.3 Deviations, the full list

These are the deviations from OpenFGA v1.22.1. [`d-per-model.md`](./d-per-model.md) section 8 (deviation 2) documents all of them:

- Inline `$expression` conditions are refused (2000, as the default server does). The flag of OpenFGA turns them on.
- `bytes`, `type()`, `dyn()`, type names as values, message construction and optional syntax are refused at model write (2056).
- The cost limit is approximate (section 13.2, item 5).
- A stored context that the current model no longer accepts makes the tuple ignored in ListObjects and ListUsers too. The lists of OpenFGA fail with 2000 (P29).
- The RLS helpers take no request context, and they deny when an answer depends on an evaluation error.
- Timestamps are microseconds (the function drops sub-microsecond digits) within years 1 to 9999. Double overflow and division by zero are errors (CEL gives infinities and NaN). `matches` uses Postgres regular expressions. The functions refuse IPv6 zones.
- In values of type `any` and in mixed literals, ints are doubles (section 13.2, item 2).
- A dyn comparison compares numbers of different kinds (`a < 5` with `a` any given 3 is true, as the server does, P41).

### 13.4 Tests

These specs test the implementation:

- `test/spec/d/37_fga_conditions_model`: 51 assertions.
- `38_fga_cel`: 142 assertions.
- `39_fga_conditions_eval`: 64 assertions.
- `90_usage_conditions`: 29 assertions.
- Four more assertions in `90_usage_rls`.
- Eight rows in `35_error_hints` for the eight new raise sites. The three 0A000 rows are gone. There were 63 sites before, and there are 68 now.

Before the implementation, the specs were red: 6 of 51, 0 of 142 and 4 of 64 passed (the assertions that passed hold without conditions). The abac oracle passes 302 of 302 and 271 of 271. [`d-per-model.md`](./d-per-model.md) section 9 has the mutants.

### 13.5 Performance

**The fast path without conditions.** The team ran `bench/run.sh --scale large --only share_list_objects,share_select_page,parents_select_page,nest_check`. The setup was a local Postgres 16.4 (Postgres.app), Apple silicon, 4 clients, 10 s for each workload. It used the large default shape of [`benchmarks/D.md`](../benchmarks/D.md), run locally and not in the Docker setup of that page. `--only` runs write no baseline JSON.

The team ran the benchmark two times before (`--tag cond-before`, the extension at commit `5c0951e`) and two times after (`--tag cond-after`). The runs were strictly one at a time, never at the same time as the tests, on 2026-10-30. The idle Docker stacks (Supabase, freereps, an unrelated container) and a browser ran too. The load average was 3 to 7 on 10 cores.

| workload | before, p50 / p95 (ms): run 1, then run 2 | after, p50 / p95 (ms): run 1, then run 2 |
| --- | --- | --- |
| `share_list_objects` (ListObjects for RLS, `fga_list_object_ids_current`) | 0.28 / 0.39, then 0.28 / 0.43 | 0.28 / 0.38, then 0.28 / 0.38 |
| `share_select_page` (RLS page) | 0.82 / 1.05, then 0.84 / 1.08 | 0.81 / 1.24, then 0.81 / 1.01 |
| `parents_select_page` (RLS page over 1M documents) | 0.93 / 10.51, then 0.96 / 11.64 | 0.85 / 8.18, then 0.89 / 9.23 |
| `nest_check` (Check, `fga_check_current`) | 0.38 / 0.58, then 0.37 / 0.52 | 0.38 / 0.48, then 0.38 / 0.50 |

The results are within noise. The p50 values match to 0.01 ms, except for `parents_select_page`. Its p95 swings by 10 to 20 % between runs of the same build. The path without conditions adds one equality to each edge join. It reads `conditional` with the flags that it already read.

**Edges with conditions.** This is a throwaway measurement on the same machine, with a scratch database, 1,000 tuples for each user on one relation, warm. One evaluation of `x < 100` costs about 9 µs through `_fga_cond_eval`. The interpreter uses 2 µs of it. The rest is the condition lookup, the merge and the conversions. A timestamp comparison costs about 18 µs and `in_cidr` 16 µs (the parse of RFC 3339 and of addresses).

ListObjects over 1,000 tuples without conditions took 2.0 ms. Over 1,000 tuples that share one condition and context, it took 2.8 ms (one evaluation). Over 1,000 tuples with 1,000 distinct stored contexts, it took 21.8 ms (about 20 µs each). Check took 68 µs for each call without conditions, and 74 µs through a true edge with a condition. On a false answer for a conditional relation, Check took about 160 to 180 µs, with the error walk of rule 7 included. Phase 5 is where to cut these costs.

Status: phase 5 of session 5 did cut these costs. See item 4 of section 13.2 and [`benchmarks/D.md`](../benchmarks/D.md), opt3.
