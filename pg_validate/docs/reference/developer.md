# Developer format validators

Validators for encodings and small languages that applications store as text. Each takes `value text` and returns `boolean`, and is `IMMUTABLE STRICT PARALLEL SAFE`.

| Function | Format | Specification |
| --- | --- | --- |
| [`base64`](#base64) | Base64, padded, canonical | RFC 4648 §4 |
| [`base64url`](#base64url) | Base64url, padding optional | RFC 4648 §5 |
| [`hex`](#hex) | Hex-encoded bytes | RFC 4648 §8 |
| [`json_pointer`](#json_pointer) | JSON Pointer | RFC 6901 |
| [`relative_json_pointer`](#relative_json_pointer) | Relative JSON Pointer | draft-handrews-relative-json-pointer-01 |
| [`uri_template`](#uri_template) | URI Template, levels 1 to 4 | RFC 6570 §2 |
| [`regex`](#regex) | ECMA-262 regular expression | ECMA-262 2025 §22.2.1, Unicode mode |
| [`cron`](#cron) | Five-field cron schedule | POSIX crontab, Vixie cron |

### `base64`

```text
validate.base64(value text) returns boolean
```

Accepts RFC 4648 §4 base64: the standard alphabet (`A-Z a-z 0-9 + /`), padded with `=` to a multiple of four characters. The encoding must be canonical (§3.5): the unused bits in the last character before the padding are zero, so each byte string has exactly one valid encoding (`Zg==` passes, `Zh==` does not). The empty string encodes zero bytes and passes. The test suite uses RFC 4648 §10's test vectors.

Not accepted: line breaks and other white space (MIME base64, RFC 2045), missing padding, and the URL-safe alphabet.

**Guarantees:** `decode(value, 'base64')` succeeds, and `encode` of the result gives the same text back, apart from the line break that `encode` adds every 76 characters.

**Does not guarantee:** anything about the decoded bytes, such as a file type or a maximum size. Limit the size with `octet_length(value) <= n`.

### `base64url`

```text
validate.base64url(value text) returns boolean
```

Accepts RFC 4648 §5 base64url: the URL- and filename-safe alphabet (`-` and `_` instead of `+` and `/`). Padding is optional, as JWS (RFC 7515 §2) and most URL uses omit it, but when present it must be correct. Pad bits must be zero.

**Guarantees:** the value decodes to exactly one byte string.

**Does not guarantee:** that it is a JWT or any other structure. A JWT is three base64url segments joined by dots; JWT structure checking is on the [roadmap](../roadmap.md).

### `hex`

```text
validate.hex(value text) returns boolean
```

Accepts bytes encoded as hexadecimal: an even number of hex digits in either case, with no `0x` prefix and no separators. The empty string is zero bytes. This is what `decode(value, 'hex')` accepts, minus the white space that `decode` ignores.

**Input form:** an even number of hex digits, in either case. Spaces, line breaks and a `0x` prefix are rejected; strip white space with `regexp_replace(value, '\s', '', 'g')`, and use `lower` only if you want one stored case. See [Canonical forms and normalizing input](../guides/normalization.md).

**Guarantees:** the value decodes to whole bytes.

**Does not guarantee:** a length. An odd-length string such as a CSS color `abc` fails; use your own check for hex numbers that are not byte strings.

### `json_pointer`

```text
validate.json_pointer(value text) returns boolean
```

Accepts an RFC 6901 JSON Pointer: the empty string (the whole document) or a sequence of `/` and a reference token, where `~` appears only in the escapes `~0` (for `~`) and `~1` (for `/`). Any other character, including non-ASCII ones, is allowed in a token. The test suite uses the examples of RFC 6901 §5.

Not accepted: the URI fragment form (`#/foo`) and relative JSON Pointers (see [`relative_json_pointer`](#relative_json_pointer)).

**Guarantees:** the value is a valid pointer that a conforming implementation can evaluate.

**Does not guarantee:** that the pointer resolves in any particular document.

### `relative_json_pointer`

```text
validate.relative_json_pointer(value text) returns boolean
```

Accepts a Relative JSON Pointer as draft-handrews-relative-json-pointer-01 §3 defines it, the version that JSON Schema Draft 2020-12 cites: a non-negative integer in ASCII digits without leading zeros (how many levels to go up), followed by `#` (the key or index there) or by a [`json_pointer`](#json_pointer). The test suite uses the draft's §5.1 examples (`0`, `1/0`, `2/highly/nested/objects`, `0#`).

Not accepted: a sign (`+1`, `-1`), leading zeros (`01`), a pointer after `#` (`1#/a`), and the index manipulation of later drafts (`0+1/a`).

**Guarantees:** the value is a valid relative pointer that an implementation of the draft can evaluate.

**Does not guarantee:** that it resolves from any particular location: going up more levels than the location has is a run-time error, not a syntax error.

### `uri_template`

```text
validate.uri_template(value text) returns boolean
```

Accepts an RFC 6570 §2 URI Template at any level up to 4: literals and expressions. A literal is any character RFC 6570 allows outside an expression (printable ASCII except space, `"`, `%`, `<`, `>`, `\`, `^`, `` ` ``, `{`, `|` and `}`, plus the non-ASCII `ucschar` and `iprivate` ranges of RFC 3987), or a complete percent-encoded triplet; the apostrophe is allowed, as erratum 6937 corrects. An expression is `{`, an optional operator (`+ # . / ; ? &`), and one or more comma-separated variables, each a name of letters, digits, `_` and percent-encoded triplets with single dots between parts, and an optional modifier: a prefix `:1` to `:9999` or the explode `*`. The test suite uses the RFC's examples.

Not accepted: the operators §2.2 reserves for future extensions (`= , ! @ |`), which no template processor can expand; empty expressions and variables; and combined modifiers (`{var:3*}`).

**Guarantees:** a level 4 template processor can parse the value.

**Does not guarantee:** that an expansion is a valid URI for any particular values, or that the template has the variables an application expects.

```sql
select validate.uri_template(value => 'https://api.example.com/users/{id}{?fields*}');
-- true
select validate.uri_template(value => '/users/{id');
-- false: unclosed expression
```

### `regex`

```text
validate.regex(value text) returns boolean
```

Accepts a regular expression `Pattern` of ECMA-262 (2025 edition) §22.2.1 in Unicode mode, the `u` flag that JSON Schema implies, with the early errors of §22.2.1.1. It is a parser of the grammar, not a test of whether Postgres can compile the pattern. It checks:

- alternatives, groups (capturing, `(?:...)`, named `(?<name>...)`), lookahead and lookbehind, and modifier groups such as `(?i:...)` and `(?-m:...)` (ES2025; each flag once, not both lists empty);
- quantifiers `* + ? {n} {n,} {n,m}`, with `n <= m` and an optional `?`, only after something that can repeat (in Unicode mode, lookarounds and `^ $ \b \B` cannot);
- character classes, including `[]` and `[^]`, with ranges in order and no class escape in a range;
- every escape: `\d \D \s \S \w \W`, `\p{...}` and `\P{...}`, `\b \B`, `\f \n \r \t \v`, `\cA`, `\0` not followed by a digit, `\xHH`, `\uHHHH` (a surrogate pair of two escapes is one character), `\u{H...}` up to `10FFFF`, and identity escapes of syntax characters and `/` only;
- backreferences `\1` to a group that exists, `\k<name>` to a name that exists, and duplicate group names only in different alternatives (ES2025).

Unicode mode rejects the Annex B leniencies that browsers accept without the `u` flag: a lone `{`, `}` or `]`, `\a` and other escaped letters, `\c` without a letter, octal escapes and quantified lookaheads. The test suite runs the JSON Schema Test Suite's `regex` and `ecmascript-regex` format cases, and passes all of them.

Checked only in part:

- `\p{...}`: General_Category values and binary properties are checked against the names ECMA-262 lists; Script and Script_Extensions values (`\p{Script=Greek}`) are checked for their shape, not against the list of scripts.
- Group names: ASCII characters follow the identifier grammar; non-ASCII characters are accepted without checking ID_Start and ID_Continue.
- The `v` flag (`unicodeSets`) syntax, such as `[\p{L}--[a-z]]`, is not accepted.

**Guarantees:** the value is a syntactically valid pattern for `new RegExp(value, 'u')`, within the limits above.

**Does not guarantee:** that Postgres can run it as a `pattern` in [`json_schema`](../json-schema.md#patterns) (named groups, lookbehind and `\p{...}` have no Postgres equivalent), that it matches anything, or that it runs in reasonable time (catastrophic backtracking is valid syntax).

```sql
select validate.regex(value => '^(?<year>[0-9]{4})-\k<year>$');
-- true
select validate.regex(value => '[z-a]');
-- false: range out of order
```

### `cron`

```text
validate.cron(value text) returns boolean
```

Accepts a standard five-field cron schedule, as POSIX crontab defines it, with the extensions of Vixie cron that cronie and pg_cron also accept:

| Field | Values | Names |
| --- | --- | --- |
| Minute | 0-59 | |
| Hour | 0-23 | |
| Day of month | 1-31 | |
| Month | 1-12 | `JAN`-`DEC`, either case |
| Day of week | 0-7 (0 and 7 are Sunday) | `SUN`-`SAT`, either case |

Each field is a comma-separated list of `*`, a value `n`, a range `n-m` (with `n <= m`), or a step over `*` or a range (`*/15`, `0-20/2`). Steps are 1 or more. Fields are separated by one or more spaces or tabs. The macros `@yearly`, `@annually`, `@monthly`, `@weekly`, `@daily`, `@midnight` and `@hourly` are also accepted.

Not accepted (extended syntax): a seconds or year field, the Quartz characters `?`, `L`, `W` and `#`, `@reboot`, a step over a single value (`5/15`), leading or trailing white space, and a command after the schedule.

**Guarantees:** the value is a schedule that Vixie cron, cronie and pg_cron parse with the same meaning.

**Does not guarantee:** that the schedule ever fires. `0 0 31 2 *` (31 February) is syntactically valid and never runs.

```sql
select validate.cron(value => '*/15 9-17 * * mon-fri');
-- true
select validate.cron(value => '0 0 L * *');
-- false: Quartz syntax
```
