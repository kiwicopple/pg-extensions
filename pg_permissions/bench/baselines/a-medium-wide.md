# Benchmark: a-tuple-core (design a), medium scale, wide shape

- Date: 2026-10-29 00:00
- Postgres: 16.4 (Postgres.app)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients
- Throwaway cluster with fsync off: write numbers are optimistic

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.27 | 0.36 | 0.283 | 14119 | - | - |
| rbac_select_page | 0.53 | 0.63 | 0.540 | 7402 | - | - |
| rbac_select_count | 0.47 | 0.57 | 0.481 | 8311 | - | - |
| rbac_update_one | 0.82 | 0.97 | 0.774 | 5169 | - | - |
| write_assign_role | 0.17 | 0.29 | 0.182 | 21966 | - | - |
| share_list_objects | 63.77 | 73.23 | 64.501 | 62 | - | - |
| share_select_page | 221.40 | 268.80 | 228.217 | 17 | - | - |
| write_share | 0.15 | 0.26 | 0.165 | 24285 | - | - |
| parents_proj_select_page | 221.55 | 246.37 | 225.729 | 17 | - | - |
| parents_proj_select_count | 221.32 | 238.33 | 223.145 | 17 | - | - |
| parents_select_page | 237.76 | 253.06 | 238.663 | 16 | - | - |
| parents_select_count | 234.14 | 251.90 | 237.108 | 16 | - | - |
| write_nest_team | 0.15 | 0.26 | 0.162 | 24731 | - | - |
| nest_check | 2.23 | 2.48 | 2.277 | 1756 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.80 | 3.6 | 10020 |
| sharing | 10.39 | 97.1 | 311822 |
| parents_proj | 0.09 | 97.6 | 313325 |
| parents | 4.04 | 135.4 | 413326 |
| nesting | 0.05 | 135.4 | 413327 |

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

Compared with other designs' latest runs at this scale and shape: none yet.

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.385..1.075 rows=50 loops=1)
  Buffers: shared hit=1526 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.363..0.364 rows=2 loops=1)
          Buffers: shared hit=49
          ->  ProjectSet (actual time=0.362..0.363 rows=2 loops=1)
                Buffers: shared hit=49
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.384..1.072 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1526 read=8
Planning:
  Buffers: shared hit=688
Planning Time: 1.858 ms
Execution Time: 1.080 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=97.629..105.542 rows=50 loops=1)
  Buffers: shared hit=96485
  InitPlan 1 (returns $0)
    ->  Result (actual time=38.971..38.971 rows=2 loops=1)
          Buffers: shared hit=47971
          ->  ProjectSet (actual time=38.969..38.970 rows=2 loops=1)
                Buffers: shared hit=47971
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=56.750..58.366 rows=6652 loops=1)
          Buffers: shared hit=47971
          ->  ProjectSet (actual time=56.750..56.892 rows=6652 loops=1)
                Buffers: shared hit=47971
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=97.628..105.539 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=96485
Planning:
  Buffers: shared hit=96580
Planning Time: 100.120 ms
Execution Time: 105.550 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=97.031..105.235 rows=50 loops=1)
  Buffers: shared hit=97001
  InitPlan 1 (returns $0)
    ->  Result (actual time=56.280..57.892 rows=6652 loops=1)
          Buffers: shared hit=48229
          ->  ProjectSet (actual time=56.280..56.429 rows=6652 loops=1)
                Buffers: shared hit=48229
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=38.830..38.835 rows=20 loops=1)
          Buffers: shared hit=48229
          ->  ProjectSet (actual time=38.829..38.830 rows=20 loops=1)
                Buffers: shared hit=48229
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=97.031..105.232 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=97001
Planning:
  Buffers: shared hit=97090
Planning Time: 100.305 ms
Execution Time: 105.244 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=112.060..112.063 rows=50 loops=1)
  Buffers: shared hit=120714
  InitPlan 1 (returns $0)
    ->  Result (actual time=103.609..106.136 rows=10386 loops=1)
          Buffers: shared hit=88413
          ->  ProjectSet (actual time=103.608..103.830 rows=10386 loops=1)
                Buffers: shared hit=88413
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=112.060..112.061 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=120714
        ->  Bitmap Heap Scan on documents (actual time=110.236..111.653 rows=10386 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1137
              Buffers: shared hit=120711
              ->  Bitmap Index Scan on documents_pkey (actual time=110.170..110.170 rows=10386 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=119574
Planning:
  Buffers: shared hit=89044
Planning Time: 106.151 ms
Execution Time: 112.074 ms
```

