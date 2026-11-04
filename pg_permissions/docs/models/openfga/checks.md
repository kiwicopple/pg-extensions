# Check and list access

Check access to one object, list accessible objects, or inspect stored tuples.

First complete [Share objects and manage tuples](tuples.md). The examples use that model and those tuples. Start with a check for the signed-in user. Use the admin methods when you need to inspect another subject’s access, read tuples, or pass trusted request context.

<span id="functions-for-rls"></span>

## Check for the current subject

Use `fga.check` to ask whether the signed-in user can access an object. Use `fga.listObjects` to list accessible objects as `type:id` strings, or pass `idsOnly: true` to return just the IDs.

On the backend, pass the ID from your verified session to `permissions.as`. An authenticated browser client already has its subject. In SQL, set the subject inside a transaction. OpenFGA uses the default type `user` here, so Bob’s subject is `user:bob`. See [Identity and request context](../../integrations/identity.md).

```js tab="JavaScript"
const asBob = permissions.as({ id: 'bob' })

const { data: canView, error: checkError } = await asBob.fga.check({
  relation: 'viewer',
  object: 'document:roadmap',
})
if (checkError) throw checkError
// canView: true
const { data: objects } = await asBob.fga.listObjects({
  type: 'document',
  relation: 'viewer',
})
// ['document:roadmap', 'document:handbook']
const { data: ids } = await asBob.fga.listObjects({
  type: 'document',
  relation: 'viewer',
  idsOnly: true,
})
// ['roadmap', 'handbook']

// The server connection has no subject outside this call.
const { data: nobody } = await permissions.fga.check({
  relation: 'viewer',
  object: 'document:roadmap',
})
// false: no subject, no access
```

```sql tab="SQL"
begin;
select set_config('permissions.subject_id', 'bob', true);
select permissions.fga_check_current(
  relation => 'viewer',
  object => 'document:roadmap'
);
-- true
select permissions.fga_list_objects_current(
  type => 'document',
  relation => 'viewer'
);
-- document:roadmap, document:handbook
select permissions.fga_list_object_ids_current(
  type => 'document',
  relation => 'viewer'
);
-- roadmap, handbook
commit;

select permissions.fga_check_current(
  relation => 'viewer',
  object => 'document:roadmap'
);
-- false: no subject, no access
```

In three cases these functions return `false` or no rows. They raise no error. The cases are: there is no subject, there is no model, or the model does not define the subject type. An unknown object type or an unknown relation is still an error, as in OpenFGA.

The functions have no cap on the number of results. They take no contextual tuples and no `context`. [OpenFGA conditions](condition-behavior.md#conditions-in-current-subject-functions) explains how they treat conditioned tuples.

## Check

The admin `check` method accepts a subject explicitly. It returns `true` when the model gives that subject the requested relation to the object.

```js tab="JavaScript"
const { data: anne } = await permissions.fga.admin.check({
  user: 'user:anne',
  relation: 'viewer',
  object: 'document:roadmap',
})
// true: owns folder:projects, two parents up
const { data: bob } = await permissions.fga.admin.check({
  user: 'user:bob',
  relation: 'viewer',
  object: 'document:roadmap',
})
// true: team:eng views folder:projects
const { data: carl } = await permissions.fga.admin.check({
  user: 'user:carl',
  relation: 'viewer',
  object: 'document:roadmap',
})
// true: team:design is in team:eng
const { data: carlCan } = await permissions.fga.admin.check({
  user: 'user:carl',
  relation: 'can_view',
  object: 'document:roadmap',
})
// false: carl is blocked
const { data: dana } = await permissions.fga.admin.check({
  user: 'user:dana',
  relation: 'viewer',
  object: 'document:roadmap',
})
// true: editors view
const { data: erin } = await permissions.fga.admin.check({
  user: 'user:erin',
  relation: 'viewer',
  object: 'document:roadmap',
})
// false
const { data: handbook } = await permissions.fga.admin.check({
  user: 'user:erin',
  relation: 'viewer',
  object: 'document:handbook',
})
// true: user:*
```

```sql tab="SQL"
select permissions.fga_check(
  subject => 'user:anne',
  relation => 'viewer',
  object => 'document:roadmap'
);
-- true: owns folder:projects, two parents up
select permissions.fga_check(
  subject => 'user:bob',
  relation => 'viewer',
  object => 'document:roadmap'
);
-- true: team:eng views folder:projects
select permissions.fga_check(
  subject => 'user:carl',
  relation => 'viewer',
  object => 'document:roadmap'
);
-- true: team:design is in team:eng
select permissions.fga_check(
  subject => 'user:carl',
  relation => 'can_view',
  object => 'document:roadmap'
);
-- false: carl is blocked
select permissions.fga_check(
  subject => 'user:dana',
  relation => 'viewer',
  object => 'document:roadmap'
);
-- true: editors view
select permissions.fga_check(
  subject => 'user:erin',
  relation => 'viewer',
  object => 'document:roadmap'
);
-- false
select permissions.fga_check(
  subject => 'user:erin',
  relation => 'viewer',
  object => 'document:handbook'
);
-- true: user:*
```

Put a deny in the model, with `but not`. In the model above, `can_view` is `viewer but not blocked`. Check `can_view` to ask "can this subject see the document". Use `viewer` to ask "did someone give access to this subject".

A misspelled relation is always an error. It is never a silent `false`:

```js tab="JavaScript"
const misspelled = await permissions.fga.admin.check({
  user: 'user:anne',
  relation: 'viewr',
  object: 'document:roadmap',
})
// misspelled.error.message:
//   relation 'document#viewr' not found
// misspelled.error.details: openfga:2000 validation_error
// misspelled.error.hint: Did you mean 'viewer'? ...
```

```sql tab="SQL"
select permissions.fga_check(
  subject => 'user:anne',
  relation => 'viewr',
  object => 'document:roadmap'
);
-- ERROR:  relation 'document#viewr' not found
-- DETAIL:  openfga:2000 validation_error
-- HINT:  Did you mean 'viewer'? Relations on type 'document': blocked, can_view, editor, owner, parent, viewer.
```

## ListObjects

Use `admin.listObjects` to find every matching object up to the result cap. Each result is a `type:id` string. The order is unspecified.

```js tab="JavaScript"
const { data: bobDocs } = await permissions.fga.admin.listObjects({
  user: 'user:bob',
  type: 'document',
  relation: 'viewer',
})
// ['document:roadmap', 'document:handbook']
const { data: carlDocs } = await permissions.fga.admin.listObjects({
  user: 'user:carl',
  type: 'document',
  relation: 'can_view',
})
// ['document:handbook']
const { data: anneFolders } = await permissions.fga.admin.listObjects({
  user: 'user:anne',
  type: 'folder',
  relation: 'viewer',
})
// ['folder:projects', 'folder:roadmaps']
```

```sql tab="SQL"
select permissions.fga_list_objects(
  subject => 'user:bob',
  type => 'document',
  relation => 'viewer'
);
-- document:roadmap, document:handbook
select permissions.fga_list_objects(
  subject => 'user:carl',
  type => 'document',
  relation => 'can_view'
);
-- document:handbook
select permissions.fga_list_objects(
  subject => 'user:anne',
  type => 'folder',
  relation => 'viewer'
);
-- folder:projects, folder:roadmaps
```

The function returns at most 1,000 objects, as OpenFGA does. Additional objects are silently omitted. The [current-subject list functions](#check-for-the-current-subject) have no cap. Use those when you need all accessible objects, including when filtering table queries with RLS.

An unknown type is error `openfga:2021`. An unknown relation is error `openfga:2022`.

## ListUsers

Use `admin.listUsers` to find the subjects with a relation to an object. Pass the types you want in `userFilters` (`user_filters` in SQL). A filter can name a type such as `user` or a userset such as `team#member`.

```js tab="JavaScript"
const { data: viewers } = await permissions.fga.admin.listUsers({
  object: 'document:roadmap',
  relation: 'viewer',
  userFilters: ['user'],
})
// ['user:anne', 'user:bob', 'user:carl', 'user:dana']
const { data: authorizedViewers } = await permissions.fga.admin.listUsers({
  object: 'document:roadmap',
  relation: 'can_view',
  userFilters: ['user'],
})
// ['user:anne', 'user:bob', 'user:dana']
const { data: teams } = await permissions.fga.admin.listUsers({
  object: 'document:roadmap',
  relation: 'viewer',
  userFilters: ['team#member'],
})
// ['team:eng#member', 'team:design#member']
const { data: everyone } = await permissions.fga.admin.listUsers({
  object: 'document:handbook',
  relation: 'viewer',
  userFilters: ['user'],
})
// ['user:*']
```

```sql tab="SQL"
select permissions.fga_list_users(
  object => 'document:roadmap',
  relation => 'viewer',
  user_filters => '{user}'
);
-- user:anne, user:bob, user:carl, user:dana
select permissions.fga_list_users(
  object => 'document:roadmap',
  relation => 'can_view',
  user_filters => '{user}'
);
-- user:anne, user:bob, user:dana
select permissions.fga_list_users(
  object => 'document:roadmap',
  relation => 'viewer',
  user_filters => '{team#member}'
);
-- team:eng#member, team:design#member
select permissions.fga_list_users(
  object => 'document:handbook',
  relation => 'viewer',
  user_filters => '{user}'
);
-- user:*
```

A wildcard comes back as `user:*`. It means every subject of that type. Like ListObjects, ListUsers returns at most 1,000 results.

## Read

Use `admin.read` to inspect stored tuples directly. Each page contains `tuples` and a `continuationToken` (`continuation_token` in SQL). Use Check or ListObjects when you need to evaluate the model.

Filter by `object`, `relation` or `user` (`subject` in SQL), in any combination. The value of `object` is `type:id`, or `type:` for every object of a type.

```js tab="JavaScript"
const { data, error } = await permissions.fga.admin.read({
  object: 'document:roadmap',
})
if (error) throw error
// data.tuples: 3 tuples
// data.continuationToken: '' (the last page)

// one line for each tuple
for (const { key } of data.tuples) {
  console.log(key.relation, key.user)
}
```

```sql tab="SQL"
select tuples, continuation_token
from permissions.fga_read(object => 'document:roadmap');
-- tuples: [{"key": {"user": "folder:roadmaps", "relation": "parent", "object": "document:roadmap"}, "timestamp": "..."}, ...] (3 tuples)
-- continuation_token: '' (the last page)

-- one row for each tuple
select t #>> '{key,relation}', t #>> '{key,user}'
from permissions.fga_read(object => 'document:roadmap') r,
  jsonb_array_elements(r.tuples) t;
```

Pages contain up to 50 tuples by default, in write order. Set `pageSize` (`page_size` in SQL) to request between 1 and 100. Pass the returned token unchanged to get the next page. An empty token marks the last page.

```js tab="JavaScript"
let token = ''
let pages = 0
do {
  const request = {
    object: 'folder:',
    pageSize: 1,
    continuationToken: token,
  }
  const { data, error } = await permissions.fga.admin.read(request)
  if (error) throw error
  pages += 1
  token = data.continuationToken
} while (token !== '')
// pages: 3; the last token is ''
```

```sql tab="SQL"
select tuples, continuation_token as token
from permissions.fga_read(
  object => 'folder:',
  page_size => 1
) \gset
select tuples, continuation_token as token
from permissions.fga_read(
  object => 'folder:',
  page_size => 1,
  continuation_token => :'token'
) \gset
select tuples, continuation_token as token
from permissions.fga_read(
  object => 'folder:',
  page_size => 1,
  continuation_token => :'token'
) \gset
-- three pages of one tuple each; the third token is ''
```

To count all tuples, keep reading until the token is empty. The SQL example does this with a recursive query.

```js tab="JavaScript"
let total = 0
let allTuplesToken = ''
do {
  const request = { pageSize: 4, continuationToken: allTuplesToken }
  const { data, error } = await permissions.fga.admin.read(request)
  if (error) throw error
  total += data.tuples.length
  allTuplesToken = data.continuationToken
} while (allTuplesToken !== '')
// total: 11
```

```sql tab="SQL"
with recursive pages(tuples, token, n) as (
    select r.tuples, r.continuation_token, 1
    from permissions.fga_read(page_size => 4) r
  union all
    select r.tuples, r.continuation_token, n + 1
    from pages,
      permissions.fga_read(
        page_size => 4,
        continuation_token => pages.token
      ) r
    where pages.token <> ''
)
select sum(jsonb_array_length(tuples))
from pages;
-- 11
```

The `key` of a tuple in a page is a tuple key that `fga_write` accepts. You can pass a page back as `deletes`.

## Contextual tuples

Check, ListObjects and ListUsers accept `contextual_tuples`. These are tuples that count for one call only. The extension never writes them. It checks them against the model, as it checks written tuples:

```js tab="JavaScript"
const contextualTuples = [
  {
    user: 'user:erin',
    relation: 'member',
    object: 'team:eng',
  },
]
const { data: allowed } = await permissions.fga.admin.check({
  user: 'user:erin',
  relation: 'viewer',
  object: 'document:roadmap',
  contextualTuples,
})
// true
const { data: contextualObjects } = await permissions.fga.admin.listObjects({
  user: 'user:erin',
  type: 'document',
  relation: 'viewer',
  contextualTuples,
})
// ['document:roadmap', 'document:handbook', 'document:notes']
const { data: plain } = await permissions.fga.admin.check({
  user: 'user:erin',
  relation: 'viewer',
  object: 'document:roadmap',
})
// false: nothing was written
```

```sql tab="SQL"
select permissions.fga_check(
  subject => 'user:erin',
  relation => 'viewer',
  object => 'document:roadmap',
  contextual_tuples => '[
    {
      "user": "user:erin",
      "relation": "member",
      "object": "team:eng"
    }
  ]'
);
-- true
select permissions.fga_list_objects(
  subject => 'user:erin',
  type => 'document',
  relation => 'viewer',
  contextual_tuples => '[
    {
      "user": "user:erin",
      "relation": "member",
      "object": "team:eng"
    }
  ]'
);
-- document:roadmap, document:handbook, document:notes
select permissions.fga_check(
  subject => 'user:erin',
  relation => 'viewer',
  object => 'document:roadmap'
);
-- false: nothing was written
```

Use contextual tuples for facts that your application knows at the time of the request. An example is a group membership from the identity provider. Do not store these facts as tuples. Current-subject functions do not take contextual tuples, because an untrusted client could vouch for itself. A trusted backend can use the explicit-subject admin check.

## Optional: use a check in RLS

This policy is a fragment. It assumes a table `public.documents` with a text column `id`:

```sql
create policy documents_select
  on public.documents
  for select
  using (
    permissions.fga_check_current(
      relation => 'viewer',
      object => 'document:' || id
    )
  );
```

For a list of rows, the fast form is `id = any (array(select permissions.fga_list_object_ids_current(type => 'document', relation => 'viewer')))`. See [RLS integration](../../rls/policies.md).

## Next step

Continue with [Update models](update-models.md).
