# Benchmark: d-per-model (design d), medium scale, wide shape

- Date: 2026-10-29 18:46
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.23 | 0.33 | 0.231 | 17309 | 1 | ok |
| rbac_select_page | 0.40 | 0.56 | 0.394 | 10146 | 2 | ok |
| rbac_select_count | 0.32 | 0.45 | 0.316 | 12657 | 2 | ok |
| rbac_update_one | 0.28 | 0.38 | 0.269 | 14875 | 3 | ok |
| write_assign_role | 0.15 | 0.22 | 0.149 | 26856 | 1 | ok |
| share_list_objects | 5.12 | 7.32 | 5.417 | 738 | 13 | ok |
| share_select_page | 11.54 | 18.57 | 12.373 | 323 | 42 | ok |
| write_share | 0.23 | 0.35 | 0.234 | 17087 | 1 | ok |
| parents_proj_select_page | 10.87 | 16.71 | 11.478 | 348 | 51 | ok |
| parents_proj_select_count | 9.04 | 11.99 | 9.462 | 422 | 31 | ok |
| parents_select_page | 10.95 | 16.04 | 11.553 | 346 | 46 | ok |
| parents_select_count | 8.85 | 11.34 | 9.186 | 435 | 40 | ok |
| write_nest_team | 0.23 | 0.36 | 0.240 | 16685 | 1 | ok |
| nest_check | 0.44 | 0.69 | 0.449 | 8905 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.46 | 3.0 | 10015 |
| sharing | 11.26 | 81.6 | 311886 |
| parents_proj | 0.04 | 81.9 | 312886 |
| parents | 2.84 | 108.8 | 412886 |
| nesting | 0.02 | 108.8 | 412887 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| fga_computed_closure | 0.02 MB, 0 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows |
| fga_edges | 0.02 MB, 0 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows |
| fga_models | 0.02 MB, 0 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows |
| fga_paths | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows |
| fga_reach | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows |
| fga_relations | 0.02 MB, 0 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows |
| fga_rewrite_nodes | 0.02 MB, 0 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows |
| fga_tuples | 0.02 MB, 0 rows | 78.09 MB, 301797 rows | 78.44 MB, 302797 rows | 105.29 MB, 402797 rows | 105.29 MB, 402798 rows |
| fga_type_restrictions | 0.02 MB, 0 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows |
| fga_types | 0.02 MB, 0 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows |
| fga_walk_steps | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows |
| rbac_assignments | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows | 2.50 MB, 10000 rows |
| rbac_role_closure | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows |
| rbac_role_inherits | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows | 0.08 MB, 2 rows |
| rbac_role_permissions | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows | 0.08 MB, 4 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |

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

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-29 12:51): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-29 13:17): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 12:57): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.761..1.566 rows=50.00 loops=1)
  Buffers: shared hit=1930 read=8
  InitPlan 1
    ->  Result (actual time=0.701..0.702 rows=2.00 loops=1)
          Buffers: shared hit=453
          ->  ProjectSet (actual time=0.700..0.701 rows=2.00 loops=1)
                Buffers: shared hit=453
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.761..1.563 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=1930 read=8
Planning:
  Buffers: shared hit=112
Planning Time: 0.145 ms
Execution Time: 1.775 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=9.805..15.359 rows=50.00 loops=1)
  Buffers: shared hit=9490
  InitPlan 1
    ->  Result (actual time=7.438..9.199 rows=6652.00 loops=1)
          Buffers: shared hit=8733
          ->  ProjectSet (actual time=7.437..7.644 rows=6652.00 loops=1)
                Buffers: shared hit=8733
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.308..0.309 rows=2.00 loops=1)
          Buffers: shared hit=213
          ->  ProjectSet (actual time=0.308..0.308 rows=2.00 loops=1)
                Buffers: shared hit=213
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=9.805..15.355 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=9490
Planning:
  Buffers: shared hit=117
Planning Time: 0.154 ms
Execution Time: 15.585 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=9.566..15.176 rows=50.00 loops=1)
  Buffers: shared hit=9500
  InitPlan 1
    ->  Result (actual time=7.078..8.822 rows=6652.00 loops=1)
          Buffers: shared hit=8733
          ->  ProjectSet (actual time=7.076..7.295 rows=6652.00 loops=1)
                Buffers: shared hit=8733
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.106..0.107 rows=0.00 loops=1)
          Buffers: shared hit=9
          ->  ProjectSet (actual time=0.106..0.106 rows=0.00 loops=1)
                Buffers: shared hit=9
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.332..0.332 rows=2.00 loops=1)
          Buffers: shared hit=214
          ->  ProjectSet (actual time=0.331..0.331 rows=2.00 loops=1)
                Buffers: shared hit=214
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=9.565..15.171 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=9500
Planning:
  Buffers: shared hit=120
Planning Time: 0.170 ms
Execution Time: 15.406 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=9.882..15.452 rows=50.00 loops=1)
  Buffers: shared hit=9493
  InitPlan 1
    ->  Result (actual time=7.462..9.262 rows=6652.00 loops=1)
          Buffers: shared hit=8736
          ->  ProjectSet (actual time=7.461..7.683 rows=6652.00 loops=1)
                Buffers: shared hit=8736
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.309..0.310 rows=2.00 loops=1)
          Buffers: shared hit=213
          ->  ProjectSet (actual time=0.309..0.309 rows=2.00 loops=1)
                Buffers: shared hit=213
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=9.881..15.448 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=9493
Planning:
  Buffers: shared hit=115
Planning Time: 0.168 ms
Execution Time: 15.671 ms
```

