# Plan: the Cedar model (`cedar_*`)

Status: planned 2026-11-02. Nothing implemented. This file is the source of truth for the implementation sessions; each phase brief must link here.

## Goal

Add a third model to pg_permissions that follows [Cedar](https://www.cedarpolicy.com) 4.x as closely as possible, in plain SQL and PL/pgSQL. It sits beside `rbac_*` and `fga_*` and shares only the toolkit: subject identity, `_unfolded_null`, `_did_you_mean`, grants, `delete_subject`, and the install and pg_tle plumbing. Models compose in RLS as before: permissive policies combine with OR, restrictive policies with AND.

Prior decisions this plan follows:

- `research/decision.md:38`: "Cedar is for later (`cedar_*`), with B as the base", "a documented subset, tested against the Cedar corpus".
- `research/architecture.md:25`: a new model needs its own API, compatibility statement, tests and RLS guidance.

## Decisions (2026-11-02, user)

1. **Error semantics.**
   - `cedar_is_authorized` follows Cedar exactly. A policy that errors is skipped and reported in `errors`; forbid overrides permit; the default is deny.
   - The current-subject and RLS helpers **fail closed**: if any applicable `forbid` errors, they return false.
   - This divergence is documented, like FGA's "deny when context is missing" rule.
2. **Scope: full Cedar 4.x.**
   - Every scope form (`==`, `in`, `is`, `is ... in`, and the slots `?principal` and `?resource`).
   - Every operator and method, `like`, `has`, `if-then-else`, sets and records.
   - Entity tags (`hasTag`, `getTag`) and annotations.
   - Long with overflow errors.
   - The extension types `decimal`, `ipaddr`, `datetime` and `duration`.
   - Policy templates and template links.
   - Both policy formats, Cedar text and JSON (EST).
   - Out of scope: schema validation and partial evaluation (see "Not in v1").
3. **Where resources come from in RLS: stored entities plus a row overlay.**
   - Principals, groups and the hierarchy live in `cedar_entities`; the app syncs them, the way it syncs FGA tuples.
   - An RLS policy may also pass row attributes (`resource_attrs => jsonb_build_object(...)`), so the app does not have to copy every row.
   - `cedar_list_resources_current` works over stored entities only.
4. **Versioning.**
   - Ship as `pg_permissions--0.1.0.sql`.
   - Add the upgrade script `pg_permissions--0.0.1--0.1.0.sql`. The change is additive: the Cedar block, plus a new `delete_subject` and new grants.
   - Add a pg_tle update path (`pgtle.install_update_path`) and a test for it.
   - The JS library updates its compatibility table.

## Research inputs

- **The oracle.** [cedar-integration-tests](https://github.com/cedar-policy/cedar-integration-tests) holds about 7,500 corpus files and about 60,000 requests (verify the counts). Each file carries `policies`, `policyFormat` (cedar or json), `entities`, `schema`, `shouldValidate`, and `requests[]` with the expected `decision`, `reason[]` and `errors[]`. It is regenerated for every Cedar release, and cedar-go and luxas/cedar-sql both use it. Pin one Cedar release, as `test/fga_abac` pins OpenFGA.
  - We ignore `shouldValidate` and the schema: we do not validate, and Cedar does not need a schema to decide a request.
  - The schema matters in one place. Entity JSON can hold extension values without `__extn` wrappers when a schema gives the types. Decide in phase 0 whether to read the schema for that purpose only, or to skip such cases and record them.
- **Semantics to get exactly right:**
  - Long overflow raises an error, never wraps.
  - `&&` and `||` short-circuit, but an error on the side that is evaluated still counts.
  - `in` is reflexive and transitive.
  - Comparing values of different types with `==` gives false, not an error.
  - `like` uses `*` with `\*` as an escape.
  - The `decimal` type has 4 fractional digits and a fixed range.
  - `ipaddr` covers v4 and v6, with CIDR and range methods.
  - `datetime` and `duration` follow RFC 80 (`offset`, `durationSince`, `toDate`, `toTime`, and the duration conversions).
- **Prior art:**
  - cedar-go: same subset idea, nightly corpus runs, and an allow-list of divergences.
  - luxas/cedar-sql: Cedar to SQL through type-aware partial evaluation. Not production. Uses `CASE` to keep short-circuits, and NULL for errors.
  - Cedarling's Postgres design: a per-row `authorized(resource_data, tokens)` from RLS.
- **Reuse from this repo:**
  - From the CEL engine (`pg_permissions--0.0.1.sql` ~1079-2900, `research/designs/d-conditions.md`): the tokenizer shape, precedence-climbing parser, jsonb syntax tree, errors as values, and cost counter. Also the helpers for IP, timestamp and duration, `_edit_distance` and `_did_you_mean`.
  - From prototype B (`prototypes/b-policy-first.sql`, `research/designs/b-policy-first.md`): the policy table, forbid-wins logic, and `in` closures. Also its planner lessons: `force_generic_plan`, `rows` on set-returning helpers, no views that join in a recursive part, and no `VOLATILE`.
  - From FGA: `_current` helpers that return false or empty and never raise, the plan-time guard, and the oracle harness (`vendor.sh`, `generate.py`, `skip.tsv`, `cases.json`, generated specs).

## Design

### Tables (owner only; clients get no table privileges)

- `cedar_policies`: `policy_id`, `effect`, `source` (the text as written, if any), `est jsonb` (the checked syntax tree), `annotations jsonb`, and extracted scope columns for indexing: principal constraint kind and value, the action set, and resource type and constraint. Template-linked policies point at their template.
- `cedar_templates` holds `template_id`, `source` and `est`. `cedar_template_links` holds `policy_id`, `template_id` and the slot values.
- `cedar_entities`: `type`, `id` (text, `collate "C"`), `attrs jsonb`, `tags jsonb`.
- `cedar_entity_parents`: one row per entity and parent.
- **The ancestor structure for `in`** is decided by a phase-2 measurement. The options are a closure table maintained on write, which needs care for B's global-lock problem, or a recursive lookup with an index. Use the faster one that has no global lock.

Policies are parsed and checked **once, at write time**, into jsonb. Checks never parse. Cedar text parses to the same EST the JSON format uses, so there is one evaluator.

### API

All functions take named arguments. Admin functions are owner or trusted-role only; the `_current` helpers are granted to PUBLIC.

| Function | Returns | Notes |
|---|---|---|
| `cedar_put_policy(policy_id, policy text default null, policy_json jsonb default null)` | void | Give exactly one of the two. Upsert. Parse errors raise `cedar:parse_error` with a line, a column and a HINT. |
| `cedar_delete_policy(policy_id)` | void | |
| `cedar_policies()` | table(policy_id, effect, source, est, annotations) | |
| `cedar_put_template(template_id, template text default null, template_json jsonb default null)` | void | |
| `cedar_link_template(policy_id, template_id, principal text default null, resource text default null)` | void | Fills the slots. |
| `cedar_delete_template(template_id)` | void | Raises if links exist. |
| `cedar_put_entities(entities jsonb)` | void | Cedar entity JSON array (uid, attrs, parents, tags). Upsert. |
| `cedar_delete_entities(uids jsonb)` | bigint | |
| `cedar_read_entities(type text default null, ids text[] default null)` | jsonb | |
| `cedar_is_authorized(principal, action, resource, context jsonb default null, entities jsonb default null)` | jsonb `{decision, reasons, errors}` | Exact Cedar semantics. `entities` overlays the stored entities. |
| `cedar_is_authorized_current(action, resource, resource_attrs jsonb default null)` | boolean | PUBLIC. The principal comes from `current_subject_type()` and `current_subject_id()`. No context. Fails closed. Plan-time guard. |
| `cedar_list_resources_current(action, resource_type)` | setof text (ids) | PUBLIC. Stored entities only. Uncapped. `rows` estimate. Fails closed. |

- **UIDs.** Arguments use Cedar's `Type::"id"` text. Namespaced types (`App::User`) are supported.
- **The principal type in the `_current` helpers.** By default it is `current_subject_type()` as written. Phase 0 decides whether to add a setting that maps it, for example `user` to `User`, because Cedar style uses capitalized types.
- **Errors.**
  - API and argument errors raise with DETAIL `cedar:<code>[ key='value' ...]`, a MESSAGE that names the values, and a HINT (with "Did you mean" where it helps). The codes include `parse_error`, `unknown_policy`, `unknown_template`, `template_in_use`, `invalid_entity`, `invalid_uid`, `null_argument`, `limit_exceeded`, and similar.
  - Evaluation errors never raise. `cedar_is_authorized` reports them in `errors` as `{policy_id, message}`.
- **Limits.** These are fixed and documented, chosen in phase 0 against the corpus: the policy text size, the expression nesting depth, a per-request evaluation cost counter (as in CEL), the entities per `put` call, and the entities per request overlay.

### RLS performance

- Index policies by (action, resource type).
- Once per statement, pre-filter policies whose principal scope can match the current subject, and cache the result for the statement.
- Per row, evaluate only the conditions that remain.
- Measure with a new benchmark design (`bench/designs/e-cedar/`) at small, medium and large scale and the existing shapes. Add budgets to `bench/budgets.tsv` using the normal rule: 3x the fastest reference p95, re-baselined only with a documented reason.
- Compiling policies to SQL predicates is not in v1.

## Phases

Each phase is one or more agent briefs. Benchmarks run one at a time with `--tag`. Commit per milestone and never push without the user.

| # | Phase | Done when |
|---|---|---|
| 0 | **Oracle and design.** Vendor the corpus into `test/cedar/` (`vendor.sh` pinned to one Cedar release, `generate.py`, `skip.tsv`). Count cases by policy format and by feature. Write `research/designs/e-cedar.md`, which fixes the EST shape, the value model, the error model, the limits, the principal-type mapping and the schema-for-extensions question. | Counts are recorded and the user agrees the design doc. |
| 1 | **Shared toolkit.** Rename the CEL helpers Cedar reuses (IP, timestamp, duration, edit distance) to neutral names, then move the toolkit into a shared section. | The full suite is unchanged: 56 files, 3,650 assertions, PG 16/17/18. |
| 2 | **Core evaluator.** Tables; entity JSON ingestion; the ancestor structure (measure both options); the EST evaluator for core types and operators, `is`, `like`, `has`, tags, sets and records; Long overflow; the authorization algorithm with reasons and errors. | The oracle passes every JSON-format case with core features only. |
| 3 | **Text parser.** Cedar text to EST: comments, string escapes including `\u{...}`, `like` patterns, annotations, and `cedar:parse_error` with a position and a HINT. | The oracle passes every text-format case with core features only. |
| 4a | **decimal and ipaddr**, including every method. | The corpus cases for these pass. |
| 4b | **datetime and duration** (RFC 80). | The corpus cases for these pass. |
| 4c | **Templates and links.** | The corpus template cases pass, and the skip list holds only documented, schema-only cases. |
| 5 | **RLS.** The `_current` helpers, fail-closed forbids, the resource_attrs overlay, the policy index and principal pre-filter, the plan-time guard, and `list_resources`. Benchmark design, seeds, workloads and budgets. | Specs pass, benchmarks meet their budgets, and any miss is documented with a reason. |
| 6 | **Integration and release.** The `delete_subject` hook; grants; the naming (`04`) and security (`02`) specs; error-hint coverage (`35`); the 0.1.0 file, the upgrade script and the pg_tle update path; the PG 16/17/18 matrix. | The matrix passes, and both the 0.0.1-to-0.1.0 upgrade and a fresh install pass the same suite. |
| 7 | **JS client.** `CedarClient` with the current-subject methods `isAuthorized` and `listResources`, and an `admin` namespace (SQL transport only) for policies, templates, entities and full requests. The `./cedar` subpath, `CedarErrorReason`, and unit and integration tests. | `js:check` passes and the integration tests pass. |
| 8 | **Docs.** `docs/models/cedar/*`; `docs/reference/cedar.md`; the compatibility statement (pinned Cedar release, supported subset, corpus pass rate, divergences); RLS guidance; SQL and JavaScript tabs; `90_usage_cedar.sql`; updates to choose-a-model, errors, limits and `site/navigation.mjs`; the journal entry. | The site builds and the doc examples run as tests. |
| 9 | **Review.** An independent review that covers security (definer functions, grants, injection, and fail-closed behaviour) and correctness against the corpus. | All findings are fixed or accepted by the user. |

The order:

- Phases 2 and 3 can overlap once phase 0 fixes the EST shape.
- Phases 4a, 4b and 4c are independent of each other.
- Phase 7 can start once phase 5 fixes the API.

## Not in v1

- Schema validation, meaning strict type-checking of policies (cedar-go also ships this as experimental).
- Partial evaluation, type-aware partial evaluation, and compiling Cedar to SQL. Revisit these if phase 5 benchmarks require it.
- Request context from untrusted clients in the `_current` helpers.

## Risks

- **Evaluator cost.** The CEL interpreter evaluates in about 2-3 µs. A Cedar policy set evaluated per row could dominate RLS cost. The phase 5 pre-filter is the main answer, and compiling to SQL is the fallback.
- **Ancestor writes.** A closure table was B's weak point: it needed a global lock. Phase 2 measures before choosing.
- **Corpus size.** About 60,000 requests may make the generated specs slow. Group cases per file, and keep the generator's output deterministic.
- **The extension types.** RFC 80 datetime arithmetic and decimal range checks are fiddly; the corpus is the judge.
