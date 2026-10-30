# Benchmark: b-policy-first (design b), medium scale, default shape

- Date: 2026-10-30 16:06
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.27 | 0.37 | 0.261 | 15319 | 1 | ok |
| rbac_select_page | 0.46 | 0.81 | 0.490 | 8157 | 2 | ok |
| rbac_select_count | 0.33 | 0.76 | 0.372 | 10762 | 2 | ok |
| rbac_update_one | 0.46 | 0.98 | 0.506 | 7911 | 3 | ok |
| write_assign_role | 0.14 | 0.27 | 0.155 | 25738 | 1 | ok |
| share_list_objects | 0.29 | 0.39 | 0.275 | 14540 | 1 | ok |
| share_select_page | 0.64 | 1.32 | 0.710 | 5632 | 3 | ok |
| write_share | 0.06 | 0.25 | 0.109 | 36749 | 1 | ok |
| parents_proj_select_page | 0.73 | 1.17 | 0.777 | 5146 | 3 | ok |
| parents_proj_select_count | 1.09 | 2.37 | 1.275 | 3138 | 3 | ok |
| parents_select_page | 4.41 | 5.90 | 4.625 | 864 | 16 | ok |
| parents_select_count | 3.67 | 4.62 | 3.833 | 1043 | 14 | ok |
| write_nest_team | 0.69 | 0.78 | 0.681 | 5875 | 1 | ok |
| nest_check | 0.32 | 0.42 | 0.305 | 13114 | 1 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.55 | 3.9 | 10028 |
| sharing | 0.46 | 10.0 | 27752 |
| parents_proj | 0.05 | 10.6 | 29256 |
| parents | 3.73 | 46.4 | 129756 |
| nesting | 0.02 | 46.4 | 129761 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| ancestors | 0.02 MB, 0 rows | 0.26 MB, 519 rows | 0.26 MB, 519 rows | 0.41 MB, 1019 rows | 0.41 MB, 1023 rows |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| parents | 0.02 MB, 0 rows | 2.11 MB, 6197 rows | 2.27 MB, 6697 rows | 37.98 MB, 106697 rows | 37.98 MB, 106698 rows |
| policies | 0.08 MB, 6 rows | 0.08 MB, 8 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows |
| role_closure | 0.08 MB, 12 rows | 0.08 MB, 15 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows |
| role_grants | 3.56 MB, 10000 rows | 7.38 MB, 21000 rows | 7.73 MB, 22000 rows | 7.73 MB, 22000 rows | 7.73 MB, 22000 rows |
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
- vs design a (2026-10-30 16:03): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 00:18): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design d (2026-10-30 16:01): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.746..3.510 rows=50.00 loops=1)
  Buffers: shared hit=2352 read=8
  InitPlan 1
    ->  Result (actual time=2.694..2.695 rows=2.00 loops=1)
          Buffers: shared hit=875
          ->  ProjectSet (actual time=2.693..2.693 rows=2.00 loops=1)
                Buffers: shared hit=875
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.746..3.507 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2352 read=8
Planning:
  Buffers: shared hit=112
Planning Time: 0.145 ms
Execution Time: 3.725 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=3.213..3.918 rows=50.00 loops=1)
  Buffers: shared hit=2387 read=4
  InitPlan 1
    ->  Result (actual time=2.948..2.948 rows=2.00 loops=1)
          Buffers: shared hit=884
          ->  ProjectSet (actual time=2.947..2.947 rows=2.00 loops=1)
                Buffers: shared hit=884
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.213..0.215 rows=7.00 loops=1)
          Buffers: shared hit=22
          ->  ProjectSet (actual time=0.212..0.213 rows=7.00 loops=1)
                Buffers: shared hit=22
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.212..3.915 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2387 read=4
Planning:
  Buffers: shared hit=117
Planning Time: 0.161 ms
Execution Time: 4.104 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=4.251..5.055 rows=50.00 loops=1)
  Buffers: shared hit=2412 read=4
  InitPlan 1
    ->  Result (actual time=3.998..4.000 rows=7.00 loops=1)
          Buffers: shared hit=896
          ->  ProjectSet (actual time=3.997..3.998 rows=7.00 loops=1)
                Buffers: shared hit=896
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.187..0.193 rows=20.00 loops=1)
          Buffers: shared hit=35
          ->  ProjectSet (actual time=0.187..0.188 rows=20.00 loops=1)
                Buffers: shared hit=35
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=4.250..5.051 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2412 read=4
Planning:
  Buffers: shared hit=114
Planning Time: 0.181 ms
Execution Time: 5.269 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=8.821..8.824 rows=50.00 loops=1)
  Buffers: shared hit=2588
  InitPlan 1
    ->  Result (actual time=4.710..5.776 rows=4007.00 loops=1)
          Buffers: shared hit=1035
          ->  ProjectSet (actual time=4.709..4.845 rows=4007.00 loops=1)
                Buffers: shared hit=1035
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Sort (actual time=8.820..8.821 rows=50.00 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=2588
        ->  Bitmap Heap Scan on documents (actual time=7.460..8.595 rows=4007.00 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1136
              Buffers: shared hit=2585
              ->  Bitmap Index Scan on documents_pkey (actual time=7.387..7.387 rows=4007.00 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Index Searches: 15
                    Buffers: shared hit=1449
Planning:
  Buffers: shared hit=111
Planning Time: 0.164 ms
Execution Time: 9.028 ms
```

