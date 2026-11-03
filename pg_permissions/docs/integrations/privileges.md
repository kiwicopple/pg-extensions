# Client and admin privileges

Application clients can check their own access. A trusted backend manages roles, models, tuples, policies and entities. These privileges apply regardless of the language you use.

The examples are fragments. They assume the `authenticated` and `service_role` database roles exist. The RBAC example uses the `alice` and `bob` variables from [RBAC setup](../models/rbac/overview.md#before-you-start); the OpenFGA example uses the [sharing model](../models/openfga/models.md); the Cedar example uses the [policies and entities](../models/cedar/policies.md). Run expected-error statements separately when your client stops on errors.

## RBAC and shared functions

The extension has two kinds of functions.

| Kind | Functions | Who can call them |
| --- | --- | --- |
| Client functions: answer for the current subject only | `current_subject_id`, `current_subject_type`, `rbac_has_permission`, `rbac_has_role`, `rbac_scopes_with_permission`, `fga_check_current`, `fga_list_objects_current`, `fga_list_object_ids_current`, `cedar_is_authorized_current`, `cedar_list_resources_current`, `cedar_uid` | Everyone (granted to `PUBLIC`), so `anon` and `authenticated` too |
| Admin functions: change data, or take a subject as an argument | `rbac_create_role`, `rbac_drop_role`, `rbac_assign_role`, `rbac_unassign_role`, `rbac_user_permissions`, `rbac_users_with_role`, `delete_subject`, and each other `fga_*` and `cedar_*` function | The extension owner. Other roles need an explicit `grant execute` |

Clients have no privilege on the tables of the extension. The functions that read the tables are `security definer`, with a fixed `search_path`.

`rbac_user_permissions` and `rbac_users_with_role` take a subject as an argument. If a client could call them, any signed-in user could ask what another user can do. A client that could call `rbac_assign_role` could make itself an admin. The client functions have no subject argument, so a client can only ask about itself.

```sql
set role authenticated;
select permissions.rbac_has_permission(permission => 'documents.read');
-- false: no subject, but no error
select permissions.rbac_assign_role(
  user_id => :'bob',
  role => 'admin'
);
-- ERROR:  permission denied for function rbac_assign_role
select permissions.rbac_user_permissions(user_id => :'alice');
-- ERROR:  permission denied for function rbac_user_permissions
reset role;
```

A trusted backend role, such as `service_role`, gets the admin functions with an explicit grant. This example is for RBAC. The [OpenFGA grants](#openfga-functions) are below.

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

On Supabase, `service_role` bypasses RLS but not function privileges. This is why the grant is necessary. Grant only the functions that the backend uses.

## OpenFGA functions

Only the extension owner can call the OpenFGA admin functions unless it grants execution to another role. Current-subject helpers are available to clients. These functions take the subject as an argument, or they change data. A client that can call `fga_check` can ask what anyone can see. A client that can write tuples can share anything with itself.

```sql
set role authenticated;
select permissions.fga_check(
  subject => 'user:anne',
  relation => 'viewer',
  object => 'document:roadmap'
);
-- ERROR:  permission denied for function fga_check
select permissions.fga_write_tuple(
  subject => 'user:erin',
  relation => 'owner',
  object => 'document:roadmap'
);
-- ERROR:  permission denied for function fga_write_tuple
select permissions.fga_check_current(
  relation => 'viewer',
  object => 'document:roadmap'
);
-- allowed: answers for the current subject
reset role;
```

To give a trusted backend role the other functions, use an explicit grant:

```sql
grant execute on function
    permissions.fga_write_authorization_model(jsonb),
    permissions.fga_read_authorization_model(text),
    permissions.fga_read_authorization_models(),
    permissions.fga_write(jsonb, jsonb, text),
    permissions.fga_write_tuple(text, text, text),
    permissions.fga_delete_tuple(text, text, text),
    permissions.fga_read(text, text, text, integer, text),
    permissions.fga_check(text, text, text, jsonb, text, jsonb),
    permissions.fga_list_objects(text, text, text, jsonb, text, jsonb),
    permissions.fga_list_users(text, text, text[], jsonb, text, jsonb)
to service_role;
```

Grant only the functions that the backend uses. Keep `fga_delete_store()` for the owner. See [Privileges](../reference.md#privileges) in the function reference.

## Cedar functions

The Cedar admin functions follow the same rule. Only the extension owner can call them, unless it grants execution to another role. Current-subject helpers are available to clients. `cedar_uid` is also available to clients. It is a pure function that builds the text of a uid, and it reads no data.

A client that can call `cedar_is_authorized` can ask what anyone can do. A client that can put policies or entities can give itself any access.

```sql
set role authenticated;
select permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"view"',
  resource => 'Document::"q3"'
);
-- ERROR:  permission denied for function cedar_is_authorized
select permissions.cedar_put_entities(
  entities => '[
    {
      "uid": {"type": "user", "id": "mallory"},
      "parents": [{"type": "Team", "id": "eng"}]
    }
  ]'
);
-- ERROR:  permission denied for function cedar_put_entities
select permissions.cedar_is_authorized_current(
  action => 'Action::"view"',
  resource => permissions.cedar_uid('Document', 'q3')
);
-- allowed: answers for the current subject
reset role;
```

To give a trusted backend role the other functions, use an explicit grant:

```sql
grant execute on function
    permissions.cedar_put_policy(text, text, jsonb),
    permissions.cedar_delete_policy(text),
    permissions.cedar_policies(),
    permissions.cedar_put_template(text, text, jsonb),
    permissions.cedar_link_template(text, text, text, text),
    permissions.cedar_delete_template(text),
    permissions.cedar_templates(),
    permissions.cedar_put_entities(jsonb),
    permissions.cedar_delete_entities(jsonb),
    permissions.cedar_read_entities(text, text[]),
    permissions.cedar_is_authorized(text, text, text, jsonb, jsonb)
to service_role;
```

Grant only the functions that the backend uses. The Cedar tables have no client privileges. The functions run with the rights of the owner, so a client reads and writes no table directly.

The current-subject helpers read the subject from the same settings as the other models. See [Identity and request context](identity.md). A role that can run `set_config` can choose its subject. Do not give such a role to a client that is not trusted.

## Security properties

The extension keeps these properties for each function and table it creates. The spec `test/spec/d/06_security_invariants.sql` checks them in the catalog, so a new function or grant that breaks one fails the tests.

- Clients can execute only the client functions in the table above. They have no privilege on a table or sequence of the extension.
- Each `security definer` function sets `search_path` to `pg_catalog, pg_temp` and `standard_conforming_strings` to `on`. A temporary type or a session setting of the caller does not change what the function does.
- The functions do not build or run dynamic SQL. Names, ids, policies and JSON are data.
- A missing subject, a null argument or a malformed value gives false or an empty result, or raises an error. It never gives access. An OpenFGA check with an unknown relation raises an error.
- The install stops if the schema `permissions` already exists and a role other than the installer, or a superuser, owns it or can create objects in it.

These limits apply:

- A role that can run SQL can call `set_config` and choose its subject. In a transaction where `cedar_is_authorized_current` ran, it can also read the cached Cedar filter with `current_setting`. The filter holds the conditions of the policies that apply to the subject, and the attributes of the subject and the action. Give such a role only to trusted code. PostgREST clients cannot run `set_config` or `current_setting`.
- If `request.jwt.claims` has no `sub` claim, the extension uses `permissions.subject_id`. Set that value with `set_config(..., true)`, so that it ends with the transaction.
- A function that you add to the schema `permissions` gets the default privileges of Postgres: `PUBLIC` can execute it. Revoke this privilege after you create the function:

```sql
revoke all on function permissions.my_function(text) from public;
```

In your own `security definer` functions, set `search_path = pg_catalog, pg_temp` and qualify each name with its schema. Do not set `search_path` to an empty value: Postgres then searches the temporary schema of the caller first for types and tables.
