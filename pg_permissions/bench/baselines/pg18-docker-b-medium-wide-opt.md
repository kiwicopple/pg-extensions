# Benchmark: b-policy-first (design b), medium scale, wide shape

- Date: 2026-10-29 12:54
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.28 | 0.37 | 0.276 | 14497 | 1 | ok |
| rbac_select_page | 0.46 | 0.59 | 0.454 | 8815 | 2 | ok |
| rbac_select_count | 0.36 | 0.45 | 0.342 | 11692 | 2 | ok |
| rbac_update_one | 0.48 | 0.95 | 0.525 | 7626 | 3 | ok |
| write_assign_role | 0.14 | 0.24 | 0.152 | 26360 | 1 | ok |
| share_list_objects | 8.41 | 15.80 | 9.789 | 408 | 13 | OVER |
| share_select_page | 17.82 | 24.18 | 18.970 | 210 | 42 | ok |
| write_share | 0.16 | 0.40 | 0.204 | 19619 | 1 | ok |
| parents_proj_select_page | 15.05 | 21.68 | 15.921 | 251 | 51 | ok |
| parents_proj_select_count | 13.44 | 18.05 | 14.171 | 282 | 31 | ok |
| parents_select_page | 13.68 | 19.98 | 14.898 | 268 | 46 | ok |
| parents_select_count | 12.22 | 17.51 | 13.143 | 304 | 40 | ok |
| write_nest_team | 1.47 | 1.81 | 1.547 | 2586 | 1 | OVER |
| nest_check | 0.34 | 0.61 | 0.363 | 11027 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.51 | 3.9 | 10028 |
| sharing | 12.56 | 105.3 | 314697 |
| parents_proj | 0.35 | 105.8 | 316201 |
| parents | 12.99 | 141.6 | 416701 |
| nesting | 0.02 | 141.6 | 416707 |

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
- vs design a (2026-10-29 12:51): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 12:48): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.519..3.272 rows=50.00 loops=1)
  Buffers: shared hit=2352 read=8
  InitPlan 1
    ->  Result (actual time=2.463..2.464 rows=2.00 loops=1)
          Buffers: shared hit=875
          ->  ProjectSet (actual time=2.462..2.463 rows=2.00 loops=1)
                Buffers: shared hit=875
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.519..3.269 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2352 read=8
Planning:
  Buffers: shared hit=112
Planning Time: 0.165 ms
Execution Time: 3.464 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=17.582..23.824 rows=50.00 loops=1)
  Buffers: shared hit=3369
  InitPlan 1
    ->  Result (actual time=6.569..6.571 rows=2.00 loops=1)
          Buffers: shared hit=1843
          ->  ProjectSet (actual time=6.569..6.570 rows=2.00 loops=1)
                Buffers: shared hit=1843
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=8.839..10.701 rows=6652.00 loops=1)
          Buffers: shared hit=983
          ->  ProjectSet (actual time=8.837..9.042 rows=6652.00 loops=1)
                Buffers: shared hit=983
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=17.581..23.813 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=3369
Planning:
  Buffers: shared hit=117
Planning Time: 0.163 ms
Execution Time: 24.045 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=15.107..21.340 rows=50.00 loops=1)
  Buffers: shared hit=6291
  InitPlan 1
    ->  Result (actual time=9.133..10.955 rows=6652.00 loops=1)
          Buffers: shared hit=3304
          ->  ProjectSet (actual time=9.131..9.351 rows=6652.00 loops=1)
                Buffers: shared hit=3304
                ->  Result (actual time=0.000..0.001 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=3.810..3.817 rows=20.00 loops=1)
          Buffers: shared hit=2444
          ->  ProjectSet (actual time=3.808..3.809 rows=20.00 loops=1)
                Buffers: shared hit=2444
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=15.106..21.333 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=6291
Planning:
  Buffers: shared hit=112
Planning Time: 0.248 ms
Execution Time: 21.657 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=18.508..18.511 rows=50.00 loops=1)
  Buffers: shared hit=5114
  InitPlan 1
    ->  Result (actual time=10.180..12.980 rows=10386.00 loops=1)
          Buffers: shared hit=3574
          ->  ProjectSet (actual time=10.179..10.518 rows=10386.00 loops=1)
                Buffers: shared hit=3574
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Sort (actual time=18.507..18.508 rows=50.00 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=5114
        ->  Bitmap Heap Scan on documents (actual time=16.518..18.014 rows=10386.00 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1137
              Buffers: shared hit=5111
              ->  Bitmap Index Scan on documents_pkey (actual time=16.446..16.446 rows=10386.00 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Index Searches: 8
                    Buffers: shared hit=3974
Planning:
  Buffers: shared hit=109
Planning Time: 0.160 ms
Execution Time: 18.707 ms
```

