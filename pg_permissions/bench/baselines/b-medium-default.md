# Benchmark: b-policy-first (design b), medium scale, default shape

- Date: 2026-10-29 00:15
- Postgres: 16.4 (Postgres.app)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients
- Throwaway cluster with fsync off: write numbers are optimistic

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.33 | 0.55 | 0.353 | 11323 | - | - |
| rbac_select_page | 0.48 | 0.56 | 0.488 | 8199 | - | - |
| rbac_select_count | 0.42 | 0.53 | 0.438 | 9124 | - | - |
| rbac_update_one | 0.80 | 1.08 | 0.780 | 5130 | - | - |
| write_assign_role | 0.15 | 0.26 | 0.173 | 23122 | - | - |
| share_list_objects | 0.30 | 0.44 | 0.322 | 12436 | - | - |
| share_select_page | 0.89 | 0.99 | 0.892 | 4484 | - | - |
| write_share | 0.14 | 0.24 | 0.156 | 25589 | - | - |
| parents_proj_select_page | 1.05 | 1.29 | 1.081 | 3699 | - | - |
| parents_proj_select_count | 1.08 | 1.75 | 1.163 | 3438 | - | - |
| parents_select_page | 28.78 | 31.79 | 29.163 | 137 | - | - |
| parents_select_count | 28.09 | 30.69 | 28.313 | 141 | - | - |
| write_nest_team | 219.77 | 240.84 | 213.945 | 18 | - | - |
| nest_check | 2.36 | 2.58 | 2.364 | 1691 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.66 | 2.9 | 10028 |
| sharing | 0.89 | 12.2 | 46727 |
| parents_proj | 0.14 | 12.7 | 48731 |
| parents | 15.46 | 86.3 | 348731 |
| nesting | 0.14 | 87.2 | 352736 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| ancestors | 0.02 MB, 0 rows | 4.53 MB, 19494 rows | 4.65 MB, 19994 rows | 53.73 MB, 219994 rows | 54.65 MB, 223998 rows |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| parents | 0.02 MB, 0 rows | 1.48 MB, 6197 rows | 1.60 MB, 6697 rows | 26.15 MB, 106697 rows | 26.15 MB, 106698 rows |
| policies | 0.08 MB, 6 rows | 0.08 MB, 8 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows |
| role_closure | 0.08 MB, 12 rows | 0.08 MB, 15 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows |
| role_grants | 2.54 MB, 10000 rows | 5.88 MB, 21000 rows | 6.13 MB, 22000 rows | 6.13 MB, 22000 rows | 6.13 MB, 22000 rows |
| role_implies | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows |
| roles | 0.06 MB, 6 rows | 0.06 MB, 8 rows | 0.06 MB, 9 rows | 0.06 MB, 9 rows | 0.06 MB, 9 rows |

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

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-29 00:12): parents_proj: same; rbac: same; parents: same; sharing: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.499..1.166 rows=50 loops=1)
  Buffers: shared hit=1507 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.474..0.475 rows=2 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.473..0.473 rows=2 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.498..1.163 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1507 read=8
Planning:
  Buffers: shared hit=815
Planning Time: 2.468 ms
Execution Time: 1.171 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=1.108..1.874 rows=50 loops=1)
  Buffers: shared hit=1541 read=4
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.640..0.641 rows=2 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.639..0.640 rows=2 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.443..0.445 rows=7 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.443..0.443 rows=7 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.108..1.872 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1541 read=4
Planning:
  Buffers: shared hit=863
Planning Time: 3.025 ms
Execution Time: 1.883 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=0.964..1.767 rows=50 loops=1)
  Buffers: shared hit=1581 read=4
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.508..0.510 rows=7 loops=1)
          Buffers: shared hit=50
          ->  ProjectSet (actual time=0.507..0.508 rows=7 loops=1)
                Buffers: shared hit=50
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.428..0.433 rows=20 loops=1)
          Buffers: shared hit=50
          ->  ProjectSet (actual time=0.428..0.428 rows=20 loops=1)
                Buffers: shared hit=50
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.964..1.764 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1581 read=4
Planning:
  Buffers: shared hit=901
Planning Time: 3.227 ms
Execution Time: 1.773 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=16.055..16.058 rows=50 loops=1)
  Buffers: shared hit=16885
  InitPlan 1 (returns $0)
    ->  Result (actual time=11.910..12.896 rows=4007 loops=1)
          Buffers: shared hit=3723
          ->  ProjectSet (actual time=11.909..11.996 rows=4007 loops=1)
                Buffers: shared hit=3723
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=16.055..16.056 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=16885
        ->  Bitmap Heap Scan on documents (actual time=14.831..15.878 rows=4007 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1135
              Buffers: shared hit=16882
              ->  Bitmap Index Scan on documents_pkey (actual time=14.771..14.771 rows=4007 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=15747
Planning:
  Buffers: shared hit=4518
Planning Time: 15.774 ms
Execution Time: 16.066 ms
```

