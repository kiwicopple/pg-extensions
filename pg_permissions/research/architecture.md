# Current architecture

`pg_permissions` provides an authorization store and check engine in one Postgres schema. RBAC manages roles and assignments. OpenFGA manages authorization models and relationship tuples. Cedar manages policies, templates and entities. All three share subject identity and expose functions for application checks. Row level security (RLS) is an optional enforcement integration.

## Separate model APIs

The `rbac_*`, `fga_*` and `cedar_*` tables and functions follow the rules of their own models. Each model retains its semantics and performance optimizations. An RBAC assignment does not create an OpenFGA tuple or a Cedar entity; applications manage each model's data explicitly.

The research compared three earlier implementations: a tuple core (A), a policy-first evaluator (B), and a compiled model (C). Those experiments exposed differences in what a generic role or deny meant. The project chose per-model tables (D) on 2026-10-29 and promoted that implementation to `pg_permissions--0.0.1.sql`.

Cedar (design E) extends that architecture in `pg_permissions--0.1.0.sql`. It is part of the same extension, alongside RBAC and OpenFGA. Existing databases can [upgrade from 0.0.1](../docs/install.md#upgrade-from-001) while keeping their roles, models and tuples.

<span id="shared-identity-and-rls"></span>

## Shared identity and application checks

The extension does not store users or depend on an `auth` schema. It reads the current subject from JWT claims or transaction-local settings. Client functions answer for that subject; admin functions manage data or evaluate an explicit subject.

The backend can use these functions as its authorization API, checking access before performing an operation and combining model decisions when needed. A Cedar `forbid` overrides Cedar permits; it does not automatically override a grant from RBAC or OpenFGA. The backend must implement any deny across models in its combined decision. See [Application checks](../docs/integrations/checks.md).

## Optional RLS enforcement

An application can also call the same functions from RLS policies on a table. Permissive policies grant access through any model; restrictive policies can deny access across them. A Cedar policy defines a model rule and works independently of these Postgres table policies.

Read policies can list accessible scopes or IDs once per statement. Write policies check the affected row. Cedar also accepts row attributes in `cedar_is_authorized_current`, so a policy can evaluate columns without storing a second copy of them as an entity. The [RLS guides](../docs/rls/policies.md) explain these choices and their performance implications.

## Conditions and compatibility

OpenFGA conditions use a CEL subset implemented in PL/pgSQL. The extension compiles expressions when it writes a model and evaluates them against tuple and request context. Current-subject helpers accept no request context and deny access that depends on a condition they cannot evaluate.

Cedar accepts policies as text or JSON and evaluates them against entities, their attributes and their hierarchy. Its admin check accepts request context and temporary entities. The current-subject functions accept no request context and deny access when a relevant `forbid` fails to evaluate. This behavior applies to application checks and RLS alike.

Pinned upstream test suites check OpenFGA and Cedar behavior. They do not imply support for every feature of the upstream services or libraries. Read [OpenFGA compatibility](../docs/models/openfga/compatibility.md), [CEL support](../docs/reference/cel.md), and [Cedar compatibility](../docs/models/cedar/compatibility.md). Cedar targets 4.14; schema validation and partial evaluation are outside its scope.

## Future models

A new model can add its own tables, management and check APIs, compatibility statement, tests and optional RLS integration while using the existing subject identity. Its documentation should explain its concepts and limits alongside the other models. Cedar is the first addition to the original RBAC and OpenFGA implementation; the earlier policy-first prototype remains historical research.

## Evidence and design details

- [Per-model tables decision](decision.md#session-4-direction-per-model-tables): why the generic API was dropped.
- [Per-model implementation](designs/d-per-model.md): tables, evaluation, and testing details.
- [Condition evaluator](designs/d-conditions.md): design and implementation record.
- [Cedar implementation](designs/e-cedar.md): parsing, evaluation, RLS helpers, compatibility tests and security review.
- [Benchmarks](benchmarks/README.md): measured results and limits, including the current implementation.
- [Historical prototypes](prototypes/README.md): earlier designs and their usage guides.
