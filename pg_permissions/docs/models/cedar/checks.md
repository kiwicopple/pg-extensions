# Check access

Check whether a principal can perform an action on a resource, then inspect the policies behind the decision and any evaluation errors.

First complete [Write policies](policies.md), [Store entities](entities.md) and [Use policy templates](templates.md). The examples use their policies and entities. The function `cedar_is_authorized` accepts an explicit principal and is admin-only. [Check for the current subject](#check-for-the-current-subject) covers the functions available to application clients.

## Check a request

`cedar_is_authorized` evaluates one request and returns the answer as JSON. It takes three uids in Cedar text, an optional `context` and optional `entities`. Each example names every argument:

```sql tab="SQL"
select permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"view"',
  resource => 'Document::"q3"'
);
-- {"errors": [], "reasons": ["eng-view-reports"], "decision": "allow"}
-- Alice is in eng, and q3 is in the folder reports.
select permissions.cedar_is_authorized(
  principal => 'user::"bob"',
  action => 'Action::"edit"',
  resource => 'Document::"q3"'
);
-- {"errors": [], "reasons": ["owner-edit"], "decision": "allow"}
-- Bob owns q3.
select permissions.cedar_is_authorized(
  principal => 'user::"carol"',
  action => 'Action::"edit"',
  resource => 'Document::"q3"'
);
-- {"errors": [], "reasons": [], "decision": "deny"}
-- No policy applies: the default is deny.
```

```ts tab="JavaScript"
const { data: alice } = await permissions.cedar.admin.isAuthorized({
  principal: { type: 'user', id: 'alice' },
  action: 'Action::"view"',
  resource: 'Document::"q3"',
})
// {
//   decision: 'allow',
//   diagnostics: { reason: ['eng-view-reports'], errors: [] },
// }
const { data: bob } = await permissions.cedar.admin.isAuthorized({
  principal: { type: 'user', id: 'bob' },
  action: 'Action::"edit"',
  resource: 'Document::"q3"',
})
// allow, reason: ['owner-edit']
const { data: carol } = await permissions.cedar.admin.isAuthorized({
  principal: { type: 'user', id: 'carol' },
  action: 'Action::"edit"',
  resource: 'Document::"q3"',
})
// deny, reason: []
```

### The response

| Field | Content |
| --- | --- |
| `decision` | `allow` or `deny` |
| `reasons` | The ids of the policies that decided. For a `deny`, these are the `forbid` policies that apply. For an `allow`, these are the `permit` policies that apply. It is empty for the default deny. The ids are sorted. |
| `errors` | One `{"policy_id", "message"}` for each policy that failed. The policy is skipped. It neither permits nor forbids. The ids are sorted. |

The JavaScript client gives the shape of Cedar's own JavaScript API. `reasons` is `diagnostics.reason`. Each error is `{ policyId, error: { message } }`. The SQL function returns the shorter form.

The algorithm is Cedar's:

1. Find the policies whose scope matches the principal, the action and the resource.
2. Evaluate the conditions of these policies. A policy applies when its conditions are true.
3. If a `forbid` applies, the decision is `deny`. A `forbid` always wins.
4. Else, if a `permit` applies, the decision is `allow`.
5. Else, the decision is `deny`.

A `forbid` policy wins over any number of `permit` policies. The policy `no-confidential` denies Alice, who owns the document `salaries`:

```sql tab="SQL"
select permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"view"',
  resource => 'Document::"salaries"'
);
-- {"errors": [], "reasons": ["no-confidential"], "decision": "deny"}
```

```ts tab="JavaScript"
const { data } = await permissions.cedar.admin.isAuthorized({
  principal: { type: 'user', id: 'alice' },
  action: 'Action::"view"',
  resource: 'Document::"salaries"',
})
// deny, reason: ['no-confidential']
```

## Pass the context

The `context` is a JSON object with facts about the request, such as the time or the IP address of the client. A policy reads it as `context.name`. Put a policy that needs a multi-factor login for the action `approve`:

```sql tab="SQL"
select permissions.cedar_put_policy(
  policy_id => 'approve-with-mfa',
  policy => 'permit (
  principal in Team::"eng",
  action == Action::"approve",
  resource
)
when { context.mfa };'
);
select permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"approve"',
  resource => 'Document::"q3"',
  context => '{"mfa": true}'
);
-- {"errors": [], "reasons": ["approve-with-mfa"], "decision": "allow"}
```

```ts tab="JavaScript"
const approve = `permit (
  principal in Team::"eng",
  action == Action::"approve",
  resource
)
when { context.mfa };`
await permissions.cedar.admin.putPolicy({
  policyId: 'approve-with-mfa',
  policy: approve,
})
const { data } = await permissions.cedar.admin.isAuthorized({
  principal: { type: 'user', id: 'alice' },
  action: 'Action::"approve"',
  resource: 'Document::"q3"',
  context: { mfa: true },
})
// allow, reason: ['approve-with-mfa']
```

The context is a record. Its values follow the same rules as [attribute values](entities.md#attribute-values). A context that is not a JSON object is the error `cedar:invalid_context`.

## Read the errors

A policy can fail while it runs. Cedar does not raise an error for this. It skips the policy and reports the failure. Without a context, the condition `context.mfa` has no attribute to read:

```sql tab="SQL"
select permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"approve"',
  resource => 'Document::"q3"'
);
-- {
--   "errors": [
--     {
--       "message": "attribute_not_found: the record has no attribute \"mfa\"",
--       "policy_id": "approve-with-mfa"
--     }
--   ],
--   "reasons": [],
--   "decision": "deny"
-- }
```

```ts tab="JavaScript"
const { data } = await permissions.cedar.admin.isAuthorized({
  principal: { type: 'user', id: 'alice' },
  action: 'Action::"approve"',
  resource: 'Document::"q3"',
})
// data?.decision: 'deny'
// data?.diagnostics.errors[0].policyId: 'approve-with-mfa'
```

The message starts with a code, then a colon and a detail. The codes follow the evaluation errors of Cedar:

| Code | Cause |
| --- | --- |
| `attribute_not_found` | The expression reads an attribute that the entity or the record does not have. Test with `has` first. |
| `entity_does_not_exist` | The expression reads an attribute of an entity that is not stored. |
| `tag_not_found` | `getTag` reads a tag that the entity does not have. Test with `hasTag` first. |
| `type_error` | An operator or a method got a value of the wrong type. |
| `overflow` | A Long operation went outside -2^63 to 2^63-1. |
| `extension_error` | An extension function got a value that it cannot read, such as `decimal("1.23456")`. |

The text of the message is not stable. Match on the code at the start. The policy ids in `errors` are the stable part.

A failed `forbid` does not block access: Cedar skips it, so another matching permit can still allow the request. Inspect `errors` as well as `decision` in a backend check. The RLS helpers deny access when a relevant `forbid` fails to evaluate. See [Check for the current subject](#check-for-the-current-subject).

To avoid a missing-attribute error, check before reading: `context has mfa && context.mfa`. The operator `&&` skips its right side when the left side is false. The value must still have the expected type. In a `forbid`, this guard makes the condition false when `mfa` is missing; if missing MFA should deny access, write that case into the condition too.

## Check with entities that are not stored

The argument `entities` is an array of entities for this request only. It has the format of [`cedar_put_entities`](entities.md#put-entities). An entity in `entities` replaces the stored entity that has the same uid, for this request. Nothing is stored. At most 1,000 entities are allowed.

Use this to ask a question about data that is not in the database. Dave has no stored entity. This request says that he is in `eng`:

```sql tab="SQL"
select permissions.cedar_is_authorized(
  principal => 'user::"dave"',
  action => 'Action::"view"',
  resource => 'Document::"q3"'
);
-- {"errors": [], "reasons": [], "decision": "deny"}
select permissions.cedar_is_authorized(
  principal => 'user::"dave"',
  action => 'Action::"view"',
  resource => 'Document::"q3"',
  entities => '[
    {
      "uid": {"type": "user", "id": "dave"},
      "parents": [{"type": "Team", "id": "eng"}]
    }
  ]'
);
-- {"errors": [], "reasons": ["eng-view-reports"], "decision": "allow"}
```

```ts tab="JavaScript"
const { data: before } = await permissions.cedar.admin.isAuthorized({
  principal: { type: 'user', id: 'dave' },
  action: 'Action::"view"',
  resource: 'Document::"q3"',
})
// deny, reason: []
const { data: after } = await permissions.cedar.admin.isAuthorized({
  principal: { type: 'user', id: 'dave' },
  action: 'Action::"view"',
  resource: 'Document::"q3"',
  entities: [
    {
      uid: { type: 'user', id: 'dave' },
      parents: [{ type: 'Team', id: 'eng' }],
    },
  ],
})
// allow, reason: ['eng-view-reports']
```

An overlay entity replaces the whole stored entity, with its attributes, parents and tags. It does not merge with it. To test a change to a document, send the full document.

The overlay costs more than stored entities. In one measurement, a request with 10 policies took 79 µs on stored entities and 263 µs with the principal and the resource in the overlay ([the design record](../../../research/designs/e-cedar.md#122-requests) has the setup).

An overlay can make a cycle, and the extension does not check for it, because the check would cost every request a walk. The test `in` still ends. In a cycle, the entities are ancestors of each other.

## Errors in the call

A mistake in the call raises an error. It does not return a `deny`:

```sql
select permissions.cedar_is_authorized(
  principal => 'user:alice',
  action => 'Action::"view"',
  resource => 'Document::"q3"'
);
-- ERROR:  invalid entity uid for principal: user:alice: it is not Type::"id"
-- DETAIL:  cedar:invalid_uid value='user:alice'
-- HINT:  Write a uid as Cedar text, a type and a quoted id: principal => 'User::"alice"' (a namespaced type: 'App::User::"alice"').
```

A uid has the form `Type::"id"`. A namespaced type is `App::User::"alice"`. Use `cedar_uid(type, id)` to build the text from a value that can hold a `"` or a `\`. In JavaScript, pass `{ type, id }`, or use `uid(type, id)`. See [Reference](../../reference/cedar.md#cedar_uid).

## Check for the current subject

Clients cannot call `cedar_is_authorized`, because it accepts any principal. Clients call two functions that answer for the current subject:

| Function | Returns |
| --- | --- |
| `cedar_is_authorized_current(action, resource, resource_attrs)` | `true` or `false` |
| `cedar_list_resources_current(action, resource_type)` | The ids of the resources, without the type |

In JavaScript, `cedar.isAuthorized` calls `cedar_is_authorized_current`, and `cedar.listResources` calls `cedar_list_resources_current`.

The principal comes from `current_subject_type()` and `current_subject_id()`, as `type::"id"`. The default type is `user`. These helpers use an empty request context. Set the subject for the transaction so it is cleared before a pooled connection serves another request:

```sql tab="SQL"
begin;
select set_config('permissions.subject_id', 'alice', true);
select permissions.cedar_is_authorized_current(
  action => 'Action::"view"',
  resource => 'Document::"q3"'
);
-- true
select permissions.cedar_is_authorized_current(
  action => 'Action::"view"',
  resource => 'Document::"salaries"'
);
-- false: no-confidential forbids it
select permissions.cedar_list_resources_current(
  action => 'Action::"view"',
  resource_type => 'Document'
);
-- q3
commit;

select permissions.cedar_is_authorized_current(
  action => 'Action::"view"',
  resource => 'Document::"q3"'
);
-- false: no subject, no access
```

```ts tab="JavaScript"
const asAlice = permissions.as({ id: 'alice' })

const { data: canView } = await asAlice.cedar.isAuthorized({
  action: 'Action::"view"',
  resource: { type: 'Document', id: 'q3' },
})
// true
const { data: canViewSalaries } = await asAlice.cedar.isAuthorized({
  action: 'Action::"view"',
  resource: { type: 'Document', id: 'salaries' },
})
// false: no-confidential forbids it
const { data: ids } = await asAlice.cedar.listResources({
  action: 'Action::"view"',
  resourceType: 'Document',
})
// ['q3']

// A client has no subject until you call as().
const { data: nobody } = await permissions.cedar.isAuthorized({
  action: 'Action::"view"',
  resource: { type: 'Document', id: 'q3' },
})
// false: no subject, no access
```

These functions fail closed:

- With no subject, `cedar_is_authorized_current` returns `false` and `cedar_list_resources_current` returns no rows.
- If a `forbid` that applies gives an error, the check returns `false`, and the list leaves out that resource.
- A `permit` that gives an error is skipped, as in Cedar. It gives no access.

These helpers accept neither request context nor a request entity overlay. Policies that require a context value, such as `context.mfa`, cannot obtain it through these calls. A failing permit grants no access; another matching permit can still allow access unless a forbid blocks it.

The optional `resource_attrs` argument of `cedar_is_authorized_current` replaces the resource's attributes for that check. Parents and tags still come from storage, and the resource itself need not be stored. In RLS, supply the attributes from the actual row. Attributes supplied by an application client are useful for a UI check but are not trusted evidence of row access. See [Cedar in RLS](../../rls/policies.md#policies-for-cedar).

`cedar_list_resources_current` returns stored entities only, with no result cap. A resource mentioned in a policy but absent from the entity store will not appear in the list. A direct check can still allow that resource if the policies permit it.

## Next step

Continue with [Extension types](extensions.md), or go to [Cedar in RLS](../../rls/policies.md#policies-for-cedar).
