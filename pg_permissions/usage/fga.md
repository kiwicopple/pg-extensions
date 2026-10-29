# The OpenFGA model

The `fga_*` functions are [OpenFGA](https://openfga.dev)'s API in SQL: the same modeling language, the same tuples, and Check, ListObjects, ListUsers and Read with OpenFGA's answers and error codes. Use it when roles aren't enough: sharing one document, nested teams, folders whose viewers see what's inside. It sits next to the `rbac` preset ([README](README.md)); [RLS with both models](rls.md) shows how to use the two together in policies.

Every example on this page runs as written in [`test/spec/d/90_usage_fga.sql`](../test/spec/d/90_usage_fga.sql), in the same order: each section uses the model and tuples the previous ones wrote. OpenFGA's own test suite runs against the same functions ([`test/fga/`](../test/fga/), 933 of 933 assertions; [`designs/d-per-model.md`](../designs/d-per-model.md) section 9). Where this extension differs from OpenFGA is in that design doc, section 8. The main differences: there is one store per database, conditions aren't supported yet, and errors are Postgres exceptions.

All the functions on this page are admin-only, because they take the user as an argument ([Privileges](#privileges)). Clients use the current-subject functions in [RLS with both models](rls.md).

## Writing a model

Write the model in OpenFGA's DSL, as in OpenFGA's documentation. This one has teams that can contain teams, folders that inherit viewers from their parent folder, and documents in folders:

```
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

The extension takes the model as JSON, the body of OpenFGA's WriteAuthorizationModel request. Convert the DSL with the [OpenFGA CLI](https://github.com/openfga/cli):

```bash
fga model transform --file model.fga > model.json
# or, with Docker:
docker run --rm -i openfga/cli model transform --input-format fga --output-format json --file /dev/stdin < model.fga > model.json
```

Each type becomes an object with its `relations` (the rewrite) and `metadata` (the type restrictions, the part in `[...]`). The `folder` type, for example:

```json
{"type": "folder",
 "relations": {
   "owner":  {"this": {}},
   "parent": {"this": {}},
   "viewer": {"union": {"child": [
     {"this": {}},
     {"computedUserset": {"relation": "owner"}},
     {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}}},
 "metadata": {"relations": {
   "owner":  {"directly_related_user_types": [{"type": "user"}]},
   "parent": {"directly_related_user_types": [{"type": "folder"}]},
   "viewer": {"directly_related_user_types": [{"type": "user"}, {"type": "team", "relation": "member"}]}}}}
```

The spec file has the whole output. Write it as the admin. In psql:

```sql
\set model `cat model.json`
select permissions.fga_write_authorization_model(:'model') as model_id \gset
```

The function returns the new model's id, a ULID such as `01JB...`, and the model becomes the latest. Every function on this page uses the latest model unless you pass `authorization_model_id`. `fga_read_authorization_models()` lists the models, newest first, and `fga_read_authorization_model(id)` returns one (the latest without an argument).

The model is checked as OpenFGA's server checks it, with the same error codes. A typo in a relation name, for example:

```sql
select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [
  {"type": "user"},
  {"type": "document",
   "relations": {"editor": {"this": {}}, "viewer": {"computedUserset": {"relation": "editr"}}},
   "metadata": {"relations": {"editor": {"directly_related_user_types": [{"type": "user"}]}}}}]}');
-- ERROR:  document#viewer: computed relation 'editr' is not defined on type 'document'
-- DETAIL:  openfga:2056 invalid_authorization_model
-- HINT:  Did you mean 'editor'? Relations on type 'document': editor, viewer.
```

Relations that can never be satisfied are refused too: two relations that only refer to each other (`define viewer: reader`, `define reader: viewer`) fail with `no entrypoints defined`, and computed relations that refer to each other in a cycle fail even when each has a type restriction. A refused model doesn't become the latest. OpenFGA's validation cases run against this function ([`test/fga_lang/`](../test/fga_lang/)).

## Tuples

A tuple says that a user has a relation to an object: `{"user": "user:bob", "relation": "member", "object": "team:eng"}`. A user is `type:id`, a typed wildcard `type:*` (everyone of that type), or a userset `type:id#relation` (everyone with that relation to that object). Write them with `fga_write`:

```sql
select permissions.fga_write('[
  {"user": "user:bob",            "relation": "member", "object": "team:eng"},
  {"user": "team:design#member",  "relation": "member", "object": "team:eng"},
  {"user": "user:carl",           "relation": "member", "object": "team:design"},
  {"user": "user:anne",           "relation": "owner",  "object": "folder:projects"},
  {"user": "team:eng#member",     "relation": "viewer", "object": "folder:projects"},
  {"user": "folder:projects",     "relation": "parent", "object": "folder:roadmaps"},
  {"user": "folder:roadmaps",     "relation": "parent", "object": "document:roadmap"},
  {"user": "user:dana",           "relation": "editor", "object": "document:roadmap"},
  {"user": "user:carl",           "relation": "blocked", "object": "document:roadmap"},
  {"user": "user:*",              "relation": "viewer", "object": "document:handbook"}
]');
```

Bob is in team `eng`, and so is everyone in team `design` (Carl). Anne owns the `projects` folder and team `eng` views it. The `roadmaps` folder is inside `projects`, and the roadmap document inside `roadmaps`. Dana edits the roadmap and Carl is blocked from it. Everyone views the handbook.

For one tuple at a time, `fga_write_tuple` and `fga_delete_tuple` don't fail when the tuple is already there or already gone:

```sql
select permissions.fga_write_tuple('user:erin', 'owner', 'document:notes');
select permissions.fga_write_tuple('user:erin', 'owner', 'document:notes');   -- no error: already there
select permissions.fga_delete_tuple('user:erin', 'owner', 'document:notes');
```

`fga_write` takes writes and deletes together, in one transaction. Each side is an array of tuple keys, or OpenFGA's `{"tuple_keys": [...]}` with `"on_duplicate": "ignore"` (writes) or `"on_missing": "ignore"` (deletes):

```sql
select permissions.fga_write(
  writes  => '[{"user": "user:erin", "relation": "editor", "object": "document:notes"}]',
  deletes => '{"tuple_keys": [{"user": "user:zed", "relation": "editor", "object": "document:notes"}], "on_missing": "ignore"}');
```

Without those options, writing a tuple that exists or deleting one that doesn't is an error, as in OpenFGA:

```sql
select permissions.fga_write('[{"user": "user:erin", "relation": "editor", "object": "document:notes"}]');
-- ERROR:  cannot write a tuple which already exists: document:notes#editor@user:erin
-- DETAIL:  openfga:2017 write_failed_due_to_invalid_input
-- HINT:  Pass writes as {"tuple_keys": [...], "on_duplicate": "ignore"} to skip tuples that already exist.
```

Every tuple is checked against the model's type restrictions. `editor` is `[user, team#member]`, so a wildcard is refused:

```sql
select permissions.fga_write('[{"user": "user:*", "relation": "editor", "object": "document:notes"}]');
-- DETAIL:  openfga:2027 invalid_tuple
-- HINT:  'document#editor' allows users of type: team#member, user.
```

## Check

`fga_check(user, relation, object)` is OpenFGA's Check:

```sql
select permissions.fga_check('user:anne', 'viewer', 'document:roadmap');    -- true: owns folder:projects, two parents up
select permissions.fga_check('user:bob',  'viewer', 'document:roadmap');    -- true: team:eng views folder:projects
select permissions.fga_check('user:carl', 'viewer', 'document:roadmap');    -- true: team:design is in team:eng
select permissions.fga_check('user:carl', 'can_view', 'document:roadmap');  -- false: carl is blocked
select permissions.fga_check('user:dana', 'viewer', 'document:roadmap');    -- true: editors view
select permissions.fga_check('user:erin', 'viewer', 'document:roadmap');    -- false
select permissions.fga_check('user:erin', 'viewer', 'document:handbook');   -- true: user:*
```

A deny belongs in the model, as `but not`: `can_view` is `viewer but not blocked`. Check `can_view` where you mean "can see it", and keep `viewer` for "was given access".

## ListObjects

`fga_list_objects(user, type, relation)` returns the objects of a type the user has the relation to, as `type:id` strings in no particular order:

```sql
select permissions.fga_list_objects('user:bob', 'document', 'viewer');     -- document:roadmap, document:handbook
select permissions.fga_list_objects('user:carl', 'document', 'can_view');  -- document:handbook
select permissions.fga_list_objects('user:anne', 'folder', 'viewer');      -- folder:projects, folder:roadmaps
```

It returns at most 1,000 objects, like OpenFGA, and drops the rest without an error ([Errors and limits](#errors-and-limits)). For RLS use `fga_list_object_ids_current`, which has no cap ([RLS with both models](rls.md)).

## ListUsers

`fga_list_users(object, relation, user_filters)` returns who has the relation to the object. The filters say which kind of user you want: a type (`user`) or a userset (`team#member`):

```sql
select permissions.fga_list_users('document:roadmap', 'viewer', '{user}');         -- user:anne, user:bob, user:carl, user:dana
select permissions.fga_list_users('document:roadmap', 'can_view', '{user}');       -- user:anne, user:bob, user:dana
select permissions.fga_list_users('document:roadmap', 'viewer', '{team#member}');  -- team:eng#member, team:design#member
select permissions.fga_list_users('document:handbook', 'viewer', '{user}');        -- user:*
```

A wildcard comes back as `user:*`: everyone. Like ListObjects, at most 1,000.

## Read

`fga_read` returns the stored tuples, without evaluating anything: one page of OpenFGA's ReadResponse as a row of `(tuples jsonb, continuation_token text)`. Filter by object (`type:id`, or `type:` for every object of a type), relation and user, in any combination:

```sql
select tuples, continuation_token from permissions.fga_read('document:roadmap');
-- tuples: [{"key": {"user": "folder:roadmaps", "relation": "parent", "object": "document:roadmap"}, "timestamp": "..."}, ...] (3 tuples)
-- continuation_token: '' (the last page)

-- as rows
select t #>> '{key,relation}', t #>> '{key,user}'
from permissions.fga_read('document:roadmap') r, jsonb_array_elements(r.tuples) t;
```

A page holds 50 tuples unless `p_page_size` (1 to 100) says otherwise, in the order they were written. When there are more, `continuation_token` is not empty: pass it back unchanged to get the next page.

```sql
select tuples, continuation_token as token from permissions.fga_read('folder:', p_page_size => 1) \gset
select tuples, continuation_token as token from permissions.fga_read('folder:', p_page_size => 1, p_continuation_token => :'token') \gset
select tuples, continuation_token as token from permissions.fga_read('folder:', p_page_size => 1, p_continuation_token => :'token') \gset
-- three pages of one tuple each; the third token is ''
```

Or walk every page in one query:

```sql
with recursive pages(tuples, token, n) as (
    select r.tuples, r.continuation_token, 1 from permissions.fga_read(p_page_size => 4) r
  union all
    select r.tuples, r.continuation_token, n + 1
    from pages, permissions.fga_read(p_page_size => 4, p_continuation_token => pages.token) r
    where pages.token <> ''
)
select sum(jsonb_array_length(tuples)) from pages;   -- 11
```

A tuple's `key` is the tuple key `fga_write` takes, so a page can be passed back as `deletes`.

## Contextual tuples

Check, ListObjects and ListUsers take `contextual_tuples`: tuples that count for this one call and are never written. They are checked against the model like writes:

```sql
select permissions.fga_check('user:erin', 'viewer', 'document:roadmap',
    contextual_tuples => '[{"user": "user:erin", "relation": "member", "object": "team:eng"}]');   -- true
select permissions.fga_list_objects('user:erin', 'document', 'viewer',
    contextual_tuples => '[{"user": "user:erin", "relation": "member", "object": "team:eng"}]');   -- document:roadmap, document:handbook, document:notes
select permissions.fga_check('user:erin', 'viewer', 'document:roadmap');                          -- false: nothing was written
```

Use them for facts your application knows at request time and doesn't store as tuples, such as a group membership that comes from the identity provider. The current-subject functions used in RLS don't take them: a client could vouch for itself.

## Errors and limits

Invalid input raises an exception. The SQLSTATE is `22023` (`invalid_parameter_value`; `54001` when a check needs more than 25 levels), `DETAIL` carries OpenFGA's error code and name, the message names the values that were wrong, and `HINT` says how to fix it:

```sql
select permissions.fga_check('user:anne', 'viewr', 'document:roadmap');
-- ERROR:  relation 'document#viewr' not found
-- DETAIL:  openfga:2000 validation_error
-- HINT:  Did you mean 'viewer'? Relations on type 'document': blocked, can_view, editor, owner, parent, viewer.
```

ListObjects gives `openfga:2022 relation_not_found` for the same typo, as OpenFGA does. A misspelled relation is always an error here, never a silent "no access". From a client, read the code from the error's detail (PostgREST returns it as `details`). The full list is in [`designs/d-per-model.md`](../designs/d-per-model.md), section 7.

The limits are OpenFGA's defaults, and they can't be changed:

| Limit | What happens |
| --- | --- |
| `fga_write`: at most 100 tuple keys, writes and deletes together | more is `openfga:2053 exceeded_entity_limit` |
| `fga_list_objects`, `fga_list_users`: at most 1,000 results | the rest are dropped, without an error |
| `fga_read`: pages of 50 by default, 1 to 100 | another page size is `openfga:2000` |
| a Check, ListObjects or ListUsers that needs 25 or more levels | `openfga:2002`, SQLSTATE `54001` |

Write more than 100 tuples in batches; the batches can share a transaction:

```sql
begin;
select permissions.fga_write((select jsonb_agg(jsonb_build_object('user', 'user:u' || g, 'relation', 'viewer', 'object', 'document:big'))
                              from generate_series(1, 100) g));
select permissions.fga_write((select jsonb_agg(jsonb_build_object('user', 'user:u' || g, 'relation', 'viewer', 'object', 'document:big'))
                              from generate_series(101, 200) g));
commit;
```

There is no time limit (OpenFGA stops a list after 3 seconds and returns what it has). Set `statement_timeout` instead; it raises rather than returning part of a list.

## Changing the model

Models are never changed in place. Write a new one and it becomes the latest; the old one stays and still answers when its id is passed. Tuples aren't tied to a model: those the new model doesn't allow are kept, ignored by checks, and can still be read and deleted. This removes `blocked` and `can_view`:

```sql
select permissions.fga_write_authorization_model(
    jsonb_set(:'model'::jsonb, '{type_definitions,3}',
              (:'model'::jsonb #> '{type_definitions,3}') #- '{relations,blocked}' #- '{relations,can_view}'
                #- '{metadata,relations,blocked}' #- '{metadata,relations,can_view}')) as model_v2 \gset

select permissions.fga_check('user:carl', 'can_view', 'document:roadmap');
-- ERROR:  relation 'document#can_view' not found (openfga:2000): not in the latest model
select permissions.fga_check('user:carl', 'can_view', 'document:roadmap', authorization_model_id => :'model_id');   -- false: the old model
select tuples from permissions.fga_read('document:roadmap', 'blocked');   -- carl's tuple is still there
```

In practice you'd edit `model.fga` and transform it again. `fga_delete_store()` removes every model and tuple.

## Privileges

Every function on this page takes the user as an argument or changes data, so only the installing role can call it. A client that could call `fga_check` could ask what anyone can see; one that could write tuples could share anything with itself:

```sql
set role authenticated;
select permissions.fga_check('user:anne', 'viewer', 'document:roadmap');      -- ERROR:  permission denied for function fga_check
select permissions.fga_write_tuple('user:erin', 'owner', 'document:roadmap'); -- ERROR:  permission denied for function fga_write_tuple
select permissions.fga_check_current('viewer', 'document:roadmap');           -- fine: answers for the current subject
reset role;
```

Clients get only `fga_check_current`, `fga_list_objects_current` and `fga_list_object_ids_current`, which answer for the current subject ([RLS with both models](rls.md)). A trusted backend role gets the rest with an explicit grant:

```sql
grant execute on function
    permissions.fga_write_authorization_model(jsonb),
    permissions.fga_read_authorization_model(text),
    permissions.fga_read_authorization_models(),
    permissions.fga_write(jsonb, jsonb, text),
    permissions.fga_write_tuple(text, text, text),
    permissions.fga_delete_tuple(text, text, text),
    permissions.fga_read(text, text, text, integer, text),
    permissions.fga_check(text, text, text, jsonb, text),
    permissions.fga_list_objects(text, text, text, jsonb, text),
    permissions.fga_list_users(text, text, text[], jsonb, text)
to service_role;
```

Grant only what the backend uses. `fga_delete_store()` is better left to the owner.
