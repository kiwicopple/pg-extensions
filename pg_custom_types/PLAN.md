# `pg_custom_types` — Planning Document

**Status:** draft, awaiting approval. Nothing in this extension is implemented yet — this
document only proposes *candidate* types. Once specific types are approved below, each will
be implemented as a versioned TLE (same pattern as `countries`, `pg_idkit`, `is_even`/`is_odd`)
in a follow-up stage.

## Goal

Postgres is missing a lot of small, commonly-needed data types that people currently fake with
`text` + application-side validation, or pull in a heavyweight extension (PostGIS, `citext`,
`pgcrypto`) for. Since this repo publishes Trusted Language Extensions (TLE) to database.dev,
we can ship these as lightweight, dependency-free, `superuser = false` extensions that anyone —
including on locked-down managed Postgres — can install with `create extension`.

This document lists candidate types, grouped by how they'd actually be built under `pg_tle`'s
constraints, so we can approve a shortlist before writing any SQL.

## What `pg_tle` actually lets us build (research summary)

Source: [`aws/pg_tle` docs/09_datatypes.md](https://github.com/aws/pg_tle/blob/main/docs/09_datatypes.md),
`pg_tle` README, PostgreSQL 1.1.1 release notes.

TLE install scripts run as plain SQL under `pgtle_admin` (no C, no superuser). That gives us
three tiers of type, in increasing order of effort:

1. **Domains** (`create domain foo as text check (...)`) — free-form validation on top of an
   existing type (text, numeric, etc). No special API needed; this is exactly what the `pg_tle`
   docs themselves demonstrate (`create domain http_method as text check (...)`). Cheapest,
   most portable option — this is the same tier as our existing `countries.continents` enum.
2. **Composite types & enums** (`create type foo as (...)` / `as enum (...)`) — also plain SQL,
   no special API. Good for structured values (e.g. an amount + currency pair) where a bare
   scalar domain isn't enough.
3. **True base types**, via `pg_tle`'s own SQL API (added in `pg_tle` 1.1.1) — this is the
   interesting one, since normal Postgres base types require C and superuser:
   - `pgtle.create_shell_type(typenamespace, typename)`
   - `pgtle.create_base_type(typenamespace, typename, infunc, outfunc, internallength, ...)`
     — `infunc`/`outfunc` must be `immutable strict`, `text -> bytea` / `bytea -> text`. Can be
     written in plain SQL/PL/pgSQL. Internally the value is stored as `bytea`.
   - `pgtle.create_operator_func(...)` to give it operators.
   - Caveat: adding a full **operator class** (needed for `btree`/`hash` indexing, `order by`,
     `distinct`) still requires superuser *except on Amazon RDS* — unclear yet whether Supabase's
     `pgtle_admin` role covers this. **Open question to verify before committing to any
     "true base type" candidate below** — flagged per-item.
   - Base types created this way are scoped to a single database (not shareable across a
     cluster like a real C base type).

Range types are plain SQL as well (`create type foo as range (subtype = ...)`) and should behave
like domains/composites for our purposes, though we don't have a worked example from the docs.

## Conventions to follow when we build these (from the existing extensions in this repo)

- One folder per extension, e.g. `pg_custom_types/`.
- `<name>.control` — `comment`, `default_version`, `superuser = false` (matches every existing
  extension here; needs re-checking per-item if it turns out to need an operator class).
- `<name>--X.Y.Z.sql` version file(s), `\echo Use "CREATE EXTENSION <name>" to load this file. \quit`
  guard at the top (see `countries`).
- `<name>--OLD--NEW.sql` upgrade scripts when bumping versions (see `countries--0.0.1--0.0.2.sql`,
  `pg_idkit--0.0.1--0.0.2.sql`), not rewriting the base file.
- `README.md` per extension: short description, function/type list, `dbdev install` /
  `create extension` usage, credits if code is adapted from elsewhere.
- MIT license header with attribution when porting someone else's algorithm (see `pg_idkit`'s
  header crediting Fabio Lima).
- Add `tle.install.<name>` to the root `Makefile`'s dependency list and a `dbdev.publish.<name>`
  target follows automatically from the existing `%` pattern rule.
- Whimsical/utility tone is fine (`is_even`/`is_odd` exist purely for fun/demo purposes) —
  doesn't all have to be "serious."

## Candidate types

Legend — **Tier**: 1 = domain, 2 = composite/enum, 3 = true base type (via `pgtle.create_base_type`).
**Effort**: S/M/L. ⚠️ = depends on the operator-class/superuser open question above.

### A. Validated identifier domains (Tier 1 — cheapest, highest immediate value)

| # | Type | Fills the gap of... | Effort |
|---|------|---------------------|--------|
| 1 | `email` | No built-in email type; everyone hand-rolls a regex `CHECK` | S |
| 2 | `url` / `uri` | No built-in URL validation/type | S |
| 3 | `slug` | URL-safe identifier (`^[a-z0-9]+(-[a-z0-9]+)*$`) | S |
| 4 | `hostname` | DNS-valid hostname (RFC 1123) | S |
| 5 | `phone_e164` | E.164 international phone number format | S |
| 6 | `iban` | IBAN bank account number, incl. mod-97 checksum | M |
| 7 | `swift_bic` | SWIFT/BIC bank identifier code format | S |
| 8 | `isbn` | ISBN-10/13 book identifier incl. check digit | M |
| 9 | `ean_upc` | EAN-13/UPC-A barcode incl. check digit | M |
| 10 | `credit_card_number` | PAN format + Luhn checksum (format-only, no PCI storage guidance) | M |
| 11 | `hex_color` | `#rrggbb`/`#rgb` CSS color validation | S |
| 12 | `natural` / `non_negative_int` | int4 domain rejecting negatives — common hand-rolled `CHECK` | S |
| 13 | `percentage` | `numeric` domain constrained to `0–100` (or `0–1` variant) | S |
| 14 | `semver` (domain flavor) | SemVer 2.0 string validation only (no ordering) — simplest version of #24 | S |

### B. Enum-backed reference types (Tier 2)

| # | Type | Fills the gap of... | Effort |
|---|------|---------------------|--------|
| 15 | `http_method` | GET/POST/PUT/PATCH/DELETE/... — literally `pg_tle`'s own doc example | S |
| 16 | `iso4217_currency` | 3-letter ISO 4217 currency codes | S |
| 17 | `iso639_language` | 2-letter ISO 639-1 language codes | S |
| 18 | `weekday` | Monday–Sunday enum (no built-in weekday type) | S |
| 19 | `http_status_class` | 1xx/2xx/3xx/4xx/5xx classification enum for a status code | S |

*(Note: ISO 3166 country codes are arguably already covered by the existing `countries` extension's
`continents` enum + table — could extend `countries` instead of duplicating here.)*

### C. Composite (structured) types (Tier 2)

| # | Type | Fills the gap of... | Effort |
|---|------|---------------------|--------|
| 20 | `money_currency` | `(amount numeric, currency iso4217_currency)` pair with `+`/`-` operators guarding currency mismatch | M |
| 21 | `geo_point` | Lightweight `(lat, lng)` point, for people who don't want a full PostGIS dependency | M |
| 22 | `dimension` | `(value numeric, unit text)` generic measurement (length/weight/volume) | M |
| 23 | `temperature` | `(value numeric, scale enum('C','F','K'))` with conversion helper functions | M |
| 24 | `semver` (composite flavor) | `(major, minor, patch, prerelease, build)` with real `<`/`>`/`=` comparison operators for correct SemVer sort order (upgrade path from #14) | L |
| 25 | `full_address` | Generic `(line1, line2, city, region, postal_code, country)` composite for reuse across schemas | M |

### D. True base types via `pgtle.create_base_type` (Tier 3 — showcases the advanced API) ⚠️

| # | Type | Fills the gap of... | Effort |
|---|------|---------------------|--------|
| 26 | `ci_text` | Case-insensitive text — alternative to core `citext` contrib for environments that can't install it (this is literally `pg_tle`'s own worked example, so lowest-risk Tier-3 candidate) | M ⚠️ |
| 27 | `roman_numeral` | Roman numeral literals with arithmetic — playful, in the spirit of `is_even`/`is_odd` | M ⚠️ |
| 28 | `ulid` | Proper sortable/indexable ULID type (complements `pg_idkit`'s existing `gen_random_uuid_v7()`/KSUID *functions* with an actual comparable *type*) | L ⚠️ |
| 29 | `base62_id` | Base62-encoded integer ID type, shorter than UUID for URLs | M ⚠️ |

### E. Range types (Tier 1/2, least explored — no worked example from `pg_tle` docs yet)

| # | Type | Fills the gap of... | Effort |
|---|------|---------------------|--------|
| 30 | `time_of_day_range` | A `range` over `time`, supporting wrap-around "business hours" style windows (e.g. 22:00–02:00) | M |

## Open questions before implementation starts

1. **Operator classes on Supabase**: does Supabase's `pgtle_admin` grant cover creating an
   operator class (needed for indexing/sorting any Tier-3 type), or is that blocked the way plain
   superuser-only `CREATE TYPE` is? This determines whether items 26–29 are actually buildable
   with `superuser = false`, or need to be descoped to "no native sort/index" versions.
2. Do we want to fold ISO-4217/639 country-style reference types into the existing `countries`
   extension instead of a new one, for consistency with how that extension already models
   `continents` as an enum + lookup table?
3. Naming: is `pg_custom_types` the right umbrella extension name for all of these, or should
   higher-effort/independent types (e.g. `ci_text`, `ulid`, `semver`) ship as their own
   standalone extensions (one `.control` per type) the way `is_even`/`is_odd` are split rather
   than merged? Recommendation: split — each type as its own extension/folder, so consumers
   aren't forced to install types they don't need. This doc's "pg_custom_types" folder is just
   the planning home; actual implementation folders would be named per type (e.g. `pg_ulid`,
   `pg_semver`, `pg_ci_text`).

## Next steps

Once you pick which of the ~30 candidates above to greenlight (all, a subset, or a different
prioritization), the next stage will, per approved type:

1. Confirm the Tier-3 operator-class question against a real Supabase/local `pg_tle` instance.
2. Create `<extension_name>/` with `.control`, `--0.0.1.sql`, and `README.md` following the
   conventions above.
3. Add it to the root `Makefile`'s `tle.install` dependency list.
