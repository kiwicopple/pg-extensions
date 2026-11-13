# Use IDs as primary keys

Use a column default to generate IDs and a primary key to enforce uniqueness. Install the functions into `extensions` first and run these examples as a table owner.

## UUID defaults

```sql
create table projects (
  id uuid primary key default extensions.gen_random_uuid_v7(),
  name text not null
);

insert into projects (name)
values ('Documentation')
returning id;
```

The default only applies when the ID is omitted or explicitly set to `default`. Callers can supply their own UUID, including another UUID version. A `uuid` column does not enforce version 7.

## KSUID defaults

```sql
create table events (
  id text collate "C" primary key
    default extensions.gen_random_ksuid_second(),
  body text not null
);

insert into events (body)
values ('Project created')
returning id;
```

Use the same text type and collation in referencing columns. A text column does not validate caller-supplied KSUIDs; its default only generates a value when needed.

## Change an existing default

If an existing table already has a UUID primary key, its owner can change the default without rewriting existing IDs. This example continues the `projects` table above:

```sql
alter table projects
alter column id set default extensions.gen_random_uuid_v6();
```

Changing a text key to a UUID key is a separate migration. Existing values and foreign keys need a mapping; a new default does not convert them.

## Ordering and pagination

`order by id` gives deterministic ID ordering, not creation or commit ordering. For a page ordered by application time, store a timestamp and use `(created_at, id)` as the cursor. This query uses the `notes` table from the [quickstart](../get-started/quickstart.md):

```sql
select id, body, created_at
from notes
order by created_at, id
limit 50;
```

For the next page, add `where (created_at, id) > (last_created_at, last_id)`, binding the last row's values as parameters. This is a query fragment, not literal SQL to paste. Concurrent inserts can still appear behind a cursor; use a transaction snapshot if a consistent scan is required.

## Application roles

If the application role differs from the installer, grant it `usage` on the destination schema and `execute` on the functions it needs, as well as the table privileges for its queries. Postgres normally grants function execution to `PUBLIC` by default; inspect your database's grants instead of assuming the schema is accessible.

The functions run with caller privileges and do not set their own `search_path`. Qualify calls and avoid schemas writable by untrusted roles in the caller's search path.
