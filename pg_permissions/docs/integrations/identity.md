# Identity and request context

Identify the subject before a permission check or a query protected by RLS. All three permission models use the same identity functions. Identity works independently of RLS; it tells the check whose access to evaluate.

The SQL examples use psql variables `alice` and `bob` for user IDs. Set them before running the examples:

```sql
\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
```

JavaScript snippets assume you have created a [client](javascript.md). The request-handler example is a fragment: use your own pool, database role, and authenticated user ID.

## Identity

Each check answers for the current subject. The extension does not store users. It does not read the `auth` schema. Two functions tell the extension who the subject is:

- `permissions.current_subject_id()` returns the ID of the subject, or null when there is no subject.
- `permissions.current_subject_type()` returns the type of the subject. The default is `'user'`.

The ID comes from the first nonempty source:

1. The `sub` claim of the JWT in the configuration parameter `request.jwt.claims`. Supabase and PostgREST set it on each request. It is the value that `auth.uid()` returns.
2. The configuration parameter `permissions.subject_id`. Plain Postgres uses this source.
3. If neither source has a value, the ID is null. Then each check returns false.

```sql tab="SQL"
select permissions.current_subject_id();
-- null: no JWT, no parameter
select permissions.current_subject_type();
-- user
select permissions.rbac_has_permission(permission => 'documents.read');
-- false: no subject, no access
```

```ts tab="JavaScript"
const { data: id } = await permissions.currentSubjectId()
// null: no JWT, no parameter
const { data: type } = await permissions.currentSubjectType()
// 'user'
const { data: canRead } = await permissions.rbac.hasPermission({
  permission: 'documents.read',
})
// false: no subject, no access
```

### Plain Postgres

Set `permissions.subject_id` at the start of each request, in the transaction that serves the request:

```sql
begin;
select set_config('permissions.subject_id', :'alice', true);
-- true: local to this transaction
select permissions.current_subject_id();
-- the ID of Alice
commit;
select permissions.current_subject_id();
-- null again
```

Do not set the third argument of `set_config` to `false`. The value then stays for the whole session. Behind a pooler in transaction mode, the next client gets the same server connection and acts as the previous user. A transaction-local value disappears at commit or rollback.

In an application, add one statement at the start of the transaction. This example uses node-postgres:

```js
const client = await pool.connect();
try {
  await client.query('begin');
  await client.query('set local role app_user');
  // use the database privileges chosen for this request
  await client.query(
    "select set_config('permissions.subject_id', $1, true)",
    [userId]
  );
  // ... the queries of this request ...
  await client.query('commit');
} catch (e) {
  await client.query('rollback');
  throw e;
} finally {
  client.release();
}
```

The JavaScript client does these steps for you. The call `as({ id })` sets `permissions.subject_id` in a transaction for each call. See [Check as a subject](javascript.md#check-as-a-subject).

Use `set_config` with a bound argument. The statement `SET LOCAL permissions.subject_id = ...` cannot take arguments. `set local role` selects the database privileges for the request; it is independent of the application subject. If you use RLS, run table queries as a role that is subject to the policies: superusers and table owners normally bypass them. Direct permission checks still evaluate the supplied subject. See [Warnings and limits](../models/rbac/overview.md#warnings-and-limits).

### Supabase and PostgREST

PostgREST sets `request.jwt.claims`. A client that sends the JWT of a user is already identified. A backend that connects directly can set the claim itself:

```sql
begin;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', :'alice',
    'role', 'authenticated'
  )::text,
  true
);
select permissions.current_subject_id();
-- the ID of Alice
select set_config('permissions.subject_id', :'bob', true);
select permissions.current_subject_id();
-- still the ID of Alice: the JWT wins
commit;
```

The JWT wins on purpose. Nothing else in the session can change the subject of a request that has a JWT. If the JWT has no `sub` claim (for example the `anon` role), the extension uses `permissions.subject_id`. If that is also empty, there is no subject.

### Subject type

`permissions.current_subject_type()` returns `'user'`, unless the configuration parameter `permissions.subject_type` has another value:

```sql
begin;
select set_config('permissions.subject_type', 'service', true);
select permissions.current_subject_type();                    -- service
commit;
```

Do not change the subject type for RBAC. Only `user` subjects hold roles. A request with another subject type holds no role. The subject type matters for the OpenFGA model. There the current subject is `<current_subject_type()>:<current_subject_id()>`. See [RLS integration](../rls/combine-models.md#current-subject-functions). In the Cedar model the principal is `<current_subject_type()>::"<current_subject_id()>"`, for example `user::"alice"`. Write Cedar policies with the same type. See [the Cedar overview](../models/cedar/overview.md#the-subject-is-the-principal).

### The type of `current_subject_id()`

The function returns `text`. Any `sub` value works. IDs that are not UUIDs, such as `user_2abc`, also work. To compare the ID with a `uuid` column, cast the column: `current_subject_id() = owner_id::text`.
