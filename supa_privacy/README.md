# supa_privacy - It's not just private, it's supa private.

## PostgreSQL Data Anonymisation TLE Extension

`supa_privacy` is a relocatable, pure SQL PostgreSQL **Trusted Language Extension (TLE)** designed for database-side data de-identification, compliance, and sandbox security. It provides standard masking, hashing, and perturbation functions and is fully optimized for **[database.dev](https://database.dev)** and **Supabase**.

It is particularly useful for:
- Preparing production database schemas for staging or development environments.
- Sharing data with external analytics teams while respecting privacy regulations (GDPR, HIPAA, CCPA).
- Implementing Dynamic Data Masking (DDM) for low-privilege database roles.

---

## 🚀 Installation

### 1. Enable TLE Support
`supa_privacy` runs as a Trusted Language Extension and requires the `pg_tle` extension to be enabled in your PostgreSQL database:

```sql
CREATE EXTENSION IF NOT EXISTS "pg_tle";
```

### 2. Installing from database.dev

Using the [dbdev CLI](https://supabase.github.io/dbdev):

```bash
dbdev add -o ./migrations -s extensions -v 1.0.1 package -n "jvent@supa_privacy"
```

This will generate a migration file in your `./migrations` folder containing the SQL required to load the extension. After applying the migration, enable the extension:

```sql
CREATE EXTENSION "jvent@supa_privacy" VERSION '1.0.1' SCHEMA supa_privacy;
```

---

## 🛠️ API Reference

All functions are located under the schema where the extension is installed (e.g. `supa_privacy`).

### 1. Email Masking
Masks the username part of an email address while keeping the domain.
* **Function:** `supa_privacy.mask_email(email text) RETURNS text`
* **Behavior:** 
  - `jesse@vent.com` ➡️ `j***e@vent.com`
  - `ab@vent.com` ➡️ `a*@vent.com`
  - `a@vent.com` ➡️ `*@vent.com`
* **Example:**
  ```sql
  SELECT supa_privacy.mask_email('jesse@vent.com'); -- Returns: j***e@vent.com
  ```

### 2. Phone Masking
Masks digit characters while preserving formatting characters (such as spaces, hyphens, plus signs, and brackets).
* **Format-Preserving Masking:** `supa_privacy.mask_phone_flexible(phone text, keep_digits int DEFAULT 4, mask_char char DEFAULT '*') RETURNS text`
* **Default Wrapper:** `supa_privacy.mask_phone(phone text) RETURNS text` (wrapper calling `mask_phone_flexible` keeping 4 digits).
* **Behavior:**
  - `+1 (202) 555-0143` ➡️ `+* (***) ***-0143`
  - `+61412345678` ➡️ `+*******5678`
* **Example:**
  ```sql
  SELECT supa_privacy.mask_phone_flexible('+1 (202) 555-0143', 4); -- Returns: +* (***) ***-0143
  ```

### 3. Text Masking & Redaction
Fully or partially obscures text strings.
* **Full Masking:** `supa_privacy.mask_text(val text, mask_char char DEFAULT '*') RETURNS text`
  - `secret` ➡️ `******`
* **Partial Masking:** `supa_privacy.partial_mask(val text, prefix_keep int, suffix_keep int, mask_char char DEFAULT '*') RETURNS text`
  - `supa_privacy.partial_mask('1234-5678-9012', 4, 4, '*')` ➡️ `1234******9012`
* **Examples:**
  ```sql
  SELECT supa_privacy.mask_text('secret'); -- Returns: ******
  SELECT supa_privacy.partial_mask('1234-5678-9012', 4, 4, '*'); -- Returns: 1234******9012
  ```

### 4. Cryptographic Salted Hashing (Deterministic)
Generates a deterministic SHA-256 hash using a secret salt.
* **Function:** `supa_privacy.salted_hash(val text, salt text) RETURNS text`
* **Example:**
  ```sql
  SELECT supa_privacy.salted_hash('user_id_123', 'secret_salt_key');
  -- Returns hex-encoded SHA-256 hash: 39de1a88b56f...
  ```

### 5. Numeric Perturbation (Noise Injection)
Adds bounded random variance (noise) to numeric fields to protect details while preserving statistical averages.
* **Volatile Perturbation:** `supa_privacy.perturb_numeric(val numeric, max_deviation numeric DEFAULT 0.07) RETURNS numeric`
  - Noise changes on every query execution.
* **Deterministic Perturbation:** `supa_privacy.perturb_numeric_deterministic(val numeric, seed_key text, max_deviation numeric DEFAULT 0.07) RETURNS numeric`
  - Noise is seeded by `seed_key` (typically the row's primary key) so it remains identical across multiple query executions (critical for analytical query stability).
* **Examples:**
  ```sql
  -- Volatile noise
  SELECT supa_privacy.perturb_numeric(100.0, 0.10); -- Returns a value between 90.0 and 110.0
  -- Deterministic noise (always returns same value for 'user_1')
  SELECT supa_privacy.perturb_numeric_deterministic(100.0, 'user_1', 0.10);
  ```

### 6. Date Generalization & Shifting
Obfuscates absolute dates via truncation or chronological offsets.
* **Date Generalization (Bucketing):** `supa_privacy.generalize_date(val date, bucket text DEFAULT 'month') RETURNS date`
  - Truncates dates to `'year'`, `'quarter'`, `'month'`, or `'week'`.
* **Deterministic Date Shifting:** `supa_privacy.shift_date_deterministic(val date, seed_key text, max_days int DEFAULT 30) RETURNS date`
  - Shifts date back/forward by a deterministic number of days based on a seed key. Ideal for HIPAA compliance (preserves chronological order of events within a user profile while masking the absolute dates).
* **Examples:**
  ```sql
  SELECT supa_privacy.generalize_date('2026-06-08'::date, 'year'); -- Returns: 2026-01-01
  SELECT supa_privacy.shift_date_deterministic('2026-06-08'::date, 'user_123_salt', 15); -- Shifts by +/- 15 days deterministically
  ```

### 7. Numeric Generalization (Bucketing)
Groups numbers into custom bucket intervals (useful for ages, salaries).
* **Function:** `supa_privacy.generalize_numeric(val numeric, bucket_size numeric) RETURNS numeric`
* **Example:**
  ```sql
  SELECT supa_privacy.generalize_numeric(27, 5); -- Returns: 25 (rounds to nearest multiple of 5)
  ```

### 8. Dynamic Masked View Generator (Extensible)
Scans a physical table and automatically generates a secure VIEW that replaces sensitive fields with masking expressions while leaving other columns untouched.
* **Function:** `supa_privacy.create_masked_view(source_table regclass, view_name text, rules jsonb) RETURNS void`
* **Rules JSONB Format:**
  A JSON object mapping column names to rule configurations. Supported rule configurations:
  - `{"type": "email"}`
  - `{"type": "phone", "keep_digits": 4}` (uses formatting-preserving masking)
  - `{"type": "hash", "salt": "my_salt"}`
  - `{"type": "perturb", "variance": 0.05, "seed_column": "id"}` (deterministic noise)
  - `{"type": "shift_date", "days": 15, "seed_column": "id"}` (deterministic date shifting)
  - `{"type": "generalize_numeric", "bucket": 10}`
  - `{"type": "generalize_date", "bucket": "year"}`
  - `{"type": "redact", "value": "NULL"}` (replaces value with constant or NULL)
  - `{"type": "custom", "expression": "upper(reverse({col}))"}` (interpolates `{col}` with column name)

---

## 📖 End-to-End Example

Here is a full walkthrough showing how to de-identify a customer table.

### 1. Create a Source Table and Insert Mock Data
```sql
CREATE TABLE public.customers (
    id SERIAL PRIMARY KEY,
    full_name TEXT NOT NULL,
    email TEXT UNIQUE NOT NULL,
    phone TEXT,
    age INT,
    yearly_salary NUMERIC(10, 2),
    signup_date DATE NOT NULL
);

INSERT INTO public.customers (full_name, email, phone, age, yearly_salary, signup_date) VALUES
('John Doe', 'john.doe@gmail.com', '+1 (202) 555-0143', 27, 85000.00, '2025-03-12'),
('Jane Smith', 'jane_smith@corp.com', '+61 412 000 222', 43, 142000.00, '2024-11-20'),
('Bob Johnson', 'bjohnson@yahoo.com', '0491 570 156', 58, 62500.50, '2026-01-05');
```

### 2. Generate a Masked View
Define anonymisation rules in JSON and invoke `create_masked_view`:

```sql
SELECT supa_privacy.create_masked_view(
    'public.customers'::regclass,
    'public.v_customers_deidentified',
    '{
        "full_name": {"type": "hash", "salt": "AppSaltKey123"},
        "email": {"type": "email"},
        "phone": {"type": "phone", "keep_digits": 4},
        "age": {"type": "generalize_numeric", "bucket": 10},
        "yearly_salary": {"type": "perturb", "variance": 0.07, "seed_column": "id"},
        "signup_date": {"type": "shift_date", "days": 15, "seed_column": "id"}
    }'::jsonb
);
```

### 3. Query the Masked View
Query the generated view:

```sql
SELECT * FROM public.v_customers_deidentified;
```

**Result:**
| id | full_name | email | phone | age | yearly_salary | signup_date |
|---|---|---|---|---|---|---|
| 1 | `e97a3a9489f...` | `j***e@gmail.com` | `+* (***) ***-0143` | 30 | `87140.23` (Stable) | `2025-03-14` (Shifted) |
| 2 | `a902b4d812d...` | `j***h@corp.com` | `+** *** *** 0222` | 40 | `138402.12` (Stable) | `2024-11-12` (Shifted) |
| 3 | `d8293bcde11...` | `b***n@yahoo.com` | `**** *** 0156` | 60 | `64102.50` (Stable) | `2026-01-08` (Shifted) |

---

## 🔐 RLS & Access Control Integration Patterns

For production environments (like **Supabase**), you should combine `supa_privacy`'s Column-level Dynamic Data Masking (DDM) with PostgreSQL **Row-Level Security (RLS)** for comprehensive access control.

### 1. Dual-Layer Masking + RLS Pattern
**Best Practice:** Always apply RLS to both the base table and the generated view. This ensures that users see only the rows they are allowed to see, with sensitive columns masked.

```sql
-- 1. Create source table with RLS
CREATE TABLE public.customers (
    id SERIAL PRIMARY KEY,
    full_name TEXT NOT NULL,
    email TEXT UNIQUE NOT NULL,
    phone TEXT,
    department_id INT,  -- RLS filter key
    yearly_salary NUMERIC(10, 2)
);

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

-- 2. Create RLS policy for the base table
CREATE POLICY cust_department_policy ON public.customers
    FOR SELECT
    USING (department_id = current_setting('app.current_department_id')::int);

-- 3. Generate the masked view (DDM layer)
SELECT supa_privacy.create_masked_view(
    'public.customers'::regclass,
    'public.v_customers_masked',
    '{
        "full_name": {"type": "hash", "salt": "SecureAppSaltKey"},
        "email": {"type": "email"},
        "phone": {"type": "phone"},
        "yearly_salary": {"type": "perturb", "variance": 0.07}
    }'::jsonb
);

-- 4. Enable RLS on the masked view (CRITICAL!)
ALTER TABLE public.v_customers_masked ENABLE ROW LEVEL SECURITY;

CREATE POLICY mask_department_policy ON public.v_customers_masked
    FOR SELECT
    USING (department_id = current_setting('app.current_department_id')::int);

-- 5. Grant permissions to database role
GRANT SELECT ON public.v_customers_masked TO app_user;
```

### 2. Alternative: Role-Based Transparent Masking
If you want users to query the base table directly but have masking applied conditionally based on the user's role or session variables:

```sql
-- Wrapper function to conditionally mask based on session variables
CREATE OR REPLACE FUNCTION public.get_secured_customers()
RETURNS TABLE(
    id INT,
    full_name TEXT,
    email TEXT,
    phone TEXT,
    department_id INT,
    yearly_salary NUMERIC(10, 2)
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        c.id,
        CASE WHEN current_setting('app.masking_enabled', true) = 'true'
            THEN supa_privacy.mask_text(c.full_name, '*')
            ELSE c.full_name
        END,
        CASE WHEN current_setting('app.masking_enabled', true) = 'true'
            THEN supa_privacy.mask_email(c.email)
            ELSE c.email
        END,
        CASE WHEN current_setting('app.masking_enabled', true) = 'true'
            THEN supa_privacy.mask_phone(c.phone)
            ELSE c.phone
        END,
        c.department_id,
        CASE WHEN current_setting('app.masking_enabled', true) = 'true'
            THEN supa_privacy.perturb_numeric(c.yearly_salary, 0.07)
            ELSE c.yearly_salary
        END
    FROM public.customers c
    WHERE c.department_id = current_setting('app.current_department_id', true)::int;
END;
$$ LANGUAGE plpgsql;
```

---

## 🛡️ License
MIT License. Feel free to use and distribute.
