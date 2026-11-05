# JSON Schema

`validate.json_schema(doc, schema)` checks a `jsonb` document against a [JSON Schema](https://json-schema.org) Draft 2020-12 schema. `format` is an assertion that calls the [format registry](registry.md), so the built-in validators and your registered formats both work. Every format that Draft 2020-12 defines has a built-in validator. The evaluator is written in PL/pgSQL, needs no other extension, and installs wherever `pg_validate` does, including through pg_tle.

You can also register a schema under a name and validate against the name with `validate.json_schema_named(doc, name)`: the schema is checked once, when it is registered, and stored with its index, so constraints stay short and a schema can change without `alter table`. [Named JSON schemas](guides/named-schemas.md) shows how.

```sql
create table products (
  id bigint generated always as identity primary key,
  doc jsonb not null
    constraint products_doc_is_valid
    check (validate.json_schema(doc, '{
      "type": "object",
      "required": ["name", "price"],
      "properties": {
        "name": {"type": "string", "minLength": 1},
        "price": {"type": "number", "exclusiveMinimum": 0},
        "tags": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}
      },
      "additionalProperties": false
    }'))
);
```

## Functions

### `json_schema`

```text
validate.json_schema(doc jsonb, schema jsonb) returns boolean
```

Returns whether `doc` is valid against `schema`. A null argument returns null; the JSON value `null` is an ordinary document. Evaluation stops at the first failing keyword.

`STABLE STRICT`, `SECURITY INVOKER`, `PARALLEL UNSAFE`. It is not `IMMUTABLE` because `format` reads the registry, which can change, so it cannot be used in an index or a generated column. A `CHECK` constraint may use it, with the same caveat as `validate.format`: registry changes do not recheck existing rows (see [Custom formats](registry.md#formats-in-check-constraints)). Custom format validators run with the caller's privileges.

### `json_schema_errors`

```text
validate.json_schema_errors(doc jsonb, schema jsonb) returns table (
  instance_location text,
  keyword_location text,
  keyword text,
  message text
)
```

Returns one row per error, and no rows when the document is valid. The columns follow the "basic" output format of the specification (§12.4):

| Column | Meaning |
| --- | --- |
| `instance_location` | JSON Pointer to the failing value in `doc`; `''` is the whole document. |
| `keyword_location` | JSON Pointer to the failing keyword along the evaluation path. It includes `$ref` and `$dynamicRef` steps, so it can lead through a reference. |
| `keyword` | The keyword that failed, such as `required` or `format`; `false` for a `false` schema. |
| `message` | A sentence for logs and developers. The wording may change between versions; match on `keyword` and the locations instead. |

Unlike `json_schema`, it evaluates every keyword, so it reports all errors, not only the first. When `anyOf` fails, or `oneOf` matches nothing, it reports the keyword and the errors of every branch. When `not` fails, or `oneOf` matches more than one branch, it reports only the keyword.

```sql
select instance_location, keyword_location, keyword
from validate.json_schema_errors(
  doc => '{"name": "", "price": -1}',
  schema => '{
    "type": "object",
    "required": ["name", "price"],
    "properties": {
      "name": {"type": "string", "minLength": 1},
      "price": {"type": "number", "exclusiveMinimum": 0}
    }
  }'
);
-- /name  | /properties/name/minLength         | minLength
-- /price | /properties/price/exclusiveMinimum | exclusiveMinimum
```

### `json_schema_named` and `json_schema_named_errors`

```text
validate.json_schema_named(doc jsonb, name text) returns boolean
validate.json_schema_named_errors(doc jsonb, name text) returns table (
  instance_location text,
  keyword_location text,
  keyword text,
  message text
)
```

The same as `json_schema` and `json_schema_errors`, against the schema registered as `name` with [`validate.register_schema`](reference/registry.md#register_schema). An unknown name raises `42704`. Both are `STABLE STRICT`, `SECURITY INVOKER`, `PARALLEL UNSAFE`, because they read the schema registry as well as the format registry.

They have their own names rather than being overloads of `json_schema(jsonb, text)`. With an untyped string literal as the second argument, Postgres prefers the `text` overload (the string category wins for unknown literals), so `json_schema(doc, '{"type": "object"}')` would have looked up a schema named `{"type": "object"}`. With separate names, a literal always means a schema in `json_schema` and a name in `json_schema_named`.

## Supported keywords

Every keyword of the Draft 2020-12 core, applicator, unevaluated and validation vocabularies is implemented, and `format` follows the format-assertion vocabulary:

| Vocabulary | Keywords |
| --- | --- |
| Core | `$id` (embedded resources), `$anchor`, `$ref`, `$dynamicAnchor`, `$dynamicRef`, `$defs`, `$comment` (ignored), boolean schemas |
| Applicator | `allOf`, `anyOf`, `oneOf`, `not`, `if` / `then` / `else`, `dependentSchemas`, `properties`, `patternProperties`, `additionalProperties`, `propertyNames`, `prefixItems`, `items`, `contains` |
| Unevaluated | `unevaluatedProperties`, `unevaluatedItems`, with annotations collected through `$ref`, `$dynamicRef`, `allOf`, `anyOf`, `oneOf`, `if` / `then` / `else`, `dependentSchemas` and `contains` |
| Validation | `type` (`integer` includes numbers such as `1.0`), `enum`, `const`, `multipleOf`, `maximum`, `exclusiveMaximum`, `minimum`, `exclusiveMinimum`, `maxLength`, `minLength` (in Unicode code points), `pattern`, `maxItems`, `minItems`, `uniqueItems`, `maxContains`, `minContains`, `maxProperties`, `minProperties`, `required`, `dependentRequired` |
| Format assertion | `format`, through the registry (below) |
| Meta-data, content | `title`, `description`, `default`, `examples`, `deprecated`, `readOnly`, `writeOnly`, `contentEncoding`, `contentMediaType`, `contentSchema`: annotations, accepted and ignored |

Numbers are compared as Postgres `numeric`, so large integers and decimals are exact: `multipleOf: 0.01` works on prices. Equality in `enum`, `const` and `uniqueItems` is JSON equality: `1` equals `1.0`, and key order does not matter.

### References

`$ref` and `$dynamicRef` resolve against the base URI in effect (RFC 3986 §5) to one of:

- a JSON Pointer fragment, such as `#/$defs/address`, percent-decoded;
- a plain-name fragment defined by `$anchor` or `$dynamicAnchor`, such as `#node`;
- a schema resource embedded in the same document with `$id`, with or without a fragment, such as `{"$ref": "address.json"}` when a subschema has `"$id": "address.json"`.

A schema without `$id` gets the base URI `pg-validate:/schema`. `$dynamicRef` follows the 2020-12 rules: when its initial target is a `$dynamicAnchor`, the outermost schema resource in the dynamic scope with the same dynamic anchor wins. Recursive schemas work. Evaluation nested more than 256 levels deep raises `54001`, which catches reference cycles that never consume the instance.

A reference to anything outside the document raises `0A000`, including the official metaschemas (`https://json-schema.org/draft/2020-12/schema`): the database does not fetch URLs. Inline the referenced schema under `$defs` with its `$id` instead.

## Formats

`format` applies to strings only; other types pass, as the specification requires. For a string, `json_schema` calls `validate.format(name, value)`:

| JSON Schema format | Validator | Notes |
| --- | --- | --- |
| `date-time` | [`validate.rfc3339`](reference/dates.md#rfc3339) | Built-in alias |
| `date` | [`validate.rfc3339_date`](reference/dates.md#rfc3339_date) | Built-in alias |
| `time` | [`validate.rfc3339_time`](reference/dates.md#rfc3339_time) | Built-in alias; the offset is required |
| `duration` | [`validate.duration`](reference/dates.md#duration) | Accepts ISO 8601 durations, a superset of RFC 3339 Appendix A |
| `email` | [`validate.email`](reference/internet.md#email) | ASCII addresses |
| `idn-email` | [`validate.idn_email`](reference/internet.md#idn_email) | Built-in alias; RFC 6531 |
| `hostname` | [`validate.hostname`](reference/internet.md#hostname) | RFC 1123; `xn--` labels must be valid IDNA2008 A-labels |
| `idn-hostname` | [`validate.idn_hostname`](reference/internet.md#idn_hostname) | Built-in alias; IDNA2008 with Unicode 12.0 tables and a subset of the UTS #46 mapping |
| `ipv4`, `ipv6` | [`validate.ipv4`](reference/internet.md#ipv4), [`validate.ipv6`](reference/internet.md#ipv6) | |
| `uri` | [`validate.uri`](reference/internet.md#uri) | |
| `uri-reference` | [`validate.uri_reference`](reference/internet.md#uri_reference) | Built-in alias |
| `iri` | [`validate.iri`](reference/internet.md#iri) | RFC 3987 |
| `iri-reference` | [`validate.iri_reference`](reference/internet.md#iri_reference) | Built-in alias; RFC 3987 |
| `uri-template` | [`validate.uri_template`](reference/developer.md#uri_template) | Built-in alias; RFC 6570 levels 1 to 4 |
| `uuid` | [`validate.uuid`](reference/identifiers.md#uuid) | |
| `json-pointer` | [`validate.json_pointer`](reference/developer.md#json_pointer) | Built-in alias |
| `relative-json-pointer` | [`validate.relative_json_pointer`](reference/developer.md#relative_json_pointer) | Built-in alias; draft-handrews-relative-json-pointer-01 |
| `regex` | [`validate.regex`](reference/developer.md#regex) | ECMA-262 syntax in Unicode mode; see its reference for what is checked |

Every other registry name works too: `"format": "iban"`, `"format": "semver"`, the [other built-in validators](README.md#reference), and any format you register.

The built-in formats are called directly, without the registry lookup and dynamic SQL of `validate.format`; the built-in rows cannot change, so the result is the same.

**An unknown format raises `42704`** when a string reaches it, instead of passing. The format-assertion vocabulary requires implementations to reject unknown formats, and an error finds a misspelt format name the first time it is used. Register a format, or remove the keyword.

### Use a custom format

Register a validator, then use its name in a schema:

```sql
create function public.product_sku(value text)
returns boolean
language sql
immutable
strict
as $$
  select value ~ '^[A-Z]{3}-[0-9]{4}$'
$$;

select validate.register_format(
  name => 'product-sku',
  validator => 'public.product_sku(text)',
  description => 'Product SKU such as ABC-1234'
);

select validate.json_schema(
  doc => '{"sku": "ABC-1234"}',
  schema => '{"properties": {"sku": {"format": "product-sku"}}}'
);
-- true
select validate.json_schema(
  doc => '{"sku": "abc"}',
  schema => '{"properties": {"sku": {"format": "product-sku"}}}'
);
-- false
```

## Patterns

`pattern` and `patternProperties` use ECMA-262 regular expressions; Postgres uses POSIX advanced regular expressions (ARE). Most patterns mean the same in both. The evaluator translates the escapes whose meaning differs, outside and inside brackets:

| ECMA-262 | Translated to | Why |
| --- | --- | --- |
| `\d`, `\D` | `[0-9]`, `[^0-9]` | Postgres's `\d` can match non-ASCII digits, depending on the locale. |
| `\w`, `\W` | `[A-Za-z0-9_]`, `[^A-Za-z0-9_]` | Same reason. |
| `\s`, `\S` | ECMA-262's white space and line terminator set | Postgres's set depends on the locale. |

Differences that remain:

- Unicode property escapes (`\p{L}`, `\p{Letter}`) have no Postgres equivalent and raise `0A000`. They are valid in a `"format": "regex"` value, which [`validate.regex`](reference/developer.md#regex) checks against the ECMA-262 grammar without running it.
- `.` matches a newline in Postgres; in ECMA-262 it does not.
- Named groups (`(?<name>...)`) and other ECMA-only syntax are invalid in Postgres and raise `2201B`.
- Non-ASCII patterns behave as in ECMA-262's Unicode mode only in a UTF-8 database.

## Not supported

| Feature | Behavior |
| --- | --- |
| Remote `$ref`, including the metaschemas | Raises `0A000` |
| `$schema`, `$vocabulary` | Ignored: every vocabulary above is always on. Schemas are not validated against a metaschema. |
| Keywords of earlier drafts (`dependencies`, `additionalItems`, array-form `items`, `$recursiveRef`, `definitions` as a place for `$id`) | Unknown keywords, ignored. A `$ref` to `#/definitions/x` still works as a JSON Pointer. |
| `contentSchema` and the other content keywords | Annotations only, never validated |
| U+0000 in strings | Postgres `jsonb` cannot store it |
| Output formats other than "basic" | `json_schema_errors` returns a flat list |

## Guarantees

**Guarantees:** a `true` result means the document satisfies every supported keyword of the schema under Draft 2020-12 semantics, with `format` asserted by the registry's validators. The evaluator passes the official JSON Schema Test Suite for Draft 2020-12, apart from the documented exceptions below.

**Does not guarantee:** that the schema itself is a valid schema (it is not checked against the metaschema; a malformed keyword value can raise an error or be ignored; `register_schema` checks references, patterns and formats, not keyword values), anything the format validators themselves do not guarantee (see each validator's reference), or ECMA-262 semantics for patterns beyond the translation above.

## Test suite results

The test suite runs the official [JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite) (commit `3f05891`, vendored in `test/json_schema/upstream` under its MIT license) on Postgres 16, 17 and 18. Each skipped case is listed in [`test/json_schema/skip.tsv`](../test/json_schema/skip.tsv) with its reason; cases whose JSON Postgres cannot store (U+0000, unpaired surrogates) are skipped automatically. No case fails.

| Part | Cases | Passed | Skipped |
| --- | --- | --- | --- |
| Required tests | 1298 | 1220 | 78 |
| Optional tests | 162 | 111 | 51 |
| Optional format tests (format assertion) | 895 | 887 | 8 |

Files with skipped cases:

| File | Passed | Skipped | Reason |
| --- | --- | --- | --- |
| `refRemote.json` | 0 | 31 | Remote `$ref` |
| `dynamicRef.json` | 31 | 13 | Remote `$ref`; every local case passes |
| `format.json` | 114 | 19 | The required tests expect `format` to be an annotation; here it is an assertion, and unknown formats raise |
| `pattern.json`, `patternProperties.json` | 32 | 6 | `\p{...}` |
| `defs.json`, `ref.json` | 77 | 4 | Need the metaschema (remote `$ref`) |
| `vocabulary.json` | 4 | 1 | `$vocabulary` is not processed |
| `const.json`, `enum.json` | 103 | 4 | U+0000 in a string |
| `optional/dependencies-compatibility.json` | 0 | 36 | `dependencies` is not a 2020-12 keyword |
| `optional/ecmascript-regex.json` | 60 | 14 | `\p{...}` |
| `optional/cross-draft.json` | 0 | 1 | Remote `$ref` |
| `optional/format/duration.json` | 47 | 4 | `duration` accepts ISO 8601 forms that RFC 3339 Appendix A omits |
| `optional/format/unknown.json` | 6 | 1 | Unknown formats raise |
| `optional/format/`: `date`, `ipv4`, `json-pointer` | 159 | 3 | U+0000 or an unpaired surrogate |

Every other file passes completely, including `unevaluatedProperties.json` (129 cases), `unevaluatedItems.json` (71), `anchor.json`, `items.json`, `oneOf.json`, and the format files for `date-time`, `time`, `email`, `idn-email`, `hostname` (with its 23 A-label cases), `idn-hostname` (95 cases), `ipv6`, `iri`, `iri-reference`, `uri`, `uri-reference`, `uri-template`, `relative-json-pointer`, `regex`, `ecmascript-regex` and `uuid`.

## Performance

`json_schema` evaluates the schema recursively in PL/pgSQL. Before that it builds an evaluation context: for a schema without embedded `$id` resources, `$anchor`, `$dynamicAnchor` or `$dynamicRef` (the common case, including `"$ref": "#/$defs/..."` and a root `$id`), the context is built without walking the schema; otherwise every call walks the schema to index its resources and anchors. `json_schema_named` reads the context that `register_schema` stored and skips this step.

Measured on Postgres 18 in Docker on an Apple M4, with 10,000 generated documents per schema, about one in ten invalid, best of three runs. [`bench/json_schema.sql`](https://github.com/kiwicopple/pg-extensions/blob/main/pg_validate/bench/json_schema.sql) has the schemas; `bench/run.sh` runs it.

| Schema | `json_schema` | `json_schema_named` |
| --- | --- | --- |
| Trivial: `{"type": "object", "required": ["id"]}` | 8 µs | 7 µs |
| Nested: six properties, a nested object, an array, `format: email`, `pattern`, `uniqueItems`, `additionalProperties: false` | 111 µs | 105 µs |
| References: a root `$id`, nine `$ref`s to `$defs` per document | 265 µs | 244 µs |
| Anchors: `$anchor` and `"$ref": "#name"`, four references per document | 212 µs | 123 µs |
| `unevaluatedProperties` with `allOf` and `if` / `then` / `else` | 78 µs | 70 µs |

Cost grows with the number of subschemas evaluated, at roughly 5 to 10 µs each, and with references, at about 8 µs each. `json_schema` stops at the first error; `json_schema_errors` evaluates everything. `unevaluatedProperties` and `unevaluatedItems` make the evaluator collect annotations, and make `anyOf` evaluate every branch; schemas without them skip that work. Built-in formats are called directly; a registered format goes through `validate.format`, which adds a dynamic `EXECUTE` per string.

Named schemas pay off most for schemas with anchors or embedded resources, which `json_schema` must index on every call. For the other shapes they save a few microseconds, and their main benefits are a schema that is checked once and a short constraint. Validate on write with a `CHECK` constraint rather than by scanning. For bulk loads of large documents, a compiled implementation such as [`pg_jsonschema`](https://github.com/supabase/pg_jsonschema) is faster, but it needs a server binary and does not use this registry for `format`.

The evaluator does not cache anything between calls. PL/pgSQL has no per-session memory that a function can keep across calls, and the alternatives, a temporary table or a custom setting holding the compiled schema, are not safe here: they are visible to and writable by the session's other code, they would make the functions depend on session state that a `CHECK` constraint should not depend on, and they would need invalidation when a schema or format changes. A named schema gives most of the benefit with none of these problems.

## Errors

| SQLSTATE | When |
| --- | --- |
| `0A000` | A remote `$ref`, or a `\p{...}` escape in a pattern. |
| `22023` | A value that is not an object or a boolean where a schema is expected, or a `$ref` whose target is not in the document. |
| `2201B` | A pattern that Postgres cannot compile. |
| `42501` | A custom format's validator needs a privilege the caller lacks. |
| `42704` | A string reaches a `format` that is not registered; or `json_schema_named` names a schema that is not registered. |
| `42883` | A registered format's function was dropped. |
| `54001` | Evaluation nested more than 256 levels deep. |
