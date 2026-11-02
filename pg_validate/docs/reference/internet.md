# Internet validators

Validators for addresses and names on the internet. Each takes `value text` and returns `boolean`, and is `IMMUTABLE STRICT PARALLEL SAFE`. All of them accept ASCII only: convert internationalized domain names to A-labels (`xn--...`) first.

| Function | Format | Specification |
| --- | --- | --- |
| [`email`](#email) | Email address | RFC 5322 §3.4.1 addr-spec, RFC 5321 §4.1.2, §4.5.3 |
| [`url`](#url) | Absolute http or https URL | RFC 3986, RFC 9110 §4.2 |
| [`uri`](#uri) | URI with any scheme | RFC 3986 §3 |
| [`uri_reference`](#uri_reference) | URI or relative reference | RFC 3986 §4.1 |
| [`hostname`](#hostname) | Host name | RFC 1123 §2.1, RFC 1035 §2.3.4 |
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

Not accepted: comments and folding white space (`(comment)joe@example.com`), the obsolete syntax of RFC 5322 §4, general address literals (`[tag:content]`), and non-ASCII addresses (RFC 6531 SMTPUTF8, such as `jöe@example.com`).

The test suite includes the JSON Schema Test Suite's `email` format cases, and passes all of them.

**Guarantees:** the value is a syntactically valid address that an SMTP client can put in `RCPT TO`, within the protocol's length limits.

**Does not guarantee:** deliverability. The domain may not exist or have no MX record, the mailbox may not exist, and the address may belong to someone else. Verify an address by sending mail to it. Single-label domains such as `admin@localhost` pass, because they are valid syntax; add `and email like '%@%.%'` to the constraint if you need a dot in the domain.

```sql
select validate.email(value => '"joe bloggs"@example.com');
-- true
select validate.email(value => 'te..st@example.com');
-- false: two dots in a row
```

Email addresses are case-insensitive in the domain and usually in practice in the local part. The validator does not normalize; compare with `lower(email)` in a unique index if you need case-insensitive uniqueness.

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

**Does not guarantee:** that the host resolves, that the server responds, or that the URL is safe to fetch. A URL can name a private address (`http://10.0.0.1/`); check the host separately before fetching user-supplied URLs (server-side request forgery). Internationalized URLs (IRIs) must be converted to ASCII first.

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

### `hostname`

```text
validate.hostname(value text) returns boolean
```

Accepts a host name under RFC 1123 §2.1: labels of ASCII letters, digits and hyphens, separated by dots, each 1 to 63 characters (RFC 1035 §2.3.4) that start and end with a letter or digit. At most 253 characters in total (255 octets in DNS wire format). A single label (`localhost`) is valid.

Not accepted: a trailing dot, underscores (`_dmarc.example.com` is a DNS name but not a host name), and non-ASCII labels.

**Guarantees:** the value is a syntactically valid host name.

**Does not guarantee:** that it resolves, or that it is not an IPv4 address: `192.168.0.1` is also valid host name syntax. Use [`domain`](#domain) to require a top-level domain, or [`ipv4`](#ipv4) to tell addresses apart. IDNA rules for A-labels (RFC 5891) are not checked.

### `domain`

```text
validate.domain(value text) returns boolean
```

Accepts a [`hostname`](#hostname) with at least two labels whose last label, the top-level domain, is 2 to 63 letters or an IDN A-label (`xn--...`). RFC 3696 §2 notes that top-level domains are never all-numeric, so IPv4 addresses are rejected.

**Guarantees:** the value has the shape of a registrable domain name.

**Does not guarantee:** that the top-level domain exists in the root zone (`example.invalidtld` passes), or that the domain is registered.

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

**Guarantees:** the value is one 48-bit address that casts to `macaddr`.

**Does not guarantee:** that the OUI is assigned. The dotted form (`001a.2b3c.4d5e`), the form without separators and 64-bit EUI-64 addresses are rejected, although `macaddr` and `macaddr8` accept some of them.

### `port`

```text
validate.port(value text) returns boolean
```

Accepts a port number in decimal: 1 to 65535, without a sign or leading zeros. Port 0 is reserved (RFC 6335 §6) and rejected.

**Guarantees:** the value is a port number that fits in a TCP or UDP header.

**Does not guarantee:** that the port is registered for any service or open.
