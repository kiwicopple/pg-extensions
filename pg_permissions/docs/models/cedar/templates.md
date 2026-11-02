# Use policy templates

Use a template when many policies have the same shape and differ only in the principal or the resource. Write the shape once. Then link it to each pair of entities.

First complete [Write policies](policies.md) and [Store entities](entities.md). An admin role runs these calls.

## Put a template

A template is a policy with a slot in its scope. The slot `?principal` stands in the principal scope. The slot `?resource` stands in the resource scope. A template can have one slot or both. A slot in a condition or in the action scope is an error. A template with no slot is an error, because it is a policy.

`cedar_put_template` takes a template id and one template, in Cedar text. It also takes `template_json`, the JSON format of the template. Pass exactly one of the two:

```sql tab="SQL"
select permissions.cedar_put_template(
  template_id => 'share-view',
  template => 'permit (
  principal == ?principal,
  action == Action::"view",
  resource == ?resource
);'
);
select permissions.cedar_put_template(
  template_id => 'team-folder',
  template => '@advice("Team access to a folder.")
permit (
  principal in ?principal,
  action == Action::"view",
  resource in ?resource
);'
);
```

```ts tab="JavaScript"
const shareView = `permit (
  principal == ?principal,
  action == Action::"view",
  resource == ?resource
);`
await permissions.cedar.admin.putTemplate({
  templateId: 'share-view',
  template: shareView,
})
const teamFolder = `@advice("Team access to a folder.")
permit (
  principal in ?principal,
  action == Action::"view",
  resource in ?resource
);`
await permissions.cedar.admin.putTemplate({
  templateId: 'team-folder',
  template: teamFolder,
})
```

A template alone gives no access. It does nothing until you link it.

## Link a template

`cedar_link_template` makes a policy from a template. Give the id of the new policy, the id of the template, and a uid for each slot of the template. The uids are Cedar text:

```sql tab="SQL"
select permissions.cedar_link_template(
  policy_id => 'bob-q3',
  template_id => 'share-view',
  principal => 'user::"bob"',
  resource => 'Document::"q3"'
);
select permissions.cedar_link_template(
  policy_id => 'design-reports',
  template_id => 'team-folder',
  principal => 'Team::"design"',
  resource => 'Folder::"reports"'
);
```

```ts tab="JavaScript"
await permissions.cedar.admin.linkTemplate({
  policyId: 'bob-q3',
  templateId: 'share-view',
  principal: { type: 'user', id: 'bob' },
  resource: { type: 'Document', id: 'q3' },
})
await permissions.cedar.admin.linkTemplate({
  policyId: 'design-reports',
  templateId: 'team-folder',
  principal: 'Team::"design"',
  resource: 'Folder::"reports"',
})
```

A link is a policy. `cedar_is_authorized` matches it and names it in `reasons` like any other policy. A link with the id of a link that exists replaces that link. Cedar's own `link` call rejects a duplicate id, and this call does not, because every put in this API replaces by id.

`cedar_policies` shows each link with its template and its slot values. A static policy has `null` in both columns:

```sql tab="SQL"
select
  policy_id,
  template_id,
  slots
from permissions.cedar_policies()
where template_id is not null;
-- bob-q3         | share-view  | {"?resource": {"id": "q3", "type": "Document"}, "?principal": {"id": "bob", "type": "user"}}
-- design-reports | team-folder | {"?resource": {"id": "reports", "type": "Folder"}, "?principal": {"id": "design", "type": "Team"}}
```

```ts tab="JavaScript"
const { data: policies } = await permissions.cedar.admin.policies()
const links = policies?.filter((p) => p.templateId !== null)
// links?.[0].slots:
//   {
//     '?principal': { type: 'user', id: 'bob' },
//     '?resource': { type: 'Document', id: 'q3' },
//   }
```

The extension fills the slots when you link, not when it checks a request. A check of a link costs the same as a check of a static policy.

A link needs a value for each slot of its template and no other value. A slot without a value is the error `cedar:invalid_link`. Its hint names the slots of the template:

```sql
select permissions.cedar_link_template(
  policy_id => 'bob-all',
  template_id => 'share-view',
  principal => 'user::"bob"'
);
-- ERROR:  template 'share-view' has the slot ?resource, and the link gives it no value
-- DETAIL:  cedar:invalid_link slot='?resource'
-- HINT:  Template 'share-view' has the slots ?principal and ?resource: pass a value for each and nothing else, for example principal => 'User::"alice"', resource => 'Folder::"docs"'.
```

## List templates

`cedar_templates` returns every template, ordered by id:

```sql tab="SQL"
select
  template_id,
  annotations
from permissions.cedar_templates();
-- share-view  | {}
-- team-folder | {"advice": "Team access to a folder."}
```

```ts tab="JavaScript"
const { data: templates } = await permissions.cedar.admin.templates()
// [
//   { templateId: 'share-view', annotations: {}, ... },
//   { templateId: 'team-folder', annotations: { advice: ... }, ... },
// ]
```

## Replace and delete

A put with the id of a template replaces it. The extension fills the slots of its links again from the new template, in the same transaction. The new template must keep the slots that its links fill. If it does not, the put raises `cedar:template_in_use` and names the links.

You cannot delete a template while it has links. Delete the links first with `cedar_delete_policy`. The hint of the error names up to five of them:

```sql tab="SQL"
select permissions.cedar_delete_policy(policy_id => 'bob-q3');
select permissions.cedar_delete_template(template_id => 'share-view');
```

```ts tab="JavaScript"
await permissions.cedar.admin.deletePolicy({
  policyId: 'bob-q3',
})
await permissions.cedar.admin.deleteTemplate({
  templateId: 'share-view',
})
```

A call to delete the template while the link exists fails:

```sql
select permissions.cedar_delete_template(template_id => 'team-folder');
-- ERROR:  template 'team-folder' has 1 link
-- DETAIL:  cedar:template_in_use template_id='team-folder'
-- HINT:  Delete its links first, with select permissions.cedar_delete_policy(policy_id => ...) for each: design-reports.
```

When you delete a user with [`delete_subject`](../../integrations/cleanup.md), the extension deletes the links whose slot names that user. Static policies and templates stay.

## When to use a link

A link is a policy row. Use a link for a rule that you can name and review, such as "the design team views the reports folder". For a grant to one object for each of a million users, use [OpenFGA](../openfga/overview.md) tuples. They are cheaper to store and to write.

## Next step

Continue with [Check access](checks.md).
