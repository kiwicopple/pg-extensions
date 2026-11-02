/*
 * pg_permissions: upgrade 0.0.1 to 0.1.0
 *
 * Copyright (c) 2026 Paul Copplestone: https://github.com/kiwicopple/pg-extensions/
 *
 * Run on a database that has pg_permissions--0.0.1.sql installed. Afterwards
 * the schema matches a fresh install of pg_permissions--0.1.0.sql:
 * test/spec/d/05_upgrade.sql compares every function (signature, body,
 * settings, privileges) and every table, column and index.
 *
 *   pg_tle:   select pgtle.install_update_path('pg_permissions', '0.0.1', '0.1.0', <this file>);
 *             alter extension pg_permissions update to '0.1.0';
 *   plain:    psql -v ON_ERROR_STOP=1 -1 -f pg_permissions--0.0.1--0.1.0.sql
 *
 * No psql meta-commands: pg_tle runs this file as an extension script.
 * Changes are listed in the order of the 0.1.0 work (research/plan-cedar.md).
 */

-- ============================================================================
-- 1. Shared toolkit: neutral names for the value helpers (Cedar phase 1)
-- ============================================================================
--
--   _fga_cel_ip  -> _ip_canon
--   _fga_cel_ts  -> _ts_canon
--   _fga_cel_du  -> _duration_ns
--
-- The same bodies under the new names, then the two CEL functions that call
-- them (_fga_cel_convert, _fga_cel_eval) as in 0.1.0, then the old names go.
-- PL/pgSQL bodies are not dependencies, so the drops need no cascade. The
-- definitions are copied from pg_permissions--0.1.0.sql; spec/d/05_upgrade
-- checks that they match.

create function permissions._ip_canon(s text)
returns text
language plpgsql immutable
as $$
declare
    ip inet;
begin
    if s ~ '^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$' then
        return host(s::inet);
    end if;
    if s !~ ':' or s ~ '[/%]' or not pg_input_is_valid(s, 'inet') then
        return null;
    end if;
    ip := s::inet;
    if ip <<= '::ffff:0:0/96'::inet then
        return host(('0.0.0.0'::inet + (ip - '::ffff:0:0'::inet)));
    end if;
    return host(ip);
end;
$$;

create function permissions._ts_canon(s text)
returns text
language plpgsql immutable
as $$
declare
    m text[];
    t text;
begin
    m := regexp_match(s, '^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:[.,]([0-9]+))?(Z|[+-]([0-9]{2}):([0-9]{2}))$');
    if m is null or m[2]::int > 23 or m[3]::int > 59 or m[4]::int > 59
       or coalesce(m[7]::int, 0) > 23 or coalesce(m[8]::int, 0) > 59
       or not pg_input_is_valid(m[1], 'date') or m[1] < '0001' then
        return null;
    end if;
    t := m[1] || ' ' || m[2] || ':' || m[3] || ':' || m[4] || coalesce('.' || left(m[5], 6), '')
         || case when m[6] = 'Z' then '+00:00' else m[6] end;
    return to_char(t::timestamptz at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
end;
$$;

create function permissions._duration_ns(s text)
returns numeric
language plpgsql immutable
as $$
declare
    body text;
    total numeric := 0;
    m text[];
begin
    if s = '0' or s = '+0' or s = '-0' then
        return 0;
    end if;
    if s !~ '^[+-]?(([0-9]+(\.[0-9]*)?|\.[0-9]+)(ns|us|µs|μs|ms|s|m|h))+$' then
        return null;
    end if;
    body := ltrim(s, '+-');
    for m in select regexp_matches(body, '([0-9]*\.?[0-9]*)(ns|us|µs|μs|ms|s|m|h)', 'g') loop
        total := total + (case when m[1] like '.%' then '0' || m[1] when m[1] like '%.' then m[1] || '0' else m[1] end)::numeric
                 * case m[2] when 'ns' then 1 when 'ms' then 1000000 when 's' then 1000000000 when 'm' then 60000000000
                             when 'h' then 3600000000000 else 1000 end;
    end loop;
    total := trunc(total);
    if left(s, 1) = '-' then
        total := -total;
    end if;
    if total not between -9223372036854775808 and 9223372036854775807 then
        return null;
    end if;
    return total;
end;
$$;

revoke all on function
    permissions._ip_canon(text),
    permissions._ts_canon(text),
    permissions._duration_ns(text)
from public;

create or replace function permissions._fga_cel_convert(t jsonb, v jsonb)
returns permissions.fga_cel_result
language plpgsql immutable
as $$
declare
    tn text := case when jsonb_typeof(t) = 'string' then t #>> '{}' else t ->> 0 end;
    jt text := jsonb_typeof(v);
    s text;
    num numeric;
    f float8;
    r permissions.fga_cel_result;
    acc jsonb;
    e record;
    i int;
begin
    if tn = 'dyn' then
        return row(v, null::text, 0);
    elsif tn in ('bool', 'string') then
        if jt = (case tn when 'bool' then 'boolean' else 'string' end) then
            return row(v, null::text, 0);
        end if;
        return row(null::jsonb, format('expected type value ''%s'', but found ''%s''', tn, case jt when 'number' then 'float64' when 'boolean' then 'bool' when 'array' then '[]interface {}' when 'object' then 'map[string]interface {}' when 'null' then '<nil>' else jt end), 0);
    elsif tn in ('int', 'uint', 'double') then
        if jt = 'number' then
            if not pg_input_is_valid(v::text, 'float8') then
                return row(null::jsonb, format('number cannot be represented as a float64: %s', v), 0);
            end if;
            f := (v::text)::float8;
            if tn = 'double' then
                return row(to_jsonb(f), null::text, 0);
            end if;
            if f <> trunc(f) then
                return row(null::jsonb, format('expected %s %s value, but found numeric value ''%s''', case tn when 'int' then 'an' else 'a' end, tn, f), 0);
            end if;
            num := case when f >= 9223372036854775807::float8 then 9223372036854775807
                        when f <= -9223372036854775808::float8 then -9223372036854775808
                        else f::bigint end;
        elsif jt = 'string' then
            s := v #>> '{}';
            if s !~ '^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$' then
                return row(null::jsonb, format('expected a %s value, but found invalid string value ''%s''', case tn when 'int' then 'int64' when 'uint' then 'uint64' else 'float64' end, s), 0);
            end if;
            num := s::numeric;
            if tn = 'double' then
                if not permissions._fga_cel_exact_double(num) then
                    return row(null::jsonb, format('number cannot be represented as a float64: %s', s), 0);
                end if;
                return row(to_jsonb(num::float8), null::text, 0);
            end if;
            if num <> trunc(num) and abs(num) < 18446744073709551616 then
                return row(null::jsonb, format('expected %s %s value, but found numeric value ''%s''', case tn when 'int' then 'an' else 'a' end, tn, s), 0);
            end if;
            num := greatest(least(trunc(num), 9223372036854775807), -9223372036854775808);
        else
            return row(null::jsonb, format('expected type value ''%s'', but found ''%s''', case tn when 'int' then 'int64' when 'uint' then 'uint64' else 'float64' end,
                                    case jt when 'boolean' then 'bool' when 'array' then '[]interface {}' when 'object' then 'map[string]interface {}' when 'null' then '<nil>' else jt end), 0);
        end if;
        if tn = 'uint' and num < 0 then
            return row(null::jsonb, format('expected a uint value, but found int64 value ''%s''', num), 0);
        end if;
        return row(to_jsonb(num), null::text, 0);
    elsif tn = 'duration' then
        if jt = 'string' then
            num := permissions._duration_ns(v #>> '{}');
            if num is not null then
                return row(to_jsonb(num), null::text, 0);
            end if;
            return row(null::jsonb, format('expected a valid duration string, but found: ''%s''', v #>> '{}'), 0);
        end if;
        return row(null::jsonb, format('expected a duration string, but found: %s', v), 0);
    elsif tn = 'timestamp' then
        if jt = 'string' then
            s := permissions._ts_canon(v #>> '{}');
            if s is not null then
                return row(to_jsonb(s), null::text, 0);
            end if;
            return row(null::jsonb, format('expected RFC 3339 formatted timestamp string, but found ''%s''', v #>> '{}'), 0);
        end if;
        return row(null::jsonb, format('expected RFC 3339 formatted timestamp string, but found: %s', v), 0);
    elsif tn = 'ipaddress' then
        if jt = 'string' then
            s := permissions._ip_canon(v #>> '{}');
            if s is not null then
                return row(to_jsonb(s), null::text, 0);
            end if;
            return row(null::jsonb, format('expected a well-formed IP address, but found: ''%s''', v #>> '{}'), 0);
        end if;
        return row(null::jsonb, format('expected an ipaddress string, but found: %s', v), 0);
    elsif tn = 'list' then
        if jt <> 'array' then
            return row(null::jsonb, format('list requires a list, found: %s', v), 0);
        end if;
        acc := '[]';
        for i in 0 .. jsonb_array_length(v) - 1 loop
            r := permissions._fga_cel_convert(t -> 1, v -> i);
            if r.e is not null then
                return row(null::jsonb, format('found an invalid list item at index `%s`: %s', i, r.e), 0);
            end if;
            acc := acc || jsonb_build_array(r.v);
        end loop;
        return row(acc, null::text, 0);
    elsif tn = 'map' then
        if jt <> 'object' then
            return row(null::jsonb, format('map requires a map, found: %s', v), 0);
        end if;
        acc := '{}';
        for e in select * from jsonb_each(v) loop
            r := permissions._fga_cel_convert(t -> 2, e.value);
            if r.e is not null then
                return row(null::jsonb, format('found an invalid value for key ''%s'': %s', e.key, r.e), 0);
            end if;
            acc := acc || jsonb_build_object(e.key, r.v);
        end loop;
        return row(acc, null::text, 0);
    end if;
    return row(null::jsonb, format('unsupported parameter type %s', permissions._fga_cel_tname(t)), 0);
end;
$$;

create or replace function permissions._fga_cel_eval(n jsonb, act jsonb, c int)
returns permissions.fga_cel_result
language plpgsql immutable
as $$
declare
    kk text := n ->> 'k';
    f text;
    an jsonb;
    na int;
    vals jsonb[];
    x permissions.fga_cel_result;
    y permissions.fga_cel_result;
    v1 jsonb;
    v2 jsonb;
    k1 text;
    k2 text;
    a1 numeric;
    a2 numeric;
    d1 float8;
    d2 float8;
    s1 text collate "C";
    s2 text collate "C";
    ts timestamptz;
    lt timestamp;
    i int;
    j int;
    err text;
    acc jsonb;
    items jsonb;
    cnt int;
    lim constant int := permissions._fga_cel_cost_limit();
begin
    if kk = 'lit' then
        return row(n -> 'v', null::text, c);
    elsif kk = 'id' then
        c := c + 1;
        if c > lim then return row(null::jsonb, 'operation cancelled: actual cost limit exceeded'::text, c); end if;
        return row(act -> (n ->> 'n'), null::text, c);
    elsif kk in ('or', 'and') then
        -- commutative, absorbing an error when the other side decides
        x := permissions._fga_cel_eval(n #> '{a,0}', act, c);
        if x.e is null and x.v = to_jsonb(kk = 'or') then
            return x;
        end if;
        y := permissions._fga_cel_eval(n #> '{a,1}', act, x.c);
        if y.e is null and y.v = to_jsonb(kk = 'or') then
            return y;
        end if;
        if x.e is not null then
            return row(null::jsonb, x.e, y.c);
        end if;
        if y.e is not null then
            return y;
        end if;
        if jsonb_typeof(x.v) <> 'boolean' or jsonb_typeof(y.v) <> 'boolean' then
            return row(null::jsonb, 'no such overload'::text, y.c);
        end if;
        return row(to_jsonb(kk = 'and'), null::text, y.c);
    elsif kk = 'cond' then
        x := permissions._fga_cel_eval(n #> '{a,0}', act, c);
        if x.e is not null then return x; end if;
        if jsonb_typeof(x.v) <> 'boolean' then return row(null::jsonb, 'no such overload'::text, x.c); end if;
        return permissions._fga_cel_eval(n -> 'a' -> case when x.v = 'true' then 1 else 2 end, act, x.c);
    elsif kk = 'comp' then
        x := permissions._fga_cel_eval(n #> '{a,0}', act, c);
        if x.e is not null then return x; end if;
        c := x.c + 1;
        if jsonb_typeof(x.v) = 'array' then
            items := x.v;
        elsif jsonb_typeof(x.v) = 'object' then
            -- a map ranges over its keys
            k1 := permissions._fga_cel_kind(n #> '{a,0,t,1}', 'null');
            select coalesce(jsonb_agg(case when k1 in ('int', 'uint') then to_jsonb(e.key::numeric)
                                           when k1 = 'bool' then to_jsonb(e.key::boolean) else to_jsonb(e.key) end), '[]')
            into items from jsonb_object_keys(x.v) e(key);
        else
            return row(null::jsonb, 'no such overload'::text, c);
        end if;
        f := n ->> 'm';
        na := jsonb_array_length(n -> 'a');
        acc := case when f in ('map', 'filter') then '[]'::jsonb end;
        cnt := 0;
        err := null;
        for i in 0 .. jsonb_array_length(items) - 1 loop
            c := c + 3;
            if c > lim then return row(null::jsonb, 'operation cancelled: actual cost limit exceeded'::text, c); end if;
            v1 := act || jsonb_build_object(n ->> 'v', items -> i);
            y := permissions._fga_cel_eval(n #> '{a,1}', v1, c);
            c := y.c;
            if f in ('exists', 'all') then
                if y.e is null and jsonb_typeof(y.v) <> 'boolean' then
                    y.e := 'no such overload';
                end if;
                if y.e is null and y.v = to_jsonb(f = 'exists') then
                    return row(to_jsonb(f = 'exists'), null::text, c);
                end if;
                err := coalesce(err, y.e);
            else
                if y.e is not null then return y; end if;
                if f = 'exists_one' then
                    if jsonb_typeof(y.v) <> 'boolean' then return row(null::jsonb, 'no such overload'::text, c); end if;
                    cnt := cnt + (y.v = 'true')::int;
                elsif f = 'filter' then
                    if jsonb_typeof(y.v) <> 'boolean' then return row(null::jsonb, 'no such overload'::text, c); end if;
                    if y.v = 'true' then acc := acc || jsonb_build_array(items -> i); end if;
                elsif na = 2 then
                    acc := acc || jsonb_build_array(y.v);
                else
                    if jsonb_typeof(y.v) <> 'boolean' then return row(null::jsonb, 'no such overload'::text, c); end if;
                    if y.v = 'true' then
                        y := permissions._fga_cel_eval(n #> '{a,2}', v1, c);
                        if y.e is not null then return y; end if;
                        c := y.c;
                        acc := acc || jsonb_build_array(y.v);
                    end if;
                end if;
            end if;
        end loop;
        if f in ('exists', 'all') then
            if err is not null then return row(null::jsonb, err, c); end if;
            return row(to_jsonb(f = 'all'), null::text, c);
        elsif f = 'exists_one' then
            return row(to_jsonb(cnt = 1), null::text, c);
        end if;
        return row(acc, null::text, c);
    end if;

    -- every other node evaluates its arguments first, left to right; the
    -- first error is the result
    c := c + 1;
    if c > lim then return row(null::jsonb, 'operation cancelled: actual cost limit exceeded'::text, c); end if;
    na := jsonb_array_length(n -> 'a');
    for i in 0 .. na - 1 loop
        an := n -> 'a' -> i;
        if an ->> 'k' = 'lit' then
            vals[i + 1] := an -> 'v';
        elsif an ->> 'k' = 'id' then
            c := c + 1;
            if c > lim then return row(null::jsonb, 'operation cancelled: actual cost limit exceeded'::text, c); end if;
            vals[i + 1] := act -> (an ->> 'n');
        else
            x := permissions._fga_cel_eval(an, act, c);
            if x.e is not null then return x; end if;
            c := x.c;
            vals[i + 1] := x.v;
        end if;
    end loop;
    v1 := vals[1];
    v2 := vals[2];

    if kk in ('sel', 'has') then
        if jsonb_typeof(v1) <> 'object' then
            return row(null::jsonb, 'no such overload'::text, c);
        end if;
        if kk = 'has' then
            return row(to_jsonb(v1 ? (n ->> 'f')), null::text, c);
        end if;
        if not v1 ? (n ->> 'f') then
            return row(null::jsonb, format('no such key: %s', n ->> 'f'), c);
        end if;
        return row(v1 -> (n ->> 'f'), null::text, c);
    elsif kk = 'list' then
        return row(coalesce(to_jsonb(vals), '[]'), null::text, c);
    elsif kk = 'map' then
        acc := '{}';
        k1 := permissions._fga_cel_kind(n #> '{t,1}', 'null');
        for i in 1 .. na by 2 loop
            s1 := case when jsonb_typeof(vals[i]) = 'string' then vals[i] #>> '{}' else vals[i]::text end;
            if acc ? s1 then
                return row(null::jsonb, format('Failed with repeated key: %s', vals[i]), c);
            end if;
            acc := acc || jsonb_build_object(s1, vals[i + 1]);
        end loop;
        return row(acc, null::text, c);
    end if;

    f := n ->> 'f';
    -- comparisons
    if f in ('eq', 'ne') then
        return row(to_jsonb((v1 = v2) = (f = 'eq')), null::text, c);
    elsif f in ('lt_num', 'le_num', 'gt_num', 'ge_num') then
        return row(to_jsonb(case left(f, 2) when 'lt' then v1 < v2 when 'le' then v1 <= v2 when 'gt' then v1 > v2 else v1 >= v2 end), null::text, c);
    elsif f in ('lt_str', 'le_str', 'gt_str', 'ge_str') then
        s1 := v1 #>> '{}';
        s2 := v2 #>> '{}';
        return row(to_jsonb(case left(f, 2) when 'lt' then s1 < s2 when 'le' then s1 <= s2 when 'gt' then s1 > s2 else s1 >= s2 end), null::text, c);
    elsif f in ('lt_dyn', 'le_dyn', 'gt_dyn', 'ge_dyn') then
        k1 := permissions._fga_cel_kind(n #> '{s,0}', v1);
        k2 := permissions._fga_cel_kind(n #> '{s,1}', v2);
        if k1 in ('int', 'uint', 'double') and k2 in ('int', 'uint', 'double') then
            a1 := v1::text::numeric; a2 := v2::text::numeric;
            return row(to_jsonb(case left(f, 2) when 'lt' then a1 < a2 when 'le' then a1 <= a2 when 'gt' then a1 > a2 else a1 >= a2 end), null::text, c);
        elsif k1 = k2 and k1 = 'string' then
            s1 := v1 #>> '{}';
            s2 := v2 #>> '{}';
            return row(to_jsonb(case left(f, 2) when 'lt' then s1 < s2 when 'le' then s1 <= s2 when 'gt' then s1 > s2 else s1 >= s2 end), null::text, c);
        elsif k1 = k2 and k1 = 'bool' then
            return row(to_jsonb(case left(f, 2) when 'lt' then v1 < v2 when 'le' then v1 <= v2 when 'gt' then v1 > v2 else v1 >= v2 end), null::text, c);
        end if;
        return row(null::jsonb, 'no such overload'::text, c);
    elsif f = 'not' then
        if jsonb_typeof(v1) <> 'boolean' then return row(null::jsonb, 'no such overload'::text, c); end if;
        return row(to_jsonb(v1 = 'false'), null::text, c);
    elsif f = 'in_cidr' then
        k1 := v2 #>> '{}';
        if jsonb_typeof(v2) <> 'string' then
            return row(null::jsonb, 'a CIDR string is required for comparison'::text, c);
        end if;
        s1 := substring(k1 from '^(.*)/(?:0|[1-9][0-9]{0,2})$');
        i := substring(k1 from '/([0-9]+)$')::int;
        s2 := permissions._ip_canon(s1);
        if s1 is null or s2 is null or s1 ~ '%' or i > (case when s1 ~ ':' then 128 else 32 end) then
            return row(null::jsonb, format('''%s'' is a malformed CIDR string', k1), c);
        end if;
        -- ParsePrefix then Unmap: an IPv4-mapped prefix of 96 bits or more is its IPv4 prefix
        if s1 ~ ':' and s2 !~ ':' then
            if i < 96 then
                return row(to_jsonb((v1 #>> '{}')::inet <<= (host(s1::inet) || '/' || i)::inet), null::text, c);
            end if;
            i := i - 96;
        end if;
        return row(to_jsonb((v1 #>> '{}')::inet <<= (s2 || '/' || i)::inet), null::text, c);
    elsif f in ('in_list', 'in_map', 'in_dyn') then
        if jsonb_typeof(v2) = 'object' then
            k1 := permissions._fga_cel_kind(coalesce(n #> '{s,1,1}', '"string"'), 'null');
            if f = 'in_dyn' and jsonb_typeof(v1) <> 'string' then
                return row('false'::jsonb, null::text, c);
            end if;
            return row(to_jsonb(v2 ? (case when jsonb_typeof(v1) = 'string' then v1 #>> '{}' else v1::text end)), null::text, c);
        elsif jsonb_typeof(v2) = 'array' then
            if jsonb_typeof(v1) in ('array', 'object') then
                return row(to_jsonb(exists (select 1 from jsonb_array_elements(v2) e where e = v1)), null::text, c);
            end if;
            return row(to_jsonb(v2 @> jsonb_build_array(v1)), null::text, c);
        end if;
        return row(null::jsonb, 'no such overload'::text, c);
    elsif f in ('idx_list', 'idx_map', 'idx_dyn') then
        if jsonb_typeof(v1) = 'array' then
            if jsonb_typeof(v2) <> 'number' or v2::text::numeric <> trunc(v2::text::numeric) then
                return row(null::jsonb, 'unsupported index type'::text, c);
            end if;
            a1 := v2::text::numeric;
            if a1 < 0 or a1 >= jsonb_array_length(v1) then
                return row(null::jsonb, format('index out of range: %s', a1), c);
            end if;
            return row(v1 -> a1::int, null::text, c);
        elsif jsonb_typeof(v1) = 'object' then
            s1 := case when jsonb_typeof(v2) = 'string' then v2 #>> '{}' else v2::text end;
            if not v1 ? s1 then
                return row(null::jsonb, format('no such key: %s', s1), c);
            end if;
            return row(v1 -> s1, null::text, c);
        end if;
        return row(null::jsonb, 'no such overload'::text, c);
    elsif f in ('size_str', 'size_list', 'size_map', 'size_dyn') then
        return case jsonb_typeof(v1)
            when 'string' then row(to_jsonb(char_length(v1 #>> '{}')), null::text, c)
            when 'array' then row(to_jsonb(jsonb_array_length(v1)), null::text, c)
            when 'object' then row(to_jsonb((select count(*) from jsonb_object_keys(v1))), null::text, c)
            else row(null::jsonb, 'no such overload'::text, c) end;
    elsif f in ('contains', 'starts', 'ends', 'matches') then
        if jsonb_typeof(v1) <> 'string' or jsonb_typeof(v2) <> 'string' then
            return row(null::jsonb, 'no such overload'::text, c);
        end if;
        s1 := v1 #>> '{}';
        s2 := v2 #>> '{}';
        if f = 'contains' then
            return row(to_jsonb(strpos(s1, s2) > 0), null::text, c);
        elsif f = 'starts' then
            return row(to_jsonb(left(s1, char_length(s2)) = s2), null::text, c);
        elsif f = 'ends' then
            return row(to_jsonb(right(s1, char_length(s2)) = s2), null::text, c);
        end if;
        begin
            return row(to_jsonb(s1 ~ s2), null::text, c);
        exception when invalid_regular_expression then
            return row(null::jsonb, format('invalid regular expression ''%s''', s2), c);
        end;
    end if;

    -- arithmetic
    if f like 'add\_%' or f like 'sub\_%' or f like 'mul\_%' or f like 'div\_%' or f like 'mod\_%' or f like 'neg\_%' then
        k1 := left(f, 3);
        k2 := substr(f, 5);
        if k2 = 'dyn' then
            -- dispatch on the run-time kinds
            s1 := permissions._fga_cel_kind(n #> '{s,0}', v1);
            s2 := case when k1 = 'neg' then s1 else permissions._fga_cel_kind(n #> '{s,1}', v2) end;
            if s1 <> s2 then
                return row(null::jsonb, 'no such overload'::text, c);
            end if;
            k2 := case s1 when 'double' then 'dbl' when 'string' then 'str' else s1 end;
            if k2 not in ('int', 'uint', 'dbl') and not (k1 = 'add' and k2 in ('str', 'list')) then
                return row(null::jsonb, 'no such overload'::text, c);
            end if;
        end if;
        if k2 in ('int', 'uint', 'du') then
            a1 := v1::text::numeric;
            a2 := case when k1 = 'neg' then 0 else v2::text::numeric end;
            if k1 in ('div', 'mod') and a2 = 0 then
                return row(null::jsonb, case k1 when 'div' then 'division by zero' else 'modulus by zero' end, c);
            end if;
            return permissions._fga_cel_intres(case k1 when 'add' then a1 + a2 when 'sub' then a1 - a2 when 'mul' then a1 * a2
                                                        when 'div' then trunc(a1 / a2) when 'mod' then mod(a1, a2) else -a1 end,
                                               case k2 when 'du' then 'duration' else k2 end, c);
        elsif k2 = 'dbl' then
            d1 := v1::text::float8;
            d2 := case when k1 = 'neg' then 0 else v2::text::float8 end;
            if k1 = 'div' and d2 = 0 then
                return row(null::jsonb, 'division by zero'::text, c);
            end if;
            begin
                return row(to_jsonb(case k1 when 'add' then d1 + d2 when 'sub' then d1 - d2 when 'mul' then d1 * d2
                                            when 'div' then d1 / d2 else -d1 end), null::text, c);
            exception when numeric_value_out_of_range then
                return row(null::jsonb, 'double overflow'::text, c);
            end;
        elsif k2 = 'str' then
            return row(to_jsonb((v1 #>> '{}') || (v2 #>> '{}')), null::text, c);
        elsif k2 = 'list' then
            return row(v1 || v2, null::text, c);
        elsif f in ('add_ts_du', 'sub_ts_du', 'add_du_ts') then
            if f = 'add_du_ts' then
                an := v1; v1 := v2; v2 := an;
            end if;
            ts := (v1 #>> '{}')::timestamptz
                  + ((case when f = 'sub_ts_du' then -1 else 1 end * trunc(v2::text::numeric / 1000)) || ' microseconds')::interval;
            an := permissions._fga_cel_ts_val(ts);
            if an is null then
                return row(null::jsonb, 'timestamp overflow'::text, c);
            end if;
            return row(an, null::text, c);
        elsif f = 'sub_ts_ts' then
            return permissions._fga_cel_intres((extract(epoch from (v1 #>> '{}')::timestamptz) - extract(epoch from (v2 #>> '{}')::timestamptz)) * 1000000000,
                                               'duration', c);
        end if;
        return row(null::jsonb, 'no such overload'::text, c);
    end if;

    -- conversions
    if f like 'to\_%' then
        k1 := permissions._fga_cel_kind(n #> '{s,0}', v1);
        k2 := substr(f, 4);
        if k1 = k2 then
            return row(v1, null::text, c);
        end if;
        if k2 in ('int', 'uint') then
            if k1 in ('int', 'uint', 'double') then
                a1 := trunc(v1::text::numeric);
            elsif k1 = 'string' then
                if (v1 #>> '{}') !~ (case k2 when 'int' then '^[+-]?[0-9]+$' else '^[0-9]+$' end) then
                    return row(null::jsonb, format('cannot convert string ''%s'' to %s', v1 #>> '{}', k2), c);
                end if;
                a1 := (v1 #>> '{}')::numeric;
            elsif k1 = 'timestamp' then
                a1 := floor(extract(epoch from (v1 #>> '{}')::timestamptz));
            else
                return row(null::jsonb, 'no such overload'::text, c);
            end if;
            if (k2 = 'int' and a1 not between -9223372036854775808 and 9223372036854775807)
               or (k2 = 'uint' and a1 not between 0 and 18446744073709551615) then
                return row(null::jsonb, format('%s overflow', k2), c);
            end if;
            return row(to_jsonb(a1), null::text, c);
        elsif k2 = 'double' then
            if k1 in ('int', 'uint') then
                return row(to_jsonb(v1::text::float8), null::text, c);
            elsif k1 = 'string' then
                if (v1 #>> '{}') !~ '^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$' or not pg_input_is_valid(v1 #>> '{}', 'float8') then
                    return row(null::jsonb, format('cannot convert string ''%s'' to double', v1 #>> '{}'), c);
                end if;
                return row(to_jsonb((v1 #>> '{}')::float8), null::text, c);
            end if;
        elsif k2 = 'string' then
            if k1 in ('int', 'uint') then
                return row(to_jsonb(v1::text), null::text, c);
            elsif k1 = 'double' then
                return row(to_jsonb(permissions._fga_cel_dbl_text(v1::text::float8)), null::text, c);
            elsif k1 = 'bool' then
                return row(to_jsonb(v1::text), null::text, c);
            elsif k1 = 'timestamp' then
                -- RFC 3339 with the fraction's trailing zeros dropped (Go's RFC3339Nano)
                return row(to_jsonb(regexp_replace(regexp_replace(v1 #>> '{}', '0+Z$', 'Z'), '\.Z$', 'Z')), null::text, c);
            elsif k1 = 'duration' then
                return row(to_jsonb(trim_scale(v1::text::numeric / 1000000000)::text || 's'), null::text, c);
            end if;
        elsif k2 = 'bool' then
            if k1 = 'string' then
                s1 := v1 #>> '{}';
                if s1 in ('1', 't', 'T', 'TRUE', 'true', 'True') then return row('true'::jsonb, null::text, c); end if;
                if s1 in ('0', 'f', 'F', 'FALSE', 'false', 'False') then return row('false'::jsonb, null::text, c); end if;
                return row(null::jsonb, format('cannot convert string ''%s'' to bool', s1), c);
            end if;
        elsif k2 in ('timestamp', 'duration', 'ipaddress') then
            if k1 = 'string' then
                x := permissions._fga_cel_convert(to_jsonb(k2), v1);
                if x.e is not null then
                    return row(null::jsonb, x.e, c);
                end if;
                return row(x.v, null::text, c);
            elsif k1 = 'int' and k2 = 'timestamp' then
                if abs(v1::text::numeric) > 253402300800 then
                    return row(null::jsonb, 'timestamp overflow'::text, c);
                end if;
                an := permissions._fga_cel_ts_val(to_timestamp(0) + (v1::text || ' seconds')::interval);
                if an is null then
                    return row(null::jsonb, 'timestamp overflow'::text, c);
                end if;
                return row(an, null::text, c);
            end if;
        end if;
        return row(null::jsonb, 'no such overload'::text, c);
    end if;

    -- getters
    if f = 'ts_get' then
        s1 := coalesce(v2 #>> '{}', 'UTC');
        -- a time zone name, or an offset (+02:00 is two hours east, unlike POSIX)
        if s1 ~ '^[+-][0-9]{2}:[0-9]{2}$' then
            lt := ((v1 #>> '{}')::timestamptz at time zone 'UTC') + (s1 || ':00')::interval;
        else
            begin
                lt := (v1 #>> '{}')::timestamptz at time zone s1;
            exception when invalid_parameter_value then
                return row(null::jsonb, format('invalid time zone ''%s''', s1), c);
            end;
        end if;
        return row(to_jsonb(case n ->> 'g'
            when 'getFullYear' then extract(year from lt)
            when 'getMonth' then extract(month from lt) - 1
            when 'getDate' then extract(day from lt)
            when 'getDayOfMonth' then extract(day from lt) - 1
            when 'getDayOfWeek' then extract(dow from lt)
            when 'getDayOfYear' then extract(doy from lt) - 1
            when 'getHours' then extract(hour from lt)
            when 'getMinutes' then extract(minute from lt)
            when 'getSeconds' then floor(extract(second from lt))
            else floor(extract(milliseconds from lt)) - floor(extract(second from lt)) * 1000 end::int), null::text, c);
    elsif f = 'du_get' then
        a1 := v1::text::numeric;
        return row(to_jsonb(trunc(a1 / case n ->> 'g' when 'getHours' then 3600000000000 when 'getMinutes' then 60000000000
                                                      when 'getSeconds' then 1000000000 else 1000000 end)), null::text, c);
    end if;
    return row(null::jsonb, format('no such overload: %s', f), c);
end;
$$;

drop function permissions._fga_cel_ip(text);
drop function permissions._fga_cel_ts(text);
drop function permissions._fga_cel_du(text);
