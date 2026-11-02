# OpenFGA compatibility

The extension follows OpenFGA schema 1.1 and uses its public test suites as an oracle. It runs inside Postgres, so storage, errors, and some evaluation behavior differ from the OpenFGA service.

## Differences from OpenFGA

The extension follows OpenFGA closely. These differences are on purpose:

- One implicit store in each database. There is no CreateStore, ListStores or store id.
- Errors are Postgres exceptions. They are not gRPC or HTTP statuses. See [Errors and limits](../../reference/errors.md).
- The limits are the OpenFGA defaults. You cannot change them. There is no time limit on ListObjects and ListUsers. OpenFGA stops a list after 3 seconds and returns part of the list. Set `statement_timeout` instead. It raises an error and does not return part of a list.
- The functions use the snapshot of the statement. There is no `consistency` argument and no cache.
- ListUsers returns `type:id#relation` strings. It does not return `User` objects, and it has no `excluded_users`.
- `fga_read` accepts any combination of `object`, `relation` and `subject`, or none. OpenFGA is stricter.
- Take a relation that uses no `and` and no `but not`, directly or through other relations. A Check on this relation that is `false` is always `false`. OpenFGA can return error `openfga:2002` there when an unrelated branch is too deep.
- The model has no size limit and no limit on the number of types.
- Conditions use a CEL evaluator in PL/pgSQL. See [OpenFGA conditions](../../reference/cel.md#cel-subset).

These OpenFGA features do not exist: Expand, BatchCheck, StreamedListObjects, ReadChanges, assertions, and modular models (schema 1.2).

## Test coverage and known differences

The extension runs the pinned [OpenFGA consolidated suite](../../../test/fga/) and [model-validation cases](../../../test/fga_lang/). The [condition suite](../../../test/fga_abac/) covers OpenFGA ABAC cases; inline `$expression` cases are excluded because the extension does not support them.

For positive recursion below an exclusion, the extension uses the least fixpoint. This differs from OpenFGA v1.22.1 in the cyclic cases documented in the [upstream report](../../../research/upstream/openfga-cycle-but-not-inconsistency.md). The behavior may change if upstream resolves that inconsistency.

[Stale conditioned tuples](condition-behavior.md#stale-context) are ignored in every evaluation API. This is a documented difference for ListObjects and ListUsers. See [CEL support](../../reference/cel.md) for expression-level differences.
