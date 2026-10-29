# OpenFGA conditions

A tuple can carry an [OpenFGA condition](https://openfga.dev/docs/modeling/conditions): an expression in [CEL](https://github.com/google/cel-spec) that must be true for the tuple to count. Access that expires, access from one network, access while an attribute holds. The condition is part of the model; each tuple names it and may store some of its parameters; each Check, ListObjects or ListUsers passes the rest as its `context`.

The extension compiles a model's conditions when the model is written and evaluates them in PL/pgSQL (no other extension, no external service). OpenFGA's own condition tests run against it ([`test/fga_abac/`](../test/fga_abac/), every case except the 9 that need inline `$expression` conditions, which are out of scope); the design, the CEL subset and every difference from OpenFGA are in [`designs/d-conditions.md`](../designs/d-conditions.md).

Every example on this page runs as written in [`test/spec/d/90_usage_conditions.sql`](../test/spec/d/90_usage_conditions.sql), in order. It continues [The OpenFGA model](fga.md), which covers models, tuples and the API without conditions.

## A model with conditions

Conditions are declared after the types, with typed parameters, and named in a type restriction with `with`:

```
model
  schema 1.1

type user

type document
  relations
    define viewer: [user, user with non_expired_grant, user with in_office_network]

condition non_expired_grant(current_time: timestamp, grant_time: timestamp, grant_duration: duration) {
  current_time < grant_time + grant_duration
}

condition in_office_network(user_ip: ipaddress, cidr: string) {
  user_ip.in_cidr(cidr)
}
```

`fga model transform` turns them into the model's `conditions`, and each `with` into a `condition` on the restriction:

```json
{"type": "document",
 "relations": {"viewer": {"this": {}}},
 "metadata": {"relations": {"viewer": {"directly_related_user_types": [
   {"type": "user"},
   {"type": "user", "condition": "non_expired_grant"},
   {"type": "user", "condition": "in_office_network"}]}}}}
```

```json
"conditions": {
  "non_expired_grant": {"name": "non_expired_grant",
    "expression": "current_time < grant_time + grant_duration",
    "parameters": {"current_time": {"type_name": "TYPE_NAME_TIMESTAMP"},
                   "grant_time": {"type_name": "TYPE_NAME_TIMESTAMP"},
                   "grant_duration": {"type_name": "TYPE_NAME_DURATION"}}},
  "in_office_network": {"name": "in_office_network",
    "expression": "user_ip.in_cidr(cidr)",
    "parameters": {"user_ip": {"type_name": "TYPE_NAME_IPADDRESS"},
                   "cidr": {"type_name": "TYPE_NAME_STRING"}}}}
```

```sql
select permissions.fga_write_authorization_model(:'model');
```

The expression is parsed and type-checked here, as OpenFGA does, so mistakes surface when the model is written. CEL has no implicit conversions, so comparing a timestamp with a string is refused:

```sql
-- the same model with: current_time < "2030-01-01"
-- ERROR:  failed to compile expression on condition 'non_expired_grant' - found no matching overload for '_<_' applied to '(timestamp, string)' (column 14)
-- DETAIL:  openfga:2056 invalid_authorization_model
-- HINT:  CEL has no implicit conversions: both operands of an operator need the same type ...
```

Parameter types are OpenFGA's: `bool`, `string`, `int`, `uint`, `double`, `duration`, `timestamp`, `ipaddress`, `any`, `list<T>` and `map<T>`. The expression may use CEL's operators, `size`, `contains`, `startsWith`, `endsWith`, `matches`, the conversions, timestamp and duration arithmetic and getters, `has()`, the macros `all`, `exists`, `exists_one`, `map` and `filter`, and OpenFGA's `ipaddress()` and `in_cidr()`. Left out, refused when the model is written: bytes, `type()`, `dyn()` ([`designs/d-conditions.md`](../designs/d-conditions.md) section 4).

## Expiring access

The tuple stores when the grant started and how long it lasts; the request says what time it is:

```sql
select permissions.fga_write('[{"user": "user:anne", "relation": "viewer", "object": "document:roadmap",
  "condition": {"name": "non_expired_grant",
                "context": {"grant_time": "2026-01-01T00:00:00Z", "grant_duration": "720h"}}}]');

select permissions.fga_check('user:anne', 'viewer', 'document:roadmap',
                             context => '{"current_time": "2026-01-15T00:00:00Z"}');   -- true
select permissions.fga_check('user:anne', 'viewer', 'document:roadmap',
                             context => '{"current_time": "2026-03-01T00:00:00Z"}');   -- false: 30 days have passed
```

Read returns the condition with the tuple key, so a page of Read can be written back:

```sql
select r.tuples #> '{0,key,condition}' from permissions.fga_read('document:roadmap') r;
-- {"name": "non_expired_grant", "context": {"grant_time": "2026-01-01T00:00:00Z", "grant_duration": "720h"}}
```

A timestamp is RFC 3339 (`2026-01-15T00:00:00Z`, `2026-01-15T02:00:00+02:00`), a duration Go's format (`720h`, `1h30m`, `300ms`; there is no `d`). A parameter the condition declares must have a value, in the tuple or in the request. Without `current_time` the condition can't be evaluated, and Check fails rather than guess:

```sql
select permissions.fga_check('user:anne', 'viewer', 'document:roadmap');
-- ERROR:  failed to evaluate relationship condition: 'non_expired_grant' - context is missing parameters '[current_time]' ...
-- DETAIL:  openfga:2000 validation_error
-- HINT:  Pass every parameter the condition declares, in the request's context argument or in the tuple's condition context, ...
```

`now()` is the usual `current_time` when the database is the clock: `context => jsonb_build_object('current_time', now())`.

## An IP range

The tuple stores the network; the request says where the user is:

```sql
select permissions.fga_write('[{"user": "user:bob", "relation": "viewer", "object": "document:roadmap",
  "condition": {"name": "in_office_network", "context": {"cidr": "10.20.0.0/16"}}}]');

select permissions.fga_check('user:bob', 'viewer', 'document:roadmap', context => '{"user_ip": "10.20.3.4"}');     -- true
select permissions.fga_check('user:bob', 'viewer', 'document:roadmap', context => '{"user_ip": "192.168.1.9"}');   -- false
```

## Lists

ListObjects and ListUsers take the same `context`. One request context serves every condition, so pass all the parameters the walk may meet:

```sql
select permissions.fga_write('[{"user": "user:carl", "relation": "viewer", "object": "document:handbook"}]');

select permissions.fga_list_users('document:roadmap', 'viewer', '{user}',
    context => '{"current_time": "2026-01-15T00:00:00Z", "user_ip": "10.20.3.4"}');   -- user:anne, user:bob
select permissions.fga_list_objects('user:bob', 'document', 'viewer',
    context => '{"user_ip": "10.20.3.4"}');                                           -- document:roadmap
```

A list fails with 2000 if a condition on its way can't be evaluated, as OpenFGA's do: without `user_ip`, ListUsers on the roadmap fails at Bob's tuple, even though Anne's would be fine. ListObjects for Carl needs no context: his walk meets no condition.

## Which context wins

When the tuple's context and the request's both have a parameter, the tuple's wins, as in OpenFGA. A request can't extend a grant by sending its own `grant_duration`:

```sql
select permissions.fga_check('user:anne', 'viewer', 'document:roadmap',
    context => '{"current_time": "2026-03-01T00:00:00Z", "grant_duration": "9000h"}');   -- false
```

## Contextual tuples

A contextual tuple can carry a condition too, validated like a written one (for Check an invalid one is 2027, for the lists 2000):

```sql
select permissions.fga_check('user:dana', 'viewer', 'document:roadmap',
    contextual_tuples => '[{"user": "user:dana", "relation": "viewer", "object": "document:roadmap",
                            "condition": {"name": "in_office_network", "context": {"cidr": "10.20.0.0/16"}}}]',
    context => '{"user_ip": "10.20.9.9"}');   -- true
```

## Writing conditioned tuples

A tuple's condition must exist in the model and be one its relation allows for that kind of user, and its context may only hold the condition's parameters, with values of their types; otherwise the write fails with 2000:

```sql
select permissions.fga_write('[{"user": "user:erin", "relation": "viewer", "object": "document:roadmap",
  "condition": {"name": "in_office_network", "context": {"cidr": "10.20.0.0/16", "region": "eu"}}}]');
-- ERROR:  Invalid tuple 'document:roadmap#viewer@user:erin'. Reason: found invalid context parameter: region
-- DETAIL:  openfga:2000 validation_error
```

The condition is not part of the tuple's key: a user has at most one `viewer` tuple per document, with one condition or none. Writing the key again with another condition fails with 2017, even with `"on_duplicate": "ignore"` (OpenFGA answers HTTP 409 there), and a Write can't name the same key in both its writes and its deletes (2004). To change the condition, delete the tuple (a delete doesn't need to name the condition), then write it again; in one transaction the two commit together:

```sql
begin;
select permissions.fga_write(deletes => '[{"user": "user:bob", "relation": "viewer", "object": "document:roadmap"}]');
select permissions.fga_write('[{"user": "user:bob", "relation": "viewer", "object": "document:roadmap",
  "condition": {"name": "in_office_network", "context": {"cidr": "10.0.0.0/8"}}}]');
commit;
```

## When a condition can't be evaluated

OpenFGA's rule, which the extension follows per API:

- **Check** is true if a path of true edges reaches the user. If none does, and the search met a conditioned tuple whose condition can't be evaluated (a missing parameter, a value of the wrong type, a division by zero), Check fails with 2000. The search reads the user's own tuples and, from the object down, every userset and parent tuple, so the tuple that fails may be one the user is not behind (a conditioned group the user isn't in). A branch that decides wins over an error: a true branch of a union, a false branch of an intersection.
- **ListObjects** and **ListUsers** fail with 2000 if an edge their walk takes errors.
- A tuple written under an older model whose condition no longer fits (a parameter renamed, a type changed) is ignored, in every API (OpenFGA's ListObjects fails instead; [`designs/d-conditions.md`](../designs/d-conditions.md) section 3).

## In RLS policies

The current-subject functions take no `context`, so a condition that needs a request parameter can't be true in a policy: the tuple is denied, never an error. [RLS with both models](rls.md#conditions-in-policies) shows what does work, and how to pass trusted values such as the time.
