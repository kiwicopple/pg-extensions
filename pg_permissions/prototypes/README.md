# Prototypes

Working implementations of the candidate designs, used to run the test suite and benchmarks before the engine is chosen. They aren't the extension: `pg_permissions--0.0.1.sql` is.

| File | Design | Status |
| --- | --- | --- |
| [`a-tuple-core.sql`](./a-tuple-core.sql) | [A: Shared tuple core](../designs/a-tuple-core.md) | Complete engine plus `rbac` preset, and the v0.0.2 goals G10–G13 (parents, `user:*`, forbid, conditions). Passes every spec file, shared and `a/` (14 files, 156 assertions). |
| [`b-policy-first.sql`](./b-policy-first.sql) | [B: Policy-first](../designs/b-policy-first.md) | Complete engine plus `rbac` preset: facts with closures maintained by triggers (one advisory lock, repeatable read refused), permit/forbid policies with `via` parent anchors, jsonb conditions split into a per-query half and a per-row half, `who_can`/`explain`, and `rls_expression`/`apply_rls`/`lint`. Covers G10–G13 natively (parents, public, forbid, conditions). Plus fail-closed `can()` on forbids with missing inputs. Passes every spec file, shared and `b/` (15 files, 172 assertions). Changes from the original design are listed in its design doc. |
| [`c-compiled-model.sql`](./c-compiled-model.sql) | [C: Compiled model](../designs/c-compiled-model.md) | Complete engine plus `rbac` preset: `apply_model()` compiles a JSON model (versioned, dry run, force) into lookup tables; `uuid` IDs; memberships and the container closure are materialized by triggers (one advisory lock, repeatable read refused), with `verify()`/`rebuild()` for drift. Covers G10–G13 in the model (`parent->P`, `user:*`, `but_not` forbid; conditions are RLS composition). Plus `who_can` reporting public grants and `tenant` as a parent type. Passes every spec file, shared and `c/` (17 files, 204 assertions). Changes from the original design are listed in its design doc §13. |

```bash
./test/run.sh  --impl prototypes/<file>.sql
./bench/run.sh --impl prototypes/<file>.sql --scale large
```

The measured comparison of the three is in [`../bench/baselines/COMPARISON.md`](../bench/baselines/COMPARISON.md); how to choose between them is in [`../DECISION.md`](../DECISION.md).

Changes made to Design A while building the prototype (also reflected in its design doc):

- Explicit-subject functions (`check_for`, `list_objects_for`, `list_subjects`) are admin-only. The client-facing `check` and `list_objects` always use the current subject, so a client can't ask what another user can access.
- The JWT `sub` claim wins over the `permissions.subject_id` setting.
- `grant` takes an optional `expires_at`, and rejects usersets whose relation isn't defined.
- v0.0.2 (design doc §12): `define_relation` gained `from_parent` (OpenFGA tuple-to-userset over a `parent` tuple) and `unless` (OpenFGA `but not`); `set_parent` and the `sync_parent()` trigger function manage parent tuples; `user:*` is a wildcard subject. Status-style conditions are RLS composition, not engine code.
- `_reach` is PL/pgSQL instead of SQL so its plan is cached per session. As a SQL function, Postgres 16 re-planned it on every call, which made every check ~0.25 ms slower once the walk grew the parent and exclusion steps.
- Measured cost of parents: a single-branch RLS policy enumerates every visible document (7.3 ms for 1,007 IDs at small scale). The two-branch policy stays the fast path; see the design doc §12.1.

Notes from building Design C (details in its design doc):

- The `rbac` preset keeps PLAN.md §6's `text` signatures (the shared specs compare its results with `text[]` and pass `org_id::text`); IDs are `uuid` underneath, with `uuid` overloads of `has_permission`/`has_role` for cast-free policies.
- `accessible()` returns `uuid[]`, and the fastest policy form for it is `id = any ((select permissions.accessible(...))::uuid[])`: the cast is a no-op, so unlike PLAN.md §4's `text[]` case there's no per-row cast.
- Parent cycles are rejected on write. Only container objects (folders, orgs) get closure rows; moving a document is one upsert.
- Nesting a 1,000-member team (`bench/designs/c/workloads/write_nest_team.sql`) costs about 14 ms with one client at small scale and serializes concurrent writers on the global lock. `bench/run.sh` runs it (the `nesting` phase); with 4 clients it measured 62 ms p50 at small and 333 ms at large (COMPARISON.md).
