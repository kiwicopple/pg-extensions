# Benchmark: a-tuple-core (design a), medium scale, deep shape

- Date: 2026-10-29 08:15
- Postgres: 16.15 (Debian 16.15-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: deep (teams in chains 9 deep, users in the leaf teams, 5 documents per team)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.29 | 0.42 | 0.287 | 13924 | 1 | ok |
| rbac_select_page | 0.54 | 0.68 | 0.534 | 7493 | 2 | ok |
| rbac_select_count | 0.46 | 0.69 | 0.463 | 8644 | 2 | ok |
| rbac_update_one | 0.68 | 1.10 | 0.686 | 5835 | 3 | ok |
| write_assign_role | 0.17 | 0.25 | 0.184 | 21719 | 1 | ok |
| share_list_objects | 0.42 | 0.55 | 0.407 | 9820 | 1 | ok |
| share_select_page | 1.52 | 2.00 | 1.570 | 2547 | 3 | ok |
| write_share | 0.17 | 0.25 | 0.176 | 22706 | 1 | ok |
| parents_proj_select_page | 2.13 | 2.87 | 2.222 | 1799 | 4 | ok |
| parents_proj_select_count | 2.46 | 3.59 | 2.620 | 1526 | 4 | ok |
| parents_select_page | 48.77 | 60.56 | 50.407 | 79 | 25 | OVER |
| parents_select_count | 48.26 | 60.12 | 50.096 | 79 | 23 | OVER |
| write_nest_team | 0.16 | 0.22 | 0.169 | 23720 | 1 | ok |
| nest_check | 0.49 | 0.90 | 0.526 | 7599 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.65 | 3.6 | 10020 |
| sharing | 0.37 | 9.5 | 27202 |
| parents_proj | 0.04 | 10.0 | 28705 |
| parents | 2.32 | 47.9 | 128706 |
| nesting | 0.01 | 47.9 | 128707 |

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
- vs design b (2026-10-28 23:54): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-28 23:57): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.510..1.561 rows=50 loops=1)
  Buffers: shared hit=1526 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.453..0.454 rows=2 loops=1)
          Buffers: shared hit=49
          ->  ProjectSet (actual time=0.452..0.453 rows=2 loops=1)
                Buffers: shared hit=49
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.509..1.557 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1526 read=8
Planning:
  Buffers: shared hit=689
Planning Time: 1.850 ms
Execution Time: 1.570 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=1.135..2.203 rows=50 loops=1)
  Buffers: shared hit=2207 read=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.608..0.609 rows=2 loops=1)
          Buffers: shared hit=363
          ->  ProjectSet (actual time=0.607..0.607 rows=2 loops=1)
                Buffers: shared hit=363
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.475..0.489 rows=47 loops=1)
          Buffers: shared hit=363
          ->  ProjectSet (actual time=0.475..0.477 rows=47 loops=1)
                Buffers: shared hit=363
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.135..2.199 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2207 read=3
Planning:
  Buffers: shared hit=1367
Planning Time: 2.407 ms
Execution Time: 2.214 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=1.190..2.239 rows=50 loops=1)
  Buffers: shared hit=2635 read=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.583..0.596 rows=47 loops=1)
          Buffers: shared hit=577
          ->  ProjectSet (actual time=0.582..0.584 rows=47 loops=1)
                Buffers: shared hit=577
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.550..0.556 rows=20 loops=1)
          Buffers: shared hit=577
          ->  ProjectSet (actual time=0.549..0.550 rows=20 loops=1)
                Buffers: shared hit=577
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.190..2.236 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2635 read=3
Planning:
  Buffers: shared hit=1789
Planning Time: 2.567 ms
Execution Time: 2.247 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=23.954..23.957 rows=50 loops=1)
  Buffers: shared hit=49959
  InitPlan 1 (returns $0)
    ->  Result (actual time=19.450..20.516 rows=4045 loops=1)
          Buffers: shared hit=36683
          ->  ProjectSet (actual time=19.448..19.595 rows=4045 loops=1)
                Buffers: shared hit=36683
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=23.953..23.954 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=49959
        ->  Bitmap Heap Scan on documents (actual time=22.494..23.745 rows=4045 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1135
              Buffers: shared hit=49956
              ->  Bitmap Index Scan on documents_pkey (actual time=22.428..22.428 rows=4045 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=48821
Planning:
  Buffers: shared hit=37314
Planning Time: 23.004 ms
Execution Time: 23.967 ms
```

