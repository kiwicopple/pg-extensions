# Use validators in constraints

This guide covers the patterns for putting validators on real tables: naming constraints, domains, adding a constraint to a table that already has data, normalizing input, and reporting errors to users.

Prerequisites: the extension is installed and you can alter the tables involved. The examples continue from the `customers` table of the [quickstart](../get-started/quickstart.md); each block runs on its own if you create that table first.

## Name every constraint

Postgres names an unnamed constraint `<table>_<column>_check`. A name that describes the rule helps the application map an error to a field:

```sql
alter table customers
  add constraint customers_email_is_valid_2
  check (validate.email(email));
```

The error has SQLSTATE `23514` and the constraint name. Drivers expose it, for example `err.constraint` in node-postgres. Map constraint names to messages in the application rather than parsing the error text.

## Reuse a rule with a domain

A domain gives a validated type a name, so every table that uses it gets the same rule:

```sql
create domain email_address as text
  check (validate.email(value));

create domain country_code as text
  check (validate.country_code(value));

create table suppliers (
  id bigint generated always as identity primary key,
  contact email_address not null,
  country country_code
);
```

A cast fails with `23514` too: `select 'nope'::email_address;`.

## Allow null, or not

Validators return null for null, and a `CHECK` constraint only rejects `false`. A nullable column with a validator accepts null. Add `not null` when a value is required. An empty string is a value, and most validators reject it.

## Add a constraint to a table that already has data

`alter table ... add constraint` checks every existing row and fails if one is invalid. To start enforcing the rule for new rows first, add the constraint `not valid`, find and fix the old rows, then validate:

```sql
alter table customers
  add constraint customers_website_is_url
  check (validate.url(website))
  not valid;

select id, website
from customers
where not validate.url(website);

alter table customers
  validate constraint customers_website_is_url;
```

`validate constraint` takes a lighter lock than adding a checked constraint, so writes continue while it scans.

## Normalize before you validate

Validators do not normalize. `validate.country_code('gb')` is false, and `validate.iban` rejects spaces. Normalize in the application, or in a trigger, and keep the constraint strict. [Canonical forms and normalizing input](normalization.md) lists the form each validator accepts and covers triggers, domains and generated columns:

```sql
create function public.normalize_customer()
returns trigger
language plpgsql
as $$
begin
  new.country := upper(new.country);
  new.iban := replace(upper(new.iban), ' ', '');
  return new;
end;
$$;

create trigger customers_normalize
before insert or update on customers
for each row execute function public.normalize_customer();
```

Do not put `upper()` or `lower()` inside the constraint: the table would then hold several spellings of one value.

## Combine rules

A constraint is an expression, so validators combine with other conditions:

```sql
alter table customers
  add column referrer text
  constraint customers_referrer_is_https
  check (
    validate.url(referrer)
    and referrer like 'https://%'
  );
```

## Validate in queries

Validators also work outside constraints, for example to audit an imported table:

```sql
select
  count(*) filter (where not validate.email(email)) as bad_emails,
  count(*) filter (where not validate.country_code(country)) as bad_countries
from customers;
```

Because the built-in validators are immutable, you can index an expression such as `validate.email(email)` or use it in a generated column.

## Use the registry only where the name is data

`validate.format(name, value)` looks a format up at run time. Use it when the format name comes from data, such as a form definition. In a constraint, call the validator itself; [Custom formats](../registry.md#formats-in-check-constraints) explains why.
