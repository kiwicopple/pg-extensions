# Function reference

This page lists every public function of `pg_permissions`, with its signature, its purpose, its errors and an example. All functions are in the schema `permissions`. The extension has 26 public functions.

Call each function with named arguments, as in the examples. The names in this page are the names in the catalog. No argument name is a reserved word in SQL. For this reason the OpenFGA `user` field is `subject`.

For an explanation of the models, read [RBAC](rbac.md) and [The OpenFGA model](fga.md). For the errors, read [Errors and limits](errors-and-limits.md).

The examples run in order. Each example uses the data that the examples before it wrote. Use a test database for them.

## Groups

| Group | Functions | Who can call them |
| --- | --- | --- |
| [Shared](#shared-functions) | `current_subject_id`, `current_subject_type`, `delete_subject` | `current_subject_id` and `current_subject_type`: everyone. `delete_subject`: admin. |
| [RBAC](#rbac-functions) | `rbac_create_role`, `rbac_drop_role`, `rbac_assign_role`, `rbac_unassign_role`, `rbac_user_permissions`, `rbac_users_with_role` | Admin |
| [FGA](#fga-functions) | `fga_write_authorization_model`, `fga_read_authorization_model`, `fga_read_authorization_models`, `fga_delete_store`, `fga_write`, `fga_write_tuple`, `fga_delete_tuple`, `fga_read`, `fga_check`, `fga_list_objects`, `fga_list_users` | Admin |
| [RLS helpers](#rls-helpers) | `rbac_has_permission`, `rbac_has_role`, `rbac_scopes_with_permission`, `fga_check_current`, `fga_list_objects_current`, `fga_list_object_ids_current` | Everyone |

## Privileges

The extension has two kinds of function:

- **Client functions** answer for the current subject only. The extension grants them to `PUBLIC`, so `anon` and `authenticated` can call them. These are `current_subject_id`, `current_subject_type` and the RLS helpers.
- **Admin functions** change data, or take a subject as an argument. Only the role that installed the extension can call them. Any other role needs an explicit `grant execute`.

No role other than the owner has a privilege on the tables. Functions that read the tables are `security definer`, with a fixed `search_path`.

A client that can call an admin function can ask what anyone can do, or can give itself access. This is the reason for the split. A call to an admin function from a client role fails with SQLSTATE `42501`:

```sql
set role authenticated;
select permissions.rbac_assign_role(user_id => 'mallory', role => 'admin');   -- ERROR:  permission denied for function rbac_assign_role
reset role;
```

To let a trusted backend role call admin functions, grant them by name and argument types. This example grants the RBAC functions and `delete_subject`. [The OpenFGA model](fga.md#privileges) has the grant for the `fga_*` functions.

```sql
grant execute on function
    permissions.rbac_create_role(text, text[], text[]),
    permissions.rbac_drop_role(text),
    permissions.rbac_assign_role(text, text, text),
    permissions.rbac_unassign_role(text, text, text),
    permissions.rbac_user_permissions(text, text),
    permissions.rbac_users_with_role(text, text),
    permissions.delete_subject(text, text)
to service_role;
```

Grant only the functions that the backend uses.

## Shared functions

### `current_subject_id`

```text
permissions.current_subject_id() returns text
```

Returns the id of the current subject, or `null` when there is none. The id comes from the first source that has a value:

1. The `sub` claim of the JWT in the setting `request.jwt.claims`. Supabase and PostgREST set this setting on each request.
2. The setting `permissions.subject_id`. Plain Postgres uses this setting.

Errors: none.

```sql
select permissions.current_subject_id();                          -- null: no JWT, no setting
select set_config('permissions.subject_id', 'alice', false);
select permissions.current_subject_id();                          -- alice
select set_config('permissions.subject_id', '', false);
```

Set `permissions.subject_id` with `set_config(..., true)` in a transaction, so that the value ends with the transaction. The value `false` keeps the setting for the whole session. A connection pool can then give the setting to the next client.

### `current_subject_type`

```text
permissions.current_subject_type() returns text
```

Returns the type of the current subject. The value is `user`, unless the setting `permissions.subject_type` has another value. The RBAC functions use the type `user` only. The OpenFGA functions for RLS use `type:id`, from this function and `current_subject_id`.

Errors: none.

```sql
select permissions.current_subject_type();   -- user
```

### `delete_subject`

```text
permissions.delete_subject(subject_type text, subject_id text) returns bigint
```

Removes a subject from every model. For the type `user`, it deletes the RBAC assignments of the subject. For every type, it deletes each tuple that names the subject as the subject, as a userset of the subject, or as the object. It returns the number of rows that it deleted. Admin only.

Errors: none.

```sql
select permissions.rbac_create_role(role => 'reader', permissions => '{docs.read}');
select permissions.rbac_assign_role(user_id => 'zoe', role => 'reader');
select permissions.delete_subject(subject_type => 'user', subject_id => 'zoe');   -- 1
```

## RBAC functions

These functions manage roles and assignments. Admin only. A role grants permissions and can inherit other roles. An assignment gives a user a role, app-wide (`scope` is `null`) or in one scope.

### `rbac_create_role`

```text
permissions.rbac_create_role(role text, permissions text[], inherits text[] default '{}') returns void
```

Creates a role with the permissions that it grants and the roles that it inherits. A role cannot change after you create it.

Errors: `23505` when the role exists. `22023` when a name is both a role and a permission, or when `inherits` names an unknown role. `22004` when `role`, `permissions` or `inherits` is `null`. An empty array, `'{}'`, is valid for `permissions` and `inherits`.

```sql
select permissions.rbac_create_role(role => 'viewer', permissions => '{documents.read}');
select permissions.rbac_create_role(role => 'editor', permissions => '{documents.edit}', inherits => '{viewer}');
```

### `rbac_drop_role`

```text
permissions.rbac_drop_role(role text) returns void
```

Deletes a role and its assignments. You cannot drop a role that another role inherits.

Errors: `22023` for an unknown role. `2BP01` when another role inherits the role.

```sql
select permissions.rbac_create_role(role => 'temp', permissions => '{temp.use}');
select permissions.rbac_drop_role(role => 'temp');
```

### `rbac_assign_role`

```text
permissions.rbac_assign_role(user_id text, role text, scope text default null) returns void
```

Gives a user a role. When `scope` is `null`, the role applies app-wide. Otherwise it applies in that scope only. A repeated call changes nothing.

Errors: `22023` for an unknown role. `22004` when `user_id` is `null`.

```sql
select permissions.rbac_assign_role(user_id => 'alice', role => 'editor');
select permissions.rbac_assign_role(user_id => 'alice', role => 'viewer', scope => 'acme');
select permissions.rbac_assign_role(user_id => 'bob', role => 'viewer', scope => 'acme');
```

### `rbac_unassign_role`

```text
permissions.rbac_unassign_role(user_id text, role text, scope text default null) returns void
```

Removes an assignment. The call changes nothing when the user does not have the role, or when the role does not exist. An app-wide call leaves the assignments in scopes unchanged.

Errors: `22004` when `user_id` or `role` is `null`.

```sql
select permissions.rbac_unassign_role(user_id => 'bob', role => 'viewer', scope => 'acme');
```

### `rbac_user_permissions`

```text
permissions.rbac_user_permissions(user_id text, scope text default null) returns text[]
```

Returns the permissions of a user, sorted, with inherited permissions. When `scope` is `null`, it returns the app-wide permissions. Otherwise it returns the permissions in that scope. The result is `{}` when the user has none.

Errors: none.

```sql
select permissions.rbac_user_permissions(user_id => 'alice');                       -- {documents.edit,documents.read}
select permissions.rbac_user_permissions(user_id => 'alice', scope => 'acme');      -- {documents.read}
```

### `rbac_users_with_role`

```text
permissions.rbac_users_with_role(role text, scope text default null) returns setof text
```

Returns the ids of the users that have the role. The result includes users that have the role through a role that inherits it.

Errors: none.

```sql
select permissions.rbac_users_with_role(role => 'viewer');                          -- alice: through editor
select permissions.rbac_users_with_role(role => 'viewer', scope => 'acme');         -- alice
```

## FGA functions

These functions use the OpenFGA model. Admin only. Each function that takes `model_id` uses the latest model when `model_id` is `null`. The page [The OpenFGA model](fga.md) explains each function with examples.

### `fga_write_authorization_model`

```text
permissions.fga_write_authorization_model(model jsonb) returns text
```

Validates a model in the JSON format of the OpenFGA WriteAuthorizationModel request. Compiles it, and makes it the latest model. Returns the id of the model, a ULID.

Errors: `openfga:2000`, `2047`, `2050`, `2056` and `2057`.

```sql
select permissions.fga_write_authorization_model(model => '{"schema_version": "1.1", "type_definitions": [
  {"type": "user"},
  {"type": "document",
   "relations": {"viewer": {"this": {}}},
   "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}}]}') as model_id \gset
```

### `fga_read_authorization_model`

```text
permissions.fga_read_authorization_model(model_id text default null) returns jsonb
```

Returns one model as JSON, with the key `id`. Without `model_id`, it returns the latest model.

Errors: `openfga:2001` for an unknown id. `2020` when no model exists.

```sql
select permissions.fga_read_authorization_model(model_id => :'model_id') ->> 'id' = :'model_id';   -- true
```

### `fga_read_authorization_models`

```text
permissions.fga_read_authorization_models() returns table (id text, created_at timestamptz)
```

Lists every model, newest first.

Errors: none.

```sql
select id from permissions.fga_read_authorization_models();
```

### `fga_delete_store`

```text
permissions.fga_delete_store() returns void
```

Deletes every model and every tuple.

Errors: none.

The example uses a transaction and rolls it back:

```sql
begin;
select permissions.fga_delete_store();
select count(*) from permissions.fga_read_authorization_models();   -- 0
rollback;
```

### `fga_write`

```text
permissions.fga_write(writes jsonb default null, deletes jsonb default null, model_id text default null) returns void
```

Writes and deletes tuples in one transaction. Each of `writes` and `deletes` is an array of tuple keys, or an object `{"tuple_keys": [...]}` with the option `on_duplicate` (writes) or `on_missing` (deletes). Pass at least one of them. The call accepts at most 100 tuple keys.

Errors: `openfga:2000`, `2001`, `2003`, `2004`, `2017`, `2020`, `2027` and `2053`.

```sql
select permissions.fga_write(
    writes  => '[{"user": "user:alice", "relation": "viewer", "object": "document:1"},
                 {"user": "user:bob",   "relation": "viewer", "object": "document:1"}]',
    deletes => '{"tuple_keys": [{"user": "user:zed", "relation": "viewer", "object": "document:1"}], "on_missing": "ignore"}');
```

### `fga_write_tuple`

```text
permissions.fga_write_tuple(subject text, relation text, object text) returns void
```

Writes one tuple. It does nothing when the tuple exists. The extension validates the tuple against the latest model.

Errors: `openfga:2000`, `2017`, `2020` and `2027`.

```sql
select permissions.fga_write_tuple(subject => 'user:carol', relation => 'viewer', object => 'document:2');
```

### `fga_delete_tuple`

```text
permissions.fga_delete_tuple(subject text, relation text, object text) returns void
```

Deletes one tuple. It does nothing when the tuple does not exist. The tuple key must be well formed. The latest model does not need to accept it.

Errors: `openfga:2000` and `2020`.

```sql
select permissions.fga_delete_tuple(subject => 'user:carol', relation => 'viewer', object => 'document:2');
```

### `fga_read`

```text
permissions.fga_read(object text default null, relation text default null, subject text default null,
                     page_size integer default null, out tuples jsonb, inout continuation_token text default null) returns record
```

Returns one page of stored tuples, in the order of the writes. The `object` filter is `type:id` or `type:`. `page_size` is 1 to 100, and the default is 50. The column `continuation_token` is `''` on the last page. To get the next page, pass the token back as the argument `continuation_token`.

Errors: `openfga:2000` for a `page_size` outside the range or a token with an invalid format. `2007` for a token that the extension does not know.

```sql
select jsonb_array_length(tuples), continuation_token <> '' from permissions.fga_read(object => 'document:', page_size => 1);   -- 1, true
```

In the catalog, `continuation_token` is one `inout` argument. Use it as an input argument and as an output column.

### `fga_check`

```text
permissions.fga_check(subject text, relation text, object text, contextual_tuples jsonb default null,
                      model_id text default null, context jsonb default null) returns boolean
```

Returns `true` when the subject has the relation to the object. `contextual_tuples` is an array of tuple keys that count for this call only. `context` is a JSON object with the parameters of the conditions.

Errors: `openfga:2000`, `2001`, `2002`, `2020` and `2027`.

```sql
select permissions.fga_check(subject => 'user:alice', relation => 'viewer', object => 'document:1');   -- true
```

### `fga_list_objects`

```text
permissions.fga_list_objects(subject text, type text, relation text, contextual_tuples jsonb default null,
                             model_id text default null, context jsonb default null) returns setof text
```

Returns the objects of one type that the subject has the relation to, as `type:id` strings. At most 1,000 results. The order is not defined.

Errors: `openfga:2000`, `2001`, `2002`, `2020`, `2021`, `2022` and `2027`.

```sql
select permissions.fga_list_objects(subject => 'user:alice', type => 'document', relation => 'viewer');   -- document:1
```

### `fga_list_users`

```text
permissions.fga_list_users(object text, relation text, user_filters text[], contextual_tuples jsonb default null,
                           model_id text default null, context jsonb default null) returns setof text
```

Returns the subjects that have the relation to the object. Each filter in `user_filters` is a type (`user`) or a userset type (`team#member`). At most 1,000 results. The order is not defined.

Errors: `openfga:2000`, `2001`, `2002`, `2020`, `2021`, `2022` and `2027`.

```sql
select permissions.fga_list_users(object => 'document:1', relation => 'viewer', user_filters => '{user}');   -- user:alice, user:bob
```

## RLS helpers

These functions answer for the current subject ([`current_subject_id`](#current_subject_id)). Everyone can call them. They return `false`, an empty array or no rows when there is no subject. They are `security definer` functions that policies can call. The page [RLS with both models](rls.md) shows how to use them in policies.

### `rbac_has_permission`

```text
permissions.rbac_has_permission(permission text, scope text default null) returns boolean
```

Returns `true` when the current subject has the permission, through a role that it holds directly or by inheritance. When `scope` is `null`, only app-wide assignments count. Otherwise only the assignments in that scope count. An unknown permission gives `false`.

Errors: none.

```sql
select set_config('permissions.subject_id', 'alice', false);
select permissions.rbac_has_permission(permission => 'documents.edit');                      -- true
select permissions.rbac_has_permission(permission => 'documents.edit', scope => 'acme');     -- false: alice is a viewer in acme
```

### `rbac_has_role`

```text
permissions.rbac_has_role(role text, scope text default null) returns boolean
```

Returns `true` when the current subject has the role, directly or through a role that inherits it. The scope rule is the same as for `rbac_has_permission`. An unknown role gives `false`.

Errors: none.

```sql
select permissions.rbac_has_role(role => 'viewer');                      -- true: editor inherits viewer
select permissions.rbac_has_role(role => 'viewer', scope => 'acme');     -- true
```

### `rbac_scopes_with_permission`

```text
permissions.rbac_scopes_with_permission(permission text, plan_time_guard boolean default permissions._unfolded_null()) returns text[]
```

Returns the scopes in which the current subject has the permission. App-wide assignments do not appear. The result is `{}` when there is none. The order is not defined. This is the fast function for policies on tables with a tenant column.

Do not pass `plan_time_guard`. The extension ignores it. Its default value makes sure that the planner does not evaluate the call before the query runs.

Errors: none.

```sql
select permissions.rbac_scopes_with_permission(permission => 'documents.read');   -- {acme}
```

### `fga_check_current`

```text
permissions.fga_check_current(relation text, object text) returns boolean
```

The same as `fga_check`, for the current subject. It takes no contextual tuples and no `context`. It returns `false` when there is no subject, no model, or the subject type is not in the model.

Errors: `openfga:2000` for a malformed object, an unknown type or an unknown relation. `2002` when the answer needs 25 levels or more.

```sql
select permissions.fga_check_current(relation => 'viewer', object => 'document:1');   -- true
```

### `fga_list_objects_current`

```text
permissions.fga_list_objects_current(type text, relation text) returns setof text
```

The same as `fga_list_objects`, for the current subject. It has no cap on the number of results.

Errors: `openfga:2000` and `2002`.

```sql
select permissions.fga_list_objects_current(type => 'document', relation => 'viewer');   -- document:1
```

### `fga_list_object_ids_current`

```text
permissions.fga_list_object_ids_current(type text, relation text) returns setof text
```

The same as `fga_list_objects_current`, but each result is the id without the type. Use it to compare with the id column of a table. It has no cap on the number of results.

Errors: `openfga:2000` and `2002`.

```sql
select permissions.fga_list_object_ids_current(type => 'document', relation => 'viewer');   -- 1
select set_config('permissions.subject_id', '', false);
```

## Tables

The extension stores its data in tables in the schema `permissions`. The extension has no views. No client role can read a table. The role that installed the extension can read the tables below.

| Table | Purpose |
| --- | --- |
| `rbac_roles` | One row for each role. |
| `rbac_role_permissions` | The permissions that each role grants directly. |
| `rbac_role_inherits` | The roles that each role inherits directly. |
| `rbac_assignments` | The roles of users. The column `scope` is `null` for an app-wide assignment. |
| `fga_models` | The authorization models, as written, with their ids. |
| `fga_conditions` | The conditions of each model: `name`, `expression` and `parameters`. |
| `fga_tuples` | The stored tuples, with their conditions. The column `seq` is the order of the writes. |

Read these tables for reports and to find faults. Do not write to them. A direct write skips the checks of the functions, and it can leave the derived tables wrong. Use the functions.

An internal object is an object that the extension uses to work. Do not read it, write to it or call it. It can change in a new version. These objects are internal:

- Each function whose name starts with `_`. One of them, `_unfolded_null`, is public, because a default value uses it.
- The tables that hold derived data: `rbac_role_closure` and the tables for the compiled model, `fga_types`, `fga_relations`, `fga_type_restrictions`, `fga_rewrite_nodes`, `fga_edges`, `fga_computed_closure`, `fga_paths`, `fga_reach` and `fga_walk_steps`.
- The sequences of the tables, and the types `fga_tuple` and `fga_cel_result`.
- The columns of a table that hold compiled data, such as `ast` in `fga_conditions`.
