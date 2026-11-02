# Benchmark: c-compiled-model (design c), medium scale, default shape

- Date: 2026-10-30 16:08
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.24 | 0.35 | 0.235 | 17049 | 1 | ok |
| rbac_select_page | 0.41 | 0.56 | 0.414 | 9670 | 2 | ok |
| rbac_select_count | 0.33 | 0.44 | 0.312 | 12820 | 2 | ok |
| rbac_update_one | 0.34 | 0.47 | 0.328 | 12179 | 3 | ok |
| write_assign_role | 0.17 | 0.28 | 0.180 | 22171 | 1 | ok |
| share_list_objects | 0.25 | 0.33 | 0.236 | 16923 | 1 | ok |
| share_select_page | 0.54 | 0.75 | 0.550 | 7274 | 3 | ok |
| write_share | 0.17 | 0.34 | 0.191 | 20934 | 1 | ok |
| parents_proj_select_page | 0.65 | 1.74 | 0.832 | 4807 | 3 | ok |
| parents_proj_select_count | 0.91 | 1.51 | 0.996 | 4015 | 3 | ok |
| parents_select_page | 2.77 | 3.92 | 2.925 | 1367 | 16 | ok |
| parents_select_count | 2.03 | 2.54 | 2.097 | 1907 | 14 | ok |
| write_nest_team | 44.98 | 54.07 | 45.498 | 87 | 1 | OVER |
| nest_check | 0.29 | 0.38 | 0.280 | 14262 | 1 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.78 | 2.9 | 10053 |
| sharing | 0.95 | 10.4 | 46241 |
| parents_proj | 0.15 | 11.0 | 48260 |
| parents | 1.60 | 27.0 | 148260 |
| nesting | 0.03 | 27.8 | 152261 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| allowed_subjects | 0.05 MB, 6 rows | 0.05 MB, 12 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows |
| ancestors | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.16 MB, 500 rows | 0.16 MB, 500 rows | 0.16 MB, 500 rows |
| memberships | 0.02 MB, 0 rows | 3.45 MB, 18975 rows | 3.45 MB, 18975 rows | 3.45 MB, 18975 rows | 4.17 MB, 22975 rows |
| models | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| parent_types | 0.01 MB, 0 rows | 0.01 MB, 0 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows |
| parents | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.16 MB, 500 rows | 16.16 MB, 100500 rows | 16.16 MB, 100500 rows |
| relations | 0.08 MB, 14 rows | 0.08 MB, 17 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows |
| satisfies | 0.05 MB, 26 rows | 0.05 MB, 30 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows |
| tuples | 2.48 MB, 10000 rows | 6.63 MB, 27197 rows | 6.87 MB, 28197 rows | 6.87 MB, 28197 rows | 6.87 MB, 28198 rows |
| types | 0.08 MB, 3 rows | 0.08 MB, 5 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows |

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
- vs design b (2026-10-30 16:06): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design d (2026-10-30 16:01): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.474..3.253 rows=50.00 loops=1)
  Buffers: shared hit=2532 read=8
  InitPlan 1
    ->  Result (actual time=2.421..2.422 rows=2.00 loops=1)
          Buffers: shared hit=1055
          ->  ProjectSet (actual time=2.421..2.421 rows=2.00 loops=1)
                Buffers: shared hit=1055
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.474..3.249 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2532 read=8
Planning:
  Buffers: shared hit=112
Planning Time: 0.169 ms
Execution Time: 3.467 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.730..3.505 rows=50.00 loops=1)
  Buffers: shared hit=2602 read=4
  InitPlan 1
    ->  Result (actual time=2.276..2.277 rows=2.00 loops=1)
          Buffers: shared hit=1079
          ->  ProjectSet (actual time=2.275..2.276 rows=2.00 loops=1)
                Buffers: shared hit=1079
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.407..0.407 rows=1.00 loops=1)
          Buffers: shared hit=43
  ->  Index Scan using documents_pkey on documents (actual time=2.729..3.502 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2602 read=4
Planning:
  Buffers: shared hit=117
Planning Time: 0.180 ms
Execution Time: 3.712 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.617..3.406 rows=50.00 loops=1)
  Buffers: shared hit=2603 read=4
  InitPlan 1
    ->  Result (actual time=1.976..1.977 rows=1.00 loops=1)
          Buffers: shared hit=1023
  InitPlan 2
    ->  Result (actual time=0.584..0.584 rows=1.00 loops=1)
          Buffers: shared hit=100
  ->  Index Scan using documents_pkey on documents (actual time=2.616..3.403 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2603 read=4
Planning:
  Buffers: shared hit=108
Planning Time: 0.168 ms
Execution Time: 3.417 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=5.479..5.482 rows=50.00 loops=1)
  Buffers: shared hit=2690
  InitPlan 1
    ->  Result (actual time=2.962..2.962 rows=1.00 loops=1)
          Buffers: shared hit=1138
  ->  Sort (actual time=5.478..5.479 rows=50.00 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=2690
        ->  Bitmap Heap Scan on documents (actual time=4.129..5.254 rows=4007.00 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1135
              Buffers: shared hit=2687
              ->  Bitmap Index Scan on documents_pkey (actual time=4.054..4.054 rows=4007.00 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Index Searches: 15
                    Buffers: shared hit=1552
Planning:
  Buffers: shared hit=103
Planning Time: 0.147 ms
Execution Time: 5.497 ms
```

