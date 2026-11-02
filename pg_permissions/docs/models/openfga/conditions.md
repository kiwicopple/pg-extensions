# Conditions and request context

Attach a CEL expression to a relationship when access depends on a value such as an expiry time or an IP address. The model declares the condition; a tuple names it and can store some of its parameters.

Use a separate test database with the extension installed for this walkthrough. Create the [JavaScript server client](overview.md#use-from-javascript) if needed. This page defines a new model, so it becomes the latest model. Continue with the [expiry and network examples](condition-examples.md) after writing it.

The evaluator runs in PL/pgSQL, without an external service. See [CEL support](../../reference/cel.md) for types, expressions, and limits.

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

Save the DSL above as `model.fga`, then convert it before running the examples:

```bash
fga model transform --file model.fga > model.json
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

As OpenFGA does, the extension parses and type-checks expressions when you write a model, so invalid expressions fail before use. CEL has no implicit conversions, so a comparison of a timestamp with a string is not valid:

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

## Write context

The values of the parameters of a condition come from two places:

- The tuple. A tuple stores a `context` object in its `condition`. It can hold some or all of the parameters.
- The request. The `context` argument of `fga_check`, `fga_list_objects` and `fga_list_users` is a JSON object of parameters.

The extension merges both objects. If a parameter appears in both, the stored tuple value wins. Request context cannot override a stored value.

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

## Next step

Continue with [Expiry and conditional shares](condition-examples.md).
