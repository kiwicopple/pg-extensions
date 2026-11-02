# Policies (Cedar)

Use Cedar to express authorization rules as policy text. A policy can check who is making a request, what they want to do, and attributes of the resource they want to access. The `cedar_*` functions evaluate those rules inside Postgres, with [documented differences](compatibility.md) from the Cedar libraries.

Cedar is included in `pg_permissions` 0.1.0. [Install or upgrade](../../install.md) before starting. An admin manages policies and entities; application clients check access for the current subject.

The walkthrough builds one example across four pages. Follow them in order:

1. [Write policies](policies.md) for team access, ownership and confidential documents.
2. [Store entities](entities.md) for the users, teams, folders and documents those policies use.
3. [Use policy templates](templates.md) to reuse a rule with different principals or resources.
4. [Check access](checks.md), inspect errors, and then [protect a table with RLS](../../rls/policies.md#policies-for-cedar).

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
| A deny must override RBAC, OpenFGA and Cedar grants | A restrictive RLS policy | Block a suspended user across all models. |
| You want one policy text that people can read and review | Cedar | A security team reviews the policy file. |

Cedar policies are code that you review and deploy. The entities they use change as users join teams or documents move between folders. Individual shares can use OpenFGA relationships or Cedar [template links](templates.md). Each model has its own data, and their decisions combine through RLS. See [Combine permission models](../../rls/combine-models.md).

Request facts such as MFA status are available through the admin check's `context` argument. The current-subject helpers used by clients and RLS do not accept request context. They use stored entities; a row check can also receive the row's attributes.

## Use from JavaScript

An example that has a JavaScript equivalent shows it next to the SQL. The JavaScript examples use [the JavaScript client](../../integrations/javascript.md). Install the client first.

The admin calls use the server client:

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)
```

The JavaScript examples throughout this walkthrough use `permissions`. Some things differ from SQL:

- By default, each method returns `{ data, error }` rather than throwing for a database error.
- Policies are strings, and entities, context and requests are JavaScript objects. You do not write JSON strings.
- Names with an underscore are in camel case: `policyId` for `policy_id`, `resourceAttrs` for `resource_attrs`.
- A uid is Cedar text (`'Document::"q3"'`) or an object (`{ type: 'Document', id: 'q3' }`). The client escapes an object. To build the text yourself, use `uid(type, id)`.
- A check for a user runs through `as({ id })`. It sets the current subject for each call.
- Admin methods are in `permissions.cedar.admin`. Methods for the current subject are in `permissions.cedar`.

## How the functions map to Cedar

| Cedar | pg_permissions |
| --- | --- |
| A policy in a policy set | `cedar_put_policy`, `cedar_delete_policy`, `cedar_policies` |
| A policy template and its links | `cedar_put_template`, `cedar_link_template`, `cedar_delete_template`, `cedar_templates` |
| The entities | `cedar_put_entities`, `cedar_delete_entities`, `cedar_read_entities` |
| `isAuthorized` | `cedar_is_authorized` |
| Not in Cedar: a check for the current subject | `cedar_is_authorized_current`, `cedar_list_resources_current` |
| Not in Cedar: a safe uid from a row id | `cedar_uid` |

The extension keeps one policy set and one entity store in each database. There is no store id. A policy id names a policy. [Write policies](policies.md) explains the ids.

The policies of a database can name entities of any type. The extension does not read a Cedar schema, so it does not check types or names in a policy. See [Compatibility](compatibility.md).

## The subject is the principal

For a check with `cedar_is_authorized_current`, the principal is the current subject: `current_subject_type()` and `current_subject_id()`, written as `type::"id"`. The default type is `user`, so the principal is `user::"alice"`. Write the policies with the same type. To use `User`, set `permissions.subject_type` to `User`. A policy can also use `principal is user`.

If there is no current subject, current-subject checks return `false` and lists are empty. See [Identity and request context](../../integrations/identity.md).

## Supported language

The extension targets Cedar 4.14. Two features are outside its scope:

- It does not validate policies against a schema. A policy with a type error is stored. It gives an evaluation error when a request reaches the error.
- It does not support partial evaluation (unknown values).

Supported features include all scope forms, `when` and `unless`, `has`, `like`, `is`, `in`, `if-then-else`, sets, records, tags, annotations, templates, and the four extension types (`decimal`, `ipaddr`, `datetime` and `duration`). See [Extension types](extensions.md) for examples. [Compatibility](compatibility.md) records the pinned upstream test results, storage differences and limits, including Postgres's restriction on U+0000.

## Errors and fail-closed behavior

A mistake in the call raises a Postgres error. Examples are a policy with a syntax error, an unknown policy id, and a uid that is not `Type::"id"`. The `DETAIL` of the error is a stable code that starts with `cedar:`. See [Errors](../../reference/errors.md#cedar-errors).

A policy can fail during evaluation, for example when it reads a missing attribute or uses a value of the wrong type. The admin check skips that policy and reports it in `errors`. A skipped `forbid` might have denied the request, so the RLS helpers use stricter behavior:

- `cedar_is_authorized_current` returns `false` when a `forbid` that applies gives an error.
- `cedar_list_resources_current` leaves out a resource when a `forbid` that applies gives an error.
- Without a subject, they return `false` and no rows.

The admin check can return `allow` alongside evaluation errors, following Cedar's semantics. Inspect both the decision and `errors` when using it to authorize a backend operation. The RLS helpers deny access if a relevant `forbid` fails to evaluate.

## Next step

Continue with [Write policies](policies.md).
