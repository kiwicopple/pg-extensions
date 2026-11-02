# Benchmark: a-tuple-core (design a), medium scale, wide shape

- Date: 2026-10-29 08:49
- Postgres: 17.11 (Debian 17.11-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.29 | 0.38 | 0.283 | 14152 | 1 | ok |
| rbac_select_page | 0.54 | 0.66 | 0.526 | 7598 | 2 | ok |
| rbac_select_count | 0.45 | 0.55 | 0.428 | 9350 | 2 | ok |
| rbac_update_one | 0.67 | 0.83 | 0.643 | 6216 | 3 | ok |
| write_assign_role | 0.16 | 0.23 | 0.163 | 24485 | 1 | ok |
| share_list_objects | 26.10 | 31.19 | 26.869 | 148 | 13 | OVER |
| share_select_page | 103.63 | 120.29 | 105.701 | 37 | 42 | OVER |
| write_share | 0.15 | 0.21 | 0.151 | 26535 | 1 | ok |
| parents_proj_select_page | 106.70 | 134.10 | 110.336 | 36 | 51 | OVER |
| parents_proj_select_count | 105.61 | 134.08 | 109.733 | 36 | 31 | OVER |
| parents_select_page | 118.00 | 154.10 | 123.501 | 32 | 46 | OVER |
| parents_select_count | 115.20 | 138.53 | 118.376 | 33 | 40 | OVER |
| write_nest_team | 0.15 | 0.21 | 0.157 | 25506 | 1 | ok |
| nest_check | 1.35 | 1.58 | 1.371 | 2917 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.68 | 3.6 | 10020 |
| sharing | 6.36 | 97.1 | 311822 |
| parents_proj | 0.05 | 97.6 | 313325 |
| parents | 2.45 | 135.4 | 413326 |
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
- vs design b (2026-10-29 08:41): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 08:46): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.431..1.398 rows=50 loops=1)
  Buffers: shared hit=1526 read=8
  InitPlan 1
    ->  Result (actual time=0.383..0.384 rows=2 loops=1)
          Buffers: shared hit=49
          ->  ProjectSet (actual time=0.382..0.382 rows=2 loops=1)
                Buffers: shared hit=49
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.431..1.394 rows=50 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1526 read=8
Planning:
  Buffers: shared hit=686
Planning Time: 1.414 ms
Execution Time: 1.405 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=52.599..58.100 rows=50 loops=1)
  Buffers: shared hit=96533
  InitPlan 1
    ->  Result (actual time=23.500..23.502 rows=2 loops=1)
          Buffers: shared hit=47995
          ->  ProjectSet (actual time=23.499..23.500 rows=2 loops=1)
                Buffers: shared hit=47995
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=27.065..28.820 rows=6652 loops=1)
          Buffers: shared hit=47995
          ->  ProjectSet (actual time=27.064..27.259 rows=6652 loops=1)
                Buffers: shared hit=47995
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=52.599..58.096 rows=50 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=96533
Planning:
  Buffers: shared hit=96626
Planning Time: 54.016 ms
Execution Time: 58.112 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=55.667..61.731 rows=50 loops=1)
  Buffers: shared hit=97049
  InitPlan 1
    ->  Result (actual time=27.807..29.496 rows=6652 loops=1)
          Buffers: shared hit=48253
          ->  ProjectSet (actual time=27.806..28.006 rows=6652 loops=1)
                Buffers: shared hit=48253
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=25.873..25.879 rows=20 loops=1)
          Buffers: shared hit=48253
          ->  ProjectSet (actual time=25.872..25.873 rows=20 loops=1)
                Buffers: shared hit=48253
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=55.666..61.726 rows=50 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=97049
Planning:
  Buffers: shared hit=97134
Planning Time: 56.289 ms
Execution Time: 61.744 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=63.779..63.783 rows=50 loops=1)
  Buffers: shared hit=90649
  InitPlan 1
    ->  Result (actual time=56.815..59.445 rows=10386 loops=1)
          Buffers: shared hit=88445
          ->  ProjectSet (actual time=56.813..57.139 rows=10386 loops=1)
                Buffers: shared hit=88445
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=63.778..63.779 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=90649
        ->  Bitmap Heap Scan on documents (actual time=61.661..63.294 rows=10386 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1137
              Buffers: shared hit=90646
              ->  Bitmap Index Scan on documents_pkey (actual time=61.591..61.591 rows=10386 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Buffers: shared hit=89509
Planning:
  Buffers: shared hit=89072
Planning Time: 58.627 ms
Execution Time: 63.803 ms
```

