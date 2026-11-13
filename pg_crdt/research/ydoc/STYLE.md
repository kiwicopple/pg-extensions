# Documentation conventions

Write for a developer who stores shared state in Postgres. Use plain English, precise technical terms, and enough context to make each example usable. Prefer natural sentences over rigid word limits or prescribed vocabulary.

The build journal in `research/journal.md` is a raw historical record. Do not edit it during documentation cleanup. Benchmark reports keep the harness format.

## Organize by the reader's task

- Start a task page with its outcome and prerequisites. Say which database role runs each kind of operation.
- Keep a complete scenario together. If it continues another page, link to that page and name the tables it needs.
- Distinguish runnable examples, fragments, and statements that intentionally raise errors.
- Give each concept one canonical explanation. Keep short reminders beside examples where a mistake could lose data or let a writer forge it.
- Keep current behavior in the guides and reference. Say plainly which types exist and which are planned; the plans live on the overview page and in Research.
- Keep the documentation generic Postgres. It must work with any client, driver or API layer. Name a platform (PostgREST, Supabase) only as one example of a mechanism, and never as the assumed setup.

## Write plainly

Lead with what the reader can do. Explain an unfamiliar term when the reader first needs it: for example, a delta carries changed entries, and a base is the version a form started from. Split sentences that mix setup, behavior and limitations into separate steps or paragraphs.

Use active voice when the actor matters. Keep paragraphs focused, and vary sentence length when it makes the explanation easier to read. Avoid announcing that a topic is important; explain what it does and when the reader needs it.

Use one term consistently for each concept:

- A *replica id* is the name of a writer. An *entry key* is a replica id, or `<replica id>:<device>`. The *owner* of a key is the part before the first `:`.
- *State* is a stored `crdt.pn` value. A *delta* is a state that carries only the entries a writer changed.
- *Merge* is the function that combines two states. *Apply* (`pn_apply_delta`) is merge for input from a writer you do not trust.
- A *trusted* writer is server code you run. An *untrusted* writer is a client that sends its own states or deltas.
- A *database role* is a Postgres role. Do not call a replica id a role or a user.

Use tables for signatures, options, error codes, and comparisons. Use numbered steps for a sequence. Put a warning immediately before the operation it applies to, with the specific consequence.

Do not turn measurements into guarantees. Keep the environment, workload, limitations, and source with the result, and say "in the benchmarks" or "on the benchmark machine". Do not rewrite quoted errors, identifiers, or values for style.

## Code examples

1. SQL examples must run on the current extension unless marked as fragments or expected errors. A fragment starts with a prose sentence that says it is one (for example, "This is a fragment: it needs the tables from the quickstart"). A statement that intentionally raises an error ends with the error as a comment, `-- ERROR:  ...`, with the text unchanged.
2. Use lowercase SQL keywords and one clause per line. Use named arguments (`replica => 'alice'`) when a literal would not explain itself, such as an amount or a replica id.
3. Put a call on one line when it has up to three short arguments. Otherwise put one argument per line with a two-space indent, and the closing parenthesis on its own line.
4. Aim for code lines of 72 characters or fewer. Long identifiers, URLs, output, and psql commands can exceed that limit when breaking them would be misleading.
5. Break long JSON and nested calls into readable blocks. Indent JSON by two spaces.
6. Show expected results as a comment after the statement (`-- 2`), or as the rows that psql prints when a result has several columns. Keep exact result and error text unchanged.
7. Break long shell commands with a trailing `\` and put flag groups on separate lines.
8. Qualify every extension object with `crdt.`. Do not add `crdt` to `search_path`.
9. Apart from the [JavaScript client](docs/reference/client.md) for collaborative text, pg_crdt has no client library, and the guides do not depend on it. Show an operation an application performs in two adjacent fences separated only by blank lines: `tab="JavaScript"` first and `tab="SQL"` last. JavaScript uses plain [node-postgres](https://node-postgres.com) (`pg`), calling `client.query(...)` on a connected client, with parameters (`$1`) and no string building, no semicolons, and single quotes. Use the same two labels in every guide so the site remembers the reader's choice. GitHub and the Markdown exports display every example in source order. Use a plain fence when an operation has only one form, and for pure SQL tasks such as installing, defining tables, and reference entries.
10. In JavaScript, construct a delta in a named constant before passing it to `client.query`. Show a result as a comment after the `console.log` (node-postgres returns `bigint` values as strings).
11. The JavaScript examples of one page run in order in a single module, so give every constant a new name, and say before a fence when it depends on one from an earlier example. Apart from that, every example needs only a connected `client`. Examples on different pages are independent.
12. Keep database definitions (tables, functions, grants) in SQL. Say who enforces a rule: a trusted backend, a database function, or row-level security. A check in a browser enforces nothing.
13. Use transaction-local identity settings (`set local`, or `set_config(..., true)`) in application examples.

## Reference entries

Each function has a heading with only its name, in backticks (`### \`pn_merge\``), then:

1. The signature in a `text` block, with argument names and defaults. It is not an example, so it is not run.
2. Returns, and the volatility and parallel labels.
3. Behavior, including how null is treated.
4. Privileges.
5. Errors, with SQLSTATE codes.
6. An example where it clarifies behavior.

Link to a guide for setup; do not require readers to execute the reference from top to bottom. Settings and constants go in tables, not under function headings: `site/scripts/check-content.mjs` requires one entry for each function in the extension file and no entry for a function that does not exist.

## Source and publication

Edit the canonical Markdown under `pg_crdt/`. The site generates its pages and plain Markdown exports from those files. `site/navigation.mjs` controls the source paths, routes, and sidebar. Research pages are listed in `research/navigation.json`; links from the guides to `research/` go to the research site.

When you change the SQL (a function, a default, an error), change the reference and the errors table in the same commit. `npm run docs:build` fails when a function or a SQLSTATE of the extension file is missing from them. See `site/README.md`.
