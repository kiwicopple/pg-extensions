# Limits

API limits and RLS helper limits differ. In particular, the OpenFGA API list functions cap their results, while RLS list helpers return every accessible result.

The batching examples are fragments for a database with the `document#viewer` model from [the error examples](errors.md).

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

The RLS helpers `fga_list_objects_current` and `fga_list_object_ids_current` have no cap on the number of results. A cap there would hide rows and give no sign of it. `fga_check_current` has the same depth limit as `fga_check`. The `rbac_*` functions have no limits.

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
