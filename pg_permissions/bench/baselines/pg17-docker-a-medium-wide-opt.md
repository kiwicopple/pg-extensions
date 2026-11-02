# Benchmark: a-tuple-core (design a), medium scale, wide shape

- Date: 2026-10-29 12:42
- Postgres: 17.11 (Debian 17.11-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.31 | 0.41 | 0.292 | 13691 | 1 | ok |
| rbac_select_page | 0.48 | 0.61 | 0.473 | 8451 | 2 | ok |
| rbac_select_count | 0.38 | 0.47 | 0.363 | 11031 | 2 | ok |
| rbac_update_one | 0.56 | 0.75 | 0.562 | 7117 | 3 | ok |
| write_assign_role | 0.16 | 0.22 | 0.158 | 25300 | 1 | ok |
| share_list_objects | 7.18 | 9.23 | 7.461 | 536 | 13 | ok |
| share_select_page | 20.17 | 23.56 | 20.672 | 193 | 42 | ok |
| write_share | 0.15 | 0.21 | 0.149 | 26830 | 1 | ok |
| parents_proj_select_page | 15.42 | 21.34 | 16.287 | 245 | 51 | ok |
| parents_proj_select_count | 13.78 | 16.56 | 14.113 | 283 | 31 | ok |
| parents_select_page | 14.90 | 17.28 | 15.199 | 263 | 46 | ok |
| parents_select_count | 13.29 | 16.65 | 13.858 | 288 | 40 | ok |
| write_nest_team | 0.15 | 0.21 | 0.154 | 25969 | 1 | ok |
| nest_check | 0.32 | 0.41 | 0.305 | 13104 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.63 | 3.6 | 10020 |
| sharing | 6.09 | 97.4 | 311822 |
| parents_proj | 0.05 | 97.9 | 313325 |
| parents | 2.30 | 136.4 | 413326 |
| nesting | 0.05 | 136.4 | 413327 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| object_types | 0.06 MB, 3 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |
| relations | 0.06 MB, 14 rows | 0.06 MB, 17 rows | 0.06 MB, 19 rows | 0.06 MB, 20 rows | 0.06 MB, 20 rows |
| tuples | 3.44 MB, 10000 rows | 97.17 MB, 311797 rows | 97.67 MB, 313297 rows | 136.18 MB, 413297 rows | 136.18 MB, 413298 rows |

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
- vs design b (2026-10-29 12:37): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 12:40): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.008..3.158 rows=50 loops=1)
  Buffers: shared hit=2184 read=8
  InitPlan 1
    ->  Result (actual time=1.944..1.944 rows=2 loops=1)
          Buffers: shared hit=707
          ->  ProjectSet (actual time=1.943..1.943 rows=2 loops=1)
                Buffers: shared hit=707
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.007..3.155 rows=50 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Buffers: shared hit=2184 read=8
Planning:
  Buffers: shared hit=109
Planning Time: 0.210 ms
Execution Time: 3.441 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=19.523..25.226 rows=50 loops=1)
  Buffers: shared hit=3989
  InitPlan 1
    ->  Result (actual time=9.862..9.863 rows=2 loops=1)
          Buffers: shared hit=2054
          ->  ProjectSet (actual time=9.860..9.861 rows=2 loops=1)
                Buffers: shared hit=2054
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=7.588..9.320 rows=6652 loops=1)
          Buffers: shared hit=1392
          ->  ProjectSet (actual time=7.586..7.794 rows=6652 loops=1)
                Buffers: shared hit=1392
                ->  Result (actual time=0.000..0.001 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=19.522..25.219 rows=50 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=3989
Planning:
  Buffers: shared hit=114
Planning Time: 0.198 ms
Execution Time: 25.641 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=13.253..18.908 rows=50 loops=1)
  Buffers: shared hit=4215
  InitPlan 1
    ->  Result (actual time=7.178..8.946 rows=6652 loops=1)
          Buffers: shared hit=2164
          ->  ProjectSet (actual time=7.177..7.385 rows=6652 loops=1)
                Buffers: shared hit=2164
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=3.998..4.005 rows=20 loops=1)
          Buffers: shared hit=1508
          ->  ProjectSet (actual time=3.997..3.998 rows=20 loops=1)
                Buffers: shared hit=1508
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=13.252..18.904 rows=50 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=4215
Planning:
  Buffers: shared hit=109
Planning Time: 0.190 ms
Execution Time: 19.124 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=21.581..21.585 rows=50 loops=1)
  Buffers: shared hit=8192
  InitPlan 1
    ->  Result (actual time=12.346..15.095 rows=10386 loops=1)
          Buffers: shared hit=5988
          ->  ProjectSet (actual time=12.345..12.668 rows=10386 loops=1)
                Buffers: shared hit=5988
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=21.580..21.582 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=8192
        ->  Bitmap Heap Scan on documents (actual time=18.378..21.068 rows=10386 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1137
              Buffers: shared hit=8189
              ->  Bitmap Index Scan on documents_pkey (actual time=18.305..18.305 rows=10386 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Buffers: shared hit=7052
Planning:
  Buffers: shared hit=106
Planning Time: 0.167 ms
Execution Time: 21.961 ms
```

