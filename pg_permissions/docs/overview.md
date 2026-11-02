# Overview

`pg_permissions` is an authorization extension for Postgres. It stores application roles, sharing relationships and policies in your database, and gives you functions to use in row level security (RLS) policies. Your application manages who has access; Postgres enforces that access when it reads or writes rows.

For example, a document app might let editors change any document in their organization, let a guest read one shared document, and block a suspended user from both. The extension provides the permission models for those rules, while RLS brings them together on the documents table.

## Why we built it

### Keep authorization close to the data

Authorization usually depends on the data being accessed: who owns a document, which organization it belongs to, or whether it has been shared with a team. We believe the best place to evaluate those rules is alongside that data.

With authorization inside Postgres, a query can enforce access and return the permitted rows without a separate round trip to an authorization service. Running the checks adds database work, and evaluating a rule in SQL may cost more than evaluating it in a dedicated engine. Our premise is that avoiding network round trips and moving data between services can more than offset that cost. What matters is the time and total cost of serving an authorized request, including access to the data itself.

### Give Postgres more ways to express access

RLS provides the enforcement point. Established authorization models provide ways to describe the rules. Combining them lets an application use roles for organization-wide access, relationships for individual shares, and row attributes for rules such as hiding drafts.

An app can start with roles and add sharing later, without replacing its existing permissions. Each model keeps its own semantics, while RLS policies combine their decisions on the same table. This makes Postgres useful for a wider range of authorization requirements.

### Build on models people and LLMs already know

Established models come with documentation, examples, tooling, and a body of work explaining how to use them. Developers and LLMs can draw on that knowledge when writing authorization rules, instead of learning a language invented for this extension.

Following OpenFGA and Cedar gives us concrete model languages and public test suites to check against. Keeping that familiar model inside Postgres makes it easier for agents to generate useful code and for developers to understand and review it. The [architecture overview](../research/architecture.md) explains why we chose separate model APIs and how future models can fit.

## What you can express

The extension has three permission models in the `permissions` schema:

| Model | Use it for | Example |
| --- | --- | --- |
| Roles and permissions (RBAC) | Roles across an application or within a tenant, with role inheritance | Alice is an editor in Acme and a viewer in Globex. |
| Relationships (OpenFGA) | Individual shares, nested teams, and access inherited from folders | Bob can read a document because it is shared with his team. |
| Policies (Cedar) | Rules on the attributes of the user, the resource and the request, and a deny that always wins | Owners edit their own documents. Nobody opens a confidential document without MFA. |

OpenFGA relationships can also have CEL conditions, such as an expiry time. The models can work together: one RLS policy grants access through a role, another grants it through a share or a Cedar policy, and a restrictive policy can deny access across all of them.

[Choose a permission model](get-started/choose-a-model.md) walks through the options. Each model has its own guide, its own functions and its own data. The structure leaves room for other models alongside them.

## Goals that shape the extension

- Keep authorization close to the data. Permission changes and application queries use Postgres, and RLS enforces access on the rows involved.
- Make read policies practical on large tables. Helpers list accessible scopes or object IDs so a query can compute them once and use an index. [Policy shape matters](rls/performance.md); a per-row check is not always the right choice.
- Work with an application's existing identity system. The extension reads a subject from JWT claims or transaction-local settings. It does not store users or require a Supabase `auth` schema.
- Keep installation portable. The implementation is SQL and PL/pgSQL, supports Postgres 16, 17, and 18, and can be installed without superuser rights. There is no C module or separate authorization service to run.
- Make behavior inspectable. The project uses executable examples, pinned OpenFGA and Cedar test suites, and benchmarks to check its rules and performance. Compatibility differences ([OpenFGA](models/openfga/compatibility.md), [Cedar](models/cedar/compatibility.md)) and [limits](reference/limits.md) are documented explicitly.

## Where it fits in your application

Your authentication system establishes who is making a request. A trusted backend assigns roles or writes sharing relationships, using SQL or the JavaScript client. Application clients can check their own permissions, and RLS policies control which rows their queries can read or change.

A permission check does not read your application tables. If a policy adds a rule such as “only editors can see drafts,” an application check alone does not include that rule. Use checks to guide the interface and let RLS make the final decision about row access.

## Start here

[Install the extension](install.md), then follow the [quickstart](get-started/quickstart.md) to protect a table and compare what two users can see. For an existing application, read [identity and request context](integrations/identity.md) and choose the model that matches your access rules.

The [documentation map](README.md) links to individual tasks. The [research section](../research/README.md) preserves the design experiments and measurements behind the implementation.
