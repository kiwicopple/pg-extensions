# Design D benchmarked

Design D ([`../../designs/d-per-model.md`](../../designs/d-per-model.md), [`../../pg_permissions--0.0.1.sql`](../../pg_permissions--0.0.1.sql), which was `prototypes/d-per-model.sql` when this was measured) measured on 2026-10-29 with exactly the workloads, scales and shapes of A, B and C, and compared with their session 3 optimized runs in [`OPTIMIZATIONS.md`](./OPTIMIZATIONS.md). Same setup: Docker, Postgres 18.6 with pg_tle 1.5.3, `cpus: 4`, `mem_limit: 6g`, 4 pgbench clients, 10 s per workload, one run per configuration, strictly serial (`docker/run-matrix.sh bench --versions 18 --designs d -- --scale <s> --shape <sh> --tag opt --check`). The D files use the same `opt` tag so they sit next to A, B and C's in the docs site's primary series: `pg18-docker-d-{large-default,medium-deep,medium-wide}-opt.{md,json}`. D itself is unoptimized: this is a measurement, nothing in the prototype was changed. The second pass, which acts on the diagnosis below, is in section "opt2".

## Summary

- **Correct everywhere.** Every read policy's checksum equals A's, B's and C's in all three Docker configurations, and in small default, deep and wide on local Postgres 16.4 (run before timing anything).
- **RBAC: as fast as the fastest engine.** `rbac_*` tables give the best or tied-best `rbac_check` (0.21-0.22 ms) and `rbac_update_one` (0.27-0.28 ms, 20-30% under C) everywhere.
- **Default and deep shapes: 1.1-2.8x slower than the best of A/B/C on FGA reads, but within budget**, except `share_list_objects` at medium deep (p95 1.02 ms against 1 ms) and the large `parents_proj_select_count` miss that all four engines share. Writes are 1.5x A's (0.23 against 0.15 ms) and far below C's nesting write (0.23 against 58-75 ms).
- **Wide shape: D is the slowest engine.** `share_list_objects` 17.8 ms against 3.4-8.4 ms, the sharing page 26 ms against 8-18 ms, the two-arm parents page 38.6 ms against 8.7-15 ms. Four budget misses.
- **The single-branch parents rows are not comparable** (D 1.4 ms against A's 45.6 ms at large): D keeps org roles in `rbac_*` and composes, so its FGA walk never visits the org-role documents that A, B and C walk to. With org roles mirrored into FGA (A's scenario literally), D's ListObjects for the same users takes 52 ms per call against A's 45.6 ms page (section "FGA-only parents").
- **Worst hotspot: ListObjects on a relation with `but not`.** Not in the benchmark model; measured separately on the wide data: 2.1 s per call (6,700 candidates, each a full top-down Check), against 17 ms for the monotone relation.
- **Storage:** 285 MB at large after the parents seed, between C (182 MB) and B/A (378/404 MB). Seeds through the native Write API are in A's range (large parents: 33.8 s; A 31.0, B 44.8, C 17.6).
- **opt3 (phase 5 of session 5, section below):** non-monotone ListObjects set-based over the rewrite tree (wide `viewer but not (blocked or muted)` 5.2 s → 7.6 ms, `editor and viewer` 621 → 6.1 ms), typed writes (0.25 → 0.16 ms; large parents seed 33 → 15 s), Check 0.45-0.47 → 0.40 ms at medium, conditions evaluated once per distinct context (wide conditioned ListObjects 14.8 → 10.6 ms; with a context per tuple 3.2 s → 0.17 s). The covering index is measured and left to the user (+120 MB at large, no pgbench gain). Checksums identical to A, B and C.
- **opt2 (second pass, section below):** the fixes proposed under "Diagnosis" (pruned CTE walk, set-based `but not`), measured the same way. Wide FGA reads 2.2-4x faster, now 1.2-1.5x the best of A/B/C and faster than A on every wide page; deep ListObjects 0.78 → 0.33 ms; no budget miss except the large one all engines share; `but not` ListObjects 2.1 s → 4.2 ms. Check and writes unchanged.

## opt3: performance pass 2 (phase 5 of session 5, 2026-10-30)

Phase 5 of [`PLAN.md`](../../PLAN.md) ("Next work"): close the hotspots under "Remaining gaps and hotspots" (opt2 section below) and measure what conditions cost. Same setup as opt and opt2 (Docker, Postgres 18.6, pg_tle 1.5.3, `cpus: 4`, `mem_limit: 6g`, 4 pgbench clients, 10 s per workload, strictly serial), with a frozen copy of the extension file passed as `--impl` so editing the source during a run can't change what is installed: `docker/run-matrix.sh bench --versions 18 --designs d -- --impl bench/results/<copy>.sql --design d --scale <s> --shape <sh> --tag <tag> --check`. Tags: `opt3-before` is `pg_permissions--0.0.1.sql` at `0bd650b` (phase 4 plus the new bench phases, no engine change), `opt3` is the file at `01b9fc2` (this pass), `opt3-covering` is `opt3` with the covering index (pending, below). Reports: `pg18-docker-d-{large-default,medium-deep,medium-wide}-opt3[-before].md` and `pg18-docker-d-{large-default,medium-wide}-opt3-covering.md`; only the `opt3` JSON is in `data/` (the docs site charts it), as with opt2. Running alongside: idle Supabase and freereps stacks and an unrelated `gallant_ritchie` container (openfga/openfga); the laptop itself was in use.

**The "before" is re-measured, not opt2.** Since opt2, phase 2 added `fga_tuples.seq` (an identity column and a unique index) and batched the bench seeds at 100 tuples per `fga_write` (the Write cap), and phase 4 added conditions. So D's storage, write and seed numbers moved before this pass started: large storage 285.0 MB (opt2) to 323.5 MB (opt3-before), `write_share` 0.23 to 0.25-0.26 ms, the large parents seed 30.4 to 33-41 s. The tables below show opt2, opt3-before and opt3 side by side; compare opt3 with opt3-before.

**Paired runs.** Each configuration was run as a pair, before then opt3, back to back (11:26-11:54), because the machine drifted during the day: the same-day reruns of A, B and C (tag `opt3-ref`, reports not kept) came out 3-24% slower than their session 3 `opt` runs (median p50 ratio per engine and configuration 1.03-1.24), and the first opt3 wide run, an hour earlier than its pair, had p95s twice those of its neighbours. The A, B and C columns are their `opt` runs, as in the opt2 section.

### What changed (`pg_permissions--0.0.1.sql`, commits `482aab4` and `01b9fc2`)

1. **Typed writes.** `fga_write_tuple` and `fga_delete_tuple` validate and write a key without building JSON for `fga_write`; `_fga_tuple_for_write` (behind `fga_write`, the seeds and contextual tuples) accepts a key without a condition with one lookup, an unconditioned type restriction that allows it (`_fga_write_key_ok`), instead of six. Anything else goes the old way, so every error is unchanged: `d/42_fga_write_paths` (68 assertions) compares each path with the JSON one on 28 keys, valid and invalid.
2. **Check.** A partial index on the userset tuples, `fga_tuples_userset_idx (object_type, object_id, relation, user_type, user_relation) where user_relation <> ''`, so `_fga_bstep` finds a team's nested teams without reading its plain members (the nest_check team has 1,000 and a wide team 313); the meet test is skipped while a plain user's forward side holds only the user.
3. **Set-based ListObjects over the rewrite tree** (`fga_relations.set_eval`, `_fga_set_rel`, `_fga_set_node`; [`d-per-model.md`](../../designs/d-per-model.md) section 5) for the non-monotone relations outside the set-based difference: intersections, unions under a subtract, nested subtracts, bases that depend on a non-monotone relation, tupleToUserset over one. `d/43_fga_set_eval` (199 assertions) checks it against Check and against the per-candidate path, through the API and the RLS helpers, with conditions, contextual tuples and the depth limit at its boundary.
4. **Conditions once per distinct context** in the forward walk's recursion (a superset walk without levels collects the pairs, `_fga_conds_eval` evaluates each once, `_fga_cond_take` applies the mode per tuple), and an equality join instead of a correlated `IS NOT DISTINCT FROM` subplan wherever evaluated pairs are matched back to tuples (`_fga_forward`, `_fga_forward_ids`, `_fga_fstep`, `_fga_bstep`).
5. **The benchmark** gained two phases for design d ([`../run.sh`](../run.sh) phases 6 and 7): `conditions`, a conditioned copy of the team graph (`cteam`, `document#cviewer`, condition `active` on every membership and team grant, one shared stored context) with plain and conditioned twins for ListObjects, the page, the nested Check and ListUsers; and `blocklist`, `can_view: viewer but not blocked` (the workload of the old side script `designs/d/but_not_list_objects.sql`), `can_view_unmuted: viewer but not (blocked or muted)` and `can_edit: editor and viewer`. The conditions phase's checksum must equal the parents phase's (it does, in every run).

**Correctness.** Every checksum equals A's, B's and C's in all three configurations, in every run of this pass (opt3-before, opt3, opt3-covering, and the A/B/C reruns): the values in the "Checksums" table below. The conditions phase matched the parents phase in every run. Suite: 55 files, 3,604 assertions, locally (PG 16.4) and on PG 16, 17 and 18 in Docker; OpenFGA's consolidated suite 933/746, the ABAC oracle 302/271, the fga_lang oracle 70/70.

### Results, opt3-before against opt3

p50 / p95 in ms. "vs best" is opt3's p50 over the best p50 of A, B and C (their `opt` runs). The new workloads have no budget (only D runs them).

#### Large, default shape

<!-- before: 20261030-114434-opt3-before-0bd650b-large.md; opt3: 20261030-114910-opt3-01b9fc2-large.md -->

| workload | D opt2 p50 / p95 | D before p50 / p95 | D opt3 p50 / p95 | opt3 vs before (p50) | A p50 / p95 | B p50 / p95 | C p50 / p95 | opt3 vs best of A/B/C (p50) | budget p95 | opt3 status |
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

Seed time (s) and size of the `permissions` tables (MB, cumulative):

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

| workload | D opt2 p50 / p95 | D before p50 / p95 | D opt3 p50 / p95 | opt3 vs before (p50) | A p50 / p95 | B p50 / p95 | C p50 / p95 | opt3 vs best of A/B/C (p50) | budget p95 | opt3 status |
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

Seed time (s) and size of the `permissions` tables (MB, cumulative):

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

| workload | D opt2 p50 / p95 | D before p50 / p95 | D opt3 p50 / p95 | opt3 vs before (p50) | A p50 / p95 | B p50 / p95 | C p50 / p95 | opt3 vs best of A/B/C (p50) | budget p95 | opt3 status |
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

Seed time (s) and size of the `permissions` tables (MB, cumulative):

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

| # | candidate (PLAN phase 5) | outcome | before → after | evidence |
| --- | --- | --- | --- | --- |
| 1 | Check (`_fga_bidi` statements) | done: userset index, meet test skipped | `nest_check` p50 0.41 → 0.39 (large), 0.45 → 0.40 (deep), 0.47 → 0.40 ms (wide); in the server 229 → 178 µs (wide) | tables; in-server loops below |
| 1a | ... folding the user probe into the step | rejected | in the server 229 → 390 µs for nest_check (wide): when the probe would hit, the folded step also expands the frontier, here a 1,000-member team | in-server loops below |
| 2 | Typed write path | done | `write_share` 0.25 → 0.16, `write_nest_team` 0.26 → 0.16 ms (wide; 0.58-0.67x everywhere); seeds: large parents 33.1 → 15.3 s, wide sharing 13.6 → 5.9 s | tables |
| 3 | Wide ListObjects: covering user index | **pending user decision** | see below: no pgbench gain at wide, -7% in the server; +120 MB at large | `opt3-covering` |
| 3 | ... one tuplestore fewer (RLS helper calls `_fga_forward` directly) | rejected | 4.39-6.03 → 4.32-5.06 ms in the server, alternating rounds: ≤ 0.3 ms, inside run-to-run noise | in-server loops |
| 3 | ... the lowest-level `group by` (`distinct` when no level can reach 25) | rejected | 3.97 → 3.66 ms in the server (8%), not visible through pgbench; the level-free walk is 2.6 ms, so levels cost about 35%, but most of it is in the recursion, not the grouping | in-server loops |
| 4 | Non-monotone ListObjects outside the set-based form | done: set-based evaluator | wide: `block_or_mute_list_objects` 5,246 → 7.6 ms, `intersect_list_objects` 621 → 6.1 ms; large 16.5 → 0.55 and 2.9 → 0.48 ms (p95 351 → 2.5 and 103 → 2.5); in the server (wide, user 1-30) 5,695 → 6.7 ms and 647 → 5.6 ms | tables |
| 5 | Cyclic userset data | rejected (measured) | leveled walk 4.0 ms on the wide tree, 13.4 ms with a 2-cycle at every inner team (3.3x); the level-free walk 2.6 → 4.7 ms on the same data (it reaches 11,197 ids instead of 6,609) | `designs/d/cyclic_walk.sql` |
| 6 | Conditions | measured; per-row evaluation done | below | `designs/d/conditions_cost.sql`, the conditions phase |

**Candidate 5, why rejected.** The cost is bounded: a node on a cycle of length k is expanded again every k levels up to 25, so at most about 12x for the cyclic part with 2-cycles, 3.3x for the whole walk here. The level-free walk avoids it but loses the depth-25 rule, and a recursive CTE can't drop a (node, level) row because the node was seen at a lower level (its recursive term sees only the previous iteration). Cycles are rare in group data and absent from the benchmark; no exact alternative that costs nothing on acyclic data was found.

### What conditions cost (candidate 6)

Through pgbench (paired runs; `plain_*` and `cond_*` run on the same data, the conditioned copy beside the original):

| configuration | ListObjects plain / cond | page (parents_select_page / cond_select_page) | nested Check (nest_check / cond_nest_check) | ListUsers plain / cond |
| --- | --- | --- | --- | --- |
| large, before | 0.33 / 0.54 | 1.07 / 1.25 | 0.41 / 0.58 | 0.30 / 0.43 |
| large, opt3 | 0.33 / 0.53 | 1.08 / 1.23 | 0.39 / 0.56 | 0.31 / 0.45 |
| deep, before | 0.33 / 0.62 | 0.79 / 1.03 | 0.45 / 0.59 | 0.91 / 1.35 |
| deep, opt3 | 0.34 / 0.53 | 0.70 / 0.95 | 0.40 / 0.56 | 0.89 / 1.37 |
| wide, before | 5.04 / 14.79 | 11.17 / 21.19 | 0.47 / 0.63 | 0.99 / 1.42 |
| wide, opt3 | 4.95 / 10.64 | 11.25 / 16.61 | 0.40 / 0.56 | 0.93 / 1.35 |

(p50 ms.) In the server, on the wide data after the full run (`designs/d/conditions_cost.sql`; time and condition evaluations per call, users 1-30, three rounds; "before" loads `0bd650b`'s walk functions inside a rolled-back transaction):

| call | viewer | cviewer before | cviewer opt3 |
| --- | --- | --- | --- |
| ListObjects, one shared context | 4.9 ms | 14.5 ms, 205 evaluations | 11.4 ms, 2 |
| Check (nest_check fixture) | 0.22 ms | 0.41 ms, 3 | 0.30 ms, 3 |
| ListUsers (a document of teams 1-30, capped at 1,000) | 28.4 ms | 59.2 ms, 4.6 | 45.5 ms, 4.6 |
| ListObjects, a distinct context per tuple | 5.4 ms | 3,203 ms, 6,774 | 167 ms, 6,748 |
| ListUsers, a distinct context per tuple | 26.3 ms | 29-37 s (two calls) | 472 ms, 20,047 (0.6-1.0 s for the same two calls) |

- **A condition evaluation costs about 22 µs** here (`_fga_cond_eval` on `expires > timestamp("...")`: lookup, parameter conversion, interpreter), 7-10x phase 4's `x < 100` micro-benchmark. With one shared context, what is left of the conditioned ListObjects' overhead (11.4 against 4.9 ms) is carrying and matching the context per leaf and the extra walk without levels, not evaluation.
- **The per-row evaluation in the recursion mattered:** 205 evaluations per wide ListObjects for one shared context; now 2 (one in the recursion, one for the leaves). Cost of the change when every context differs: the walk without levels, about 0.3 ms of 167.
- **The quadratic match was the bigger find:** with a context per tuple the old leaves' filter compared every leaf with every evaluated pair (6,700 x 6,700 for a wide ListObjects; 20,000 x 20,000 for ListUsers). An equality join makes both linear: 19x and about 40x.
- **What a conditioned edge costs, now:** a wide ListObjects pays about 2x (shared context) or 30x (a context per tuple: one evaluation per leaf, as phase 4 predicted, 30-60 ms per 10,000); a Check through three conditioned edges about 0.1-0.15 ms; ListUsers 1.5x with a shared context.

### Pending user decision: the covering user index

`fga_tuples_user_idx (user_type, user_id, user_relation, object_type, relation) include (object_id, condition_name)` makes the forward walk's probes index-only (`condition_name` is needed since phase 4: a tuple matches the edge of its own condition). Measured fully (time and MB), not kept in the extension:

| | opt3 | opt3-covering |
| --- | --- | --- |
| storage, large, after the parents seed | 323.7 MB | 444.1 MB (+120 MB, +37%) |
| storage, medium wide, after the parents seed / at the end | 127.1 / 231.5 MB | 171.9 / 311.5 MB |
| index size, medium wide (715k tuples) | 7.3 MB (deduplicated) | 87 MB |
| wide `share_list_objects` p50 | 4.90 | 4.85 |
| wide `parents_select_page` / `_count` p50 | 11.25 / 9.06 | 11.86 / 9.54 |
| wide `plain_list_objects` p50 | 4.95 | 5.15 |
| wide ListObjects in the server (users 1-30, alternating) | 4.79 | 4.47 (-7%) |
| large `parents_select_page` / `_count` p50 (runs 14 min apart) | 1.29 / 9.84 | 1.13 / 9.20 |
| large `plain_list_users` p50 | 0.35 | 12.95 (a plan change: ListUsers' backward probes pick the wider index) |
| large parents seed | 18.7 s | 20.7 s |

Recommendation: don't adopt. The gain the opt diagnosis measured (52 → 35 ms on FGA-only org fan-outs, -33%) needs large fan-outs in FGA, which D's composition avoids; on the benchmark's shapes it is within noise through pgbench, costs 37% more storage at large, and regressed large ListUsers 37x until its plans are pinned.

### Budget misses (`--check`), opt3

| configuration | opt3-before | opt3 |
| --- | --- | --- |
| large default | `parents_proj_select_count` 9.32 > 9 | `parents_proj_select_count` 9.35 > 9 (shared by all four engines: the heap-fetch floor; phase 6 re-baselines it) |
| medium deep | none | none |
| medium wide | none | none |

`bench/budgets.tsv` re-checked: no change. Every opt3 p95 is within its budget but the shared large one; the nine new workloads stay without a budget (the budget rule needs a reference engine, and only D runs them).

### Wrong turns

- **The first "before" runs were contaminated:** they read the extension file at the start of each configuration, and the file was being edited while the batch ran. Medium deep and wide installed half-finished opt3 code (their `intersect_list_objects` was 8.6 ms, the per-candidate path takes 630). Rerun from a frozen copy (`--impl bench/results/opt3-before-0bd650b.sql`); every run since uses a frozen copy.
- **Folding Check's user probe into the backward step** (the opt2 idea, done here so the level accounting stays exact) made the benchmark's Check slower, not faster, and was reverted: see candidate 1a.
- **A cold cache looked like a 2x regression:** the first in-server comparison after a server restart read pages from disk; repeated loops alternating the variants settled it.

### Remaining gaps and hotspots (after opt3)

1. Wide ListObjects is 1.1-1.4x A and 1.4x C through pgbench (4.9 ms); the level-free walk is 35% faster than the leveled one in the server, and the covering index buys 7% in the server and nothing visible through pgbench.
2. Check 1.2-1.3x A (0.39-0.40 ms): the remaining cost is statement count in `_fga_bidi`.
3. ListUsers on non-monotone relations outside the set-based difference still checks every candidate top-down (not in the benchmark).
4. A condition evaluation costs about 22 µs (timestamp parsing in PL/pgSQL), so a context per tuple costs a wide ListObjects about 30x; generated functions per condition (10-25x faster in the phase 4 micro-benchmark) remain rejected for the reasons in `designs/d-conditions.md`.
5. Cyclic userset data costs the leveled walk up to 25/k re-expansions (candidate 5).

## opt2: the second pass (2026-10-29)

The fixes this report's diagnosis proposed, applied to the prototype and measured exactly as before (Docker, Postgres 18.6, `cpus: 4`, 4 clients, 10 s per workload, strictly serial: `docker/run-matrix.sh bench --versions 18 --designs d -- --scale <s> --shape <sh> --tag opt2 --check`). The files are tagged `opt2` (`pg18-docker-d-{large-default,medium-deep,medium-wide}-opt2.{md,json}`), so the `opt` files above, and the docs site's primary series, are unchanged. The design is in [`../../designs/d-per-model.md`](../../designs/d-per-model.md) §5.

**What changed** (`prototypes/d-per-model.sql`, now `pg_permissions--0.0.1.sql`):

1. **Target-pruned walk steps, compiled at model write.** `fga_reach` holds reachability between (type, relation) pairs in the positive graph; `fga_walk_steps` holds, per target relation, every `d`/`t` edge joined with the computed closure of its destination, kept only if the node it yields can reach the target, with `expand` when that node has steps of its own toward it. 13 rows for the benchmark model.
2. **ListObjects is one recursive CTE** (`_fga_forward`), A's `_reach` shape, over those steps: one `fga_tuples` probe per node and step. The recursion produces only expandable nodes; leaves come from one final join of the reached nodes (each at its lowest level) to the steps that yield the target. Levels are kept per row (a node is re-expanded once per distinct level, a cycle until level 25), which keeps the depth-25 rule exact; if an expandable node is first reached at 25, a level-free walk (`_fga_forward_ids`) finishes behind it. The list functions stream the result instead of `array_agg` then `unnest`.
3. **Set-based `but not` for ListObjects and ListUsers** when the base is a positive expression over monotone relations and the subtract is `r` or `r from ts` with `r` monotone: base walk minus subtract walk. A recursive or long subtract rechecks only what it removes with `_fga_rec`. Intersections, union or nested subtracts and non-monotone bases keep the per-candidate path.
4. **Semantics, decided during this pass:** a monotone relation under a subtract is evaluated by its least fixpoint (a userset cycle contributes nobody), in Check too; recursion through negation keeps OpenFGA's cycle rule. `d/31_fga_cycles` now expects true for its cycle case (design doc §5). The OpenFGA suite is unaffected (933/933 stored, 746/746 contextual on 16, 17, 18).
5. Check trims: no statement for a plain user's start frontier or initial meet test, inline object parsing, one lookup for the monotone flag and PathExists.

**Correctness:** every checksum equals A's, B's and C's in all three configurations (the same values as the table under "Checksums"). Seeds and storage are unchanged within noise (large: 285.0 MB against 284.9; parents seed 30.4 s against 33.8).

### Results, opt against opt2

p50 / p95 in ms. A, B and C are their `opt` runs, as above. "vs best" is opt2's p50 over the best p50 of A, B and C.

#### Large, default shape

| workload | D opt p50 / p95 | D opt2 p50 / p95 | opt2 vs opt (p50) | A p50 / p95 | B p50 / p95 | C p50 / p95 | opt2 vs best of A/B/C (p50) | budget p95 | opt2 status |
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

| workload | D opt p50 / p95 | D opt2 p50 / p95 | opt2 vs opt (p50) | A p50 / p95 | B p50 / p95 | C p50 / p95 | opt2 vs best of A/B/C (p50) | budget p95 | opt2 status |
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

| workload | D opt p50 / p95 | D opt2 p50 / p95 | opt2 vs opt (p50) | A p50 / p95 | B p50 / p95 | C p50 / p95 | opt2 vs best of A/B/C (p50) | budget p95 | opt2 status |
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
| large default | `parents_proj_select_count` 11.03 > 9 | `parents_proj_select_count` 11.55 > 9 (shared by all four engines: the heap-fetch floor) |
| medium deep | `share_list_objects` 1.02 > 1 | none |
| medium wide | `share_list_objects`, `share_select_page`, `parents_proj_select_page`, `parents_proj_select_count` | none |

### In-server measurements (Docker PG 18, the wide database the run left behind)

Measured as in "Diagnosis" (PL/pgSQL loops over users 1-30, three rounds, warm cache), on the medium wide data after the full opt2 run:

| call | opt | opt2 | A |
| --- | --- | --- | --- |
| ListObjects `document#viewer` (monotone, about 6,600 ids) | 17 ms | **3.74 ms** | 3.9 ms (`_reach`) |
| ListObjects `folder#viewer` (empty for most users) | 13.7 ms | **0.04 ms** | |
| ListObjects on `viewer: (...) but not blocked`, user 7 (6,701 ids) | 2,079 ms | **4.16 ms** (set-based) | |
| the same, users 1-30 | | 4.32 ms | |
| the same, per-candidate path on the same build (user 7) | | 2,234 ms | |
| Check on that relation (top-down `_fga_rec`) | 270 µs | 391 µs | |

The `but not` rows come from [`../designs/d/but_not_list_objects.sql`](../designs/d/but_not_list_objects.sql): it writes the benchmark model plus `blocked: [user]` and `viewer: ([user, team#member] or editor or viewer from parent) but not blocked` (the latest model from then on), blocks one of user 7's documents, and times `fga_list_object_ids_current('document', 'viewer')`, then the per-candidate path by clearing the compiled `diff_relation` inside a rolled-back transaction. Set-based and per-candidate return the same 6,701 ids (also compared id by id on local Postgres 16). 540x faster than per-candidate, and about the cost of the monotone list: the subtract walk is one probe. The Check row is not comparable with the opt figure (different data: the parents phase had run here).

### What the pass did and didn't buy

- **Wide FGA reads 2.2-4x faster**, now 1.2-1.5x the best of A/B/C and faster than A on every page and count. The two-arm parents projection gained most (38.6 → 10.9 ms): the folder arm costs nothing now that it is pruned.
- **Deep: ListObjects 0.78 → 0.33 ms**, within 1.2x of C; the pages match A/B/C.
- **Large default barely moved** except `share_list_objects` (0.54 → 0.36) and the two-arm page (1.66 → 1.11): those walks are a few nodes, so per-call overhead dominates.
- **Check didn't move** (`nest_check` 0.41 → 0.40 large, 0.43 deep, 0.44 wide). The trims saved about 13% of a local in-server Check (0.234 → 0.204 ms) but nothing visible through pgbench. The remaining gap to A (1.3-1.4x) is `_fga_bidi`'s statement count (two `_fga_bstep` calls plus a probe and a meet test per round); folding the user probe into the step was considered and not done (it changes the level accounting for userset users).
- **Not done:** the covering `fga_tuples` user index (diagnosis 4: +120 MB at large; not re-measured), the typed write path (writes still 0.23 ms, 1.5-1.7x A), memoization in `_fga_rec` (needs state across a recursive PL/pgSQL evaluation; no cheap way found).

### Remaining gaps and hotspots

1. **Wide ListObjects is 1.15x A and 1.5x C** (5.12 against 4.44 and 3.41 ms). Of the 3.7 ms in-server: the final leaf join (one index probe plus a heap fetch per tuple, since the user index has no `object_id`: the covering index would make it index-only), the sort-based `group by` that keeps each target's lowest level (generic plan, small row estimate), and three PL/pgSQL result tuplestores (`_fga_forward`, `_fga_list_object_ids`, the current-subject wrapper).
2. **Check** 1.3-1.4x A (above). Matters for per-row RLS (`fga_check_current` in an update policy), not for list policies.
3. **Writes** 1.5-1.7x A: `fga_write_tuple` builds JSON that `fga_write` re-parses and validates with six lookups.
4. **Non-monotone relations outside the set-based form** (intersections, `but not (a or b)`, a base that depends on a non-monotone relation) still check every candidate top-down without memoization: about 2 s per wide ListObjects, as before. Check on any `but not` relation is top-down too (0.39 ms here).
5. **Cyclic data in the leveled walk:** a node is expanded once per level it is reached at, so a userset cycle is walked around until level 25 (about 25/cycle-length times, expandable nodes only). Not in the benchmark data; `_fga_forward_ids` (one row per node) is the alternative if it shows up.

## How D runs the scenario

The seeds and workloads are in [`../designs/d/`](../designs/d/). They read the same shape tables as every design, so the data is identical by construction.

- **One FGA model, written once** in `seed_sharing.sql`: `team#member: [user, team#member]`; `folder#viewer: [user]`; `document#parent: [folder]`, `document#editor: [user]`, `document#viewer: [user, team#member] or editor or viewer from parent`.
- **Tuples through the native Write API**: `fga_write` with 50,000 tuple keys per call (each key validated against the model, then one set-based insert). OpenFGA caps a Write at 100 tuples; D doesn't (design doc §8.4). Nested team k is `team:<k/4>#member@team:<k>#member`; a team share is `document:d#viewer@team:k#member`; a parent link is `document:d#parent@folder:f`.
- **RLS by composition, D's idiom** (design doc §6): `seed_rbac.sql`'s RBAC policy (`org_id = any(scopes_with_permission(...))`) stays in place for the whole run, and each phase adds or replaces one permissive FGA policy next to it:
  - sharing: `id = any(array(select fga_list_object_ids_current('document', 'viewer')::uuid))`
  - parents_proj (two-arm projection): that `or folder_id = any(array(select fga_list_object_ids_current('folder', 'viewer')::uuid))`
  - parents (single branch): the sharing form again, now that every document has a parent tuple
  - the update policy adds `fga_check_current('editor', 'document:' || id)` (not exercised: `rbac_update_one` runs before it exists)
- **Org roles are not in the FGA graph.** In A, B and C the rbac preset lives in the same engine as sharing, so `folder#viewer` inherits `documents.read` from the org and the single-branch call walks every document of the user's orgs. D keeps roles in `rbac_*` (no bridge between the models, by design), so folders have no parent and org-role documents come from the RBAC policy. The visible sets are identical (the checksums prove it), but the parents workloads do different work: at large, D's FGA call returns at most about 1,000 documents (a folder viewer's folder plus shares; 7 for most users) where A's returns about 20,000-21,000. That is the real cost of D for this app, but it is not an engine-to-engine comparison; the next section is.
- Workloads: `share_list_objects` counts `fga_list_object_ids_current('document', 'viewer')`; `nest_check` is `fga_check_current('viewer', 'document:…')`; `write_share` and `write_nest_team` are one `fga_write_tuple(...)` each, rolled back. The page and count workloads are A's.

## Checksums

Identical for every policy and configuration, A = B = C = D:

| configuration | rbac | sharing | parents_proj | parents |
| --- | --- | --- | --- | --- |
| large default | `2e1dd348` | `58a66d1d` | `bffa5242` | `bffa5242` |
| medium deep | `d394663f` | `7cf80111` | `3261b092` | `3261b092` |
| medium wide | `d394663f` | `6f7c008d` | `f2867b7f` | `f2867b7f` |

Before the Docker runs, small default, small deep and small wide on local Postgres 16.4 (`bench/run.sh --scale small [--shape …] --duration 1`, not kept) also matched A, B and C for all four policies.

## Results

p50 / p95 in ms. A, B and C are the `opt` runs of [`OPTIMIZATIONS.md`](./OPTIMIZATIONS.md). "D vs best" is D's p50 over the best p50 of A, B and C. The budget column is `bench/budgets.tsv` (p95).

### Large, default shape (1M documents)

| workload | A p50 / p95 | B p50 / p95 | C p50 / p95 | D p50 / p95 | D vs best of A/B/C (p50) | budget p95 | D status |
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

Seed time (s) and size of the `permissions` tables (MB, cumulative):

| phase | A s / MB | B s / MB | C s / MB | D s / MB |
| --- | --- | --- | --- | --- |
| rbac | 5.14 / 7 | 4.31 / 7.4 | 4.95 / 5.3 | 4.86 / 5.4 |
| sharing | 0.65 / 18.7 | 1 / 19.6 | 1.93 / 21.3 | 1.84 / 16.1 |
| parents_proj | 0.08 / 19.6 | 0.11 / 20.6 | 0.34 / 22.3 | 0.1 / 16.8 |
| parents | 31.02 / 404.3 | 44.82 / 377.9 | 17.63 / 182.4 | 33.8 / 284.9 |
| nesting | 0.05 / 404.3 | 0.02 / 377.9 | 0.04 / 183.2 | 0.03 / 284.9 |


### Medium, deep shape (100k documents, team chains 9 deep)

| workload | A p50 / p95 | B p50 / p95 | C p50 / p95 | D p50 / p95 | D vs best of A/B/C (p50) | budget p95 | D status |
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

Seed time (s) and size of the `permissions` tables (MB, cumulative):

| phase | A s / MB | B s / MB | C s / MB | D s / MB |
| --- | --- | --- | --- | --- |
| rbac | 0.6 / 3.6 | 0.48 / 3.9 | 0.81 / 2.9 | 0.46 / 3 |
| sharing | 0.36 / 9.5 | 0.48 / 10.1 | 1.08 / 15 | 0.89 / 8.7 |
| parents_proj | 0.04 / 10 | 0.06 / 10.6 | 0.15 / 15.5 | 0.05 / 9 |
| parents | 2.14 / 48.6 | 3.97 / 46.5 | 1.57 / 31.5 | 3.18 / 35.9 |
| nesting | 0.02 / 48.6 | 0.02 / 46.5 | 0.06 / 33.1 | 0.02 / 35.9 |


### Medium, wide shape (100k documents, 50 teams per user, 50 documents per team)

| workload | A p50 / p95 | B p50 / p95 | C p50 / p95 | D p50 / p95 | D vs best of A/B/C (p50) | budget p95 | D status |
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

Seed time (s) and size of the `permissions` tables (MB, cumulative):

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

The large `parents_proj_select_count` miss is shared by all four engines (the heap-fetch floor described in VERSIONS.md). The wide p95 values are noisy: a 5 s `--only share_list_objects` rerun on the same server gave p50 16.55 / p95 22.28 ms (p50 reproduces, p95 doesn't). Other Docker containers (an unrelated local Supabase stack) were running during these runs; whether they were during A/B/C's runs isn't recorded.

### Storage and seeds

At large, `fga_tuples` is 279 MB for 1.04M tuples (the parent links are 1M of them); the RBAC tables add 5 MB. Below A (404 MB) and B (378 MB) because D stores one row per tuple with no surrogate key and one secondary index, `(user_type, user_id, user_relation, object_type, relation)`, which B-tree deduplication shrinks to 12 MB (1,000 parent tuples share each key). C (182 MB) is smaller still. The 1M parent tuples load in 33.8 s through `fga_write` (about 30,000 validated tuples per second); wide sharing (300k tuples) takes 13.3 s, between A (5.9 s) and C (24.7 s).

## Diagnosis

Everything below was measured in the Docker PG 18 server right after the runs, on the benchmark's own database (left in place with `--keep-running`), single session, warm cache. Per-call times are from PL/pgSQL loops (`clock_timestamp()`) over 30 users or 500-2,000 calls; call counts from `track_functions = 'all'`; plans from `auto_explain` with nested statements. The experiments marked "variant" are throwaway `pg_temp` functions or indexes in that database, not changes to the prototype.

### 1. ListObjects per reached node is 4x A's (wide sharing, deep shape)

Same server, same data, user 1-30 of medium wide (6,574 documents, 134 teams reached): A's `_reach` takes **3.9 ms** per call; D's `_fga_forward` **17 ms**. A 5 s A rerun on the same server reproduced A's bench number (p50 4.41 ms), so this is the engine, not the machine.

Where it goes (user 7, 5 forward steps of 0.6-4.8 ms each, 12.8 of 15.8 ms inside `_fga_fstep`): every step unnests the frontier into a materialized CTE, hash-joins it to `fga_edges`, probes `fga_tuples`, applies the computed closure, anti-joins the result against the whole visited set (unnested from three growing `text[]`, 5,140 entries at step 4), sorts and groups for `min(level)`, then `array_agg`s four arrays that the next step unnests again. Plans are generic with 1-10 row estimates, so the grouping is sort-based. Leaves are carried too: the 2,500 documents a step reaches are hashed into the next step's frontier and the visited set although `document#viewer` has no outgoing edge (the edge join drops them, after the cost). In the deep shape the same walk takes 10 steps of about 45 µs fixed cost each, hence `share_list_objects` 0.78 ms against 0.28-0.32 ms.

The four-way `union all` with empty contextual-tuple branches (risk flagged in the design doc) is **not** a measurable cost in steady state: the branches over `unnest('{}')` execute in microseconds and the plan is cached; a variant without them was within run-to-run noise (26-45 ms against 26-35 ms for a 20k-row step). They only add planning time to the first call per session (1.4 ms against 0.4 ms for the first step).

**Fix: one recursive CTE, A's `_reach` shape, over a pre-joined edge list** (each `d`/`t` edge already expanded with its computed closure, so the recursive term is one join to `fga_tuples`; only `(type, relation)` pairs with an outgoing edge recurse). Variant measured: **17 ms → 8.5 ms** on the wide walk, same ids. It has no levels, so the depth-25 rule needs adding back (a level column with `min` per node in the final select, or a cap on the recursion); the variant is a lower bound for that. Expected: wide `share_list_objects` about 2x faster, deep 0.78 → about 0.35 ms (no per-step function call), every list-based page correspondingly.

### 2. ListObjects walks the whole graph whatever the target type (the two-arm policy pays twice)

`fga_list_object_ids_current('folder', 'viewer')` for a wide user who views no folder takes **13.7 ms and returns nothing**: the forward walk expands every team and document the user reaches, though no team or document leads to `folder#viewer`. The two-arm projection policy calls ListObjects twice (documents and folders), which is why D's `parents_proj_select_page` (38.6 ms) is about 1.5x its own `share_select_page` (26.2 ms) on wide, and 1.3-1.5x on the other shapes.

**Fix: prune the frontier to nodes that can reach the target relation** (reverse reachability over `fga_edges` and the closure, a few rows, per model and target; it could be compiled at model write like `fga_paths`), and to nodes with an outgoing edge. Variant measured: folder list **13.7 → 0.25 ms**; document list 17.0 → 13.9 ms (the documents are no longer carried as frontier). Expected: wide `parents_proj_select_page` about 38.6 → 25 ms, and in combination with fix 1 roughly A's numbers. On the FGA-only large data below, it removes the last step (8 ms of 52 ms: 20,005 leaf documents expanded to find nothing).

### 3. ListObjects on a non-monotone relation checks every candidate top-down

The benchmark model is monotone, so the bench never reaches `_fga_rec`. Measured separately on the wide data with `viewer: (...) but not blocked` (`blocked: [user]`, one blocked tuple): **2,079 ms** per `fga_list_object_ids_current` for user 7 (6,702 ids), against 17 ms for the monotone relation, 120x. Call counts for one call: 20,106 `_fga_rec`, 33,512 `_fga_rec_node`, 6,702 `_fga_bidi`, 5,900 `_fga_bstep`, 4,205 `_fga_fstep`: one full bidirectional Check per candidate, about 310 µs each, with no memoization of the shared team subproblems. A Check on that relation is 270 µs (one candidate).

**Fix: set-based difference when the subtract side is monotone** (the common case: a block list, a ban): ListObjects of the base (one forward walk) minus the objects the user reaches through the subtract relation (a second forward walk), and for intersection the same with an intersect. Keep `_fga_rec` for subtracts that are themselves non-monotone or can cycle (the cycle rule of design doc §5 only matters there). Expected: two walks, about 2 x 17 ms = 35 ms at wide (60x), or about 17 ms with fix 1. Memoizing `_fga_rec` results per request would help Check on `and`/`but not` too, but is secondary.

### 4. FGA-only parents: org roles mirrored into the graph

To compare the engines on A's single-branch walk, after the large run the database got a second model (org type, `folder#parent: [org]`, `folder#viewer: [user] or viewer from parent`) and one `org:o#viewer@user:u` tuple per RBAC assignment (20,000) plus `folder#parent@org` for the 1,000 folders. ListObjects then returns the same set as A's single call (20,214 ids on average over users 1-30): **52 ms per call** against A's whole `parents_select_page` at 45.6 ms p50 (B 13.7, C 4.9). Steps: 0.8, 0.5, 33-35 (folder → 20,000 documents through the parent tuples) and 8-11 ms (expanding 20,005 leaves for nothing). In the big step most of the time is the index scan on `fga_tuples_user_idx` plus a heap fetch per parent tuple: the index has no `object_id`.

**Fix: a covering user index**, `(user_type, user_id, user_relation, object_type, relation) include (object_id)`, so the forward probes are index-only. Variant measured: **52 → 35 ms** here, 17 → 15 ms on the wide walk. Cost: the index grows from 12 MB (deduplicated) to 133 MB at large, total storage 285 → about 405 MB, A's size. Worth it if apps put large fan-outs (parents, org-wide grants) in FGA; with D's composition they mostly don't.

### 5. Check: fixed overhead per call

`nest_check` is 0.41-0.45 ms against 0.30-0.37 for A/B/C. One `fga_check_current` costs about 200 µs in the server (loop of 2,000): `_fga_current` (subject, latest model by `seq desc limit 1`, user type exists) about 6 µs, `_fga_parse_object` (object format, type and relation exist) 7 µs, `_fga_path_exists` 9 µs, `_fga_bidi` 177 µs. The bidirectional search itself does 2 `_fga_bstep` calls here, plus 4-6 other statements (start frontiers, the user-probe, the meeting test), each a few tens of µs. So the model re-resolution and re-validation per call (flagged in the design doc) is about 10% of a Check, and the rest is statement count.

**Fix:** resolve the model and validate `(type, relation)` once per transaction (a `set_config('permissions.fga_model', ..., true)` cache keyed by the latest `seq`, or a single lookup returning the model id, monotone flag and path existence in one statement): about 20 µs per call, 10%. Folding the start frontiers and the meeting test into the step queries would cut the statement count roughly in half: expected 0.41 → about 0.32 ms, A's range. This matters for per-row RLS (`fga_check_current` in an update policy runs once per candidate row), not for list policies.

### Writes

`write_share` and `write_nest_team` are 0.23 ms against A's 0.15: `fga_write_tuple` builds a JSON key, `fga_write` re-parses it, resolves the model, validates user, object and type restriction (six small lookups), checks duplicates and inserts. A dedicated typed path (`fga_write_tuple` validating its three strings directly, no JSON round trip) would save most of the 0.08 ms. No write maintains derived rows, so nesting a 1,000-member team costs the same as any tuple (C: 58-75 ms).

## Risks flagged in the design doc, verdict

| Risk (design doc §10) | Measured | Verdict |
| --- | --- | --- |
| Check: a PL/pgSQL call per search step, 4-way union with empty contextual branches | empty branches: noise in steady state, +1 ms planning on the first call per session; per-step calls: about half of Check's 200 µs | Statement count matters; the empty branches don't |
| ListObjects: PL/pgSQL loop over growing arrays instead of a recursive CTE | 4x A per reached node on wide; a CTE variant halves it | Real, the main wide cost (fix 1) |
| Every call re-resolves the latest model and re-validates type and relation | about 20 µs of a 200 µs Check, 0.2 ms of a 17 ms list | Minor (fix 5) |
| `and` / `but not` evaluated top-down without memoization | ListObjects 2.1 s vs 17 ms on wide; Check 270 µs | Real and severe for lists; not in the bench model (fix 3) |
| (not flagged) walks ignore the target type | 13.7 ms for an empty folder list; the two-arm policy pays it on every query | Real (fix 2) |

## Proposed fixes, by expected gain

(1-3 done in opt2, with the measured gains in that section; 5 partly; 4 and 6 not done.)

1. Set-based `but not` / `and` when the subtract or other operand is monotone: non-monotone ListObjects 2.1 s → about 35 ms (wide). Not visible in the current bench (monotone model); a bench workload with a block list would show it.
2. Recursive-CTE ListObjects over a pre-joined edge list (with the depth rule restored): wide lists 17 → about 8.5 ms, deep 0.78 → about 0.35 ms; all FGA list policies.
3. Target-relevance pruning of the walk frontier: empty-arm lists 13.7 → 0.25 ms; wide two-arm parents page 38.6 → about 25 ms (more with 2).
4. Covering `fga_tuples` user index: large fan-out lists -33% (52 → 35 ms), wide -10%; +120 MB at large.
5. Check overhead (model/validation cache, fewer statements in `_fga_bidi`): `nest_check` 0.41 → about 0.32 ms.
6. Typed `fga_write_tuple` without the JSON round trip: writes 0.23 → about 0.15 ms.

## Files

- Reports: `pg18-docker-d-large-default-opt.md`, `pg18-docker-d-medium-deep-opt.md`, `pg18-docker-d-medium-wide-opt.md` (plans, per-table storage, per-user checksums); JSON in `data/`. The second pass: the same names with `-opt2`. The third pass: `-opt3` (JSON in `data/`), `-opt3-before` and `-opt3-covering` (reports only).
- Phase 5 side scripts: [`../designs/d/conditions_cost.sql`](../designs/d/conditions_cost.sql) (conditions in the server) and [`../designs/d/cyclic_walk.sql`](../designs/d/cyclic_walk.sql) (userset cycles).
- The `but not` measurement: [`../designs/d/but_not_list_objects.sql`](../designs/d/but_not_list_objects.sql).
- Seeds and workloads: [`../designs/d/`](../designs/d/). `bench/run.sh` accepts `--design d` (the default for the extension file, `pg_permissions--0.0.1.sql`).
