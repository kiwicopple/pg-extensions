# Developer format validators

Validators for encodings and small languages that applications store as text. Each takes `value text` and returns `boolean`, and is `IMMUTABLE STRICT PARALLEL SAFE`.

| Function | Format | Specification |
| --- | --- | --- |
| [`base64`](#base64) | Base64, padded, canonical | RFC 4648 §4 |
| [`base64url`](#base64url) | Base64url, padding optional | RFC 4648 §5 |
| [`hex`](#hex) | Hex-encoded bytes | RFC 4648 §8 |
| [`json_pointer`](#json_pointer) | JSON Pointer | RFC 6901 |
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

**Guarantees:** the value decodes to whole bytes.

**Does not guarantee:** a length. An odd-length string such as a CSS color `abc` fails; use your own check for hex numbers that are not byte strings.

### `json_pointer`

```text
validate.json_pointer(value text) returns boolean
```

Accepts an RFC 6901 JSON Pointer: the empty string (the whole document) or a sequence of `/` and a reference token, where `~` appears only in the escapes `~0` (for `~`) and `~1` (for `/`). Any other character, including non-ASCII ones, is allowed in a token. The test suite uses the examples of RFC 6901 §5.

Not accepted: the URI fragment form (`#/foo`) and relative JSON Pointers.

**Guarantees:** the value is a valid pointer that a conforming implementation can evaluate.

**Does not guarantee:** that the pointer resolves in any particular document.

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
