# Registry functions

Functions and the table of the format registry. [Custom formats](../registry.md) explains how to use them and the security model.

| Function | Volatility | Who can call it |
| --- | --- | --- |
| [`format`](#format) | `STABLE STRICT`, `SECURITY INVOKER` | Everyone |
| [`list_formats`](#list_formats) | `STABLE` | Everyone |
| [`register_format`](#register_format) | `VOLATILE`, `SECURITY INVOKER` | The extension owner and roles it grants |
| [`unregister_format`](#unregister_format) | `VOLATILE`, `SECURITY INVOKER` | The extension owner and roles it grants |

### `format`

```text
validate.format(name text, value text) returns boolean
```

Looks up `name` in the registry and returns the result of its validator for `value`. A built-in name calls the built-in validator, for example `validate.email(value)`. A null `name` or `value` returns null without calling anything.

The validator runs with the caller's privileges. `format` is `STABLE` (the registry can change), `PARALLEL UNSAFE` (a registered validator might be) and cannot be used in an index. It runs the validator through dynamic SQL, which costs more than calling the validator directly.

Errors:

| SQLSTATE | When |
| --- | --- |
| `42704` | No format has this name. |
| `42883` | The format's function was dropped or renamed. |
| `42501` | The caller lacks a privilege the validator needs, such as `EXECUTE` on it or `SELECT` on a table it reads. |

```sql
select validate.format(
  name => 'semver',
  value => '2.0.0-rc.1'
);
-- true
```

### `list_formats`

```text
validate.list_formats() returns table (
  name text,
  builtin boolean,
  validator regprocedure,
  description text,
  owner name
)
```

Returns every format, built-in ones first, then by name. `validator` is null when a registered function no longer exists. `owner` is the role that registered the entry; for built-in formats, the role that installed the extension.

Errors: none.

```sql
select name, validator
from validate.list_formats()
where not builtin;
```

### `register_format`

```text
validate.register_format(
  name text,
  validator regprocedure,
  description text default null
) returns void
```

Registers `validator` under `name`, owned by the current role. `validator` must take exactly one `text` argument, return one `boolean`, and be `IMMUTABLE` or `STABLE`. The caller needs `EXECUTE` on `register_format`, `INSERT` on `validate.formats` and `EXECUTE` on `validator`.

Errors:

| SQLSTATE | When |
| --- | --- |
| `22004` | `name` or `validator` is null. |
| `22023` | `name` does not match `^[A-Za-z][A-Za-z0-9_.-]{0,62}$`; or `validator` has the wrong arguments, result or kind, or is `VOLATILE`. |
| `42501` | The caller cannot execute `register_format` or `validator`, or cannot insert into `validate.formats`. |
| `42710` | `name` is already registered, as a built-in or a custom format. |
| `42883` | `validator` names a function that does not exist (raised by the `regprocedure` cast). |

```sql
create function public.order_number(value text)
returns boolean
language sql
immutable
as $$
  select value ~ '^ORD-[0-9]{8}$'
$$;

select validate.register_format(
  name => 'order-number',
  validator => 'public.order_number(text)',
  description => 'Order numbers such as ORD-00012345'
);
```

### `unregister_format`

```text
validate.unregister_format(name text) returns void
```

Removes a custom format. The caller needs `EXECUTE` on `unregister_format` and `DELETE` on `validate.formats`, and must be the entry's owner, have the owner's privileges, or have the extension owner's privileges.

Errors:

| SQLSTATE | When |
| --- | --- |
| `42704` | No format has this name. |
| `42501` | The format is built in; or the caller is not allowed to remove this entry or lacks a privilege above. |

```sql
select validate.unregister_format(name => 'order-number');
```

## The `validate.formats` table

| Column | Type | Meaning |
| --- | --- | --- |
| `name` | `text` | Primary key. |
| `validator_schema` | `text` | Schema of the validator function. |
| `validator_name` | `text` | Name of the validator function; its argument is always `text`. |
| `builtin` | `boolean` | True for the extension's own formats. |
| `description` | `text` | Free text. For built-ins, the function's comment. |
| `owner` | `name` | Role that registered the entry. |
| `created_at` | `timestamptz` | Time of registration. |

`PUBLIC` has `SELECT`. Write it through `register_format` and `unregister_format`; direct writes go through the same ownership and built-in checks (a trigger), and need `INSERT` or `DELETE`, which nobody but the owner has by default. `UPDATE` and `TRUNCATE` are never needed.
