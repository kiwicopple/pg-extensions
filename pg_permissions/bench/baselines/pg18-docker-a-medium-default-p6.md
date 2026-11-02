# Benchmark: a-tuple-core (design a), medium scale, default shape

- Date: 2026-10-30 16:03
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.28 | 0.67 | 0.312 | 12831 | 1 | ok |
| rbac_select_page | 0.43 | 1.12 | 0.514 | 7786 | 2 | ok |
| rbac_select_count | 0.34 | 0.59 | 0.345 | 11585 | 2 | ok |
| rbac_update_one | 0.53 | 1.49 | 0.683 | 5857 | 3 | ok |
| write_assign_role | 0.16 | 0.33 | 0.180 | 22266 | 1 | ok |
| share_list_objects | 0.29 | 0.47 | 0.280 | 14296 | 1 | ok |
| share_select_page | 0.65 | 1.14 | 0.709 | 5641 | 3 | ok |
| write_share | 0.15 | 0.26 | 0.154 | 26021 | 1 | ok |
| parents_proj_select_page | 0.86 | 1.15 | 0.880 | 4546 | 3 | ok |
| parents_proj_select_count | 1.16 | 1.62 | 1.200 | 3332 | 3 | ok |
| parents_select_page | 7.26 | 10.27 | 7.719 | 518 | 16 | ok |
| parents_select_count | 6.26 | 8.19 | 6.553 | 610 | 14 | ok |
| write_nest_team | 0.15 | 0.22 | 0.150 | 26722 | 1 | ok |
| nest_check | 0.34 | 0.46 | 0.326 | 12263 | 1 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.60 | 3.6 | 10020 |
| sharing | 0.42 | 9.5 | 27222 |
| parents_proj | 0.05 | 10.1 | 28725 |
| parents | 2.17 | 48.6 | 128726 |
| nesting | 0.02 | 48.6 | 128727 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| object_types | 0.06 MB, 3 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |
| relations | 0.06 MB, 14 rows | 0.06 MB, 17 rows | 0.06 MB, 19 rows | 0.06 MB, 20 rows | 0.06 MB, 20 rows |
| tuples | 3.44 MB, 10000 rows | 9.34 MB, 27197 rows | 9.85 MB, 28697 rows | 48.39 MB, 128697 rows | 48.39 MB, 128698 rows |

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
- vs design b (2026-10-29 00:15): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 00:18): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design d (2026-10-30 16:01): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.211..3.043 rows=50.00 loops=1)
  Buffers: shared hit=2179 read=8
  InitPlan 1
    ->  Result (actual time=2.140..2.142 rows=2.00 loops=1)
          Buffers: shared hit=702
          ->  ProjectSet (actual time=2.139..2.140 rows=2.00 loops=1)
                Buffers: shared hit=702
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.210..3.040 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2179 read=8
Planning:
  Buffers: shared hit=112
Planning Time: 0.175 ms
Execution Time: 3.266 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.210..3.194 rows=50.00 loops=1)
  Buffers: shared hit=2258 read=4
  InitPlan 1
    ->  Result (actual time=1.952..1.953 rows=2.00 loops=1)
          Buffers: shared hit=716
          ->  ProjectSet (actual time=1.950..1.951 rows=2.00 loops=1)
                Buffers: shared hit=716
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.180..0.183 rows=7.00 loops=1)
          Buffers: shared hit=60
          ->  ProjectSet (actual time=0.179..0.180 rows=7.00 loops=1)
                Buffers: shared hit=60
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.209..3.190 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2258 read=4
Planning:
  Buffers: shared hit=117
Planning Time: 0.273 ms
Execution Time: 3.484 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.137..3.021 rows=50.00 loops=1)
  Buffers: shared hit=2481 read=4
  InitPlan 1
    ->  Result (actual time=1.853..1.856 rows=7.00 loops=1)
          Buffers: shared hit=826
          ->  ProjectSet (actual time=1.853..1.853 rows=7.00 loops=1)
                Buffers: shared hit=826
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.209..0.214 rows=20.00 loops=1)
          Buffers: shared hit=173
          ->  ProjectSet (actual time=0.208..0.209 rows=20.00 loops=1)
                Buffers: shared hit=173
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.137..3.017 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2481 read=4
Planning:
  Buffers: shared hit=114
Planning Time: 0.240 ms
Execution Time: 3.288 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=9.698..9.702 rows=50.00 loops=1)
  Buffers: shared hit=6487
  InitPlan 1
    ->  Result (actual time=5.856..6.908 rows=4007.00 loops=1)
          Buffers: shared hit=4937
          ->  ProjectSet (actual time=5.855..5.980 rows=4007.00 loops=1)
                Buffers: shared hit=4937
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Sort (actual time=9.698..9.699 rows=50.00 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=6487
        ->  Bitmap Heap Scan on documents (actual time=8.547..9.491 rows=4007.00 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1133
              Buffers: shared hit=6484
              ->  Bitmap Index Scan on documents_pkey (actual time=8.477..8.477 rows=4007.00 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Index Searches: 15
                    Buffers: shared hit=5351
Planning:
  Buffers: shared hit=109
Planning Time: 0.142 ms
Execution Time: 9.890 ms
```

