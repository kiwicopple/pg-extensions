# pg_permissions test suite

Tests are the spec. Each file in `spec/` is one goal from [`../GOALS.md`](../GOALS.md), written against the public API in [`../PLAN.md`](../PLAN.md), not against any one engine. The same files run against the extension or any prototype. Files in `spec/<design>/` (`a/`, `b/`, `c/`) cover the Zanzibar-level goals: each design has its own copy of the same scenario in its native API, with the same assertions.

No dependencies beyond Postgres binaries (`initdb`, `pg_ctl`, `psql`; `pgbench` for benchmarks). Postgres.app is detected automatically; otherwise set `PGBIN`.

## Running

From `pg_permissions/`:

```bash
./test/run.sh                                     # the extension: pg_permissions--0.0.1.sql
./test/run.sh --impl prototypes/a-tuple-core.sql  # a prototype
./test/run.sh rbac                                # only spec files whose name contains "rbac"
./test/run.sh --design b --impl my.sql            # force the design (a|b|c|none)
./test/run.sh -v                                  # print every assertion
```

Or from the repo root: `make test.pg_permissions` (and `IMPL=prototypes/a-tuple-core.sql make test.pg_permissions`).

`--design` picks which `spec/<design>/` directory runs on top of the shared files. By default it comes from the `--impl` file name: the letter before the first dash (`a-tuple-core.sql` is `a`, `b-policy-first.sql` is `b`, `c-compiled-model.sql` is `c`). Anything else, including the extension, is `none`, which runs only the shared files. Files from both directories are sorted by file name, the name filter applies to both, and design files are listed with their directory (`a/30_zanzibar_reference`).

By default the runner starts a throwaway Postgres in a temp directory. It listens on a Unix socket only, so it never conflicts with a server you have running, and it's deleted when the run ends. Each spec file gets a fresh database cloned from a template with the implementation installed. To use an existing server instead, pass `--external` and set `PGHOST`, `PGPORT`, `PGUSER` (the user must be able to create databases and roles).

The runner creates Supabase's client roles (`anon`, `authenticated`, `service_role`) so RLS tests run the way Supabase clients do.

## Layout

```
test/
  run.sh             runner: one fresh database per spec file, TAP parsing, summary
  lib/tap.sql        assertions (pgTAP-compatible names), installed in schema `tap`
  lib/cluster.sh     throwaway cluster helpers, shared with bench/run.sh
  fixtures/ids.sql   fixed UUIDs for the PLAN.md scenarios (psql variables :alice, :acme, ...)
  fixtures/rbac_roles.sql  the viewer/editor/admin roles from PLAN.md §6
  spec/              engine-independent files, one per goal
  spec/a/ b/ c/      per-design files: same scenarios, each design's native API
```

| Prefix | Area | Where |
| --- | --- | --- |
| `0x_` | Identity, security, install | `spec/` (shared) |
| `1x_` | `rbac` preset | `spec/` (shared) |
| `2x_` | RLS | `spec/` (shared) |
| `3x_`, `4x_`, `5x_` | Zanzibar-level API, graduation, v0.0.2 scenarios (PLAN.md §10) | `spec/<design>/` (per design) |

## Writing a test

A spec file is a psql script. Set up data as the superuser, declare a plan, assert, finish:

```sql
-- Goal: one line saying what this file proves (PLAN.md §n)
\ir ../fixtures/ids.sql
\ir ../fixtures/rbac_roles.sql
select permissions.assign_role(:'bob', 'editor');

select tap.plan(2);

select set_config('permissions.subject_id', :'bob', false);
select tap.is(permissions.has_permission('documents.edit'), true, 'editors can edit');

set role authenticated;           -- test as a client
select tap.throws_ok($$ select permissions.assign_role('x', 'admin') $$, '42501', 'clients cannot assign roles');
reset role;

select * from tap.finish();
```

Assertions (all in schema `tap`, same names as pgTAP):

| Function | Passes when |
| --- | --- |
| `plan(n)` | Declares how many assertions follow. Missing ones count as failures. |
| `ok(bool, desc)` | the value is true |
| `is(got, want, desc)` / `isnt(...)` | values are (not) distinct |
| `set_eq(got[], want[], desc)` | arrays hold the same elements, ignoring order and duplicates |
| `throws_ok(sql, sqlstate, desc)` | the SQL raises (sqlstate `null` = any error) |
| `lives_ok(sql, desc)` | the SQL doesn't raise |
| `pass(desc)` / `fail(desc)` | always / never |
| `finish()` | Prints a diagnostic if the plan and the count differ. |

Rules that keep shared tests engine-independent (per-design files in `spec/<design>/` use `\ir ../../fixtures/...` and their design's own API):

- Use only the public API from PLAN.md. Don't touch tables in the `permissions` schema; check privileges through the catalog instead (see `02_security.sql`).
- Use the fixture UUIDs as untyped literals (`:'alice'`), so they work with `text` and `uuid` implementations.
- Compare unordered results with `set_eq`.
- Test client behaviour with `set role authenticated`, not as the superuser (superusers bypass RLS).

## TDD workflow

1. Add or change a goal in `GOALS.md` and write its spec file. Run it and watch it fail.
2. Implement until it passes: `./test/run.sh <name>`.
3. Run everything, and the benchmark if the change touches a query path: `./bench/run.sh --check`.

A file passes only when every planned assertion ran and passed, and no SQL errors occurred.

### Checking the tests themselves

On 2026-10-28 the suite was checked against 8 deliberately broken copies of Prototype A ("mutants"): `has_permission` always true, setting beats JWT, all functions public, no role inheritance, scope ignored, expiry ignored, no group expansion, and `drop_role` ignoring heirs. Every mutant failed at least one spec file. When you add an engine feature, break it on purpose once and confirm a test goes red.

## Benchmarks

See `bench/run.sh --help`. In short:

```bash
./bench/run.sh --impl prototypes/a-tuple-core.sql                  # small: 10k docs, ~1.5 min
./bench/run.sh --impl prototypes/a-tuple-core.sql --scale large    # 1M docs, 10k users
./bench/run.sh --impl ... --check                                  # exit 1 if any p95 is over budget
```

It seeds tenant-scoped RBAC through the preset API (any engine), then, if `bench/designs/<design>/` exists, that design's per-document sharing with nested teams in its native API (`seed_sharing.sql`, `workloads/share_*.sql`, `workloads/write_share.sql`; skipped otherwise). The design is inferred from the `--impl` file name like in `test/run.sh`, or set with `--design a|b|c|none`. It runs each workload in `bench/workloads/` (and the design's `workloads/`) with pgbench as `authenticated` under RLS, reports p50/p95/tps against `bench/budgets.tsv`, prints a visible-row sanity check so a broken seed can't produce fast-but-empty numbers, and saves a markdown report with query plans to `bench/results/` (git-ignored). Reference runs worth keeping are copied to `bench/baselines/`, which is committed.
