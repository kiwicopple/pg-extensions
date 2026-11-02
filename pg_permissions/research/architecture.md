# Current architecture

`pg_permissions` puts separate permission models in one Postgres schema. RBAC manages roles and assignments. OpenFGA manages authorization models and relationship tuples. Both share subject identity and compose through row level security.

## Separate model APIs

The `rbac_*` and `fga_*` tables and functions follow the rules of their own models. There is no generic API that translates every model into one representation. This lets each model retain its semantics and its own performance optimizations.

The research compared three earlier implementations: a tuple core (A), a policy-first evaluator (B), and a compiled model (C). Those experiments exposed differences in what a generic role or deny meant. The project chose per-model tables (D) on 2026-10-29 and promoted that implementation to `pg_permissions--0.0.1.sql`.

## Shared identity and RLS

The extension does not store users or depend on an `auth` schema. It reads the current subject from JWT claims or transaction-local settings. Client functions answer for that subject; admin functions manage data or evaluate an explicit subject.

An application can combine RBAC and OpenFGA on one table. Permissive RLS policies grant access through either model, while restrictive policies can deny access across both. Read policies use lists of accessible scopes or IDs; write policies check the affected row. The [RLS guides](../docs/rls/policies.md) show the supported forms.

## Conditions and compatibility

OpenFGA conditions use a CEL subset implemented in PL/pgSQL. The extension compiles expressions when it writes a model and evaluates them against tuple and request context. Current-subject helpers accept no request context and deny access that depends on a condition they cannot evaluate.

The OpenFGA test suites are pinned oracles, not a claim that every service feature is supported. Read [OpenFGA compatibility](../docs/models/openfga/compatibility.md) and [CEL support](../docs/reference/cel.md) before relying on a particular feature.

## Future models

> Note, 2026-11-02: Cedar is now implemented as the `cedar_*` model in `pg_permissions--0.1.0.sql`. It has its own API, [compatibility statement](../docs/models/cedar/compatibility.md), tests and [RLS guidance](../docs/rls/policies.md#policies-for-cedar). The design is in [`designs/e-cedar.md`](designs/e-cedar.md). The text below is the earlier statement, kept as history.

The design reserves Cedar as a future, separate model. It is not implemented. The policy-first prototype is research for that work, not a Cedar installation option. A new model would need its own API, compatibility statement, tests, and RLS guidance.

## Evidence and design details

- [Per-model tables decision](decision.md#session-4-direction-per-model-tables): why the generic API was dropped.
- [Per-model implementation](designs/d-per-model.md): tables, evaluation, and testing details.
- [Condition evaluator](designs/d-conditions.md): design and implementation record.
- [Benchmarks](benchmarks/README.md): measured results and limits, including the current implementation.
- [Historical prototypes](prototypes/README.md): earlier designs and their usage guides.
