# Benchmark: a-tuple-core (design a), medium scale, wide shape

- Date: 2026-10-29 12:34
- Postgres: 16.15 (Debian 16.15-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.35 | 0.81 | 0.414 | 9671 | 1 | ok |
| rbac_select_page | 0.49 | 0.81 | 0.507 | 7884 | 2 | ok |
| rbac_select_count | 0.38 | 0.51 | 0.382 | 10468 | 2 | ok |
| rbac_update_one | 0.53 | 0.75 | 0.558 | 7166 | 3 | ok |
| write_assign_role | 0.17 | 0.27 | 0.189 | 21203 | 1 | ok |
| share_list_objects | 4.57 | 5.83 | 4.761 | 840 | 13 | ok |
| share_select_page | 14.67 | 18.04 | 15.275 | 261 | 42 | ok |
| write_share | 0.16 | 0.23 | 0.171 | 23448 | 1 | ok |
| parents_proj_select_page | 15.28 | 20.61 | 16.036 | 249 | 51 | ok |
| parents_proj_select_count | 16.19 | 22.13 | 17.509 | 228 | 31 | ok |
| parents_select_page | 18.78 | 23.32 | 19.144 | 208 | 46 | ok |
| parents_select_count | 17.14 | 23.39 | 17.924 | 223 | 40 | ok |
| write_nest_team | 0.16 | 0.24 | 0.175 | 22826 | 1 | ok |
| nest_check | 0.33 | 0.66 | 0.361 | 11079 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 1.18 | 3.6 | 10020 |
| sharing | 6.11 | 97.4 | 311822 |
| parents_proj | 0.07 | 97.9 | 313325 |
| parents | 2.39 | 136.4 | 413326 |
| nesting | 0.03 | 136.4 | 413327 |

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
- vs design b (2026-10-29 09:34): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 09:09): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.210..3.468 rows=50 loops=1)
  Buffers: shared hit=2198 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=2.148..2.149 rows=2 loops=1)
          Buffers: shared hit=721
          ->  ProjectSet (actual time=2.147..2.147 rows=2 loops=1)
                Buffers: shared hit=721
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.209..3.464 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=2198 read=8
Planning:
  Buffers: shared hit=109
Planning Time: 0.219 ms
Execution Time: 3.714 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=12.745..18.282 rows=50 loops=1)
  Buffers: shared hit=4000
  InitPlan 1 (returns $0)
    ->  Result (actual time=6.178..6.180 rows=2 loops=1)
          Buffers: shared hit=2065
          ->  ProjectSet (actual time=6.178..6.178 rows=2 loops=1)
                Buffers: shared hit=2065
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=4.447..6.262 rows=6652 loops=1)
          Buffers: shared hit=1392
          ->  ProjectSet (actual time=4.446..4.655 rows=6652 loops=1)
                Buffers: shared hit=1392
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=12.744..18.278 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=4000
Planning:
  Buffers: shared hit=114
Planning Time: 0.155 ms
Execution Time: 18.472 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=12.546..18.180 rows=50 loops=1)
  Buffers: shared hit=4229
  InitPlan 1 (returns $0)
    ->  Result (actual time=6.648..8.412 rows=6652 loops=1)
          Buffers: shared hit=2178
          ->  ProjectSet (actual time=6.647..6.850 rows=6652 loops=1)
                Buffers: shared hit=2178
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=3.822..3.829 rows=20 loops=1)
          Buffers: shared hit=1508
          ->  ProjectSet (actual time=3.821..3.822 rows=20 loops=1)
                Buffers: shared hit=1508
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=12.546..18.176 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=4229
Planning:
  Buffers: shared hit=111
Planning Time: 0.165 ms
Execution Time: 18.405 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=24.947..24.951 rows=50 loops=1)
  Buffers: shared hit=38302
  InitPlan 1 (returns $0)
    ->  Result (actual time=14.779..17.524 rows=10386 loops=1)
          Buffers: shared hit=6001
          ->  ProjectSet (actual time=14.777..15.095 rows=10386 loops=1)
                Buffers: shared hit=6001
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=24.946..24.947 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=38302
        ->  Bitmap Heap Scan on documents (actual time=22.896..24.466 rows=10386 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1137
              Buffers: shared hit=38299
              ->  Bitmap Index Scan on documents_pkey (actual time=22.827..22.827 rows=10386 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=37162
Planning:
  Buffers: shared hit=106
Planning Time: 0.161 ms
Execution Time: 25.258 ms
```

