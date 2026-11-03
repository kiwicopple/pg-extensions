# Overview

`pg_validate` is a Postgres extension of boolean validators for common string formats. Each validator takes a `text` value and returns `true` or `false`, so you can use it in a `CHECK` constraint, a domain, a `WHERE` clause or an RLS policy:

```sql
create table signups (
  email text not null
    check (validate.email(email)),
  referrer text
    check (validate.url(referrer))
);
```

A registry gives every validator a name. `validate.format(name, value)` looks a format up at run time, and applications can register their own formats next to the built-in ones.

## Why it exists

### Put format rules where the data is

Applications usually validate formats in one service and trust the database to hold whatever arrives. Other writers, such as a second service, a migration, a support script or a bulk import, do not share that code. A constraint in the database applies to every writer.

### Implement the specification, not a regular expression found online

Formats like email addresses, URIs, dates and IBANs have published grammars. A short regular expression accepts strings the grammar forbids, such as `2026-02-30`, and rejects strings it allows, such as `"joe bloggs"@example.com`. Each validator here follows the grammar it cites, checks what can be checked from the string alone (calendar dates, check digits, ISO code lists, length limits), and documents where it deliberately accepts less.

### Keep constraints cheap and stable

The built-in validators are `IMMUTABLE STRICT PARALLEL SAFE`, and the markings are true: no validator reads a catalog, a setting such as `TimeZone`, or the session's collation. A constraint gives the same answer on every server and every session, and you can use a validator in an index or a generated column.

## What it checks, and what it does not

Every validator checks **structure and encoding only**. It never checks existence or authenticity:

| Validator | Checks | Does not check |
| --- | --- | --- |
| `email` | RFC 5321/5322 address syntax and length limits | That the domain exists or the mailbox accepts mail |
| `card_number` | 12 to 19 digits and the Luhn check digit | That the card was issued, is active, or belongs to anyone |
| `iban` | Registry country and length, MOD 97 check | That the account exists |
| `url` | RFC 3986 syntax for http and https, valid host and port | That the server responds |
| `country_code` | Membership in the ISO 3166-1 list in this release | Political recognition; codes added after the release |

Each [reference page](README.md#reference) has a **Guarantees** and a **Does not guarantee** section for every validator.

## The validators

| Group | Validators |
| --- | --- |
| [Identifiers](reference/identifiers.md) | `uuid`, `ulid`, `nanoid`, `slug`, `semver`, `git_sha` |
| [Internet](reference/internet.md) | `email`, `url`, `uri`, `uri_reference`, `domain`, `hostname`, `ipv4`, `ipv6`, `mac`, `port` |
| [Dates and times](reference/dates.md) | `iso8601`, `rfc3339`, `rfc3339_date`, `rfc3339_time`, `duration` |
| [International](reference/international.md) | `e164`, `country_code`, `country_code_alpha3`, `currency_code`, `language_code` |
| [Developer formats](reference/developer.md) | `base64`, `base64url`, `hex`, `json_pointer`, `cron` |
| [Financial](reference/financial.md) | `iban`, `isbn`, `isbn10`, `isbn13`, `card_number`, `luhn` |

[Custom formats](registry.md) covers the registry. [JSON Schema](json-schema.md) covers `validate.json_schema(doc, schema)`, which validates `jsonb` documents against Draft 2020-12 schemas and checks `format` through the registry. The [roadmap](roadmap.md) lists the formats under consideration.

## Goals that shape the extension

- Be exact. Follow the cited specification; when a validator accepts less than the specification, say so in the reference.
- Keep markings honest. Mark a function `IMMUTABLE` only when its result depends on its argument alone.
- Install anywhere. The extension is SQL and PL/pgSQL, needs no superuser and no other extension, and runs on Postgres 16, 17 and 18, including through pg_tle and on Supabase.
- Run validators with the caller's privileges. Nothing in the extension is `SECURITY DEFINER`, so a custom validator cannot read data its caller cannot read.
- Test against published examples: the RFC examples, semver.org's lists, the IBAN registry examples, the official JSON Schema Test Suite and payment test card numbers.

## Start here

[Install the extension](install.md), then follow the [quickstart](get-started/quickstart.md) to add constraints to a table and register a custom format. The [documentation map](README.md) lists every page.
