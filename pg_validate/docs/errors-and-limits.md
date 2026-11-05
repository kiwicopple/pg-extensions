# Errors and limits

## Validators do not raise errors for bad input

A validator returns `false` for any invalid value, whatever its length or content, and null for null. Only two calls raise errors, both for invalid arguments rather than invalid values:

| Call | SQLSTATE | When |
| --- | --- | --- |
| `validate.uuid(value, version)` | `22023` | `version` is not 1 to 8. |
| `validate.nanoid(value, size, alphabet)` | `22023` | `size` is below 1 or `alphabet` is empty. |

A row that fails a `CHECK` constraint raises `23514` (`check_violation`) with the constraint's name, and a value cast to a domain raises the same.

## Registry errors

| SQLSTATE | Name | Raised by | When |
| --- | --- | --- | --- |
| `22004` | `null_value_not_allowed` | `register_format`, `register_schema` | `name`, `validator` or `schema` is null. |
| `22023` | `invalid_parameter_value` | `register_format`, `register_schema` | Invalid name, or a validator with the wrong signature or `VOLATILE`; a schema with a subschema that is not a schema or a `$ref` to a missing location. |
| `0A000` | `feature_not_supported` | `register_schema` | A remote `$ref`, or `\p{...}` in a pattern. |
| `2201B` | `invalid_regular_expression` | `register_schema` | A pattern Postgres cannot compile. |
| `42501` | `insufficient_privilege` | the register and unregister functions, direct writes | Missing `EXECUTE`, `INSERT`, `UPDATE` or `DELETE`; a built-in format; an entry owned by another role; `truncate`. |
| `42704` | `undefined_object` | `format`, `unregister_format`, `json_schema_named`, `unregister_schema`, `register_schema` | Unknown format or schema name; a schema with an unknown `format`. |
| `42710` | `duplicate_object` | `register_format`, `register_schema` | The name is already registered. |
| `42883` | `undefined_function` | `format`, `register_format` | The format's function was dropped or renamed; or the `regprocedure` argument names no function. |

Every registry error has a message that names the format or schema, and most have a hint.

## JSON Schema errors

`validate.json_schema` and `validate.json_schema_named` return `false` for an invalid document and raise only for problems with the schema or the environment: a remote `$ref` or a `\p{...}` pattern (`0A000`), a malformed schema or a missing `$ref` target (`22023`), a pattern Postgres cannot compile (`2201B`), an unknown format (`42704`), and nesting deeper than 256 levels (`54001`). See [JSON Schema](json-schema.md#errors). To find out why a document is invalid, call `validate.json_schema_errors`.

## Limits

| Limit | Value | Source |
| --- | --- | --- |
| Email address | 254 octets; local part 64 | RFC 5321 §4.5.3 |
| Host name | 253 characters; label 63 | RFC 1035 §2.3.4 |
| Internationalized host name | 253 octets; label 63, both in A-label form | RFC 5890 §2.3.2.1 |
| Internationalized email address | 254 octets of UTF-8; local part 64 | RFC 6531 §3.3, RFC 5321 §4.5.3 |
| E.164 number | 15 digits | E.164 §6.1 |
| Card number | 12 to 19 digits | ISO/IEC 7812-1 |
| IBAN | 15 to 33 characters, by country | SWIFT IBAN registry |
| Years in dates | 0000 to 9999 | RFC 3339; ISO 8601 without expansion |
| Format and schema names | 63 characters | This extension |
| IDNA tables | Unicode 12.0.0: later characters are rejected in `idn_hostname`, `idn_email` and A-labels | IANA IDNA tables; see [`idn_hostname`](reference/internet.md#idn_hostname) |
| URI, URL, base64, hex | No limit beyond Postgres's 1 GB for `text` | Add `octet_length(value) <= n` to your constraint |

## Cost

The built-in validators are small SQL or PL/pgSQL functions. Most are one regular expression match; the date, URI, IBAN, cron and checksum validators run a short PL/pgSQL routine. `regex` parses the pattern character by character, and `idn_hostname`, `idn_email` and `hostname` (for `xn--` labels only) decode Punycode and look each character up in the IDNA table: expect tens of microseconds for those. Postgres caches compiled regular expressions per session. Expect microseconds per call, which is negligible next to an insert.

`validate.format` adds a registry lookup and a dynamic `EXECUTE` (parse and plan) per call. In a constraint or a large scan, call the validator function directly.

`validate.json_schema` and `validate.json_schema_named` cost from a few to a few hundred microseconds per document, depending on the schema; [JSON Schema](json-schema.md#performance) has measurements.

Each function sets `search_path` to the empty string, which Postgres applies on every call. That keeps the functions safe from objects in the caller's search path and costs a little time per call.

## Compatibility notes

- Postgres 16, 17 and 18 are tested, as a plain install, as a non-superuser, through pg_tle 1.5.3 and with `create extension`.
- Results do not depend on `TimeZone`, `DateStyle`, `standard_conforming_strings`, the database collation or the session's locale. The test suite checks this, including a Turkish ICU collation, where `upper('i')` is not `I`.
- `idn_hostname`, `idn_email`, `iri`, `iri_reference`, `uri_template` and `regex` need a database with the `UTF8` encoding for non-ASCII input; in other encodings such input can raise an error. `idn_hostname` normalizes with Postgres's Unicode tables (Unicode 15.0 in Postgres 16, 15.1 in 17, 16.0 in 18), so a character whose NFKC form changed between Unicode versions can give a different result on different major versions.
- `pg_dump` restores table rows before the registry rows. Add `CHECK` constraints that use a custom format or a named schema `NOT VALID`; see [Formats in CHECK constraints](registry.md#formats-in-check-constraints).
- Do not put `validate` on the `search_path`; see [Install](install.md#search-path).
