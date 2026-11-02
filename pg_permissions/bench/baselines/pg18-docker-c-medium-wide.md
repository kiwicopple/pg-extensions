# Benchmark: c-compiled-model (design c), medium scale, wide shape

- Date: 2026-10-29 09:09
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.24 | 0.42 | 0.262 | 15290 | 1 | ok |
| rbac_select_page | 0.48 | 0.77 | 0.501 | 7987 | 2 | ok |
| rbac_select_count | 0.38 | 0.67 | 0.405 | 9882 | 2 | ok |
| rbac_update_one | 0.46 | 0.90 | 0.501 | 7987 | 3 | ok |
| write_assign_role | 0.17 | 0.28 | 0.188 | 21248 | 1 | ok |
| share_list_objects | 4.25 | 6.77 | 4.747 | 842 | 13 | ok |
| share_select_page | 10.25 | 15.66 | 11.141 | 359 | 42 | ok |
| write_share | 0.18 | 0.39 | 0.210 | 19036 | 1 | ok |
| parents_proj_select_page | 11.07 | 18.00 | 12.119 | 330 | 51 | ok |
| parents_proj_select_count | 8.97 | 14.63 | 9.867 | 405 | 31 | ok |
| parents_select_page | 11.80 | 18.39 | 12.968 | 308 | 46 | ok |
| parents_select_count | 9.40 | 13.22 | 9.921 | 403 | 40 | ok |
| write_nest_team | 180.54 | 231.13 | 185.045 | 21 | 1 | OVER |
| nest_check | 0.31 | 0.48 | 0.318 | 12562 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.91 | 2.9 | 10053 |
| sharing | 176.36 | 191.6 | 969122 |
| parents_proj | 0.19 | 192.2 | 971141 |
| parents | 1.95 | 208.2 | 1071141 |
| nesting | 0.10 | 209.1 | 1076142 |

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
- vs design a (2026-10-29 09:01): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-29 09:04): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=1.188..2.296 rows=50.00 loops=1)
  Buffers: shared hit=1559 read=8
  InitPlan 1
    ->  Result (actual time=1.115..1.117 rows=2.00 loops=1)
          Buffers: shared hit=82
          ->  ProjectSet (actual time=1.115..1.115 rows=2.00 loops=1)
                Buffers: shared hit=82
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.187..2.292 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=1559 read=8
Planning:
  Buffers: shared hit=1128
Planning Time: 3.404 ms
Execution Time: 2.307 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=6.462..12.178 rows=50.00 loops=1)
  Buffers: shared hit=4380
  InitPlan 1
    ->  Result (actual time=1.654..1.655 rows=2.00 loops=1)
          Buffers: shared hit=2648
          ->  ProjectSet (actual time=1.653..1.653 rows=2.00 loops=1)
                Buffers: shared hit=2648
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=4.704..4.704 rows=1.00 loops=1)
          Buffers: shared hit=1188
  ->  Index Scan using documents_pkey on documents (actual time=6.462..12.174 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=4380
Planning:
  Buffers: shared hit=3705
Planning Time: 4.148 ms
Execution Time: 12.199 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=7.352..13.525 rows=50.00 loops=1)
  Buffers: shared hit=4443
  InitPlan 1
    ->  Result (actual time=6.182..6.182 rows=1.00 loops=1)
          Buffers: shared hit=2122
  InitPlan 2
    ->  Result (actual time=1.063..1.063 rows=1.00 loops=1)
          Buffers: shared hit=1777
  ->  Index Scan using documents_pkey on documents (actual time=7.352..13.520 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Index Searches: 1
        Buffers: shared hit=4443
Planning:
  Buffers: shared hit=106
Planning Time: 0.149 ms
Execution Time: 13.538 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=15.267..15.272 rows=50.00 loops=1)
  Buffers: shared hit=5396
  InitPlan 1
    ->  Result (actual time=9.896..9.896 rows=1.00 loops=1)
          Buffers: shared hit=3856
  ->  Sort (actual time=15.266..15.268 rows=50.00 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=5396
        ->  Bitmap Heap Scan on documents (actual time=12.909..14.768 rows=10386.00 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1137
              Buffers: shared hit=5393
              ->  Bitmap Index Scan on documents_pkey (actual time=12.832..12.832 rows=10386.00 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Index Searches: 8
                    Buffers: shared hit=4256
Planning:
  Buffers: shared hit=103
Planning Time: 0.204 ms
Execution Time: 15.292 ms
```

