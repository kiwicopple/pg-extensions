# OpenFGA conditions

A tuple can carry an [OpenFGA condition](https://openfga.dev/docs/modeling/conditions). A condition is an expression in [CEL](https://github.com/google/cel-spec). The expression must be true for the tuple to count. Examples are access that expires, access from one network, and access while an attribute holds.

The model defines the condition. Each tuple names the condition. A tuple can also store some of the parameters of the condition. Each Check, ListObjects or ListUsers call passes the other parameters in its `context` argument.

The extension compiles the conditions of a model when you write the model. It evaluates them in PL/pgSQL. It needs no other extension and no external service. The tests in [`test/fga_abac/`](../test/fga_abac/) run the OpenFGA condition tests against it. The only cases that do not run are the cases with inline `$expression` conditions.

This page continues [The OpenFGA model](fga.md). That page covers models, tuples and the API without conditions. The examples on this page run in order.

The JavaScript examples use the server client of [The OpenFGA model](fga.md#use-from-javascript). A `context` is a JavaScript object. The client does not change its keys. Write each key as the model names the parameter, for example `grant_time`.

## A model with conditions

The DSL declares conditions after the types, with typed parameters. A type restriction names a condition with `with`. This model has two conditions:

```text
model
  schema 1.1

type user

type document
  relations
    define viewer: [user, user with non_expired_grant, user with in_office_network]

condition non_expired_grant(
  current_time: timestamp,
  grant_time: timestamp,
  grant_duration: duration
) {
  current_time < grant_time + grant_duration
}

condition in_office_network(user_ip: ipaddress, cidr: string) {
  user_ip.in_cidr(cidr)
}
```

The command `fga model transform` turns the conditions into the `conditions` key of the model. It turns each `with` into a `condition` on the type restriction. This fragment shows the restrictions of `viewer`:

```json
{"type": "document",
 "relations": {"viewer": {"this": {}}},
 "metadata": {"relations": {"viewer": {"directly_related_user_types": [
   {"type": "user"},
   {"type": "user", "condition": "non_expired_grant"},
   {"type": "user", "condition": "in_office_network"}]}}}}
```

This fragment shows the `conditions` key:

```json
"conditions": {
  "non_expired_grant": {
    "name": "non_expired_grant",
    "expression": "current_time < grant_time + grant_duration",
    "parameters": {
      "current_time": {"type_name": "TYPE_NAME_TIMESTAMP"},
      "grant_time": {"type_name": "TYPE_NAME_TIMESTAMP"},
      "grant_duration": {"type_name": "TYPE_NAME_DURATION"}
    }
  },
  "in_office_network": {
    "name": "in_office_network",
    "expression": "user_ip.in_cidr(cidr)",
    "parameters": {
      "user_ip": {"type_name": "TYPE_NAME_IPADDRESS"},
      "cidr": {"type_name": "TYPE_NAME_STRING"}
    }
  }
}
```

The extension parses and type-checks each expression when you write the model, as OpenFGA does. You find a mistake at that time. CEL has no implicit conversions, so a comparison of a timestamp with a string is not valid:

```sql tab="SQL"
\set model `cat model.json`
select permissions.fga_write_authorization_model(
  model => jsonb_set(
    :'model'::jsonb,
    '{conditions,non_expired_grant,expression}',
    '"current_time < \"2030-01-01\""'
  )
);
-- ERROR:  failed to compile expression on condition 'non_expired_grant' - found no matching overload for '_<_' applied to '(timestamp, string)' (column 14)
-- DETAIL:  openfga:2056 invalid_authorization_model
-- HINT:  CEL has no implicit conversions: both operands of an operator need the same type ...
```

```ts tab="JavaScript"
import { readFileSync } from 'node:fs'

const json = readFileSync('model.json', 'utf8')
const model = JSON.parse(json)

const broken = structuredClone(model)
broken.conditions.non_expired_grant.expression =
  'current_time < "2030-01-01"'
const refused =
  await permissions.fga.admin.writeAuthorizationModel(broken)
// refused.error.message:
//   failed to compile expression on condition 'non_expired_grant' ...
// refused.error.details:
//   openfga:2056 invalid_authorization_model
```

Write the model:

```sql tab="SQL"
select permissions.fga_write_authorization_model(model => :'model');
```

```ts tab="JavaScript"
await permissions.fga.admin.writeAuthorizationModel(model)
```

## CEL subset

A parameter has one of these types: `bool`, `string`, `int`, `uint`, `double`, `duration`, `timestamp`, `ipaddress`, `any`, `list<T>` and `map<T>`. A `bytes` parameter is not valid.

An expression must give a `bool`. An expression can use these parts of CEL:

| Part | Supported |
| --- | --- |
| Literals | `int`, `uint`, `double`, `string`, `bool` and `null`, hexadecimal and exponent forms, raw strings, triple-quoted strings, list literals and map literals |
| Operators | `&&`, `\|\|`, `!`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `+`, `-`, `*`, `/`, `%`, `? :`, `in` and `[ ]` |
| Access | `map.key`, `has(map.key)` and `list[0]` |
| String functions | `size`, `contains`, `startsWith`, `endsWith` and `matches` |
| Conversions | `int`, `uint`, `double`, `string`, `bool`, `timestamp` and `duration` |
| Time | Timestamp and duration arithmetic, comparisons, and the getters, for example `getHours` and `getDayOfWeek`. A timestamp getter takes an optional time zone. |
| Macros | `all`, `exists`, `exists_one`, `map` and `filter` |
| Network | `ipaddress(string)` and `in_cidr(string)` |

The extension refuses these parts of CEL when you write the model, with error `openfga:2056`: `bytes`, `type()`, `dyn()`, protobuf messages and the optional syntax. The extension also refuses inline conditions (`$expression`), with error `openfga:2000`, as the default OpenFGA server does.

Some details are different from OpenFGA:

- `matches` uses Postgres regular expressions.
- A timestamp has microsecond precision.
- An integer overflow or a division by zero is an error. A `double` overflow or a division by zero is also an error. CEL gives infinity there.
- In a value of type `any`, and in a list or map literal of mixed types, a number is a `double`.
- An IPv6 address with a zone, such as `fe80::1%eth0`, is not valid.

These limits apply:

| Limit | Value |
| --- | --- |
| Length of an expression | 512 bytes |
| Parameters of one condition | 25 |
| Name of a condition or a parameter | 1 to 50 characters, without `:`, `#`, `@` or white space |
| Cost of one evaluation | 100 steps. The extension counts parameters, calls and loop steps. A more costly evaluation fails with error `openfga:2000`. |

## Write context

The values of the parameters of a condition come from two places:

- The tuple. A tuple stores a `context` object in its `condition`. It can hold some or all of the parameters.
- The request. The `context` argument of `fga_check`, `fga_list_objects` and `fga_list_users` is a JSON object of parameters.

The extension merges the two objects. When both have a value for one parameter, the value of the tuple wins. A request cannot change a value that a tuple stores.

After the merge, each parameter that the condition declares must have a value. If a value is absent, the call raises an error. It does not guess.

Write each value as a JSON value of the type of the parameter:

| Parameter type | JSON value |
| --- | --- |
| `bool`, `string` | `true`, `"text"` |
| `int`, `uint`, `double` | A number |
| `timestamp` | A string in RFC 3339 format: `"2026-01-15T00:00:00Z"` or `"2026-01-15T02:00:00+02:00"` |
| `duration` | A string in the Go format: `"720h"`, `"1h30m"` or `"300ms"`. There is no unit `d`. |
| `ipaddress` | A string: `"10.20.3.4"` |
| `list<T>` | A JSON array |
| `map<T>` | A JSON object |
| `any` | Any JSON value |

## Access that expires

The tuple stores the start of the grant and its duration. The request says the time:

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

```ts tab="JavaScript"
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
await permissions.fga.admin.write({ writes })

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

`fga_read` returns the condition with the tuple key. You can write a page of Read back with `fga_write`:

```sql tab="SQL"
select r.tuples #> '{0,key,condition}'
from permissions.fga_read(object => 'document:roadmap') r;
-- {"name": "non_expired_grant", "context": {"grant_time": "2026-01-01T00:00:00Z", "grant_duration": "720h"}}
```

```ts tab="JavaScript"
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

Without `current_time`, the extension cannot evaluate the condition. Check raises an error:

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

```ts tab="JavaScript"
const missing = await permissions.fga.admin.check({
  user: 'user:anne',
  relation: 'viewer',
  object: 'document:roadmap',
})
// missing.error.message:
//   failed to evaluate relationship condition: ...
// missing.error.details: openfga:2000 validation_error
```

When the database is the clock, use `now()` as `current_time`:

```sql tab="SQL"
select permissions.fga_check(
  subject => 'user:anne',
  relation => 'viewer',
  object => 'document:roadmap',
  context => jsonb_build_object('current_time', now())
);
```

```ts tab="JavaScript"
const now = { current_time: new Date().toISOString() }
const { data: allowed } = await permissions.fga.admin.check({
  user: 'user:anne',
  relation: 'viewer',
  object: 'document:roadmap',
  context: now,
})
```

## An IP range

The tuple stores the network. The request says where the subject is:

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

```ts tab="JavaScript"
const writes = [
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
await permissions.fga.admin.write({ writes })

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

## Lists

ListObjects and ListUsers accept the same `context`. One request context serves every condition. Pass all the parameters that the search can meet:

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

```ts tab="JavaScript"
const writes = [
  {
    user: 'user:carl',
    relation: 'viewer',
    object: 'document:handbook',
  },
]
await permissions.fga.admin.write({ writes })

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

A list fails with error `openfga:2000` when it meets a condition that it cannot evaluate. Without `user_ip`, ListUsers on the roadmap fails at the tuple of Bob. It fails even though the tuple of Anne is correct. ListObjects for Carl needs no context, because his search meets no condition.

## Which context wins

The values in the tuple win over the values in the request. A request cannot extend a grant with its own `grant_duration`:

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

```ts tab="JavaScript"
const context = {
  current_time: '2026-03-01T00:00:00Z',
  grant_duration: '9000h',
}
const { data: allowed } = await permissions.fga.admin.check({
  user: 'user:anne',
  relation: 'viewer',
  object: 'document:roadmap',
  context,
})
// false
```

## Contextual tuples

A contextual tuple can carry a condition. The extension validates it as it validates a written tuple. An invalid condition on a contextual tuple is error `openfga:2027` for Check. For ListObjects and ListUsers it is error `openfga:2000`.

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

```ts tab="JavaScript"
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
const context = { user_ip: '10.20.9.9' }
const { data: allowed } = await permissions.fga.admin.check({
  user: 'user:dana',
  relation: 'viewer',
  object: 'document:roadmap',
  contextualTuples,
  context,
})
// true
```

## Write conditioned tuples

A condition on a tuple must meet these rules:

- The condition exists in the model.
- The type restriction of the relation accepts the condition for that kind of subject.
- The context holds only parameters of the condition.
- The values have the types of the parameters.

When a rule fails, the write fails with error `openfga:2000`:

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

```ts tab="JavaScript"
const writes = [
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
const invalid = await permissions.fga.admin.write({ writes })
// invalid.error.message:
//   Invalid tuple 'document:roadmap#viewer@user:erin'. Reason: ...
// invalid.error.details: openfga:2000 validation_error
```

The condition is not a part of the key of a tuple. A subject has at most one `viewer` tuple for each document, with one condition or none. If you write the same key again with another condition, the write fails with error `openfga:2017`. This is true even with `"on_duplicate": "ignore"`. A write cannot name the same key in its writes and in its deletes. That is error `openfga:2004`.

To change the condition, delete the tuple, then write it again. A delete does not need to name the condition. Do both in one transaction, so that they commit together:

```sql
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

## When the extension cannot evaluate a condition

There are three cases. A parameter has no value. Or a request value has the wrong type. Or the expression raises an error, for example a division by zero. Each API follows the OpenFGA rule:

- **Check** is `true` when a path of true edges reaches the subject. If no such path exists, and the search met a conditioned tuple that it could not evaluate, Check fails with error `openfga:2000`. A branch that decides wins over an error. A true branch of a union decides. A false branch of an intersection decides.
- **ListObjects** and **ListUsers** fail with error `openfga:2000` when an edge that their search takes gives an error.

The search of Check goes top down. It reads the tuples of the subject. From the object down, it also reads every userset tuple and every parent tuple. For this reason the tuple that fails can be a tuple that the subject is not behind. An example is a conditioned team that the subject is not in.

## Stale context

A tuple can become stale when you write a new model. The tuple is stale in these cases:

- Its condition is not in the new model.
- The new restriction does not accept its condition.
- Its context has a key that is not a parameter now.
- A value of its context does not convert to the type of the parameter now.

Every API ignores a stale tuple. This is true for Check, ListObjects, ListUsers and the functions for RLS. The OpenFGA lists fail with an error in the last two cases. This extension keeps the lists consistent with Check. `fga_read` still returns a stale tuple, and you can delete it.

## Conditions in RLS helpers

The functions `fga_check_current`, `fga_list_objects_current` and `fga_list_object_ids_current` take no `context` and no contextual tuples. A client could claim any time or any address. These functions follow three rules:

- A conditioned tuple counts when its condition is true with the stored context of the tuple alone.
- A tuple whose condition needs a parameter from the request does not count. The function denies it.
- The function denies an answer that depends on a condition that it cannot evaluate. This includes a `but not` that raises an error: the subject does not get access. A policy never fails because of a condition.

In the first example, the tuple of Bob needs `user_ip` from the request. The function denies it. The tuple of Fay stores both parameters, so the function grants it:

```sql tab="SQL"
select set_config('permissions.subject_id', 'bob', false);
select permissions.fga_check_current(
  relation => 'viewer',
  object => 'document:roadmap'
);
-- false: the condition needs user_ip

select permissions.fga_write(
  writes => '[
    {
      "user": "user:fay",
      "relation": "viewer",
      "object": "document:lab",
      "condition": {
        "name": "in_office_network",
        "context": {
          "cidr": "10.0.0.0/8",
          "user_ip": "10.1.2.3"
        }
      }
    }
  ]'
);
select set_config('permissions.subject_id', 'fay', false);
select permissions.fga_check_current(
  relation => 'viewer',
  object => 'document:lab'
);
-- true: the tuple holds every parameter
select set_config('permissions.subject_id', '', false);
```

```ts tab="JavaScript"
const asBob = permissions.as({ id: 'bob' })
const { data: bobCan } = await asBob.fga.check({
  relation: 'viewer',
  object: 'document:roadmap',
})
// false: the condition needs user_ip

const writes = [
  {
    user: 'user:fay',
    relation: 'viewer',
    object: 'document:lab',
    condition: {
      name: 'in_office_network',
      context: { cidr: '10.0.0.0/8', user_ip: '10.1.2.3' },
    },
  },
]
await permissions.fga.admin.write({ writes })

const asFay = permissions.as({ id: 'fay' })
const { data: fayCan } = await asFay.fga.check({
  relation: 'viewer',
  object: 'document:lab',
})
// true: the tuple holds every parameter
```

To use a value that the server can trust, such as the time, write a function of your own. The function calls `fga_check` and passes the value. `fga_check` is for admins only, so make the function `security definer`. See [RLS with both models](rls.md).

## More expressions

This example uses a list parameter and a time zone. The model has two conditions. The condition `in_region` takes a list. The condition `office_hours` reads the hour in Paris:

```sql tab="SQL"
select permissions.fga_write_authorization_model(
  model => '{
    "schema_version": "1.1",
    "type_definitions": [
      {"type": "user"},
      {
        "type": "folder",
        "relations": {"viewer": {"this": {}}},
        "metadata": {
          "relations": {
            "viewer": {
              "directly_related_user_types": [
                {"type": "user", "condition": "in_region"},
                {"type": "user", "condition": "office_hours"}
              ]
            }
          }
        }
      }
    ],
    "conditions": {
      "in_region": {
        "name": "in_region",
        "expression": "region in allowed",
        "parameters": {
          "region": {"type_name": "TYPE_NAME_STRING"},
          "allowed": {
            "type_name": "TYPE_NAME_LIST",
            "generic_types": [{"type_name": "TYPE_NAME_STRING"}]
          }
        }
      },
      "office_hours": {
        "name": "office_hours",
        "expression": "current_time.getHours(\"Europe/Paris\") >= 9 && current_time.getHours(\"Europe/Paris\") < 17",
        "parameters": {
          "current_time": {"type_name": "TYPE_NAME_TIMESTAMP"}
        }
      }
    }
  }'
);

select permissions.fga_write(
  writes => '[
    {
      "user": "user:gus",
      "relation": "viewer",
      "object": "folder:eu",
      "condition": {
        "name": "in_region",
        "context": {"allowed": ["eu", "uk"]}
      }
    },
    {
      "user": "user:hana",
      "relation": "viewer",
      "object": "folder:eu",
      "condition": {"name": "office_hours"}
    }
  ]'
);

select permissions.fga_check(
  subject => 'user:gus',
  relation => 'viewer',
  object => 'folder:eu',
  context => '{"region": "eu"}'
);
-- true
select permissions.fga_check(
  subject => 'user:gus',
  relation => 'viewer',
  object => 'folder:eu',
  context => '{"region": "us"}'
);
-- false
select permissions.fga_check(
  subject => 'user:hana',
  relation => 'viewer',
  object => 'folder:eu',
  context => '{"current_time": "2026-01-15T10:00:00Z"}'
);
-- true: 11:00 in Paris
select permissions.fga_check(
  subject => 'user:hana',
  relation => 'viewer',
  object => 'folder:eu',
  context => '{"current_time": "2026-01-15T20:00:00Z"}'
);
-- false: 21:00 in Paris
```

```ts tab="JavaScript"
const model = {
  schema_version: '1.1',
  type_definitions: [
    { type: 'user' },
    {
      type: 'folder',
      relations: { viewer: { this: {} } },
      metadata: {
        relations: {
          viewer: {
            directly_related_user_types: [
              { type: 'user', condition: 'in_region' },
              { type: 'user', condition: 'office_hours' },
            ],
          },
        },
      },
    },
  ],
  conditions: {
    in_region: {
      name: 'in_region',
      expression: 'region in allowed',
      parameters: {
        region: { type_name: 'TYPE_NAME_STRING' },
        allowed: {
          type_name: 'TYPE_NAME_LIST',
          generic_types: [{ type_name: 'TYPE_NAME_STRING' }],
        },
      },
    },
    office_hours: {
      name: 'office_hours',
      expression:
        'current_time.getHours("Europe/Paris") >= 9 && ' +
        'current_time.getHours("Europe/Paris") < 17',
      parameters: {
        current_time: { type_name: 'TYPE_NAME_TIMESTAMP' },
      },
    },
  },
}
await permissions.fga.admin.writeAuthorizationModel(model)

const writes = [
  {
    user: 'user:gus',
    relation: 'viewer',
    object: 'folder:eu',
    condition: {
      name: 'in_region',
      context: { allowed: ['eu', 'uk'] },
    },
  },
  {
    user: 'user:hana',
    relation: 'viewer',
    object: 'folder:eu',
    condition: { name: 'office_hours' },
  },
]
await permissions.fga.admin.write({ writes })

const inEu = { region: 'eu' }
const { data: gusEu } = await permissions.fga.admin.check({
  user: 'user:gus',
  relation: 'viewer',
  object: 'folder:eu',
  context: inEu,
})
// true
const inUs = { region: 'us' }
const { data: gusUs } = await permissions.fga.admin.check({
  user: 'user:gus',
  relation: 'viewer',
  object: 'folder:eu',
  context: inUs,
})
// false
const morning = { current_time: '2026-01-15T10:00:00Z' }
const { data: hanaMorning } = await permissions.fga.admin.check({
  user: 'user:hana',
  relation: 'viewer',
  object: 'folder:eu',
  context: morning,
})
// true: 11:00 in Paris
const evening = { current_time: '2026-01-15T20:00:00Z' }
const { data: hanaEvening } = await permissions.fga.admin.check({
  user: 'user:hana',
  relation: 'viewer',
  object: 'folder:eu',
  context: evening,
})
// false: 21:00 in Paris
```
