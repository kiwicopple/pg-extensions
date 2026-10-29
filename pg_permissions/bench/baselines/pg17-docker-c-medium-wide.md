# Benchmark: c-compiled-model (design c), medium scale, wide shape

- Date: 2026-10-29 08:58
- Postgres: 17.11 (Debian 17.11-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.28 | 0.37 | 0.266 | 15064 | 1 | ok |
| rbac_select_page | 0.57 | 0.84 | 0.586 | 6830 | 2 | ok |
| rbac_select_count | 0.47 | 0.58 | 0.455 | 8786 | 2 | ok |
| rbac_update_one | 0.67 | 0.80 | 0.648 | 6176 | 3 | ok |
| write_assign_role | 0.20 | 0.26 | 0.204 | 19624 | 1 | ok |
| share_list_objects | 4.23 | 4.88 | 4.303 | 929 | 13 | ok |
| share_select_page | 9.59 | 11.73 | 9.815 | 407 | 42 | ok |
| write_share | 0.17 | 0.27 | 0.184 | 21778 | 1 | ok |
| parents_proj_select_page | 9.75 | 14.11 | 10.312 | 387 | 51 | ok |
| parents_proj_select_count | 8.04 | 10.20 | 8.308 | 481 | 31 | ok |
| parents_select_page | 10.85 | 12.77 | 11.155 | 358 | 46 | ok |
| parents_select_count | 9.32 | 10.36 | 9.457 | 422 | 40 | ok |
| write_nest_team | 174.15 | 218.93 | 175.080 | 22 | 1 | OVER |
| nest_check | 0.34 | 0.42 | 0.314 | 12721 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.79 | 2.9 | 10053 |
| sharing | 183.76 | 191.6 | 969122 |
| parents_proj | 0.21 | 192.2 | 971141 |
| parents | 1.53 | 208.2 | 1071141 |
| nesting | 0.08 | 209.1 | 1076142 |

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
- vs design a (2026-10-29 08:49): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-29 08:52): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.717..1.637 rows=50 loops=1)
  Buffers: shared hit=1518 read=8
  InitPlan 1
    ->  Result (actual time=0.676..0.677 rows=2 loops=1)
          Buffers: shared hit=41
          ->  ProjectSet (actual time=0.675..0.676 rows=2 loops=1)
                Buffers: shared hit=41
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.717..1.634 rows=50 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1518 read=8
Planning:
  Buffers: shared hit=1063
Planning Time: 2.648 ms
Execution Time: 1.648 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=5.641..11.328 rows=50 loops=1)
  Buffers: shared hit=3050
  InitPlan 1
    ->  Result (actual time=0.935..0.937 rows=2 loops=1)
          Buffers: shared hit=1324
          ->  ProjectSet (actual time=0.934..0.935 rows=2 loops=1)
                Buffers: shared hit=1324
                ->  Result (actual time=0.000..0.001 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=4.605..4.606 rows=1 loops=1)
          Buffers: shared hit=1182
  ->  Index Scan using documents_pkey on documents (actual time=5.640..11.324 rows=50 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=3050
Planning:
  Buffers: shared hit=2359
Planning Time: 3.113 ms
Execution Time: 11.341 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=8.720..14.449 rows=50 loops=1)
  Buffers: shared hit=4416
  InitPlan 1
    ->  Result (actual time=7.676..7.676 rows=1 loops=1)
          Buffers: shared hit=2095
  InitPlan 2
    ->  Result (actual time=0.920..0.920 rows=1 loops=1)
          Buffers: shared hit=1777
  ->  Index Scan using documents_pkey on documents (actual time=8.720..14.445 rows=50 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=4416
Planning:
  Buffers: shared hit=103
Planning Time: 0.134 ms
Execution Time: 14.460 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=13.968..13.971 rows=50 loops=1)
  Buffers: shared hit=6035
  InitPlan 1
    ->  Result (actual time=8.553..8.554 rows=1 loops=1)
          Buffers: shared hit=3831
  ->  Sort (actual time=13.967..13.968 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=6035
        ->  Bitmap Heap Scan on documents (actual time=11.545..13.494 rows=10386 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1137
              Buffers: shared hit=6032
              ->  Bitmap Index Scan on documents_pkey (actual time=11.470..11.470 rows=10386 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Buffers: shared hit=4895
Planning:
  Buffers: shared hit=100
Planning Time: 0.118 ms
Execution Time: 13.985 ms
```

