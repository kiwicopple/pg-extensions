# Benchmark: pg_permissions--0.0.1 (design d), medium scale, default shape

- Date: 2026-10-30 16:01
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.15 | 0.38 | 0.175 | 22915 | 1 | ok |
| rbac_select_page | 0.38 | 0.95 | 0.433 | 9236 | 2 | ok |
| rbac_select_count | 0.30 | 0.45 | 0.291 | 13741 | 2 | ok |
| rbac_update_one | 0.27 | 0.46 | 0.284 | 14091 | 3 | ok |
| write_assign_role | 0.13 | 0.23 | 0.139 | 28738 | 1 | ok |
| share_list_objects | 0.28 | 0.37 | 0.260 | 15379 | 1 | ok |
| share_select_page | 0.57 | 1.18 | 0.680 | 5882 | 3 | ok |
| write_share | 0.15 | 0.27 | 0.158 | 25346 | 1 | ok |
| parents_proj_select_page | 0.64 | 0.84 | 0.649 | 6164 | 3 | ok |
| parents_proj_select_count | 0.95 | 1.31 | 0.983 | 4070 | 3 | ok |
| parents_select_page | 0.61 | 1.43 | 0.735 | 5441 | 16 | ok |
| parents_select_count | 0.91 | 1.42 | 0.986 | 4057 | 14 | ok |
| write_nest_team | 0.15 | 0.26 | 0.164 | 24407 | 1 | ok |
| nest_check | 0.38 | 0.51 | 0.370 | 10801 | 1 | ok |
| plain_list_objects | 0.29 | 0.52 | 0.307 | 13030 | - | - |
| cond_list_objects | 0.46 | 0.87 | 0.509 | 7856 | - | - |
| cond_select_page | 0.85 | 2.19 | 1.084 | 3691 | - | - |
| cond_nest_check | 0.57 | 1.29 | 0.678 | 5897 | - | - |
| plain_list_users | 0.31 | 1.74 | 0.582 | 6870 | - | - |
| cond_list_users | 0.46 | 2.13 | 0.781 | 5119 | - | - |
| block_list_objects | 0.37 | 0.88 | 0.439 | 9119 | - | - |
| block_or_mute_list_objects | 0.59 | 1.08 | 0.632 | 6331 | - | - |
| intersect_list_objects | 0.41 | 1.10 | 0.563 | 7110 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.44 | 3.0 | 10015 |
| sharing | 0.59 | 9.6 | 27286 |
| parents_proj | 0.03 | 10.0 | 28286 |
| parents | 1.43 | 40.6 | 128286 |
| nesting | 0.01 | 40.6 | 128287 |
| conditions | 0.59 | 43.5 | 135603 |
| blocklist | 0.48 | 47.2 | 145838 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting | after conditions | after blocklist |
| --- | --- | --- | --- | --- | --- | --- | --- |
| fga_computed_closure | 0.02 MB, 0 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 3 rows | 0.08 MB, 11 rows |
| fga_conditions | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.06 MB, 1 rows | 0.06 MB, 2 rows |
| fga_edges | 0.02 MB, 0 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 24 rows | 0.08 MB, 45 rows |
| fga_models | 0.02 MB, 0 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 2 rows | 0.08 MB, 3 rows |
| fga_paths | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 33 rows | 0.06 MB, 78 rows |
| fga_reach | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 33 rows | 0.06 MB, 75 rows |
| fga_relations | 0.02 MB, 0 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 12 rows | 0.06 MB, 24 rows |
| fga_rewrite_nodes | 0.02 MB, 0 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 21 rows | 0.06 MB, 47 rows |
| fga_tuples | 0.04 MB, 0 rows | 6.14 MB, 17197 rows | 6.50 MB, 18197 rows | 37.08 MB, 118197 rows | 37.08 MB, 118198 rows | 39.99 MB, 125396 rows | 43.70 MB, 135396 rows |
| fga_type_restrictions | 0.02 MB, 0 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 18 rows | 0.06 MB, 31 rows |
| fga_types | 0.02 MB, 0 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 9 rows | 0.06 MB, 14 rows |
| fga_walk_steps | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 36 rows | 0.07 MB, 97 rows |
| rbac_assignments | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows |
| rbac_role_closure | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows |
| rbac_role_inherits | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows |
| rbac_role_permissions | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |

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
| conditions | 1 | 4007 | a72affb8dac9720afe47ed798856f486 |
| conditions | 2 | 4007 | a2907603023a122749a3257a6b76c92e |
| conditions | 3 | 4012 | dd7a7ecbdd714a8dc57fa5f0f8e69c8c |
| conditions | 5 | 4212 | a570b2a32be579248c09197f56dca5bb |
| conditions | 10 | 4210 | 08d4ebfb3b09329146de3fdac7fc86f1 |
| conditions | 77 | 4022 | 992b5588b0acef0e5f01285d911f79da |
| conditions | 500 | 4220 | 5fee4f97891d7a79d09e06a8208212c2 |
| conditions | 5000 | 4206 | a4e9098b3f0f4616a3bb53336e12c394 |

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-29 00:12): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-29 00:15): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 00:18): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.677..1.354 rows=50.00 loops=1)
  Buffers: shared hit=1930 read=8
  InitPlan 1
    ->  Result (actual time=0.629..0.630 rows=2.00 loops=1)
          Buffers: shared hit=453
          ->  ProjectSet (actual time=0.628..0.629 rows=2.00 loops=1)
                Buffers: shared hit=453
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.676..1.350 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=1930 read=8
Planning:
  Buffers: shared hit=112
Planning Time: 0.164 ms
Execution Time: 1.542 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=3.086..3.777 rows=50.00 loops=1)
  Buffers: shared hit=3013 read=4
  InitPlan 1
    ->  Result (actual time=2.739..2.742 rows=7.00 loops=1)
          Buffers: shared hit=1317
          ->  ProjectSet (actual time=2.739..2.739 rows=7.00 loops=1)
                Buffers: shared hit=1317
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.293..0.294 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=0.292..0.293 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.085..3.774 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=3013 read=4
Planning:
  Buffers: shared hit=117
Planning Time: 0.185 ms
Execution Time: 3.966 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.136..3.900 rows=50.00 loops=1)
  Buffers: shared hit=3022 read=4
  InitPlan 1
    ->  Result (actual time=2.678..2.681 rows=7.00 loops=1)
          Buffers: shared hit=1318
          ->  ProjectSet (actual time=2.677..2.678 rows=7.00 loops=1)
                Buffers: shared hit=1318
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.102..0.102 rows=0.00 loops=1)
          Buffers: shared hit=9
          ->  ProjectSet (actual time=0.102..0.102 rows=0.00 loops=1)
                Buffers: shared hit=9
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.305..0.306 rows=2.00 loops=1)
          Buffers: shared hit=213
          ->  ProjectSet (actual time=0.304..0.305 rows=2.00 loops=1)
                Buffers: shared hit=213
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.135..3.895 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=3022 read=4
Planning:
  Buffers: shared hit=120
Planning Time: 0.188 ms
Execution Time: 4.139 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=2.921..3.726 rows=50.00 loops=1)
  Buffers: shared hit=3014 read=3
  InitPlan 1
    ->  Result (actual time=2.564..2.567 rows=7.00 loops=1)
          Buffers: shared hit=1317
          ->  ProjectSet (actual time=2.563..2.563 rows=7.00 loops=1)
                Buffers: shared hit=1317
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.304..0.305 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=0.304..0.304 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.920..3.722 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=3014 read=3
Planning:
  Buffers: shared hit=117
Planning Time: 0.184 ms
Execution Time: 3.955 ms
```

