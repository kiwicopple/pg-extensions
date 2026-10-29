# Benchmark: c-compiled-model (design c), medium scale, wide shape

- Date: 2026-10-29 12:57
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.24 | 0.35 | 0.248 | 16110 | 1 | ok |
| rbac_select_page | 0.44 | 0.61 | 0.451 | 8872 | 2 | ok |
| rbac_select_count | 0.33 | 0.43 | 0.312 | 12820 | 2 | ok |
| rbac_update_one | 0.38 | 0.49 | 0.360 | 11116 | 3 | ok |
| write_assign_role | 0.18 | 0.26 | 0.186 | 21520 | 1 | ok |
| share_list_objects | 3.41 | 3.87 | 3.460 | 1156 | 13 | ok |
| share_select_page | 8.20 | 16.47 | 8.968 | 446 | 42 | ok |
| write_share | 0.17 | 0.24 | 0.179 | 22407 | 1 | ok |
| parents_proj_select_page | 8.73 | 18.83 | 10.209 | 391 | 51 | ok |
| parents_proj_select_count | 6.33 | 7.17 | 6.459 | 619 | 31 | ok |
| parents_select_page | 8.06 | 10.65 | 8.504 | 470 | 46 | ok |
| parents_select_count | 6.61 | 7.48 | 6.748 | 592 | 40 | ok |
| write_nest_team | 61.23 | 73.27 | 62.040 | 64 | 1 | OVER |
| nest_check | 0.31 | 0.44 | 0.310 | 12919 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.84 | 2.9 | 10053 |
| sharing | 24.71 | 191.6 | 969122 |
| parents_proj | 0.20 | 192.2 | 971141 |
| parents | 1.65 | 208.2 | 1071141 |
| nesting | 0.04 | 209.1 | 1076142 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| allowed_subjects | 0.05 MB, 6 rows | 0.05 MB, 12 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows |
| ancestors | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.16 MB, 500 rows | 0.16 MB, 500 rows | 0.16 MB, 500 rows |
| memberships | 0.02 MB, 0 rows | 116.80 MB, 657256 rows | 116.80 MB, 657256 rows | 116.80 MB, 657256 rows | 117.69 MB, 662256 rows |
| models | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| parent_types | 0.01 MB, 0 rows | 0.01 MB, 0 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows |
| parents | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.16 MB, 500 rows | 16.16 MB, 100500 rows | 16.16 MB, 100500 rows |
| relations | 0.08 MB, 14 rows | 0.08 MB, 17 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows |
| satisfies | 0.05 MB, 26 rows | 0.05 MB, 30 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows |
| tuples | 2.48 MB, 10000 rows | 74.42 MB, 311797 rows | 74.67 MB, 312797 rows | 74.67 MB, 312797 rows | 74.67 MB, 312798 rows |
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
- vs design b (2026-10-29 12:54): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.795..4.389 rows=50.00 loops=1)
  Buffers: shared hit=2532 read=8
  InitPlan 1
    ->  Result (actual time=2.682..2.684 rows=2.00 loops=1)
          Buffers: shared hit=1055
          ->  ProjectSet (actual time=2.682..2.682 rows=2.00 loops=1)
                Buffers: shared hit=1055
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.795..4.385 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2532 read=8
Planning:
  Buffers: shared hit=112
Planning Time: 0.369 ms
Execution Time: 4.822 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=11.889..17.709 rows=50.00 loops=1)
  Buffers: shared hit=4582
  InitPlan 1
    ->  Result (actual time=7.874..7.876 rows=2.00 loops=1)
          Buffers: shared hit=2757
          ->  ProjectSet (actual time=7.872..7.874 rows=2.00 loops=1)
                Buffers: shared hit=2757
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=3.879..3.879 rows=1.00 loops=1)
          Buffers: shared hit=1281
  ->  Index Scan using documents_pkey on documents (actual time=11.888..17.704 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=4582
Planning:
  Buffers: shared hit=115
Planning Time: 0.176 ms
Execution Time: 18.106 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=8.291..13.954 rows=50.00 loops=1)
  Buffers: shared hit=3757
  InitPlan 1
    ->  Result (actual time=5.495..5.495 rows=1.00 loops=1)
          Buffers: shared hit=2268
  InitPlan 2
    ->  Result (actual time=2.664..2.664 rows=1.00 loops=1)
          Buffers: shared hit=945
  ->  Index Scan using documents_pkey on documents (actual time=8.290..13.950 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=3757
Planning:
  Buffers: shared hit=106
Planning Time: 0.149 ms
Execution Time: 13.971 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=13.110..13.114 rows=50.00 loops=1)
  Buffers: shared hit=3525
  InitPlan 1
    ->  Result (actual time=8.495..8.495 rows=1.00 loops=1)
          Buffers: shared hit=1985
  ->  Sort (actual time=13.110..13.111 rows=50.00 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 30kB
        Buffers: shared hit=3525
        ->  Bitmap Heap Scan on documents (actual time=10.546..12.587 rows=10386.00 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1137
              Buffers: shared hit=3522
              ->  Bitmap Index Scan on documents_pkey (actual time=10.474..10.474 rows=10386.00 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Index Searches: 8
                    Buffers: shared hit=2385
Planning:
  Buffers: shared hit=103
Planning Time: 0.154 ms
Execution Time: 13.128 ms
```

