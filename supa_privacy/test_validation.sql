-- =====================================================================
-- SUPA_PRIVACY EXTENSION VALIDATION TEST SCRIPT
-- Run this script in any PostgreSQL database (version 13+) to verify
-- the correctness of the anonymisation functions and view generation.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------
-- 1. Loading extension schema and functions...
-- ---------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS supa_privacy;

-- Copy of functions for standalone execution verification

CREATE OR REPLACE FUNCTION supa_privacy.mask_email(email text)
RETURNS text AS $$
DECLARE
    parts text[];
    username text;
    domain text;
    len int;
BEGIN
    IF email IS NULL OR email = '' THEN
        RETURN email;
    END IF;
    parts := string_to_array(email, '@');
    IF array_length(parts, 1) != 2 THEN
        RETURN regexp_replace(email, '.', '*', 'g');
    END IF;
    username := parts[1];
    domain := parts[2];
    len := length(username);
    IF len <= 1 THEN
        RETURN '*' || '@' || domain;
    ELSIF len = 2 THEN
        RETURN left(username, 1) || '*' || '@' || domain;
    ELSE
        RETURN left(username, 1) || '***' || right(username, 1) || '@' || domain;
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION supa_privacy.mask_phone_flexible(
    phone text, 
    keep_digits int DEFAULT 4, 
    mask_char char DEFAULT '*'
)
RETURNS text AS $$
DECLARE
    result text := '';
    char_val text;
    digit_count int := 0;
    total_digits int := 0;
    digits_to_mask int;
BEGIN
    IF phone IS NULL OR phone = '' THEN
        RETURN phone;
    END IF;
    total_digits := length(regexp_replace(phone, '\D', '', 'g'));
    digits_to_mask := total_digits - keep_digits;
    FOR i IN 1..length(phone) LOOP
        char_val := substr(phone, i, 1);
        IF char_val ~ '[0-9]' THEN
            digit_count := digit_count + 1;
            IF digit_count <= digits_to_mask THEN
                result := result || mask_char;
            ELSE
                result := result || char_val;
            END IF;
        ELSE
            result := result || char_val;
        END IF;
    END LOOP;
    RETURN result;
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION supa_privacy.mask_phone(phone text)
RETURNS text AS $$
BEGIN
    RETURN supa_privacy.mask_phone_flexible(phone, 4, '*');
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION supa_privacy.mask_text(val text, mask_char char DEFAULT '*')
RETURNS text AS $$
BEGIN
    IF val IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN repeat(mask_char, length(val));
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION supa_privacy.partial_mask(val text, prefix_keep int, suffix_keep int, mask_char char DEFAULT '*')
RETURNS text AS $$
DECLARE
    len int;
BEGIN
    IF val IS NULL THEN
        RETURN NULL;
    END IF;
    len := length(val);
    IF len <= (prefix_keep + suffix_keep) THEN
        RETURN repeat(mask_char, len);
    END IF;
    RETURN left(val, prefix_keep) || repeat(mask_char, len - prefix_keep - suffix_keep) || right(val, suffix_keep);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION supa_privacy.salted_hash(val text, salt text)
RETURNS text AS $$
BEGIN
    IF val IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN encode(sha256(convert_to(val || salt, 'UTF8')), 'hex');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION supa_privacy.perturb_numeric(val numeric, max_deviation numeric DEFAULT 0.07)
RETURNS numeric AS $$
BEGIN
    IF val IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN val * (1.0 + (random() * (max_deviation * 2.0) - max_deviation));
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION supa_privacy.perturb_numeric_deterministic(
    val numeric, 
    seed_key text, 
    max_deviation numeric DEFAULT 0.07
)
RETURNS numeric AS $$
DECLARE
    raw_hash bigint;
    normalized_rand numeric;
BEGIN
    IF val IS NULL OR seed_key IS NULL THEN
        RETURN val;
    END IF;
    raw_hash := ('x' || left(encode(sha256(convert_to(seed_key, 'UTF8')), 'hex'), 15))::bit(60)::bigint;
    normalized_rand := abs(raw_hash)::numeric / 1152921504606846975.0;
    RETURN val * (1.0 + (normalized_rand * (max_deviation * 2.0) - max_deviation));
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION supa_privacy.generalize_date(val date, bucket text DEFAULT 'month')
RETURNS date AS $$
BEGIN
    IF val IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN date_trunc(bucket, val)::date;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION supa_privacy.shift_date_deterministic(
    val date, 
    seed_key text, 
    max_days int DEFAULT 30
)
RETURNS date AS $$
DECLARE
    raw_hash bigint;
    shift_days int;
BEGIN
    IF val IS NULL OR seed_key IS NULL THEN
        RETURN val;
    END IF;
    raw_hash := ('x' || left(encode(sha256(convert_to(seed_key, 'UTF8')), 'hex'), 15))::bit(60)::bigint;
    shift_days := (abs(raw_hash) % (max_days * 2 + 1)) - max_days;
    RETURN val + shift_days;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION supa_privacy.generalize_numeric(val numeric, bucket_size numeric)
RETURNS numeric AS $$
BEGIN
    IF val IS NULL OR bucket_size IS NULL OR bucket_size <= 0 THEN
        RETURN val;
    END IF;
    RETURN round(val / bucket_size) * bucket_size;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION supa_privacy.create_masked_view(
    source_table regclass,
    view_name text,
    rules jsonb
)
RETURNS void AS $$
DECLARE
    column_record record;
    col_name text;
    col_type text;
    rule jsonb;
    rule_type text;
    select_expr text;
    select_list text := '';
    sql_stmt text;
    full_table_name text;
    seed_col text;
BEGIN
    full_table_name := source_table::text;
    FOR column_record IN
        SELECT attname, format_type(atttypid, atttypmod) AS type_desc
        FROM pg_attribute
        WHERE attrelid = source_table AND attnum > 0 AND NOT attisdropped
        ORDER BY attnum
    LOOP
        col_name := column_record.attname;
        col_type := column_record.type_desc;
        rule := rules -> col_name;
        IF rule IS NOT NULL THEN
            rule_type := rule ->> 'type';
            CASE rule_type
                WHEN 'email' THEN
                    select_expr := 'supa_privacy.mask_email(' || quote_ident(col_name) || '::text)';
                WHEN 'phone' THEN
                    IF (rule ->> 'keep_digits') IS NOT NULL THEN
                        select_expr := 'supa_privacy.mask_phone_flexible(' || quote_ident(col_name) || '::text, ' || (rule ->> 'keep_digits') || ')';
                    ELSE
                        select_expr := 'supa_privacy.mask_phone(' || quote_ident(col_name) || '::text)';
                    END IF;
                WHEN 'hash' THEN
                    select_expr := 'supa_privacy.salted_hash(' || quote_ident(col_name) || '::text, ' || quote_literal(coalesce(rule ->> 'salt', '')) || ')';
                WHEN 'perturb' THEN
                    seed_col := rule ->> 'seed_column';
                    IF seed_col IS NOT NULL THEN
                        select_expr := 'supa_privacy.perturb_numeric_deterministic(' || quote_ident(col_name) || '::numeric, ' || quote_ident(seed_col) || '::text, ' || coalesce(rule ->> 'variance', '0.07') || ')';
                    ELSE
                        select_expr := 'supa_privacy.perturb_numeric(' || quote_ident(col_name) || '::numeric, ' || coalesce(rule ->> 'variance', '0.07') || ')';
                    END IF;
                WHEN 'shift_date' THEN
                    seed_col := rule ->> 'seed_column';
                    IF seed_col IS NOT NULL THEN
                        select_expr := 'supa_privacy.shift_date_deterministic(' || quote_ident(col_name) || '::date, ' || quote_ident(seed_col) || '::text, ' || coalesce(rule ->> 'days', '30') || ')';
                    ELSE
                        select_expr := 'supa_privacy.shift_date_deterministic(' || quote_ident(col_name) || '::date, ''default_seed'', ' || coalesce(rule ->> 'days', '30') || ')';
                    END IF;
                WHEN 'generalize_numeric' THEN
                    select_expr := 'supa_privacy.generalize_numeric(' || quote_ident(col_name) || '::numeric, ' || coalesce(rule ->> 'bucket', '10') || ')';
                WHEN 'generalize_date' THEN
                    select_expr := 'supa_privacy.generalize_date(' || quote_ident(col_name) || '::date, ' || quote_literal(coalesce(rule ->> 'bucket', 'month')) || ')';
                WHEN 'redact' THEN
                    IF (rule ->> 'value') IS NULL OR (rule ->> 'value') = 'NULL' THEN
                        select_expr := 'NULL';
                    ELSE
                        select_expr := quote_literal(rule ->> 'value');
                    END IF;
                WHEN 'custom' THEN
                    select_expr := replace(rule ->> 'expression', '{col}', quote_ident(col_name));
                ELSE
                    select_expr := quote_ident(col_name);
            END CASE;
            select_expr := '(' || select_expr || ')::' || col_type;
        ELSE
            select_expr := quote_ident(col_name);
        END IF;
        IF select_list != '' THEN
            select_list := select_list || ', ';
        END IF;
        select_list := select_list || select_expr || ' AS ' || quote_ident(col_name);
    END LOOP;
    sql_stmt := 'CREATE OR REPLACE VIEW ' || quote_ident(view_name) || ' AS SELECT ' || select_list || ' FROM ' || full_table_name;
    EXECUTE sql_stmt;
END;
$$ LANGUAGE plpgsql VOLATILE;

-- ---------------------------------------------------------
-- 2. Running Function Unit Tests...
-- ---------------------------------------------------------

DO $$
BEGIN
    -- test email masking
    ASSERT supa_privacy.mask_email('jesse@vent.com') = 'j***e@vent.com', 'mask_email failed for normal username';
    ASSERT supa_privacy.mask_email('ab@vent.com') = 'a*@vent.com', 'mask_email failed for length 2 username';
    ASSERT supa_privacy.mask_email('a@vent.com') = '*@vent.com', 'mask_email failed for length 1 username';
    ASSERT supa_privacy.mask_email('') = '', 'mask_email failed for empty string';
    ASSERT supa_privacy.mask_email(NULL) IS NULL, 'mask_email failed for NULL';

    -- test standard and flexible phone masking
    ASSERT supa_privacy.mask_phone('+61412345678') = '+*******5678', 'mask_phone failed for +61412345678';
    ASSERT supa_privacy.mask_phone_flexible('+1 (202) 555-0143', 4) = '+* (***) ***-0143', 'mask_phone_flexible failed for formatted phone';
    ASSERT supa_privacy.mask_phone_flexible('12345', 2, '#') = '###45', 'mask_phone_flexible failed for custom mask char';

    -- test text masking
    ASSERT supa_privacy.mask_text('secret') = '******', 'mask_text failed';
    ASSERT supa_privacy.partial_mask('1234-5678-9012', 4, 4, '*') = '1234******9012', 'partial_mask failed';

    -- test salted hash (should be deterministic)
    ASSERT supa_privacy.salted_hash('test_value', 'my_salt') = supa_privacy.salted_hash('test_value', 'my_salt'), 'salted_hash is not deterministic';
    ASSERT supa_privacy.salted_hash('test_value', 'my_salt') != supa_privacy.salted_hash('test_value', 'different_salt'), 'salted_hash does not respect salt';
    ASSERT length(supa_privacy.salted_hash('test_value', 'my_salt')) = 64, 'salted_hash output is not 64-char sha256 hex string';

    -- test numeric perturbation (volatile vs deterministic)
    ASSERT supa_privacy.perturb_numeric(100.0, 0.0) = 100.0, 'perturb_numeric variance 0.0 deviation failed';
    
    -- verify deterministic perturbation is stable
    ASSERT supa_privacy.perturb_numeric_deterministic(100.0, 'seed1', 0.07) = supa_privacy.perturb_numeric_deterministic(100.0, 'seed1', 0.07), 'deterministic perturbation is not stable';
    ASSERT supa_privacy.perturb_numeric_deterministic(100.0, 'seed1', 0.07) != supa_privacy.perturb_numeric_deterministic(100.0, 'seed2', 0.07), 'deterministic perturbation did not respect seed';

    -- test date generalization and shifting
    ASSERT supa_privacy.generalize_date('2026-06-08'::date, 'year') = '2026-01-01'::date, 'generalize_date year failed';
    ASSERT supa_privacy.generalize_date('2026-06-08'::date, 'month') = '2026-06-01'::date, 'generalize_date month failed';
    
    -- verify deterministic date shifting
    ASSERT supa_privacy.shift_date_deterministic('2026-06-08'::date, 'seed1', 30) = supa_privacy.shift_date_deterministic('2026-06-08'::date, 'seed1', 30), 'deterministic date shift is not stable';
    ASSERT supa_privacy.shift_date_deterministic('2026-06-08'::date, 'seed1', 30) != supa_privacy.shift_date_deterministic('2026-06-08'::date, 'seed2', 30), 'deterministic date shift did not respect seed';
    ASSERT abs(supa_privacy.shift_date_deterministic('2026-06-08'::date, 'seed1', 30) - '2026-06-08'::date) <= 30, 'deterministic date shift out of bounds';

    -- test numeric generalization
    ASSERT supa_privacy.generalize_numeric(27, 5) = 25, 'generalize_numeric 27/5 failed';
    ASSERT supa_privacy.generalize_numeric(84200, 10000) = 80000, 'generalize_numeric salary failed';
    
    RAISE NOTICE '✅ All individual unit tests passed successfully!';
END;
$$;

-- ---------------------------------------------------------
-- 3. Testing Masked View Generator...
-- ---------------------------------------------------------

-- Create temporary mock table
CREATE TEMP TABLE test_users (
    id int PRIMARY KEY,
    name text,
    email text,
    phone text,
    salary numeric,
    birth_date date,
    secret_code text
);

INSERT INTO test_users VALUES 
(1, 'Alice Smith', 'alice@gmail.com', '+1 (202) 555-0143', 95000.50, '1990-04-15', 'top_secret_code_123'),
(2, 'Bob Jones', 'bob@corp.com', '+61 412 000 222', 125000.00, '1985-09-22', 'top_secret_code_456');

-- Generate masked view with advanced and custom rules
SELECT supa_privacy.create_masked_view(
    'test_users'::regclass,
    'v_test_users_masked',
    '{
        "name": {"type": "hash", "salt": "testsalt"},
        "email": {"type": "email"},
        "phone": {"type": "phone", "keep_digits": 4},
        "salary": {"type": "perturb", "variance": 0.05, "seed_column": "id"},
        "birth_date": {"type": "shift_date", "days": 15, "seed_column": "id"},
        "secret_code": {"type": "custom", "expression": "upper(reverse({col}))"}
    }'::jsonb
);

-- Check that view exists and columns are masked correctly
DO $$
DECLARE
    r1 record;
    r2 record;
BEGIN
    SELECT * INTO r1 FROM v_test_users_masked WHERE id = 1;
    SELECT * INTO r2 FROM v_test_users_masked WHERE id = 1; -- query view again to check deterministic stability
    
    -- Verify types and values
    ASSERT r1.id = 1;
    ASSERT r1.email = 'a***e@gmail.com', 'View email masking failed';
    ASSERT r1.phone = '+* (***) ***-0143', 'View phone formatting preservation failed';
    ASSERT abs(r1.birth_date - '1990-04-15'::date) <= 15, 'View birth date shifting failed';
    ASSERT length(r1.name) = 64, 'View name hashing failed';
    ASSERT r1.salary >= 90250.0 AND r1.salary <= 99751.0, 'View salary perturbation failed';
    ASSERT r1.secret_code = '321_EDOC_TERCES_POT', 'View custom expression execution failed';
    
    -- Verify deterministic stability (r1 values MUST equal r2 values exactly)
    ASSERT r1.salary = r2.salary, 'Deterministic perturbation is not stable in view';
    ASSERT r1.birth_date = r2.birth_date, 'Deterministic date shifting is not stable in view';
    
    RAISE NOTICE '✅ Masked View Generator advanced test passed successfully!';
END;
$$;

-- Cleanup view and tables
DROP VIEW IF EXISTS v_test_users_masked;
DROP TABLE IF EXISTS test_users;
DROP SCHEMA supa_privacy CASCADE;

-- ---------------------------------------------------------
-- ✅ All tests passed successfully!
-- ---------------------------------------------------------

ROLLBACK; -- rollback to keep the test clean
