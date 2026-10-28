# pg_permissions: Goals

Each goal is a spec file in [`test/spec/`](./test/spec/). A goal is met when its file passes. Write the test first, then the code. See [`test/README.md`](./test/README.md) for how to run things.

Status as of 2026-10-28, from `test/run.sh --impl <implementation>`:

## Functional goals

| # | Goal | PLAN.md | Spec | Extension | Prototype A | Prototype B (stand-in) |
| --- | --- | --- | --- | --- | --- | --- |
| G1 | Identity from JWT `sub`, falling back to `permissions.subject_id`; no `auth` schema | §3 | `01_identity` | ❌ | ✅ 11/11 | ✅ 11/11 |
| G2 | Clients can't read or write permission data or act for other users | §3, §4 | `02_security` | ❌ | ✅ 14/14 | ✅ 14/14 |
| G3 | `rbac` preset: app-wide roles, inheritance, `has_permission`, `has_role` | §6 | `10_rbac_app_wide` | ❌ | ✅ 17/17 | ✅ 17/17 |
| G4 | `rbac` preset: tenant-scoped roles, `scopes_with_permission` | §6 | `11_rbac_tenant` | ❌ | ✅ 13/13 | ✅ 13/13 |
| G5 | `rbac` preset: assign, unassign, create, drop, validation | §6 | `12_rbac_management` | ❌ | ✅ 15/15 | ✅ 15/15 |
| G6 | RLS enforcement as `authenticated`; fast path is an InitPlan | §4, §6 | `20_rls` | ❌ | ✅ 12/12 | ✅ 12/12 |
| G7 | Reference scenario: per-object relations, implied relations, groups | §5 | `<design>/30_zanzibar_reference` | ❌ | ✅ 14/14 (`a/`) | ❌ (`b/` not written) |
| G8 | Nested groups, cycles, revocation, expiry, cleanup | §2, §3 | `<design>/31_zanzibar_groups` | ❌ | ✅ 11/11 (`a/`) | ❌ (`b/` not written) |
| G9 | Graduation: add sharing to an rbac app without migrating | §6 | `<design>/40_graduation` | ❌ | ✅ 5/5 (`a/`) | ❌ (`b/` not written) |
| G10 | Parent inheritance: org → folder → document, single fast-path RLS branch, cycles terminate | §10 | `<design>/50_parents` | ❌ | ❌ | ❌ |
| G11 | Public access (`user:*`); null subject is denied | §10 | `<design>/51_public` | ❌ | ❌ | ❌ |
| G12 | Forbid beats grants, including parent-derived ones | §10 | `<design>/52_forbid` | ❌ | ❌ | ❌ |
| G13 | Conditions: document status, expired grants | §10 | `<design>/53_conditions` | ❌ | ❌ | ❌ |
| G14 | Installs as a non-superuser; via `pgtle.install_extension` if pg_tle is available | §10 | `03_tle_install` | ❌ | ✅ 9/9 non-superuser install (pg_tle path not tested: not available locally) | ✅ 9/9 non-superuser install (pg_tle not tested); C: ✅ 9/9 (same) |

Zanzibar-level spec files (`30`+, in `test/spec/<design>/`) are per-design: each design has its own copy of the same scenario written in its native API, with the same assertions, so results compare one to one. G10-G14 are the v0.0.2 scenarios from PLAN.md §10; none are written yet.

The extension (`pg_permissions--0.0.1.sql`) is still empty, so every goal is red. That's the starting point.

## Performance goals

p95 budgets per workload, enforced by `bench/run.sh --check`. Budgets live in [`bench/budgets.tsv`](./bench/budgets.tsv). They were set at about 2–3× Design A's measured p95, so they're a regression guard as much as a target.

| Workload | What it measures | Small budget | Large budget | Prototype A, large (p95) |
| --- | --- | --- | --- | --- |
| `rbac_check` | One `has_permission` call | 1 ms | 1 ms | 0.40 ms |
| `rbac_select_page` | First 50 documents through the RBAC policy | 2 ms | 3 ms | 0.85 ms |
| `rbac_select_count` | Count all visible documents (20k at large) | 2 ms | 3 ms | 1.02 ms |
| `rbac_update_one` | Update one document by id under RLS | 4 ms | 3 ms | 1.12 ms |
| `write_assign_role` | `assign_role` as admin | 1 ms | 1 ms | 0.15 ms |
| `share_list_objects` | All documents shared with a user via nested teams | 2 ms | 2 ms | 0.77 ms |
| `share_select_page` | First 50 documents through the two-branch policy | 5 ms | 6 ms | 2.31 ms |
| `write_share` | Share a document with a user | 1 ms | 1 ms | 0.16 ms |

The `share_*` and `write_share` workloads are per-design (`bench/designs/<design>/`, native API); the budgets are shared. Only Design A has them so far.

Large scale is 1M documents, 10k users, 100 orgs and 500 teams nested about 5 levels deep. Measured on Postgres 16 on an Apple Silicon laptop with 4 pgbench clients. Write numbers come from a throwaway cluster with `fsync` off, so they're optimistic.

## Not yet covered by tests

- [ ] Medium-scale performance budgets, and a benchmark against Design C's materialized memberships
