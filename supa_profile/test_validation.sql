-- =====================================================================
-- SUPA_PROFILE EXTENSION VALIDATION TEST SCRIPT
-- Run this script to verify the correctness of the profiling functions.
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------
-- 1. Loading extension schema and functions...
-- ---------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS supa_profile;

CREATE OR REPLACE FUNCTION supa_profile.classify_values(vals text[])
RETURNS text AS $$
DECLARE
    val text;
    total int := 0;
    uuid_cnt int := 0;
    email_cnt int := 0;
    ipv4_cnt int := 0;
    url_cnt int := 0;
    numeric_cnt int := 0;
    date_cnt int := 0;
BEGIN
    IF vals IS NULL OR array_length(vals, 1) IS NULL THEN
        RETURN '.*';
    END IF;
    
    total := array_length(vals, 1);
    
    FOREACH val IN ARRAY vals LOOP
        IF val IS NULL OR val = 'NULL' OR val = '' THEN
            total := total - 1;
            CONTINUE;
        END IF;
        
        IF val ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
            uuid_cnt := uuid_cnt + 1;
        ELSIF val ~* '^[a-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$' THEN
            email_cnt := email_cnt + 1;
        ELSIF val ~* '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$' THEN
            ipv4_cnt := ipv4_cnt + 1;
        ELSIF val ~* '^https?://[^\s/$.?#].[^\s]*$' THEN
            url_cnt := url_cnt + 1;
        ELSIF val ~* '^-?\d+$' THEN
            numeric_cnt := numeric_cnt + 1;
        ELSIF val ~* '^\d{4}-\d{2}-\d{2}$' OR val ~* '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}' THEN
            date_cnt := date_cnt + 1;
        END IF;
    END LOOP;
    
    IF total <= 0 THEN
        RETURN '.*';
    END IF;
    
    IF (uuid_cnt::numeric / total) >= 0.8 THEN RETURN 'UUID'; END IF;
    IF (email_cnt::numeric / total) >= 0.8 THEN RETURN 'EMAIL'; END IF;
    IF (ipv4_cnt::numeric / total) >= 0.8 THEN RETURN 'IPV4'; END IF;
    IF (url_cnt::numeric / total) >= 0.8 THEN RETURN 'URL'; END IF;
    IF (date_cnt::numeric / total) >= 0.8 THEN RETURN 'DATE'; END IF;
    IF (numeric_cnt::numeric / total) >= 0.8 THEN RETURN 'NUMERIC'; END IF;
    
    RETURN '.*';
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION supa_profile.infer_pattern(data_type text)
RETURNS text AS $$
DECLARE
    t text := upper(data_type);
BEGIN
    IF t = 'UUID' THEN RETURN 'UUID'; END IF;
    IF t = 'INET' THEN RETURN 'IPV4'; END IF;
    IF t LIKE '%DATE%' THEN RETURN 'YYYY-MM-DD'; END IF;
    IF t LIKE '%TIME%' THEN RETURN 'HH:MM:SS'; END IF;
    IF t LIKE '%INT%' THEN RETURN '-?\d+'; END IF;
    IF t LIKE '%FLOAT%' OR t LIKE '%NUMERIC%' OR t LIKE '%DECIMAL%' OR t LIKE '%DOUBLE%' OR t LIKE '%REAL%' THEN 
        RETURN '-?\d+\.?\d*'; 
    END IF;
    RETURN '.*';
END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION supa_profile.profile_table(
    target_table regclass,
    options jsonb DEFAULT '{}'
)
RETURNS jsonb AS $$
DECLARE
    -- Options
    scan_field_values boolean;
    min_cell_count int;
    max_distinct_values int;
    rows_per_table int;
    calculate_numeric_stats boolean;
    use_estimated_stats boolean;
    sampling_method text;
    sample_percentage numeric;

    -- Execution metadata
    start_time timestamptz;
    duration_ms numeric;
    total_rows bigint;
    column_count int;
    
    -- Resolving names
    schema_name_val text;
    table_name_val text;
    full_table_name text;
    from_clause text;
    
    -- Column loops
    col record;
    is_numeric boolean;
    skip_min_max boolean;
    
    -- SQL Construction
    select_exprs text := '';
    query_str text;
    result_row record;
    result_json jsonb;
    
    -- Arrays
    fields_array jsonb := '[]'::jsonb;
    values_array jsonb := '[]'::jsonb;
    
    -- Temp vars for each column
    non_null_count bigint;
    distinct_count bigint;
    min_val text;
    max_val text;
    avg_len numeric;
    max_len bigint;
    avg_val numeric;
    median_val numeric;
    p90_val numeric;
    p99_val numeric;
    pattern_val text;
    
    -- Value Distribution (Unified Parallelized Union Query)
    val_query text := '';
    val_rec record;
    val_obj jsonb;
    field_obj jsonb;
    mode_val text;
    sample_vals text[];
    
    -- Estimated Stats variables
    null_fraction numeric;
    distinct_stat numeric;
    width_stat int;
    mcv_vals text[];
    mcf_freqs numeric[];
    i int;
BEGIN
    start_time := clock_timestamp();
    full_table_name := target_table::text;

    -- Retrieve resolved schema and table name
    SELECT n.nspname, c.relname
    INTO schema_name_val, table_name_val
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = target_table;

    -- Ensure options is not null
    options := coalesce(options, '{}'::jsonb);

    -- Parse options with defaults
    scan_field_values := coalesce((options ->> 'scan_field_values')::boolean, true);
    min_cell_count := coalesce((options ->> 'min_cell_count')::int, 5);
    max_distinct_values := coalesce((options ->> 'max_distinct_values')::int, 100);
    rows_per_table := coalesce((options ->> 'rows_per_table')::int, 0);
    calculate_numeric_stats := coalesce((options ->> 'calculate_numeric_stats')::boolean, true);
    use_estimated_stats := coalesce((options ->> 'use_estimated_stats')::boolean, false);
    sampling_method := coalesce(lower(options ->> 'sampling_method'), 'limit');
    sample_percentage := (options ->> 'sample_percentage')::numeric;

    -- Retrieve column count
    SELECT COUNT(*)::int INTO column_count
    FROM pg_attribute
    WHERE attrelid = target_table AND attnum > 0 AND NOT attisdropped;

    -- -----------------------------------------------------------------
    -- BRANCH A: CATALOG-BASED ESTIMATED PROFILING (Fast path)
    -- -----------------------------------------------------------------
    IF use_estimated_stats THEN
        -- Get estimated row count from pg_class
        SELECT reltuples::bigint INTO total_rows
        FROM pg_class
        WHERE oid = target_table;
        
        -- Guard against negative estimates
        IF total_rows < 0 THEN
            total_rows := 0;
        END IF;

        FOR col IN
            SELECT 
                attname AS column_name,
                format_type(atttypid, atttypmod) AS data_type,
                NOT attnotnull AS is_nullable
            FROM pg_attribute
            WHERE attrelid = target_table AND attnum > 0 AND NOT attisdropped
            ORDER BY attnum
        LOOP
            -- Check if we have stats in pg_stats
            SELECT 
                null_frac, n_distinct, avg_width, 
                most_common_vals::text::text[], most_common_freqs
            INTO null_fraction, distinct_stat, width_stat, mcv_vals, mcf_freqs
            FROM pg_stats
            WHERE schemaname = schema_name_val AND tablename = table_name_val AND attname = col.column_name;

            IF null_fraction IS NOT NULL THEN
                non_null_count := (total_rows * (1.0 - null_fraction))::bigint;
                
                -- Calculate distinct count
                IF distinct_stat < 0 THEN
                    distinct_count := (abs(distinct_stat) * total_rows)::bigint;
                ELSE
                    distinct_count := distinct_stat::bigint;
                END IF;
                
                avg_len := width_stat::numeric;
                max_len := width_stat::bigint;
            ELSE
                non_null_count := total_rows;
                distinct_count := 0;
                avg_len := 0;
                max_len := 0;
                mcv_vals := NULL;
                mcf_freqs := NULL;
            END IF;

            -- Build value distribution list from MCV/MCF
            mode_val := '';
            IF scan_field_values AND mcv_vals IS NOT NULL AND mcf_freqs IS NOT NULL THEN
                FOR i IN 1..array_length(mcv_vals, 1) LOOP
                    IF i = 1 THEN
                        mode_val := mcv_vals[1];
                    END IF;
                    
                    val_obj := jsonb_build_object(
                        'columnName', col.column_name,
                        'value', mcv_vals[i],
                        'frequency', (mcf_freqs[i] * total_rows)::bigint,
                        'percent', mcf_freqs[i]::numeric(10,4)
                    );
                    values_array := values_array || jsonb_build_array(val_obj);
                END LOOP;
            END IF;

            -- Classify pattern from MCV values
            IF mcv_vals IS NOT NULL AND array_length(mcv_vals, 1) > 0 THEN
                pattern_val := supa_profile.classify_values(mcv_vals);
            ELSE
                pattern_val := supa_profile.infer_pattern(col.data_type);
            END IF;

            field_obj := jsonb_build_object(
                'tableName', full_table_name,
                'columnName', col.column_name,
                'dataType', col.data_type,
                'nullable', col.is_nullable,
                'nonNullCount', non_null_count,
                'nullCount', total_rows - non_null_count,
                'distinctCount', distinct_count,
                'avgLength', avg_len,
                'maxLength', max_len,
                'mode', mode_val,
                'pattern', pattern_val
            );
            fields_array := fields_array || jsonb_build_array(field_obj);
        END LOOP;

    -- -----------------------------------------------------------------
    -- BRANCH B: DYNAMIC QUERY-BASED EXACT PROFILING (Thorough path)
    -- -----------------------------------------------------------------
    ELSE
        -- Build FROM clause with dynamic sampling options
        IF sampling_method IN ('system', 'bernoulli') AND sample_percentage > 0 AND sample_percentage <= 100 THEN
            from_clause := full_table_name || ' TABLESAMPLE ' || upper(sampling_method) || ' (' || sample_percentage || ')';
        ELSIF rows_per_table > 0 THEN
            from_clause := '(SELECT * FROM ' || full_table_name || ' LIMIT ' || rows_per_table || ') AS sampled_table';
        ELSE
            from_clause := full_table_name;
        END IF;

        -- Build SELECT expressions for column stats
        FOR col IN
            SELECT 
                attname AS column_name,
                format_type(atttypid, atttypmod) AS data_type,
                NOT attnotnull AS is_nullable
            FROM pg_attribute
            WHERE attrelid = target_table AND attnum > 0 AND NOT attisdropped
            ORDER BY attnum
        LOOP
            -- Determine if type is numeric
            is_numeric := (col.data_type IN ('smallint', 'integer', 'bigint', 'decimal', 'numeric', 'real', 'double precision') 
                           OR col.data_type ~* 'int|numeric|decimal|real|double|float|number');

            -- Determine if type does not support MIN/MAX
            skip_min_max := (col.data_type ~* '\[\]|json|jsonb|bytea|xml|geometry|geography|box|circle|line|lseg|path|point|polygon|xid|cid|oid|tid|txid_snapshot|uuid');

            -- Basic column stats
            select_exprs := select_exprs || ', COUNT(' || quote_ident(col.column_name) || ') AS ' || quote_ident(col.column_name || '__non_null');
            select_exprs := select_exprs || ', COUNT(DISTINCT ' || quote_ident(col.column_name) || ') AS ' || quote_ident(col.column_name || '__distinct');

            -- MIN/MAX
            IF skip_min_max THEN
                select_exprs := select_exprs || ', NULL::text AS ' || quote_ident(col.column_name || '__min');
                select_exprs := select_exprs || ', NULL::text AS ' || quote_ident(col.column_name || '__max');
            ELSE
                select_exprs := select_exprs || ', MIN(' || quote_ident(col.column_name) || ')::text AS ' || quote_ident(col.column_name || '__min');
                select_exprs := select_exprs || ', MAX(' || quote_ident(col.column_name) || ')::text AS ' || quote_ident(col.column_name || '__max');
            END IF;

            -- Avg and Max string length
            select_exprs := select_exprs || ', AVG(length(' || quote_ident(col.column_name) || '::text))::numeric AS ' || quote_ident(col.column_name || '__avg_len');
            select_exprs := select_exprs || ', MAX(length(' || quote_ident(col.column_name) || '::text))::bigint AS ' || quote_ident(col.column_name || '__max_len');

            -- Numeric stats (AVG, MEDIAN, P90, P99)
            IF calculate_numeric_stats AND is_numeric THEN
                select_exprs := select_exprs || ', AVG(' || quote_ident(col.column_name) || ')::numeric AS ' || quote_ident(col.column_name || '__avg');
                select_exprs := select_exprs || ', percentile_disc(0.5) WITHIN GROUP (ORDER BY ' || quote_ident(col.column_name) || ')::numeric AS ' || quote_ident(col.column_name || '__median');
                select_exprs := select_exprs || ', percentile_disc(0.9) WITHIN GROUP (ORDER BY ' || quote_ident(col.column_name) || ')::numeric AS ' || quote_ident(col.column_name || '__p90');
                select_exprs := select_exprs || ', percentile_disc(0.99) WITHIN GROUP (ORDER BY ' || quote_ident(col.column_name) || ')::numeric AS ' || quote_ident(col.column_name || '__p99');
            ELSE
                select_exprs := select_exprs || ', NULL::numeric AS ' || quote_ident(col.column_name || '__avg');
                select_exprs := select_exprs || ', NULL::numeric AS ' || quote_ident(col.column_name || '__median');
                select_exprs := select_exprs || ', NULL::numeric AS ' || quote_ident(col.column_name || '__p90');
                select_exprs := select_exprs || ', NULL::numeric AS ' || quote_ident(col.column_name || '__p99');
            END IF;
        END LOOP;

        -- Execute main statistics query
        query_str := 'SELECT COUNT(*) AS total_rows' || select_exprs || ' FROM ' || from_clause;
        EXECUTE query_str INTO result_row;
        result_json := to_jsonb(result_row);
        total_rows := (result_json ->> 'total_rows')::bigint;

        -- Build unified parallelized value distribution query if enabled
        IF scan_field_values AND total_rows > 0 THEN
            FOR col IN
                SELECT attname AS column_name
                FROM pg_attribute
                WHERE attrelid = target_table AND attnum > 0 AND NOT attisdropped
                ORDER BY attnum
            LOOP
                IF val_query != '' THEN
                    val_query := val_query || ' UNION ALL ';
                END IF;
                val_query := val_query || 
                             'SELECT * FROM (' ||
                             'SELECT ' || 
                             quote_literal(col.column_name) || ' AS column_name, ' || 
                             'coalesce(' || quote_ident(col.column_name) || '::text, ''NULL'') AS value, ' || 
                             'COUNT(*) AS frequency ' ||
                             'FROM ' || from_clause || ' ' ||
                             'WHERE ' || quote_ident(col.column_name) || ' IS NOT NULL ' ||
                             'GROUP BY ' || quote_ident(col.column_name) || '::text ' ||
                             'HAVING COUNT(*) >= ' || min_cell_count || ' ' ||
                             'ORDER BY COUNT(*) DESC ' ||
                             'LIMIT ' || max_distinct_values || ') q_' || quote_ident(col.column_name);
            END LOOP;

            IF val_query != '' THEN
                FOR val_rec IN EXECUTE val_query LOOP
                    val_obj := jsonb_build_object(
                        'columnName', val_rec.column_name,
                        'value', val_rec.value,
                        'frequency', val_rec.frequency,
                        'percent', CASE WHEN total_rows > 0 THEN (val_rec.frequency::numeric / total_rows)::numeric(10,4) ELSE 0 END
                    );
                    values_array := values_array || jsonb_build_array(val_obj);
                END LOOP;
            END IF;
        END IF;

        -- Build final fields array
        FOR col IN
            SELECT 
                attname AS column_name,
                format_type(atttypid, atttypmod) AS data_type,
                NOT attnotnull AS is_nullable
            FROM pg_attribute
            WHERE attrelid = target_table AND attnum > 0 AND NOT attisdropped
            ORDER BY attnum
        LOOP
            non_null_count := (result_json ->> (col.column_name || '__non_null'))::bigint;
            distinct_count := (result_json ->> (col.column_name || '__distinct'))::bigint;
            min_val := result_json ->> (col.column_name || '__min');
            max_val := result_json ->> (col.column_name || '__max');
            avg_len := (result_json ->> (col.column_name || '__avg_len'))::numeric;
            max_len := (result_json ->> (col.column_name || '__max_len'))::bigint;
            avg_val := (result_json ->> (col.column_name || '__avg'))::numeric;
            median_val := (result_json ->> (col.column_name || '__median'))::numeric;
            p90_val := (result_json ->> (col.column_name || '__p90'))::numeric;
            p99_val := (result_json ->> (col.column_name || '__p99'))::numeric;

            -- Find mode for this column if we scanned values
            mode_val := '';
            IF scan_field_values THEN
                DECLARE
                    temp_val jsonb;
                BEGIN
                    FOR temp_val IN SELECT * FROM jsonb_array_elements(values_array) LOOP
                        IF temp_val ->> 'columnName' = col.column_name THEN
                            mode_val := temp_val ->> 'value';
                            EXIT;
                        END IF;
                    END LOOP;
                END;
            END IF;

            -- Collect a small sample of values to classify the data pattern
            EXECUTE 'SELECT array_agg(' || quote_ident(col.column_name) || '::text) FROM (SELECT ' || quote_ident(col.column_name) || ' FROM ' || from_clause || ' WHERE ' || quote_ident(col.column_name) || ' IS NOT NULL LIMIT 50) t' INTO sample_vals;
            
            IF sample_vals IS NOT NULL AND array_length(sample_vals, 1) > 0 THEN
                pattern_val := supa_profile.classify_values(sample_vals);
            ELSE
                pattern_val := supa_profile.infer_pattern(col.data_type);
            END IF;

            -- Construct field profile object matching FieldProfile interface
            field_obj := jsonb_build_object(
                'tableName', full_table_name,
                'columnName', col.column_name,
                'dataType', col.data_type,
                'nullable', col.is_nullable,
                'nonNullCount', non_null_count,
                'nullCount', total_rows - non_null_count,
                'distinctCount', distinct_count,
                'avgLength', coalesce(avg_len, 0),
                'maxLength', coalesce(max_len, 0),
                'mode', mode_val,
                'pattern', pattern_val
            );

            -- Add optional numeric and min/max stats
            IF min_val IS NOT NULL THEN
                field_obj := field_obj || jsonb_build_object('minValue', min_val);
            END IF;
            IF max_val IS NOT NULL THEN
                field_obj := field_obj || jsonb_build_object('maxValue', max_val);
            END IF;
            IF avg_val IS NOT NULL THEN
                field_obj := field_obj || jsonb_build_object('avgValue', avg_val);
            END IF;
            IF median_val IS NOT NULL THEN
                field_obj := field_obj || jsonb_build_object('median', median_val);
            END IF;
            IF p90_val IS NOT NULL THEN
                field_obj := field_obj || jsonb_build_object('p90', p90_val);
            END IF;
            IF p99_val IS NOT NULL THEN
                field_obj := field_obj || jsonb_build_object('p99', p99_val);
            END IF;

            fields_array := fields_array || jsonb_build_array(field_obj);
        END LOOP;
    END IF;

    duration_ms := EXTRACT(EPOCH FROM (clock_timestamp() - start_time)) * 1000;

    -- Return full result matching ProfilingResult interface
    RETURN jsonb_build_object(
        'tableStats', jsonb_build_object(
            'tableName', full_table_name,
            'rowCount', total_rows,
            'columnCount', column_count,
            'selected', false
        ),
        'fields', fields_array,
        'values', values_array,
        'profiledAt', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'durationMs', round(duration_ms, 2),
        'queryMode', CASE 
            WHEN use_estimated_stats THEN 'ESTIMATED'
            WHEN rows_per_table > 0 OR sample_percentage > 0 THEN 'FAST'
            ELSE 'NORMAL'
        END
    );
END;
$$ LANGUAGE plpgsql VOLATILE STRICT;

-- ---------------------------------------------------------
-- 2. Create mock table and populate data...
-- ---------------------------------------------------------

CREATE TEMP TABLE mock_users (
    id serial PRIMARY KEY,
    username text NOT NULL,
    email text,
    uuid_val uuid,
    ip_val text,
    url_val text,
    age int,
    salary numeric(10, 2),
    signup_date date
);

INSERT INTO mock_users (username, email, uuid_val, ip_val, url_val, age, salary, signup_date) VALUES
('alice', 'alice@corp.com', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid, '192.168.1.1', 'https://supabase.com', 25, 80000.00, '2025-01-10'::date),
('bob', 'bob@corp.com', 'b0eebc99-9c0b-4ef8-bb6d-6bb9bd380a22'::uuid, '192.168.1.2', 'https://google.com', 30, 95000.00, '2025-02-15'::date),
('charlie', 'charlie@gmail.com', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380a33'::uuid, '10.0.0.1', 'https://github.com', 45, 120000.50, '2024-11-20'::date),
('diana', 'diana@corp.com', 'd0eebc99-9c0b-4ef8-bb6d-6bb9bd380a44'::uuid, '10.0.0.2', 'https://database.dev', 25, 80000.00, '2025-03-01'::date),
('diana', 'diana@corp.com', 'e0eebc99-9c0b-4ef8-bb6d-6bb9bd380a55'::uuid, '10.0.0.3', 'https://database.dev', 25, NULL::numeric, NULL::date);

-- ---------------------------------------------------------
-- 3. Execute unit tests...
-- ---------------------------------------------------------
DO $$
DECLARE
    res jsonb;
    fields jsonb;
    vals jsonb;
    f record;
    v record;
BEGIN
    -- Profile the mock table with default options
    res := supa_profile.profile_table('mock_users'::regclass, '{"min_cell_count": 2}'::jsonb);

    -- Verify tableStats
    ASSERT res -> 'tableStats' ->> 'tableName' = 'mock_users', 'Table stats name mismatch';
    ASSERT (res -> 'tableStats' ->> 'rowCount')::int = 5, 'Table stats row count mismatch';
    ASSERT (res -> 'tableStats' ->> 'columnCount')::int = 9, 'Table stats column count mismatch';
    
    fields := res -> 'fields';
    vals := res -> 'values';

    -- Loop through fields and check pattern classifiers and basic validations
    FOR f IN SELECT * FROM jsonb_to_recordset(fields) AS (
        "columnName" text, "dataType" text, "nullable" boolean, 
        "nonNullCount" int, "nullCount" int, "distinctCount" int, 
        "minValue" text, "maxValue" text, "avgValue" numeric, 
        "median" numeric, "mode" text, "pattern" text
    ) LOOP
        IF f."columnName" = 'id' THEN
            ASSERT f."nullable" = false, 'id should not be nullable';
            ASSERT f."nonNullCount" = 5, 'id non-null count mismatch';
            ASSERT f."distinctCount" = 5, 'id distinct count mismatch';
            ASSERT f."pattern" = 'NUMERIC', 'id pattern classification failed (expected NUMERIC)';
        ELSIF f."columnName" = 'username' THEN
            ASSERT f."mode" = 'diana', 'username mode mismatch (should be diana, frequency = 2)';
            ASSERT f."pattern" = '.*', 'username pattern classification failed (expected .*)';
        ELSIF f."columnName" = 'email' THEN
            ASSERT f."pattern" = 'EMAIL', 'email pattern classification failed (expected EMAIL)';
        ELSIF f."columnName" = 'uuid_val' THEN
            ASSERT f."pattern" = 'UUID', 'uuid_val pattern classification failed (expected UUID)';
        ELSIF f."columnName" = 'ip_val' THEN
            ASSERT f."pattern" = 'IPV4', 'ip_val pattern classification failed (expected IPV4)';
        ELSIF f."columnName" = 'url_val' THEN
            ASSERT f."pattern" = 'URL', 'url_val pattern classification failed (expected URL)';
        ELSIF f."columnName" = 'signup_date' THEN
            ASSERT f."pattern" = 'DATE', 'signup_date pattern classification failed (expected DATE)';
        ELSIF f."columnName" = 'age' THEN
            ASSERT f."pattern" = 'NUMERIC', 'age pattern classification failed (expected NUMERIC)';
            ASSERT f."median" = 25.00, 'age median mismatch';
        END IF;
    END LOOP;

    -- Verify value distribution (we filtered with min_cell_count = 2)
    -- Values expected to be frequent: age=25 (freq=3), email=diana@corp.com (freq=2), country/url_val=https://database.dev (freq=2)
    DECLARE
        age_25_found boolean := false;
        email_diana_found boolean := false;
        url_dbdev_found boolean := false;
    BEGIN
        FOR v IN SELECT * FROM jsonb_to_recordset(vals) AS (
            "columnName" text, "value" text, "frequency" int, "percent" numeric
        ) LOOP
            IF v."columnName" = 'age' AND v."value" = '25' THEN
                ASSERT v."frequency" = 3, 'age 25 frequency mismatch';
                age_25_found := true;
            ELSIF v."columnName" = 'email' AND v."value" = 'diana@corp.com' THEN
                ASSERT v."frequency" = 2, 'email diana frequency mismatch';
                email_diana_found := true;
            ELSIF v."columnName" = 'url_val' AND v."value" = 'https://database.dev' THEN
                ASSERT v."frequency" = 2, 'url_val frequency mismatch';
                url_dbdev_found := true;
            END IF;
        END LOOP;

        ASSERT age_25_found, 'age 25 value distribution missing';
        ASSERT email_diana_found, 'email diana value distribution missing';
        ASSERT url_dbdev_found, 'url_val database.dev value distribution missing';
    END;

    -- Test TABLESAMPLE system/bernoulli options
    res := supa_profile.profile_table('mock_users'::regclass, '{"sampling_method": "bernoulli", "sample_percentage": 100}'::jsonb);
    ASSERT res ->> 'queryMode' = 'FAST', 'FAST queryMode mismatch for sampled table';
    ASSERT (res -> 'tableStats' ->> 'rowCount')::int = 5, 'tablesample result size mismatch';

    -- Test CATALOG ESTIMATIONS
    -- Execute ANALYZE so that pg_stats gets populated for our temp table
    -- Temp tables need manual ANALYZE to populate statistics
    ANALYZE mock_users;
    
    res := supa_profile.profile_table('mock_users'::regclass, '{"use_estimated_stats": true}'::jsonb);
    ASSERT res ->> 'queryMode' = 'ESTIMATED', 'ESTIMATED queryMode mismatch';
    ASSERT (res -> 'tableStats' ->> 'rowCount')::int = 5, 'Estimated row count mismatch';
    
    -- Verify pattern classification on catalog estimations
    FOR f IN SELECT * FROM jsonb_to_recordset(res -> 'fields') AS ("columnName" text, "pattern" text) LOOP
        IF f."columnName" = 'email' THEN
            ASSERT f."pattern" = 'EMAIL', 'Estimated email pattern failed';
        ELSIF f."columnName" = 'uuid_val' THEN
            ASSERT f."pattern" = 'UUID', 'Estimated uuid pattern failed';
        END IF;
    END LOOP;

    RAISE NOTICE '✅ All supa_profile unit tests passed successfully!';
END;
$$;

DROP TABLE IF EXISTS mock_users;
DROP SCHEMA supa_profile CASCADE;

ROLLBACK;
