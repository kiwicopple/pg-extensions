# KSUID generators

These functions return 27-character text values using the base62 alphabet `0-9`, `A-Z`, `a-z`. Use `text collate "C"` for byte-order comparisons. Both read `clock_timestamp()` and use `random()`; the sizes of their random fields are not claims of equivalent random entropy.

### `gen_random_ksuid_second`

```text
extensions.gen_random_ksuid_second() → text
```

Combines a seconds field relative to Unix epoch value 1400000000 (2014-05-13 16:53:20 UTC) with a 128-bit payload assembled from three calls to `random()`, then encodes and pads the result to 27 base62 characters.

**Guarantees:** for current timestamps within the format's range, produces a fixed-width base62 string suitable for a text column default.

**Does not guarantee:** uniqueness, cryptographic unpredictability or ordering of calls within a second. The seconds field is rounded, not floored. The function does not explicitly guard the 32-bit seconds range; see [errors and limits](../errors-and-limits.md).

```sql
select length(extensions.gen_random_ksuid_second());
-- 27
```

### `gen_random_ksuid_microsecond`

```text
extensions.gen_random_ksuid_microsecond() → text
```

Uses the same epoch and encoding, with 20 bits for microseconds and a 108-bit random payload assembled from two calls to `random()`. This is the extension's microsecond variant; a conventional KSUID decoder treats those microsecond bits as part of the payload.

**Guarantees:** for current timestamps within the format's range, produces a 27-character base62 string with an additional time field.

**Does not guarantee:** uniqueness, cryptographic unpredictability, strict monotonicity or exact microsecond ordering. The seconds field is rounded before the microseconds field is added.

```sql
select length(extensions.gen_random_ksuid_microsecond());
-- 27
```

The extension exposes no KSUID decoder or validator. Use [primary keys](../guides/primary-keys.md) for table defaults and collation examples.
