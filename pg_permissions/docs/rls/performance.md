# Performance and query plans

A read policy should compute its accessible IDs once per query and let Postgres use the table index. The policy shape can matter as much as the permission check.

For tenant tables, use the [RBAC fast path](policies.md#tenant-tables-the-fast-path). That section compares three slower or invalid alternatives and explains where to put UUID casts.

The `EXPLAIN` example below uses the database built in [Combine permission models](combine-models.md). See the [benchmark reports](../../research/benchmarks/README.md) for measurements and their limits.

## Plan-time evaluation

A read policy must compute its list once for each query. It must not compute the list once for each row. It must not compute the list while Postgres plans the query, because that runs it a second time.

The form above does this. The `fga_list_object_ids_current` functions return a set. Postgres never calls a function that returns a set at plan time. `EXPLAIN` shows one InitPlan for each list policy and no per-row SubPlan:

```sql
begin;
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
explain select * from public.documents;   -- three InitPlans, no SubPlan
commit;
```

To keep it this way, follow these rules:

- Use `id = any (array(select f(...)::uuid))`, with the cast inside. The form `id in (select ...)` makes Postgres skip the index of the table. This is the same as for `rbac_scopes_with_permission` (see [Tenant tables](policies.md#tenant-tables-the-fast-path)).
- Call the function that returns a set directly. Do not wrap it in your own function that returns an array. Postgres can evaluate a `STABLE` function with constant arguments while it plans. That is why `rbac_scopes_with_permission` has a last argument that you must not pass. If you mark the wrapper `VOLATILE`, you get another problem (see [Other rules](policies.md#other-rules)).
- Use `fga_check_current` only in write policies, which touch few rows. In a read policy, it runs once for each row.
