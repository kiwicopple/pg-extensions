# Documentation and code conventions

Write for a developer who stores user input in Postgres. Use plain English, precise technical terms, and enough context to make each example usable. Prefer natural sentences over rigid word limits or prescribed vocabulary.

## Organize by the reader's task

- Start a task page with its outcome and prerequisites. Say which database role runs each kind of operation.
- Keep a complete scenario together. If it continues another page, link to that page and name the tables it needs.
- Distinguish runnable examples, fragments, and statements that intentionally raise errors.
- Give each concept one canonical explanation. The security model of the registry lives in `docs/registry.md`; other pages link to it.
- Keep current behavior in the guides and reference. Put plans in `docs/roadmap.md`, and label them as plans.

## Write plainly

Use active voice when the actor matters. Keep paragraphs focused. Avoid announcing that a topic is important; explain what it does and when the reader needs it.

Use one term consistently for each concept: a *validator* is a function; a *format* is a name in the registry; a *built-in* format is one the extension registers; a *custom* format is one an application registers. Distinguish the *extension owner* (the role that installed it) from the *owner of an entry* (the role that registered a format).

Use tables for signatures, options, error codes and comparisons. Use numbered steps for a sequence. Put a warning immediately before the operation it applies to, with the specific consequence.

## Reference entries

Each validator entry has, in this order:

1. The signature in a `text` block.
2. What it accepts, with the specification and section it follows, and what it deliberately does not accept.
3. **Guarantees:** what a `true` result lets the application rely on.
4. **Does not guarantee:** what the validator cannot know from the string, such as existence, ownership or deliverability, and the near misses a reader might expect it to catch.
5. An example where it clarifies behavior.

Validators check structure and encoding only. Never write that a validator checks that something exists, works or belongs to someone.

## Code examples

1. SQL examples must run on the current extension unless marked as fragments or expected errors. `test/spec/90_usage_*.sql` and `91_usage_*.sql` run the examples of the guides; update them together.
2. Use named arguments (`validate.email(value => ...)`), lowercase SQL keywords, and one clause per line.
3. Put multi-argument calls on multiple lines, with one argument per line and a two-space indent. Put the closing parenthesis on its own line.
4. Aim for code lines of 72 characters or fewer. Long literals, URLs and output can exceed that limit when breaking them would be misleading.
5. Show results as a comment after the statement: `-- true`. Keep exact error text unchanged.
6. Always qualify extension functions with `validate.`.

## SQL in the extension

- Lowercase keywords, four-space indentation, `$$` bodies, as in `pg_validate--0.0.1.sql`.
- Every function has `set search_path = ''` and qualifies every object, including `pg_catalog` functions whose names the extension reuses (`pg_catalog.format`).
- Mark a validator `IMMUTABLE STRICT PARALLEL SAFE` only when its result depends on its argument alone: no catalog lookups, no settings, no casts to time types, no collation-sensitive operations (`upper`, `lower`, `~*`, character classes such as `[[:alpha:]]`). Use explicit ASCII ranges and `translate()`.
- Do not write backslashes in string literals: the meaning of `'\.'` depends on `standard_conforming_strings`. Use bracket expressions (`[.]`) or `chr(92)`.
- In PL/pgSQL, parenthesize a `case` expression inside an `if` condition: the condition ends at the first `then`.
- Cite the specification and section in a comment above each validator.
- Nothing is `SECURITY DEFINER`.

## Source and publication

Edit the canonical Markdown under `pg_validate/docs/`. The site generates its pages from those files; `site/navigation.mjs` controls the source paths, routes and sidebar. See `site/README.md`.
