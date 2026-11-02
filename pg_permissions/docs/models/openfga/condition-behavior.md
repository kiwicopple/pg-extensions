# Condition evaluation and RLS

Condition errors, model changes, and the source of context affect whether a relationship grants access.

The examples use the model and tuples from [the condition examples](condition-examples.md). Complete that page first. Client methods cannot supply trusted request facts such as the current time or network address.

## When the extension cannot evaluate a condition

Evaluation can fail because a parameter is missing, a request value has the wrong type, or an expression raises an error such as division by zero. Each API follows the OpenFGA rule:

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

The functions `fga_check_current`, `fga_list_objects_current` and `fga_list_object_ids_current` take no `context` and no contextual tuples. A client could claim any time or any address. Their behavior is:

- A conditioned tuple counts when its condition is true with the stored context of the tuple alone.
- A tuple whose condition needs a parameter from the request does not count. The function denies it.
- The function denies access if the answer depends on a condition it cannot evaluate. This includes a `but not` that raises an error: the subject does not get access. A policy never fails because of a condition.

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

To use a value that the server can trust, such as the time, write a function of your own. The function calls `fga_check` and passes the value. `fga_check` is for admins only, so make the function `security definer`. See [RLS integration](../../rls/policies.md).

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
