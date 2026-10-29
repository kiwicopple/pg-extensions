# Benchmark: a-tuple-core (design a), medium scale, deep shape

- Date: 2026-10-29 12:26
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: deep (teams in chains 9 deep, users in the leaf teams, 5 documents per team)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.29 | 0.40 | 0.285 | 14042 | 1 | ok |
| rbac_select_page | 0.44 | 0.56 | 0.428 | 9335 | 2 | ok |
| rbac_select_count | 0.35 | 0.48 | 0.343 | 11667 | 2 | ok |
| rbac_update_one | 0.48 | 0.66 | 0.481 | 8308 | 3 | ok |
| write_assign_role | 0.15 | 0.23 | 0.160 | 25065 | 1 | ok |
| share_list_objects | 0.31 | 0.41 | 0.303 | 13194 | 1 | ok |
| share_select_page | 0.76 | 1.00 | 0.789 | 5071 | 3 | ok |
| write_share | 0.15 | 0.22 | 0.149 | 26840 | 1 | ok |
| parents_proj_select_page | 1.00 | 1.26 | 1.013 | 3948 | 4 | ok |
| parents_proj_select_count | 1.25 | 1.47 | 1.267 | 3155 | 4 | ok |
| parents_select_page | 7.41 | 9.76 | 7.803 | 512 | 25 | ok |
| parents_select_count | 6.40 | 8.06 | 6.644 | 602 | 23 | ok |
| write_nest_team | 0.15 | 0.23 | 0.159 | 25145 | 1 | ok |
| nest_check | 0.34 | 0.47 | 0.334 | 11961 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.60 | 3.6 | 10020 |
| sharing | 0.36 | 9.5 | 27202 |
| parents_proj | 0.04 | 10.0 | 28705 |
| parents | 2.14 | 48.6 | 128706 |
| nesting | 0.02 | 48.6 | 128707 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| object_types | 0.06 MB, 3 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| rbac_roles | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows | 0.06 MB, 3 rows |
| relations | 0.06 MB, 14 rows | 0.06 MB, 17 rows | 0.06 MB, 19 rows | 0.06 MB, 20 rows | 0.06 MB, 20 rows |
| tuples | 3.44 MB, 10000 rows | 9.34 MB, 27177 rows | 9.84 MB, 28677 rows | 48.38 MB, 128677 rows | 48.38 MB, 128678 rows |

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
- vs design b (2026-10-29 12:21): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 12:24): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=1.657..2.376 rows=50.00 loops=1)
  Buffers: shared hit=2179 read=8
  InitPlan 1
    ->  Result (actual time=1.599..1.600 rows=2.00 loops=1)
          Buffers: shared hit=702
          ->  ProjectSet (actual time=1.599..1.599 rows=2.00 loops=1)
                Buffers: shared hit=702
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.656..2.372 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 1429
        Index Searches: 1
        Buffers: shared hit=2179 read=8
Planning:
  Buffers: shared hit=112
Planning Time: 0.150 ms
Execution Time: 2.557 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.488..3.496 rows=50.00 loops=1)
  Buffers: shared hit=2371 read=3
  InitPlan 1
    ->  Result (actual time=2.223..2.224 rows=2.00 loops=1)
          Buffers: shared hit=773
          ->  ProjectSet (actual time=2.223..2.223 rows=2.00 loops=1)
                Buffers: shared hit=773
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.205..0.218 rows=47.00 loops=1)
          Buffers: shared hit=117
          ->  ProjectSet (actual time=0.204..0.206 rows=47.00 loops=1)
                Buffers: shared hit=117
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.488..3.493 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1428
        Index Searches: 1
        Buffers: shared hit=2371 read=3
Planning:
  Buffers: shared hit=115
Planning Time: 0.179 ms
Execution Time: 3.712 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.810..3.736 rows=50.00 loops=1)
  Buffers: shared hit=2590 read=3
  InitPlan 1
    ->  Result (actual time=2.476..2.489 rows=47.00 loops=1)
          Buffers: shared hit=881
          ->  ProjectSet (actual time=2.475..2.477 rows=47.00 loops=1)
                Buffers: shared hit=881
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.265..0.273 rows=20.00 loops=1)
          Buffers: shared hit=228
          ->  ProjectSet (actual time=0.259..0.261 rows=20.00 loops=1)
                Buffers: shared hit=228
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.810..3.732 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 1428
        Index Searches: 1
        Buffers: shared hit=2590 read=3
Planning:
  Buffers: shared hit=114
Planning Time: 0.204 ms
Execution Time: 3.993 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=10.578..10.582 rows=50.00 loops=1)
  Buffers: shared hit=6540
  InitPlan 1
    ->  Result (actual time=6.654..7.729 rows=4045.00 loops=1)
          Buffers: shared hit=4990
          ->  ProjectSet (actual time=6.653..6.782 rows=4045.00 loops=1)
                Buffers: shared hit=4990
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Sort (actual time=10.578..10.579 rows=50.00 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=6540
        ->  Bitmap Heap Scan on documents (actual time=9.364..10.344 rows=4045.00 loops=1)
              Recheck Cond: (id = ANY ((InitPlan 1).col1))
              Heap Blocks: exact=1133
              Buffers: shared hit=6537
              ->  Bitmap Index Scan on documents_pkey (actual time=9.294..9.294 rows=4045.00 loops=1)
                    Index Cond: (id = ANY ((InitPlan 1).col1))
                    Index Searches: 15
                    Buffers: shared hit=5404
Planning:
  Buffers: shared hit=109
Planning Time: 0.154 ms
Execution Time: 10.787 ms
```

