# pg_permissions: Plan

> Status: requirements and summary, with the session 4 direction (per-model tables, RBAC and OpenFGA first) in "Current plan" below. D is the chosen engine (end of session 4) and, since phase 1 of session 5, is the extension file `pg_permissions--0.0.1.sql` (phases 1 to 5 are done; each has a status line); the ordered work plan is "Next work (session 5 onward)" right after it, and the decisions are in [`DECISION.md`](./DECISION.md), "Decisions at the end of session 4". Sections that assumed one generic API are marked superseded and kept as history. The requirements and the A/B/C comparison below were written before that decision.
>
> Earlier status (history, before the session 4 decision): requirements and summary. The extension itself wasn't implemented yet (`pg_permissions--0.0.1.sql` was empty). All three designs were built as prototypes in [`prototypes/`](./prototypes/), passed the test suite and had been benchmarked; the choice between them was open. See [`DECISION.md`](./DECISION.md).
>
> This document holds the goals and requirements every design must meet. The candidate designs are in [`designs/`](./designs/). The requirements are turned into executable goals in [`GOALS.md`](./GOALS.md) and [`test/`](./test/).

## Current plan (session 4): per-model tables

Decided 2026-10-29. The reasons and the evidence are in [`DECISION.md`](./DECISION.md), "Session 4 direction: per-model tables". This section is the current plan; the sections after it are kept as history, and those that assumed one generic API carry a "Superseded" note.

- The `permissions` schema holds a separate set of tables for each model, each following an existing spec as closely as possible. There is no single generic API over all models.
  - `rbac_*` tables: the blessed path, first-class tables rather than wrappers over a shared core.
  - `fga_*` tables: follow OpenFGA, not SpiceDB or a generic "Zanzibar-style" model. The two have different schema languages, so following a spec means choosing one. OpenFGA was chosen so that its public test suite can serve as a test oracle, and because it has CEL conditions on tuples.
  - `cedar_*` tables: later. B is the starting point. Full Cedar `when`/`unless` over arbitrary attributes doesn't compile to index lookups (DECISION, Scorecard, Evolvability; C §9), so this will likely be a documented subset tested against Cedar's corpus.
- Models compose in RLS. An app can use several at once for different things: permissive policies OR together and restrictive policies AND. Graduation means adding the FGA model next to RBAC, not migrating off it.
- No separate ABAC model, because ABAC is a category and not a spec. Row attributes are covered by RLS, attributes on a relationship (expiry, IP range, amount) by OpenFGA conditions, and policy-language ABAC by Cedar later. Row attributes that exist only in RLS are invisible to the check functions (A §12.4), so the usage docs must say either that the check functions are advisory and RLS is final, or that row attributes are passed into the check.
- Shared code is a small toolkit, not an API: subject identity (§3), the plan-time-evaluation guard and `collate "C"` on text ids (§4), and the install and pg_tle plumbing.
- First spike: the `rbac_*` tables plus an OpenFGA core subset (direct relations, computed usersets, tuple-to-userset, wildcards `user:*`), run against OpenFGA's own test cases, plus one table whose RLS combines RBAC and FGA, benchmarked against the current numbers (§8).
- Second stage: OpenFGA conditions (CEL). In pg_tle this means a parser and compiler in SQL or PL/pgSQL, the largest single cost, so it follows the core.
- Prototypes: A is the starting point for `fga_*` (C's materialized memberships remain a possible optimization if wide reads need it), B for `cedar_*`, and C's generic compiled model is dropped. They stay in the repo as measured history. The spike was validated, D was chosen and is now `pg_permissions--0.0.1.sql` (phase 1 of "Next work").

## Next work (session 5 onward)

Decided by the user at the end of session 4 (2026-10-29); the decisions are in [`DECISION.md`](./DECISION.md), "Decisions at the end of session 4". D is the engine and is the extension (phase 1 moved it from `prototypes/d-per-model.sql` to `pg_permissions--0.0.1.sql`): schema `permissions`, prefixes `rbac_*` and `fga_*`, one implicit OpenFGA store per database. A, B and C stay as measured history. Each phase below is done when its "Done when" line holds, and each ends with a commit. Do the phases in order: 2 changes the API that 3 documents, 4 touches every evaluator that 5 then optimizes.

Starting point (end of session 4): 37 spec files and 2,164 assertions pass on PG 16, 17 and 18 (Docker, pg_tle 1.5.3); OpenFGA's consolidated suite passes 933 of 933 stored and 746 of 746 contextual assertions; D's design and limitations are in [`designs/d-per-model.md`](./designs/d-per-model.md) (sections 7, 8 and 11 matter most), its numbers in [`bench/baselines/D.md`](./bench/baselines/D.md) (opt2).

### Working rules (every phase)

- **TDD.** Write the failing spec first (the `tdd` skill's red-green-refactor), then the code. A change to one evaluator (`_fga_bidi`, `_fga_forward`, `_fga_rec`, the set-based `but not` lists) is run against the whole suite, since they must agree (design doc section 11, item 6).
- **Benchmarks strictly one at a time, and never while tests run** (they share the machine's CPU; a concurrent run corrupts the numbers). Use `--tag` for every experiment so results never overwrite a baseline. Record what else was running on the machine.
- **Commit per milestone, never push.** Subject `pg_permissions: <what>`; the commit message ends with the attribution line the session's instructions specify.
- **Append each session to [`JOURNAL.md`](./JOURNAL.md)**: what was tried, mishaps, decisions, numbers worth quoting, angles for the post. The user will write a blog post from it.
- **Treat downloaded upstream data as untrusted.** Clone or download into a new empty temp directory, keep scripts in a different directory, pass paths as arguments, run Python with `python3 -I`, and execute nothing that came from it. Pin the commit SHA and verify what was fetched. Same approach as [`test/fga/vendor.sh`](./test/fga/vendor.sh).
- **Never edit an upstream expectation to make a case pass.** List the case in a skip file with the reason.
- **Unrelated Docker stacks may be running on the machine** (Supabase, freereps, an `openfga/openfga` container). Don't stop or remove them; pick free ports and your own compose project name.
- Docs are code: every example in a usage page is a spec; every number in a doc names its source.

### Phase 1: promote D to the extension

> Status: done (commit `246fe1f`). The extension file is D, `prototypes/d-per-model.sql` is removed, and the scripts and docs default to it; 37 files and 2,164 assertions locally and on PG 16, 17 and 18.

Goal: `pg_permissions--0.0.1.sql` is D, and every script and doc treats the extension as the default.

Steps:
1. Copy `prototypes/d-per-model.sql` into `pg_permissions--0.0.1.sql` (the extension file is the source of truth from here on). Decide what happens to `prototypes/d-per-model.sql`: recommended, delete it and repoint links (`grep -rn d-per-model.sql .. --include=*.md --include=*.sh --include=*.mjs`), leaving old benchmark baselines' mentions as history with one note in `prototypes/README.md` that D moved. Check `pg_permissions.control` (`default_version = '0.0.1'`, `superuser = false`, the `comment` line) still describes it, and that the file is valid as a plain extension script and for pg_tle (the existing `03_tle_install` spec).
2. `test/run.sh`: the default `--impl` is the extension file and the design letter used to pick `test/spec/<letter>/` is `d` for it (the shared specs under `test/spec/` run too). Keep `test/spec/d/` as the extension's own specs (don't rename the directory).
3. `bench/run.sh`: default implementation is the extension file with design `d`; `--impl prototypes/a-tuple-core.sql` and the others still work. Root `Makefile`: `test.pg_permissions` and `bench.pg_permissions` already default `IMPL` to `pg_permissions--0.0.1.sql`; check `tle.install.pg_permissions` and the help text.
4. `docker/run-matrix.sh`: `--designs` defaults to `ext` (it already maps `ext` to the extension file); `a,b,c,d` remain selectable. Update `docker/README.md`.
5. READMEs and the docs site: `README.md`, `test/README.md`, `prototypes/README.md`, `docker/README.md`, `usage/README.md` and the site in `../docs` (run `make docs.sync` from the repo root; see `../docs/AGENTS.md`) present D as the engine and A/B/C as history. Update the status blockquote and the "stays empty" statements in PLAN.md (this file, the sections after this one) and DECISION.md that say `pg_permissions--0.0.1.sql` is empty or that the choice is open.

Files: `pg_permissions--0.0.1.sql`, `pg_permissions.control`, `prototypes/README.md`, `test/run.sh`, `bench/run.sh`, `../Makefile`, `docker/run-matrix.sh`, `docker/README.md`, `README.md`, `test/README.md`, `usage/README.md`, `../docs/`.

Done when: `test/run.sh` with no `--impl` passes the full suite on the extension file locally (same counts as the starting point); `docker/run-matrix.sh` with the default designs passes on PG 16, 17 and 18, including `03_tle_install`; `make docs` builds from the repo root with no broken links; `grep -rn "stays empty\|is empty" .` finds nothing stale.

### Phase 2: API decisions (caps, pagination, descriptive errors)

> Status: done (commit `8e0f614`). Caps (1,000 and 100), Read pagination, and a HINT on every raise site with `d/35_error_hints` and its guard; 39 files and 2,276 assertions locally and on PG 16, 17 and 18, OpenFGA suite 933/746.

Goal: the decisions in DECISION.md, points 4 and 5, are implemented and spec-tested.

Steps:
1. **Caps.** First read OpenFGA's documentation (and the pinned source's behavior; downloaded data is untrusted) for what happens when each limit is hit, and match it: ListObjects and ListUsers return at most 1,000 results (record whether OpenFGA truncates silently or errors, and which results survive), Write takes at most 100 tuples per call (the error code and name when exceeded), Read is paginated with `page_size` and `continuation_token` (default and maximum page size, the token's role, and the behavior on a bad token). Write the specs first: 1,001 or more objects through `fga_list_objects`, 101 tuples through `fga_write`, a Read walked page by page that returns every tuple exactly once in a stable order, a bad token. Read needs a deterministic order (the primary key) and a token that encodes the last key.
2. **API functions are capped; the RLS helpers are not.** Split each list function into an uncapped internal one and a capped public one. `fga_list_objects_current`, `fga_list_object_ids_current` and any other RLS-facing variant call the uncapped one. A spec seeds more than 1,000 reachable objects and asserts the API returns 1,000 while the `_current` functions return all of them, and that `40_rbac_fga_rls` and `41_no_plan_time_eval` (STABLE, not run at plan time, once per query) still pass.
3. **Descriptive errors with HINTs, everywhere**, `rbac_*` as well as `fga_*`. Keep SQLSTATE and the `DETAIL` code `openfga:<code> <name>` on fga errors. The MESSAGE names the actual offending values (type, relation, user string, model id); the HINT always suggests the fix: the allowed user types for that relation, the nearest existing relation name (by edit distance; the extension must stay pure SQL/PL/pgSQL with no contrib dependency, so write a small function, or list the relations when none is close), the call to make first (for example `fga_write_authorization_model` when no model exists), the valid model id list. Go through every `raise` in the extension file (about 9 sites in the prototype use `raise exception` directly, and more through helper functions; count them with grep, do not trust this number).
4. **A spec that triggers every raise site** (new file in `test/spec/d/`, table-driven: statement, expected SQLSTATE, expected DETAIL code or none for `rbac_*`, a pattern for the MESSAGE) and asserts a non-empty HINT on each. Add a guard that fails when a raise site has no HINT, for example by scanning `pg_proc.prosrc` for the extension's functions for `raise` statements without `hint`. All existing OpenFGA suite error-code assertions must keep passing.
5. Update `designs/d-per-model.md`: section 4 (caps, pagination), section 7 (error table, HINTs), section 8 deviation 4 (no longer a deviation, except the RLS helpers), and the exact behaviors found in step 1.

Files: `pg_permissions--0.0.1.sql`, `test/spec/d/30_fga_api.sql` and a new spec file for the errors and the caps, `designs/d-per-model.md`, `usage/` (phase 3 rewrites it; fix examples that break).

Done when: the new specs fail before and pass after; the full suite is green locally and on the docker matrix (PG 16, 17, 18); the OpenFGA consolidated suite is still 933/746; the every-raise-site spec passes and the guard fails if a HINT is removed (check by deleting one).

### Phase 3: hardening and usage docs

> Status: done (commit `pg_permissions: model validation oracle, D usage docs, findings closed (phase 3)`). Entrypoint and cycle checks and OpenFGA's model error codes; openfga/language's 93 validation cases vendored in `test/fga_lang/`, 66 run and pass, 27 skipped with reasons; usage pages `fga.md` and `rls.md` with the README rewritten for D, every example a spec; every finding in DECISION.md closed or carried; 43 files and 2,463 assertions locally and on PG 16, 17 and 18, OpenFGA suite 933/746.

Goal: model validation is complete, the usage docs describe D, and the old findings list is closed or carried.

Steps:
1. **Complete model validation.** The gaps are in `designs/d-per-model.md` section 8, item 8: relations with no entrypoint (`define a: b`, `define b: a`) and OpenFGA's other graph checks (cycles in computed relations and anything else the validator rejects). Use openfga/language's `tests/data/dsl-semantic-validation-cases.yaml` (Apache-2.0) as the oracle, with the same vendoring approach as [`test/fga/`](./test/fga/): a new vendor script that fetches the repository at a pinned SHA into an empty temp directory, verifies the SHA, copies the file with its LICENSE and a SOURCE file (repository, commit, CLI image, date), converts each case's DSL model to JSON with the pinned `openfga/cli` image by digest (stdin, no network; if the transformer refuses invalid models, say so, find the pinned CLI's way to emit JSON without validating, or record those cases in the skip file with the reason), and commits the result. A `generate.py` (run with `python3 -I`) writes TAP specs. For each case assert accepted versus rejected by `fga_write_authorization_model` and, for rejected ones, the error code (`openfga:2056`) and a non-empty HINT; the upstream error text is the language library's, not the server's, so do not match messages. A skip list (`skip.tsv`) with a reason for each case not run; never edit an expectation. Report how many cases pass.
2. Implement the missing checks in `fga_write_authorization_model` until every non-skipped case passes. Re-check the existing suite: a stricter validator must not reject any model in the consolidated suite. Add mutants (disable one check, see the cases fail) and record the counts.
3. **Rewrite the usage docs for D.** `usage/` today has pages for A, B and C. Write the D page (one page for the extension, or `rbac` and `fga` pages plus the combined RLS page) and rewrite `usage/README.md`; every example is a spec (pattern: `test/spec/90_usage_rbac.sql` and `test/spec/a/90_*`; add `test/spec/d/90_usage_*.sql`). Cover: the RBAC API, writing a model (DSL converted to JSON with `fga model transform`), tuples, Check, ListObjects, ListUsers, Read with pagination, contextual tuples, composing RBAC and FGA in RLS (the `40_rbac_fga_rls` pattern), the plan-time guard, caps and errors, privileges. The usage docs must say that row attributes that exist only in RLS are invisible to the check functions: either the check functions are advisory and RLS is final, or row attributes are passed in (this file's "Current plan (session 4)", the "No separate ABAC model" bullet; DECISION, "Session 4 direction", point 6).
4. **Re-check "Findings from writing the usage docs" in DECISION.md against D**, bullet by bullet: for each, write one of "closed: not applicable to D (reason)", "closed: fixed in D (the spec that proves it)" or "carried: D has it (what to do)". Most are A, B or C specific and close as not applicable, but check D for the analogues (a typo in a relation name giving silent no-access, which D should raise as 2022; forbid semantics, which in D are `but not`; the RLS-only attribute gap; `delete_subject` spanning both models, design doc section 11 item 5). Any item claimed fixed gets a spec.
5. Update `designs/d-per-model.md` section 8 (item 8 removed or narrowed) and `GOALS.md` if a goal's status changed.

Files: `pg_permissions--0.0.1.sql`, a new `test/fga_lang/` (or similar) directory with `vendor.sh`, `generate.py`, `skip.tsv`, `upstream/`, `cases.json`, new `test/spec/d/6x_*` generated specs, `usage/`, `test/spec/d/90_usage_*.sql`, `DECISION.md`, `designs/d-per-model.md`.

Done when: the validation oracle passes except the listed skips (each with a reason); the consolidated suite is still 933/746; every usage example is a spec and the specs pass; each finding in DECISION.md has a closing note; docs site builds.

### Phase 4: OpenFGA conditions (CEL)

> Status: done (commit `pg_permissions: OpenFGA conditions with a PL/pgSQL CEL evaluator (phase 4)`). Conditions are compiled at model write (tokenizer, parser, type checker in PL/pgSQL, a jsonb AST in `fga_conditions`) and evaluated by a PL/pgSQL interpreter in every walk, with OpenFGA's error rules and a `conditional` flag that keeps unconditioned relations on their statements; decisions in DECISION.md, "Decisions for conditions (session 5)", design and deviations in `designs/d-conditions.md` (section 13). OpenFGA's ABAC suite passes 302/302 stored and 271/271 contextual (9 `$expression` cases skipped), the consolidated suite is still 933/746, the fga_lang oracle 70/70 (4 condition cases newly run); in-house specs `d/37`, `d/38` (142 CEL expressions), `d/39`, usage page `usage/conditions.md` (`d/90_usage_conditions`) and a "Conditions in policies" section in `usage/rls.md`; every mutant caught; the unconditioned fast path within noise on the benchmark; 53 files and 3,337 assertions locally and on PG 16, 17 and 18.

Goal: conditions on tuples, type restrictions and models work as in OpenFGA, with the CEL evaluator written in PL/pgSQL (the user wants it in the database: no external service, no extension beyond pg_tle's limits). The largest single cost in the plan.

Steps:
1. **Vendor the oracle.** `assets/tests/abac_tests.yaml` (33 cases) from the same repository and the same pinned SHA as the consolidated suite (`44054f542f64e9b9589dd26a595081b3d2cfd942`), extending `test/fga/vendor.sh` (or a sibling script) and `generate.py`: same pinned CLI image, same skip file, same stored and contextual-tuple runs, same TAP naming. Condition cases pass `context` on the request and on tuples. Before writing any code, list from the cases which CEL types, operators and functions they use, and from OpenFGA's documentation the supported condition parameter types (any, bool, string, int, uint, double, duration, timestamp, map, list, ipaddress) and functions; that list is the scope.
2. **Write `designs/d-conditions.md` first** (a short design doc: grammar subset, token and AST shapes, how the compiled form is stored, how it is evaluated, error mapping, how walks consult it, performance expectations), and check it against the cases before coding. Recommended shape: a tokenizer and a precedence-climbing parser in PL/pgSQL producing an AST; store the compiled form at model-write time (rows in a new `fga_condition_*` table or jsonb on `fga_models`; no parsing at Check time); evaluate with a recursive PL/pgSQL function over typed values. Whatever is chosen, say why.
3. **Model write:** parse every condition expression when the model is written; reject a syntax error, an unknown parameter name, a parameter type that is not one of OpenFGA's, a condition that is not boolean, and a tuple or type restriction naming an undefined condition, with the error code OpenFGA gives (look it up in the cases and docs) and a descriptive HINT. Store the parameter types. Remove the `0A000` `conditions_not_supported` error.
4. **Evaluation:** typed parameters (OpenFGA's condition parameter types) with the tuple's stored context and the request's context merged exactly as OpenFGA does (find which side wins in the docs and cases and pin it with a spec); a missing parameter raises 2000 as upstream does, a type mismatch likewise; an evaluation error in one branch follows the same rules as other branch errors (it loses to a branch that decides). `fga_write` validates a tuple's condition name and context types as OpenFGA does; Read returns conditions with the tuple.
5. **Wire conditions into every evaluator:** `_fga_bidi`, `_fga_forward`, `_fga_backward`, `_fga_rec`, the set-based `but not` lists, ListObjects, ListUsers, and contextual tuples. A walk edge through a conditioned tuple is taken only when the condition evaluates true. Keep the unconditioned fast path as fast as it is now (compare `fga_check` and ListObjects timings on the existing benchmark before and after, tag the run).
6. Update `designs/d-per-model.md` (sections 2, 4, 7, 8 deviation 2) and `usage/` (a conditions page with specs, for example expiry and IP range).

Files: `pg_permissions--0.0.1.sql`, `designs/d-conditions.md`, `test/fga/vendor.sh` and `generate.py` (or siblings), `test/fga/upstream/abac_tests.yaml`, `cases.json` (or a second JSON), `test/fga/skip.tsv`, generated `test/spec/d/6x_*` specs, new in-house specs for CEL expressions the cases don't reach, `usage/`.

Done when: the abac suite passes fully in both runs (stored and contextual-tuple), with any skip listed with a reason; the consolidated suite is still 933/746; mutants are caught (ignore the condition, treat a missing parameter as false, swap context precedence, skip the type check: each fails at least one assertion; record the counts); `d/41_no_plan_time_eval` still passes (no plan-time evaluation); the full suite is green locally and on the docker matrix (PG 16, 17 and 18).

### Phase 5: performance pass 2

> Status: done (commits `0bd650b`, `482aab4`, `01b9fc2` and the write-up). Measured as opt3 against a re-measured "before" (phase 2 and 4 had moved D's storage and write numbers since opt2), in paired PG 18 Docker runs (`bench/baselines/D.md`, opt3): non-monotone ListObjects evaluate the rewrite tree over sets (wide `but not (a or b)` 5,246 → 7.6 ms, `a and b` 621 → 6.1 ms), typed writes (0.25 → 0.16 ms, large parents seed 33 → 15 s), a partial userset index for Check (`nest_check` 0.45-0.47 → 0.40 ms at medium), conditions evaluated once per distinct context and matched by an equality join (wide conditioned ListObjects 14.8 → 10.6 ms; a context per tuple 3.2 s → 0.17 s, ListUsers 29-37 s → 0.6-1.0 s); rejected with measurements: folding Check's probe (slower), one tuplestore fewer and `distinct` for the level grouping (≤ 8%), a fix for userset cycles (3.3x, no exact alternative); the covering index measured (+120 MB at large, no pgbench gain) and left to the user. New bench phases for conditions and non-monotone relations (the `but not` workload moved in), specs `d/42` (68 assertions) and `d/43` (199), every mutant caught; checksums identical to A, B and C; budgets unchanged; 55 files and 3,604 assertions locally and on PG 16, 17 and 18, OpenFGA suite 933/746, ABAC 302/271, fga_lang 70/70.

Goal: close the hotspots listed in [`bench/baselines/D.md`](./bench/baselines/D.md) ("Remaining gaps and hotspots") and measure what conditions cost. Everything is tested before and after; a change that doesn't pay is reverted and written up.

Candidates, from D.md and the journal:
1. **Check** is 1.3-1.4x A: `_fga_bidi` runs too many statements per round (two `_fga_bstep` calls, a probe and a meet test). Matters for per-row RLS (`fga_check_current` in an update policy). Folding the user probe into the step was considered and not done because it changes the level accounting for userset users; the depth specs (`d/33`) and the OpenFGA depth cases guard that.
2. **Writes** are 1.5-1.7x A: `fga_write_tuple` builds JSON that `fga_write` re-parses and validates with six lookups. Add a typed write path (validate and insert without the JSON round trip) behind both.
3. **Wide ListObjects** (1.15x A, 1.5x C): the final leaf join does an index probe plus a heap fetch per tuple because the user index has no `object_id`. A covering index would make it index-only (-33% on large fan-outs, +120 MB at large: decide on the numbers); also the sort-based `group by` that keeps each target's lowest level and the three PL/pgSQL result tuplestores.
4. **Non-monotone paths** outside the set-based form (intersections, `but not (a or b)`, a base that depends on a non-monotone relation): about 2 s per wide ListObjects, because each candidate is checked top-down without memoization. Look for a set-based form for intersections and a union-of-subtracts, or memoization.
5. **Cyclic userset data**: the leveled walk re-expands a node once per level up to 25. `_fga_forward_ids` (one row per node) is the alternative; needs data with cycles, which the benchmark doesn't have, so add a cyclic shape or a side script first.
6. **Conditions** (phase 4): what a conditioned edge costs in Check, ListObjects and ListUsers against the unconditioned version of the same data.

Steps: pick the order by the numbers; for each change write or extend a spec that pins the behavior (the existing specs plus the OpenFGA suite are the safety net; add a mutant if the change adds a path), implement, run the whole suite (not at the same time as a benchmark), then benchmark one configuration at a time with a new tag (for example `opt3`) on PG 18 in Docker: large default, medium deep, medium wide, all four designs for comparison where the earlier numbers exist. Move the `but not` ListObjects block-list workload from the side script (`designs/d/but_not_list_objects.sql`) into the pgbench workloads. Update `bench/baselines/D.md` with a new section comparing opt2 and opt3 (and A, B, C), including budgets and `--check`; update `designs/d-per-model.md` section 5 and 10.

Done when: each candidate above is either done with before/after numbers or rejected with a measurement; checksums still identical across designs; the suite is green on the docker matrix; `D.md` has the opt3 section; budgets in `bench/budgets.tsv` are re-checked.

### Phase 6: loose ends

1. **Small and medium scale benchmarks in Docker** for the extension (and A, B, C for comparison): small and medium default shape after the optimizations, which were never measured (DECISION, "What hasn't been measured"). One run at a time, tagged.
2. **Re-baseline the large `parents_proj_select_count` budget** in `bench/budgets.tsv`. It misses (11.55 ms against 9 ms) for every engine, a heap-fetch floor on current Postgres patch releases that no engine can reach. Change the budget to a number every engine can meet with a recorded reason, not an engine-specific exemption; say so in `bench/baselines/D.md` and `DECISION.md`.
3. Close the open items in DECISION.md ("What hasn't been measured", open questions) that the work above settled, and record the rest.

Done when: small and medium results are committed under `bench/baselines/`; `--check` at large passes; DECISION.md's lists are current.

## Goal

A single Postgres extension that can express several authorization models (RBAC, Zanzibar/FGA-style relationships, and later attribute rules), so each application picks the model that fits instead of installing a different extension per model.

Constraints, same as the rest of this repo:

- Pure SQL / PL/pgSQL, installable as a Trusted Language Extension (`superuser = false`), published on database.dev.
- Every check is usable inside RLS policies.
- Not tied to Supabase. It works with Supabase out of the box, but nothing references the `auth` schema.

## 1. Review of the existing ideas

There are four open RFC PRs in this repo, each proposing a separate extension:

| PR | Extension | Model | Core storage | How it finds the current user |
| --- | --- | --- | --- | --- |
| #7 | `pg_zanzibar` | ReBAC (Zanzibar) | `tuples(object, relation, subject[#relation])` + `relation_configs(implied_by[])` | `auth.uid()`, then `zanzibar.subject_id` setting |
| #8 | `pg_abac` | ABAC | `subject_attributes`, `policies`, `policy_rules(attr, op, value)` | `abac.subject_id` setting, then `current_user` |
| #9 | `pg_cel` | CEL expressions + RBAC/ABAC helpers | Mostly stateless; optional `policies(expression)` | JWT claims (`request.jwt.claims`) |
| #10 | `pg_cedar` | Cedar (permit/forbid) | `entities(attributes jsonb)`, `entity_parents`, `actions`, `policies` | `cedar.user_id` setting |

What they have in common:

1. **Each one reinvents identity.** There are four different ways to answer "who is the current user?", and one of them (#7) hard-codes `auth.uid()`, which fails on non-Supabase databases.
2. **Each one reinvents "subject is related to object".** Zanzibar tuples, Cedar `entity_parents`, ABAC role assignments and group membership are all the same shape: `(object_type, object_id) --relation--> (subject_type, subject_id)`.
3. **They differ mainly in how a decision is computed:** graph walk (Zanzibar), attribute rules (ABAC), expressions (CEL), or ordered permit/forbid (Cedar).
4. **They share the same RLS performance problem.** #7 makes the important point: a per-row `check()` in a policy runs once per row. A "list the IDs I can access" function wrapped in `(select ...)` runs once per query. This has to be a first-class part of the API.

Superseded in part (session 4, see "Current plan"): the "one way to model subject is related to object" part. Per-model tables each follow their own spec; identity and the RLS fast path stay shared.

Takeaway: whichever design we choose should have **one identity layer**, **one way to model "subject is related to object"**, and a **first-class RLS fast path**. The designs in `designs/` disagree on how to get there.

## 2. Proof-of-concept scope

Superseded (session 4): the first spike is `rbac_*` plus an OpenFGA core subset (see "Current plan"); the "one extension, many models in one API" framing below no longer applies. The model descriptions and the v0.0.1 exclusions are still a useful reference.

The first version must support these models in one extension. Implementing two genuinely different models proves the "one extension, many models" goal. The examples below describe behaviour, not storage; each design decides how to store them.

### Model 1: RBAC (global or per-tenant)

- Roles are scoped to a tenant/org, or app-wide.
- Roles form a hierarchy: `owner` > `admin` > `member`. Permissions such as `edit_documents` are granted to one or more roles.
- Example: Alice is an admin of Acme, so she can edit every Acme document.

### Model 2: ReBAC / Zanzibar-lite (fine-grained)

- Per-object relationships: Bob is an editor of the `readme` document.
- Implied relations on the same object: `editor` implies `viewer`.
- Groups: every member of team `eng` is a viewer of `readme`.
- Nested groups, with recursion capped at a maximum depth (default 10).

### Model 3 (stretch): attribute conditions

- Access that depends on attributes of the subject, resource or request (for example "only published documents", or a grant that expires).
- No CEL parser in v0.0.1.

### Explicitly out of scope for v0.0.1

- A CEL parser, Cedar `forbid` policies and priority ordering (but the design must show where they would fit).
- Parent inheritance ("viewers of a folder can view its documents"). The first item for v0.0.2, so the design must show how it would be added.
- Zookies / replica consistency, audit logging, caching.

## 3. Identity requirements

- The extension must not store users or reference the `auth` schema.
- It must resolve the current subject without configuration on Supabase (PostgREST sets `request.jwt.claims`; its `sub` claim is what `auth.uid()` returns) and with an explicit session setting on plain Postgres.
- Contract, fixed by `test/spec/01_identity.sql`: `permissions.current_subject_id()` returns the JWT `sub` if present, otherwise the `permissions.subject_id` setting, otherwise null. `permissions.current_subject_type()` defaults to `'user'`. The JWT wins, so nothing else in a session can override the subject of a request that carries one.
- Explicit-subject variants must exist for tests and server-side jobs, and must be **admin-only**. If clients could call them, any user could ask what any other user can access.
- Apps need a documented way to clean up permissions when a user is deleted from their identity table.

## 4. RLS requirements

- All checks are STABLE and safe to call from RLS policies.
- There must be a fast path for SELECT on large tables that doesn't call a function once per row (for example a "list accessible IDs" function wrapped in `(select ...)`), plus a simple per-row check for single-row writes.
- Clients must not be able to write permission data directly.
- **The RLS fast path is `col = any (array(select unnest(f())::uuid))`.** Two other ways of writing it look right but aren't, both measured on Postgres 16 with 1M rows:
  - `col = any ((select f()))` is parsed as a subquery comparison and fails with `operator does not exist`, even with the double parentheses. The original Zanzibar RFC (#7) has this bug.
  - `col = any ((select f())::uuid[])` works, but Postgres re-applies the `::uuid[]` cast to the parameter on every row it filters. A page of 50 documents took 3.64 ms instead of 0.73 ms.
  - `col in (select unnest(f())::uuid)` (a hashed subquery) stops Postgres using the column's index: counting a user's visible documents took 88.8 ms instead of 2.2 ms.
- **RLS-facing functions are STABLE, with a volatile-default dummy argument so the planner can't fold them.** To estimate the row count of `array(select unnest(f('x'))::uuid)`, the planner evaluates a STABLE `f` at plan time when all its arguments are constants, so every query ran the whole list function twice (A's medium wide planning: 11.7-12.8 ms and 3,564 buffers, against 0.22 ms and 112 after the fix; B 3.9 to 0.24 ms; C 3.2-3.4 to 0.27 ms; A §13.1, B Optimizations steps 6-7, C §15.8). Don't fix it by marking the function VOLATILE: under read committed a volatile function takes a fresh snapshot for each query it runs, so grants can be read at a later instant than the rows being filtered. Add a trailing parameter whose default is a VOLATILE function returning null (`permissions._unfolded_null()`, granted to public because defaults run as the caller). The parameter is ignored, callers use the short form, and the function still reads the statement's snapshot. Passing every argument as a constant folds the call again. Boolean quals such as `has_permission` and `can`, and scalar subqueries such as `(select f())::uuid[]`, aren't pre-evaluated. Pin it with a spec: `pg_proc.provolatile` is STABLE, and a call-count probe shows that `EXPLAIN` doesn't run the function (`test/spec/22_no_plan_time_eval.sql`).
- **Use `collate "C"` on text identifier columns** (ids, type names, relation and role names). The database default collation (`en_SG.UTF-8` in the benchmarks) sent every B-tree comparison, join and `distinct` sort of a uuid-as-text through `strcoll`. In B it took medium wide `share_list_objects` from 24.5-25.3 to 6.8 ms and `nest_check` from 2.2 to 0.79 ms; in A the wide sharing page went from 18.1 to 16.2 ms (B step 1, A §13.1 item 2b). Equality, hashing and `= any` don't change, only the order of returned arrays, so compare id lists as sets. A recursive CTE needs its non-recursive term marked `collate "C"` too. `uuid` columns need nothing. Linux's glibc `strcoll` is slower than macOS's, so the gain should be larger in production (not isolated in the Docker runs).
- **Write hot functions that can't be inlined in PL/pgSQL (Postgres 16).** A SQL function with a `SET` clause or `security definer` is never inlined, and on Postgres 16 its body is parsed and planned again on every call; PL/pgSQL caches plans per session. In B this took `rbac_check` from 0.39 to 0.29 ms and `nest_check` from 0.39 to 0.33 ms, and `_parent_keys` off 0.08-0.2 ms per call (B step 3). In the Docker runs B's RBAC reads were 1.2-1.7x faster on 16 and 17 and 1.0-1.2x on 18 (OPT, Other differences). If a PL/pgSQL function's cached custom plans are re-planned on every call, pin `plan_cache_mode = force_generic_plan` (B `can()` 0.66 to 0.11 ms), and mark CTEs the generic plan could turn into per-row probes as `materialized` (A §13.1 item 3).
- **Give set-returning helpers a `rows` estimate.** A function scan is estimated at 1,000 rows. B's `_parent_keys()` returns about one row, but once `ancestors` had real statistics the planner hash-joined a seq scan of it, and `can()` went from about 1.3 to 17-22 ms; `rows 1` restored the primary-key probe (`nest_check` 0.79 ms; B Weaknesses). Joining a view whose branch is a join needs the same care: use `cross join lateral (... offset 0)`.

## 5. Reference scenario

Every design must show this scenario end to end (schema, setup SQL, RLS policies), so the designs can be compared side by side:

- Org `acme`. Alice is an `admin`, Carol is a `member`. Admins can edit all of the org's documents; members can view them.
- A `documents` table with `id uuid` and `org_id uuid` columns.
- Document `readme`: Bob (not in the org) is an `editor`. Team `eng` (members: Carol and Dave) are `viewer`s.
- `editor` implies `viewer`.
- Queries to answer: Can Bob update `readme`? Which documents can Dave select? Who can view `readme`?

## 6. Blessed path and model presets

Superseded (session 4): presets over one shared engine are dropped. The blessed path is now first-class `rbac_*` tables, and graduation adds `fga_*` next to them (see "Current plan"). The rule that both presets write to the same core data, and the "identical `rbac` preset API in every design" rule, no longer hold; the usage-doc findings in [`DECISION.md`](./DECISION.md) show why. Kept as history.

The extension should offer a **blessed path**: a developer picks a model preset and only learns the concepts that preset needs. Presets are a layer of functions on top of whichever engine we choose. The engine is never visible to a developer who stays on the RBAC preset.

### Presets

| Preset | For | Concepts the developer learns |
| --- | --- | --- |
| `rbac` | Most apps: app-wide roles, optionally scoped to a tenant/org | Roles, permissions, scopes |
| `zanzibar` | Per-object sharing, groups, nested teams | Object types, relations, groups (the engine's full API) |

Later presets (attribute conditions, Cedar-style policies) follow the same pattern.

Rules for every design:

- **Both presets write to the same core data.** An app that starts on `rbac` and later needs per-document sharing adds the `zanzibar` functions without migrating anything. Its RLS policies gain an extra `or` branch.
- **The `rbac` preset API is identical in every design.** Only the implementation underneath differs. That keeps the engine swappable, and backwards compatibility with earlier drafts isn't a concern.
- **Plain names.** A developer on the `rbac` preset never sees tuples, relations, policies, `via`, or a model file.

### The `rbac` preset API

User and scope IDs are shown as `text`. A design with typed IDs (Design C) uses `uuid`.

```sql
-- Define roles. A role grants permissions and can inherit other roles' permissions.
permissions.create_role(role text, permissions text[], inherits text[] default '{}')
permissions.drop_role(role text)

-- Assign roles. scope = null means app-wide; otherwise a tenant/org ID.
permissions.assign_role(user_id text, role text, scope text default null)
permissions.unassign_role(user_id text, role text, scope text default null)

-- Checks for the current user (STABLE, safe in RLS)
permissions.has_permission(permission text, scope text default null) returns boolean
permissions.has_role(role text, scope text default null) returns boolean
permissions.scopes_with_permission(permission text) returns text[]   -- RLS fast path for tenant scoping

-- Admin and debugging (not callable by clients)
permissions.user_permissions(user_id text, scope text default null) returns text[]
permissions.users_with_role(role text, scope text default null) returns setof text
```

Behaviour the tests pin down (`test/spec/1x_*.sql`):

- `create_role`, `drop_role`, `assign_role` and `unassign_role` are admin-only.
- `has_role` is true for a role held directly or through inheritance (an editor "has" viewer).
- Unknown permission or role names return false rather than raising, so an RLS policy that names a dropped permission denies instead of breaking every query.
- `drop_role` fails while another role inherits it, and removes the role's assignments.
- Role names and permission names can't overlap.

**App-wide and scoped roles are kept separate.** `has_permission(p)` checks only app-wide roles, and `has_permission(p, scope)` checks only that scope. An app that wants "app-wide admins can do anything in any tenant" writes both checks in its policy. This keeps the rule explicit: there's no hidden inheritance between scopes.

### RBAC scenario

Every design must also show this scenario, written **only** with the preset API above, and then show what happens underneath:

1. **App-wide roles.** Roles: `viewer` (`documents.read`), `editor` (`documents.edit`, inherits `viewer`), `admin` (`documents.delete`, `users.manage`, inherits `editor`). Alice is `admin`, Bob is `editor`, Carol is `viewer`.
2. **RLS on `documents`:** SELECT needs `documents.read`, UPDATE needs `documents.edit`, DELETE needs `documents.delete`.
3. **Tenant-scoped variant.** Same roles, but assigned per org: Alice is `admin` of `acme`, Bob is `editor` of `acme` and `viewer` of `globex`. RLS uses `documents.org_id`.
4. **Graduation.** Later, the app shares one `acme` document with Dave (not in any org) as an editor, using the `zanzibar` preset. Show what changes in the data and in the RLS policies, and confirm the RBAC data is untouched.
5. **Queries:** Can Carol edit documents? What permissions does Bob have in `globex`? Who are the admins of `acme`?

## 7. Evaluation criteria

Written for choosing one engine. The "Blessed path" row refers to the superseded presets (§6); the rest still apply to each model's tables.

| Criterion | Question |
| --- | --- |
| Model flexibility | How naturally does it express RBAC, ReBAC, attributes, and later CEL/Cedar? |
| RLS performance | Cost of a SELECT over 1M rows, and of a single-row check. Read vs write cost. |
| Simplicity | How much SQL does an app developer write for the reference scenario? How much code is in the extension? |
| Blessed path | How cleanly does the `rbac` preset (§6) map onto the engine? Can an app graduate to `zanzibar` without migrating data? |
| Correctness and safety | Default deny, cycle handling, no dynamic SQL injection, clients can't escalate. |
| Identity decoupling | Meets §3 without special cases. |
| TLE fit | Pure SQL/PL/pgSQL, no superuser, works through dbdev. |
| Evolvability | Cost of adding parent inheritance, conditions, CEL, Cedar later. |

## 8. Candidate designs

Superseded as a choice (session 4): the three designs are measured history and starting points (A for `fga_*`, B for `cedar_*`, C's generic model dropped), not candidates for one API. The numbers remain the baseline the spike is benchmarked against. See "Current plan".

| Design | Approach |
| --- | --- |
| [A: Shared tuple core](./designs/a-tuple-core.md) | Zanzibar-style tuples in one generic table with `text` IDs. Decisions computed at read time by a recursive CTE. |
| [B: Policy-first](./designs/b-policy-first.md) | Cedar-style `policies` table decides everything. Roles, groups and parents are plain data. Group and role closures are precomputed on write. |
| [C: Compiled model](./designs/c-compiled-model.md) | A JSON model is compiled into lookup tables. Group membership is materialized by triggers. Typed, `uuid`-only IDs. |

All three are built ([`prototypes/`](./prototypes/)) and pass every goal in [`GOALS.md`](./GOALS.md): A 18/18 spec files (199 assertions), B 18/18 (189), C 21/21 (229). They return identical visible-document sets for every read policy at every scale, shape and Postgres version benchmarked. The numbers below are for the engines after the session 3 optimization pass, from [`bench/baselines/OPTIMIZATIONS.md`](./bench/baselines/OPTIMIZATIONS.md) (serial runs, Postgres 18.6 in Docker, one laptop, 4 clients, p50 at large unless noted; "wide" and "deep" are medium-scale stress shapes). The same matrix on Postgres 16 and 17 is in OPTIMIZATIONS.md and [`VERSIONS.md`](./bench/baselines/VERSIONS.md). The pre-optimization numbers (local Postgres 16.4) are in [`COMPARISON.md`](./bench/baselines/COMPARISON.md).

### Comparison

Each design's own "weaknesses" section has the details. This table summarizes them against §7.

| Criterion | A: Tuple core | B: Policy-first | C: Compiled model |
| --- | --- | --- | --- |
| Model flexibility | RBAC, ReBAC, parents, `user:*` and expiry in the engine. Forbid only against a subject's own tuple. Conditions are RLS composition. | Widest: forbid (including group principals) and conditions are policy shapes, evaluated in the engine and compiled into RLS. Refuses policies that can't become SQL filters. | RBAC and ReBAC with OpenFGA-like types. Forbid is deny-overrides along the parent chain. Conditions are RLS composition. |
| Read cost | Pruned recursive walk. `share_select_page` 1.03 ms; 14.4 ms in the wide shape (was 125); 0.76 ms deep. | Flat joins. 1.00 ms; 17.8 ms wide (was 36.9); 0.72 ms deep. | Flat joins. 0.93 ms; 8.20 ms wide (was 10.2); 0.66 ms deep. |
| Write cost | One row per grant. `write_nest_team` 0.15 ms. | Closure rows for inner nodes only, under a global lock: 0.62 ms (was 107; 4 clients). | Membership rows under a global lock: 57.7 ms (was 300; 4 clients, 67 tps). |
| Org-wide access via parents | Two-arm projection policy 1.33 ms; single-branch policy 45.6 ms (was 240). | 1.15 ms; 13.7 ms (was 102). | 1.05 ms; 4.94 ms (was 9.26). |
| Simplicity | One concept (tuples). 871 lines, 28 functions. | Two concepts (facts and policies). 1,810 lines, 57 functions. | One model file plus grants. Most complex write path. 2,012 lines, 65 functions. |
| Blessed path (`rbac` preset, §6) | Identical API and answers on all three; RBAC p50 under 1 ms and within about 0.1 ms across engines. Thin wrappers; roles defined twice (`app`, `tenant`). Graduation adds an `or` branch. | Maps one to one: inheritance is `role_implies`, permissions are actions. Generated policies carry `managed_by`. Graduating introduces policies. | One lookup, no triggers for RBAC. Each `create_role` is a new model version. Graduation is one `apply_model()` call. |
| Validation | Weak: relation names only. | Roles declared per type. | Strongest: typed subjects, unknown names raise on write. |
| IDs | `text` (`collate "C"`), array cast to `uuid[]` in RLS. | `text` (`collate "C"`), cast to `uuid[]` in RLS. | `uuid` only, no casts. Other key types need a mapping table. |
| Concurrency | No locks. | One advisory lock for closure writes (held about 0.2 ms when nesting users); `repeatable read` refused for them. | One global advisory lock for memberships and container moves; `repeatable read` refused. |
| Drift risk | None: nothing is derived. | Closure tables can drift (triggers); no `verify`. Delete can drop a closure pair beyond depth 10 (open decision, DECISION.md). | `memberships` can drift (`verify`/`rebuild` provided). |
| Familiarity | SpiceDB / OpenFGA. | Cedar. | OpenFGA. |

### What the three designs tell us

- **Precomputing group membership pays on reads, and after optimization the price on writes depends on what is precomputed.** In the wide shape (50 teams per user) `share_select_page` is 14.4 ms for A, 17.8 ms for B and 8.20 ms for C. Fixing plan-time evaluation, dropping a `distinct` sort and pruning the walk closed most of A's gap (it was 125 ms, against 10.2 for C). Nesting a 1,000-member team takes 0.15 ms for A, 0.62 ms for B (closure rows for inner nodes only, no longer per document) and 57.7 ms for C, which still writes a membership row per member and ancestor under a global lock. C's reads lead; its write cost is the price.
- **The `rbac` preset works the same on all three engines.** The identical preset API (§6) gives the same answers to the RBAC scenario and the same latency within about 0.1 ms. For developers who stay on RBAC, which is most apps, the engine is invisible. The choice only matters for performance and for apps that graduate to per-object sharing.
- **How the RLS policy is written matters as much as the engine.** The two-arm projection (`id = any(<shared with me>) or folder_id = any(<folders I can view>)`) costs about what plain sharing costs on every engine. The single-branch policy makes the engine materialize every visible document id: 45.6 ms for A and 13.7 ms for B at large, against 4.94 ms for C, against 1.33, 1.15 and 1.05 ms for the projection. The projection is still about 4.7x cheaper for C. (§4 has the policy-form findings.)
- **A and C have almost the same `zanzibar`-level API** (`grant`/`revoke`, check, list accessible IDs, list subjects). C is close to "A with a typed model and a materialized membership index". B's `zanzibar`-level API is different (policies plus role grants), so that part is a choice to make up front.
- **Most of the optimization lessons are engine-independent** and became the §4 rules: don't let the planner fold STABLE list functions, collate text ids as `"C"`, use PL/pgSQL for non-inlinable hot functions on Postgres 16, and give set-returning helpers a `rows` estimate.
- **The real decision is relationship-first (A/C) or policy-first (B)**, and for relationship-first, whether to pay write-time cost for read speed. Relationship-first is simpler and familiar to FGA users. Policy-first is the only one with forbid on groups and conditions in the engine, at the price of a second concept and a coupling between policies and RLS.

### Deciding

[`DECISION.md`](./DECISION.md) is the decision guide: a scorecard against §7, when each engine wins, what the optimization pass taught, untested hybrids, open questions and what hasn't been measured. The raw numbers are in [`bench/baselines/OPTIMIZATIONS.md`](./bench/baselines/OPTIMIZATIONS.md) (optimized engines), [`bench/baselines/VERSIONS.md`](./bench/baselines/VERSIONS.md) (Postgres 16-18) and [`bench/baselines/COMPARISON.md`](./bench/baselines/COMPARISON.md) (pre-optimization).

## 9. Open questions (all designs)

1. **Schema name**: `permissions`, or something less likely to clash with app schemas? Also confirm how pg_tle / dbdev handles a fixed schema versus `with schema extensions`.
2. **Who may grant?** Should the extension ship a convention for who can grant what, or leave it to the app?
3. **Public access** (`user:*` in OpenFGA terms): in v0.0.1 or later? Built and tested on all three prototypes as G11 (§10).

## 10. v0.0.2 goal scenarios

Each design implements these in its own native API, as spec files in `test/spec/<design>/`. Assertions are the same across designs, so results compare one to one. All RLS assertions run as `authenticated`.

- **G10 Parent inheritance (`50_parents`).** Org `acme` is the parent of folder `specs`; folder `specs` is the parent of document `readme` (documents have `id`, `org_id`, `folder_id`). Org admins (Alice) can edit every document under the org; org members (Carol) can view them; Erin is a viewer of folder `specs` and can view `readme` but not other folders' documents. An RLS policy on `documents` expresses this **with a single fast-path branch** (no hand-written `or org_id = ...` arm). `list_subjects`-equivalent for `readme`/view includes Alice, Carol and Erin. Removing Erin's folder grant removes her access; moving `readme` to another folder (changing its parent) changes who inherits access. Parent chains terminate on cycles.
- **G11 Public access (`51_public`).** Document `announcement` is viewable by every user (`user:*`). Any subject with no other data can view it, cannot edit it, and it appears in their list of viewable objects. A request with no subject (null) is denied (default deny; anonymous access is out of scope). Revoking the public grant removes access for everyone.
- **G12 Forbid (`52_forbid`).** Dave is a viewer of `readme` through team `eng`, and Alice is an org admin. A forbid/block on `readme` for Dave makes his check false, removes `readme` from his object list and from `readme`'s subject list, and the RLS SELECT no longer returns it. A forbid on Alice for `readme` beats her parent-derived admin access. Removing the forbid restores access. Forbids on one object don't affect others.
- **G13 Conditions (`53_conditions`).** Documents have `status` (`'draft'` | `'published'`). Org members can view only published documents; editors and admins can view drafts too. A grant with `expires_at` in the past grants nothing. Expressed however the design prefers (policy condition, or RLS composition), asserted through RLS SELECT results.
- **G14 TLE install (`03_tle_install`, shared).** The implementation installs as a non-superuser that owns the database (no superuser-only features, no C), and if pg_tle is available it installs via `pgtle.install_extension`; otherwise the test checks non-superuser install only and says so in a diagnostic.
