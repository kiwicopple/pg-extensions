# Benchmark: b-policy-first (design b), medium scale, deep shape

- Date: 2026-10-29 08:17
- Postgres: 16.15 (Debian 16.15-1.pgdg13+2)
- Data: 100000 documents, 5000 users, 50 orgs, 200 teams
- Shape: deep (teams in chains 9 deep, users in the leaf teams, 5 documents per team)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.35 | 0.44 | 0.343 | 11671 | 1 | ok |
| rbac_select_page | 0.56 | 0.69 | 0.561 | 7125 | 2 | ok |
| rbac_select_count | 0.45 | 0.55 | 0.434 | 9213 | 2 | ok |
| rbac_update_one | 0.79 | 0.95 | 0.765 | 5231 | 3 | ok |
| write_assign_role | 0.16 | 0.22 | 0.167 | 23942 | 1 | ok |
| share_list_objects | 0.48 | 0.57 | 0.466 | 8574 | 1 | ok |
| share_select_page | 1.65 | 1.98 | 1.679 | 2382 | 3 | ok |
| write_share | 0.15 | 0.22 | 0.163 | 24594 | 1 | ok |
| parents_proj_select_page | 1.15 | 1.43 | 1.176 | 3401 | 4 | ok |
| parents_proj_select_count | 1.49 | 1.80 | 1.522 | 2628 | 4 | ok |
| parents_select_page | 12.57 | 14.64 | 12.812 | 312 | 25 | ok |
| parents_select_count | 11.14 | 13.14 | 11.396 | 351 | 23 | ok |
| write_nest_team | 136.33 | 197.75 | 136.650 | 29 | 1 | OVER |
| nest_check | 1.31 | 1.54 | 1.337 | 2992 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 0.54 | 2.9 | 10028 |
| sharing | 0.68 | 18.0 | 72466 |
| parents_proj | 0.08 | 18.5 | 74470 |
| parents | 11.53 | 92.2 | 374470 |
| nesting | 0.08 | 94.2 | 383480 |

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
- vs design a (2026-10-29 08:15): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design c (2026-10-28 23:57): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=0.555..1.457 rows=50 loops=1)
  Buffers: shared hit=1507 read=8
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.513..0.514 rows=2 loops=1)
          Buffers: shared hit=30
          ->  ProjectSet (actual time=0.512..0.513 rows=2 loops=1)
                Buffers: shared hit=30
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.554..1.454 rows=50 loops=1)
        Filter: (org_id = ANY ($0))
        Rows Removed by Filter: 1429
        Buffers: shared hit=1507 read=8
Planning:
  Buffers: shared hit=815
Planning Time: 2.060 ms
Execution Time: 1.464 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=0.825..1.827 rows=50 loops=1)
  Buffers: shared hit=1686 read=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.466..0.467 rows=2 loops=1)
          Buffers: shared hit=102
          ->  ProjectSet (actual time=0.465..0.466 rows=2 loops=1)
                Buffers: shared hit=102
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.315..0.328 rows=47 loops=1)
          Buffers: shared hit=102
          ->  ProjectSet (actual time=0.314..0.316 rows=47 loops=1)
                Buffers: shared hit=102
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.825..1.823 rows=50 loops=1)
        Filter: ((org_id = ANY ($0)) OR (id = ANY ($1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=1686 read=3
Planning:
  Buffers: shared hit=1002
Planning Time: 2.763 ms
Execution Time: 1.841 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=0.943..1.946 rows=50 loops=1)
  Buffers: shared hit=1728 read=3
  InitPlan 1 (returns $0)
    ->  Result (actual time=0.549..0.564 rows=47 loops=1)
          Buffers: shared hit=123
          ->  ProjectSet (actual time=0.548..0.550 rows=47 loops=1)
                Buffers: shared hit=123
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  InitPlan 2 (returns $1)
    ->  Result (actual time=0.342..0.349 rows=20 loops=1)
          Buffers: shared hit=123
          ->  ProjectSet (actual time=0.342..0.343 rows=20 loops=1)
                Buffers: shared hit=123
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=0.943..1.942 rows=50 loops=1)
        Filter: ((id = ANY ($0)) OR (folder_id = ANY ($1)))
        Rows Removed by Filter: 1428
        Buffers: shared hit=1728 read=3
Planning:
  Buffers: shared hit=1048
Planning Time: 2.903 ms
Execution Time: 1.954 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=8.767..8.771 rows=50 loops=1)
  Buffers: shared hit=17080
  InitPlan 1 (returns $0)
    ->  Result (actual time=3.959..5.228 rows=4045 loops=1)
          Buffers: shared hit=3806
          ->  ProjectSet (actual time=3.952..4.079 rows=4045 loops=1)
                Buffers: shared hit=3806
                ->  Result (actual time=0.000..0.000 rows=1 loops=1)
  ->  Sort (actual time=8.767..8.768 rows=50 loops=1)
        Sort Key: documents.id
        Sort Method: top-N heapsort  Memory: 31kB
        Buffers: shared hit=17080
        ->  Bitmap Heap Scan on documents (actual time=7.254..8.566 rows=4045 loops=1)
              Recheck Cond: (id = ANY ($0))
              Heap Blocks: exact=1133
              Buffers: shared hit=17077
              ->  Bitmap Index Scan on documents_pkey (actual time=7.183..7.183 rows=4045 loops=1)
                    Index Cond: (id = ANY ($0))
                    Buffers: shared hit=15944
Planning:
  Buffers: shared hit=4600
Planning Time: 7.857 ms
Execution Time: 8.779 ms
```

