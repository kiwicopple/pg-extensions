# pg_permissions: Decision guide

Picks nothing. It lays out what was built and measured so you can pick. Every claim cites its source; numbers come from [`bench/baselines/COMPARISON.md`](./bench/baselines/COMPARISON.md) (**CMP**), test results from [`GOALS.md`](./GOALS.md), and weaknesses from the design docs [A](./designs/a-tuple-core.md), [B](./designs/b-policy-first.md) and [C](./designs/c-compiled-model.md). Section names are given where a file is long. "Large" is 1M documents, 10k users, 500 teams (CMP, Large default); "medium" is 100k documents.

## Where things stand

Three engines are built as prototypes in [`prototypes/`](./prototypes/): A (tuple core, Zanzibar-style tuples, read-time recursive walk), B (policy-first, Cedar-style policies, closures precomputed on write) and C (compiled model, JSON model, materialized memberships). The extension file itself is still empty. All three pass the shared goals G1-G14 and their own design-specific specs (A 14/14 files and 156 assertions, B 15/15 and 172, C 17/17 and 204; GOALS.md). They return identical visible-document sets for every read policy, at every scale and shape measured (CMP, Checksum agreement). The `rbac` preset is the same API and gives the same answers on all three, and its latency is within about 0.1-0.2 ms across engines (CMP, "RBAC is a wash"). So the choice only matters for apps that graduate to per-object sharing. There the engines differ on three axes: read cost for wide or deep groups, the cost of nesting a team (A writes one row, B and C write rows under a global lock), and how much extra the policy shape and the engine's data model cost. pg_tle was never run, and nothing was measured outside Postgres 16 on one laptop.

## Scorecard

Latencies are p50 ms from CMP unless noted. One run per configuration, so gaps under about 20% are noise (CMP, What the numbers say). Lines of code are `wc -l` of `prototypes/*.sql`; function counts are `create function` statements, public (no leading underscore) plus internal.

| Criterion (PLAN §7) | A: tuple core | B: policy first | C: compiled model |
| --- | --- | --- | --- |
| Model flexibility | RBAC, ReBAC, parents (`from_parent`), `user:*`, expiry. Forbid only against the subject's own tuple, not a group; each relation must opt in via `unless` or it silently ignores forbids (A §12.3). Conditions are RLS composition, so `check_for` says true for a draft the RLS hides (A §12.4). | Widest. Forbid with group principals, conditions evaluated in the engine and compiled into RLS (B, Schema `principal_in_type/id`; Deviations 4, 6). Refuses shapes it can't split, such as `resource.owner_id == principal.id` (B, Weaknesses). | RBAC, ReBAC, typed model, parents, `user:*`. Forbid is deny-overrides along the chain and same-type only (C §9). Conditions are RLS composition. No expiring group memberships (C §9, §12.9). |
| Read cost, default shape | `rbac_check` 0.28, `share_select_page` 2.02, `share_list_objects` 0.52 (large) | 0.33, 1.21, 0.31 | 0.23, 0.95, 0.23 |
| Read cost, deep (medium, 9 levels) | `share_select_page` 2.47 (1.53 in the default shape) | 2.04 (0.89) | 0.77 (0.69) |
| Read cost, wide (medium, 50 teams per user) | `share_select_page` 221.40, `share_list_objects` 63.77 | 70.19, 25.65 | 10.72, 3.76 |
| Parents, two-arm projection policy (large) | `parents_proj_select_page` 3.20; count 5.00 | 1.44; 3.21 | 1.01; 2.72 |
| Parents, single-branch policy (large) | `parents_select_page` 509.43; count 536.39 (about 160x the projection) | 197.22; 226.11 (about 140x) | 9.57; 22.08 (about 9x) |
| Write cost: `write_nest_team` (4 clients, rolled back) | 0.15 at every scale and shape | small 134.09, large 285.44, wide 320.82 | small 62.07, large 333.48, wide 144.63 |
| Write cost: single-row (large) | `write_assign_role` 0.17, `write_share` 0.15 | 0.14, 0.14 | 0.20, 0.16 |
| Check through a nested team: `nest_check` | 0.70 large, 2.23 wide | 2.60, 2.80 | 0.26, 0.28 |
| Storage and seed, per-document parent links (large) | +378 MB, 44 s | +736 MB, 167 s | +160 MB, 16 s |
| Storage and seed, wide sharing (medium) | 97.1 MB, 10.39 s | 225.9 MB, 35.45 s | 191.6 MB, 182.95 s |
| Concurrency | No locks. | One advisory lock for closure writes, a second for role definitions. `repeatable read` raises `0A000` for those writes; serializable allowed (B, Closure maintenance). | One global advisory lock for userset grants, container moves, model changes and `rebuild()`. `repeatable read` raises `0A000`. Object grants take no lock (C §5). |
| Drift risk | None: nothing derived (A §9). | Closure tables can drift. No `verify`/`rebuild` in the design or the prototype. | `memberships` and `ancestors` can drift. `verify()` and `rebuild()` exist; four broken copies were each caught by specs (C §12.1). |
| Known open correctness gaps | Reserved name `check`; `parent` is a reserved relation and a typo gives no access, not an error; a non-uuid stored id aborts the whole `::uuid` query; no FKs, orphan tuples accumulate (A §7, §9, §11, §12.1). | `ids_for` as a list isn't net of conditioned or folder-based forbids (RLS is exact). `can()` raises `22023` if a forbid's inputs are missing from `resource`. RLS must be regenerated when policies change, and `lint()` is text-based. `can()` trusts its `resource` argument (B, Weaknesses). | Global lock; `repeatable read` refused; uuid-only IDs, assumed unique across principal types; `who_can` null row for public isn't net of forbids; model changes touching usersets rebuild all memberships (C §12). |
| Lines of code | 618 | 1,557 | 1,871 (about 590 compiler, 350 derived-data maintenance, 250 preset; C §12.1) |
| Function count | 27 (24 public, 3 internal) | 56 (38, 18) | 63 (32, 31) |
| Blessed path (`rbac` preset) | G3-G5 17/17, 13/13, 15/15; graduation 5/5; RLS 12/12 (GOALS). Thin wrappers of about 50 lines; roles defined twice, `app` and `tenant` (A §6). | Same results. Generated `managed_by` policies; graduating introduces policies, a second concept (B, Blessed path). | Same results. Each `create_role` is a new model version; text signatures, uuid underneath; non-uuid scope gives false on reads and `22P02` on writes (C §8). |
| Correctness and safety | G2 14/14 on all. Cycles terminate via `union` (A §12.1). | Cycles and depth over 10 rejected on write (B, Closure maintenance). | Cycles rejected on write (`23514`), depth over 10 raises `54001` (C §5, §9). Strongest validation: typed subjects, unknown names raise on write (PLAN §8 table). |
| Identity decoupling | G1 11/11 | 11/11 | 11/11 |
| TLE fit | G14 9/9 for non-superuser install; the pg_tle path was not run (GOALS) | same | same |
| Evolvability | Policy layer for conditions, CEL and Cedar is "the least designed part" (A §9). | Natural home: forbid, conditions, later CEL and Cedar are policy shapes (PLAN §8 table). | CEL would compile to SQL text at model time; Cedar `when`/`unless` over arbitrary attributes doesn't compile to lookups (C §9). |
| Budgets, `--check` at small | Fails 4: both `parents_proj_*`, both single-branch `parents_*` | Fails 4: single-branch `parents_*`, `write_nest_team`, `nest_check` | Fails 1: `write_nest_team` |

All three pass every session-1 budget (CMP, Budgets). B and C miss `write_nest_team` everywhere because that budget derives from A's one-tuple write, and A and B miss the single-branch budgets because they derive from C (CMP, Budgets).

## Choose A if

- Your sharing graphs are shallow and narrow, or you mostly use RBAC. At large with the default shape A's sharing page is 2.02 ms and it meets the session-1 budgets (CMP, Large default; Sharing reads).
- Team and membership edits are frequent or bulk (directory syncs, big teams being nested). A's nest is one tuple at 0.15 ms regardless of size, while B and C queue at 12-70 tps (CMP, Nesting).
- You want the smallest extension to maintain: 618 lines, 27 functions, no derived data, no drift, no locks, no isolation-level restrictions.
- You want OpenFGA/SpiceDB familiarity (A §1).
- You accept writing the two-arm projection policy (an `org_id` or `folder_id` arm plus a shared-ids arm) for org or folder access.
- It loses on: wide memberships (221 ms at 50 teams per user), single-branch parent policies (509 ms at large, and the session-1 extrapolation of 150 ms was low), and deep chains (1.6x slower than the default shape). Parent links per document cost +378 MB at large (CMP, What the numbers say; Storage).

## Choose B if

- You need forbid on groups, or conditions evaluated by the engine, in the first year. B is the only engine that has them (B, Deviations 4, 6; PLAN §8 "The real decision").
- Your roadmap is Cedar-like policies (CEL, attribute rules), and a policy table is the natural place.
- Keys are text or bigint rather than uuid (B, Schema: text ids).
- You want generated RLS (`rls_expression`, `apply_rls`), and can live with regenerating it when policies change.
- It is in the middle on sharing reads (wide 70.19 ms) and the worst on three things: nesting cost (285 ms large, 4 clients), storage (+736 MB for per-document parents at large) and `nest_check` (2.60 ms vs 0.26 for C). It is the second largest of the three (1,557 lines, after C's 1,871). Its `can()` and `ids()` are two implementations of one semantics; they agreed on 2,400 random cases, an ad hoc check not committed as a spec (B, Partial evaluation).

## Choose C if

- Reads dominate and group shapes are wide or deep. C's reads barely move between shapes (`share_select_page` 0.69 default, 0.77 deep) and on wide it is about 20x faster than A and 6.5x faster than B (10.72 vs 221.40 and 70.19).
- You want the single-branch RLS policy (no hand-written `org_id` arm) at a large scale. It is 9.57 ms for C against 197 ms for B and 509 ms for A at large. Even so, the projection stays 9x cheaper for C too (CMP, What the numbers say).
- Nesting teams is rare, or an admin-time action, and a global write lock is acceptable. Nesting costs 333 ms at large with 4 clients, and C's wide sharing seed took 183 s (A 10 s).
- Your IDs are uuids, and you want typed validation and unknown names that raise on write.
- It loses on: the largest and most complex write path (1,871 lines; C §12.1), `repeatable read` refused for lock-taking writes, uuid-only IDs, and the global lock.

## Hybrids worth considering (untested ideas)

None of these has been built or measured.

1. **A's engine with C's materialized memberships behind the same functions.** PLAN §8 notes A and C share almost the same API. This targets the wide and deep reads (C's 10.72 vs A's 221.40 ms). It would also inherit C's global lock, drift risk and the write path that is the bulk of C's code (C §12.1), so it may end up as C without the typed model. Object grants would still take no lock (C §5).
2. **The projection policy as the blessed RLS pattern, whatever the engine.** Write the two-arm form: shared ids or a parent column (`org_id`, `folder_id`). At large it is 3.20 / 1.44 / 1.01 ms (A / B / C), against 509 / 197 / 9.57 ms for the single branch. B's `rls_expression` already generates this shape. The cost is that org or folder access lives in the policy, so `check` and `list_subjects` on the engine side need the parent links to stay complete (A §12.1).
3. **Ship only the `rbac` preset first, and pick the sharing engine later.** The preset's API and answers are identical on all three and its latency is flat (CMP, "RBAC is a wash"), so it could be released on the smallest engine and swapped. The risk is graduation: C's graduation is one `apply_model()` call, B's introduces policies, A's is an extra `or` branch (C §8, B Blessed path, PLAN §6). Whether data would need migrating between engines is not tested.

## Open questions for you

1. **Are forbid on groups and engine-evaluated conditions needed in year one?** Yes points at B. No leaves A and C, which have forbid on direct subjects (A) or deny-overrides (C), and handle conditions in RLS (G12 9/9 and G13 6/6 pass on all three).
2. **Is uuid-only acceptable?** C requires it and assumes uuids don't collide across principal types (C §12.11). A and B take text and cast to `uuid[]` in RLS (PLAN §4).
3. **Is a global write lock acceptable?** B and C queue concurrent nests: 12-70 tps (CMP, Nesting). Does your app edit teams concurrently, and how big are the teams?
4. **Is `repeatable read` refusal acceptable?** B and C raise `0A000` for lock-taking writes. ORMs that default to it would need a different isolation level for permission writes (C §12.3).
5. **Do you need single-branch RLS policies, or is the two-arm projection acceptable as the documented pattern?** It decides how much C's 9.57 ms matters.
6. **Are per-document parent links acceptable?** Mirroring a column is +160 to +736 MB at 1M documents (CMP, Storage).
7. **Do you want sharing in the first release at all, or `rbac` only?** (Hybrid 3.)
8. **Carried over from PLAN §9:** the schema name, and a convention for who may grant. Public access (PLAN §9 question 3) is now built and tested on all three (G11 7/7).

## What hasn't been measured

- **Single-client writes at large.** CMP's `write_nest_team` runs with 4 clients and includes queueing on the lock (CMP, Caveats). The only single-client figure is C's 14 ms at small (C §11); B's single-client nest is not measured.
- **pg_tle.** Never run; `03_tle_install` checks the non-superuser path only (GOALS, Not yet covered by tests).
- **Real hardware and durability.** One Apple Silicon laptop, `fsync=off`, `full_page_writes=off`; every write rolls back, so commit cost isn't measured (CMP, Caveats).
- **Concurrency mixes.** Each workload runs alone. No reads under concurrent membership writes, and no mixed read/write load.
- **PG versions other than 16.** Measured on 16.4. A's `_reach` is PL/pgSQL because Postgres 16 re-plans SQL function bodies on every call (prototypes/README).
- **Repeat runs, confidence intervals, bloat from churn,** and checksums beyond 8 sample users (CMP, Caveats).
- **A user who sees most of 1M documents,** and a 1M-element array from `accessible()` (C §11). Sample users see about 20k at large.
- **Large model changes.** C's full `memberships` rebuild at millions of rows (C §12.5); runtime `create_role` churn.
- **B's InitPlan count at scale** (5-7 function calls per table; B, Performance).
