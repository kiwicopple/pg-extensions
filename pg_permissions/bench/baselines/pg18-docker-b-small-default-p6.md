# Benchmark: b-policy-first (design b), small scale, default shape

- Date: 2026-10-30 16:17
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 10000 documents, 1000 users, 20 orgs, 50 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.25 | 0.45 | 0.237 | 16861 | 1 | ok |
| rbac_select_page | 0.33 | 0.46 | 0.322 | 12440 | 2 | ok |
| rbac_select_count | 0.29 | 0.38 | 0.266 | 15059 | 2 | ok |
| rbac_update_one | 0.43 | 0.66 | 0.445 | 8996 | 4 | ok |
| write_assign_role | 0.14 | 0.20 | 0.133 | 30052 | 1 | ok |
| share_list_objects | 0.28 | 0.38 | 0.273 | 14629 | 2 | ok |
| share_select_page | 0.47 | 0.92 | 0.501 | 7979 | 5 | ok |
| write_share | 0.14 | 0.23 | 0.135 | 29705 | 1 | ok |
| parents_proj_select_page | 0.53 | 1.16 | 0.598 | 6693 | 2 | ok |
| parents_proj_select_count | 0.51 | 0.94 | 0.554 | 7216 | 2 | ok |
| parents_select_page | 1.21 | 1.86 | 1.288 | 3106 | 4 | ok |
| parents_select_count | 1.11 | 1.57 | 1.149 | 3480 | 4 | ok |
| write_nest_team | 0.81 | 1.27 | 0.875 | 4571 | 1 | OVER |
| nest_check | 0.30 | 0.47 | 0.294 | 13623 | 1 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.09 | 1.1 | 2028 |
| sharing | 0.16 | 2.7 | 6415 |
| parents_proj | 0.03 | 2.8 | 6819 |
| parents | 0.60 | 6.5 | 17019 |
| nesting | 0.02 | 6.5 | 17023 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| ancestors | 0.02 MB, 0 rows | 0.12 MB, 82 rows | 0.12 MB, 82 rows | 0.17 MB, 282 rows | 0.17 MB, 285 rows |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| parents | 0.02 MB, 0 rows | 0.76 MB, 2047 rows | 0.81 MB, 2247 rows | 4.40 MB, 12247 rows | 4.40 MB, 12248 rows |
| policies | 0.08 MB, 6 rows | 0.08 MB, 8 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows |
| role_closure | 0.08 MB, 12 rows | 0.08 MB, 15 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows |
| role_grants | 0.77 MB, 2000 rows | 1.55 MB, 4250 rows | 1.61 MB, 4450 rows | 1.61 MB, 4450 rows | 1.61 MB, 4450 rows |
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
- vs design a (2026-10-30 16:15): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-30 15:57): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design d (2026-10-30 16:13): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.538..2.700 rows=50.00 loops=1)
  Buffers: shared hit=1462 read=4
  InitPlan 1
    ->  Result (actual time=2.491..2.492 rows=2.00 loops=1)
          Buffers: shared hit=872
          ->  ProjectSet (actual time=2.490..2.491 rows=2.00 loops=1)
                Buffers: shared hit=872
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.537..2.696 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=1462 read=4
Planning:
  Buffers: shared hit=112
Planning Time: 0.152 ms
Execution Time: 2.907 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=3.278..3.473 rows=50.00 loops=1)
  Buffers: shared hit=1487 read=2
  InitPlan 1
    ->  Result (actual time=3.027..3.028 rows=2.00 loops=1)
          Buffers: shared hit=874
          ->  ProjectSet (actual time=3.026..3.027 rows=2.00 loops=1)
                Buffers: shared hit=874
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.207..0.210 rows=7.00 loops=1)
          Buffers: shared hit=20
          ->  ProjectSet (actual time=0.206..0.207 rows=7.00 loops=1)
                Buffers: shared hit=20
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.277..3.470 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=1487 read=2
Planning:
  Buffers: shared hit=117
Planning Time: 0.175 ms
Execution Time: 3.687 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.853..3.100 rows=50.00 loops=1)
  Buffers: shared hit=1480 read=2
  InitPlan 1
    ->  Result (actual time=2.628..2.631 rows=7.00 loops=1)
          Buffers: shared hit=856
          ->  ProjectSet (actual time=2.627..2.628 rows=7.00 loops=1)
                Buffers: shared hit=856
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.185..0.191 rows=20.00 loops=1)
          Buffers: shared hit=31
          ->  ProjectSet (actual time=0.184..0.185 rows=20.00 loops=1)
                Buffers: shared hit=31
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.852..3.096 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=1480 read=2
Planning:
  Buffers: shared hit=144
Planning Time: 0.183 ms
Execution Time: 3.287 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=4.699..4.702 rows=50.00 loops=1)
  Buffers: shared hit=1147
  InitPlan 1
    ->  Result (actual time=3.789..4.078 rows=1007.00 loops=1)
          Buffers: shared hit=975
          ->  ProjectSet (actual time=3.788..3.825 rows=1007.00 loops=1)
                Buffers: shared hit=975
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Sort (actual time=4.698..4.699 rows=50.00 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=1147
        ->  Bitmap Heap Scan on documents (actual time=4.386..4.616 rows=1007.00 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=114
              Buffers: shared hit=1144
              ->  Bitmap Index Scan on documents_pkey (actual time=4.372..4.372 rows=1007.00 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Index Searches: 16
                    Buffers: shared hit=1030
Planning:
  Buffers: shared hit=109
Planning Time: 0.170 ms
Execution Time: 4.974 ms
```

