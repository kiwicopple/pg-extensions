# Benchmark: c-compiled-model (design c), medium scale, wide shape

- Date: 2026-10-29 12:40
- Postgres: 16.15 (Debian 16.15-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.27 | 0.38 | 0.270 | 14840 | 1 | ok |
| rbac_select_page | 0.48 | 0.66 | 0.480 | 8338 | 2 | ok |
| rbac_select_count | 0.38 | 0.49 | 0.362 | 11048 | 2 | ok |
| rbac_update_one | 0.47 | 0.62 | 0.464 | 8621 | 3 | ok |
| write_assign_role | 0.21 | 0.30 | 0.229 | 17444 | 1 | ok |
| share_list_objects | 3.40 | 4.23 | 3.505 | 1141 | 13 | ok |
| share_select_page | 8.89 | 19.38 | 11.178 | 357 | 42 | ok |
| write_share | 0.19 | 0.30 | 0.205 | 19491 | 1 | ok |
| parents_proj_select_page | 8.62 | 19.49 | 10.962 | 364 | 51 | ok |
| parents_proj_select_count | 8.30 | 9.97 | 8.504 | 470 | 31 | ok |
| parents_select_page | 12.23 | 14.55 | 12.345 | 324 | 46 | ok |
| parents_select_count | 10.15 | 12.01 | 10.272 | 389 | 40 | ok |
| write_nest_team | 60.82 | 71.44 | 61.322 | 65 | 1 | OVER |
| nest_check | 0.33 | 0.45 | 0.317 | 12607 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.81 | 2.9 | 10053 |
| sharing | 23.58 | 191.6 | 969122 |
| parents_proj | 0.24 | 192.2 | 971141 |
| parents | 1.56 | 208.2 | 1071141 |
| nesting | 0.04 | 209.1 | 1076142 |

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
- vs design a (2026-10-29 12:34): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-29 12:37): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.213..3.253 rows=50 loops=1)
  Buffers: shared hit=2472 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=2.153..2.154 rows=2 loops=1)
          Buffers: shared hit=995
          ->  ProjectSet (actual time=2.152..2.153 rows=2 loops=1)
                Buffers: shared hit=995
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.212..3.249 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=2472 read=8
Planning:
  Buffers: shared hit=109
Planning Time: 0.232 ms
Execution Time: 3.521 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=8.222..14.195 rows=50 loops=1)
  Buffers: shared hit=3687
  InitPlan 1 (returns $0)
    ->  Result (actual time=4.230..4.231 rows=2 loops=1)
          Buffers: shared hit=1856
          ->  ProjectSet (actual time=4.229..4.230 rows=2 loops=1)
                Buffers: shared hit=1856
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=3.872..3.873 rows=1 loops=1)
          Buffers: shared hit=1287
  ->  Index Scan using documents_pkey on documents (actual time=8.221..14.190 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=3687
Planning:
  Buffers: shared hit=112
Planning Time: 0.170 ms
Execution Time: 14.427 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=8.274..13.845 rows=50 loops=1)
  Buffers: shared hit=3749
  InitPlan 1 (returns $0)
    ->  Result (actual time=5.611..5.611 rows=1 loops=1)
          Buffers: shared hit=2254
  InitPlan 2 (returns $1)
    ->  Result (actual time=2.544..2.544 rows=1 loops=1)
          Buffers: shared hit=951
  ->  Index Scan using documents_pkey on documents (actual time=8.273..13.841 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=3749
Planning:
  Buffers: shared hit=103
Planning Time: 0.160 ms
Execution Time: 13.859 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=14.876..14.879 rows=50 loops=1)
  Buffers: shared hit=34270
  InitPlan 1 (returns $0)
    ->  Result (actual time=8.544..8.544 rows=1 loops=1)
          Buffers: shared hit=1969
  ->  Sort (actual time=14.875..14.876 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=34270
        ->  Bitmap Heap Scan on documents (actual time=12.587..14.401 rows=10386 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1137
              Buffers: shared hit=34267
              ->  Bitmap Index Scan on documents_pkey (actual time=12.515..12.515 rows=10386 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=33130
Planning:
  Buffers: shared hit=100
Planning Time: 0.194 ms
Execution Time: 14.906 ms
```

