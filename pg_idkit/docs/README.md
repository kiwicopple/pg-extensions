# pg_idkit documentation

Generate IDs inside Postgres and use them as table defaults. These docs describe the SQL shipped in version 0.0.4.

| Task | Read |
| --- | --- |
| Understand the extension | [Overview](overview.md) |
| Load the functions | [Install](install.md) |
| Create your first table | [Quickstart](get-started/quickstart.md) |
| Compare UUIDs and KSUIDs | [Choose an ID](get-started/choose-an-id.md) |
| Add defaults, constraints and pagination | [Primary keys](guides/primary-keys.md) |
| Extract a UUIDv7 timestamp | [Read timestamps](guides/timestamps.md) |
| Look up UUID functions | [UUID generators](reference/uuid.md) |
| Look up KSUID functions | [KSUID generators](reference/ksuid.md) |
| Look up the timestamp function | [Timestamp extraction](reference/timestamps.md) |
| Understand failures and guarantees | [Errors and limits](errors-and-limits.md) |

Examples use the `extensions` schema, lowercase SQL and named arguments where functions accept arguments. Run each task page in order; generated values vary between calls.
