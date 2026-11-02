# Write policies

Store the policies that give or deny access. Put each policy with its own id. Replace a policy: put it again with the same id. Delete it when you do not need it.

Install the extension in a fresh database and connect as its owner. For JavaScript, create the [server client](overview.md#use-from-javascript). The later pages use the policies from this page. The admin role runs every call here. A client role cannot call these functions (see [Privileges](../../integrations/privileges.md#cedar-functions)).

## Put a policy in Cedar text

`cedar_put_policy` takes a policy id and one policy. The policy is Cedar text, as in the [Cedar documentation](https://docs.cedarpolicy.com/policies/syntax-policy.html). Engineers in the team `eng` can view the documents in the folder `reports`:

```sql tab="SQL"
select permissions.cedar_put_policy(
  policy_id => 'eng-view-reports',
  policy => 'permit (
  principal in Team::"eng",
  action == Action::"view",
  resource in Folder::"reports"
);'
);
```

```ts tab="JavaScript"
const policy = `permit (
  principal in Team::"eng",
  action == Action::"view",
  resource in Folder::"reports"
);`
await permissions.cedar.admin.putPolicy({
  policyId: 'eng-view-reports',
  policy,
})
```

A put with an id that exists replaces that policy. The put checks the policy. It raises an error with the line and the column when the text has a syntax error:

```sql
select permissions.cedar_put_policy(
  policy_id => 'broken',
  policy => 'permit (principal, action, resource) when {'
);
-- ERROR:  unexpected end of input at line 1, column 44: expected an expression
-- DETAIL:  cedar:parse_error line=1 column=44
-- HINT:  Check the policy against the Cedar grammar: https://docs.cedarpolicy.com/policies/syntax-grammar.html
```

Each call takes exactly one policy. Text with two policies is an error. Call the function once for each policy.

## Use a condition

A `when` condition must be true for the policy to apply. An `unless` condition must be false. In a condition, `principal`, `action`, `resource` and `context` are the parts of the request. An attribute of an entity comes from the stored entity (see [Entities](entities.md)).

This policy lets the owner of a document edit it. The attribute `owner` of the document is an entity:

```sql tab="SQL"
select permissions.cedar_put_policy(
  policy_id => 'owner-edit',
  policy => 'permit (
  principal,
  action == Action::"edit",
  resource
)
when { resource.owner == principal };'
);
```

```ts tab="JavaScript"
const ownerEdit = `permit (
  principal,
  action == Action::"edit",
  resource
)
when { resource.owner == principal };`
await permissions.cedar.admin.putPolicy({
  policyId: 'owner-edit',
  policy: ownerEdit,
})
```

## Put a policy in JSON

Cedar also has a [JSON policy format](https://docs.cedarpolicy.com/policies/json-format.html). Use `policy_json` for a policy that a program writes, or one that the Cedar CLI translated. The extension stores the JSON as you give it. It rejects JSON with an unknown key, a wrong `op`, or a wrong shape, and the error names the path.

This `forbid` policy denies every action on a document with the level `confidential`:

```sql tab="SQL"
select permissions.cedar_put_policy(
  policy_id => 'no-confidential',
  policy_json => '{
  "effect": "forbid",
  "principal": {"op": "All"},
  "action": {"op": "All"},
  "resource": {"op": "All"},
  "conditions": [
    {
      "kind": "when",
      "body": {
        "==": {
          "left": {
            ".": {
              "left": {"Var": "resource"},
              "attr": "level"
            }
          },
          "right": {"Value": "confidential"}
        }
      }
    }
  ]
}'
);
```

```ts tab="JavaScript"
const noConfidential = {
  effect: 'forbid' as const,
  principal: { op: 'All' },
  action: { op: 'All' },
  resource: { op: 'All' },
  conditions: [
    {
      kind: 'when',
      body: {
        '==': {
          left: {
            '.': { left: { Var: 'resource' }, attr: 'level' },
          },
          right: { Value: 'confidential' },
        },
      },
    },
  ],
}
await permissions.cedar.admin.putPolicy({
  policyId: 'no-confidential',
  policyJson: noConfidential,
})
```

Pass exactly one of `policy` and `policy_json`. A call with both is the error `cedar:invalid_argument`. A call with neither is the error `cedar:null_argument`. A policy that has a slot (`?principal` or `?resource`) is a template. See [Templates](templates.md).

## The policy id

The `policy_id` argument names the policy. It is the id that `cedar_is_authorized` returns in `reasons`.

An `@id("...")` annotation in the text does not name the policy. It stays an annotation, and it does not have to agree with `policy_id`. The JSON format has no id field, so an id always comes from the call. Cedar's own call for one policy, `Policy::parse`, also takes the id as an argument.

Put each policy with its own call and a stable id. The extension has no function that loads a file with many policies. A loader that names policies by position would change the ids when you add a policy at the top of the file. Split the file in your own code and call `cedar_put_policy` once for each policy.

Static policies, template links and templates share one set of ids. A put can replace a policy that has the same id. If the id belongs to a template or a link, the put raises `cedar:id_in_use`.

## Annotations

An annotation is metadata on a policy. It has no effect on a decision. A JSON value of `null` is the same as `""`. Use annotations for notes, owners or ticket numbers. The put stores them, and `cedar_policies` returns them:

```sql tab="SQL"
select permissions.cedar_put_policy(
  policy_id => 'notes',
  policy => '@id("old-name")
@advice("Ask the security team first.")
forbid (principal, action, resource)
when { context.maintenance };'
);
select
  policy_id,
  annotations
from permissions.cedar_policies()
where policy_id = 'notes';
-- notes | {"id": "old-name", "advice": "Ask the security team first."}
```

```ts tab="JavaScript"
const notes = `@id("old-name")
@advice("Ask the security team first.")
forbid (principal, action, resource)
when { context.maintenance };`
await permissions.cedar.admin.putPolicy({
  policyId: 'notes',
  policy: notes,
})
const { data: policies } = await permissions.cedar.admin.policies()
const found = policies?.find((p) => p.policyId === 'notes')
// found?.annotations:
//   { id: 'old-name', advice: 'Ask the security team first.' }
```

## List policies

`cedar_policies` returns every policy, ordered by id. A row has the id, the effect, the Cedar text of a text put, the policy in JSON (`est`), the annotations, and the template of a link:

```sql tab="SQL"
select
  policy_id,
  effect,
  template_id
from permissions.cedar_policies();
-- eng-view-reports | permit | (null)
-- no-confidential  | forbid | (null)
-- notes            | forbid | (null)
-- owner-edit       | permit | (null)
```

```ts tab="JavaScript"
const { data: policies } = await permissions.cedar.admin.policies()
// [
//   { policyId: 'eng-view-reports', effect: 'permit', ... },
//   { policyId: 'no-confidential', effect: 'forbid', ... },
//   ...
// ]
```

`source` is `null` for a policy that you put as JSON. `est` always holds the policy in the JSON format, so you can read a text policy as JSON.

## Delete a policy

`cedar_delete_policy` deletes a policy or a template link. An unknown id is an error, and its hint lists the ids that exist:

```sql tab="SQL"
select permissions.cedar_delete_policy(policy_id => 'notes');
```

```ts tab="JavaScript"
await permissions.cedar.admin.deletePolicy({ policyId: 'notes' })
```

The policy is gone, so a second delete fails:

```sql
select permissions.cedar_delete_policy(policy_id => 'notes');
-- ERROR:  unknown policy 'notes'
-- DETAIL:  cedar:unknown_policy policy_id='notes'
-- HINT:  Policy ids: eng-view-reports, no-confidential, owner-edit.
```

## Limits

A policy has at most 64 KiB of text, 4,096 expression nodes and 64 levels of depth. [Limits](../../reference/limits.md#cedar-limits) lists every limit. The number of policies has no limit. A check reads only the policies whose scope can match the request. A policy with the scope `All` can match every request.

## Next step

Continue with [Templates](templates.md), or go to [Entities](entities.md).
