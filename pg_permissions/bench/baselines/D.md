# Design D benchmarked

Design D ([`../../designs/d-per-model.md`](../../designs/d-per-model.md), [`../../prototypes/d-per-model.sql`](../../prototypes/d-per-model.sql)) measured on 2026-10-29 with exactly the workloads, scales and shapes of A, B and C, and compared with their session 3 optimized runs in [`OPTIMIZATIONS.md`](./OPTIMIZATIONS.md). Same setup: Docker, Postgres 18.6 with pg_tle 1.5.3, `cpus: 4`, `mem_limit: 6g`, 4 pgbench clients, 10 s per workload, one run per configuration, strictly serial (`docker/run-matrix.sh bench --versions 18 --designs d -- --scale <s> --shape <sh> --tag opt --check`). The D files use the same `opt` tag so they sit next to A, B and C's in the docs site's primary series: `pg18-docker-d-{large-default,medium-deep,medium-wide}-opt.{md,json}`. D itself is unoptimized: this is a measurement, nothing in the prototype was changed. The second pass, which acts on the diagnosis below, is in section "opt2".

## Summary

- **Correct everywhere.** Every read policy's checksum equals A's, B's and C's in all three Docker configurations, and in small default, deep and wide on local Postgres 16.4 (run before timing anything).
- **RBAC: as fast as the fastest engine.** `rbac_*` tables give the best or tied-best `rbac_check` (0.21-0.22 ms) and `rbac_update_one` (0.27-0.28 ms, 20-30% under C) everywhere.
- **Default and deep shapes: 1.1-2.8x slower than the best of A/B/C on FGA reads, but within budget**, except `share_list_objects` at medium deep (p95 1.02 ms against 1 ms) and the large `parents_proj_select_count` miss that all four engines share. Writes are 1.5x A's (0.23 against 0.15 ms) and far below C's nesting write (0.23 against 58-75 ms).
- **Wide shape: D is the slowest engine.** `share_list_objects` 17.8 ms against 3.4-8.4 ms, the sharing page 26 ms against 8-18 ms, the two-arm parents page 38.6 ms against 8.7-15 ms. Four budget misses.
- **The single-branch parents rows are not comparable** (D 1.4 ms against A's 45.6 ms at large): D keeps org roles in `rbac_*` and composes, so its FGA walk never visits the org-role documents that A, B and C walk to. With org roles mirrored into FGA (A's scenario literally), D's ListObjects for the same users takes 52 ms per call against A's 45.6 ms page (section "FGA-only parents").
- **Worst hotspot: ListObjects on a relation with `but not`.** Not in the benchmark model; measured separately on the wide data: 2.1 s per call (6,700 candidates, each a full top-down Check), against 17 ms for the monotone relation.
- **Storage:** 285 MB at large after the parents seed, between C (182 MB) and B/A (378/404 MB). Seeds through the native Write API are in A's range (large parents: 33.8 s; A 31.0, B 44.8, C 17.6).
- **opt2 (second pass, section below):** the fixes proposed under "Diagnosis" (pruned CTE walk, set-based `but not`), measured the same way. Wide FGA reads 2.2-4x faster, now 1.2-1.5x the best of A/B/C and faster than A on every wide page; deep ListObjects 0.78 → 0.33 ms; no budget miss except the large one all engines share; `but not` ListObjects 2.1 s → 4.2 ms. Check and writes unchanged.

## opt2: the second pass (2026-10-29)

The fixes this report's diagnosis proposed, applied to the prototype and measured exactly as before (Docker, Postgres 18.6, `cpus: 4`, 4 clients, 10 s per workload, strictly serial: `docker/run-matrix.sh bench --versions 18 --designs d -- --scale <s> --shape <sh> --tag opt2 --check`). The files are tagged `opt2` (`pg18-docker-d-{large-default,medium-deep,medium-wide}-opt2.{md,json}`), so the `opt` files above, and the docs site's primary series, are unchanged. The design is in [`../../designs/d-per-model.md`](../../designs/d-per-model.md) §5.

**What changed** (`prototypes/d-per-model.sql`):

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

- Reports: `pg18-docker-d-large-default-opt.md`, `pg18-docker-d-medium-deep-opt.md`, `pg18-docker-d-medium-wide-opt.md` (plans, per-table storage, per-user checksums); JSON in `data/`. The second pass: the same names with `-opt2`.
- The `but not` measurement: [`../designs/d/but_not_list_objects.sql`](../designs/d/but_not_list_objects.sql).
- Seeds and workloads: [`../designs/d/`](../designs/d/). `bench/run.sh` accepts `--design d` (inferred from `d-per-model.sql`).
