# Benchmark: d-per-model (design d), medium scale, wide shape

- Date: 2026-10-29 17:38
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.21 | 0.31 | 0.213 | 18784 | 1 | ok |
| rbac_select_page | 0.40 | 0.61 | 0.409 | 9785 | 2 | ok |
| rbac_select_count | 0.31 | 0.46 | 0.317 | 12602 | 2 | ok |
| rbac_update_one | 0.27 | 0.48 | 0.297 | 13488 | 3 | ok |
| write_assign_role | 0.14 | 0.25 | 0.156 | 25674 | 1 | ok |
| share_list_objects | 17.77 | 37.11 | 20.681 | 193 | 13 | OVER |
| share_select_page | 26.20 | 49.49 | 30.555 | 130 | 42 | OVER |
| write_share | 0.23 | 0.32 | 0.229 | 17467 | 1 | ok |
| parents_proj_select_page | 38.63 | 51.14 | 40.810 | 98 | 51 | OVER |
| parents_proj_select_count | 36.07 | 42.51 | 36.954 | 108 | 31 | OVER |
| parents_select_page | 23.56 | 34.94 | 25.695 | 155 | 46 | ok |
| parents_select_count | 21.58 | 27.57 | 22.636 | 176 | 40 | ok |
| write_nest_team | 0.23 | 0.30 | 0.229 | 17449 | 1 | ok |
| nest_check | 0.45 | 0.96 | 0.513 | 7804 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.45 | 3.0 | 10015 |
| sharing | 13.26 | 81.4 | 311860 |
| parents_proj | 0.05 | 81.8 | 312860 |
| parents | 3.18 | 108.6 | 412860 |
| nesting | 0.01 | 108.6 | 412861 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| fga_computed_closure | 0.02 MB, 0 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows |
| fga_edges | 0.02 MB, 0 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows | 0.08 MB, 9 rows |
| fga_models | 0.02 MB, 0 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows | 0.08 MB, 1 rows |
| fga_paths | 0.02 MB, 0 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows | 0.06 MB, 13 rows |
| fga_relations | 0.02 MB, 0 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows |
| fga_rewrite_nodes | 0.02 MB, 0 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows | 0.06 MB, 8 rows |
| fga_tuples | 0.02 MB, 0 rows | 78.09 MB, 301797 rows | 78.44 MB, 302797 rows | 105.29 MB, 402797 rows | 105.29 MB, 402798 rows |
| fga_type_restrictions | 0.02 MB, 0 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows | 0.06 MB, 7 rows |
| fga_types | 0.02 MB, 0 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows | 0.06 MB, 4 rows |
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
Limit (actual time=0.855..1.535 rows=50.00 loops=1)
  Buffers: shared hit=1930 read=8
  InitPlan 1
    ->  Result (actual time=0.772..0.773 rows=2.00 loops=1)
          Buffers: shared hit=453
          ->  ProjectSet (actual time=0.771..0.772 rows=2.00 loops=1)
                Buffers: shared hit=453
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.854..1.532 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=1930 read=8
Planning:
  Buffers: shared hit=112
Planning Time: 0.159 ms
Execution Time: 1.742 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=21.501..27.226 rows=50.00 loops=1)
  Buffers: shared hit=16078
  InitPlan 1
    ->  Result (actual time=19.177..20.895 rows=6652.00 loops=1)
          Buffers: shared hit=15327
          ->  ProjectSet (actual time=19.176..19.408 rows=6652.00 loops=1)
                Buffers: shared hit=15327
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.307..0.307 rows=2.00 loops=1)
          Buffers: shared hit=207
          ->  ProjectSet (actual time=0.306..0.306 rows=2.00 loops=1)
                Buffers: shared hit=207
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=21.501..27.222 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=16078
Planning:
  Buffers: shared hit=117
Planning Time: 0.152 ms
Execution Time: 27.482 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=38.035..43.736 rows=50.00 loops=1)
  Buffers: shared hit=30226
  InitPlan 1
    ->  Result (actual time=20.599..22.376 rows=6652.00 loops=1)
          Buffers: shared hit=15327
          ->  ProjectSet (actual time=20.597..20.813 rows=6652.00 loops=1)
                Buffers: shared hit=15327
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=14.892..14.892 rows=0.00 loops=1)
          Buffers: shared hit=14147
          ->  ProjectSet (actual time=14.891..14.891 rows=0.00 loops=1)
                Buffers: shared hit=14147
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 3
    ->  Result (actual time=0.456..0.457 rows=2.00 loops=1)
          Buffers: shared hit=208
          ->  ProjectSet (actual time=0.454..0.455 rows=2.00 loops=1)
                Buffers: shared hit=208
                ->  Result (actual time=0.000..0.001 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=38.034..43.731 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)) OR (org_id = ANY ((InitPlan 3).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=30226
Planning:
  Buffers: shared hit=118
Planning Time: 0.193 ms
Execution Time: 44.146 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=22.666..28.594 rows=50.00 loops=1)
  Buffers: shared hit=16075
  InitPlan 1
    ->  Result (actual time=20.303..22.032 rows=6652.00 loops=1)
          Buffers: shared hit=15324
          ->  ProjectSet (actual time=20.302..20.529 rows=6652.00 loops=1)
                Buffers: shared hit=15324
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.335..0.336 rows=2.00 loops=1)
          Buffers: shared hit=207
          ->  ProjectSet (actual time=0.335..0.335 rows=2.00 loops=1)
                Buffers: shared hit=207
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=22.666..28.590 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (org_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=16075
Planning:
  Buffers: shared hit=115
Planning Time: 0.166 ms
Execution Time: 28.839 ms
```

