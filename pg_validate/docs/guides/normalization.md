# Canonical forms and normalizing input

This guide explains which spelling each validator accepts and how to turn the input you receive (`us`, `de89 3704 0044 0532 0130 00`, `978-0-306-40615-7`) into that spelling before the check runs.

Prerequisites: the extension is installed and you can create tables, functions and triggers. Each block runs on its own unless it says it continues the previous one.

## Validators accept one form

A validator accepts the canonical, compact form of a value and nothing else. `validate.country_code` accepts `US`, not `us`, ` US` or `US `. `validate.iban` accepts the ISO 13616 electronic format, uppercase with no spaces, and rejects the print format with spaces. A validator never trims white space or folds case for you: it returns `false`.

The functions are built for `CHECK` constraints and domains, and those should guarantee that a column holds one stored form. If the validator accepted `us`, `US` and ` US ` alike, a column would hold three spellings of one country, and equality, `unique` constraints, `group by` and joins would each treat them as different values. A strict check pushes normalization to the write boundary, where you can see and control it.

So the rule is: normalize, then validate, then store the normalized value.

## Accepted forms and how to normalize them

In the table, `v` is the input expression, for example a column name or a parameter. Every normalization expression returns null for null, so it passes through a nullable column unchanged.

| Validators | Accepted form | Rejected variants | Normalization |
| --- | --- | --- | --- |
| `country_code`, `country_code_alpha3`, `currency_code` | Uppercase, as ISO 3166 and ISO 4217 define them: `US`, `USA`, `EUR` | `us`, `Us`, ` US`, `US ` | `upper(btrim(v))` |
| `language_code` | Lowercase, as ISO 639-1 defines it: `en`, `fr` | `EN`, `En`, ` en` | `lower(btrim(v))` |
| `iban` | ISO 13616 electronic format: uppercase, no spaces: `DE89370400440532013000` | `de89370400440532013000`, `DE89 3704 0044 0532 0130 00` | `upper(regexp_replace(v, '\s', '', 'g'))` |
| `isbn`, `isbn10`, `isbn13` | Compact: digits, with an uppercase `X` as an ISBN-10 check character: `0306406152`, `9780306406157` | `978-0-306-40615-7`, `0 306 40615 2`, `080442957x` | `upper(regexp_replace(v, '[\s-]', '', 'g'))` |
| `card_number`, `luhn` | Digits only | `4111 1111 1111 1111`, `4111-1111-1111-1111` | `regexp_replace(v, '[\s-]', '', 'g')` |
| `e164` | `+`, then digits only: `+14155552671` | `+1 415 555 2671`, `+1 (415) 555-2671`, `+1-415-555-2671` | `regexp_replace(v, '[\s().-]', '', 'g')` |
| `email` | Printable ASCII with no surrounding space. Case is preserved: `Ada@Example.com` and `ada@example.com` are both valid | ` ada@example.com`, `ada@example.com ` | `btrim(v)` |
| `uuid` | Hyphenated 8-4-4-4-12, either case | `{017f22e2-79b0-7cc3-98c4-dc0c0c07398f}`, a value without hyphens, a value with a space | `lower(btrim(v))` (see below) |
| `hex` | An even number of hex digits, either case, no prefix | `0a ff`, `0x0aff` | `lower(regexp_replace(v, '\s', '', 'g'))` (see below) |
| `git_sha` | Lowercase hex, 40 or 64 digits | An uppercase digit, an abbreviated name | `lower(btrim(v))` |

Notes on the table:

- `btrim(v)` removes spaces only. To remove every kind of white space at the ends of a value, such as tabs and newlines, use `regexp_replace(v, '^\s+|\s+$', '', 'g')`. The `\s` in the table assumes the default `standard_conforming_strings = on`.
- `e164` needs the leading `+`. Normalization cannot supply a missing country code, so `14155552671` and `(415) 555-2671` stay invalid, and the application must decide the country before it stores the number.
- `email`: do not lowercase an address to make it validate. It validates in any case. RFC 5321 treats the local part (before the `@`) as case-sensitive, even though most providers ignore case, so folding it changes the address you store. Whether to lowercase, and which part, is an application choice. If you want case-insensitive uniqueness, add a unique index on `lower(email)` instead of rewriting the column.
- `uuid` and `hex` accept either case, so a mixed-case value validates. Normalize the case only to keep one stored form in a `text` column; a column of type `uuid` stores one form already. `validate.uuid` also rejects the braces and missing hyphens that the `uuid` type's input function accepts.
- `ulid`, `mac` and `base64` follow the same rule as `uuid`: `ulid` and `mac` accept either case, and none of the three accepts white space. `slug` and `git_sha` accept lowercase only.

## Pattern 1: validate a normalized expression

Use this in a query or an import script, where you do not need to store the result:

```sql
select validate.iban(
  value => upper(regexp_replace(
    'de89 3704 0044 0532 0130 00', '\s', '', 'g'))
);
-- true

select validate.iban(value => 'de89 3704 0044 0532 0130 00');
-- false: lowercase, with spaces
```

To find the rows in a table that would pass after normalization but fail as stored:

```sql
create table imported_payees (id int, iban text);

select id, iban
from imported_payees
where not validate.iban(iban)
  and validate.iban(
    upper(regexp_replace(iban, '\s', '', 'g'))
  );
```

## Pattern 2: a trigger that normalizes, and a strict check

A `BEFORE INSERT OR UPDATE` trigger rewrites the value, and the `CHECK` constraint validates what the trigger produced. Postgres runs `BEFORE` triggers before it checks constraints, so the constraint sees the normalized row.

```sql
create table payees (
  id bigint generated always as identity primary key,
  name text not null,
  country text
    constraint payees_country_is_valid
    check (validate.country_code(country)),
  iban text
    constraint payees_iban_is_valid
    check (validate.iban(iban))
);

insert into payees (name, country, iban)
values ('Ada', ' de', 'de89 3704 0044 0532 0130 00');
-- ERROR: new row for relation "payees" violates check constraint
-- "payees_country_is_valid"
```

Without the trigger, the strict constraint rejects the raw input with SQLSTATE `23514`. Add the trigger:

```sql
create function public.normalize_payee()
returns trigger
language plpgsql
as $$
begin
  new.country := upper(btrim(new.country));
  new.iban := upper(regexp_replace(new.iban, '\s', '', 'g'));
  return new;
end;
$$;

create trigger payees_normalize
before insert or update on payees
for each row execute function public.normalize_payee();

insert into payees (name, country, iban)
values ('Ada', ' de', 'de89 3704 0044 0532 0130 00')
returning country, iban;
-- DE | DE89370400440532013000
```

The row is stored in canonical form. A value that is still wrong after normalization, such as `de89 3704 0044 0532 0130 01`, fails the constraint as before.

## Pattern 3: a domain, with normalization at insert time

A domain names the rule once. It does not normalize: a domain check sees the value as given, and a cast to the domain fails for a non-canonical value. Normalize in the statement that writes the value, ideally through one function that every writer uses:

```sql
create domain iban_code as text
  check (validate.iban(value));

create function public.normalize_iban(value text)
returns text
language sql
immutable
strict
as $$
  select upper(regexp_replace(value, '\s', '', 'g'))
$$;

create table accounts (
  id bigint generated always as identity primary key,
  iban iban_code not null
);

insert into accounts (iban)
values (public.normalize_iban('de89 3704 0044 0532 0130 00'));

insert into accounts (iban)
values ('de89 3704 0044 0532 0130 00');
-- ERROR: value for domain iban_code violates check constraint
-- "iban_code_check"
```

You can combine the patterns: a trigger that calls `public.normalize_iban` on a column of type `iban_code` gives you the domain's reuse and the trigger's convenience.

## Keep the raw input with a generated column

If you also want to keep what the user typed, store it in one column and let a generated column hold the normalized form. The constraint checks the generated column:

```sql
create table payouts (
  id bigint generated always as identity primary key,
  iban_raw text not null,
  iban text generated always as (
    upper(regexp_replace(iban_raw, '\s', '', 'g'))
  ) stored
    constraint payouts_iban_is_valid
    check (validate.iban(iban))
);

insert into payouts (iban_raw)
values ('de89 3704 0044 0532 0130 00')
returning iban;
-- DE89370400440532013000
```

Use `iban` for lookups, uniqueness and joins, and `iban_raw` only to show the user what they entered. A generated column is computed from the row's own columns, so it cannot look up other tables as a trigger can.

## See also

- [Use validators in constraints](constraints.md) for naming constraints, domains and adding a constraint to a table that has data.
- The reference entries for each validator state the exact form it accepts: [International](../reference/international.md), [Financial](../reference/financial.md), [Identifiers](../reference/identifiers.md), [Internet](../reference/internet.md) and [Developer formats](../reference/developer.md).
