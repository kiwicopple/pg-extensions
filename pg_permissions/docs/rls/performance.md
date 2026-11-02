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

## Cedar policies

The Cedar functions follow the same rule as the others: compute a list once for each query, and check one row for a write. The cost differs from OpenFGA in one way. A list of Cedar resources is a set of stored entities, and a check for one row can run a condition on that row.

| Function | Work for each query | Work for each row |
| --- | --- | --- |
| `cedar_list_resources_current`, as `id = any (array(select ...))` | The walk of the groups of the user, the policies that can match, and the candidate resources | None. Postgres uses the index of the table. |
| `cedar_is_authorized_current` | The walk of the groups of the user and of the action, and the policies that can match | A look-up in the result of the first part. Then, when a policy has a condition, the condition. |

### Measurements

The tables below record phase 5 measurements from [the design record](../../research/designs/e-cedar.md#152-cedar_is_authorized_current-the-statement-level-work-in-a-setting) and [the benchmark page](../../research/benchmarks/cedar.md). They predate the statement-cache security fixes. The later [phase 9 runs](../../research/benchmarks/cedar.md#phase-9) cover small and medium datasets: list and single-row workloads remained within measurement noise, while the per-row page improved from 39.9 to 35.2 ms at small scale and from 107.8 to 97.5 ms at medium scale (p50). Large scale was not rerun in phase 9.

These measurements describe the workloads and machines below. Measure your own policies before choosing a query shape.

Per row, in microseconds (Postgres 16.4 on a laptop with Apple silicon, 1,000 rows, best of 5 runs):

| Policy shape | µs for each row |
| --- | --- |
| 5 of 1,000 documents are shared with the user. The other rows have no policy that matches. | 4.0 |
| `resource_attrs` from the row, and a condition on every row (`resource.level <= principal.level`) | 36.6 |
| 20 folder links, each with a condition. Every row walks to its folder and runs the condition. | 78.5 |
| For comparison: `cedar_is_authorized` on the same requests | 77.1 |

For one call of the list function (the same setup, 1,000 documents):

| Policy shape | µs for each call |
| --- | --- |
| 5 shares, no conditions | 73.9 |
| 20 folder links with a condition: 1,000 documents are walked and checked | 23,302 |
| `resource is Document` with a condition: every document is checked | 15,336 |

A condition added about 15 to 23 µs per candidate resource in these measurements. Unconditional permits can avoid that evaluation when no forbid needs checking.

The benchmark of the harness (Postgres 18.6 in Docker, 4 clients, 10 s for each workload, p50 and p95 in ms) has a page of documents that a user can read, with the list in the policy, and a page that checks each row:

| Workload | Small (10,000 documents) | Large (1,000,000 documents) |
| --- | --- | --- |
| `share_select_page`: the list in the policy | 0.56 / 0.91 | 1.19 / 1.84 |
| `nest_check`: one check of one row | 0.34 / 0.58 | 0.40 / 0.63 |
| `row_select_page`: a check on every row, until 50 rows are visible | 39.9 / 59.6 | 225.5 / 312.5 |

The page that checks each row reads about 500 rows at small scale, and about 2,600 rows at large scale, because a user sees 2% of the documents there. This is about 80 µs for each row in this setup. The list and the one-row check are close to the cost of the OpenFGA functions in the same harness. The [benchmark page](../../research/benchmarks/cedar.md) compares both models workload by workload.

### Rules

- **Use the list for reads.** `id = any (array(select permissions.cedar_list_resources_current(...)))` computes accessible ids once per statement. Narrow policy scopes reduce candidate work; broad scopes with conditions can still require checking every stored resource. In the phase 5 sharing benchmark, a page took 0.56 ms at 10,000 documents and 1.19 ms at 1,000,000 documents (p50).
- **Use the check for writes and for single rows.** A write policy touches few rows.
- **Reduce repeated condition evaluation.** A condition over many candidate resources can dominate the query cost. If the rule can be represented by group membership, use that hierarchy in the policy scope. Moving an attribute into entity storage does not remove the cost of evaluating a condition on it. Rules on row columns can also use a plain SQL policy.
- **A forbid that applies to a user costs more.** For a user to whom no `forbid` applies, a check of a row is answered from the work of the query. For a user to whom a `forbid` applies, each row evaluates it.
- **Store resources that need to appear in lists.** The list returns stored entities only; a row check can use attributes supplied from the row. A policy with `resource in Folder::"x"` walks that folder's descendants, including other entity types. Keep the resource hierarchy focused to avoid unnecessary traversal.
- **Do not wrap the functions.** The same rule as in [Plan-time evaluation](#plan-time-evaluation) holds. Call the list function directly. Do not pass `plan_time_guard`.

`EXPLAIN` shows a list policy as one InitPlan. A check policy is a filter on the table. The check does the work for the principal once for each query, and `EXPLAIN` does not show it. To see the number of calls, use `auto_explain` with nested statements, or `pg_stat_user_functions` with `track_functions = 'all'`.
