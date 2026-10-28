# pg_permissions: Goals

Each goal is a spec file in [`test/spec/`](./test/spec/). A goal is met when its file passes. Write the test first, then the code. See [`test/README.md`](./test/README.md) for how to run things.

Status as of 2026-10-28, from `test/run.sh --impl <implementation>`:

## Functional goals (v0.0.1)

| # | Goal | PLAN.md | Spec | Extension | Prototype A | Prototype B (stand-in) |
| --- | --- | --- | --- | --- | --- | --- |
| G1 | Identity from JWT `sub`, falling back to `permissions.subject_id`; no `auth` schema | §3 | `01_identity` | ❌ | ✅ 11/11 | ✅ 11/11 |
| G2 | Clients can't read or write permission data or act for other users | §3, §4 | `02_security` | ❌ | ✅ 14/14 | ✅ 14/14 |
| G3 | `rbac` preset: app-wide roles, inheritance, `has_permission`, `has_role` | §6 | `10_rbac_app_wide` | ❌ | ✅ 17/17 | ✅ 17/17 |
| G4 | `rbac` preset: tenant-scoped roles, `scopes_with_permission` | §6 | `11_rbac_tenant` | ❌ | ✅ 13/13 | ✅ 13/13 |
| G5 | `rbac` preset: assign, unassign, create, drop, validation | §6 | `12_rbac_management` | ❌ | ✅ 15/15 | ✅ 15/15 |
| G6 | RLS enforcement as `authenticated`; fast path is an InitPlan | §4, §6 | `20_rls` | ❌ | ✅ 12/12 | ✅ 12/12 |
| G7 | Reference scenario: per-object relations, implied relations, groups | §5 | `30_zanzibar_reference` ⚠️ | ❌ | ✅ 14/14 | ❌ (different API) |
| G8 | Nested groups, cycles, revocation, expiry, cleanup | §2, §3 | `31_zanzibar_groups` ⚠️ | ❌ | ✅ 11/11 | ❌ (different API) |
| G9 | Graduation: add sharing to an rbac app without migrating | §6 | `40_graduation` ⚠️ | ❌ | ✅ 5/5 | ❌ (different API) |

⚠️ Provisional: these files use Design A's zanzibar-level API (`define_type`, `define_relation`, `grant`, `check_for`, ...), because that API isn't settled. When the engine is chosen, update the function calls and keep the assertions.

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
| `share_list_objects` ⚠️ | All documents shared with a user via nested teams | 2 ms | 2 ms | 0.77 ms |
| `share_select_page` ⚠️ | First 50 documents through the two-branch policy | 5 ms | 6 ms | 2.31 ms |
| `write_share` ⚠️ | Share a document with a user | 1 ms | 1 ms | 0.16 ms |

Large scale is 1M documents, 10k users, 100 orgs and 500 teams nested about 5 levels deep. Measured on Postgres 16 on an Apple Silicon laptop with 4 pgbench clients. Write numbers come from a throwaway cluster with `fsync` off, so they're optimistic.

## Not yet covered by tests

Goals from PLAN.md that need a spec file once their API is designed:

- [ ] Parent inheritance: "viewers of an org can view its documents" without a two-branch RLS policy (v0.0.2)
- [ ] `list_subjects` includes access that comes through a parent (e.g. org admins on a document)
- [ ] Attribute conditions (Model 3)
- [ ] Public access (`user:*`)
- [ ] Forbid / deny rules
- [ ] Installs through pg_tle / dbdev as a non-superuser (the suite loads SQL directly as a superuser today)
- [ ] Medium-scale performance budgets, and a benchmark against Design C's materialized memberships
