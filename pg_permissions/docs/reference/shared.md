# Shared SQL functions

Identity and cleanup functions are shared by the permission models. Each entry gives its signature, behavior, errors, and JavaScript equivalent.

The examples illustrate individual calls. Set up the subject explicitly before checking it, and use a test database for examples that create roles. See [request identity](../integrations/identity.md) and [cleanup](../integrations/cleanup.md) for application integration.

## Shared functions

### `current_subject_id`

```text
permissions.current_subject_id() returns text
```

Returns the id of the current subject, or `null` when there is none. The id comes from the first source that has a value:

1. The `sub` claim of the JWT in the setting `request.jwt.claims`. Supabase and PostgREST set this setting on each request.
2. The setting `permissions.subject_id`. Plain Postgres uses this setting.

Errors: none.

JavaScript: `currentSubjectId()`.

```sql
select permissions.current_subject_id();
-- null: no JWT, no setting
select set_config('permissions.subject_id', 'alice', false);
select permissions.current_subject_id();
-- alice
select set_config('permissions.subject_id', '', false);
```

Set `permissions.subject_id` with `set_config(..., true)` in a transaction, so that the value ends with the transaction. The value `false` keeps the setting for the whole session. A connection pool can then give the setting to the next client.

### `current_subject_type`

```text
permissions.current_subject_type() returns text
```

Returns the type of the current subject. The value is `user`, unless the setting `permissions.subject_type` has another value. The RBAC functions use the type `user` only. The OpenFGA functions for RLS use `type:id`, from this function and `current_subject_id`.

Errors: none.

JavaScript: `currentSubjectType()`.

```sql
select permissions.current_subject_type();   -- user
```

### `delete_subject`

```text
permissions.delete_subject(
  subject_type text,
  subject_id text
) returns bigint
```

Removes a subject from every model. For the type `user`, it deletes the RBAC assignments of the subject. For every type, it deletes each tuple that names the subject as the subject, as a userset of the subject, or as the object. It returns the number of rows that it deleted. Admin only.

Errors: none.

JavaScript: `admin.deleteSubject({ type, id })`.

```sql
select permissions.rbac_create_role(
  role => 'reader',
  permissions => '{docs.read}'
);
select permissions.rbac_assign_role(
  user_id => 'zoe',
  role => 'reader'
);
select permissions.delete_subject(
  subject_type => 'user',
  subject_id => 'zoe'
);
-- 1
```

## Tables

The extension stores its data in tables in the schema `permissions`. The extension has no views. No client role can read a table. The extension owner can read the tables below.

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
