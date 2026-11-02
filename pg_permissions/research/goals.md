# pg_permissions: Goals

Each goal is a spec file in [`../test/spec/`](../test/spec/). A goal is met when its file passes. Write the test first, then the code. See [`../test/README.md`](../test/README.md) to learn how to run the tests.

> Status: this page is a historical record. The table counts are from 2026-10-30, from `test/run.sh` (the extension) and `test/run.sh --impl prototypes/<file>.sql`. The extension is design D in `pg_permissions--0.0.1.sql`. Its suite now has 56 spec files and 3,638 assertions, and it passes on PG 16, 17 and 18. The count of 53 files and 3,337 assertions below is the count at the last update of the table.
>
> The performance table has a budget that is now different. Phase 6 changed the large budget of `parents_proj_select_count` from 9 ms to 20 ms (see [`./decision.md`](./decision.md), "Budget re-baseline").

## Functional goals

In the table, "pass" means that the spec file passes, with the count of passed assertions over the total.

| # | Goal | Plan section ([`plan.md`](./plan.md)) | Spec | Extension | Prototype A | Prototype B | Prototype C |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G1 | Identity comes from the JWT `sub` claim, or from `permissions.subject_id` when there is no claim. No `auth` schema. | 3 | `01_identity` | pass 11/11 | pass 11/11 | pass 11/11 | pass 11/11 |
| G2 | Clients cannot read or write permission data. Clients cannot act for other users. | 3, 4 | `02_security` | pass 14/14 | pass 14/14 | pass 14/14 | pass 14/14 |
| G3 | `rbac` preset: app-wide roles, inheritance, `has_permission`, `has_role` | 6 | `10_rbac_app_wide` | pass 17/17 | pass 17/17 | pass 17/17 | pass 17/17 |
| G4 | `rbac` preset: tenant-scoped roles, `scopes_with_permission` | 6 | `11_rbac_tenant` | pass 13/13 | pass 13/13 | pass 13/13 | pass 13/13 |
| G5 | `rbac` preset: assign, unassign, create, drop, validation | 6 | `12_rbac_management` | pass 15/15 | pass 15/15 | pass 15/15 | pass 15/15 |
| G6 | RLS enforcement as `authenticated`. The fast path is an InitPlan. | 4, 6 | `20_rls` | pass 12/12 | pass 12/12 | pass 12/12 | pass 12/12 |
| G7 | Reference scenario: per-object relations, implied relations, groups | 5 | `<design>/30_zanzibar_reference` | see `d/` (own scenarios) | pass 14/14 | pass 14/14 | pass 14/14 |
| G8 | Nested groups, cycles, revocation, expiry, cleanup | 2, 3 | `<design>/31_zanzibar_groups` | see `d/` (own scenarios) | pass 11/11 | pass 11/11 | pass 11/11 |
| G9 | Graduation: add sharing to an `rbac` app without a migration | 6 | `<design>/40_graduation` | see `d/` (own scenarios) | pass 5/5 | pass 5/5 | pass 5/5 |
| G10 | Parent inheritance: org, folder, document. One fast-path RLS branch. Parent cycles end. | 10 | `<design>/50_parents` | see `d/` (own scenarios) | pass 13/13 | pass 13/13 | pass 13/13 |
| G11 | Public access (`user:*`). A null subject gets a deny. | 10 | `<design>/51_public` | see `d/` (own scenarios) | pass 7/7 | pass 7/7 | pass 7/7 |
| G12 | A forbid wins over grants, also over grants that come from a parent | 10 | `<design>/52_forbid` | see `d/` (own scenarios) | pass 9/9 | pass 9/9 | pass 9/9 |
| G13 | Conditions: document status, expired grants | 10 | `<design>/53_conditions` | see `d/` (OpenFGA conditions: `d/37` to `d/39`, `d/63` to `d/64`, `d/90_usage_conditions`) | pass 6/6 | pass 6/6 | pass 6/6 |
| G14 | The extension installs as a non-superuser. It installs through `pgtle.install_extension` when pg_tle is available. | 10 | `03_tle_install` | pass 9/9 | pass 9/9 (pg_tle path on PG 16 to 18 in Docker) | pass 9/9 (same) | pass 9/9 (same) |
| | RLS policies do not run `scopes_with_permission` at plan time. The test is a call-count probe. Each design also has a probe for its own list function: `a/58` (3/3), `b/56` (8/8) and `c/57` (3/3). | 4 | `22_no_plan_time_eval` | pass 6/6 | pass 6/6 | pass 6/6 | pass 6/6 |
| | Design-specific: B fails closed on a forbid when an input is not present | | `b/54_fail_closed` | | | pass 16/16 | |
| | Design-specific: the materialized memberships of C stay correct | | `c/32_memberships` | | | | pass 31/31 |
| | Design-specific: `who_can` of C reports public grants | | `c/54_who_can_public` | | | | pass 8/8 |
| | Design-specific: C uses a tenant as a parent type | | `c/55_tenant_parent` | | | | pass 9/9 |
| | **Total** | | | **53/53 files, 3,337 assertions** | **18/18 files, 199 assertions** | **18/18 files, 189 assertions** | **21/21 files, 229 assertions** |

The Zanzibar-level spec files (`30` and higher, in `test/spec/<design>/`) belong to one design each. Each design has its own copy of the same scenario, written in its native API, with the same assertions. So the results compare one to one. G10 to G14 are the v0.0.2 scenarios from [`plan.md`](./plan.md), section 10.

The extension (`pg_permissions--0.0.1.sql`) is design D. It passes the specs that do not depend on a design (G1 to G6, G14 and the plan-time probe), like A, B and C. G7 to G13 are per-design specs in the native API of the prototypes. The `d/` specs are the equivalents for D. They cover these areas:

- the OpenFGA API
- cycles
- set-based walks
- RBAC plus FGA in RLS
- the API limits
- an error-hint check of every raise site
- model validation
- the consolidated test suite of OpenFGA
- the model validation cases of openfga/language
- the conditions of OpenFGA (its ABAC suite and the in-house CEL specs)
- the examples in the user docs in [`../docs/`](../docs/)

So the D cells read "see `d/`". The total for the extension is the whole local run at the time of the table: 53 files, 3,337 assertions.

## Performance goals

Each workload has a p95 budget. The command `bench/run.sh --check` enforces the budgets. They are in [`../bench/budgets.tsv`](../bench/budgets.tsv). The session 1 budgets are the small and large `rbac_*`, `share_*` and `write_*` budgets. They are about 2 to 3 times the p95 that the benchmark measured for design A.

The other budgets are new on 2026-10-29. Each of them is 3 times the p95 of the fastest design for that workload, rounded up to a whole ms. The budgets of the stress shapes (`medium-deep` and `medium-wide`) are only in `budgets.tsv`. [`./benchmarks/COMPARISON.md`](./benchmarks/COMPARISON.md) has the full results, the seed times, the storage and the analysis.

The next table shows the large-scale p95 (ms) of the optimized designs (session 3). The runs used Postgres 18.6 in Docker, on 2026-10-29. The reports are `bench/baselines/pg18-docker-<design>-large-default-opt.md`. [`./benchmarks/OPTIMIZATIONS.md`](./benchmarks/OPTIMIZATIONS.md) has the numbers from before and after the optimization.

It also has all versions and the medium deep and wide shapes. "over" means that the value is over the large budget. The numbers from before the optimization are in these files:

- `bench/baselines/<design>-large-default.md` (local 16.4)
- `bench/baselines/pg<NN>-docker-<design>-large-default.md` (Docker)
- [`COMPARISON.md`](./benchmarks/COMPARISON.md)
- [`VERSIONS.md`](./benchmarks/VERSIONS.md)

| Workload | What it measures | Small budget | Medium budget | Large budget | A, large p95 | B, large p95 | C, large p95 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `rbac_check` | One call of `has_permission` | 1 ms | 1 ms | 1 ms | 0.56 | 0.41 | 0.33 |
| `rbac_select_page` | The first 50 documents through the RBAC policy | 2 ms | 2 ms | 3 ms | 1.44 | 1.1 | 0.91 |
| `rbac_select_count` | Count of all visible documents (20k at large) | 2 ms | 2 ms | 3 ms | 1.07 | 0.99 | 0.93 |
| `rbac_update_one` | Update of one document by id under RLS | 4 ms | 3 ms | 3 ms | 0.65 | 0.68 | 0.5 |
| `write_assign_role` | `assign_role` as admin (rolled back) | 1 ms | 1 ms | 1 ms | 0.23 | 0.22 | 0.24 |
| `share_list_objects` | All documents that nested teams share with a user | 2 ms | 1 ms | 2 ms | 0.38 | 0.43 | 0.36 |
| `share_select_page` | The first 50 documents through the two-branch policy (org roles or shares) | 5 ms | 3 ms | 6 ms | 1.35 | 1.29 | 1.27 |
| `write_share` | Share of a document with a user (rolled back) | 1 ms | 1 ms | 1 ms | 0.23 | 0.21 | 0.25 |
| `parents_proj_select_page` | The first 50 documents. The parents come through the `folder_id` column: shared ids or viewable folders. | 2 ms | 3 ms | 4 ms | 2.62 | 1.55 | 1.57 |
| `parents_proj_select_count` | Count through the same two-arm projection policy | 2 ms | 3 ms | 9 ms | 14.66 over | 12.36 over | 9.97 over |
| `parents_select_page` | The first 50 documents through the single-branch parents policy (one call returns every visible id) | 4 ms | 16 ms | 32 ms | 66.27 over | 16.82 | 6.55 |
| `parents_select_count` | Count through the single-branch parents policy | 4 ms | 14 ms | 70 ms | 92.44 over | 27.61 | 15.53 |
| `write_nest_team` | Nest of a team with 1,000 members into a random team (rolled back) | 1 ms | 1 ms | 1 ms | 0.27 | 0.78 | 77.18 over |
| `nest_check` | One check for a user who reaches a document only through a nested team | 1 ms | 1 ms | 2 ms | 0.48 | 0.42 | 0.45 |

The optimized results on PG 18.6 in Docker are these:

- At large, A fails 3 workloads: `parents_proj_select_count` and both single-branch `parents_*` workloads.
- At large, B fails 1 workload: `parents_proj_select_count`.
- At large, C fails 2 workloads: `parents_proj_select_count` and `write_nest_team`.
- At medium deep, only C fails (`write_nest_team`).
- At medium wide, A passes every workload. B fails `share_list_objects` and `write_nest_team`. C fails `write_nest_team`.

The large `parents_proj_select_count` fails for every design, at about 8 ms p50. Current minor releases read every heap page for that bitmap count. Version 16.4 skipped the pages, and the budget was set on 16.4 (see `VERSIONS.md`, Calibration). The results on 16 and 17 are the same, except for some borderline values of B (see `OPTIMIZATIONS.md`, Budgets).

Before the optimizations, `bench/run.sh --check` ran at small scale (2026-10-29, not run again after that). A failed 4 workloads: `parents_proj_select_page`, `parents_proj_select_count`, `parents_select_page` and `parents_select_count`. B failed 4 workloads: `parents_select_page`, `parents_select_count`, `write_nest_team` and `nest_check`. C failed 1 workload: `write_nest_team`. Every design passed every session 1 budget.

Before the optimizations, the runs on Postgres 16.15, 17.11 and 18.6 in Docker gave the same large budget results as local 16.4 ([`./benchmarks/VERSIONS.md`](./benchmarks/VERSIONS.md)). There were two differences. First, `parents_proj_select_count` was over its budget, or within 10% of it, for every design. Second, B passed `nest_check`.

The workloads `share_*`, `parents*`, `write_share`, `write_nest_team` and `nest_check` belong to one design each (`bench/designs/<design>/`, native API). They run over identical data (`bench/seed_shape.sql`), and the budgets are shared. All three designs return identical visible-document checksums for every read policy, at every scale and shape that the benchmark measured.

Large scale is 1M documents, 10k users, 100 orgs and 500 teams, nested about 5 levels deep. Medium scale is 100k documents, 5k users, 50 orgs and 200 teams.

The table above comes from Postgres 18.6 in Docker (`cpus: 4`) on an Apple Silicon laptop, with 4 pgbench clients and one run for each configuration. The reference runs from before the optimization are local Postgres 16.4 ([`COMPARISON.md`](./benchmarks/COMPARISON.md)) and Docker 16 to 18 ([`VERSIONS.md`](./benchmarks/VERSIONS.md)). The writes roll back and run on a throwaway cluster with `fsync` off, so they are faster than real writes.

Design D has its own benchmark report: [`./benchmarks/D.md`](./benchmarks/D.md). Phase 6 measured small and medium scale for D, and D misses no budget there.

## Not yet covered by tests

- [x] pg_tle install path: `03_tle_install` runs `pgtle.install_extension` and `create extension` as a non-superuser on Postgres 16, 17 and 18 with pg_tle 1.5.3 (`docker/run-matrix.sh test`, 2026-10-29). Locally, without pg_tle, the spec checks only the non-superuser install.
