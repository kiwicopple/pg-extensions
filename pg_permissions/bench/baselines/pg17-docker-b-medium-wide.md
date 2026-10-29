# Benchmark: b-policy-first (design b), medium scale, wide shape

- Date: 2026-10-29 08:52
- Postgres: 17.11 (Debian 17.11-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.35 | 0.43 | 0.322 | 12438 | 1 | ok |
| rbac_select_page | 0.55 | 0.71 | 0.547 | 7311 | 2 | ok |
| rbac_select_count | 0.44 | 0.56 | 0.425 | 9405 | 2 | ok |
| rbac_update_one | 0.79 | 0.98 | 0.754 | 5302 | 3 | ok |
| write_assign_role | 0.15 | 0.23 | 0.154 | 26045 | 1 | ok |
| share_list_objects | 9.02 | 11.13 | 9.257 | 432 | 13 | ok |
| share_select_page | 33.76 | 41.40 | 34.731 | 115 | 42 | ok |
| write_share | 0.14 | 0.20 | 0.144 | 27736 | 1 | ok |
| parents_proj_select_page | 36.70 | 42.52 | 37.249 | 107 | 51 | ok |
| parents_proj_select_count | 34.56 | 39.11 | 34.844 | 114 | 31 | OVER |
| parents_select_page | 32.93 | 38.08 | 33.667 | 118 | 46 | ok |
| parents_select_count | 31.34 | 36.38 | 31.924 | 125 | 40 | ok |
| write_nest_team | 133.51 | 178.16 | 139.228 | 28 | 1 | OVER |
| nest_check | 1.41 | 2.93 | 1.692 | 2364 | 2 | OVER |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.52 | 2.9 | 10028 |
| sharing | 20.49 | 225.9 | 971953 |
| parents_proj | 0.08 | 226.4 | 973957 |
| parents | 11.10 | 300.0 | 1273957 |
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
- vs design a (2026-10-29 08:49): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 08:46): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.615..1.776 rows=50 loops=1)
  Buffers: shared hit=1507 read=8
  InitPlan 1
    ->  Result (actual time=0.566..0.567 rows=2 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.565..0.565 rows=2 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.614..1.772 rows=50 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1507 read=8
Planning:
  Buffers: shared hit=816
Planning Time: 2.271 ms
Execution Time: 1.786 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=16.773..22.514 rows=50 loops=1)
  Buffers: shared hit=5311
  InitPlan 1
    ->  Result (actual time=5.507..5.508 rows=2 loops=1)
          Buffers: shared hit=2384
          ->  ProjectSet (actual time=5.506..5.507 rows=2 loops=1)
                Buffers: shared hit=2384
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=9.323..10.976 rows=6652 loops=1)
          Buffers: shared hit=2384
          ->  ProjectSet (actual time=9.323..9.526 rows=6652 loops=1)
                Buffers: shared hit=2384
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=16.772..22.510 rows=50 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=5311
Planning:
  Buffers: shared hit=5573
Planning Time: 17.882 ms
Execution Time: 22.523 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=17.777..23.713 rows=50 loops=1)
  Buffers: shared hit=5353
  InitPlan 1
    ->  Result (actual time=9.869..11.623 rows=6652 loops=1)
          Buffers: shared hit=2405
          ->  ProjectSet (actual time=9.868..10.068 rows=6652 loops=1)
                Buffers: shared hit=2405
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=5.834..5.840 rows=20 loops=1)
          Buffers: shared hit=2405
          ->  ProjectSet (actual time=5.833..5.834 rows=20 loops=1)
                Buffers: shared hit=2405
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=17.776..23.710 rows=50 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=5353
Planning:
  Buffers: shared hit=5616
Planning Time: 20.783 ms
Execution Time: 23.724 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=21.273..21.276 rows=50 loops=1)
  Buffers: shared hit=8308
  InitPlan 1
    ->  Result (actual time=13.458..16.612 rows=10386 loops=1)
          Buffers: shared hit=6104
          ->  ProjectSet (actual time=13.457..13.825 rows=10386 loops=1)
                Buffers: shared hit=6104
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=21.272..21.273 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=8308
        ->  Bitmap Heap Scan on documents (actual time=19.076..20.811 rows=10386 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1137
              Buffers: shared hit=8305
              ->  Bitmap Index Scan on documents_pkey (actual time=18.999..18.999 rows=10386 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Buffers: shared hit=7168
Planning:
  Buffers: shared hit=6905
Planning Time: 20.110 ms
Execution Time: 21.286 ms
```

