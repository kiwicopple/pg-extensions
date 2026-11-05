# pg_validate documentation

`pg_validate` adds boolean validators for common string formats to Postgres, for `CHECK` constraints and queries, plus a registry of named formats. The extension is SQL and PL/pgSQL and runs on Postgres 16, 17 and 18.

New to the project? Read the [overview](overview.md), then [install the extension](install.md) and follow the [quickstart](get-started/quickstart.md). The quickstart adds constraints to a table, shows a rejected row and registers a custom format.

## Build your application

| Task | Read |
| --- | --- |
| Install with `create extension`, pg_tle or psql | [Install](install.md) |
| Add constraints to a table | [Quickstart](get-started/quickstart.md) |
| Name constraints, use domains, constrain existing data, normalize input | [Use validators in constraints](guides/constraints.md) |
| Know which spelling each validator accepts, and normalize input before the check | [Canonical forms and normalizing input](guides/normalization.md) |
| Register your own format and control who can | [Custom formats](registry.md) |
| Validate `jsonb` documents against a JSON Schema | [JSON Schema](json-schema.md) |
| Understand an error or a limit | [Errors and limits](errors-and-limits.md) |

<span id="reference"></span>

## Reference

Each validator has its signature, the specification it follows, examples, and what it guarantees and does not guarantee.

| Group | Validators |
| --- | --- |
| [Identifiers](reference/identifiers.md) | `uuid`, `ulid`, `nanoid`, `slug`, `semver`, `git_sha` |
| [Internet](reference/internet.md) | `email`, `url`, `uri`, `uri_reference`, `domain`, `hostname`, `ipv4`, `ipv6`, `mac`, `port` |
| [Dates and times](reference/dates.md) | `iso8601`, `rfc3339`, `rfc3339_date`, `rfc3339_time`, `duration` |
| [International](reference/international.md) | `e164`, `country_code`, `country_code_alpha3`, `currency_code`, `language_code` |
| [Developer formats](reference/developer.md) | `base64`, `base64url`, `hex`, `json_pointer`, `cron` |
| [Financial](reference/financial.md) | `iban`, `isbn`, `isbn10`, `isbn13`, `card_number`, `luhn` |
| [Registry](reference/registry.md) | `format`, `list_formats`, `register_format`, `unregister_format` |
| [JSON Schema](json-schema.md) | `json_schema`, `json_schema_errors` |

## Plans

The [roadmap](roadmap.md) lists candidate formats and the rules new validators follow.

## Example conventions

SQL examples use named arguments and lowercase keywords. Comments after a statement show its result (`-- true`). Each task page states its prerequisites; run its blocks in order unless one is marked as an expected error. The test suite runs the quickstart, custom formats, JSON Schema and normalization examples (`test/spec/90_usage_quickstart.sql`, `91_usage_registry.sql`, `92_usage_json_schema.sql`, `93_usage_normalization.sql`).

The examples call the role that installed the extension the extension owner. It owns the registry and can let other roles register formats.
