# Benchmark: b-policy-first (design b), medium scale, wide shape

- Date: 2026-10-29 12:45
- Postgres: 17.11 (Debian 17.11-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.28 | 0.52 | 0.305 | 13133 | 1 | ok |
| rbac_select_page | 0.47 | 0.69 | 0.486 | 8234 | 2 | ok |
| rbac_select_count | 0.37 | 0.45 | 0.351 | 11411 | 2 | ok |
| rbac_update_one | 0.46 | 0.65 | 0.456 | 8767 | 3 | ok |
| write_assign_role | 0.15 | 0.22 | 0.149 | 26764 | 1 | ok |
| share_list_objects | 9.26 | 12.64 | 9.708 | 412 | 13 | ok |
| share_select_page | 18.85 | 24.74 | 19.835 | 201 | 42 | ok |
| write_share | 0.14 | 0.20 | 0.142 | 28192 | 1 | ok |
| parents_proj_select_page | 13.77 | 15.81 | 14.185 | 281 | 51 | ok |
| parents_proj_select_count | 12.42 | 14.72 | 12.732 | 314 | 31 | ok |
| parents_select_page | 13.17 | 15.42 | 13.608 | 293 | 46 | ok |
| parents_select_count | 11.44 | 12.96 | 11.600 | 344 | 40 | ok |
| write_nest_team | 1.23 | 1.43 | 1.270 | 3149 | 1 | OVER |
| nest_check | 0.33 | 0.41 | 0.317 | 12617 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.52 | 3.9 | 10028 |
| sharing | 12.40 | 105.3 | 314697 |
| parents_proj | 0.12 | 105.8 | 316201 |
| parents | 11.54 | 141.6 | 416701 |
| nesting | 0.01 | 141.6 | 416707 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| ancestors | 0.02 MB, 0 rows | 1.02 MB, 2864 rows | 1.02 MB, 2864 rows | 1.19 MB, 3364 rows | 1.19 MB, 3369 rows |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| parents | 0.02 MB, 0 rows | 83.06 MB, 251797 rows | 83.23 MB, 252297 rows | 118.91 MB, 352297 rows | 118.91 MB, 352298 rows |
| policies | 0.08 MB, 6 rows | 0.08 MB, 8 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows |
| role_closure | 0.08 MB, 12 rows | 0.08 MB, 15 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows |
| role_grants | 3.56 MB, 10000 rows | 20.91 MB, 60000 rows | 21.25 MB, 61000 rows | 21.25 MB, 61000 rows | 21.25 MB, 61000 rows |
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
- vs design a (2026-10-29 12:42): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 12:40): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=4.214..5.219 rows=50 loops=1)
  Buffers: shared hit=2348 read=8
  InitPlan 1
    ->  Result (actual time=4.161..4.162 rows=2 loops=1)
          Buffers: shared hit=871
          ->  ProjectSet (actual time=4.160..4.161 rows=2 loops=1)
                Buffers: shared hit=871
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=4.213..5.215 rows=50 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Buffers: shared hit=2348 read=8
Planning:
  Buffers: shared hit=109
Planning Time: 0.149 ms
Execution Time: 5.419 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=18.101..23.513 rows=50 loops=1)
  Buffers: shared hit=3367
  InitPlan 1
    ->  Result (actual time=7.043..7.044 rows=2 loops=1)
          Buffers: shared hit=1841
          ->  ProjectSet (actual time=7.042..7.042 rows=2 loops=1)
                Buffers: shared hit=1841
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=9.031..10.781 rows=6652 loops=1)
          Buffers: shared hit=983
          ->  ProjectSet (actual time=9.030..9.240 rows=6652 loops=1)
                Buffers: shared hit=983
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=18.100..23.509 rows=50 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=3367
Planning:
  Buffers: shared hit=114
Planning Time: 0.175 ms
Execution Time: 23.724 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=12.270..17.952 rows=50 loops=1)
  Buffers: shared hit=6287
  InitPlan 1
    ->  Result (actual time=7.551..9.346 rows=6652 loops=1)
          Buffers: shared hit=3300
          ->  ProjectSet (actual time=7.550..7.757 rows=6652 loops=1)
                Buffers: shared hit=3300
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=2.601..2.607 rows=20 loops=1)
          Buffers: shared hit=2444
          ->  ProjectSet (actual time=2.600..2.601 rows=20 loops=1)
                Buffers: shared hit=2444
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=12.270..17.948 rows=50 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=6287
Planning:
  Buffers: shared hit=109
Planning Time: 0.155 ms
Execution Time: 18.154 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=17.657..17.661 rows=50 loops=1)
  Buffers: shared hit=5773
  InitPlan 1
    ->  Result (actual time=9.309..12.121 rows=10386 loops=1)
          Buffers: shared hit=3569
          ->  ProjectSet (actual time=9.308..9.622 rows=10386 loops=1)
                Buffers: shared hit=3569
                ->  Result (actual time=0.000..0.001 rows=1 loops=1)
  ->  Sort (actual time=17.656..17.657 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=5773
        ->  Bitmap Heap Scan on documents (actual time=15.409..17.191 rows=10386 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1137
              Buffers: shared hit=5770
              ->  Bitmap Index Scan on documents_pkey (actual time=15.338..15.338 rows=10386 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Buffers: shared hit=4633
Planning:
  Buffers: shared hit=106
Planning Time: 0.149 ms
Execution Time: 17.870 ms
```

