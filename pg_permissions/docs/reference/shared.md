# Shared API

Identity and cleanup functions are shared by the permission models. Use these calls to inspect the identity attached to a request or clean up a deleted account.

The JavaScript examples use a server client called `permissions`, created with `throwOnError: true` so a failed call stops the example. See [JavaScript setup](../integrations/javascript.md) to create the client.

The examples illustrate individual calls. Set up the subject explicitly before checking it, and use a test database for examples that create roles. See [request identity](../integrations/identity.md) and [cleanup](../integrations/cleanup.md) for application integration.

## Shared functions

### `current_subject_id`

Returns the id of the current subject, or `null` when there is none. The id comes from the first source that has a value:

1. The `sub` claim of the JWT in the setting `request.jwt.claims`. Supabase and PostgREST set this setting on each request.
2. The setting `permissions.subject_id`. Plain Postgres uses this setting.

Errors: none.

```js tab="JavaScript"
const alice = permissions.as({ id: 'alice' })
const { data: subjectId } = await alice.currentSubjectId()
// 'alice'
```

```sql tab="SQL"
-- permissions.current_subject_id() returns text

begin;
select set_config('permissions.subject_id', 'alice', true);
select permissions.current_subject_id();   -- alice
commit;
```

Set `permissions.subject_id` with `set_config(..., true)` in a transaction, so that the value ends with the transaction. The value `false` keeps the setting for the whole session. A connection pool can then give the setting to the next client.

### `current_subject_type`

Returns the type of the current subject. The value is `user`, unless the setting `permissions.subject_type` has another value. The RBAC functions use the type `user` only. The OpenFGA current-subject functions use `type:id`, from this function and `current_subject_id`.

Errors: none.

```js tab="JavaScript"
const alice = permissions.as({ id: 'alice' })
const { data: subjectType } = await alice.currentSubjectType()
// 'user'
```

```sql tab="SQL"
-- permissions.current_subject_type() returns text

select permissions.current_subject_type();   -- user
```

### `delete_subject`

Removes a subject from every model. For the type `user`, it deletes the RBAC assignments of the subject. For every type, it deletes each tuple that names the subject as the subject, as a userset of the subject, or as the object. It also deletes the Cedar entity `<subject_type>::"<subject_id>"`, the parent edges from and to it, and each template link whose slot names it; static Cedar policies stay. It returns the number of rows that it deleted. Admin only.

Errors: none.

```js tab="JavaScript"
await permissions.rbac.admin.createRole({
  role: 'reader',
  permissions: ['docs.read'],
})
await permissions.rbac.admin.assignRole({ userId: 'zoe', role: 'reader' })
const { data: deleted } = await permissions.admin.deleteSubject({
  type: 'user',
  id: 'zoe',
})
// 1 if this assignment was Zoe's only permission data
```

```sql tab="SQL"
-- permissions.delete_subject(
--   subject_type text,
--   subject_id text
-- ) returns bigint

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
| `cedar_policies` | The static policies and the template links, as Cedar text and JSON. |
| `cedar_templates` | The policy templates. |
| `cedar_entities` | The entities, with their attributes and tags. |
| `cedar_entity_parents` | The direct parents of each entity. |

Read these tables for reports and to find faults. Do not write to them. A direct write skips the checks of the functions, and it can leave the derived tables wrong. Use the functions.

An internal object is an object that the extension uses to work. Do not read it, write to it or call it. It can change in a new version. These objects are internal:

- Each function whose name starts with `_`. One of them, `_unfolded_null`, is public, because a default value uses it.
- The tables that hold derived data: `rbac_role_closure` and the tables for the compiled model, `fga_types`, `fga_relations`, `fga_type_restrictions`, `fga_rewrite_nodes`, `fga_edges`, `fga_computed_closure`, `fga_paths`, `fga_reach` and `fga_walk_steps`.
- The sequences of the tables, and the types `fga_tuple` and `fga_cel_result`.
- The table `cedar_policy_scopes`, which indexes the scope of each policy.
- The columns of a table that hold compiled data, such as `ast` in `fga_conditions` and in `cedar_policies`.
