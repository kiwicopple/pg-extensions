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

-- ============================================================================
-- 2. The Cedar model (cedar_*): new in 0.1.0
-- ============================================================================
--
-- Tables, functions and privileges, copied from pg_permissions--0.1.0.sql by
-- tools/sync-upgrade.sh: do not edit the region between the markers here.

-- >>> cedar section: begin
-- Everything from this line to the matching end line is the Cedar model.
-- tools/sync-upgrade.sh copies it, unchanged, into the marked region of
-- pg_permissions--0.0.1--0.1.0.sql: edit it here, then run the script.
-- ============================================================================
-- Cedar: cedar_* tables
-- ============================================================================
--
-- Cedar 4.x (research/plan-cedar.md; design research/designs/e-cedar.md),
-- tested against Cedar's own integration tests (test/cedar/). A policy is put
-- in Cedar's JSON policy format (the EST; Cedar text arrives with the parser
-- in a later phase), checked and compiled once: the EST is kept as given in
-- `est`, the conditions as a compact tree in `ast` (e-cedar.md section 2.3)
-- and the scope in columns, so a request matches the scope in SQL and
-- evaluates only the conditions of the policies whose scope matches.
--
-- Entities (uid, attrs, parents, tags) are stored as the app syncs them, one
-- row per entity and one per direct parent. `in` follows the parents
-- recursively (e-cedar.md "Phase 2 measurements": a closure table reads
-- faster only on deep hierarchies, and needs a lock to stay correct under
-- concurrent writes).
--
-- Values are jsonb in one canonical form (e-cedar.md section 3): Bool, Long
-- and String as JSON, an entity as {"__entity": {"type", "id"}}, a set as a
-- sorted array without duplicates, a record as an object. Cedar `==` is jsonb
-- equality. Ids and types are collate "C".

-- Policy templates (phase 4c fills and uses this table; a link is a row of
-- cedar_policies that names its template).
create table permissions.cedar_templates (
    template_id text collate "C" primary key,
    source      text,                  -- the Cedar text as written; null when put as JSON
    est         jsonb not null         -- Cedar's JSON policy format, with slots
);

create table permissions.cedar_policies (
    policy_id      text collate "C" primary key,
    effect         text collate "C" not null check (effect in ('permit', 'forbid')),
    source         text,               -- the Cedar text as written; null when put as policy_json
    est            jsonb not null,     -- Cedar's JSON policy format, as put
    ast            jsonb,              -- the conditions, compiled (_cedar_compile); null: none (true)
    annotations    jsonb not null default '{}',
    -- the scope; a uid is its key (_cedar_key), a type its name
    principal_op   text collate "C" not null check (principal_op in ('All', '==', 'in', 'is')),
    principal_type text collate "C",   -- is
    principal_uid  text collate "C",   -- ==, in, is ... in
    action_op      text collate "C" not null check (action_op in ('All', '==', 'in')),
    action_uids    text[] collate "C", -- ==: one, in: one or more
    resource_op    text collate "C" not null check (resource_op in ('All', '==', 'in', 'is')),
    resource_type  text collate "C",
    resource_uid   text collate "C",
    template_id    text collate "C" references permissions.cedar_templates (template_id),
    slots          jsonb               -- a link's slot values (phase 4c)
);
create index on permissions.cedar_policies (template_id) where template_id is not null;

create table permissions.cedar_entities (
    type  text collate "C" not null,
    id    text collate "C" not null,
    attrs jsonb not null default '{}',
    tags  jsonb not null default '{}',
    primary key (type, id)
);

-- Direct parents only. A parent need not be a stored entity (Cedar allows
-- that; it then has no ancestors of its own).
create table permissions.cedar_entity_parents (
    type        text collate "C" not null,
    id          text collate "C" not null,
    parent_type text collate "C" not null,
    parent_id   text collate "C" not null,
    primary key (type, id, parent_type, parent_id),
    foreign key (type, id) references permissions.cedar_entities (type, id) on delete cascade
);
create index on permissions.cedar_entity_parents (parent_type, parent_id);

-- ----------------------------------------------------------------------------
-- Limits (e-cedar.md section 6), fixed, each well above the corpus maximum
-- ----------------------------------------------------------------------------
-- policy_bytes: the text of a policy, or its JSON; policy_nodes and
-- policy_depth: expression nodes and nesting of one policy; value_depth: the
-- nesting of sets and records in entity data and context; put_entities:
-- entities in one cedar_put_entities call; request_entities: the entities
-- overlay of one request. Cedar's evaluation has no loops, so these static
-- limits bound its cost; there is no runtime counter (section 4.3).
create function permissions._cedar_limits(out policy_bytes int, out policy_nodes int, out policy_depth int,
                                          out value_depth int, out put_entities int, out request_entities int)
language sql immutable
as $$
    select 65536, 4096, 64, 32, 10000, 1000
$$;

-- ----------------------------------------------------------------------------
-- Errors
-- ----------------------------------------------------------------------------
-- API and argument errors raise with DETAIL 'cedar:<code>[ key=''value'' ...]',
-- a MESSAGE that names the values and a HINT (e-cedar.md section 5; every
-- call passes one, test/spec/d/35_error_hints.sql). Evaluation errors never
-- raise out of cedar_is_authorized: they are its `errors`.
create function permissions._cedar_error(p_code text, p_message text, hint text, p_detail text default null)
returns void
language plpgsql
as $$
begin
    raise exception using
        message = p_message,
        errcode = case p_code
            when 'parse_error' then '42601'
            when 'template_in_use' then '2BP01'
            when 'id_in_use' then '23505'
            when 'unsupported' then '0A000'
            when 'null_argument' then '22004'
            when 'limit_exceeded' then '54000'
            else '22023' end,
        detail = 'cedar:' || p_code || coalesce(' ' || p_detail, ''),
        hint = _cedar_error.hint;
end;
$$;

-- An evaluation error. The evaluator returns SQL null for an error, so the
-- hot path never builds a message (e-cedar.md section 4.1); when a policy
-- errs, cedar_is_authorized evaluates it once more with p_why, which raises
-- here with the message (SQLSTATE CE001, caught right there; it never
-- reaches the caller). The message starts with the kind of Cedar's
-- EvaluationError: type_error, entity_does_not_exist, attribute_not_found,
-- tag_not_found, overflow, extension_error.
create function permissions._cedar_eval_fail(p_why boolean, p_message text)
returns jsonb
language plpgsql immutable
as $$
begin
    if p_why then
        raise exception using
            message = p_message,
            errcode = 'CE001',
            detail = 'cedar:evaluation_error',
            hint = 'Internal: cedar_is_authorized catches this and reports it in errors.';
    end if;
    return null;
end;
$$;

-- ----------------------------------------------------------------------------
-- Uids and values
-- ----------------------------------------------------------------------------

-- The lookup key of a uid: Type::"id" without escapes. An entity type never
-- holds a double quote, so the key is unique (the type ends at the first ").
create function permissions._cedar_key(p_type text, p_id text)
returns text
language sql immutable
as $$
    select p_type || '::"' || p_id || '"'
$$;

-- A uid as Cedar text, Type::"id" with Cedar's string escapes (messages).
create function permissions._cedar_uid_text(p_type text, p_id text)
returns text
language sql immutable
as $$
    select p_type || '::"' || coalesce((select string_agg(case when c = '"' then '\"' when c = '\' then '\\'
                                                      when ascii(c) < 32 or ascii(c) = 127 then format('\u{%s}', to_hex(ascii(c)))
                                                      else c end, '' order by o)
                               from regexp_split_to_table(p_id, '') with ordinality s(c, o) where c <> ''), '')
                         || '"'
$$;

-- A valid entity type name: Ident(::Ident)*.
create function permissions._cedar_is_name(p_name text)
returns boolean
language sql immutable
as $$
    select coalesce(p_name ~ '^[_a-zA-Z][_a-zA-Z0-9]*(::[_a-zA-Z][_a-zA-Z0-9]*)*$', false)
$$;

-- A uid in entity JSON or the EST: {"type": T, "id": "x"}, or the same inside
-- {"__entity": ...}. {type, id}, or null when it is not one.
create function permissions._cedar_uid_json(v jsonb, out type text, out id text)
language plpgsql immutable
as $$
begin
    if jsonb_typeof(v) = 'object' and v ? '__entity' and v - '__entity' = '{}' then
        v := v -> '__entity';
    end if;
    if jsonb_typeof(v) = 'object' and jsonb_typeof(v -> 'type') = 'string' and jsonb_typeof(v -> 'id') = 'string'
       and v - 'type' - 'id' = '{}' and permissions._cedar_is_name(v ->> 'type') then
        type := v ->> 'type';
        id := v ->> 'id';
    end if;
end;
$$;

-- A uid argument in Cedar text, Type::"id" (Cedar's string escapes: \n \r \t
-- \\ \0 \' \" \xHH \u{H..}). Raises cedar:invalid_uid.
create function permissions._cedar_uid(p_text text, p_arg text, out type text, out id text)
language plpgsql immutable
as $$
declare
    m text[];
    s text;
    r text := '';
    i int := 1;
    c text;
    h text[];
    bad text;
begin
    -- the common case without escapes: the type ends at the first ::" (a
    -- type has no double quote), the id at the last character
    i := strpos(p_text, '::"');
    if i > 0 and right(p_text, 1) = '"' and strpos(p_text, '\') = 0 and char_length(p_text) > i + 2
       and strpos(substr(p_text, i + 3, char_length(p_text) - i - 3), '"') = 0
       and permissions._cedar_is_name(left(p_text, i - 1)) then
        type := left(p_text, i - 1);
        id := substr(p_text, i + 3, char_length(p_text) - i - 3);
        return;
    end if;
    i := 1;
    m := regexp_match(p_text, '^\s*([_a-zA-Z][_a-zA-Z0-9]*(?:::[_a-zA-Z][_a-zA-Z0-9]*)*)::"((?:[^"\\]|\\.)*)"\s*$');
    if m is not null and m[2] !~ '\\' then
        type := m[1];
        id := m[2];
        return;
    end if;
    if m is null then
        bad := 'it is not Type::"id"';
    else
        s := m[2];
        while i <= char_length(s) loop
            c := substr(s, i, 1);
            if c <> '\' then
                r := r || c;
                i := i + 1;
                continue;
            end if;
            c := substr(s, i + 1, 1);
            if c in ('n', 'r', 't', '\', '"', '''') then
                r := r || case c when 'n' then e'\n' when 'r' then e'\r' when 't' then e'\t' else c end;
                i := i + 2;
            elsif c = 'x' and substr(s, i + 2, 2) ~ '^[0-7][0-9a-fA-F]$' and substr(s, i + 2, 2) <> '00' then
                r := r || chr(('x' || lpad(substr(s, i + 2, 2), 8, '0'))::bit(32)::int);
                i := i + 4;
            elsif c = 'u' then
                h := regexp_match(substr(s, i + 2), '^\{([0-9a-fA-F]{1,6})\}');
                if h is null or ('x' || lpad(h[1], 8, '0'))::bit(32)::int not between 1 and 1114111
                   or ('x' || lpad(h[1], 8, '0'))::bit(32)::int between 55296 and 57343 then
                    bad := format('the escape \u%s is not a Unicode scalar value (U+0000 is not supported)', coalesce(substr(s, i + 2, 8), ''));
                    exit;
                end if;
                r := r || chr(('x' || lpad(h[1], 8, '0'))::bit(32)::int);
                i := i + 3 + char_length(h[1]) + 1;
            else
                bad := format('the escape \%s is not valid in a Cedar string (U+0000 is not supported)', c);
                exit;
            end if;
        end loop;
        if bad is null then
            type := m[1];
            id := r;
            return;
        end if;
    end if;
    perform permissions._cedar_error('invalid_uid', format('invalid entity uid for %s: %s: %s', p_arg, p_text, bad),
        hint => format('Write a uid as Cedar text, a type and a quoted id: %s => ''User::"alice"'' (a namespaced type: ''App::User::"alice"'').', p_arg),
        p_detail => format('value=%L', p_text));
end;
$$;

-- The Cedar type of an internal value, for messages.
create function permissions._cedar_type_of(v jsonb)
returns text
language sql immutable
as $$
    select case jsonb_typeof(v)
        when 'boolean' then 'Bool' when 'number' then 'Long' when 'string' then 'String' when 'array' then 'Set'
        when 'object' then case when v ? '__entity' then 'Entity'
                                when v ? '__extn' then coalesce(v -> '__extn' ->> 'fn', 'extension')
                                else 'Record' end
        else 'no value' end
$$;

-- The extension functions and methods of Cedar 4.x, and the extension type
-- each belongs to. None is implemented yet: the phases of research/plan-cedar.md
-- add decimal and ipaddr (4a), datetime and duration (4b). The compiler
-- rejects them until then (cedar:unsupported), and an unknown name gets the
-- nearest of these (cedar:invalid_policy).
create function permissions._cedar_extensions()
returns jsonb
language sql immutable
as $$
    select '{"decimal": "decimal", "lessThan": "decimal", "lessThanOrEqual": "decimal",
             "greaterThan": "decimal", "greaterThanOrEqual": "decimal",
             "ip": "ipaddr", "isIpv4": "ipaddr", "isIpv6": "ipaddr", "isLoopback": "ipaddr",
             "isMulticast": "ipaddr", "isInRange": "ipaddr",
             "datetime": "datetime", "offset": "datetime", "durationSince": "datetime",
             "toDate": "datetime", "toTime": "datetime",
             "duration": "duration", "toDays": "duration", "toHours": "duration", "toMinutes": "duration",
             "toSeconds": "duration", "toMilliseconds": "duration"}'::jsonb
$$;

-- A set in canonical form: sorted by jsonb order, without duplicates.
create function permissions._cedar_set(p_items jsonb)
returns jsonb
language sql immutable
as $$
    select coalesce(jsonb_agg(x order by x), '[]') from (select distinct x from jsonb_array_elements(p_items) x) d
$$;

-- A Cedar JSON value (entity attrs and tags, context, an EST Value) in the
-- internal form, or an error: code is invalid, unsupported or limit, and err
-- says what and where (p_path, a JSON path).
create function permissions._cedar_value_in(v jsonb, p_path text, p_depth int,
                                            out val jsonb, out code text, out err text)
language plpgsql immutable
as $$
declare
    t text := jsonb_typeof(v);
    u record;
    x record;
    kv record;
    acc jsonb;
    i int;
    fn text;
begin
    if t in ('boolean', 'string') then
        val := v;
        return;
    elsif t = 'number' then
        if scale(v::text::numeric) > 0 or v::text::numeric not between -9223372036854775808 and 9223372036854775807 then
            code := 'invalid';
            err := format('%s: %s is not a Long (an integer from -9223372036854775808 to 9223372036854775807)', p_path, v);
            return;
        end if;
        val := v;
        return;
    elsif t = 'null' then
        code := 'invalid';
        err := format('%s: null is not a Cedar value', p_path);
        return;
    end if;
    if p_depth > (permissions._cedar_limits()).value_depth then
        code := 'limit';
        err := format('%s: sets and records nest deeper than %s levels', p_path, (permissions._cedar_limits()).value_depth);
        return;
    end if;
    if t = 'array' then
        acc := '[]';
        for i in 0 .. jsonb_array_length(v) - 1 loop
            if jsonb_typeof(v -> i) in ('boolean', 'string') then
                acc := acc || jsonb_build_array(v -> i);
                continue;
            end if;
            select * into x from permissions._cedar_value_in(v -> i, p_path || '[' || i || ']', p_depth + 1) r;
            if x.code is not null then
                code := x.code;
                err := x.err;
                return;
            end if;
            acc := acc || jsonb_build_array(x.val);
        end loop;
        val := permissions._cedar_set(acc);
        return;
    end if;
    -- an object: an entity reference, an extension value or a record
    if v ? '__entity' then
        select * into u from permissions._cedar_uid_json(v);
        if u.type is null then
            code := 'invalid';
            err := format('%s: an entity reference is {"__entity": {"type": "<Type>", "id": "<id>"}} with a valid type name, got %s', p_path, v);
            return;
        end if;
        val := jsonb_build_object('__entity', jsonb_build_object('type', u.type, 'id', u.id));
        return;
    elsif v ? '__extn' then
        if (select count(*) from jsonb_object_keys(v)) <> 1 or jsonb_typeof(v -> '__extn') <> 'object'
           or jsonb_typeof(v -> '__extn' -> 'fn') <> 'string' then
            code := 'invalid';
            err := format('%s: an extension value is {"__extn": {"fn": "<function>", "arg": "<text>"}}, got %s', p_path, v);
            return;
        end if;
        fn := v -> '__extn' ->> 'fn';
        if not permissions._cedar_extensions() ? fn then
            code := 'invalid';
            err := format('%s: unknown extension function ''%s''', p_path, fn);
            return;
        end if;
        -- Phases 4a and 4b convert {"fn", "arg"} to the internal {"fn", "v"}.
        code := 'unsupported';
        err := format('%s: the %s extension type is not supported yet (extension value %s)',
                      p_path, permissions._cedar_extensions() ->> fn, v);
        return;
    end if;
    -- a record: Bools and Strings stay as they are; everything else is
    -- checked or converted, and the record is rebuilt only if a value changed
    acc := v;
    for kv in select * from jsonb_each(v) e where jsonb_typeof(e.value) not in ('boolean', 'string') loop
        select * into x from permissions._cedar_value_in(kv.value, p_path || '.' || kv.key, p_depth + 1) r;
        if x.code is not null then
            code := x.code;
            err := x.err;
            return;
        end if;
        if x.val <> kv.value then
            acc := acc || jsonb_build_object(kv.key, x.val);
        end if;
    end loop;
    val := acc;
end;
$$;

-- An internal value in Cedar's JSON form (cedar_read_entities). Every value
-- of phase 2 is already in that form; extension values (phase 4) go back to
-- {"__extn": {"fn", "arg"}} here.
create function permissions._cedar_value_out(v jsonb)
returns jsonb
language sql immutable
as $$
    select v
$$;

-- One entity of Cedar entity JSON ({"uid", "attrs", "parents", "tags"}),
-- checked and in internal form, or an error (code: invalid, unsupported or
-- limit; err says what).
create function permissions._cedar_entity_in(e jsonb, out t text, out i text, out attrs jsonb, out tags jsonb,
                                             out parents jsonb, out code text, out err text)
language plpgsql immutable
as $$
declare
    u record;
    x record;
    pv jsonb;
    acc jsonb[];
begin
    code := 'invalid';
    if jsonb_typeof(e) <> 'object' then
        err := format('an entity must be a JSON object, got a JSON %s', jsonb_typeof(e));
        return;
    end if;
    if e - '{uid,attrs,parents,tags}'::text[] <> '{}' then
        err := format('unknown keys %s (an entity has uid, attrs, parents and tags)',
                      (select string_agg(k, ', ' order by k) from jsonb_object_keys(e - '{uid,attrs,parents,tags}'::text[]) k));
        return;
    end if;
    select * into u from permissions._cedar_uid_json(e -> 'uid');
    if u.type is null then
        err := format('uid must be {"type": "<Type>", "id": "<id>"} with a valid type name, got %s',
                      coalesce((e -> 'uid')::text, 'nothing'));
        return;
    end if;
    if jsonb_typeof(coalesce(e -> 'attrs', '{}')) not in ('object', 'null') then
        err := format('%s: attrs must be a JSON object, got a JSON %s', permissions._cedar_uid_text(u.type, u.id), jsonb_typeof(e -> 'attrs'));
        return;
    end if;
    if jsonb_typeof(coalesce(e -> 'tags', '{}')) not in ('object', 'null') then
        err := format('%s: tags must be a JSON object, got a JSON %s', permissions._cedar_uid_text(u.type, u.id), jsonb_typeof(e -> 'tags'));
        return;
    end if;
    if jsonb_typeof(coalesce(e -> 'parents', '[]')) not in ('array', 'null') then
        err := format('%s: parents must be a JSON array of uids, got a JSON %s', permissions._cedar_uid_text(u.type, u.id), jsonb_typeof(e -> 'parents'));
        return;
    end if;
    if jsonb_typeof(e -> 'parents') = 'array' then
        for pv in select p from jsonb_array_elements(e -> 'parents') p loop
            select * into x from permissions._cedar_uid_json(pv);
            if x.type is null then
                err := format('%s: a parent is not a uid {"type": "<Type>", "id": "<id>"}: %s', permissions._cedar_uid_text(u.type, u.id), pv);
                return;
            end if;
            acc := acc || jsonb_build_array(x.type, x.id);
        end loop;
    end if;
    attrs := '{}';
    tags := '{}';
    if not (e -> 'attrs' is null or e -> 'attrs' = 'null' or e -> 'attrs' = '{}') then
        select * into x from permissions._cedar_value_in(e -> 'attrs', 'attrs', 1) r;
        attrs := x.val;
        code := x.code;
        err := x.err;
    end if;
    if err is null and not (e -> 'tags' is null or e -> 'tags' = 'null' or e -> 'tags' = '{}') then
        select * into x from permissions._cedar_value_in(e -> 'tags', 'tags', 1) r;
        tags := x.val;
        code := x.code;
        err := x.err;
    end if;
    if err is not null then
        err := format('%s: %s', permissions._cedar_uid_text(u.type, u.id), err);
        return;
    end if;
    code := null;
    t := u.type;
    i := u.id;
    parents := case when cardinality(acc) > 1 then permissions._cedar_set(to_jsonb(acc)) else coalesce(to_jsonb(acc), '[]') end;
end;
$$;

-- Cedar entity JSON (an array of entities), checked and in internal form:
-- [{"t", "i", "attrs", "tags", "parents": [[type, id], ...]}]. p_arg names
-- the argument for the messages and p_max is the limit on the number of
-- entities. Raises cedar:invalid_entity, cedar:unsupported or
-- cedar:limit_exceeded at the first bad entity.
create function permissions._cedar_entities_in(p_entities jsonb, p_arg text, p_max int)
returns jsonb
language plpgsql stable
as $$
declare
    r jsonb;
    res jsonb;
begin
    if jsonb_typeof(p_entities) <> 'array' then
        r := jsonb_build_object('n', 0, 'code', 'invalid',
                                'err', format('%s must be a JSON array of entities, got a JSON %s', p_arg, jsonb_typeof(p_entities)));
    elsif jsonb_array_length(p_entities) > p_max then
        r := jsonb_build_object('n', 0, 'code', 'limit',
                                'err', format('too many entities: %s (the limit is %s)', jsonb_array_length(p_entities), p_max));
    else
        select jsonb_agg(jsonb_build_object('t', x.t, 'i', x.i, 'attrs', x.attrs, 'tags', x.tags, 'parents', x.parents)
                         order by x.n) filter (where x.code is null),
               jsonb_agg(jsonb_build_object('n', x.n, 'code', x.code, 'err', x.err) order by x.n)
                 filter (where x.code is not null) -> 0
        into res, r
        from (select e.n - 1 as n, v.t, v.i, v.attrs, v.tags, v.parents,
                     case when v.code is null and row_number() over (partition by v.t, v.i order by e.n) > 1
                          then 'invalid' else v.code end as code,
                     case when v.code is null and row_number() over (partition by v.t, v.i order by e.n) > 1
                          then format('duplicate entity %s', permissions._cedar_uid_text(v.t, v.i)) else v.err end as err
              from jsonb_array_elements(p_entities) with ordinality e(v, n)
              cross join lateral permissions._cedar_entity_in(e.v) v) x;
        if r is null then
            return coalesce(res, '[]');
        end if;
    end if;
    perform permissions._cedar_error(case r ->> 'code' when 'limit' then 'limit_exceeded' when 'unsupported' then 'unsupported' else 'invalid_entity' end,
        format('invalid entity at index %s of %s: %s', r ->> 'n', p_arg, r ->> 'err'),
        hint => case r ->> 'code'
            when 'limit' then format('An argument holds at most %s entities, and sets and records in attributes and tags nest at most %s levels.',
                                     p_max, (permissions._cedar_limits()).value_depth)
            when 'unsupported' then 'Extension values (decimal, ipaddr, datetime, duration) arrive in a later phase of research/plan-cedar.md; store the value as a String for now.'
            else 'Each entity is {"uid": {"type": "User", "id": "alice"}, "attrs": {...}, "parents": [{"type": "Group", "id": "staff"}], "tags": {...}}; write an entity reference in an attribute as {"__entity": {"type": "User", "id": "alice"}}.' end,
        p_detail => format('index=%s', r ->> 'n'));
end;
$$;

-- ----------------------------------------------------------------------------
-- Compiler: the EST (Cedar's JSON policy format) to the ast
-- ----------------------------------------------------------------------------
-- The ast (e-cedar.md section 2.3). Every node has its kind in "k":
--
--   {"k":"lit","v":V}                  a value, internal form (sets and records of constants folded)
--   {"k":"var","n":"principal"}        principal, action, resource, context
--   {"k":"and"|"or","a":x,"b":y}
--   {"k":"if","c":c,"t":t,"e":e}
--   {"k":"not"|"neg"|"isEmpty","a":x}
--   {"k":"eq"|"ne"|"lt"|"le"|"gt"|"ge"|"add"|"sub"|"mul"|"in"|"contains"|"containsAll"|"containsAny"
--        |"hasTag"|"getTag","a":x,"b":y}
--   {"k":"get"|"has","a":x,"f":"name"}  `e has a.b` is has(e,a) && has(e.a,b), as in Cedar
--   {"k":"is","a":x,"t":"Type"}        with "in":y for `is ... in`
--   {"k":"like","a":x,"p":"<SQL LIKE pattern, \ escapes>"}
--   {"k":"set","a":[x,...]}, {"k":"rec","a":{"key":x,...}}
--   {"k":"call","f":"name","a":[x,...]}  an extension function or method (phase 4)
--
-- The conditions of a policy are one chain of "and" in source order, with
-- `unless c` as not(c). The scope is not in the ast: it goes to the scope
-- columns of cedar_policies.

-- One EST expression: {"ast", "n" (nodes)} or {"code", "err", "path"} where
-- code is invalid_policy, unsupported or limit_exceeded.
create function permissions._cedar_compile(e jsonb, p_path text, p_depth int)
returns jsonb
language plpgsql immutable
as $$
declare
    op text;
    a jsonb;
    x jsonb;
    y jsonb;
    z jsonb;
    v record;
    kv record;
    i int;
    n int := 1;
    lits boolean := true;
    acc jsonb;
    pat text := '';
    attrs jsonb;
    bin constant jsonb := '{"==": "eq", "!=": "ne", "<": "lt", "<=": "le", ">": "gt", ">=": "ge",
                            "+": "add", "-": "sub", "*": "mul", "in": "in", "&&": "and", "||": "or",
                            "contains": "contains", "containsAll": "containsAll", "containsAny": "containsAny",
                            "hasTag": "hasTag", "getTag": "getTag"}';
    lim record := permissions._cedar_limits();
begin
    if p_depth > lim.policy_depth then
        return jsonb_build_object('code', 'limit_exceeded', 'path', p_path,
                                  'err', format('expressions nest deeper than %s levels', lim.policy_depth));
    end if;
    if jsonb_typeof(e) <> 'object' or (select count(*) from jsonb_object_keys(e)) <> 1 then
        return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                  'err', format('an expression is a JSON object with one key (the operator), got %s', left(e::text, 200)));
    end if;
    select k into op from jsonb_object_keys(e) k;
    a := e -> op;
    p_path := p_path || '.' || case when op ~ '^[A-Za-z_][A-Za-z0-9_]*$' then op else '"' || op || '"' end;

    -- the arguments' shape
    if op in ('!', 'neg', 'isEmpty') then
        if jsonb_typeof(a) <> 'object' or (select array_agg(k order by k) from jsonb_object_keys(a) k) <> '{arg}' then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path, 'err', format('%s takes {"arg": <expression>}', op));
        end if;
    elsif bin ? op then
        if jsonb_typeof(a) <> 'object' or (select array_agg(k order by k) from jsonb_object_keys(a) k) <> '{left,right}' then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                      'err', format('%s takes {"left": <expression>, "right": <expression>}', op));
        end if;
    elsif op in ('.', 'has') then
        if jsonb_typeof(a) <> 'object' or (select array_agg(k order by k) from jsonb_object_keys(a) k) <> '{attr,left}'
           or not (jsonb_typeof(a -> 'attr') = 'string'
                   or (op = 'has' and jsonb_typeof(a -> 'attr') = 'array' and jsonb_array_length(a -> 'attr') > 0
                       and not exists (select 1 from jsonb_array_elements(a -> 'attr') t where jsonb_typeof(t) <> 'string'))) then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                      'err', format('%s takes {"left": <expression>, "attr": "<name>"}', op));
        end if;
    elsif op = 'is' then
        if jsonb_typeof(a) <> 'object'
           or exists (select 1 from jsonb_object_keys(a) k where k not in ('left', 'entity_type', 'in'))
           or not (a ? 'left') or not permissions._cedar_is_name(a ->> 'entity_type') then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                      'err', 'is takes {"left": <expression>, "entity_type": "<Type>"} and an optional "in": <expression>');
        end if;
    elsif op = 'like' then
        if jsonb_typeof(a) <> 'object' or (select array_agg(k order by k) from jsonb_object_keys(a) k) <> '{left,pattern}'
           or jsonb_typeof(a -> 'pattern') <> 'array'
           or exists (select 1 from jsonb_array_elements(a -> 'pattern') t
                      where t <> '"Wildcard"' and not (jsonb_typeof(t) = 'object' and jsonb_typeof(t -> 'Literal') = 'string'
                                                       and (select count(*) from jsonb_object_keys(t)) = 1)) then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                      'err', 'like takes {"left": <expression>, "pattern": ["Wildcard", {"Literal": "<text>"}, ...]}');
        end if;
    elsif op = 'if-then-else' then
        if jsonb_typeof(a) <> 'object' or (select array_agg(k order by k) from jsonb_object_keys(a) k) <> '{else,if,then}' then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                      'err', 'if-then-else takes {"if": <expression>, "then": <expression>, "else": <expression>}');
        end if;
    end if;

    if op = 'Value' then
        select * into v from permissions._cedar_value_in(a, 'value', 1) r;
        if v.code is not null then
            return jsonb_build_object('code', case v.code when 'limit' then 'limit_exceeded' when 'unsupported' then 'unsupported' else 'invalid_policy' end,
                                      'path', p_path, 'err', v.err);
        end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'lit', 'v', v.val), 'n', 1);
    elsif op = 'Var' then
        if jsonb_typeof(a) <> 'string' or a #>> '{}' not in ('principal', 'action', 'resource', 'context') then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                      'err', format('Var is "principal", "action", "resource" or "context", got %s', a));
        end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'var', 'n', a #>> '{}'), 'n', 1);
    elsif op = 'Slot' then
        -- Templates (phase 4c) fill the slots at link time.
        return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                  'err', format('a static policy has no slots, got %s', a));
    elsif op = 'Unknown' then
        return jsonb_build_object('code', 'unsupported', 'path', p_path,
                                  'err', 'Unknown is for partial evaluation, which is not supported');
    elsif op in ('!', 'neg', 'isEmpty') then
        x := permissions._cedar_compile(a -> 'arg', p_path, p_depth + 1);
        if x ? 'code' then return x; end if;
        return jsonb_build_object('ast', jsonb_build_object('k', case op when '!' then 'not' else op end, 'a', x -> 'ast'),
                                  'n', 1 + (x ->> 'n')::int);
    elsif bin ? op then
        x := permissions._cedar_compile(a -> 'left', p_path, p_depth + 1);
        if x ? 'code' then return x; end if;
        y := permissions._cedar_compile(a -> 'right', p_path, p_depth + 1);
        if y ? 'code' then return y; end if;
        return jsonb_build_object('ast', jsonb_build_object('k', bin ->> op, 'a', x -> 'ast', 'b', y -> 'ast'),
                                  'n', 1 + (x ->> 'n')::int + (y ->> 'n')::int);
    elsif op = '.' then
        x := permissions._cedar_compile(a -> 'left', p_path, p_depth + 1);
        if x ? 'code' then return x; end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'get', 'a', x -> 'ast', 'f', a ->> 'attr'),
                                  'n', 1 + (x ->> 'n')::int);
    elsif op = 'has' then
        x := permissions._cedar_compile(a -> 'left', p_path, p_depth + 1);
        if x ? 'code' then return x; end if;
        attrs := case when jsonb_typeof(a -> 'attr') = 'string' then jsonb_build_array(a -> 'attr') else a -> 'attr' end;
        -- e has a.b.c: e has a && e.a has b && e.a.b has c
        y := x -> 'ast';                                  -- e, then e.a, then e.a.b
        z := null;                                        -- the chain so far
        for i in 0 .. jsonb_array_length(attrs) - 1 loop
            acc := jsonb_build_object('k', 'has', 'a', y, 'f', attrs ->> i);
            z := case when z is null then acc else jsonb_build_object('k', 'and', 'a', z, 'b', acc) end;
            y := jsonb_build_object('k', 'get', 'a', y, 'f', attrs ->> i);
        end loop;
        return jsonb_build_object('ast', z, 'n', jsonb_array_length(attrs) + (x ->> 'n')::int);
    elsif op = 'is' then
        x := permissions._cedar_compile(a -> 'left', p_path, p_depth + 1);
        if x ? 'code' then return x; end if;
        acc := jsonb_build_object('k', 'is', 'a', x -> 'ast', 't', a ->> 'entity_type');
        n := 1 + (x ->> 'n')::int;
        if a ? 'in' then
            y := permissions._cedar_compile(a -> 'in', p_path, p_depth + 1);
            if y ? 'code' then return y; end if;
            acc := acc || jsonb_build_object('in', y -> 'ast');
            n := n + (y ->> 'n')::int;
        end if;
        return jsonb_build_object('ast', acc, 'n', n);
    elsif op = 'like' then
        x := permissions._cedar_compile(a -> 'left', p_path, p_depth + 1);
        if x ? 'code' then return x; end if;
        for z in select t from jsonb_array_elements(a -> 'pattern') t loop
            pat := pat || case when z = '"Wildcard"' then '%'
                               else regexp_replace(z ->> 'Literal', '([\\%_])', '\\\1', 'g') end;
        end loop;
        return jsonb_build_object('ast', jsonb_build_object('k', 'like', 'a', x -> 'ast', 'p', pat),
                                  'n', 1 + (x ->> 'n')::int);
    elsif op = 'if-then-else' then
        x := permissions._cedar_compile(a -> 'if', p_path, p_depth + 1);
        if x ? 'code' then return x; end if;
        y := permissions._cedar_compile(a -> 'then', p_path, p_depth + 1);
        if y ? 'code' then return y; end if;
        z := permissions._cedar_compile(a -> 'else', p_path, p_depth + 1);
        if z ? 'code' then return z; end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'if', 'c', x -> 'ast', 't', y -> 'ast', 'e', z -> 'ast'),
                                  'n', 1 + (x ->> 'n')::int + (y ->> 'n')::int + (z ->> 'n')::int);
    elsif op = 'Set' then
        if jsonb_typeof(a) <> 'array' then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path, 'err', 'Set takes an array of expressions');
        end if;
        acc := '[]';
        for i in 0 .. jsonb_array_length(a) - 1 loop
            x := permissions._cedar_compile(a -> i, p_path || '[' || i || ']', p_depth + 1);
            if x ? 'code' then return x; end if;
            acc := acc || jsonb_build_array(x -> 'ast');
            n := n + (x ->> 'n')::int;
            lits := lits and x -> 'ast' ->> 'k' = 'lit';
        end loop;
        if lits then
            return jsonb_build_object('ast', jsonb_build_object('k', 'lit', 'v',
                                          permissions._cedar_set(coalesce((select jsonb_agg(t -> 'v') from jsonb_array_elements(acc) t), '[]'))),
                                      'n', n);
        end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'set', 'a', acc), 'n', n);
    elsif op = 'Record' then
        if jsonb_typeof(a) <> 'object' then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path, 'err', 'Record takes an object of expressions');
        end if;
        if a ? '__entity' or a ? '__extn' then
            return jsonb_build_object('code', 'unsupported', 'path', p_path,
                                      'err', 'a record with the key __entity or __extn (it would read as an entity or an extension value)');
        end if;
        acc := '{}';
        for kv in select * from jsonb_each(a) loop
            x := permissions._cedar_compile(kv.value, p_path || '.' || kv.key, p_depth + 1);
            if x ? 'code' then return x; end if;
            acc := acc || jsonb_build_object(kv.key, x -> 'ast');
            n := n + (x ->> 'n')::int;
            lits := lits and x -> 'ast' ->> 'k' = 'lit';
        end loop;
        if lits then
            return jsonb_build_object('ast', jsonb_build_object('k', 'lit', 'v',
                                          coalesce((select jsonb_object_agg(t.key, t.value -> 'v') from jsonb_each(acc) t), '{}')),
                                      'n', n);
        end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'rec', 'a', acc), 'n', n);
    elsif jsonb_typeof(a) = 'array' then
        -- an extension function or method: {"name": [receiver, args...]}
        if permissions._cedar_extensions() ? op then
            return jsonb_build_object('code', 'unsupported', 'path', p_path,
                                      'err', format('the %s extension (function %s) is not supported yet', permissions._cedar_extensions() ->> op, op),
                                      'feature', permissions._cedar_extensions() ->> op);
        end if;
        return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                  'err', format('unknown extension function ''%s''', op),
                                  'hint', permissions._did_you_mean(op, array(select jsonb_object_keys(permissions._cedar_extensions())),
                                                                    'Extension functions'));
    end if;
    return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                              'err', format('unknown expression kind ''%s''', op),
                              'hint', permissions._did_you_mean(op,
                                  '{Value,Var,Slot,!,neg,==,!=,in,<,<=,>,>=,&&,||,+,-,*,contains,containsAll,containsAny,isEmpty,hasTag,getTag,.,has,is,like,if-then-else,Set,Record}',
                                  'Expression kinds'));
end;
$$;

-- One scope constraint of the EST ({"op": ...}): {"op", "type", "uid"} for the
-- scope columns, or {"code", "err", "path"}. p_var is principal, action or
-- resource.
create function permissions._cedar_compile_scope(s jsonb, p_var text)
returns jsonb
language plpgsql immutable
as $$
declare
    op text := s ->> 'op';
    u record;
    keys text[];
    e jsonb;
    path text := '$.' || p_var;
    act boolean := p_var = 'action';
    form text := case when p_var = 'action'
                      then '{"op": "All"}, {"op": "==", "entity": E}, {"op": "in", "entity": E} or {"op": "in", "entities": [E, ...]}'
                      else '{"op": "All"}, {"op": "==", "entity": E}, {"op": "in", "entity": E} or {"op": "is", "entity_type": "T"} with an optional "in": {"entity": E}' end
                 || ', where E is {"type": "<Type>", "id": "<id>"}';
begin
    if jsonb_typeof(s) <> 'object' or op is null then
        return jsonb_build_object('code', 'invalid_policy', 'path', path, 'err', format('the %s scope is %s', p_var, form));
    end if;
    if s ? 'slot' or (jsonb_typeof(s -> 'in') = 'object' and s -> 'in' ? 'slot') then
        return jsonb_build_object('code', 'invalid_policy', 'path', path,
                                  'err', format('a static policy has no slots, and the %s scope has %s', p_var, coalesce(s -> 'slot', s -> 'in' -> 'slot')));
    end if;
    if op = 'All' and (select count(*) from jsonb_object_keys(s)) = 1 then
        return jsonb_build_object('op', 'All');
    elsif op in ('==', 'in') and s ? 'entity' and (select count(*) from jsonb_object_keys(s)) = 2 then
        select * into u from permissions._cedar_uid_json(s -> 'entity');
        if u.type is not null and (not act or u.type ~ '(^|::)Action$') then
            return jsonb_build_object('op', op, 'uids', jsonb_build_array(permissions._cedar_key(u.type, u.id)),
                                      'uid', permissions._cedar_key(u.type, u.id));
        end if;
        if u.type is not null then
            return jsonb_build_object('code', 'invalid_policy', 'path', path || '.entity',
                                      'err', format('the action scope names %s, which is not an action (an action''s type is Action or Namespace::Action)',
                                                    permissions._cedar_uid_text(u.type, u.id)));
        end if;
    elsif act and op = 'in' and jsonb_typeof(s -> 'entities') = 'array' and (select count(*) from jsonb_object_keys(s)) = 2 then
        for e in select x from jsonb_array_elements(s -> 'entities') x loop
            select * into u from permissions._cedar_uid_json(e);
            if u.type is null or u.type !~ '(^|::)Action$' then
                return jsonb_build_object('code', 'invalid_policy', 'path', path || '.entities',
                                          'err', format('the action scope lists %s, which is not an action uid (type Action or Namespace::Action)', e));
            end if;
            keys := keys || permissions._cedar_key(u.type, u.id);
        end loop;
        return jsonb_build_object('op', 'in', 'uids', coalesce(to_jsonb(keys), '[]'));
    elsif not act and op = 'is' and permissions._cedar_is_name(s ->> 'entity_type')
          and not exists (select 1 from jsonb_object_keys(s) k where k not in ('op', 'entity_type', 'in')) then
        if not s ? 'in' then
            return jsonb_build_object('op', 'is', 'type', s ->> 'entity_type');
        end if;
        if jsonb_typeof(s -> 'in') = 'object' and (select count(*) from jsonb_object_keys(s -> 'in')) = 1 then
            select * into u from permissions._cedar_uid_json(s -> 'in' -> 'entity');
            if u.type is not null then
                return jsonb_build_object('op', 'is', 'type', s ->> 'entity_type', 'uid', permissions._cedar_key(u.type, u.id));
            end if;
        end if;
    end if;
    return jsonb_build_object('code', 'invalid_policy', 'path', path,
                              'err', format('the %s scope is %s; got %s', p_var, form, left(s::text, 200)));
end;
$$;

-- A policy in the EST: its columns for cedar_policies ({"effect", "ast",
-- "annotations", "principal", "action", "resource"}, the scopes as
-- _cedar_compile_scope returns them). Raises cedar:invalid_policy,
-- cedar:unsupported or cedar:limit_exceeded.
create function permissions._cedar_compile_policy(p_est jsonb, p_id text)
returns jsonb
language plpgsql immutable
as $$
declare
    lim record := permissions._cedar_limits();
    r jsonb;
    c jsonb;
    x jsonb;
    ast jsonb;
    n int := 0;
    i int;
    s text;
    res jsonb := '{}';
begin
    if octet_length(p_est::text) > lim.policy_bytes then
        r := jsonb_build_object('code', 'limit_exceeded', 'path', '$',
                                'err', format('the policy is %s bytes of JSON (the limit is %s)', octet_length(p_est::text), lim.policy_bytes),
                                'limit', 'policy_bytes');
    elsif jsonb_typeof(p_est) <> 'object' then
        r := jsonb_build_object('code', 'invalid_policy', 'path', '$', 'err', format('a policy is a JSON object, got a JSON %s', jsonb_typeof(p_est)));
    else
        s := (select string_agg(k, ', ' order by k) from jsonb_object_keys(p_est) k
              where k not in ('effect', 'principal', 'action', 'resource', 'conditions', 'annotations'));
        if s is not null then
            r := jsonb_build_object('code', 'invalid_policy', 'path', '$',
                                    'err', format('unknown keys %s (a policy has effect, principal, action, resource, conditions and annotations)', s));
        elsif p_est ->> 'effect' is null or p_est ->> 'effect' not in ('permit', 'forbid') or jsonb_typeof(p_est -> 'effect') <> 'string' then
            r := jsonb_build_object('code', 'invalid_policy', 'path', '$.effect',
                                    'err', format('effect is "permit" or "forbid", got %s', coalesce((p_est -> 'effect')::text, 'nothing')));
        elsif p_est ? 'annotations' and jsonb_typeof(p_est -> 'annotations') <> 'object'
              or exists (select 1 from jsonb_each(case when jsonb_typeof(p_est -> 'annotations') = 'object' then p_est -> 'annotations' end) a
                         where jsonb_typeof(a.value) not in ('string', 'null') or a.key !~ '^[_a-zA-Z][_a-zA-Z0-9]*$') then
            r := jsonb_build_object('code', 'invalid_policy', 'path', '$.annotations',
                                    'err', format('annotations are an object of identifiers to strings, got %s', left((p_est -> 'annotations')::text, 200)));
        elsif not (coalesce(jsonb_typeof(p_est -> 'conditions'), 'array') = 'array'
                   and not exists (select 1 from jsonb_array_elements(coalesce(p_est -> 'conditions', '[]')) w(cl)
                                   where jsonb_typeof(w.cl) <> 'object' or (select array_agg(k order by k) from jsonb_object_keys(w.cl) k) <> '{body,kind}'
                                      or w.cl ->> 'kind' not in ('when', 'unless') or jsonb_typeof(w.cl -> 'kind') <> 'string')) then
            r := jsonb_build_object('code', 'invalid_policy', 'path', '$.conditions',
                                    'err', 'conditions are an array of {"kind": "when" or "unless", "body": <expression>}');
        else
            res := jsonb_build_object('effect', p_est ->> 'effect',
                                      'annotations', coalesce((select jsonb_object_agg(a.key, coalesce(a.value #>> '{}', ''))
                                                               from jsonb_each(p_est -> 'annotations') a), '{}'));
            foreach s in array array['principal', 'action', 'resource'] loop
                x := permissions._cedar_compile_scope(p_est -> s, s);
                if x ? 'code' then
                    r := x;
                    exit;
                end if;
                res := res || jsonb_build_object(s, x);
            end loop;
            if r is null then
                i := 0;
                for c in select t from jsonb_array_elements(coalesce(p_est -> 'conditions', '[]')) t loop
                    x := permissions._cedar_compile(c -> 'body', '$.conditions[' || i || '].body', 1);
                    if x ? 'code' then
                        r := x;
                        exit;
                    end if;
                    n := n + (x ->> 'n')::int;
                    x := case when c ->> 'kind' = 'unless' then jsonb_build_object('k', 'not', 'a', x -> 'ast') else x -> 'ast' end;
                    ast := case when ast is null then x else jsonb_build_object('k', 'and', 'a', ast, 'b', x) end;
                    i := i + 1;
                end loop;
            end if;
            if r is null and n > lim.policy_nodes then
                r := jsonb_build_object('code', 'limit_exceeded', 'path', '$.conditions', 'limit', 'policy_nodes',
                                        'err', format('the conditions have %s expression nodes (the limit is %s)', n, lim.policy_nodes));
            end if;
        end if;
    end if;
    if r is not null then
        perform permissions._cedar_error(r ->> 'code',
            format('invalid policy %L at %s: %s', p_id, r ->> 'path', r ->> 'err'),
            hint => coalesce(r ->> 'hint', case r ->> 'code'
                when 'limit_exceeded' then format('Split the policy into smaller policies: a policy holds at most %s bytes, %s expression nodes and %s levels of nesting.',
                                                  lim.policy_bytes, lim.policy_nodes, lim.policy_depth)
                when 'unsupported' then 'The extension types (decimal, ipaddr, datetime, duration) arrive in a later phase of research/plan-cedar.md.'
                else 'Pass the policy in Cedar''s JSON policy format, as `cedar translate-policy --direction cedar-to-json` prints it (https://docs.cedarpolicy.com/policies/json-format.html).' end),
            p_detail => case r ->> 'code'
                when 'limit_exceeded' then format('limit=%L', coalesce(r ->> 'limit', 'policy_depth'))
                when 'unsupported' then format('feature=%L', coalesce(r ->> 'feature', r ->> 'err'))
                else format('path=%L', r ->> 'path') end);
    end if;
    return res || jsonb_build_object('ast', ast);
end;
$$;

-- ----------------------------------------------------------------------------
-- Evaluator
-- ----------------------------------------------------------------------------
-- The environment of one request (built once by _cedar_env):
--
--   principal, action, resource   the entities, internal form
--   context                       a record, internal form
--   anc   {key: [ancestor keys]}  the ancestors of principal, action and resource
--   ent   {key: {"attrs", "tags"} or null}  entity data looked up already: the
--         three request entities (null: not stored) and every overlay entity
--   ov    {key: {"attrs", "tags", "parents": [[type, id], ...]}}  the
--         `entities` overlay of the request; absent without one
--
-- An overlay entity replaces the stored entity with the same uid (attrs,
-- tags and parents).

-- Every ancestor of an entity (not the entity itself), as a jsonb array of
-- keys. Without an overlay, a recursive walk over the direct parents (UNION
-- ends it on a cycle: cedar_put_entities rejects cycles, but two concurrent
-- puts could still make one). With an overlay, breadth first: each entity's
-- parents come from the overlay if it has the entity, else from storage.
-- A generic plan: the walk's plan does not depend on the uid, and planning
-- it per call would cost more than running it.
create function permissions._cedar_ancestors(p_type text, p_id text, p_ov jsonb)
returns jsonb
language plpgsql stable
set plan_cache_mode = force_generic_plan
as $$
declare
    r jsonb;
    seen jsonb := '{}';
    ts text[] := array[p_type];
    ids text[] := array[p_id];
    nt text[];
    ni text[];
    k text;
    e jsonb;
    i int;
begin
    if p_ov is null then
        with recursive a(t, i) as (
            select p.parent_type, p.parent_id from permissions.cedar_entity_parents p
            where p.type = p_type and p.id = p_id
            union
            -- offset 0 keeps the lateral subquery, so each step is an index
            -- probe (a join would hash the whole table: the planner guesses
            -- 10 rows per step)
            select q.parent_type, q.parent_id from a cross join lateral (
                select p.parent_type, p.parent_id from permissions.cedar_entity_parents p
                where p.type = a.t and p.id = a.i offset 0) q
        )
        select jsonb_agg(permissions._cedar_key(a.t, a.i)) into r from a;
        return coalesce(r, '[]');
    end if;
    while cardinality(ts) > 0 loop
        nt := '{}';
        ni := '{}';
        for i in 1 .. cardinality(ts) loop
            k := permissions._cedar_key(ts[i], ids[i]);
            if p_ov ? k then
                for e in select x from jsonb_array_elements(p_ov -> k -> 'parents') x loop
                    nt := nt || (e ->> 0);
                    ni := ni || (e ->> 1);
                end loop;
            else
                select nt || array_agg(p.parent_type), ni || array_agg(p.parent_id) into nt, ni
                from permissions.cedar_entity_parents p
                where p.type = ts[i] and p.id = ids[i];
            end if;
        end loop;
        ts := '{}';
        ids := '{}';
        for i in 1 .. cardinality(nt) loop
            k := permissions._cedar_key(nt[i], ni[i]);
            if not seen ? k then
                seen := seen || jsonb_build_object(k, true);
                ts := ts || nt[i];
                ids := ids || ni[i];
            end if;
        end loop;
    end loop;
    return coalesce((select jsonb_agg(x) from jsonb_object_keys(seen) x), '[]');
end;
$$;

-- The data of an entity value ({"attrs", "tags"}), or null if it does not
-- exist: from env.ent, else stored.
create function permissions._cedar_entity(env jsonb, v jsonb)
returns jsonb
language plpgsql stable
as $$
declare
    k text := permissions._cedar_key(v -> '__entity' ->> 'type', v -> '__entity' ->> 'id');
    r jsonb := env -> 'ent' -> k;
begin
    if r is not null then
        return nullif(r, 'null');
    end if;
    if env -> 'ov' ? k then
        return env -> 'ov' -> k;
    end if;
    select jsonb_build_object('attrs', e.attrs, 'tags', e.tags) into r
    from permissions.cedar_entities e
    where e.type = v -> '__entity' ->> 'type' and e.id = v -> '__entity' ->> 'id';
    return r;
end;
$$;

-- x in y, for x an entity: y is an entity or a set of entities (else a type
-- error, also for any element of the set that is not an entity). True if x
-- is y or y is an ancestor of x. Null is an error.
create function permissions._cedar_in(x jsonb, y jsonb, env jsonb, why boolean)
returns jsonb
language plpgsql stable
as $$
declare
    k text;
    anc jsonb;
begin
    if jsonb_typeof(y) = 'object' and y ? '__entity' then
        if x = y then
            return 'true';
        end if;
    elsif jsonb_typeof(y) = 'array' then
        if exists (select 1 from jsonb_array_elements(y) e where not (jsonb_typeof(e) = 'object' and e ? '__entity')) then
            return permissions._cedar_eval_fail(why, format('type_error: in: the set %s holds a value that is not an entity',
                                                             left(y::text, 200)));
        end if;
        if jsonb_array_length(y) = 0 then
            return 'false';
        end if;
        if exists (select 1 from jsonb_array_elements(y) e where e = x) then
            return 'true';
        end if;
    else
        return permissions._cedar_eval_fail(why, format('type_error: in: expected an entity or a set of entities on the right, got %s',
                                                         permissions._cedar_type_of(y)));
    end if;
    k := permissions._cedar_key(x -> '__entity' ->> 'type', x -> '__entity' ->> 'id');
    anc := coalesce(env -> 'anc' -> k,
                    permissions._cedar_ancestors(x -> '__entity' ->> 'type', x -> '__entity' ->> 'id', env -> 'ov'));
    if jsonb_typeof(y) = 'object' then
        return to_jsonb(anc ? permissions._cedar_key(y -> '__entity' ->> 'type', y -> '__entity' ->> 'id'));
    end if;
    return to_jsonb(exists (select 1 from jsonb_array_elements(y) e
                            where anc ? permissions._cedar_key(e -> '__entity' ->> 'type', e -> '__entity' ->> 'id')));
end;
$$;

-- One node of an ast over an environment: the value, or SQL null for an
-- evaluation error (with why, the error raises instead: _cedar_eval_fail).
-- Cedar's rules (e-cedar.md section 4.2): && and || evaluate the left side
-- first and the right side only when the left does not decide, and both
-- sides must be Bool; if-then-else evaluates only the chosen branch; every
-- other operator evaluates its operands left to right, and the first error
-- is the result. == never errs: values of different types are not equal.
create function permissions._cedar_eval(n jsonb, env jsonb, why boolean)
returns jsonb
language plpgsql stable
as $$
declare
    k text := n ->> 'k';
    x jsonb;
    y jsonb;
    r numeric;
    d jsonb;
    f text;
    vals jsonb[];
    kv record;
begin
    if k = 'lit' then
        return n -> 'v';
    elsif k = 'var' then
        return env -> (n ->> 'n');
    elsif k = 'and' or k = 'or' then
        x := permissions._cedar_eval(n -> 'a', env, why);
        if x is null then
            return null;
        elsif jsonb_typeof(x) <> 'boolean' then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected Bool on the left, got %s',
                                                             case k when 'and' then '&&' else '||' end, permissions._cedar_type_of(x)));
        elsif (x = 'true') = (k = 'or') then
            return x;
        end if;
        y := permissions._cedar_eval(n -> 'b', env, why);
        if y is null then
            return null;
        elsif jsonb_typeof(y) <> 'boolean' then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected Bool on the right, got %s',
                                                             case k when 'and' then '&&' else '||' end, permissions._cedar_type_of(y)));
        end if;
        return y;
    elsif k = 'if' then
        x := permissions._cedar_eval(n -> 'c', env, why);
        if x is null then
            return null;
        elsif jsonb_typeof(x) <> 'boolean' then
            return permissions._cedar_eval_fail(why, format('type_error: if: expected a Bool condition, got %s', permissions._cedar_type_of(x)));
        end if;
        return permissions._cedar_eval(n -> case when x = 'true' then 't' else 'e' end, env, why);
    elsif k = 'get' or k = 'has' then
        x := permissions._cedar_eval(n -> 'a', env, why);
        if x is null then
            return null;
        end if;
        f := n ->> 'f';
        if jsonb_typeof(x) = 'object' and x ? '__entity' then
            d := permissions._cedar_entity(env, x);
            if k = 'has' then
                return to_jsonb(coalesce(d -> 'attrs' ? f, false));
            elsif d is null then
                return permissions._cedar_eval_fail(why, format('entity_does_not_exist: %s (reading .%s)',
                                                                 permissions._cedar_uid_text(x -> '__entity' ->> 'type', x -> '__entity' ->> 'id'), f));
            elsif not d -> 'attrs' ? f then
                return permissions._cedar_eval_fail(why, format('attribute_not_found: %s has no attribute %s',
                                                                 permissions._cedar_uid_text(x -> '__entity' ->> 'type', x -> '__entity' ->> 'id'), to_jsonb(f)));
            end if;
            return d -> 'attrs' -> f;
        elsif jsonb_typeof(x) = 'object' and not x ? '__extn' then
            if k = 'has' then
                return to_jsonb(x ? f);
            elsif not x ? f then
                return permissions._cedar_eval_fail(why, format('attribute_not_found: the record has no attribute %s', to_jsonb(f)));
            end if;
            return x -> f;
        end if;
        return permissions._cedar_eval_fail(why, format('type_error: %s: expected an entity or a record, got %s',
                                                         case k when 'get' then '.' || f else 'has ' || f end, permissions._cedar_type_of(x)));
    elsif k = 'not' then
        x := permissions._cedar_eval(n -> 'a', env, why);
        if x is null then
            return null;
        elsif jsonb_typeof(x) <> 'boolean' then
            return permissions._cedar_eval_fail(why, format('type_error: !: expected Bool, got %s', permissions._cedar_type_of(x)));
        end if;
        return to_jsonb(x = 'false');
    elsif k = 'neg' then
        x := permissions._cedar_eval(n -> 'a', env, why);
        if x is null then
            return null;
        elsif jsonb_typeof(x) <> 'number' then
            return permissions._cedar_eval_fail(why, format('type_error: -: expected Long, got %s', permissions._cedar_type_of(x)));
        elsif x::text::numeric = -9223372036854775808 then
            return permissions._cedar_eval_fail(why, format('overflow: -(%s)', x));
        end if;
        return to_jsonb(-(x::text::numeric));
    elsif k = 'is' then
        x := permissions._cedar_eval(n -> 'a', env, why);
        if x is null then
            return null;
        elsif not (jsonb_typeof(x) = 'object' and x ? '__entity') then
            return permissions._cedar_eval_fail(why, format('type_error: is: expected an entity, got %s', permissions._cedar_type_of(x)));
        elsif x -> '__entity' ->> 'type' <> n ->> 't' then
            return 'false';
        elsif not n ? 'in' then
            return 'true';
        end if;
        y := permissions._cedar_eval(n -> 'in', env, why);
        if y is null then
            return null;
        end if;
        return permissions._cedar_in(x, y, env, why);
    elsif k = 'like' then
        x := permissions._cedar_eval(n -> 'a', env, why);
        if x is null then
            return null;
        elsif jsonb_typeof(x) <> 'string' then
            return permissions._cedar_eval_fail(why, format('type_error: like: expected String, got %s', permissions._cedar_type_of(x)));
        end if;
        return to_jsonb((x #>> '{}') collate "C" like (n ->> 'p'));
    elsif k = 'isEmpty' then
        x := permissions._cedar_eval(n -> 'a', env, why);
        if x is null then
            return null;
        elsif jsonb_typeof(x) <> 'array' then
            return permissions._cedar_eval_fail(why, format('type_error: isEmpty: expected Set, got %s', permissions._cedar_type_of(x)));
        end if;
        return to_jsonb(jsonb_array_length(x) = 0);
    elsif k = 'set' then
        for x in select e from jsonb_array_elements(n -> 'a') e loop
            y := permissions._cedar_eval(x, env, why);
            if y is null then
                return null;
            end if;
            vals := vals || y;
        end loop;
        return permissions._cedar_set(to_jsonb(vals));
    elsif k = 'rec' then
        d := '{}';
        for kv in select * from jsonb_each(n -> 'a') loop
            y := permissions._cedar_eval(kv.value, env, why);
            if y is null then
                return null;
            end if;
            d := d || jsonb_build_object(kv.key, y);
        end loop;
        return d;
    elsif k = 'call' then
        -- Extension functions and methods (phases 4a and 4b). The compiler
        -- does not emit this node yet.
        return permissions._cedar_eval_fail(why, format('extension_error: %s is not supported', n ->> 'f'));
    end if;

    -- binary operators: both operands, left to right
    x := permissions._cedar_eval(n -> 'a', env, why);
    if x is null then
        return null;
    end if;
    y := permissions._cedar_eval(n -> 'b', env, why);
    if y is null then
        return null;
    end if;
    if k = 'eq' then
        return to_jsonb(x = y);
    elsif k = 'ne' then
        return to_jsonb(x <> y);
    elsif k in ('lt', 'le', 'gt', 'ge') then
        -- Long only; datetime and duration (phase 4b) compare here too
        if jsonb_typeof(x) <> 'number' or jsonb_typeof(y) <> 'number' then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected two Longs, got %s and %s',
                                                             case k when 'lt' then '<' when 'le' then '<=' when 'gt' then '>' else '>=' end,
                                                             permissions._cedar_type_of(x), permissions._cedar_type_of(y)));
        end if;
        return to_jsonb(case k when 'lt' then x::text::numeric < y::text::numeric
                               when 'le' then x::text::numeric <= y::text::numeric
                               when 'gt' then x::text::numeric > y::text::numeric
                               else x::text::numeric >= y::text::numeric end);
    elsif k in ('add', 'sub', 'mul') then
        if jsonb_typeof(x) <> 'number' or jsonb_typeof(y) <> 'number' then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected two Longs, got %s and %s',
                                                             case k when 'add' then '+' when 'sub' then '-' else '*' end,
                                                             permissions._cedar_type_of(x), permissions._cedar_type_of(y)));
        end if;
        r := case k when 'add' then x::text::numeric + y::text::numeric
                    when 'sub' then x::text::numeric - y::text::numeric
                    else x::text::numeric * y::text::numeric end;
        if r not between -9223372036854775808 and 9223372036854775807 then
            return permissions._cedar_eval_fail(why, format('overflow: %s %s %s', x, case k when 'add' then '+' when 'sub' then '-' else '*' end, y));
        end if;
        return to_jsonb(r);
    elsif k = 'in' then
        if not (jsonb_typeof(x) = 'object' and x ? '__entity') then
            return permissions._cedar_eval_fail(why, format('type_error: in: expected an entity on the left, got %s', permissions._cedar_type_of(x)));
        end if;
        return permissions._cedar_in(x, y, env, why);
    elsif k = 'contains' then
        if jsonb_typeof(x) <> 'array' then
            return permissions._cedar_eval_fail(why, format('type_error: contains: expected Set, got %s', permissions._cedar_type_of(x)));
        end if;
        return to_jsonb(exists (select 1 from jsonb_array_elements(x) e where e = y));
    elsif k = 'containsAll' or k = 'containsAny' then
        if jsonb_typeof(x) <> 'array' or jsonb_typeof(y) <> 'array' then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected two Sets, got %s and %s', k,
                                                             permissions._cedar_type_of(x), permissions._cedar_type_of(y)));
        elsif k = 'containsAll' then
            return to_jsonb(not exists (select 1 from jsonb_array_elements(y) b
                                        where not exists (select 1 from jsonb_array_elements(x) a where a = b)));
        end if;
        return to_jsonb(exists (select 1 from jsonb_array_elements(y) b join jsonb_array_elements(x) a on a = b));
    elsif k = 'hasTag' or k = 'getTag' then
        if not (jsonb_typeof(x) = 'object' and x ? '__entity') or jsonb_typeof(y) <> 'string' then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected an entity and a String, got %s and %s', k,
                                                             permissions._cedar_type_of(x), permissions._cedar_type_of(y)));
        end if;
        d := permissions._cedar_entity(env, x);
        f := y #>> '{}';
        if k = 'hasTag' then
            return to_jsonb(coalesce(d -> 'tags' ? f, false));
        elsif d is null then
            return permissions._cedar_eval_fail(why, format('entity_does_not_exist: %s (reading tag %s)',
                                                             permissions._cedar_uid_text(x -> '__entity' ->> 'type', x -> '__entity' ->> 'id'), y));
        elsif not d -> 'tags' ? f then
            return permissions._cedar_eval_fail(why, format('tag_not_found: %s has no tag %s',
                                                             permissions._cedar_uid_text(x -> '__entity' ->> 'type', x -> '__entity' ->> 'id'), y));
        end if;
        return d -> 'tags' -> f;
    end if;
    return permissions._cedar_eval_fail(why, format('internal: unknown ast node %s', k));
end;
$$;

-- ----------------------------------------------------------------------------
-- Authorization
-- ----------------------------------------------------------------------------

-- A request context: a record (null is {}), in internal form. Raises
-- cedar:invalid_context, cedar:unsupported or cedar:limit_exceeded.
create function permissions._cedar_context(p_context jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
    x record;
    code text := 'invalid';
    err text;
begin
    if p_context is null or p_context = 'null' then
        return '{}';
    end if;
    if jsonb_typeof(p_context) <> 'object' or p_context ? '__entity' or p_context ? '__extn' then
        err := format('the context must be a record (a JSON object), got %s', left(p_context::text, 200));
    else
        select * into x from permissions._cedar_value_in(p_context, 'context', 1) r;
        if x.code is null then
            return x.val;
        end if;
        code := x.code;
        err := x.err;
    end if;
    perform permissions._cedar_error(case code when 'limit' then 'limit_exceeded' when 'unsupported' then 'unsupported' else 'invalid_context' end,
        format('invalid context: %s', err),
        hint => case code
            when 'limit' then format('Flatten the context: sets and records nest at most %s levels.', (permissions._cedar_limits()).value_depth)
            when 'unsupported' then 'Extension values (decimal, ipaddr, datetime, duration) arrive in a later phase of research/plan-cedar.md; pass the value as a String for now.'
            else 'Pass context => ''{"mfa": true, "level": 3, "owner": {"__entity": {"type": "User", "id": "alice"}}}''::jsonb: Bools, Longs, Strings, sets, records and entity references.' end,
        p_detail => case code when 'limit' then 'limit=''value_depth''' when 'unsupported' then 'feature=''extension value''' end);
end;
$$;

-- The environment of one request (see the Evaluator section): the request
-- entities, the context, their ancestors and their stored data, and the
-- overlay (p_ov: _cedar_entities_in's output, or null). Also each request
-- entity's key with its ancestors' keys (pk, ak, rk), for the scope match.
create function permissions._cedar_env(p_pt text, p_pi text, p_at text, p_ai text, p_rt text, p_ri text,
                                       p_context jsonb, p_ov jsonb,
                                       out env jsonb, out pk text[], out ak text[], out rk text[])
language plpgsql stable
as $$
declare
    ov jsonb;
    ent jsonb;
begin
    if p_ov is null then
        -- the three walks in one query (as in _cedar_ancestors)
        with recursive w(o, t, i) as (
            select v.o, q.parent_type, q.parent_id
            from (values (1, p_pt, p_pi), (2, p_at, p_ai), (3, p_rt, p_ri)) v(o, t, i)
            cross join lateral (select p.parent_type, p.parent_id from permissions.cedar_entity_parents p
                                where p.type = v.t and p.id = v.i offset 0) q
            union
            select w.o, q.parent_type, q.parent_id from w cross join lateral (
                select p.parent_type, p.parent_id from permissions.cedar_entity_parents p
                where p.type = w.t and p.id = w.i offset 0) q
        )
        select coalesce(array_agg(permissions._cedar_key(w.t, w.i)) filter (where w.o = 1), '{}'),
               coalesce(array_agg(permissions._cedar_key(w.t, w.i)) filter (where w.o = 2), '{}'),
               coalesce(array_agg(permissions._cedar_key(w.t, w.i)) filter (where w.o = 3), '{}')
        into pk, ak, rk
        from w;
        select jsonb_object_agg(permissions._cedar_key(v.t, v.i),
                                case when e.type is not null then jsonb_build_object('attrs', e.attrs, 'tags', e.tags) else 'null' end)
        into ent
        from (values (p_pt, p_pi), (p_at, p_ai), (p_rt, p_ri)) v(t, i)
        left join permissions.cedar_entities e on e.type = v.t and e.id = v.i;
    else
        select jsonb_object_agg(permissions._cedar_key(e ->> 't', e ->> 'i'), e - 't' - 'i') into ov
        from jsonb_array_elements(p_ov) e;
        ov := coalesce(ov, '{}');
        pk := array(select jsonb_array_elements_text(permissions._cedar_ancestors(p_pt, p_pi, ov)));
        ak := array(select jsonb_array_elements_text(permissions._cedar_ancestors(p_at, p_ai, ov)));
        rk := array(select jsonb_array_elements_text(permissions._cedar_ancestors(p_rt, p_ri, ov)));
        select jsonb_object_agg(v.k, coalesce(ov -> v.k,
                                              case when e.type is not null then jsonb_build_object('attrs', e.attrs, 'tags', e.tags) end,
                                              'null'))
        into ent
        from (values (p_pt, p_pi), (p_at, p_ai), (p_rt, p_ri)) v0(t, i)
        cross join lateral (select v0.t, v0.i, permissions._cedar_key(v0.t, v0.i) as k) v
        left join permissions.cedar_entities e on e.type = v.t and e.id = v.i and not ov ? v.k;
    end if;
    env := jsonb_build_object(
        'principal', jsonb_build_object('__entity', jsonb_build_object('type', p_pt, 'id', p_pi)),
        'action', jsonb_build_object('__entity', jsonb_build_object('type', p_at, 'id', p_ai)),
        'resource', jsonb_build_object('__entity', jsonb_build_object('type', p_rt, 'id', p_ri)),
        'context', p_context,
        'anc', jsonb_build_object(permissions._cedar_key(p_pt, p_pi), to_jsonb(pk),
                                  permissions._cedar_key(p_at, p_ai), to_jsonb(ak),
                                  permissions._cedar_key(p_rt, p_ri), to_jsonb(rk)),
        'ent', ent)
        || case when ov is null then '{}' else jsonb_build_object('ov', ov) end;
    -- for the scope: the entity first, then its ancestors
    pk := permissions._cedar_key(p_pt, p_pi) || pk;
    ak := permissions._cedar_key(p_at, p_ai) || ak;
    rk := permissions._cedar_key(p_rt, p_ri) || rk;
end;
$$;

-- Cedar's authorizer (e-cedar.md section 4.4). principal, action and resource
-- are uids in Cedar text (Type::"id"), context a record (null: {}), entities
-- an overlay of Cedar entity JSON for this request only: an entity there
-- replaces the stored entity with the same uid. The policies whose scope
-- matches are evaluated; a forbid that holds denies, else a permit that holds
-- allows, else the default is deny. A policy whose evaluation errs is
-- skipped and reported in errors (Cedar's semantics: it neither permits nor
-- forbids). Returns {"decision": "allow" or "deny", "reasons": [policy ids],
-- "errors": [{"policy_id", "message"}]}, ids sorted (collate "C").
create function permissions.cedar_is_authorized(principal text, action text, resource text,
                                                 context jsonb default null, entities jsonb default null)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
    p record;
    a record;
    r record;
    e record;
    env jsonb;
    pk text[];
    ak text[];
    rk text[];
    pol record;
    v jsonb;
    msg text;
    permits text[] := '{}';
    forbids text[] := '{}';
    errs jsonb := '[]';
begin
    if principal is null or action is null or resource is null then
        perform permissions._cedar_error('null_argument',
            format('%s is required to authorize a request', case when principal is null then 'principal' when action is null then 'action' else 'resource' end),
            hint => 'Pass three uids in Cedar text: principal => ''User::"alice"'', action => ''Action::"view"'', resource => ''Photo::"vacation.jpg"''.',
            p_detail => format('argument=%L', case when principal is null then 'principal' when action is null then 'action' else 'resource' end));
    end if;
    select * into p from permissions._cedar_uid(principal, 'principal');
    select * into a from permissions._cedar_uid(action, 'action');
    select * into r from permissions._cedar_uid(resource, 'resource');
    select * into e
    from permissions._cedar_env(p.type, p.id, a.type, a.id, r.type, r.id,
                                permissions._cedar_context(context),
                                case when entities is not null and entities <> 'null'
                                     then permissions._cedar_entities_in(entities, 'entities', (permissions._cedar_limits()).request_entities) end);
    env := e.env;
    pk := e.pk;
    ak := e.ak;
    rk := e.rk;
    for pol in
        select c.policy_id, c.effect, c.ast
        from permissions.cedar_policies c
        where (c.principal_op = 'All' or (c.principal_op = '==' and c.principal_uid = pk[1])
               or (c.principal_op = 'in' and c.principal_uid = any(pk))
               or (c.principal_op = 'is' and c.principal_type = p.type and (c.principal_uid is null or c.principal_uid = any(pk))))
          and (c.action_op = 'All' or (c.action_op = '==' and c.action_uids[1] = ak[1]) or (c.action_op = 'in' and c.action_uids && ak))
          and (c.resource_op = 'All' or (c.resource_op = '==' and c.resource_uid = rk[1])
               or (c.resource_op = 'in' and c.resource_uid = any(rk))
               or (c.resource_op = 'is' and c.resource_type = r.type and (c.resource_uid is null or c.resource_uid = any(rk))))
    loop
        v := case when pol.ast is null then 'true' else permissions._cedar_eval(pol.ast, env, false) end;
        if v = 'true' then
            if pol.effect = 'permit' then
                permits := permits || pol.policy_id;
            else
                forbids := forbids || pol.policy_id;
            end if;
        elsif v is null or jsonb_typeof(v) <> 'boolean' then
            -- the error's message: evaluate again, raising at the error
            begin
                v := permissions._cedar_eval(pol.ast, env, true);
                msg := case when v is null then 'internal: the condition has no value'
                            else format('type_error: a condition must be Bool, got %s', permissions._cedar_type_of(v)) end;
            exception when sqlstate 'CE001' then
                msg := sqlerrm;
            end;
            errs := errs || jsonb_build_array(jsonb_build_object('policy_id', pol.policy_id, 'message', msg));
        end if;
    end loop;
    return jsonb_build_object(
        'decision', case when cardinality(forbids) = 0 and cardinality(permits) > 0 then 'allow' else 'deny' end,
        'reasons', to_jsonb(array(select x from unnest(case when cardinality(forbids) > 0 then forbids else permits end) x
                                  order by x collate "C")),
        'errors', coalesce((select jsonb_agg(x order by x ->> 'policy_id' collate "C") from jsonb_array_elements(errs) x), '[]'));
end;
$$;

-- ----------------------------------------------------------------------------
-- Admin API: policies
-- ----------------------------------------------------------------------------

-- The nearest policy ids (_did_you_mean), for hints.
create function permissions._cedar_policy_hint(p_id text)
returns text
language sql stable
as $$
    select coalesce(permissions._did_you_mean(coalesce(p_id, ''),
                                              array(select c.policy_id from permissions.cedar_policies c),
                                              'Policy ids'),
                    'No policy exists yet: put one with select permissions.cedar_put_policy(policy_id => ..., policy_json => ...).')
$$;

-- Put (insert or replace) one static policy. Give exactly one of policy
-- (Cedar text) and policy_json (Cedar's JSON policy format, the EST, as
-- `cedar translate-policy` prints it). The policy is checked and compiled
-- here; requests never parse. Annotations are kept as metadata.
create function permissions.cedar_put_policy(policy_id text, policy text default null, policy_json jsonb default null)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    c jsonb;
begin
    if policy_id is null or (cedar_put_policy.policy is null and policy_json is null) then
        perform permissions._cedar_error('null_argument',
            case when policy_id is null then 'policy_id is required to put a policy'
                 else format('policy %L needs policy_json (or policy): both are null', policy_id) end,
            hint => 'select permissions.cedar_put_policy(policy_id => ''view-own'', policy_json => ''{"effect": "permit", "principal": {"op": "All"}, "action": {"op": "All"}, "resource": {"op": "All"}, "conditions": []}''::jsonb);',
            p_detail => format('argument=%L', case when policy_id is null then 'policy_id' else 'policy_json' end));
    end if;
    if cedar_put_policy.policy is not null and policy_json is not null then
        perform permissions._cedar_error('invalid_argument', format('policy %L has both policy and policy_json', policy_id),
            hint => 'Pass exactly one: policy => Cedar text, or policy_json => the same policy in Cedar''s JSON format.',
            p_detail => 'argument=''policy''');
    end if;
    if cedar_put_policy.policy is not null then
        -- Cedar text: the parser arrives in phase 3 of research/plan-cedar.md.
        perform permissions._cedar_error('unsupported', format('policy %L is Cedar text, which is not supported yet', policy_id),
            hint => 'Pass the policy as policy_json => ..., in Cedar''s JSON policy format: `cedar translate-policy --direction cedar-to-json` converts the text.',
            p_detail => 'feature=''policy text''');
    end if;
    -- Phase 4c (templates): a template id or a link's id here raises
    -- cedar:id_in_use.
    c := permissions._cedar_compile_policy(policy_json, policy_id);
    insert into permissions.cedar_policies as x (policy_id, effect, source, est, ast, annotations,
                                                 principal_op, principal_type, principal_uid,
                                                 action_op, action_uids,
                                                 resource_op, resource_type, resource_uid)
    values (cedar_put_policy.policy_id, c ->> 'effect', null, policy_json, nullif(c -> 'ast', 'null'), c -> 'annotations',
            c -> 'principal' ->> 'op', c -> 'principal' ->> 'type', c -> 'principal' ->> 'uid',
            c -> 'action' ->> 'op', array(select jsonb_array_elements_text(c -> 'action' -> 'uids')),
            c -> 'resource' ->> 'op', c -> 'resource' ->> 'type', c -> 'resource' ->> 'uid')
    on conflict on constraint cedar_policies_pkey do update
        set effect = excluded.effect, source = excluded.source, est = excluded.est, ast = excluded.ast,
            annotations = excluded.annotations,
            principal_op = excluded.principal_op, principal_type = excluded.principal_type, principal_uid = excluded.principal_uid,
            action_op = excluded.action_op, action_uids = excluded.action_uids,
            resource_op = excluded.resource_op, resource_type = excluded.resource_type, resource_uid = excluded.resource_uid;
end;
$$;

create function permissions.cedar_delete_policy(policy_id text)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
    delete from permissions.cedar_policies c where c.policy_id = cedar_delete_policy.policy_id;
    if not found then
        perform permissions._cedar_error(case when policy_id is null then 'null_argument' else 'unknown_policy' end,
            case when policy_id is null then 'policy_id is required to delete a policy' else format('unknown policy %L', policy_id) end,
            hint => permissions._cedar_policy_hint(policy_id),
            p_detail => case when policy_id is null then 'argument=''policy_id''' else format('policy_id=%L', policy_id) end);
    end if;
end;
$$;

-- Every policy: its id, effect, Cedar text (null when put as JSON), EST and
-- annotations, by id.
create function permissions.cedar_policies()
returns table (policy_id text, effect text, source text, est jsonb, annotations jsonb)
language sql stable security definer
set search_path = ''
as $$
    select c.policy_id, c.effect, c.source, c.est, c.annotations
    from permissions.cedar_policies c
    order by c.policy_id
$$;

-- ----------------------------------------------------------------------------
-- Admin API: entities
-- ----------------------------------------------------------------------------

-- Put (insert or replace) entities: Cedar entity JSON, an array of {"uid":
-- {"type", "id"}, "attrs": {...}, "parents": [uids], "tags": {...}}. Entity
-- references in attrs and tags are {"__entity": {"type", "id"}}, extension
-- values {"__extn": {"fn", "arg"}}. An entity's attrs, tags and parents are
-- replaced as a whole. Parents need not exist. A cycle in the hierarchy
-- raises cedar:invalid_entity, as in Cedar.
create function permissions.cedar_put_entities(entities jsonb)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    v jsonb;
    n int;
    ec int[];
    ep int[];
    names jsonb[];
    first int[];
    color int[];
    stk int[];
    pos int[];
    top int;
    u int;
    w int;
    i int;
    cyc text;
    ts text[];
    ids text[];
    attrs jsonb[];
    tags jsonb[];
    cts text[];
    cis text[];
    pts text[];
    pis text[];
begin
    if entities is null then
        perform permissions._cedar_error('null_argument', 'entities is required to put entities',
            hint => 'select permissions.cedar_put_entities(entities => ''[{"uid": {"type": "User", "id": "alice"}, "attrs": {}, "parents": []}]''::jsonb);',
            p_detail => 'argument=''entities''');
    end if;
    v := permissions._cedar_entities_in(entities, 'entities', (permissions._cedar_limits()).put_entities);
    -- The statements below go from the put entities to the tables through
    -- index probes (lateral subqueries with offset 0 or limit 1): the planner
    -- would otherwise hash a whole table for a few entities.
    select array_agg(x ->> 't'), array_agg(x ->> 'i'), array_agg(x -> 'attrs'), array_agg(x -> 'tags')
    into ts, ids, attrs, tags
    from jsonb_array_elements(v) x;
    select coalesce(array_agg(x ->> 't'), '{}'), coalesce(array_agg(x ->> 'i'), '{}'),
           coalesce(array_agg(y ->> 0), '{}'), coalesce(array_agg(y ->> 1), '{}')
    into cts, cis, pts, pis
    from jsonb_array_elements(v) x cross join lateral jsonb_array_elements(x -> 'parents') y;
    insert into permissions.cedar_entities as e (type, id, attrs, tags)
    select * from unnest(ts, ids, attrs, tags)
    on conflict (type, id) do update set attrs = excluded.attrs, tags = excluded.tags;
    delete from permissions.cedar_entity_parents p
    using (select q.ctid as c
           from unnest(ts, ids) d(t, i)
           cross join lateral (select x.ctid, x.type, x.id, x.parent_type, x.parent_id
                               from permissions.cedar_entity_parents x
                               where x.type = d.t and x.id = d.i offset 0) q
           where (q.type, q.id, q.parent_type, q.parent_id) not in (select * from unnest(cts, cis, pts, pis))) z
    where p.ctid = z.c;
    insert into permissions.cedar_entity_parents (type, id, parent_type, parent_id)
    select * from unnest(cts, cis, pts, pis)
    on conflict do nothing;

    -- Cycles. A new cycle passes through an entity put here that is the
    -- parent of another entity (a new leaf can't close one). If there is
    -- such an entity, take the put entities and their ancestors, number them,
    -- list the parent edges among them, and search for a back edge
    -- (depth-first, iterative).
    if not exists (select 1 from unnest(ts, ids) d(t, i)
                   cross join lateral (select 1 from permissions.cedar_entity_parents p
                                       where p.parent_type = d.t and p.parent_id = d.i limit 1) q) then
        return;
    end if;
    with recursive s(t, i) as (
        select d.t collate "C", d.i collate "C" from unnest(ts, ids) d(t, i)
        union
        select q.parent_type, q.parent_id from s cross join lateral (
            select p.parent_type, p.parent_id from permissions.cedar_entity_parents p
            where p.type = s.t and p.id = s.i offset 0) q
    ), nodes as (
        select s.t, s.i, (row_number() over (order by s.t, s.i))::int as no from s
    ), edges as (
        select c.no as c, q.no as p
        from nodes c
        join permissions.cedar_entity_parents e on e.type = c.t and e.id = c.i
        join nodes q on q.t = e.parent_type and q.i = e.parent_id
    )
    select (select count(*)::int from nodes),
           array(select jsonb_build_array(nodes.t, nodes.i) from nodes order by nodes.no),
           array(select edges.c from edges order by edges.c, edges.p),
           array(select edges.p from edges order by edges.c, edges.p)
    into n, names, ec, ep;
    if cardinality(ec) > 0 then
        first := array_fill(cardinality(ec) + 1, array[n + 1]);
        for i in reverse cardinality(ec) .. 1 loop
            first[ec[i]] := i;
        end loop;
        color := array_fill(0, array[n]);
        <<roots>>
        for u in 1 .. n loop
            continue when color[u] <> 0;
            stk := array[u];
            pos := array[first[u]];
            color[u] := 1;
            top := 1;
            while top > 0 loop
                i := pos[top];
                if i <= cardinality(ec) and ec[i] = stk[top] then
                    pos[top] := i + 1;
                    w := ep[i];
                    if color[w] = 1 then
                        cyc := permissions._cedar_uid_text(names[w] ->> 0, names[w] ->> 1);
                        exit roots;
                    elsif color[w] = 0 then
                        color[w] := 1;
                        top := top + 1;
                        stk[top] := w;
                        pos[top] := first[w];
                    end if;
                else
                    color[stk[top]] := 2;
                    top := top - 1;
                end if;
            end loop;
        end loop;
    end if;
    if cyc is not null then
        perform permissions._cedar_error('invalid_entity', format('the entity hierarchy has a cycle through %s', cyc),
            hint => 'An entity cannot be its own ancestor (Cedar rejects cycles): remove one of the parent links of the cycle.',
            p_detail => format('uid=%L', cyc));
    end if;
end;
$$;

-- Delete entities by uid: a JSON array of {"type", "id"} (or {"__entity":
-- ...}) or of Cedar text uids ("User::\"alice\""). Their attributes, tags and
-- parent links go with them; links from other entities to them stay (a
-- parent need not exist). Returns the number of entities deleted.
create function permissions.cedar_delete_entities(uids jsonb)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
    n bigint;
    bad jsonb;
    x jsonb;
    u record;
    ts text[] := '{}';
    ids text[] := '{}';
begin
    if uids is null or jsonb_typeof(uids) <> 'array' then
        perform permissions._cedar_error(case when uids is null then 'null_argument' else 'invalid_uid' end,
            case when uids is null then 'uids is required to delete entities'
                 else format('uids must be a JSON array of uids, got a JSON %s', jsonb_typeof(uids)) end,
            hint => 'select permissions.cedar_delete_entities(uids => ''[{"type": "User", "id": "alice"}, "Group::\"staff\""]''::jsonb);',
            p_detail => case when uids is null then 'argument=''uids''' else format('value=%L', left(uids::text, 200)) end);
    end if;
    select j into bad from jsonb_array_elements(uids) j
    where jsonb_typeof(j) <> 'string' and (permissions._cedar_uid_json(j)).type is null
    limit 1;
    if bad is not null then
        perform permissions._cedar_error('invalid_uid', format('invalid entity uid in uids: %s', left(bad::text, 200)),
            hint => 'A uid is {"type": "User", "id": "alice"} or Cedar text, "User::\"alice\"".',
            p_detail => format('value=%L', left(bad::text, 200)));
    end if;
    for x in select e from jsonb_array_elements(uids) e loop
        if jsonb_typeof(x) = 'string' then
            select * into u from permissions._cedar_uid(x #>> '{}', 'uids');
        else
            select * into u from permissions._cedar_uid_json(x);
        end if;
        ts := ts || u.type;
        ids := ids || u.id;
    end loop;
    delete from permissions.cedar_entities e
    using unnest(ts, ids) d(t, i)
    where e.type = d.t and e.id = d.i;
    get diagnostics n = row_count;
    return n;
end;
$$;

-- Stored entities as Cedar entity JSON, by type and id: all of them, one
-- type's, or (with ids) some of one type.
create function permissions.cedar_read_entities(type text default null, ids text[] default null)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
begin
    if ids is not null and cedar_read_entities.type is null then
        perform permissions._cedar_error('null_argument', 'type is required with ids',
            hint => 'select permissions.cedar_read_entities(type => ''User'', ids => ''{alice,bob}'');',
            p_detail => 'argument=''type''');
    end if;
    return coalesce((
        select jsonb_agg(jsonb_build_object(
                   'uid', jsonb_build_object('type', e.type, 'id', e.id),
                   'attrs', permissions._cedar_value_out(e.attrs),
                   'parents', coalesce((select jsonb_agg(jsonb_build_object('type', p.parent_type, 'id', p.parent_id)
                                                         order by p.parent_type, p.parent_id)
                                        from permissions.cedar_entity_parents p
                                        where p.type = e.type and p.id = e.id), '[]'),
                   'tags', permissions._cedar_value_out(e.tags))
                   order by e.type, e.id)
        from permissions.cedar_entities e
        where (cedar_read_entities.type is null or e.type = cedar_read_entities.type)
          and (ids is null or e.id = any(ids))), '[]');
end;
$$;

-- Privileges. Every cedar_* function and table is for the owner and the
-- trusted roles the app grants (e.g. service_role), never PUBLIC. A fresh
-- install revokes everything from PUBLIC at the end of the file; this does the
-- same for the objects above when the upgrade script adds them.
do $$
declare
    f regprocedure;
    t regclass;
begin
    for f in select p.oid::regprocedure from pg_proc p
             where p.pronamespace = 'permissions'::regnamespace and p.proname ~ '^_?cedar_' loop
        execute format('revoke all on function %s from public', f);
    end loop;
    for t in select c.oid::regclass from pg_class c
             where c.relnamespace = 'permissions'::regnamespace and c.relkind = 'r' and c.relname ~ '^cedar_' loop
        execute format('revoke all on table %s from public', t);
    end loop;
end;
$$;
-- <<< cedar section: end
