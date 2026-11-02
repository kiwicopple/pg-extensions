# Benchmark: a-tuple-core (design a), medium scale, wide shape

- Date: 2026-10-29 09:25
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.26 | 0.57 | 0.299 | 13368 | 1 | ok |
| rbac_select_page | 0.50 | 1.09 | 0.580 | 6897 | 2 | ok |
| rbac_select_count | 0.41 | 0.89 | 0.472 | 8480 | 2 | ok |
| rbac_update_one | 0.53 | 1.13 | 0.588 | 6803 | 3 | ok |
| write_assign_role | 0.16 | 0.35 | 0.187 | 21435 | 1 | ok |
| share_list_objects | 29.08 | 39.75 | 30.669 | 130 | 13 | OVER |
| share_select_page | 124.52 | 157.19 | 128.639 | 31 | 42 | OVER |
| write_share | 0.16 | 0.38 | 0.195 | 20548 | 1 | ok |
| parents_proj_select_page | 122.88 | 158.24 | 126.660 | 31 | 51 | OVER |
| parents_proj_select_count | 111.62 | 142.26 | 115.445 | 34 | 31 | OVER |
| parents_select_page | 118.46 | 146.48 | 123.964 | 32 | 46 | OVER |
| parents_select_count | 121.21 | 152.32 | 124.793 | 32 | 40 | OVER |
| write_nest_team | 0.15 | 0.29 | 0.171 | 23425 | 1 | ok |
| nest_check | 1.34 | 2.09 | 1.449 | 2761 | 2 | OVER |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.85 | 3.6 | 10020 |
| sharing | 7.75 | 97.1 | 311822 |
| parents_proj | 0.06 | 97.6 | 313325 |
| parents | 2.71 | 135.4 | 413326 |
| nesting | 0.04 | 135.4 | 413327 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| object_types | 0.06 MB, 3 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |
| relations | 0.06 MB, 14 rows | 0.06 MB, 17 rows | 0.06 MB, 19 rows | 0.06 MB, 20 rows | 0.06 MB, 20 rows |
| tuples | 3.43 MB, 10000 rows | 96.88 MB, 311797 rows | 97.38 MB, 313297 rows | 135.23 MB, 413297 rows | 135.23 MB, 413298 rows |

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
- vs design b (2026-10-29 09:04): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 09:09): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.514..1.418 rows=50.00 loops=1)
  Buffers: shared hit=1526 read=8
  InitPlan 1
    ->  Result (actual time=0.463..0.464 rows=2.00 loops=1)
          Buffers: shared hit=49
          ->  ProjectSet (actual time=0.462..0.462 rows=2.00 loops=1)
                Buffers: shared hit=49
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.514..1.414 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=1526 read=8
Planning:
  Buffers: shared hit=680
Planning Time: 1.754 ms
Execution Time: 1.424 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=51.215..57.534 rows=50.00 loops=1)
  Buffers: shared hit=96486
  InitPlan 1
    ->  Result (actual time=22.523..22.530 rows=2.00 loops=1)
          Buffers: shared hit=47971
          ->  ProjectSet (actual time=22.520..22.526 rows=2.00 loops=1)
                Buffers: shared hit=47971
                ->  Result (actual time=0.000..0.003 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=26.606..28.361 rows=6652.00 loops=1)
          Buffers: shared hit=47971
          ->  ProjectSet (actual time=26.604..26.816 rows=6652.00 loops=1)
                Buffers: shared hit=47971
                ->  Result (actual time=0.002..0.002 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=51.214..57.522 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=96486
Planning:
  Buffers: shared hit=96570
Planning Time: 48.178 ms
Execution Time: 57.559 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=50.934..56.908 rows=50.00 loops=1)
  Buffers: shared hit=97002
  InitPlan 1
    ->  Result (actual time=26.183..27.861 rows=6652.00 loops=1)
          Buffers: shared hit=48229
          ->  ProjectSet (actual time=26.180..26.385 rows=6652.00 loops=1)
                Buffers: shared hit=48229
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=22.767..22.773 rows=20.00 loops=1)
          Buffers: shared hit=48229
          ->  ProjectSet (actual time=22.765..22.766 rows=20.00 loops=1)
                Buffers: shared hit=48229
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=50.933..56.903 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=97002
Planning:
  Buffers: shared hit=97080
Planning Time: 50.544 ms
Execution Time: 56.927 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=60.634..60.639 rows=50.00 loops=1)
  Buffers: shared hit=89951
  InitPlan 1
    ->  Result (actual time=52.452..55.058 rows=10386.00 loops=1)
          Buffers: shared hit=88411
          ->  ProjectSet (actual time=52.449..52.773 rows=10386.00 loops=1)
                Buffers: shared hit=88411
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Sort (actual time=60.633..60.635 rows=50.00 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 30kB
        Buffers: shared hit=89951
        ->  Bitmap Heap Scan on documents (actual time=57.252..60.076 rows=10386.00 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1137
              Buffers: shared hit=89948
              ->  Bitmap Index Scan on documents_pkey (actual time=57.173..57.173 rows=10386.00 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Index Searches: 8
                    Buffers: shared hit=88811
Planning:
  Buffers: shared hit=89032
Planning Time: 51.212 ms
Execution Time: 60.669 ms
```

