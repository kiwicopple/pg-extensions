# Check access in your application

Use `pg_permissions` as the authorization store and check engine behind your API, server functions, or background jobs. Store roles, relationships or Cedar policies in Postgres, call a function to evaluate access, and use the result to allow or reject an operation. You do not need to enable RLS or create application tables to use the models.

This is an alternative to running a separate authorization service when Postgres fits your application. Choose a [permission model](../get-started/choose-a-model.md), then use its management, check and list functions. If you are moving from an existing tool, compare its behavior with the [OpenFGA](../models/openfga/compatibility.md) or [Cedar](../models/cedar/compatibility.md) compatibility notes and map your calls to the [SQL and JavaScript APIs](../reference/javascript.md).

## Make a permission check

Complete the role assignment in the [quickstart](../get-started/quickstart.md#create-a-permission-and-assign-it). For JavaScript, create the server client described in [JavaScript setup](javascript.md). The examples below use its `permissions` variable.

Alice has `documents.read` in Acme. Check that permission directly:

```sql tab="SQL"
begin;
select set_config('permissions.subject_id', 'alice', true);
select permissions.rbac_has_permission(
  permission => 'documents.read',
  scope => 'acme'
);
-- true
commit;
```

```ts tab="JavaScript"
const { data: allowed, error } = await permissions
  .as({ id: 'alice' })
  .rbac.hasPermission({
    permission: 'documents.read',
    scope: 'acme',
  })

if (error) throw error
console.log(allowed) // true
```

The subject identifies the application user, separately from the Postgres role used by the connection. A trusted backend sets it from the authenticated request. The SQL setting is transaction-local; `as({ id })` sets and clears it for each client call. See [Identity and request context](identity.md).

## Enforce the result in your backend

A check returns a result. Your request handler must act on it before returning data or carrying out the protected operation. This server-side fragment assumes `user` comes from your authentication system and `orgId` is the organization the request wants to access:

```ts
const { data: allowed, error } = await permissions
  .as({ id: user.id })
  .rbac.hasPermission({
    permission: 'documents.read',
    scope: orgId,
  })

if (error) throw error
if (!allowed) throw new Error('Forbidden')

// Now fetch documents for orgId, or perform the authorized action.
```

Use the same subject, resource and action in the check and the operation. When access depends on data that can change during the operation, keep the check and operation together with the transaction and locking behavior your application needs. `as()` wraps the permission call only; it does not include subsequent application queries in its transaction.

A browser can use the same checks to show or hide controls. Its answer is not enforcement: the backend must run its own check, or the database must enforce a policy. A caller must not be able to bypass the check by reaching the protected operation through another endpoint.

## Check or list access with each model

| Model | Check one permission or resource | List access |
| --- | --- | --- |
| RBAC | `rbac_has_permission` / `rbac.hasPermission` | `rbac_scopes_with_permission` / `rbac.scopesWithPermission` |
| OpenFGA | `fga_check_current` / `fga.check` | `fga_list_object_ids_current` / `fga.listObjects({ idsOnly: true, ... })` |
| Cedar | `cedar_is_authorized_current` / `cedar.isAuthorized` | `cedar_list_resources_current` / `cedar.listResources` |

These functions answer for the current subject and work both in application checks and in RLS policies. Their results describe permission data. They do not query your application tables or include rules defined only in RLS.

Use lists to filter application queries or build a list of available resources. An RBAC list returns scopes; OpenFGA returns modeled objects; Cedar lists stored entities. The model guides describe result limits and behavior: [RBAC](../models/rbac/tenants.md), [OpenFGA](../models/openfga/checks.md), and [Cedar](../models/cedar/checks.md).

## Trusted request context and resource attributes

The OpenFGA and Cedar admin checks accept an explicit subject and trusted request context. They are useful in a backend which knows facts such as an MFA result or the current time. Current-subject functions do not accept request context. Choose the API according to the inputs you need and the [privileges](privileges.md) of the caller.

For Cedar, `cedar_is_authorized_current` can take `resource_attrs` (`resourceAttrs` in JavaScript). A backend can supply attributes read from its own data, without copying them into Cedar's entity store. Do not use unverified attributes from the browser to decide whether to authorize a backend operation. See [Cedar checks](../models/cedar/checks.md#check-for-the-current-subject).

Cedar's admin check returns a decision and diagnostics. Following Cedar semantics, a policy that fails during evaluation is skipped, including a failing `forbid`. Inspect the errors as well as the decision. The current-subject functions instead deny access when a relevant forbid fails to evaluate. This difference applies whether or not you use RLS.

## Combine model decisions

The models keep separate data and semantics. Your backend can grant access when either a role or an individual share allows it, while requiring a separate suspension check to pass. Define this combination explicitly and handle errors before granting access.

A Cedar `forbid` overrides Cedar permits. It does not automatically override a positive RBAC or OpenFGA result. If a deny must apply across models, enforce it in the backend's combined decision. With RLS, a restrictive policy can serve that purpose.

## Optional: enforce access with RLS

Use RLS when you want Postgres to apply authorization to table reads and writes. An RLS policy calls the same check or list functions; the database then filters rows or rejects writes according to the policy. [Read and write policies](../rls/policies.md) covers setup, and [Combine models with RLS](../rls/combine-models.md) covers grants and denies across models.

A Cedar policy is a rule evaluated by the Cedar engine. An RLS policy is a Postgres rule on a table. Storing and evaluating Cedar policies does not require RLS.
