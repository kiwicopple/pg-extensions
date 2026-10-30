# Benchmark: opt3-before-0bd650b (design d), medium scale, wide shape

- Date: 2026-10-30 11:26
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.22 | 0.31 | 0.218 | 18356 | 1 | ok |
| rbac_select_page | 0.40 | 0.58 | 0.407 | 9830 | 2 | ok |
| rbac_select_count | 0.31 | 0.44 | 0.306 | 13087 | 2 | ok |
| rbac_update_one | 0.27 | 0.36 | 0.269 | 14886 | 3 | ok |
| write_assign_role | 0.14 | 0.21 | 0.146 | 27421 | 1 | ok |
| share_list_objects | 4.93 | 6.42 | 5.149 | 776 | 13 | ok |
| share_select_page | 11.30 | 21.61 | 13.315 | 300 | 42 | ok |
| write_share | 0.25 | 0.37 | 0.259 | 15418 | 1 | ok |
| parents_proj_select_page | 11.24 | 20.37 | 12.343 | 324 | 51 | ok |
| parents_proj_select_count | 9.06 | 11.05 | 9.287 | 430 | 31 | ok |
| parents_select_page | 11.17 | 20.79 | 12.370 | 323 | 46 | ok |
| parents_select_count | 8.98 | 11.80 | 9.362 | 427 | 40 | ok |
| write_nest_team | 0.26 | 0.36 | 0.259 | 15442 | 1 | ok |
| nest_check | 0.47 | 0.65 | 0.466 | 8585 | 2 | ok |
| plain_list_objects | 5.04 | 6.54 | 5.297 | 755 | - | - |
| cond_list_objects | 14.79 | 20.45 | 15.697 | 254 | - | - |
| cond_select_page | 21.19 | 26.96 | 21.960 | 182 | - | - |
| cond_nest_check | 0.63 | 0.80 | 0.632 | 6329 | - | - |
| plain_list_users | 0.99 | 16.26 | 3.430 | 1166 | - | - |
| cond_list_users | 1.42 | 20.35 | 4.460 | 896 | - | - |
| block_list_objects | 4.98 | 6.47 | 5.188 | 770 | - | - |
| block_or_mute_list_objects | 5246.18 | 5365.27 | 5319.417 | 0 | - | - |
| intersect_list_objects | 621.21 | 687.40 | 640.206 | 6 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.48 | 3.0 | 10015 |
| sharing | 13.61 | 92.4 | 311886 |
| parents_proj | 0.05 | 92.8 | 312886 |
| parents | 3.21 | 123.4 | 412886 |
| nesting | 0.02 | 123.4 | 412887 |
| conditions | 16.23 | 220.5 | 704803 |
| blocklist | 2.48 | 224.2 | 715038 |

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
| fga_tuples | 0.03 MB, 0 rows | 88.96 MB, 301797 rows | 89.35 MB, 302797 rows | 119.90 MB, 402797 rows | 119.90 MB, 402798 rows | 216.92 MB, 694596 rows | 220.64 MB, 704596 rows |
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
| sharing | 1 | 10386 | ab9080eadd0f4310f22e8646aa07e9f7 |
| sharing | 2 | 10386 | 53195b0cadf66821217c5baaeb534e0d |
| sharing | 3 | 10386 | d912a85300386da9bd80f68ad6ac4da9 |
| sharing | 5 | 10386 | 45c5a269bacc3af730141723ef2b1bdf |
| sharing | 10 | 10434 | 82e7ad21c3b542a37ba5f908ad207b45 |
| sharing | 77 | 10434 | 329e4d2d334c9f0f88c08dc92bf339d2 |
| sharing | 500 | 9906 | d19403d0d9a07365dac45f9ce2b732bb |
| sharing | 5000 | 10434 | 24f988700218cef00636ed9569e47122 |
| parents_proj | 1 | 10386 | ab9080eadd0f4310f22e8646aa07e9f7 |
| parents_proj | 2 | 10386 | 53195b0cadf66821217c5baaeb534e0d |
| parents_proj | 3 | 10386 | d912a85300386da9bd80f68ad6ac4da9 |
| parents_proj | 5 | 10568 | 2dc01b9dc66af4433be7eb9cb8228d04 |
| parents_proj | 10 | 10614 | 48acb4581e03ba1712c342d0cae9a6dc |
| parents_proj | 77 | 10434 | 329e4d2d334c9f0f88c08dc92bf339d2 |
| parents_proj | 500 | 10101 | 4a029273fb8c3704d6e82124e401382e |
| parents_proj | 5000 | 10629 | 24a6f04f9a473be6d8e3b84b232c110f |
| parents | 1 | 10386 | ab9080eadd0f4310f22e8646aa07e9f7 |
| parents | 2 | 10386 | 53195b0cadf66821217c5baaeb534e0d |
| parents | 3 | 10386 | d912a85300386da9bd80f68ad6ac4da9 |
| parents | 5 | 10568 | 2dc01b9dc66af4433be7eb9cb8228d04 |
| parents | 10 | 10614 | 48acb4581e03ba1712c342d0cae9a6dc |
| parents | 77 | 10434 | 329e4d2d334c9f0f88c08dc92bf339d2 |
| parents | 500 | 10101 | 4a029273fb8c3704d6e82124e401382e |
| parents | 5000 | 10629 | 24a6f04f9a473be6d8e3b84b232c110f |
| conditions | 1 | 10386 | ab9080eadd0f4310f22e8646aa07e9f7 |
| conditions | 2 | 10386 | 53195b0cadf66821217c5baaeb534e0d |
| conditions | 3 | 10386 | d912a85300386da9bd80f68ad6ac4da9 |
| conditions | 5 | 10568 | 2dc01b9dc66af4433be7eb9cb8228d04 |
| conditions | 10 | 10614 | 48acb4581e03ba1712c342d0cae9a6dc |
| conditions | 77 | 10434 | 329e4d2d334c9f0f88c08dc92bf339d2 |
| conditions | 500 | 10101 | 4a029273fb8c3704d6e82124e401382e |
| conditions | 5000 | 10629 | 24a6f04f9a473be6d8e3b84b232c110f |

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-30 11:05): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-30 11:08): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-30 11:11): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.873..1.611 rows=50.00 loops=1)
  Buffers: shared hit=1930 read=8
  InitPlan 1
    ->  Result (actual time=0.806..0.807 rows=2.00 loops=1)
          Buffers: shared hit=453
          ->  ProjectSet (actual time=0.805..0.805 rows=2.00 loops=1)
                Buffers: shared hit=453
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.872..1.608 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=1930 read=8
Planning:
  Buffers: shared hit=112
Planning Time: 0.147 ms
Execution Time: 1.805 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=10.698..16.170 rows=50.00 loops=1)
  Buffers: shared hit=9580
  InitPlan 1
    ->  Result (actual time=8.294..10.051 rows=6652.00 loops=1)
          Buffers: shared hit=8823
          ->  ProjectSet (actual time=8.292..8.527 rows=6652.00 loops=1)
                Buffers: shared hit=8823
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.327..0.328 rows=2.00 loops=1)
          Buffers: shared hit=213
          ->  ProjectSet (actual time=0.327..0.327 rows=2.00 loops=1)
                Buffers: shared hit=213
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=10.697..16.166 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=9580
Planning:
  Buffers: shared hit=115
Planning Time: 0.157 ms
Execution Time: 16.390 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=10.210..15.732 rows=50.00 loops=1)
  Buffers: shared hit=9590
  InitPlan 1
    ->  Result (actual time=7.763..9.498 rows=6652.00 loops=1)
          Buffers: shared hit=8823
          ->  ProjectSet (actual time=7.762..7.998 rows=6652.00 loops=1)
                Buffers: shared hit=8823
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.108..0.109 rows=0.00 loops=1)
          Buffers: shared hit=9
          ->  ProjectSet (actual time=0.108..0.108 rows=0.00 loops=1)
                Buffers: shared hit=9
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.294..0.295 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=0.293..0.294 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=10.210..15.728 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=9590
Planning:
  Buffers: shared hit=120
Planning Time: 0.179 ms
Execution Time: 15.948 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=10.696..16.266 rows=50.00 loops=1)
  Buffers: shared hit=9583
  InitPlan 1
    ->  Result (actual time=8.196..10.030 rows=6652.00 loops=1)
          Buffers: shared hit=8826
          ->  ProjectSet (actual time=8.195..8.470 rows=6652.00 loops=1)
                Buffers: shared hit=8826
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.338..0.339 rows=2.00 loops=1)
          Buffers: shared hit=213
          ->  ProjectSet (actual time=0.337..0.338 rows=2.00 loops=1)
                Buffers: shared hit=213
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=10.696..16.262 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=9583
Planning:
  Buffers: shared hit=115
Planning Time: 0.173 ms
Execution Time: 16.553 ms
```

