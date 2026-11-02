# Client and admin privileges

Application clients can check their own access. A trusted backend manages roles, models, and tuples. These privileges apply regardless of the language you use.

The examples are fragments. They assume the `authenticated` and `service_role` database roles exist. The RBAC example uses the `alice` and `bob` variables from [RBAC setup](../models/rbac/overview.md#before-you-start); the OpenFGA example uses the [sharing model](../models/openfga/models.md). Run expected-error statements separately when your client stops on errors.

## RBAC and shared functions

The extension has two kinds of functions.

| Kind | Functions | Who can call them |
| --- | --- | --- |
| Client functions: answer for the current subject only | `current_subject_id`, `current_subject_type`, `rbac_has_permission`, `rbac_has_role`, `rbac_scopes_with_permission`, `fga_check_current`, `fga_list_objects_current`, `fga_list_object_ids_current` | Everyone (granted to `PUBLIC`), so `anon` and `authenticated` too |
| Admin functions: change data, or take a subject as an argument | `rbac_create_role`, `rbac_drop_role`, `rbac_assign_role`, `rbac_unassign_role`, `rbac_user_permissions`, `rbac_users_with_role`, `delete_subject`, and each other `fga_*` function | The extension owner. Other roles need an explicit `grant execute` |

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
