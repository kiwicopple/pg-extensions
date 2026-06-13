# supa_profile - PostgreSQL Database Table & Column Profiler

`supa_profile` is a relocatable, pure SQL PostgreSQL **Trusted Language Extension (TLE)** designed for native table and column-level statistical profiling. It introspects schema metadata, dynamically constructs parallelized queries, and compiles a comprehensive statistical report (including counts, nullability, distinctness, min/max, string length distributions, averages, medians, percentiles, and frequent value distributions) returned directly as a single structured JSONB document.

The JSONB output format is fully compatible with the **`ProfilingResult`** TypeScript interface used by frontend profiling dashboards.

---

## 🚀 Installation

### 1. Enable TLE Support
`supa_profile` runs as a Trusted Language Extension and requires the `pg_tle` extension to be enabled:

```sql
CREATE EXTENSION IF NOT EXISTS "pg_tle";
```

### 2. Installing from database.dev

Using the [dbdev CLI](https://supabase.github.io/dbdev):

```bash
dbdev add -o ./migrations -s extensions -v 1.0.0 package -n "jvent@supa_profile"
```

This generates a migration script to load the TLE. Apply the migration, then enable the extension:

```sql
CREATE EXTENSION "jvent@supa_profile" VERSION '1.0.0' SCHEMA supa_profile;
```

---

## 🛠️ API Reference

### 1. Profile Table
Introspects and profiles a physical table, view, or materialized view.
* **Function:** `supa_profile.profile_table(target_table regclass, options jsonb DEFAULT '{}') RETURNS jsonb`
* **Options Parameter (`options`):**
  A JSON object supporting the following parameters:
  - `scan_field_values` (boolean, default: `true`): Scan column values to compute top value frequency distributions.
  - `min_cell_count` (int, default: `5`): Minimum occurrence count of a value to include it in the value distribution list.
  - `max_distinct_values` (int, default: `100`): Maximum distinct values returned per column in the value distribution list.
  - `rows_per_table` (int, default: `0` = unlimited): Maximum rows to scan. If greater than zero, it wraps the source in a sampled subquery (`LIMIT N`).
  - `calculate_numeric_stats` (boolean, default: `true`): Compute average, median, 90th percentile, and 99th percentile for numeric fields.
  - `sampling_method` (text, default: `'limit'`): Sampling strategy when limiting scans. Options:
    - `'limit'`: Truncates scan to first $N$ rows (`LIMIT N`). Works on all table types, views, and foreign tables.
    - `'system'`: Uses PostgreSQL native block-level sampling (`TABLESAMPLE SYSTEM (percentage)`). Extremely fast, but block-based.
    - `'bernoulli'`: Uses PostgreSQL native row-level random sampling (`TABLESAMPLE BERNOULLI (percentage)`). Slower than system, but fully random.
  - `sample_percentage` (numeric): Percentage of rows to sample (between `0` and `100`). Only used if `sampling_method` is set to `'system'` or `'bernoulli'`.
  - `use_estimated_stats` (boolean, default: `false`): Enable instant catalog-based profiling. When `true`, it bypasses active table queries entirely and extracts statistics directly from Postgres catalogs (`pg_class.reltuples` and `pg_stats`). Excellent for tables with billions of rows (completes in < 5ms).

* **Example:**
  ```sql
  -- Profile using Bernoulli row-level sampling at 10%
  SELECT supa_profile.profile_table(
      'public.users'::regclass,
      '{"sampling_method": "bernoulli", "sample_percentage": 10.0}'::jsonb
  );
  
  -- Profile billions of rows instantly using pg_stats estimates
  SELECT supa_profile.profile_table(
      'public.huge_analytics_log'::regclass,
      '{"use_estimated_stats": true}'::jsonb
  );
  ```

---

## 🔍 Data Pattern Classifier

The profiler includes a data classifier that samples column values and matches them against regular expression pattern groups to identify specific fields:
- `EMAIL`: Match handles like `user@corp.com`.
- `UUID`: Match UUID strings like `a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11`.
- `IPV4`: Match IP addresses like `192.168.1.1`.
- `URL`: Match URLs like `https://supabase.com`.
- `DATE`: Match ISO date formats.
- `NUMERIC`: Match integers and floats.
- `.*`: Fallback for generic text fields.

---

## 📊 Output Schema (JSONB)

The function returns a JSONB object containing:
- `tableStats`: Table name, row count, column count.
- `fields`: Array of column-level statistics.
- `values`: Value frequency distribution array.
- `profiledAt`: Timestamp in UTC.
- `durationMs`: Total duration of the profiling process.
- `queryMode`: Current query mode (`NORMAL`, `FAST` for sampled scans, or `ESTIMATED` for catalog statistics).

---

## 🛡️ License
MIT License. Feel free to use and distribute.
