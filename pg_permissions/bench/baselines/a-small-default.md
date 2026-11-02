# Benchmark: a-tuple-core (design a), small scale, default shape

- Date: 2026-10-29 00:20
- Postgres: 16.4 (Postgres.app)
- Data: 10000 documents, 1000 users, 20 orgs, 50 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients
- Throwaway cluster with fsync off: write numbers are optimistic

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.27 | 0.43 | 0.287 | 13951 | 1 | ok |
| rbac_select_page | 0.44 | 0.61 | 0.461 | 8675 | 2 | ok |
| rbac_select_count | 0.39 | 0.47 | 0.398 | 10044 | 2 | ok |
| rbac_update_one | 0.79 | 1.03 | 0.767 | 5215 | 4 | ok |
| write_assign_role | 0.16 | 0.27 | 0.172 | 23262 | 1 | ok |
| share_list_objects | 0.38 | 0.47 | 0.390 | 10258 | 2 | ok |
| share_select_page | 1.15 | 1.29 | 1.140 | 3509 | 5 | ok |
| write_share | 0.15 | 0.25 | 0.159 | 25153 | 1 | ok |
| parents_proj_select_page | 2.16 | 3.02 | 2.266 | 1765 | - | - |
| parents_proj_select_count | 2.06 | 2.44 | 2.081 | 1922 | - | - |
| parents_select_page | 20.83 | 22.75 | 21.006 | 190 | - | - |
| parents_select_count | 20.53 | 22.44 | 20.675 | 193 | - | - |
| write_nest_team | 0.15 | 0.27 | 0.170 | 23477 | - | - |
| nest_check | 0.33 | 0.45 | 0.347 | 11514 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.13 | 1.0 | 2020 |
| sharing | 0.17 | 2.5 | 6322 |
| parents_proj | 0.04 | 2.6 | 6725 |
| parents | 0.37 | 6.4 | 16726 |
| nesting | 0.05 | 6.4 | 16727 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| object_types | 0.06 MB, 3 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |
| relations | 0.06 MB, 14 rows | 0.06 MB, 17 rows | 0.06 MB, 19 rows | 0.06 MB, 20 rows | 0.06 MB, 20 rows |
| tuples | 0.78 MB, 2000 rows | 2.27 MB, 6297 rows | 2.41 MB, 6697 rows | 6.22 MB, 16697 rows | 6.22 MB, 16698 rows |

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
- vs design b (2026-10-28 23:24): parents_proj: same; rbac: same; parents: same; sharing: same
- vs design c (2026-10-28 23:25): parents_proj: same; rbac: same; parents: same; sharing: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.368..0.515 rows=50 loops=1)
  Buffers: shared hit=639 read=4
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.346..0.347 rows=2 loops=1)
          Buffers: shared hit=49
          ->  ProjectSet (actual time=0.346..0.346 rows=2 loops=1)
                Buffers: shared hit=49
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.367..0.513 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 548
        Buffers: shared hit=639 read=4
Planning:
  Buffers: shared hit=686
Planning Time: 1.890 ms
Execution Time: 0.521 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.830..0.999 rows=50 loops=1)
  Buffers: shared hit=806 read=2
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.416..0.417 rows=2 loops=1)
          Buffers: shared hit=106
          ->  ProjectSet (actual time=0.415..0.416 rows=2 loops=1)
                Buffers: shared hit=106
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.394..0.396 rows=7 loops=1)
          Buffers: shared hit=106
          ->  ProjectSet (actual time=0.394..0.394 rows=7 loops=1)
                Buffers: shared hit=106
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.830..0.997 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 548
        Buffers: shared hit=806 read=2
Planning:
  Buffers: shared hit=852
Planning Time: 2.420 ms
Execution Time: 1.007 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=1.188..1.375 rows=50 loops=1)
  Buffers: shared hit=1182 read=2
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.586..0.588 rows=7 loops=1)
          Buffers: shared hit=294
          ->  ProjectSet (actual time=0.585..0.585 rows=7 loops=1)
                Buffers: shared hit=294
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.578..0.583 rows=20 loops=1)
          Buffers: shared hit=294
          ->  ProjectSet (actual time=0.578..0.579 rows=20 loops=1)
                Buffers: shared hit=294
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.187..1.373 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 548
        Buffers: shared hit=1182 read=2
Planning:
  Buffers: shared hit=1223
Planning Time: 2.748 ms
Execution Time: 1.383 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=9.634..9.637 rows=50 loops=1)
  Buffers: shared hit=9421
  InitPlan 1 (returns $0)
    ->  Result (actual time=8.867..9.107 rows=1007 loops=1)
          Buffers: shared hit=7287
          ->  ProjectSet (actual time=8.866..8.889 rows=1007 loops=1)
                Buffers: shared hit=7287
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=9.634..9.635 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 30kB
        Buffers: shared hit=9421
        ->  Bitmap Heap Scan on documents (actual time=9.439..9.584 rows=1007 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=114
              Buffers: shared hit=9418
              ->  Bitmap Index Scan on documents_pkey (actual time=9.431..9.431 rows=1007 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=9304
Planning:
  Buffers: shared hit=7916
Planning Time: 10.836 ms
Execution Time: 9.644 ms
```

