# Benchmark: c-compiled-model (design c), medium scale, wide shape

- Date: 2026-10-29 00:09
- Postgres: 16.4 (Postgres.app)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients
- Throwaway cluster with fsync off: write numbers are optimistic

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.23 | 0.31 | 0.239 | 16763 | - | - |
| rbac_select_page | 0.49 | 0.58 | 0.504 | 7939 | - | - |
| rbac_select_count | 0.42 | 0.50 | 0.434 | 9226 | - | - |
| rbac_update_one | 0.65 | 0.76 | 0.630 | 6345 | - | - |
| write_assign_role | 0.20 | 0.34 | 0.217 | 18465 | - | - |
| share_list_objects | 3.76 | 4.06 | 3.790 | 1055 | - | - |
| share_select_page | 10.72 | 13.73 | 11.018 | 363 | - | - |
| write_share | 0.16 | 0.29 | 0.180 | 22248 | - | - |
| parents_proj_select_page | 11.15 | 16.98 | 11.665 | 342 | - | - |
| parents_proj_select_count | 8.60 | 10.14 | 8.802 | 454 | - | - |
| parents_select_page | 13.74 | 15.27 | 13.737 | 291 | - | - |
| parents_select_count | 11.63 | 13.32 | 11.722 | 341 | - | - |
| write_nest_team | 144.63 | 174.19 | 142.910 | 27 | - | - |
| nest_check | 0.28 | 0.35 | 0.287 | 13920 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.87 | 2.9 | 10053 |
| sharing | 182.95 | 191.6 | 969122 |
| parents_proj | 0.23 | 192.2 | 971141 |
| parents | 1.65 | 208.2 | 1071141 |
| nesting | 0.09 | 209.1 | 1076142 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| allowed_subjects | 0.05 MB, 6 rows | 0.05 MB, 12 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows |
| ancestors | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.16 MB, 500 rows | 0.16 MB, 500 rows | 0.16 MB, 500 rows |
| memberships | 0.02 MB, 0 rows | 116.80 MB, 657256 rows | 116.80 MB, 657256 rows | 116.80 MB, 657256 rows | 117.69 MB, 662256 rows |
| models | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| parent_types | 0.01 MB, 0 rows | 0.01 MB, 0 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows |
| parents | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.16 MB, 500 rows | 16.16 MB, 100500 rows | 16.16 MB, 100500 rows |
| relations | 0.08 MB, 14 rows | 0.08 MB, 17 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows |
| satisfies | 0.05 MB, 26 rows | 0.05 MB, 30 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows |
| tuples | 2.48 MB, 10000 rows | 74.42 MB, 311797 rows | 74.67 MB, 312797 rows | 74.67 MB, 312797 rows | 74.67 MB, 312798 rows |
| types | 0.08 MB, 3 rows | 0.08 MB, 5 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows |

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
- vs design a (2026-10-29 00:00): parents_proj: same; rbac: same; parents: same; sharing: same
- vs design b (2026-10-29 00:04): parents_proj: same; rbac: same; parents: same; sharing: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.499..1.176 rows=50 loops=1)
  Buffers: shared hit=1509 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.476..0.476 rows=2 loops=1)
          Buffers: shared hit=32
          ->  ProjectSet (actual time=0.475..0.476 rows=2 loops=1)
                Buffers: shared hit=32
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.499..1.174 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1509 read=8
Planning:
  Buffers: shared hit=1054
Planning Time: 2.665 ms
Execution Time: 1.181 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=5.081..12.971 rows=50 loops=1)
  Buffers: shared hit=3033
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.921..0.922 rows=2 loops=1)
          Buffers: shared hit=1316
          ->  ProjectSet (actual time=0.921..0.921 rows=2 loops=1)
                Buffers: shared hit=1316
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=4.031..4.031 rows=1 loops=1)
          Buffers: shared hit=1174
  ->  Index Scan using documents_pkey on documents (actual time=5.081..12.969 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=3033
Planning:
  Buffers: shared hit=2340
Planning Time: 3.143 ms
Execution Time: 12.994 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=7.754..15.360 rows=50 loops=1)
  Buffers: shared hit=4391
  InitPlan 1 (returns $0)
    ->  Result (actual time=6.595..6.596 rows=1 loops=1)
          Buffers: shared hit=2082
  InitPlan 2 (returns $1)
    ->  Result (actual time=1.022..1.022 rows=1 loops=1)
          Buffers: shared hit=1766
  ->  Index Scan using documents_pkey on documents (actual time=7.753..15.358 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=4391
Planning:
  Buffers: shared hit=103
Planning Time: 0.221 ms
Execution Time: 15.372 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=15.471..15.474 rows=50 loops=1)
  Buffers: shared hit=36108
  InitPlan 1 (returns $0)
    ->  Result (actual time=8.599..8.600 rows=1 loops=1)
          Buffers: shared hit=3807
  ->  Sort (actual time=15.471..15.472 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=36108
        ->  Bitmap Heap Scan on documents (actual time=13.424..15.004 rows=10386 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1137
              Buffers: shared hit=36105
              ->  Bitmap Index Scan on documents_pkey (actual time=13.357..13.357 rows=10386 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=34968
Planning:
  Buffers: shared hit=100
Planning Time: 0.207 ms
Execution Time: 15.491 ms
```

