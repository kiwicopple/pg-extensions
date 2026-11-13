# Code list sources

Five validators embed a code list in their function bodies: `country_code`, `country_code_alpha3`, `currency_code`, `language_code` and `iban`. Three more, `hostname`, `idn_hostname` and `idn_email`, use an embedded IDNA table (see [IDNA tables](#idna-tables)). This directory records where each list comes from, and `refresh.py` and `refresh_idna.py` compare the lists in `pg_validate--0.0.1.sql` with their sources. Nothing here is needed to install the extension; the SQL file stays the only artifact.

## Snapshot in this release

Retrieved 2026-11-03. The SHA-256 is of the file as fetched.

| Validator | Codes | Source | Version | SHA-256 |
| --- | --- | --- | --- | --- |
| `currency_code` | 178 | ISO 4217 List One from SIX, the maintenance agency: <https://www.six-group.com/dam/download/financial-information/data-center/iso-currrency/lists/list-one.xml> | `Pblshd="2026-09-17"` | `33139b438657d1cee116ba737807ea71d19d6de4b90f799a09c56f0cc6a1b0ff` |
| `country_code`, `country_code_alpha3` | 249, 249 | Debian iso-codes, `data/iso_3166-1.json`: <https://salsa.debian.org/iso-codes-team/iso-codes/-/raw/main/data/iso_3166-1.json> | Last change to the file: commit `d055275324963c9bce5882eaaa93024cf2bf7ed0` (2023-02-22) | `f01b812b57fba9f31ff621bf33e7c7570a01964dbeb5be2167e94decf538c89f` |
| `language_code` | 183 | Debian iso-codes, `data/iso_639-2.json`, the `alpha_2` fields: <https://salsa.debian.org/iso-codes-team/iso-codes/-/raw/main/data/iso_639-2.json> | Last change to the file: commit `83f51f8b396229cce6c141a8ddaeaa7505284cde` (2025-10-13) | `0e9c25b3860cec74ce9367b0434c538caac4a3128a4c91c5fc7824fdc648d479` |
| `iban` | 89 countries | SWIFT IBAN Registry (TXT), from the ISO 13616 registration authority: <https://www.swift.com/swift-resource/11971/download>, listed on <https://www.swift.com/standards/data-standards/iban-international-bank-account-number> | Updated by SWIFT on 2026-09-17 (the date on the download page). Latest entry update in the file: `Sep-26` (Brazil) | `ad13d9595a991790ad1a5a1363d574a43357c710e3bce2170f95c9bef8932df0` |

The ISO 3166-1 and ISO 639 standards are not published in a machine-readable form, so iso-codes is the primary source. The lists were also checked against these sources:

| List | Cross-check | Result |
| --- | --- | --- |
| ISO 3166-1 alpha-2 | Wikipedia, [ISO 3166-1 alpha-2](https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2), officially assigned code elements (including the 7 codes reassigned after an earlier use) | Same 249 codes |
| ISO 3166-1 alpha-3 | Wikipedia, [ISO 3166-1 alpha-3](https://en.wikipedia.org/wiki/ISO_3166-1_alpha-3), officially assigned code elements | Same 249 codes |
| ISO 639-1 | Wikipedia, [List of ISO 639 language codes](https://en.wikipedia.org/wiki/List_of_ISO_639_language_codes) | Same 183 codes |
| ISO 639-1 | iso-codes `iso_639-3.json`, `alpha_2` fields | 184 codes: the same plus `sh` (Serbo-Croatian), which ISO 639-1 deprecated and which is not in ISO 639-2 |
| ISO 4217 | SIX List Three (historic codes), `Pblshd="2026-01-01"` | `ANG` withdrawn 2025-03, `BGN` 2026-01, `SLL` 2023-12 |
| IBAN registry | [schwifty](https://github.com/mdomke/schwifty) `iban_registry/generated.json`, regenerated from the SWIFT file on 2026-10-25 | Same 89 prefixes and lengths. Schwifty also lists the 16 territories under FR, GB and FI as separate keys; see the policy below |

The Library of Congress ISO 639-2 table (<https://www.loc.gov/standards/iso639-2/ISO-639-2_utf-8.txt>) is the registration authority's own list, but it answered every automated request with HTTP 403 on 2026-11-03.

swift.com rejects automated downloads. The registry file above is the Wayback Machine capture of 2026-09-30 (<https://web.archive.org/web/20260930225706id_/https://www.swift.com/swift-resource/11971/download?language=en>), after SWIFT's update of 2026-09-17; no later capture had different content. Compared with the capture of 2026-05-10, only Brazil's entry changed in substance: its BBAN structure (`8!n` to `8!c` for the bank code, `1!a` to `1!c` for the account type) and its example. `iban` does not check BBAN structure, so its table is unchanged.

## Changes made from this snapshot

| List | Before | After | Added | Removed |
| --- | --- | --- | --- | --- |
| ISO 4217 List One | 177 | 178 | `XAD` (Arab Accounting Dinar, a fund code of the Arab Monetary Fund) | none |
| ISO 3166-1 alpha-2 | 249 | 249 | none | none |
| ISO 3166-1 alpha-3 | 249 | 249 | none | none |
| ISO 639-1 | 183 | 183 | none | none |
| IBAN registry | 89 | 89 | none | none; no length changed |

## Policy

- **ISO 3166-1:** officially assigned codes only. User-assigned codes, including `XK` for Kosovo, exceptionally reserved codes (`UK`, `EU`), transitionally reserved and withdrawn codes are rejected.
- **ISO 4217:** every alphabetic code currently in List One, including fund codes (`BOV`, `CHE`, `XAD`), precious metals (`XAU`, `XAG`, `XPD`, `XPT`), `XDR`, `XTS` (testing) and `XXX` (no currency). Historic codes (List Three) are rejected.
- **ISO 639-1:** the two-letter codes of ISO 639-2. Deprecated codes (`bh`, `sh`) and withdrawn codes (`iw`, `in`, `ji`) are rejected.
- **IBAN:** every country in the SWIFT IBAN Registry, with the registry's length. The registry file has no partial or provisional entries: each of the 89 has an effective date. Experimental IBANs outside the registry, which some banks publish (`DZ`, `AO`, `IR`, `SN` and others), are rejected. Territories that the registry lists under another country use that country's prefix, so their own codes are not prefixes: `GF`, `GP`, `MQ`, `RE`, `PF`, `TF`, `YT`, `NC`, `BL`, `MF`, `PM` and `WF` use `FR`; `IM`, `JE` and `GG` use `GB`; `AX` uses `FI`. `XK` is in the registry, so `iban` accepts it although `country_code` does not.

## Refresh the lists

Run this before each release, and at least every three months: ISO 4217 and the IBAN registry change several times a year.

1. Download "IBAN Registry (TXT)" from the SWIFT page above (swift.com blocks scripts). Without the file, `refresh.py` uses the latest Wayback Machine capture, which can be stale.
2. From `pg_validate/`, run:

   ```bash
   data/refresh.py --iban-registry ~/Downloads/IBAN_Registry.txt
   ```

   It prints each source's version, checksum and count, and the codes to add and remove. It exits 1 if any list differs. Python 3.9 or later, standard library only.
3. For a list that differs, `--sql` prints the regenerated string literal or `case` arms to paste into `pg_validate--0.0.1.sql` (or the next version's script), and `--examples` prints the registry example IBANs as rows for `test/spec/15_financial.sql`.
4. Update the counts in `test/spec/13_international.sql`, add cases for the codes added and removed, and update this file, the comments above the validators, and `docs/reference/international.md` and `financial.md`.
5. Run `docker/run-matrix.sh` and `npm run docs:build`.

## IDNA tables

`validate._idna_label` embeds one table of code point ranges for the IDNA2008 checks, and `validate._idna_hostname` the list of code points that the UTS #46 mapping ignores. Both are generated blocks in `pg_validate--0.0.1.sql`, between `-- BEGIN GENERATED ... by data/refresh_idna.py --sql` and `-- END GENERATED ...`.

Retrieved 2026-11-05. The SHA-256 is of the file as fetched.

| Data | Source | Version | SHA-256 |
| --- | --- | --- | --- |
| Derived property of every code point: PVALID, CONTEXTJ, CONTEXTO, DISALLOWED, UNASSIGNED (RFC 5892) | IANA IDNA Parameters: <https://www.iana.org/assignments/idna-tables-12.0.0/idna-tables-properties.csv> | 12.0.0, the latest version in the registry | `160b72e33a377a84253393c572dc338879f39b93beccbb9cb9baebbf4d6dd743` |
| Bidi_Class, for the Bidi rule (RFC 5893) | <https://www.unicode.org/Public/12.0.0/ucd/extracted/DerivedBidiClass.txt> | Unicode 12.0.0 | `a50670c09adf9a7f6e7344bdef81d5c8a2c5d116191c6f141bd772f149d8ecdc` |
| Joining_Type, for ZERO WIDTH NON-JOINER (RFC 5892 A.1) | <https://www.unicode.org/Public/12.0.0/ucd/extracted/DerivedJoiningType.txt> | Unicode 12.0.0 | `2a92a39d6713b8cc9a6d4eb808efaf93c52a4fcc01c149fec9892113838dae8b` |
| Canonical_Combining_Class = Virama (A.1, A.2) | <https://www.unicode.org/Public/12.0.0/ucd/extracted/DerivedCombiningClass.txt> | Unicode 12.0.0 | `a857ee16245430a68577c060adbeae6e72cb25aac1dcd5f6c940eb0fdcee31f6` |
| General_Category M, for a leading combining mark (RFC 5891 §4.2.3.2) | <https://www.unicode.org/Public/12.0.0/ucd/extracted/DerivedGeneralCategory.txt> | Unicode 12.0.0 | `d4db33ff590a6c80d7c34d2968595586ae59bfb280978470b6e2fa2b34808405` |
| Script Greek, Hebrew, Hiragana, Katakana, Han (A.4 to A.7) | <https://www.unicode.org/Public/12.0.0/ucd/Scripts.txt> | Unicode 12.0.0 | `bd327cbb8bffd2e4b40b1e9842c9a7d641d1c4e91c34a41020cf174f3a1c86a1` |
| Code points with status "ignored" in the UTS #46 mapping | <https://www.unicode.org/Public/idna/12.0.0/IdnaMappingTable.txt> | 12.0.0 | `87848ce5634c2b018a88dd8e97dd4dfdf575fd2861c3f930817f272e7433d912` |

What the table holds: the 123,006 PVALID, 2 CONTEXTJ and 25 CONTEXTO code points of IANA 12.0.0, as 2,865 ranges in 34 classes. Each class records the derived property, the Bidi class, whether the code point is a combining mark or a virama, its joining type, and whether its script is one of the five that the contextual rules name. Every other code point is a gap, rejected as DISALLOWED or UNASSIGNED. The UCD files are of the same Unicode version as the IANA table, so every attribute describes the same character repertoire.

### Policy and known gaps

- **Unicode version.** IANA has not published derived property tables after 12.0.0. Characters added in Unicode 13.0 and later are UNASSIGNED in this table and rejected, although newer derivations (for example the Python `idna` package's) list many of them as PVALID. Deriving the table from a newer UCD with the RFC 5892 algorithm is possible, but it would no longer be IANA's published table; this release keeps the registry's version.
- **Mapping.** `idn_hostname` applies a subset of UTS #46: it removes the ignored code points, normalizes to NFKC with Postgres's own Unicode tables (`normalize()`), maps U+3002 to `.` and lowercases ASCII. It does not apply the rest of the UTS #46 mapping table, which case-folds non-ASCII letters and maps other characters that NFKC leaves alone; embedding it would add its 5,522 "mapped" entries, most with a replacement string.
- **What is not stored.** Only the attributes the IDNA2008 rules use. Names, ages and the other UCD properties are not needed.

### Refresh the IDNA tables

From `pg_validate/`:

```bash
data/refresh_idna.py            # compare the SQL file with the sources
data/refresh_idna.py --sql      # also print the two generated blocks
```

It exits 1 when a block differs. To move to a newer version, change the version in the URLs at the top of the script, replace the two blocks with the `--sql` output, run `test/run.sh 11_internet 42_`, and update this section and the reference of `idn_hostname`. Python 3.9 or later, standard library only.
