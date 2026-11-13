# Documentation conventions

Write for a developer adding IDs to a Postgres application. Keep canonical Markdown in `docs/`; the site generates its routes and exports from `site/navigation.mjs`.

## Examples

Use lowercase SQL, schema-qualified calls under `extensions`, and named arguments where available. State installation and table prerequisites. Keep each runnable scenario together, mark fragments explicitly, and show stable results in comments. Do not present generated IDs as deterministic output.

## Reference

Give each exported function a signature, implementation behavior, **Guarantees:**, **Does not guarantee:** and a short example. Check claims against `pg_idkit--0.0.4.sql`. Distinguish reserved bit widths from entropy and intended timestamp precision from observed implementation behavior.

## Scope

Document current behavior. Never promise uniqueness without a constraint, cryptographic security from `random()`, strict monotonicity or exact timestamp recovery. Keep the canonical discussion of implementation limitations in `docs/errors-and-limits.md` and link to it from task pages.

## Publication

Run `npm run docs:build` from `pg_idkit/` after edits. The build checks rendered links, Markdown exports, navigation and coverage of the functions in the SQL source. Do not commit generated site pages or build output.
