# Identifier validators

Validators for generated identifiers and version strings. Each takes `value text` and returns `boolean`. All are `IMMUTABLE STRICT PARALLEL SAFE`: a null value returns null, and the result depends on the value alone.

| Function | Format | Specification |
| --- | --- | --- |
| [`uuid`](#uuid) | UUID string form, any version | RFC 9562 §4 |
| [`uuid(value, version)`](#uuid-with-a-version) | UUID of one version and the RFC variant | RFC 9562 §4.1, §4.2 |
| [`ulid`](#ulid) | ULID | ULID specification |
| [`nanoid`](#nanoid) | Nano ID, default or custom alphabet and size | Nano ID |
| [`slug`](#slug) | URL slug | This extension's definition |
| [`semver`](#semver) | Semantic version | Semantic Versioning 2.0.0 |
| [`git_sha`](#git_sha) | Full git object name | git object formats |

### `uuid`

```text
validate.uuid(value text) returns boolean
```

Accepts the RFC 9562 string form: 32 hexadecimal digits, either case, grouped 8-4-4-4-12 with hyphens. Any version and variant passes, including the Nil (`00000000-0000-0000-0000-000000000000`) and Max (`ffffffff-ffff-ffff-ffff-ffffffffffff`) UUIDs.

The `uuid` type's input function is more lenient than this: it also accepts braces, missing hyphens and hyphens after any group of four digits. `validate.uuid` accepts only the canonical layout, so text columns hold one form.

**Guarantees:** the value is in the canonical 8-4-4-4-12 layout and casts to `uuid`.

**Does not guarantee:** a particular version or variant (use the two-argument form), uniqueness, or that the value was generated randomly or by any particular algorithm.

```sql
select validate.uuid(value => '017f22e2-79b0-7cc3-98c4-dc0c0c07398f');
-- true
select validate.uuid(value => '{017f22e2-79b0-7cc3-98c4-dc0c0c07398f}');
-- false: braces
```

For a `uuid` column, the type itself validates; this function is for UUIDs stored in `text` or `jsonb`.

### `uuid` with a version

```text
validate.uuid(value text, version int) returns boolean
```

Accepts a value that passes `validate.uuid(value)`, has the RFC 9562 variant (§4.1: the 17th hex digit is `8`, `9`, `a` or `b`) and has the given version in the version nibble (§4.2: the 13th hex digit). `version` must be 1 to 8; any other value raises `22023`. The Nil and Max UUIDs have no version and fail for every version.

This overload is not in the registry; `validate.format('uuid', ...)` calls the one-argument form. To register "UUIDv7" as a format, wrap it in a one-argument function (see [Custom formats](../registry.md)).

**Guarantees:** the canonical layout, the RFC variant and the requested version number.

**Does not guarantee:** that the rest of the value follows the version's layout. For version 7, the timestamp in the first 48 bits is not checked against the clock; for versions 3 and 5, the hash is not recomputed.

```sql
select validate.uuid(
  value => '017f22e2-79b0-7cc3-98c4-dc0c0c07398f',
  version => 7
);
-- true
```

### `ulid`

```text
validate.ulid(value text) returns boolean
```

Accepts a [ULID](https://github.com/ulid/spec): 26 characters of Crockford's Base32 (`0-9`, `A-Z` without `I`, `L`, `O`, `U`), in either case. The first character is `0` to `7`, because 26 characters hold 130 bits and a ULID has 128; `8ZZZZZZZZZZZZZZZZZZZZZZZZZ` overflows.

Crockford's decoding of `I`, `L` and `O` as `1`, `1` and `0` is not applied: the ULID specification excludes them.

**Guarantees:** the value decodes to a 128-bit ULID.

**Does not guarantee:** that its 48-bit timestamp is plausible, or monotonic ordering.

### `nanoid`

```text
validate.nanoid(value text) returns boolean
validate.nanoid(value text, size int, alphabet text default '_-0-9a-zA-Z') returns boolean
```

The one-argument form accepts [Nano ID](https://github.com/ai/nanoid)'s default: exactly 21 characters of `A-Z a-z 0-9 _ -`. The second form checks a `customAlphabet(alphabet, size)` ID: exactly `size` characters, each in `alphabet`. `size` below 1 or an empty alphabet raises `22023`. Only the one-argument form is in the registry.

**Guarantees:** the length and the alphabet.

**Does not guarantee:** randomness or uniqueness. Any 21-character string over the alphabet passes, including `_____________________`.

```sql
select validate.nanoid(
  value => '4f90d13a42',
  size => 10,
  alphabet => '0123456789abcdef'
);
-- true
```

### `slug`

```text
validate.slug(value text) returns boolean
```

Accepts lowercase ASCII letters and digits in groups joined by single hyphens: `hello-world`, `2026-roadmap`, `a`. There is no published standard; this is the form most frameworks generate.

**Guarantees:** the value is non-empty, lowercase ASCII, and has no leading, trailing or doubled hyphen. It is safe to use as a URL path segment without encoding.

**Does not guarantee:** a maximum length (add `char_length(slug) <= 80` to the constraint if you need one) or uniqueness.

### `semver`

```text
validate.semver(value text) returns boolean
```

Accepts a [Semantic Versioning 2.0.0](https://semver.org) version: `MAJOR.MINOR.PATCH` with numbers without leading zeros, an optional pre-release (`-` and dot-separated identifiers; numeric identifiers without leading zeros) and optional build metadata (`+` and dot-separated identifiers). It implements the specification's complete BNF, using the regular expression that semver.org recommends, and is tested against semver.org's lists of valid and invalid versions.

**Guarantees:** the value is a valid SemVer 2.0.0 version.

**Does not guarantee:** a range or constraint syntax (`^1.2`, `>=1.0.0 <2.0.0`), a leading `v` (`v1.2.3` is rejected), or that the numbers fit in an integer type: `99999999999999999999999.0.0` is valid SemVer.

```sql
select validate.semver(value => '1.0.0-alpha.1+build.5');
-- true
select validate.semver(value => '1.2.3-0123');
-- false: numeric pre-release with a leading zero
```

### `git_sha`

```text
validate.git_sha(value text) returns boolean
```

Accepts a full git object name: 40 lowercase hexadecimal digits (SHA-1) or 64 (SHA-256 repositories). Git prints object names in lowercase.

**Guarantees:** the length and lowercase hex digits.

**Does not guarantee:** that the object exists in any repository, or which kind of object (commit, tree, blob) it names. Abbreviated names such as `e83c516` are rejected.
