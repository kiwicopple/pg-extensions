# Choose a permission model

Choose the model that describes how your application grants access. You can use more than one model in the same database.

| Your rule | Start with | Example |
| --- | --- | --- |
| A role grants access across the application | [App-wide RBAC](../models/rbac/app-wide.md) | Editors can edit documents. |
| A role grants access within an organization | [Tenant-scoped RBAC](../models/rbac/tenants.md) | Alice edits documents in Acme and reads documents in Globex. |
| Access depends on a relationship to one object | [OpenFGA](../models/openfga/overview.md) | Bob views a document shared with his team. |
| A relationship depends on expiry or another attribute | [OpenFGA conditions](../models/openfga/conditions.md) | A document share lasts for 30 days. |
| Access depends on a column of the row | [RLS row attributes](../rls/denies-and-context.md#row-attributes-that-only-rls-sees) | Only editors can see drafts. |

## Start with roles, add sharing when needed

RBAC is the shortest path when roles describe your access rules. Its `rbac_*` functions manage roles, permissions, and assignments. A user can hold a role app-wide or in one scope. Those assignments are separate: an app-wide role does not automatically apply within a tenant.

OpenFGA uses `fga_*` functions to manage authorization models and relationship tuples. Use it for individual shares, nested teams, and access inherited from folders. Conditions are part of this model and use a CEL expression on a tuple.

The two models have separate data and APIs. A role does not create a relationship, and a relationship does not assign a role. They compose through RLS: permissive policies combine with OR, and restrictive policies combine with AND.

To add sharing to an existing RBAC application, keep the roles and add an OpenFGA policy alongside the role policy. [Combine permission models](../rls/combine-models.md) demonstrates this, including a deny across both models. Keep the policy for shared objects separate from the role policy; combining both checks in one policy can be much slower on large tables.

## Other models

Cedar is a future direction, not an available permission model. The design leaves room for a separate `cedar_*` API alongside RBAC and OpenFGA. Its supported language and behavior will need their own documentation and tests. The [design decision](../../research/decision.md#session-4-direction-per-model-tables) records the rationale.

ABAC describes a category of authorization rules. Today, use RLS for row attributes and OpenFGA conditions for attributes on relationships. CEL support here is part of OpenFGA conditions, not a separate authorization model.
