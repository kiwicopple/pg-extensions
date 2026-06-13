-- supa_privacy extension database schema definition

-- ---------------------------------------------------------------------
-- 1. EMAIL MASKING
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @extschema@.mask_email(email text)
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

    -- Split email by '@'
    parts := string_to_array(email, '@');
    IF array_length(parts, 1) != 2 THEN
        -- Fallback if format is not standard email
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
        -- e.g. jesse@vent.com -> j***e@vent.com
        RETURN left(username, 1) || '***' || right(username, 1) || '@' || domain;
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;


-- ---------------------------------------------------------------------
-- 2. PHONE MASKING (Formatting-Preserving)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @extschema@.mask_phone_flexible(
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

    -- Count total digits in the string
    total_digits := length(regexp_replace(phone, '\D', '', 'g'));
    digits_to_mask := total_digits - keep_digits;

    -- Iterate and mask digits selectively
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
            -- Keep formatting spaces, hyphens, plus signs, brackets
            result := result || char_val;
        END IF;
    END LOOP;

    RETURN result;
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION @extschema@.mask_phone(phone text)
RETURNS text AS $$
BEGIN
    -- Backward-compatible wrapper that defaults to format-preserving masking
    RETURN @extschema@.mask_phone_flexible(phone, 4, '*');
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;


-- ---------------------------------------------------------------------
-- 3. TEXT MASKING & REDACTION
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @extschema@.mask_text(val text, mask_char char DEFAULT '*')
RETURNS text AS $$
BEGIN
    IF val IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN repeat(mask_char, length(val));
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION @extschema@.partial_mask(val text, prefix_keep int, suffix_keep int, mask_char char DEFAULT '*')
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


-- ---------------------------------------------------------------------
-- 4. CRYPTOGRAPHIC HASHING (Salted & Deterministic)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @extschema@.salted_hash(val text, salt text)
RETURNS text AS $$
BEGIN
    IF val IS NULL THEN
        RETURN NULL;
    END IF;
    -- Uses built-in sha256 to hash concatenation of value and salt, and encodes to hex
    RETURN encode(sha256(convert_to(val || salt, 'UTF8')), 'hex');
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- ---------------------------------------------------------------------
-- 5. NUMERIC PERTURBATION (Volatile & Deterministic Noise)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @extschema@.perturb_numeric(val numeric, max_deviation numeric DEFAULT 0.07)
RETURNS numeric AS $$
BEGIN
    IF val IS NULL THEN
        RETURN NULL;
    END IF;
    -- deviation is a random number between -max_deviation and +max_deviation (volatile per run)
    RETURN val * (1.0 + (random() * (max_deviation * 2.0) - max_deviation));
END;
$$ LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION @extschema@.perturb_numeric_deterministic(
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

    -- Convert SHA-256 hash fragment to a big integer deterministically
    raw_hash := ('x' || left(encode(sha256(convert_to(seed_key, 'UTF8')), 'hex'), 15))::bit(60)::bigint;

    -- Normalize big integer to a 0.0 .. 1.0 range (divide by 2^60 - 1)
    normalized_rand := abs(raw_hash)::numeric / 1152921504606846975.0;

    -- Map normalized value to the deviation bounds
    RETURN val * (1.0 + (normalized_rand * (max_deviation * 2.0) - max_deviation));
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- ---------------------------------------------------------------------
-- 6. DATE GENERALIZATION & SHIFTING
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @extschema@.generalize_date(val date, bucket text DEFAULT 'month')
RETURNS date AS $$
BEGIN
    IF val IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN date_trunc(bucket, val)::date;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION @extschema@.shift_date_deterministic(
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

    -- Convert SHA-256 hash fragment to a big integer deterministically
    raw_hash := ('x' || left(encode(sha256(convert_to(seed_key, 'UTF8')), 'hex'), 15))::bit(60)::bigint;

    -- Map to a shift in days between [-max_days, max_days]
    shift_days := (abs(raw_hash) % (max_days * 2 + 1)) - max_days;

    RETURN val + shift_days;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- ---------------------------------------------------------------------
-- 7. NUMERIC GENERALIZATION (Bucketing)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @extschema@.generalize_numeric(val numeric, bucket_size numeric)
RETURNS numeric AS $$
BEGIN
    IF val IS NULL OR bucket_size IS NULL OR bucket_size <= 0 THEN
        RETURN val;
    END IF;
    -- Rounds value to the nearest multiple of bucket_size
    RETURN round(val / bucket_size) * bucket_size;
END;
$$ LANGUAGE plpgsql IMMUTABLE;


-- ---------------------------------------------------------------------
-- 8. DYNAMIC MASKED VIEW GENERATOR (Enhanced & Extensible)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @extschema@.create_masked_view(
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
    -- Resolve full schema-qualified table name
    full_table_name := source_table::text;

    -- Loop through all columns of the source table
    FOR column_record IN
        SELECT attname, format_type(atttypid, atttypmod) AS type_desc
        FROM pg_attribute
        WHERE attrelid = source_table AND attnum > 0 AND NOT attisdropped
        ORDER BY attnum
    LOOP
        col_name := column_record.attname;
        col_type := column_record.type_desc;

        -- Check if there is a rule defined for this column
        rule := rules -> col_name;

        IF rule IS NOT NULL THEN
            rule_type := rule ->> 'type';

            CASE rule_type
                WHEN 'email' THEN
                    select_expr := '@extschema@.mask_email(' || quote_ident(col_name) || '::text)';

                WHEN 'phone' THEN
                    IF (rule ->> 'keep_digits') IS NOT NULL THEN
                        select_expr := '@extschema@.mask_phone_flexible(' || quote_ident(col_name) || '::text, ' || (rule ->> 'keep_digits') || ')';
                    ELSE
                        select_expr := '@extschema@.mask_phone(' || quote_ident(col_name) || '::text)';
                    END IF;

                WHEN 'hash' THEN
                    select_expr := '@extschema@.salted_hash(' || quote_ident(col_name) || '::text, ' || quote_literal(coalesce(rule ->> 'salt', '')) || ')';

                WHEN 'perturb' THEN
                    seed_col := rule ->> 'seed_column';
                    IF seed_col IS NOT NULL THEN
                        select_expr := '@extschema@.perturb_numeric_deterministic(' || quote_ident(col_name) || '::numeric, ' || quote_ident(seed_col) || '::text, ' || coalesce(rule ->> 'variance', '0.07') || ')';
                    ELSE
                        select_expr := '@extschema@.perturb_numeric(' || quote_ident(col_name) || '::numeric, ' || coalesce(rule ->> 'variance', '0.07') || ')';
                    END IF;

                WHEN 'shift_date' THEN
                    seed_col := rule ->> 'seed_column';
                    IF seed_col IS NOT NULL THEN
                        select_expr := '@extschema@.shift_date_deterministic(' || quote_ident(col_name) || '::date, ' || quote_ident(seed_col) || '::text, ' || coalesce(rule ->> 'days', '30') || ')';
                    ELSE
                        select_expr := '@extschema@.shift_date_deterministic(' || quote_ident(col_name) || '::date, ' || quote_literal('default_seed') || ', ' || coalesce(rule ->> 'days', '30') || ')';
                    END IF;

                WHEN 'generalize_numeric' THEN
                    select_expr := '@extschema@.generalize_numeric(' || quote_ident(col_name) || '::numeric, ' || coalesce(rule ->> 'bucket', '10') || ')';

                WHEN 'generalize_date' THEN
                    select_expr := '@extschema@.generalize_date(' || quote_ident(col_name) || '::date, ' || quote_literal(coalesce(rule ->> 'bucket', 'month')) || ')';

                WHEN 'redact' THEN
                    IF (rule ->> 'value') IS NULL OR (rule ->> 'value') = 'NULL' THEN
                        select_expr := 'NULL';
                    ELSE
                        select_expr := quote_literal(rule ->> 'value');
                    END IF;

                WHEN 'custom' THEN
                    -- Replace placeholder {col} with the actual quoted column identifier
                    select_expr := replace(rule ->> 'expression', '{col}', quote_ident(col_name));

                ELSE
                    -- Unknown rule type: default to as-is
                    select_expr := quote_ident(col_name);
            END CASE;

            -- Ensure expression is cast back to the original column type
            select_expr := '(' || select_expr || ')::' || col_type;
        ELSE
            -- No rule defined: select as-is
            select_expr := quote_ident(col_name);
        END IF;

        -- Append to select list
        IF select_list != '' THEN
            select_list := select_list || ', ';
        END IF;
        select_list := select_list || select_expr || ' AS ' || quote_ident(col_name);
    END LOOP;

    -- Build and execute CREATE VIEW statement
    sql_stmt := 'CREATE OR REPLACE VIEW ' || quote_ident(view_name) || ' AS SELECT ' || select_list || ' FROM ' || full_table_name;
    EXECUTE sql_stmt;
END;
$$ LANGUAGE plpgsql VOLATILE;


-- ---------------------------------------------------------------------
-- 9. ROLE GRANTS (Supabase)
-- ---------------------------------------------------------------------
-- The masking helpers execute with the *invoker's* privileges, so any
-- role that calls them directly (PostgREST RPC, or an invoker-side
-- wrapper function such as the get_secured_customers() pattern) needs
-- USAGE on the extension schema and EXECUTE on the functions.
--
-- NOTE: querying a masked VIEW does NOT require these grants -- a view
-- accesses its referenced functions/tables as the view OWNER, so the
-- client only needs SELECT on the view itself.
--
-- Wrapped in role-existence checks so CREATE EXTENSION still succeeds on
-- non-Supabase Postgres where anon/authenticated do not exist.
-- @extschema@ is substituted by pg_tle with the install schema, so this
-- stays relocatable.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        GRANT USAGE ON SCHEMA @extschema@ TO anon;
        GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA @extschema@ TO anon;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        GRANT USAGE ON SCHEMA @extschema@ TO authenticated;
        GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA @extschema@ TO authenticated;
    END IF;

    -- create_masked_view() runs dynamic DDL (CREATE VIEW). Keep it out of
    -- reach of untrusted client roles: an admin/owner should create the
    -- masked view once, then expose it via GRANT SELECT on the view.
    -- Remove these REVOKEs if you deliberately want clients to build their
    -- own masked views.
    REVOKE EXECUTE ON FUNCTION @extschema@.create_masked_view(regclass, text, jsonb) FROM PUBLIC;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
        REVOKE EXECUTE ON FUNCTION @extschema@.create_masked_view(regclass, text, jsonb) FROM anon;
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        REVOKE EXECUTE ON FUNCTION @extschema@.create_masked_view(regclass, text, jsonb) FROM authenticated;
    END IF;
END $$;
