# Overview

`pg_idkit` adds four ID generators and a UUIDv7 timestamp extractor to Postgres. Functions run inside the database, so a column default can assign an ID on insert without an application round trip.

| Function | Returns | Purpose |
| --- | --- | --- |
| `gen_random_uuid_v6()` | `uuid` | Time-based UUID with a reordered timestamp |
| `gen_random_uuid_v7()` | `uuid` | UUID with Unix time in the leading bits |
| `gen_random_ksuid_second()` | `text` | 27-character base62 identifier with a seconds field |
| `gen_random_ksuid_microsecond()` | `text` | KSUID variant with a microseconds field |
| `timestamp_from_uuid_v7(uuid_v7, timezone)` | `timestamp` | Read the leading time field in a chosen timezone |

The implementation uses SQL, PL/pgSQL, `clock_timestamp()` and `random()`. It needs neither pgcrypto nor a native library. It does not maintain a sequence or coordinate generators across sessions.

Time fields make these IDs useful for approximate time grouping, but do not establish insertion or commit order. Version 0.0.4 also rounds some timestamp components, and the extractor truncates milliseconds. Keep a separate timestamp column for application dates; see [errors and limits](errors-and-limits.md).

Start with [installation](install.md) and the [quickstart](get-started/quickstart.md), or [compare the formats](get-started/choose-an-id.md).
