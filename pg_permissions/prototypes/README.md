# Prototypes

Working implementations of the candidate designs, used to run the test suite and benchmarks before the engine is chosen. They aren't the extension: `pg_permissions--0.0.1.sql` is.

| File | Design | Status |
| --- | --- | --- |
| [`a-tuple-core.sql`](./a-tuple-core.sql) | [A: Shared tuple core](../designs/a-tuple-core.md) | Complete engine plus `rbac` preset. Passes every spec file. |
| [`b-policy-first.sql`](./b-policy-first.sql) | [B: Policy-first](../designs/b-policy-first.md) | **Stand-in.** B's schema, a minimal evaluator (permit policies without `via`) and the `rbac` preset. Passes the engine-independent spec files; fails the zanzibar-level ones by design. |
| — | [C: Compiled model](../designs/c-compiled-model.md) | Not built yet. Needs `apply_model()` and the membership triggers. |

```bash
./test/run.sh  --impl prototypes/a-tuple-core.sql
./bench/run.sh --impl prototypes/a-tuple-core.sql --scale large
```

Changes made to Design A while building the prototype (also reflected in its design doc):

- Explicit-subject functions (`check_for`, `list_objects_for`, `list_subjects`) are admin-only. The client-facing `check` and `list_objects` always use the current subject, so a client can't ask what another user can access.
- The JWT `sub` claim wins over the `permissions.subject_id` setting.
- `grant` takes an optional `expires_at`, and rejects usersets whose relation isn't defined.
