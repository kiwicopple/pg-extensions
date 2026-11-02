# Benchmark: b-policy-first (design b), medium scale, wide shape

- Date: 2026-10-29 12:37
- Postgres: 16.15 (Debian 16.15-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 800 teams
- Shape: wide (50 team(s) per user, 50 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.27 | 0.40 | 0.271 | 14756 | 1 | ok |
| rbac_select_page | 0.46 | 0.60 | 0.456 | 8779 | 2 | ok |
| rbac_select_count | 0.37 | 0.48 | 0.358 | 11188 | 2 | ok |
| rbac_update_one | 0.47 | 0.60 | 0.449 | 8914 | 3 | ok |
| write_assign_role | 0.16 | 0.23 | 0.171 | 23405 | 1 | ok |
| share_list_objects | 4.47 | 5.40 | 4.586 | 872 | 13 | ok |
| share_select_page | 11.88 | 14.03 | 12.165 | 328 | 42 | ok |
| write_share | 0.15 | 0.22 | 0.163 | 24583 | 1 | ok |
| parents_proj_select_page | 13.95 | 19.37 | 14.735 | 271 | 51 | ok |
| parents_proj_select_count | 14.49 | 17.71 | 14.798 | 270 | 31 | ok |
| parents_select_page | 17.00 | 21.40 | 17.457 | 229 | 46 | ok |
| parents_select_count | 15.09 | 20.01 | 15.745 | 254 | 40 | ok |
| write_nest_team | 1.40 | 1.76 | 1.461 | 2737 | 1 | OVER |
| nest_check | 0.33 | 0.46 | 0.332 | 12037 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.53 | 3.9 | 10028 |
| sharing | 12.10 | 105.3 | 314697 |
| parents_proj | 0.12 | 105.8 | 316201 |
| parents | 13.63 | 141.6 | 416701 |
| nesting | 0.02 | 141.6 | 416707 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| ancestors | 0.02 MB, 0 rows | 1.02 MB, 2864 rows | 1.02 MB, 2864 rows | 1.19 MB, 3364 rows | 1.19 MB, 3369 rows |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| parents | 0.02 MB, 0 rows | 83.06 MB, 251797 rows | 83.23 MB, 252297 rows | 118.91 MB, 352297 rows | 118.91 MB, 352298 rows |
| policies | 0.08 MB, 6 rows | 0.08 MB, 8 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows |
| role_closure | 0.08 MB, 12 rows | 0.08 MB, 15 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows |
| role_grants | 3.56 MB, 10000 rows | 20.91 MB, 60000 rows | 21.25 MB, 61000 rows | 21.25 MB, 61000 rows | 21.25 MB, 61000 rows |
| role_implies | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows | 0.06 MB, 5 rows |
| roles | 0.06 MB, 6 rows | 0.06 MB, 8 rows | 0.06 MB, 9 rows | 0.06 MB, 9 rows | 0.06 MB, 9 rows |

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
- vs design c (2026-10-29 09:09): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=3.806..4.758 rows=50 loops=1)
  Buffers: shared hit=2347 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=3.740..3.741 rows=2 loops=1)
          Buffers: shared hit=870
          ->  ProjectSet (actual time=3.740..3.740 rows=2 loops=1)
                Buffers: shared hit=870
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.805..4.756 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=2347 read=8
Planning:
  Buffers: shared hit=109
Planning Time: 0.203 ms
Execution Time: 5.002 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=43.557..49.684 rows=50 loops=1)
  Buffers: shared hit=6261
  InitPlan 1 (returns $0)
    ->  Result (actual time=23.596..23.599 rows=2 loops=1)
          Buffers: shared hit=3289
          ->  ProjectSet (actual time=23.593..23.594 rows=2 loops=1)
                Buffers: shared hit=3289
                ->  Result (actual time=0.000..0.001 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=16.351..19.355 rows=6652 loops=1)
          Buffers: shared hit=2429
          ->  ProjectSet (actual time=16.349..16.777 rows=6652 loops=1)
                Buffers: shared hit=2429
                ->  Result (actual time=0.000..0.001 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=43.556..49.677 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=6261
Planning:
  Buffers: shared hit=114
Planning Time: 0.580 ms
Execution Time: 50.424 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=13.352..19.027 rows=50 loops=1)
  Buffers: shared hit=6288
  InitPlan 1 (returns $0)
    ->  Result (actual time=8.625..10.434 rows=6652 loops=1)
          Buffers: shared hit=3301
          ->  ProjectSet (actual time=8.624..8.829 rows=6652 loops=1)
                Buffers: shared hit=3301
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=2.598..2.604 rows=20 loops=1)
          Buffers: shared hit=2444
          ->  ProjectSet (actual time=2.597..2.598 rows=20 loops=1)
                Buffers: shared hit=2444
                ->  Result (actual time=0.000..0.001 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=13.351..19.023 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 489
        Buffers: shared hit=6288
Planning:
  Buffers: shared hit=109
Planning Time: 0.143 ms
Execution Time: 19.232 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=20.333..20.337 rows=50 loops=1)
  Buffers: shared hit=35874
  InitPlan 1 (returns $0)
    ->  Result (actual time=9.280..12.419 rows=10386 loops=1)
          Buffers: shared hit=3573
          ->  ProjectSet (actual time=9.278..9.593 rows=10386 loops=1)
                Buffers: shared hit=3573
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=20.332..20.333 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=35874
        ->  Bitmap Heap Scan on documents (actual time=17.724..19.831 rows=10386 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1137
              Buffers: shared hit=35871
              ->  Bitmap Index Scan on documents_pkey (actual time=17.655..17.655 rows=10386 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=34734
Planning:
  Buffers: shared hit=106
Planning Time: 0.143 ms
Execution Time: 20.694 ms
```

