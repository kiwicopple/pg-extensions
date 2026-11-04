# Expiry, networks, and conditional shares

Use conditions to grant access for a limited time or from a particular network.

First write the model in [Conditions and request context](conditions.md). Run the examples here in order, with the same model and JavaScript server client. Tuple writes and calls that supply request context require admin privileges.

## Access that expires

The tuple stores the start of the grant and its duration. The request says the time:

```js tab="JavaScript"
const writes = [
  {
    user: 'user:anne',
    relation: 'viewer',
    object: 'document:roadmap',
    condition: {
      name: 'non_expired_grant',
      context: {
        grant_time: '2026-01-01T00:00:00Z',
        grant_duration: '720h',
      },
    },
  },
]
const grantedAnne = await permissions.fga.admin.write({ writes })
if (grantedAnne.error) throw grantedAnne.error

const january = { current_time: '2026-01-15T00:00:00Z' }
const { data: inJanuary } = await permissions.fga.admin.check({
  user: 'user:anne',
  relation: 'viewer',
  object: 'document:roadmap',
  context: january,
})
// true
const march = { current_time: '2026-03-01T00:00:00Z' }
const { data: inMarch } = await permissions.fga.admin.check({
  user: 'user:anne',
  relation: 'viewer',
  object: 'document:roadmap',
  context: march,
})
// false: 30 days have passed
```

```sql tab="SQL"
select permissions.fga_write(
  writes => '[
    {
      "user": "user:anne",
      "relation": "viewer",
      "object": "document:roadmap",
      "condition": {
        "name": "non_expired_grant",
        "context": {
          "grant_time": "2026-01-01T00:00:00Z",
          "grant_duration": "720h"
        }
      }
    }
  ]'
);

select permissions.fga_check(
  subject => 'user:anne',
  relation => 'viewer',
  object => 'document:roadmap',
  context => '{"current_time": "2026-01-15T00:00:00Z"}'
);
-- true
select permissions.fga_check(
  subject => 'user:anne',
  relation => 'viewer',
  object => 'document:roadmap',
  context => '{"current_time": "2026-03-01T00:00:00Z"}'
);
-- false: 30 days have passed
```

Use `admin.read` to inspect the condition stored with a tuple key. Keys returned by Read can be supplied to Write.

```js tab="JavaScript"
const { data } = await permissions.fga.admin.read({
  object: 'document:roadmap',
})
const condition = data?.tuples[0]?.key.condition
// {
//   name: 'non_expired_grant',
//   context: {
//     grant_time: '2026-01-01T00:00:00Z',
//     grant_duration: '720h',
//   },
// }
```

```sql tab="SQL"
select r.tuples #> '{0,key,condition}'
from permissions.fga_read(object => 'document:roadmap') r;
-- {"name": "non_expired_grant", "context": {"grant_time": "2026-01-01T00:00:00Z", "grant_duration": "720h"}}
```

Without `current_time`, the extension cannot evaluate the condition. Check raises an error:

```js tab="JavaScript"
const missing = await permissions.fga.admin.check({
  user: 'user:anne',
  relation: 'viewer',
  object: 'document:roadmap',
})
// missing.error.message:
//   failed to evaluate relationship condition: ...
// missing.error.details: openfga:2000 validation_error
```

```sql tab="SQL"
select permissions.fga_check(
  subject => 'user:anne',
  relation => 'viewer',
  object => 'document:roadmap'
);
-- ERROR:  failed to evaluate relationship condition: 'non_expired_grant' - context is missing parameters '[current_time]' (tuple context {...})
-- DETAIL:  openfga:2000 validation_error
-- HINT:  Pass every parameter the condition declares, in the request's context argument or in the tuple's condition context, ...
```

When the database is the clock, use `now()` as `current_time`:

```js tab="JavaScript"
const now = { current_time: new Date().toISOString() }
const { data: allowed } = await permissions.fga.admin.check({
  user: 'user:anne',
  relation: 'viewer',
  object: 'document:roadmap',
  context: now,
})
```

```sql tab="SQL"
select permissions.fga_check(
  subject => 'user:anne',
  relation => 'viewer',
  object => 'document:roadmap',
  context => jsonb_build_object('current_time', now())
);
```

## An IP range

The tuple stores the network. The request says where the subject is:

```js tab="JavaScript"
const networkGrants = [
  {
    user: 'user:bob',
    relation: 'viewer',
    object: 'document:roadmap',
    condition: {
      name: 'in_office_network',
      context: { cidr: '10.20.0.0/16' },
    },
  },
]
const grantedBob = await permissions.fga.admin.write({ writes: networkGrants })
if (grantedBob.error) throw grantedBob.error

const inside = { user_ip: '10.20.3.4' }
const { data: atWork } = await permissions.fga.admin.check({
  user: 'user:bob',
  relation: 'viewer',
  object: 'document:roadmap',
  context: inside,
})
// true
const outside = { user_ip: '192.168.1.9' }
const { data: atHome } = await permissions.fga.admin.check({
  user: 'user:bob',
  relation: 'viewer',
  object: 'document:roadmap',
  context: outside,
})
// false
```

```sql tab="SQL"
select permissions.fga_write(
  writes => '[
    {
      "user": "user:bob",
      "relation": "viewer",
      "object": "document:roadmap",
      "condition": {
        "name": "in_office_network",
        "context": {"cidr": "10.20.0.0/16"}
      }
    }
  ]'
);

select permissions.fga_check(
  subject => 'user:bob',
  relation => 'viewer',
  object => 'document:roadmap',
  context => '{"user_ip": "10.20.3.4"}'
);
-- true
select permissions.fga_check(
  subject => 'user:bob',
  relation => 'viewer',
  object => 'document:roadmap',
  context => '{"user_ip": "192.168.1.9"}'
);
-- false
```

## Lists

ListObjects and ListUsers accept the same `context`. One request context serves every condition. Pass all the parameters that the search can meet:

```js tab="JavaScript"
const handbookGrants = [
  {
    user: 'user:carl',
    relation: 'viewer',
    object: 'document:handbook',
  },
]
const grantedCarl = await permissions.fga.admin.write({ writes: handbookGrants })
if (grantedCarl.error) throw grantedCarl.error

const context = {
  current_time: '2026-01-15T00:00:00Z',
  user_ip: '10.20.3.4',
}
const { data: users } = await permissions.fga.admin.listUsers({
  object: 'document:roadmap',
  relation: 'viewer',
  userFilters: ['user'],
  context,
})
// ['user:anne', 'user:bob']
const bobIp = { user_ip: '10.20.3.4' }
const { data: objects } = await permissions.fga.admin.listObjects({
  user: 'user:bob',
  type: 'document',
  relation: 'viewer',
  context: bobIp,
})
// ['document:roadmap']
```

```sql tab="SQL"
select permissions.fga_write(
  writes => '[
    {
      "user": "user:carl",
      "relation": "viewer",
      "object": "document:handbook"
    }
  ]'
);

select permissions.fga_list_users(
  object => 'document:roadmap',
  relation => 'viewer',
  user_filters => '{user}',
  context => '{
    "current_time": "2026-01-15T00:00:00Z",
    "user_ip": "10.20.3.4"
  }'
);
-- user:anne, user:bob
select permissions.fga_list_objects(
  subject => 'user:bob',
  type => 'document',
  relation => 'viewer',
  context => '{"user_ip": "10.20.3.4"}'
);
-- document:roadmap
```

A list fails with error `openfga:2000` when it meets a condition that it cannot evaluate. Without `user_ip`, ListUsers on the roadmap fails at the tuple of Bob. It fails even though the tuple of Anne is correct. ListObjects for Carl needs no context, because his search meets no condition.

## Which context wins

The values in the tuple win over the values in the request. A request cannot extend a grant with its own `grant_duration`:

```js tab="JavaScript"
const override = {
  current_time: '2026-03-01T00:00:00Z',
  grant_duration: '9000h',
}
const { data: stillExpired } = await permissions.fga.admin.check({
  user: 'user:anne',
  relation: 'viewer',
  object: 'document:roadmap',
  context: override,
})
// false
```

```sql tab="SQL"
select permissions.fga_check(
  subject => 'user:anne',
  relation => 'viewer',
  object => 'document:roadmap',
  context => '{
    "current_time": "2026-03-01T00:00:00Z",
    "grant_duration": "9000h"
  }'
);
-- false
```

## Contextual tuples

A contextual tuple can carry a condition. The extension validates it as it validates a written tuple. An invalid condition on a contextual tuple is error `openfga:2027` for Check. For ListObjects and ListUsers it is error `openfga:2000`.

```js tab="JavaScript"
const contextualTuples = [
  {
    user: 'user:dana',
    relation: 'viewer',
    object: 'document:roadmap',
    condition: {
      name: 'in_office_network',
      context: { cidr: '10.20.0.0/16' },
    },
  },
]
const office = { user_ip: '10.20.9.9' }
const { data: temporaryAccess } = await permissions.fga.admin.check({
  user: 'user:dana',
  relation: 'viewer',
  object: 'document:roadmap',
  contextualTuples,
  context: office,
})
// true
```

```sql tab="SQL"
select permissions.fga_check(
  subject => 'user:dana',
  relation => 'viewer',
  object => 'document:roadmap',
  contextual_tuples => '[
    {
      "user": "user:dana",
      "relation": "viewer",
      "object": "document:roadmap",
      "condition": {
        "name": "in_office_network",
        "context": {"cidr": "10.20.0.0/16"}
      }
    }
  ]',
  context => '{"user_ip": "10.20.9.9"}'
);
-- true
```

## Write conditioned tuples

A condition on a tuple must meet these rules:

- The condition exists in the model.
- The type restriction of the relation accepts the condition for that kind of subject.
- The context holds only parameters of the condition.
- The values have the types of the parameters.

If a tuple violates one of these rules, the write fails with error `openfga:2000`:

```js tab="JavaScript"
const invalidGrants = [
  {
    user: 'user:erin',
    relation: 'viewer',
    object: 'document:roadmap',
    condition: {
      name: 'in_office_network',
      context: { cidr: '10.20.0.0/16', region: 'eu' },
    },
  },
]
const invalid = await permissions.fga.admin.write({ writes: invalidGrants })
// invalid.error.message:
//   Invalid tuple 'document:roadmap#viewer@user:erin'. Reason: ...
// invalid.error.details: openfga:2000 validation_error
```

```sql tab="SQL"
select permissions.fga_write(
  writes => '[
    {
      "user": "user:erin",
      "relation": "viewer",
      "object": "document:roadmap",
      "condition": {
        "name": "in_office_network",
        "context": {
          "cidr": "10.20.0.0/16",
          "region": "eu"
        }
      }
    }
  ]'
);
-- ERROR:  Invalid tuple 'document:roadmap#viewer@user:erin'. Reason: found invalid context parameter: region
-- DETAIL:  openfga:2000 validation_error
```

The condition is not a part of the key of a tuple. A subject has at most one `viewer` tuple for each document, with one condition or none. If you write the same key again with another condition, the write fails with error `openfga:2017`. This is true even with `"on_duplicate": "ignore"`. A write cannot name the same key in its writes and in its deletes. That is error `openfga:2004`.

To change the condition, delete the tuple, then write it again. A delete does not need to name the condition. Use one transaction so both changes commit together. In JavaScript, take one connection from the pool and create the admin client on that connection. Enable `throwOnError` so a failed write reaches the rollback.

```js tab="JavaScript"
const connection = await pool.connect()
const tx = createServerClient(connection, { throwOnError: true })
try {
  await connection.query('begin')
  const tuple = {
    user: 'user:bob',
    relation: 'viewer',
    object: 'document:roadmap',
  }
  await tx.fga.admin.write({ deletes: [tuple] })
  await tx.fga.admin.write({
    writes: [{
      ...tuple,
      condition: {
        name: 'in_office_network',
        context: { cidr: '10.0.0.0/8' },
      },
    }],
  })
  await connection.query('commit')
} catch (error) {
  await connection.query('rollback')
  throw error
} finally {
  connection.release()
}
```

```sql tab="SQL"
begin;
select permissions.fga_write(
  deletes => '[
    {
      "user": "user:bob",
      "relation": "viewer",
      "object": "document:roadmap"
    }
  ]'
);
select permissions.fga_write(
  writes => '[
    {
      "user": "user:bob",
      "relation": "viewer",
      "object": "document:roadmap",
      "condition": {
        "name": "in_office_network",
        "context": {"cidr": "10.0.0.0/8"}
      }
    }
  ]'
);
commit;
```


## Next step

Continue with [Condition evaluation and context](condition-behavior.md).
