# Extension types

Use the Cedar extension types to compare IP addresses, decimal numbers, dates and durations. Cedar has four: `ipaddr`, `decimal`, `datetime` and `duration`. The extension supports all four, with every method of Cedar 4.14.

First complete [Check access](checks.md). The examples use the same policies and entities. An admin role runs these calls.

## The types

You make a value with a constructor, which takes one string. Then you compare it or call a method on it.

| Type | Constructor | Methods and operators |
| --- | --- | --- |
| `ipaddr` | `ip("10.0.0.0/8")` | `isIpv4()`, `isIpv6()`, `isLoopback()`, `isMulticast()`, `isInRange(range)`. Equality with `==`. |
| `decimal` | `decimal("12.34")` | `lessThan`, `lessThanOrEqual`, `greaterThan`, `greaterThanOrEqual`. Equality with `==`. |
| `datetime` | `datetime("2026-12-01T09:30:00Z")` | `offset(duration)`, `durationSince(datetime)`, `toDate()`, `toTime()`. The operators `<`, `<=`, `>`, `>=`. Equality. |
| `duration` | `duration("1d12h")` | `toMilliseconds()`, `toSeconds()`, `toMinutes()`, `toHours()`, `toDays()`. The operators `<`, `<=`, `>`, `>=`. Equality. |

A decimal has up to four digits after the point. A datetime and a duration are whole milliseconds. The operators `<` and the others do not work on decimals. Use the methods for decimals.

## Values in data

An entity attribute, a tag or the context holds an extension value in this JSON form:

```json
{"__extn": {"fn": "ip", "arg": "10.0.0.1"}}
```

`fn` is the name of the constructor as a policy writes it: `ip`, not `ipaddr`. `arg` is the string. The extension reads the value when you put it, or when the request starts. A string that the constructor does not accept is the error `cedar:invalid_entity` or `cedar:invalid_context`. The message is the one of the constructor, with a hint that shows the form.

## Compare IP addresses

This policy lets a user download from the office network, `10.0.0.0/8`. The client address comes in the request context:

```sql tab="SQL"
select permissions.cedar_put_policy(
  policy_id => 'ip-office',
  policy => 'permit (
  principal,
  action == Action::"download",
  resource
)
when { context.ip.isInRange(ip("10.0.0.0/8")) };'
);
select permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"download"',
  resource => 'Document::"q3"',
  context => '{
    "ip": {"__extn": {"fn": "ip", "arg": "10.1.2.3"}}
  }'
);
-- {"errors": [], "reasons": ["ip-office"], "decision": "allow"}
select permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"download"',
  resource => 'Document::"q3"',
  context => '{
    "ip": {"__extn": {"fn": "ip", "arg": "192.168.1.1"}}
  }'
);
-- {"errors": [], "reasons": [], "decision": "deny"}
```

```ts tab="JavaScript"
const office = `permit (
  principal,
  action == Action::"download",
  resource
)
when { context.ip.isInRange(ip("10.0.0.0/8")) };`
await permissions.cedar.admin.putPolicy({
  policyId: 'ip-office',
  policy: office,
})
const request = {
  principal: { type: 'user', id: 'alice' },
  action: 'Action::"download"',
  resource: 'Document::"q3"',
}
const { data: inside } = await permissions.cedar.admin.isAuthorized({
  ...request,
  context: {
    ip: { __extn: { fn: 'ip', arg: '10.1.2.3' } },
  },
})
// allow, reason: ['ip-office']
const { data: outside } = await permissions.cedar.admin.isAuthorized({
  ...request,
  context: {
    ip: { __extn: { fn: 'ip', arg: '192.168.1.1' } },
  },
})
// deny, reason: []
```

## Compare decimals

Use a decimal for a score or a price. Compare it with a method:

```sql tab="SQL"
select permissions.cedar_put_policy(
  policy_id => 'score',
  policy => 'permit (
  principal,
  action == Action::"rate",
  resource
)
when { context.score.greaterThanOrEqual(decimal("2.50")) };'
);
select permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"rate"',
  resource => 'Document::"q3"',
  context => '{
    "score": {"__extn": {"fn": "decimal", "arg": "3.2"}}
  }'
);
-- {"errors": [], "reasons": ["score"], "decision": "allow"}
```

```ts tab="JavaScript"
const score = `permit (
  principal,
  action == Action::"rate",
  resource
)
when { context.score.greaterThanOrEqual(decimal("2.50")) };`
await permissions.cedar.admin.putPolicy({
  policyId: 'score',
  policy: score,
})
const { data } = await permissions.cedar.admin.isAuthorized({
  principal: { type: 'user', id: 'alice' },
  action: 'Action::"rate"',
  resource: 'Document::"q3"',
  context: {
    score: { __extn: { fn: 'decimal', arg: '3.2' } },
  },
})
// allow, reason: ['score']
```

## Compare dates and durations

A datetime has a value in time. A duration is a length of time. Store a datetime as an attribute of an entity, and send the current time in the context. This policy lets a user open a document during the first 7 days after it is published:

```sql tab="SQL"
select permissions.cedar_put_entities(
  entities => '[
    {
      "uid": {"type": "Document", "id": "launch"},
      "attrs": {
        "level": "internal",
        "publish_at": {
          "__extn": {"fn": "datetime", "arg": "2026-12-01"}
        }
      }
    }
  ]'
);
select permissions.cedar_put_policy(
  policy_id => 'first-week',
  policy => 'permit (
  principal,
  action == Action::"open",
  resource
)
when {
  context.now >= resource.publish_at &&
  context.now.durationSince(resource.publish_at) < duration("7d")
};'
);
select permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"open"',
  resource => 'Document::"launch"',
  context => '{
    "now": {
      "__extn": {"fn": "datetime", "arg": "2026-12-03T10:00:00Z"}
    }
  }'
);
-- {"errors": [], "reasons": ["first-week"], "decision": "allow"}
select permissions.cedar_is_authorized(
  principal => 'user::"alice"',
  action => 'Action::"open"',
  resource => 'Document::"launch"',
  context => '{
    "now": {
      "__extn": {"fn": "datetime", "arg": "2026-12-09T00:00:00Z"}
    }
  }'
);
-- {"errors": [], "reasons": [], "decision": "deny"}
```

```ts tab="JavaScript"
await permissions.cedar.admin.putEntities([
  {
    uid: { type: 'Document', id: 'launch' },
    attrs: {
      level: 'internal',
      publish_at: {
        __extn: { fn: 'datetime', arg: '2026-12-01' },
      },
    },
  },
])
const firstWeek = `permit (
  principal,
  action == Action::"open",
  resource
)
when {
  context.now >= resource.publish_at &&
  context.now.durationSince(resource.publish_at) < duration("7d")
};`
await permissions.cedar.admin.putPolicy({
  policyId: 'first-week',
  policy: firstWeek,
})
const request = {
  principal: { type: 'user', id: 'alice' },
  action: 'Action::"open"',
  resource: 'Document::"launch"',
}
const { data: early } = await permissions.cedar.admin.isAuthorized({
  ...request,
  context: {
    now: { __extn: { fn: 'datetime', arg: '2026-12-03T10:00:00Z' } },
  },
})
// allow, reason: ['first-week']
const { data: late } = await permissions.cedar.admin.isAuthorized({
  ...request,
  context: {
    now: { __extn: { fn: 'datetime', arg: '2026-12-09T00:00:00Z' } },
  },
})
// deny, reason: []
```

[`cedar_read_entities`](entities.md#read-entities) writes a datetime in its canonical text, `2026-12-01T00:00:00.000Z`.

A client for the current subject cannot send a context. A policy that reads `context.now` does not allow a check from `cedar_is_authorized_current`. To test the time in an RLS policy, use a `resource_attrs` value or a condition on a stored entity. See [Cedar in RLS](../../rls/policies.md#policies-for-cedar).

## What can surprise you

These points follow Cedar 4.14. Some differ from the helpers that the OpenFGA conditions use. The first column is a condition. The second column is its value in a policy:

| Condition | Value | Why |
| --- | --- | --- |
| `decimal("1.0") < decimal("2.0")` | `type_error` | Operators work on Longs, datetimes and durations. Use `lessThan`. |
| `decimal("1.50") == decimal("1.5")` | `true` | A decimal is a number. |
| `decimal("1.23456") == decimal("1.0")` | `extension_error` | A decimal has at most four digits after the point. |
| `ip("10.0.0.1/24") == ip("10.0.0.2/24")` | `false` | Equality keeps the host bits and the prefix length. |
| `ip("10.0.0.1/24").isInRange(ip("10.0.0.0/24"))` | `true` | `isInRange` takes exactly one range. A second range is an error. |
| `ip("::ffff:a00:1") == ip("10.0.0.1")` | `false` | An IPv4-mapped IPv6 address is an IPv6 address. It is not the IPv4 address. |
| `ip("::ffff:1.2.3.4")` | `extension_error` | Cedar rejects the dotted IPv4 form inside IPv6. |
| `ip("127.0.0.1/7").isLoopback()` | `false` | The prefix must be as long as the range of the loopback addresses. |
| `datetime("2026-01-01T00:00:00+0100")` | A valid datetime | The offset is `+hhmm`, with no colon. |
| `datetime("2026-01-01T00:00:00+01:00")` | `extension_error` | A colon in the offset is not valid. |
| `duration("1h30m") == duration("90m")` | `true` | A duration is a number of milliseconds. |
| `duration("1m1h")` | `extension_error` | The units must be in the order `d`, `h`, `m`, `s`, `ms`, and each can occur once. |
| `duration("-1999ms").toSeconds() == -1` | `true` | The conversions round toward zero. |
| `datetime("1969-12-31T23:00:00Z").toTime() == duration("23h")` | `true` | `toTime` is the time of the day. It is never negative. |
| `true \|\| decimal("x") == decimal("1.0")` | `true` | Cedar reads a constructor string when it evaluates the call. The right side is not evaluated. |
| `decimal("x") == decimal("1.0")` | `extension_error` | The same string, evaluated. |

A datetime has a year from 0000 to 9999. It has no leap seconds. The method `offset` can go beyond that range, up to the limit of a 64-bit number of milliseconds. An operation that goes beyond the limit is an `extension_error`.

## Next step

Continue with [Cedar in RLS](../../rls/policies.md#policies-for-cedar), or read [Compatibility](compatibility.md).
