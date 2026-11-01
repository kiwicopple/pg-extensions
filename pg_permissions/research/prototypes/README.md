# Prototypes

This directory has the usage guides of the prototypes of the candidate designs A, B and C. The prototypes are measured history. They ran the test suite and the benchmarks while people chose the design. You can still select them with `--impl`.

A, B and C put every model behind one generic API. D (session 4) replaced that API with one set of tables for each model. D won and became the design. **D moved to the extension file, [`../../pg_permissions--0.0.1.sql`](../../pg_permissions--0.0.1.sql).

This file is its source of truth from now on.** The file `prototypes/d-per-model.sql` no longer exists. The [old benchmark baselines](../../bench/baselines/) and the [journal](../journal.md) still name it. The measurements that name `d-per-model.sql` ran on the earlier copy of that file.

The user docs of the extension are at [Using pg_permissions](../../docs/README.md).

## Guides and SQL files

| Guide | SQL file | Design | Status |
| --- | --- | --- | --- |
| [Design A: tuple core](a-tuple-core.md) | [`../../prototypes/a-tuple-core.sql`](../../prototypes/a-tuple-core.sql) | [A: Shared tuple core](../designs/a-tuple-core.md) | Complete design plus the `rbac` preset, and the goals G10–G13 of v0.0.2 (parents, `user:*`, forbid, conditions). It passes every spec file, shared and `a/` (18 files, 199 assertions). |
| [Design B: policy first](b-policy-first.md) | [`../../prototypes/b-policy-first.sql`](../../prototypes/b-policy-first.sql) | [B: Policy-first](../designs/b-policy-first.md) | Complete design plus the `rbac` preset. Triggers maintain facts with closures (one advisory lock, repeatable read refused). It has permit and forbid policies with `via` parent anchors. Conditions are jsonb. The design splits them into a half for each query and a half for each row. It has `who_can` and `explain`, and also `rls_expression`, `apply_rls` and `lint`. It covers G10–G13 natively (parents, public, forbid, conditions). Also, `can()` fails closed on forbids with inputs that are absent. It passes every spec file, shared and `b/` (18 files, 189 assertions). The design doc lists the changes from the original design. |
| [Design C: compiled model](c-compiled-model.md) | [`../../prototypes/c-compiled-model.sql`](../../prototypes/c-compiled-model.sql) | [C: Compiled model](../designs/c-compiled-model.md) | Complete design plus the `rbac` preset. `apply_model()` compiles a JSON model (versioned, dry run, force) into lookup tables. IDs are `uuid`. Triggers materialize the memberships and the container closure (one advisory lock, repeatable read refused). `verify()` and `rebuild()` handle drift. It covers G10–G13 in the model (`parent->P`, `user:*`, `but_not` forbid). Conditions are RLS composition. Also, `who_can` reports public grants, and `tenant` is a parent type. It passes every spec file, shared and `c/` (21 files, 229 assertions). The design doc lists the changes from the original design in section 13. |
| [Using pg_permissions](../../docs/README.md) | [`../../pg_permissions--0.0.1.sql`](../../pg_permissions--0.0.1.sql) | [D: Per-model tables](../designs/d-per-model.md) | **The extension.** It has no generic API. The `rbac_*` tables are first-class, and they sit behind the same `rbac` functions. The `fga_*` tables follow OpenFGA: models in schema 1.1 JSON (versioned, compiled on write), tuples, Check, ListObjects, ListUsers, Read, and OpenFGA error codes in `DETAIL`. Monotone relations use set-based walks (the bidirectional search of A). The relations `and` and `but not` use a recursive evaluator after the LocalChecker of OpenFGA. It passes every shared spec and the consolidated test suite of OpenFGA (138 cases, 933 assertions stored and 746 with contextual tuples). It also passes the `d/` specs for the API, for RBAC and FGA composition in RLS, and for plan-time evaluation. In all, it passes 37 files and 2,164 assertions. The benchmarks are in [D.md](../benchmarks/D.md). |

## Run a prototype

Run these commands from the `pg_permissions` directory. To run the tests on a prototype, use `--impl`:

```bash
./test/run.sh  --impl prototypes/<file>.sql      # without --impl: the extension (design d)
./bench/run.sh --impl prototypes/<file>.sql --scale large
```

For example, to run the tests on prototype A, run `./test/run.sh --impl prototypes/a-tuple-core.sql`.

The measured comparison of A, B and C is in [COMPARISON.md](../benchmarks/COMPARISON.md). [decision.md](../decision.md) explains how to choose between them.

## Changes to design A

People made these changes to design A while they built the prototype. The [design doc](../designs/a-tuple-core.md) also shows them.

- The functions with an explicit subject (`check_for`, `list_objects_for`, `list_subjects`) are admin-only. The functions `check` and `list_objects` for clients always use the current subject. So a client cannot ask what another user can access.
- The JWT `sub` claim wins over the `permissions.subject_id` setting.
- The function `grant` takes an optional `expires_at`. It rejects usersets whose relation is not defined.
- v0.0.2 (section 12 of the design doc): `define_relation` gained `from_parent` (OpenFGA tuple-to-userset over a `parent` tuple) and `unless` (OpenFGA `but not`). `set_parent` and the trigger function `sync_parent()` manage parent tuples. `user:*` is a wildcard subject. Status-style conditions are RLS composition, not design code.
- `_reach` is PL/pgSQL, not SQL, so Postgres caches its plan for each session. Postgres 16 planned `_reach` again on every call when it was a SQL function. This made every check about 0.25 ms slower after the walk got the parent and exclusion steps.
- The measured cost of parents: a single-branch RLS policy lists every visible document. It took 7.3 ms for 1,007 IDs at small scale, before the session 3 optimizations. These optimizations cut the large single-branch page from 240 to 46 ms (see [OPTIMIZATIONS.md](../benchmarks/OPTIMIZATIONS.md)). The two-branch policy stays the fast path. See section 12.1 of the design doc.

## Notes from the build of design C

The [design doc](../designs/c-compiled-model.md) has the details.

- The `rbac` preset keeps the `text` signatures of [section 6 of the plan](../plan.md). The shared specs compare its results with `text[]` and pass `org_id::text`. IDs are `uuid` underneath. The functions `has_permission` and `has_role` have `uuid` overloads, for policies without a cast.
- `accessible()` returns `uuid[]`. The fastest policy form for it is `id = any ((select permissions.accessible(...))::uuid[])`. The cast has no effect, so no per-row cast exists. This is different from the `text[]` case in [section 4 of the plan](../plan.md).
- The design rejects parent cycles on write. Only container objects (folders, orgs) get closure rows. To move a document, write one upsert.
- The operation to nest a team of 1,000 members (`bench/designs/c/workloads/write_nest_team.sql`) costs about 14 ms with one client at small scale. It serializes concurrent writers on the global lock. `bench/run.sh` runs it (the `nesting` phase). With 4 clients, it measured 62 ms p50 at small and 333 ms at large ([COMPARISON.md](../benchmarks/COMPARISON.md), before the session 3 optimizations). At large it is now about 58 ms ([OPTIMIZATIONS.md](../benchmarks/OPTIMIZATIONS.md)).

## Notes from the build of design D

D is now the extension. The [design doc](../designs/d-per-model.md) has the details.

- The tests of the OpenFGA tables use the own test suite of OpenFGA. `test/fga/vendor.sh` vendors that suite, and `test/fga/generate.py` turns it into TAP specs (`test/spec/d/60_*`, `61_*`).
- The FGA list functions return `setof text`. Postgres never evaluates a set-returning function at plan time. So these functions need no `_unfolded_null()` argument (`test/spec/d/41_no_plan_time_eval.sql`).
- `delete_subject(type, id)` (the name and signature of A) cleans up both models. So the cleanup step of `90_usage_rbac` needs no D branch.
