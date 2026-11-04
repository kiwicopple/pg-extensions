# Policies (Cedar)

Use Cedar to express authorization rules as policy text. A policy can check who is making a request, what they want to do, and attributes of the resource they want to access. The `cedar_*` functions evaluate those rules inside Postgres, with [documented differences](compatibility.md) from the Cedar libraries.

Store policies and entities here and call the checks from your backend. Cedar policies work without Postgres RLS; RLS is an optional way to apply their decisions to table queries.

[Install the extension](../../install.md) before starting the walkthrough. Use an admin connection to manage policies and entities.

The walkthrough builds one example across four pages. Follow them in order:

1. [Write policies](policies.md) for team access, ownership and confidential documents.
2. [Store entities](entities.md) for the users, teams, folders and documents those policies use.
3. [Use policy templates](templates.md) to reuse a rule with different principals or resources.
4. [Check access](checks.md), inspect errors, and use the decision in your backend. Optionally, [protect a table with RLS](../../rls/policies.md#policies-for-cedar).

## What Cedar is

Cedar is an authorization language developed by AWS. A policy has an effect, a scope and optional conditions:

```text
permit (
  principal in Team::"eng",
  action == Action::"view",
  resource in Folder::"reports"
)
when { resource.level != "confidential" };
```

- The effect is `permit` or `forbid`.
- The scope names the principal (who), the action (what) and the resource (which object). It can match one entity, the members of a group, or a type.
- A condition (`when` or `unless`) is an expression on the principal, the action, the resource and the request `context`.

A request names a principal, an action and a resource. Cedar evaluates the policies that match the request. A matching `forbid` overrides all matching permits. Otherwise, at least one matching `permit` is required to allow access. The default is deny. See [how Cedar authorization works](https://docs.cedarpolicy.com/auth/authorization.html).

Entities are the things that policies refer to: users, teams, folders and documents. Each has a type and an id, and can have attributes, parents and tags. The expression `principal in Team::"eng"` matches a principal that belongs to `eng`, directly or through nested groups. It also matches the team entity itself.

## When to use it

| Your rule | Use | Example |
| --- | --- | --- |
| A role grants access, app-wide or in one tenant | [RBAC](../rbac/overview.md) | Editors edit documents in Acme. |
| One object is shared with a user or a team | [OpenFGA](../openfga/overview.md) | Bob views a document that is shared with his team. |
| The rule uses attributes of the user, the resource or the request | Cedar | Owners edit their own documents. Nobody views a confidential document without MFA. |
| A deny must override other Cedar policies | Cedar `forbid` | A confidentiality rule overrides an ownership grant. |
| A deny must override RBAC, OpenFGA and Cedar grants | [Backend decision logic](../../integrations/checks.md#combine-model-decisions), or a restrictive RLS policy | Block a suspended user across all models. |
| You want one policy text that people can read and review | Cedar | A security team reviews the policy file. |

Cedar policies are authorization rules that you review and deploy. They are stored and evaluated independently of Postgres RLS policies. The entities they use change as users join teams or documents move between folders. Individual shares can use OpenFGA relationships or Cedar [template links](templates.md). Each model has its own data. Your backend can [combine their decisions](../../integrations/checks.md#combine-model-decisions), or you can [combine them through RLS](../../rls/combine-models.md).

Request facts such as MFA status are available through the admin check's `context` argument. The current-subject helpers used by clients and RLS do not accept request context. They use stored entities; a row check can also receive the row's attributes.

## Use from JavaScript

[Install the JavaScript client](../../integrations/javascript.md), then create a server client with a database role that can manage permissions. Keep the connection string on your backend.

```js
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)
```

Store policies through `permissions.cedar.admin`. Pass Cedar text as a string and entity IDs as objects such as `{ type: 'Document', id: 'q3' }`. The client escapes the ID for you. It also accepts Cedar text such as `'Document::"q3"'`.

For a check in your backend, use `permissions.as({ id }).cedar.isAuthorized({ action, resource })` with the user ID from your verified session. Each method returns `{ data, error }` by default. Handle `error` before acting on `data`.

## How the functions map to Cedar

| Operation | JavaScript (`permissions.cedar`) | SQL |
| --- | --- | --- |
| Manage policies | `admin.putPolicy`, `admin.deletePolicy`, `admin.policies` | `cedar_put_policy`, `cedar_delete_policy`, `cedar_policies` |
| Manage templates and links | `admin.putTemplate`, `admin.linkTemplate`, `admin.deleteTemplate`, `admin.templates` | `cedar_put_template`, `cedar_link_template`, `cedar_delete_template`, `cedar_templates` |
| Manage entities | `admin.putEntities`, `admin.deleteEntities`, `admin.readEntities` | `cedar_put_entities`, `cedar_delete_entities`, `cedar_read_entities` |
| Inspect a decision for an explicit principal | `admin.isAuthorized` | `cedar_is_authorized` |
| Check or list access for the current subject | `isAuthorized`, `listResources` | `cedar_is_authorized_current`, `cedar_list_resources_current` |
| Build a Cedar UID | `uid(type, id)`, imported from `permissions/cedar` | `cedar_uid` |

The extension keeps one policy set and one entity store in each database. There is no store id. A policy id names a policy. [Write policies](policies.md) explains the ids.

The policies of a database can name entities of any type. The extension does not read a Cedar schema, so it does not check types or names in a policy. See [Compatibility](compatibility.md).

## The subject is the principal

For a check with `cedar_is_authorized_current`, the principal is the current subject: `current_subject_type()` and `current_subject_id()`, written as `type::"id"`. The default type is `user`, so the principal is `user::"alice"`. Write the policies with the same type. For a principal of type `User`, pass `{ id: 'alice', type: 'User' }` to `permissions.as` or set `permissions.subject_type` in the SQL transaction. A policy can also use `principal is user`.

If there is no current subject, current-subject checks return `false` and lists are empty. See [Identity and request context](../../integrations/identity.md).

## Supported language

The extension targets Cedar 4.14. Two features are outside its scope:

- It does not validate policies against a schema. A policy with a type error is stored. It gives an evaluation error when a request reaches the error.
- It does not support partial evaluation (unknown values).

Supported features include all scope forms, `when` and `unless`, `has`, `like`, `is`, `in`, `if-then-else`, sets, records, tags, annotations, templates, and the four extension types (`decimal`, `ipaddr`, `datetime` and `duration`). See [Extension types](extensions.md) for examples. [Compatibility](compatibility.md) records the pinned upstream test results, storage differences and limits, including Postgres's restriction on U+0000.

## Errors and fail-closed behavior

A mistake in the call raises a Postgres error. Examples are a policy with a syntax error, an unknown policy id, and a uid that is not `Type::"id"`. The `DETAIL` of the error is a stable code that starts with `cedar:`. See [Errors](../../reference/errors.md#cedar-errors).

A policy can fail during evaluation, for example when it reads a missing attribute or uses a value of the wrong type. The admin check skips that policy and reports it in `errors`. A skipped `forbid` might have denied the request, so the current-subject functions use stricter behavior:

- `cedar_is_authorized_current` returns `false` when a `forbid` that applies gives an error.
- `cedar_list_resources_current` leaves out a resource when a `forbid` that applies gives an error.
- Without a subject, they return `false` and no rows.

The admin check can return `allow` alongside evaluation errors, following Cedar's semantics. Inspect both the decision and `errors` when using it to authorize a backend operation. The current-subject functions deny access if a relevant `forbid` fails to evaluate, whether called from application code or RLS.

## Next step

Continue with [Write policies](policies.md).
