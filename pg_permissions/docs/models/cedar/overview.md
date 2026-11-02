# Policies (Cedar)

Use policies to give or deny access with rules on the user, the action, the resource and the request. The `cedar_*` functions follow the Cedar policy language, with [documented differences](compatibility.md).

Start with [Write policies](policies.md). Then [store entities](entities.md) and [check requests](checks.md). The walkthrough uses one database and builds its data in that order. An admin manages policies and entities. Application clients check access for the current subject.

## What Cedar is

Cedar is an authorization language that Amazon Web Services publishes. A Cedar policy has an effect, a scope and optional conditions:

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

A request names a principal, an action and a resource. Cedar finds the policies whose scope fits it. A `forbid` that applies always wins. Without a `forbid`, one `permit` that applies allows the request. If no policy matches, the answer is `deny`.

Entities are the things that policies talk about: users, teams, folders and documents. An entity has a type and an id. It can have attributes and parent entities. The test `principal in Team::"eng"` is true when the team is the user or one of the ancestors of the user.

## When to use it

| Your rule | Use | Example |
| --- | --- | --- |
| A role grants access, app-wide or in one tenant | [RBAC](../rbac/overview.md) | Editors edit documents in Acme. |
| One object is shared with a user or a team | [OpenFGA](../openfga/overview.md) | Bob views a document that is shared with his team. |
| The rule uses attributes of the user, the resource or the request | Cedar | Owners edit their own documents. Nobody views a confidential document without MFA. |
| The rule needs a deny that beats every grant | Cedar, or a restrictive RLS policy | Block a suspended user everywhere. |
| You want one policy text that people can read and review | Cedar | A security team reviews the policy file. |

Cedar policies are code that you review and deploy. The data they use (entities) changes more often. If you grant access to a single object for each user, store that grant as a relationship in OpenFGA, or as a [template link](templates.md). The models have separate data. They work together through RLS. See [Combine permission models](../../rls/combine-models.md).

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

- Each method returns `{ data, error }`. It does not throw for a database error.
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

If there is no current subject, every check returns `false` and every list is empty. See [Identity and request context](../../integrations/identity.md).

## Supported language

The extension implements Cedar 4.14, with two exceptions:

- It does not validate policies against a schema. A policy with a type error is stored. It gives an evaluation error when a request reaches the error.
- It does not support partial evaluation (unknown values).

Everything else in Cedar 4.14 is supported: all scope forms, `when` and `unless`, `has`, `like`, `is`, `in`, `if-then-else`, sets, records, tags, annotations, templates, and the four extension types (`decimal`, `ipaddr`, `datetime` and `duration`). [Extension types](extensions.md) has the details. The extension passes Cedar's own test suite. [Compatibility](compatibility.md) lists the results and the differences.

## Errors and fail-closed behavior

A mistake in the call raises a Postgres error. Examples are a policy with a syntax error, an unknown policy id, and a uid that is not `Type::"id"`. The `DETAIL` of the error is a stable code that starts with `cedar:`. See [Errors](../../reference/errors.md#cedar-errors).

A mistake in a policy while it runs does not raise an error. Cedar skips that policy and reports the error. Examples are an attribute that does not exist and a type error. `cedar_is_authorized` returns the errors in its answer. Because a skipped `forbid` could have denied the request, the functions for RLS fail closed:

- `cedar_is_authorized_current` returns `false` when a `forbid` that applies gives an error.
- `cedar_list_resources_current` leaves out a resource when a `forbid` that applies gives an error.
- Without a subject, they return `false` and no rows.

`cedar_is_authorized` does not fail closed. It reports the decision and the errors, as Cedar does. Read the `errors` list when you build a tool on it.

## Next step

Continue with [Write policies](policies.md).
