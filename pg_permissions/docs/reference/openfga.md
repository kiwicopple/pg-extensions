# OpenFGA API

The JavaScript examples use a server client called `permissions`, created with `throwOnError: true` so a failed call stops the example. See [JavaScript setup](../integrations/javascript.md) to create the client.

Examples are fragments: they illustrate a call using existing data, rather than forming a script to run in order. For runnable setup, follow the [OpenFGA walkthrough](../models/openfga/models.md). Management and explicit-subject functions require [admin privileges](../integrations/privileges.md); current-subject helpers are granted to `PUBLIC`.

## FGA functions

These functions use the OpenFGA model. Admin only. Each function that takes `model_id` uses the latest model when `model_id` is `null`. The page [The OpenFGA model](../models/openfga/overview.md) explains each function with examples.

### `fga_write_authorization_model`

Validates a model in the JSON format of the OpenFGA WriteAuthorizationModel request. Compiles it, and makes it the latest model. Returns the id of the model, a ULID.

Errors: `openfga:2000`, `2047`, `2050`, `2056` and `2057`.

```js tab="JavaScript"
const model = {
  schema_version: '1.1',
  type_definitions: [
    { type: 'user' },
    {
      type: 'document',
      relations: { viewer: { this: {} } },
      metadata: {
        relations: { viewer: { directly_related_user_types: [{ type: 'user' }] } },
      },
    },
  ],
}
const { data: written, error } = await permissions.fga.admin.writeAuthorizationModel(model)
if (error) throw error
const modelId = written.authorizationModelId
```

```sql tab="SQL"
-- permissions.fga_write_authorization_model(model jsonb) returns text

select permissions.fga_write_authorization_model(
  model => '{
    "schema_version": "1.1",
    "type_definitions": [
      {"type": "user"},
      {
        "type": "document",
        "relations": {"viewer": {"this": {}}},
        "metadata": {
          "relations": {
            "viewer": {
              "directly_related_user_types": [
                {"type": "user"}
              ]
            }
          }
        }
      }
    ]
  }'
) as model_id \gset
```

### `fga_read_authorization_model`

Returns one model as JSON, with the key `id`. Without `model_id`, it returns the latest model.

Errors: `openfga:2001` for an unknown id. `2020` when no model exists.

```js tab="JavaScript"
const { data: stored } = await permissions.fga.admin.readAuthorizationModel({
  authorizationModelId: modelId,
})
// stored.id equals the modelId returned when you wrote the model
```

```sql tab="SQL"
-- permissions.fga_read_authorization_model(
--   model_id text default null
-- ) returns jsonb

select permissions.fga_read_authorization_model(
  model_id => :'model_id'
) ->> 'id' = :'model_id';
-- true
```

### `fga_read_authorization_models`

Lists every model, newest first.

Errors: none.

```js tab="JavaScript"
const { data: models } = await permissions.fga.admin.readAuthorizationModels()
// Each entry contains id and createdAt, newest first.
```

```sql tab="SQL"
-- permissions.fga_read_authorization_models() returns table (id text, created_at timestamptz)

select id from permissions.fga_read_authorization_models();
```

### `fga_delete_store`

Deletes every model and every tuple.

Errors: none.

Use the extension owner's connection in a test database. The examples roll back the deletion. In JavaScript, `pool` is the owner's PostgreSQL pool.

```js tab="JavaScript"
const conn = await pool.connect()
try {
  await conn.query('begin')
  const owner = createServerClient(conn, { throwOnError: true })
  await owner.fga.admin.deleteStore()
  const { data: models } = await owner.fga.admin.readAuthorizationModels()
  // []
} finally {
  try {
    await conn.query('rollback')
  } finally {
    conn.release()
  }
}
```

```sql tab="SQL"
-- permissions.fga_delete_store() returns void

begin;
select permissions.fga_delete_store();
select count(*) from permissions.fga_read_authorization_models();   -- 0
rollback;
```

### `fga_write`

Writes and deletes tuples in one transaction. Each of `writes` and `deletes` is an array of tuple keys, or an object `{"tuple_keys": [...]}` with the option `on_duplicate` (writes) or `on_missing` (deletes). Pass at least one of them. The call accepts at most 100 tuple keys.

Errors: `openfga:2000`, `2001`, `2003`, `2004`, `2017`, `2020`, `2027` and `2053`.

```js tab="JavaScript"
await permissions.fga.admin.write({
  writes: [
    { user: 'user:alice', relation: 'viewer', object: 'document:1' },
    { user: 'user:bob', relation: 'viewer', object: 'document:1' },
  ],
  deletes: [{ user: 'user:zed', relation: 'viewer', object: 'document:1' }],
  onMissing: 'ignore',
})
```

```sql tab="SQL"
-- permissions.fga_write(
--   writes jsonb default null,
--   deletes jsonb default null,
--   model_id text default null
-- ) returns void

select permissions.fga_write(
  writes => '[
    {
      "user": "user:alice",
      "relation": "viewer",
      "object": "document:1"
    },
    {
      "user": "user:bob",
      "relation": "viewer",
      "object": "document:1"
    }
  ]',
  deletes => '{
    "tuple_keys": [
      {
        "user": "user:zed",
        "relation": "viewer",
        "object": "document:1"
      }
    ],
    "on_missing": "ignore"
  }'
);
```

### `fga_write_tuple`

Writes one tuple. It does nothing when the tuple exists. The extension validates the tuple against the latest model.

Errors: `openfga:2000`, `2017`, `2020` and `2027`.

```js tab="JavaScript"
await permissions.fga.admin.writeTuple({
  user: 'user:carol', relation: 'viewer', object: 'document:2',
})
```

```sql tab="SQL"
-- permissions.fga_write_tuple(
--   subject text,
--   relation text,
--   object text
-- ) returns void

select permissions.fga_write_tuple(
  subject => 'user:carol',
  relation => 'viewer',
  object => 'document:2'
);
```

### `fga_delete_tuple`

Deletes one tuple. It does nothing when the tuple does not exist. The tuple key must be well formed. The latest model does not need to accept it.

Errors: `openfga:2000` and `2020`.

```js tab="JavaScript"
await permissions.fga.admin.deleteTuple({
  user: 'user:carol', relation: 'viewer', object: 'document:2',
})
```

```sql tab="SQL"
-- permissions.fga_delete_tuple(
--   subject text,
--   relation text,
--   object text
-- ) returns void

select permissions.fga_delete_tuple(
  subject => 'user:carol',
  relation => 'viewer',
  object => 'document:2'
);
```

### `fga_read`

Returns one page of stored tuples, in the order of the writes. The `object` filter is `type:id` or `type:`. `page_size` is 1 to 100, and the default is 50. The column `continuation_token` is `''` on the last page. To get the next page, pass the token back as the argument `continuation_token`.

Errors: `openfga:2000` for a `page_size` outside the range or a token with an invalid format. `2007` for a token that the extension does not know.

```js tab="JavaScript"
const { data: page, error } = await permissions.fga.admin.read({
  object: 'document:',
  pageSize: 1,
})
if (error) throw error
console.log(page.tuples.length, page.continuationToken !== '') // 1, true
```

```sql tab="SQL"
-- permissions.fga_read(
--   object text default null,
--   relation text default null,
--   subject text default null,
--   page_size integer default null,
--   out tuples jsonb,
--   inout continuation_token text default null
-- ) returns record

select
  jsonb_array_length(tuples),
  continuation_token <> ''
from permissions.fga_read(
  object => 'document:',
  page_size => 1
);
-- 1, true
```

In the catalog, `continuation_token` is one `inout` argument. Use it as an input argument and as an output column.

### `fga_check`

Returns `true` when the subject has the relation to the object. `contextual_tuples` is an array of tuple keys that count for this call only. `context` is a JSON object with the parameters of the conditions.

Errors: `openfga:2000`, `2001`, `2002`, `2020` and `2027`.

```js tab="JavaScript"
const { data: allowed } = await permissions.fga.admin.check({
  user: 'user:alice', relation: 'viewer', object: 'document:1',
})
// true
```

```sql tab="SQL"
-- permissions.fga_check(
--   subject text,
--   relation text,
--   object text,
--   contextual_tuples jsonb default null,
--   model_id text default null,
--   context jsonb default null
-- ) returns boolean

select permissions.fga_check(
  subject => 'user:alice',
  relation => 'viewer',
  object => 'document:1'
);
-- true
```

### `fga_list_objects`

Returns the objects of one type that the subject has the relation to, as `type:id` strings. At most 1,000 results. The order is not defined.

Errors: `openfga:2000`, `2001`, `2002`, `2020`, `2021`, `2022` and `2027`.

```js tab="JavaScript"
const { data: documents } = await permissions.fga.admin.listObjects({
  user: 'user:alice', type: 'document', relation: 'viewer',
})
// ['document:1']
```

```sql tab="SQL"
-- permissions.fga_list_objects(
--   subject text,
--   type text,
--   relation text,
--   contextual_tuples jsonb default null,
--   model_id text default null,
--   context jsonb default null
-- ) returns setof text

select permissions.fga_list_objects(
  subject => 'user:alice',
  type => 'document',
  relation => 'viewer'
);
-- document:1
```

### `fga_list_users`

Returns the subjects that have the relation to the object. Each filter in `user_filters` is a type (`user`) or a userset type (`team#member`). At most 1,000 results. The order is not defined.

Errors: `openfga:2000`, `2001`, `2002`, `2020`, `2021`, `2022` and `2027`.

```js tab="JavaScript"
const { data: viewers } = await permissions.fga.admin.listUsers({
  object: 'document:1', relation: 'viewer', userFilters: ['user'],
})
// ['user:alice', 'user:bob'] in any order
```

```sql tab="SQL"
-- permissions.fga_list_users(
--   object text,
--   relation text,
--   user_filters text[],
--   contextual_tuples jsonb default null,
--   model_id text default null,
--   context jsonb default null
-- ) returns setof text

select permissions.fga_list_users(
  object => 'document:1',
  relation => 'viewer',
  user_filters => '{user}'
);
-- user:alice, user:bob
```

## Current-subject helpers

These functions are granted to `PUBLIC` and use the current subject and latest model. They accept neither request context nor contextual tuples. They deny access that depends on a condition they cannot evaluate. The list helpers have no result cap. See [condition behavior](../models/openfga/condition-behavior.md) for the full rules.

The examples use `const alice = permissions.as({ id: 'alice' })` on a backend that has already verified Alice's identity. A browser client calls the same methods for the user in its access token.

### `fga_check_current`

The same as `fga_check`, for the current subject. It takes no contextual tuples and no `context`. It returns `false` when there is no subject, no model, or the subject type is not in the model.

Errors: `openfga:2000` for a malformed object, an unknown type or an unknown relation. `2002` when the answer needs 25 levels or more.

```js tab="JavaScript"
const { data: allowed } = await alice.fga.check({
  relation: 'viewer', object: 'document:1',
})
// true
```

```sql tab="SQL"
-- permissions.fga_check_current(
--   relation text,
--   object text
-- ) returns boolean

begin;
select set_config('permissions.subject_id', 'alice', true);
select permissions.fga_check_current(
  relation => 'viewer',
  object => 'document:1'
);
-- true
commit;
```

### `fga_list_objects_current`

The same as `fga_list_objects`, for the current subject. It has no cap on the number of results.

Errors: `openfga:2000` and `2002`.

```js tab="JavaScript"
const { data: documents } = await alice.fga.listObjects({
  type: 'document', relation: 'viewer',
})
// ['document:1']
```

```sql tab="SQL"
-- permissions.fga_list_objects_current(
--   type text,
--   relation text
-- ) returns setof text

begin;
select set_config('permissions.subject_id', 'alice', true);
select permissions.fga_list_objects_current(
  type => 'document',
  relation => 'viewer'
);
-- document:1
commit;
```

### `fga_list_object_ids_current`

The same as `fga_list_objects_current`, but each result is the id without the type. Use it to compare with the id column of a table. It has no cap on the number of results.

Errors: `openfga:2000` and `2002`.

```js tab="JavaScript"
const { data: ids } = await alice.fga.listObjects({
  type: 'document', relation: 'viewer', idsOnly: true,
})
// ['1']
```

```sql tab="SQL"
-- permissions.fga_list_object_ids_current(
--   type text,
--   relation text
-- ) returns setof text

begin;
select set_config('permissions.subject_id', 'alice', true);
select permissions.fga_list_object_ids_current(
  type => 'document',
  relation => 'viewer'
);
-- 1
commit;
```
