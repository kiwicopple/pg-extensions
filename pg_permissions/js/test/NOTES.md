# Probe notes (2026-11-01)

Probed against `test/docker-compose.yml`: Postgres 17.11 with `pg_permissions--0.0.1.sql`, PostgREST 16.5, `pg` 8.23. The integration test `test/integration/transports.test.ts` checks most of these.

## PostgREST (`POST /rpc/<fn>`, `Content-Profile: permissions`)

| Call | Status | Body |
| --- | --- | --- |
| `rbac_has_permission` (boolean) | 200 | `true` |
| `rbac_scopes_with_permission` (text[]), args `{permission}` only | 200 | `["acme"]`, or `[]`. The hidden `plan_time_guard` argument is not needed. |
| `fga_list_objects_current` (setof text) | 200 | `["document:1", "document:2"]`, `[]` when empty |
| `current_subject_id` with no JWT (anon) | 200 | `null` |
| void function (`fga_write_tuple`, as service_role) | **204** | empty body, no content type |
| `fga_read` (OUT `tuples` + INOUT `continuation_token`) | 200 | one object, not an array: `{"tuples":[{"key":{...},"timestamp":"..."}],"continuation_token":""}` |
| `fga_read_authorization_models` (returns table) | 200 | array of objects `[{"id":"...","created_at":"2026-11-01T05:48:04.631493+00:00"}]` |
| `delete_subject` (bigint) | 200 | `0` (a JSON number) |
| error from the extension | 400 | `{"code":"22023","details":"openfga:2000 validation_error","hint":"Did you mean 'viewer'? ...","message":"relation 'document#viewr' not found"}` |
| `rbac_drop_role` unknown role | 400 | `{"code":"22023","details":"rbac:unknown_role role='nobody'","hint":"Existing roles: editor.","message":"unknown role 'nobody'"}` |
| admin function as `authenticated` | 403 | `{"code":"42501","details":null,"hint":null,"message":"permission denied for function rbac_assign_role"}` |
| unknown function | 404 | `{"code":"PGRST202",...}` |

DETAIL and HINT come through as `details` and `hint`. Missing fields are JSON `null`.

## SQL (`pg`)

- `select * from permissions.fga_read(...)` returns one row `{ tuples: <parsed jsonb array>, continuation_token: '' }`. Do not call it as a scalar: `select permissions.fga_read(...)` returns the record as one composite string. Use shape `'record'`.
- A void function, `select permissions.fga_write_tuple(...)`, returns one row `{ fga_write_tuple: '' }`. Shape `'void'` discards it.
- `text[]` comes back as a JS array; `jsonb` as parsed JSON; `timestamptz` as a JS `Date`; **`bigint` as a string** (`delete_subject` returns `'0'`; PostgREST returns a number). The client must convert with `Number()`.
- `setof text` with `select value from fn(...) as t(value)` returns one row per value.
- A pg error has `message`, `code`, `detail`, `hint`, `severity`. The extension errors set `detail` and `hint`. A `42501` has `detail` and `hint` `undefined`.
- Parameters: `$n::text[]` takes a JS array; `$n::jsonb` takes JSON text (the transport stringifies).

## Test setup

- `service_role` connections: `pg.Pool({ options: '-c role=service_role' })` as `postgres` (see `servicePool()` in `integration/helpers.ts`). `service_role` has the grants from `setup.sql`, except `fga_delete_store()`.
- PostgREST JWT secret: `permissions-js-test-secret-at-least-32-chars`. `userToken('alice')` signs `{ sub: 'alice', role: 'authenticated' }`.
- PostgREST `--ready` health check needs `PGRST_ADMIN_SERVER_HOST=127.0.0.1`; with the default server host `!4` it refuses to run.
