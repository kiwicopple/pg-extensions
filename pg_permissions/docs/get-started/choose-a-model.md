# Choose a permission model

Choose the model that describes how your application grants access. Every model stores permission data and provides check and list functions you can call from your backend. You can use more than one model in the same database. RLS is optional and independent of this choice.

| Your rule | Start with | Example |
| --- | --- | --- |
| A role grants access across the application | [App-wide RBAC](../models/rbac/app-wide.md) | Editors can edit documents. |
| A role grants access within an organization | [Tenant-scoped RBAC](../models/rbac/tenants.md) | Alice edits documents in Acme and reads documents in Globex. |
| Access depends on a relationship to one object | [OpenFGA](../models/openfga/overview.md) | Bob views a document shared with his team. |
| A relationship depends on expiry or another attribute | [OpenFGA conditions](../models/openfga/conditions.md) | A document share lasts for 30 days. |
| Access depends on attributes of the user or resource | [Cedar](../models/cedar/overview.md) | Owners edit their own documents unless they are confidential. |
| A backend check needs trusted request facts | [Cedar request context](../models/cedar/checks.md#pass-the-context) | Approving a document requires MFA. |
| A deny must override grants from several models | [Combine model decisions](../integrations/checks.md#combine-model-decisions) | Block a suspended user even if a role or share grants access. |
| You want rules as policy text that people can review | [Cedar](../models/cedar/policies.md) | A security team reviews a policy file. |

## Start with roles, add sharing when needed

RBAC is the shortest path when roles describe your access rules. Its `rbac_*` functions manage roles, permissions, and assignments. A user can hold a role app-wide or in one scope. Those assignments are separate: an app-wide role does not automatically apply within a tenant.

OpenFGA uses `fga_*` functions to manage authorization models and relationship tuples. Use it for individual shares, nested teams, and access inherited from folders. Conditions are part of this model and use a CEL expression on a tuple.

Cedar uses `cedar_*` functions to manage policies and entities. Policies permit or forbid actions on resources, with conditions on attributes or trusted request context. Use it for rules expressed as policy text, including attribute checks, nested groups and explicit denies. A Cedar `forbid` overrides every matching `permit` in Cedar.

Request context is available to the admin check. The current-subject functions accept no request context; they use stored entities and can receive resource attributes from your backend or an RLS policy. See [Check access](../models/cedar/checks.md#check-for-the-current-subject).

The three models have separate data and APIs. A role does not create a relationship, a relationship does not assign a role, and a Cedar policy does not read either. Your backend can combine their results into one decision. For example, allow a role or a share to grant access, while requiring a suspension check to pass.

To add sharing to an existing RBAC application, keep the roles and add OpenFGA tuples and checks. If you enforce table access with RLS, [Combine models with RLS](../rls/combine-models.md) shows separate policies for each model and a restrictive policy for a deny across them. Keeping those grant policies separate can improve query performance.

## How the models compare

| | RBAC | OpenFGA | Cedar |
| --- | --- | --- | --- |
| You write | Roles, permissions, assignments | An authorization model, and tuples | Policies, and entities |
| A rule is | A role has a permission in a scope | A relationship between a user and an object | A `permit` or a `forbid` with conditions |
| Attributes | No | On a relationship, with CEL conditions | On entities, on the resource and in the context |
| Deny behavior | No explicit deny; a missing grant returns false | `but not` excludes access through that relation | `forbid` overrides Cedar permits |
| Groups | Role inheritance | Teams and nested teams | Any hierarchy of entities |
| The check for the current user | `rbac_has_permission` | `fga_check_current` | `cedar_is_authorized_current` |
| A list of accessible scopes or resources | `rbac_scopes_with_permission` | `fga_list_object_ids_current` | `cedar_list_resources_current` |
| How you represent a share | A role assignment in an object scope | A tuple | Entity data used by a policy, or a template link |

Denies within OpenFGA or Cedar do not automatically override another model's answer. Apply a deny across models in your backend's combined decision, or use a restrictive policy if you choose RLS.

## Choose where to enforce access

[Check access in your application](../integrations/checks.md) covers backend enforcement with SQL or JavaScript. Use it to authorize API requests, server functions or other operations. The backend handles the result before carrying out the operation.

[RLS policies](../rls/policies.md) are an optional way to enforce access on database rows. They can call the model functions and add conditions on row columns, such as allowing only editors to see drafts. A Cedar policy defines a rule in the Cedar language; it works with either enforcement approach and does not require an RLS policy.

## Other models

ABAC describes a category of authorization rules. Use Cedar for attributes of the user, the resource and the request, and OpenFGA conditions for attributes on a relationship. Your backend can supply trusted resource attributes; an RLS policy can supply them from a row. CEL support here is part of OpenFGA conditions, not a separate authorization model.
