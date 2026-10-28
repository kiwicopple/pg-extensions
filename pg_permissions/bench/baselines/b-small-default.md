# Benchmark: b-policy-first (design b), small scale, default shape

- Date: 2026-10-29 00:23
- Postgres: 16.4 (Postgres.app)
- Data: 10000 documents, 1000 users, 20 orgs, 50 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients
- Throwaway cluster with fsync off: write numbers are optimistic

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.32 | 0.39 | 0.328 | 12206 | 1 | ok |
| rbac_select_page | 0.39 | 0.47 | 0.398 | 10047 | 2 | ok |
| rbac_select_count | 0.34 | 0.42 | 0.354 | 11292 | 2 | ok |
| rbac_update_one | 0.79 | 0.87 | 0.739 | 5412 | 4 | ok |
| write_assign_role | 0.15 | 0.25 | 0.159 | 25180 | 1 | ok |
| share_list_objects | 0.28 | 0.36 | 0.287 | 13931 | 2 | ok |
| share_select_page | 0.69 | 0.82 | 0.711 | 5629 | 5 | ok |
| write_share | 0.14 | 0.24 | 0.151 | 26471 | 1 | ok |
| parents_proj_select_page | 0.79 | 1.04 | 0.819 | 4886 | - | - |
| parents_proj_select_count | 0.73 | 0.89 | 0.754 | 5306 | - | - |
| parents_select_page | 5.88 | 6.31 | 5.926 | 675 | - | - |
| parents_select_count | 5.80 | 6.25 | 5.849 | 683 | - | - |
| write_nest_team | 134.09 | 161.47 | 134.582 | 29 | - | - |
| nest_check | 1.16 | 1.29 | 1.166 | 3429 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.11 | 0.9 | 2028 |
| sharing | 0.21 | 3.0 | 10055 |
| parents_proj | 0.07 | 3.2 | 10659 |
| parents | 1.49 | 10.5 | 40659 |
| nesting | 0.07 | 11.2 | 43663 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| ancestors | 0.02 MB, 0 rows | 0.92 MB, 3722 rows | 0.98 MB, 3922 rows | 5.90 MB, 23922 rows | 6.58 MB, 26925 rows |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| parents | 0.02 MB, 0 rows | 0.55 MB, 2047 rows | 0.59 MB, 2247 rows | 3.05 MB, 12247 rows | 3.05 MB, 12248 rows |
| policies | 0.08 MB, 6 rows | 0.08 MB, 8 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows |
| role_closure | 0.08 MB, 12 rows | 0.08 MB, 15 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows |
| role_grants | 0.56 MB, 2000 rows | 1.24 MB, 4250 rows | 1.30 MB, 4450 rows | 1.30 MB, 4450 rows | 1.30 MB, 4450 rows |
| role_implies | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows |
| roles | 0.06 MB, 6 rows | 0.06 MB, 8 rows | 0.06 MB, 9 rows | 0.06 MB, 9 rows | 0.06 MB, 9 rows |

## Equivalence

Documents each sample user sees through RLS after each seed, and the md5 of their sorted ids. Every 5th user is also a folder viewer, so for users not divisible by 5 parents_proj and parents must equal sharing, and parents_proj must always equal parents.

| policy | user | visible | md5 |
| --- | --- | --- | --- |
| rbac | 1 | 1000 | 32d4f239c366fea35a5ef36b8c39951e |
| rbac | 2 | 1000 | 4e1830b17a8269e704b55b945b618cd4 |
| rbac | 3 | 1000 | 78c4d0b810ba5f8a462642451ca609b0 |
| rbac | 5 | 1000 | 600d6ac1d050e16012c44cc9caf4b9e3 |
| rbac | 10 | 1000 | 67b08ee90ded8099328c7ac98376a317 |
| rbac | 77 | 1000 | 4e1830b17a8269e704b55b945b618cd4 |
| rbac | 500 | 1000 | b6a5aa102e8824a66f6644f1429b9d78 |
| rbac | 1000 | 1000 | b6a5aa102e8824a66f6644f1429b9d78 |
| sharing | 1 | 1007 | f635214e68cb66caeeaaf31b9e47c0e5 |
| sharing | 2 | 1005 | a32ea7ae134e6eec5e63db894c97e9b8 |
| sharing | 3 | 1012 | d65d9f337cf0efef2fbbb2b5fa39a0c0 |
| sharing | 5 | 1011 | 9ea5cdb71a200276b84ae1d60daf8b70 |
| sharing | 10 | 1012 | b98e1ed845af9b686122a67c92a52194 |
| sharing | 77 | 1015 | 9936bba1571d2af2f5fcd43ad643be5a |
| sharing | 500 | 1007 | a0147f5aa1e0d2179a774c6ae09277a0 |
| sharing | 1000 | 1007 | c837ee69e297b4776b984dc062bb28ee |
| parents_proj | 1 | 1007 | f635214e68cb66caeeaaf31b9e47c0e5 |
| parents_proj | 2 | 1005 | a32ea7ae134e6eec5e63db894c97e9b8 |
| parents_proj | 3 | 1012 | d65d9f337cf0efef2fbbb2b5fa39a0c0 |
| parents_proj | 5 | 1060 | 557a27517d4d2b6eb8f4ecd87060ab57 |
| parents_proj | 10 | 1062 | c34e39f19fa172caadc858d61087fbc5 |
| parents_proj | 77 | 1015 | 9936bba1571d2af2f5fcd43ad643be5a |
| parents_proj | 500 | 1057 | 497acd0fa8a7231c284ada146bac9aa5 |
| parents_proj | 1000 | 1057 | 1c8390d0c8b5c0058632f723c73fbf89 |
| parents | 1 | 1007 | f635214e68cb66caeeaaf31b9e47c0e5 |
| parents | 2 | 1005 | a32ea7ae134e6eec5e63db894c97e9b8 |
| parents | 3 | 1012 | d65d9f337cf0efef2fbbb2b5fa39a0c0 |
| parents | 5 | 1060 | 557a27517d4d2b6eb8f4ecd87060ab57 |
| parents | 10 | 1062 | c34e39f19fa172caadc858d61087fbc5 |
| parents | 77 | 1015 | 9936bba1571d2af2f5fcd43ad643be5a |
| parents | 500 | 1057 | 497acd0fa8a7231c284ada146bac9aa5 |
| parents | 1000 | 1057 | 1c8390d0c8b5c0058632f723c73fbf89 |

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-29 00:20): parents_proj: same; rbac: same; parents: same; sharing: same
- vs design c (2026-10-28 23:25): parents_proj: same; rbac: same; parents: same; sharing: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.475..0.623 rows=50 loops=1)
  Buffers: shared hit=619 read=4
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.452..0.453 rows=2 loops=1)
          Buffers: shared hit=29
          ->  ProjectSet (actual time=0.452..0.452 rows=2 loops=1)
                Buffers: shared hit=29
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.475..0.621 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 548
        Buffers: shared hit=619 read=4
Planning:
  Buffers: shared hit=812
Planning Time: 2.361 ms
Execution Time: 0.628 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.810..0.981 rows=50 loops=1)
  Buffers: shared hit=647 read=2
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.463..0.464 rows=2 loops=1)
          Buffers: shared hit=27
          ->  ProjectSet (actual time=0.462..0.463 rows=2 loops=1)
                Buffers: shared hit=27
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.326..0.328 rows=7 loops=1)
          Buffers: shared hit=27
          ->  ProjectSet (actual time=0.326..0.326 rows=7 loops=1)
                Buffers: shared hit=27
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.810..0.979 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 548
        Buffers: shared hit=647 read=2
Planning:
  Buffers: shared hit=855
Planning Time: 3.138 ms
Execution Time: 0.988 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=0.903..1.103 rows=50 loops=1)
  Buffers: shared hit=669 read=2
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.485..0.487 rows=7 loops=1)
          Buffers: shared hit=38
          ->  ProjectSet (actual time=0.484..0.484 rows=7 loops=1)
                Buffers: shared hit=38
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.390..0.396 rows=20 loops=1)
          Buffers: shared hit=38
          ->  ProjectSet (actual time=0.390..0.391 rows=20 loops=1)
                Buffers: shared hit=38
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.903..1.101 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 548
        Buffers: shared hit=669 read=2
Planning:
  Buffers: shared hit=877
Planning Time: 3.071 ms
Execution Time: 1.111 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=3.596..3.599 rows=50 loops=1)
  Buffers: shared hit=2711
  InitPlan 1 (returns $0)
    ->  Result (actual time=2.797..3.038 rows=1007 loops=1)
          Buffers: shared hit=577
          ->  ProjectSet (actual time=2.797..2.822 rows=1007 loops=1)
                Buffers: shared hit=577
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=3.596..3.597 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 30kB
        Buffers: shared hit=2711
        ->  Bitmap Heap Scan on documents (actual time=3.392..3.546 rows=1007 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=114
              Buffers: shared hit=2708
              ->  Bitmap Index Scan on documents_pkey (actual time=3.385..3.385 rows=1007 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=2594
Planning:
  Buffers: shared hit=1374
Planning Time: 5.083 ms
Execution Time: 3.610 ms
```

