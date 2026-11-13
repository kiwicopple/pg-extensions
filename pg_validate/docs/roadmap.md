# Roadmap

This page lists formats under consideration and the rules a new validator must follow. Nothing here is implemented unless the [overview](overview.md#the-validators) lists it.

## Principles for new validators

- **Structure and encoding only.** A validator checks what the string itself can prove: grammar, lengths, check digits, membership in a published code list. It never checks existence or authenticity: no DNS lookups, no network calls, no signature verification, no "is this card real". The reference for each validator says what it does not guarantee.
- **Follow the specification.** Cite the RFC or standard section. Implement its grammar, not a short regular expression; where the validator accepts less, document it.
- **Honest volatility.** `IMMUTABLE` only when the result depends on the argument alone. Anything that reads a catalog (time zone names, collations), a setting or a table is `STABLE` and says why.
- **Test against published vectors** where they exist.
- **Cut breadth before correctness.** A format waits for a later release rather than ship with a guess.

## JSON Schema follow-ups

[`validate.json_schema`](json-schema.md) ships in 0.0.1 with a validator for every Draft 2020-12 format and [named schemas](guides/named-schemas.md), which are checked and indexed once. Possible next steps:

- Bundle the Draft 2020-12 metaschemas as known resources, so that `$ref` to `https://json-schema.org/draft/2020-12/schema` works and schemas can be validated against them, including at registration.
- An `IMMUTABLE` variant restricted to built-in formats, for indexes and generated columns.
- A registry-backed translation of common `\p{...}` classes in patterns.
- A faster evaluator for named schemas: generating a PL/pgSQL function per registered schema would remove most of the per-keyword checks, at the cost of `CREATE FUNCTION` at registration.
- Restore order: a way for `pg_dump` to restore the registries before tables whose constraints use them, so that those constraints need not be `NOT VALID`.
- IDNA: the IANA tables for a newer Unicode version when IANA publishes them, the rest of the UTS #46 mapping (case folding of non-ASCII letters), and the list of Script values for `\p{Script=...}` in `regex`.

## Implemented early

These were on the list and cost little, so they ship in 0.0.1: `ipv4`, `ipv6`, `mac`, `port`, `git_sha`, `duration`, `uri_reference`, `base64url`, `luhn`, `rfc3339_date` and `rfc3339_time`. The JSON Schema formats `iri`, `iri_reference`, `idn_hostname`, `idn_email`, `uri_template`, `relative_json_pointer` and `regex` ship in 0.0.1 too.

## Candidates

### Identifiers

| Format | Notes |
| --- | --- |
| KSUID | 27 base62 characters, at most `aWgEPTl1tmebfsQzFP4bxwgy80V`. |
| CUID, CUID2 | CUID2 has a defined alphabet and length range but no checksum; CUID is deprecated. |
| Snowflake ID | A decimal 64-bit integer; a timestamp range check needs an epoch per service. |
| Abbreviated git SHA | 4 to 40 hex digits, as an overload of `git_sha`. |
| UUID string forms | Overloads of `uuid` for the URN form (`urn:uuid:...`) and for hex without hyphens. |

### Network

| Format | Notes |
| --- | --- |
| CIDR on text | `ipv4_cidr`, `ipv6_cidr` with prefix length and zero host bits. `pg_input_is_valid(value, 'cidr')` is exact but `STABLE`. |
| EUI-64 | Eight groups, as `mac` has six. |
| Origin | RFC 6454 serialized origin: scheme, host and port, no path. |
| WebSocket URL | `ws` and `wss`, as `url` is for `http` and `https` (RFC 6455 §3). |
| MIME type | RFC 9110 §8.3.1 `media-type` with parameters. |

### Dates, places and locales

| Format | Notes |
| --- | --- |
| Time zone name | Membership in `pg_timezone_names`. Must be `STABLE`: the list depends on the server's tzdata. An `IMMUTABLE` snapshot of IANA names is the alternative. |
| Locale, BCP 47 language tag | RFC 5646 §2.1 syntax is exact and `IMMUTABLE`. Checking subtags against the IANA registry needs a snapshot. |
| ISO 639-3 | 7,900 codes; a snapshot in the function body is large but possible. |
| Latitude and longitude | Decimal degrees in range; a pair format such as `"51.5,-0.12"`. |
| Geohash | Base32 alphabet without `a i l o`, length 1 to 12. |
| ISO 8601 interval | `start/end`, `start/duration`, `duration/end`, recurring `R5/...`. |
| Postal codes | Per-country patterns from a published source (CLDR or UPU); a two-argument form `postal_code(value, country)`. |

### Financial and commercial

| Format | Notes |
| --- | --- |
| BIC (SWIFT code) | ISO 9362: 8 or 11 characters; country part checked against ISO 3166. |
| ISSN | ISO 3297, mod 11 check digit. |
| ISIN | ISO 6166, Luhn over the letter-expanded digits. |
| LEI | ISO 17442, MOD 97-10 like the IBAN. |
| GTIN, EAN, UPC | GS1 mod 10 for GTIN-8, -12, -13, -14. |
| VAT numbers | Per-country check digits; large and changes often, likely a separate module. |

### Documents and data

| Format | Notes |
| --- | --- |
| JSON Patch, JSON Merge Patch | RFC 6902 operation structure (on `jsonb`); RFC 7386 has no structure beyond JSON. |
| JSON Lines | Each line parses as JSON. `IMMUTABLE` through a per-line cast with an exception block, which costs a subtransaction per call. |
| JWT (structure only) | Three base64url segments; header and payload decode to JSON objects; `alg` present. Never verifies the signature. |
| JWK | RFC 7517 member structure per `kty`. |
| PEM | RFC 7468 labels, base64 body, matching `BEGIN` and `END`. |
| SRI | W3C Subresource Integrity: `sha256-`, `sha384-` or `sha512-` and base64 of the right length. |

### Packages and software

| Format | Notes |
| --- | --- |
| OCI image reference | The `distribution/reference` grammar: registry, path, tag and digest. |
| npm package name | The rules of `validate-npm-package-name`, including scopes. |
| PURL | Package URL specification: `pkg:type/namespace/name@version?qualifiers#subpath`. |
| SPDX license expression | SPDX 2.3 Annex D grammar; checking identifiers needs the license list snapshot. |

### Security and crypto formats (structure only)

| Format | Notes |
| --- | --- |
| bcrypt hash | `$2a$`, `$2b$` or `$2y$`, cost 04 to 31, 53 characters of bcrypt's base64. |
| Argon2 hash | PHC string format: `$argon2id$v=19$m=...,t=...,p=...$salt$hash`. |
| Ethereum address | 40 hex digits after `0x`; EIP-55 mixed-case checksum needs Keccak-256 in PL/pgSQL. |
| Bitcoin address | Base58Check (needs SHA-256 twice: `sha256()` is built in) and Bech32/Bech32m (BIP 173, 350). |
| DID | W3C DID Core syntax `did:method:id`; method-specific rules are out of scope. |

### Optional schema modules

Validators for whole documents, built on `json_schema`, shipped as separate extensions or optional files: OpenAPI 3.1 documents, CloudEvents, GeoJSON (RFC 7946), JSON Feed, AsyncAPI. Each is a JSON Schema plus a few rules the schema cannot express.

## Other ideas

- `validate.explain(name, value) returns text`: why a value failed, for user-facing error messages.
- Normalizers next to validators, for example `validate.normalize_iban(text)` and `validate.normalize_email(text)`, so that applications store one form.
- A database.dev package and an upgrade script per release, so that code list snapshots can be refreshed with `alter extension pg_validate update`.
