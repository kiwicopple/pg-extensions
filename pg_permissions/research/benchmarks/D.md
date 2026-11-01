# Design D benchmarked

Design D is the extension. This file gives its benchmark results. The design is in [`../designs/d-per-model.md`](../designs/d-per-model.md). The code is in [`../../pg_permissions--0.0.1.sql`](../../pg_permissions--0.0.1.sql), which was `prototypes/d-per-model.sql` when we measured it.

We measured design D on 2026-10-29 with the same workloads, scales and shapes as A, B and C. We compared the results with their optimized runs from session 3 in [`OPTIMIZATIONS.md`](./OPTIMIZATIONS.md). The setup is the same. It uses Docker, Postgres 18.6 with pg_tle 1.5.3, `cpus: 4`, `mem_limit: 6g`, 4 pgbench clients, 10 s for each workload and one run for each configuration. Each run was strictly serial. The command was `docker/run-matrix.sh bench --versions 18 --designs d -- --scale <s> --shape <sh> --tag opt --check`.

The D files have the `opt` tag. So they are next to the files of A, B and C in the primary series of the docs site. The names are `pg18-docker-d-{large-default,medium-deep,medium-wide}-opt.{md,json}`. In this first measurement D was not optimized, and we did not change the prototype.

The second pass acts on the diagnosis below. It is in section "opt2". The reports are in [`../../bench/baselines/`](../../bench/baselines/).

## Summary

- **Correct everywhere.** Every read policy gives the same checksum as A, B and C in all three Docker configurations. This also holds in small default, deep and wide on local Postgres 16.4. We ran those before we measured time.
- **RBAC: as fast as the fastest design.** The `rbac_*` tables give the best or tied-best `rbac_check` (0.21-0.22 ms) in all configurations. They also give the best or tied-best `rbac_update_one` (0.27-0.28 ms, 20-30% under C).
- **Default and deep shapes: D is 1.1-2.8x slower than the best of A, B and C on FGA reads, but within budget.** There are two exceptions: `share_list_objects` at medium deep (p95 1.02 ms against 1 ms), and the large `parents_proj_select_count` miss that all four designs share. Writes of D take 1.5x the time of A (0.23 against 0.15 ms). They are much faster than the nesting write of C (0.23 against 58-75 ms).
- **Wide shape: D is the slowest design.** `share_list_objects` takes 17.8 ms against 3.4-8.4 ms. The sharing page takes 26 ms against 8-18 ms. The two-arm parents page takes 38.6 ms against 8.7-15 ms. D has four budget misses.
- **Do not compare the single-branch parents rows directly.** D takes 1.4 ms and A takes 45.6 ms at large. D keeps org roles in `rbac_*` and composes the two models. So the FGA walk of D never visits the org-role documents that A, B and C walk to. Copy the org roles into FGA, as in the scenario of A. Then ListObjects of D for the same users takes 52 ms for each call, against 45.6 ms for the page of A (Diagnosis, item 4).
- **Worst hotspot: ListObjects on a relation with `but not`.** The benchmark model does not have such a relation. We measured it separately on the wide data. It takes 2.1 s for each call, against 17 ms for the monotone relation. There are 6,700 candidates, and each is a full top-down Check.
- **Storage:** 285 MB at large after the parents seed. This is between C (182 MB) and B or A (378 and 404 MB). Seeds through the native Write API take about the same time as A. For large parents: D 33.8 s, A 31.0 s, B 44.8 s, C 17.6 s.
- **Phase 6 (section below):** We measured small and medium, and changed the large budget. D is within 1.1x of the best design on reads at medium and large, and within 1.0-1.4x at small. D is the slowest on Check (0.37-0.38 ms against 0.25-0.34 ms). D has no budget miss at small or medium.

  The large `parents_proj_select_count` budget changed from 9 to 20 ms for every design. The p50 of 7.5-9.4 ms is a heap-fetch floor, and the worst p95 ever measured is 16.1 ms. `--check` at large passes.
- **opt3 (phase 5 of session 5; section below):** ListObjects for non-monotone relations is now set-based over the rewrite tree. Wide `viewer but not (blocked or muted)` changed from 5.2 s to 7.6 ms, and `editor and viewer` from 621 to 6.1 ms. Typed writes changed from 0.25 to 0.16 ms, and the large parents seed from 33 to 15 s. Check changed from 0.45-0.47 to 0.40 ms at medium.

  The code now evaluates conditions once for each distinct context. Wide conditioned ListObjects changed from 14.8 to 10.6 ms, and with a context for each tuple from 3.2 s to 0.17 s. We measured the covering index and left the decision to the user (+120 MB at large, no pgbench gain). The checksums are the same as A, B and C.
- **opt2 (second pass; section below):** We applied the fixes from "Diagnosis" (pruned CTE walk, set-based `but not`) and measured in the same way. Wide FGA reads are 2.2-4x faster. They are now 1.2-1.5x the best of A, B and C, and faster than A on every wide page. Deep ListObjects changed from 0.78 to 0.33 ms.

  No budget miss remains, except the large one that all designs share. `but not` ListObjects changed from 2.1 s to 4.2 ms. Check and writes did not change.

## Phase 6: small, medium and large across the four designs (2026-10-30)

Phase 6 of [`../plan.md`](../plan.md) ("loose ends") had two problems. First, nobody had measured the small and medium default shapes after the optimizations. Second, the large `parents_proj_select_count` budget missed for every design. The tag is `p6`.

The reports are `pg18-docker-{d,a,b,c}-{small,medium,large}-default-p6.md` (JSON in `data/`), and `pg18-docker-d-large-default-p6check.md` (the `--check` run, below). D is `pg_permissions--0.0.1.sql` at `f5a25a7`, after the API rename. The d seed and the workloads of the benchmark call the `rbac_*` names. A, B and C are the prototypes.

The setup is the same as in opt3: Docker, Postgres 18.6, pg_tle 1.5.3, `cpus: 4`, `mem_limit: 6g`, 4 pgbench clients, and 10 s for each workload. We did one run at a time with `docker/run-matrix.sh bench --versions 18 --designs <d> -- --scale <s> --tag p6 --check`. We ran nothing else. The budgets in the tables are the budgets in force when each run started. The large `parents_proj_select_count` budget was still 9 ms.

**What else ran on the machine.** We ran `docker ps` and `uptime` before every run. [`../journal.md`](../journal.md) has a summary. The unrelated `supabase_*_swarm-new` stack was idle.

`freereps-local-*` was idle. `gallant_ritchie` (openfga) was idle. From 15:37 a second unrelated Supabase stack (`supabase_*_agar`) ran on the same machine. It was idle after its start (about 10% of one CPU across all containers), but it caused noise while it started.

Someone used the laptop itself (Chrome, Notion). The host load average was 4-8 at the start of each kept run, and 15-21 during the discarded runs.

**We discarded one batch.** The first small batch (15:28-15:40, D, A, B, C) ran when the machine was busy. The C run, and a medium D run that started right after it, overlapped the start of the `agar` stack. On every design the p95 values were 2-5x their p50 values.

A, B and C missed 11, 6 and 11 budgets at small. For example, the `rbac_check` p95 of A was 1.59 against 1 ms. D missed one budget (`nest_check` p95 3.59 ms). We killed the medium D run.

We waited about 11 minutes and polled `docker stats` until the other stacks were idle. Then we ran everything again in this order: small C, medium D/A/B/C, small D/A/B/C, large D/A/B/C and large D check. The second small run makes the four small runs share a batch. The reports of the discarded runs were only in the git-ignored `bench/results/`.

The numbers below are from the clean batch. The large numbers agree with the p50 values of the opt3 section for every design. For example, `parents_select_count` changed from 7.59 to 7.76 ms for D and from 75.08 to 69.89 ms for A. It changed from 21.57 to 21.21 ms for B and from 11.88 to 11.45 ms for C. The first value is from D opt3 or from A, B and C `opt`. The second value is from `p6`.

All values are p50 / p95 in ms. The column "D against best of A/B/C" is the p50 of D divided by the best p50 of A, B and C. At small, most rows are 0.2-0.6 ms, so a ratio of 1.8x is only 0.06 ms.

#### Small (10k documents), default shape

<!-- reports: pg18-docker-{d,a,b,c}-small-default-p6.md -->

| workload | D p50 / p95 | A p50 / p95 | B p50 / p95 | C p50 / p95 | D against best of A/B/C (p50) | budget p95 | over budget |
| --- | --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.20 / 0.29 | 0.17 / 0.61 | 0.25 / 0.45 | 0.24 / 0.39 | 1.2x | 1 | none |
| rbac_select_page | 0.28 / 0.38 | 0.23 / 0.81 | 0.33 / 0.46 | 0.30 / 0.43 | 1.2x | 2 | none |
| rbac_select_count | 0.24 / 0.33 | 0.17 / 0.64 | 0.29 / 0.38 | 0.25 / 0.49 | 1.4x | 2 | none |
| rbac_update_one | 0.26 / 0.40 | 0.49 / 1.32 | 0.43 / 0.66 | 0.36 / 0.84 | 0.7x | 4 | none |
| write_assign_role | 0.14 / 0.23 | 0.08 / 0.32 | 0.14 / 0.20 | 0.17 / 0.41 | 1.8x | 1 | none |
| share_list_objects | 0.28 / 0.46 | 0.26 / 0.51 | 0.28 / 0.38 | 0.23 / 0.48 | 1.2x | 2 | none |
| share_select_page | 0.39 / 0.54 | 0.46 / 0.71 | 0.47 / 0.92 | 0.39 / 0.64 | 1.0x | 5 | none |
| write_share | 0.15 / 0.26 | 0.14 / 0.23 | 0.14 / 0.23 | 0.17 / 0.40 | 1.1x | 1 | none |
| parents_proj_select_page | 0.46 / 0.88 | 0.64 / 0.99 | 0.53 / 1.16 | 0.46 / 1.11 | 1.0x | 2 | none |
| parents_proj_select_count | 0.44 / 0.63 | 0.62 / 0.98 | 0.51 / 0.94 | 0.44 / 1.04 | 1.0x | 2 | none |
| parents_select_page | 0.41 / 0.63 | 2.68 / 4.03 | 1.21 / 1.86 | 0.74 / 1.58 | 0.6x | 4 | A |
| parents_select_count | 0.40 / 1.03 | 2.52 / 3.22 | 1.11 / 1.57 | 0.63 / 1.24 | 0.6x | 4 | none |
| write_nest_team | 0.13 / 0.35 | 0.14 / 0.28 | 0.81 / 1.27 | 32.03 / 44.74 | 0.9x | 1 | B, C |
| nest_check | 0.37 / 0.99 | 0.33 / 0.79 | 0.30 / 0.47 | 0.25 / 0.49 | 1.5x | 1 | none |

#### Medium (100k documents), default shape

<!-- reports: pg18-docker-{d,a,b,c}-medium-default-p6.md -->

| workload | D p50 / p95 | A p50 / p95 | B p50 / p95 | C p50 / p95 | D against best of A/B/C (p50) | budget p95 | over budget |
| --- | --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.15 / 0.38 | 0.28 / 0.67 | 0.27 / 0.37 | 0.24 / 0.35 | 0.6x | 1 | none |
| rbac_select_page | 0.38 / 0.95 | 0.43 / 1.12 | 0.46 / 0.81 | 0.41 / 0.56 | 0.9x | 2 | none |
| rbac_select_count | 0.30 / 0.45 | 0.34 / 0.59 | 0.33 / 0.76 | 0.33 / 0.44 | 0.9x | 2 | none |
| rbac_update_one | 0.27 / 0.46 | 0.53 / 1.49 | 0.46 / 0.98 | 0.34 / 0.47 | 0.8x | 3 | none |
| write_assign_role | 0.13 / 0.23 | 0.16 / 0.33 | 0.14 / 0.27 | 0.17 / 0.28 | 0.9x | 1 | none |
| share_list_objects | 0.28 / 0.37 | 0.29 / 0.47 | 0.29 / 0.39 | 0.25 / 0.33 | 1.1x | 1 | none |
| share_select_page | 0.57 / 1.18 | 0.65 / 1.14 | 0.64 / 1.32 | 0.54 / 0.75 | 1.1x | 3 | none |
| write_share | 0.15 / 0.27 | 0.15 / 0.26 | 0.06 / 0.25 | 0.17 / 0.34 | 2.5x | 1 | none |
| parents_proj_select_page | 0.64 / 0.84 | 0.86 / 1.15 | 0.73 / 1.17 | 0.65 / 1.74 | 1.0x | 3 | none |
| parents_proj_select_count | 0.95 / 1.31 | 1.16 / 1.62 | 1.09 / 2.37 | 0.91 / 1.51 | 1.0x | 3 | none |
| parents_select_page | 0.61 / 1.43 | 7.26 / 10.27 | 4.41 / 5.90 | 2.77 / 3.92 | 0.2x | 16 | none |
| parents_select_count | 0.91 / 1.42 | 6.26 / 8.19 | 3.67 / 4.62 | 2.03 / 2.54 | 0.4x | 14 | none |
| write_nest_team | 0.15 / 0.26 | 0.15 / 0.22 | 0.69 / 0.78 | 44.98 / 54.07 | 1.0x | 1 | C |
| nest_check | 0.38 / 0.51 | 0.34 / 0.46 | 0.32 / 0.42 | 0.29 / 0.38 | 1.3x | 1 | none |

#### Large (1M documents), default shape

<!-- reports: pg18-docker-{d,a,b,c}-large-default-p6.md -->

| workload | D p50 / p95 | A p50 / p95 | B p50 / p95 | C p50 / p95 | D against best of A/B/C (p50) | budget p95 | over budget |
| --- | --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.17 / 0.38 | 0.27 / 0.48 | 0.27 / 0.35 | 0.25 / 0.37 | 0.7x | 1 | none |
| rbac_select_page | 0.72 / 2.06 | 0.74 / 1.96 | 0.71 / 0.92 | 0.69 / 0.96 | 1.0x | 3 | none |
| rbac_select_count | 0.76 / 1.56 | 0.79 / 1.41 | 0.78 / 1.02 | 0.77 / 1.19 | 1.0x | 3 | none |
| rbac_update_one | 0.24 / 0.54 | 0.52 / 1.09 | 0.40 / 0.57 | 0.35 / 0.49 | 0.7x | 3 | none |
| write_assign_role | 0.12 / 0.27 | 0.14 / 0.27 | 0.14 / 0.21 | 0.18 / 0.24 | 0.9x | 1 | none |
| share_list_objects | 0.27 / 0.62 | 0.28 / 0.67 | 0.28 / 0.39 | 0.26 / 0.35 | 1.0x | 2 | none |
| share_select_page | 1.05 / 2.38 | 1.06 / 1.90 | 1.00 / 1.27 | 0.94 / 1.31 | 1.1x | 6 | none |
| write_share | 0.14 / 0.33 | 0.14 / 0.24 | 0.14 / 0.20 | 0.17 / 0.25 | 1.0x | 1 | none |
| parents_proj_select_page | 1.04 / 1.90 | 1.36 / 3.11 | 1.15 / 1.56 | 1.04 / 1.50 | 1.0x | 4 | none |
| parents_proj_select_count | 7.89 / 13.25 | 8.70 / 16.10 | 7.74 / 8.49 | 7.50 / 8.21 | 1.1x | 9 | D, A |
| parents_select_page | 1.05 / 6.99 | 43.54 / 57.54 | 13.46 / 16.38 | 4.71 / 6.43 | 0.2x | 32 | A |
| parents_select_count | 7.76 / 13.26 | 69.89 / 80.93 | 21.21 / 26.61 | 11.45 / 14.47 | 0.7x | 70 | A |
| write_nest_team | 0.15 / 0.29 | 0.14 / 0.21 | 0.61 / 0.70 | 53.69 / 66.33 | 1.1x | 1 | C |
| nest_check | 0.38 / 0.66 | 0.29 / 0.41 | 0.32 / 0.41 | 0.30 / 0.41 | 1.3x | 2 | none |

#### D-only workloads (conditions and non-monotone relations), p50 / p95 ms

| workload | small | medium | large |
| --- | --- | --- | --- |
| plain_list_objects | 0.17 / 0.60 | 0.29 / 0.52 | 0.33 / 1.94 |
| cond_list_objects | 0.43 / 1.20 | 0.46 / 0.87 | 0.65 / 3.08 |
| cond_select_page | 0.61 / 1.68 | 0.85 / 2.19 | 1.51 / 8.47 |
| cond_nest_check | 0.58 / 1.63 | 0.57 / 1.29 | 0.56 / 1.24 |
| plain_list_users | 0.36 / 2.61 | 0.31 / 1.74 | 0.33 / 1.57 |
| cond_list_users | 0.59 / 3.49 | 0.46 / 2.13 | 0.52 / 2.36 |
| block_list_objects | 0.26 / 0.88 | 0.37 / 0.88 | 0.42 / 2.31 |
| block_or_mute_list_objects | 0.63 / 1.58 | 0.59 / 1.08 | 0.54 / 2.62 |
| intersect_list_objects | 0.35 / 1.01 | 0.41 / 1.10 | 0.49 / 2.68 |

The table shows the seed time (s) and the cumulative size of the `permissions` tables (MB) after each phase. The later phases of D (conditions, blocklist) have no counterpart in A, B and C. Compare through `nesting`.

| scale | design | rbac | sharing | parents_proj | parents | nesting | conditions | blocklist |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| small | D | 0.06 / 1.1 | 0.37 / 3.2 | 0.02 / 3.3 | 0.14 / 6.3 | 0.02 / 6.3 | 0.43 / 7.3 | 0.31 / 8.1 |
| small | A | 0.10 / 1.0 | 0.12 / 2.5 | 0.02 / 2.6 | 0.21 / 6.5 | 0.02 / 6.5 |  |  |
| small | B | 0.09 / 1.1 | 0.16 / 2.7 | 0.03 / 2.8 | 0.60 / 6.5 | 0.02 / 6.5 |  |  |
| small | C | 0.15 / 1.0 | 0.58 / 2.7 | 0.08 / 3.0 | 0.17 / 4.6 | 0.11 / 5.1 |  |  |
| medium | D | 0.44 / 3.0 | 0.59 / 9.6 | 0.03 / 10.0 | 1.43 / 40.6 | 0.01 / 40.6 | 0.59 / 43.5 | 0.48 / 47.2 |
| medium | A | 0.60 / 3.6 | 0.42 / 9.5 | 0.05 / 10.1 | 2.17 / 48.6 | 0.02 / 48.6 |  |  |
| medium | B | 0.55 / 3.9 | 0.46 / 10.0 | 0.05 / 10.6 | 3.73 / 46.4 | 0.02 / 46.4 |  |  |
| medium | C | 0.78 / 2.9 | 0.95 / 10.4 | 0.15 / 11.0 | 1.60 / 27.0 | 0.03 / 27.8 |  |  |
| large | D | 4.39 / 5.4 | 1.04 / 17.9 | 0.05 / 18.6 | 15.35 / 323.7 | 0.02 / 323.7 | 1.37 / 329.5 | 0.78 / 337.0 |
| large | A | 4.71 / 7.0 | 1.06 / 18.7 | 0.07 / 19.6 | 29.76 / 404.3 | 0.03 / 404.3 |  |  |
| large | B | 3.82 / 7.4 | 0.82 / 19.6 | 0.10 / 20.6 | 43.26 / 377.9 | 0.02 / 377.9 |  |  |
| large | C | 4.43 / 5.3 | 1.86 / 21.3 | 0.30 / 22.3 | 16.83 / 182.4 | 0.04 / 183.2 |  |  |

**Checksums** (for each read policy, from the output of each run) are the same for D, A, B and C at all three scales. The conditions phase of D gives the same checksum as its parents phase.

| scale | rbac | sharing | parents_proj = parents |
| --- | --- | --- | --- |
| small | `8d25a1e0` | `577076ec` | `ca5b4e06` |
| medium | `d394663f` | `9b43a472` | `afbedca5` |
| large | `2e1dd348` | `58a66d1d` | `bffa5242` |

### What the three scales show

- **D is within 1.1x of the best design on every read at medium and large, except Check.**
  At small, every design answers in less than 1 ms (p50 0.2-0.6 ms on the common rows). At small, D is 1.0-1.4x the best on the RBAC and sharing reads. The difference is 0.03-0.07 ms. Its single-branch parents policy (`parents_select_*`) takes 0.4 ms against 2.5-2.7 ms for A. The gap opens with scale.
- The `parents_select_count` p50 values at small, medium and large are as follows. D: 0.40, 0.91 and 7.76 ms. A: 2.52, 6.26 and 69.89 ms. B: 1.11, 3.67 and 21.21 ms. C: 0.63, 2.03 and 11.45 ms.
- **Check is the one workload where D is slower.** `nest_check` takes 0.37-0.38 ms at every scale. This is 1.3-1.5x A, B and C (0.25-0.34 ms). The cause is the fixed statement count of `_fga_bidi` (opt3, gap 2 in the list of gaps). It stays within its budget (1 ms at small and medium, 2 ms at large).
- **Writes:** `write_share` and `write_nest_team` of D take 0.13-0.15 ms at every scale. D has no materialized memberships, so a write is one row. The nest write of B takes 0.6-0.8 ms. The nest write of C takes 32 ms (small), 45 ms (medium) and 54 ms (large), which is 50-100x over budget, as it always was. At small, `write_assign_role` of A takes 0.08 ms against 0.14 ms for D (1.8x, on a row that the preset API makes trivial for A). At medium and large D is equal (0.13 against 0.16 ms, and 0.12 against 0.14 ms).
- **Budgets at small and medium:** D misses no budget at either scale. These runs were over budget in the clean batch. Small: `parents_select_page` of A (p95 4.03 against 4 ms), `write_nest_team` of B (1.27 against 1) and `write_nest_team` of C. Medium: `write_nest_team` of C only.

  Large (old budget): `parents_proj_select_count` for D (13.25) and A (16.10), and the nest write of C. The two single-branch rows of A were also over budget (57.5 against 32, 80.9 against 70). B and C passed `parents_proj_select_count` at 9 ms in this run (8.49 and 8.21), but not in earlier runs. The p95 of that row moves by 2x between runs of the same design (below).
- **Storage:** D is 6.3, 40.6 and 323.7 MB through nesting at small, medium and large. A is 6.5 / 48.6 / 404.3, B is 6.5 / 46.4 / 377.9, and C is 4.6-5.1 / 27.0-27.8 / 182.4-183.2. C is the smallest at large because its closure holds only containers. The large parents seed of D takes 15.4 s against 29.8 s for A, 43.3 s for B and 16.8 s for C.

### The large `parents_proj_select_count` budget: from 9 to 20 ms

The row counts every document that a sample user sees through the two-arm policy. The plan is a bitmap heap scan over about 10,900 all-visible heap pages of `documents`. The budget was 3x the fastest p95 of session 2 (2.9 ms, on a local Postgres 16.4). It assumed the behavior of 16.4, which skips the heap fetch for all-visible pages when the query needs no columns. Postgres 16.15, 17.11 and 18.6 read every page ([`VERSIONS.md`](./VERSIONS.md), Calibration).

So the row has a floor, and no design can be faster than the floor: p50 7.5-9.4 ms for A, B, C and D. The row missed 9 ms in 22 of the 27 large reports on PG 16-18 that existed before this change. This is true for every design. The 27 reports are every `pg*-docker-*-large-default*.md` except the `p6check` one.

The measured spread over those 27 reports (all designs and tags) is p50 7.48-9.43 ms and p95 8.21-16.10 ms. The p95 depends on the host. The same D file gave p95 9.35 in opt3, 13.25 in the `p6` run and 8.24 in the `p6check` run straight after it. The p50 values were 7.74, 7.89 and 7.49. A budget at the p50 floor would fail on host noise. A budget at the tightest p95 would fail on every busy afternoon.

**Chosen: 20 ms for every design.** It is above every p95 ever measured on PG 16-18 (worst 16.10, A in `p6`; worst D 15.76 in `opt3-covering`). It is 2.1x the worst p50. It still fails if the plan gets worse in a way that matters, because a floor that doubles puts the p95 at 16-30 ms.

The session rule is 3x the p95 of the fastest design on the row. The fastest p95 now is 8.21 ms, so the rule gives 25 ms. Thus 20 is stricter than the rule, not looser.

There is no exemption for one design. There is one number, in [`bench/budgets.tsv`](../../bench/budgets.tsv), with the reason in its header. Nothing else in `budgets.tsv` changed.

`--check` at large for D with the new budget: we ran `bench/run.sh --scale large --tag p6check --check` through the Docker harness (16:36-16:40) and ran nothing else. Every workload is within budget and the exit code is 0. `parents_proj_select_count` has p50 7.49 ms and p95 8.24 ms against 20. We took the large runs of A, B and C in `p6` before the change.

With 20 ms their `parents_proj_select_count` (A 16.10, B 8.49, C 8.21) passes. The other `--check` failures at large are failures that these designs always had (the single-branch rows of A and `write_nest_team` of C). They are not part of this change.

## opt3: performance pass 2 (phase 5 of session 5, 2026-10-30)

Phase 5 of [`../plan.md`](../plan.md) ("Next work") has two goals. The first goal is to close the hotspots under "Gaps and hotspots" (opt2 section below). The second goal is to measure what conditions cost. The setup is the same as for opt and opt2.

It uses Docker, Postgres 18.6, pg_tle 1.5.3, `cpus: 4`, `mem_limit: 6g`, 4 pgbench clients and 10 s for each workload. The runs were strictly serial. We passed a frozen copy of the extension file as `--impl`. An edit of the source during a run cannot change the installed code. The command was: `docker/run-matrix.sh bench --versions 18 --designs d -- --impl bench/results/<copy>.sql --design d --scale <s> --shape <sh> --tag <tag> --check`.

The tags are these. `opt3-before` is `pg_permissions--0.0.1.sql` at `0bd650b` (phase 4 plus the new benchmark phases, no design change). `opt3` is the file at `01b9fc2` (this pass). `opt3-covering` is `opt3` with the covering index (pending, below). The reports are `pg18-docker-d-{large-default,medium-deep,medium-wide}-opt3[-before].md` and `pg18-docker-d-{large-default,medium-wide}-opt3-covering.md`. Only the `opt3` JSON is in `data/` (the docs site makes charts from it), as with opt2.

Other processes ran on the machine: idle Supabase and freereps stacks and an unrelated `gallant_ritchie` container (openfga/openfga). Someone used the laptop itself.

**We measured the "before" again. It is not the opt2 run.** After opt2, phase 2 added `fga_tuples.seq` (an identity column and a unique index). It also batched the benchmark seeds at 100 tuples for each `fga_write` (the Write cap). Phase 4 added conditions. So the storage, write and seed numbers of D changed before this pass started.

Large storage went from 285.0 MB (opt2) to 323.5 MB (opt3-before). `write_share` went from 0.23 to 0.25-0.26 ms. The large parents seed went from 30.4 to 33-41 s. The tables below show opt2, opt3-before and opt3 side by side. Compare opt3 with opt3-before.

**Paired runs.** We ran each configuration as a pair, before and then opt3, one after the other (11:26-11:54), because the machine changed during the day. The reruns of A, B and C on the same day (tag `opt3-ref`, reports not kept) were 3-24% slower than their session 3 `opt` runs. The median p50 ratio for each design and configuration was 1.03-1.24. The first opt3 wide run, an hour earlier than its pair, had p95 values twice those of its neighbors. The columns of A, B and C are their `opt` runs, as in the opt2 section.

### What changed (`pg_permissions--0.0.1.sql`, commits `482aab4` and `01b9fc2`)

1. **Typed writes.** `fga_write_tuple` and `fga_delete_tuple` validate and write a key without JSON for `fga_write`. `_fga_tuple_for_write` (behind `fga_write`, the seeds and contextual tuples) accepts a key without a condition after one lookup, instead of six. For this it uses `_fga_write_key_ok`: an unconditioned type restriction that accepts the key. Every other key goes the old way, so every error is the same. The test `d/42_fga_write_paths` (68 assertions) compares each path with the JSON path on 28 keys, valid and not valid.
2. **Check.** A partial index on the userset tuples: `fga_tuples_userset_idx (object_type, object_id, relation, user_type, user_relation) where user_relation <> ''`. With it, `_fga_bstep` finds the nested teams of a team without a read of its plain members. The `nest_check` team has 1,000 members and a wide team has 313. The code skips the meet test while the forward side of a plain user holds only the user.
3. **Set-based ListObjects over the rewrite tree** (`fga_relations.set_eval`, `_fga_set_rel`, `_fga_set_node`; [`d-per-model.md`](../designs/d-per-model.md) section 5). It covers the non-monotone relations outside the set-based difference. These are intersections, unions under a subtract, nested subtracts, bases that depend on a non-monotone relation, and tupleToUserset over such a relation. The test `d/43_fga_set_eval` (199 assertions) checks it against Check and against the per-candidate path. It checks through the API and the RLS helpers, with conditions, contextual tuples and the depth limit at its boundary.
4. **Conditions once for each distinct context** in the recursion of the forward walk. A superset walk without levels collects the pairs, `_fga_conds_eval` evaluates each pair once, and `_fga_cond_take` applies the mode for each tuple. Wherever evaluated pairs are matched back to tuples, an equality join replaces a correlated `IS NOT DISTINCT FROM` subplan (`_fga_forward`, `_fga_forward_ids`, `_fga_fstep`, `_fga_bstep`).
5. **The benchmark** has two new phases for design d ([`../../bench/run.sh`](../../bench/run.sh) phases 6 and 7). The phase `conditions` is a conditioned copy of the team graph (`cteam`, `document#cviewer`, condition `active` on every membership and team grant, one shared stored context). It has plain and conditioned twins for ListObjects, the page, the nested Check and ListUsers. The phase `blocklist` has `can_view: viewer but not blocked` (the workload of the old side script [`bench/designs/d/but_not_list_objects.sql`](../../bench/designs/d/but_not_list_objects.sql)), `can_view_unmuted: viewer but not (blocked or muted)` and `can_edit: editor and viewer`. The checksum of the conditions phase must equal the checksum of the parents phase. It does in every run.

**Correctness.** Every checksum equals the checksum of A, B and C in all three configurations. This holds in every run of this pass: opt3-before, opt3, opt3-covering, and the reruns of A, B and C. The values are in the "Checksums" table below.

The conditions phase matched the parents phase in every run. The suite has 55 files and 3,604 assertions. It passes locally (PG 16.4) and on PG 16, 17 and 18 in Docker. The consolidated suite of OpenFGA passes 933/746, the ABAC oracle 302/271, and the fga_lang oracle 70/70.

### Results, opt3-before against opt3

All values are p50 / p95 in ms. "opt3 against best of A/B/C" is the p50 of opt3 divided by the best p50 of A, B and C (their `opt` runs). The new workloads have no budget, because only D runs them.

#### Large, default shape

<!-- before: 20261030-114434-opt3-before-0bd650b-large.md; opt3: 20261030-114910-opt3-01b9fc2-large.md -->

| workload | D opt2 p50 / p95 | D before p50 / p95 | D opt3 p50 / p95 | opt3 against before (p50) | A p50 / p95 | B p50 / p95 | C p50 / p95 | opt3 against best of A/B/C (p50) | budget p95 | opt3 status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.21 / 0.31 | 0.22 / 0.31 | 0.22 / 0.3 | 1.00x | 0.3 / 0.56 | 0.27 / 0.41 | 0.24 / 0.33 | 0.9x | 1 | ok |
| rbac_select_page | 0.65 / 0.84 | 0.67 / 0.97 | 0.68 / 1.57 | 1.01x | 0.76 / 1.44 | 0.73 / 1.1 | 0.67 / 0.91 | 1.0x | 3 | ok |
| rbac_select_count | 0.71 / 0.95 | 0.71 / 0.92 | 0.72 / 0.97 | 1.01x | 0.78 / 1.07 | 0.78 / 0.99 | 0.73 / 0.93 | 1.0x | 3 | ok |
| rbac_update_one | 0.28 / 0.5 | 0.27 / 0.36 | 0.28 / 0.4 | 1.04x | 0.47 / 0.65 | 0.47 / 0.68 | 0.36 / 0.5 | 0.8x | 3 | ok |
| write_assign_role | 0.14 / 0.22 | 0.14 / 0.2 | 0.14 / 0.22 | 1.00x | 0.15 / 0.23 | 0.14 / 0.22 | 0.17 / 0.24 | 1.0x | 1 | ok |
| share_list_objects | 0.36 / 0.74 | 0.31 / 0.41 | 0.3 / 0.4 | 0.97x | 0.29 / 0.38 | 0.29 / 0.43 | 0.25 / 0.36 | 1.2x | 2 | ok |
| share_select_page | 1.29 / 3.07 | 0.95 / 1.26 | 0.97 / 1.35 | 1.02x | 1.03 / 1.35 | 1 / 1.29 | 0.93 / 1.27 | 1.0x | 6 | ok |
| write_share | 0.23 / 0.36 | 0.25 / 0.33 | 0.16 / 0.24 | 0.64x | 0.15 / 0.23 | 0.14 / 0.21 | 0.17 / 0.25 | 1.1x | 1 | ok |
| parents_proj_select_page | 1.11 / 1.61 | 1.02 / 1.43 | 1.05 / 1.4 | 1.03x | 1.33 / 2.62 | 1.15 / 1.55 | 1.05 / 1.57 | 1.0x | 4 | ok |
| parents_proj_select_count | 8.41 / 11.55 | 7.66 / 9.32 | 7.74 / 9.35 | 1.01x | 8.42 / 14.66 | 8.2 / 12.36 | 7.88 / 9.97 | 1.0x | 9 | OVER |
| parents_select_page | 1.16 / 7.58 | 1.07 / 7.12 | 1.08 / 7.18 | 1.01x | 45.65 / 66.27 | 13.65 / 16.82 | 4.94 / 6.55 | 0.2x | 32 | ok |
| parents_select_count | 8.38 / 14.74 | 7.61 / 12.64 | 7.59 / 12.38 | 1.00x | 75.08 / 92.44 | 21.57 / 27.61 | 11.88 / 15.53 | 0.6x | 70 | ok |
| write_nest_team | 0.24 / 0.32 | 0.26 / 0.32 | 0.16 / 0.22 | 0.62x | 0.15 / 0.27 | 0.62 / 0.78 | 57.66 / 77.18 | 1.1x | 1 | ok |
| nest_check | 0.4 / 0.54 | 0.41 / 0.53 | 0.39 / 0.53 | 0.95x | 0.31 / 0.48 | 0.32 / 0.42 | 0.3 / 0.45 | 1.3x | 2 | ok |
| plain_list_objects |  | 0.33 / 1.9 | 0.33 / 1.8 | 1.00x |  |  |  |  | - | - |
| cond_list_objects |  | 0.54 / 2.18 | 0.53 / 2.27 | 0.98x |  |  |  |  | - | - |
| cond_select_page |  | 1.25 / 7.37 | 1.23 / 7.35 | 0.98x |  |  |  |  | - | - |
| cond_nest_check |  | 0.58 / 0.86 | 0.56 / 0.73 | 0.97x |  |  |  |  | - | - |
| plain_list_users |  | 0.3 / 1.48 | 0.31 / 1.48 | 1.03x |  |  |  |  | - | - |
| cond_list_users |  | 0.43 / 1.96 | 0.45 / 1.85 | 1.05x |  |  |  |  | - | - |
| block_list_objects |  | 0.38 / 1.94 | 0.39 / 1.95 | 1.03x |  |  |  |  | - | - |
| block_or_mute_list_objects |  | 16.52 / 350.64 | 0.55 / 2.48 | 0.03x |  |  |  |  | - | - |
| intersect_list_objects |  | 2.93 / 103.39 | 0.48 / 2.52 | 0.16x |  |  |  |  | - | - |

The table shows the seed time (s) and the cumulative size of the `permissions` tables (MB).

| phase | D opt2 s / MB | D before s / MB | D opt3 s / MB |
| --- | --- | --- | --- |
| rbac | 4.99 / 5.4 | 4.27 / 5.4 | 3.93 / 5.4 |
| sharing | 2.05 / 16.2 | 1.58 / 17.7 | 0.82 / 17.9 |
| parents_proj | 0.09 / 16.9 | 0.08 / 18.4 | 0.05 / 18.6 |
| parents | 30.42 / 285.0 | 33.05 / 323.5 | 15.26 / 323.7 |
| nesting | 0.02 / 285.0 | 0.02 / 323.5 | 0.02 / 323.7 |
| conditions |  | 1.04 / 329.0 | 1.03 / 329.5 |
| blocklist |  | 1.06 / 336.5 | 0.71 / 337.0 |

#### Medium, deep shape

<!-- before: 20261030-113533-opt3-before-0bd650b-medium-deep.md; opt3: 20261030-113935-opt3-01b9fc2-medium-deep.md -->

| workload | D opt2 p50 / p95 | D before p50 / p95 | D opt3 p50 / p95 | opt3 against before (p50) | A p50 / p95 | B p50 / p95 | C p50 / p95 | opt3 against best of A/B/C (p50) | budget p95 | opt3 status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.23 / 0.33 | 0.22 / 0.3 | 0.21 / 0.3 | 0.95x | 0.29 / 0.4 | 0.27 / 0.36 | 0.24 / 0.32 | 0.9x | 1 | ok |
| rbac_select_page | 0.39 / 0.51 | 0.4 / 0.55 | 0.39 / 0.49 | 0.97x | 0.44 / 0.56 | 0.46 / 0.57 | 0.42 / 0.57 | 0.9x | 2 | ok |
| rbac_select_count | 0.32 / 0.42 | 0.31 / 0.44 | 0.31 / 0.4 | 1.00x | 0.35 / 0.48 | 0.37 / 0.48 | 0.32 / 0.41 | 1.0x | 2 | ok |
| rbac_update_one | 0.28 / 0.37 | 0.28 / 0.38 | 0.27 / 0.36 | 0.96x | 0.48 / 0.66 | 0.46 / 0.58 | 0.35 / 0.46 | 0.8x | 3 | ok |
| write_assign_role | 0.15 / 0.21 | 0.15 / 0.27 | 0.14 / 0.21 | 0.93x | 0.15 / 0.23 | 0.14 / 0.21 | 0.18 / 0.24 | 1.0x | 1 | ok |
| share_list_objects | 0.33 / 0.48 | 0.32 / 0.5 | 0.32 / 0.43 | 1.00x | 0.31 / 0.41 | 0.32 / 0.4 | 0.28 / 0.37 | 1.1x | 1 | ok |
| share_select_page | 0.68 / 1.05 | 0.69 / 1.17 | 0.65 / 0.91 | 0.94x | 0.76 / 1 | 0.72 / 0.89 | 0.66 / 0.9 | 1.0x | 3 | ok |
| write_share | 0.24 / 0.36 | 0.26 / 0.39 | 0.15 / 0.22 | 0.58x | 0.15 / 0.22 | 0.14 / 0.2 | 0.17 / 0.23 | 1.1x | 1 | ok |
| parents_proj_select_page | 0.75 / 1.08 | 0.77 / 1.3 | 0.75 / 1.59 | 0.97x | 1 / 1.26 | 0.83 / 1.14 | 0.73 / 1 | 1.0x | 4 | ok |
| parents_proj_select_count | 1.06 / 1.57 | 1.04 / 1.54 | 1.02 / 1.29 | 0.98x | 1.25 / 1.47 | 1.14 / 1.4 | 0.99 / 1.18 | 1.0x | 4 | ok |
| parents_select_page | 0.78 / 1.9 | 0.79 / 1.76 | 0.7 / 1.35 | 0.89x | 7.41 / 9.76 | 4.52 / 5.54 | 2.83 / 3.8 | 0.2x | 25 | ok |
| parents_select_count | 1.08 / 1.89 | 0.98 / 1.45 | 0.97 / 1.4 | 0.99x | 6.4 / 8.06 | 3.74 / 6.01 | 2.1 / 2.69 | 0.5x | 23 | ok |
| write_nest_team | 0.24 / 0.47 | 0.24 / 0.31 | 0.16 / 0.22 | 0.67x | 0.15 / 0.23 | 0.63 / 0.73 | 75.12 / 115.12 | 1.1x | 1 | ok |
| nest_check | 0.43 / 0.79 | 0.45 / 0.72 | 0.4 / 0.53 | 0.89x | 0.34 / 0.47 | 0.34 / 0.44 | 0.3 / 0.41 | 1.3x | 2 | ok |
| plain_list_objects |  | 0.33 / 0.51 | 0.34 / 0.54 | 1.03x |  |  |  |  | - | - |
| cond_list_objects |  | 0.62 / 0.91 | 0.53 / 0.76 | 0.85x |  |  |  |  | - | - |
| cond_select_page |  | 1.03 / 1.72 | 0.95 / 1.6 | 0.92x |  |  |  |  | - | - |
| cond_nest_check |  | 0.59 / 0.74 | 0.56 / 0.7 | 0.95x |  |  |  |  | - | - |
| plain_list_users |  | 0.91 / 2.24 | 0.89 / 2.46 | 0.98x |  |  |  |  | - | - |
| cond_list_users |  | 1.35 / 3.96 | 1.37 / 3.54 | 1.01x |  |  |  |  | - | - |
| block_list_objects |  | 0.38 / 0.57 | 0.39 / 0.58 | 1.03x |  |  |  |  | - | - |
| block_or_mute_list_objects |  | 27.65 / 92.48 | 0.5 / 0.76 | 0.02x |  |  |  |  | - | - |
| intersect_list_objects |  | 4.86 / 24.95 | 0.44 / 0.65 | 0.09x |  |  |  |  | - | - |

The table shows the seed time (s) and the cumulative size of the `permissions` tables (MB).

| phase | D opt2 s / MB | D before s / MB | D opt3 s / MB |
| --- | --- | --- | --- |
| rbac | 0.49 / 3.0 | 0.44 / 3.0 | 0.44 / 3.0 |
| sharing | 0.91 / 8.8 | 1.07 / 9.5 | 0.55 / 9.6 |
| parents_proj | 0.04 / 9.1 | 0.04 / 9.9 | 0.03 / 10.0 |
| parents | 2.86 / 36.0 | 3.41 / 40.4 | 1.47 / 40.6 |
| nesting | 0.02 / 36.0 | 0.01 / 40.4 | 0.02 / 40.6 |
| conditions |  | 0.65 / 43.3 | 0.64 / 43.5 |
| blocklist |  | 0.63 / 47.0 | 0.47 / 47.3 |

#### Medium, wide shape

<!-- before: 20261030-112656-opt3-before-0bd650b-medium-wide.md; opt3: 20261030-113128-opt3-01b9fc2-medium-wide.md -->

| workload | D opt2 p50 / p95 | D before p50 / p95 | D opt3 p50 / p95 | opt3 against before (p50) | A p50 / p95 | B p50 / p95 | C p50 / p95 | opt3 against best of A/B/C (p50) | budget p95 | opt3 status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.23 / 0.33 | 0.22 / 0.31 | 0.21 / 0.3 | 0.95x | 0.29 / 0.4 | 0.28 / 0.37 | 0.24 / 0.35 | 0.9x | 1 | ok |
| rbac_select_page | 0.4 / 0.56 | 0.4 / 0.58 | 0.4 / 0.5 | 1.00x | 0.44 / 0.56 | 0.46 / 0.59 | 0.44 / 0.61 | 0.9x | 2 | ok |
| rbac_select_count | 0.32 / 0.45 | 0.31 / 0.44 | 0.3 / 0.39 | 0.97x | 0.36 / 0.48 | 0.36 / 0.45 | 0.33 / 0.43 | 0.9x | 2 | ok |
| rbac_update_one | 0.28 / 0.38 | 0.27 / 0.36 | 0.27 / 0.38 | 1.00x | 0.49 / 0.63 | 0.48 / 0.95 | 0.38 / 0.49 | 0.7x | 3 | ok |
| write_assign_role | 0.15 / 0.22 | 0.14 / 0.21 | 0.14 / 0.2 | 1.00x | 0.15 / 0.23 | 0.14 / 0.24 | 0.18 / 0.26 | 1.0x | 1 | ok |
| share_list_objects | 5.12 / 7.32 | 4.93 / 6.42 | 4.9 / 6.79 | 0.99x | 4.44 / 5.57 | 8.41 / 15.8 | 3.41 / 3.87 | 1.4x | 13 | ok |
| share_select_page | 11.54 / 18.57 | 11.3 / 21.61 | 10.94 / 18.16 | 0.97x | 14.44 / 16.96 | 17.82 / 24.18 | 8.2 / 16.47 | 1.3x | 42 | ok |
| write_share | 0.23 / 0.35 | 0.25 / 0.37 | 0.16 / 0.23 | 0.64x | 0.15 / 0.22 | 0.16 / 0.4 | 0.17 / 0.24 | 1.1x | 1 | ok |
| parents_proj_select_page | 10.87 / 16.71 | 11.24 / 20.37 | 11.66 / 20.12 | 1.04x | 14.98 / 18.27 | 15.05 / 21.68 | 8.73 / 18.83 | 1.3x | 51 | ok |
| parents_proj_select_count | 9.04 / 11.99 | 9.06 / 11.05 | 9.11 / 13.79 | 1.01x | 13.24 / 16.48 | 13.44 / 18.05 | 6.33 / 7.17 | 1.4x | 31 | ok |
| parents_select_page | 10.95 / 16.04 | 11.17 / 20.79 | 11.25 / 17.27 | 1.01x | 14.74 / 19.23 | 13.68 / 19.98 | 8.06 / 10.65 | 1.4x | 46 | ok |
| parents_select_count | 8.85 / 11.34 | 8.98 / 11.8 | 9.06 / 12.43 | 1.01x | 13.31 / 16.64 | 12.22 / 17.51 | 6.61 / 7.48 | 1.4x | 40 | ok |
| write_nest_team | 0.23 / 0.36 | 0.26 / 0.36 | 0.16 / 0.25 | 0.62x | 0.15 / 0.21 | 1.47 / 1.81 | 61.23 / 73.27 | 1.1x | 1 | ok |
| nest_check | 0.44 / 0.69 | 0.47 / 0.65 | 0.4 / 0.58 | 0.85x | 0.37 / 0.48 | 0.34 / 0.61 | 0.31 / 0.44 | 1.3x | 2 | ok |
| plain_list_objects |  | 5.04 / 6.54 | 4.95 / 7.07 | 0.98x |  |  |  |  | - | - |
| cond_list_objects |  | 14.79 / 20.45 | 10.64 / 22.95 | 0.72x |  |  |  |  | - | - |
| cond_select_page |  | 21.19 / 26.96 | 16.61 / 22.7 | 0.78x |  |  |  |  | - | - |
| cond_nest_check |  | 0.63 / 0.8 | 0.56 / 0.7 | 0.89x |  |  |  |  | - | - |
| plain_list_users |  | 0.99 / 16.26 | 0.93 / 14.88 | 0.94x |  |  |  |  | - | - |
| cond_list_users |  | 1.42 / 20.35 | 1.35 / 17.42 | 0.95x |  |  |  |  | - | - |
| block_list_objects |  | 4.98 / 6.47 | 4.99 / 7.38 | 1.00x |  |  |  |  | - | - |
| block_or_mute_list_objects |  | 5246.18 / 5365.27 | 7.63 / 9.86 | 0.00x |  |  |  |  | - | - |
| intersect_list_objects |  | 621.21 / 687.4 | 6.07 / 7.58 | 0.01x |  |  |  |  | - | - |

The table shows the seed time (s) and the cumulative size of the `permissions` tables (MB).

| phase | D opt2 s / MB | D before s / MB | D opt3 s / MB |
| --- | --- | --- | --- |
| rbac | 0.46 / 3.0 | 0.48 / 3.0 | 0.48 / 3.0 |
| sharing | 11.26 / 81.6 | 13.61 / 92.4 | 5.90 / 96.1 |
| parents_proj | 0.04 / 81.9 | 0.05 / 92.8 | 0.03 / 96.5 |
| parents | 2.84 / 108.8 | 3.21 / 123.4 | 1.57 / 127.1 |
| nesting | 0.02 / 108.8 | 0.02 / 123.4 | 0.02 / 127.1 |
| conditions |  | 16.23 / 220.5 | 16.79 / 227.8 |
| blocklist |  | 2.48 / 224.2 | 2.28 / 231.5 |

### Per candidate

| # | candidate (phase 5 of [`../plan.md`](../plan.md)) | outcome | before → after | evidence |
| --- | --- | --- | --- | --- |
| 1 | Check (`_fga_bidi` statements) | done: userset index, and the code skips the meet test | `nest_check` p50 0.41 → 0.39 (large), 0.45 → 0.40 (deep), 0.47 → 0.40 ms (wide); in the server 229 → 178 µs (wide) | tables; loops in the server below |
| 1a | ... fold the user probe into the step | rejected | in the server 229 → 390 µs for `nest_check` (wide). When the probe hits, the folded step also expands the frontier, here a team of 1,000 members | loops in the server below |
| 2 | Typed write path | done | `write_share` 0.25 → 0.16, `write_nest_team` 0.26 → 0.16 ms (wide; 0.58-0.67x everywhere); seeds: large parents 33.1 → 15.3 s, wide sharing 13.6 → 5.9 s | tables |
| 3 | Wide ListObjects: covering user index | **waits for a decision of the user** | see below: no gain in pgbench at wide, -7% in the server; +120 MB at large | `opt3-covering` |
| 3 | ... one tuplestore less (the RLS helper calls `_fga_forward` directly) | rejected | 4.39-6.03 → 4.32-5.06 ms in the server, in alternate rounds. The gain is 0.3 ms or less, which is inside the noise between runs | loops in the server |
| 3 | ... change the lowest-level `group by` (use `distinct` when no level can reach 25) | rejected | 3.97 → 3.66 ms in the server (8%), not visible in pgbench. The walk without levels takes 2.6 ms, so levels cost about 35%, but most of that cost is in the recursion, not in the `group by` | loops in the server |
| 4 | Non-monotone ListObjects outside the set-based form | done: set-based evaluator | wide: `block_or_mute_list_objects` 5,246 → 7.6 ms, `intersect_list_objects` 621 → 6.1 ms; large 16.5 → 0.55 and 2.9 → 0.48 ms (p95 351 → 2.5 and 103 → 2.5); in the server (wide, user 1-30) 5,695 → 6.7 ms and 647 → 5.6 ms | tables |
| 5 | Cyclic userset data | rejected (measured) | the walk with levels takes 4.0 ms on the wide tree, and 13.4 ms with a 2-cycle at every inner team (3.3x); the walk without levels changes from 2.6 to 4.7 ms on the same data (it reaches 11,197 ids, not 6,609) | [`bench/designs/d/cyclic_walk.sql`](../../bench/designs/d/cyclic_walk.sql) |
| 6 | Conditions | measured; evaluation for each row done | below | [`bench/designs/d/conditions_cost.sql`](../../bench/designs/d/conditions_cost.sql), the conditions phase |

**Candidate 5, why we rejected it.** The cost has a limit. A node on a cycle of length k is expanded again every k levels, up to level 25. So the cost is at most about 12x for the cyclic part with 2-cycles, and 3.3x for the whole walk here.

The walk without levels avoids this cost, but it loses the depth-25 rule. A recursive CTE cannot drop a (node, level) row because it saw the node at a lower level. Its recursive term sees only the previous iteration. Cycles are rare in group data and are not in the benchmark. We found no exact alternative that costs nothing on acyclic data.

### What conditions cost (candidate 6)

The next table shows pgbench results from paired runs. The `plain_*` and `cond_*` workloads run on the same data, with the conditioned copy next to the original.

| configuration | ListObjects plain / cond | page (parents_select_page / cond_select_page) | nested Check (nest_check / cond_nest_check) | ListUsers plain / cond |
| --- | --- | --- | --- | --- |
| large, before | 0.33 / 0.54 | 1.07 / 1.25 | 0.41 / 0.58 | 0.30 / 0.43 |
| large, opt3 | 0.33 / 0.53 | 1.08 / 1.23 | 0.39 / 0.56 | 0.31 / 0.45 |
| deep, before | 0.33 / 0.62 | 0.79 / 1.03 | 0.45 / 0.59 | 0.91 / 1.35 |
| deep, opt3 | 0.34 / 0.53 | 0.70 / 0.95 | 0.40 / 0.56 | 0.89 / 1.37 |
| wide, before | 5.04 / 14.79 | 11.17 / 21.19 | 0.47 / 0.63 | 0.99 / 1.42 |
| wide, opt3 | 4.95 / 10.64 | 11.25 / 16.61 | 0.40 / 0.56 | 0.93 / 1.35 |

The values are p50 in ms. The second table shows measurements in the server, on the wide data after the full run ([`bench/designs/d/conditions_cost.sql`](../../bench/designs/d/conditions_cost.sql)). It gives the time and the number of condition evaluations for each call, for users 1-30, in three rounds. "Before" loads the walk functions of `0bd650b` inside a rolled-back transaction.

| call | viewer | cviewer before | cviewer opt3 |
| --- | --- | --- | --- |
| ListObjects, one shared context | 4.9 ms | 14.5 ms, 205 evaluations | 11.4 ms, 2 |
| Check (`nest_check` fixture) | 0.22 ms | 0.41 ms, 3 | 0.30 ms, 3 |
| ListUsers (a document of teams 1-30, limit of 1,000) | 28.4 ms | 59.2 ms, 4.6 | 45.5 ms, 4.6 |
| ListObjects, one distinct context for each tuple | 5.4 ms | 3,203 ms, 6,774 | 167 ms, 6,748 |
| ListUsers, one distinct context for each tuple | 26.3 ms | 29-37 s (two calls) | 472 ms, 20,047 (0.6-1.0 s for the same two calls) |

- **A condition evaluation costs about 22 µs** here (`_fga_cond_eval` on `expires > timestamp("...")`: lookup, parameter conversion, interpreter). This is 7-10x the micro-benchmark `x < 100` of phase 4. With one shared context, the overhead that is left in the conditioned ListObjects (11.4 against 4.9 ms) is not evaluation. It is the cost to carry and match the context for each leaf, and the extra walk without levels.
- **The evaluation for each row in the recursion was important.** A wide ListObjects with one shared context did 205 evaluations. Now it does 2 (one in the recursion, one for the leaves). When every context is different, the change costs the walk without levels, about 0.3 ms of 167 ms.
- **The quadratic match was the more important result.** With a context for each tuple, the old filter compared every leaf with every evaluated pair. This is 6,700 x 6,700 for a wide ListObjects and 20,000 x 20,000 for ListUsers. An equality join makes both linear. They are 19x and about 40x faster.
- **What a conditioned edge costs now:** A wide ListObjects costs about 2x with one shared context. It costs about 30x with a context for each tuple. This is one evaluation for each leaf, as phase 4 predicted (30-60 ms for each 10,000). A Check through three conditioned edges adds about 0.1-0.15 ms. ListUsers costs 1.5x with a shared context.

### Open decision of the user: the covering user index

The index is `fga_tuples_user_idx (user_type, user_id, user_relation, object_type, relation) include (object_id, condition_name)`. It makes the probes of the forward walk index-only. From phase 4 the index must include `condition_name`, because a tuple matches the edge of its own condition. We measured the index fully (time and MB). We did not keep it in the extension.

| | opt3 | opt3-covering |
| --- | --- | --- |
| storage, large, after the parents seed | 323.7 MB | 444.1 MB (+120 MB, +37%) |
| storage, medium wide, after the parents seed / at the end | 127.1 / 231.5 MB | 171.9 / 311.5 MB |
| index size, medium wide (715k tuples) | 7.3 MB (deduplicated) | 87 MB |
| wide `share_list_objects` p50 | 4.90 | 4.85 |
| wide `parents_select_page` / `_count` p50 | 11.25 / 9.06 | 11.86 / 9.54 |
| wide `plain_list_objects` p50 | 4.95 | 5.15 |
| wide ListObjects in the server (users 1-30, alternate rounds) | 4.79 | 4.47 (-7%) |
| large `parents_select_page` / `_count` p50 (runs 14 min apart) | 1.29 / 9.84 | 1.13 / 9.20 |
| large `plain_list_users` p50 | 0.35 | 12.95 (a plan change: the backward probes of ListUsers choose the wider index) |
| large parents seed | 18.7 s | 20.7 s |

Recommendation: do not adopt the index. The opt diagnosis measured a gain of 33% (52 → 35 ms) on FGA-only org fan-outs. That gain needs large fan-outs in FGA, which the composition of D avoids. On the shapes of the benchmark the gain is inside the noise in pgbench. The index costs 37% more storage at large. It made large ListUsers 37x slower, until someone pins its plans.

### Budget misses (`--check`), opt3

| configuration | opt3-before | opt3 |
| --- | --- | --- |
| large default | `parents_proj_select_count` 9.32 > 9 | `parents_proj_select_count` 9.35 > 9 (all four designs have this miss: the heap-fetch floor; phase 6 sets a new baseline) |
| medium deep | none | none |
| medium wide | none | none |

We checked `bench/budgets.tsv` again: no change. Every opt3 p95 is within its budget, except the shared large one. The nine new workloads stay without a budget, because the budget rule needs a reference design and only D runs them.

### Wrong turns

- **The first "before" runs were contaminated.** They read the extension file at the start of each configuration. Someone edited the file while the batch ran. Medium deep and wide installed unfinished opt3 code (their `intersect_list_objects` took 8.6 ms, and the per-candidate path takes 630 ms). We ran them again from a frozen copy (`--impl bench/results/opt3-before-0bd650b.sql`). Every run after that uses a frozen copy.
- **We folded the user probe of Check into the backward step** (the opt2 idea, done here so that the level count stays exact). This made Check of the benchmark slower, not faster, so we reverted it: see candidate 1a.
- **A cold cache looked like a 2x regression.** The first comparison in the server after a restart read pages from disk. Repeated loops that alternate the variants settled the question.

### Gaps and hotspots after opt3

1. Wide ListObjects is 1.1-1.4x A and 1.4x C in pgbench (4.9 ms). In the server, the walk without levels is 35% faster than the walk with levels. The covering index gives 7% in the server and nothing visible in pgbench.
2. Check is 1.2-1.3x A (0.39-0.40 ms). The statement count in `_fga_bidi` is the rest of the cost.
3. ListUsers on non-monotone relations outside the set-based difference still checks every candidate top-down (not in the benchmark).
4. A condition evaluation costs about 22 µs (timestamp parse in PL/pgSQL). So a context for each tuple costs a wide ListObjects about 30x. We still reject generated functions for each condition (10-25x faster in the micro-benchmark of phase 4), for the reasons in [`d-conditions.md`](../designs/d-conditions.md).
5. Cyclic userset data costs the walk with levels up to 25/k re-expansions (candidate 5).

## opt2: the second pass (2026-10-29)

This pass applies the fixes that the diagnosis of this report proposed to the prototype. We measured it in the same way as before (Docker, Postgres 18.6, `cpus: 4`, 4 clients, 10 s for each workload, strictly serial: `docker/run-matrix.sh bench --versions 18 --designs d -- --scale <s> --shape <sh> --tag opt2 --check`). The files have the tag `opt2` (`pg18-docker-d-{large-default,medium-deep,medium-wide}-opt2.{md,json}`). So the `opt` files above, and the primary series of the docs site, do not change. The design is in [`../designs/d-per-model.md`](../designs/d-per-model.md) section 5.

**What changed** (`prototypes/d-per-model.sql`, now `pg_permissions--0.0.1.sql`):

1. **Walk steps with target pruning, compiled at model write.** `fga_reach` holds the reachability between (type, relation) pairs in the positive graph. `fga_walk_steps` holds, for each target relation, every `d` or `t` edge joined with the computed closure of its destination. A step stays only if the node that it yields can reach the target. It has `expand` when that node has steps of its own toward the target. The benchmark model has 13 rows.
2. **ListObjects is one recursive CTE** (`_fga_forward`) over those steps, in the `_reach` shape of A. It makes one `fga_tuples` probe for each node and step. The recursion produces only expandable nodes. The leaves come from one final join of the reached nodes (each at its lowest level) to the steps that yield the target.

   The query keeps levels for each row (a node is expanded again once for each distinct level, and a cycle until level 25). This keeps the depth-25 rule exact. If an expandable node is first reached at level 25, a walk without levels (`_fga_forward_ids`) finishes behind it. The list functions stream the result. They do not use `array_agg` and then `unnest`.
3. **Set-based `but not` for ListObjects and ListUsers.** It applies in this case: the base is a positive expression over monotone relations, and the subtract is `r` or `r from ts` with `r` monotone. The result is the base walk minus the subtract walk. A recursive or long subtract checks again only what it removes, with `_fga_rec`. Intersections, unions or nested subtracts, and non-monotone bases keep the per-candidate path.
4. **Semantics, decided in this pass:** A monotone relation under a subtract is evaluated by its least fixpoint (a userset cycle contributes nobody), also in Check. Recursion through negation keeps the cycle rule of OpenFGA. `d/31_fga_cycles` now expects true for its cycle case (design document section 5). The OpenFGA suite does not change (933/933 stored and 746/746 contextual on 16, 17 and 18).
5. **Check trims:** the code has no statement for the start frontier or the first meet test of a plain user. It parses the object inline. It uses one lookup for the monotone flag and PathExists.

**Correctness:** every checksum equals the checksum of A, B and C in all three configurations (the same values as in the "Checksums" table). Seeds and storage do not change, within noise (large: 285.0 MB against 284.9 MB; parents seed 30.4 s against 33.8 s).

### Results, opt against opt2

All values are p50 / p95 in ms. A, B and C are their `opt` runs, as above. "opt2 against best of A/B/C" is the p50 of opt2 divided by the best p50 of A, B and C.

#### Large, default shape

| workload | D opt p50 / p95 | D opt2 p50 / p95 | opt2 against opt (p50) | A p50 / p95 | B p50 / p95 | C p50 / p95 | opt2 against best of A/B/C (p50) | budget p95 | opt2 status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.22 / 0.36 | 0.21 / 0.31 | 0.95x | 0.3 / 0.56 | 0.27 / 0.41 | 0.24 / 0.33 | 0.9x | 1 | ok |
| rbac_select_page | 0.72 / 1.81 | 0.65 / 0.84 | 0.90x | 0.76 / 1.44 | 0.73 / 1.1 | 0.67 / 0.91 | 1.0x | 3 | ok |
| rbac_select_count | 0.77 / 1.55 | 0.71 / 0.95 | 0.92x | 0.78 / 1.07 | 0.78 / 0.99 | 0.73 / 0.93 | 1.0x | 3 | ok |
| rbac_update_one | 0.28 / 0.44 | 0.28 / 0.5 | 1.00x | 0.47 / 0.65 | 0.47 / 0.68 | 0.36 / 0.5 | 0.8x | 3 | ok |
| write_assign_role | 0.14 / 0.22 | 0.14 / 0.22 | 1.00x | 0.15 / 0.23 | 0.14 / 0.22 | 0.17 / 0.24 | 1.0x | 1 | ok |
| share_list_objects | 0.54 / 0.71 | 0.36 / 0.74 | 0.67x | 0.29 / 0.38 | 0.29 / 0.43 | 0.25 / 0.36 | 1.4x | 2 | ok |
| share_select_page | 1.29 / 3.34 | 1.29 / 3.07 | 1.00x | 1.03 / 1.35 | 1 / 1.29 | 0.93 / 1.27 | 1.4x | 6 | ok |
| write_share | 0.23 / 0.35 | 0.23 / 0.36 | 1.00x | 0.15 / 0.23 | 0.14 / 0.21 | 0.17 / 0.25 | 1.6x | 1 | ok |
| parents_proj_select_page | 1.66 / 2.61 | 1.11 / 1.61 | 0.67x | 1.33 / 2.62 | 1.15 / 1.55 | 1.05 / 1.57 | 1.1x | 4 | ok |
| parents_proj_select_count | 8.92 / 11.03 | 8.41 / 11.55 | 0.94x | 8.42 / 14.66 | 8.2 / 12.36 | 7.88 / 9.97 | 1.1x | 9 | OVER |
| parents_select_page | 1.4 / 9.45 | 1.16 / 7.58 | 0.83x | 45.65 / 66.27 | 13.65 / 16.82 | 4.94 / 6.55 | 0.2x | 32 | ok |
| parents_select_count | 8.44 / 15.96 | 8.38 / 14.74 | 0.99x | 75.08 / 92.44 | 21.57 / 27.61 | 11.88 / 15.53 | 0.7x | 70 | ok |
| write_nest_team | 0.24 / 0.5 | 0.24 / 0.32 | 1.00x | 0.15 / 0.27 | 0.62 / 0.78 | 57.66 / 77.18 | 1.6x | 1 | ok |
| nest_check | 0.41 / 0.64 | 0.4 / 0.54 | 0.98x | 0.31 / 0.48 | 0.32 / 0.42 | 0.3 / 0.45 | 1.3x | 2 | ok |

#### Medium, deep shape

| workload | D opt p50 / p95 | D opt2 p50 / p95 | opt2 against opt (p50) | A p50 / p95 | B p50 / p95 | C p50 / p95 | opt2 against best of A/B/C (p50) | budget p95 | opt2 status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.22 / 0.36 | 0.23 / 0.33 | 1.05x | 0.29 / 0.4 | 0.27 / 0.36 | 0.24 / 0.32 | 1.0x | 1 | ok |
| rbac_select_page | 0.41 / 0.7 | 0.39 / 0.51 | 0.95x | 0.44 / 0.56 | 0.46 / 0.57 | 0.42 / 0.57 | 0.9x | 2 | ok |
| rbac_select_count | 0.32 / 0.53 | 0.32 / 0.42 | 1.00x | 0.35 / 0.48 | 0.37 / 0.48 | 0.32 / 0.41 | 1.0x | 2 | ok |
| rbac_update_one | 0.28 / 0.45 | 0.28 / 0.37 | 1.00x | 0.48 / 0.66 | 0.46 / 0.58 | 0.35 / 0.46 | 0.8x | 3 | ok |
| write_assign_role | 0.14 / 0.21 | 0.15 / 0.21 | 1.07x | 0.15 / 0.23 | 0.14 / 0.21 | 0.18 / 0.24 | 1.1x | 1 | ok |
| share_list_objects | 0.78 / 1.02 | 0.33 / 0.48 | 0.42x | 0.31 / 0.41 | 0.32 / 0.4 | 0.28 / 0.37 | 1.2x | 1 | ok |
| share_select_page | 1.18 / 1.5 | 0.68 / 1.05 | 0.58x | 0.76 / 1 | 0.72 / 0.89 | 0.66 / 0.9 | 1.0x | 3 | ok |
| write_share | 0.23 / 0.31 | 0.24 / 0.36 | 1.04x | 0.15 / 0.22 | 0.14 / 0.2 | 0.17 / 0.23 | 1.7x | 1 | ok |
| parents_proj_select_page | 1.79 / 2.74 | 0.75 / 1.08 | 0.42x | 1 / 1.26 | 0.83 / 1.14 | 0.73 / 1 | 1.0x | 4 | ok |
| parents_proj_select_count | 2.09 / 2.84 | 1.06 / 1.57 | 0.51x | 1.25 / 1.47 | 1.14 / 1.4 | 0.99 / 1.18 | 1.1x | 4 | ok |
| parents_select_page | 1.23 / 2.4 | 0.78 / 1.9 | 0.63x | 7.41 / 9.76 | 4.52 / 5.54 | 2.83 / 3.8 | 0.3x | 25 | ok |
| parents_select_count | 1.54 / 2.52 | 1.08 / 1.89 | 0.70x | 6.4 / 8.06 | 3.74 / 6.01 | 2.1 / 2.69 | 0.5x | 23 | ok |
| write_nest_team | 0.23 / 0.31 | 0.24 / 0.47 | 1.04x | 0.15 / 0.23 | 0.63 / 0.73 | 75.12 / 115.12 | 1.6x | 1 | ok |
| nest_check | 0.43 / 0.54 | 0.43 / 0.79 | 1.00x | 0.34 / 0.47 | 0.34 / 0.44 | 0.3 / 0.41 | 1.4x | 2 | ok |

#### Medium, wide shape

| workload | D opt p50 / p95 | D opt2 p50 / p95 | opt2 against opt (p50) | A p50 / p95 | B p50 / p95 | C p50 / p95 | opt2 against best of A/B/C (p50) | budget p95 | opt2 status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.21 / 0.31 | 0.23 / 0.33 | 1.10x | 0.29 / 0.4 | 0.28 / 0.37 | 0.24 / 0.35 | 1.0x | 1 | ok |
| rbac_select_page | 0.4 / 0.61 | 0.4 / 0.56 | 1.00x | 0.44 / 0.56 | 0.46 / 0.59 | 0.44 / 0.61 | 0.9x | 2 | ok |
| rbac_select_count | 0.31 / 0.46 | 0.32 / 0.45 | 1.03x | 0.36 / 0.48 | 0.36 / 0.45 | 0.33 / 0.43 | 1.0x | 2 | ok |
| rbac_update_one | 0.27 / 0.48 | 0.28 / 0.38 | 1.04x | 0.49 / 0.63 | 0.48 / 0.95 | 0.38 / 0.49 | 0.7x | 3 | ok |
| write_assign_role | 0.14 / 0.25 | 0.15 / 0.22 | 1.07x | 0.15 / 0.23 | 0.14 / 0.24 | 0.18 / 0.26 | 1.1x | 1 | ok |
| share_list_objects | 17.77 / 37.11 | 5.12 / 7.32 | 0.29x | 4.44 / 5.57 | 8.41 / 15.8 | 3.41 / 3.87 | 1.5x | 13 | ok |
| share_select_page | 26.2 / 49.49 | 11.54 / 18.57 | 0.44x | 14.44 / 16.96 | 17.82 / 24.18 | 8.2 / 16.47 | 1.4x | 42 | ok |
| write_share | 0.23 / 0.32 | 0.23 / 0.35 | 1.00x | 0.15 / 0.22 | 0.16 / 0.4 | 0.17 / 0.24 | 1.5x | 1 | ok |
| parents_proj_select_page | 38.63 / 51.14 | 10.87 / 16.71 | 0.28x | 14.98 / 18.27 | 15.05 / 21.68 | 8.73 / 18.83 | 1.2x | 51 | ok |
| parents_proj_select_count | 36.07 / 42.51 | 9.04 / 11.99 | 0.25x | 13.24 / 16.48 | 13.44 / 18.05 | 6.33 / 7.17 | 1.4x | 31 | ok |
| parents_select_page | 23.56 / 34.94 | 10.95 / 16.04 | 0.46x | 14.74 / 19.23 | 13.68 / 19.98 | 8.06 / 10.65 | 1.4x | 46 | ok |
| parents_select_count | 21.58 / 27.57 | 8.85 / 11.34 | 0.41x | 13.31 / 16.64 | 12.22 / 17.51 | 6.61 / 7.48 | 1.3x | 40 | ok |
| write_nest_team | 0.23 / 0.3 | 0.23 / 0.36 | 1.00x | 0.15 / 0.21 | 1.47 / 1.81 | 61.23 / 73.27 | 1.5x | 1 | ok |
| nest_check | 0.45 / 0.96 | 0.44 / 0.69 | 0.98x | 0.37 / 0.48 | 0.34 / 0.61 | 0.31 / 0.44 | 1.4x | 2 | ok |

### Budget misses (`--check`), opt2

| configuration | opt | opt2 |
| --- | --- | --- |
| large default | `parents_proj_select_count` 11.03 > 9 | `parents_proj_select_count` 11.55 > 9 (all four designs have this miss: the heap-fetch floor) |
| medium deep | `share_list_objects` 1.02 > 1 | none |
| medium wide | `share_list_objects`, `share_select_page`, `parents_proj_select_page`, `parents_proj_select_count` | none |

### Measurements in the server (Docker PG 18, the wide database that the run left)

We measured as in "Diagnosis": PL/pgSQL loops over users 1-30, three rounds, warm cache. The data is the medium wide data after the full opt2 run.

| call | opt | opt2 | A |
| --- | --- | --- | --- |
| ListObjects `document#viewer` (monotone, about 6,600 ids) | 17 ms | **3.74 ms** | 3.9 ms (`_reach`) |
| ListObjects `folder#viewer` (empty for most users) | 13.7 ms | **0.04 ms** | |
| ListObjects on `viewer: (...) but not blocked`, user 7 (6,701 ids) | 2,079 ms | **4.16 ms** (set-based) | |
| the same, users 1-30 | | 4.32 ms | |
| the same, per-candidate path on the same build (user 7) | | 2,234 ms | |
| Check on that relation (top-down `_fga_rec`) | 270 µs | 391 µs | |

The `but not` rows come from [`../../bench/designs/d/but_not_list_objects.sql`](../../bench/designs/d/but_not_list_objects.sql). The script writes the benchmark model plus `blocked: [user]` and `viewer: ([user, team#member] or editor or viewer from parent) but not blocked` (from then on the latest model). It blocks one of the documents of user 7. It times `fga_list_object_ids_current('document', 'viewer')`. Then it times the per-candidate path, for which it clears the compiled `diff_relation` inside a rolled-back transaction.

The set-based path and the per-candidate path return the same 6,701 ids (we also compared them id by id on local Postgres 16). The set-based path is 540x faster than the per-candidate path. It costs about the same as the monotone list, because the subtract walk is one probe. Do not compare the Check row with the opt figure. The data is different, because the parents phase had run here.

### What the pass changed and what it did not change

- **Wide FGA reads are 2.2-4x faster.** They are now 1.2-1.5x the best of A, B and C. They are faster than A on every page and count. The two-arm parents projection gained most (38.6 → 10.9 ms), because the folder arm now costs nothing after pruning.
- **Deep: ListObjects changed from 0.78 to 0.33 ms**, within 1.2x of C. The pages match A, B and C.
- **Large default barely changed**, except `share_list_objects` (0.54 → 0.36 ms) and the two-arm page (1.66 → 1.11 ms). Those walks have a few nodes, so the overhead of each call dominates.
- **Check did not change** (`nest_check` 0.41 → 0.40 ms large, 0.43 deep, 0.44 wide). The trims saved about 13% of a local Check in the server (0.234 → 0.204 ms), but pgbench shows no gain. The gap that is left to A (1.3-1.4x) is the statement count of `_fga_bidi`. Each round has two `_fga_bstep` calls, a probe and a meet test. We considered a fold of the user probe into the step. We did not do it, because it changes the level count for userset users.
- **Not done:** the covering `fga_tuples` user index (diagnosis 4: +120 MB at large; not measured again), the typed write path and memoization in `_fga_rec`. Writes still take 0.23 ms, 1.5-1.7x A. Memoization needs state across a recursive PL/pgSQL evaluation, and we found no cheap way.

### Gaps and hotspots

1. **Wide ListObjects is 1.15x A and 1.5x C** (5.12 against 4.44 and 3.41 ms). The 3.7 ms in the server has three parts. The first part is the final leaf join: one index probe plus a heap fetch for each tuple. The user index has no `object_id`, and a covering index would make it index-only. The second part is the sort-based `group by` that keeps the lowest level of each target (generic plan, small row estimate). The third part is three PL/pgSQL result tuplestores (`_fga_forward`, `_fga_list_object_ids` and the current-subject wrapper).
2. **Check** is 1.3-1.4x A (above). It matters for RLS on each row (`fga_check_current` in an update policy), not for list policies.
3. **Writes** are 1.5-1.7x A: `fga_write_tuple` builds JSON that `fga_write` parses again and validates with six lookups.
4. **Non-monotone relations outside the set-based form** (intersections, `but not (a or b)`, a base that depends on a non-monotone relation) still check every candidate top-down, without memoization. This takes about 2 s for each wide ListObjects, as before. Check on any `but not` relation is also top-down (0.39 ms here).
5. **Cyclic data in the walk with levels:** a node is expanded once for each level at which the walk reaches it. So the walk goes around a userset cycle until level 25 (about 25/cycle-length times, expandable nodes only). The benchmark data has no cycles. `_fga_forward_ids` (one row for each node) is the alternative if cycles become a problem.

## How D runs the scenario

The seeds and workloads are in [`../../bench/designs/d/`](../../bench/designs/d/). They read the same shape tables as every design, so the data is identical by construction.

- **One FGA model, written once** in `seed_sharing.sql`: `team#member: [user, team#member]`; `folder#viewer: [user]`; `document#parent: [folder]`, `document#editor: [user]`, `document#viewer: [user, team#member] or editor or viewer from parent`.
- **Tuples through the native Write API:** `fga_write` with 50,000 tuple keys in each call. The call validates each key against the model, then does one set-based insert. OpenFGA limits a Write to 100 tuples. D does not have this limit (design document section 8.4).

  Nested team k is `team:<k/4>#member@team:<k>#member`. A team share is `document:d#viewer@team:k#member`. A parent link is `document:d#parent@folder:f`.
- **RLS by composition, the idiom of D** (design document section 6): The RBAC policy of `seed_rbac.sql` (`org_id = any(scopes_with_permission(...))`) stays in place for the whole run. Each phase adds or replaces one permissive FGA policy next to it:
  - sharing: `id = any(array(select fga_list_object_ids_current('document', 'viewer')::uuid))`
  - parents_proj (two-arm projection): the same policy `or folder_id = any(array(select fga_list_object_ids_current('folder', 'viewer')::uuid))`
  - parents (single branch): the sharing form again, now that every document has a parent tuple
  - the update policy adds `fga_check_current('editor', 'document:' || id)` (no workload uses it: `rbac_update_one` runs before it exists)
- **Org roles are not in the FGA graph.** In A, B and C the rbac preset is in the same design as sharing. So `folder#viewer` inherits `documents.read` from the org. The single-branch call walks every document of the orgs of the user. D keeps roles in `rbac_*`, and by design there is no bridge between the models. So folders have no parent, and the RBAC policy gives the org-role documents.
- **The parents workloads do different work in D.** The visible sets are identical (the checksums prove it). At large, the FGA call of D returns about 1,000 documents at most (the folder of a folder viewer plus shares; 7 for most users). The call of A returns about 20,000-21,000. This is the real cost of D for this app, but it is not a comparison between designs. Diagnosis, item 4, makes a design-to-design comparison.
- **Workloads:** `share_list_objects` counts `fga_list_object_ids_current('document', 'viewer')`. `nest_check` is `fga_check_current('viewer', 'document:…')`. `write_share` and `write_nest_team` are one `fga_write_tuple(...)` each, rolled back. The page and count workloads are the workloads of A.

## Checksums

The checksums are identical for every policy and configuration: A = B = C = D.

| configuration | rbac | sharing | parents_proj | parents |
| --- | --- | --- | --- | --- |
| large default | `2e1dd348` | `58a66d1d` | `bffa5242` | `bffa5242` |
| medium deep | `d394663f` | `7cf80111` | `3261b092` | `3261b092` |
| medium wide | `d394663f` | `6f7c008d` | `f2867b7f` | `f2867b7f` |

We ran small default, small deep and small wide on local Postgres 16.4 before the Docker runs (`bench/run.sh --scale small [--shape …] --duration 1`, reports not kept). They also matched A, B and C for all four policies.

## Results

All values are p50 / p95 in ms. A, B and C are the `opt` runs of [`OPTIMIZATIONS.md`](./OPTIMIZATIONS.md). "D against best" is the p50 of D divided by the best p50 of A, B and C. The budget column is `bench/budgets.tsv` (p95).

### Large, default shape (1M documents)

| workload | A p50 / p95 | B p50 / p95 | C p50 / p95 | D p50 / p95 | D against best of A/B/C (p50) | budget p95 | D status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.3 / 0.56 | 0.27 / 0.41 | 0.24 / 0.33 | 0.22 / 0.36 | 0.9x | 1 | ok |
| rbac_select_page | 0.76 / 1.44 | 0.73 / 1.1 | 0.67 / 0.91 | 0.72 / 1.81 | 1.1x | 3 | ok |
| rbac_select_count | 0.78 / 1.07 | 0.78 / 0.99 | 0.73 / 0.93 | 0.77 / 1.55 | 1.1x | 3 | ok |
| rbac_update_one | 0.47 / 0.65 | 0.47 / 0.68 | 0.36 / 0.5 | 0.28 / 0.44 | 0.8x | 3 | ok |
| write_assign_role | 0.15 / 0.23 | 0.14 / 0.22 | 0.17 / 0.24 | 0.14 / 0.22 | 1.0x | 1 | ok |
| share_list_objects | 0.29 / 0.38 | 0.29 / 0.43 | 0.25 / 0.36 | 0.54 / 0.71 | 2.2x | 2 | ok |
| share_select_page | 1.03 / 1.35 | 1 / 1.29 | 0.93 / 1.27 | 1.29 / 3.34 | 1.4x | 6 | ok |
| write_share | 0.15 / 0.23 | 0.14 / 0.21 | 0.17 / 0.25 | 0.23 / 0.35 | 1.6x | 1 | ok |
| parents_proj_select_page | 1.33 / 2.62 | 1.15 / 1.55 | 1.05 / 1.57 | 1.66 / 2.61 | 1.6x | 4 | ok |
| parents_proj_select_count | 8.42 / 14.66 | 8.2 / 12.36 | 7.88 / 9.97 | 8.92 / 11.03 | 1.1x | 9 | OVER |
| parents_select_page | 45.65 / 66.27 | 13.65 / 16.82 | 4.94 / 6.55 | 1.4 / 9.45 | 0.3x | 32 | ok |
| parents_select_count | 75.08 / 92.44 | 21.57 / 27.61 | 11.88 / 15.53 | 8.44 / 15.96 | 0.7x | 70 | ok |
| write_nest_team | 0.15 / 0.27 | 0.62 / 0.78 | 57.66 / 77.18 | 0.24 / 0.5 | 1.6x | 1 | ok |
| nest_check | 0.31 / 0.48 | 0.32 / 0.42 | 0.3 / 0.45 | 0.41 / 0.64 | 1.4x | 2 | ok |

The table shows the seed time (s) and the cumulative size of the `permissions` tables (MB).

| phase | A s / MB | B s / MB | C s / MB | D s / MB |
| --- | --- | --- | --- | --- |
| rbac | 5.14 / 7 | 4.31 / 7.4 | 4.95 / 5.3 | 4.86 / 5.4 |
| sharing | 0.65 / 18.7 | 1 / 19.6 | 1.93 / 21.3 | 1.84 / 16.1 |
| parents_proj | 0.08 / 19.6 | 0.11 / 20.6 | 0.34 / 22.3 | 0.1 / 16.8 |
| parents | 31.02 / 404.3 | 44.82 / 377.9 | 17.63 / 182.4 | 33.8 / 284.9 |
| nesting | 0.05 / 404.3 | 0.02 / 377.9 | 0.04 / 183.2 | 0.03 / 284.9 |

### Medium, deep shape (100k documents, team chains 9 deep)

| workload | A p50 / p95 | B p50 / p95 | C p50 / p95 | D p50 / p95 | D against best of A/B/C (p50) | budget p95 | D status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.29 / 0.4 | 0.27 / 0.36 | 0.24 / 0.32 | 0.22 / 0.36 | 0.9x | 1 | ok |
| rbac_select_page | 0.44 / 0.56 | 0.46 / 0.57 | 0.42 / 0.57 | 0.41 / 0.7 | 1.0x | 2 | ok |
| rbac_select_count | 0.35 / 0.48 | 0.37 / 0.48 | 0.32 / 0.41 | 0.32 / 0.53 | 1.0x | 2 | ok |
| rbac_update_one | 0.48 / 0.66 | 0.46 / 0.58 | 0.35 / 0.46 | 0.28 / 0.45 | 0.8x | 3 | ok |
| write_assign_role | 0.15 / 0.23 | 0.14 / 0.21 | 0.18 / 0.24 | 0.14 / 0.21 | 1.0x | 1 | ok |
| share_list_objects | 0.31 / 0.41 | 0.32 / 0.4 | 0.28 / 0.37 | 0.78 / 1.02 | 2.8x | 1 | OVER |
| share_select_page | 0.76 / 1 | 0.72 / 0.89 | 0.66 / 0.9 | 1.18 / 1.5 | 1.8x | 3 | ok |
| write_share | 0.15 / 0.22 | 0.14 / 0.2 | 0.17 / 0.23 | 0.23 / 0.31 | 1.6x | 1 | ok |
| parents_proj_select_page | 1 / 1.26 | 0.83 / 1.14 | 0.73 / 1 | 1.79 / 2.74 | 2.5x | 4 | ok |
| parents_proj_select_count | 1.25 / 1.47 | 1.14 / 1.4 | 0.99 / 1.18 | 2.09 / 2.84 | 2.1x | 4 | ok |
| parents_select_page | 7.41 / 9.76 | 4.52 / 5.54 | 2.83 / 3.8 | 1.23 / 2.4 | 0.4x | 25 | ok |
| parents_select_count | 6.4 / 8.06 | 3.74 / 6.01 | 2.1 / 2.69 | 1.54 / 2.52 | 0.7x | 23 | ok |
| write_nest_team | 0.15 / 0.23 | 0.63 / 0.73 | 75.12 / 115.12 | 0.23 / 0.31 | 1.5x | 1 | ok |
| nest_check | 0.34 / 0.47 | 0.34 / 0.44 | 0.3 / 0.41 | 0.43 / 0.54 | 1.4x | 2 | ok |

The table shows the seed time (s) and the cumulative size of the `permissions` tables (MB).

| phase | A s / MB | B s / MB | C s / MB | D s / MB |
| --- | --- | --- | --- | --- |
| rbac | 0.6 / 3.6 | 0.48 / 3.9 | 0.81 / 2.9 | 0.46 / 3 |
| sharing | 0.36 / 9.5 | 0.48 / 10.1 | 1.08 / 15 | 0.89 / 8.7 |
| parents_proj | 0.04 / 10 | 0.06 / 10.6 | 0.15 / 15.5 | 0.05 / 9 |
| parents | 2.14 / 48.6 | 3.97 / 46.5 | 1.57 / 31.5 | 3.18 / 35.9 |
| nesting | 0.02 / 48.6 | 0.02 / 46.5 | 0.06 / 33.1 | 0.02 / 35.9 |

### Medium, wide shape (100k documents, 50 teams per user, 50 documents per team)

| workload | A p50 / p95 | B p50 / p95 | C p50 / p95 | D p50 / p95 | D against best of A/B/C (p50) | budget p95 | D status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| rbac_check | 0.29 / 0.4 | 0.28 / 0.37 | 0.24 / 0.35 | 0.21 / 0.31 | 0.9x | 1 | ok |
| rbac_select_page | 0.44 / 0.56 | 0.46 / 0.59 | 0.44 / 0.61 | 0.4 / 0.61 | 0.9x | 2 | ok |
| rbac_select_count | 0.36 / 0.48 | 0.36 / 0.45 | 0.33 / 0.43 | 0.31 / 0.46 | 0.9x | 2 | ok |
| rbac_update_one | 0.49 / 0.63 | 0.48 / 0.95 | 0.38 / 0.49 | 0.27 / 0.48 | 0.7x | 3 | ok |
| write_assign_role | 0.15 / 0.23 | 0.14 / 0.24 | 0.18 / 0.26 | 0.14 / 0.25 | 1.0x | 1 | ok |
| share_list_objects | 4.44 / 5.57 | 8.41 / 15.8 | 3.41 / 3.87 | 17.77 / 37.11 | 5.2x | 13 | OVER |
| share_select_page | 14.44 / 16.96 | 17.82 / 24.18 | 8.2 / 16.47 | 26.2 / 49.49 | 3.2x | 42 | OVER |
| write_share | 0.15 / 0.22 | 0.16 / 0.4 | 0.17 / 0.24 | 0.23 / 0.32 | 1.5x | 1 | ok |
| parents_proj_select_page | 14.98 / 18.27 | 15.05 / 21.68 | 8.73 / 18.83 | 38.63 / 51.14 | 4.4x | 51 | OVER |
| parents_proj_select_count | 13.24 / 16.48 | 13.44 / 18.05 | 6.33 / 7.17 | 36.07 / 42.51 | 5.7x | 31 | OVER |
| parents_select_page | 14.74 / 19.23 | 13.68 / 19.98 | 8.06 / 10.65 | 23.56 / 34.94 | 2.9x | 46 | ok |
| parents_select_count | 13.31 / 16.64 | 12.22 / 17.51 | 6.61 / 7.48 | 21.58 / 27.57 | 3.3x | 40 | ok |
| write_nest_team | 0.15 / 0.21 | 1.47 / 1.81 | 61.23 / 73.27 | 0.23 / 0.3 | 1.5x | 1 | ok |
| nest_check | 0.37 / 0.48 | 0.34 / 0.61 | 0.31 / 0.44 | 0.45 / 0.96 | 1.5x | 2 | ok |

The table shows the seed time (s) and the cumulative size of the `permissions` tables (MB).

| phase | A s / MB | B s / MB | C s / MB | D s / MB |
| --- | --- | --- | --- | --- |
| rbac | 0.58 / 3.6 | 0.51 / 3.9 | 0.84 / 2.9 | 0.45 / 3 |
| sharing | 5.88 / 97.4 | 12.56 / 105.3 | 24.71 / 191.6 | 13.26 / 81.4 |
| parents_proj | 0.04 / 97.9 | 0.35 / 105.8 | 0.2 / 192.2 | 0.05 / 81.8 |
| parents | 2.32 / 136.4 | 12.99 / 141.6 | 1.65 / 208.2 | 3.18 / 108.6 |
| nesting | 0.04 / 136.4 | 0.02 / 141.6 | 0.04 / 209.1 | 0.01 / 108.6 |

### Budget misses (`--check`)

| configuration | D | A | B | C |
| --- | --- | --- | --- | --- |
| large default | `parents_proj_select_count` 11.03 > 9 | same workload 14.66 > 9; `parents_select_page` 66.27 > 32; `parents_select_count` 92.44 > 70 | `parents_proj_select_count` 12.36 > 9 | `parents_proj_select_count` 9.97 > 9; `write_nest_team` 77.18 > 1 |
| medium deep | `share_list_objects` 1.02 > 1 | none | none | `write_nest_team` 115.12 > 1 |
| medium wide | `share_list_objects` 37.11 > 13; `share_select_page` 49.49 > 42; `parents_proj_select_page` 51.14 > 51; `parents_proj_select_count` 42.51 > 31 | none | `share_list_objects` 15.8 > 13; `write_nest_team` 1.81 > 1 | `write_nest_team` 73.27 > 1 |

The large `parents_proj_select_count` miss is shared by all four designs (the heap-fetch floor in [`VERSIONS.md`](./VERSIONS.md)). The wide p95 values are noisy. A rerun of 5 s with `--only share_list_objects` on the same server gave p50 16.55 ms and p95 22.28 ms. The p50 reproduces, but the p95 does not. Other Docker containers (an unrelated local Supabase stack) ran during these runs. We did not record whether they ran during the runs of A, B and C.

### Storage and seeds

At large, `fga_tuples` is 279 MB for 1.04M tuples (the parent links are 1M of them). The RBAC tables add 5 MB. This is below A (404 MB) and B (378 MB). D stores one row for each tuple with no surrogate key.

D has one secondary index, `(user_type, user_id, user_relation, object_type, relation)`. B-tree deduplication shrinks the index to 12 MB (1,000 parent tuples share each key). C (182 MB) is smaller still.

The 1M parent tuples load in 33.8 s through `fga_write` (about 30,000 validated tuples each second). The wide sharing seed (300k tuples) takes 13.3 s, between A (5.9 s) and C (24.7 s).

## Diagnosis

We took all measurements below in the Docker PG 18 server, right after the runs. We used the database of the benchmark, which we kept with `--keep-running`. They use a single session and a warm cache. Per-call times come from PL/pgSQL loops (`clock_timestamp()`) over 30 users or 500-2,000 calls.

Call counts come from `track_functions = 'all'`. Plans come from `auto_explain` with nested statements. The experiments with the name "variant" are throwaway `pg_temp` functions or indexes in that database. They are not changes to the prototype.

### 1. ListObjects takes 4x the time of A for each reached node (wide sharing, deep shape)

The server, the data and the users are the same: users 1-30 of medium wide (6,574 documents, 134 teams reached). `_reach` of A takes **3.9 ms** for each call. `_fga_forward` of D takes **17 ms**. A rerun of A for 5 s on the same server reproduced the benchmark number of A (p50 4.41 ms). So the cause is the design, not the machine.

Time goes into the steps of the walk (user 7: 5 forward steps of 0.6-4.8 ms each, 12.8 of 15.8 ms inside `_fga_fstep`). Every step does these actions. It unnests the frontier into a materialized CTE and hash-joins it to `fga_edges`. It probes `fga_tuples` and applies the computed closure.

It anti-joins the result against the whole visited set (unnested from three `text[]` arrays that grow, 5,140 entries at step 4). It sorts and groups for `min(level)`. It then uses `array_agg` for four arrays that the next step unnests again.

The plans are generic with row estimates of 1-10, so the `group by` is sort-based. The walk also carries the leaves. The 2,500 documents that a step reaches go into the frontier and the visited set of the next step, although `document#viewer` has no outgoing edge. The edge join drops them, but only after the cost. In the deep shape the same walk takes 10 steps with a fixed cost of about 45 µs each. So `share_list_objects` takes 0.78 ms against 0.28-0.32 ms.

The four-way `union all` with empty contextual-tuple branches (a risk in the design document) is **not** a measurable cost in the steady state. The branches over `unnest('{}')` run in microseconds, and the plan is cached. A variant without them was within the noise between runs (26-45 ms against 26-35 ms for a step of 20,000 rows). They only add planning time to the first call in a session (1.4 ms against 0.4 ms for the first step).

**Fix: one recursive CTE over a pre-joined edge list.** It has the `_reach` shape of A. The list has each `d` or `t` edge already expanded with its computed closure. So the recursive term is one join to `fga_tuples`. Only `(type, relation)` pairs with an outgoing edge recurse. We measured a variant: **17 ms → 8.5 ms** on the wide walk, with the same ids.

It has no levels, so the depth-25 rule needs a new implementation. The implementation can use a level column with `min` for each node in the final select, or a cap on the recursion. The variant is a lower bound for that. We expect wide `share_list_objects` to be about 2x faster, and deep to change from 0.78 to about 0.35 ms (no function call for each step). Every list-based page improves in the same way.

### 2. ListObjects walks the whole graph for any target type (the two-arm policy pays twice)

`fga_list_object_ids_current('folder', 'viewer')` for a wide user who views no folder takes **13.7 ms and returns nothing**. The forward walk expands every team and document that the user reaches, although no team or document leads to `folder#viewer`. The two-arm projection policy calls ListObjects twice (documents and folders). This is why `parents_proj_select_page` of D (38.6 ms) is about 1.5x its own `share_select_page` (26.2 ms) on wide, and 1.3-1.5x on the other shapes.

**Fix: prune the frontier to nodes that can reach the target relation.** The code uses reverse reachability over `fga_edges` and the closure. This is a few rows for each model and target. The code can compile it at model write, as it does for `fga_paths`.

The code also prunes to nodes with an outgoing edge. A variant gave: folder list **13.7 → 0.25 ms**; document list 17.0 → 13.9 ms (the documents are no longer carried as frontier). We expect wide `parents_proj_select_page` to change from 38.6 to about 25 ms, and with fix 1 to roughly the numbers of A. On the FGA-only large data below, it removes the last step (8 ms of 52 ms: 20,005 leaf documents expanded to find nothing).

### 3. ListObjects on a non-monotone relation checks every candidate top-down

The benchmark model is monotone, so the benchmark never reaches `_fga_rec`. We measured separately on the wide data with `viewer: (...) but not blocked` (`blocked: [user]`, one blocked tuple): **2,079 ms** for each `fga_list_object_ids_current` for user 7 (6,702 ids). The monotone relation takes 17 ms, so this is 120x. The counts for one call are: 20,106 `_fga_rec`, 33,512 `_fga_rec_node`, 6,702 `_fga_bidi`, 5,900 `_fga_bstep`, 4,205 `_fga_fstep`. This is one full bidirectional Check for each candidate, about 310 µs each, with no memoization of the shared team subproblems. A Check on that relation takes 270 µs (one candidate).

**Fix: a set-based difference when the subtract side is monotone** (the common case: a block list, a ban). The result is the ListObjects of the base (one forward walk). The code removes the objects that the user reaches through the subtract relation (a second forward walk). Intersection works the same way with an intersect.

Keep `_fga_rec` for subtracts that are non-monotone or can cycle (the cycle rule of design document section 5 matters only there). We expect two walks, about 2 x 17 ms = 35 ms at wide (60x), or about 17 ms with fix 1. Memoization of `_fga_rec` results for each request would also help Check on `and` and `but not`, but it is secondary.

### 4. FGA-only parents: org roles mirrored into the graph

We compared the designs on the single-branch walk of A. After the large run, we added a second model to the database: an org type, `folder#parent: [org]` and `folder#viewer: [user] or viewer from parent`. We also added one `org:o#viewer@user:u` tuple for each RBAC assignment (20,000) and `folder#parent@org` for the 1,000 folders. ListObjects then returns the same set as the single call of A (20,214 ids on average over users 1-30).

It takes **52 ms** for each call, against 45.6 ms p50 for the whole `parents_select_page` of A (B 13.7 ms, C 4.9 ms). The steps take 0.8, 0.5, 33-35 (folder → 20,000 documents through the parent tuples) and 8-11 ms (expand 20,005 leaves for nothing). In the big step, most of the time goes to the index scan on `fga_tuples_user_idx` plus a heap fetch for each parent tuple. The cause is that the index has no `object_id`.

**Fix: a covering user index**, `(user_type, user_id, user_relation, object_type, relation) include (object_id)`, so that the forward probes are index-only. A variant gave **52 → 35 ms** here, and 17 → 15 ms on the wide walk. The index grows from 12 MB (deduplicated) to 133 MB at large. Total storage changes from 285 MB to about 405 MB, the size of A. The index is worth the cost if apps put large fan-outs (parents, org-wide grants) in FGA. With the composition of D they mostly do not.

### 5. Check: fixed overhead per call

`nest_check` takes 0.41-0.45 ms against 0.30-0.37 ms for A, B and C. One `fga_check_current` costs about 200 µs in the server (loop of 2,000 calls). These are the parts. `_fga_current` (subject, latest model by `seq desc limit 1`, user type exists) takes about 6 µs. `_fga_parse_object` (object format, type and relation exist) takes 7 µs. `_fga_path_exists` takes 9 µs.

`_fga_bidi` takes 177 µs. The bidirectional search does 2 `_fga_bstep` calls here. It also does 4-6 other statements (start frontiers, the user probe, the meet test), each of a few tens of µs. So the model resolution and validation in each call (a risk in the design document) are about 10% of a Check. The rest is statement count.

**Fix:** resolve the model and validate `(type, relation)` once for each transaction. The code can use a `set_config('permissions.fga_model', ..., true)` cache with the latest `seq` as key. It can also use one lookup that returns the model id, the monotone flag and the path existence in one statement. This saves about 20 µs for each call, 10%.

If the code folds the start frontiers and the meet test into the step queries, it cuts the statement count by about half. We expect 0.41 → about 0.32 ms, in the range of A. This matters for RLS on each row (`fga_check_current` in an update policy runs once for each candidate row), not for list policies.

### Writes

`write_share` and `write_nest_team` take 0.23 ms against 0.15 ms for A. `fga_write_tuple` builds a JSON key. `fga_write` parses it again, resolves the model, validates the user, the object and the type restriction (six small lookups), checks duplicates and inserts. A dedicated typed path would save most of the 0.08 ms. In it, `fga_write_tuple` validates its three strings directly, with no JSON round trip. No write maintains derived rows, so nesting a team of 1,000 members costs the same as any tuple (C: 58-75 ms).

## Risks in the design document, and the verdict

| Risk (design document section 10) | Measured | Verdict |
| --- | --- | --- |
| Check: a PL/pgSQL call for each search step, a four-way union with empty contextual branches | empty branches: noise in the steady state, +1 ms planning on the first call in a session; calls for each step: about half of the 200 µs of Check | The statement count matters; the empty branches do not |
| ListObjects: PL/pgSQL loop over growing arrays instead of a recursive CTE | 4x A for each reached node on wide; a CTE variant halves it | Real, the main wide cost (fix 1) |
| Every call resolves the latest model again and validates type and relation again | about 20 µs of a 200 µs Check, 0.2 ms of a 17 ms list | Minor (fix 5) |
| `and` / `but not` evaluated top-down without memoization | ListObjects 2.1 s against 17 ms on wide; Check 270 µs | Real and severe for lists; not in the benchmark model (fix 3) |
| (not flagged) walks ignore the target type | 13.7 ms for an empty folder list; the two-arm policy pays it on every query | Real (fix 2) |

## Proposed fixes, in order of expected gain

Items 1-3 are done in opt2, with the measured gains in that section. Item 5 is partly done. Items 4 and 6 are not done in opt2. The opt3 section later did item 6 (typed writes) and part of item 5.

1. Set-based `but not` and `and` when the subtract or other operand is monotone: non-monotone ListObjects changes from 2.1 s to about 35 ms (wide). The current benchmark does not show it, because the model is monotone. A benchmark workload with a block list would show it.
2. ListObjects as a recursive CTE over a pre-joined edge list (with the depth rule restored). Wide lists change from 17 to about 8.5 ms, and deep lists from 0.78 to about 0.35 ms. It improves all FGA list policies.
3. Prune the walk frontier by target relevance: empty-arm lists change from 13.7 to 0.25 ms. The wide two-arm parents page changes from 38.6 to about 25 ms (more with item 2).
4. Add a covering `fga_tuples` user index: lists with a large fan-out are 33% faster (52 → 35 ms), and wide lists are 10% faster. The cost is +120 MB at large.
5. Check overhead (a cache for the model and the validation, fewer statements in `_fga_bidi`): `nest_check` changes from 0.41 to about 0.32 ms.
6. Typed `fga_write_tuple` without the JSON round trip: writes change from 0.23 to about 0.15 ms.

## Files

- Reports: `pg18-docker-d-large-default-opt.md`, `pg18-docker-d-medium-deep-opt.md` and `pg18-docker-d-medium-wide-opt.md` (plans, per-table storage, per-user checksums), in [`../../bench/baselines/`](../../bench/baselines/). The JSON is in [`../../bench/baselines/data/`](../../bench/baselines/data/). The second pass has the same names with `-opt2`. The third pass has `-opt3` (JSON in `data/`), `-opt3-before` and `-opt3-covering` (reports only). The phase 6 reports have the tag `p6`.
- Side scripts of phase 5: [`../../bench/designs/d/conditions_cost.sql`](../../bench/designs/d/conditions_cost.sql) (conditions in the server) and [`../../bench/designs/d/cyclic_walk.sql`](../../bench/designs/d/cyclic_walk.sql) (userset cycles).
- The `but not` measurement: [`../../bench/designs/d/but_not_list_objects.sql`](../../bench/designs/d/but_not_list_objects.sql).
- Seeds and workloads: [`../../bench/designs/d/`](../../bench/designs/d/). `bench/run.sh` accepts `--design d` (the default for the extension file, `pg_permissions--0.0.1.sql`).
