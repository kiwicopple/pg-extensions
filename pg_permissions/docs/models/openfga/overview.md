# Relationships (OpenFGA)

Use relationships to share individual documents, nest teams, and inherit access from folders. Store the relationships in Postgres and ask questions such as “Can Anne view this document?” or “Which folders can her team edit?” The extension follows the OpenFGA model language and APIs, with [documented differences](compatibility.md).

Start with [Define an authorization model](models.md), then [write tuples](tuples.md) and [check access](checks.md). The walkthrough uses one database and builds its data in that order. Models and tuples are managed by an admin; current-subject methods are available to application clients.

You can use this as your backend's relationship store and authorization API without RLS. Your backend enforces the returned decision. RLS policies are an optional integration for table queries.

## Use from JavaScript

[Install the JavaScript client](../../integrations/javascript.md), then create a server client with a database role that can manage permissions. Keep the connection string on your backend.

```js
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)
```

Use `permissions.fga.admin` to write models and tuples. Pass them as JavaScript objects. For an application check, call `permissions.as({ id }).fga.check({ relation, object })` with the user ID from your verified session. Each method returns `{ data, error }` by default. Handle `error` before acting on `data`.

## How the functions map to OpenFGA

The extension keeps one implicit store in each database. Calls use the store in the database you connect to.

| OpenFGA | JavaScript (`permissions.fga.admin`) | SQL |
| --- | --- | --- |
| WriteAuthorizationModel | `writeAuthorizationModel` | `fga_write_authorization_model` |
| ReadAuthorizationModel, ReadAuthorizationModels | `readAuthorizationModel`, `readAuthorizationModels` | `fga_read_authorization_model`, `fga_read_authorization_models` |
| Write | `write`, `writeTuple`, `deleteTuple` | `fga_write`, `fga_write_tuple`, `fga_delete_tuple` |
| Read | `read` | `fga_read` |
| Check | `check` | `fga_check` |
| ListObjects | `listObjects` | `fga_list_objects` |
| ListUsers | `listUsers` | `fga_list_users` |
| DeleteStore | `deleteStore` | `fga_delete_store` |
| The `user` field of a tuple | `user` | The `subject` argument |
| `authorization_model_id` | `authorizationModelId` | The `model_id` argument |
| `contextual_tuples`, `context` | `contextualTuples`, `context` | The arguments with the same names |

`user` is a reserved word in SQL. For this reason the argument is `subject`, and `user => ...` does not parse. Subject identifiers use these forms:

- `type:id`, for example `user:anne`.
- `type:*`, a typed wildcard. It means every subject of that type.
- `type:id#relation`, a userset. It means every subject that has the relation to that object.
