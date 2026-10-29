# Benchmark: c-compiled-model (design c), large scale, default shape

- Date: 2026-10-29 08:12
- Postgres: 18.6 (Debian 18.6-1.pgdg13+2)
- Data: 1000000 documents, 10000 users, 100 orgs, 500 teams
- Shape: default (1 team(s) per user, 5 documents per team, 4-ary team tree)
- pgbench: 10s per workload, 4 clients

| workload | p50 ms | p95 ms | avg ms | tps | p95 budget ms | status |
| --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.25 | 0.32 | 0.243 | 16468 | 1 | ok |
| rbac_select_page | 0.73 | 0.96 | 0.757 | 5283 | 3 | ok |
| rbac_select_count | 0.82 | 1.02 | 0.823 | 4861 | 3 | ok |
| rbac_update_one | 0.45 | 0.57 | 0.434 | 9207 | 3 | ok |
| write_assign_role | 0.18 | 0.24 | 0.183 | 21820 | 1 | ok |
| share_list_objects | 0.26 | 0.35 | 0.261 | 15302 | 2 | ok |
| share_select_page | 1.00 | 1.41 | 1.053 | 3797 | 6 | ok |
| write_share | 0.17 | 0.23 | 0.175 | 22834 | 1 | ok |
| parents_proj_select_page | 1.05 | 1.54 | 1.098 | 3641 | 4 | ok |
| parents_proj_select_count | 7.48 | 8.50 | 7.559 | 529 | 9 | ok |
| parents_select_page | 9.26 | 11.13 | 9.529 | 419 | 32 | ok |
| parents_select_count | 16.91 | 24.90 | 18.253 | 219 | 70 | ok |
| write_nest_team | 299.65 | 359.34 | 277.485 | 14 | 1 | OVER |
| nest_check | 0.30 | 0.44 | 0.299 | 13391 | 2 | ok |

## Seed time and storage

Seed time is the native-API load only. Sizes are `pg_total_relation_size` (table, indexes, toast) of every table in schema `permissions` after the seed and `VACUUM FULL` (non-empty tables only, see `vacuum_nonempty` in run.sh), cumulative across phases.

| phase | seed s | permission tables MB | rows |
| --- | --- | --- | --- |
| rbac | 4.86 | 5.3 | 20053 |
| sharing | 4.08 | 21.3 | 98346 |
| parents_proj | 0.30 | 22.3 | 102365 |
| parents | 17.13 | 182.4 | 1102365 |
| nesting | 0.06 | 183.2 | 1107366 |

| table | after rbac | after sharing | after parents_proj | after parents | after nesting |
| --- | --- | --- | --- | --- | --- |
| allowed_subjects | 0.05 MB, 6 rows | 0.05 MB, 12 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows | 0.05 MB, 13 rows |
| ancestors | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.26 MB, 1000 rows | 0.26 MB, 1000 rows | 0.26 MB, 1000 rows |
| memberships | 0.02 MB, 0 rows | 7.95 MB, 44280 rows | 7.95 MB, 44280 rows | 7.95 MB, 44280 rows | 8.82 MB, 49280 rows |
| models | 0.06 MB, 4 rows | 0.06 MB, 5 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows | 0.06 MB, 6 rows |
| parent_types | 0.01 MB, 0 rows | 0.01 MB, 0 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows | 0.05 MB, 2 rows |
| parents | 0.02 MB, 0 rows | 0.02 MB, 0 rows | 0.23 MB, 1000 rows | 160.27 MB, 1001000 rows | 160.27 MB, 1001000 rows |
| relations | 0.08 MB, 14 rows | 0.08 MB, 17 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows | 0.08 MB, 20 rows |
| satisfies | 0.05 MB, 26 rows | 0.05 MB, 30 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows | 0.05 MB, 41 rows |
| tuples | 4.88 MB, 20000 rows | 13.02 MB, 53997 rows | 13.49 MB, 55997 rows | 13.49 MB, 55997 rows | 13.49 MB, 55998 rows |
| types | 0.08 MB, 3 rows | 0.08 MB, 5 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows | 0.08 MB, 6 rows |

## Equivalence

Documents each sample user sees through RLS after each seed, and the md5 of their sorted ids. Every 5th user is also a folder viewer, so for users not divisible by 5 parents_proj and parents must equal sharing, and parents_proj must always equal parents.

| policy | user | visible | md5 |
| --- | --- | --- | --- |
| rbac | 1 | 20000 | 83dfc8a4117363cd29474848ec593462 |
| rbac | 2 | 20000 | e011f33abf8ec3609fe7413a636dafb7 |
| rbac | 3 | 20000 | 5466f182950003a321d8658d12e38760 |
| rbac | 5 | 20000 | 694e0998e6843b06e6d8c4f5b4d88795 |
| rbac | 10 | 20000 | 821fd2c6b79483746aab43841450b9c6 |
| rbac | 77 | 20000 | 43afbd5eee1be997db26e1ca9a889aa3 |
| rbac | 500 | 20000 | 0561304ca98a061cdf6a51a7d82459e6 |
| rbac | 10000 | 20000 | 0561304ca98a061cdf6a51a7d82459e6 |
| sharing | 1 | 20007 | d2b4030ad636f968f35a8af5008ac9f6 |
| sharing | 2 | 20007 | abb87f25aaf62620d8b791efa17462b4 |
| sharing | 3 | 20012 | b4c68ea1387b14cdb659ac1be1bc314a |
| sharing | 5 | 20012 | 033a5195f5d6c532f52c9cd816196a27 |
| sharing | 10 | 20012 | e01f45d54102a2059611bc18421a6fc3 |
| sharing | 77 | 20022 | eb1cd8028cf96891dd907c58dd08b89f |
| sharing | 500 | 20007 | abc7fbfa02e70e61e8a0b57bc01c375f |
| sharing | 10000 | 20007 | b91916b3d484d728f128f79576324a38 |
| parents_proj | 1 | 20007 | d2b4030ad636f968f35a8af5008ac9f6 |
| parents_proj | 2 | 20007 | abb87f25aaf62620d8b791efa17462b4 |
| parents_proj | 3 | 20012 | b4c68ea1387b14cdb659ac1be1bc314a |
| parents_proj | 5 | 21012 | 62038fc0969395160b3e96933ddac9e4 |
| parents_proj | 10 | 21012 | 447d15cf1ccb48b8a791f10de5616989 |
| parents_proj | 77 | 20022 | eb1cd8028cf96891dd907c58dd08b89f |
| parents_proj | 500 | 21007 | d357b76a845e832d77fdd55403df4e56 |
| parents_proj | 10000 | 21007 | 24fc32209c7c854bc0f098b1e1d6940d |
| parents | 1 | 20007 | d2b4030ad636f968f35a8af5008ac9f6 |
| parents | 2 | 20007 | abb87f25aaf62620d8b791efa17462b4 |
| parents | 3 | 20012 | b4c68ea1387b14cdb659ac1be1bc314a |
| parents | 5 | 21012 | 62038fc0969395160b3e96933ddac9e4 |
| parents | 10 | 21012 | 447d15cf1ccb48b8a791f10de5616989 |
| parents | 77 | 20022 | eb1cd8028cf96891dd907c58dd08b89f |
| parents | 500 | 21007 | d357b76a845e832d77fdd55403df4e56 |
| parents | 10000 | 21007 | 24fc32209c7c854bc0f098b1e1d6940d |

Compared with other designs' latest runs at this scale and shape:
- vs design a (2026-10-29 08:04): parents_proj: same; parents: same; sharing: same; rbac: same
- vs design b (2026-10-29 08:09): parents_proj: same; parents: same; sharing: same; rbac: same

## Query plans

### rbac_select_page (RBAC policy, user 1)

```
Limit (actual time=1.273..4.589 rows=50.00 loops=1)
  Buffers: shared hit=2750 read=13
  InitPlan 1
    ->  Result (actual time=1.143..1.144 rows=2.00 loops=1)
          Buffers: shared hit=82
          ->  ProjectSet (actual time=1.142..1.143 rows=2.00 loops=1)
                Buffers: shared hit=82
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  ->  Index Scan using documents_pkey on documents (actual time=1.273..4.585 rows=50.00 loops=1)
        Filter: (org_id = ANY ((InitPlan 1).col1))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=2750 read=13
Planning:
  Buffers: shared hit=1128
Planning Time: 4.044 ms
Execution Time: 4.595 ms
```

### share_select_page (two-branch policy, user 1)

```
Limit (actual time=1.370..5.019 rows=50.00 loops=1)
  Buffers: shared hit=2818 read=12
  InitPlan 1
    ->  Result (actual time=0.859..0.860 rows=2.00 loops=1)
          Buffers: shared hit=104
          ->  ProjectSet (actual time=0.858..0.859 rows=2.00 loops=1)
                Buffers: shared hit=104
                ->  Result (actual time=0.000..0.000 rows=1.00 loops=1)
  InitPlan 2
    ->  Result (actual time=0.393..0.393 rows=1.00 loops=1)
          Buffers: shared hit=45
  ->  Index Scan using documents_pkey on documents (actual time=1.369..5.015 rows=50.00 loops=1)
        Filter: ((org_id = ANY ((InitPlan 1).col1)) OR (id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=2818 read=12
Planning:
  Buffers: shared hit=1159
Planning Time: 3.494 ms
Execution Time: 5.027 ms
```

### parents_proj_select_page (two-arm projection policy, user 1)

```
Limit (actual time=3.134..7.170 rows=50.00 loops=1)
  Buffers: shared hit=3756 read=12
  InitPlan 1
    ->  Result (actual time=2.241..2.242 rows=1.00 loops=1)
          Buffers: shared hit=978
  InitPlan 2
    ->  Result (actual time=0.706..0.707 rows=1.00 loops=1)
          Buffers: shared hit=109
  ->  Index Scan using documents_pkey on documents (actual time=3.133..7.165 rows=50.00 loops=1)
        Filter: ((id = ANY ((InitPlan 1).col1)) OR (folder_id = ANY ((InitPlan 2).col1)))
        Rows Removed by Filter: 2619
        Index Searches: 1
        Buffers: shared hit=3756 read=12
Planning:
  Buffers: shared hit=108
Planning Time: 0.196 ms
Execution Time: 7.184 ms
```

### parents_select_page (single-branch policy, user 1)

```
Limit (actual time=11.585..11.845 rows=50.00 loops=1)
  Buffers: shared hit=1269 read=40
  InitPlan 1
    ->  Result (actual time=8.869..8.869 rows=1.00 loops=1)
          Buffers: shared hit=1226
  ->  Index Scan using documents_pkey on documents (actual time=11.584..11.840 rows=50.00 loops=1)
        Index Cond: (id = ANY ((InitPlan 1).col1))
        Index Searches: 11
        Buffers: shared hit=1269 read=40
Planning:
  Buffers: shared hit=103
Planning Time: 0.125 ms
Execution Time: 11.855 ms
```

