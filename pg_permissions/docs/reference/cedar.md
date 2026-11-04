# Cedar API

The JavaScript examples use a server client called `permissions`, created with `throwOnError: true` so a failed call stops the example. See [JavaScript setup](../integrations/javascript.md) to create the client.

Examples are fragments: they show a call on data that exists, and are not a script to run in order. For runnable setup, follow the [Cedar walkthrough](../models/cedar/overview.md). Management and explicit-principal functions require [admin privileges](../integrations/privileges.md#cedar-functions). The functions `cedar_is_authorized_current`, `cedar_list_resources_current` and `cedar_uid` are granted to `PUBLIC`.

A uid argument is Cedar text, `Type::"id"`. An id in a uid can hold any character if you escape `"` and `\`. Use [`cedar_uid`](#cedar_uid) to build the text. All `cedar_*` functions run with the rights of the extension owner, and they set `search_path` to `pg_catalog, pg_temp`.

## Policies

These functions manage policies. Admin only. Static policies, template links and templates share one set of ids.

### `cedar_put_policy`

Stores one policy and replaces a policy that has the same id. Pass exactly one of `policy` (Cedar text) and `policy_json` (Cedar's JSON policy format). The text must hold one policy. `policy_id` names the policy; an `@id` annotation does not. A policy with a slot is a template: use `cedar_put_template`.

Privileges: admin only. Subject: none. Context: not applicable. Result cap: none.

Errors: `cedar:parse_error`, `cedar:invalid_policy`, `cedar:invalid_argument` (both arguments), `cedar:null_argument` (no policy, or no id), `cedar:id_in_use`, `cedar:limit_exceeded` and `cedar:unsupported`.

```js tab="JavaScript"
await permissions.cedar.admin.putPolicy({
  policyId: 'owner-edit',
  policy: `permit (principal, action == Action::"edit", resource)
           when { resource.owner == principal };`,
})
```

```sql tab="SQL"
-- permissions.cedar_put_policy(
--   policy_id text,
--   policy text default null,
--   policy_json jsonb default null
-- ) returns void

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

### `cedar_delete_policy`

Deletes a static policy or a template link.

Privileges: admin only. Subject: none. Context: not applicable. Result cap: none.

Errors: `cedar:unknown_policy` (the hint lists the ids, and names `cedar_delete_template` for a template id) and `cedar:null_argument`.

```js tab="JavaScript"
await permissions.cedar.admin.deletePolicy({ policyId: 'owner-edit' })
```

```sql tab="SQL"
-- permissions.cedar_delete_policy(
--   policy_id text
-- ) returns void

select permissions.cedar_delete_policy(
  policy_id => 'owner-edit'
);
```

### `cedar_policies`

Returns every static policy and every link, ordered by id. `source` is the Cedar text of a text put, and `null` for a JSON put or a link. `est` is the policy in Cedar's JSON format, with the slots of a link filled. `template_id` and `slots` are `null` for a static policy. `slots` is an object such as `{"?principal": {"type": "user", "id": "bob"}}`.

Privileges: admin only. Subject: none. Context: not applicable. Result cap: none.

Errors: none.

```js tab="JavaScript"
const { data: policies, error } = await permissions.cedar.admin.policies()
if (error) throw error
for (const { policyId, effect } of policies) console.log(policyId, effect)
```

```sql tab="SQL"
-- permissions.cedar_policies() returns table (
--   policy_id text,
--   effect text,
--   source text,
--   est jsonb,
--   annotations jsonb,
--   template_id text,
--   slots jsonb
-- )

select
  policy_id,
  effect
from permissions.cedar_policies();
```

## Templates

These functions manage policy templates and their links. Admin only.

### `cedar_put_template`

Stores one template and replaces a template that has the same id. Pass exactly one of `template` (Cedar text) and `template_json`. A template has `?principal` in its principal scope, `?resource` in its resource scope, or both. A slot anywhere else is an error, and so is a template with no slot. When the template replaces another one, the extension fills the slots of its links again in the same transaction.

Privileges: admin only. Subject: none. Context: not applicable. Result cap: none.

Errors: `cedar:parse_error`, `cedar:invalid_policy`, `cedar:invalid_argument`, `cedar:null_argument`, `cedar:id_in_use`, `cedar:template_in_use` (the new template does not keep a slot that a link fills), `cedar:limit_exceeded` and `cedar:unsupported`.

```js tab="JavaScript"
await permissions.cedar.admin.putTemplate({
  templateId: 'share-view',
  template: `permit (
    principal == ?principal,
    action == Action::"view",
    resource == ?resource
  );`,
})
```

```sql tab="SQL"
-- permissions.cedar_put_template(
--   template_id text,
--   template text default null,
--   template_json jsonb default null
-- ) returns void

select permissions.cedar_put_template(
  template_id => 'share-view',
  template => 'permit (
  principal == ?principal,
  action == Action::"view",
  resource == ?resource
);'
);
```

### `cedar_link_template`

Makes a policy from a template. Pass a uid in Cedar text for each slot of the template and no other value. A link with the id of a link that exists replaces it.

Privileges: admin only. Subject: none. Context: not applicable. Result cap: none.

Errors: `cedar:unknown_template`, `cedar:invalid_link` (a slot has no value, or a value has no slot), `cedar:invalid_uid`, `cedar:id_in_use` and `cedar:null_argument`.

```js tab="JavaScript"
await permissions.cedar.admin.linkTemplate({
  policyId: 'bob-q3',
  templateId: 'share-view',
  principal: { type: 'user', id: 'bob' },
  resource: { type: 'Document', id: 'q3' },
})
```

```sql tab="SQL"
-- permissions.cedar_link_template(
--   policy_id text,
--   template_id text,
--   principal text default null,
--   resource text default null
-- ) returns void

select permissions.cedar_link_template(
  policy_id => 'bob-q3',
  template_id => 'share-view',
  principal => 'user::"bob"',
  resource => 'Document::"q3"'
);
```

### `cedar_delete_template`

Deletes a template that has no links.

Privileges: admin only. Subject: none. Context: not applicable. Result cap: none.

Errors: `cedar:unknown_template`, `cedar:template_in_use` (the hint names up to five links) and `cedar:null_argument`.

```js tab="JavaScript"
await permissions.cedar.admin.deleteTemplate({ templateId: 'share-view' })
```

```sql tab="SQL"
-- permissions.cedar_delete_template(
--   template_id text
-- ) returns void

select permissions.cedar_delete_template(
  template_id => 'share-view'
);
```

### `cedar_templates`

Returns every template, ordered by id.

Privileges: admin only. Subject: none. Context: not applicable. Result cap: none.

Errors: none.

```js tab="JavaScript"
const { data: templates, error } = await permissions.cedar.admin.templates()
if (error) throw error
for (const { templateId } of templates) console.log(templateId)
```

```sql tab="SQL"
-- permissions.cedar_templates() returns table (
--   template_id text,
--   source text,
--   est jsonb,
--   annotations jsonb
-- )

select template_id from permissions.cedar_templates();
```

## Entities

These functions manage the entities that policies read. Admin only.

### `cedar_put_entities`

Stores an array of entities, in one transaction. Each entity is `{"uid": {"type", "id"}, "attrs": {}, "parents": [], "tags": {}}`. An entity replaces the stored entity with the same uid, with its attributes, parents and tags. The call rejects a duplicate uid in the array, a value that is not valid, and a hierarchy with a cycle.

Batches containing parent links share a write guard until the transaction ends. Concurrent writes at `REPEATABLE READ` or `SERIALIZABLE` can raise `40001`; retry the transaction. See [The hierarchy](../models/cedar/entities.md#the-hierarchy).

Privileges: admin only. Subject: none. Context: not applicable. Cap: at most 10,000 entities in one call.

Errors: `cedar:invalid_entity` (with the index of the entity, or the uid of a cycle), `cedar:limit_exceeded` and `cedar:null_argument`.

```js tab="JavaScript"
await permissions.cedar.admin.putEntities([
  { uid: { type: 'user', id: 'zoe' }, parents: [{ type: 'Team', id: 'eng' }] },
])
```

```sql tab="SQL"
-- permissions.cedar_put_entities(
--   entities jsonb
-- ) returns void

select permissions.cedar_put_entities(
  entities => '[
    {
      "uid": {"type": "user", "id": "zoe"},
      "parents": [{"type": "Team", "id": "eng"}]
    }
  ]'
);
```

### `cedar_delete_entities`

Deletes entities and their own parent links, and returns the number of entities that it deleted. `uids` is an array. Each item is `{"type", "id"}` or Cedar text. An unknown uid is not an error. The links of other entities that name a deleted entity as a parent stay.

Privileges: admin only. Subject: none. Context: not applicable. Result cap: none.

Errors: `cedar:invalid_uid` and `cedar:null_argument`.

```js tab="JavaScript"
const { data: count } = await permissions.cedar.admin.deleteEntities([
  { type: 'user', id: 'zoe' },
])
// 1
```

```sql tab="SQL"
-- permissions.cedar_delete_entities(
--   uids jsonb
-- ) returns bigint

select permissions.cedar_delete_entities(
  uids => '[{"type": "user", "id": "zoe"}]'
);
-- 1
```

### `cedar_read_entities`

Returns the stored entities as a JSON array, in the format of `cedar_put_entities`. `type` limits the result to one type. `ids` limits it to some ids of that type, and needs `type`. Extension values are in their canonical text.

Privileges: admin only. Subject: none. Context: not applicable. Result cap: none.

Errors: `cedar:null_argument` when `ids` has no `type`.

```js tab="JavaScript"
const { data: documents } = await permissions.cedar.admin.readEntities({
  type: 'Document', ids: ['q3'],
})
```

```sql tab="SQL"
-- permissions.cedar_read_entities(
--   type text default null,
--   ids text[] default null
-- ) returns jsonb

select permissions.cedar_read_entities(
  type => 'Document',
  ids => '{q3}'
);
```

## Checks

### `cedar_is_authorized`

Evaluates one request. `context` is a JSON object, and `null` means `{}`. `entities` is an array of entities for this request only. Each one replaces the stored entity with the same uid. The SQL result is `{"decision": "allow" | "deny", "reasons": [policy ids], "errors": [{"policy_id", "message"}]}`. The ids are sorted. A forbid that applies gives `deny`. A policy that fails is in `errors` and is skipped. This function does not fail closed.

Privileges: admin only. Subject: none; the principal is an argument. Context: accepted. Cap: at most 1,000 entities in `entities`. The number of policies and results has no cap.

Errors: `cedar:invalid_uid`, `cedar:null_argument` (a uid is `null`), `cedar:invalid_context`, `cedar:invalid_entity` and `cedar:limit_exceeded`. A failure in a policy is not an error: it is in `errors`.

```js tab="JavaScript"
const { data: decision } = await permissions.cedar.admin.isAuthorized({
  principal: { type: 'user', id: 'alice' },
  action: { type: 'Action', id: 'view' },
  resource: { type: 'Document', id: 'q3' },
})
// { decision: 'allow', diagnostics: { reason: ['eng-view-reports'], errors: [] } }
```

```sql tab="SQL"
-- permissions.cedar_is_authorized(
--   principal text,
--   action text,
--   resource text,
--   context jsonb default null,
--   entities jsonb default null
-- ) returns jsonb

select permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"view"',
  resource => 'Document::"q3"'
);
-- {"errors": [], "reasons": ["eng-view-reports"], "decision": "allow"}
```

<span id="functions-for-rls"></span>

## Current-subject functions

These functions are granted to `PUBLIC`. They answer for the current subject, as `current_subject_type()::"current_subject_id()"`, and can be used by application code or RLS policies. They take no context and no request entities. They fail closed. See [Check access](../models/cedar/checks.md#check-for-the-current-subject).

The examples use `const alice = permissions.as({ id: 'alice' })` on a backend that has already verified Alice's identity. A browser client calls the same methods for the user in its access token.

### `cedar_is_authorized_current`

Returns `true` when the decision for the current subject is `allow` and no relevant `forbid` fails to evaluate. It returns `false` when there is no subject or when `action` or `resource` is `null`. The optional `resource_attrs` defaults to `null`, which uses stored attributes. When supplied as a JSON object, it replaces the resource's attributes for this check; parents and tags still come from storage. A stored resource entity is not required. Do not pass `plan_time_guard`.

Invalid values in supplied resource attributes deny access, even when the matching permit has no conditions. For backend enforcement, build `resource_attrs` from trusted application data; for RLS, build it from the row being protected. Unverified attributes supplied by a browser do not establish access to a backend operation.

The function computes the work for the principal and the action once for each statement, and it then answers each row from that work. A resource text of the form `Type::"..."` that is not a valid Cedar string denies that row. Build the text with `cedar_uid`.

Privileges: `PUBLIC`. Subject: the current subject. Context: none. Result cap: not applicable.

Errors: `cedar:invalid_uid` when `action` is not a uid, or `resource` is not of the form `Type::"..."`.

```js tab="JavaScript"
const { data: allowed } = await alice.cedar.isAuthorized({
  action: { type: 'Action', id: 'view' },
  resource: { type: 'Document', id: 'q3' },
})
// true
```

```sql tab="SQL"
-- permissions.cedar_is_authorized_current(
--   action text,
--   resource text,
--   resource_attrs jsonb default null,
--   plan_time_guard boolean default permissions._unfolded_null()
-- ) returns boolean

begin;
select set_config('permissions.subject_id', 'alice', true);
select permissions.cedar_is_authorized_current(
  action => 'Action::"view"',
  resource => 'Document::"q3"'
);
-- true
commit;
```

### `cedar_list_resources_current`

Returns the ids, without the type, of the stored entities of `resource_type` on which the current subject can do the action. It returns no row when there is no subject, or when an argument is `null`. It leaves out a resource when a `forbid` that applies gives an error. The result is the same as the one of `cedar_is_authorized_current` for each stored entity of the type. A resource that a policy names but nobody stored is not listed.

Use it as `id = any (array(select permissions.cedar_list_resources_current(...)))`: Postgres then runs it once for each statement.

Privileges: `PUBLIC`. Subject: the current subject. Context: none. Result cap: none.

Errors: `cedar:invalid_uid` when `action` is not a uid. `cedar:invalid_argument` when `resource_type` is not a type name.

```js tab="JavaScript"
const { data: ids } = await alice.cedar.listResources({
  action: { type: 'Action', id: 'view' }, resourceType: 'Document',
})
// ['q3']
```

```sql tab="SQL"
-- permissions.cedar_list_resources_current(
--   action text,
--   resource_type text
-- ) returns setof text

begin;
select set_config('permissions.subject_id', 'alice', true);
select permissions.cedar_list_resources_current(
  action => 'Action::"view"',
  resource_type => 'Document'
);
-- q3
commit;
```

## Helpers

### `cedar_uid`

Returns the uid `Type::"id"` as Cedar text. It escapes `"` and `\`, and it writes the control characters and DEL as `\n`, `\r`, `\t` and `\u{hex}`. Use it to build a resource uid from the id of a row: `resource => permissions.cedar_uid('Document', id::text)`. A raw `'Document::"' || id || '"'` reads an id with a `"` as a different text, or as an error. An id such as `a\nb` (a backslash and an `n`) reads as a line break. The function does not check the type. A bad type gives `cedar:invalid_uid` where the text is used. The result is the same text that `uid(type, id)` builds in the JavaScript client.

The JavaScript helper runs locally. The SQL function is `immutable`, `strict` and `parallel safe`. A `null` argument gives `null`.

Privileges: `PUBLIC`. Subject: none. Context: not applicable. Result cap: not applicable.

Errors: none.

```js tab="JavaScript"
import { uid } from 'permissions/cedar'

const resource = uid('Document', 'say "hi"')
// Document::"say \"hi\""
```

```sql tab="SQL"
-- permissions.cedar_uid(
--   type text,
--   id text
-- ) returns text

select permissions.cedar_uid('Document', 'say "hi"');
-- Document::"say \"hi\""
```
