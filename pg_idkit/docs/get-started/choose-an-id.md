# Choose an ID

Choose the database type and external representation your application needs. All four generators use the database clock and pseudo-random values; none promises collision-free or strictly increasing output.

| Generator | Column type | Representation | Use when |
| --- | --- | --- | --- |
| UUIDv7 | `uuid` | Standard UUID text when displayed | You want UUID storage and a readable Unix time field |
| UUIDv6 | `uuid` | Standard UUID text when displayed | An integration expects UUIDv6 |
| KSUID seconds | `text collate "C"` | 27 base62 characters | An integration uses KSUID-shaped strings |
| KSUID microseconds | `text collate "C"` | 27 base62 characters | You control both ends and want this variant's finer time field |

UUID values use Postgres's native `uuid` type. KSUID values are text; the `C` collation preserves the generator's base62 byte ordering. The microsecond variant repurposes part of the random payload for time, so a conventional KSUID decoder will not expose that extra time field.

These are the choices implemented by this extension, not a promise of strict standard conformance or a comparison with every Postgres ID option. The current implementation rounds time components; review [errors and limits](../errors-and-limits.md) before relying on timestamp ordering or external decoders.

For a first example, follow the [UUIDv7 quickstart](quickstart.md). For text IDs, see the [KSUID reference](../reference/ksuid.md).
