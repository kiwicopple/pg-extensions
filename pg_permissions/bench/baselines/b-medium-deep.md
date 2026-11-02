# Benchmark: b-policy-first (design b), medium scale, deep shape

- Date: 2026-10-28 23:54
- Postgres: 16.4 (Postgres.app)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: deep (teams in chains 9 deep, users in the leaf teams, 5 documents per team)
- pgbench: 10s per workload, 4 clients
- Throwaway cluster with fsync off: write numbers are optimistic

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.32 | 0.40 | 0.331 | 12073 | - | - |
| rbac_select_page | 0.47 | 0.56 | 0.487 | 8220 | - | - |
| rbac_select_count | 0.42 | 0.66 | 0.450 | 8883 | - | - |
| rbac_update_one | 0.80 | 0.91 | 0.748 | 5348 | - | - |
| write_assign_role | 0.14 | 0.24 | 0.153 | 26175 | - | - |
| share_list_objects | 0.60 | 0.68 | 0.611 | 6550 | - | - |
| share_select_page | 2.04 | 2.18 | 2.052 | 1949 | - | - |
| write_share | 0.14 | 0.23 | 0.150 | 26691 | - | - |
| parents_proj_select_page | 1.37 | 1.51 | 1.381 | 2897 | - | - |
| parents_proj_select_count | 1.36 | 1.45 | 1.370 | 2920 | - | - |
| parents_select_page | 29.35 | 32.37 | 29.664 | 134 | - | - |
| parents_select_count | 28.24 | 31.05 | 28.544 | 140 | - | - |
| write_nest_team | 312.46 | 449.13 | 317.898 | 12 | - | - |
| nest_check | 2.54 | 2.77 | 2.558 | 1563 | - | - |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.68 | 2.9 | 10028 |
| sharing | 1.13 | 18.0 | 72466 |
| parents_proj | 0.13 | 18.5 | 74470 |
| parents | 15.33 | 92.2 | 374470 |
| nesting | 0.17 | 94.2 | 383480 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| ancestors | 0.02 MB, 0 rows | 10.38 MB, 45253 rows | 10.51 MB, 45753 rows | 59.59 MB, 245753 rows | 61.65 MB, 254762 rows |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| parents | 0.02 MB, 0 rows | 1.48 MB, 6177 rows | 1.60 MB, 6677 rows | 26.13 MB, 106677 rows | 26.13 MB, 106678 rows |
| policies | 0.08 MB, 6 rows | 0.08 MB, 8 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows |
| role_closure | 0.08 MB, 12 rows | 0.08 MB, 15 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows |
| role_grants | 2.54 MB, 10000 rows | 5.88 MB, 21000 rows | 6.13 MB, 22000 rows | 6.13 MB, 22000 rows | 6.13 MB, 22000 rows |
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
- vs design a (2026-10-28 23:51): parents_proj: same; rbac: same; parents: same; sharing: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.485..1.185 rows=50 loops=1)
  Buffers: shared hit=1507 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.460..0.461 rows=2 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.460..0.460 rows=2 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.484..1.183 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1507 read=8
Planning:
  Buffers: shared hit=815
Planning Time: 2.447 ms
Execution Time: 1.191 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.970..1.824 rows=50 loops=1)
  Buffers: shared hit=1684 read=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.505..0.506 rows=2 loops=1)
          Buffers: shared hit=102
          ->  ProjectSet (actual time=0.504..0.505 rows=2 loops=1)
                Buffers: shared hit=102
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.433..0.445 rows=47 loops=1)
          Buffers: shared hit=102
          ->  ProjectSet (actual time=0.433..0.434 rows=47 loops=1)
                Buffers: shared hit=102
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.970..1.822 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=1684 read=3
Planning:
  Buffers: shared hit=1002
Planning Time: 3.146 ms
Execution Time: 1.833 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=1.155..2.166 rows=50 loops=1)
  Buffers: shared hit=1726 read=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.630..0.642 rows=47 loops=1)
          Buffers: shared hit=123
          ->  ProjectSet (actual time=0.629..0.630 rows=47 loops=1)
                Buffers: shared hit=123
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.489..0.494 rows=20 loops=1)
          Buffers: shared hit=123
          ->  ProjectSet (actual time=0.488..0.489 rows=20 loops=1)
                Buffers: shared hit=123
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.155..2.164 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=1726 read=3
Planning:
  Buffers: shared hit=1048
Planning Time: 3.468 ms
Execution Time: 2.172 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=17.967..17.970 rows=50 loops=1)
  Buffers: shared hit=17074
  InitPlan 1 (returns $0)
    ->  Result (actual time=13.384..14.407 rows=4045 loops=1)
          Buffers: shared hit=3798
          ->  ProjectSet (actual time=13.382..13.480 rows=4045 loops=1)
                Buffers: shared hit=3798
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=17.966..17.967 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 30kB
        Buffers: shared hit=17074
        ->  Bitmap Heap Scan on documents (actual time=16.538..17.782 rows=4045 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1135
              Buffers: shared hit=17071
              ->  Bitmap Index Scan on documents_pkey (actual time=16.472..16.472 rows=4045 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=15936
Planning:
  Buffers: shared hit=4592
Planning Time: 16.987 ms
Execution Time: 17.984 ms
```

