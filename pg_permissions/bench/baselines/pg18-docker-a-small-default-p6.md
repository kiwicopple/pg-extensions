# Benchmark: a-tuple-core (design a), small scale, default shape

- Date: 2026-10-30 16:15
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 10000 documents, 1000 users, 20 orgs, 50 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.17 | 0.61 | 0.254 | 15724 | 1 | ok |
| rbac_select_page | 0.23 | 0.81 | 0.342 | 11688 | 2 | ok |
| rbac_select_count | 0.17 | 0.64 | 0.264 | 15132 | 2 | ok |
| rbac_update_one | 0.49 | 1.32 | 0.608 | 6583 | 4 | ok |
| write_assign_role | 0.08 | 0.32 | 0.132 | 30189 | 1 | ok |
| share_list_objects | 0.26 | 0.51 | 0.261 | 15316 | 2 | ok |
| share_select_page | 0.46 | 0.71 | 0.478 | 8372 | 5 | ok |
| write_share | 0.14 | 0.23 | 0.143 | 28025 | 1 | ok |
| parents_proj_select_page | 0.64 | 0.99 | 0.663 | 6032 | 2 | ok |
| parents_proj_select_count | 0.62 | 0.98 | 0.652 | 6132 | 2 | ok |
| parents_select_page | 2.68 | 4.03 | 2.887 | 1385 | 4 | OVER |
| parents_select_count | 2.52 | 3.22 | 2.642 | 1513 | 4 | ok |
| write_nest_team | 0.14 | 0.28 | 0.151 | 26503 | 1 | ok |
| nest_check | 0.33 | 0.79 | 0.371 | 10779 | 1 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.10 | 1.0 | 2020 |
| sharing | 0.12 | 2.5 | 6322 |
| parents_proj | 0.02 | 2.6 | 6725 |
| parents | 0.21 | 6.5 | 16726 |
| nesting | 0.02 | 6.5 | 16727 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| object_types | 0.06 MB, 3 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |
| relations | 0.06 MB, 14 rows | 0.06 MB, 17 rows | 0.06 MB, 19 rows | 0.06 MB, 20 rows | 0.06 MB, 20 rows |
| tuples | 0.79 MB, 2000 rows | 2.28 MB, 6297 rows | 2.42 MB, 6697 rows | 6.30 MB, 16697 rows | 6.30 MB, 16698 rows |

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
- vs design b (2026-10-30 15:37): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-30 15:57): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design d (2026-10-30 16:13): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.167..2.347 rows=50.00 loops=1)
  Buffers: shared hit=1290 read=4
  InitPlan 1
    ->  Result (actual time=2.102..2.103 rows=2.00 loops=1)
          Buffers: shared hit=700
          ->  ProjectSet (actual time=2.101..2.101 rows=2.00 loops=1)
                Buffers: shared hit=700
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.166..2.344 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=1290 read=4
Planning:
  Buffers: shared hit=112
Planning Time: 0.235 ms
Execution Time: 2.636 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.232..2.406 rows=50.00 loops=1)
  Buffers: shared hit=1371 read=2
  InitPlan 1
    ->  Result (actual time=2.038..2.039 rows=2.00 loops=1)
          Buffers: shared hit=716
          ->  ProjectSet (actual time=2.037..2.038 rows=2.00 loops=1)
                Buffers: shared hit=716
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.153..0.156 rows=7.00 loops=1)
          Buffers: shared hit=60
          ->  ProjectSet (actual time=0.153..0.153 rows=7.00 loops=1)
                Buffers: shared hit=60
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.231..2.403 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=1371 read=2
Planning:
  Buffers: shared hit=117
Planning Time: 0.158 ms
Execution Time: 2.613 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.093..2.312 rows=50.00 loops=1)
  Buffers: shared hit=1513 read=2
  InitPlan 1
    ->  Result (actual time=1.829..1.831 rows=7.00 loops=1)
          Buffers: shared hit=772
          ->  ProjectSet (actual time=1.828..1.829 rows=7.00 loops=1)
                Buffers: shared hit=772
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.210..0.216 rows=20.00 loops=1)
          Buffers: shared hit=146
          ->  ProjectSet (actual time=0.209..0.210 rows=20.00 loops=1)
                Buffers: shared hit=146
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.092..2.308 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 548
        Index Searches: 1
        Buffers: shared hit=1513 read=2
Planning:
  Buffers: shared hit=144
Planning Time: 0.190 ms
Execution Time: 2.526 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=4.246..4.250 rows=50.00 loops=1)
  Buffers: shared hit=3067
  InitPlan 1
    ->  Result (actual time=3.487..3.750 rows=1007.00 loops=1)
          Buffers: shared hit=2895
          ->  ProjectSet (actual time=3.486..3.518 rows=1007.00 loops=1)
                Buffers: shared hit=2895
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Sort (actual time=4.246..4.247 rows=50.00 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=3067
        ->  Bitmap Heap Scan on documents (actual time=4.039..4.177 rows=1007.00 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=114
              Buffers: shared hit=3064
              ->  Bitmap Index Scan on documents_pkey (actual time=4.029..4.029 rows=1007.00 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Index Searches: 16
                    Buffers: shared hit=2950
Planning:
  Buffers: shared hit=109
Planning Time: 0.132 ms
Execution Time: 4.444 ms
```

