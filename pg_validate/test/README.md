# pg_validate test suite

The tests are the specification of the extension. Each file in `spec/` is one goal, stated in its first comment line. The harness is the one `pg_permissions` uses, without designs. The JSON Schema benchmark is separate: `bench/run.sh`, see `docs/json-schema.md#performance`.

The tests need only the Postgres binaries: `initdb`, `pg_ctl`, `psql`, and `pg_dump` for one spec. The runner finds Postgres.app by itself; otherwise, set `PGBIN`. With Docker, nothing needs to be installed locally.

## Run the tests

From the `pg_validate/` directory:

```bash
./test/run.sh                     # the extension: pg_validate--0.0.1.sql
./test/run.sh registry            # only spec files whose name contains "registry"
./test/run.sh -v                  # print every assertion
./test/run.sh --external          # use the server from PGHOST, PGPORT, PGUSER
docker/run-matrix.sh              # Postgres 16, 17 and 18 in Docker
docker/run-matrix.sh --versions 18 -- -v 03_tle
```

From the root of the repository, run `make test.pg_validate`, or `npm run test` and `npm run test:docker` from `pg_validate/`.

By default, the runner starts a throwaway Postgres in a temporary directory, listening on a Unix socket only, and deletes it at the end. Each spec file gets a new database, cloned from a template that has the extension installed with `psql -f`. The runner creates Supabase's client roles `anon`, `authenticated` and `service_role`, so specs can test as clients.

`docker/run-matrix.sh` runs the suite against each version in turn, with pg_tle preloaded and `pg_validate.control` copied into the server's extension directory. Only there do `03_tle_install` (the `pgtle.install_extension` path) and `04_control_install` (`create extension`, `pg_dump` and restore) run every branch; elsewhere they pass with `SKIP` assertions.

A file passes only when every planned assertion ran and passed and no SQL error occurred.

## Layout

```
test/
  run.sh                 runner: one fresh database per spec file, TAP parsing, summary
  lib/tap.sql            assertions (pgTAP-compatible names), installed in schema `tap`
  lib/cluster.sh         throwaway cluster helpers
  fixtures/cases.sql     table-driven validator cases: temp table `cases` and pg_temp.call()
  fixtures/run_cases.sql one assertion per row of `cases`
  spec/                  the spec files
```

| Prefix | Area |
| --- | --- |
| `0x_` | Install, privileges, pg_tle, `create extension` and `pg_dump` |
| `1x_` | Validators, one file per reference page, with published test vectors |
| `2x_` | Registry: API, permissions and ownership, volatility markings, named JSON schemas (`23`) |
| `3x_` | `CHECK` constraints and domains |
| `4x_` | JSON Schema: `40`-`42` are generated from the official JSON Schema Test Suite, `43` is hand-written |
| `9x_` | The documentation's examples, as written (`90` quickstart, `91` custom formats and constraints guide, `92` JSON Schema, `93` canonical forms and normalization, `94` named JSON schemas) |

## The JSON Schema Test Suite

`json_schema/` holds the official [JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite) for Draft 2020-12 and turns it into specs:

```
json_schema/
  vendor.sh        fetches the suite at a pinned commit into upstream/ (run once; committed)
  upstream/        tests/draft2020-12/ verbatim, LICENSE (MIT), SOURCE (repository, commit, date)
  skip.tsv         cases that are not run, each with its reason
  generate.py      writes spec/40_json_schema_suite.sql (required), 41_..._optional.sql, 42_..._format.sql
  run_suite.sql    shared by the generated specs: one assertion per case, plus a per-file summary
```

After changing `skip.tsv` or vendoring a new commit, run `test/json_schema/generate.py` and commit the specs. The generator fails if a `skip.tsv` entry matches no case. Never change an expectation; skip a case with the reason instead, and keep the reasons in step with "Not supported" in `docs/json-schema.md`. Cases whose JSON Postgres cannot store (U+0000, unpaired surrogates) are skipped automatically.

Each case is one assertion; a skipped case is a passing `SKIP` assertion. `./test/run.sh -v 40_` prints the per-file summary as `#` lines:

```
# additionalProperties.json        21 passed    0 failed    0 skipped of   21
```

## Write a test

A validator spec inserts cases and runs them with one statement. Each row is one assertion:

```sql
-- Goal: one line saying what this file proves
\ir ../fixtures/cases.sql

insert into cases (fn, input, want, note) values
    ('slug', 'hello-world', true, null),
    ('slug', 'Hello', false, 'uppercase');

select tap.plan((select count(*)::int from cases) + 1);
\ir ../fixtures/run_cases.sql

select tap.is(validate.slug(null), null, 'null in, null out');

select * from tap.finish();
```

`pg_temp.call(fn, input)` calls `validate.<fn>(input)` directly, not through the registry. Take cases from the specification's own examples and test vectors where they exist, and name the source in `note`.

Other specs use the assertions in schema `tap`, with the same names as pgTAP:

| Function | Passes when |
| --- | --- |
| `plan(n)` | Declares how many assertions follow. An assertion that did not run counts as a failure. |
| `ok(bool, desc)` | The value is true. |
| `is(got, want, desc)` / `isnt(...)` | The values are (not) distinct. |
| `set_eq(got[], want[], desc)` | The arrays hold the same elements. |
| `throws_ok(sql, sqlstate, desc)` | The SQL raises an error with that SQLSTATE (`null` for any). |
| `lives_ok(sql, desc)` | The SQL does not raise an error. |
| `pass(desc)` / `fail(desc)` | Always passes / never passes. |
| `finish()` | Prints a diagnostic if the plan and the count differ. |

Rules:

- Test client behavior with `set role authenticated` (or another role), not as the superuser.
- Roles are cluster-wide: drop leftovers at the start of a spec and drop the roles at the end.
- A spec that needs the extension file reads the psql variable `:impl_path`, which the runner sets. Write `\i :impl_path`.
- When a guide's SQL changes, change the matching `9x_usage_*` spec in the same commit.
