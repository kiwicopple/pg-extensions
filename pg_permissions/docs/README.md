# pg_permissions documentation

Use `pg_permissions` to manage application permissions in Postgres and enforce them through row level security (RLS). The extension is pure SQL and runs on Postgres 16, 17, and 18.

New to the project? Read the [overview](overview.md) for its purpose, goals, and how it fits into an application. Then [install the extension](install.md) and [protect a table](get-started/quickstart.md). The quickstart creates roles, grants access, and checks what two users can see.

<span id="which-model-do-i-use"></span>

## Choose a model

[RBAC](models/rbac/overview.md) grants permissions through roles, either app-wide or within a tenant. [OpenFGA](models/openfga/overview.md) grants access through relationships to individual objects. [Cedar](models/cedar/overview.md) grants or denies access with policies on attributes, groups and the request. All three live in the `permissions` schema, and an application can use them on the same table.

Use the [model chooser](get-started/choose-a-model.md) to find the right starting point. Adding object sharing to an RBAC application does not require migrating its role assignments.

<span id="pages"></span>

## Build your application

| Task | Read |
| --- | --- |
| Identify the user making a request | [Identity and request context](integrations/identity.md) |
| Connect from Node or a browser | [JavaScript setup](integrations/javascript.md) |
| Give a backend access to admin functions | [Client and admin privileges](integrations/privileges.md) |
| Assign roles across the application | [App-wide roles](models/rbac/app-wide.md) |
| Give users different roles in each organization | [Tenant-scoped roles](models/rbac/tenants.md) |
| Share an individual document | [Share objects and manage tuples](models/openfga/tuples.md) |
| Grant access that expires | [Conditions and request context](models/openfga/conditions.md) |
| Write policies with conditions and denies | [Write policies](models/cedar/policies.md) |
| Link one policy shape to many users | [Use policy templates](models/cedar/templates.md) |
| Protect a table with a Cedar policy | [Policies for Cedar](rls/policies.md#policies-for-cedar) |
| Enforce roles and shares on one table | [Combine permission models](rls/combine-models.md) |
| Remove permissions when a user is deleted | [Delete users and clean up permissions](integrations/cleanup.md) |

## Reference and research

Look up [shared SQL functions](reference/shared.md), [RBAC functions](reference/rbac.md), [OpenFGA functions](reference/openfga.md), [Cedar functions](reference/cedar.md), or [JavaScript methods](reference/javascript.md). [Errors](reference/errors.md), [limits](reference/limits.md), and [CEL support](reference/cel.md) have their own reference pages.

[Research and design](../research/README.md) explains the architecture and preserves the earlier prototypes, measurements, and decisions. Those prototypes are historical implementations, not installation choices.

<span id="conventions-in-the-examples"></span>

## Example conventions

SQL examples use named arguments and lowercase keywords. JavaScript equivalents appear alongside SQL. Each task page states its prerequisites; run its steps in order unless a block is marked as a fragment or an expected error.

The examples call the extension owner the admin. Functions that change roles, models, tuples, Cedar policies or entities run as that role or an explicitly authorized backend. Policy tests switch to the application's database role so that RLS applies.

Some examples use psql variables, such as `:'alice'`. The OpenFGA `user` field is named `subject` in SQL because `user` is reserved. JavaScript uses `user` and camel-case argument names.
