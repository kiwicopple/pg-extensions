# pg_permissions: Plan

> Status: this page is a historical record of the plan. D is the chosen design (end of session 4). From phase 1 of session 5, D is the extension file `pg_permissions--0.0.1.sql`. Phases 1 to 6 of the work plan are all done (as of 2026-10-30), and each phase has a status line. The extension has 56 spec files and 3,638 assertions, and they pass on PG 16, 17 and 18. The user docs are in [`../docs/`](../docs/).
>
> The page has the requirements and a summary, with the session 4 direction (per-model tables, RBAC and OpenFGA first) in "Current plan" below. The ordered work plan is "Next work (session 5 onward)", right after it. The decisions are in [`./decision.md`](./decision.md), "Decisions at the end of session 4". A section that assumed one generic API has a "Superseded" note. It stays as history. The requirements and the A/B/C comparison below were written before that decision.
>
> Earlier status (history, before the session 4 decision): the page had the requirements and a summary. The extension was not yet written, and `pg_permissions--0.0.1.sql` was empty. All three designs were built as prototypes in [`../prototypes/`](../prototypes/). They passed the test suite and the benchmarks had measured them. The choice between them was open (see [`./decision.md`](./decision.md)).
>
> This page has the goals and requirements that every design must meet. The candidate designs are in [`./designs/`](./designs/). [`./goals.md`](./goals.md) and [`../test/`](../test/) turn the requirements into executable goals.

## Current plan (session 4): per-model tables

The user decided this on 2026-10-29. [`./decision.md`](./decision.md), "Session 4 direction: per-model tables", has the reasons and the evidence. This section is the plan of session 4. The sections after it are history. Those that assumed one generic API have a "Superseded" note.

- The `permissions` schema holds a separate set of tables for each model. Each set follows a public spec as closely as possible. There is no single generic API over all models.
  - `rbac_*` tables: the blessed path. They are first-class tables, not wrappers over a shared core.
  - `fga_*` tables: they follow OpenFGA, not SpiceDB or a generic "Zanzibar-style" model. The two have different schema languages, so to follow a spec is to choose one. The user chose OpenFGA for two reasons. Its public test suite can serve as a test oracle, and it has CEL conditions on tuples.
  - `cedar_*` tables: later. B is the base. Full Cedar `when` and `unless` over arbitrary attributes do not compile to index lookups (see [`./decision.md`](./decision.md), Scorecard, Evolvability, and design C, section 9). So this model will probably be a documented subset, tested against the Cedar corpus.
- Models compose in RLS. An app can use more than one model at the same time, for different things. Permissive policies combine with OR, and restrictive policies combine with AND. To graduate is to add the FGA model next to RBAC. The app does not migrate off RBAC.
- There is no separate ABAC model, because ABAC is a category and not a spec.
  - RLS covers row attributes.
  - OpenFGA conditions cover attributes on a relationship (expiry, IP range, amount).
  - Cedar will cover policy-language ABAC later.
  - The check functions cannot see row attributes that exist only in RLS (design A, section 12.4). So the usage docs must say one of two things. Either the check functions are advisory and RLS is final, or the app passes the row attributes into the check.
- Shared code is a small toolkit, not an API. It has the subject identity (section 3), the plan-time-evaluation guard and `collate "C"` on text ids (section 4), and the install and pg_tle code.
- First spike: the `rbac_*` tables plus a core subset of OpenFGA. The subset has direct relations, computed usersets, tuple-to-userset and wildcards (`user:*`). The spike runs against the test cases of OpenFGA, and it has one table whose RLS combines RBAC and FGA. The benchmark compares it with the current numbers (section 8).
- Second stage: OpenFGA conditions (CEL). In pg_tle this means a parser and a compiler in SQL or PL/pgSQL. That is the largest single cost, so it comes after the core.
- Prototypes: A is the base for `fga_*`. The materialized memberships of C stay a possible optimization if wide reads need them. B is the base for `cedar_*`. The generic compiled model of C is dropped. The prototypes stay in the repo as measured history. The spike was valid, the user chose D, and D is now `pg_permissions--0.0.1.sql` (phase 1 of "Next work").

## Next work (session 5 onward)

> Status: done. All six phases below are done (as of 2026-10-30). Each phase has its own status line. This section is the plan as written at the end of session 4. Some text uses the future tense for work that is now complete.

The user decided this at the end of session 4 (2026-10-29). The decisions are in [`./decision.md`](./decision.md), "Decisions at the end of session 4". D is the chosen design, and it is the extension. Phase 1 moved it from `prototypes/d-per-model.sql` to `pg_permissions--0.0.1.sql`. The schema is `permissions`, the prefixes are `rbac_*` and `fga_*`, and there is one implicit OpenFGA store for each database. A, B and C stay as measured history.

Each phase is done when its "Done when" line is true, and each phase ends with a commit. Do the phases in order. Phase 2 changes the API that phase 3 documents. Phase 4 touches every evaluator that phase 5 then optimizes.

State at the end of session 4: 37 spec files and 2,164 assertions pass on PG 16, 17 and 18 (Docker, pg_tle 1.5.3). The consolidated suite of OpenFGA passes 933 of 933 stored assertions and 746 of 746 contextual assertions. [`designs/d-per-model.md`](./designs/d-per-model.md) has the design and the limits of D (sections 7, 8 and 11 matter most). [`./benchmarks/D.md`](./benchmarks/D.md) has its numbers (opt2).

### Rules for every phase

- **TDD.** Write the spec that fails first (the red-green-refactor loop of the `tdd` skill). Then write the code.
  - Run the whole suite after a change to one evaluator (`_fga_bidi`, `_fga_forward`, `_fga_rec` or the set-based `but not` lists). The evaluators must agree (design doc [`designs/d-per-model.md`](./designs/d-per-model.md), section 11, item 6).
- **Run benchmarks strictly one at a time. Never run them at the same time as tests.** They share the CPU of the machine. A concurrent run corrupts the numbers.
  - Use `--tag` for every experiment, so that a result never overwrites a baseline.
  - Record what else runs on the machine.
- **Commit for each milestone. Never push.** The subject is `pg_permissions: <what>`. The commit message ends with the attribution line that the instructions of the session give.
- **Append each session to [`./journal.md`](./journal.md).** Write what the session tried, the mishaps, the decisions, the numbers to quote and the angles for the post. The user will write a blog post from the journal.
- **Treat downloaded upstream data as untrusted.**
  - Clone or download it into a new empty temp directory.
  - Keep the scripts in a different directory, and pass paths as arguments.
  - Run Python with `python3 -I`, and execute nothing that came from the download.
  - Pin the commit SHA and verify what you got.
  - Use the same approach as [`../test/fga/vendor.sh`](../test/fga/vendor.sh).
- **Never edit an upstream expectation to make a case pass.** List the case in a skip file with the reason.
- **Unrelated Docker stacks can run on the machine** (Supabase, freereps, an `openfga/openfga` container). Do not stop or remove them. Pick free ports and your own compose project name.
- Docs are code. Every example in a usage page is a spec. Every number in a doc names its source.

### Phase 1: promote D to the extension

> Status: done (commit `246fe1f`). The extension file is D, and `prototypes/d-per-model.sql` is removed. The scripts and docs use the extension by default. The suite passed with 37 files and 2,164 assertions locally and on PG 16, 17 and 18.

Goal: `pg_permissions--0.0.1.sql` is D, and every script and doc treats the extension as the default.

Steps:
1. Copy `prototypes/d-per-model.sql` into `pg_permissions--0.0.1.sql`. The extension file is the source of truth from here on.
   - Decide what happens to `prototypes/d-per-model.sql`. The recommendation is to delete it and to repoint the links (`grep -rn d-per-model.sql .. --include=*.md --include=*.sh --include=*.mjs`).
   - Leave the mentions in old benchmark baselines as history. Add one note to [`prototypes/README.md`](./prototypes/README.md) that D moved.
   - Check that `pg_permissions.control` still describes the extension (`default_version = '0.0.1'`, `superuser = false`, the `comment` line).
   - Check that the file is valid as a plain extension script and for pg_tle (the `03_tle_install` spec checks this).
2. In `test/run.sh`, make the extension file the default `--impl`. The design letter that picks `test/spec/<letter>/` is `d` for it. The shared specs under `test/spec/` also run. Keep `test/spec/d/` as the own specs of the extension. Do not rename the directory.
3. In `bench/run.sh`, make the extension file with design `d` the default implementation. The options `--impl prototypes/a-tuple-core.sql` and the others must still work.
   - In the root `Makefile`, `test.pg_permissions` and `bench.pg_permissions` already default `IMPL` to `pg_permissions--0.0.1.sql`.
   - Check `tle.install.pg_permissions` and the help text.
4. In `docker/run-matrix.sh`, make `ext` the default of `--designs` (it already maps `ext` to the extension file). The designs `a,b,c,d` stay selectable. Update `docker/README.md`.
5. Make these files present D as the design and A, B and C as history:
   - `README.md`, `test/README.md`, `prototypes/README.md`, `docker/README.md` and the user docs in [`../docs/`](../docs/).
   - Then update the docs site in the repo-level `docs` directory. Run `make docs.sync` from the repo root (see `docs/AGENTS.md`).
   - Update the status blockquote and the "stays empty" statements in this page (the sections after this one) and in [`./decision.md`](./decision.md). They say that `pg_permissions--0.0.1.sql` is empty or that the choice is open.

Files:
- `pg_permissions--0.0.1.sql`, `pg_permissions.control`, `test/run.sh`, `bench/run.sh`
- the root `Makefile`, `docker/run-matrix.sh`, `docker/README.md`, `README.md`, `test/README.md`
- [`prototypes/README.md`](./prototypes/README.md), the user docs in [`../docs/`](../docs/), the docs site in the repo-level `docs` directory

Done when:
- `test/run.sh` with no `--impl` passes the full suite on the extension file locally.
- The counts are the same as the state at the end of session 4.
- `docker/run-matrix.sh` with the default designs passes on PG 16, 17 and 18, with `03_tle_install`.
- `make docs` builds from the repo root with no broken links.
- `grep -rn "stays empty\|is empty" .` finds nothing that is out of date.

### Phase 2: API decisions (caps, pagination, descriptive errors)

> Status: done (commit `8e0f614`). The phase added the caps (1,000 and 100), the pagination of Read, and a HINT on every raise site. It also added the spec `d/35_error_hints` and its guard. The suite passed with 39 files and 2,276 assertions locally and on PG 16, 17 and 18, and the OpenFGA suite passed 933/746.

Goal: the decisions in [`./decision.md`](./decision.md), points 4 and 5 of "Decisions at the end of session 4", are implemented and tested with specs.

Steps:
1. **Caps.** First read the OpenFGA documentation for what happens when each limit is reached. Read the behavior of the pinned source also (downloaded data is untrusted). Then match that behavior.
   - ListObjects and ListUsers return at most 1,000 results. Record if OpenFGA truncates in silence or raises an error, and which results survive.
   - Write takes at most 100 tuples for each call. Record the error code and the name when a call exceeds the limit.
   - Read has pages with `page_size` and `continuation_token`. Record the default and maximum page size, the role of the token, and the behavior with a bad token.
   - Write the specs first. They test 1,001 or more objects through `fga_list_objects`, 101 tuples through `fga_write` and a bad token.
   - One spec walks Read page by page. It must return every tuple one time, in a stable order.
   - Read needs a deterministic order (the primary key) and a token that encodes the last key.
2. **The API functions have caps. The RLS helpers have none.** Split each list function into an internal function without a cap and a public function with a cap.
   - `fga_list_objects_current`, `fga_list_object_ids_current` and any other variant for RLS call the function without a cap.
   - A spec seeds more than 1,000 reachable objects. It asserts that the API returns 1,000 and that the `_current` functions return all of them.
   - The specs `40_rbac_fga_rls` and `41_no_plan_time_eval` must still pass (STABLE, no plan-time evaluation, one run for each query).
3. **Write descriptive errors with HINTs, everywhere.** This covers `rbac_*` and `fga_*`. Keep the SQLSTATE and the `DETAIL` code `openfga:<code> <name>` on fga errors.
   - The MESSAGE names the actual wrong values (type, relation, user string, model id).
   - The HINT always suggests the fix. It names one of these items:
     - the user types that are valid for that relation
     - the name of the nearest relation that exists
     - the call to make first (an example is `fga_write_authorization_model`, when no model exists)
     - the list of valid model ids
   - Find the nearest name by edit distance. The extension must stay pure SQL and PL/pgSQL with no contrib dependency. So write a small function, or list the relations when none is close.
   - Go through every `raise` in the extension file. About 9 sites in the prototype use `raise exception` directly, and more sites are in helper functions. Count them with grep. Do not trust this number.
4. **Write a spec that triggers every raise site.** Put it in a new file in `test/spec/d/`. It is table-driven: the statement, the expected SQLSTATE, the expected `DETAIL` code (none for `rbac_*`) and a pattern for the MESSAGE. It asserts a HINT that is not empty on each site.
   - Add a guard that fails when a raise site has no HINT. For example, scan `pg_proc.prosrc` of the functions of the extension for `raise` statements without `hint`.
   - All error-code assertions of the OpenFGA suite must still pass.
5. Update [`designs/d-per-model.md`](./designs/d-per-model.md): section 4 (caps, pagination), section 7 (error table, HINTs) and section 8, deviation 4. Deviation 4 is no longer a deviation, except for the RLS helpers. Also add the exact behaviors that step 1 found.

Files:
- `pg_permissions--0.0.1.sql`, `test/spec/d/30_fga_api.sql`, a new spec file for the errors and the caps
- [`designs/d-per-model.md`](./designs/d-per-model.md)
- the user docs in [`../docs/`](../docs/) (phase 3 rewrites them; fix the examples that break)

Done when:
- The new specs fail before the change and pass after it.
- The full suite is green locally and on the docker matrix (PG 16, 17, 18).
- The consolidated suite of OpenFGA is still 933/746.
- The spec of every raise site passes. The guard fails if a HINT is removed. To check this, delete one HINT.

### Phase 3: stronger checks and usage docs

> Status: done (commit `pg_permissions: model validation oracle, D usage docs, findings closed (phase 3)`). The phase added the entrypoint and cycle checks and the model error codes of OpenFGA. It vendored the 93 validation cases of openfga/language in `test/fga_lang/`: 66 run and pass, and 27 are skipped with reasons.
>
> It added the usage pages `fga.md` and `rls.md`, and it rewrote the README for D. Every example is a spec. Every result in the "Findings from the usage docs" of [`./decision.md`](./decision.md) is closed or carried. The suite passed with 43 files and 2,463 assertions locally and on PG 16, 17 and 18. The OpenFGA suite passed 933/746. The usage pages are now in [`../docs/`](../docs/).

Goal: the model validation is complete, the usage docs describe D, and the old list of findings is closed or carried.

Steps:
1. **Complete the model validation.** The gaps are in [`designs/d-per-model.md`](./designs/d-per-model.md), section 8, item 8. The gaps are relations with no entrypoint (`define a: b`, `define b: a`). They are also the other graph checks of OpenFGA: cycles in computed relations and all other cases that the validator rejects.
   - Use `tests/data/dsl-semantic-validation-cases.yaml` (Apache-2.0) of openfga/language as the oracle. Vendor it in the same way as [`../test/fga/`](../test/fga/).
   - Write a new vendor script. It gets the repository at a pinned SHA into an empty temp directory and verifies the SHA. It copies the file with its LICENSE and a SOURCE file (repository, commit, CLI image, date).
   - Convert the DSL model of each case to JSON with the pinned `openfga/cli` image, by digest (stdin, no network). If the transformer refuses invalid models, say so. Then find the way of the pinned CLI to emit JSON without validation, or record those cases in the skip file with the reason. Commit the result.
   - A `generate.py` (run with `python3 -I`) writes TAP specs. For each case, assert that `fga_write_authorization_model` accepts or rejects the model. For a rejected case, assert the error code (`openfga:2056`) and a HINT that is not empty.
   - Do not match messages. The upstream error text comes from the language library, not from the server.
   - Keep a skip list (`skip.tsv`) with a reason for each case that does not run. Never edit an expectation. Report how many cases pass.
2. Implement the checks that are not present in `fga_write_authorization_model` until every case that is not skipped passes.
   - Run the suite again. A stricter validator must not reject any model in the consolidated suite.
   - Add mutants. Disable one check, and see the cases fail. Record the counts.
3. **Rewrite the usage docs for D.** The usage docs had pages for A, B and C. Write the D page. It can be one page for the extension, or `rbac` and `fga` pages and the combined RLS page. Rewrite the README of the usage docs.
   - Every example is a spec. The pattern is `test/spec/90_usage_rbac.sql` and `test/spec/a/90_*`. Add `test/spec/d/90_usage_*.sql`.
   - Cover these topics:
     - the RBAC API
     - the write of a model (DSL converted to JSON with `fga model transform`)
     - tuples, Check, ListObjects and ListUsers
     - Read with pagination, and contextual tuples
     - RBAC and FGA together in RLS (the `40_rbac_fga_rls` pattern)
     - the plan-time guard, caps and errors, and privileges
   - The usage docs must say that the check functions cannot see row attributes that exist only in RLS. Either the check functions are advisory and RLS is final, or the app passes the row attributes in. See "Current plan (session 4)" above, the bullet "There is no separate ABAC model", and [`./decision.md`](./decision.md), "Session 4 direction", point 6.
4. **Check the "Findings from the usage docs" in [`./decision.md`](./decision.md) against D, bullet by bullet.** For each result, write one of these three notes:
   - "closed: not applicable to D (reason)"
   - "closed: fixed in D (the spec that proves it)"
   - "carried: D has it (what to do)"
   - Most findings are specific to A, B or C, and they close as not applicable. Check D for the analogues.
   - The analogues are:
     - a typo in a relation name that gives silent no-access (D must raise 2022)
     - the semantics of forbid (in D they are `but not`)
     - the gap of RLS-only attributes
     - `delete_subject`, which spans both models (design doc section 11, item 5)
   - Add a spec for any item that you claim as fixed.
5. Update [`designs/d-per-model.md`](./designs/d-per-model.md), section 8 (remove or narrow item 8), and [`goals.md`](./goals.md) if the status of a goal changed.

Files:
- `pg_permissions--0.0.1.sql`
- a new `test/fga_lang/` (or a similar directory) with `vendor.sh`, `generate.py`, `skip.tsv`, `upstream/` and `cases.json`
- new generated specs `test/spec/d/6x_*`, and the usage specs `test/spec/d/90_usage_*.sql`
- the usage docs (now in [`../docs/`](../docs/)), [`./decision.md`](./decision.md), [`designs/d-per-model.md`](./designs/d-per-model.md)

Done when:
- The validation oracle passes, except for the listed skips (each with a reason).
- The consolidated suite is still 933/746.
- Every usage example is a spec, and the specs pass.
- Each result in the "Findings from the usage docs" of [`./decision.md`](./decision.md) has a final note.
- The docs site builds.

### Phase 4: OpenFGA conditions (CEL)

> Status: done (commit `pg_permissions: OpenFGA conditions with a PL/pgSQL CEL evaluator (phase 4)`). The model write compiles conditions (tokenizer, parser and type checker in PL/pgSQL, with a jsonb AST in `fga_conditions`). A PL/pgSQL interpreter evaluates them in every walk, with the error rules of OpenFGA. A `conditional` flag keeps relations without conditions on their own statements.
>
> The decisions are in [`./decision.md`](./decision.md), "Decisions for conditions (session 5)". The design and the deviations are in [`designs/d-conditions.md`](./designs/d-conditions.md) (section 13). The ABAC suite of OpenFGA passes 302/302 stored and 271/271 contextual assertions (9 `$expression` cases are skipped). The consolidated suite is still 933/746. The fga_lang oracle passes 70/70 (4 condition cases newly run).
>
> The in-house specs are `d/37`, `d/38` (142 CEL expressions) and `d/39`. The usage page is [`../docs/conditions.md`](../docs/conditions.md) (`d/90_usage_conditions`). A section "Conditions in policies" is in [`../docs/rls.md`](../docs/rls.md). Every mutant was caught. The fast path without conditions stayed within noise on the benchmark. The suite passed with 53 files and 3,337 assertions locally and on PG 16, 17 and 18.

Goal: conditions on tuples, type restrictions and models work as in OpenFGA. The CEL evaluator is written in PL/pgSQL. The user wants it in the database: no external service, and no extension beyond the limits of pg_tle. This is the largest single cost in the plan.

Steps:
1. **Vendor the oracle.** The file is `assets/tests/abac_tests.yaml` (33 cases). It comes from the same repository and the same pinned SHA as the consolidated suite (`44054f542f64e9b9589dd26a595081b3d2cfd942`).
   - Extend `test/fga/vendor.sh` (or a similar script) and `generate.py`. Use the same pinned CLI image, the same skip file, the same runs with stored and with contextual tuples, and the same TAP names.
   - The condition cases pass `context` on the request and on tuples.
   - Before you write code, list from the cases which CEL types, operators and functions they use. List also, from the OpenFGA documentation, the supported condition parameter types (any, bool, string, int, uint, double, duration, timestamp, map, list, ipaddress) and the functions. This list is the scope.
2. **Write [`designs/d-conditions.md`](./designs/d-conditions.md) first.** It is a short design doc. It covers these topics:
   - the grammar subset, and the token and AST shapes
   - how the design stores the compiled form, and how it evaluates it
   - the error codes, how walks use it, and the expected performance

   Check the doc against the cases before you write code.
   - The recommended shape is a tokenizer and a precedence-climbing parser in PL/pgSQL that produce an AST.
   - Store the compiled form when the model is written, in rows of a new `fga_condition_*` table or in jsonb on `fga_models`. Do not parse at Check time.
   - Evaluate with a recursive PL/pgSQL function over typed values.
   - Say why you choose each option.
3. **Model write.** Parse every condition expression when the model is written. Reject each of these cases with the error code that OpenFGA gives (look it up in the cases and the docs) and a descriptive HINT:
   - a syntax error
   - an unknown parameter name
   - a parameter type that is not one of the types of OpenFGA
   - a condition that is not boolean
   - a tuple or type restriction that names an undefined condition
   - Store the parameter types. Remove the `0A000` error `conditions_not_supported`.
4. **Evaluation.** Use typed parameters (the condition parameter types of OpenFGA). Merge the stored context of the tuple and the context of the request exactly as OpenFGA does. Find from the docs and the cases which side wins, and pin it with a spec.
   - A parameter that is not present raises 2000, as upstream does. A type mismatch does the same.
   - An evaluation error in one branch follows the same rules as other branch errors: it loses to a branch that decides.
   - `fga_write` validates the condition name and the context types of a tuple as OpenFGA does. Read returns the conditions with the tuple.
5. **Wire conditions into every evaluator.** These are `_fga_bidi`, `_fga_forward`, `_fga_backward`, `_fga_rec`, the set-based `but not` lists, ListObjects, ListUsers and contextual tuples.
   - A walk edge through a conditioned tuple is taken only when the condition evaluates true.
   - Keep the path without conditions as fast as it is now. Compare the timings of `fga_check` and ListObjects on the benchmark that exists, before and after the change. Tag the run.
6. Update [`designs/d-per-model.md`](./designs/d-per-model.md) (sections 2, 4, 7 and 8, deviation 2). Add a conditions page to the usage docs, with specs (for example expiry and IP range).

Files:
- `pg_permissions--0.0.1.sql`, [`designs/d-conditions.md`](./designs/d-conditions.md)
- `test/fga/vendor.sh` and `generate.py` (or similar scripts), `test/fga/upstream/abac_tests.yaml`
- `cases.json` (or a second JSON), `test/fga/skip.tsv`
- the generated specs `test/spec/d/6x_*`, and new in-house specs for the CEL expressions that the cases do not reach
- the usage docs (now in [`../docs/`](../docs/))

Done when:
- The abac suite passes fully in both runs (stored and contextual-tuple). Any skip has a listed reason.
- The consolidated suite is still 933/746.
- The mutants are caught. The mutants ignore the condition, treat a parameter that is not present as false, swap the context precedence, or skip the type check. Each mutant fails at least one assertion. Record the counts.
- `d/41_no_plan_time_eval` still passes (no plan-time evaluation).
- The full suite is green locally and on the docker matrix (PG 16, 17 and 18).

### Phase 5: performance pass 2

> Status: done (commits `0bd650b`, `482aab4`, `01b9fc2` and the write-up). The phase measured opt3 against a new "before" run, because phases 2 and 4 had changed the storage and write numbers of D after opt2. The runs were paired, on PG 18 in Docker ([`./benchmarks/D.md`](./benchmarks/D.md), opt3).
>
> What the phase changed, with the numbers:
> - Non-monotone ListObjects evaluate the rewrite tree over sets. Wide `but not (a or b)` went from 5,246 to 7.6 ms, and `a and b` from 621 to 6.1 ms.
> - Typed writes: 0.25 to 0.16 ms, and the large parents seed from 33 to 15 s.
> - A partial userset index for Check: `nest_check` went from 0.45-0.47 to 0.40 ms at medium.
> - The evaluator runs conditions one time for each distinct context, and an equality join matches them. Wide conditioned ListObjects went from 14.8 to 10.6 ms. With a context for each tuple, ListObjects went from 3.2 s to 0.17 s, and ListUsers from 29-37 s to 0.6-1.0 s.
>
> The phase rejected three changes, with measurements:
> - to fold the probe of Check (slower)
> - one tuplestore fewer, and `distinct` for the level group (8% or less)
> - a fix for userset cycles (3.3x, no exact alternative)
>
> It measured the covering index (+120 MB at large, no pgbench gain) and left the decision to the user. The user decided on 2026-11-01 not to adopt it (see [`./decision.md`](./decision.md), open question 11).
>
> The phase added benchmark phases for conditions and non-monotone relations (the `but not` workload moved in). It added the specs `d/42` (68 assertions) and `d/43` (199), and it caught every mutant. The checksums are identical to A, B and C, and the budgets did not change. The suite passed with 55 files and 3,604 assertions locally and on PG 16, 17 and 18. The OpenFGA suite passed 933/746, ABAC 302/271 and fga_lang 70/70.

Goal: close the hotspots that [`./benchmarks/D.md`](./benchmarks/D.md) lists ("Remaining gaps and hotspots"), and measure what conditions cost. Test everything before and after. Revert a change that does not pay, and write it up.

Candidates, from D.md and the journal:
1. **Check** is 1.3 to 1.4 times A. `_fga_bidi` runs too many statements in each round (two `_fga_bstep` calls, a probe and a meet test). This matters for per-row RLS (`fga_check_current` in an update policy).
   - The plan considered to fold the user probe into the step, but did not do it. The change alters the level count for userset users. The depth specs (`d/33`) and the OpenFGA depth cases guard that.
2. **Writes** are 1.5 to 1.7 times A. `fga_write_tuple` builds JSON that `fga_write` parses again and validates with six lookups. Add a typed write path (validate and insert without the JSON round trip) behind both.
3. **Wide ListObjects** (1.15 times A, 1.5 times C). The final leaf join does an index probe and a heap read for each tuple, because the user index has no `object_id`.
   - A covering index would make it index-only (-33% on large fan-outs, +120 MB at large). Decide on the numbers.
   - Look also at the sort-based `group by` that keeps the lowest level of each target, and at the three PL/pgSQL result tuplestores.
4. **Non-monotone paths** outside the set-based form (intersections, `but not (a or b)`, and a base that depends on a non-monotone relation). Each wide ListObjects takes about 2 s, because each candidate is checked top-down without memoization. Look for a set-based form for intersections and for a union of subtracts, or add memoization.
5. **Cyclic userset data.** The leveled walk expands a node again at each level, up to 25 levels. `_fga_forward_ids` (one row for each node) is the alternative. It needs data with cycles, and the benchmark has none. So add a cyclic shape or a side script first.
6. **Conditions** (phase 4). Measure what a conditioned edge costs in Check, ListObjects and ListUsers, against the same data without conditions.

Steps: pick the order by the numbers.
- For each change, write or extend a spec that pins the behavior. The specs that exist and the OpenFGA suite are the safety net. Add a mutant if the change adds a path.
- Implement the change. Run the whole suite (not at the same time as a benchmark).
- Benchmark one configuration at a time with a new tag (for example `opt3`) on PG 18 in Docker. Use large default, medium deep and medium wide, and all four designs for comparison where the earlier numbers exist.
- Move the `but not` ListObjects workload with the block list from the side script (`bench/designs/d/but_not_list_objects.sql`) into the pgbench workloads.
- Update [`./benchmarks/D.md`](./benchmarks/D.md) with a new section that compares opt2 and opt3 (and A, B, C). Include the budgets and `--check`. Update [`designs/d-per-model.md`](./designs/d-per-model.md), sections 5 and 10.

Done when:
- Each candidate above is done with numbers from before and after, or rejected with a measurement.
- The checksums are still identical across designs.
- The suite is green on the docker matrix.
- [`./benchmarks/D.md`](./benchmarks/D.md) has the opt3 section.
- The budgets in `bench/budgets.tsv` are checked again.

### Phase 6: loose ends

> Status: done (commit `68b65d5` and the docs commit). The phase measured small and medium default for the extension and for A, B and C on PG 18 in Docker (tag `p6`, reports `bench/baselines/pg18-docker-{d,a,b,c}-{small,medium,large}-default-p6.md`).
>
> The results for D:
> - D misses no budget at small or medium.
> - D is within 1.1 times the best design on reads at medium and large (1.0 to 1.4 times at small).
> - D is slowest on Check (0.37-0.38 ms against 0.25-0.34).
> - `parents_select_count` p50 is 0.40, 0.91 and 7.76 ms at small, medium and large, against 2.52, 6.26 and 69.89 ms for A.
>
> The large budget of `parents_proj_select_count` went from 9 to 20 ms for every design. The reason is a floor of heap reads (p50 7.5-9.4 ms, and a worst p95 of 16.1 ms over 27 large reports on PG 16-18). The full reason is in `bench/budgets.tsv` and in [`./benchmarks/D.md`](./benchmarks/D.md), Phase 6. `--check` at large passes for D (`p6check`).
>
> The lists in [`./decision.md`](./decision.md) ("What is not measured" and the open questions) are current. One item waited for the user (the covering index). The user closed it on 2026-11-01: do not adopt it. No SQL or bench script changed, so the test matrix did not run again.

1. **Run small and medium scale benchmarks in Docker** for the extension (and for A, B, C as comparison). Measure small and medium default shape after the optimizations. Nobody measured them before (see [`./decision.md`](./decision.md), "What is not measured"). Run one at a time, with a tag.
2. **Re-baseline the large `parents_proj_select_count` budget** in `bench/budgets.tsv`. It misses for every design (11.55 ms against 9 ms). The cause is a floor of heap reads on current Postgres patch releases, and no design can reach the budget.
   - Change the budget to a number that every design can meet, with a recorded reason. Do not make an exemption for one design.
   - Say so in [`./benchmarks/D.md`](./benchmarks/D.md) and in [`./decision.md`](./decision.md).
3. Close the open items in [`./decision.md`](./decision.md) ("What is not measured" and the open questions) that the work above settled, and record the other items.

Done when:
- The results for small and medium are committed under `bench/baselines/`.
- `--check` at large passes.
- The lists in [`./decision.md`](./decision.md) are current.

## Goal

The goal is one Postgres extension that can express more than one authorization model (RBAC, Zanzibar or FGA-style relationships, and later attribute rules). Then each application picks the model that fits, and does not install a different extension for each model.

The constraints are the same as in the rest of this repo:

- Pure SQL and PL/pgSQL. The extension installs as a Trusted Language Extension (`superuser = false`), and it is published on database.dev.
- Every check is usable inside RLS policies.
- The extension is not tied to Supabase. It works with Supabase out of the box, but nothing references the `auth` schema.

## 1. Review of the ideas that exist

There are four open RFC PRs in this repo. Each proposes a separate extension.

| PR | Extension | Model | Core storage | How it finds the current user |
| --- | --- | --- | --- | --- |
| #7 | `pg_zanzibar` | ReBAC (Zanzibar) | `tuples(object, relation, subject[#relation])` and `relation_configs(implied_by[])` | `auth.uid()`, then the `zanzibar.subject_id` setting |
| #8 | `pg_abac` | ABAC | `subject_attributes`, `policies`, `policy_rules(attr, op, value)` | the `abac.subject_id` setting, then `current_user` |
| #9 | `pg_cel` | CEL expressions and RBAC/ABAC helpers | Mostly stateless, with an optional `policies(expression)` | JWT claims (`request.jwt.claims`) |
| #10 | `pg_cedar` | Cedar (permit and forbid) | `entities(attributes jsonb)`, `entity_parents`, `actions`, `policies` | the `cedar.user_id` setting |

The four RFCs have these things in common:

1. **Each one invents identity again.** There are four different ways to answer "who is the current user?". One of them (#7) hard-codes `auth.uid()`, which fails on databases that are not Supabase.
2. **Each one invents "subject is related to object" again.** Zanzibar tuples, Cedar `entity_parents`, ABAC role assignments and group membership all have the same shape: `(object_type, object_id) --relation--> (subject_type, subject_id)`.
3. **They differ mainly in how they compute a decision.** The methods are:
   - a graph walk (Zanzibar)
   - attribute rules (ABAC)
   - expressions (CEL)
   - ordered permit and forbid rules (Cedar)
4. **They share the same RLS performance problem.** RFC #7 makes the important point. A `check()` for each row in a policy runs one time for each row. A function that lists the ids that the user can access, in `(select ...)`, runs one time for each query. This must be a first-class part of the API.

Superseded in part (session 4, see "Current plan"): the part about one way to model "subject is related to object". Each model has its own tables, and each follows its own spec. The identity and the RLS fast path stay shared.

Takeaway: whichever design we choose must have **one identity layer**, **one way to model "subject is related to object"** and a **first-class RLS fast path**. The designs in [`./designs/`](./designs/) do not agree on how to get there.

## 2. Proof-of-concept scope

Superseded (session 4): the first spike is `rbac_*` plus a core subset of OpenFGA (see "Current plan"). The idea "one extension, many models in one API" below no longer applies. The model descriptions and the exclusions of v0.0.1 are still a useful reference.

The first version must support these models in one extension. To implement two models that are really different proves the goal "one extension, many models". The examples below describe behavior, not storage. Each design decides how to store the data.

### Model 1: RBAC (global or per-tenant)

- Roles are scoped to a tenant or an org, or they are app-wide.
- Roles form a hierarchy: `owner` is above `admin`, and `admin` is above `member`. A permission such as `edit_documents` goes to one or more roles.
- Example: Alice is an admin of Acme, so she can edit every Acme document.

### Model 2: ReBAC / Zanzibar-lite (fine-grained)

- Relationships are for each object: Bob is an editor of the `readme` document.
- Relations on the same object imply other relations: `editor` implies `viewer`.
- Groups: every member of team `eng` is a viewer of `readme`.
- Groups nest, and the recursion has a maximum depth (default 10).

### Model 3 (stretch): attribute conditions

- Access depends on attributes of the subject, the resource or the request (for example "only published documents", or a grant that expires).
- v0.0.1 has no CEL parser.

### Explicitly out of scope for v0.0.1

- A CEL parser, Cedar `forbid` policies and the order of priorities. The design must show where they would fit.
- Parent inheritance ("viewers of a folder can view its documents"). This is the first item for v0.0.2, so the design must show how to add it.
- Zookies and replica consistency, audit logs, and caches.

## 3. Identity requirements

- The extension must not store users. It must not reference the `auth` schema.
- It must resolve the current subject without configuration on Supabase. PostgREST sets `request.jwt.claims`, and its `sub` claim is what `auth.uid()` returns. On plain Postgres, it must resolve the subject with an explicit session setting.
- The contract is fixed by `test/spec/01_identity.sql`.
  - `permissions.current_subject_id()` returns the JWT `sub` if it is present. Otherwise it returns the `permissions.subject_id` setting. Otherwise it returns null.
  - `permissions.current_subject_type()` defaults to `'user'`.
  - The JWT wins, so nothing else in a session can override the subject of a request that has a JWT.
- Variants with an explicit subject must exist for tests and server-side jobs. They must be **admin-only**. If clients could call them, any user could ask what any other user can access.
- Apps need a documented way to clean up permissions when a user is deleted from their identity table.

## 4. RLS requirements

- All checks are STABLE and safe to call from RLS policies.
- A fast path must exist for SELECT on large tables. It does not call a function one time for each row (for example a function that lists the accessible ids, in `(select ...)`). A simple per-row check must also exist for writes of single rows.
- Clients must not write permission data directly.
- **The RLS fast path is `col = any (array(select unnest(f())::uuid))`.** Three other ways to write it look right but are not. Postgres 16 with 1M rows measured all of them.
  - `col = any ((select f()))` is parsed as a subquery comparison. It fails with `operator does not exist`, also with double parentheses. The original Zanzibar RFC (#7) has this bug.
  - `col = any ((select f())::uuid[])` works, but Postgres applies the `::uuid[]` cast to the parameter again for each row that it filters. A page of 50 documents took 3.64 ms instead of 0.73 ms.
  - `col in (select unnest(f())::uuid)` (a hashed subquery) stops Postgres from the use of the index of the column. A count of the visible documents of a user took 88.8 ms instead of 2.2 ms.
- **Functions that RLS calls are STABLE. They have a dummy argument with a volatile default, so the planner cannot fold them.** The planner estimates the row count of `array(select unnest(f('x'))::uuid)`. For that estimate, it evaluates a STABLE `f` at plan time if all its arguments are constants. So every query ran the whole list function two times.
  - The numbers: the plan time of the medium wide sharing policy of A was 11.7-12.8 ms and 3,564 buffers. After the fix it is 0.22 ms and 112 buffers.
  - B went from 3.9 to 0.24 ms, and C from 3.2-3.4 to 0.27 ms.
  - The sources are design A (section 13.1), design B (Optimizations, steps 6 and 7) and design C (section 15.8).
  - Do not fix it by a VOLATILE mark on the function. Under read committed, a volatile function takes a new snapshot for each query that it runs. So the function can read grants at a later instant than the rows that it filters.
  - Add a last parameter. Its default is a VOLATILE function that returns null (`permissions._unfolded_null()`, granted to public because defaults run as the caller). The parameter is ignored. Callers use the short form. The function still reads the snapshot of the statement.
  - If a caller passes every argument as a constant, the call folds again. Boolean quals such as `has_permission` and `can`, and scalar subqueries such as `(select f())::uuid[]`, are not evaluated early.
  - Pin it with a spec. In the spec, `pg_proc.provolatile` is STABLE, and a call-count probe shows that `EXPLAIN` does not run the function (`test/spec/22_no_plan_time_eval.sql`).
- **Use `collate "C"` on text identifier columns** (ids, type names, relation names and role names). The default collation of the database (`en_SG.UTF-8` in the benchmarks) sent every B-tree comparison, join and `distinct` sort of a uuid-as-text through `strcoll`.
  - In B, this took medium wide `share_list_objects` from 24.5-25.3 to 6.8 ms and `nest_check` from 2.2 to 0.79 ms. In A, the wide sharing page went from 18.1 to 16.2 ms (design B, step 1; design A, section 13.1, item 2b).
  - Equality, the hash and `= any` do not change. Only the order of the returned arrays changes, so compare id lists as sets.
  - A recursive CTE needs `collate "C"` on its non-recursive term also. A `uuid` column needs nothing.
  - The `strcoll` of glibc on Linux is slower than that of macOS. So the gain must be larger in production (the Docker runs did not isolate this).
- **Write the hot functions that cannot be inlined in PL/pgSQL (Postgres 16).** A SQL function with a `SET` clause or `security definer` is never inlined. On Postgres 16, Postgres parses and plans its body again on every call. PL/pgSQL caches plans for each session.
  - In B, this took `rbac_check` from 0.39 to 0.29 ms and `nest_check` from 0.39 to 0.33 ms. It took 0.08-0.2 ms off each call of `_parent_keys` (design B, step 3).
  - In the Docker runs, the RBAC reads of B were 1.2-1.7 times faster on 16 and 17. They were 1.0-1.2 times faster on 18 (OPT, Other differences).
  - If Postgres plans the cached custom plans of a PL/pgSQL function again on every call, pin `plan_cache_mode = force_generic_plan` (B `can()` from 0.66 to 0.11 ms).
  - Mark as `materialized` the CTEs that the generic plan could turn into probes for each row (design A, section 13.1, item 3).
- **Give set-returning helpers a `rows` estimate.** The planner estimates a function scan at 1,000 rows. `_parent_keys()` of B returns about one row. But after `ancestors` had real statistics, the planner hash-joined a seq scan of it, and `can()` went from about 1.3 to 17-22 ms. `rows 1` restored the primary-key probe (`nest_check` 0.79 ms; design B, Weaknesses).
  - A view whose branch is a join needs the same care. Use `cross join lateral (... offset 0)`.

## 5. Reference scenario

Every design must show this scenario from start to end (schema, setup SQL, RLS policies), so that the designs compare side by side:

- Org `acme`. Alice is an `admin`, and Carol is a `member`. Admins can edit all documents of the org. Members can view them.
- A `documents` table with the columns `id uuid` and `org_id uuid`.
- Document `readme`: Bob (not in the org) is an `editor`. Team `eng` (members: Carol and Dave) are `viewer`s.
- `editor` implies `viewer`.
- The queries to answer: Can Bob update `readme`? Which documents can Dave select? Who can view `readme`?

## 6. Blessed path and model presets

Superseded (session 4): presets over one shared core are dropped. The blessed path is now the first-class `rbac_*` tables, and graduation adds `fga_*` next to them (see "Current plan").

Two rules no longer hold. The first rule says that both presets write to the same core data. The second says that the `rbac` preset API is identical in every design. The findings in [`./decision.md`](./decision.md) show why.

This section stays as history. The RBAC functions in the extension now have the prefix `rbac_` (for example `rbac_create_role`). See [`./decision.md`](./decision.md), "API naming (session 5)".

The extension must offer a **blessed path**. A developer picks a model preset, and learns only the concepts that this preset needs. Presets are a layer of functions on top of the design that we choose. A developer who stays on the RBAC preset never sees the design.

### Presets

| Preset | For | Concepts the developer learns |
| --- | --- | --- |
| `rbac` | Most apps: app-wide roles, optionally scoped to a tenant or org | Roles, permissions, scopes |
| `zanzibar` | Sharing for each object, groups, nested teams | Object types, relations, groups (the full API of the design) |

Later presets (attribute conditions, Cedar-style policies) follow the same pattern.

The rules for every design:

- **Both presets write to the same core data.** An app that starts on `rbac` and later needs sharing for each document adds the `zanzibar` functions. Nothing migrates. Its RLS policies get one more `or` branch.
- **The `rbac` preset API is identical in every design.** Only the implementation below it is different. This keeps the design replaceable. Backward compatibility with earlier drafts is not a concern.
- **Plain names.** A developer on the `rbac` preset never sees tuples, relations, policies, `via` or a model file.

### The `rbac` preset API

The ids of users and scopes are shown as `text`. A design with typed ids (Design C) uses `uuid`.

```sql
-- Define roles. A role grants permissions and can inherit the permissions of other roles.
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

This API is the original draft. The extension names these functions with the prefix `rbac_`.

The tests pin down this behavior (`test/spec/1x_*.sql`):

- `create_role`, `drop_role`, `assign_role` and `unassign_role` are admin-only.
- `has_role` is true for a role that the user holds directly or through inheritance (an editor "has" viewer).
- An unknown permission name or role name returns false and does not raise an error. So an RLS policy that names a dropped permission denies access, and does not break every query.
- `drop_role` fails when another role inherits it. It removes the assignments of the role.
- Role names and permission names cannot overlap.

**App-wide roles and scoped roles are separate.** `has_permission(p)` checks only app-wide roles. `has_permission(p, scope)` checks only that scope. An app that wants "app-wide admins can do anything in any tenant" writes both checks in its policy. This keeps the rule explicit: there is no hidden inheritance between scopes.

### RBAC scenario

Every design must also show this scenario. Write it **only** with the preset API above, and then show what happens below it:

1. **App-wide roles.** The roles are `viewer` (`documents.read`), `editor` (`documents.edit`, inherits `viewer`) and `admin` (`documents.delete`, `users.manage`, inherits `editor`). Alice is `admin`, Bob is `editor`, and Carol is `viewer`.
2. **RLS on `documents`.** SELECT needs `documents.read`, UPDATE needs `documents.edit`, and DELETE needs `documents.delete`.
3. **Tenant-scoped variant.** The roles are the same, but the assignment is for each org. Alice is `admin` of `acme`. Bob is `editor` of `acme` and `viewer` of `globex`. RLS uses `documents.org_id`.
4. **Graduation.** Later, the app shares one `acme` document with Dave (not in any org) as an editor, with the `zanzibar` preset. Show what changes in the data and in the RLS policies. Confirm that the RBAC data does not change.
5. **Queries.** Can Carol edit documents? What permissions does Bob have in `globex`? Who are the admins of `acme`?

## 7. Evaluation criteria

The criteria were written to choose one design. The row "Blessed path" refers to the superseded presets (section 6). The other rows still apply to the tables of each model.

| Criterion | Question |
| --- | --- |
| Model flexibility | How naturally does the design express RBAC, ReBAC, attributes, and later CEL and Cedar? |
| RLS performance | What is the cost of a SELECT over 1M rows, and of a check of one row? What are the read cost and the write cost? |
| Simplicity | How much SQL does an app developer write for the reference scenario? How much code is in the extension? |
| Blessed path | How cleanly does the `rbac` preset (section 6) map onto the design? Can an app graduate to `zanzibar` without a data migration? |
| Correctness and safety | Default deny, the rules for cycles, no dynamic SQL injection, and no escalation by clients. |
| Independent identity | The design meets section 3 without special cases. |
| TLE fit | Pure SQL and PL/pgSQL, no superuser, works through dbdev. |
| Evolvability | What is the cost to add parent inheritance, conditions, CEL and Cedar later? |

## 8. Candidate designs

Superseded as a choice (session 4): the three designs are measured history and bases for later work. A is the base for `fga_*`, B is the base for `cedar_*`, and the generic model of C is dropped. They are not candidates for one API. The numbers stay as the baseline for the benchmark of the spike (see "Current plan").

D, the fourth design, became the extension. See [`./designs/d-per-model.md`](./designs/d-per-model.md).

| Design | Approach |
| --- | --- |
| [A: Shared tuple core](./designs/a-tuple-core.md) | Zanzibar-style tuples in one generic table with `text` ids. A recursive CTE computes decisions at read time. |
| [B: Policy-first](./designs/b-policy-first.md) | A Cedar-style `policies` table decides everything. Roles, groups and parents are plain data. The write precomputes the closures of groups and roles. |
| [C: Compiled model](./designs/c-compiled-model.md) | The design compiles a JSON model into lookup tables. Triggers materialize the group membership. The ids are typed and `uuid`-only. |

All three are built ([`../prototypes/`](../prototypes/)), and they pass every goal in [`./goals.md`](./goals.md): A 18/18 spec files (199 assertions), B 18/18 (189), C 21/21 (229). They return identical visible-document sets for every read policy, at every scale, shape and Postgres version that the benchmark measured.

The numbers below are for the designs after the session 3 optimization pass. They come from [`./benchmarks/OPTIMIZATIONS.md`](./benchmarks/OPTIMIZATIONS.md). The runs were serial, on Postgres 18.6 in Docker, on one laptop, with 4 clients. The values are p50 at large, unless the text says otherwise. "Wide" and "deep" are medium-scale stress shapes.

The same matrix on Postgres 16 and 17 is in OPTIMIZATIONS.md and in [`VERSIONS.md`](./benchmarks/VERSIONS.md). The numbers from before the optimization (local Postgres 16.4) are in [`COMPARISON.md`](./benchmarks/COMPARISON.md).

### Comparison

The weaknesses section of each design has the details. This table summarizes them against section 7.

| Criterion | A: Tuple core | B: Policy-first | C: Compiled model |
| --- | --- | --- | --- |
| Model flexibility | The design has RBAC, ReBAC, parents, `user:*` and expiry. A forbid works only against the own tuple of a subject. Conditions are RLS composition. | The widest. Forbid (also with group principals) and conditions are policy shapes. The design evaluates them and compiles them into RLS. It refuses policies that cannot become SQL filters. | The design has RBAC and ReBAC with types like OpenFGA. A forbid is deny-overrides along the parent chain. Conditions are RLS composition. |
| Read cost | A pruned recursive walk. `share_select_page` 1.03 ms; 14.4 ms in the wide shape (was 125); 0.76 ms deep. | Flat joins. 1.00 ms; 17.8 ms wide (was 36.9); 0.72 ms deep. | Flat joins. 0.93 ms; 8.20 ms wide (was 10.2); 0.66 ms deep. |
| Write cost | One row for each grant. `write_nest_team` 0.15 ms. | Closure rows for inner nodes only, under a global lock: 0.62 ms (was 107; 4 clients). | Membership rows under a global lock: 57.7 ms (was 300; 4 clients, 67 tps). |
| Org-wide access through parents | Two-arm projection policy 1.33 ms; single-branch policy 45.6 ms (was 240). | 1.15 ms; 13.7 ms (was 102). | 1.05 ms; 4.94 ms (was 9.26). |
| Simplicity | One concept (tuples). 871 lines, 28 functions. | Two concepts (facts and policies). 1,810 lines, 57 functions. | One model file and grants. The most complex write path. 2,012 lines, 65 functions. |
| Blessed path (`rbac` preset, section 6) | The API and the answers are identical on all three. RBAC p50 is under 1 ms and within about 0.1 ms across designs. Thin wrappers. Roles are defined two times (`app`, `tenant`). Graduation adds an `or` branch. | One to one. Inheritance is `role_implies`, and permissions are actions. Generated policies carry `managed_by`. Graduation introduces policies. | One lookup, and no triggers for RBAC. Each `create_role` is a new model version. Graduation is one call of `apply_model()`. |
| Validation | Weak: relation names only. | Roles are declared for each type. | The strongest: typed subjects, and unknown names raise an error on write. |
| IDs | `text` (`collate "C"`), and an array cast to `uuid[]` in RLS. | `text` (`collate "C"`), cast to `uuid[]` in RLS. | `uuid` only, no casts. Other key types need a lookup table. |
| Concurrency | No locks. | One advisory lock for closure writes (held about 0.2 ms when it nests users). The design refuses `repeatable read` for them. | One global advisory lock for memberships and container moves. The design refuses `repeatable read`. |
| Drift risk | None: nothing is derived. | Closure tables can drift (triggers). There is no `verify`. A delete can drop a closure pair beyond depth 10 (open decision, [`./decision.md`](./decision.md)). | `memberships` can drift (`verify` and `rebuild` exist). |
| Familiarity | SpiceDB and OpenFGA. | Cedar. | OpenFGA. |

### What the three designs tell us

- **Precomputed group membership pays on reads. After the optimization, the price on writes depends on what the design precomputes.**
  - In the wide shape (50 teams for each user), `share_select_page` is 14.4 ms for A, 17.8 ms for B and 8.20 ms for C.
  - Three changes closed most of the gap of A (it was 125 ms, against 10.2 for C). They are the fix of plan-time evaluation, the removal of a `distinct` sort, and a walk that prunes paths.
  - A nest of a team with 1,000 members takes 0.15 ms for A, 0.62 ms for B and 57.7 ms for C.
  - B writes closure rows for inner nodes only. It does not write them for each document any more.
  - C still writes a membership row for each member and ancestor, under a global lock.
  - The reads of C are the fastest. Its write cost is the price.
- **The `rbac` preset works the same on all three designs.** The identical preset API (section 6) gives the same answers to the RBAC scenario. The latency is the same, within about 0.1 ms. Most apps stay on RBAC, and for them the design is invisible. The choice matters only for performance and for apps that graduate to sharing for each object.
- **How you write the RLS policy matters as much as the design.**
  - The two-arm projection (`id = any(<shared with me>) or folder_id = any(<folders I can view>)`) costs about the same as plain sharing, on every design.
  - The single-branch policy makes the design materialize every visible document id. At large this costs 45.6 ms for A, 13.7 ms for B and 4.94 ms for C. The projection costs 1.33, 1.15 and 1.05 ms.
  - The projection is still about 4.7 times cheaper for C. (Section 4 has the findings about policy forms.)
- **A and C have almost the same `zanzibar`-level API** (`grant` and `revoke`, check, list accessible ids, list subjects). C is close to "A with a typed model and a materialized membership index". The `zanzibar`-level API of B is different (policies and role grants). So that part is a choice to make at the start.
- **Most of the optimization lessons do not depend on the design.** They became the rules of section 4:
  - Do not let the planner fold STABLE list functions.
  - Collate text ids as `"C"`.
  - Use PL/pgSQL for hot functions that cannot be inlined on Postgres 16.
  - Give set-returning helpers a `rows` estimate.
- **The real decision is relationship-first (A and C) or policy-first (B).** For relationship-first, there is a second decision: pay a cost on write for speed on read, or not. Relationship-first is simpler, and FGA users know it. Policy-first is the only design with forbid on groups and conditions in the design. Its price is a second concept and a link between policies and RLS.

### How to decide

[`./decision.md`](./decision.md) is the decision guide. It has these parts: a scorecard against section 7, the cases where each design wins, and what the optimization pass taught. It also has hybrids that nobody tested, the open questions, and what is not measured. The raw numbers are in [`./benchmarks/OPTIMIZATIONS.md`](./benchmarks/OPTIMIZATIONS.md) (optimized designs), [`./benchmarks/VERSIONS.md`](./benchmarks/VERSIONS.md) (Postgres 16 to 18) and [`./benchmarks/COMPARISON.md`](./benchmarks/COMPARISON.md) (before the optimization).

## 9. Open questions (all designs)

1. **Schema name.** Is it `permissions`, or a name that is less likely to clash with app schemas? Also confirm how pg_tle and dbdev handle a fixed schema compared with `with schema extensions`. Status: the user decided on `permissions` at the end of session 4 (see [`./decision.md`](./decision.md), question 10).
2. **Who can grant?** Must the extension have a convention for who can grant what, or must it leave this to the app? Status: the convention stays as built. Writes are admin-only, and clients use the current-subject functions.
3. **Public access** (`user:*` in the terms of OpenFGA). Is it in v0.0.1 or later? All three prototypes built and tested it as G11 (section 10).

## 10. v0.0.2 goal scenarios

Each design implements these scenarios in its own native API, as spec files in `test/spec/<design>/`. The assertions are the same across designs, so the results compare one to one. All RLS assertions run as `authenticated`.

- **G10 Parent inheritance (`50_parents`).** Org `acme` is the parent of folder `specs`. Folder `specs` is the parent of document `readme` (documents have `id`, `org_id`, `folder_id`).
  - Org admins (Alice) can edit every document under the org. Org members (Carol) can view them.
  - Erin is a viewer of folder `specs`. She can view `readme`, but not the documents of other folders.
  - An RLS policy on `documents` expresses this **with a single fast-path branch** (no hand-written `or org_id = ...` arm).
  - The equivalent of `list_subjects` for `readme` and view includes Alice, Carol and Erin.
  - If you remove the folder grant of Erin, she loses access. If you move `readme` to another folder (a change of its parent), the set of users that inherit access changes.
  - Parent chains end on cycles.
- **G11 Public access (`51_public`).** Document `announcement` is viewable by every user (`user:*`).
  - A subject with no other data can view it, cannot edit it, and sees it in their list of viewable objects.
  - A request with no subject (null) gets a deny (default deny; anonymous access is out of scope).
  - If you revoke the public grant, everyone loses access.
- **G12 Forbid (`52_forbid`).** Dave is a viewer of `readme` through team `eng`, and Alice is an org admin.
  - A forbid or block on `readme` for Dave makes his check false. It removes `readme` from his object list and from the subject list of `readme`. The RLS SELECT no longer returns it.
  - A forbid on Alice for `readme` wins over her admin access that comes from a parent.
  - If you remove the forbid, access returns.
  - A forbid on one object does not affect other objects.
- **G13 Conditions (`53_conditions`).** Documents have `status` (`'draft'` or `'published'`).
  - Org members can view only published documents. Editors and admins can also view drafts.
  - A grant with `expires_at` in the past grants nothing.
  - The design expresses this as it prefers (policy condition, or RLS composition). The assertions use the results of RLS SELECT.
- **G14 TLE install (`03_tle_install`, shared).** The implementation installs as a non-superuser that owns the database (no features for superusers only, no C). If pg_tle is available, it installs through `pgtle.install_extension`. Otherwise the test checks only the non-superuser install, and says so in a diagnostic.
