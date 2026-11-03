# Limits

Explicit-subject and current-subject API limits differ. In particular, the OpenFGA admin list functions cap their results, while the current-subject list functions return every accessible result, whether called from application code or RLS. The Cedar functions have size limits on policies and entities, and no cap on results.

The batching examples are fragments for a database with the `document#viewer` model from [the error examples](errors.md).

The sections [Limits](#limits) (OpenFGA) and [Cedar limits](#cedar-limits) list the limits of each model. The `rbac_*` functions have no limits.

## Limits

The limits of the API functions are the default limits of OpenFGA. You cannot change them.

| Limit | Value | What happens when you go over it |
| --- | --- | --- |
| Tuple keys in one `fga_write` call, `writes` and `deletes` together | 100 | Error `openfga:2053`. |
| Results of `fga_list_objects` and `fga_list_users` | 1,000 | Additional results are silently omitted. |
| Tuples in one page of `fga_read` | 50 by default. `page_size` can be 1 to 100. | Another `page_size` is error `openfga:2000`. |
| Length of a `continuation_token` | 5,120 bytes | Error `openfga:2000`. |
| Levels in one Check, ListObjects or ListUsers | 25 | Error `openfga:2002`, with SQLSTATE `54001`. |
| Length of a type name | 254 characters | Error `openfga:2047`. |
| Length of a relation name | 50 characters | Error `openfga:2050`. |
| Length of an expression of a condition | 512 bytes | Error `openfga:2000`. |
| Parameters of a condition | 25 | Error `openfga:2000`. |
| Length of the name of a condition or a parameter | 50 characters | Error `openfga:2000`. |
| Cost of the evaluation of a condition | 100 steps | Error `openfga:2000` when the extension evaluates the condition. |

The current-subject functions `fga_list_objects_current` and `fga_list_object_ids_current` have no cap on the number of results. A cap there would hide rows and give no sign of it. `fga_check_current` has the same depth limit as `fga_check`. The `rbac_*` functions have no limits.

The extension has no built-in time limit on API calls. OpenFGA stops a list after 3 seconds and can return partial results. To bound execution in Postgres, set `statement_timeout`; exceeding it raises an error instead of returning a partial list.

To write more than 100 tuples, write them in batches. The batches can share a transaction. They then commit together:

```sql
begin;
select permissions.fga_write(
  writes => (
    select jsonb_agg(
      jsonb_build_object(
        'user', 'user:u' || g,
        'relation', 'viewer',
        'object', 'document:big'
      )
    )
    from generate_series(1, 100) g
  )
);
select permissions.fga_write(
  writes => (
    select jsonb_agg(
      jsonb_build_object(
        'user', 'user:u' || g,
        'relation', 'viewer',
        'object', 'document:big'
      )
    )
    from generate_series(101, 200) g
  )
);
commit;
```

A call with 101 tuple keys fails:

```sql
select permissions.fga_write(
  writes => (
    select jsonb_agg(
      jsonb_build_object(
        'user', 'user:v' || g,
        'relation', 'viewer',
        'object', 'document:big'
      )
    )
    from generate_series(1, 101) g
  )
);
-- ERROR:  The number of write operations exceeds the allowed limit of 100: got 101 tuple keys (101 writes, 0 deletes)
-- DETAIL:  openfga:2053 exceeded_entity_limit
-- HINT:  Split the tuple keys into batches of at most 100 and call fga_write once per batch: calls in one transaction commit or roll back together.
```

## Cedar limits

These limits are fixed and exceed the maxima in the tested Cedar corpus. The extension has no evaluation-step counter. Although Cedar has no loops, the number of candidate policies, the entity hierarchy and collection sizes still affect the work of a request. Use `statement_timeout` to bound execution time.

| Limit | Value | What happens when you go over it |
| --- | --- | --- |
| Text of one policy or template | 64 KiB | Error `cedar:limit_exceeded` with `limit='policy_bytes'`. |
| Expression nodes in one policy | 4,096 | Error `cedar:limit_exceeded` with `limit='policy_nodes'`. |
| Nesting depth of one expression | 64 | Error `cedar:limit_exceeded` with `limit='policy_depth'`. The parser checks it too. |
| Nesting of sets and records in entity data and in the context | 32 | Error `cedar:limit_exceeded` with `limit='value_depth'`. The entity error also has the `index` of the entity. |
| Entities in one `cedar_put_entities` call | 10,000 | Error `cedar:limit_exceeded` with `limit='put_entities'`. |
| Entities in the `entities` argument of one `cedar_is_authorized` call | 1,000 | Error `cedar:limit_exceeded` with `limit='request_entities'`. |
| Depth of the entity hierarchy | None. A cycle is an error. | Not applicable. |
| Number of policies, templates and links | None | Not applicable. |
| Results of `cedar_list_resources_current` | None | Not applicable. |
| Size of a Long | -2^63 to 2^63-1 | An entity with another number is `cedar:invalid_entity`. A result that goes beyond the range is an `overflow` error of the policy. |

`cedar_list_resources_current` has no result cap: a cap could silently hide rows from an RLS query. `cedar_is_authorized_current` returns a single boolean. The extension has no built-in time limit; exceeding Postgres's `statement_timeout` raises an error rather than returning a partial result.

To store more than 10,000 entities, put them in batches. The batches can share a transaction. They then commit together:

```sql
begin;
select permissions.cedar_put_entities(
  entities => (
    select jsonb_agg(
      jsonb_build_object(
        'uid', jsonb_build_object(
          'type', 'Item',
          'id', 'i' || g
        )
      )
    )
    from generate_series(1, 10000) g
  )
);
select permissions.cedar_put_entities(
  entities => (
    select jsonb_agg(
      jsonb_build_object(
        'uid', jsonb_build_object(
          'type', 'Item',
          'id', 'i' || g
        )
      )
    )
    from generate_series(10001, 20000) g
  )
);
commit;
```

A call with 10,001 entities fails:

```sql
select permissions.cedar_put_entities(
  entities => (
    select jsonb_agg(
      jsonb_build_object(
        'uid', jsonb_build_object(
          'type', 'Big',
          'id', 'b' || g
        )
      )
    )
    from generate_series(1, 10001) g
  )
);
-- ERROR:  too many entities in entities: 10001 (the limit is 10000)
-- DETAIL:  cedar:limit_exceeded limit='put_entities'
-- HINT:  An argument holds at most 10000 entities: put them in batches.
```
