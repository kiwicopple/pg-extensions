# pg_permissions: Goals

Each goal is a spec file in [`test/spec/`](./test/spec/). A goal is met when its file passes. Write the test first, then the code. See [`test/README.md`](./test/README.md) for how to run things.

Status as of 2026-10-30, from `test/run.sh` (the extension) and `test/run.sh --impl prototypes/<file>.sql`:

## Functional goals

| # | Goal | PLAN.md | Spec | Extension | Prototype A | Prototype B | Prototype C |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G1 | Identity from JWT `sub`, falling back to `permissions.subject_id`; no `auth` schema | §3 | `01_identity` | ✅ 11/11 | ✅ 11/11 | ✅ 11/11 | ✅ 11/11 |
| G2 | Clients can't read or write permission data or act for other users | §3, §4 | `02_security` | ✅ 14/14 | ✅ 14/14 | ✅ 14/14 | ✅ 14/14 |
| G3 | `rbac` preset: app-wide roles, inheritance, `has_permission`, `has_role` | §6 | `10_rbac_app_wide` | ✅ 17/17 | ✅ 17/17 | ✅ 17/17 | ✅ 17/17 |
| G4 | `rbac` preset: tenant-scoped roles, `scopes_with_permission` | §6 | `11_rbac_tenant` | ✅ 13/13 | ✅ 13/13 | ✅ 13/13 | ✅ 13/13 |
| G5 | `rbac` preset: assign, unassign, create, drop, validation | §6 | `12_rbac_management` | ✅ 15/15 | ✅ 15/15 | ✅ 15/15 | ✅ 15/15 |
| G6 | RLS enforcement as `authenticated`; fast path is an InitPlan | §4, §6 | `20_rls` | ✅ 12/12 | ✅ 12/12 | ✅ 12/12 | ✅ 12/12 |
| G7 | Reference scenario: per-object relations, implied relations, groups | §5 | `<design>/30_zanzibar_reference` | see `d/` (own scenarios) | ✅ 14/14 | ✅ 14/14 | ✅ 14/14 |
| G8 | Nested groups, cycles, revocation, expiry, cleanup | §2, §3 | `<design>/31_zanzibar_groups` | see `d/` (own scenarios) | ✅ 11/11 | ✅ 11/11 | ✅ 11/11 |
| G9 | Graduation: add sharing to an rbac app without migrating | §6 | `<design>/40_graduation` | see `d/` (own scenarios) | ✅ 5/5 | ✅ 5/5 | ✅ 5/5 |
| G10 | Parent inheritance: org → folder → document, single fast-path RLS branch, cycles terminate | §10 | `<design>/50_parents` | see `d/` (own scenarios) | ✅ 13/13 | ✅ 13/13 | ✅ 13/13 |
| G11 | Public access (`user:*`); null subject is denied | §10 | `<design>/51_public` | see `d/` (own scenarios) | ✅ 7/7 | ✅ 7/7 | ✅ 7/7 |
| G12 | Forbid beats grants, including parent-derived ones | §10 | `<design>/52_forbid` | see `d/` (own scenarios) | ✅ 9/9 | ✅ 9/9 | ✅ 9/9 |
| G13 | Conditions: document status, expired grants | §10 | `<design>/53_conditions` | see `d/` (OpenFGA conditions: `d/37`-`d/39`, `d/63`-`d/64`, `d/90_usage_conditions`) | ✅ 6/6 | ✅ 6/6 | ✅ 6/6 |
| G14 | Installs as a non-superuser; via `pgtle.install_extension` if pg_tle is available | §10 | `03_tle_install` | ✅ 9/9 | ✅ 9/9 (pg_tle path on PG 16-18 in Docker) | ✅ 9/9 (same) | ✅ 9/9 (same) |
| | RLS policies don't run `scopes_with_permission` at plan time (call-count probe; each design also has `a/58`, `b/56`, `c/57` for its own list function: 3/3, 8/8, 3/3) | §4 | `22_no_plan_time_eval` | ✅ 6/6 | ✅ 6/6 | ✅ 6/6 | ✅ 6/6 |
| | Design-specific: B fails closed on forbids with missing inputs | | `b/54_fail_closed` | | | ✅ 16/16 | |
| | Design-specific: C materialized memberships stay correct | | `c/32_memberships` | | | | ✅ 31/31 |
| | Design-specific: C `who_can` reports public grants | | `c/54_who_can_public` | | | | ✅ 8/8 |
| | Design-specific: C tenant as a parent type | | `c/55_tenant_parent` | | | | ✅ 9/9 |
| | **Total** | | | **53/53 files, 3,337 assertions** | **18/18 files, 199 assertions** | **18/18 files, 189 assertions** | **21/21 files, 229 assertions** |

Zanzibar-level spec files (`30`+, in `test/spec/<design>/`) are per-design: each design has its own copy of the same scenario written in its native API, with the same assertions, so results compare one to one. G10–G14 are the v0.0.2 scenarios from PLAN.md §10.

The extension (`pg_permissions--0.0.1.sql`) is design D. It passes the engine-independent specs (G1-G6, G14 and the plan-time probe) like A, B and C. G7-G13 are per-design specs in the prototypes' native API; D's equivalents are the `d/` specs (the OpenFGA API, cycles, set-based walks, RBAC plus FGA in RLS, the API limits, an error-hint check of every raise site, model validation, OpenFGA's own consolidated suite, openfga/language's model validation cases, OpenFGA's conditions (its ABAC suite and in-house CEL specs), and the usage pages' examples), so those rows read "see `d/`". The extension's total is the whole local run: 53 files, 3,337 assertions.

## Performance goals

p95 budgets per workload, enforced by `bench/run.sh --check`. Budgets live in [`bench/budgets.tsv`](./bench/budgets.tsv). Session-1 budgets (small and large `rbac_*`, `share_*`, `write_*`) were set at about 2–3× Design A's measured p95. The rest, added on 2026-10-29, are 3× the p95 of the fastest engine on that workload, rounded up to a whole ms. Stress-shape budgets (`medium-deep`, `medium-wide`) are only in `budgets.tsv`. Full results, seed times, storage and the analysis are in [`bench/baselines/COMPARISON.md`](./bench/baselines/COMPARISON.md).

Large-scale p95 (ms) of the optimized engines (session 3), Postgres 18.6 in Docker, 2026-10-29 (`bench/baselines/pg18-docker-<design>-large-default-opt.md`; before/after, all versions and medium deep/wide in [`bench/baselines/OPTIMIZATIONS.md`](./bench/baselines/OPTIMIZATIONS.md)). ❌ = over the large budget. The pre-optimization numbers are in `bench/baselines/<design>-large-default.md` (local 16.4), `pg<NN>-docker-<design>-large-default.md` (Docker), [`COMPARISON.md`](./bench/baselines/COMPARISON.md) and [`VERSIONS.md`](./bench/baselines/VERSIONS.md).

| Workload | What it measures | Small budget | Medium budget | Large budget | A, large p95 | B, large p95 | C, large p95 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `rbac_check` | One `has_permission` call | 1 ms | 1 ms | 1 ms | 0.56 | 0.41 | 0.33 |
| `rbac_select_page` | First 50 documents through the RBAC policy | 2 ms | 2 ms | 3 ms | 1.44 | 1.1 | 0.91 |
| `rbac_select_count` | Count all visible documents (20k at large) | 2 ms | 2 ms | 3 ms | 1.07 | 0.99 | 0.93 |
| `rbac_update_one` | Update one document by id under RLS | 4 ms | 3 ms | 3 ms | 0.65 | 0.68 | 0.5 |
| `write_assign_role` | `assign_role` as admin (rolled back) | 1 ms | 1 ms | 1 ms | 0.23 | 0.22 | 0.24 |
| `share_list_objects` | All documents shared with a user via nested teams | 2 ms | 1 ms | 2 ms | 0.38 | 0.43 | 0.36 |
| `share_select_page` | First 50 documents through the two-branch policy (org roles or shares) | 5 ms | 3 ms | 6 ms | 1.35 | 1.29 | 1.27 |
| `write_share` | Share a document with a user (rolled back) | 1 ms | 1 ms | 1 ms | 0.23 | 0.21 | 0.25 |
| `parents_proj_select_page` | First 50 documents, parents via the `folder_id` column: shared ids or viewable folders | 2 ms | 3 ms | 4 ms | 2.62 | 1.55 | 1.57 |
| `parents_proj_select_count` | Count through the same two-arm projection policy | 2 ms | 3 ms | 9 ms | 14.66 ❌ | 12.36 ❌ | 9.97 ❌ |
| `parents_select_page` | First 50 documents through the single-branch parents policy (one call returns every visible id) | 4 ms | 16 ms | 32 ms | 66.27 ❌ | 16.82 | 6.55 |
| `parents_select_count` | Count through the single-branch parents policy | 4 ms | 14 ms | 70 ms | 92.44 ❌ | 27.61 | 15.53 |
| `write_nest_team` | Nest a 1,000-member team into a random team (rolled back) | 1 ms | 1 ms | 1 ms | 0.27 | 0.78 | 77.18 ❌ |
| `nest_check` | One check for a user who reaches a document only through a nested team | 1 ms | 1 ms | 2 ms | 0.48 | 0.42 | 0.45 |

Optimized, PG 18.6 Docker: at large A fails 3 (`parents_proj_select_count`, both single-branch `parents_*`), B fails 1 (`parents_proj_select_count`), C fails 2 (`parents_proj_select_count`, `write_nest_team`). At medium deep only C fails (`write_nest_team`). At medium wide, A passes everything, B fails `share_list_objects` and `write_nest_team`, and C fails `write_nest_team`. `parents_proj_select_count` at large fails for every engine at about 8 ms p50 because current minor releases read every heap page for that bitmap count, while 16.4 (where the budget was set) skipped them (VERSIONS.md, Calibration). Results on 16 and 17 are the same except for borderline B values (OPTIMIZATIONS.md, Budgets).

Before the optimizations, `bench/run.sh --check` at small scale (2026-10-29, not rerun since): A fails 4 (`parents_proj_select_page`, `parents_proj_select_count`, `parents_select_page`, `parents_select_count`), B fails 4 (`parents_select_page`, `parents_select_count`, `write_nest_team`, `nest_check`), C fails 1 (`write_nest_team`). Every engine passes every session-1 budget.

Pre-optimization, on Postgres 16.15, 17.11 and 18.6 in Docker ([`bench/baselines/VERSIONS.md`](./bench/baselines/VERSIONS.md)): the large budget results matched local 16.4, except that `parents_proj_select_count` was over or within 10% of its budget for every engine, and B passed `nest_check`.

The `share_*`, `parents*`, `write_share`, `write_nest_team` and `nest_check` workloads are per-design (`bench/designs/<design>/`, native API) over identical data (`bench/seed_shape.sql`); the budgets are shared. All three engines return identical visible-document checksums for every read policy at every scale and shape measured.

Large scale is 1M documents, 10k users, 100 orgs and 500 teams nested about 5 levels deep; medium is 100k documents, 5k users, 50 orgs, 200 teams. The table above is Postgres 18.6 in Docker (`cpus: 4`) on an Apple Silicon laptop with 4 pgbench clients, one run per configuration. The pre-optimization reference runs are local Postgres 16.4 ([`COMPARISON.md`](./bench/baselines/COMPARISON.md)) and Docker 16-18 ([`VERSIONS.md`](./bench/baselines/VERSIONS.md)). Writes roll back and run on a throwaway cluster with `fsync` off, so they're optimistic.

## Not yet covered by tests

- [x] pg_tle install path: `03_tle_install` runs `pgtle.install_extension` + `create extension` as a non-superuser on Postgres 16, 17 and 18 with pg_tle 1.5.3 (`docker/run-matrix.sh test`, 2026-10-29). Locally, without pg_tle, it still checks only the non-superuser install
