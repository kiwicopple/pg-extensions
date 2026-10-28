# Benchmark: a-tuple-core, large scale

- Date: 2026-10-28 21:39
- Postgres: 16.4 (Postgres.app)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- pgbench: 10s per workload, 4 clients
- Throwaway cluster with fsync off: write numbers are optimistic

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.29 | 0.40 | 0.309 | 12957 | - | - |
| rbac_select_page | 0.71 | 0.85 | 0.729 | 5486 | - | - |
| rbac_select_count | 0.87 | 1.02 | 0.893 | 4477 | - | - |
| rbac_update_one | 0.96 | 1.12 | 0.904 | 4425 | - | - |
| write_assign_role | 0.09 | 0.15 | 0.107 | 37402 | - | - |
| share_list_objects | 0.48 | 0.77 | 0.508 | 7874 | - | - |
| share_select_page | 1.90 | 2.31 | 1.928 | 2074 | - | - |
| write_share | 0.09 | 0.16 | 0.105 | 38121 | - | - |

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.212..2.401 rows=50 loops=1)
  Buffers: shared hit=2714
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.155..0.156 rows=2 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.154..0.155 rows=2 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.212..2.399 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 2619
        Buffers: shared hit=2714
Planning:
  Buffers: shared hit=590
Planning Time: 0.858 ms
Execution Time: 2.406 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.616..11.971 rows=50 loops=1)
  Buffers: shared hit=447 read=2393 written=1558
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.228..0.229 rows=2 loops=1)
          Buffers: shared hit=78
          ->  ProjectSet (actual time=0.228..0.228 rows=2 loops=1)
                Buffers: shared hit=78
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.185..0.187 rows=7 loops=1)
          Buffers: shared hit=78
          ->  ProjectSet (actual time=0.185..0.185 rows=7 loops=1)
                Buffers: shared hit=78
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.615..11.968 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 2619
        Buffers: shared hit=447 read=2393 written=1558
Planning:
  Buffers: shared hit=714
Planning Time: 1.190 ms
Execution Time: 11.980 ms
```

