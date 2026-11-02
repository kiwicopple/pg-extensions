# Benchmark: opt3-covering-01b9fc2 (design d), medium scale, wide shape

- Date: 2026-10-30 10:45
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.21 | 0.42 | 0.240 | 16687 | 1 | ok |
| rbac_select_page | 0.40 | 0.74 | 0.438 | 9133 | 2 | ok |
| rbac_select_count | 0.33 | 0.66 | 0.378 | 10581 | 2 | ok |
| rbac_update_one | 0.28 | 0.58 | 0.318 | 12584 | 3 | ok |
| write_assign_role | 0.15 | 0.36 | 0.187 | 21348 | 1 | ok |
| share_list_objects | 4.85 | 7.56 | 5.304 | 754 | 13 | ok |
| share_select_page | 11.89 | 17.58 | 12.755 | 313 | 42 | ok |
| write_share | 0.17 | 0.39 | 0.202 | 19788 | 1 | ok |
| parents_proj_select_page | 11.61 | 18.76 | 12.600 | 317 | 51 | ok |
| parents_proj_select_count | 9.13 | 13.18 | 9.845 | 406 | 31 | ok |
| parents_select_page | 11.86 | 18.09 | 12.739 | 314 | 46 | ok |
| parents_select_count | 9.54 | 18.77 | 11.205 | 356 | 40 | ok |
| write_nest_team | 0.16 | 0.32 | 0.183 | 21891 | 1 | ok |
| nest_check | 0.40 | 0.83 | 0.454 | 8818 | 2 | ok |
| plain_list_objects | 5.15 | 8.62 | 5.712 | 700 | - | - |
| cond_list_objects | 14.77 | 28.22 | 16.768 | 238 | - | - |
| cond_select_page | 19.39 | 29.27 | 20.909 | 191 | - | - |
| cond_nest_check | 0.57 | 1.18 | 0.660 | 6064 | - | - |
| plain_list_users | 1.12 | 16.36 | 3.562 | 1122 | - | - |
| cond_list_users | 1.59 | 19.41 | 4.828 | 828 | - | - |
| block_list_objects | 5.04 | 8.02 | 5.562 | 719 | - | - |
| block_or_mute_list_objects | 7.57 | 11.42 | 8.224 | 486 | - | - |
| intersect_list_objects | 6.41 | 10.79 | 7.172 | 557 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.58 | 3.0 | 10015 |
| sharing | 7.24 | 129.2 | 311886 |
| parents_proj | 0.05 | 129.6 | 312886 |
| parents | 1.74 | 171.9 | 412886 |
| nesting | 0.02 | 171.9 | 412887 |
| conditions | 18.85 | 307.4 | 704803 |
| blocklist | 2.48 | 311.5 | 715038 |

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
| fga_tuples | 0.04 MB, 0 rows | 125.70 MB, 301797 rows | 126.09 MB, 302797 rows | 168.45 MB, 402797 rows | 168.45 MB, 402798 rows | 303.88 MB, 694596 rows | 307.98 MB, 704596 rows |
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
- vs design a (2026-10-29 12:51): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-29 13:17): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 12:57): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.779..1.579 rows=50.00 loops=1)
  Buffers: shared hit=1930 read=8
  InitPlan 1
    ->  Result (actual time=0.706..0.707 rows=2.00 loops=1)
          Buffers: shared hit=453
          ->  ProjectSet (actual time=0.706..0.706 rows=2.00 loops=1)
                Buffers: shared hit=453
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.778..1.576 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=1930 read=8
Planning:
  Buffers: shared hit=112
Planning Time: 0.160 ms
Execution Time: 1.790 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=11.585..17.361 rows=50.00 loops=1)
  Buffers: shared hit=3065
  InitPlan 1
    ->  Result (actual time=9.176..10.888 rows=6652.00 loops=1)
          Buffers: shared hit=2309
          ->  ProjectSet (actual time=9.175..9.444 rows=6652.00 loops=1)
                Buffers: shared hit=2309
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.373..0.374 rows=2.00 loops=1)
          Buffers: shared hit=213
          ->  ProjectSet (actual time=0.372..0.373 rows=2.00 loops=1)
                Buffers: shared hit=213
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=11.584..17.355 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=3065
Planning:
  Buffers: shared hit=115
Planning Time: 0.225 ms
Execution Time: 17.657 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=11.572..17.961 rows=50.00 loops=1)
  Buffers: shared hit=3074
  InitPlan 1
    ->  Result (actual time=8.457..10.523 rows=6652.00 loops=1)
          Buffers: shared hit=2308
          ->  ProjectSet (actual time=8.455..8.752 rows=6652.00 loops=1)
                Buffers: shared hit=2308
                ->  Result (actual time=0.000..0.001 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.211..0.212 rows=0.00 loops=1)
          Buffers: shared hit=9
          ->  ProjectSet (actual time=0.211..0.211 rows=0.00 loops=1)
                Buffers: shared hit=9
                ->  Result (actual time=0.000..0.001 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.453..0.454 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=0.452..0.453 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=11.570..17.953 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=3074
Planning:
  Buffers: shared hit=120
Planning Time: 0.211 ms
Execution Time: 18.439 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=9.764..15.647 rows=50.00 loops=1)
  Buffers: shared hit=3358
  InitPlan 1
    ->  Result (actual time=7.378..9.120 rows=6652.00 loops=1)
          Buffers: shared hit=2602
          ->  ProjectSet (actual time=7.377..7.633 rows=6652.00 loops=1)
                Buffers: shared hit=2602
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.325..0.326 rows=2.00 loops=1)
          Buffers: shared hit=213
          ->  ProjectSet (actual time=0.324..0.325 rows=2.00 loops=1)
                Buffers: shared hit=213
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=9.763..15.642 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=3358
Planning:
  Buffers: shared hit=117
Planning Time: 0.218 ms
Execution Time: 15.899 ms
```

