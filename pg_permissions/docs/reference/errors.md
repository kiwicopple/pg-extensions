# Errors

Errors include a message for people, a stable detail code for programs, and a hint describing the fix. The JavaScript client returns database errors in `error`; its `reason` field parses the detail code.

The SQL examples below run in order in a separate test database. The setup model supports the deliberate error cases.

Create this model before trying the error examples:

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
);
```

## Error format

Each error has a SQLSTATE and three text fields. Every error sets all three fields:

| Field | Content |
| --- | --- |
| `MESSAGE` | What went wrong. It names the values that were wrong. |
| `DETAIL` | A code that a program can read. It starts with a namespace: `openfga:<code> <name>` for the `fga_*` functions, `rbac:<code>` for the `rbac_*` functions, and `cedar:<code>` for the `cedar_*` functions. |
| `HINT` | How to fix the error. For a misspelled name, the hint gives the nearest name and the list of valid names. |

The code in `DETAIL` is stable. Your code can match on it.

This example has a typo in a relation name:

```sql
select permissions.fga_check(
  subject => 'user:anne',
  relation => 'viewr',
  object => 'document:1'
);
-- ERROR:  relation 'document#viewr' not found
-- DETAIL:  openfga:2000 validation_error
-- HINT:  Did you mean 'viewer'? Relations on type 'document': viewer.
```

This example has a typo in a role name. No role exists yet, so the hint says how to create one:

```sql
select permissions.rbac_assign_role(
  user_id => 'anne',
  role => 'admn'
);
-- ERROR:  unknown role 'admn'
-- DETAIL:  rbac:unknown_role role='admn'
-- HINT:  No roles exist yet: create it first, e.g. select permissions.rbac_create_role(role => 'admn', permissions => '{documents.read}').
```

### DETAIL namespaces

The `DETAIL` code has two parts: a namespace and a code. A colon separates them.

| Namespace | Raised by | Form | Meaning of the code |
| --- | --- | --- | --- |
| `openfga:` | The `fga_*` functions | `openfga:<number> <name>`, for example `openfga:2000 validation_error` | The number and the name are the OpenFGA API error code and its name. |
| `rbac:` | The `rbac_*` functions | `rbac:<code>`, then optional context, for example `rbac:unknown_role role='admn'` | The code is a name in snake case. It names the cause. One cause has one code in every function. |
| `cedar:` | The `cedar_*` functions | `cedar:<code>`, then optional context, for example `cedar:unknown_policy policy_id='x'` | The code is a name in snake case. It names the cause. |

The `rbac:` and `cedar:` context is a list of `key=value` pairs. The value is a quoted literal. To get the code only, read the text before the first space.

The shared functions `current_subject_id`, `current_subject_type` and `delete_subject` raise no error. They have no `DETAIL` code.

A misspelled name is always an error. It is never a silent `false`. The only exceptions are the RBAC checks `rbac_has_permission` and `rbac_has_role`. They return `false` for an unknown permission or role. A policy that names a dropped permission then denies access. It does not break every query.

The SQLSTATE is `22023` (`invalid_parameter_value`) for every OpenFGA code, with one exception. Code `2002` has SQLSTATE `54001` (`statement_too_complex`). The RBAC functions use other SQLSTATE values, which the table in [RBAC errors](#rbac-errors) lists.

To read the fields in PL/pgSQL, use `get stacked diagnostics`:

```sql
do $$
declare
  code text;
  fix text;
begin
  perform permissions.fga_check(
    subject => 'user:anne',
    relation => 'viewr',
    object => 'document:1'
  );
exception when invalid_parameter_value then
  get stacked diagnostics
    code = pg_exception_detail,
    fix = pg_exception_hint;
  raise notice 'code: %, hint: %', code, fix;
end $$;
-- NOTICE:  code: openfga:2000 validation_error, hint: Did you mean 'viewer'? Relations on type 'document': viewer.
```

From a client, read the code from the `details` field of the error. PostgREST returns it there. It returns the hint in the field `hint`.

## RBAC errors

Each row has one code, in the column `DETAIL`. The same code has the same cause in each function that raises it. The `DETAIL` column shows the form of the context after the code.

| `DETAIL` | SQLSTATE | Raised by | Cause | Fix |
| --- | --- | --- | --- | --- |
| `rbac:role_exists role=<name>` | `23505` | `rbac_create_role` | The role exists. | Use another name. To replace a role, drop it with `rbac_drop_role`, and create it again. |
| `rbac:name_overlap` | `22023` | `rbac_create_role` | A name is both a role and a permission. A role cannot list itself as a permission. | Use different names for roles and permissions. |
| `rbac:unknown_role role=<name>` | `22023` | `rbac_create_role`, `rbac_drop_role`, `rbac_assign_role` | The role does not exist. In `rbac_create_role`, `inherits` names the role. | Create the role first, or use a role from the list in the hint. The hint gives the nearest role name. |
| `rbac:role_in_use role=<name>` | `2BP01` | `rbac_drop_role` | Another role inherits the role. | Drop the roles that inherit it first. The hint names them. |
| `rbac:null_argument argument=<name>` | `22004` | `rbac_create_role`, `rbac_assign_role`, `rbac_unassign_role` | An argument is `null`. The argument can be `role`, `permissions` or `inherits` in `rbac_create_role`, `user_id` in `rbac_assign_role`, and `user_id` or `role` in `rbac_unassign_role`. | Pass a value for the argument. For `permissions`, pass `'{}'` for a role that only inherits. For `inherits`, you can also omit it. |

## OpenFGA errors

Every row has the SQLSTATE `22023`, except code `2002`. Each row has one code, in the column `DETAIL`. The column `Cause` gives the start of the `MESSAGE` where it helps you find the row.

| `DETAIL` | SQLSTATE | Cause | Fix |
| --- | --- | --- | --- |
| `openfga:2000 validation_error` | `22023` | A subject has an invalid form: `invalid 'user' value`. The form is not `type:id`, `type:*` or `type:id#relation`. The type or the relation of a userset is not in the model. | Write the subject in one of the three forms. Use a type and a relation from the model. |
| `openfga:2000 validation_error` | `22023` | An object has an invalid form (`invalid 'object' field format`). Or it is a typed wildcard (`type:*`). Or its type or relation is not in the model (`type '...' not found`, `relation '...#...' not found`). Raised by `fga_check` and by the RLS helpers. | Write the object as `type:id`. Use a type and a relation from the model. |
| `openfga:2000 validation_error` | `22023` | `context` is not a JSON object, or `contextual_tuples` is not an array of tuple keys. | Pass a JSON object as `context`. Pass an array or `{"tuple_keys": [...]}` as `contextual_tuples`. |
| `openfga:2000 validation_error` | `22023` | `fga_write`: `writes` or `deletes` is not an array. An option is not `error` or `ignore`. A list is empty. A key in `deletes` is malformed. | Pass arrays of tuple keys. Omit a list that is empty. Use `ignore` or `error`. |
| `openfga:2000 validation_error` | `22023` | The condition of a tuple is not valid. Raised by `fga_write` and by the contextual tuples of a list. The model does not define the condition. Or the type restriction does not accept it. Or the context has a key that is not a parameter. Or a value has the wrong type. | Name a condition that the relation accepts. Put only parameters of the condition in the context, with values of their types. |
| `openfga:2000 validation_error` | `22023` | The extension cannot evaluate a condition: `failed to evaluate relationship condition`. A parameter has no value, a value has the wrong type, the expression raises an error, or the evaluation cost is more than 100. | Pass every parameter in `context` or in the tuple. Use values of the right types. |
| `openfga:2000 validation_error` | `22023` | `fga_read`: `page_size` is not in 1 to 100, or the token has an invalid form or is more than 5,120 bytes. | Use a `page_size` from 1 to 100. Pass the token as the previous call returned it. |
| `openfga:2000 validation_error` | `22023` | `fga_list_users`: `user_filters` is empty or the object is malformed. | Pass at least one filter, for example `{user}`. |
| `openfga:2000 validation_error` | `22023` | `fga_write_authorization_model`: the request is not valid. A condition has an invalid name, an expression of more than 512 bytes, or more than 25 parameters. The model has an inline `$expression`. The schema version is not 1.0, 1.1 or 1.2. | Follow the limits in [Limits](limits.md#limits). Define a named condition. Use `"schema_version": "1.1"`. |
| `openfga:2001 authorization_model_not_found` | `22023` | `model_id` is not the id of a model. | Use an id that `fga_read_authorization_models` returns. Omit `model_id` to use the latest model. |
| `openfga:2002 authorization_model_resolution_too_complex` | `54001` | The answer needs 25 levels or more. A level is one userset tuple or one parent tuple. | Remove long chains or cycles of usersets from the tuples or the model. |
| `openfga:2003 invalid_write_input` | `22023` | `fga_write` has no `writes` and no `deletes`. | Pass `writes`, `deletes` or both. |
| `openfga:2004 cannot_allow_duplicate_tuples_in_one_request` | `22023` | One call names the same tuple key twice, in `writes`, in `deletes`, or in both. | Name each tuple key once in each call. |
| `openfga:2007 invalid_continuation_token` | `22023` | `fga_read`: the token has a valid form but the extension does not know it. | Pass the token as the previous call returned it. Use `''` for the first page. |
| `openfga:2017 write_failed_due_to_invalid_input` | `22023` | `fga_write` writes a tuple that exists, or deletes a tuple that does not exist. Or it writes a tuple key that exists with another condition. | Use `on_duplicate` or `on_missing` with `ignore`. To change a condition, delete the tuple and write it again. |
| `openfga:2020 latest_authorization_model_not_found` | `22023` | The call needs a model, and no model exists. | Write a model with `fga_write_authorization_model`. |
| `openfga:2021 type_not_found` | `22023` | `fga_list_objects` or `fga_list_users`: a type is not in the model. | Use a type from the hint. |
| `openfga:2022 relation_not_found` | `22023` | `fga_list_objects` or `fga_list_users`: a relation is not defined on the type. | Use a relation from the hint. |
| `openfga:2027 invalid_tuple` | `22023` | A tuple in `fga_write`, `fga_write_tuple` or `contextual_tuples` is not valid for the model. The key is malformed. Or its type or relation is not in the model. Or the type restriction does not accept the subject. Or a tupleset relation has a wildcard or a userset. | Use a subject that the relation accepts. The hint lists the accepted types. |
| `openfga:2047 type_invalid_pattern` | `22023` | A type name is not valid. | Use 1 to 254 characters, without `:`, `#`, `@` or white space. |
| `openfga:2050 relations_invalid_pattern` | `22023` | A relation name is not valid. | Use 1 to 50 characters, without `:`, `#`, `@` or white space. |
| `openfga:2053 exceeded_entity_limit` | `22023` | `fga_write` has more than 100 tuple keys, writes and deletes together. | Write in batches of 100 or less. |
| `openfga:2056 invalid_authorization_model` | `22023` | The model is not a JSON object, or `type_definitions` is empty. | Pass the body of the OpenFGA WriteAuthorizationModel request. |
| `openfga:2056 invalid_authorization_model` | `22023` | The schema version is `1.0`, or the model defines a type twice. A type or a relation has the reserved name `self` or `this`. | Use schema 1.1. Define each type once. Rename the type or the relation. |
| `openfga:2056 invalid_authorization_model` | `22023` | A type restriction names a type or a relation that is not in the model. The metadata names a relation that is not defined. | Fix the name. The hint gives the nearest name. |
| `openfga:2056 invalid_authorization_model` | `22023` | A rewrite is not valid, a computed relation is not defined, or a `from` relation is not a direct relation of plain types. | Define the relation. In `x from y`, make `y` a direct relation with plain types. |
| `openfga:2056 invalid_authorization_model` | `22023` | A relation with `this` has no type restrictions, or a relation without `this` has type restrictions. | Give each direct relation a restriction, such as `[user]`. Remove restrictions from other relations. |
| `openfga:2056 invalid_authorization_model` | `22023` | `no entrypoints defined`: no tuple can ever satisfy a relation. | Give the relation a direct type restriction, or compute it from a relation that has one. |
| `openfga:2056 invalid_authorization_model` | `22023` | `an authorization model cannot contain a cycle`: computed relations on one type refer to each other. | Remove one of the references. Recursion is valid through a userset or a `from` relation. |
| `openfga:2056 invalid_authorization_model` | `22023` | A restriction names a condition that is not defined, or the key of a condition differs from its name. | Define the condition in `conditions`. |
| `openfga:2056 invalid_authorization_model` | `22023` | `failed to compile expression on condition`. The cause is a syntax error, an unknown name, a type error, or a result that is not `bool`. Or the expression uses a CEL part that the extension does not support. | Fix the expression. See [CEL subset](cel.md#cel-subset). |
| `openfga:2056 invalid_authorization_model` | `22023` | `failed to decode parameter type`: a parameter type is not valid. A `bytes` parameter is not supported. | Use a parameter type from [CEL subset](cel.md#cel-subset). |
| `openfga:2057 unsupported_schema_version` | `22023` | The schema version is `1.2`, the version for modular models. | Use schema 1.1. |

The RLS helpers raise a subset of these errors. They raise no error when there is no subject, when there is no model, or when the model does not define the subject type. They return `false` or no rows. They never raise an error for a condition.

## Cedar errors

Each row has one code, in the column `DETAIL`. The same code has the same cause in each function that raises it. The `DETAIL` column shows the form of the context after the code.

| `DETAIL` | SQLSTATE | Raised by | Cause | Fix |
| --- | --- | --- | --- | --- |
| `cedar:parse_error line=<n> column=<n>` | `42601` | `cedar_put_policy`, `cedar_put_template` (text) | The text is not one Cedar policy. It has a syntax error, no policy, or more than one policy. The message names the position. | Fix the text at the line and the column. The hint links the Cedar grammar. Put each policy with its own call. |
| `cedar:invalid_policy path='<json path>'` | `22023` | `cedar_put_policy`, `cedar_put_template` (JSON, and the checks of text) | The JSON does not have the shape of Cedar's policy format. Or a static policy has a slot. Or a template has no slot, or has a slot outside the principal and resource scopes. | Pass the policy as the Cedar CLI writes it. Use `cedar_put_template` for a policy with a slot, and `cedar_put_policy` for a policy without one. |
| `cedar:invalid_argument argument='policy'` | `22023` | `cedar_put_policy`, `cedar_put_template` | A call passes both the text and the JSON. | Pass exactly one. |
| `cedar:invalid_argument value='<text>'` | `22023` | `cedar_list_resources_current` | `resource_type` is not an entity type name. | Pass a type name without an id, such as `'Document'` or `'App::Document'`. |
| `cedar:unknown_policy policy_id='<id>'` | `22023` | `cedar_delete_policy` | No policy has this id. | Use an id from `cedar_policies`. The hint lists the ids. |
| `cedar:unknown_template template_id='<id>'` | `22023` | `cedar_link_template`, `cedar_delete_template` | No template has this id. | Use an id from `cedar_templates`. The hint gives the nearest id. |
| `cedar:template_in_use template_id='<id>'` | `2BP01` | `cedar_delete_template`, `cedar_put_template` | The template has links. Or a new template does not keep a slot that a link fills. | Delete the links with `cedar_delete_policy` first. The hint names them. Keep the slots in the new template. |
| `cedar:id_in_use id='<id>'` | `23505` | `cedar_put_policy`, `cedar_put_template`, `cedar_link_template` | The id belongs to the other kind: a static policy, a template or a link. | Choose another id, or delete the existing one first. |
| `cedar:invalid_link slot='?<name>'` | `22023` | `cedar_link_template` | A slot of the template has no value, or a value has no slot. | Pass a value for each slot of the template and nothing else. The hint names the slots. |
| `cedar:invalid_uid value='<text>'` | `22023` | Every function that takes a uid | The text is not `Type::"id"`. For `cedar_delete_entities`, an item is not `{"type", "id"}` or Cedar text. | Write `User::"alice"`, or build the text with `cedar_uid`. |
| `cedar:invalid_entity index=<n>` | `22023` | `cedar_put_entities`, `entities` of `cedar_is_authorized` | The entity at this index is not valid. The uid is a duplicate. A value is not a Long, a String, a Boolean, a set, a record, an entity or an extension value. An extension value is not valid. The `entities` argument is not an array. | Fix the entity. The message names the path of the value. The hint shows the format. |
| `cedar:invalid_entity uid='<uid>'` | `22023` | `cedar_put_entities` | The put makes a cycle in the hierarchy. The uid is on the cycle. | Remove one of the parent links of the cycle. |
| `cedar:invalid_context` | `22023` | `cedar_is_authorized` | The context is not a JSON object, or a value in it is not valid. | Pass a JSON object. Write an extension value as `{"__extn": {"fn": "ip", "arg": "10.0.0.1"}}`. |
| `cedar:unsupported feature='<name>'` | `0A000` | `cedar_put_policy`, `cedar_put_template`, and the parser | A string holds U+0000. Or a record literal in a policy has the only key `__entity` or `__extn`. | Remove the character or the key. See [Compatibility](../models/cedar/compatibility.md#differences-from-cedar). |
| `cedar:null_argument argument='<name>'` | `22004` | `cedar_put_policy`, `cedar_delete_policy`, `cedar_put_template`, `cedar_link_template`, `cedar_delete_template`, `cedar_put_entities`, `cedar_delete_entities`, `cedar_read_entities`, `cedar_is_authorized` | A required argument is `null`. Or `cedar_put_policy` has neither `policy` nor `policy_json`. Or `cedar_read_entities` has `ids` and no `type`. | Pass the argument. The hint shows a call. |
| `cedar:limit_exceeded limit='<name>'` | `54000` | `cedar_put_policy`, `cedar_put_template`, `cedar_is_authorized` | A policy or a context is over a limit. The name is `policy_bytes`, `policy_nodes`, `policy_depth` or `value_depth`. | Split the policy into smaller policies. Flatten the data. See [Limits](limits.md#cedar-limits). |
| `cedar:limit_exceeded index=<n>` | `54000` | `cedar_put_entities`, `entities` of `cedar_is_authorized` | The array has more entities than the limit, or a value nests deeper than 32 levels. | Put the entities in batches. See [Limits](limits.md#cedar-limits). |

The functions for RLS raise a small subset of these errors. `cedar_is_authorized_current` and `cedar_list_resources_current` raise `cedar:invalid_uid` for an action that is not a uid. `cedar_is_authorized_current` raises it for a resource that is not of the form `Type::"..."`. `cedar_list_resources_current` raises `cedar:invalid_argument` for a bad `resource_type`. They return `false` or no rows when there is no subject, when an argument is `null`, and when a `forbid` fails. They never raise an error for a policy that fails, and they never raise an error for an id that holds a `"` or a `\`.

A policy that fails while it runs is not an error of the call. `cedar_is_authorized` returns it in `errors`, and the message starts with one of these codes:

| Code | Cause |
| --- | --- |
| `attribute_not_found` | The expression reads an attribute that the entity or the record does not have. |
| `entity_does_not_exist` | The expression reads an attribute of an entity that is not stored. |
| `tag_not_found` | `getTag` reads a tag that the entity does not have. |
| `type_error` | An operator or a method got a value of the wrong type. |
| `overflow` | A Long operation went outside -2^63 to 2^63-1. |
| `extension_error` | An extension function got a value that it cannot read, or the wrong number of arguments. |

## Errors from Postgres

Postgres raises these errors, not the extension:

| SQLSTATE | Cause | Fix |
| --- | --- | --- |
| `42501` | A role without the privilege calls an admin function or reads a table. The message is `permission denied for function ...`. | Call the function as the extension owner, or grant `execute` on it. See [Privileges](../integrations/privileges.md). |
| `57014` | The statement is longer than `statement_timeout`. | Increase the timeout, or make the query smaller. |
| `23502` | A call passes `null` as the name of a role. | Pass a name. |
