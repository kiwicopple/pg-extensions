# Quickstart: validate a table

This walkthrough adds format checks to a table, shows what happens when a row breaks one, and registers a custom format. It takes about five minutes.

Prerequisites: a Postgres 16, 17 or 18 database with the extension installed (see [Install](../install.md)), and a role that can create tables. Run every block in order as that role. The test suite runs this page as `test/spec/90_usage_quickstart.sql`.

## 1. Check a value

Each validator takes one `text` value and returns a boolean:

```sql
select validate.email(value => 'ada@example.com');
-- true
select validate.email(value => 'ada@example');
-- true: a single-label domain is valid syntax
select validate.email(value => 'ada@@example.com');
-- false
select validate.semver(value => '1.4.0-rc.1');
-- true
```

A validator checks structure and encoding only. `validate.email` says that an address is well formed, not that a mailbox exists. Each reference page lists what a validator guarantees and what it does not.

## 2. Add CHECK constraints

Call a validator in a `check` constraint. Name each constraint, so that an error message says which rule failed:

```sql
create table customers (
  id bigint generated always as identity primary key,
  email text not null
    constraint customers_email_is_valid
    check (validate.email(email)),
  website text
    constraint customers_website_is_valid
    check (validate.url(website)),
  country text
    constraint customers_country_is_valid
    check (validate.country_code(country)),
  iban text
    constraint customers_iban_is_valid
    check (validate.iban(iban))
);
```

A valid row inserts. A null passes the check: validators return null for null, and a check constraint only rejects `false`. Use `not null` where a value is required.

```sql
insert into customers (email, website, country, iban)
values (
  'ada@example.com',
  'https://example.com',
  'GB',
  'GB82WEST12345698765432'
);

insert into customers (email)
values ('grace@example.com');
```

## 3. See a rejected row

This statement fails on purpose:

```sql
insert into customers (email, country)
values ('alan@example.com', 'UK');
-- ERROR:  new row for relation "customers" violates check constraint "customers_country_is_valid"
```

`UK` is not an ISO 3166-1 code; the United Kingdom is `GB`. The error has SQLSTATE `23514` (`check_violation`), and the constraint name tells the application which field to report.

## 4. Look up a format by name

`validate.format` checks a value against a format named at run time. Every built-in validator is registered under its own name:

```sql
select validate.format(
  name => 'iban',
  value => 'GB82WEST12345698765432'
);
-- true
```

Prefer the validator function itself in constraints. `validate.format` is `STABLE`, not `IMMUTABLE`, because the registry can change. [Custom formats](../registry.md) explains why.

## 5. Register a custom format

A custom format is a function that takes one `text` argument and returns `boolean`. Register it under a name as the extension owner, or as a role that the owner has allowed to register formats:

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

select validate.format(
  name => 'order-number',
  value => 'ORD-00012345'
);
-- true
```

List the registry to see the built-in formats and yours:

```sql
select name, builtin, validator
from validate.list_formats()
where not builtin;
-- order-number | f | order_number(text)
```

## Next steps

- [Use validators in constraints](../guides/constraints.md): domains, existing data, normalization and error handling.
- [Custom formats](../registry.md): who can register, ownership, and the security model.
- The reference pages: [identifiers](../reference/identifiers.md), [internet](../reference/internet.md), [dates](../reference/dates.md), [international](../reference/international.md), [developer formats](../reference/developer.md) and [financial](../reference/financial.md).
