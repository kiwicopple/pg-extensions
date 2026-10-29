# Benchmark: b-policy-first (design b), medium scale, deep shape

- Date: 2026-10-29 12:14
- Postgres: 16.15 (Debian 16.15-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: deep (teams in chains 9 deep, users in the leaf teams, 5 documents per team)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.26 | 0.35 | 0.252 | 15903 | 1 | ok |
| rbac_select_page | 0.46 | 0.68 | 0.480 | 8332 | 2 | ok |
| rbac_select_count | 0.36 | 0.47 | 0.343 | 11667 | 2 | ok |
| rbac_update_one | 0.46 | 0.64 | 0.456 | 8774 | 3 | ok |
| write_assign_role | 0.15 | 0.23 | 0.166 | 24149 | 1 | ok |
| share_list_objects | 0.30 | 0.40 | 0.303 | 13191 | 1 | ok |
| share_select_page | 0.76 | 2.09 | 1.004 | 3982 | 3 | ok |
| write_share | 0.16 | 0.27 | 0.181 | 22124 | 1 | ok |
| parents_proj_select_page | 0.83 | 1.27 | 0.876 | 4564 | 4 | ok |
| parents_proj_select_count | 1.22 | 1.68 | 1.273 | 3141 | 4 | ok |
| parents_select_page | 6.37 | 10.76 | 6.979 | 573 | 25 | ok |
| parents_select_count | 4.89 | 7.16 | 5.218 | 766 | 23 | ok |
| write_nest_team | 0.64 | 0.75 | 0.669 | 5974 | 1 | ok |
| nest_check | 0.33 | 0.41 | 0.309 | 12938 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.53 | 3.9 | 10028 |
| sharing | 0.49 | 10.1 | 27985 |
| parents_proj | 0.06 | 10.6 | 29489 |
| parents | 4.36 | 46.5 | 129989 |
| nesting | 0.02 | 46.5 | 129999 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| ancestors | 0.02 MB, 0 rows | 0.34 MB, 772 rows | 0.34 MB, 772 rows | 0.50 MB, 1272 rows | 0.50 MB, 1281 rows |
| entities | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.02 MB, 0 rows |
| parents | 0.02 MB, 0 rows | 2.11 MB, 6177 rows | 2.27 MB, 6677 rows | 37.95 MB, 106677 rows | 37.95 MB, 106678 rows |
| policies | 0.08 MB, 6 rows | 0.08 MB, 8 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows | 0.08 MB, 10 rows |
| role_closure | 0.08 MB, 12 rows | 0.08 MB, 15 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows | 0.08 MB, 16 rows |
| role_grants | 3.56 MB, 10000 rows | 7.38 MB, 21000 rows | 7.73 MB, 22000 rows | 7.73 MB, 22000 rows | 7.73 MB, 22000 rows |
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
- vs design a (2026-10-29 12:11): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-29 08:35): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=3.116..3.994 rows=50 loops=1)
  Buffers: shared hit=2347 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=3.063..3.064 rows=2 loops=1)
          Buffers: shared hit=870
          ->  ProjectSet (actual time=3.062..3.063 rows=2 loops=1)
                Buffers: shared hit=870
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=3.115..3.991 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=2347 read=8
Planning:
  Buffers: shared hit=109
Planning Time: 0.174 ms
Execution Time: 4.231 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=6.883..8.088 rows=50 loops=1)
  Buffers: shared hit=2452 read=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=6.538..6.540 rows=2 loops=1)
          Buffers: shared hit=914
          ->  ProjectSet (actual time=6.536..6.537 rows=2 loops=1)
                Buffers: shared hit=914
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.272..0.286 rows=47 loops=1)
          Buffers: shared hit=58
          ->  ProjectSet (actual time=0.271..0.273 rows=47 loops=1)
                Buffers: shared hit=58
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=6.882..8.084 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2452 read=3
Planning:
  Buffers: shared hit=114
Planning Time: 0.204 ms
Execution Time: 8.359 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=4.349..5.512 rows=50 loops=1)
  Buffers: shared hit=2474 read=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=4.050..4.065 rows=47 loops=1)
          Buffers: shared hit=925
          ->  ProjectSet (actual time=4.049..4.051 rows=47 loops=1)
                Buffers: shared hit=925
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.219..0.225 rows=20 loops=1)
          Buffers: shared hit=69
          ->  ProjectSet (actual time=0.218..0.219 rows=20 loops=1)
                Buffers: shared hit=69
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=4.348..5.508 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=2474 read=3
Planning:
  Buffers: shared hit=111
Planning Time: 0.214 ms
Execution Time: 5.814 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=10.950..10.954 rows=50 loops=1)
  Buffers: shared hit=14347
  InitPlan 1 (returns $0)
    ->  Result (actual time=5.337..6.451 rows=4045 loops=1)
          Buffers: shared hit=1070
          ->  ProjectSet (actual time=5.334..5.462 rows=4045 loops=1)
                Buffers: shared hit=1070
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=10.949..10.951 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=14347
        ->  Bitmap Heap Scan on documents (actual time=9.055..10.698 rows=4045 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1136
              Buffers: shared hit=14344
              ->  Bitmap Index Scan on documents_pkey (actual time=8.972..8.973 rows=4045 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=13208
Planning:
  Buffers: shared hit=108
Planning Time: 0.182 ms
Execution Time: 11.351 ms
```

