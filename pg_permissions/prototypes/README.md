# Prototypes

Working implementations of the candidate designs, used to run the test suite and benchmarks before the engine is chosen. They aren't the extension: `pg_permissions--0.0.1.sql` is.

| File | Design | Status |
| --- | --- | --- |
| [`a-tuple-core.sql`](./a-tuple-core.sql) | [A: Shared tuple core](../designs/a-tuple-core.md) | Complete engine plus `rbac` preset, and the v0.0.2 goals G10–G13 (parents, `user:*`, forbid, conditions). Passes every spec file, shared and `a/` (13 files, 147 assertions). |
| [`b-policy-first.sql`](./b-policy-first.sql) | [B: Policy-first](../designs/b-policy-first.md) | Complete engine plus `rbac` preset: facts with closures maintained by triggers (one advisory lock, repeatable read refused), permit/forbid policies with `via` parent anchors, jsonb conditions split into a per-query half and a per-row half, `who_can`/`explain`, and `rls_expression`/`apply_rls`/`lint`. Covers G10–G13 natively (parents, public, forbid, conditions). Passes every spec file, shared and `b/` (13 files, 147 assertions). Changes from the original design are listed in its design doc. |
| — | [C: Compiled model](../designs/c-compiled-model.md) | Not built yet. Needs `apply_model()` and the membership triggers. |

```bash
./test/run.sh  --impl prototypes/a-tuple-core.sql
./bench/run.sh --impl prototypes/a-tuple-core.sql --scale large
```

Changes made to Design A while building the prototype (also reflected in its design doc):

- Explicit-subject functions (`check_for`, `list_objects_for`, `list_subjects`) are admin-only. The client-facing `check` and `list_objects` always use the current subject, so a client can't ask what another user can access.
- The JWT `sub` claim wins over the `permissions.subject_id` setting.
- `grant` takes an optional `expires_at`, and rejects usersets whose relation isn't defined.
- v0.0.2 (design doc §12): `define_relation` gained `from_parent` (OpenFGA tuple-to-userset over a `parent` tuple) and `unless` (OpenFGA `but not`); `set_parent` and the `sync_parent()` trigger function manage parent tuples; `user:*` is a wildcard subject. Status-style conditions are RLS composition, not engine code.
- `_reach` is PL/pgSQL instead of SQL so its plan is cached per session. As a SQL function, Postgres 16 re-planned it on every call, which made every check ~0.25 ms slower once the walk grew the parent and exclusion steps.
- Measured cost of parents: a single-branch RLS policy enumerates every visible document (7.3 ms for 1,007 IDs at small scale). The two-branch policy stays the fast path; see the design doc §12.1.
