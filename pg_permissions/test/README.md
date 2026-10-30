# pg_permissions test suite

Tests are the spec. Each file in `spec/` is one goal from [`../GOALS.md`](../GOALS.md), written against the `rbac` preset API in [`../PLAN.md`](../PLAN.md) §6 that the prototypes share (unprefixed `create_role`, `has_permission`, ...); they run against every prototype. Files in `spec/<design>/` use that design's native API: `a/`, `b/` and `c/` cover the Zanzibar-level goals, one copy of the same scenario per prototype with the same assertions, and `d/` is the extension's own spec directory (the extension is design D). The extension renamed the preset (`rbac_create_role`, `rbac_has_permission`, ...; [`../DECISION.md`](../DECISION.md), "API naming (session 5)"), so `d/` holds its own copies of the shared files, with the same names and assertions and the new function names, and the runner skips `spec/*.sql` for design `d`. `d/04_api_naming` pins the naming rules.

No dependencies beyond Postgres binaries (`initdb`, `pg_ctl`, `psql`; `pgbench` for benchmarks). Postgres.app is detected automatically; otherwise set `PGBIN`.

## Running

From `pg_permissions/`:

```bash
./test/run.sh                                     # the extension: pg_permissions--0.0.1.sql
./test/run.sh --impl prototypes/a-tuple-core.sql  # a prototype
./test/run.sh rbac                                # only spec files whose name contains "rbac"
./test/run.sh --design b --impl my.sql            # force the design (a|b|c|d|none)
./test/run.sh -v                                  # print every assertion
```

Or from the repo root: `make test.pg_permissions` (and `IMPL=prototypes/a-tuple-core.sql make test.pg_permissions` for a prototype).

`--design` picks which `spec/<design>/` directory runs: on top of the shared files for `a`, `b`, `c` and `none`, instead of them for `d`. By default it comes from the `--impl` file name: the letter before the first dash (`a-tuple-core.sql` is `a`, `b-policy-first.sql` is `b`, `c-compiled-model.sql` is `c`), and it is `d` for the extension file (`pg_permissions--*.sql`). Anything else is `none`, which runs only the shared files. Files from both directories are sorted by file name, the name filter applies to both, and design files are listed with their directory (`a/30_zanzibar_reference`).

By default the runner starts a throwaway Postgres in a temp directory. It listens on a Unix socket only, so it never conflicts with a server you have running, and it's deleted when the run ends. Each spec file gets a fresh database cloned from a template with the implementation installed. To use an existing server instead, pass `--external` and set `PGHOST`, `PGPORT`, `PGUSER` (the user must be able to create databases and roles).

To run against Postgres 16, 17 and 18 with pg_tle installed, use Docker: `docker/run-matrix.sh test` runs the extension on each version (`--designs ext,a,b,c` adds the prototypes), one server at a time (see [`../docker/README.md`](../docker/README.md)). That is the only way the `pgtle.install_extension` branch of `03_tle_install.sql` runs; without pg_tle it passes with a `SKIP` assertion.

The runner creates Supabase's client roles (`anon`, `authenticated`, `service_role`) so RLS tests run the way Supabase clients do.

## Layout

```
test/
  run.sh             runner: one fresh database per spec file, TAP parsing, summary
  lib/tap.sql        assertions (pgTAP-compatible names), installed in schema `tap`
  lib/cluster.sh     throwaway cluster helpers, shared with bench/run.sh
  fixtures/ids.sql   fixed UUIDs for the PLAN.md scenarios (psql variables :alice, :acme, ...)
  fixtures/rbac_roles.sql  the viewer/editor/admin roles from PLAN.md §6 (the prototypes' API)
  fixtures/d/rbac_roles.sql  the same roles through the extension's rbac_create_role
  spec/              shared files, one per goal, in the prototypes' rbac API (not run for d)
  spec/a/ b/ c/ d/   per-design files: same scenarios, each design's native API (d/ is the extension,
                     with its own copies of the shared files)
  fga/               OpenFGA's consolidated suite: vendor.sh, generate.py -> spec/d/6[01]_fga_oracle_*
  fga_lang/          openfga/language's model validation cases: vendor.sh, generate.py -> spec/d/62_fga_lang_oracle
  fga_abac/          OpenFGA's ABAC (conditions) suite: vendor.sh, generate.py --suite -> spec/d/6[34]_fga_abac_*
                     (without --suite: fga_abac/spec/, not run), probe.sh (the server's answers, P1-P44)
```

| Prefix | Area | Where |
| --- | --- | --- |
| `0x_` | Identity, security, install, API naming (`d/04`) | `spec/` (shared) and `spec/d/` |
| `1x_` | `rbac` preset | `spec/` (shared) and `spec/d/` |
| `2x_` | RLS | `spec/` (shared) and `spec/d/` |
| `3x_`, `4x_`, `5x_` | Zanzibar-level API, graduation, v0.0.2 scenarios (PLAN.md §10) | `spec/<design>/` (per design) |

## Writing a test

A spec file is a psql script. Set up data as the superuser, declare a plan, assert, finish:

```sql
-- Goal: one line saying what this file proves (PLAN.md §n)
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

(That is a file in `spec/d/`; a shared file for the prototypes uses `\ir ../fixtures/...` and the unprefixed names.)

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

Rules that keep shared tests engine-independent (per-design files in `spec/<design>/` use `\ir ../../fixtures/...` and their design's own API; the extension's copies of the shared files follow the same rules):

- Use only the public API from PLAN.md. Don't touch tables in the `permissions` schema; check privileges through the catalog instead (see `02_security.sql`).
- Use the fixture UUIDs as untyped literals (`:'alice'`), so they work with `text` and `uuid` implementations.
- Compare unordered results with `set_eq`.
- Test client behaviour with `set role authenticated`, not as the superuser (superusers bypass RLS).
- A spec that needs the implementation file itself (`03_tle_install.sql` installs it into its own scratch databases as a non-superuser) reads the psql variable `:impl_path`, which the runner sets with `-v impl_path=...` to the absolute path of `--impl`. Use `\i :impl_path` (unquoted).

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
./bench/run.sh                                                     # the extension, small: 10k docs, ~2.5 min
./bench/run.sh --scale medium                                      # 100k docs, 5k users
./bench/run.sh --scale large                                       # 1M docs, 10k users
./bench/run.sh --impl prototypes/a-tuple-core.sql                  # a prototype, for comparison
./bench/run.sh --impl ... --shape deep                             # teams nested 9 deep
./bench/run.sh --impl ... --shape wide                             # 50 teams per user, 50 shares per team
./bench/run.sh --impl ... --only parents,nest_check                # rerun some workloads
./bench/run.sh --impl ... --check                                  # exit 1 if any p95 is over budget
```

A run has five phases. Each loads a seed, times it, runs `VACUUM FULL ANALYZE` on the non-empty tables, records the size and row count of every table in schema `permissions`, and checksums what sample users see. Then it runs the phase's workloads:

| Phase | Seed | Workloads |
| --- | --- | --- |
| rbac | `seed_rbac.sql`: tenant-scoped roles through the prototypes' preset API, or `designs/<design>/seed_rbac.sql` when the design has one (d: the same statements with the `rbac_` names) | `rbac_*`, `write_assign_role` |
| sharing | `designs/<design>/seed_sharing.sql`: per-document sharing with nested teams, native API | `share_list_objects`, `share_select_page`, `write_share` |
| parents_proj | `designs/<design>/seed_parents.sql`: about 10 folders per org, org roles inherited by folders, every 5th user a folder viewer. Documents point at folders only through the app column `documents.folder_id`. Two-arm projection policy: `id = any(<documents shared with me>) or folder_id = any(<folders I can view>)` | `parents_proj_select_page`, `parents_proj_select_count` |
| parents | `designs/<design>/seed_parent_docs.sql`: a parent link per document in the engine's tables. Single-branch policy: one engine call returns every visible document id | `parents_select_page`, `parents_select_count` |
| nesting | `designs/<design>/seed_nest.sql`, loaded after `write_nest_team`: a 1,000-member team nested in the deepest team for good | `write_nest_team` (rolled back), `nest_check` (a check that needs the nesting) |

Both parents policies have no `org_id` branch, and they see the same documents. The projection shape measures the engine on a few folder ids; the single-branch shape measures it on every visible document, and the per-document link it needs is counted in the parents seed time and storage.

The design is inferred from the `--impl` file name like in `test/run.sh`, or set with `--design a|b|c|d|none` (the extension file is design `d`). Phases 2 to 5 are skipped when the design has no files for them. Workloads in `bench/workloads/` are shared, and a file of the same name in the design's `workloads/` replaces one (d has its own `rbac_check` and `write_assign_role`, with the `rbac_` names); the rest are in the design's `workloads/`. Each runs with pgbench as `authenticated` under RLS. Writes roll back, so a faster engine doesn't end up with more rows in later phases.

**Same data for every engine.** `bench/seed_shape.sql` generates the teams, memberships, shares, folders and folder viewers as integer tables in schema `bench`. Each design's seed reads them and writes the same facts through its own API. `--shape` changes them: `default` (one team per user, 5 shares per team, 4-ary team tree), `deep` (teams in chains 9 deep, users in the leaf teams, so `write_nest_team` reaches depth 10, the most B and C accept), `wide` (4x the teams, each user in 50, 50 shares per team).

**Equivalence check.** After each seed, the report lists for sample users how many documents RLS lets them see and an md5 of the sorted ids, so a broken seed can't produce fast-but-empty numbers. Complete runs save these to `bench/results/equivalence-<scale>-<shape>-<design>.tsv` and compare them with the other designs' latest files: the same data and correct engines give identical checksums, and a mismatch names the policy and users.

The report also shows p50/p95/tps against `bench/budgets.tsv` (workloads without a budget never fail `--check`; `--shape deep|wide` look up keys like `medium-wide`, which have none yet), seed times, storage per table and query plans. It's saved as markdown to `bench/results/` (git-ignored). Reference runs worth keeping are copied to `bench/baselines/`, which is committed.

Complete runs (not `--only`) also write `bench/baselines/data/<run_id>.json` through `bench/report_to_json.sh`, for the docs site's charts; the schema is in [`../bench/baselines/data/README.md`](../bench/baselines/data/README.md). The run_id is `pg<major>-<environment>-<design>-<scale>-<shape>`, so a new run replaces the previous one with the same settings; `--tag NAME` appends `-NAME` for experiments. `BENCH_ENVIRONMENT` (`local` by default, `docker` from `docker/run-matrix.sh`) and `BENCH_HOST` fill the environment and host fields. `bench/report_to_json.sh REPORT.md...` converts existing reports.

`docker/run-matrix.sh bench -- <bench/run.sh options>` runs the benchmark on Postgres 16, 17 and 18 for each design, strictly one at a time (see [`../docker/README.md`](../docker/README.md)).
