# Overview

`pg_permissions` is an authorization store and check engine for Postgres. It stores roles, sharing relationships and policies alongside your application data. A backend can check access with the JavaScript client or SQL and enforce the decision in a request handler.

If you already use Postgres, it is an alternative to running a separate authorization service. A document app can store its roles and shares here, check whether a user can edit a document, and allow or reject the operation in its backend. You can also call the functions from RLS policies if you want Postgres to enforce access on tables.

The models follow familiar authorization approaches, with documented [OpenFGA](models/openfga/compatibility.md) and [Cedar](models/cedar/compatibility.md) compatibility. Moving from another tool means mapping your model and integration to these APIs; the extension does not expose that tool's HTTP service.

## Why we built it

### Keep authorization close to the data

Authorization usually depends on the data being accessed: who owns a document, which organization it belongs to, or whether it has been shared with a team. We believe the best place to evaluate those rules is alongside that data.

With authorization inside Postgres, permission changes and application data can share a transaction. Checks can run from your backend or inside a database query, without a separate authorization service. Running the checks adds database work, and evaluating a rule in SQL may cost more than evaluating it in a dedicated engine. Our premise is that avoiding network round trips and moving data between services can more than offset that cost. What matters is the time and total cost of serving an authorized request, including access to the data itself.

### Give Postgres more ways to express access

Established authorization models let an application use roles for organization-wide access, relationships for individual shares, and Cedar policies for attribute rules. Your backend can evaluate these rules through the extension's functions and decide whether to carry out an operation.

An app can start with roles and add sharing later, without replacing its existing permissions. Each model keeps its own semantics. When you want enforcement on database rows, the same functions can be used in RLS policies. The choice of permission model and the choice of where to enforce it are separate.

### Build on models people and LLMs already know

Established models come with documentation, examples, tooling, and a body of work explaining how to use them. Developers and LLMs can draw on that knowledge when writing authorization rules, instead of learning a language invented for this extension.

Following OpenFGA and Cedar gives us concrete model languages and public test suites to check against. Keeping that familiar model inside Postgres makes it easier for agents to generate useful code and for developers to understand and review it. The [architecture overview](../research/architecture.md) explains why we chose separate model APIs and how future models can fit.

## What you can express

The extension has three permission models in the `permissions` schema:

| Model | Use it for | Example |
| --- | --- | --- |
| Roles and permissions (RBAC) | Roles across an application or within a tenant, with role inheritance | Alice is an editor in Acme and a viewer in Globex. |
| Relationships (OpenFGA) | Individual shares, nested teams, and access inherited from folders | Bob can read a document because it is shared with his team. |
| Policies (Cedar) | Reviewed policy text, rules on attributes, and explicit denies | Owners edit their own documents. A confidentiality rule can override that access. |

OpenFGA relationships can also have CEL conditions, such as an expiry time. Your backend can combine model checks, for example allowing access through either a role or a share while rejecting suspended users. RLS policies provide another way to enforce that combination on a table.

Cedar's admin API also accepts trusted request context, such as an MFA result or a client address. Its current-subject functions use stored entities and can receive resource attributes supplied by your backend or an RLS policy. They do not accept request context. A Cedar `forbid` overrides Cedar permits; it does not automatically override another model's answer. Your backend must apply any deny across models, or you can use [a restrictive RLS policy](rls/combine-models.md#add-cedar-as-a-third-model).

A **Cedar policy** defines an authorization rule. A **Postgres RLS policy** enforces an expression on table reads or writes. You can use Cedar policies without creating any RLS policies.

[Choose a permission model](get-started/choose-a-model.md) walks through the options. Each model has its own guide, its own functions and its own data. The structure leaves room for other models alongside them.

## Goals that shape the extension

- Keep authorization close to the data. Store permission data and evaluate access in Postgres, with enforcement in your backend, database functions, or optional RLS policies.
- Provide useful checks and lists. Ask whether an operation is allowed, list accessible scopes or object IDs, and use those answers in application code or queries. For RLS on large tables, [policy shape matters](rls/performance.md); a per-row check is not always the right choice.
- Work with an application's existing identity system. The extension reads a subject from JWT claims or transaction-local settings. It does not store users or require a Supabase `auth` schema.
- Keep installation portable. The implementation is SQL and PL/pgSQL, supports Postgres 16, 17, and 18, and can be installed without superuser rights. There is no C module or separate authorization service to run.
- Make behavior inspectable. The project uses executable examples, pinned OpenFGA and Cedar test suites, and benchmarks to check its rules and performance. Compatibility differences ([OpenFGA](models/openfga/compatibility.md), [Cedar](models/cedar/compatibility.md)) and [limits](reference/limits.md) are documented explicitly.

## Where it fits in your application

Your authentication system establishes who is making a request. A Node backend uses `createServerClient(pool)` to manage permissions and `permissions.as({ id: user.id })` to check the signed-in user’s access. A trusted backend assigns roles, writes sharing relationships, or manages Cedar policies and entities, using SQL or the JavaScript client. It checks access before returning data or carrying out an operation, and handles a denied result or an error.

A permission check returns a decision; it does not block a later query by itself. Browser checks can guide the interface, but a trusted backend or database policy must enforce access. If you choose RLS, Postgres applies the policies to table queries. A standalone check does not include extra rules you put only in RLS. See [Check access in your application](integrations/checks.md).

## Start here

[Install the extension](install.md), then follow the [quickstart](get-started/quickstart.md) to assign a role and check access for two users. Connect those checks to your backend with [Check access in your application](integrations/checks.md). If you want table-level enforcement, continue with the optional RLS example.

The [documentation map](README.md) links to individual tasks. The [research section](../research/README.md) preserves the design experiments and measurements behind the implementation.
