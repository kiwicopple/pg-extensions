# Benchmark: a-tuple-core (design a), medium scale, wide shape

- Date: 2026-10-29 08:38
- Postgres: 16.15 (Debian 16.15-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.29 | 0.48 | 0.277 | 14459 | 1 | ok |
| rbac_select_page | 0.54 | 0.66 | 0.527 | 7589 | 2 | ok |
| rbac_select_count | 0.46 | 0.58 | 0.451 | 8873 | 2 | ok |
| rbac_update_one | 0.67 | 0.84 | 0.651 | 6141 | 3 | ok |
| write_assign_role | 0.17 | 0.25 | 0.186 | 21529 | 1 | ok |
| share_list_objects | 24.52 | 30.90 | 25.293 | 158 | 13 | OVER |
| share_select_page | 98.57 | 110.42 | 99.659 | 40 | 42 | OVER |
| write_share | 0.16 | 0.22 | 0.169 | 23657 | 1 | ok |
| parents_proj_select_page | 100.41 | 113.29 | 102.337 | 39 | 51 | OVER |
| parents_proj_select_count | 99.52 | 112.31 | 101.171 | 39 | 31 | OVER |
| parents_select_page | 112.29 | 128.66 | 114.510 | 34 | 46 | OVER |
| parents_select_count | 112.66 | 136.63 | 116.158 | 34 | 40 | OVER |
| write_nest_team | 0.16 | 0.23 | 0.171 | 23430 | 1 | ok |
| nest_check | 1.33 | 1.69 | 1.367 | 2927 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.81 | 3.6 | 10020 |
| sharing | 6.58 | 97.1 | 311822 |
| parents_proj | 0.05 | 97.6 | 313325 |
| parents | 2.60 | 135.4 | 413326 |
| nesting | 0.03 | 135.4 | 413327 |

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
- vs design b (2026-10-29 00:04): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 00:09): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.631..1.607 rows=50 loops=1)
  Buffers: shared hit=1526 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.577..0.578 rows=2 loops=1)
          Buffers: shared hit=49
          ->  ProjectSet (actual time=0.575..0.575 rows=2 loops=1)
                Buffers: shared hit=49
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.630..1.603 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1526 read=8
Planning:
  Buffers: shared hit=689
Planning Time: 2.731 ms
Execution Time: 1.616 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=41.914..47.463 rows=50 loops=1)
  Buffers: shared hit=96486
  InitPlan 1 (returns $0)
    ->  Result (actual time=18.424..18.424 rows=2 loops=1)
          Buffers: shared hit=47971
          ->  ProjectSet (actual time=18.422..18.423 rows=2 loops=1)
                Buffers: shared hit=47971
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=21.462..23.178 rows=6652 loops=1)
          Buffers: shared hit=47971
          ->  ProjectSet (actual time=21.462..21.692 rows=6652 loops=1)
                Buffers: shared hit=47971
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=41.914..47.459 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=96486
Planning:
  Buffers: shared hit=96579
Planning Time: 43.096 ms
Execution Time: 47.472 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=42.844..48.651 rows=50 loops=1)
  Buffers: shared hit=97002
  InitPlan 1 (returns $0)
    ->  Result (actual time=22.135..23.887 rows=6652 loops=1)
          Buffers: shared hit=48229
          ->  ProjectSet (actual time=22.134..22.367 rows=6652 loops=1)
                Buffers: shared hit=48229
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=18.648..18.653 rows=20 loops=1)
          Buffers: shared hit=48229
          ->  ProjectSet (actual time=18.647..18.648 rows=20 loops=1)
                Buffers: shared hit=48229
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=42.843..48.647 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=97002
Planning:
  Buffers: shared hit=97089
Planning Time: 43.858 ms
Execution Time: 48.661 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=55.927..55.931 rows=50 loops=1)
  Buffers: shared hit=120704
  InitPlan 1 (returns $0)
    ->  Result (actual time=46.599..49.272 rows=10386 loops=1)
          Buffers: shared hit=88403
          ->  ProjectSet (actual time=46.598..46.917 rows=10386 loops=1)
                Buffers: shared hit=88403
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=55.926..55.927 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 30kB
        Buffers: shared hit=120704
        ->  Bitmap Heap Scan on documents (actual time=53.680..55.431 rows=10386 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1137
              Buffers: shared hit=120701
              ->  Bitmap Index Scan on documents_pkey (actual time=53.607..53.607 rows=10386 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=119564
Planning:
  Buffers: shared hit=89033
Planning Time: 51.770 ms
Execution Time: 55.946 ms
```

