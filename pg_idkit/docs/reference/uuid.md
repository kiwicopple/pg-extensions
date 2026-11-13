# UUID generators

These functions return native Postgres `uuid` values. Install into `extensions` before running the examples. Both functions are declared with Postgres's default volatility (`VOLATILE`) and read `clock_timestamp()` on each call.

### `gen_random_uuid_v6`

```text
extensions.gen_random_uuid_v6() → uuid
```

Builds a UUID with a reordered timestamp based on the 1582-10-15 epoch. It sets the version nibble to 6 and the variant bits to `10`, and fills the remaining clock-sequence/node portion using `random()`.

**Guarantees:** returns a UUID with the version and variant bits set by the implementation. No arguments or sequence setup are needed.

**Does not guarantee:** unique values, a stable node identifier, cryptographic unpredictability, strict generation order or exact clock precision. The implementation rounds epoch seconds before adding microseconds; see [time rounding](../errors-and-limits.md#time-rounding).

```sql
select extensions.gen_random_uuid_v6();
-- A generated UUID; its third group starts with 6.
```

### `gen_random_uuid_v7`

```text
extensions.gen_random_uuid_v7() → uuid
```

Builds a UUID with Unix milliseconds in its leading field. The implementation places `v_usec << 2` into the following field, sets the version nibble to 7 and the variant bits to `10`, and obtains the trailing random portion from `random()`.

**Guarantees:** returns a UUID with version 7 and the variant bits set by the implementation. It can be used directly as a `uuid` column default.

**Does not guarantee:** unique values, cryptographic unpredictability, strict time ordering or an exact creation timestamp. The additional time bits are implementation-specific; do not assume another library will interpret them the same way. Epoch seconds, milliseconds and microseconds are rounded during assignment in 0.0.4.

```sql
select extensions.gen_random_uuid_v7();
-- A generated UUID; its third group starts with 7.
```

For table examples, see [primary keys](../guides/primary-keys.md). For UUIDv7 decoding, see [timestamp extraction](timestamps.md).
