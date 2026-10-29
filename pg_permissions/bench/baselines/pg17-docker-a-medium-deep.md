# Benchmark: a-tuple-core (design a), medium scale, deep shape

- Date: 2026-10-29 08:22
- Postgres: 17.11 (Debian 17.11-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: deep (teams in chains 9 deep, users in the leaf teams, 5 documents per team)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.29 | 0.37 | 0.280 | 14265 | 1 | ok |
| rbac_select_page | 0.53 | 0.66 | 0.524 | 7627 | 2 | ok |
| rbac_select_count | 0.45 | 0.54 | 0.433 | 9234 | 2 | ok |
| rbac_update_one | 0.63 | 0.82 | 0.633 | 6320 | 3 | ok |
| write_assign_role | 0.16 | 0.23 | 0.163 | 24526 | 1 | ok |
| share_list_objects | 0.43 | 0.57 | 0.426 | 9397 | 1 | ok |
| share_select_page | 1.57 | 1.84 | 1.596 | 2506 | 3 | ok |
| write_share | 0.15 | 0.21 | 0.150 | 26611 | 1 | ok |
| parents_proj_select_page | 2.16 | 2.55 | 2.220 | 1801 | 4 | ok |
| parents_proj_select_count | 2.48 | 2.85 | 2.529 | 1581 | 4 | ok |
| parents_select_page | 49.76 | 57.43 | 50.728 | 78 | 25 | OVER |
| parents_select_count | 48.38 | 56.88 | 49.451 | 80 | 23 | OVER |
| write_nest_team | 0.15 | 0.27 | 0.165 | 24187 | 1 | ok |
| nest_check | 0.66 | 0.79 | 0.656 | 6093 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.65 | 3.6 | 10020 |
| sharing | 0.35 | 9.5 | 27202 |
| parents_proj | 0.04 | 10.0 | 28705 |
| parents | 2.32 | 47.9 | 128706 |
| nesting | 0.02 | 47.9 | 128707 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| object_types | 0.06 MB, 3 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |
| relations | 0.06 MB, 14 rows | 0.06 MB, 17 rows | 0.06 MB, 19 rows | 0.06 MB, 20 rows | 0.06 MB, 20 rows |
| tuples | 3.43 MB, 10000 rows | 9.33 MB, 27177 rows | 9.81 MB, 28677 rows | 47.70 MB, 128677 rows | 47.70 MB, 128678 rows |

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
| sharing | 1 | 4045 | 191b9e3562eac23676f2ae85efb3a6ee |
| sharing | 2 | 4046 | 335c04f0b5bc3d03bcffc67aae3869ca |
| sharing | 3 | 4045 | 75d3d9ab19d3c59998a6f1c0aa0b6948 |
| sharing | 5 | 4047 | f93629e4f85e699b1035f55bdd839a18 |
| sharing | 10 | 4044 | d14583b707a0b173a9335693da0f83ce |
| sharing | 77 | 4044 | 1f5d5175497f9753469592e0dc00ef29 |
| sharing | 500 | 4040 | 2311723442185f44718d106cc6157e17 |
| sharing | 5000 | 4044 | 8d1cc59bb9cac19a9e3f641423c36bbc |
| parents_proj | 1 | 4045 | 191b9e3562eac23676f2ae85efb3a6ee |
| parents_proj | 2 | 4046 | 335c04f0b5bc3d03bcffc67aae3869ca |
| parents_proj | 3 | 4045 | 75d3d9ab19d3c59998a6f1c0aa0b6948 |
| parents_proj | 5 | 4247 | e901b7bd5efdcfbdba02c49ec5756579 |
| parents_proj | 10 | 4243 | 27e3570218fbbdeb167dd1a25cad3a86 |
| parents_proj | 77 | 4044 | 1f5d5175497f9753469592e0dc00ef29 |
| parents_proj | 500 | 4240 | 33efaf6a01975b460f502f30ed1dd363 |
| parents_proj | 5000 | 4244 | 9b47bb1a6b8c58829b3e82950e381c80 |
| parents | 1 | 4045 | 191b9e3562eac23676f2ae85efb3a6ee |
| parents | 2 | 4046 | 335c04f0b5bc3d03bcffc67aae3869ca |
| parents | 3 | 4045 | 75d3d9ab19d3c59998a6f1c0aa0b6948 |
| parents | 5 | 4247 | e901b7bd5efdcfbdba02c49ec5756579 |
| parents | 10 | 4243 | 27e3570218fbbdeb167dd1a25cad3a86 |
| parents | 77 | 4044 | 1f5d5175497f9753469592e0dc00ef29 |
| parents | 500 | 4240 | 33efaf6a01975b460f502f30ed1dd363 |
| parents | 5000 | 4244 | 9b47bb1a6b8c58829b3e82950e381c80 |

Compared with other designs' latest runs at this scale and shape:
- vs design b (2026-10-29 08:17): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 08:20): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.521..1.430 rows=50 loops=1)
  Buffers: shared hit=1526 read=8
  InitPlan 1
    ->  Result (actual time=0.468..0.469 rows=2 loops=1)
          Buffers: shared hit=49
          ->  ProjectSet (actual time=0.466..0.467 rows=2 loops=1)
                Buffers: shared hit=49
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.521..1.427 rows=50 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1526 read=8
Planning:
  Buffers: shared hit=686
Planning Time: 1.639 ms
Execution Time: 1.440 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.920..1.921 rows=50 loops=1)
  Buffers: shared hit=2209 read=3
  InitPlan 1
    ->  Result (actual time=0.450..0.451 rows=2 loops=1)
          Buffers: shared hit=363
          ->  ProjectSet (actual time=0.450..0.450 rows=2 loops=1)
                Buffers: shared hit=363
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=0.410..0.428 rows=47 loops=1)
          Buffers: shared hit=363
          ->  ProjectSet (actual time=0.409..0.411 rows=47 loops=1)
                Buffers: shared hit=363
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.919..1.918 rows=50 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2209 read=3
Planning:
  Buffers: shared hit=1364
Planning Time: 2.240 ms
Execution Time: 1.929 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=1.423..2.449 rows=50 loops=1)
  Buffers: shared hit=2637 read=3
  InitPlan 1
    ->  Result (actual time=0.737..0.750 rows=47 loops=1)
          Buffers: shared hit=577
          ->  ProjectSet (actual time=0.736..0.738 rows=47 loops=1)
                Buffers: shared hit=577
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2
    ->  Result (actual time=0.622..0.633 rows=20 loops=1)
          Buffers: shared hit=577
          ->  ProjectSet (actual time=0.622..0.623 rows=20 loops=1)
                Buffers: shared hit=577
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.422..2.446 rows=50 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2637 read=3
Planning:
  Buffers: shared hit=1786
Planning Time: 2.842 ms
Execution Time: 2.458 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=23.915..23.919 rows=50 loops=1)
  Buffers: shared hit=38952
  InitPlan 1
    ->  Result (actual time=20.056..21.136 rows=4045 loops=1)
          Buffers: shared hit=36689
          ->  ProjectSet (actual time=20.054..20.179 rows=4045 loops=1)
                Buffers: shared hit=36689
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=23.915..23.916 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=38952
        ->  Bitmap Heap Scan on documents (actual time=22.495..23.701 rows=4045 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1136
              Buffers: shared hit=38949
              ->  Bitmap Index Scan on documents_pkey (actual time=22.429..22.429 rows=4045 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Buffers: shared hit=37813
Planning:
  Buffers: shared hit=37317
Planning Time: 23.863 ms
Execution Time: 23.930 ms
```

