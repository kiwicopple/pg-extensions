# Read timestamps

Extract the leading time field of a UUIDv7 for inspection. Install the functions into `extensions` first. You do not need a table for these examples.

```sql
select extensions.timestamp_from_uuid_v7(
  uuid_v7 => '018b99e6-5a2d-78cc-89aa-4b29b940caa7'::uuid
);
-- 2023-11-04 10:34:52
```

The default timezone is UTC. The result is a `timestamp without time zone`, so it contains a wall-clock time without an offset or zone label.

```sql
select extensions.timestamp_from_uuid_v7(
  uuid_v7 => '018b99e6-5a2d-78cc-89aa-4b29b940caa7'::uuid,
  timezone => 'Europe/Paris'
);
-- 2023-11-04 11:34:52
```

If you need a `timestamptz`, interpret the UTC result explicitly:

```sql
select extensions.timestamp_from_uuid_v7(
  uuid_v7 => '018b99e6-5a2d-78cc-89aa-4b29b940caa7'::uuid
) at time zone 'UTC';
-- The same instant; display depends on the session timezone.
```

Do not cast the wall-clock result directly to `timestamptz` unless the session timezone matches the timezone used to extract it.

## Precision and trust

Version 0.0.4 divides the encoded millisecond field by 1000 with integer division, discarding milliseconds. It does not decode the generator's extra sub-millisecond bits. The generators also round some timestamp components, so the extracted value is not an exact record of when a row was created.

The function does not check the UUID version or variant. A UUIDv4 can produce a plausible-looking but meaningless date. IDs supplied by a client can encode arbitrary times. Store a separate timestamp for audit records, retention rules or user-facing creation dates.

See [timestamp extraction](../reference/timestamps.md) for the signature and [errors and limits](../errors-and-limits.md) for failure behavior.
