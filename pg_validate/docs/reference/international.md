# International validators

Validators for phone numbers and ISO codes. Each takes `value text` and returns `boolean`, and is `IMMUTABLE STRICT PARALLEL SAFE`.

| Function | Format | Specification |
| --- | --- | --- |
| [`e164`](#e164) | International phone number | ITU-T E.164 |
| [`country_code`](#country_code) | Two-letter country code | ISO 3166-1 alpha-2 |
| [`country_code_alpha3`](#country_code_alpha3) | Three-letter country code | ISO 3166-1 alpha-3 |
| [`currency_code`](#currency_code) | Currency code | ISO 4217 List One |
| [`language_code`](#language_code) | Two-letter language code | ISO 639-1 |

## Code list snapshots

The ISO lists are embedded in the function bodies, which is why the functions can be `IMMUTABLE`: they read no table. Each release of the extension carries a snapshot, and a change to a list is a new extension version. A code that ISO adds after the release fails until you upgrade; a code that ISO withdraws keeps passing until you upgrade.

| Function | Codes | Source | Snapshot |
| --- | --- | --- | --- |
| `country_code`, `country_code_alpha3` | 249 officially assigned codes | Debian [iso-codes](https://salsa.debian.org/iso-codes-team/iso-codes) `iso_3166-1.json`, cross-checked with Wikipedia's table of officially assigned codes | Retrieved 2026-11-03 |
| `currency_code` | 178 List One codes | [SIX](https://www.six-group.com/en/products-services/financial-information/market-reference-data/data-standards.html), the ISO 4217 maintenance agency: `list-one.xml` | List One published 2026-09-17: includes `XAD`, `XCG` and `SLE`; excludes `ANG`, `BGN`, `CUC`, `HRK`, `SLL`, `ZWL` |
| `language_code` | 183 codes | Debian iso-codes `iso_639-2.json` (its two-letter codes), cross-checked with Wikipedia's list of ISO 639 codes | Retrieved 2026-11-03, after the 2021 deprecation of `bh` |

[`data/README.md`](../../data/README.md) records the source URLs, versions and checksums. Before each release, and at least every three months (ISO 4217 changes several times a year), run `data/refresh.py`: it fetches the sources and prints the codes to add and remove. The test suite counts the accepted codes, so an unintended change to a list fails a test.

Known exclusions, by policy:

- `XK` (Kosovo) and other user-assigned codes are not ISO 3166-1 assignments, so `country_code` rejects them, as it rejects exceptionally reserved codes such as `UK` and `EU`. `XK` is a valid IBAN prefix: see [`iban`](financial.md#iban).
- `currency_code` accepts List One only. Historic codes (List Three) are rejected, including codes withdrawn recently: `ANG` (replaced by `XCG` in 2025), `BGN` (Bulgaria adopted the euro on 2026-01-01) and `SLL` (replaced by `SLE`).

Codes are case-sensitive, in the case the standard uses: uppercase for countries and currencies, lowercase for languages. To accept other cases, normalize in the constraint, for example `check (validate.country_code(upper(country)))`, or better, store the normalized value.

### `e164`

```text
validate.e164(value text) returns boolean
```

Accepts an E.164 number in its international form: `+`, a country code that does not start with `0`, then the rest of the number, at most 15 digits in total (E.164 §6.1). No spaces, hyphens or parentheses: this is the form that Twilio and most SMS providers expect.

**Guarantees:** the value has the structure of an international number and fits E.164's 15-digit limit.

**Does not guarantee:** that the country code is assigned, that the number has a valid length for its country, that it is assigned to a subscriber, or that it can receive calls or SMS. Use a library such as libphonenumber in the application for national numbering plans, and verify ownership by sending a code.

```sql
select validate.e164(value => '+14155552671');
-- true
select validate.e164(value => '+1 415 555 2671');
-- false: spaces
```

### `country_code`

```text
validate.country_code(value text) returns boolean
```

Accepts one of the 249 officially assigned ISO 3166-1 alpha-2 codes, in uppercase (`US`, `GB`, `AX`).

Rejected: lowercase codes, exceptionally reserved codes (`UK`, `EU`), transitionally reserved and withdrawn codes (`AN`, `YU`), and user-assigned codes, including `XK`, which many systems use for Kosovo. To accept `XK`, use `check (validate.country_code(country) or country = 'XK')`.

**Guarantees:** the value is an assigned ISO 3166-1 alpha-2 code in the snapshot.

**Does not guarantee:** that the code is still assigned after the snapshot, or anything about political recognition.

### `country_code_alpha3`

```text
validate.country_code_alpha3(value text) returns boolean
```

Accepts one of the 249 officially assigned ISO 3166-1 alpha-3 codes, in uppercase (`USA`, `GBR`, `ALA`). The same rules as `country_code` apply; user-assigned codes such as `XKX` are rejected.

**Guarantees and limits:** as for `country_code`.

### `currency_code`

```text
validate.currency_code(value text) returns boolean
```

Accepts an ISO 4217 alphabetic code from List One (current currencies and funds), in uppercase. List One includes fund codes (`BOV`, `CHE`, `USN`, `XAD`), precious metals (`XAU`, `XAG`), `XTS` (reserved for testing) and `XXX` (no currency). Exclude the ones you do not want in the constraint, for example `and currency not in ('XTS', 'XXX')`.

**Guarantees:** the value is a List One code in the snapshot.

**Does not guarantee:** that the currency is legal tender anywhere today if ISO withdrew it after the snapshot. Historic codes (List Three, such as `HRK`) and non-ISO codes (`BTC`, `USDT`) are rejected.

### `language_code`

```text
validate.language_code(value text) returns boolean
```

Accepts one of the 183 ISO 639-1 two-letter codes, in lowercase (`en`, `fr`, `zh`). Withdrawn codes (`iw`, `in`, `ji`) and the deprecated `bh` are rejected.

This is not a language tag. `en-US`, `zh-Hant` and three-letter ISO 639-2 and 639-3 codes (`eng`, `yue`) are rejected. For language tags as used by HTTP and HTML, BCP 47 (RFC 5646) is on the [roadmap](../roadmap.md); its syntax needs a grammar and its subtags need the IANA registry.

**Guarantees:** the value is a current ISO 639-1 code in the snapshot.

**Does not guarantee:** coverage of languages that have no two-letter code; most of the world's languages have only a 639-3 code.
