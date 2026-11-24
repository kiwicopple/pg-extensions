# Errors and limits

Version 0.0.5 generates IDs from the database clock. UUID and KSUID generators use Postgres `random()`; ULID uses the built-in UUIDv4 generator. Use a unique constraint for identity and a separate timestamp for application time.

## Randomness and collisions

The UUID and KSUID generators do not use a cryptographic random source. ULID uses 80 bits from Postgres's strong random source, excluding UUIDv4's fixed version and variant bits. Do not use these IDs as passwords, API keys, reset tokens or proof that a caller is authorized. For the UUID and KSUID generators, the number of bits reserved in the output is not a guarantee of that many bits of random entropy.

No function checks existing rows for collisions. A primary key or unique constraint rejects a duplicate; the generator itself does not retry. If an application retries a failed insert, handle the specific constraint violation and generate a new ID.

## Time rounding

The UUID functions assign fractional epoch seconds to `bigint`, which rounds rather than truncates. They then add a separately extracted fractional component. In the latter half of a second this can put the encoded time roughly one second ahead of the sampled clock. UUIDv7's millisecond and microsecond assignments also round.

The KSUID functions store epoch seconds in `numeric(50)`, whose scale is zero, so those seconds are also rounded. The microsecond variant then adds its fractional time field separately.

These are properties of the shipped implementation, not guarantees of standard-conformant timestamp encoding. Even with a stable clock, transitions between seconds can break generation order. Clock adjustments, concurrent sessions, ties and random payloads add further reasons not to treat IDs as a strict sequence. No monotonic counter or rollback handling is implemented.

KSUID encoding reserves a 32-bit seconds field and does not explicitly check its bounds. The documented 27-character representation is for timestamps within the supported layout, not arbitrary clock values.

ULID floors the complete Unix millisecond value and checks that it fits in 48 bits. It does not have the rounding behavior above. A clock outside the range 0 through 281474976710655 Unix milliseconds raises SQLSTATE `22008`. Same-millisecond calls and clock rollback do not preserve generation order.

## Timestamp extraction

The extractor truncates milliseconds and accepts any `uuid`, without checking its version or variant. Its `timestamp` return value carries no timezone label. See [read timestamps](guides/timestamps.md) before using it in comparisons.

## Common failures

| Symptom | Explanation and next step |
| --- | --- |
| Extension is not available | Install the control and SQL files on the target server, or use a provider-supported install method. |
| Function does not exist | Check the database, installed schema and version. Qualify the call with the actual schema. |
| Permission denied for schema or function | Have the owner grant the application role schema `usage` and function `execute`. |
| Invalid input syntax for type uuid | The supplied text cannot be cast to `uuid`; the extractor has not run. |
| Time zone not recognized | Supply a timezone recognized by the server, such as `UTC`. |
| Duplicate key violates unique constraint | The supplied or generated ID already exists. Keep the constraint and handle the conflict. |
| Null value violates not-null constraint | An explicit null bypasses the default. Omit the ID or use `default`. |

The ULID generator explicitly raises `22008` for an out-of-range clock. Other errors come from Postgres operations used by the functions and from table constraints. Failure of the strong random source is propagated; ULID never falls back to `random()`.
