# Define an authorization model

Describe the relationships your application supports, then write the model to Postgres.

Use the [server client](overview.md#use-from-javascript) with an admin connection to a fresh database with the extension installed. Save the model below as `model.fga`. Later pages use its JSON representation and ID. Run examples marked as errors separately from a migration that stops on errors.

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

Write the model as the admin. Read the JSON from the file `model.json`:

```js tab="JavaScript"
import { readFileSync } from 'node:fs'

const json = readFileSync('model.json', 'utf8')
const model = JSON.parse(json)

const written =
  await permissions.fga.admin.writeAuthorizationModel(model)
if (written.error) throw written.error
const modelId = written.data.authorizationModelId
```

```sql tab="SQL"
\set model `cat model.json`
select permissions.fga_write_authorization_model(
  model => :'model'
) as model_id \gset
```

A successful write returns the new ID in `data.authorizationModelId`. The id is a ULID, for example `01JB...`. The new model becomes the latest model.

Checks use the latest model by default. Pass `authorizationModelId` (`model_id` in SQL) to check against a particular version. `fga_read_authorization_models()` lists the models, newest first. `fga_read_authorization_model()` returns one model, with its `id`. Without an argument, it returns the latest model.

```js tab="JavaScript"
const all = await permissions.fga.admin.readAuthorizationModels()
// all.data.length: 1
const one = await permissions.fga.admin.readAuthorizationModel({
  authorizationModelId: modelId,
})
// one.data.id === modelId: true
```

```sql tab="SQL"
select count(*)
from permissions.fga_read_authorization_models();
-- 1
select permissions.fga_read_authorization_model(
  model_id => :'model_id'
) ->> 'id' = :'model_id';
-- true
```

The extension checks the model as the OpenFGA server does. It raises the same error codes. This example has a typo in a relation name:

```js tab="JavaScript"
const typo = {
  schema_version: '1.1',
  type_definitions: [
    { type: 'user' },
    {
      type: 'document',
      relations: {
        editor: { this: {} },
        viewer: { computedUserset: { relation: 'editr' } },
      },
      metadata: {
        relations: {
          editor: {
            directly_related_user_types: [{ type: 'user' }],
          },
        },
      },
    },
  ],
}
const refused =
  await permissions.fga.admin.writeAuthorizationModel(typo)
// refused.error.message:
//   document#viewer: computed relation 'editr' is not defined ...
// refused.error.details:
//   openfga:2056 invalid_authorization_model
// refused.error.hint: Did you mean 'editor'? ...
```

```sql tab="SQL"
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

The extension also refuses a relation that no tuple can satisfy. For example, `define viewer: reader` and `define reader: viewer` refer only to each other. This fails with `no entrypoints defined`. Computed relations that refer to each other in a cycle also fail, even when each relation has a type restriction. A refused model does not become the latest model. The tests in [`test/fga_lang/`](../../../test/fga_lang) run the OpenFGA validation cases against this function.

## Next step

Continue with [Share objects and manage tuples](tuples.md).
