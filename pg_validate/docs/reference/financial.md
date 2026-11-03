# Financial validators

Validators for bank accounts, book numbers and card numbers. Each takes `value text` and returns `boolean`, and is `IMMUTABLE STRICT PARALLEL SAFE`.

| Function | Format | Specification |
| --- | --- | --- |
| [`iban`](#iban) | International Bank Account Number | ISO 13616-1, SWIFT IBAN registry, ISO 7064 |
| [`isbn`](#isbn) | ISBN-10 or ISBN-13 | ISO 2108 |
| [`isbn10`](#isbn10) | ISBN-10 | ISO 2108 |
| [`isbn13`](#isbn13) | ISBN-13 | ISO 2108, EAN-13 |
| [`card_number`](#card_number) | Payment card number | ISO/IEC 7812-1 |
| [`luhn`](#luhn) | Any digit string with a Luhn check digit | ISO/IEC 7812-1 Annex B |

All of them accept the compact electronic form only: no spaces or hyphens. Strip separators before checking, for example `validate.iban(replace(value, ' ', ''))`, and store the compact form.

### `iban`

```text
validate.iban(value text) returns boolean
```

Accepts an IBAN in electronic format:

1. Uppercase letters and digits only, no spaces.
2. An IBAN prefix from the SWIFT IBAN Registry (the 89 countries and territories of this release's snapshot, including `XK` for Kosovo and `YE`), and exactly the length the registry gives for that country (from 15 for Norway to 33 for Russia). Territories that the registry lists under another country use that country's prefix, so their own codes are rejected as prefixes: `GF`, `GP`, `MQ`, `RE`, `PF`, `TF`, `YT`, `NC`, `BL`, `MF`, `PM` and `WF` use `FR`; `IM`, `JE` and `GG` use `GB`; `AX` uses `FI`.
3. Check digits `02` to `98` (ISO 13616: `00`, `01` and `99` are never issued, although some pass the arithmetic).
4. The ISO 7064 MOD 97-10 check: move the first four characters to the end, replace letters with 10 to 35, and the number modulo 97 is 1.

The test suite checks the registry's example IBAN for each of the 89 countries.

| Source | Snapshot |
| --- | --- |
| SWIFT [IBAN Registry](https://www.swift.com/standards/data-standards/iban-international-bank-account-number) (TXT), the ISO 13616 registration authority | Updated by SWIFT on 2026-09-17, retrieved 2026-11-03 |

Every country in the registry is included. Countries with experimental or proposed IBANs that are not in the registry (the lists that some banks publish, with Algeria `DZ`, Angola `AO`, Iran `IR`, Senegal `SN` and others) are rejected. [`data/README.md`](../../data/README.md) records the source and its checksum. SWIFT updates the registry several times a year; before each release, and at least every three months, run `data/refresh.py` to compare the embedded lengths with the latest registry.

**Guarantees:** the value has a registered country, the right length and valid check digits, so it was not mistyped in any way MOD 97 detects (all single-character errors and most transpositions).

**Does not guarantee:** that the account exists or is open. The BBAN's national structure (bank code, branch code, the positions of letters and digits) and national check digits are not checked. A country added to the registry after the snapshot fails until you upgrade the extension.

```sql
select validate.iban(value => 'GB82WEST12345698765432');
-- true
select validate.iban(value => 'GB82 WEST 1234 5698 7654 32');
-- false: print format with spaces
```

### `isbn`

```text
validate.isbn(value text) returns boolean
```

Accepts an ISBN-10 or an ISBN-13 in compact form; see the next two entries.

**Guarantees:** a valid check digit for one of the two forms.

**Does not guarantee:** that the ISBN was assigned to a book. Hyphenated forms (`978-0-306-40615-7`) are rejected, because the hyphen positions depend on the ISBN range tables, which change; strip hyphens first.

### `isbn10`

```text
validate.isbn10(value text) returns boolean
```

Accepts nine digits and a check character, `0`-`9` or uppercase `X` for 10, where the sum of each digit times its weight (10 down to 1) is divisible by 11.

**Guarantees and limits:** as for `isbn`. A lowercase `x` is rejected.

### `isbn13`

```text
validate.isbn13(value text) returns boolean
```

Accepts 13 digits starting with `978` or `979` and a valid EAN-13 check digit (weights 1 and 3, sum divisible by 10). The prefix `979-0` is reserved for ISMN (printed music), not ISBN, and is rejected.

**Guarantees and limits:** as for `isbn`. Other EAN-13 barcodes are rejected; a general GTIN validator is on the [roadmap](../roadmap.md).

### `card_number`

```text
validate.card_number(value text) returns boolean
```

Accepts a payment card number (PAN): 12 to 19 digits (ISO/IEC 7812-1) with a valid Luhn check digit. The test suite uses the card networks' published test numbers.

**Guarantees:** the number is well formed and has a valid check digit, so it was not mistyped in any way Luhn detects (all single-digit errors and most adjacent transpositions).

**Does not guarantee:** that the card exists, was issued, is active or belongs to the person entering it. The issuer identification number (IIN, the first six to eight digits) is not checked, so the validator does not tell Visa from Mastercard, and all-zero numbers of valid length pass. Only a payment processor can tell you whether a card is real.

Storing card numbers brings a database into PCI DSS scope. Prefer storing your processor's token and, if needed, the last four digits.

### `luhn`

```text
validate.luhn(value text) returns boolean
```

Accepts a string of at least two digits whose last digit is a valid Luhn ("mod 10") check digit. Use it for identifiers that use Luhn but are not payment cards, such as IMEI numbers and some national identifiers.

**Guarantees:** the check digit is valid.

**Does not guarantee:** any length or meaning. Combine it with a length check, as `card_number` does.
