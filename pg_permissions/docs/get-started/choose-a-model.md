# Choose a permission model

Choose the model that describes how your application grants access. You can use more than one model in the same database.

| Your rule | Start with | Example |
| --- | --- | --- |
| A role grants access across the application | [App-wide RBAC](../models/rbac/app-wide.md) | Editors can edit documents. |
| A role grants access within an organization | [Tenant-scoped RBAC](../models/rbac/tenants.md) | Alice edits documents in Acme and reads documents in Globex. |
| Access depends on a relationship to one object | [OpenFGA](../models/openfga/overview.md) | Bob views a document shared with his team. |
| A relationship depends on expiry or another attribute | [OpenFGA conditions](../models/openfga/conditions.md) | A document share lasts for 30 days. |
| Access depends on a column of the row | [RLS row attributes](../rls/denies-and-context.md#row-attributes-that-only-rls-sees) | Only editors can see drafts. |
| Access depends on attributes of the user, the resource or the request, or you need a deny that beats every grant | [Cedar](../models/cedar/overview.md) | Owners edit their own documents. Nobody opens a confidential document without MFA. |
| You want rules as policy text that people can review | [Cedar](../models/cedar/policies.md) | A security team reviews a policy file. |

## Start with roles, add sharing when needed

RBAC is the shortest path when roles describe your access rules. Its `rbac_*` functions manage roles, permissions, and assignments. A user can hold a role app-wide or in one scope. Those assignments are separate: an app-wide role does not automatically apply within a tenant.

OpenFGA uses `fga_*` functions to manage authorization models and relationship tuples. Use it for individual shares, nested teams, and access inherited from folders. Conditions are part of this model and use a CEL expression on a tuple.

Cedar uses `cedar_*` functions to manage policies and entities. A policy says that a principal can, or cannot, do an action on a resource, with conditions on attributes and on the request. Use it when a rule uses attributes, groups of groups, a deny that always wins, or a request context such as the time or the address of the client. A Cedar `forbid` beats every `permit` in Cedar.

The three models have separate data and APIs. A role does not create a relationship, a relationship does not assign a role, and a Cedar policy does not read either. They compose through RLS: permissive policies combine with OR, and restrictive policies combine with AND.

To add sharing to an existing RBAC application, keep the roles and add an OpenFGA policy alongside the role policy. [Combine permission models](../rls/combine-models.md) demonstrates this, including a deny across both models, and a Cedar policy as a third model. Keep the policy for shared objects separate from the role policy; combining both checks in one policy can be much slower on large tables.

## How the models compare

| | RBAC | OpenFGA | Cedar |
| --- | --- | --- | --- |
| You write | Roles, permissions, assignments | An authorization model, and tuples | Policies, and entities |
| A rule is | A role has a permission in a scope | A relationship between a user and an object | A `permit` or a `forbid` with conditions |
| Attributes | No | On a relationship, with CEL conditions | On entities, on the resource and in the context |
| A deny that wins | A restrictive RLS policy | `but not` in the model | `forbid` |
| Groups | Role inheritance | Teams and nested teams | Any hierarchy of entities |
| The check for the current user | `rbac_has_permission` | `fga_check_current` | `cedar_is_authorized_current` |
| A list of accessible rows | `rbac_scopes_with_permission` | `fga_list_object_ids_current` | `cedar_list_resources_current` |
| Cost to share one object with one user | A role assignment | A tuple | An entity, or a template link |

## Other models

ABAC describes a category of authorization rules. Use Cedar for attributes of the user, the resource and the request. Use RLS for the columns of a row, and OpenFGA conditions for attributes on a relationship. CEL support here is part of OpenFGA conditions, not a separate authorization model.
