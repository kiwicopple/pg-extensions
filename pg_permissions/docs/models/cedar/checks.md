# Check access

Check whether a principal can perform an action on a resource, then inspect the policies behind the decision and any evaluation errors.

First complete [Write policies](policies.md), [Store entities](entities.md) and [Use policy templates](templates.md). The examples use their policies and entities. Start with a check for the signed-in user. An admin check can also supply a principal explicitly and inspect the decision.

## Check for the current subject

Use `cedar.isAuthorized` to check a single operation and `cedar.listResources` to find the IDs of permitted resources of one type.

On the backend, pass the user ID from your verified session to `permissions.as`. An authenticated browser client already has its subject. The default principal type is `user` and these checks use an empty request context. For direct SQL, set the subject inside the transaction.

```js tab="JavaScript"
const asAlice = permissions.as({ id: 'alice' })

const { data: canView, error } = await asAlice.cedar.isAuthorized({
  action: 'Action::"view"',
  resource: { type: 'Document', id: 'q3' },
})
if (error) throw error
// canView: true
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

// The server connection has no subject outside this call.
const { data: nobody } = await permissions.cedar.isAuthorized({
  action: 'Action::"view"',
  resource: { type: 'Document', id: 'q3' },
})
// false: no subject, no access
```

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

These functions fail closed:

- With no subject, `cedar_is_authorized_current` returns `false` and `cedar_list_resources_current` returns no rows.
- If a `forbid` that applies gives an error, the check returns `false`, and the list leaves out that resource.
- A `permit` that gives an error is skipped, as in Cedar. It gives no access.

These helpers accept neither request context nor a request entity overlay. Policies that require a context value, such as `context.mfa`, cannot obtain it through these calls. A failing permit grants no access; another matching permit can still allow access unless a forbid blocks it.

The optional `resource_attrs` argument of `cedar_is_authorized_current` replaces the resource's attributes for that check. Parents and tags still come from storage, and the resource itself need not be stored. For backend enforcement, supply attributes from trusted application data. Browser-supplied attributes can guide a UI but must not establish access to a backend operation. If you use RLS, supply attributes from the actual row. See [Application checks](../../integrations/checks.md) and [Cedar in RLS](../../rls/policies.md#policies-for-cedar).

`cedar_list_resources_current` returns stored entities only, with no result cap. A resource mentioned in a policy but absent from the entity store will not appear in the list. A direct check can still allow that resource if the policies permit it.

## Check a request

Use `permissions.cedar.admin.isAuthorized` when you need a decision for an explicit principal, trusted request context, or the IDs of matching policies. Pass the principal, action and resource as Cedar text or UID objects.

```js tab="JavaScript"
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

### The response

| JavaScript field (on `data`) | SQL field | Content |
| --- | --- | --- |
| `decision` | `decision` | `allow` or `deny` |
| `diagnostics.reason` | `reasons` | The ids of the policies that decided. For a `deny`, these are the `forbid` policies that apply. For an `allow`, these are the `permit` policies that apply. It is empty for the default deny. The ids are sorted. |
| `diagnostics.errors` | `errors` | The ID and error message for each policy that failed. Cedar skips those policies. The ids are sorted. |

In JavaScript each diagnostic error is `{ policyId, error: { message } }`. SQL returns `{ policy_id, message }`. A failed database call returns a top-level `error` in the client instead of a decision.

The algorithm is Cedar's:

1. Find the policies whose scope matches the principal, the action and the resource.
2. Evaluate the conditions of these policies. A policy applies when its conditions are true.
3. If a `forbid` applies, the decision is `deny`. A `forbid` always wins.
4. Else, if a `permit` applies, the decision is `allow`.
5. Else, the decision is `deny`.

A `forbid` policy wins over any number of `permit` policies. The policy `no-confidential` denies Alice, who owns the document `salaries`:

```js tab="JavaScript"
const { data: salaries } = await permissions.cedar.admin.isAuthorized({
  principal: { type: 'user', id: 'alice' },
  action: 'Action::"view"',
  resource: 'Document::"salaries"',
})
// deny, reason: ['no-confidential']
```

```sql tab="SQL"
select permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"view"',
  resource => 'Document::"salaries"'
);
-- {"errors": [], "reasons": ["no-confidential"], "decision": "deny"}
```

## Pass the context

The `context` is a JSON object with facts about the request, such as the time or the IP address of the client. A policy reads it as `context.name`. Put a policy that needs a multi-factor login for the action `approve`:

```js tab="JavaScript"
const approve = `permit (
  principal in Team::"eng",
  action == Action::"approve",
  resource
)
when { context.mfa };`
const savedApproval = await permissions.cedar.admin.putPolicy({
  policyId: 'approve-with-mfa',
  policy: approve,
})
if (savedApproval.error) throw savedApproval.error
const { data: approval } = await permissions.cedar.admin.isAuthorized({
  principal: { type: 'user', id: 'alice' },
  action: 'Action::"approve"',
  resource: 'Document::"q3"',
  context: { mfa: true },
})
// allow, reason: ['approve-with-mfa']
```

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

The context is a record. Its values follow the same rules as [attribute values](entities.md#attribute-values). A context that is not a JSON object is the error `cedar:invalid_context`.

## Read the errors

A policy can fail while it runs. Cedar does not raise an error for this. It skips the policy and reports the failure. Without a context, the condition `context.mfa` has no attribute to read:

```js tab="JavaScript"
const { data: missingMfa } = await permissions.cedar.admin.isAuthorized({
  principal: { type: 'user', id: 'alice' },
  action: 'Action::"approve"',
  resource: 'Document::"q3"',
})
// missingMfa?.decision: 'deny'
// missingMfa?.diagnostics.errors[0].policyId: 'approve-with-mfa'
```

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

A failed `forbid` does not block access: Cedar skips it, so another matching permit can still allow the request. Inspect `errors` as well as `decision` in a backend check. The current-subject functions deny access when a relevant `forbid` fails to evaluate, in application calls as well as RLS. See [Check for the current subject](#check-for-the-current-subject).

To avoid a missing-attribute error, check before reading: `context has mfa && context.mfa`. The operator `&&` skips its right side when the left side is false. The value must still have the expected type. In a `forbid`, this guard makes the condition false when `mfa` is missing; if missing MFA should deny access, write that case into the condition too.

## Check with entities that are not stored

The argument `entities` is an array of entities for this request only. It has the format of [`cedar_put_entities`](entities.md#put-entities). An entity in `entities` replaces the stored entity that has the same uid, for this request. Nothing is stored. At most 1,000 entities are allowed.

Use this to ask a question about data that is not in the database. Dave has no stored entity. This request says that he is in `eng`:

```js tab="JavaScript"
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

An overlay entity replaces the whole stored entity, with its attributes, parents and tags. It does not merge with it. To test a change to a document, send the full document.

The overlay costs more than stored entities. In one measurement, a request with 10 policies took 79 µs on stored entities and 263 µs with the principal and the resource in the overlay ([the design record](../../../research/designs/e-cedar.md#122-requests) has the setup).

An overlay can make a cycle, and the extension does not check for it, because the check would cost every request a walk. The test `in` still ends. In a cycle, the entities are ancestors of each other.

## Errors in the call

A mistake in the call raises an error. It does not return a `deny`:

```js tab="JavaScript"
const invalid = await permissions.cedar.admin.isAuthorized({
  principal: 'user:alice',
  action: 'Action::"view"',
  resource: 'Document::"q3"',
})
// invalid.error.details: cedar:invalid_uid value='user:alice'
```

```sql tab="SQL"
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

## Next step

Use the results in [your backend](../../integrations/checks.md), continue with [Extension types](extensions.md), or optionally enforce them with [Cedar in RLS](../../rls/policies.md#policies-for-cedar).
