# Timestamp extraction

Read the leading time field of a UUIDv7. This utility decodes bits; it does not authenticate when an ID was created.

### `timestamp_from_uuid_v7`

```text
extensions.timestamp_from_uuid_v7(
  uuid_v7 uuid,
  timezone text default 'UTC'
) → timestamp without time zone
```

Reads the first 48 bits as Unix milliseconds, divides by 1000 using integer division, converts to a timestamp, and expresses that instant in the requested timezone. The SQL function is declared `IMMUTABLE` in the extension source, and is not declared `STRICT`.

**Guarantees:** for a UUIDv7 with a valid encoded time, returns its whole-second time in the requested timezone. Omitting `timezone` selects UTC. A null UUID or null timezone produces null.

**Does not guarantee:** UUIDv7 validation, millisecond precision, the original timezone, or the true time an ID or row was created. Other UUID versions are accepted and decoded without a version check. Timezone conversions depend on the server's timezone rules even though the function is declared immutable.

```sql
select extensions.timestamp_from_uuid_v7(
  uuid_v7 => '018b99e6-5a2d-78cc-89aa-4b29b940caa7'::uuid,
  timezone => 'UTC'
);
-- 2023-11-04 10:34:52
```

An invalid UUID literal fails the UUID cast before the function runs. An unrecognized timezone raises a Postgres error. See [read timestamps](../guides/timestamps.md) for conversion to `timestamptz`.
