# Date and time validators

Validators for dates, times and durations written as text. Each takes `value text` and returns `boolean`, and is `IMMUTABLE STRICT PARALLEL SAFE`.

The validators check dates by arithmetic on the digits. They never cast to `date` or `timestamptz`, whose results depend on the session's `DateStyle` and `TimeZone` and on the server's time zone database; that is why they can be `IMMUTABLE`. They check real calendar dates in the proleptic Gregorian calendar: month lengths, leap years (divisible by 4, except centuries not divisible by 400), ordinal days and ISO week numbers.

| Function | Format | Specification |
| --- | --- | --- |
| [`rfc3339`](#rfc3339) | Date and time with offset | RFC 3339 §5.6 `date-time` |
| [`rfc3339_date`](#rfc3339_date) | Date | RFC 3339 §5.6 `full-date` |
| [`rfc3339_time`](#rfc3339_time) | Time with offset | RFC 3339 §5.6 `full-time` |
| [`iso8601`](#iso8601) | Date, or date and time | ISO 8601-1:2019, profile below |
| [`duration`](#duration) | Duration | ISO 8601-1 §5.5.2 |

## Leap seconds

RFC 3339 allows second `60` for a leap second, which happens at 23:59:60 UTC. `rfc3339` and `rfc3339_time` accept second 60 only when the time, adjusted by its offset, is 23:59 UTC: `1990-12-31T15:59:60-08:00` passes and `1998-12-31T22:59:60Z` does not. They do not check the date against the published table of leap seconds, which changes over time; a fixed table would make the result depend on the release. `iso8601` accepts second 60 at any minute.

### `rfc3339`

```text
validate.rfc3339(value text) returns boolean
```

Accepts an RFC 3339 §5.6 `date-time`: `YYYY-MM-DDThh:mm:ss`, an optional fraction of a second (`.` and one or more digits), and an offset, `Z` or `±hh:mm`. `T` and `Z` may be lowercase (§5.6 note). Offset hours are 00 to 23. The offset `-00:00` (unknown local offset, §4.3) is accepted. This is the format of JSON Schema's `date-time`.

Not accepted: a space instead of `T`, a missing offset, a missing seconds field, a comma fraction, an offset without the colon, and years outside 0000 to 9999.

**Guarantees:** the value names one instant, on a real calendar day, with a valid offset. `timestamptz` input accepts it, except for year 0000, which Postgres rejects (add `and value >= '0001'` if you cast), and it reads second 60 as the start of the next minute.

**Does not guarantee:** that a leap second really happened at that instant (see above), or that the offset was in use in any time zone on that date.

```sql
select validate.rfc3339(value => '1985-04-12T23:20:50.52Z');
-- true
select validate.rfc3339(value => '2019-02-29T00:00:00Z');
-- false: 2019 is not a leap year
```

### `rfc3339_date`

```text
validate.rfc3339_date(value text) returns boolean
```

Accepts an RFC 3339 `full-date`, `YYYY-MM-DD`, on a real calendar day. This is JSON Schema's `date`.

**Guarantees:** the date exists in the Gregorian calendar.

**Does not guarantee:** anything about the range of dates your application expects. Add `and value between '1900-01-01' and '2100-12-31'` (a text comparison works for this fixed-width form) if you need one.

### `rfc3339_time`

```text
validate.rfc3339_time(value text) returns boolean
```

Accepts an RFC 3339 `full-time`: `hh:mm:ss`, an optional fraction and a required offset, as in `23:20:50.52Z` or `08:30:06+05:30`. This is JSON Schema's `time`. Second 60 follows the leap second rule above.

**Guarantees:** a valid time of day with an offset.

**Does not guarantee:** that a leap second happened on any particular day.

### `iso8601`

```text
validate.iso8601(value text) returns boolean
```

ISO 8601 has many representations, several of which need agreement between the parties. This validator accepts a documented profile of ISO 8601-1:2019: a date, or a complete date followed by `T` and a time.

| Part | Extended format | Basic format |
| --- | --- | --- |
| Calendar date | `2026-11-02` | `20261102` |
| Ordinal date | `2026-306` | `2026306` |
| Week date | `2026-W45-1` | `2026W451` |
| Reduced date (alone only) | `2026-11`, `2026`, `2026-W45` | `2026`, `2026W45` |
| Time after `T` | `10:30:15`, `10:30`, `10` | `103015`, `1030`, `10` |
| Fraction on the last time component | `10:30:15.25`, `10:30,5` | `103015.25` |
| Zone | `Z`, `+05`, `+05:30` | `Z`, `+05`, `+0530` |

Rules:

- A date and a time are both basic or both extended (`20261102T10:00` is rejected).
- Years are four digits, 0000 to 9999. Expanded years (`+12026`) are not accepted.
- Calendar days, ordinal days (365 or 366) and ISO weeks are real: week 53 exists only in years that have it, such as 2020 and 2026 but not 2021.
- `24:00`, `24:00:00` and `24:00:00.0` mean the end of the day. Hour 24 with a later minute, second or fraction is rejected.
- Second 60 is accepted (a leap second).

Not accepted: a time without a date, lowercase `t` or `z`, a space separator, `YYYYMM` (not ISO 8601, because it reads like `YYMMDD`), and durations or intervals.

**Guarantees:** the value is a valid representation in the profile above, of a real calendar date and valid time.

**Does not guarantee:** that a time without a zone is unambiguous: `2026-11-02T10:00` is a local time in an unknown zone. Require `rfc3339` if you need instants.

```sql
select validate.iso8601(value => '2026-W53-4');
-- true: 2026 has 53 ISO weeks
select validate.iso8601(value => '2021-W53-1');
-- false: 2021 has 52
```

### `duration`

```text
validate.duration(value text) returns boolean
```

Accepts an ISO 8601-1 duration: `P`, then years, months and days (`nY`, `nM`, `nD`) in that order, then `T` and hours, minutes and seconds (`nH`, `nM`, `nS`) in that order. Each component is optional, but at least one is present, and `T` is followed by at least one time component. Weeks (`nW`) stand alone. Numbers are non-negative integers; the last component may have a decimal fraction with `.` or `,` (`PT0.5S`).

This is a superset of the RFC 3339 Appendix A grammar, which JSON Schema's `duration` cites: that grammar omits combinations that skip a unit, such as `P1Y2D` and `PT1H5S`, which ISO 8601 allows.

**Guarantees:** a valid ISO 8601 duration in the format with designators.

**Does not guarantee:** that the value casts to `interval`, or a particular length: `P1M` is 28 to 31 days depending on the start date. Negative durations, the alternative format (`P0001-02-03T04:05:06`) and intervals (`start/end`) are rejected.
