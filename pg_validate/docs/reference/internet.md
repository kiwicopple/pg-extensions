# Internet validators

Validators for addresses and names on the internet. Each takes `value text` and returns `boolean`, and is `IMMUTABLE STRICT PARALLEL SAFE`. Most accept ASCII only, with internationalized domain names as A-labels (`xn--...`); [`idn_email`](#idn_email), [`idn_hostname`](#idn_hostname), [`iri`](#iri) and [`iri_reference`](#iri_reference) also accept non-ASCII text, and need a database with the `UTF8` encoding for it.

| Function | Format | Specification |
| --- | --- | --- |
| [`email`](#email) | Email address | RFC 5322 §3.4.1 addr-spec, RFC 5321 §4.1.2, §4.5.3 |
| [`url`](#url) | Absolute http or https URL | RFC 3986, RFC 9110 §4.2 |
| [`uri`](#uri) | URI with any scheme | RFC 3986 §3 |
| [`uri_reference`](#uri_reference) | URI or relative reference | RFC 3986 §4.1 |
| [`iri`](#iri) | Internationalized URI | RFC 3987 §2.2 |
| [`iri_reference`](#iri_reference) | IRI or relative reference | RFC 3987 §2.2 |
| [`hostname`](#hostname) | Host name | RFC 1123 §2.1, RFC 1035 §2.3.4; A-labels RFC 5891 |
| [`idn_hostname`](#idn_hostname) | Internationalized host name | RFC 5890-5893 (IDNA2008), UTS #46 mapping subset |
| [`idn_email`](#idn_email) | Internationalized email address | RFC 6531 §3.3 |
| [`domain`](#domain) | Domain name with a top-level domain | RFC 1123, RFC 3696 §2 |
| [`ipv4`](#ipv4) | IPv4 address | RFC 3986 §3.2.2 |
| [`ipv6`](#ipv6) | IPv6 address | RFC 3986 §3.2.2, RFC 4291 §2.2 |
| [`mac`](#mac) | MAC-48 / EUI-48 address | IEEE 802 |
| [`port`](#port) | TCP or UDP port | RFC 6335 |

### `email`

```text
validate.email(value text) returns boolean
```

Accepts an RFC 5322 `addr-spec`, limited to the forms that SMTP (RFC 5321) can deliver:

| Part | Accepted |
| --- | --- |
| Local part | A dot-atom of RFC 5322 `atext` characters (letters, digits and ``!#$%&'*+/=?^_`{\|}~-``), separated by single dots; or a quoted string such as `"joe bloggs"` with RFC 5321 `qtextSMTP` and backslash escapes. At most 64 octets. |
| Domain | Host name labels (RFC 1123, see [`hostname`](#hostname)), a single label allowed; or an address literal `[192.0.2.1]` or `[IPv6:2001:db8::1]`. |
| Whole address | At most 254 octets: the RFC 5321 path limit of 256 less the angle brackets (RFC 3696 erratum 1690). |

Not accepted: comments and folding white space (`(comment)joe@example.com`), the obsolete syntax of RFC 5322 §4, general address literals (`[tag:content]`), and non-ASCII addresses (RFC 6531 SMTPUTF8, such as `jöe@example.com`; use [`idn_email`](#idn_email)). Domain labels that start with `xn--` must be valid A-labels, as in [`hostname`](#hostname).

The test suite includes the JSON Schema Test Suite's `email` format cases, and passes all of them.

**Guarantees:** the value is a syntactically valid address that an SMTP client can put in `RCPT TO`, within the protocol's length limits.

**Does not guarantee:** deliverability. The domain may not exist or have no MX record, the mailbox may not exist, and the address may belong to someone else. Verify an address by sending mail to it. Single-label domains such as `admin@localhost` pass, because they are valid syntax; add `and email like '%@%.%'` to the constraint if you need a dot in the domain.

```sql
select validate.email(value => '"joe bloggs"@example.com');
-- true
select validate.email(value => 'te..st@example.com');
-- false: two dots in a row
```

**Input form:** the address with no leading or trailing space. Case is preserved and either case is accepted: the validator neither trims nor folds case. RFC 5321 treats the local part as case-sensitive, so lowercasing it is an application choice, not a validation fix; use `btrim(value)` to remove stray spaces. Email addresses are case-insensitive in the domain and usually in practice in the local part: compare with `lower(email)` in a unique index if you need case-insensitive uniqueness. See [Canonical forms and normalizing input](../guides/normalization.md).

### `url`

```text
validate.url(value text) returns boolean
```

Accepts an absolute `http` or `https` URL, the kind a browser can open:

- The scheme is `http` or `https`, in either case.
- An authority is present, with a host: a DNS host name (RFC 1123 labels, one trailing dot allowed), an IPv4 address, or an IPv6 address in brackets.
- The port, if present, is 0 to 65535 and not empty.
- There is no userinfo (`user:password@`). RFC 9110 §4.2.4 forbids it in http and https URIs.
- The path, query and fragment follow RFC 3986, so spaces and other unencoded characters are rejected. Percent-encoding must be complete (`%7E`).

**Guarantees:** the value parses as an http or https URI with a usable host and port.

**Does not guarantee:** that the host resolves, that the server responds, or that the URL is safe to fetch. A URL can name a private address (`http://10.0.0.1/`); check the host separately before fetching user-supplied URLs (server-side request forgery). Internationalized URLs must be converted to ASCII first, or checked with [`iri`](#iri), which accepts any scheme.

```sql
select validate.url(value => 'https://example.com:8443/a?b=c#d');
-- true
select validate.url(value => 'https://user:pw@example.com/');
-- false: userinfo
```

### `uri`

```text
validate.uri(value text) returns boolean
```

Accepts an RFC 3986 §3 `URI`: a scheme, `:`, a hierarchical part (an authority and path, or a path alone), an optional query and an optional fragment. Any scheme is allowed (`mailto:`, `urn:`, `tel:`, `file:///`). The host can be a registered name with percent-encoding and sub-delimiters, an IPv4 address, an IPv6 address or an IPvFuture literal. The port can be empty. The validator splits the value with RFC 3986 Appendix B, then checks each component against its ABNF.

**Guarantees:** the value is a valid absolute URI, so a conforming parser can split it into components.

**Does not guarantee:** that the scheme is registered, that the scheme-specific syntax is valid (for example, that a `mailto:` address is a valid email), or that the resource exists. Relative references are rejected; use [`uri_reference`](#uri_reference).

### `uri_reference`

```text
validate.uri_reference(value text) returns boolean
```

Accepts an RFC 3986 §4.1 `URI-reference`: a URI, or a relative reference such as `../a?b#c`, `//example.com/x`, `#frag` or the empty string. A relative path's first segment cannot contain a colon (`a:b` is a URI with the scheme `a`; `:a` is invalid).

**Guarantees:** the value is a valid URI or relative reference.

**Does not guarantee:** that it resolves to anything against a particular base URI.

### `iri`

```text
validate.iri(value text) returns boolean
```

Accepts an RFC 3987 §2.2 `IRI`: the grammar of [`uri`](#uri), where every place that allows an unreserved character also allows a `ucschar` (most non-ASCII characters: U+00A0 to U+D7FF, U+F900 to U+FDCF, U+FDF0 to U+FFEF, and planes 1 to 14 except each plane's last two code points and the start of plane 14), and the query also allows `iprivate` (the private use areas U+E000 to U+F8FF and planes 15 and 16). The scheme, IP literals and the port stay ASCII. Percent-encoding must be complete, as in a URI.

Not accepted: C1 controls (U+0080 to U+009F), the specials U+FFF0 to U+FFFD, noncharacters, private use characters outside the query, spaces and backslashes.

**Guarantees:** the value is a valid absolute IRI, so it maps to a URI by percent-encoding its non-ASCII characters (RFC 3987 §3.1).

**Does not guarantee:** that the host is a valid internationalized domain name (an `ireg-name` is any sequence of allowed characters; check it with [`idn_hostname`](#idn_hostname) if you need IDNA), RFC 3987 §4.1's recommendations for bidirectional text, or anything [`uri`](#uri) does not guarantee.

```sql
select validate.iri(value => 'https://例え.テスト/パス?q=値');
-- true
select validate.iri(value => 'https://example.com/a b');
-- false: a space
```

### `iri_reference`

```text
validate.iri_reference(value text) returns boolean
```

Accepts an RFC 3987 §2.2 `IRI-reference`: an IRI, or a relative reference with the same character rules, such as `/パス`, `//例え.テスト/`, `#ƒrägmênt` or the empty string.

**Guarantees:** the value is a valid IRI or relative IRI reference.

**Does not guarantee:** that it resolves to anything against a particular base IRI.

### `hostname`

```text
validate.hostname(value text) returns boolean
```

Accepts a host name under RFC 1123 §2.1: labels of ASCII letters, digits and hyphens, separated by dots, each 1 to 63 characters (RFC 1035 §2.3.4) that start and end with a letter or digit. At most 253 characters in total (255 octets in DNS wire format). A single label (`localhost`) is valid.

A label that starts with `xn--`, in either case, is an IDNA A-label and must be a valid one (RFC 5891 §5.4): its Punycode (RFC 3492) decodes, encodes back to the same text, contains a non-ASCII character, is in Unicode NFC, and is a valid U-label under the same rules as [`idn_hostname`](#idn_hostname). When an A-label holds right-to-left characters, every label of the name must satisfy the Bidi rule (RFC 5893). Other labels follow RFC 1123 only, so `ab--cd` is valid here.

Not accepted: a trailing dot, underscores (`_dmarc.example.com` is a DNS name but not a host name), non-ASCII labels (use [`idn_hostname`](#idn_hostname)), and `xn--` labels that are not valid A-labels (`xn--X`, or `xn--ls8h`, which decodes to an emoji).

**Guarantees:** the value is a syntactically valid host name, and each A-label in it stands for a valid internationalized label.

**Does not guarantee:** that it resolves, or that it is not an IPv4 address: `192.168.0.1` is also valid host name syntax. Use [`domain`](#domain) to require a top-level domain, or [`ipv4`](#ipv4) to tell addresses apart. A-labels are checked against IDNA2008 tables for Unicode 12.0, with the gaps listed under [`idn_hostname`](#idn_hostname). In a database whose encoding is not `UTF8`, the NFC check of A-labels is skipped.

### `domain`

```text
validate.domain(value text) returns boolean
```

Accepts a [`hostname`](#hostname) with at least two labels whose last label, the top-level domain, is 2 to 63 letters or an IDN A-label (`xn--...`). RFC 3696 §2 notes that top-level domains are never all-numeric, so IPv4 addresses are rejected.

**Guarantees:** the value has the shape of a registrable domain name.

**Does not guarantee:** that the top-level domain exists in the root zone (`example.invalidtld` passes), or that the domain is registered.

### `idn_hostname`

```text
validate.idn_hostname(value text) returns boolean
```

Accepts an internationalized host name (RFC 5890 §2.3.2.3): labels that are U-labels (`münchen`), A-labels (`xn--mnchen-3ya`) or ASCII letter-digit-hyphen labels, separated by `.`, U+3002 IDEOGRAPHIC FULL STOP, U+FF0E FULLWIDTH FULL STOP or U+FF61 HALFWIDTH IDEOGRAPHIC FULL STOP. Before the checks, the value is mapped the way a browser maps user input, as a subset of UTS #46 §4.1: the code points UTS #46 ignores (soft hyphen, zero width space, variation selectors and a few others) are removed, the value is normalized to NFKC (which turns full-width letters and digits into ASCII and a non-NFC `café` into NFC), and ASCII letters are lowercased.

Each label is then checked against IDNA2008:

| Rule | Source |
| --- | --- |
| Every code point is PVALID, or CONTEXTJ / CONTEXTO with its contextual rule satisfied: ZERO WIDTH (NON-)JOINER after a virama or between joining letters, MIDDLE DOT between two `l`, Greek KERAIA before Greek, Hebrew GERESH and GERSHAYIM after Hebrew, KATAKANA MIDDLE DOT with Hiragana, Katakana or Han, and the two sets of Arabic-Indic digits not mixed | RFC 5892 §2.6, §2.7, Appendix A |
| No hyphen first or last, and no `--` in the third and fourth positions (for ASCII labels too, except A-labels) | RFC 5891 §4.2.3.1, RFC 5890 §2.3.1 |
| No combining mark first | RFC 5891 §4.2.3.2 |
| A-labels decode and re-encode exactly, contain a non-ASCII character and are NFC | RFC 5891 §5.3, RFC 3492 |
| Each label at most 63 octets and the name at most 253, both measured in A-label form | RFC 5890 §2.3.2.1 |
| In a name with any right-to-left label, every label satisfies the Bidi rule | RFC 5893 §2 |

The derived properties come from IANA's IDNA tables for Unicode 12.0.0, the latest version IANA publishes, and the Bidi classes, joining types, virama class, scripts and combining marks from the Unicode 12.0.0 character database. [`data/README.md`](https://github.com/kiwicopple/pg-extensions/blob/main/pg_validate/data/README.md) records the sources, and `data/refresh_idna.py` regenerates the embedded table. The test suite runs the JSON Schema Test Suite's `idn-hostname` and `hostname` cases, and passes all of them.

Not accepted, although a browser would accept them:

- Non-ASCII uppercase letters (`MÜNCHEN.de`). UTS #46 case-folds them; this validator lowercases ASCII only, and IDNA2008 makes uppercase letters DISALLOWED.
- Characters added in Unicode 13.0 or later, which the 12.0.0 tables list as UNASSIGNED.
- A trailing dot (the root label).

`ß`, final sigma `ς`, ZERO WIDTH JOINER and ZERO WIDTH NON-JOINER are kept as they are (IDNA2008 and UTS #46 nontransitional processing), not mapped to `ss`, `σ` or nothing as the obsolete transitional processing did.

**Guarantees:** each label is a valid U-label, A-label or LDH label under IDNA2008 after the mapping, so the name has a valid A-label form of at most 253 octets.

**Does not guarantee:** that the name is registered or resolves, that it is not confusable with another name (homographs such as Cyrillic `а` for Latin `a` are valid), or that a registry allows its script. In a database whose encoding is not `UTF8`, non-ASCII input raises an error, because Unicode normalization needs `UTF8`.

```sql
select validate.idn_hostname(value => 'münchen.de');
-- true
select validate.idn_hostname(value => '例え。テスト');
-- true: U+3002 separates labels
select validate.idn_hostname(value => 'a·b.example');
-- false: MIDDLE DOT outside l·l
```

### `idn_email`

```text
validate.idn_email(value text) returns boolean
```

Accepts an internationalized email address, RFC 6531 §3.3: the `addr-spec` of [`email`](#email) where the local part may also contain any non-ASCII character (RFC 6532 `UTF8-non-ascii`), in a dot-atom or a quoted string, and the domain is an [`idn_hostname`](#idn_hostname) or an address literal. The local part is at most 64 octets and the address at most 254 octets, counted in UTF-8.

**Guarantees:** the value is a syntactically valid address that an SMTP client with the SMTPUTF8 extension can put in `RCPT TO`.

**Does not guarantee:** deliverability, that the receiving server supports SMTPUTF8, or that the local part is in NFC (RFC 6532 §3.1 recommends it but servers must not rely on it). Everything [`email`](#email) does not guarantee applies too. An ASCII address that [`email`](#email) accepts is accepted here, unless its domain has a label with `--` in the third and fourth positions that is not an A-label.

```sql
select validate.idn_email(value => 'δοκιμή@παράδειγμα.δοκιμή');
-- true
select validate.idn_email(value => 'user＠example.com');
-- false: U+FF20 FULLWIDTH COMMERCIAL AT is not "@"
```

### `ipv4`

```text
validate.ipv4(value text) returns boolean
```

Accepts the dotted-decimal form of RFC 3986 §3.2.2: four decimal octets 0 to 255, without leading zeros (`01.1.1.1` is rejected, because some parsers read it as octal).

**Guarantees:** the value is one IPv4 address that casts to `inet`.

**Does not guarantee:** that the address is public, routable or assigned. A prefix length (`/24`) is rejected; use the `cidr` type for networks.

### `ipv6`

```text
validate.ipv6(value text) returns boolean
```

Accepts the text forms of RFC 4291 §2.2 as RFC 3986 §3.2.2 writes them: eight groups of 1 to 4 hex digits, at most one `::` for one or more zero groups, and an optional IPv4 address in place of the last two groups (`::ffff:192.0.2.128`). Either case.

Not accepted: a zone identifier (`fe80::1%eth0`, RFC 6874) and a prefix length.

**Guarantees:** the value is one IPv6 address that casts to `inet`.

**Does not guarantee:** the canonical form of RFC 5952 (lowercase, longest zero run compressed). Normalize with `value::inet::text` if you need it.

### `mac`

```text
validate.mac(value text) returns boolean
```

Accepts a MAC-48 / EUI-48 address as six pairs of hex digits, either case, separated by colons (`00:1a:2b:3c:4d:5e`) or by hyphens (`00-1A-2B-3C-4D-5E`, the IEEE 802 canonical form). The separator is the same throughout.

**Input form:** either case, one separator throughout, no surrounding spaces. Case and separators are not normalized; use `lower(replace(btrim(value), '-', ':'))` before the check if you need one stored form. See [Canonical forms and normalizing input](../guides/normalization.md).

**Guarantees:** the value is one 48-bit address that casts to `macaddr`.

**Does not guarantee:** that the OUI is assigned. The dotted form (`001a.2b3c.4d5e`), the form without separators and 64-bit EUI-64 addresses are rejected, although `macaddr` and `macaddr8` accept some of them.

### `port`

```text
validate.port(value text) returns boolean
```

Accepts a port number in decimal: 1 to 65535, without a sign or leading zeros. Port 0 is reserved (RFC 6335 §6) and rejected.

**Guarantees:** the value is a port number that fits in a TCP or UDP header.

**Does not guarantee:** that the port is registered for any service or open.
