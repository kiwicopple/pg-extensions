# pg_permissions documentation

These pages show how to use `pg_permissions` in an application. Start with [Install](install.md). Then read the page for the model that you use.

The extension has two permission models in one schema, `permissions`. The `rbac_*` functions give roles. The `fga_*` functions give relationships between users and objects, as [OpenFGA](https://openfga.dev) does. Both models work in row level security (RLS) policies.

## Pages

| Page | What it covers |
| --- | --- |
| [Install](install.md) | How to install the extension with database.dev, with psql, as a non-superuser, with pg_tle and with Docker. The requirements. How to check the install. |
| [RBAC](rbac.md) | How the extension finds the current user. Roles, permissions, scopes and the privileges of each function. Two scenarios: app-wide roles and roles for each tenant. |
| [The OpenFGA model](fga.md) | How to write an authorization model and tuples. How to use Check, ListObjects, ListUsers and Read. Contextual tuples and privileges. |
| [OpenFGA conditions](conditions.md) | How to add CEL conditions to tuples. Access that expires, access from an IP range, and the context of a request. |
| [RLS policies](rls.md) | How to write RLS policies for RBAC, and how to use both models in one policy set. Denies, row attributes and conditions in policies. |
| [Function reference](reference.md) | The full signature, arguments and return type of each function. |
| [Errors and limits](errors-and-limits.md) | Each error code, and the limits of the extension. |
| [JavaScript client: setup](javascript.md) | The npm package `permissions`. How to install it, choose an entry point and set the subject. The examples of each call are in the RBAC and OpenFGA pages. |

## Which model do I use

Use RBAC when access depends on the role of a user. For example, editors can edit all documents, or editors can edit all documents of their organization. Roles are the quickest way to start, and most apps start there.

Use the OpenFGA model when access depends on a relationship to one object. Examples are one document that you share with one user, and teams that contain teams. Another example is a folder whose viewers see its documents.

The two models are separate. A role does not give a relation, and a tuple does not give a role. They meet in RLS policies. Permissive policies combine with OR. Restrictive policies combine with AND. A restrictive policy can deny a user across both models.

To move from RBAC to access for single objects, keep your roles and add the OpenFGA model next to them. You do not migrate any data. Write an authorization model and tuples. Then add one permissive policy to the shared table that lists the objects that the current user can view. [RLS policies](rls.md) builds this step by step.

Keep the policy for shared objects separate from the role policy. Do not replace the role policy with one policy that does both. On large tables, the single policy is much slower.

## Conventions in the examples

- Each function call uses named arguments, for example `permissions.fga_check(subject => 'user:anne', relation => 'viewer', object => 'document:1')`.
- The argument `subject` is the `user` field of OpenFGA. `user` is a reserved word in SQL.
- The examples use psql variables for IDs, for example `:'alice'`.
- Run the examples in order. Each page says what it needs from the pages before it.
- Statements that change roles, models or tuples run as the role that installed the extension. This role is the admin.
