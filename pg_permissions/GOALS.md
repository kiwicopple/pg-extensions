# pg_permissions: Goals

Each goal is a spec file in [`test/spec/`](./test/spec/). A goal is met when its file passes. Write the test first, then the code. See [`test/README.md`](./test/README.md) for how to run things.

Status as of 2026-10-29, from `test/run.sh --impl <implementation>`:

## Functional goals

| # | Goal | PLAN.md | Spec | Extension | Prototype A | Prototype B | Prototype C |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G1 | Identity from JWT `sub`, falling back to `permissions.subject_id`; no `auth` schema | §3 | `01_identity` | ❌ | ✅ 11/11 | ✅ 11/11 | ✅ 11/11 |
| G2 | Clients can't read or write permission data or act for other users | §3, §4 | `02_security` | ❌ | ✅ 14/14 | ✅ 14/14 | ✅ 14/14 |
| G3 | `rbac` preset: app-wide roles, inheritance, `has_permission`, `has_role` | §6 | `10_rbac_app_wide` | ❌ | ✅ 17/17 | ✅ 17/17 | ✅ 17/17 |
| G4 | `rbac` preset: tenant-scoped roles, `scopes_with_permission` | §6 | `11_rbac_tenant` | ❌ | ✅ 13/13 | ✅ 13/13 | ✅ 13/13 |
| G5 | `rbac` preset: assign, unassign, create, drop, validation | §6 | `12_rbac_management` | ❌ | ✅ 15/15 | ✅ 15/15 | ✅ 15/15 |
| G6 | RLS enforcement as `authenticated`; fast path is an InitPlan | §4, §6 | `20_rls` | ❌ | ✅ 12/12 | ✅ 12/12 | ✅ 12/12 |
| G7 | Reference scenario: per-object relations, implied relations, groups | §5 | `<design>/30_zanzibar_reference` | ❌ | ✅ 14/14 | ✅ 14/14 | ✅ 14/14 |
| G8 | Nested groups, cycles, revocation, expiry, cleanup | §2, §3 | `<design>/31_zanzibar_groups` | ❌ | ✅ 11/11 | ✅ 11/11 | ✅ 11/11 |
| G9 | Graduation: add sharing to an rbac app without migrating | §6 | `<design>/40_graduation` | ❌ | ✅ 5/5 | ✅ 5/5 | ✅ 5/5 |
| G10 | Parent inheritance: org → folder → document, single fast-path RLS branch, cycles terminate | §10 | `<design>/50_parents` | ❌ | ✅ 13/13 | ✅ 13/13 | ✅ 13/13 |
| G11 | Public access (`user:*`); null subject is denied | §10 | `<design>/51_public` | ❌ | ✅ 7/7 | ✅ 7/7 | ✅ 7/7 |
| G12 | Forbid beats grants, including parent-derived ones | §10 | `<design>/52_forbid` | ❌ | ✅ 9/9 | ✅ 9/9 | ✅ 9/9 |
| G13 | Conditions: document status, expired grants | §10 | `<design>/53_conditions` | ❌ | ✅ 6/6 | ✅ 6/6 | ✅ 6/6 |
| G14 | Installs as a non-superuser; via `pgtle.install_extension` if pg_tle is available | §10 | `03_tle_install` | ❌ | ✅ 9/9 (pg_tle path on PG 16-18 in Docker) | ✅ 9/9 (same) | ✅ 9/9 (same) |
| | Design-specific: B fails closed on forbids with missing inputs | | `b/54_fail_closed` | | | ✅ 16/16 | |
| | Design-specific: C materialized memberships stay correct | | `c/32_memberships` | | | | ✅ 31/31 |
| | Design-specific: C `who_can` reports public grants | | `c/54_who_can_public` | | | | ✅ 8/8 |
| | Design-specific: C tenant as a parent type | | `c/55_tenant_parent` | | | | ✅ 9/9 |
| | **Total** | | | ❌ | **14/14 files, 156 assertions** | **15/15 files, 172 assertions** | **17/17 files, 204 assertions** |

Zanzibar-level spec files (`30`+, in `test/spec/<design>/`) are per-design: each design has its own copy of the same scenario written in its native API, with the same assertions, so results compare one to one. G10–G14 are the v0.0.2 scenarios from PLAN.md §10.

The extension (`pg_permissions--0.0.1.sql`) is still empty, so every goal is red there.

## Performance goals

p95 budgets per workload, enforced by `bench/run.sh --check`. Budgets live in [`bench/budgets.tsv`](./bench/budgets.tsv). Session-1 budgets (small and large `rbac_*`, `share_*`, `write_*`) were set at about 2–3× Design A's measured p95. The rest, added on 2026-10-29, are 3× the p95 of the fastest engine on that workload, rounded up to a whole ms. Stress-shape budgets (`medium-deep`, `medium-wide`) are only in `budgets.tsv`. Full results, seed times, storage and the analysis are in [`bench/baselines/COMPARISON.md`](./bench/baselines/COMPARISON.md).

Large-scale p95 (ms) from the serial runs of 2026-10-28 (`bench/baselines/<design>-large-default.md`). ❌ = over the large budget.

| Workload | What it measures | Small budget | Medium budget | Large budget | A, large p95 | B, large p95 | C, large p95 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `rbac_check` | One `has_permission` call | 1 ms | 1 ms | 1 ms | 0.35 | 0.48 | 0.34 |
| `rbac_select_page` | First 50 documents through the RBAC policy | 2 ms | 2 ms | 3 ms | 0.77 | 0.99 | 0.80 |
| `rbac_select_count` | Count all visible documents (20k at large) | 2 ms | 2 ms | 3 ms | 0.92 | 0.82 | 0.87 |
| `rbac_update_one` | Update one document by id under RLS | 4 ms | 3 ms | 3 ms | 1.06 | 0.86 | 0.80 |
| `write_assign_role` | `assign_role` as admin (rolled back) | 1 ms | 1 ms | 1 ms | 0.28 | 0.24 | 0.34 |
| `share_list_objects` | All documents shared with a user via nested teams | 2 ms | 1 ms | 2 ms | 0.84 | 0.38 | 0.35 |
| `share_select_page` | First 50 documents through the two-branch policy (org roles or shares) | 5 ms | 3 ms | 6 ms | 2.28 | 1.41 | 1.22 |
| `write_share` | Share a document with a user (rolled back) | 1 ms | 1 ms | 1 ms | 0.25 | 0.25 | 0.28 |
| `parents_proj_select_page` | First 50 documents, parents via the `folder_id` column: shared ids or viewable folders | 2 ms | 3 ms | 4 ms | 3.71 | 1.66 | 1.29 |
| `parents_proj_select_count` | Count through the same two-arm projection policy | 2 ms | 3 ms | 9 ms | 5.58 | 3.39 | 2.90 |
| `parents_select_page` | First 50 documents through the single-branch parents policy (one call returns every visible id) | 4 ms | 16 ms | 32 ms | 560.66 ❌ | 251.96 ❌ | 10.34 |
| `parents_select_count` | Count through the single-branch parents policy | 4 ms | 14 ms | 70 ms | 579.85 ❌ | 266.63 ❌ | 23.25 |
| `write_nest_team` | Nest a 1,000-member team into a random team (rolled back) | 1 ms | 1 ms | 1 ms | 0.24 | 325.98 ❌ | 384.19 ❌ |
| `nest_check` | One check for a user who reaches a document only through a nested team | 1 ms | 1 ms | 2 ms | 0.79 | 2.83 ❌ | 0.34 |

`bench/run.sh --check` at small scale (2026-10-29): A fails 4 (`parents_proj_select_page`, `parents_proj_select_count`, `parents_select_page`, `parents_select_count`), B fails 4 (`parents_select_page`, `parents_select_count`, `write_nest_team`, `nest_check`), C fails 1 (`write_nest_team`). Every engine passes every session-1 budget.

On Postgres 16.15, 17.11 and 18.6 in Docker (2026-10-29, [`bench/baselines/VERSIONS.md`](./bench/baselines/VERSIONS.md)), the large-scale budget results are the same as the table above, with two exceptions. First, `parents_proj_select_count` (9 ms) is over or within 10% of the budget for every engine on every version: A 10.3-12.1 ms p95; B 9.97, 9.15 and 8.46 on 16, 17 and 18; C 9.50, 8.94 and 8.50. The cause is that current minor releases read every heap page for that bitmap count, while 16.4 skipped them (VERSIONS.md, Calibration). Second, B's `nest_check` passes (1.4-1.7 ms). Between versions, the only budget that flips is that borderline `parents_proj_select_count`.

The `share_*`, `parents*`, `write_share`, `write_nest_team` and `nest_check` workloads are per-design (`bench/designs/<design>/`, native API) over identical data (`bench/seed_shape.sql`); the budgets are shared. All three engines return identical visible-document checksums for every read policy at every scale and shape measured.

Large scale is 1M documents, 10k users, 100 orgs and 500 teams nested about 5 levels deep; medium is 100k documents, 5k users, 50 orgs, 200 teams. Measured on Postgres 16 on an Apple Silicon laptop with 4 pgbench clients, one run per configuration; Postgres 16, 17 and 18 in Docker on the same laptop in [`bench/baselines/VERSIONS.md`](./bench/baselines/VERSIONS.md). Writes roll back and run on a throwaway cluster with `fsync` off, so they're optimistic.

## Not yet covered by tests

- [x] pg_tle install path: `03_tle_install` runs `pgtle.install_extension` + `create extension` as a non-superuser on Postgres 16, 17 and 18 with pg_tle 1.5.3 (`docker/run-matrix.sh test`, 2026-10-29). Locally, without pg_tle, it still checks only the non-superuser install
