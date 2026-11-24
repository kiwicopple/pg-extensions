# ULID generator

### `gen_random_ulid`

```text
extensions.gen_random_ulid() → text
```

Added in 0.0.5; requires Postgres 13 or later. Returns a [ULID](https://github.com/ulid/spec): 10 Crockford base32 timestamp characters followed by 16 random characters. The uppercase alphabet is `0123456789ABCDEFGHJKMNPQRSTVWXYZ` and the first character is `0` through `7`.

Samples `clock_timestamp()` once and floors the complete Unix millisecond value into a 48-bit field. The 80-bit payload comes from one built-in `pg_catalog.gen_random_uuid()` call, selecting bytes that contain neither UUID version nor variant bits. No pgcrypto dependency is required. The function is volatile and does not keep state between calls.

**Guarantees:** a 26-character canonical ULID with a millisecond timestamp and 80 bits drawn from Postgres's strong random source. With byte-order collation, IDs with different encoded timestamps sort by those timestamps. An out-of-range timestamp raises SQLSTATE `22008` rather than wrapping.

**Does not guarantee:** uniqueness, order within the same millisecond, insertion or commit order, or monotonicity when the clock moves backward. The timestamp is public; use a dedicated token generator for secrets. Keep a primary key or unique constraint. See [errors and limits](../errors-and-limits.md).

After [installing](../install.md) 0.0.5 into `extensions`, run as a role allowed to create tables and call its functions:

```sql
create table ulid_events (
  id text collate "C" primary key default extensions.gen_random_ulid(),
  created_at timestamptz not null default clock_timestamp(),
  body text not null
);

insert into ulid_events (body) values ('first event'), ('second event');
select id, length(id) from ulid_events order by id;
-- Each generated ID is 26 characters. Values vary between calls.
```

Use `text collate "C"` for byte-order comparisons. Text columns also accept arbitrary caller-supplied values; this generator does not add a ULID type or a validation constraint. There is no ULID parser, timestamp extractor or UUID conversion function in this release.
