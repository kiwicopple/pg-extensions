# Benchmark: a-tuple-core (design a), medium scale, wide shape

- Date: 2026-10-29 12:51
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.29 | 0.40 | 0.279 | 14315 | 1 | ok |
| rbac_select_page | 0.44 | 0.56 | 0.428 | 9350 | 2 | ok |
| rbac_select_count | 0.36 | 0.48 | 0.352 | 11368 | 2 | ok |
| rbac_update_one | 0.49 | 0.63 | 0.487 | 8207 | 3 | ok |
| write_assign_role | 0.15 | 0.23 | 0.158 | 25375 | 1 | ok |
| share_list_objects | 4.44 | 5.57 | 4.613 | 867 | 13 | ok |
| share_select_page | 14.44 | 16.96 | 14.662 | 272 | 42 | ok |
| write_share | 0.15 | 0.22 | 0.153 | 26172 | 1 | ok |
| parents_proj_select_page | 14.98 | 18.27 | 15.379 | 260 | 51 | ok |
| parents_proj_select_count | 13.24 | 16.48 | 13.662 | 292 | 31 | ok |
| parents_select_page | 14.74 | 19.23 | 15.447 | 258 | 46 | ok |
| parents_select_count | 13.31 | 16.64 | 13.788 | 290 | 40 | ok |
| write_nest_team | 0.15 | 0.21 | 0.152 | 26386 | 1 | ok |
| nest_check | 0.37 | 0.48 | 0.369 | 10842 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.58 | 3.6 | 10020 |
| sharing | 5.88 | 97.4 | 311822 |
| parents_proj | 0.04 | 97.9 | 313325 |
| parents | 2.32 | 136.4 | 413326 |
| nesting | 0.04 | 136.4 | 413327 |

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
- vs design b (2026-10-29 12:45): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 12:48): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.309..3.090 rows=50.00 loops=1)
  Buffers: shared hit=2179 read=8
  InitPlan 1
    ->  Result (actual time=2.239..2.240 rows=2.00 loops=1)
          Buffers: shared hit=702
          ->  ProjectSet (actual time=2.238..2.238 rows=2.00 loops=1)
                Buffers: shared hit=702
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.308..3.087 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2179 read=8
Planning:
  Buffers: shared hit=112
Planning Time: 0.149 ms
Execution Time: 3.316 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=11.880..17.518 rows=50.00 loops=1)
  Buffers: shared hit=3982
  InitPlan 1
    ->  Result (actual time=5.829..5.830 rows=2.00 loops=1)
          Buffers: shared hit=2046
          ->  ProjectSet (actual time=5.828..5.828 rows=2.00 loops=1)
                Buffers: shared hit=2046
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=4.047..5.765 rows=6652.00 loops=1)
          Buffers: shared hit=1392
          ->  ProjectSet (actual time=4.046..4.249 rows=6652.00 loops=1)
                Buffers: shared hit=1392
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=11.879..17.513 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=3982
Planning:
  Buffers: shared hit=117
Planning Time: 0.180 ms
Execution Time: 17.734 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=12.220..17.901 rows=50.00 loops=1)
  Buffers: shared hit=4211
  InitPlan 1
    ->  Result (actual time=6.429..8.161 rows=6652.00 loops=1)
          Buffers: shared hit=2159
          ->  ProjectSet (actual time=6.428..6.627 rows=6652.00 loops=1)
                Buffers: shared hit=2159
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=3.736..3.741 rows=20.00 loops=1)
          Buffers: shared hit=1508
          ->  ProjectSet (actual time=3.735..3.736 rows=20.00 loops=1)
                Buffers: shared hit=1508
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=12.220..17.897 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=4211
Planning:
  Buffers: shared hit=112
Planning Time: 0.185 ms
Execution Time: 18.114 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=18.801..18.805 rows=50.00 loops=1)
  Buffers: shared hit=7521
  InitPlan 1
    ->  Result (actual time=10.628..13.459 rows=10386.00 loops=1)
          Buffers: shared hit=5981
          ->  ProjectSet (actual time=10.627..11.086 rows=10386.00 loops=1)
                Buffers: shared hit=5981
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Sort (actual time=18.800..18.802 rows=50.00 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 30kB
        Buffers: shared hit=7521
        ->  Bitmap Heap Scan on documents (actual time=16.789..18.302 rows=10386.00 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1137
              Buffers: shared hit=7518
              ->  Bitmap Index Scan on documents_pkey (actual time=16.717..16.717 rows=10386.00 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Index Searches: 8
                    Buffers: shared hit=6381
Planning:
  Buffers: shared hit=109
Planning Time: 0.148 ms
Execution Time: 19.013 ms
```

