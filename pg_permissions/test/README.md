# pg_permissions test suite

The tests are the spec. Each file in `spec/` is one goal from [`../research/goals.md`](../research/goals.md). This page also describes the benchmark harness in `bench/`.

The directory `spec/` has files for the earlier implementations in `prototypes/`. These files use the unprefixed `rbac` API of the prototypes (`create_role`, `has_permission`). The files run against each prototype. The directory `spec/<design>/` has files for one design, in the native API of that design:

- `a/`, `b/` and `c/` cover the Zanzibar-level goals. Each directory has one copy of the same scenario, with the same assertions.
- `d/` is the spec directory of the extension. It has its own copies of the shared files. The names and assertions are the same, but the functions have the `rbac_*` names.
- The runner skips `spec/*.sql` for design `d`. The file `d/04_api_naming` pins the rules for the names of the API.

The tests need only the Postgres binaries: `initdb`, `pg_ctl` and `psql`. The benchmarks also need `pgbench`. The runner finds Postgres.app by itself. Otherwise, set `PGBIN`.

## Run the tests

Run these commands from the `pg_permissions/` directory:

```bash
./test/run.sh                                     # the extension: pg_permissions--0.1.0.sql
./test/run.sh --impl prototypes/a-tuple-core.sql  # a prototype
./test/run.sh rbac                                # only spec files whose name contains "rbac"
./test/run.sh --design b --impl my.sql            # force the design (a|b|c|d|none)
./test/run.sh -v                                  # print every assertion
./test/run.sh --no-cedar-oracle                   # skip the generated Cedar oracle files
./test/run.sh --upgrade-from 0.0.1                # the whole suite on 0.0.1 plus the upgrade script
```

From the root of the repository, run `make test.pg_permissions`. To test a prototype, run `IMPL=prototypes/a-tuple-core.sql make test.pg_permissions`.

The option `--design` selects the directory `spec/<design>/` to run. For `a`, `b`, `c` and `none`, the runner also runs the shared files. For `d`, it runs only the `d/` files. By default, the design comes from the name of the `--impl` file:

- The letter before the first dash selects the design. `a-tuple-core.sql` is `a`, `b-policy-first.sql` is `b` and `c-compiled-model.sql` is `c`.
- A file named `pg_permissions--*.sql` (the extension file) is `d`.
- Any other name is `none`. The runner then runs only the shared files.

The runner sorts the files of both directories by file name. The name filter applies to both directories. The runner lists the files of a design with their directory, for example `a/30_zanzibar_reference`.

By default, the runner starts a throwaway Postgres in a temporary directory. The server listens on a Unix socket only, so it does not conflict with a server that you already run. The runner deletes it at the end of the run. Each spec file gets a new database. The runner clones the database from a template that has the implementation installed.

`--upgrade-from 0.0.1` builds the template from `pg_permissions--0.0.1.sql` and the upgrade script `pg_permissions--0.0.1--0.1.0.sql` instead of the 0.1.0 file, so every spec runs against an upgraded install. For the extension, the runner first runs `tools/sync-upgrade.sh --check` and counts it as a file (`tools/sync-upgrade --check`), so an upgrade script that misses a change to a marked section fails the run.

To use a server that already runs, pass `--external` and set `PGHOST`, `PGPORT` and `PGUSER`. The user must be able to create databases and roles.

To test on Postgres 16, 17 and 18 with pg_tle, use Docker. The command `docker/run-matrix.sh test` runs the extension on each version, one server at a time. Add `--designs ext,a,b,c` to run the prototypes too. See [`../docker/README.md`](../docker/README.md). This is the only way to run the `pgtle.install_extension` branch of `03_tle_install.sql`, the `pgtle.install_update_path` branch of `d/05_upgrade.sql`, and the non-superuser update and `pgtle.set_default_version` branch of `d/03_tle_install.sql`. Without pg_tle, these tests pass with `SKIP` assertions.

The runner creates the client roles of Supabase: `anon`, `authenticated` and `service_role`. RLS tests then run like Supabase clients.

A file passes only when each planned assertion ran and passed, and no SQL error occurred.

### The generated Cedar oracle files

The files `spec/d/7[0-7]_cedar_oracle*_NN.sql` come from Cedar's integration tests (`cedar/`): requests with JSON policies (entities stored, in the overlay, and with direct parents only), with Cedar text policies, and through template links, plus the parser on every text policy. They cover every case of the corpus, the extension types included, and are about 197 MB in 190 files, so Git ignores them (`spec/d/.gitignore`), and the runner writes them before each run of the extension with `python3 -I test/cedar/generate.py suite`. That takes about 9 seconds, and the files add about 140 seconds to a run (the whole suite takes about 165 seconds on Apple silicon). The runner skips the step when its name patterns select none of them, for example `./test/run.sh rbac`.

- `--no-cedar-oracle` runs everything else and skips these files.
- Without `python3`, the runner uses the files that are already there, and warns if there are none. `docker/run-matrix.sh test` writes them on the host, because its client containers have no Python.
- To write them by hand, or for another phase, see [`cedar/README.md`](cedar/README.md).

### The upgrade script

The code that is new in 0.1.0 sits in `pg_permissions--0.1.0.sql` between marker lines: the Cedar model between `-- >>> cedar section: begin` and `-- <<< cedar section: end`, and the new `delete_subject` in the `cleanup` section. The upgrade script `pg_permissions--0.0.1--0.1.0.sql` has the same markers. Edit the install file only, then copy the section into the upgrade script:

```bash
./tools/sync-upgrade.sh           # rewrite the marked regions of the upgrade script
./tools/sync-upgrade.sh --check   # exit 1 if the upgrade script is out of date
```

`spec/d/05_upgrade.sql` then checks that 0.0.1 plus the upgrade script equals a fresh 0.1.0 install.

## Layout

```
test/
  run.sh             runner: one fresh database per spec file, TAP parsing, summary
  lib/tap.sql        assertions (pgTAP-compatible names), installed in schema `tap`
  lib/cluster.sh     throwaway cluster helpers, shared with bench/run.sh
  fixtures/ids.sql   fixed UUIDs for the plan scenarios (psql variables :alice, :acme, ...)
  fixtures/rbac_roles.sql  the viewer/editor/admin roles (the API of the prototypes)
  fixtures/d/rbac_roles.sql  the same roles through the extension's rbac_create_role
  fixtures/d/cedar.sql       helpers for the hand-written Cedar specs (cedar_t.eval, cedar_t.authz, ...)
  spec/              shared files, one per goal, in the rbac API of the prototypes (not run for d)
  spec/a/ b/ c/ d/   per-design files: same scenarios, each design's native API (d/ is the extension,
                     with its own copies of the shared files)
  fga/               OpenFGA's consolidated suite: vendor.sh, generate.py -> spec/d/6[01]_fga_oracle_*
  fga_lang/          openfga/language's model validation cases: vendor.sh, generate.py -> spec/d/62_fga_lang_oracle
  fga_abac/          OpenFGA's ABAC (conditions) suite: vendor.sh, generate.py --suite -> spec/d/6[34]_fga_abac_*
                     (without --suite: fga_abac/spec/, not run), probe.sh (the server's answers, P1-P44)
  cedar/             Cedar's integration tests: vendor.sh, generate.py suite -> spec/d/7[0-7]_cedar_oracle_*
                     (generated by run.sh, not committed)
```

The scenarios and the work plan are in [`../research/plan.md`](../research/plan.md).

| Prefix | Area | Where |
| --- | --- | --- |
| `0x_` | Identity, security, install, names of the API (`d/04`), upgrade from 0.0.1 (`d/05`) | `spec/` (shared) and `spec/d/` |
| `1x_` | `rbac` preset | `spec/` (shared) and `spec/d/` |
| `2x_` | RLS | `spec/` (shared) and `spec/d/` |
| `3x_`, `4x_`, `5x_` | Zanzibar-level API, graduation, v0.0.2 scenarios (see `research/plan.md`) | `spec/<design>/` (per design) |
| `5x_cedar_` | Cedar: API, errors and limits, hierarchy, evaluator, overlay, text parser, templates (`research/plan-cedar.md`) | `spec/d/` |
| `6x_` | OpenFGA oracles (generated, committed) | `spec/d/` |
| `7x_cedar_oracle` | Cedar oracle (generated before each run, not committed) | `spec/d/` |

## Write a test

A spec file is a psql script. Create the data as the superuser, declare a plan, assert, and finish:

```sql
-- Goal: one line saying what this file proves (research/plan.md)
\ir ../../fixtures/ids.sql
\ir ../../fixtures/d/rbac_roles.sql
select permissions.rbac_assign_role(user_id => :'bob', role => 'editor');

select tap.plan(2);

select set_config('permissions.subject_id', :'bob', false);
select tap.is(permissions.rbac_has_permission(permission => 'documents.edit'), true, 'editors can edit');

set role authenticated;           -- test as a client
select tap.throws_ok($$ select permissions.rbac_assign_role(user_id => 'x', role => 'admin') $$, '42501', 'clients cannot assign roles');
reset role;

select * from tap.finish();
```

This file is in `spec/d/`. A shared file for the prototypes uses `\ir ../fixtures/...` and the unprefixed names.

All assertions are in the schema `tap`, with the same names as pgTAP:

| Function | Passes when |
| --- | --- |
| `plan(n)` | Declares how many assertions follow. An assertion that did not run counts as a failure. |
| `ok(bool, desc)` | The value is true. |
| `is(got, want, desc)` / `isnt(...)` | The values are (not) distinct. |
| `set_eq(got[], want[], desc)` | The arrays hold the same elements. The order and duplicates do not matter. |
| `throws_ok(sql, sqlstate, desc)` | The SQL raises an error. A sqlstate of `null` means any error. |
| `lives_ok(sql, desc)` | The SQL does not raise an error. |
| `pass(desc)` / `fail(desc)` | Always passes / never passes. |
| `finish()` | Prints a diagnostic if the plan and the count differ. |

These rules keep the shared tests independent of the design. Files in `spec/<design>/` use `\ir ../../fixtures/...` and the API of their design. The copies of the shared files in `spec/d/` follow the same rules.

- Use only the public API from the plan. Do not touch the tables in the `permissions` schema. To check privileges, read the catalog (see `02_security.sql`).
- Use the fixture UUIDs as untyped literals (`:'alice'`). They then work with `text` and `uuid` implementations.
- Compare unordered results with `set_eq`.
- Test the behavior of clients with `set role authenticated`, not as the superuser. Superusers bypass RLS.
- A spec can need the implementation file. For example, `03_tle_install.sql` installs the file into its own scratch databases as a non-superuser. The spec reads the psql variable `:impl_path`. The runner sets it with `-v impl_path=...` to the absolute path of `--impl`. Write `\i :impl_path` (without quotes).

## TDD workflow

1. Add or change a goal in [`../research/goals.md`](../research/goals.md). Write its spec file. Run the file and make sure it fails.
2. Change the implementation until the file passes. Run `./test/run.sh <name>`.
3. Run all the tests. If the change touches a query path, also run the benchmark: `./bench/run.sh --check`.

### Check the tests

On 2026-10-28, the suite ran against 8 broken copies of prototype A ("mutants"). Each mutant had one fault:

- `has_permission` is always true.
- The configuration parameter beats the JWT.
- All functions are public.
- There is no role inheritance.
- The function ignores the scope.
- The function ignores the expiry.
- There is no group expansion.
- `drop_role` ignores heirs.

Each mutant failed at least one spec file. When you add a design feature, break it on purpose once. Make sure that a test fails.

## Benchmarks

For all options, run `bench/run.sh --help`. These are the main commands:

```bash
./bench/run.sh                                                     # the extension, small: 10k docs, ~2.5 min
./bench/run.sh --scale medium                                      # 100k docs, 5k users
./bench/run.sh --scale large                                       # 1M docs, 10k users
./bench/run.sh --impl prototypes/a-tuple-core.sql                  # a prototype, for comparison
./bench/run.sh --impl ... --shape deep                             # teams nested 9 deep
./bench/run.sh --impl ... --shape wide                             # 50 teams per user, 50 shares per team
./bench/run.sh --impl ... --only parents,nest_check                # rerun some workloads
./bench/run.sh --impl ... --check                                  # exit 1 if any p95 is over budget
```

A run has five phases. Each phase loads a seed and measures the time. Then it runs `VACUUM FULL ANALYZE` on the tables that have rows. It records the size and the row count of each table in the schema `permissions`. It also computes a checksum of what sample users see. Then it runs the workloads of the phase.

| Phase | Seed | Workloads |
| --- | --- | --- |
| rbac | `seed_rbac.sql`: tenant-scoped roles through the preset API of the prototypes, or `designs/<design>/seed_rbac.sql` when the design has one (d: the same statements with the `rbac_` names) | `rbac_*`, `write_assign_role` |
| `sharing` | `designs/<design>/seed_sharing.sql`: shares of single documents with nested teams, native API | `share_list_objects`, `share_select_page`, `write_share` |
| parents_proj | `designs/<design>/seed_parents.sql`: about 10 folders per org, org roles inherited by folders, every 5th user a folder viewer. Documents point at folders only through the app column `documents.folder_id`. Two-arm projection policy: `id = any(<documents shared with me>) or folder_id = any(<folders I can view>)` | `parents_proj_select_page`, `parents_proj_select_count` |
| parents | `designs/<design>/seed_parent_docs.sql`: a parent link per document in the tables of the design. Single-branch policy: one call returns each visible document ID | `parents_select_page`, `parents_select_count` |
| `nesting` | `designs/<design>/seed_nest.sql`, loaded after `write_nest_team`: a team of 1,000 members nested in the deepest team for good | `write_nest_team` (rolled back), `nest_check` (a check that needs the nested team) |
| `rowcheck` (design `e` only) | `designs/e/seed_rowcheck.sql`: one select policy that calls `cedar_is_authorized_current` on every row, with the row's org as a resource attribute. Its visible sets must equal the parents phase's | `row_select_page` |

Both parents policies have no `org_id` branch, and they see the same documents. The projection shape measures the design on a few folder IDs. The single-branch shape measures the design on each visible document. The seed time and the storage of the parents phase include the per-document link that this shape needs.

The runner infers the design from the name of the `--impl` file, as `test/run.sh` does. You can also set it with `--design a|b|c|d|e|none`. The extension file is design `d`. Design `e` is the extension's Cedar model: run the extension file with `--design e` (`docker/run-matrix.sh bench --designs e`). Its seeds write the same facts as Cedar entities and template links, and its results are in [`../research/benchmarks/cedar.md`](../research/benchmarks/cedar.md). The runner skips a phase when the design has no files for it (phases 2 to 5, and the design-specific phases).

The workloads in `bench/workloads/` are shared. A file of the same name in the `workloads/` directory of the design replaces a shared file. Design `d` has its own `rbac_check` and `write_assign_role`, with the `rbac_` names. The other workloads are in the `workloads/` directory of the design. Each workload runs with pgbench as `authenticated`, under RLS. Writes roll back, so a faster design does not end up with more rows in later phases.

**Same data for every design.** The file `bench/seed_shape.sql` generates the teams, memberships, shares, folders and folder viewers as integer tables in the schema `bench`. The seed of each design reads these tables and writes the same facts through its own API. The option `--shape` changes the data:

- `default`: one team per user, 5 shares per team, a team tree with 4 children per team.
- `deep`: teams in chains 9 deep, with users in the leaf teams. `write_nest_team` then reaches depth 10, the most that B and C accept.
- `wide`: 4 times the teams, with each user in 50 teams and 50 shares per team.

**Equivalence check.** After each seed, the report lists how many documents RLS lets sample users see. It also lists an md5 of the sorted IDs. A broken seed cannot then produce fast but empty numbers.

Complete runs save these values to `bench/results/equivalence-<scale>-<shape>-<design>.tsv`. They compare the values with the latest files of the other designs. The same data and correct designs give identical checksums. A mismatch names the policy and the users.

The report also shows p50, p95 and tps against `bench/budgets.tsv`. A workload without a budget never fails `--check`. The options `--shape deep` and `--shape wide` look up keys such as `medium-wide`, which have no budget yet. The report also shows seed times, storage for each table and query plans. The runner saves it as markdown in `bench/results/`, which Git does not track. Copy the reference runs that you want to keep to `bench/baselines/`, which Git tracks.

Complete runs (not `--only`) also write `bench/baselines/data/<run_id>.json` through `bench/report_to_json.sh`. The docs site uses this file for its charts. The schema is in [`../bench/baselines/data/README.md`](../bench/baselines/data/README.md). The `run_id` is `pg<major>-<environment>-<design>-<scale>-<shape>`. A new run replaces the previous run with the same settings. The option `--tag NAME` appends `-NAME` for experiments.

`BENCH_ENVIRONMENT` is `local` by default. `docker/run-matrix.sh` sets it to `docker`. `BENCH_HOST` and `BENCH_ENVIRONMENT` fill the environment and host fields. To convert saved reports, run `bench/report_to_json.sh REPORT.md...`.

The command `docker/run-matrix.sh bench -- <bench/run.sh options>` runs the benchmark on Postgres 16, 17 and 18 for each design. It runs one server at a time. See [`../docker/README.md`](../docker/README.md).
