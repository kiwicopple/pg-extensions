# Benchmark: a-tuple-core (design a), medium scale, deep shape

- Date: 2026-10-29 12:11
- Postgres: 16.15 (Debian 16.15-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: deep (teams in chains 9 deep, users in the leaf teams, 5 documents per team)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.32 | 0.45 | 0.327 | 12239 | 1 | ok |
| rbac_select_page | 0.48 | 0.73 | 0.499 | 8008 | 2 | ok |
| rbac_select_count | 0.41 | 0.95 | 0.475 | 8422 | 2 | ok |
| rbac_update_one | 0.59 | 0.84 | 0.594 | 6738 | 3 | ok |
| write_assign_role | 0.17 | 0.30 | 0.196 | 20401 | 1 | ok |
| share_list_objects | 0.34 | 0.46 | 0.337 | 11855 | 1 | ok |
| share_select_page | 0.83 | 1.21 | 0.884 | 4524 | 3 | ok |
| write_share | 0.16 | 0.24 | 0.173 | 23140 | 1 | ok |
| parents_proj_select_page | 1.06 | 1.30 | 1.086 | 3682 | 4 | ok |
| parents_proj_select_count | 1.43 | 1.79 | 1.474 | 2712 | 4 | ok |
| parents_select_page | 9.68 | 12.43 | 10.019 | 399 | 25 | ok |
| parents_select_count | 8.01 | 10.25 | 8.335 | 479 | 23 | ok |
| write_nest_team | 0.15 | 0.23 | 0.166 | 24112 | 1 | ok |
| nest_check | 0.30 | 0.40 | 0.296 | 13492 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.72 | 3.6 | 10020 |
| sharing | 0.44 | 9.5 | 27202 |
| parents_proj | 0.05 | 10.0 | 28705 |
| parents | 2.58 | 48.6 | 128706 |
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
- vs design b (2026-10-29 08:32): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 08:35): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=2.086..3.003 rows=50 loops=1)
  Buffers: shared hit=2198 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=2.020..2.021 rows=2 loops=1)
          Buffers: shared hit=721
          ->  ProjectSet (actual time=2.019..2.019 rows=2 loops=1)
                Buffers: shared hit=721
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.086..2.999 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=2198 read=8
Planning:
  Buffers: shared hit=109
Planning Time: 0.155 ms
Execution Time: 3.222 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=2.074..3.135 rows=50 loops=1)
  Buffers: shared hit=2392 read=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=1.795..1.796 rows=2 loops=1)
          Buffers: shared hit=792
          ->  ProjectSet (actual time=1.794..1.795 rows=2 loops=1)
                Buffers: shared hit=792
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.209..0.225 rows=47 loops=1)
          Buffers: shared hit=117
          ->  ProjectSet (actual time=0.209..0.211 rows=47 loops=1)
                Buffers: shared hit=117
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.073..3.131 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2392 read=3
Planning:
  Buffers: shared hit=114
Planning Time: 0.183 ms
Execution Time: 3.388 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=2.587..3.796 rows=50 loops=1)
  Buffers: shared hit=2611 read=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=2.192..2.207 rows=47 loops=1)
          Buffers: shared hit=900
          ->  ProjectSet (actual time=2.191..2.193 rows=47 loops=1)
                Buffers: shared hit=900
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.326..0.334 rows=20 loops=1)
          Buffers: shared hit=228
          ->  ProjectSet (actual time=0.325..0.326 rows=20 loops=1)
                Buffers: shared hit=228
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=2.586..3.791 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2611 read=3
Planning:
  Buffers: shared hit=111
Planning Time: 0.223 ms
Execution Time: 4.084 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=16.124..16.130 rows=50 loops=1)
  Buffers: shared hit=18280
  InitPlan 1 (returns $0)
    ->  Result (actual time=8.886..10.340 rows=4045 loops=1)
          Buffers: shared hit=5008
          ->  ProjectSet (actual time=8.883..9.051 rows=4045 loops=1)
                Buffers: shared hit=5008
                ->  Result (actual time=0.000..0.001 rows=1 loops=1)
  ->  Sort (actual time=16.123..16.125 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=18280
        ->  Bitmap Heap Scan on documents (actual time=13.186..15.757 rows=4045 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1131
              Buffers: shared hit=18277
              ->  Bitmap Index Scan on documents_pkey (actual time=13.112..13.112 rows=4045 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=17146
Planning:
  Buffers: shared hit=106
Planning Time: 0.226 ms
Execution Time: 16.462 ms
```

