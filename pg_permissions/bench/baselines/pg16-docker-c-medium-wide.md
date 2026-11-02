# Benchmark: c-compiled-model (design c), medium scale, wide shape

- Date: 2026-10-29 08:46
- Postgres: 16.15 (Debian 16.15-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.28 | 0.35 | 0.268 | 14915 | 1 | ok |
| rbac_select_page | 0.57 | 0.68 | 0.560 | 7143 | 2 | ok |
| rbac_select_count | 0.48 | 0.56 | 0.464 | 8623 | 2 | ok |
| rbac_update_one | 0.67 | 0.80 | 0.650 | 6155 | 3 | ok |
| write_assign_role | 0.22 | 0.29 | 0.232 | 17205 | 1 | ok |
| share_list_objects | 4.08 | 4.52 | 4.137 | 966 | 13 | ok |
| share_select_page | 9.40 | 12.27 | 9.773 | 409 | 42 | ok |
| write_share | 0.19 | 0.25 | 0.195 | 20504 | 1 | ok |
| parents_proj_select_page | 9.61 | 11.39 | 9.829 | 406 | 51 | ok |
| parents_proj_select_count | 10.15 | 12.36 | 10.383 | 385 | 31 | ok |
| parents_select_page | 14.27 | 16.85 | 14.452 | 276 | 46 | ok |
| parents_select_count | 12.77 | 16.59 | 13.159 | 303 | 40 | ok |
| write_nest_team | 148.12 | 191.07 | 152.229 | 26 | 1 | OVER |
| nest_check | 0.34 | 0.43 | 0.327 | 12248 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.80 | 2.9 | 10053 |
| sharing | 181.49 | 191.6 | 969122 |
| parents_proj | 0.21 | 192.2 | 971141 |
| parents | 1.61 | 208.2 | 1071141 |
| nesting | 0.07 | 209.1 | 1076142 |

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
- vs design a (2026-10-29 08:38): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-29 08:41): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.710..1.435 rows=50 loops=1)
  Buffers: shared hit=1509 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.678..0.679 rows=2 loops=1)
          Buffers: shared hit=32
          ->  ProjectSet (actual time=0.678..0.678 rows=2 loops=1)
                Buffers: shared hit=32
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.710..1.432 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1509 read=8
Planning:
  Buffers: shared hit=1054
Planning Time: 2.232 ms
Execution Time: 1.441 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=5.672..11.468 rows=50 loops=1)
  Buffers: shared hit=3042
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.968..0.969 rows=2 loops=1)
          Buffers: shared hit=1316
          ->  ProjectSet (actual time=0.967..0.968 rows=2 loops=1)
                Buffers: shared hit=1316
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=4.608..4.609 rows=1 loops=1)
          Buffers: shared hit=1182
  ->  Index Scan using documents_pkey on documents (actual time=5.671..11.464 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=3042
Planning:
  Buffers: shared hit=2340
Planning Time: 2.667 ms
Execution Time: 11.477 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=7.924..13.858 rows=50 loops=1)
  Buffers: shared hit=4398
  InitPlan 1 (returns $0)
    ->  Result (actual time=6.842..6.842 rows=1 loops=1)
          Buffers: shared hit=2088
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.962..0.962 rows=1 loops=1)
          Buffers: shared hit=1766
  ->  Index Scan using documents_pkey on documents (actual time=7.924..13.855 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=4398
Planning:
  Buffers: shared hit=103
Planning Time: 0.134 ms
Execution Time: 13.869 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=16.768..16.772 rows=50 loops=1)
  Buffers: shared hit=36116
  InitPlan 1 (returns $0)
    ->  Result (actual time=8.607..8.607 rows=1 loops=1)
          Buffers: shared hit=3815
  ->  Sort (actual time=16.768..16.769 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=36116
        ->  Bitmap Heap Scan on documents (actual time=14.084..16.262 rows=10386 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1137
              Buffers: shared hit=36113
              ->  Bitmap Index Scan on documents_pkey (actual time=14.003..14.003 rows=10386 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=34976
Planning:
  Buffers: shared hit=100
Planning Time: 0.134 ms
Execution Time: 16.788 ms
```

