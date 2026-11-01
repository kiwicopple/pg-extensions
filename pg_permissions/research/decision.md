# pg_permissions: Decision guide

> Status: this page is a historical record. The user chose D on 2026-10-29, and D is now the extension file `pg_permissions--0.0.1.sql`. All six phases of [`./plan.md`](./plan.md) are done (as of 2026-10-30). The extension has 56 spec files and 3,638 assertions on PG 16, 17 and 18. The user closed the last open question (question 11, the covering index) on 2026-11-01.
>
> The sections that compare A, B and C describe the state before D was chosen, and they are not changed. The usage docs that this page names are now the user docs in [`../docs/`](../docs/).

This guide picks no winner among the three designs A, B and C. (See "Session 4 direction" for the direction that the user took after it.) It lays out what the author built and measured. Every claim cites its source.

These are the sources:

- **OPT** is [`./benchmarks/OPTIMIZATIONS.md`](./benchmarks/OPTIMIZATIONS.md). It has the numbers of all three designs after the session 3 optimization pass (Postgres 18.6 in Docker). Most numbers in this guide come from OPT.
- **VER** is [`./benchmarks/VERSIONS.md`](./benchmarks/VERSIONS.md). It has the results across Postgres versions.
- **CMP** is [`./benchmarks/COMPARISON.md`](./benchmarks/COMPARISON.md). It has the numbers from before the optimization (local Postgres 16.4).
- **D.md** is [`./benchmarks/D.md`](./benchmarks/D.md). It has the benchmark of design D.
- The test results come from [`./goals.md`](./goals.md). The weaknesses come from the design docs [A](./designs/a-tuple-core.md), [B](./designs/b-policy-first.md) and [C](./designs/c-compiled-model.md). A reference such as "A, section 13.1" means a section of the design doc of A.

The text gives section names where a file is long.

"Large" is 1M documents, 10k users and 500 teams (OPT, Large default). "Medium" is 100k documents. "Deep" and "wide" are stress shapes at medium scale. In the deep shape, teams nest 9 levels. In the wide shape, each user is in 50 teams (VER, shape descriptions).

## Session 4 direction: per-model tables

On 2026-10-29 (session 4) the direction changed: the single generic API is dropped. The A/B/C comparison below stays as the evidence for the change. It no longer decides between three designs for one API.

1. **Per-model table sets.** The `permissions` schema holds a separate set of tables for each model. Each set follows an existing spec as closely as possible.
   - `rbac_*` tables are the blessed path. They are first-class tables, not wrappers over a core.
   - `fga_*` tables follow OpenFGA.
   - An app can use more than one model at the same time, for different things. The models compose in Postgres RLS: permissive policies combine with OR, and restrictive policies combine with AND.
   - This is also the graduation path. An app adds the FGA model next to RBAC. It does not migrate off RBAC.
2. **Why.**
   - (a) The findings of the usage docs come from the use of one API for different semantics. The `rbac` preset is not fully identical across designs, and forbid means something different in each design. A forbids only against the own tuple of the subject. C forbids for the same type only. B covers groups. (See "Findings from the usage docs" below, C section 9 and B, Deviations 4.)
   - (b) The `rbac` preset is flat across designs (under 1 ms, within about 0.1 ms; OPT, Ranking). The designs differ only on sharing shapes, and the optimizations there are specific to a model (the closures of B, the materialized memberships of C). Tables for each model let the author optimize each model for itself.
   - (c) A spec lets developers and tools reuse what they know already. It also lets the project follow updates of the spec, and a generic layer makes that hard.
3. **OpenFGA, not SpiceDB and not a generic "Zanzibar-style" model.** The two have different schema languages, so to follow a spec is to choose one. The user chose OpenFGA for two reasons. The public test suite of OpenFGA can serve as a test oracle, and OpenFGA has CEL conditions on tuples.
4. **First spike.** The spike has the `rbac_*` tables and a core subset of OpenFGA (direct relations, computed usersets, tuple-to-userset, wildcards `user:*`). It runs against the test cases of OpenFGA. It also has one table whose RLS combines RBAC and FGA. The benchmark compares it with the numbers in this guide.
   - OpenFGA conditions (CEL) are a second stage after the core.
   - In pg_tle, CEL means a parser and a compiler written in SQL or PL/pgSQL. This is the largest single cost.
5. **Cedar is for later (`cedar_*`), with B as the base.** Full Cedar `when` and `unless` over arbitrary attributes do not compile to index lookups (C, section 9). B already refuses shapes such as `resource.owner_id == principal.id` (B, Weaknesses). So Cedar will probably be a documented subset, tested against the Cedar corpus.
6. **No separate ABAC model.** ABAC is a category, not a spec. XACML is the only formal standard, and nobody builds new systems on it.
   - RLS covers row attributes (`status = 'published'`, tenant and owner columns).
   - OpenFGA conditions cover attributes on a relationship (expiry, IP range, amount).
   - Cedar will cover policy-language ABAC later.
   - One gap stays. The check functions cannot see row attributes that exist only in RLS (A, section 12.4: `check_for` returns true for a draft that RLS hides).
   - The usage docs must say one of two things. Either the check functions are advisory and RLS is final, or the app passes the row attributes into the check.
7. **Shared code is a small toolkit, not an API.** It has these parts:
   - the subject identity (G1)
   - the guard against plan-time evaluation (the dummy last argument with a VOLATILE default `_unfolded_null()`, see result 1 of "What the optimization pass taught" below)
   - `collate "C"` on text ids
   - the install and pg_tle code (G14)
8. **The prototypes.** A is closest to OpenFGA, and it is the base for `fga_*`. The materialized memberships of C stay a possible optimization if wide reads need them. B is the base for Cedar later.

   The generic compiled model of C is the part that this direction drops. The prototypes stay in the repo as measured history. The spike was valid, and D is now `pg_permissions--0.0.1.sql` (see "Decisions at the end of session 4", point 1).

The open questions below have notes on what this direction changes. The sections that compare the three designs as candidates for one API are not changed. They are "Where things stand" through "Hybrid ideas (untested)".

## Decisions at the end of session 4

The user made these decisions on 2026-10-29, after the OpenFGA report and the opt2 benchmarks. They settle the question of the design for the extension. The work plan is in [`./plan.md`](./plan.md), "Next work (session 5 onward)". That work is done: all six phases are done as of 2026-10-30.

1. **D is the design, and it becomes the extension.** In phase 1 of session 5, `prototypes/d-per-model.sql` became `pg_permissions--0.0.1.sql`. The prototype file was removed. The extension file is the source of truth. A, B and C stay in the repo as measured history. The comparison above is not changed.
2. **Names.** The schema is `permissions`. The table and function prefixes are `rbac_*` and `fga_*`. This resolves Q10.
3. **One implicit OpenFGA store for each database.** The latest model is the default. A function that receives an older model id still evaluates with that model.
4. **Result caps on the API functions follow OpenFGA.**
   - ListObjects and ListUsers return at most 1,000 results.
   - Write takes at most 100 tuples for each call.
   - Read has pages with `page_size` and `continuation_token`.
   - When a call reaches a cap, the behavior follows the documented behavior of OpenFGA.
   - The RLS helper functions (`fga_list_objects_current`, `fga_list_object_ids_current`, and any other variant for RLS) have **no cap**. A cap there would cut off access in silence: a user would lose rows with no error.
5. **Errors are descriptive.**
   - The numeric code of OpenFGA stays in `DETAIL` as `openfga:<code> <name>`.
   - The `MESSAGE` says what was wrong, with the actual wrong values (type, relation, user string, model id).
   - A `HINT` is always present, and it says how to fix the error. It gives the user types that are valid for that relation, the nearest relation name that exists, or the call to make first.
   - This applies to the `rbac_*` errors also, not only to the `fga_*` errors.
6. **Cycle semantics.** D uses the least fixpoint for positive recursion below an exclusion (done in `d/31_fga_cycles`). This differs from OpenFGA v1.22.1. The user reported this to the OpenFGA team ([`./upstream/openfga-cycle-but-not-inconsistency.md`](./upstream/openfga-cycle-but-not-inconsistency.md)). If upstream decides differently, D changes again.
7. **pg_tle is not a further goal.** The plan drops the pg_tle test on a managed host (the user told the author not to worry about pg_tle). The spec `03_tle_install` for the Docker pg_tle install still passes. There is no other pg_tle work.

Resolved at the end of session 4 (the open questions below have notes also): Q2, Q3, Q9 and Q10.

## Decisions for conditions (session 5)

The user and the orchestrator made these decisions on 2026-10-29 and 2026-10-30. They answer the open questions of [`designs/d-conditions.md`](./designs/d-conditions.md) (section 11), before steps 3 to 6 of phase 4. Phase 4 implemented them, and the design doc records how.

1. **Storage S1.** The design compiles the conditions of a model when it writes the model. It stores them as a jsonb AST in `fga_conditions`. There is no parse at Check time, and no DDL at run time (no generated functions).
2. **Evaluator.** A PL/pgSQL interpreter walks the tree of the expression over typed values, with the error semantics of CEL. `||` and `&&` absorb an error when the other side decides, in either order, as the probed server does. A walk step evaluates a condition one time for each distinct pair of condition and tuple context.
3. **Fast path.** A flag `conditional` on each relation keeps the statements of before when no conditioned edge can be involved. Edges and type restrictions carry a `condition` column.
4. **The RLS helpers** (`fga_check_current`, `fga_list_objects_current`, `fga_list_object_ids_current`) get no request context.
   - They deny a conditioned edge that they cannot evaluate. They never take such an edge, and they never fail.
   - An answer that depends on an evaluation error is a deny (an example is a `but not` whose subtract errors).
   - [`../docs/rls.md`](../docs/rls.md) documents this ("Conditions in policies"), with a spec.
5. **Error rule.** The rule is the top-down rule of OpenFGA. Check fails with 2000 when a condition that it evaluates errors and no path of true edges exists. This is also true for an edge that is not on the path of the user (as the probed server does). ListObjects and ListUsers fail with 2000 if any edge that their walk takes errors.
6. **Stale stored contexts.** A tuple whose condition or context no longer fits the model is ignored in every API. This is a documented deviation for ListObjects and ListUsers, where OpenFGA fails with 2000.
7. **Cost limit.** An approximate counter counts the nodes that the evaluator evaluates and the iterations of comprehensions. The limit is 100, like OpenFGA. Past the limit, the error is 2000.
   - The author calibrated the limit so that `l.exists(e, e == "zzz")` over 50 strings (and 20) exceeds it, and every abac case stays well below it.
   - The docs say that the threshold is approximate.
8. **Inline `$expression` conditions** are out of scope. The design refuses them with 2000, as the default server does. The 9 abac cases stay skipped as `inline-expression`.
9. **A rewrite of a key with a different condition under `on_duplicate: ignore`** is 2017 with a HINT. OpenFGA answers HTTP 409 `Aborted`, which has no code.
10. **`bytes`, `type()` and `dyn()`** are refused at model write (2056), with a HINT.
11. **The `0A000 conditions_not_supported` error is removed.** Every new raise site has a descriptive MESSAGE, a HINT and a row in `test/spec/d/35_error_hints.sql`.
12. **The 8 `test/fga_lang` cases that were skipped as `conditions`** run where the server and the expectation agree (4 now pass). They stay skipped with a more exact reason where they do not agree (2 `server-accepts`, 2 `inline-expression`).

## API naming (session 5)

The user made these decisions on 2026-10-30, after phase 5. They are in the commit "rbac_ prefix on RBAC functions, named-argument parameter names". The spec `test/spec/d/04_api_naming.sql` pins them. Point 1 is point 2 of session 4, which the RBAC functions had never followed.

1. **A prefix means a function for one model. No prefix means a function for both models.**
   - The RBAC functions take the prefix `rbac_` and keep their verbs: `rbac_create_role`, `rbac_drop_role`, `rbac_assign_role`, `rbac_unassign_role`, `rbac_has_role`, `rbac_has_permission`, `rbac_user_permissions`, `rbac_users_with_role` and `rbac_scopes_with_permission`.
   - The `fga_*` names do not change.
   - Only the functions that both models share have no prefix: `current_subject_id`, `current_subject_type` and `delete_subject`.
   - A `_` at the start of a name means an internal function.
   - Prototypes A, B and C keep the old names (frozen history). The shared specs in `test/spec/*.sql` stay in that API for them. The extension runs its own copies in `test/spec/d/`.
2. **Parameter names read well in named notation.**
   - There is no `p_` prefix. Both models use one vocabulary. The names are `role`, `permissions`, `inherits`, `permission`, `scope`, `user_id`, `subject`, `subject_type`, `subject_id`, `object`, `relation`, `type`, `model`, `model_id`, `writes`, `deletes`, `contextual_tuples`, `context`, `user_filters`, `page_size` and `continuation_token`.
   - No name is a reserved, type_func_name or col_name keyword. So no name needs quotes in `name => value`.
   - The positional order of every function does not change.
   - Named notation costs nothing at run time. The orchestrator checked this: the same expression in EXPLAIN, and the same time over 1M calls.
   - A parameter can have the same name as a column in a function body. Then the code qualifies the parameter with the function name, and the column with its alias. This follows the default `variable_conflict = error` of PL/pgSQL.
   - The ignored last argument of `rbac_scopes_with_permission` (Q9) is named `plan_time_guard`.
   - `continuation_token` of `fga_read` is `inout`, because the input and the output column share the name of OpenFGA.
3. **`user` is a reserved word, so the user of OpenFGA is `subject`.** `fga_check(user => ...)` does not parse without quotes. `subject` matches `current_subject_*`. The docs say that it is the `user` field of OpenFGA, and the JSON tuple keys keep `"user"`. The `authorization_model_id` of OpenFGA is `model_id`.
4. **Every usage example and RLS example passes arguments by name** (the usage docs in [`../docs/`](../docs/), their `test/spec/d/90_usage_*` specs and the examples in the design doc). The HINTs that show a call show it in the same way. Calls inside the extension and in the other specs can stay positional.

## Where things stand

Three designs are built as prototypes in [`../prototypes/`](../prototypes/). A is the tuple core: Zanzibar-style tuples and a recursive walk at read time. B is policy-first: Cedar-style policies, and closures that the write precomputes. C is the compiled model: a JSON model and materialized memberships. (This text was written before D became the extension file in phase 1 of session 5.)

All three pass the shared goals G1 to G14 and their own design-specific specs. The counts are A 18/18 files and 199 assertions, B 18/18 and 189, C 21/21 and 229 (see [`./goals.md`](./goals.md)). They return identical visible-document sets for every read policy, at every scale, shape and Postgres version that the benchmark measured. The optimizations changed no checksum (OPT, Checksums).

The `rbac` preset is the same API and gives the same answers on all three designs. Its p50 latency stays under 1 ms and within about 0.1 ms across designs (OPT, Ranking: `rbac_check` 0.30 / 0.27 / 0.24, `rbac_select_page` 0.76 / 0.73 / 0.67). So the choice matters only for apps that graduate to sharing for each object.

The optimization pass moved the trade-offs. The list below compares the designs with the guide from before the pass (same Docker setup, PG 18; OPT, Before to after):

- **The nest write of B** went from 107 to 0.62 ms (4 clients, large). B is now in the range of A on writes, not in the range of C. The nest write of C went from 300 to 57.7 ms. C is still the slowest by two orders of magnitude, but it is 5 times better.
- **The storage of B** halved (763 to 378 MB at large). It is now below A (404 MB). C is the lowest at large (182 MB).
- **`nest_check`** is a tie between the three designs (0.31 / 0.32 / 0.30 ms at large).
- **The wide reads of A** are no longer an outlier. Wide `share_select_page` went from 125 to 14.4 ms. That is 1.8 times the 8.20 ms of C, where it was 12 times. A beats B there (B 17.8 ms) on 17 and 18, but not on 16 (OPT, Ranking).
- **The gaps on the single-branch parents policy** are smaller. The page is 45.6 / 13.7 / 4.94 ms for A / B / C (it was 240 / 102 / 9.26).
- **Budgets.** At large, A misses 3, B misses 1 and C misses 2 (it was 3, 3 and 1; OPT, Budgets).

What still separates the designs:

- the cost to nest a team (A writes one row, B writes closure rows, C writes membership rows under a global lock)
- the single-branch policy and wide reads (C leads)
- storage, which depends on the shape (C is the largest at medium wide)
- the cost of the policy shape and of the data model

pg_tle now installs on PG 16, 17 and 18 for all three designs (G14). The author measured everything on one laptop, in Docker, with one run for each configuration.

## Scorecard

The latencies are p50 ms from OPT (PG 18.6 Docker, 4 clients, after the optimization), unless a note says otherwise. There is one run for each configuration. The p50 agrees within about 5% between repeats for workloads under 1 ms, and within about 20% for the heavy workloads. So smaller gaps are noise (OPT, Repeatability and replaced runs).

Nobody ran medium default and small scale again after the optimizations (OPT, Caveats). The lines of code come from `wc -l` of `prototypes/*.sql`. The function counts are case-insensitive `create function` statements: public (no `_` at the start of the name) plus internal.

| Criterion (plan, section 7) | A: tuple core | B: policy first | C: compiled model |
| --- | --- | --- | --- |
| Model flexibility | RBAC, ReBAC, parents (`from_parent`), `user:*`, expiry. A forbid works only against the own tuple of the subject, not against a group. Each relation must opt in with `unless`, or it ignores forbids in silence (A, section 12.3). Conditions are RLS composition, so `check_for` says true for a draft that RLS hides (A, section 12.4). | The widest. Forbid with group principals. The design evaluates conditions and compiles them into RLS (B, Schema `principal_in_type/id`; Deviations 4 and 6). It refuses shapes that it cannot split, such as `resource.owner_id == principal.id` (B, Weaknesses). | RBAC, ReBAC, typed model, parents, `user:*`. Forbid is deny-overrides along the chain, and for the same type only (C, section 9). Conditions are RLS composition. Group memberships cannot expire (C, sections 9 and 12.9). |
| Read cost, default shape (large): `rbac_check`, `share_select_page`, `share_list_objects` | 0.30, 1.03, 0.29 | 0.27, 1.00, 0.29 | 0.24, 0.93, 0.25 |
| Read cost, deep (medium deep, 9 levels): `share_select_page`, `share_list_objects` | 0.76, 0.31 (was 1.42, 0.42) | 0.72, 0.32 (was 1.68, 0.48) | 0.66, 0.28 (was 0.77, 0.28) |
| Read cost, wide (medium wide, 50 teams for each user): `share_select_page`, `share_list_objects` | 14.4, 4.44 (was 125, 29.1) | 17.8, 8.41 (was 36.9, 11.4) | 8.20, 3.41 (was 10.2, 4.25) |
| Parents, two-arm projection policy (large): page; count | 1.33; 8.42 | 1.15; 8.20 | 1.05; 7.88 |
| Parents, single-branch policy (large): page; count | 45.6; 75.1 (page about 34 times the projection) | 13.7; 21.6 (about 12 times) | 4.94; 11.9 (about 4.7 times) |
| Parents, single-branch policy (medium wide): page; count | 14.7; 13.3 | 13.7; 12.2 | 8.06; 6.61 |
| Write cost: `write_nest_team` (4 clients, rolled back; large / deep / wide) | 0.15 / 0.15 / 0.15 (23.6k tps at large) | 0.62 / 0.63 / 1.47 (6.1k tps at large) | 57.7 / 75.1 / 61.2 (67 tps at large) |
| Write cost: one row (large) | `write_assign_role` 0.15, `write_share` 0.15 | 0.14, 0.14 | 0.17, 0.17 |
| Check through a nested team: `nest_check` (large / deep / wide) | 0.31 / 0.34 / 0.37 | 0.32 / 0.34 / 0.34 | 0.30 / 0.30 / 0.31 (a tie between the three) |
| Storage and seed, per-document parent links (large; cumulative size after the parents phase; parents seed time) | 404 MB, 31.0 s (+385 MB for the phase) | 378 MB, 44.8 s (+357 MB) | 182 MB, 17.6 s (+160 MB) |
| Storage and seed, wide sharing (medium wide; size after sharing, sharing seed) | 97.4 MB, 5.88 s | 105.3 MB, 12.56 s | 191.6 MB, 24.71 s |
| Concurrency | No locks. | One advisory lock for closure writes, and a second for role definitions. `repeatable read` raises `0A000` for those writes, and serializable works (B, Closure maintenance). A nest of users holds the lock about 0.2 ms. A nest of a sub-tree with many inner nodes still writes `inner descendants x ancestors` rows under the lock (B, Remaining hard limits; not benchmarked). | One global advisory lock for userset grants, container moves, model changes and `rebuild()`. A nest holds it about 10 ms (C, section 15.7). `repeatable read` raises `0A000`. Object grants take no lock (C, section 5). |
| Drift risk | None: nothing is derived (A, section 9). | Closure tables can drift. The design and the prototype have no `verify` or `rebuild`. Two differential fuzzers compared the optimized closure with the original (168k closure operations, 119k read comparisons, 0 differences). They are not committed as specs (B, Optimizations: correctness checks). | `memberships` and `ancestors` can drift. `verify()` and `rebuild()` exist. `verify()` shares no code with the incremental path. The specs caught each of four copies of the delta that the author broke on purpose (C, section 15.5, `c/33`). |
| Known open correctness gaps | Reserved name `check`. `parent` is a reserved relation, and a typo gives no access and no error. A stored id that is not a uuid aborts the whole `::uuid` query. There are no FKs, so orphan tuples accumulate (A, sections 7, 9, 11 and 12.1). The id arrays from `list_objects_for` have no order. A caller who passes the dummy third argument as a constant enables plan-time evaluation again (A, section 13.1). Plans are pinned generic, so the walk never picks a hash join for a huge frontier (A, section 13.3). | `ids_for` as a list does not subtract conditioned forbids or forbids that are based on folders (RLS is exact). `can()` raises `22023` if the inputs of a forbid are not in `resource`. The app must generate RLS again when policies change, and `lint()` is text-based. `can()` trusts its `resource` argument (B, Weaknesses). **A latent depth-cap bug on delete:** the removal of a shortcut edge can leave a shortest remaining path that is longer than 10. The delete drops that pair in silence, so the closure gives a partial answer. The design keeps it for compatibility. A fix is a decision about semantics (B, Remaining hard limits). Policies that the app created before the session 3 install still fold `ids()` at plan time. RLS from the older `apply_rls` does the same. This stays until the app generates them again (B, Optimizations, steps 6 and 7). | The global lock. `repeatable read` is refused. The ids are uuid-only, and the design assumes they are unique across principal types. The `who_can` null row for public does not subtract forbids. Model changes that touch usersets rebuild all memberships. Deletes recompute the affected principals, not a delta (C, sections 12 and 15.7). Policy forms other than `(select accessible(...))::uuid[]` still run `accessible()` at plan time (C, section 15.8). |
| Lines of code | 871 | 1,810 | 2,012 (the version with 1,871 lines has about 590 lines of compiler, 350 of derived-data maintenance and 250 of preset; C, section 12.1) |
| Function count | 28 (24 public, 4 internal) | 57 (38, 19) | 65 (33, 32) |
| Blessed path (`rbac` preset) | G3 to G5 17/17, 13/13, 15/15; graduation 5/5; RLS 12/12 (goals page). Thin wrappers of about 50 lines. Roles are defined two times, `app` and `tenant` (A, section 6). | The same results. Generated `managed_by` policies. Graduation introduces policies, a second concept (B, Blessed path). | The same results. Each `create_role` is a new model version. Text signatures, with uuid below. A scope that is not a uuid gives false on reads and `22P02` on writes (C, section 8). |
| Correctness and safety | G2 14/14 on all. Cycles end through `union` (A, section 12.1). | Cycles and a depth over 10 are rejected on write, but not on delete (see the gap above) (B, Closure maintenance). | Cycles are rejected on write (`23514`), and a depth over 10 raises `54001` (C, sections 5 and 9). The strongest validation: typed subjects, and unknown names raise an error on write (plan, section 8 table). |
| Independent identity | G1 11/11 | 11/11 | 11/11 |
| TLE fit | G14 9/9: non-superuser install, and `pgtle.install_extension` and `create extension` on PG 16, 17, 18 with pg_tle 1.5.3 (goals page, `docker/README.md`) | The same | The same |
| Evolvability | The policy layer for conditions, CEL and Cedar is "the least designed part" (A, section 9). | The natural home: forbid, conditions, and later CEL and Cedar are policy shapes (plan, section 8 table). | CEL would compile to SQL text at model time. Cedar `when` and `unless` over arbitrary attributes do not compile to lookups (C, section 9). |
| Budgets, `--check`, PG 18 optimized, p95 (large / medium deep / medium wide) | Fails 3 / 0 / 0: `parents_proj_select_count`, `parents_select_page`, `parents_select_count` at large | Fails 1 / 0 / 2: `parents_proj_select_count` at large; `share_list_objects` (15.8 against 13) and `write_nest_team` (1.81 against 1) at medium wide | Fails 2 / 1 / 1: `parents_proj_select_count` and `write_nest_team` at large; `write_nest_team` at deep and wide |
| Budgets, `--check` at small (before the optimization, not run again) | Fails 4: both `parents_proj_*`, both single-branch `parents_*` | Fails 4: single-branch `parents_*`, `write_nest_team`, `nest_check` | Fails 1: `write_nest_team` |

All three designs pass every session 1 large budget (`rbac_*`, `share_*`, `write_assign_role`, `write_share`; OPT, Budgets). `parents_proj_select_count` at large fails for every design (p50 about 8 ms against a 9 ms p95 budget). Current minor releases read every heap page of that bitmap count. The author set the budget on 16.4, which skipped the reads (OPT, Budgets; VER, Calibration). Phase 6 re-baselined that budget to 20 ms for every design (see "Budget re-baseline" below).

The budget of 1 ms for `write_nest_team` comes from the one-tuple write of A (CMP, Budgets). C misses it by 50 to 100 times at every scale. B passes at large and deep on 18 (p95 0.78 and 0.73 ms), and misses at wide (p50 1.47 ms). On 16, B also misses at large (p95 1.29 ms). Only A still misses the single-branch budgets, which come from C (CMP, Budgets): p95 66 and 92 ms against 32 and 70.

## Choose A if

- Your sharing graphs are shallow and narrow, or you use mostly RBAC. At large with the default shape, the sharing page of A is 1.03 ms. This is within 10% of the other designs. A meets the session 1 budgets (OPT, Large default; Budgets).
- You want the smallest extension to maintain: 871 lines, 28 functions, no derived data, no drift, no locks and no limits on the isolation level. This is now the main advantage of A over B, not the speed of the nest. The nest of B is 0.62 ms against 0.15 ms for A (OPT, Ranking), and both are far under the 57.7 ms of C.
- Team and membership edits are frequent or bulk (directory syncs, nests of big teams), and you want no write amplification.
  - A writes one tuple at 23.6k tps with 4 clients.
  - B writes closure rows under a lock that it holds about 0.2 ms for a team of users (6.1k tps).
  - A nest of a sub-tree of many teams in B writes the product of descendants and ancestors. Nobody benchmarked this (B, Remaining hard limits).
- You want the familiarity of OpenFGA and SpiceDB (A, section 1).
- You accept to write the two-arm projection policy (an `org_id` or `folder_id` arm and a shared-ids arm) for org or folder access.
- A loses in these cases:
  - The single-branch parents policy: 45.6 ms for the page and 75.1 ms for the count at large (9 and 6 times C). A is the only design over those budgets.
  - Wide memberships: 14.4 ms at 50 teams for each user (1.8 times C and, on 17 and 18, ahead of B).
  - Storage at large: 404 MB, the most of the three designs. This includes a 6.8 MB edge-kind index that the optimization added (A, section 13.1).
  - The read cost still grows with what the subject reaches (A, section 13.3).
  - `rbac_check` got 10 to 20% slower in every cell (0.26 to 0.30 ms; OPT, Other differences).
- Before the optimization, the wide page of A was 125 ms (12 times C). The large single-branch page was 240 ms in Docker (221 and 509 ms on local 16.4). Docker runs these paths about 2 times faster (VER, Calibration).

## Choose B if

- You need forbid on groups, or conditions that the design evaluates, in the first year. B is the only design that has them (B, Deviations 4 and 6; plan, section 8, "The real decision").
- Your roadmap is Cedar-like policies (CEL, attribute rules), and a policy table is the natural place.
- Your keys are text or bigint, not uuid (B, Schema: text ids).
- You want generated RLS (`rls_expression`, `apply_rls`), and you can generate it again when policies change.
- After the optimization, B is no longer the worst on writes or on storage, the axes where it was the worst before:
  - The nest is 0.62 ms (it was 107).
  - The storage at large is 378 MB, below the 404 MB of A (it was 763).
  - `nest_check` is 0.32 ms (a tie).
  - The single-branch page is 13.7 ms (2.8 times C, and 3.3 times faster than A), and the count is 21.6 ms (OPT, Ranking).
- B is the slowest of the three on wide sharing reads (17.8 ms page, 8.41 ms list; C 8.20 and 3.41, A 14.4 and 4.44). It misses the budget of `share_list_objects` at medium wide (OPT, Budgets). It misses `write_nest_team` at wide (1.47 ms). It is the second largest design (1,810 lines and 57 functions, after the 2,012 lines and 65 functions of C).
- `can()` and `ids()` of B are two implementations of one semantics. They agreed on 2,400 random cases. This was an ad hoc check, and it is not committed as a spec (B, Partial evaluation). The optimized closure has the latent delete bug that the open questions describe.

## Choose C if

- Reads dominate and the groups are wide or deep. The reads of C barely move between shapes (`share_select_page` 0.66 ms deep, 8.20 ms wide at medium). On wide, C is 1.8 times faster than A and 2.2 times faster than B (8.20 against 14.4 and 17.8). The optimization reduced the lead over A on wide reads from 12 times to 1.8 times (OPT, Ranking). So this is now a smaller reason to pick C than it was.
- You want the single-branch RLS policy (no hand-written `org_id` arm) at large scale. The page is 4.94 ms for C, against 13.7 for B and 45.6 for A. The count is 11.9 / 21.6 / 75.1 ms. The projection is also about 4.7 times cheaper for C (1.05 ms; OPT, Large default).
- Nests of teams are rare or an action of an admin, and a global write lock is acceptable.
  - A nest costs 57.7 ms at large with 4 clients (67 tps; it was 300 ms).
  - The wide sharing seed of C took 24.7 s (it was 176 s; A 5.9 s, B 12.6 s).
  - `grant_many()` loads the wide seed in about 8 s (C, section 15.4, local, not in the benchmark seed).
- Your ids are uuids, and you want typed validation and unknown names that raise an error on write.
- C has the smallest storage at large (182 MB). It has the largest storage at medium wide (191.6 MB against 97.4 for A and 105.3 for B), because it materializes memberships for each user.
- C loses in these cases:
  - It has the largest and most complex write path (2,012 lines, 65 functions).
  - Its nest is far over the 1 ms budget at every scale, and it is the only design where this is true (OPT, Budgets).
  - It refuses `repeatable read` for writes that take a lock.
  - Its ids are uuid-only, and it has the global lock.

## Hybrid ideas (untested)

Nobody built or measured any of these ideas.

1. **The design of A with the materialized memberships of C behind the same functions.** [`plan.md`](./plan.md), section 8, notes that A and C share almost the same API.
   - This targets the wide and deep reads. But after the optimization the gap is 14.4 against 8.20 ms on the wide page (it was 125 against 10.2), so the case is weaker.
   - It would also inherit the global lock of C and the drift risk. It would inherit the write path that is most of the code of C (C, section 12.1). It can end as C without the typed model.
   - Object grants would still take no lock (C, section 5).
2. **The projection policy as the blessed RLS pattern, for every design.** Write the two-arm form: shared ids or a parent column (`org_id`, `folder_id`).
   - At large it is 1.33 / 1.15 / 1.05 ms (A / B / C). The single branch is 45.6 / 13.7 / 4.94 ms.
   - `rls_expression` of B already generates this shape.
   - The cost is that org or folder access lives in the policy. So `check` and `list_subjects` on the design side need the parent links to stay complete (A, section 12.1).
   - The projection matters less than before. The design is no longer the bottleneck for B and C on the single branch.
3. **Ship only the `rbac` preset first, and pick the sharing design later.** The API and the answers of the preset are identical on all three designs, and its latency is flat (OPT, Ranking). So the author could release it on the smallest design and replace the design later.
   - The risk is graduation. In C, graduation is one `apply_model()` call. In B, it introduces policies. In A, it is an extra `or` branch (C, section 8; B, Blessed path; plan, section 6).
   - Nobody tested if the data must migrate between designs.

## What the optimization pass taught

Four results apply to any design. They are the reason that plan section 4 got four rules. The design docs measured each result locally (16.4, 1 client, interleaved). OPT measures their combined effect in Docker with 4 clients, and not each result alone.

1. **The planner runs STABLE functions at plan time.** The planner estimates the row count of `array(select unnest(f('x'))::uuid)`. For that estimate, it evaluates `f` when its arguments are constants (`estimate_expression_value`). So every RLS query ran the whole list function two times.
   - The numbers: the plan time of the medium wide sharing policy of A was 11.7-12.8 ms (3,564 buffers). Now it is 0.22 ms (112 buffers, catalog lookups only). B went from 3.9 to 0.24 ms, and C from 3.2-3.4 to 0.27 ms (A, section 13.1; B, step 7; C, section 15.8).
   - A VOLATILE mark on the functions stops this, but it gives up the snapshot of the statement. Under read committed, a volatile function takes a new snapshot for each query that it runs. So the function can read grants at a later instant than the rows that it filters. B showed this, and the fix is in A and C.
   - The fix that keeps the snapshot is a last argument whose default is a VOLATILE function that returns null (`_unfolded_null()`). The call is then not constant, but the function stays STABLE.
   - The cost is an ignored extra parameter in the signature (`boolean` in A and C, `jsonb` in B). A caller who passes every argument as a constant folds the call again.
   - Boolean quals (`has_permission`, `can`) and `(select f())::uuid[]` are not evaluated early.
   - The first pass missed cases in B (`scopes_with_permission`, and the constant resource condition that `rls_expression` emitted). An EXPLAIN and a call-count probe found them (B, step 7; `22_no_plan_time_eval`).
2. **Collation on text ids.** The default database collation (`en_SG.UTF-8` here) sent every B-tree comparison, join and `distinct` sort of a uuid-as-text through `strcoll`. `collate "C"` on the id columns changed these numbers:
   - B, medium wide `share_list_objects`: 24.5-25.3 to 6.8 ms
   - B, `nest_check`: 2.2 to 0.79 ms (the `distinct` sort of 6.7k ids was 19 of 29 ms)
   - A, wide page: 18.1 to 16.2 ms
   - Equality does not change. Only the order of arrays changes.
   - The `strcoll` of Linux is slower than that of macOS, so Docker must gain more (OPT did not isolate this).
   - C uses uuid columns, so the collation does not affect it.
3. **PL/pgSQL against SQL.** A SQL function with a `SET` clause or `security definer` is never inlined. On Postgres 16, Postgres plans its body again on every call.
   - The move of the hot wrappers of B to PL/pgSQL took `rbac_check` from 0.39 to 0.29 ms. It took 0.08-0.2 ms off each call of `_parent_keys`.
   - In Docker, the RBAC reads of B are 1.2-1.7 times faster on 16 and 17, and 1.0-1.2 times faster on 18 (OPT, Other differences). The explanation that 18 caches those plans is the explanation of OPT. The author did not verify it here.
   - `_reach` of A and `_memberships_for` of C are PL/pgSQL for the same reason ([prototypes/README](./prototypes/README.md); C, section 15.2).
   - `plan_cache_mode = force_generic_plan` fixed functions whose custom plans Postgres planned again on every call (B `can()` 0.66 to 0.11 ms). The price is that the planner never picks a hash join for a huge frontier (A, section 13.3).
   - Set-returning helpers also need a `rows` estimate. The planner assumed that `_parent_keys` of B returned 1,000 rows, and it hash-joined a seq scan of `ancestors`. This took `can()` from about 1.3 to 17-22 ms.
4. **Closures over containers only.** The closure rows for each document in B were the cost behind its nest write and its storage. B now stores rows only for entities that have children (C already did this).
   - The nest went from 107 to 0.62 ms, the large storage from 763 to 378 MB, and the parents seed from 121 to 45 s.
   - The groups of a user are then one hop further, so wide reads got 5 to 8% slower (B, step 4).
   - The nest gain of C came from a different change: a delta insert instead of a recompute (C, section 15.1; 300 to 57.7 ms).
   - One caveat: the optimized closure keeps a depth-cap bug on delete that was present before (open question 8).

Cross-design observations from OPT to keep:

- Docker and local numbers differ by up to 2 times for the paths that use much PL/pgSQL (VER, Calibration). So the optimization factors that the design docs measured locally are larger than the factors in Docker. An example is the single-branch page of A: 505 to 35 ms locally, and 240 to 45.6 ms in Docker. The values after the change reproduce within 1.3 times (OPT, Claims).
- Medium wide `share_list_objects` for B improved on 16 (8.96 to 4.47 ms), but not on 17 (9.02 to 9.26). It improved only in part on 18. The author reproduced this and did not investigate it (OPT, Other differences).

## Open questions for you

1. **Do you need forbid on groups and conditions that the design evaluates in year one?** Yes points at B. No leaves A and C. A has forbid on direct subjects, and C has deny-overrides. Both handle conditions in RLS (G12 9/9 and G13 6/6 pass on all three designs).
   - Session 4: reframed. The group forbid of B goes to the later `cedar_*` model. FGA conditions are the second stage of `fga_*`. Neither is in the first spike.
   - **Closed (phase 6):** D has both. A group deny is `but not` in the model (`d/90_usage_fga`). Conditions shipped in phase 4 (`d/37`, `d/39`, [`../docs/conditions.md`](../docs/conditions.md)). Their cost is measured (D.md, opt3, "What conditions cost").
2. **Is uuid-only acceptable?** C needs it, and it assumes that uuids do not collide across principal types (C, section 12.11). A and B take text and cast to `uuid[]` in RLS (plan, section 4). Resolved at the end of session 4: D is the design and it takes text ids (`text collate "C"`), so uuid-only (C) does not apply.
3. **Is a global write lock acceptable?** After the optimization this applies mainly to C: 67 tps with 4 clients at 58 ms for each nest (pg18 large report). The lock of B is held about 0.2 ms for a team of users (6.1k tps), and longer for the nest of a sub-tree. Does your app edit teams at the same time, and how big are the teams and sub-trees?
   - Session 4: this applies only if the project adopts the materialized memberships of C later, as an optimization of `fga_*`.
   - Resolved at the end of session 4: not applicable. C is not the design, and D materializes no memberships (a write is one row).
4. **Is the refusal of `repeatable read` acceptable?** B and C raise `0A000` for writes that take a lock. ORMs that use it by default would need a different isolation level for permission writes (C, section 12.3). **Closed (phase 6): not applicable to D.** D takes no advisory locks and refuses no isolation level.
5. **Do you need single-branch RLS policies, or is the two-arm projection acceptable as the documented pattern?** The answer decides how much the 4.94 ms of C matters (against 13.7 for B and 45.6 for A).
   - Session 4: this still applies to the `fga_*` tables and to the table that combines RBAC and FGA in the spike.
   - **Closed (phase 6):** the single-branch policy of D costs the same as the two-arm projection at large. The page p50 is 1.05 against 1.04 ms, and the count is 7.76 against 7.89 ms (`pg18-docker-d-large-default-p6.md`). The reason is that D composes RBAC and FGA. It does not walk org roles. The app picks the shape when it writes the policy. The extension has nothing left to decide.
6. **Are per-document parent links acceptable?** A mirror of a column adds +160 to +385 MB at 1M documents (OPT, Seed time and storage). **Closed (phase 6):** the parent links of D cost +305 MB at 1M documents. The parents seed took the size from 18.6 to 323.7 MB at large, and from 10.0 to 40.6 MB at 100k documents (`pg18-docker-d-{large,medium,small}-default-p6.md`). This is the same range as A (+385) and B (+357). The extension stores parent links only when the app writes `parent` tuples.
7. **Do you want sharing in the first release at all, or `rbac` only?** (Hybrid 3.) Session 4: resolved. The first spike has `rbac_*` and a core subset of OpenFGA (Hybrid 3 is not the plan).
8. **For B: must a delete be rejected (`23514`) when it would leave a shortest path over 10, or must the depth have no cap?** Today the delete succeeds and drops the closure pair in silence. This is against the rule that the cap applies on write. The optimized design reproduces it on purpose, because the fuzzers compared against the original (B, Remaining hard limits). It is a change of semantics, so it is the decision of the user.
   - Session 4: this matters when the project builds Cedar on B. It does not matter for the first spike.
   - **Closed (phase 6): not applicable to D.** D stores no closure (see "What is not measured" and the findings of the usage docs).
9. **Is an ignored last parameter on `scopes_with_permission` and the list functions acceptable in the public API?** It keeps the functions STABLE without plan-time evaluation (result 1 of "What the optimization pass taught"). Plan section 6 says that the API of the `rbac` preset is identical in every design. The one-argument call is identical, but the signatures now differ (`boolean` in A and C, `jsonb` in B), and the grants must name them.
   - Session 4: this still applies, to the shared toolkit (point 7). The signatures are not compared across designs any more, because there is no common API.
   - Resolved at the end of session 4: the signatures are those of D. The FGA list functions return `setof text` and take no dummy argument. `scopes_with_permission` keeps `(text, boolean)` because the shared specs pin it.
   - Session 5 (API names): it is `rbac_scopes_with_permission(permission text, plan_time_guard boolean)`.
10. **Carried over from plan section 9: the schema name, and a convention for who can grant.** The project built and tested public access (plan section 9, question 3) on all three designs (G11 7/7).
    - Session 4: the schema name is still open. The per-model tables live in `permissions`.
    - Resolved at the end of session 4: the schema is `permissions`, with the prefixes `rbac_*` and `fga_*`. The convention for who can grant stays as built: writes are admin-only, and clients use the current-subject functions (G2).
11. **The covering user index** `fga_tuples_user_idx ... include (object_id, condition_name)`. It makes the probes of the forward walk index-only. Phase 5 measured it (D.md, opt3, "Pending user decision"):
    - Storage at large: +120 MB (323.7 to 444.1 MB, +37%).
    - Speed through pgbench: no gain (wide `share_list_objects` p50 4.90 against 4.85 ms). In the server the index is 7% faster.
    - Plan change: the index flips a plan, and large `plain_list_users` goes from 0.35 to 12.95 ms until the app pins plans.

    The recommendation was not to add it. **Closed (2026-11-01): not adopted.** The user decided not to add the index. It is not in the extension. If a later workload needs it, it is one `create index` line and a plan pin.

## Decision after phase 6 (2026-11-01): no covering index

The user closed open question 11 on 2026-11-01. The decision is not to adopt the covering index `include (object_id, condition_name)` on `fga_tuples_user_idx`. The reasons are the numbers in question 11:

- +120 MB at large (323.7 to 444.1 MB)
- no gain through pgbench (4.90 against 4.85 ms), and 7% faster in the server
- a plan flip that takes large `plain_list_users` from 0.35 to 12.95 ms

The extension keeps the index without the extra columns. No open question waits for the user now.

## What is not measured

The text of phase 6 of session 5 updated this section. Each item says what settled it, or why it stays open. The sources are OPT ([`./benchmarks/OPTIMIZATIONS.md`](./benchmarks/OPTIMIZATIONS.md)), VER ([`./benchmarks/VERSIONS.md`](./benchmarks/VERSIONS.md)) and D.md ([`./benchmarks/D.md`](./benchmarks/D.md)).

**Closed in phases 5 and 6:**

- **Small and medium default after the optimizations.** Measured for D, A, B and C on PG 18 in Docker (tag `p6`; D.md, "Phase 6"). D misses no budget at either scale. It is within 1.1 times the best design on reads at medium and large (1.0-1.4 times at small). The result of `--check` at small in the [goals page](./goals.md) stays as history from before the optimization.
- **The cost of a condition, and non-monotone relations** (`but not`, `and`). The benchmark measures them from phase 5 (D.md, opt3: conditions twins, `block_*` and `intersect_*`). The `but not` ListObjects that took 2.1 s for each call went to 4.2 ms in opt2. The wide `but not (blocked or muted)` is 7.6 ms in opt3.
- **A nest of a sub-tree, and deletes, for D.** A nest is one `fga_write` row, and D keeps no closure or membership to maintain. So there is no sub-tree cost to measure: `write_nest_team` is 0.13-0.15 ms at every scale (D.md, Phase 6). The closure cost of B and the recompute of C stay history. The benchmark has no delete timings for D.
- **Single-client writes in Docker.** Not applicable to D (no lock, so 4 clients do not queue). For C and B, the figures stay as the local 16.4 numbers of the design docs (C 15.5 ms, B 0.17 ms at large). Nobody will optimize those designs, so they are not worth a new measurement.
- **The miss of the large `parents_proj_select_count` budget** (every design, a floor of heap reads on current patch releases). The budget is now 20 ms (see below).
- **Large model changes, and the InitPlan count of B.** Closed, not applicable to D. D has no `memberships` rebuild, and the InitPlan count came from the per-table policy functions of B. The author did not measure runtime role churn (`rbac_create_role` in a loop). See the open list.

**Still open (recorded, not planned):**

- **pg_tle beyond the install test.** `03_tle_install` runs `pgtle.install_extension` and `create extension` as a non-superuser on PG 16, 17 and 18 with pg_tle 1.5.3. It passes for D (and for A, B, C). Not run: an install through database.dev (`dbdev install`) or on a hosted platform. The user dropped the managed-host test at the end of session 4. The benchmarks load the designs with `psql -f`, not through pg_tle.
- **Real hardware and durability.** The benchmark ran on one Apple Silicon laptop with `fsync=off` and `full_page_writes=off`. Every write rolls back, so the commit cost is not measured. The host is never idle.

  Phase 6 ran next to two idle Supabase stacks, a freereps stack and an openfga container. The user used the laptop at the same time (load average 4-8). The author discarded one batch of small runs as disturbed (D.md, Phase 6).
- **Concurrency mixes.** Each workload runs alone. The benchmark has no reads under concurrent writes, and no mixed read and write load.
- **PG versions.** D is benchmarked on PG 18.6 only (opt, opt2, opt3, `p6`). A, B and C also ran on 16.15 and 17.11, before and after the optimization (VER, OPT), with the same order except where noted. Not measured: D on 16 and 17, the optimized designs locally on 16.4 in the own setup of the benchmark, and a hosted platform.
- **Repeat runs and confidence intervals.** The runs are single runs with a window of 10 s for each workload. The spread is real. The large `parents_proj_select_count` p95 for the same D file was 9.35, 13.25 and 8.24 ms in three runs (opt3, `p6`, `p6check`).

  The p50 was within 0.4 ms. Judge a change by p50 and by paired runs (opt3 did this). Treat a single p95 as noisy. Also not measured: bloat from churn, and checksums beyond 8 sample users.
- **A user who sees most of 1M documents**, and the array of 1M elements that the RLS helper `fga_list_object_ids_current` would return for that user. (This helper has no cap.) The sample users see about 20k at large.
- **Runtime role churn.** `rbac_create_role` and `rbac_assign_role` in a loop. The benchmark seeds roles one time.

## Budget re-baseline (session 5, phase 6)

Phase 6 made this change, and the header of `bench/budgets.tsv` records it. The large `parents_proj_select_count` budget moves from 9 to 20 ms for every design. There is no exemption for one design.

The reason is a floor of heap reads. The bitmap heap scan reads about 10,900 all-visible heap pages on Postgres 16.15, 17.11 and 18.6. (Version 16.4 skipped them, and the 9 ms budget was set there.) The floor is p50 7.5-9.4 ms for A, B, C and D alike. Over the 27 large reports on PG 16-18 that existed (D.md, Phase 6, from `bench/baselines/pg*-docker-*-large-default*.md`), the workload missed the budget 22 times. The worst p95 was 16.1 ms (A, `p6`).

20 ms is above every measured p95, and it is 2.1 times the worst p50. It is stricter than the 25 ms that the rule of the session (3 times the fastest p95) would give. `--check` at large passes for D (`pg18-docker-d-large-default-p6check.md`: p50 7.49, p95 8.24 ms against 20; exit 0). The single-branch rows of A and `write_nest_team` of C still miss their own budgets at large, as before.

## Findings from the usage docs

The author wrote a usage guide for each design, and ran every example as a spec (`test/spec/90_usage_rbac.sql`, `a/90`, `b/90`, `c/90`). That work gave these findings. The prototypes do not fix any of them. Each one is documented on the relevant usage page. (The usage pages for D are now in [`../docs/`](../docs/).)

Phase 3 of session 5 checked each bullet against D. It did this when it wrote the usage pages of D ([`../docs/README.md`](../docs/README.md), [`../docs/fga.md`](../docs/fga.md), [`../docs/rls.md`](../docs/rls.md); each example is a spec). Each bullet ends with its status:

- closed as not applicable to D
- closed as fixed in D (with the spec that shows it)
- carried (D has the problem, and the note says what to do)

The tally: 13 not applicable, 6 fixed, 3 carried (the recheck added one of them, the last bullet).

**The `rbac` preset is not fully identical across designs** (plan section 6 says that it must be):
- `current_subject_id()` returns `text` on A and B, but `uuid` on C. On C, a JWT `sub` that is not a UUID (for example `user_2abc`) means no subject. **Closed: not applicable to D.** There is one design, and `current_subject_id()` returns `text`, so any `sub` is a subject.
- C raises `22P02` in `assign_role` for a user or scope that is not a UUID. A and B accept any text. **Closed: not applicable to D.** The user ids and scopes of D are `text`, and D never casts them.
- `scopes_with_permission` takes `(text, boolean)` on A and C, but `(text, jsonb)` on B, because of the dummy argument. C also has `uuid` overloads of `has_permission` and `has_role`. **Closed: not applicable to D.** There is one signature, `(text, boolean)`, and there are no `uuid` overloads ([`../docs/rbac.md`](../docs/rbac.md#warnings-and-limits)).
- There is no common cleanup call: `delete_subject` (A), `delete_entity` (B), `forget_subject` (C). **Closed: fixed in D.** `delete_subject(type, id)` removes the role assignments of a subject and every FGA tuple that names it, in one call (design doc, section 11, item 5). The specs are `d/30_fga_api` and `d/90_usage_rls`, where a trigger on a users table removes the role of Dave and his three tuples.
- Under `repeatable read`, B refuses `create_role` and `drop_role`. A and C let them run. **Closed: not applicable to D.** D takes no advisory locks and refuses no isolation level.

**Security-relevant RLS footguns:**
- **A:** the recommended two-arm projection policy ignores a forbid on one document, because the folder arm never visits the document. A forbid on a document needs the single-branch shape or a forbid on a folder. Nobody checked if the two-arm policy of C behaves in the same way. **Closed: fixed in D** for the recommended policy.
  - Parents are part of the OpenFGA model. So a single FGA arm on a relation with `but not` honors a deny on one document (`can_view: viewer but not blocked`, with `viewer` inherited `from parent`).
  - The specs are `d/90_usage_fga` and `d/32_fga_set_based`.
  - In `d/90_usage_fga`, Carl is blocked on a document that he reaches through two folders and a nested team, and he is not in `can_view`.
  - `d/32_fga_set_based` compares the lists that the RLS helper returns with Check.
  - A projection arm that the app writes itself (`folder_id = any (...)`), or an RBAC arm, still bypasses a deny of the model. [`../docs/rls.md`](../docs/rls.md) ("Policies") says to list the relation that contains the deny, or to use a restrictive policy, as `d/90_usage_rls` does for Dave.
- **B:** RLS does not enforce a conditioned forbid until the app runs `apply_rls` again, and `lint()` does not flag a new `via` type or column. **Closed: not applicable to D.** D generates no RLS (the policies belong to the app, and they read the tables at query time). From phase 4, D has conditions. The RLS helpers evaluate them at query time like everything else, so a new condition or model applies to the next query.
- **B:** a row with a null parent column is hidden when the user has a parent with a deny (`not (null = any(...))` is null). Here `can()` says yes, but RLS says no. **Carried: D has it** in its recommended restrictive policy on a column that can be null. `org_id <> all (array(...))` is null for a null `org_id`, so the row is hidden when the list is not empty.
  - What to do: write `org_id is null or org_id <> all (...)`.
  - [`../docs/rls.md`](../docs/rls.md) ("Policies") says so. `d/90_usage_rls` checks the null result. It also checks that Dave keeps his personal document (no org) when a ban excludes him from an org.
- **B:** conditions are only partly validated on write. An unknown operator raises an error at evaluation time, and then `rls_expression` emits SQL that does not work. **Closed: fixed in D.** From phase 4, the model write parses and type-checks the conditions of a model. An unknown operator, function or identifier, a type error, and an expression that is not bool are all 2056 (`d/37_fga_conditions_model`). A write validates the condition and the context of a tuple (`d/39_fga_conditions_eval`).
- **B:** the depth cap drops a path after a delete (open question 8). `b/90` reproduces this, and it asserts the current behavior. **Closed: not applicable to D.** D stores no closure. Walks run at read time with the depth limit of OpenFGA (`d/33_fga_walk_pruning`).

**API gaps and quirks:**
- **A:**
  - `grant` is an upsert, so if you leave out `p_expires_at`, it clears the expiry. **Closed: not applicable to D.** There is no upsert and no expiry. A write of a tuple that exists is 2017, unless `on_duplicate` is `ignore` (`d/30_fga_api`).
  - `grant` does not validate the subject type. **Closed: fixed in D.** The call checks every written or contextual tuple against the type restrictions of the relation. The error is 2027, with the valid types in the HINT. The specs are `d/30_fga_api`, `d/35_error_hints` and `d/90_usage_fga`.
  - `revoke` without the subject relation returns false in silence. **Closed: fixed in D.** A delete in `fga_write` of a tuple that does not exist is 2017, unless `on_missing` is `ignore`. An example is `team:eng` where the call meant `team:eng#member` (`d/30_fga_api`). `fga_delete_tuple` stays idempotent by design and says nothing, as [`../docs/fga.md`](../docs/fga.md) documents.
  - A typo in `from_parent` gives no access in silence. **Closed: fixed in D.** A relation with a wrong name is 2056 at model write. In a call it is 2000 (Check and the current-subject functions, RLS included) or 2022 (ListObjects, ListUsers), with the nearest name in the HINT. The specs are `d/35_error_hints`, `d/36_fga_model_validation`, `d/90_usage_fga` and `d/90_usage_rls`.
- **B:**
  - No API can undefine a role, remove an implication or disable a policy. **Carried: D has it** for roles. `drop_role` exists, but nothing changes the permissions or the inherited roles of a role, and `drop_role` removes its assignments. So a change is: drop, create and assign again ([`../docs/README.md`](../docs/README.md), `drop_role`). What to do: an `alter_role`-style call (follow-up). Policies: not applicable (OpenFGA models have versions; write a new one).
  - `apply_rls` cannot handle keys that are not uuid. **Closed: not applicable to D.** D generates no RLS.
  - `explain` can return duplicate rows. **Closed: not applicable to D.** D has no `explain`.
- **C:**
  - `apply_model` loses some rows from the plan that it returns. **Closed: not applicable to D.** `fga_write_authorization_model` returns only the model id.
  - Dry runs use up version numbers. **Closed: not applicable to D.** There is no dry run. A model that D refuses rolls back and does not become the latest (`d/36_fga_model_validation`).
  - `apply_model` skips the `repeatable read` check. **Closed: not applicable to D.** There are no locks. A model is a set of new immutable rows.
  - No API lists raw grants or purges expired grants. **Closed: fixed in D** for the list. `fga_read` returns the stored tuples, filtered and in pages (`d/34_fga_limits`, `d/90_usage_fga`). The purge is **carried: D has it** from phase 4.

    A grant that expires through a condition (`non_expired_grant`, [`../docs/conditions.md`](../docs/conditions.md)) stays a tuple after it expires: false, but stored. What to do: purge from the app with `fga_read` and `fga_write` deletes. A purge function must evaluate conditions with a chosen `current_time`.

**Checked against D, not in the lists above:**
- **Row attributes that exist only in RLS** are invisible to the check functions (session 4 direction, point 6; A, section 12.4). **Carried: D has it.** `fga_check_current` says true for a draft that RLS hides. What to do: treat the check functions as advisory and RLS as final, or pass the attribute in from a backend as a contextual tuple. [`../docs/rls.md`](../docs/rls.md) ("Row attributes that only RLS sees") documents both, and `d/90_usage_rls` checks both.

These are issues at the level of a prototype. Whichever design the user chooses, its list becomes the first work to make it stronger.
