# OpenFGA SQL functions

Each entry gives the SQL signature, behavior, return type, errors, and corresponding JavaScript method. Functions are in the `permissions` schema.

Examples are fragments: they illustrate a call using existing data, rather than forming a script to run in order. For runnable setup, follow the [OpenFGA walkthrough](../models/openfga/models.md). Management and explicit-subject functions require [admin privileges](../integrations/privileges.md); current-subject helpers are granted to `PUBLIC`.

## FGA functions

These functions use the OpenFGA model. Admin only. Each function that takes `model_id` uses the latest model when `model_id` is `null`. The page [The OpenFGA model](../models/openfga/overview.md) explains each function with examples.

### `fga_write_authorization_model`

```text
permissions.fga_write_authorization_model(model jsonb) returns text
```

Validates a model in the JSON format of the OpenFGA WriteAuthorizationModel request. Compiles it, and makes it the latest model. Returns the id of the model, a ULID.

Errors: `openfga:2000`, `2047`, `2050`, `2056` and `2057`.

JavaScript: `fga.admin.writeAuthorizationModel(model)`.

```sql
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

```text
permissions.fga_read_authorization_model(
  model_id text default null
) returns jsonb
```

Returns one model as JSON, with the key `id`. Without `model_id`, it returns the latest model.

Errors: `openfga:2001` for an unknown id. `2020` when no model exists.

JavaScript: `fga.admin.readAuthorizationModel({ authorizationModelId? })`.

```sql
select permissions.fga_read_authorization_model(
  model_id => :'model_id'
) ->> 'id' = :'model_id';
-- true
```

### `fga_read_authorization_models`

```text
permissions.fga_read_authorization_models(
  
) returns table (id text, created_at timestamptz)
```

Lists every model, newest first.

Errors: none.

JavaScript: `fga.admin.readAuthorizationModels()`.

```sql
select id from permissions.fga_read_authorization_models();
```

### `fga_delete_store`

```text
permissions.fga_delete_store() returns void
```

Deletes every model and every tuple.

Errors: none.

JavaScript: `fga.admin.deleteStore()`.

The example uses a transaction and rolls it back:

```sql
begin;
select permissions.fga_delete_store();
select count(*) from permissions.fga_read_authorization_models();   -- 0
rollback;
```

### `fga_write`

```text
permissions.fga_write(
  writes jsonb default null,
  deletes jsonb default null,
  model_id text default null
) returns void
```

Writes and deletes tuples in one transaction. Each of `writes` and `deletes` is an array of tuple keys, or an object `{"tuple_keys": [...]}` with the option `on_duplicate` (writes) or `on_missing` (deletes). Pass at least one of them. The call accepts at most 100 tuple keys.

Errors: `openfga:2000`, `2001`, `2003`, `2004`, `2017`, `2020`, `2027` and `2053`.

JavaScript: `fga.admin.write({ writes?, deletes?, onDuplicate?, onMissing?, authorizationModelId? })`.

```sql
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

```text
permissions.fga_write_tuple(
  subject text,
  relation text,
  object text
) returns void
```

Writes one tuple. It does nothing when the tuple exists. The extension validates the tuple against the latest model.

Errors: `openfga:2000`, `2017`, `2020` and `2027`.

JavaScript: `fga.admin.writeTuple({ user, relation, object })`.

```sql
select permissions.fga_write_tuple(
  subject => 'user:carol',
  relation => 'viewer',
  object => 'document:2'
);
```

### `fga_delete_tuple`

```text
permissions.fga_delete_tuple(
  subject text,
  relation text,
  object text
) returns void
```

Deletes one tuple. It does nothing when the tuple does not exist. The tuple key must be well formed. The latest model does not need to accept it.

Errors: `openfga:2000` and `2020`.

JavaScript: `fga.admin.deleteTuple({ user, relation, object })`.

```sql
select permissions.fga_delete_tuple(
  subject => 'user:carol',
  relation => 'viewer',
  object => 'document:2'
);
```

### `fga_read`

```text
permissions.fga_read(
  object text default null,
  relation text default null,
  subject text default null,
  page_size integer default null,
  out tuples jsonb,
  inout continuation_token text default null
) returns record
```

Returns one page of stored tuples, in the order of the writes. The `object` filter is `type:id` or `type:`. `page_size` is 1 to 100, and the default is 50. The column `continuation_token` is `''` on the last page. To get the next page, pass the token back as the argument `continuation_token`.

Errors: `openfga:2000` for a `page_size` outside the range or a token with an invalid format. `2007` for a token that the extension does not know.

JavaScript: `fga.admin.read({ object?, relation?, user?, pageSize?, continuationToken? })`.

```sql
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

```text
permissions.fga_check(
  subject text,
  relation text,
  object text,
  contextual_tuples jsonb default null,
  model_id text default null,
  context jsonb default null
) returns boolean
```

Returns `true` when the subject has the relation to the object. `contextual_tuples` is an array of tuple keys that count for this call only. `context` is a JSON object with the parameters of the conditions.

Errors: `openfga:2000`, `2001`, `2002`, `2020` and `2027`.

JavaScript: `fga.admin.check({ user, relation, object, ... })`.

```sql
select permissions.fga_check(
  subject => 'user:alice',
  relation => 'viewer',
  object => 'document:1'
);
-- true
```

### `fga_list_objects`

```text
permissions.fga_list_objects(
  subject text,
  type text,
  relation text,
  contextual_tuples jsonb default null,
  model_id text default null,
  context jsonb default null
) returns setof text
```

Returns the objects of one type that the subject has the relation to, as `type:id` strings. At most 1,000 results. The order is not defined.

Errors: `openfga:2000`, `2001`, `2002`, `2020`, `2021`, `2022` and `2027`.

JavaScript: `fga.admin.listObjects({ user, type, relation, ... })`.

```sql
select permissions.fga_list_objects(
  subject => 'user:alice',
  type => 'document',
  relation => 'viewer'
);
-- document:1
```

### `fga_list_users`

```text
permissions.fga_list_users(
  object text,
  relation text,
  user_filters text[],
  contextual_tuples jsonb default null,
  model_id text default null,
  context jsonb default null
) returns setof text
```

Returns the subjects that have the relation to the object. Each filter in `user_filters` is a type (`user`) or a userset type (`team#member`). At most 1,000 results. The order is not defined.

Errors: `openfga:2000`, `2001`, `2002`, `2020`, `2021`, `2022` and `2027`.

JavaScript: `fga.admin.listUsers({ object, relation, userFilters, ... })`.

```sql
select permissions.fga_list_users(
  object => 'document:1',
  relation => 'viewer',
  user_filters => '{user}'
);
-- user:alice, user:bob
```

## Current-subject helpers

These functions are granted to `PUBLIC` and use the current subject and latest model. They accept neither request context nor contextual tuples. They deny access that depends on a condition they cannot evaluate. The list helpers have no result cap. See [condition behavior](../models/openfga/condition-behavior.md) for the full rules.

### `fga_check_current`

```text
permissions.fga_check_current(
  relation text,
  object text
) returns boolean
```

The same as `fga_check`, for the current subject. It takes no contextual tuples and no `context`. It returns `false` when there is no subject, no model, or the subject type is not in the model.

Errors: `openfga:2000` for a malformed object, an unknown type or an unknown relation. `2002` when the answer needs 25 levels or more.

JavaScript: `fga.check({ relation, object })`.

```sql
select permissions.fga_check_current(
  relation => 'viewer',
  object => 'document:1'
);
-- true
```

### `fga_list_objects_current`

```text
permissions.fga_list_objects_current(
  type text,
  relation text
) returns setof text
```

The same as `fga_list_objects`, for the current subject. It has no cap on the number of results.

Errors: `openfga:2000` and `2002`.

JavaScript: `fga.listObjects({ type, relation })`.

```sql
select permissions.fga_list_objects_current(
  type => 'document',
  relation => 'viewer'
);
-- document:1
```

### `fga_list_object_ids_current`

```text
permissions.fga_list_object_ids_current(
  type text,
  relation text
) returns setof text
```

The same as `fga_list_objects_current`, but each result is the id without the type. Use it to compare with the id column of a table. It has no cap on the number of results.

Errors: `openfga:2000` and `2002`.

JavaScript: `fga.listObjects({ type, relation, idsOnly: true })`.

```sql
select permissions.fga_list_object_ids_current(
  type => 'document',
  relation => 'viewer'
);
-- 1
select set_config('permissions.subject_id', '', false);
```
