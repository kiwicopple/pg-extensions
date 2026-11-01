# The OpenFGA model

The `fga_*` functions give you the [OpenFGA](https://openfga.dev) API in SQL. They use the same language for models and the same tuples. Check, ListObjects, ListUsers and Read give the same answers and the same error codes as OpenFGA.

Use this model when roles are not enough. Examples are one shared document, nested teams, and folders whose viewers see the content of the folder.

This page covers the API without conditions. [OpenFGA conditions](conditions.md) covers conditions. [RLS with both models](rls.md) shows how to use the functions in policies. [Function reference](reference.md) has the full signature of each function. [Errors and limits](errors-and-limits.md) lists every error.

The test suite of OpenFGA runs against these functions (see [`test/fga/`](../test/fga/)).

The examples on this page run in order. Each section uses the model and the tuples that the sections before it wrote.

## How the functions map to OpenFGA

The extension keeps one implicit store in each database. There is no store id. To use two stores, use two databases or two schemas.

| OpenFGA | pg_permissions |
| --- | --- |
| WriteAuthorizationModel | `fga_write_authorization_model` |
| ReadAuthorizationModel, ReadAuthorizationModels | `fga_read_authorization_model`, `fga_read_authorization_models` |
| Write | `fga_write`, `fga_write_tuple`, `fga_delete_tuple` |
| Read | `fga_read` |
| Check | `fga_check` |
| ListObjects | `fga_list_objects` |
| ListUsers | `fga_list_users` |
| DeleteStore | `fga_delete_store` |
| The `user` field of a tuple | The `subject` argument |
| `authorization_model_id` | The `model_id` argument |
| `contextual_tuples`, `context` | The arguments with the same names |

`user` is a reserved word in SQL. For this reason the argument is `subject`, and `user => ...` does not parse. A subject has one of three forms:

- `type:id`, for example `user:anne`.
- `type:*`, a typed wildcard. It means every subject of that type.
- `type:id#relation`, a userset. It means every subject that has the relation to that object.

## Write a model

Write the model in the OpenFGA DSL, as in the OpenFGA documentation. This model has teams that can contain teams. It also has folders that inherit viewers from the parent folder, and documents in folders.

```text
model
  schema 1.1

type user

type team
  relations
    define member: [user, team#member]

type folder
  relations
    define parent: [folder]
    define owner: [user]
    define viewer: [user, team#member] or owner or viewer from parent

type document
  relations
    define parent: [folder]
    define owner: [user]
    define editor: [user, team#member] or owner
    define viewer: [user, user:*, team#member] or editor or viewer from parent
    define blocked: [user]
    define can_view: viewer but not blocked
```

The extension takes the model as JSON. This is the body of the OpenFGA WriteAuthorizationModel request. Convert the DSL with the [OpenFGA CLI](https://github.com/openfga/cli). This is a fragment for a shell:

```bash
fga model transform --file model.fga > model.json
# or, with Docker:
docker run --rm -i openfga/cli model transform \
  --input-format fga \
  --output-format json \
  --file /dev/stdin < model.fga > model.json
```

Each type becomes an object. Its `relations` key holds the rewrite. Its `metadata` key holds the type restrictions, the part in `[...]`. This fragment shows the `folder` type:

```json
{
  "type": "folder",
  "relations": {
    "owner": {"this": {}},
    "parent": {"this": {}},
    "viewer": {
      "union": {
        "child": [
          {"this": {}},
          {"computedUserset": {"relation": "owner"}},
          {
            "tupleToUserset": {
              "tupleset": {"relation": "parent"},
              "computedUserset": {"relation": "viewer"}
            }
          }
        ]
      }
    }
  },
  "metadata": {
    "relations": {
      "owner": {
        "directly_related_user_types": [{"type": "user"}]
      },
      "parent": {
        "directly_related_user_types": [{"type": "folder"}]
      },
      "viewer": {
        "directly_related_user_types": [
          {"type": "user"},
          {"type": "team", "relation": "member"}
        ]
      }
    }
  }
}
```

Write the model as the admin. In psql, read the JSON from the file `model.json`:

```sql
\set model `cat model.json`
select permissions.fga_write_authorization_model(
  model => :'model'
) as model_id \gset
```

The function returns the id of the new model. The id is a ULID, for example `01JB...`. The new model becomes the latest model.

Every function on this page uses the latest model. To use an older model, pass `model_id`. `fga_read_authorization_models()` lists the models, newest first. `fga_read_authorization_model()` returns one model, with its `id`. Without an argument, it returns the latest model.

```sql
select count(*)
from permissions.fga_read_authorization_models();
-- 1
select permissions.fga_read_authorization_model(
  model_id => :'model_id'
) ->> 'id' = :'model_id';
-- true
```

The extension checks the model as the OpenFGA server does. It raises the same error codes. This example has a typo in a relation name:

```sql
select permissions.fga_write_authorization_model(
  model => '{
    "schema_version": "1.1",
    "type_definitions": [
      {"type": "user"},
      {
        "type": "document",
        "relations": {
          "editor": {"this": {}},
          "viewer": {"computedUserset": {"relation": "editr"}}
        },
        "metadata": {
          "relations": {
            "editor": {
              "directly_related_user_types": [{"type": "user"}]
            }
          }
        }
      }
    ]
  }'
);
-- ERROR:  document#viewer: computed relation 'editr' is not defined on type 'document'
-- DETAIL:  openfga:2056 invalid_authorization_model
-- HINT:  Did you mean 'editor'? Relations on type 'document': editor, viewer.
```

The extension also refuses a relation that no tuple can satisfy. For example, `define viewer: reader` and `define reader: viewer` refer only to each other. This fails with `no entrypoints defined`. Computed relations that refer to each other in a cycle also fail, even when each relation has a type restriction. A refused model does not become the latest model. The tests in [`test/fga_lang/`](../test/fga_lang/) run the OpenFGA validation cases against this function.

## Write tuples

A tuple says that a subject has a relation to an object. This is a tuple key in JSON: `{"user": "user:bob", "relation": "member", "object": "team:eng"}`. In a tuple key, the `user` field holds the subject.

Write tuples with `fga_write`:

```sql
select permissions.fga_write(
  writes => '[
    {
      "user": "user:bob",
      "relation": "member",
      "object": "team:eng"
    },
    {
      "user": "team:design#member",
      "relation": "member",
      "object": "team:eng"
    },
    {
      "user": "user:carl",
      "relation": "member",
      "object": "team:design"
    },
    {
      "user": "user:anne",
      "relation": "owner",
      "object": "folder:projects"
    },
    {
      "user": "team:eng#member",
      "relation": "viewer",
      "object": "folder:projects"
    },
    {
      "user": "folder:projects",
      "relation": "parent",
      "object": "folder:roadmaps"
    },
    {
      "user": "folder:roadmaps",
      "relation": "parent",
      "object": "document:roadmap"
    },
    {
      "user": "user:dana",
      "relation": "editor",
      "object": "document:roadmap"
    },
    {
      "user": "user:carl",
      "relation": "blocked",
      "object": "document:roadmap"
    },
    {
      "user": "user:*",
      "relation": "viewer",
      "object": "document:handbook"
    }
  ]'
);
```

These tuples state these facts:

- Bob is in team `eng`. Everyone in team `design` is also in team `eng`. Carl is in team `design`.
- Anne owns the `projects` folder. Team `eng` views it.
- The `roadmaps` folder is inside `projects`. The roadmap document is inside `roadmaps`.
- Dana edits the roadmap. Carl has the `blocked` relation to the roadmap.
- Everyone views the handbook.

To write or delete one tuple, use `fga_write_tuple` or `fga_delete_tuple`. These functions do not fail when the tuple is already there or already gone:

```sql
select permissions.fga_write_tuple(
  subject => 'user:erin',
  relation => 'owner',
  object => 'document:notes'
);
select permissions.fga_write_tuple(
  subject => 'user:erin',
  relation => 'owner',
  object => 'document:notes'
);
-- no error: already there
select permissions.fga_delete_tuple(
  subject => 'user:erin',
  relation => 'owner',
  object => 'document:notes'
);
```

`fga_write` takes writes and deletes together, in one transaction. Each side is an array of tuple keys. Each side can also be an object `{"tuple_keys": [...]}` with an option. The option `"on_duplicate": "ignore"` applies to writes. The option `"on_missing": "ignore"` applies to deletes:

```sql
select permissions.fga_write(
  writes => '[
    {
      "user": "user:erin",
      "relation": "editor",
      "object": "document:notes"
    }
  ]',
  deletes => '{
    "tuple_keys": [
      {
        "user": "user:zed",
        "relation": "editor",
        "object": "document:notes"
      }
    ],
    "on_missing": "ignore"
  }'
);
```

Without an option, `fga_write` raises an error when you write a tuple that exists. It also raises an error when you delete a tuple that does not exist. This is the OpenFGA behavior.

```sql
select permissions.fga_write(
  writes => '[
    {
      "user": "user:erin",
      "relation": "editor",
      "object": "document:notes"
    }
  ]'
);
-- ERROR:  cannot write a tuple which already exists: document:notes#editor@user:erin
-- DETAIL:  openfga:2017 write_failed_due_to_invalid_input
-- HINT:  Pass writes as {"tuple_keys": [...], "on_duplicate": "ignore"} to skip tuples that already exist.
```

The extension checks each tuple against the type restrictions of the model. The relation `editor` is `[user, team#member]`, so a wildcard is not valid:

```sql
select permissions.fga_write(
  writes => '[
    {
      "user": "user:*",
      "relation": "editor",
      "object": "document:notes"
    }
  ]'
);
-- ERROR:  Invalid tuple 'document:notes#editor@user:*'. Reason: the typed wildcard 'user:*' is not an allowed type restriction for 'document#editor'
-- DETAIL:  openfga:2027 invalid_tuple
-- HINT:  'document#editor' allows users of type: team#member, user.
```

`fga_write` accepts at most 100 tuple keys in each call. See [Errors and limits](errors-and-limits.md#limits).

## Check

`fga_check` is the OpenFGA Check. It answers one question: does the subject have the relation to the object? The result is `true` or `false`. Each example names every argument:

```sql
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

```sql
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

`fga_list_objects` returns the objects of one type that the subject has the relation to. Each result is a `type:id` string. The order is not defined:

```sql
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

The function returns at most 1,000 objects, as OpenFGA does. It drops the other objects without an error. For RLS, use `fga_list_object_ids_current`. It has no cap. See [Functions for RLS](#functions-for-rls).

An unknown type is error `openfga:2021`. An unknown relation is error `openfga:2022`.

## ListUsers

`fga_list_users` returns the subjects that have the relation to the object. The argument `user_filters` says which kind of subject you want. Use a type (`user`) or a userset (`team#member`):

```sql
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

`fga_read` returns stored tuples. It does not evaluate the model. It returns one page of the OpenFGA ReadResponse, as one row with two columns: `tuples` (jsonb) and `continuation_token` (text).

Filter the tuples with `object`, `relation` and `subject`, in any combination. The value of `object` is `type:id`, or `type:` for every object of a type.

```sql
select tuples, continuation_token
from permissions.fga_read(object => 'document:roadmap');
-- tuples: [{"key": {"user": "folder:roadmaps", "relation": "parent", "object": "document:roadmap"}, "timestamp": "..."}, ...] (3 tuples)
-- continuation_token: '' (the last page)

-- one row for each tuple
select t #>> '{key,relation}', t #>> '{key,user}'
from permissions.fga_read(object => 'document:roadmap') r,
  jsonb_array_elements(r.tuples) t;
```

A page holds 50 tuples. To change this, pass `page_size` (1 to 100). The tuples come in the order of the writes. When more tuples exist, `continuation_token` is not empty. Pass the token back without change to get the next page. A token with the value `''` means that this is the last page.

```sql
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

To read every page in one query, use a recursive query:

```sql
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

```sql
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

Use contextual tuples for facts that your application knows at the time of the request. An example is a group membership from the identity provider. Do not store these facts as tuples. The functions for RLS do not take contextual tuples, because a client could vouch for itself.

## Functions for RLS

Clients cannot call the functions above, because those functions take the subject as an argument (see [Privileges](#privileges)). Clients call three functions that answer for the current subject:

| Function | Returns |
| --- | --- |
| `fga_check_current(relation, object)` | `true` or `false` |
| `fga_list_objects_current(type, relation)` | The objects as `type:id` strings |
| `fga_list_object_ids_current(type, relation)` | The ids of the objects, without the type |

The current subject is `current_subject_type()` and `current_subject_id()`, joined as `type:id`. The default type is `user`. [Function reference](reference.md#shared-functions) shows how the extension finds the current subject. This example sets the subject for the session:

```sql
select set_config('permissions.subject_id', 'bob', false);
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
select set_config('permissions.subject_id', '', false);
select permissions.fga_check_current(
  relation => 'viewer',
  object => 'document:roadmap'
);
-- false: no subject, no access
```

In three cases these functions return `false` or no rows. They raise no error. The cases are: there is no subject, there is no model, or the model does not define the subject type. An unknown object type or an unknown relation is still an error, as in OpenFGA.

The functions have no cap on the number of results. They take no contextual tuples and no `context`. [OpenFGA conditions](conditions.md#conditions-in-rls-helpers) explains how they treat conditioned tuples.

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

For a list of rows, the fast form is `id = any (array(select permissions.fga_list_object_ids_current(type => 'document', relation => 'viewer')))`. See [RLS with both models](rls.md).

## Change the model

The extension never changes a model in place. Write a new model, and it becomes the latest model. The old model stays, and it still answers when you pass its id.

Tuples do not belong to a model. When a new model does not accept a tuple, the extension keeps the tuple and ignores it in checks. You can still read and delete it. This example removes `blocked` and `can_view`:

```sql
select permissions.fga_write_authorization_model(
  model => jsonb_set(
    :'model'::jsonb,
    '{type_definitions,3}',
    (:'model'::jsonb #> '{type_definitions,3}')
      #- '{relations,blocked}'
      #- '{relations,can_view}'
      #- '{metadata,relations,blocked}'
      #- '{metadata,relations,can_view}'
  )
) as model_v2 \gset

select permissions.fga_check(
  subject => 'user:carl',
  relation => 'can_view',
  object => 'document:roadmap'
);
-- ERROR:  relation 'document#can_view' not found
-- DETAIL:  openfga:2000 validation_error
select permissions.fga_check(
  subject => 'user:carl',
  relation => 'can_view',
  object => 'document:roadmap',
  model_id => :'model_id'
);
-- false: the old model
select jsonb_array_length(tuples)
from permissions.fga_read(
  object => 'document:roadmap',
  relation => 'blocked'
);
-- 1: the tuple is still there
```

In practice, edit `model.fga` and transform it again. To remove every model and every tuple, call `fga_delete_store()`.

## Privileges

Only the role that installed the extension can call the functions on this page, except the functions for RLS. These functions take the subject as an argument, or they change data. A client that can call `fga_check` can ask what anyone can see. A client that can write tuples can share anything with itself.

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

Grant only the functions that the backend uses. Keep `fga_delete_store()` for the owner. See [Privileges](reference.md#privileges) in the function reference.

## Differences from OpenFGA

The extension follows OpenFGA closely. These differences are on purpose:

- One implicit store in each database. There is no CreateStore, ListStores or store id.
- Errors are Postgres exceptions. They are not gRPC or HTTP statuses. See [Errors and limits](errors-and-limits.md).
- The limits are the OpenFGA defaults. You cannot change them. There is no time limit on ListObjects and ListUsers. OpenFGA stops a list after 3 seconds and returns part of the list. Set `statement_timeout` instead. It raises an error and does not return part of a list.
- The functions use the snapshot of the statement. There is no `consistency` argument and no cache.
- ListUsers returns `type:id#relation` strings. It does not return `User` objects, and it has no `excluded_users`.
- `fga_read` accepts any combination of `object`, `relation` and `subject`, or none. OpenFGA is stricter.
- Take a relation that uses no `and` and no `but not`, directly or through other relations. A Check on this relation that is `false` is always `false`. OpenFGA can return error `openfga:2002` there when an unrelated branch is too deep.
- The model has no size limit and no limit on the number of types.
- Conditions use a CEL evaluator in PL/pgSQL. See [OpenFGA conditions](conditions.md#cel-subset).

These OpenFGA features do not exist: Expand, BatchCheck, StreamedListObjects, ReadChanges, assertions, and modular models (schema 1.2).
