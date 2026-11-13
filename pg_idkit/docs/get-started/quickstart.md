# Quickstart

Create a table that assigns a UUIDv7 to each new row. First [install](../install.md) version 0.0.4 into `extensions`. Run these statements as a role that can create a table and call the extension functions.

## Create a table

```sql
create table notes (
  id uuid primary key default extensions.gen_random_uuid_v7(),
  body text not null,
  created_at timestamptz not null default clock_timestamp()
);
```

The primary key enforces uniqueness. `created_at` records an explicit application timestamp; it does not depend on decoding the ID.

## Insert and read

```sql
insert into notes (body)
values ('My first note'), ('Another note')
returning id, body, created_at;
-- Two rows, each with its own generated UUID.

select id, body
from notes
order by created_at, id;
```

Omit `id` to use the default. Supplying `null` does not invoke the default and fails the primary key's not-null constraint.

## Inspect the encoded time

```sql
select id, extensions.timestamp_from_uuid_v7(uuid_v7 => id)
from notes;
-- A timestamp without time zone, expressed in UTC.
```

The extracted time has whole-second precision in 0.0.4 and can differ from `created_at`. See [read timestamps](../guides/timestamps.md).

Next, [choose an ID](choose-an-id.md) or learn about [primary keys and pagination](../guides/primary-keys.md).
