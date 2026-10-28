# Benchmark: a-tuple-core (design a), medium scale, default shape

- Date: 2026-10-29 00:12
- Postgres: 16.4 (Postgres.app)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients
- Throwaway cluster with fsync off: write numbers are optimistic

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.27 | 0.37 | 0.285 | 14011 | - | - |
| rbac_select_page | 0.53 | 0.63 | 0.542 | 7377 | - | - |
| rbac_select_count | 0.47 | 0.56 | 0.475 | 8416 | - | - |
| rbac_update_one | 0.82 | 0.97 | 0.777 | 5146 | - | - |
| write_assign_role | 0.17 | 0.29 | 0.180 | 22184 | - | - |
| share_list_objects | 0.45 | 0.60 | 0.464 | 8623 | - | - |
| share_select_page | 1.53 | 1.73 | 1.530 | 2614 | - | - |
| write_share | 0.15 | 0.26 | 0.163 | 24479 | - | - |
| parents_proj_select_page | 2.57 | 3.01 | 2.595 | 1541 | - | - |
| parents_proj_select_count | 2.62 | 3.06 | 2.668 | 1499 | - | - |
| parents_select_page | 99.57 | 109.11 | 100.653 | 39 | - | - |
| parents_select_count | 98.91 | 115.06 | 100.780 | 39 | - | - |
| write_nest_team | 0.15 | 0.25 | 0.157 | 25417 | - | - |
| nest_check | 0.66 | 0.77 | 0.681 | 5869 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.80 | 3.6 | 10020 |
| sharing | 0.61 | 9.5 | 27222 |
| parents_proj | 0.09 | 10.0 | 28725 |
| parents | 3.82 | 47.9 | 128726 |
| nesting | 0.03 | 47.9 | 128727 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| object_types | 0.06 MB, 3 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |
| relations | 0.06 MB, 14 rows | 0.06 MB, 17 rows | 0.06 MB, 19 rows | 0.06 MB, 20 rows | 0.06 MB, 20 rows |
| tuples | 3.43 MB, 10000 rows | 9.33 MB, 27197 rows | 9.82 MB, 28697 rows | 47.70 MB, 128697 rows | 47.70 MB, 128698 rows |

## Equivalence

Documents each sample user sees through RLS after each seed, and the md5 of their sorted ids. Every 5th user is also a folder viewer, so for users not divisible by 5 parents_proj and parents must equal sharing, and parents_proj must always equal parents.

| policy | user | visible | md5 |
| --- | --- | --- | --- |
| rbac | 1 | 4000 | abe7a5a8440045bf3a6b4d35af791d8b |
| rbac | 2 | 4000 | 15806ec009213b1b8680a43dd9dae415 |
| rbac | 3 | 4000 | a171b9d4a238ebe30a12f7d43e4792a6 |
| rbac | 5 | 4000 | 3c906bb80bfb8cf875bcced92319d78e |
| rbac | 10 | 4000 | 83682d14d44928065e8fcd51a0fa3904 |
| rbac | 77 | 4000 | 266488027a22126548692c1fbb5615be |
| rbac | 500 | 4000 | ac5436d43b03d0b83e3ab7c5eecb0aa0 |
| rbac | 5000 | 4000 | ac5436d43b03d0b83e3ab7c5eecb0aa0 |
| sharing | 1 | 4007 | a72affb8dac9720afe47ed798856f486 |
| sharing | 2 | 4007 | a2907603023a122749a3257a6b76c92e |
| sharing | 3 | 4012 | dd7a7ecbdd714a8dc57fa5f0f8e69c8c |
| sharing | 5 | 4012 | 62910a5297358a981fbcb3abcd8b27ca |
| sharing | 10 | 4010 | 3f86ef71af4f0df87ebea0da7274fff6 |
| sharing | 77 | 4022 | 992b5588b0acef0e5f01285d911f79da |
| sharing | 500 | 4020 | 425a5d25d85612f6054e6591a821fafb |
| sharing | 5000 | 4006 | ba82507ecb8f9717f9ecb4b21da14ade |
| parents_proj | 1 | 4007 | a72affb8dac9720afe47ed798856f486 |
| parents_proj | 2 | 4007 | a2907603023a122749a3257a6b76c92e |
| parents_proj | 3 | 4012 | dd7a7ecbdd714a8dc57fa5f0f8e69c8c |
| parents_proj | 5 | 4212 | a570b2a32be579248c09197f56dca5bb |
| parents_proj | 10 | 4210 | 08d4ebfb3b09329146de3fdac7fc86f1 |
| parents_proj | 77 | 4022 | 992b5588b0acef0e5f01285d911f79da |
| parents_proj | 500 | 4220 | 5fee4f97891d7a79d09e06a8208212c2 |
| parents_proj | 5000 | 4206 | a4e9098b3f0f4616a3bb53336e12c394 |
| parents | 1 | 4007 | a72affb8dac9720afe47ed798856f486 |
| parents | 2 | 4007 | a2907603023a122749a3257a6b76c92e |
| parents | 3 | 4012 | dd7a7ecbdd714a8dc57fa5f0f8e69c8c |
| parents | 5 | 4212 | a570b2a32be579248c09197f56dca5bb |
| parents | 10 | 4210 | 08d4ebfb3b09329146de3fdac7fc86f1 |
| parents | 77 | 4022 | 992b5588b0acef0e5f01285d911f79da |
| parents | 500 | 4220 | 5fee4f97891d7a79d09e06a8208212c2 |
| parents | 5000 | 4206 | a4e9098b3f0f4616a3bb53336e12c394 |

Compared with other designs' latest runs at this scale and shape: none yet.

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.419..1.111 rows=50 loops=1)
  Buffers: shared hit=1526 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.395..0.396 rows=2 loops=1)
          Buffers: shared hit=49
          ->  ProjectSet (actual time=0.394..0.394 rows=2 loops=1)
                Buffers: shared hit=49
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.419..1.108 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1526 read=8
Planning:
  Buffers: shared hit=688
Planning Time: 1.955 ms
Execution Time: 1.117 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.844..1.560 rows=50 loops=1)
  Buffers: shared hit=1695 read=4
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.422..0.422 rows=2 loops=1)
          Buffers: shared hit=106
          ->  ProjectSet (actual time=0.421..0.421 rows=2 loops=1)
                Buffers: shared hit=106
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.397..0.399 rows=7 loops=1)
          Buffers: shared hit=106
          ->  ProjectSet (actual time=0.397..0.397 rows=7 loops=1)
                Buffers: shared hit=106
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.844..1.559 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1695 read=4
Planning:
  Buffers: shared hit=852
Planning Time: 2.428 ms
Execution Time: 1.568 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=1.252..2.023 rows=50 loops=1)
  Buffers: shared hit=2127 read=4
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.618..0.620 rows=7 loops=1)
          Buffers: shared hit=322
          ->  ProjectSet (actual time=0.617..0.618 rows=7 loops=1)
                Buffers: shared hit=322
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.605..0.610 rows=20 loops=1)
          Buffers: shared hit=322
          ->  ProjectSet (actual time=0.604..0.605 rows=20 loops=1)
                Buffers: shared hit=322
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.251..2.021 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 1429
        Buffers: shared hit=2127 read=4
Planning:
  Buffers: shared hit=1276
Planning Time: 2.801 ms
Execution Time: 2.030 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=43.684..43.687 rows=50 loops=1)
  Buffers: shared hit=49493
  InitPlan 1 (returns $0)
    ->  Result (actual time=39.752..40.713 rows=4007 loops=1)
          Buffers: shared hit=36332
          ->  ProjectSet (actual time=39.752..39.838 rows=4007 loops=1)
                Buffers: shared hit=36332
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=43.683..43.684 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=49493
        ->  Bitmap Heap Scan on documents (actual time=42.609..43.515 rows=4007 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1134
              Buffers: shared hit=49490
              ->  Bitmap Index Scan on documents_pkey (actual time=42.549..42.549 rows=4007 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=48356
Planning:
  Buffers: shared hit=36962
Planning Time: 43.119 ms
Execution Time: 43.695 ms
```

