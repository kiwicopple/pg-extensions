# Custom formats

The registry maps a format name to a validator function. Every built-in validator is registered under its own name, and you can register your own functions next to them. `validate.format(name, value)` looks the name up and calls the function.

Use the registry when the format is chosen at run time: a form builder that stores a format name per field, a JSON Schema's `format` keyword ([`json_schema`](json-schema.md)), or an import job configured with column formats. When the format is fixed, call the validator function directly.

This page describes how to register a format, who may do it, and what runs with whose privileges. The [registry reference](reference/registry.md) lists the functions, their arguments and errors.

## Write a validator

A validator is a function that:

- takes exactly one argument, of type `text`;
- returns `boolean`, one row (not `setof`);
- is `IMMUTABLE` or `STABLE` (`register_format` refuses `VOLATILE` functions);
- is a function, not a procedure or an aggregate.

Make it `STRICT` or handle null yourself; `validate.format` returns null for a null value without calling it. Return `false` for invalid input rather than raising an error, so that the result works in `WHERE` clauses and `CHECK` constraints alike.

A validator can call the built-in ones. For example, a UUIDv7 format and a work email format:

```sql
create function public.uuid_v7(value text)
returns boolean
language sql
immutable
strict
parallel safe
as $$
  select validate.uuid(value, 7)
$$;

create function public.work_email(value text)
returns boolean
language sql
immutable
strict
parallel safe
as $$
  select validate.email(value)
    and split_part(lower(value), '@', 2)
        not in ('gmail.com', 'outlook.com', 'yahoo.com')
$$;
```

## Register, use and remove a format

```sql
select validate.register_format(
  name => 'uuid-v7',
  validator => 'public.uuid_v7(text)',
  description => 'RFC 9562 version 7 UUID'
);

select validate.format(
  name => 'uuid-v7',
  value => '017f22e2-79b0-7cc3-98c4-dc0c0c07398f'
);
-- true

select validate.unregister_format(name => 'uuid-v7');
```

A name starts with a letter and has at most 63 letters, digits, `_`, `-` or `.`. Names are case-sensitive. A name that is already registered raises `42710`; unregister it first to point it at another function. `validate.list_formats()` lists every format with its function, description and owner.

The registry stores the function's schema and name, not its OID. Renaming or dropping the function breaks the entry: `validate.format` then raises `42883`, and `list_formats()` shows the function as null. `create or replace function` keeps the entry working.

## Built-in formats are fixed

The 42 built-in formats are inserted by the extension and marked `builtin`: one per validator, plus the JSON Schema names `date-time`, `date`, `time`, `uri-reference` and `json-pointer`, which point at `rfc3339`, `rfc3339_date`, `rfc3339_time`, `uri_reference` and `json_pointer`. Nobody can replace or remove them, the extension owner and superusers included:

- `register_format` with a built-in name raises `42710`.
- `unregister_format` of a built-in name raises `42501`.
- Direct `update`, `delete`, `insert ... builtin = true` and `truncate` on the registry table raise `42501`, through a trigger that applies to every role.

A name always means the same thing, so `validate.format('email', ...)` in one database means the same as in another with the same extension version.

## The security model

**Reading is public.** Every role can call `validate.format`, `validate.list_formats` and the validators, and can read the table `validate.formats`. Format names, functions and owners are not secret.

**Registering is not.** `register_format` and `unregister_format` are revoked from `PUBLIC`. Both are `SECURITY INVOKER` and write the table as the caller, so a role needs three things: `EXECUTE` on the function it calls, `INSERT` (to register) or `DELETE` (to unregister) on `validate.formats`, and `EXECUTE` on the validator it registers. The extension owner has all of them.

**Each entry has an owner.** The role that registers a format owns the entry. A trigger on the table, which also covers direct `insert` and `delete`, lets a role remove or change an entry only if it is the owner, has the owner's privileges (is a member of the owner role with `INHERIT`), or has the privileges of the registry's owner, which is the extension owner. Superusers can always. A role cannot register an entry on behalf of another role.

**Validators run as the caller.** `validate.format` is `SECURITY INVOKER` and nothing in the extension is `SECURITY DEFINER`. A registered validator runs with the privileges of whoever calls `validate.format`, so it can read only what that caller can read, and the caller needs `EXECUTE` on it. A validator that reads a private table fails with `42501` for a client that cannot read it.

**Dispatch is not injectable.** `validate.format` calls the function with `format('select %I.%I($1)', schema, name)` and passes the value as a parameter. Names are checked against a fixed pattern at registration and are never part of SQL text; the value is never part of SQL text.

### What registration lets a role do

Running as the caller protects callers from validators that read too much, but it also means that a registered validator runs with the privileges of everyone who calls it, including the extension owner, a superuser or a service role that writes through a constraint. The owner of a validator function can change its body with `create or replace function` at any time.

Grant registration only to roles you trust as much as the code they register, and register only functions owned by trusted roles. Prefer validators that are pure functions of their argument: `IMMUTABLE`, no table access.

### Allow a role to register formats

As the extension owner:

```sql
grant execute on function
  validate.register_format(text, regprocedure, text),
  validate.unregister_format(text)
to app_admin;

grant insert, delete
on validate.formats
to app_admin;
```

`app_admin` can then register formats with functions it can execute, and remove the formats it registered. To let a second role manage `app_admin`'s formats too, grant it membership: `grant app_admin to app_admin2;`.

To take the right away again, revoke the same privileges. The formats that the role registered stay, owned by it; the extension owner can remove them.

## Formats in CHECK constraints

Postgres accepts `validate.format` in a `CHECK` constraint:

```sql
create table tickets (
  ref text
    check (validate.format('order-number', ref))
);
```

Postgres checks a constraint only when a row is inserted or updated. If someone later unregisters `order-number` and registers it with a different function, existing rows are not rechecked, and new rows follow the new rule. If the function is dropped, every insert fails with `42883` until the format is fixed.

`validate.format` is `STABLE` because its result depends on the registry; it cannot be used in an index or a generated column. It is `PARALLEL UNSAFE` because a registered validator might be.

For these reasons, call the validator function directly in constraints: `check (public.order_number(ref))` or `check (validate.email(email))`. Postgres then records a dependency on the function, so it cannot be dropped while the constraint exists. Use `validate.format` where the name really is data.

## Backups and upgrades

When the extension is installed with `create extension`, the registry table is an extension configuration table (`pg_extension_config_dump` with the filter `where not builtin`). `pg_dump` keeps the formats you registered, with their owners, and leaves out the built-in rows, which `create extension` recreates on restore. Restore the functions your formats use before the data, which `pg_dump` does by default.

The registry stores schema and function names, not `regprocedure` values, so `pg_upgrade` works: it refuses tables with `reg*` columns other than `regclass`, `regrole` and `regtype`.

After a plain `psql -f` install there is no extension object, and `pg_dump` dumps the whole table, built-in rows included, as ordinary data.
