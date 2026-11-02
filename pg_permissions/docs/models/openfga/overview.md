# Relationships (OpenFGA)

Use relationships to share individual documents, nest teams, and inherit access from folders. The `fga_*` functions follow the OpenFGA model language and APIs, with [documented differences](compatibility.md).

Start with [Define an authorization model](models.md), then [write tuples](tuples.md) and [check access](checks.md). The walkthrough uses one database and builds its data in that order. Models and tuples are managed by an admin; current-subject methods are available to application clients.

## Use from JavaScript

An example that has a JavaScript equivalent shows it next to the SQL. The JavaScript examples use [the JavaScript client](../../integrations/javascript.md). Install the client first.

The admin calls use the server client:

```ts
import pg from 'pg'
import { createServerClient } from 'permissions'

const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
})
const permissions = createServerClient(pool)
```

The JavaScript examples throughout this walkthrough use `permissions`. Some things differ from SQL:

- Each method returns `{ data, error }`. It does not throw for a database error.
- The model, the tuples and the context are JavaScript objects. You do not write JSON strings.
- The argument `subject` is `user`. The names that have an underscore are in camel case: `authorizationModelId` for `model_id`, `userFilters` for `user_filters`.
- A check for a user runs through `as({ id })`. It sets the current subject for each call. Each task page links to the setup it needs.

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

`user` is a reserved word in SQL. For this reason the argument is `subject`, and `user => ...` does not parse. Subject identifiers use these forms:

- `type:id`, for example `user:anne`.
- `type:*`, a typed wildcard. It means every subject of that type.
- `type:id#relation`, a userset. It means every subject that has the relation to that object.
