# `pg_validate`

`pg_validate` is a Postgres extension of boolean validators for common string formats: email addresses, URLs, UUIDs, dates, ISO codes, IBANs and more. Use them in `CHECK` constraints:

```sql
create table customers (
  email text not null
    check (validate.email(email)),
  country text
    check (validate.country_code(country))
);
```

A registry gives every validator a name, so `validate.format('email', value)` works too, and applications can register their own formats. `validate.json_schema(doc, schema)` validates `jsonb` documents against JSON Schema Draft 2020-12, with `format` checked through the same registry.

The extension is pure SQL and PL/pgSQL. It needs no other extension, no C code and no superuser, and runs on Postgres 16, 17 and 18, including through pg_tle.

- Source: https://github.com/kiwicopple/pg-extensions/tree/main/pg_validate
- database.dev (dbdev): https://database.dev/kiwicopple/pg_validate (not yet published)

## Features

- 37 validators, each following a cited specification: RFC 5321/5322 email syntax, RFC 3986 URIs, RFC 3339 and ISO 8601 dates with real calendar checks, RFC 9562 UUIDs, SemVer 2.0.0, ISO 3166, 4217 and 639-1 codes, IBAN MOD 97, ISBN and Luhn check digits, and more.
- Honest volatility: every built-in validator is `IMMUTABLE STRICT PARALLEL SAFE` because it reads no catalog or setting. Results do not change with `TimeZone`, `DateStyle` or collation.
- Documented boundaries: every validator states what it guarantees and what it does not. Validators check structure, never existence: a valid email address may be undeliverable.
- A format registry with ownership and a clear security model: registration is not granted to `PUBLIC`, built-in formats cannot be replaced, and custom validators run with the caller's privileges.
- `pg_dump` keeps registered formats (an extension configuration table).
- JSON Schema Draft 2020-12 in PL/pgSQL: every core, applicator, unevaluated and validation keyword, local `$ref`, `$anchor` and `$dynamicRef`, and format assertion through the registry, with an error report that gives instance and keyword locations. It passes the official JSON Schema Test Suite apart from documented exceptions (remote references, `\p{...}` in patterns, formats without a validator).
- A test suite of over 3,200 assertions, including published test vectors and the official JSON Schema Test Suite, run on Postgres 16, 17 and 18 in Docker, including pg_tle and `create extension` installs.

## Quick start

With the files on the server:

```sql
create extension pg_validate;
```

Or run the SQL file once in a database:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f pg_validate--0.0.1.sql
```

Then follow [Validate a table](docs/get-started/quickstart.md). [Install](docs/install.md) covers pg_tle, non-superuser installs and Docker. The extension always lives in the schema `validate`; call its functions as `validate.name(...)`.

## Validators

| Group | Validators |
| --- | --- |
| [Identifiers](docs/reference/identifiers.md) | `uuid`, `ulid`, `nanoid`, `slug`, `semver`, `git_sha` |
| [Internet](docs/reference/internet.md) | `email`, `url`, `uri`, `uri_reference`, `domain`, `hostname`, `ipv4`, `ipv6`, `mac`, `port` |
| [Dates and times](docs/reference/dates.md) | `iso8601`, `rfc3339`, `rfc3339_date`, `rfc3339_time`, `duration` |
| [International](docs/reference/international.md) | `e164`, `country_code`, `country_code_alpha3`, `currency_code`, `language_code` |
| [Developer formats](docs/reference/developer.md) | `base64`, `base64url`, `hex`, `json_pointer`, `cron` |
| [Financial](docs/reference/financial.md) | `iban`, `isbn`, `isbn10`, `isbn13`, `card_number`, `luhn` |
| [JSON Schema](docs/json-schema.md) | `json_schema`, `json_schema_errors` |

## Documentation

Start with the [documentation map](docs/README.md).

| Task | Guide |
| --- | --- |
| Install | [Install](docs/install.md) |
| Add constraints to a table | [Quickstart](docs/get-started/quickstart.md), [Use validators in constraints](docs/guides/constraints.md), [Canonical forms and normalizing input](docs/guides/normalization.md) |
| Register your own formats | [Custom formats](docs/registry.md) |
| Look up a validator | The [reference](docs/README.md#reference) |
| Understand an error | [Errors and limits](docs/errors-and-limits.md) |
| Validate `jsonb` documents | [JSON Schema](docs/json-schema.md) |
| See what is planned | [Roadmap](docs/roadmap.md) |

## Development scripts

The file `package.json` in this directory is the entry point for the folder. It is private and has no dependencies. Run each script with `npm run <name>` from `pg_validate/`.

| Script | What it does |
| --- | --- |
| `test` | Runs the test suite on a throwaway local Postgres. Needs the Postgres binaries. |
| `test:docker` | Runs the suite on Postgres 16, 17 and 18 with Docker, including pg_tle and `create extension`. |
| `test:all` | Runs `test`, then `test:docker`. |
| `docs:install` | Installs the site dependencies from the lock file (`npm ci` in `site/`). |
| `docs:sync` | Generates the site pages from `docs/`. |
| `docs:dev` | Starts the site locally with hot reload. |
| `docs:build` | Syncs, builds the site into `site/dist`, and checks links and content. |
| `docs:preview` | Serves the built site locally. |
| `docs:publish` | Deploys the site to Vercel production with `npx vercel deploy --prod`. Needs your Vercel login. |

The build output (`site/dist`) and the generated site pages are never committed. From the repository root, `make test.pg_validate` runs the tests.

### Deploy the docs on Vercel

Create the Vercel project with the Root Directory `pg_validate`. The install command, the build command and the output directory come from [`vercel.json`](vercel.json).

## Contributing

To run the tests, see [`test/README.md`](test/README.md). To run Postgres 16, 17 and 18 with pg_tle, see [`docker/README.md`](docker/README.md). Write documentation as described in [`STYLE.md`](STYLE.md). The documentation site (Astro + Starlight) is in [`site/`](site/README.md). The sources of the embedded code lists (ISO 3166-1, ISO 4217, ISO 639-1 and the IBAN registry), and the script that compares them with the extension, are in [`data/`](data/README.md).
