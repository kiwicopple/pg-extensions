# Benchmark: b-policy-first (design b), medium scale, wide shape

- Date: 2026-10-29 09:04
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.29 | 0.76 | 0.363 | 11024 | 1 | ok |
| rbac_select_page | 0.57 | 1.79 | 0.814 | 4911 | 2 | ok |
| rbac_select_count | 0.42 | 0.98 | 0.491 | 8148 | 2 | ok |
| rbac_update_one | 0.57 | 1.65 | 0.747 | 5353 | 3 | ok |
| write_assign_role | 0.15 | 0.34 | 0.183 | 21856 | 1 | ok |
| share_list_objects | 11.37 | 18.83 | 12.605 | 317 | 13 | OVER |
| share_select_page | 36.89 | 54.82 | 40.439 | 98 | 42 | OVER |
| write_share | 0.15 | 0.35 | 0.182 | 21930 | 1 | ok |
| parents_proj_select_page | 40.74 | 58.17 | 42.968 | 93 | 51 | OVER |
| parents_proj_select_count | 38.53 | 61.77 | 41.851 | 95 | 31 | OVER |
| parents_select_page | 39.31 | 51.51 | 40.770 | 98 | 46 | OVER |
| parents_select_count | 41.19 | 71.95 | 45.318 | 88 | 40 | OVER |
| write_nest_team | 133.20 | 193.40 | 139.872 | 28 | 1 | OVER |
| nest_check | 1.22 | 1.90 | 1.303 | 3070 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.86 | 2.9 | 10028 |
| sharing | 26.06 | 225.9 | 971953 |
| parents_proj | 0.11 | 226.4 | 973957 |
| parents | 13.98 | 300.0 | 1273957 |
| nesting | 0.06 | 301.1 | 1278963 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| ancestors | 0.02 MB, 0 rows | 150.51 MB, 660120 rows | 150.62 MB, 660620 rows | 199.71 MB, 860620 rows | 200.87 MB, 865625 rows |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| parents | 0.02 MB, 0 rows | 57.52 MB, 251797 rows | 57.64 MB, 252297 rows | 82.16 MB, 352297 rows | 82.16 MB, 352298 rows |
| policies | 0.08 MB, 6 rows | 0.08 MB, 8 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows |
| role_closure | 0.08 MB, 12 rows | 0.08 MB, 15 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows |
| role_grants | 2.54 MB, 10000 rows | 17.55 MB, 60000 rows | 17.79 MB, 61000 rows | 17.79 MB, 61000 rows | 17.79 MB, 61000 rows |
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
- vs design a (2026-10-29 09:01): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 08:58): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.543..1.363 rows=50.00 loops=1)
  Buffers: shared hit=1507 read=8
  InitPlan 1
    ->  Result (actual time=0.478..0.479 rows=2.00 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.477..0.478 rows=2.00 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.542..1.359 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=1507 read=8
Planning:
  Buffers: shared hit=819
Planning Time: 2.118 ms
Execution Time: 1.370 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=21.062..28.293 rows=50.00 loops=1)
  Buffers: shared hit=5312
  InitPlan 1
    ->  Result (actual time=5.531..5.533 rows=2.00 loops=1)
          Buffers: shared hit=2384
          ->  ProjectSet (actual time=5.529..5.530 rows=2.00 loops=1)
                Buffers: shared hit=2384
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=13.311..15.101 rows=6652.00 loops=1)
          Buffers: shared hit=2384
          ->  ProjectSet (actual time=13.309..13.554 rows=6652.00 loops=1)
                Buffers: shared hit=2384
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=21.061..28.284 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=5312
Planning:
  Buffers: shared hit=5576
Planning Time: 18.052 ms
Execution Time: 28.323 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=19.156..25.252 rows=50.00 loops=1)
  Buffers: shared hit=5354
  InitPlan 1
    ->  Result (actual time=9.815..12.264 rows=6652.00 loops=1)
          Buffers: shared hit=2405
          ->  ProjectSet (actual time=9.813..10.109 rows=6652.00 loops=1)
                Buffers: shared hit=2405
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=6.458..6.466 rows=20.00 loops=1)
          Buffers: shared hit=2405
          ->  ProjectSet (actual time=6.455..6.457 rows=20.00 loops=1)
                Buffers: shared hit=2405
                ->  Result (actual time=0.000..0.001 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=19.155..25.243 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=5354
Planning:
  Buffers: shared hit=5617
Planning Time: 22.073 ms
Execution Time: 25.268 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=24.748..24.752 rows=50.00 loops=1)
  Buffers: shared hit=7620
  InitPlan 1
    ->  Result (actual time=17.046..19.705 rows=10386.00 loops=1)
          Buffers: shared hit=6080
          ->  ProjectSet (actual time=17.045..17.383 rows=10386.00 loops=1)
                Buffers: shared hit=6080
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Sort (actual time=24.747..24.749 rows=50.00 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=7620
        ->  Bitmap Heap Scan on documents (actual time=22.141..24.219 rows=10386.00 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1137
              Buffers: shared hit=7617
              ->  Bitmap Index Scan on documents_pkey (actual time=22.061..22.061 rows=10386.00 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Index Searches: 8
                    Buffers: shared hit=6480
Planning:
  Buffers: shared hit=6884
Planning Time: 20.086 ms
Execution Time: 24.766 ms
```

