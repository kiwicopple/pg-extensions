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

-- These are new functions: remove named-role default grants as well as
-- PUBLIC. Replaced functions below retain their existing explicit grants.
do $$
declare a record;
begin
    for a in
        select distinct p.oid::regprocedure as fn, x.grantee
        from pg_catalog.pg_proc p
        cross join lateral pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) x
        where p.oid in ('permissions._ip_canon(text)'::regprocedure,
                        'permissions._ts_canon(text)'::regprocedure,
                        'permissions._duration_ns(text)'::regprocedure)
          and x.grantee <> p.proowner
    loop
        execute format('revoke all on function %s from %s', a.fn,
            case when a.grantee = 0 then 'public' else quote_ident(pg_catalog.pg_get_userbyid(a.grantee)) end);
    end loop;
end;
$$;

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
-- as Cedar text or in Cedar's JSON policy format (the EST; text is parsed to
-- the EST), checked and compiled once: the EST is kept in `est`, the
-- conditions as a compact tree in `ast` (e-cedar.md section 2.3) and the
-- scope in columns, so a request matches the scope in SQL and evaluates only
-- the conditions of the policies whose scope matches. A template link is a
-- policy too, with the template's slots filled in when it is linked.
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

-- Policy templates. A link is a row of cedar_policies that names its
-- template, with the slots filled in at link time (cedar_link_template).
create table permissions.cedar_templates (
    template_id text collate "C" primary key,
    source      text,                  -- the Cedar text as written; null when put as JSON
    est         jsonb not null,        -- Cedar's JSON policy format, with slots
    ast         jsonb,                 -- the conditions, compiled; links copy it
    annotations jsonb not null default '{}'
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
    slots          jsonb               -- a link's slot values: {"?principal": {"type", "id"}, ...}
);
create index on permissions.cedar_policies (template_id) where template_id is not null;

-- The scope index (e-cedar.md section 15.1): one row per policy and action
-- of its action scope, keyed so that a request finds its candidate policies
-- with equality probes, = any(keys), and no scan of cedar_policies:
--   action_key     each uid of the action scope; '*' for All
--   principal_key  ==, in and is ... in: the uid; is: the type; All: '*'
--   resource_key   the same for the resource
-- A request probes the principal's and the resource's own key, their
-- ancestors' keys, their type and '*', through the index that leads with the
-- side with fewer keys. That finds every policy whose scope can match, and
-- a few that don't (a == on an ancestor, an is ... in of another type); the
-- scope predicate in _cedar_candidates is exact.
-- _cedar_store_policy keeps it; a policy's rows go with it.
create table permissions.cedar_policy_scopes (
    policy_id     text collate "C" not null references permissions.cedar_policies (policy_id) on delete cascade,
    action_key    text collate "C" not null,
    principal_key text collate "C" not null,
    resource_key  text collate "C" not null,
    primary key (policy_id, action_key)
);
create index on permissions.cedar_policy_scopes (action_key, principal_key, resource_key) include (policy_id);
create index on permissions.cedar_policy_scopes (action_key, resource_key, principal_key) include (policy_id);

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

-- Coordinate parent additions before checking the graph for cycles. A row
-- write also causes concurrent REPEATABLE READ / SERIALIZABLE writers with
-- an old snapshot to fail with 40001; a lock alone would let them validate
-- different snapshots and commit a cycle. Created lazily on the first write.
create table permissions._cedar_hierarchy_guard (
    one boolean primary key check (one)
);

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

-- A uid as Cedar text, Type::"id" with Cedar's string escapes. The escapes
-- match uid() in js/src/cedar/uid.ts: \" \\ \n \r \t, and \u{hex} for the
-- other control characters and DEL. Messages and cedar_uid use it.
create function permissions._cedar_uid_text(p_type text, p_id text)
returns text
language sql immutable
as $$
    select p_type || '::"' || case
        when coalesce(p_id, '') !~ '[\x01-\x1f"\\\x7f]' then coalesce(p_id, '')
        else (select string_agg(case when c = '"' then '\"' when c = '\' then '\\'
                                     when c = chr(10) then '\n' when c = chr(13) then '\r' when c = chr(9) then '\t'
                                     when ascii(c) < 32 or ascii(c) = 127 then format('\u{%s}', to_hex(ascii(c)))
                                     else c end, '' order by o)
              from regexp_split_to_table(p_id, '') with ordinality s(c, o) where c <> '')
        end || '"'
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
-- \\ \0 \' \" \xHH \u{H..}). Raises cedar:invalid_uid, or with p_quiet
-- returns nulls.
create function permissions._cedar_uid(p_text text, p_arg text, p_quiet boolean default false, out type text, out id text)
language plpgsql immutable
as $$
declare
    m text[];
    s text;
    r text := '';
    i int := 1;
    c text;
    n int := 0;
    cp int;
    parts text[] := '{}';
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
        -- one token per run of plain characters or per escape, decoded and
        -- joined once (linear in the length; i is the character position)
        s := m[2];
        for c in select t[1] from regexp_matches(s, '[^\\]+|\\x[0-7][0-9a-fA-F]|\\u\{[0-9a-fA-F]{1,6}\}|\\.', 'g') t loop
            n := n + 1;
            if left(c, 1) <> '\' then
                parts[n] := c;
            elsif substr(c, 2, 1) in ('n', 'r', 't', '\', '"', '''') then
                parts[n] := case substr(c, 2, 1) when 'n' then e'\n' when 'r' then e'\r' when 't' then e'\t' else substr(c, 2, 1) end;
            elsif substr(c, 2, 1) = 'x' and length(c) = 4 and substr(c, 3) <> '00' then
                parts[n] := chr(('x' || lpad(substr(c, 3), 8, '0'))::bit(32)::int);
            elsif substr(c, 2, 1) = 'u' then
                -- \u{1 to 6 hex digits} is one token; a bare \u is \. (cp null)
                cp := case when length(c) > 4 then ('x' || lpad(substr(c, 4, length(c) - 4), 8, '0'))::bit(32)::int end;
                if cp is null or cp not between 1 and 1114111 or cp between 55296 and 57343 then
                    bad := format('the escape \u%s is not a Unicode scalar value (U+0000 is not supported)', coalesce(substr(s, i + 2, 8), ''));
                    exit;
                end if;
                parts[n] := chr(cp);
            else
                bad := format('the escape \%s is not valid in a Cedar string (U+0000 is not supported)', substr(c, 2, 1));
                exit;
            end if;
            i := i + length(c);
        end loop;
        r := array_to_string(parts, '');
        if bad is null then
            type := m[1];
            id := r;
            return;
        end if;
    end if;
    if p_quiet then
        return;
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
                                when v ? '__extn' then case v -> '__extn' ->> 'fn' when 'ip' then 'ipaddr'
                                                       else coalesce(v -> '__extn' ->> 'fn', 'extension') end
                                else 'Record' end
        else 'no value' end
$$;

-- The extension functions and methods of Cedar 4.x, and the extension type
-- each belongs to: for a method, the type of its receiver. An unknown name
-- gets the nearest of these (cedar:invalid_policy).
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

-- ----------------------------------------------------------------------------
-- Extension types: decimal, ipaddr, datetime, duration (e-cedar.md section 14)
-- ----------------------------------------------------------------------------
-- An extension value is {"__extn": {"fn": F, "v": V}} internally, one
-- canonical V per value, so Cedar == stays jsonb equality:
--
--   decimal   F "decimal", V the i64 value times 10^4 (decimal("1.0") ==
--             decimal("1.0000"))
--   ipaddr    F "ip", V the inet text with the prefix length always
--             written, as Cedar prints it: "10.0.0.1/32" for ip("10.0.0.1"),
--             host bits kept ("10.0.0.1/24" <> "10.0.0.0/24"), IPv6 always
--             in hex groups
--   datetime  F "datetime", V i64 milliseconds since the Unix epoch
--   duration  F "duration", V i64 milliseconds
--
-- Entity and context JSON write them as {"__extn": {"fn", "arg": "<text>"}}
-- (Cedar's form); _cedar_value_in converts on input and _cedar_value_out on
-- output. The parsers below follow Cedar 4.14's own (cedar-policy-core,
-- src/extensions/), not the toolkit's _ip_canon, _ts_canon and _duration_ns,
-- which follow Go for FGA: each returns null for text Cedar rejects.

-- Cedar's decimal("…"): -?digits.digits, 1 to 4 digits after the point,
-- within i64 / 10^4. The value times 10^4, or null.
create function permissions._cedar_decimal(s text)
returns bigint
language plpgsql immutable
as $$
declare
    m text[] := regexp_match(s, '^(-?)([0-9]+)\.([0-9]{1,4})$');
    v numeric;
begin
    if m is null then
        return null;
    end if;
    v := (m[2]::numeric * 10000 + rpad(m[3], 4, '0')::numeric) * case when m[1] = '-' then -1 else 1 end;
    if v not between -9223372036854775808 and 9223372036854775807 then
        return null;
    end if;
    return v;
end;
$$;

-- Cedar's ip("…"): an IPv4 address (four decimal octets, no leading zeros)
-- or an IPv6 address in hex groups (Rust's std parser), with an optional
-- /prefix (decimal, no leading zeros, at most 32 or 128). At most 43 bytes.
-- No zone (%eth0), and no IPv4 embedded in IPv6: Cedar rejects any text with
-- two colons and two dots (::ffff:1.2.3.4); ::ffff:102:304 is an IPv6
-- address. The canonical text (see above), or null.
create function permissions._cedar_ip(s text)
returns text
language plpgsql immutable
as $$
declare
    i int := strpos(s, '/');
    a text := case when i > 0 then left(s, i - 1) else s end;
    p text := case when i > 0 then substr(s, i + 1) end;
    v6 boolean;
    t text;
    m text[];
begin
    if octet_length(s) > 43 or (s ~ ':.*:' and s ~ '\..*\.') then
        return null;
    end if;
    if a ~ '^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$' then
        v6 := false;
    elsif a ~ '^[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){7}$'
          or (a ~ '^(([0-9a-fA-F]{1,4}:)*[0-9a-fA-F]{1,4})?::(([0-9a-fA-F]{1,4}:)*[0-9a-fA-F]{1,4})?$'
              and (select count(*) from regexp_matches(a, '[0-9a-fA-F]+', 'g') g) <= 7) then
        v6 := true;
    else
        return null;
    end if;
    if p is not null and (p !~ '^(0|[1-9][0-9]{0,2})$' or p::int > (case when v6 then 128 else 32 end)) then
        return null;
    end if;
    t := (a || coalesce('/' || p, ''))::inet::text;
    -- Postgres prints ::ffff:a.b.c.d and ::a.b.c.d with an IPv4 tail, which
    -- Cedar would not read back: write the tail as two hex groups
    if v6 and strpos(t, '.') > 0 then
        m := regexp_match(t, '^(.*:)([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)(/[0-9]+)?$');
        t := m[1] || to_hex(m[2]::int * 256 + m[3]::int) || ':' || to_hex(m[4]::int * 256 + m[5]::int) || coalesce(m[6], '');
    end if;
    return t;
end;
$$;

-- Cedar's datetime("…") (RFC 80): YYYY-MM-DD, optionally followed by
-- Thh:mm:ss, an optional .SSS, and Z or an offset +hhmm / -hhmm (hh < 24,
-- mm < 60). Years 0000 to 9999 of the proleptic Gregorian calendar; no leap
-- second. Milliseconds since the Unix epoch, or null.
create function permissions._cedar_datetime(s text)
returns bigint
language plpgsql immutable
as $$
declare
    m text[] := regexp_match(s, '^([0-9]{4})-([0-9]{2})-([0-9]{2})(?:T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{3}))?(?:Z|([+-])([0-9]{2})([0-9]{2})))?$');
    y int;
    mo int;
    d int;
    era int;
    yoe int;
    doe int;
begin
    if m is null then
        return null;
    end if;
    y := m[1]::int;
    mo := m[2]::int;
    d := m[3]::int;
    if mo not between 1 and 12 or d < 1
       or d > (case when mo = 2 then (case when y % 4 = 0 and (y % 100 <> 0 or y % 400 = 0) then 29 else 28 end)
                    when mo in (4, 6, 9, 11) then 30 else 31 end)
       or coalesce(m[4]::int > 23 or m[5]::int > 59 or m[6]::int > 59, false)
       or coalesce(m[9]::int > 23 or m[10]::int > 59, false) then
        return null;
    end if;
    -- days from 1970-01-01 (H. Hinnant's days_from_civil)
    y := y - (mo <= 2)::int;
    era := (case when y >= 0 then y else y - 399 end) / 400;
    yoe := y - era * 400;
    doe := yoe * 365 + yoe / 4 - yoe / 100 + (153 * (mo + case when mo > 2 then -3 else 9 end) + 2) / 5 + d - 1;
    return (era * 146097 + doe - 719468)::bigint * 86400000
           + coalesce(m[4]::bigint * 3600000 + m[5]::bigint * 60000 + m[6]::bigint * 1000, 0) + coalesce(m[7]::bigint, 0)
           - coalesce(case m[8] when '+' then 1 else -1 end * (m[9]::bigint * 3600000 + m[10]::bigint * 60000), 0);
end;
$$;

-- Cedar's duration("…") (RFC 80): an optional -, then quantity-unit pairs in
-- the order d, h, m, s, ms, each at most once, at least one ("1d2h3m4s5ms",
-- "-90m"). Milliseconds, or null (also beyond i64).
create function permissions._cedar_duration(s text)
returns bigint
language plpgsql immutable
as $$
declare
    m text[] := regexp_match(s, '^(-?)(?:([0-9]+)d)?(?:([0-9]+)h)?(?:([0-9]+)m)?(?:([0-9]+)s)?(?:([0-9]+)ms)?$');
    v numeric;
begin
    if m is null or s = '' or s = '-' then
        return null;
    end if;
    v := coalesce(m[2]::numeric * 86400000, 0) + coalesce(m[3]::numeric * 3600000, 0) + coalesce(m[4]::numeric * 60000, 0)
         + coalesce(m[5]::numeric * 1000, 0) + coalesce(m[6]::numeric, 0);
    if m[1] = '-' then
        v := -v;
    end if;
    if v not between -9223372036854775808 and 9223372036854775807 then
        return null;
    end if;
    return v;
end;
$$;

-- An extension value from its constructor and text: fn is decimal, ip,
-- datetime or duration. The internal value, or null when Cedar's
-- constructor would fail.
create function permissions._cedar_extn(fn text, arg text)
returns jsonb
language plpgsql immutable
as $$
declare
    v jsonb := case fn when 'decimal' then to_jsonb(permissions._cedar_decimal(arg))
                       when 'ip' then to_jsonb(permissions._cedar_ip(arg))
                       when 'datetime' then to_jsonb(permissions._cedar_datetime(arg))
                       when 'duration' then to_jsonb(permissions._cedar_duration(arg)) end;
begin
    if v is null then
        return null;
    end if;
    return jsonb_build_object('__extn', jsonb_build_object('fn', fn, 'v', v));
end;
$$;

-- What a constructor accepts, for messages and hints.
create function permissions._cedar_extn_help(fn text)
returns text
language sql immutable
as $$
    select case fn
        when 'decimal' then 'a decimal has digits on both sides of the point, at most 4 after it, and lies within -922337203685477.5808 and 922337203685477.5807, like "12.34"'
        when 'ip' then 'an ipaddr is an IPv4 or IPv6 address with an optional CIDR prefix, like "10.0.0.1", "10.0.0.0/8" or "ffee::/64", with no leading zeros, no zone and no IPv4 embedded in IPv6'
        when 'datetime' then 'a datetime is "YYYY-MM-DD", optionally followed by "Thh:mm:ss", an optional ".SSS", and "Z" or an offset "+hhmm" or "-hhmm", like "2024-10-15T11:35:00Z"'
        when 'duration' then 'a duration is quantity-unit pairs in the order d, h, m, s, ms with an optional leading "-", like "1d2h3m4s5ms", within the 64-bit range of milliseconds'
        else 'the constructors are decimal, ip, datetime and duration' end
$$;

-- A datetime as text, YYYY-MM-DDThh:mm:ss.SSSZ, or null outside the years
-- 0000 to 9999 (which only offset reaches; H. Hinnant's civil_from_days).
create function permissions._cedar_datetime_text(ms bigint)
returns text
language plpgsql immutable
as $$
declare
    tod bigint := mod(mod(ms, 86400000) + 86400000, 86400000);
    days bigint := div(ms::numeric - tod, 86400000);
    z bigint := days + 719468;
    era bigint := (case when z >= 0 then z else z - 146096 end) / 146097;
    doe bigint := z - era * 146097;
    yoe bigint := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    doy bigint := doe - (365 * yoe + yoe / 4 - yoe / 100);
    mp bigint := (5 * doy + 2) / 153;
    mo bigint := case when mp < 10 then mp + 3 else mp - 9 end;
    y bigint := yoe + era * 400 + (mo <= 2)::int;
begin
    if y not between 0 and 9999 then
        return null;
    end if;
    return format('%s-%s-%sT%s:%s:%s.%sZ', lpad(y::text, 4, '0'), lpad(mo::text, 2, '0'), lpad((doy - (153 * mp + 2) / 5 + 1)::text, 2, '0'),
                  lpad((tod / 3600000)::text, 2, '0'), lpad((tod / 60000 % 60)::text, 2, '0'), lpad((tod / 1000 % 60)::text, 2, '0'),
                  lpad((tod % 1000)::text, 3, '0'));
end;
$$;

-- An internal extension value in Cedar's JSON form: {"__extn": {"fn", "arg"}}
-- with the canonical text (decimal "1.2300", ip "10.0.0.1/32", datetime
-- "2024-01-01T00:00:00.000Z", duration "5400000ms"). A datetime outside the
-- years 0000 to 9999 is Cedar's own form for it, offset(datetime("1970-01-01"),
-- duration("<ms>ms")), which _cedar_value_in reads back.
create function permissions._cedar_extn_out(v jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
    fn text := v -> '__extn' ->> 'fn';
    x jsonb := v -> '__extn' -> 'v';
    t text;
begin
    if fn = 'decimal' then
        t := case when x::text::numeric < 0 then '-' else '' end || div(abs(x::text::numeric), 10000)::text
             || '.' || lpad(mod(abs(x::text::numeric), 10000)::text, 4, '0');
    elsif fn = 'ip' then
        t := x #>> '{}';
    elsif fn = 'duration' then
        t := x::text || 'ms';
    else
        t := permissions._cedar_datetime_text(x::text::bigint);
        if t is null then
            return jsonb_build_object('__extn', jsonb_build_object('fn', 'offset', 'args', jsonb_build_array(
                jsonb_build_object('__extn', jsonb_build_object('fn', 'datetime', 'arg', '1970-01-01')),
                jsonb_build_object('__extn', jsonb_build_object('fn', 'duration', 'arg', x::text || 'ms')))));
        end if;
    end if;
    return jsonb_build_object('__extn', jsonb_build_object('fn', fn, 'arg', t));
end;
$$;

-- A Bool, a String or a Long: a value that is its own internal form.
create function permissions._cedar_is_plain(v jsonb)
returns boolean
language sql immutable
as $$
    select case jsonb_typeof(v)
        when 'boolean' then true
        when 'string' then true
        when 'number' then v::text ~ '^-?[0-9]{1,18}$'
                           or (v::text ~ '^-?[0-9]{19}$' and v::text::numeric between -9223372036854775808 and 9223372036854775807)
        else false end
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
    w jsonb;
    vals jsonb[];
    keys text[];
    n int;
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
        -- the elements already in internal form (Bools, Strings, Longs) are
        -- kept in one query; the others are checked or converted one by
        -- one, in order (the first error wins), and the set is built once
        n := 0;
        for u in select e.v, e.o - 1 as i from jsonb_array_elements(v) with ordinality e(v, o)
                 where not permissions._cedar_is_plain(e.v) order by e.o loop
            select * into x from permissions._cedar_value_in(u.v, p_path || '[' || u.i || ']', p_depth + 1) r;
            if x.code is not null then
                code := x.code;
                err := x.err;
                return;
            end if;
            n := n + 1;
            vals[n] := x.val;
        end loop;
        val := permissions._cedar_set(case when n = 0 then v
                                           else coalesce((select jsonb_agg(e) from jsonb_array_elements(v) e where permissions._cedar_is_plain(e)), '[]')
                                                || to_jsonb(vals) end);
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
        -- Cedar's {"fn", "arg"}, or {"fn", "args": [...]} (its own output
        -- for a datetime is offset(datetime(...), duration(...)) in that form);
        -- the arguments are values too
        w := v -> '__extn';
        if (select count(*) from jsonb_object_keys(v)) <> 1 or jsonb_typeof(w) <> 'object'
           or jsonb_typeof(w -> 'fn') is distinct from 'string' or w - '{fn,arg,args}'::text[] <> '{}'
           or (w ? 'arg') = (w ? 'args') or (w ? 'args' and jsonb_typeof(w -> 'args') <> 'array') then
            code := 'invalid';
            err := format('%s: an extension value is {"__extn": {"fn": "<function>", "arg": "<text>"}}, got %s', p_path, v);
            return;
        end if;
        fn := w ->> 'fn';
        if not permissions._cedar_extensions() ? fn then
            code := 'invalid';
            err := format('%s: unknown extension function ''%s''', p_path, fn);
            return;
        end if;
        -- Cedar applies the function to the arguments (each a value, a
        -- constructor's a string) as it would in a policy: decimal, ip,
        -- datetime and duration, but also offset or toDate. An error there
        -- is an invalid value.
        if fn in ('decimal', 'ip', 'datetime', 'duration') and jsonb_typeof(w -> 'arg') = 'string' then
            -- the common case, without the general call
            val := permissions._cedar_extn(fn, w ->> 'arg');
            if val is not null then
                return;
            end if;
        end if;
        acc := case when w ? 'arg' then jsonb_build_array(w -> 'arg') else w -> 'args' end;
        for i in 0 .. jsonb_array_length(acc) - 1 loop
            select * into x from permissions._cedar_value_in(acc -> i, p_path || '.__extn.' || case when w ? 'arg' then 'arg' else 'args[' || i || ']' end,
                                                             p_depth + 1) r;
            if x.code is not null then
                code := x.code;
                err := x.err;
                return;
            end if;
            vals := vals || x.val;
        end loop;
        val := permissions._cedar_call(fn, vals, false);
        if val is null then
            code := 'extension';
            begin
                perform permissions._cedar_call(fn, vals, true);
            exception when sqlstate 'CE001' then
                err := format('%s: %s', p_path, sqlerrm);
            end;
            return;
        end if;
        return;
    end if;
    -- a record: Bools, Strings and Longs stay as they are; everything else
    -- is checked or converted, and the changed values replace theirs once
    n := 0;
    for kv in select * from jsonb_each(v) e where not permissions._cedar_is_plain(e.value) loop
        select * into x from permissions._cedar_value_in(kv.value, p_path || '.' || kv.key, p_depth + 1) r;
        if x.code is not null then
            code := x.code;
            err := x.err;
            return;
        end if;
        if x.val <> kv.value then
            n := n + 1;
            keys[n] := kv.key;
            vals[n] := x.val;
        end if;
    end loop;
    val := case when n = 0 then v else v || (select jsonb_object_agg(q.qk, q.qw) from unnest(keys, vals) q(qk, qw)) end;
end;
$$;

-- An internal value in Cedar's JSON form (cedar_read_entities): the same
-- value, with each extension value back in {"__extn": {"fn", "arg"}}.
create function permissions._cedar_value_out(v jsonb)
returns jsonb
language plpgsql immutable
as $$
begin
    if strpos(v::text, '"__extn"') = 0 then
        return v;
    elsif jsonb_typeof(v) = 'array' then
        return (select jsonb_agg(permissions._cedar_value_out(e) order by o) from jsonb_array_elements(v) with ordinality t(e, o));
    elsif v ? '__extn' then
        return permissions._cedar_extn_out(v);
    end if;
    return (select jsonb_object_agg(e.key, permissions._cedar_value_out(e.value)) from jsonb_each(v) e);
end;
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
    pj jsonb;
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
        -- _cedar_uid_json for each parent, in one query: the first one that
        -- is not a uid, and the [type, id] pairs
        with p as (select t.o, t.v, case when jsonb_typeof(t.v) = 'object' and t.v ? '__entity' and t.v - '__entity' = '{}'
                                         then t.v -> '__entity' else t.v end as w
                   from jsonb_array_elements(e -> 'parents') with ordinality t(v, o)),
             q as (select p.o, p.v, case when jsonb_typeof(p.w) = 'object' and jsonb_typeof(p.w -> 'type') = 'string'
                                              and jsonb_typeof(p.w -> 'id') = 'string' and p.w - 'type' - 'id' = '{}'
                                              and permissions._cedar_is_name(p.w ->> 'type') then p.w end as uid
                   from p)
        select (select q.v from q where q.uid is null order by q.o limit 1),
               jsonb_agg(jsonb_build_array(q.uid ->> 'type', q.uid ->> 'id') order by q.o)
        into pv, pj
        from q;
        if pv is not null then
            err := format('%s: a parent is not a uid {"type": "<Type>", "id": "<id>"}: %s', permissions._cedar_uid_text(u.type, u.id), pv);
            return;
        end if;
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
    parents := case when jsonb_array_length(pj) > 1 then permissions._cedar_set(pj) else coalesce(pj, '[]') end;
end;
$$;

-- Cedar entity JSON (an array of entities), checked and in internal form:
-- [{"t", "i", "attrs", "tags", "parents": [[type, id], ...]}]. p_arg names
-- the argument for the messages and p_limit the limit on the number of
-- entities (put_entities or request_entities of _cedar_limits). Raises
-- cedar:invalid_entity index=<n> at the first bad entity, or
-- cedar:limit_exceeded limit='<name>' (value_depth: with index=<n>).
create function permissions._cedar_entities_in(p_entities jsonb, p_arg text, p_limit text)
returns jsonb
language plpgsql stable
as $$
declare
    r jsonb;
    res jsonb;
    p_max int := case p_limit when 'put_entities' then (permissions._cedar_limits()).put_entities
                              else (permissions._cedar_limits()).request_entities end;
begin
    if jsonb_typeof(p_entities) <> 'array' then
        r := jsonb_build_object('n', 0, 'code', 'invalid',
                                'err', format('%s must be a JSON array of entities, got a JSON %s', p_arg, jsonb_typeof(p_entities)));
    elsif jsonb_array_length(p_entities) > p_max then
        perform permissions._cedar_error('limit_exceeded',
            format('too many entities in %s: %s (the limit is %s)', p_arg, jsonb_array_length(p_entities), p_max),
            hint => format('An argument holds at most %s entities: put them in batches.', p_max),
            p_detail => format('limit=%L', p_limit));
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
    perform permissions._cedar_error(case r ->> 'code' when 'limit' then 'limit_exceeded' else 'invalid_entity' end,
        format('invalid entity at index %s of %s: %s', r ->> 'n', p_arg, r ->> 'err'),
        hint => case r ->> 'code'
            when 'limit' then format('Sets and records in attributes and tags nest at most %s levels.',
                                     (permissions._cedar_limits()).value_depth)
            when 'extension' then 'Write an extension value as {"__extn": {"fn": "decimal", "arg": "12.34"}}, with fn one of decimal, ip, datetime and duration and an arg its constructor accepts: decimal("12.34"), ip("10.0.0.0/8"), datetime("2024-10-15T11:35:00Z"), duration("1h30m").'
            else 'Each entity is {"uid": {"type": "User", "id": "alice"}, "attrs": {...}, "parents": [{"type": "Group", "id": "staff"}], "tags": {...}}; write an entity reference in an attribute as {"__entity": {"type": "User", "id": "alice"}}.' end,
        p_detail => case r ->> 'code' when 'limit' then format('limit=''value_depth'' index=%s', r ->> 'n')
                                      else format('index=%s', r ->> 'n') end);
end;
$$;

-- A Cedar JSON value as an EST expression: each {"__extn": {"fn", "arg"}} a
-- call of fn, each set a Set and each record a Record. The compiler uses it
-- for a Value with an extension value that Cedar would fail to build, so the
-- error happens when the call is evaluated, as in Cedar.
create function permissions._cedar_value_expr(v jsonb)
returns jsonb
language plpgsql immutable
as $$
begin
    return case
        when jsonb_typeof(v) = 'array' then
            jsonb_build_object('Set', coalesce((select jsonb_agg(permissions._cedar_value_expr(e) order by o)
                                                from jsonb_array_elements(v) with ordinality t(e, o)), '[]'))
        when jsonb_typeof(v) <> 'object' or v ? '__entity' then jsonb_build_object('Value', v)
        when v ? '__extn' and jsonb_typeof(v -> '__extn') = 'object' and jsonb_typeof(v -> '__extn' -> 'fn') = 'string' then
            jsonb_build_object(v -> '__extn' ->> 'fn',
                               coalesce((select jsonb_agg(permissions._cedar_value_expr(e) order by o)
                                         from jsonb_array_elements(case when v -> '__extn' ? 'arg' then jsonb_build_array(v -> '__extn' -> 'arg')
                                                                        else v -> '__extn' -> 'args' end) with ordinality t(e, o)), '[]'))
        else jsonb_build_object('Record', coalesce((select jsonb_object_agg(e.key, permissions._cedar_value_expr(e.value)) from jsonb_each(v) e), '{}'))
    end;
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
--   {"k":"call","f":"name","a":[x,...]}  an extension function or method (receiver first);
--                                      a constructor of a valid string literal is a lit
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
    asts jsonb[];                   -- the compiled elements, joined once
    keys text[];
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
        if v.code = 'extension' then
            -- an extension value Cedar would fail to build: as in Cedar, a
            -- call that errs when it is evaluated
            return permissions._cedar_compile(permissions._cedar_value_expr(a), p_path, p_depth);
        elsif v.code is not null then
            return jsonb_build_object('code', case v.code when 'limit' then 'limit_exceeded' else 'invalid_policy' end,
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
        -- Cedar allows slots in the scope only (SlotsInConditionClause).
        return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                  'err', format('a slot (%s) can appear only in the principal or resource scope of a template, not in a condition', a),
                                  'hint', 'Constrain the slot in the scope (principal == ?principal, resource in ?resource) and compare principal or resource in the condition.');
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
        pat := coalesce((select string_agg(case when t = '"Wildcard"' then '%'
                                                else regexp_replace(t ->> 'Literal', '([\\%_])', '\\\1', 'g') end, '' order by o)
                         from jsonb_array_elements(a -> 'pattern') with ordinality p(t, o)), '');
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
        for i in 0 .. jsonb_array_length(a) - 1 loop
            x := permissions._cedar_compile(a -> i, p_path || '[' || i || ']', p_depth + 1);
            if x ? 'code' then return x; end if;
            asts[i + 1] := x -> 'ast';
            n := n + (x ->> 'n')::int;
            lits := lits and x -> 'ast' ->> 'k' = 'lit';
        end loop;
        acc := coalesce(to_jsonb(asts), '[]');
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
        i := 0;
        for kv in select * from jsonb_each(a) loop
            x := permissions._cedar_compile(kv.value, p_path || '.' || kv.key, p_depth + 1);
            if x ? 'code' then return x; end if;
            i := i + 1;
            keys[i] := kv.key;
            asts[i] := x -> 'ast';
            n := n + (x ->> 'n')::int;
            lits := lits and x -> 'ast' ->> 'k' = 'lit';
        end loop;
        acc := coalesce((select jsonb_object_agg(u.k, u.w) from unnest(keys, asts) u(k, w)), '{}');
        if lits then
            return jsonb_build_object('ast', jsonb_build_object('k', 'lit', 'v',
                                          coalesce((select jsonb_object_agg(t.key, t.value -> 'v') from jsonb_each(acc) t), '{}')),
                                      'n', n);
        end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'rec', 'a', acc), 'n', n);
    elsif jsonb_typeof(a) = 'array' then
        -- an extension function or method: {"name": [receiver, args...]}
        if not permissions._cedar_extensions() ? op then
            return jsonb_build_object('code', 'invalid_policy', 'path', p_path,
                                      'err', format('unknown extension function ''%s''', op),
                                      'hint', permissions._did_you_mean(op, array(select jsonb_object_keys(permissions._cedar_extensions())),
                                                                        'Extension functions'));
        end if;
        for i in 0 .. jsonb_array_length(a) - 1 loop
            x := permissions._cedar_compile(a -> i, p_path || '[' || i || ']', p_depth + 1);
            if x ? 'code' then return x; end if;
            asts[i + 1] := x -> 'ast';
            n := n + (x ->> 'n')::int;
        end loop;
        acc := coalesce(to_jsonb(asts), '[]');
        -- A constructor of a valid string literal is folded into its value.
        -- Cedar checks the string only when it evaluates the call, so an
        -- invalid one stays a call and errs then (the arity, too).
        if op in ('decimal', 'ip', 'datetime', 'duration') and jsonb_array_length(acc) = 1
           and acc #>> '{0,k}' = 'lit' and jsonb_typeof(acc #> '{0,v}') = 'string' then
            y := permissions._cedar_extn(op, acc #>> '{0,v}');
            if y is not null then
                return jsonb_build_object('ast', jsonb_build_object('k', 'lit', 'v', y), 'n', n);
            end if;
        end if;
        return jsonb_build_object('ast', jsonb_build_object('k', 'call', 'f', op, 'a', acc), 'n', n);
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
-- resource. For a template (p_template), the principal and resource scopes
-- may hold their slot instead of an entity: {"op": "==" or "in", "slot":
-- "?principal"}, or "in": {"slot": ...} under "is". The result then has
-- "slot" instead of "uid"; a link fills it (_cedar_link).
create function permissions._cedar_compile_scope(s jsonb, p_var text, p_template boolean default false)
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
        e := coalesce(s -> 'slot', s -> 'in' -> 'slot');
        if not p_template then
            return jsonb_build_object('code', 'invalid_policy', 'path', path,
                                      'err', format('a static policy has no slots, and the %s scope has %s', p_var, e),
                                      'hint', 'A policy with slots is a template: put it with cedar_put_template(template_id => ..., template => ...), then fill the slots with cedar_link_template.');
        end if;
        if act or e is distinct from to_jsonb('?' || p_var) then
            return jsonb_build_object('code', 'invalid_policy', 'path', path,
                                      'err', format('the %s scope can hold only the slot %s, got %s', p_var,
                                                    case when act then 'none: templates have the slots ?principal and ?resource' else '?' || p_var end, e),
                                      'hint', 'A template has at most two slots: ?principal in the principal scope and ?resource in the resource scope.');
        end if;
        if op in ('==', 'in') and (select count(*) from jsonb_object_keys(s)) = 2 then
            return jsonb_build_object('op', op, 'slot', e);
        elsif op = 'is' and permissions._cedar_is_name(s ->> 'entity_type') and (select count(*) from jsonb_object_keys(s)) = 3
              and (select count(*) from jsonb_object_keys(s -> 'in')) = 1 then
            return jsonb_build_object('op', 'is', 'type', s ->> 'entity_type', 'slot', e);
        end if;
        return jsonb_build_object('code', 'invalid_policy', 'path', path,
                                  'err', format('the %s scope is {"op": "==" or "in", "slot": "?%s"} or {"op": "is", "entity_type": "T", "in": {"slot": "?%s"}}; got %s',
                                                p_var, p_var, p_var, left(s::text, 200)));
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
-- cedar:unsupported or cedar:limit_exceeded. p_template: a template, which
-- has a slot in its principal or resource scope or both (a static policy has
-- none). p_text: the EST came from Cedar text, whose size the parser already
-- checked (policy_bytes limits the text, not the larger EST).
create function permissions._cedar_compile_policy(p_est jsonb, p_id text, p_template boolean default false,
                                                  p_text boolean default false)
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
    if not p_text and octet_length(p_est::text) > lim.policy_bytes then
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
                x := permissions._cedar_compile_scope(p_est -> s, s, p_template);
                if x ? 'code' then
                    r := x;
                    exit;
                end if;
                res := res || jsonb_build_object(s, x);
            end loop;
            if r is null and p_template and not (res -> 'principal' ? 'slot' or res -> 'resource' ? 'slot') then
                r := jsonb_build_object('code', 'invalid_policy', 'path', '$',
                                        'err', 'a template has a slot (?principal or ?resource) in its scope, and this one has none',
                                        'hint', 'Put a policy without slots with cedar_put_policy, or write the template with a slot, for example permit (principal == ?principal, action, resource);');
            end if;
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
            format('invalid %s %L at %s: %s', case when p_template then 'template' else 'policy' end, p_id, r ->> 'path', r ->> 'err'),
            hint => coalesce(r ->> 'hint', case r ->> 'code'
                when 'limit_exceeded' then format('Split the policy into smaller policies: a policy holds at most %s bytes, %s expression nodes and %s levels of nesting.',
                                                  lim.policy_bytes, lim.policy_nodes, lim.policy_depth)
                when 'unsupported' then 'Partial evaluation (Unknown) is not supported, and a record literal cannot have the key __entity or __extn, which Cedar''s JSON reserves for entity and extension values.'
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
-- Cedar text: the policy parser (phase 3)
-- ----------------------------------------------------------------------------
-- Cedar policy text parses to Cedar's JSON policy format (the EST), exactly
-- as cedar-policy-cli 4.14.0 `translate-policy --direction cedar-to-json`
-- writes it, so text and JSON reach one compiler (_cedar_compile_policy) and
-- one evaluator. jsonb equality with the CLI's output is the oracle: every
-- text policy of the corpus (test/cedar/generate.py --parse-est), and the
-- stored EST after a text put (--check-est).
--
--   _cedar_parse_policy(src) returns jsonb
--     Exactly one policy or template: its EST object {"effect", "principal",
--     "action", "resource", "conditions", "annotations"?}. "annotations" is
--     present only when the policy has some. A template is a policy whose
--     principal or resource scope holds a slot ({"slot": "?principal"}, or
--     "in": {"slot": ...} under "is"); the caller (cedar_put_policy,
--     cedar_put_template) checks which one it wants. No policy, or more than
--     one, is a parse error.
--
--   _cedar_parse_policies(src) returns jsonb
--     A policy set (zero or more policies), in the CLI's policy-set shape:
--       {"staticPolicies": {id: EST, ...}, "templates": {id: EST, ...},
--        "templateLinks": []}
--     Policy ids follow the CLI: the value of an @id annotation when the
--     policy has one (a bare @id gives ""), else "policy<i>", where i counts
--     every policy and template of the text from 0 in source order. A
--     duplicate id is a parse error. No public function takes a policy set
--     (e-cedar.md section 13); the parser oracle checks this path.
--
-- Both return null for a null src. Errors raise through _cedar_error:
--   cedar:parse_error line=<n> column=<n>      SQLSTATE 42601
--   cedar:limit_exceeded limit='<name>'         SQLSTATE 54000
--   cedar:unsupported feature='U+0000'          SQLSTATE 0A000
-- with a MESSAGE that names the token found and what was expected, and a HINT
-- (test/spec/d/55_cedar_parse.sql checks them). The limits are those of
-- _cedar_limits: policy_bytes for the text of one policy, policy_nodes, and
-- policy_depth (the depth of the EST, and of brackets in the text).
--
-- CLI quirks the EST reproduces (and the compiler accepts):
--   - A negative integer literal folds into Value (-5 is {"Value": -5}); a
--     minus before anything else is neg. --5 is neg(Value -5).
--     -9223372036854775808 is valid only this way.
--   - action in [A] with one entity is {"op": "in", "entity": A}; with
--     zero or two or more it is {"op": "in", "entities": [...]}.
--   - e has a.b.c (several attributes) is {"has": {"left", "attr": ["a",
--     "b", "c"]}}: attr is an array. One attribute gives a string.
--   - like patterns are one {"Literal": "c"} per character, and "Wildcard"
--     for each *; a * written as an escape (\u{2a}, \x2a) is a wildcard too,
--     only \* is a literal star.
--   - A bare annotation @foo has the value null.
--   - !x applied n times nests n "!" nodes (no folding).

-- A token for an error message.
create function permissions._cedar_token_text(p_kind text, p_value text)
returns text
language sql
immutable
as $$
    select case p_kind
        when 'eof' then 'end of input'
        when 'str' then format('string literal "%s"', case when length(p_value) > 30 then left(p_value, 27) || '...' else p_value end)
        when 'int' then format('number %s', p_value)
        when 'id' then format('''%s''', p_value)
        when 'slot' then format('slot %s', p_value)
        else format('''%s''', p_kind) end
$$;

-- "unexpected <token> at line L, column C: expected <what>"
create function permissions._cedar_syntax_error(k text[], v text[], ln int[], cl int[], q int, p_expected text, hint text)
returns void
language plpgsql
as $$
begin
    perform permissions._cedar_error('parse_error',
        format('unexpected %s at line %s, column %s: expected %s',
               permissions._cedar_token_text(k[q], v[q]), ln[q], cl[q], p_expected),
        hint => coalesce(hint, 'Check the policy against the Cedar grammar: https://docs.cedarpolicy.com/policies/syntax-grammar.html'),
        p_detail => format('line=%s column=%s', ln[q], cl[q]));
end;
$$;

-- Any other parse error, at a position.
create function permissions._cedar_parse_fail(p_message text, p_line int, p_col int, hint text)
returns void
language plpgsql
as $$
begin
    perform permissions._cedar_error('parse_error', format('%s at line %s, column %s', p_message, p_line, p_col),
        hint => coalesce(hint, 'Check the policy against the Cedar grammar: https://docs.cedarpolicy.com/policies/syntax-grammar.html'),
        p_detail => format('line=%s column=%s', p_line, p_col));
end;
$$;

-- ----------------------------------------------------------------------------
-- Tokens
-- ----------------------------------------------------------------------------
-- One regular expression splits the whole text (the scan runs in C, and each
-- match is a token, white space or a comment; the last branch takes any other
-- character, so the matches cover the text). Kinds: id (identifiers and
-- keywords, v is the text), int (v is the digits), str (v is the body between
-- the quotes, still escaped: like patterns read the escapes differently),
-- slot (v is ?name), the punctuators themselves (:: == != <= >= && || ( ) [ ]
-- { } , ; . < > + - * ! : @), and eof (three of them, so a lookahead never
-- leaves the arrays). ln and cl are the line and column (1-based,
-- characters) of each token, off its character offset.
create function permissions._cedar_tokens(p_src text, out k text[], out v text[], out ln int[], out cl int[], out off int[])
language plpgsql
immutable strict
as $$
declare
    m text;
    c text;
    len int;
    nl int;
    line int := 1;
    col int := 1;
    o int := 1;
begin
    k := '{}'; v := '{}'; ln := '{}'; cl := '{}'; off := '{}';
    for m in
        select t[1]
        from regexp_matches(p_src,
            '\s+|//[^\n\r]*|"(?:[^"\\]|\\[^\n])*"|[A-Za-z_][A-Za-z0-9_]*|[0-9]+|\?[A-Za-z_][A-Za-z0-9_]*|::|==|!=|<=|>=|&&|\|\||[\s\S]',
            'g') t
    loop
        c := left(m, 1);
        len := length(m);
        if c ~ '\s' or left(m, 2) = '//' then
            null;
        elsif c = '"' then
            if len = 1 then
                perform permissions._cedar_parse_fail('unterminated string literal', line, col,
                    'Close the string with ". A backslash cannot continue a string on the next line; Cedar strings may contain the line break itself.');
            end if;
            k := k || 'str'::text; v := v || substr(m, 2, len - 2);
        elsif c ~ '[A-Za-z_]' then
            k := k || 'id'::text; v := v || m;
        elsif c ~ '[0-9]' then
            k := k || 'int'::text; v := v || m;
        elsif c = '?' and len > 1 then
            k := k || 'slot'::text; v := v || m;
        elsif m in ('::', '==', '!=', '<=', '>=', '&&', '||', '(', ')', '[', ']', '{', '}', ',', ';', '.', '<', '>', '+', '-', '*', '!', ':', '@') then
            k := k || m; v := v || m;
        else
            perform permissions._cedar_parse_fail(format('invalid character %L', m), line, col,
                case when m in ('=', '&', '|') then format('Cedar has no single %L operator: use %L.', m, m || m)
                     when m = '''' then 'Cedar strings use double quotes: "text".'
                     else 'Outside string literals Cedar uses ASCII letters, digits, _ and its operators. Put other text in a string literal ("...").' end);
        end if;
        if c !~ '\s' and left(m, 2) <> '//' then
            ln := ln || line; cl := cl || col; off := off || o;
        end if;
        nl := len - length(replace(m, E'\n', ''));
        if nl > 0 then
            line := line + nl;
            col := strpos(reverse(m), E'\n');
        else
            col := col + len;
        end if;
        o := o + len;
    end loop;
    k := k || '{eof,eof,eof}'::text[]; v := v || '{"","",""}'::text[];
    ln := ln || array[line, line, line]; cl := cl || array[col, col, col]; off := off || array[o, o, o];
end;
$$;

-- ----------------------------------------------------------------------------
-- String literals
-- ----------------------------------------------------------------------------
-- Cedar reads escapes as Rust does (rustc_lexer): \n \r \t \\ \0 \' \", \xHH
-- up to \x7f, and \u{H...} with 1 to 6 hex digits (underscores allowed, not
-- first), no surrogates, at most 10FFFF. A bare carriage return is an error.
-- U+0000 cannot be held by Postgres text: cedar:unsupported.
--
-- p_pattern false: the decoded text, as a jsonb string.
-- p_pattern true: a like pattern, a jsonb array of "Wildcard" for each * and
-- {"Literal": c} for every other character. \* is a literal star, and a star
-- from any other escape (\u{2a}) is a wildcard, as in Cedar.
create function permissions._cedar_unescape(p_raw text, p_pattern boolean, p_line int, p_col int)
returns jsonb
language plpgsql
immutable
as $$
declare
    m text;
    e text;
    h text;
    cp int;
    ch text;
    n int := 0;
    parts text[] := '{}';           -- the decoded text, one piece per token
    stars boolean[] := '{}';        -- in a pattern: the piece is \*, a literal star
    bad text;
begin
    if strpos(p_raw, '\') = 0 and strpos(p_raw, E'\r') = 0 then
        if not p_pattern then
            return to_jsonb(p_raw);
        end if;
        if p_raw = '' then
            return '[]';
        end if;
        return (select coalesce(jsonb_agg(case when c = '*' then '"Wildcard"'::jsonb else jsonb_build_object('Literal', c) end order by o), '[]')
                from regexp_split_to_table(p_raw, '') with ordinality t(c, o));
    end if;
    for m in
        select t[1] from regexp_matches(p_raw, '[^\\\r]+|\\u\{[0-9A-Fa-f_]*\}|\\x[0-9A-Fa-f]{2}|\\[\s\S]?|\r', 'g') t
    loop
        if left(m, 1) <> '\' and m <> E'\r' then
            n := n + 1;
            parts[n] := m;
            stars[n] := false;
            continue;
        end if;
        e := substr(m, 2, 1);
        ch := null;
        bad := null;
        if m = E'\r' then
            bad := 'a bare carriage return';
        elsif e in ('n', 'r', 't', '\', '"', '''') then
            ch := case e when 'n' then E'\n' when 'r' then E'\r' when 't' then E'\t' else e end;
        elsif e = '0' then
            cp := 0;
        elsif e = '*' and p_pattern then
            n := n + 1;
            parts[n] := '*';
            stars[n] := true;
            continue;
        elsif e = 'x' and length(m) = 4 then
            cp := ('x' || lpad(substr(m, 3), 8, '0'))::bit(32)::int;
            if cp > 127 then
                bad := m;
            end if;
        elsif e = 'u' and length(m) > 3 then
            h := substr(m, 4, length(m) - 4);
            if left(h, 1) = '_' or replace(h, '_', '') = '' or length(replace(h, '_', '')) > 6 then
                bad := m;
            else
                cp := ('x' || lpad(replace(h, '_', ''), 8, '0'))::bit(32)::int;
                if cp > 1114111 or cp between 55296 and 57343 then
                    bad := m;
                end if;
            end if;
        else
            bad := m;
        end if;
        if bad is not null then
            perform permissions._cedar_parse_fail(
                case when left(bad, 1) = '\' then format('invalid escape %s in a string literal', bad)
                     else format('%s in a string literal', bad) end, p_line, p_col,
                case when bad = '\*' then 'Only a like pattern can escape a star (\*). In other strings write * as it is.'
                     when bad = 'a bare carriage return' then 'Write a carriage return in a string as \r.'
                     else 'The escapes are \n, \r, \t, \\, \0, \'', \", \x00 to \x7f, and \u{...} with 1 to 6 hex digits (a Unicode scalar value).' end);
        end if;
        if ch is null then
            if cp = 0 then
                perform permissions._cedar_error('unsupported',
                    format('a string literal at line %s, column %s contains U+0000, which Postgres text cannot hold', p_line, p_col),
                    hint => 'Remove the U+0000 character (\0, \x00 or \u{0}) from the string.',
                    p_detail => 'feature=''U+0000''');
            end if;
            ch := chr(cp);
        end if;
        n := n + 1;
        parts[n] := ch;
        stars[n] := false;
    end loop;
    -- joined once: appending to a jsonb or a text in the loop copies it
    -- each time (quadratic in the length)
    if p_pattern then
        return (select coalesce(jsonb_agg(case when p.star then '{"Literal": "*"}'::jsonb when x.c = '*' then '"Wildcard"'::jsonb
                                               else jsonb_build_object('Literal', x.c) end order by p.o, x.o), '[]')
                from unnest(parts, stars) with ordinality p(t, star, o)
                cross join lateral regexp_split_to_table(p.t, '') with ordinality x(c, o));
    end if;
    return to_jsonb(array_to_string(parts, ''));
end;
$$;

-- ----------------------------------------------------------------------------
-- Expressions
-- ----------------------------------------------------------------------------
--   Expr     = "if" Expr "then" Expr "else" Expr | Or
--   Or       = And { "||" And }                                   prec 1
--   And      = Relation { "&&" Relation }                         prec 2
--   Relation = Add [ RelOp Add ] | Add "has" (Ident {"." Ident} | Str)
--            | Add "like" Str | Add "is" Path [ "in" Add ]       prec 3, one per operand
--   RelOp    = "<" | "<=" | ">" | ">=" | "==" | "!=" | "in"
--   Add      = Mult { ("+" | "-") Mult }                          prec 4
--   Mult     = Unary { "*" Unary }                                prec 5
--   Unary    = ("!" | "-"){0,4} Member      (one kind of operator per run)
--   Member   = Primary { "." Ident [ "(" [Exprs] ")" ] | "[" Str "]" }
--   Primary  = Int | Str | "true" | "false" | Var | Path "::" Str
--            | Path "(" [Exprs] ")" | "(" Expr ")" | "[" [Exprs] "]"
--            | "{" [ (Ident | Str) ":" Expr {"," ...} ] "}"
-- (lists may end with a comma). One function: the binary operators are
-- reduced with an operator stack (precedence climbing without one call per
-- level), and the function calls itself only for a nested expression, so the
-- PL/pgSQL recursion is about the bracket nesting of the text. minprec 4
-- parses an Add (the right side of "is ... in"). lvl is the bracket nesting.
-- Returns the EST node, the next token, the node's depth and its node count.
create function permissions._cedar_parse_expr(k text[], v text[], ln int[], cl int[], p int, lvl int, minprec int,
                                              out node jsonb, out np int, out dep int, out cnt int)
language plpgsql
immutable
as $$
declare
    q int := p;
    r record;
    nodes jsonb[] := '{}';
    deps int[] := '{}';
    nn int := 0;
    ops text[] := '{}';
    opp int[] := '{}';
    no int := 0;
    relq int := 0;
    x jsonb;
    xd int;
    y jsonb;
    a jsonb;
    an int;                         -- the elements of a literal or call: avals[1:an]
    avals jsonb[];
    akeys text[];                   -- a record's keys (a has path's names)
    akq int[];                      -- and the token of each key
    dup int;
    ad int;
    op text;
    pr int;
    unop text;
    unn int;
    unq int;
    name text;
    nq int;
    key text;
    ty text;
    seg text;
    lit numeric;
    reserved constant text[] := '{true,false,if,then,else,in,is,like,has,__cedar}';
    vars constant text[] := '{principal,action,resource,context}';
    ext_fns constant text[] := '{decimal,ip,datetime,duration}';
    ext_methods constant text[] := '{lessThan,lessThanOrEqual,greaterThan,greaterThanOrEqual,isIpv4,isIpv6,isLoopback,isMulticast,isInRange,offset,durationSince,toDate,toTime,toDays,toHours,toMinutes,toSeconds,toMilliseconds}';
    bin_methods constant text[] := '{contains,containsAll,containsAny,getTag,hasTag}';
    reserved_hint constant text := 'true, false, if, then, else, in, is, like, has and __cedar are reserved. Use a string instead: e["if"], e has "if", {"if": 1}.';
begin
    cnt := 0;
    if lvl > (permissions._cedar_limits()).policy_depth then
        perform permissions._cedar_error('limit_exceeded',
            format('the expression at line %s, column %s is nested more than %s levels deep', ln[p], cl[p], (permissions._cedar_limits()).policy_depth),
            hint => 'Split the condition into simpler parts, for example several when clauses.',
            p_detail => 'limit=''policy_depth''');
    end if;

    if minprec = 0 and k[q] = 'id' and v[q] = 'if' then
        r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 0);
        x := r.node; xd := r.dep; cnt := r.cnt; q := r.np;
        if k[q] <> 'id' or v[q] <> 'then' then
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''then''', 'An if expression is: if <condition> then <value> else <value>.');
        end if;
        r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 0);
        y := r.node; xd := greatest(xd, r.dep); cnt := cnt + r.cnt; q := r.np;
        if k[q] <> 'id' or v[q] <> 'else' then
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''else''', 'An if expression is: if <condition> then <value> else <value>. The else branch is required.');
        end if;
        r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 0);
        node := jsonb_build_object('if-then-else', jsonb_build_object('if', x, 'then', y, 'else', r.node));
        dep := 1 + greatest(xd, r.dep); cnt := cnt + r.cnt + 1; np := r.np;
        return;
    end if;

    <<operands>>
    loop
        -- unary operators: a run of one kind, at most 4
        unop := null; unn := 0; unq := q;
        if k[q] in ('!', '-') then
            unop := k[q];
            while k[q] = unop loop
                unn := unn + 1;
                q := q + 1;
            end loop;
            if unn > 4 then
                perform permissions._cedar_parse_fail(format('too many occurrences of ''%s'' (%s)', unop, unn), ln[unq], cl[unq],
                    'Cedar allows at most 4 unary operators in a row. Use parentheses, or remove pairs that cancel.');
            end if;
            if k[q] in ('!', '-') then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an expression',
                    format('Put the operand of ''%s'' in parentheses: %s(%s...).', unop, unop, k[q]));
            end if;
        end if;

        -- primary
        if k[q] = 'int' then
            lit := v[q]::numeric;
            if unop = '-' and k[q + 1] not in ('.', '[') then
                lit := -lit;                    -- a negative literal: Cedar folds the minus
                unn := unn - 1;
            end if;
            if lit > 9223372036854775807 or lit < -9223372036854775808 then
                perform permissions._cedar_parse_fail(format('integer literal %s is too large', v[q]), ln[q], cl[q],
                    'A Cedar Long is from -9223372036854775808 to 9223372036854775807.');
            end if;
            x := jsonb_build_object('Value', lit);
            xd := 1; cnt := cnt + 1; q := q + 1;
        elsif k[q] = 'str' then
            x := jsonb_build_object('Value', permissions._cedar_unescape(v[q], false, ln[q], cl[q]));
            xd := 1; cnt := cnt + 1; q := q + 1;
        elsif k[q] = '(' then
            r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 0);
            x := r.node; xd := r.dep; cnt := cnt + r.cnt; q := r.np;
            if k[q] <> ')' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''')'' or an operator', null);
            end if;
            q := q + 1;
        elsif k[q] in ('[', '{') then
            op := k[q];
            an := 0; avals := '{}'; akeys := '{}'; akq := '{}';
            ad := 0;
            seg := case op when '[' then ']' else '}' end;
            q := q + 1;
            while k[q] <> seg loop
                if op = '{' then
                    if k[q] = 'id' then
                        key := v[q];
                        if key = any (reserved) then
                            perform permissions._cedar_parse_fail(format('this identifier is reserved and cannot be a record key: %s', key), ln[q], cl[q], reserved_hint);
                        end if;
                    elsif k[q] = 'str' then
                        key := permissions._cedar_unescape(v[q], false, ln[q], cl[q]) #>> '{}';
                    else
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'a record key (an identifier or a string literal)', null);
                    end if;
                    if k[q + 1] <> ':' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, ''':''', 'A record literal is {key: value, ...}.');
                    end if;
                    an := an + 1; akeys[an] := key; akq[an] := q;
                    r := permissions._cedar_parse_expr(k, v, ln, cl, q + 2, lvl + 1, 0);
                    avals[an] := r.node;
                else
                    r := permissions._cedar_parse_expr(k, v, ln, cl, q, lvl + 1, 0);
                    an := an + 1; avals[an] := r.node;
                end if;
                ad := greatest(ad, r.dep); cnt := cnt + r.cnt; q := r.np;
                if k[q] = ',' then
                    q := q + 1;
                elsif k[q] <> seg then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q, format(''','' or ''%s''', seg), null);
                end if;
            end loop;
            -- the elements are joined once (a jsonb grown in the loop is
            -- copied each time); a repeated key is found once, here
            if op = '{' then
                select u.i into dup
                from (select u.i, row_number() over (partition by u.k order by u.i) as n
                      from unnest(akeys collate "C") with ordinality u(k, i)) u
                where u.n = 2 order by u.i limit 1;
                if dup is not null then
                    perform permissions._cedar_parse_fail(format('duplicate key %L in a record literal', akeys[dup]), ln[akq[dup]], cl[akq[dup]],
                        'Each key of a record literal must be different.');
                end if;
                a := coalesce((select jsonb_object_agg(u.k, u.w) from unnest(akeys, avals) u(k, w)), '{}');
            else
                a := to_jsonb(avals);
            end if;
            x := jsonb_build_object(case op when '[' then 'Set' else 'Record' end, a);
            xd := ad + 1; cnt := cnt + 1; q := q + 1;
        elsif k[q] = 'slot' then
            perform permissions._cedar_parse_fail(format('found template slot %s in a condition', v[q]), ln[q], cl[q],
                'Slots (?principal, ?resource) can appear only in the policy scope, not in when or unless clauses.');
        elsif k[q] = 'id' and v[q] in ('true', 'false') then
            x := jsonb_build_object('Value', v[q] = 'true');
            xd := 1; cnt := cnt + 1; q := q + 1;
        elsif k[q] = 'id' and v[q] in ('if', 'then', 'else', 'in', 'is', 'like', 'has') then
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an expression',
                case when v[q] = 'if' then 'Put an if expression in parentheses here: (if c then a else b).' end);
        elsif k[q] = 'id' then
            nq := q;
            name := v[q];
            q := q + 1;
            while k[q] = '::' and k[q + 1] = 'id' loop
                name := name || '::' || v[q + 1];
                q := q + 2;
            end loop;
            if k[q] = '::' or k[q] = '(' or nq + 1 < q then
                foreach seg in array string_to_array(name, '::') loop
                    if seg = any (reserved) then
                        perform permissions._cedar_parse_fail(
                            case when seg = '__cedar' then format('the name %s contains __cedar, which is reserved', name)
                                 else format('this identifier is reserved and cannot be used in a name: %s', seg) end,
                            ln[nq], cl[nq], 'Rename the entity type or namespace.');
                    end if;
                end loop;
            end if;
            if k[q] = '::' and k[q + 1] = 'str' then
                x := jsonb_build_object('Value', jsonb_build_object('__entity',
                        jsonb_build_object('type', name, 'id', permissions._cedar_unescape(v[q + 1], false, ln[q + 1], cl[q + 1]))));
                xd := 1; cnt := cnt + 1; q := q + 2;
            elsif k[q] = '::' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'an identifier or a quoted entity id',
                    'An entity is written Type::"id", for example User::"alice".');
            elsif k[q] = '(' then
                if name = any (vars) then
                    perform permissions._cedar_parse_fail(format('%s(...) is not a valid function call', name), ln[nq], cl[nq],
                        'Variables cannot be called as functions.');
                elsif name = any (ext_methods || bin_methods || '{isEmpty}'::text[]) then
                    perform permissions._cedar_parse_fail(format('%s is a method, not a function', name), ln[nq], cl[nq],
                        format('Use a method call: e.%s(...).', name));
                elsif name <> all (ext_fns) then
                    perform permissions._cedar_parse_fail(format('%s is not a valid function', name), ln[nq], cl[nq],
                        permissions._did_you_mean(name, ext_fns, 'The extension functions are'));
                end if;
                an := 0; avals := '{}'; ad := 0;
                q := q + 1;
                while k[q] <> ')' loop
                    r := permissions._cedar_parse_expr(k, v, ln, cl, q, lvl + 1, 0);
                    an := an + 1; avals[an] := r.node;
                    ad := greatest(ad, r.dep); cnt := cnt + r.cnt; q := r.np;
                    if k[q] = ',' then
                        q := q + 1;
                    elsif k[q] <> ')' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''','' or '')''', null);
                    end if;
                end loop;
                x := jsonb_build_object(name, to_jsonb(avals));
                xd := ad + 1; cnt := cnt + 1; q := q + 1;
            elsif nq + 1 = q and name = any (vars) then
                x := jsonb_build_object('Var', name);
                xd := 1; cnt := cnt + 1;
            else
                perform permissions._cedar_parse_fail(format('invalid variable: %s', name), ln[nq], cl[nq],
                    coalesce(permissions._did_you_mean(name, vars, 'The Cedar variables are') || ' ', '')
                    || format('For a string write "%s"; for an entity write %s::"id".', name, name));
            end if;
        else
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an expression', null);
        end if;

        -- member access and method calls
        loop
            if k[q] = '.' then
                if k[q + 1] <> 'id' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'an attribute or method name', null);
                end if;
                name := v[q + 1];
                if name = any (reserved) then
                    perform permissions._cedar_parse_fail(
                        case when name = '__cedar' then 'the name __cedar is reserved'
                             else format('this identifier is reserved and cannot be used: %s', name) end,
                        ln[q + 1], cl[q + 1], reserved_hint);
                end if;
                if k[q + 2] = '(' then
                    nq := q + 1;
                    an := 0; avals := '{}'; ad := 0;
                    q := q + 3;
                    while k[q] <> ')' loop
                        r := permissions._cedar_parse_expr(k, v, ln, cl, q, lvl + 1, 0);
                        an := an + 1; avals[an] := r.node;
                        ad := greatest(ad, r.dep); cnt := cnt + r.cnt; q := r.np;
                        if k[q] = ',' then
                            q := q + 1;
                        elsif k[q] <> ')' then
                            perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''','' or '')''', null);
                        end if;
                    end loop;
                    a := to_jsonb(avals);
                    q := q + 1;
                    if name = any (bin_methods) or name = 'isEmpty' then
                        if jsonb_array_length(a) <> (case when name = 'isEmpty' then 0 else 1 end) then
                            perform permissions._cedar_parse_fail(
                                format('call to %s requires exactly %s, but got %s', name,
                                       case when name = 'isEmpty' then '0 arguments' else '1 argument' end,
                                       jsonb_array_length(a) || case when jsonb_array_length(a) = 1 then ' argument' else ' arguments' end),
                                ln[nq], cl[nq],
                                case when name = 'isEmpty' then 'Write s.isEmpty().' else format('Write e.%s(x) with one argument.', name) end);
                        end if;
                        x := case when name = 'isEmpty' then jsonb_build_object(name, jsonb_build_object('arg', x))
                                  else jsonb_build_object(name, jsonb_build_object('left', x, 'right', a -> 0)) end;
                    elsif name = any (ext_methods) then
                        x := jsonb_build_object(name, jsonb_build_array(x) || a);
                    elsif name = any (ext_fns) then
                        perform permissions._cedar_parse_fail(format('%s is a function, not a method', name), ln[nq], cl[nq],
                            format('Use a function call: %s(...).', name));
                    else
                        perform permissions._cedar_parse_fail(format('%s is not a valid method', name), ln[nq], cl[nq],
                            permissions._did_you_mean(name, bin_methods || ext_methods || '{isEmpty}'::text[], 'The methods are'));
                    end if;
                    xd := 1 + greatest(xd, ad); cnt := cnt + 1;
                else
                    x := jsonb_build_object('.', jsonb_build_object('left', x, 'attr', name));
                    xd := xd + 1; cnt := cnt + 1; q := q + 2;
                end if;
            elsif k[q] = '[' then
                if k[q + 1] <> 'str' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'a string literal',
                        'Only an attribute name in a string literal can follow [ : e["name"].');
                end if;
                if k[q + 2] <> ']' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 2, ''']''', null);
                end if;
                x := jsonb_build_object('.', jsonb_build_object('left', x, 'attr', permissions._cedar_unescape(v[q + 1], false, ln[q + 1], cl[q + 1])));
                xd := xd + 1; cnt := cnt + 1; q := q + 3;
            elsif k[q] = '(' then
                perform permissions._cedar_parse_fail('function calls must be of the form name(arg1, arg2, ...)', ln[q], cl[q],
                    'Only extension functions (decimal, ip, datetime, duration) and methods (e.name(...)) can be called.');
            else
                exit;
            end if;
        end loop;

        for i in 1..unn loop
            x := jsonb_build_object(case unop when '!' then '!' else 'neg' end, jsonb_build_object('arg', x));
            xd := xd + 1; cnt := cnt + 1;
        end loop;
        nn := nn + 1; nodes[nn] := x; deps[nn] := xd;

        -- binary operators, and the has / like / is relations
        <<binops>>
        loop
            op := null; pr := null;
            if k[q] = '||' then op := '||'; pr := 1;
            elsif k[q] = '&&' then op := '&&'; pr := 2;
            elsif k[q] in ('<', '<=', '>', '>=', '==', '!=') then op := k[q]; pr := 3;
            elsif k[q] = 'id' and v[q] in ('in', 'has', 'like', 'is') then op := v[q]; pr := 3;
            elsif k[q] in ('+', '-') then op := k[q]; pr := 4;
            elsif k[q] = '*' then op := '*'; pr := 5;
            end if;
            if pr is null or pr < minprec then
                exit operands;
            end if;
            while no > 0 and (opp[no] > pr or (opp[no] = pr and pr <> 3)) loop
                nodes[nn - 1] := jsonb_build_object(ops[no], jsonb_build_object('left', nodes[nn - 1], 'right', nodes[nn]));
                deps[nn - 1] := 1 + greatest(deps[nn - 1], deps[nn]);
                nn := nn - 1; no := no - 1; cnt := cnt + 1;
            end loop;
            if pr = 3 then
                if relq > 0 then
                    perform permissions._cedar_parse_fail(
                        format('multiple relational operators (%s at line %s, column %s, then %s)', v[relq], ln[relq], cl[relq], v[q]),
                        ln[q], cl[q], 'Use parentheses to make the order explicit, for example (a == b) == c.');
                end if;
                relq := q;
            elsif pr < 3 then
                relq := 0;
            end if;
            if op in ('has', 'like', 'is') then
                x := nodes[nn]; xd := deps[nn];
                nq := q;
                q := q + 1;
                if op = 'has' then
                    if k[q] = 'str' then
                        x := jsonb_build_object('has', jsonb_build_object('left', x, 'attr', permissions._cedar_unescape(v[q], false, ln[q], cl[q])));
                        q := q + 1;
                    elsif k[q] = 'id' then
                        an := 0; akeys := '{}';
                        loop
                            if v[q] = any (reserved) then
                                perform permissions._cedar_parse_fail(
                                    case when v[q] = '__cedar' then 'the name __cedar is reserved'
                                         else format('this identifier is reserved and cannot be used: %s', v[q]) end,
                                    ln[q], cl[q], reserved_hint);
                            end if;
                            an := an + 1; akeys[an] := v[q];
                            q := q + 1;
                            exit when k[q] <> '.' or k[q + 1] <> 'id';
                            q := q + 1;
                        end loop;
                        a := to_jsonb(akeys);
                        x := jsonb_build_object('has', jsonb_build_object('left', x,
                                'attr', case when jsonb_array_length(a) = 1 then a -> 0 else a end));
                    else
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an attribute name (identifiers separated by ''.'', or a string literal)', null);
                    end if;
                elsif op = 'like' then
                    if k[q] <> 'str' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'a pattern string literal',
                            'The right side of like is a string literal, where * matches any text and \* is a literal star.');
                    end if;
                    x := jsonb_build_object('like', jsonb_build_object('left', x, 'pattern', permissions._cedar_unescape(v[q], true, ln[q], cl[q])));
                    q := q + 1;
                else
                    if k[q] <> 'id' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an entity type name',
                            case when k[q] = 'str' then format('Remove the quotes: is %s.', v[q]) end);
                    end if;
                    ty := v[q];
                    nq := q;
                    q := q + 1;
                    while k[q] = '::' and k[q + 1] = 'id' loop
                        ty := ty || '::' || v[q + 1];
                        q := q + 2;
                    end loop;
                    foreach seg in array string_to_array(ty, '::') loop
                        if seg = any (reserved) then
                            perform permissions._cedar_parse_fail(format('this identifier is reserved and cannot be used in a type name: %s', seg),
                                ln[nq], cl[nq], 'Rename the entity type or namespace.');
                        end if;
                    end loop;
                    if k[q] = '::' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''in'', an operator or the end of the expression',
                            'The right side of is is an entity type, such as User or App::User, not an entity.');
                    end if;
                    if k[q] = 'id' and v[q] = 'in' then
                        r := permissions._cedar_parse_expr(k, v, ln, cl, q + 1, lvl + 1, 4);
                        x := jsonb_build_object('is', jsonb_build_object('left', x, 'entity_type', ty, 'in', r.node));
                        xd := greatest(xd, r.dep); cnt := cnt + r.cnt; q := r.np;
                    else
                        x := jsonb_build_object('is', jsonb_build_object('left', x, 'entity_type', ty));
                    end if;
                end if;
                if k[q] in ('+', '-', '*', '.', '[', '(', '::') then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''&&'', ''||'' or the end of the expression',
                        format('The right side of %s must stand alone. Use parentheses around the whole %s expression.', op, op));
                end if;
                nodes[nn] := x; deps[nn] := xd + 1; cnt := cnt + 1;
                continue binops;
            end if;
            no := no + 1; ops[no] := op; opp[no] := pr;
            q := q + 1;
            exit binops;
        end loop;
    end loop;

    while no > 0 loop
        nodes[nn - 1] := jsonb_build_object(ops[no], jsonb_build_object('left', nodes[nn - 1], 'right', nodes[nn]));
        deps[nn - 1] := 1 + greatest(deps[nn - 1], deps[nn]);
        nn := nn - 1; no := no - 1; cnt := cnt + 1;
    end loop;
    node := nodes[1]; dep := deps[1]; np := q;
end;
$$;

-- ----------------------------------------------------------------------------
-- Policies
-- ----------------------------------------------------------------------------
-- An entity in the scope: Path "::" Str. Returns {"type", "id"} and the next
-- token. p_var names the scope variable for the messages.
create function permissions._cedar_parse_ref(k text[], v text[], ln int[], cl int[], p int, p_var text,
                                             out ent jsonb, out np int)
language plpgsql
immutable
as $$
declare
    q int := p;
    name text;
    seg text;
begin
    if k[q] = 'str' then
        perform permissions._cedar_parse_fail(format('expected an entity uid for %s, found a string literal', p_var), ln[q], cl[q],
            format('Include the entity type: %s::"%s".', case p_var when 'action' then 'Action' else 'User' end, v[q]));
    elsif k[q] = '[' then
        perform permissions._cedar_parse_fail(format('expected a single entity uid for %s, found a set', p_var), ln[q], cl[q],
            'Only the action scope takes a list, with in: action in [Action::"a", Action::"b"].');
    elsif k[q] <> 'id' then
        perform permissions._cedar_syntax_error(k, v, ln, cl, q, 'an entity uid (Type::"id")', null);
    end if;
    name := v[q];
    q := q + 1;
    while k[q] = '::' and k[q + 1] = 'id' loop
        name := name || '::' || v[q + 1];
        q := q + 2;
    end loop;
    if k[q] <> '::' or k[q + 1] <> 'str' then
        perform permissions._cedar_syntax_error(k, v, ln, cl, case when k[q] = '::' then q + 1 else q end,
            format('''::'' and a quoted entity id after %s', name),
            format('An entity is written Type::"id", for example %s::"alice".', name));
    end if;
    foreach seg in array string_to_array(name, '::') loop
        if seg in ('true', 'false', 'if', 'then', 'else', 'in', 'is', 'like', 'has', '__cedar') then
            perform permissions._cedar_parse_fail(format('this identifier is reserved and cannot be used in a type name: %s', seg),
                ln[p], cl[p], 'Rename the entity type or namespace.');
        end if;
    end loop;
    ent := jsonb_build_object('type', name, 'id', permissions._cedar_unescape(v[q + 1], false, ln[q + 1], cl[q + 1]));
    if p_var = 'action' and name <> 'Action' and name not like '%::Action' then
        perform permissions._cedar_parse_fail(format('expected an entity uid with type Action but got %s::"%s"', name, ent ->> 'id'),
            ln[p], cl[p], 'Action entities have the type Action, optionally in a namespace (App::Action).');
    end if;
    np := q + 2;
end;
$$;

-- The policies of a text. p_single: exactly one, returned as its EST; else
-- the policy-set object (see the top of this file).
create function permissions._cedar_parse_text(p_src text, p_single boolean)
returns jsonb
language plpgsql
immutable
as $$
declare
    t record;
    r record;
    k text[];
    v text[];
    ln int[];
    cl int[];
    off int[];
    q int := 1;
    n int := 0;
    start int;
    annos jsonb;
    pid text;
    eff text;
    scope jsonb;
    an int;                         -- avals[1:an]: annotation values, action uids, conditions
    avals jsonb[];
    anames text[];
    aq int[];
    dup int;
    est jsonb;
    is_template boolean;
    statics jsonb := '{}';
    templates jsonb := '{}';
    nodes int;
    sv text;
    ent jsonb;
    ents jsonb;
    ty text;
    nq int;
    kind text;
    scope_hint constant text := 'A policy scope lists principal, action and resource, in that order: permit (principal, action, resource);';
    lim record := permissions._cedar_limits();
begin
    if p_single and octet_length(p_src) > lim.policy_bytes then
        perform permissions._cedar_error('limit_exceeded',
            format('the policy text is %s bytes, more than the limit of %s', octet_length(p_src), lim.policy_bytes),
            hint => 'Split the policy into several smaller policies.',
            p_detail => 'limit=''policy_bytes''');
    end if;
    t := permissions._cedar_tokens(p_src);
    k := t.k; v := t.v; ln := t.ln; cl := t.cl; off := t.off;

    while k[q] <> 'eof' loop
        start := q;
        an := 0; anames := '{}'; avals := '{}'; aq := '{}';
        pid := null;
        nodes := 0;

        -- annotations
        while k[q] = '@' loop
            if k[q + 1] <> 'id' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'an annotation name', 'An annotation is @name("value") or @name.');
            end if;
            an := an + 1; anames[an] := v[q + 1]; aq[an] := q;
            if k[q + 2] = '(' then
                if k[q + 3] <> 'str' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 3, 'a string literal', 'An annotation is @name("value") or @name.');
                end if;
                if k[q + 4] <> ')' then
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q + 4, ''')''', 'An annotation is @name("value") or @name.');
                end if;
                avals[an] := permissions._cedar_unescape(v[q + 3], false, ln[q + 3], cl[q + 3]);
                q := q + 5;
            else
                avals[an] := 'null';
                q := q + 2;
            end if;
        end loop;
        -- joined once (a jsonb grown in the loop is copied each time), and
        -- a repeated name is found once, here
        select u.i into dup
        from (select u.i, row_number() over (partition by u.k order by u.i) as n
              from unnest(anames collate "C") with ordinality u(k, i)) u
        where u.n = 2 order by u.i limit 1;
        if dup is not null then
            perform permissions._cedar_parse_fail(format('duplicate annotation @%s', anames[dup]), ln[aq[dup]], cl[aq[dup]],
                'Each annotation name may appear once in a policy.');
        end if;
        annos := coalesce((select jsonb_object_agg(u.k, u.w) from unnest(anames, avals) u(k, w)), '{}');
        if annos ? 'id' then
            pid := coalesce(annos ->> 'id', '');
        end if;

        -- effect
        if k[q] <> 'id' or v[q] not in ('permit', 'forbid') then
            if k[q] = 'id' then
                perform permissions._cedar_parse_fail(format('invalid policy effect: %s', v[q]), ln[q], cl[q],
                    permissions._did_you_mean(v[q], '{permit,forbid}', 'A policy starts with'));
            end if;
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''permit'' or ''forbid''',
                'A policy is: [@annotations] permit|forbid (principal, action, resource) [when { ... }] [unless { ... }];');
        end if;
        eff := v[q];
        q := q + 1;
        if k[q] <> '(' then
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''(''', scope_hint);
        end if;
        q := q + 1;

        -- scope: principal, action, resource
        scope := '{}';
        is_template := false;
        foreach sv in array array['principal', 'action', 'resource'] loop
            if k[q] <> 'id' or v[q] <> sv then
                if k[q] = 'id' and v[q] in ('principal', 'action', 'resource', 'context') then
                    perform permissions._cedar_parse_fail(format('found the variable %s where the variable %s must be', v[q], sv), ln[q], cl[q], scope_hint);
                elsif k[q] = 'id' then
                    perform permissions._cedar_parse_fail(format('found %s where the variable %s must be', v[q], sv), ln[q], cl[q],
                        coalesce(permissions._did_you_mean(v[q], array[sv], 'The scope variable here is') || ' ', '') || scope_hint);
                elsif k[q] = ')' then
                    perform permissions._cedar_parse_fail(format('this policy is missing the %s variable in the scope', sv), ln[q], cl[q], scope_hint);
                end if;
                perform permissions._cedar_syntax_error(k, v, ln, cl, q, format('''%s''', sv), scope_hint);
            end if;
            nq := q;
            q := q + 1;
            if k[q] = ':' then
                perform permissions._cedar_parse_fail('type constraints using : are not supported', ln[q], cl[q],
                    format('Use is instead: %s is User.', sv));
            end if;
            if sv = 'action' then
                if k[q] = '==' then
                    if k[q + 1] = 'slot' then
                        perform permissions._cedar_parse_fail('the action scope cannot hold a slot', ln[q + 1], cl[q + 1],
                            'Templates have slots for the principal and the resource only.');
                    end if;
                    r := permissions._cedar_parse_ref(k, v, ln, cl, q + 1, sv);
                    scope := scope || jsonb_build_object('action', jsonb_build_object('op', '==', 'entity', r.ent));
                    q := r.np;
                elsif k[q] = 'id' and v[q] = 'in' then
                    if k[q + 1] = '[' then
                        an := 0; avals := '{}';
                        q := q + 2;
                        while k[q] <> ']' loop
                            r := permissions._cedar_parse_ref(k, v, ln, cl, q, sv);
                            an := an + 1; avals[an] := r.ent;
                            q := r.np;
                            if k[q] = ',' then
                                q := q + 1;
                            elsif k[q] <> ']' then
                                perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''','' or '']''', null);
                            end if;
                        end loop;
                        q := q + 1;
                        ents := to_jsonb(avals);
                        scope := scope || jsonb_build_object('action',
                            case when jsonb_array_length(ents) = 1 then jsonb_build_object('op', 'in', 'entity', ents -> 0)
                                 else jsonb_build_object('op', 'in', 'entities', ents) end);
                    else
                        if k[q + 1] = 'slot' then
                            perform permissions._cedar_parse_fail('the action scope cannot hold a slot', ln[q + 1], cl[q + 1],
                                'Templates have slots for the principal and the resource only.');
                        end if;
                        r := permissions._cedar_parse_ref(k, v, ln, cl, q + 1, sv);
                        scope := scope || jsonb_build_object('action', jsonb_build_object('op', 'in', 'entity', r.ent));
                        q := r.np;
                    end if;
                elsif k[q] = 'id' and v[q] = 'is' then
                    perform permissions._cedar_parse_fail('is cannot appear in the action scope', ln[q], cl[q],
                        'Move action is ... into a when condition.');
                else
                    scope := scope || '{"action": {"op": "All"}}';
                end if;
            else
                kind := null;
                if k[q] = 'id' and v[q] = 'is' then
                    if k[q + 1] <> 'id' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, 'an entity type name',
                            case when k[q + 1] = 'str' then format('Remove the quotes: is %s.', v[q + 1]) end);
                    end if;
                    ty := v[q + 1];
                    q := q + 2;
                    while k[q] = '::' and k[q + 1] = 'id' loop
                        ty := ty || '::' || v[q + 1];
                        q := q + 2;
                    end loop;
                    if ty ~ '(^|::)(true|false|if|then|else|in|is|like|has|__cedar)(::|$)' then
                        perform permissions._cedar_parse_fail(format('the type name %s uses a reserved identifier', ty), ln[nq], cl[nq],
                            'true, false, if, then, else, in, is, like, has and __cedar are reserved.');
                    end if;
                    if k[q] = '::' then
                        perform permissions._cedar_syntax_error(k, v, ln, cl, q, format('''in'', '','' or '')'' after the type %s', ty),
                            format('is takes an entity type; to name one entity use ==: %s == %s::"id".', sv, ty));
                    end if;
                    if k[q] = 'id' and v[q] = 'in' then
                        kind := 'is_in';
                        q := q + 1;
                    else
                        scope := scope || jsonb_build_object(sv, jsonb_build_object('op', 'is', 'entity_type', ty));
                    end if;
                elsif k[q] = '==' then
                    kind := '==';
                    q := q + 1;
                elsif k[q] = 'id' and v[q] = 'in' then
                    kind := 'in';
                    q := q + 1;
                else
                    scope := scope || jsonb_build_object(sv, '{"op": "All"}'::jsonb);
                end if;
                if kind is not null then
                    if k[q] = 'slot' then
                        if v[q] <> '?' || sv then
                            perform permissions._cedar_parse_fail(format('expected an entity uid or the slot ?%s, found %s', sv, v[q]), ln[q], cl[q],
                                format('The %s scope can hold only the slot ?%s.', sv, sv));
                        end if;
                        ent := jsonb_build_object('slot', v[q]);
                        is_template := true;
                        q := q + 1;
                    else
                        r := permissions._cedar_parse_ref(k, v, ln, cl, q, sv);
                        ent := jsonb_build_object('entity', r.ent);
                        q := r.np;
                    end if;
                    scope := scope || jsonb_build_object(sv,
                        case kind when 'is_in' then jsonb_build_object('op', 'is', 'entity_type', ty, 'in', ent)
                                  else jsonb_build_object('op', kind) || ent end);
                end if;
            end if;
            if sv <> 'resource' then
                if k[q] <> ',' then
                    if k[q] = ')' then
                        perform permissions._cedar_parse_fail(format('this policy is missing the %s variable in the scope',
                            case sv when 'principal' then 'action' else 'resource' end), ln[q], cl[q], scope_hint);
                    end if;
                    perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''',''', scope_hint);
                end if;
                q := q + 1;
            end if;
        end loop;
        if k[q] = ',' and k[q + 1] = ')' then
            q := q + 1;
        end if;
        if k[q] <> ')' then
            if k[q] = ',' and k[q + 1] = 'id' then
                perform permissions._cedar_parse_fail(format('this policy has an extra element in the scope: %s', v[q + 1]), ln[q + 1], cl[q + 1],
                    scope_hint || ' Conditions go in when or unless clauses after the scope.');
            end if;
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, ''')''', scope_hint);
        end if;
        q := q + 1;

        -- conditions
        an := 0; avals := '{}';
        while k[q] = 'id' and v[q] in ('when', 'unless') loop
            if k[q + 1] <> '{' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, q + 1, '''{''', format('A condition is %s { <expression> }.', v[q]));
            end if;
            if k[q + 2] = '}' then
                perform permissions._cedar_parse_fail(format('the %s condition clause is empty', v[q]), ln[q], cl[q],
                    format('Write an expression between the braces, or remove the %s clause.', v[q]));
            end if;
            r := permissions._cedar_parse_expr(k, v, ln, cl, q + 2, 1, 0);
            if k[r.np] <> '}' then
                perform permissions._cedar_syntax_error(k, v, ln, cl, r.np, 'an operator or ''}''', null);
            end if;
            if r.dep > lim.policy_depth then
                perform permissions._cedar_error('limit_exceeded',
                    format('the %s condition at line %s, column %s is %s levels deep, more than the limit of %s', v[q], ln[q], cl[q], r.dep, lim.policy_depth),
                    hint => 'Split the condition into simpler parts, for example several when clauses.',
                    p_detail => 'limit=''policy_depth''');
            end if;
            nodes := nodes + r.cnt;
            an := an + 1; avals[an] := jsonb_build_object('kind', v[q], 'body', r.node);
            q := r.np + 1;
        end loop;
        if k[q] <> ';' then
            if k[q] = 'id' then
                perform permissions._cedar_parse_fail(format('invalid policy condition: %s', v[q]), ln[q], cl[q],
                    coalesce(permissions._did_you_mean(v[q], '{when,unless}', 'A condition starts with'), '')
                    || case when v[q] in ('permit', 'forbid') then ' Or end the previous policy with '';''.' else '' end);
            end if;
            perform permissions._cedar_syntax_error(k, v, ln, cl, q, '''when'', ''unless'' or '';''',
                case when k[q] in ('eof', '@') then 'End each policy with '';''.' end);
        end if;
        if nodes > lim.policy_nodes then
            perform permissions._cedar_error('limit_exceeded',
                format('the policy at line %s, column %s has %s expression nodes, more than the limit of %s', ln[start], cl[start], nodes, lim.policy_nodes),
                hint => 'Split the policy into several smaller policies.',
                p_detail => 'limit=''policy_nodes''');
        end if;
        if not p_single and octet_length(substr(p_src, off[start], off[q] + 1 - off[start])) > lim.policy_bytes then
            perform permissions._cedar_error('limit_exceeded',
                format('the policy at line %s, column %s is more than %s bytes long', ln[start], cl[start], lim.policy_bytes),
                hint => 'Split the policy into several smaller policies.',
                p_detail => 'limit=''policy_bytes''');
        end if;
        q := q + 1;

        est := jsonb_build_object('effect', eff) || scope || jsonb_build_object('conditions', to_jsonb(avals));
        if annos <> '{}' then
            est := est || jsonb_build_object('annotations', annos);
        end if;
        if p_single then
            if k[q] <> 'eof' then
                perform permissions._cedar_parse_fail(
                    case when k[q] = '@' or (k[q] = 'id' and v[q] in ('permit', 'forbid'))
                         then 'expected exactly one policy, found a second policy'
                         else 'expected exactly one policy, found more text after the first' end, ln[q], cl[q],
                    'A call puts one policy or template: put each one with its own call and id, for example select permissions.cedar_put_policy(policy_id => ''second'', policy => ''forbid (principal, action, resource);'').');
            end if;
            return est;
        end if;
        pid := coalesce(pid, 'policy' || n);
        if statics ? pid or templates ? pid then
            perform permissions._cedar_parse_fail(format('duplicate template or policy id %L', pid), ln[start], cl[start],
                'Policy ids come from @id("...") or are policy0, policy1, ... by position. Give each policy a different @id.');
        end if;
        if is_template then
            templates := templates || jsonb_build_object(pid, est);
        else
            statics := statics || jsonb_build_object(pid, est);
        end if;
        n := n + 1;
    end loop;
    if p_single then
        perform permissions._cedar_parse_fail('expected a policy, found no policy', ln[q], cl[q],
            'Write one policy, for example: permit (principal, action, resource);');
    end if;
    return jsonb_build_object('staticPolicies', statics, 'templates', templates, 'templateLinks', '[]'::jsonb);
end;
$$;

-- Exactly one policy or template: its EST.
create function permissions._cedar_parse_policy(src text)
returns jsonb
language sql
immutable strict
as $$
    select permissions._cedar_parse_text(src, true)
$$;

-- A policy set: {"staticPolicies", "templates", "templateLinks": []}.
create function permissions._cedar_parse_policies(src text)
returns jsonb
language sql
immutable strict
as $$
    select permissions._cedar_parse_text(src, false)
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
-- puts could still make one). With an overlay, the same walk: each
-- entity's parents come from the overlay if it has the entity, else from
-- storage.
-- A generic plan: the walk's plan does not depend on the uid, and planning
-- it per call would cost more than running it.
create function permissions._cedar_ancestors(p_type text, p_id text, p_ov jsonb)
returns jsonb
language plpgsql stable
set plan_cache_mode = force_generic_plan
as $$
declare
    r jsonb;
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
    -- the same walk, each entity's parents from the overlay if it has the
    -- entity, else from storage (a key lookup in the overlay per step)
    with recursive a(t, i) as (
        select x.t, x.i from (
            select e ->> 0 as t, e ->> 1 as i from jsonb_array_elements(p_ov -> permissions._cedar_key(p_type, p_id) -> 'parents') e
            union all
            select p.parent_type, p.parent_id from permissions.cedar_entity_parents p
            where p.type = p_type and p.id = p_id and not p_ov ? permissions._cedar_key(p_type, p_id)) x
        union
        select q.t, q.i from a cross join lateral (
            select e ->> 0 as t, e ->> 1 as i from jsonb_array_elements(p_ov -> permissions._cedar_key(a.t, a.i) -> 'parents') e
            union all
            select p.parent_type, p.parent_id from permissions.cedar_entity_parents p
            where p.type = a.t and p.id = a.i and not p_ov ? permissions._cedar_key(a.t, a.i) offset 0) q
    )
    select jsonb_agg(permissions._cedar_key(a.t, a.i)) into r from a;
    return coalesce(r, '[]');
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
    -- a set operation, not a scan of anc (jsonb ? on an array) per element
    return to_jsonb(exists (select permissions._cedar_key(e -> '__entity' ->> 'type', e -> '__entity' ->> 'id') collate "C"
                            from jsonb_array_elements(y) e
                            intersect
                            select a collate "C" from jsonb_array_elements_text(anc) a));
end;
$$;

-- An extension function or method applied to its evaluated arguments (the
-- receiver first): the value, or null for an error (Cedar's
-- extension_error, wrong number of arguments, or type_error). The
-- arguments are already evaluated, left to right, as Cedar does before it
-- checks the arity and the types.
create function permissions._cedar_call(f text, a jsonb[], why boolean)
returns jsonb
language plpgsql immutable
as $$
declare
    n int := coalesce(cardinality(a), 0);
    want int := case when f in ('decimal', 'ip', 'datetime', 'duration', 'isIpv4', 'isIpv6', 'isLoopback', 'isMulticast',
                                'toDate', 'toTime', 'toMilliseconds', 'toSeconds', 'toMinutes', 'toHours', 'toDays') then 1 else 2 end;
    t text := permissions._cedar_extensions() ->> f;
    x numeric;
    y numeric;
    r numeric;
    ip inet;
    i int;
begin
    if n <> want then
        return permissions._cedar_eval_fail(why, format('extension_error: wrong number of arguments to %s (a method counts its receiver): expected %s, got %s',
                                                         f, want, n));
    end if;
    if f = t or f = 'ip' then
        -- a constructor
        if jsonb_typeof(a[1]) <> 'string' then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected String, got %s', f, permissions._cedar_type_of(a[1])));
        end if;
        return coalesce(permissions._cedar_extn(f, a[1] #>> '{}'),
                        permissions._cedar_eval_fail(why, format('extension_error: %s(%s) is not valid: %s', f, a[1], permissions._cedar_extn_help(f))));
    end if;
    -- a method: every argument has the receiver's type, except offset's
    -- duration
    for i in 1 .. n loop
        if (a[i] -> '__extn' ->> 'fn') is distinct from (case when i > 1 and f = 'offset' then 'duration' when t = 'ipaddr' then 'ip' else t end) then
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected %s, got %s', f,
                case when i > 1 and f = 'offset' then 'duration' else t end, permissions._cedar_type_of(a[i])));
        end if;
    end loop;
    if t = 'ipaddr' then
        ip := (a[1] #>> '{__extn,v}')::inet;
        return to_jsonb(case f
            when 'isIpv4' then family(ip) = 4
            when 'isIpv6' then family(ip) = 6
            -- the address in 127.0.0.0/8 or ::1, and a prefix at least as long
            when 'isLoopback' then ip <<= '127.0.0.0/8'::inet or ip <<= '::1/128'::inet
            when 'isMulticast' then ip <<= '224.0.0.0/4'::inet or ip <<= 'ff00::/8'::inet
            -- isInRange: the range holds the receiver's whole range (false
            -- across families)
            else ip <<= (a[2] #>> '{__extn,v}')::inet end);
    end if;
    x := (a[1] #>> '{__extn,v}')::numeric;
    y := (a[2] #>> '{__extn,v}')::numeric;
    if f in ('lessThan', 'lessThanOrEqual', 'greaterThan', 'greaterThanOrEqual') then
        return to_jsonb(case f when 'lessThan' then x < y when 'lessThanOrEqual' then x <= y
                               when 'greaterThan' then x > y else x >= y end);
    elsif f in ('toMilliseconds', 'toSeconds', 'toMinutes', 'toHours', 'toDays') then
        -- truncated toward zero, as Rust's integer division
        return to_jsonb(div(x, case f when 'toMilliseconds' then 1 when 'toSeconds' then 1000 when 'toMinutes' then 60000
                                      when 'toHours' then 3600000 else 86400000 end));
    end if;
    -- toTime: the time of day, x mod a day (the Euclidean remainder: a
    -- datetime before 1970 has a time of day >= 0); toDate: x minus it
    r := mod(x, 86400000);
    if r < 0 then
        r := r + 86400000;
    end if;
    if f = 'toTime' then
        return jsonb_build_object('__extn', jsonb_build_object('fn', 'duration', 'v', r));
    end if;
    r := case f when 'offset' then x + y when 'durationSince' then x - y else x - r end;
    if r not between -9223372036854775808 and 9223372036854775807 then
        return permissions._cedar_eval_fail(why, format('extension_error: %s overflows the 64-bit range of milliseconds', f));
    end if;
    return jsonb_build_object('__extn', jsonb_build_object('fn', case f when 'durationSince' then 'duration' else 'datetime' end, 'v', r));
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
    keys text[];
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
        for kv in select * from jsonb_each(n -> 'a') loop
            y := permissions._cedar_eval(kv.value, env, why);
            if y is null then
                return null;
            end if;
            keys := keys || kv.key;
            vals := vals || y;
        end loop;
        return coalesce((select jsonb_object_agg(u.k, u.w) from unnest(keys, vals) u(k, w)), '{}');
    elsif k = 'call' then
        for x in select e from jsonb_array_elements(n -> 'a') e loop
            y := permissions._cedar_eval(x, env, why);
            if y is null then
                return null;
            end if;
            vals := vals || y;
        end loop;
        return permissions._cedar_call(n ->> 'f', vals, why);
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
        -- two Longs, two datetimes or two durations (Cedar's operator
        -- overloading; decimals compare with their methods only)
        if jsonb_typeof(x) = 'number' and jsonb_typeof(y) = 'number' then
            null;
        elsif (x -> '__extn' ->> 'fn') in ('datetime', 'duration') and x -> '__extn' ->> 'fn' = y -> '__extn' ->> 'fn' then
            x := x -> '__extn' -> 'v';
            y := y -> '__extn' -> 'v';
        else
            return permissions._cedar_eval_fail(why, format('type_error: %s: expected two Longs, two datetimes or two durations, got %s and %s',
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
            -- set operations (hashed or sorted), not a scan of x for each
            -- element of y; jsonb = is Cedar == on the canonical form
            return to_jsonb(not exists (select b from jsonb_array_elements(y) b except select a from jsonb_array_elements(x) a));
        end if;
        return to_jsonb(exists (select b from jsonb_array_elements(y) b intersect select a from jsonb_array_elements(x) a));
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
-- cedar:invalid_context or cedar:limit_exceeded.
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
    perform permissions._cedar_error(case code when 'limit' then 'limit_exceeded' else 'invalid_context' end,
        format('invalid context: %s', err),
        hint => case code
            when 'limit' then format('Flatten the context: sets and records nest at most %s levels.', (permissions._cedar_limits()).value_depth)
            when 'extension' then 'Write an extension value as {"__extn": {"fn": "decimal", "arg": "12.34"}}, with fn one of decimal, ip, datetime and duration and an arg its constructor accepts: decimal("12.34"), ip("10.0.0.0/8"), datetime("2024-10-15T11:35:00Z"), duration("1h30m").'
            else 'Pass context => ''{"mfa": true, "level": 3, "owner": {"__entity": {"type": "User", "id": "alice"}}}''::jsonb: Bools, Longs, Strings, sets, records, entity references and extension values ({"__extn": {"fn": "ip", "arg": "10.0.0.1"}}).' end,
        p_detail => case code when 'limit' then 'limit=''value_depth''' end);
end;
$$;

-- The keys of the request entities for the scope match, from storage: each
-- entity's key, then its ancestors' keys (pk, ak, rk). The three walks run
-- in one query (as in _cedar_ancestors). A null type gives a null array.
create function permissions._cedar_keys(p_pt text, p_pi text, p_at text, p_ai text, p_rt text, p_ri text,
                                        out pk text[], out ak text[], out rk text[])
language plpgsql stable
as $$
begin
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
    pk := permissions._cedar_key(p_pt, p_pi) || pk;
    ak := permissions._cedar_key(p_at, p_ai) || ak;
    rk := case when p_rt is not null then permissions._cedar_key(p_rt, p_ri) || rk end;
end;
$$;

-- The policies whose scope matches a request (e-cedar.md section 4.4, step
-- 2): pk, ak and rk are _cedar_keys' arrays, p_pt and p_rt the principal's
-- and the resource's type. cedar_policy_scopes gives the candidates: one
-- index scan for each action key and each key of the side with fewer keys
-- (usually the resource), with the other side's keys in its index
-- condition. The predicate after it is the exact scope match. The lateral
-- subqueries with offset 0 keep each probe an index probe: with the three
-- arrays in one scan, the planner scanned the table on a thousand policies
-- and tested each row against the arrays (e-cedar.md section 15.1).
create function permissions._cedar_candidates(pk text[], ak text[], rk text[], p_pt text, p_rt text)
returns table (policy_id text, effect text, ast jsonb)
language sql stable
as $$
    select c.policy_id, c.effect, c.ast
    from (select distinct x.policy_id
          from unnest((ak || '*'::text) collate "C") a(k)
          cross join unnest((pk || p_pt || '*'::text) collate "C") p(k)
          cross join lateral (select s.policy_id from permissions.cedar_policy_scopes s
                              where s.action_key = a.k and s.principal_key = p.k
                                and s.resource_key = any((rk || p_rt || '*'::text) collate "C") offset 0) x
          where cardinality(pk) <= cardinality(rk)
          union
          select x.policy_id
          from unnest((ak || '*'::text) collate "C") a(k)
          cross join unnest((rk || p_rt || '*'::text) collate "C") r(k)
          cross join lateral (select s.policy_id from permissions.cedar_policy_scopes s
                              where s.action_key = a.k and s.resource_key = r.k
                                and s.principal_key = any((pk || p_pt || '*'::text) collate "C") offset 0) x
          where cardinality(pk) > cardinality(rk)) s
    cross join lateral (select * from permissions.cedar_policies x where x.policy_id = s.policy_id offset 0) c
    where (c.principal_op = 'All' or (c.principal_op = '==' and c.principal_uid = pk[1])
           or (c.principal_op = 'in' and c.principal_uid = any(pk))
           or (c.principal_op = 'is' and c.principal_type = p_pt and (c.principal_uid is null or c.principal_uid = any(pk))))
      and (c.action_op = 'All' or (c.action_op = '==' and c.action_uids[1] = ak[1]) or (c.action_op = 'in' and c.action_uids && ak))
      and (c.resource_op = 'All' or (c.resource_op = '==' and c.resource_uid = rk[1])
           or (c.resource_op = 'in' and c.resource_uid = any(rk))
           or (c.resource_op = 'is' and c.resource_type = p_rt and (c.resource_uid is null or c.resource_uid = any(rk))))
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
        select k.pk[2:], k.ak[2:], k.rk[2:] into pk, ak, rk
        from permissions._cedar_keys(p_pt, p_pi, p_at, p_ai, p_rt, p_ri) k;
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
set search_path = pg_catalog, pg_temp
set plan_cache_mode = force_generic_plan
set standard_conforming_strings = on
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
    errs jsonb[] := '{}';
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
                                     then permissions._cedar_entities_in(entities, 'entities', 'request_entities') end);
    env := e.env;
    pk := e.pk;
    ak := e.ak;
    rk := e.rk;
    for pol in select * from permissions._cedar_candidates(pk, ak, rk, p.type, r.type) loop
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
            errs := errs || jsonb_build_object('policy_id', pol.policy_id, 'message', msg);
        end if;
    end loop;
    return jsonb_build_object(
        'decision', case when cardinality(forbids) = 0 and cardinality(permits) > 0 then 'allow' else 'deny' end,
        'reasons', to_jsonb(array(select x from unnest(case when cardinality(forbids) > 0 then forbids else permits end) x
                                  order by x collate "C")),
        'errors', coalesce((select jsonb_agg(x order by x ->> 'policy_id' collate "C") from unnest(errs) x), '[]'));
end;
$$;

-- ----------------------------------------------------------------------------
-- RLS: the current subject (phase 5)
-- ----------------------------------------------------------------------------
-- cedar_is_authorized_current and cedar_list_resources_current decide for
-- the current subject (e-cedar.md sections 7 and 15). The principal is
-- current_subject_type()::"current_subject_id()": the type and the id are
-- used as they are, never through Cedar text, so an id needs no escapes. A
-- subject type that is not a Cedar type name can't be a principal. No
-- context: a client could otherwise vouch for itself.
--
-- They differ from cedar_is_authorized in one rule (plan-cedar.md, decision
-- 1): they fail closed. A forbid whose scope matches and whose conditions
-- hold or err denies; a permit that errs is skipped, as in Cedar. No
-- subject: false or nothing, so RLS denies instead of failing. An action or
-- resource that is not Cedar text (Type::"id") still raises
-- cedar:invalid_uid, like fga_check_current's unknown type or relation: it
-- is a mistake in the RLS policy, not a decision.

-- The policies whose principal and action scopes match, for any resource:
-- _cedar_candidates without the resource, plus the resource scope, for the
-- statement-level filter and the list.
create function permissions._cedar_principal_candidates(pk text[], ak text[], p_pt text)
returns table (policy_id text, effect text, ast jsonb, resource_op text, resource_type text, resource_uid text)
language sql stable
as $$
    select c.policy_id, c.effect, c.ast, c.resource_op, c.resource_type, c.resource_uid
    from (select distinct x.policy_id
          from unnest((ak || '*'::text) collate "C") a(k)
          cross join unnest((pk || p_pt || '*'::text) collate "C") p(k)
          cross join lateral (select s.policy_id from permissions.cedar_policy_scopes s
                              where s.action_key = a.k and s.principal_key = p.k offset 0) x) s
    cross join lateral (select * from permissions.cedar_policies x where x.policy_id = s.policy_id offset 0) c
    where (c.principal_op = 'All' or (c.principal_op = '==' and c.principal_uid = pk[1])
           or (c.principal_op = 'in' and c.principal_uid = any(pk))
           or (c.principal_op = 'is' and c.principal_type = p_pt and (c.principal_uid is null or c.principal_uid = any(pk))))
      and (c.action_op = 'All' or (c.action_op = '==' and c.action_uids[1] = ak[1]) or (c.action_op = 'in' and c.action_uids && ak))
$$;

-- The environment of a current-subject request without its resource: the
-- principal and the action, their ancestors (pk and ak: _cedar_keys'
-- arrays), their stored data, and an empty context. PL/pgSQL, so the plan
-- of the query is cached: as a SQL function (not inlined, for its
-- subquery) it was planned on every call, most of its cost.
create function permissions._cedar_current_env(p_pt text, p_pi text, p_at text, p_ai text, pk text[], ak text[])
returns jsonb
language plpgsql stable
as $$
declare
    ent jsonb;
begin
    select jsonb_object_agg(permissions._cedar_key(v.t, v.i),
                            case when e.type is not null then jsonb_build_object('attrs', e.attrs, 'tags', e.tags) else 'null' end)
    into ent
    from (values (p_pt, p_pi), (p_at, p_ai)) v(t, i)
    left join permissions.cedar_entities e on e.type = v.t and e.id = v.i;
    return jsonb_build_object(
        'principal', jsonb_build_object('__entity', jsonb_build_object('type', p_pt, 'id', p_pi)),
        'action', jsonb_build_object('__entity', jsonb_build_object('type', p_at, 'id', p_ai)),
        'context', '{}'::jsonb,
        'anc', jsonb_build_object(pk[1], to_jsonb(pk[2:]), ak[1], to_jsonb(ak[2:])),
        'ent', ent);
end;
$$;

-- One request of cedar_is_authorized_current from scratch: the walks, the
-- candidates of the scope index, then their conditions, forbids first.
-- p_attrs: the resource's attrs in internal form, which replace the stored
-- ones (null: the stored entity's).
create function permissions._cedar_current_check(p_pt text, p_pi text, p_at text, p_ai text, p_rt text, p_ri text,
                                                  p_attrs jsonb)
returns boolean
language plpgsql stable
set plan_cache_mode = force_generic_plan
as $$
declare
    k record;
    pol record;
    env jsonb;
    v jsonb;
begin
    select * into k from permissions._cedar_keys(p_pt, p_pi, p_at, p_ai, p_rt, p_ri);
    -- 'forbid' sorts before 'permit'
    for pol in select c.effect, c.ast from permissions._cedar_candidates(k.pk, k.ak, k.rk, p_pt, p_rt) c order by c.effect loop
        if pol.ast is null then
            -- no conditions: a forbid denies; a permit allows, as every
            -- forbid before it was false
            return pol.effect = 'permit';
        end if;
        if env is null then
            env := permissions._cedar_current_env(p_pt, p_pi, p_at, p_ai, k.pk, k.ak)
                   || jsonb_build_object('resource', jsonb_build_object('__entity', jsonb_build_object('type', p_rt, 'id', p_ri)));
            env := jsonb_set(env, '{anc}', (env -> 'anc') || jsonb_build_object(k.rk[1], to_jsonb(k.rk[2:])));
            if p_attrs is not null then
                env := jsonb_set(env, '{ent}', (env -> 'ent') || jsonb_build_object(k.rk[1], jsonb_build_object('attrs', p_attrs,
                    'tags', coalesce((select e.tags from permissions.cedar_entities e where e.type = p_rt and e.id = p_ri), '{}'))));
            end if;
        end if;
        v := permissions._cedar_eval(pol.ast, env, false);
        if pol.effect = 'forbid' then
            if v is distinct from 'false' then
                return false;               -- it holds, or it errs: fail closed
            end if;
        elsif v = 'true' then
            return true;                    -- a permit that errs is skipped
        end if;
    end loop;
    return false;
end;
$$;

-- The statement-level part of cedar_is_authorized_current (e-cedar.md
-- section 15.2): computed once per statement, kept as text in a
-- transaction-local setting. Two parts, split by chr(28):
--   1. Flags, chr(30), then one entry per permit whose principal and action
--      scopes match, each followed by chr(30): its resource scope, E:<key>
--      (resource == key), I:<key> (resource in key), T:<type> (resource is
--      type) or A:* (any resource) for a permit without conditions; e:,
--      i:, t: and a:* for a permit with conditions, or with is ... in (as
--      i:<key>). Flags: F, a forbid's principal and action scopes match; X,
--      part 2 would be too large to parse per row.
--   2. Unless X, and if there is a forbid or an entry in lower case, the
--      forbids and the lower-case permits grouped by resource scope, with
--      the environment without the resource, as jsonb text:
--        {"pf": {"e": {key: [p]}, "i": {key: [p]}, "t": {type: [p]}, "a": [p]},
--         "env": _cedar_current_env, "tags": a condition uses tags}
--      with p {"f": forbid?, "a": ast or null, "t": the type of is ... in}.
-- Part 2 is parsed for the rows that need it, so it is capped: 8 KiB parse
-- in about 40 us, about what the check from scratch costs.
create function permissions._cedar_current_filter(p_pt text, p_pi text, p_at text, p_ai text)
returns text
language plpgsql stable
set plan_cache_mode = force_generic_plan
as $$
declare
    k record;
    cs jsonb;
    f text;
    payload text;
    sep boolean;
    forbid boolean;
    part1 text;
    cond boolean;
begin
    select * into k from permissions._cedar_keys(p_pt, p_pi, p_at, p_ai, null, null);
    -- the candidates and what part 1 needs from them, in one pass (a query
    -- for each flag cost more than the candidates)
    select coalesce(jsonb_agg(y.c), '[]'),
           coalesce(bool_or(strpos(y.c ->> 'v', chr(28)) > 0 or strpos(y.c ->> 'v', chr(30)) > 0), false),
           coalesce(bool_or((y.c ->> 'f')::boolean), false),
           coalesce(string_agg(case when (y.c ->> 'free')::boolean then upper(y.c ->> 'k') else y.c ->> 'k' end
                                   || ':' || (y.c ->> 'v') || chr(30), '') filter (where not (y.c ->> 'f')::boolean), ''),
           coalesce(bool_or(not (y.c ->> 'free')::boolean), false)
    into cs, sep, forbid, part1, cond
    from (select jsonb_build_object(
                     'f', x.effect = 'forbid', 'a', x.ast,
                     'k', case x.resource_op when '==' then 'e' when 'in' then 'i' when 'All' then 'a'
                                             else case when x.resource_uid is null then 't' else 'i' end end,
                     'v', case x.resource_op when 'All' then '*' when 'is' then coalesce(x.resource_uid, x.resource_type) else x.resource_uid end,
                     't', case when x.resource_op = 'is' and x.resource_uid is not null then x.resource_type end,
                     'free', x.effect = 'permit' and x.ast is null and not (x.resource_op = 'is' and x.resource_uid is not null)) as c
          -- offset 0: built once per row (flattened, every y.c below
          -- built it again)
          from permissions._cedar_principal_candidates(k.pk, k.ak, p_pt) x offset 0) y;
    if sep then
        -- a resource scope holds a separator of this layout: every row that
        -- a permit can match is checked from scratch (flag X, entry a:*)
        return 'X' || chr(30) || 'a:*' || chr(30) || chr(28);
    end if;
    f := case when forbid then 'F' else '' end || chr(30) || part1;
    if cond then
        with p as (select c ->> 'k' as k, c ->> 'v' as v, jsonb_build_object('f', c -> 'f', 'a', c -> 'a', 't', c -> 't') as p
                   from jsonb_array_elements(cs) c where not (c ->> 'free')::boolean)
        select jsonb_build_object(
                   'pf', jsonb_build_object(
                       'e', coalesce((select jsonb_object_agg(g.v, g.ps) from (select p.v, jsonb_agg(p.p) as ps from p where p.k = 'e' group by p.v) g), '{}'),
                       'i', coalesce((select jsonb_object_agg(g.v, g.ps) from (select p.v, jsonb_agg(p.p) as ps from p where p.k = 'i' group by p.v) g), '{}'),
                       't', coalesce((select jsonb_object_agg(g.v, g.ps) from (select p.v, jsonb_agg(p.p) as ps from p where p.k = 't' group by p.v) g), '{}'),
                       'a', coalesce((select jsonb_agg(p.p) from p where p.k = 'a'), '[]')),
                   'env', permissions._cedar_current_env(p_pt, p_pi, p_at, p_ai, k.pk, k.ak),
                   'tags', exists (select 1 from p where (p.p -> 'a')::text ~ '"k": "(has|get)Tag"'))::text
        into payload;
        if octet_length(payload) > 8192 then
            f := 'X' || f;
            payload := '';
        end if;
    end if;
    return f || chr(28) || coalesce(payload, '');
end;
$$;

-- The decision for one resource from part 2 of the statement's filter (x,
-- parsed): the forbids and the permits with conditions whose resource scope
-- matches, forbids first, failing closed; p_free: a permit without
-- conditions matches (part 1 says). p_attrs: the row's attributes, internal
-- form, or null for the stored ones; p_anc: the resource's ancestors if the
-- caller walked them already.
create function permissions._cedar_decide(x jsonb, p_rt text, p_ri text, p_attrs jsonb, p_anc jsonb, p_free boolean)
returns boolean
language plpgsql stable
as $$
declare
    rk text := permissions._cedar_key(p_rt, p_ri);
    pf jsonb := x -> 'pf';
    anc jsonb := p_anc;
    m jsonb[] := '{}';
    g jsonb;
    tg jsonb;
    e jsonb;
    p jsonb;
    v jsonb;
    n int;
begin
    -- the matching policies, in the order e, t, a, then i by key (the
    -- resource's ancestors, then the resource). Index loops over jsonb and
    -- an array variable: no query per row (a query costs more than the
    -- rest of a row's decision)
    foreach g in array array[pf -> 'e' -> rk, pf -> 't' -> p_rt, pf -> 'a'] loop
        for j in 0 .. coalesce(jsonb_array_length(g), 0) - 1 loop
            m := m || (g -> j);
        end loop;
    end loop;
    if pf -> 'i' <> '{}' then
        anc := coalesce(anc, permissions._cedar_ancestors(p_rt, p_ri, null));
        n := jsonb_array_length(anc);
        for i in 0 .. n loop
            g := pf -> 'i' -> case when i < n then anc ->> i else rk end;
            for j in 0 .. coalesce(jsonb_array_length(g), 0) - 1 loop
                if g -> j ->> 't' is null or g -> j ->> 't' = p_rt then
                    m := m || (g -> j);
                end if;
            end loop;
        end loop;
    end if;
    if cardinality(m) = 0 then
        return p_free;
    end if;
    -- the environment with the resource, built once (jsonb_set per key
    -- copied all of it each time)
    if p_attrs is not null and (x ->> 'tags')::boolean then
        select t.tags into tg from permissions.cedar_entities t where t.type = p_rt and t.id = p_ri;
    end if;
    e := (x -> 'env') || jsonb_build_object(
        'resource', jsonb_build_object('__entity', jsonb_build_object('type', p_rt, 'id', p_ri)),
        'anc', case when anc is null then x -> 'env' -> 'anc' else (x -> 'env' -> 'anc') || jsonb_build_object(rk, anc) end,
        'ent', case when p_attrs is null then x -> 'env' -> 'ent'
                    else (x -> 'env' -> 'ent') || jsonb_build_object(rk, jsonb_build_object('attrs', p_attrs, 'tags', coalesce(tg, '{}'))) end);
    foreach p in array m loop
        continue when (p ->> 'f')::boolean is not true;
        v := case when p -> 'a' = 'null' then 'true' else permissions._cedar_eval(p -> 'a', e, false) end;
        if v is distinct from 'false' then
            return false;                   -- a forbid holds, or errs: fail closed
        end if;
    end loop;
    if p_free then
        return true;
    end if;
    foreach p in array m loop
        continue when (p ->> 'f')::boolean is not false;
        if p -> 'a' = 'null' or permissions._cedar_eval(p -> 'a', e, false) = 'true' then
            return true;                    -- a permit that errs is skipped
        end if;
    end loop;
    return false;
end;
$$;

-- The trust of the statement filter (e-cedar.md section 15.2). The filter
-- lives in a setting, which any client can write, so each entry carries
-- MACs (_cedar_mac) under this secret: an entry the helper did not write is
-- ignored. One row, owner only, filled with random bytes when the extension
-- is installed or upgraded (gen_random_uuid() is pg_strong_random: 3 x 122
-- bits). A dump of the extension does not hold it; create extension makes a
-- new one. Without a row no entry verifies and every row is checked from
-- scratch: slower, never wrong.
create table permissions._cedar_secret (
    one    boolean primary key default true check (one),
    secret bytea not null
);
insert into permissions._cedar_secret (secret)
select decode(replace(gen_random_uuid()::text || gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'hex');

-- The MAC of a filter entry: sha256(s || sha256(s || m)), HMAC's nesting, so
-- sha256's length extension does not apply. m is text as stored (the
-- database encoding, no conversion: it never raises). Stable, as
-- getdatabaseencoding() is, so that a call is inlined.
create function permissions._cedar_mac(s bytea, m text)
returns text
language sql stable
as $$
    select encode(sha256(s || sha256(s || convert_to(m, getdatabaseencoding()))), 'hex')
$$;

-- Own writes. A Cedar write ends the filters this transaction cached: the
-- key holds the generation of the transaction's last Cedar write, from this
-- table, which only the owner writes (the setting the key used to hold was
-- a client's to reset). One row per backend, so writers never wait on each
-- other; a row of an earlier transaction of the backend (another xid) does
-- not count. The sequence makes each write's generation new, even after a
-- rolled-back subtransaction reuses the row's old value. Unlogged: a crash
-- empties it, which ends no live transaction. A read replica never writes
-- Cedar and cannot read an unlogged table, so the helper reads it only once
-- the transaction has an xid (pg_current_xact_id_if_assigned()), which a
-- replica never assigns: generation 0 there.
create unlogged table permissions._cedar_write_gen (
    pid int primary key,
    xid xid8 not null,
    gen bigint not null
);
create sequence permissions._cedar_write_seq;

create function permissions._cedar_changed()
returns trigger
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set standard_conforming_strings = on
as $$
begin
    insert into permissions._cedar_write_gen as w (pid, xid, gen)
    values (pg_backend_pid(), pg_current_xact_id(), nextval('permissions._cedar_write_seq'))
    on conflict (pid) do update set xid = excluded.xid, gen = excluded.gen;
    return null;
end;
$$;

create trigger cedar_changed after insert or update or delete or truncate on permissions.cedar_policies
    for each statement execute function permissions._cedar_changed();
create trigger cedar_changed after insert or update or delete or truncate on permissions.cedar_entities
    for each statement execute function permissions._cedar_changed();
create trigger cedar_changed after insert or update or delete or truncate on permissions.cedar_entity_parents
    for each statement execute function permissions._cedar_changed();

-- Whether a record of attributes is already in internal form (e-cedar.md
-- section 3), so the row overlay of cedar_is_authorized_current needs no
-- conversion: every value a String, a Bool, a Long in range, or an entity
-- reference {"__entity": {"type", "id"}}. Anything else (sets, records,
-- extension values) goes through _cedar_value_in.
create function permissions._cedar_attrs_plain(v jsonb)
returns boolean
language plpgsql immutable
as $$
declare
    vals jsonb;
    e jsonb;
begin
    if jsonb_typeof(v) is distinct from 'object' then
        -- callers pass records; the query keeps jsonb_each's answer for the rest
        return not exists (select 1 from jsonb_each(v));
    end if;
    -- the values without a query (jsonb_each would be one per row of a
    -- policy): every value must pass. A missing entity id makes the test
    -- NULL, which must fall back to the full validator, not count as valid.
    vals := jsonb_path_query_array(v, '$.*');
    for i in 0 .. jsonb_array_length(vals) - 1 loop
        e := vals -> i;
        if (case jsonb_typeof(e)
                when 'string' then true
                when 'boolean' then true
                when 'number' then scale(e::text::numeric) = 0
                                   and e::text::numeric between -9223372036854775808 and 9223372036854775807
                when 'object' then e - '__entity' = '{}' and jsonb_typeof(e -> '__entity') = 'object'
                                   and (e -> '__entity') - 'type' - 'id' = '{}'
                                   and jsonb_typeof(e -> '__entity' -> 'id') = 'string'
                                   and jsonb_typeof(e -> '__entity' -> 'type') = 'string'
                                   and permissions._cedar_is_name(e -> '__entity' ->> 'type')
                else false end) is not true then
            return false;
        end if;
    end loop;
    return true;
end;
$$;

-- Per-row checks in RLS:
--   using (permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || id || '"'))
-- with a row's columns as the resource's attributes (Cedar entity JSON):
--   using (permissions.cedar_is_authorized_current('Action::"view"', 'Document::"' || id || '"',
--          resource_attrs => jsonb_build_object('owner', jsonb_build_object('__entity',
--                                jsonb_build_object('type', 'User', 'id', owner_id)), 'level', level)))
-- resource_attrs replaces the stored entity's attrs; its parents and tags
-- still come from storage, and a resource that is not stored has no parents
-- and no tags. Attributes Cedar can't hold (a fraction, a null) deny, as
-- does a null action or resource, and a resource Type::"..." whose id is
-- not a Cedar string (a row's id with " or \ concatenated unescaped): data
-- never raises. Other resource text, and an action that is not a uid, are
-- the caller's typos and raise cedar:invalid_uid. Ids may hold any
-- character. plan_time_guard is ignored: its volatile
-- default keeps a constant call out of plan-time evaluation (see
-- _unfolded_null); don't pass it.
--
-- Once per statement (e-cedar.md section 15.2): the principal's and the
-- action's walks, the candidate policies and the environment
-- (_cedar_current_filter), kept in a transaction-local setting under a key
-- of the database (a database made from a template has the same secret),
-- the snapshot, the settings the subject comes from, the generation of the
-- transaction's own Cedar writes (_cedar_write_gen) and the action.
-- Per row: the resource's scope against the candidates; only a resource
-- that a forbid or a permit with conditions can match evaluates anything.
--
-- A client can write the setting, so the helper trusts only what it wrote:
--   key chr(29) mac1 part1 chr(28) mac2 chr(31) part2
-- mac1 = _cedar_mac(secret, octet_length(key) ':' key part1), checked on
-- every row; mac2 = _cedar_mac(secret, mac1 part2), checked on the rows
-- that read part 2. An entry with another key, a bad MAC or a bad shape is
-- a miss: the filter is computed again (bad part 2: the row is checked from
-- scratch). It never raises. A client can still read its own entries and
-- write them back, but an entry is valid only under its key, so that
-- replays the same answer.
create function permissions.cedar_is_authorized_current(action text, resource text, resource_attrs jsonb default null,
                                                        plan_time_guard boolean default permissions._unfolded_null())
returns boolean
language plpgsql stable security definer
set search_path = pg_catalog, pg_temp
set standard_conforming_strings = on
as $$
declare
    g text;
    key text;
    f text;
    payload text;
    a record;
    rt text;
    ri text;
    rk text;
    i int;
    x record;
    anc jsonb;
    free boolean;
    cond boolean;
    sep boolean;
    attrs jsonb;
    sec bytea;
    gen bigint;
    mac text;
    fresh boolean := false;
    n int;
    ak text;
begin
    if action is null or resource is null then
        return false;
    end if;
    -- the statement's filter, and what makes it trusted: the secret, and
    -- the generation of this transaction's own Cedar writes (none without
    -- an xid; a replica has none)
    g := 'permissions.cedar_filter_' || md5(action);
    select s.secret into sec from permissions._cedar_secret s;
    if pg_current_xact_id_if_assigned() is not null then
        select w.gen into gen from permissions._cedar_write_gen w where w.pid = pg_backend_pid() and w.xid = pg_current_xact_id();
    end if;
    key := format('%s %s %L %L %L %s %L', current_database(), pg_current_snapshot(), current_setting('request.jwt.claims', true),
                  current_setting('permissions.subject_id', true), current_setting('permissions.subject_type', true),
                  coalesce(gen, 0), action) || chr(29);
    -- key chr(29) mac1 part1 chr(28) mac2 chr(31) part2, split byte-wise
    -- (split_part): substr and left count the characters of the whole
    -- text, about 2 ns a byte, and part 2 can be 8 KiB. Part 1 never holds
    -- chr(28), nor part 2 (jsonb text) a control character; a key that
    -- holds chr(28) (a subject setting can) never verifies: a miss.
    payload := current_setting(g, true);
    f := null;
    if payload is not null and starts_with(payload, key) then
        f := split_part(payload, chr(28), 1);
        mac := substr(f, char_length(key) + 1, 64);
        f := substr(f, char_length(key) + 65);
        if mac is distinct from permissions._cedar_mac(sec, octet_length(key) || ':' || key || f) then
            f := null;                      -- not the helper's entry: a miss
        end if;
    end if;
    if f is null then
        select * into a from permissions._cedar_uid(action, 'action');
        payload := case when permissions.current_subject_id() is null or not permissions._cedar_is_name(permissions.current_subject_type())
                        then chr(30) || chr(28)
                        else permissions._cedar_current_filter(permissions.current_subject_type(), permissions.current_subject_id(), a.type, a.id) end;
        f := split_part(payload, chr(28), 1);
        payload := split_part(payload, chr(28), 2);
        -- without a secret no entry verifies (a dash is never a MAC)
        mac := coalesce(permissions._cedar_mac(sec, octet_length(key) || ':' || key || f), repeat('-', 64));
        perform set_config(g, key || mac || f || chr(28) || coalesce(permissions._cedar_mac(sec, mac || payload), repeat('-', 64))
                              || chr(31) || payload, true);
        fresh := true;
    end if;
    -- the resource uid (_cedar_uid's common case inline: no escapes)
    i := strpos(resource, '::"');
    if i > 0 and right(resource, 1) = '"' and strpos(resource, '\') = 0 and char_length(resource) > i + 2
       and strpos(substr(resource, i + 3, char_length(resource) - i - 3), '"') = 0
       and permissions._cedar_is_name(left(resource, i - 1)) then
        rt := left(resource, i - 1);
        ri := substr(resource, i + 3, char_length(resource) - i - 3);
    else
        select * into x from permissions._cedar_uid(resource, 'resource', true);
        if x.type is null then
            -- Type::"..." whose id is not a Cedar string, as when a row's id
            -- with " or \ is concatenated unescaped: data, so the row is
            -- denied. Any other text is the caller's typo and raises.
            if resource !~ '^\s*[_a-zA-Z][_a-zA-Z0-9]*(::[_a-zA-Z][_a-zA-Z0-9]*)*::".*"\s*$' then
                perform permissions._cedar_uid(resource, 'resource');
            end if;
            return false;
        end if;
        rt := x.type;
        ri := x.id;
    end if;
    if strpos(f, ':') = 0 then
        return false;                       -- no subject, or no permit for it
    end if;
    -- which permits' resource scopes match: free (no conditions), cond (others)
    rk := permissions._cedar_key(rt, ri);
    free := strpos(f, chr(30) || 'A:*' || chr(30)) > 0 or strpos(f, chr(30) || 'E:' || rk || chr(30)) > 0
            or strpos(f, chr(30) || 'T:' || rt || chr(30)) > 0;
    cond := strpos(f, chr(30) || 'a:*' || chr(30)) > 0 or strpos(f, chr(30) || 'e:' || rk || chr(30)) > 0
            or strpos(f, chr(30) || 't:' || rt || chr(30)) > 0;
    sep := strpos(rk, chr(30)) > 0;
    if (not free and strpos(f, chr(30) || 'I:') > 0) or (not cond and strpos(f, chr(30) || 'i:') > 0) then
        anc := permissions._cedar_ancestors(rt, ri, null);
        -- the ancestors' keys, then the resource's: an index loop, not a
        -- query per row
        n := jsonb_array_length(anc);
        for j in 0 .. n loop
            ak := case when j < n then anc ->> j else rk end;
            free := free or coalesce(strpos(f, chr(30) || 'I:' || ak || chr(30)) > 0, false);
            cond := cond or coalesce(strpos(f, chr(30) || 'i:' || ak || chr(30)) > 0, false);
            sep := sep or coalesce(strpos(ak, chr(30)) > 0, false);
        end loop;
    end if;
    if sep then
        -- the resource's key or an ancestor's holds chr(30), the separator
        -- of the entries, so the matches above can be false: from scratch
        f := 'X';
        free := false;
        cond := true;
    end if;
    if not free and not cond then
        return false;
    end if;
    if resource_attrs is not null and resource_attrs <> 'null' then
        if jsonb_typeof(resource_attrs) <> 'object' or resource_attrs ? '__entity' or resource_attrs ? '__extn' then
            return false;
        elsif permissions._cedar_attrs_plain(resource_attrs) then
            attrs := resource_attrs;
        else
            select * into x from permissions._cedar_value_in(resource_attrs, 'resource_attrs', 1);
            if x.code is not null then
                return false;
            end if;
            attrs := x.val;
        end if;
    end if;
    if free and strpos(split_part(f, chr(30), 1), 'F') = 0 then
        return true;                        -- valid input, an unconditional permit, and no forbid
    end if;
    if strpos(split_part(f, chr(30), 1), 'X') > 0 then
        select * into a from permissions._cedar_uid(action, 'action');
        return permissions._cedar_current_check(permissions.current_subject_type(), permissions.current_subject_id(),
                                                a.type, a.id, rt, ri, attrs);
    end if;
    if not fresh then
        payload := split_part(payload, chr(28), 2);     -- mac2 chr(31) part 2
        if split_part(payload, chr(31), 1) is distinct from permissions._cedar_mac(sec, mac || split_part(payload, chr(31), 2)) then
            -- part 2 is not the helper's: this row from scratch
            select * into a from permissions._cedar_uid(action, 'action');
            return permissions._cedar_current_check(permissions.current_subject_type(), permissions.current_subject_id(),
                                                    a.type, a.id, rt, ri, attrs);
        end if;
        payload := split_part(payload, chr(31), 2);
    end if;
    return permissions._cedar_decide(payload::jsonb, rt, ri, attrs, anc, free);
end;
$$;

-- The candidate resources of cedar_list_resources_current: the ids of the
-- stored entities of type p_type that a permit of pf names in its resource
-- scope (pf as _cedar_eval_resource takes it), and whether a permit without
-- conditions names it (free). ==: that entity; in X: X and its descendants;
-- All and is: every entity of the type.
create function permissions._cedar_list_candidates(pf jsonb, p_type text)
returns table (id text, free boolean)
language sql stable
as $$
    with recursive p as materialized (
        select x ->> 'op' as op, x ->> 'u' as u, split_part(x ->> 'u', '::"', 1) as ut,
               x -> 'a' = 'null' as free
        from jsonb_array_elements(pf) x
        where not (x ->> 'f')::boolean
    ), d(t, i, root, free) as (
        select p.ut collate "C", substr(p.u, char_length(p.ut) + 4, char_length(p.u) - char_length(p.ut) - 4) collate "C", true, p.free
        from p
        where p.op = 'in' or (p.op = 'is' and p.u is not null)
        union
        -- a child in cedar_entity_parents is a stored entity
        select q.type, q.id, false, d.free from d cross join lateral (
            select x.type, x.id from permissions.cedar_entity_parents x
            where x.parent_type = d.t and x.parent_id = d.i offset 0) q
    )
    select c.id, bool_or(c.free)
    -- lateral subqueries with offset 0: run only for the scopes that need
    -- them (a join here became a hash of every entity of the type)
    from (select q.id, p.free from p cross join lateral (
              select e.id from permissions.cedar_entities e where e.type = p_type offset 0) q
          where p.op = 'All' or (p.op = 'is' and p.u is null)
          union all
          select q.id, p.free from p cross join lateral (
              select e.id from permissions.cedar_entities e
              where e.type = p_type and e.id = substr(p.u, char_length(p.ut) + 4, char_length(p.u) - char_length(p.ut) - 4) offset 0) q
          where p.op = '==' and p.ut = p_type
          union all
          select d.i, d.free from d
          where d.t = p_type and not d.root
          union all
          -- a root (X itself) must be stored: a primary-key probe (an
          -- exists here became a hashed scan of every entity)
          select d.i, d.free from d cross join lateral (
              select 1 from permissions.cedar_entities e where e.type = d.t and e.id = d.i offset 0) q
          where d.t = p_type and d.root) c
    group by c.id
$$;

-- Whether the policies pf allow a resource, failing closed. pf: a jsonb
-- array, forbids first, of {"f": forbid?, "a": ast or null, "op", "t", "u"}
-- (the resource scope: op, type and uid key) of policies whose principal
-- and action scopes match; env: _cedar_current_env's. The resource's
-- ancestors are walked only if an in scope needs them.
create function permissions._cedar_eval_resource(pf jsonb, env jsonb, p_rt text, p_ri text)
returns boolean
language plpgsql stable
as $$
declare
    rk text := permissions._cedar_key(p_rt, p_ri);
    anc jsonb;
    e jsonb;
    p jsonb;
    v jsonb;
begin
    e := env || jsonb_build_object('resource', jsonb_build_object('__entity', jsonb_build_object('type', p_rt, 'id', p_ri)));
    for p in select x from jsonb_array_elements(pf) x loop
        if p ->> 'op' = '==' then
            continue when p ->> 'u' <> rk;
        elsif p ->> 'op' <> 'All' then
            continue when p ->> 'op' = 'is' and p ->> 't' <> p_rt;
            if p ->> 'u' is not null and p ->> 'u' <> rk then
                if anc is null then
                    anc := permissions._cedar_ancestors(p_rt, p_ri, null);
                    e := jsonb_set(e, '{anc}', (e -> 'anc') || jsonb_build_object(rk, anc));
                end if;
                continue when not anc ? (p ->> 'u');
            end if;
        end if;
        v := case when p -> 'a' = 'null' then 'true' else permissions._cedar_eval(p -> 'a', e, false) end;
        if (p ->> 'f')::boolean then
            if v is distinct from 'false' then
                return false;
            end if;
        elsif v = 'true' then
            return true;
        end if;
    end loop;
    return false;
end;
$$;

-- Ids (without the type) of the stored entities of resource_type that the
-- current subject may perform action on, for RLS:
--   id = any (array(select permissions.cedar_list_resources_current('Action::"view"', 'Document')::uuid))
-- Stored entities only (plan-cedar.md, decision 3): a resource that is not
-- stored is never listed, even when a policy names it, and no row
-- attributes apply. Uncapped, unordered, and fails closed like
-- cedar_is_authorized_current. The candidates come from the resource scopes
-- of the permits (section 15.3); a candidate is evaluated only when a
-- forbid could match or only a permit with conditions names it. A
-- set-returning function is never evaluated at plan time (its estimate is
-- `rows`), so it needs no plan_time_guard. No JIT: the generic plan of
-- _cedar_list_candidates is costed for every branch (with a million
-- documents, over jit_above_cost), and compiling it took 10 ms a call on
-- Postgres 18 for a query that runs in 0.2 ms (e-cedar.md section 15.3).
create function permissions.cedar_list_resources_current(action text, resource_type text)
returns setof text
language plpgsql stable security definer
set search_path = pg_catalog, pg_temp
set plan_cache_mode = force_generic_plan
set jit = off
set standard_conforming_strings = on
rows 100
as $$
declare
    pt text := permissions.current_subject_type();
    pi text := permissions.current_subject_id();
    a record;
    k record;
    pf jsonb;
    env jsonb;
    cand record;
    forbids boolean;
begin
    if action is null or resource_type is null then
        return;
    end if;
    select * into a from permissions._cedar_uid(action, 'action');
    if not permissions._cedar_is_name(resource_type) then
        perform permissions._cedar_error('invalid_argument', format('invalid entity type for resource_type: %s', resource_type),
            hint => 'Pass an entity type name without an id: resource_type => ''Document'' (a namespaced type: ''App::Document'').',
            p_detail => format('value=%L', resource_type));
    end if;
    if pi is null or not permissions._cedar_is_name(pt) then
        return;
    end if;
    select * into k from permissions._cedar_keys(pt, pi, a.type, a.id, null, null);
    select coalesce(jsonb_agg(jsonb_build_object('f', c.effect = 'forbid', 'a', c.ast, 'op', c.resource_op,
                                                 't', c.resource_type, 'u', c.resource_uid)
                              order by c.effect, c.policy_id), '[]')
    into pf
    from permissions._cedar_principal_candidates(k.pk, k.ak, pt) c
    where c.resource_op in ('All', 'in')
       or (c.resource_op = 'is' and c.resource_type = cedar_list_resources_current.resource_type)
       or (c.resource_op = '==' and split_part(c.resource_uid, '::"', 1) = cedar_list_resources_current.resource_type);
    if not exists (select 1 from jsonb_array_elements(pf) p where not (p ->> 'f')::boolean) then
        return;
    end if;
    forbids := exists (select 1 from jsonb_array_elements(pf) p where (p ->> 'f')::boolean);
    if not forbids and not exists (select 1 from jsonb_array_elements(pf) p where p -> 'a' <> 'null') then
        -- permits without conditions: their scopes are the answer
        return query select l.id from permissions._cedar_list_candidates(pf, resource_type) l;
        return;
    end if;
    env := permissions._cedar_current_env(pt, pi, a.type, a.id, k.pk, k.ak);
    for cand in select * from permissions._cedar_list_candidates(pf, resource_type) loop
        if (cand.free and not forbids) or permissions._cedar_eval_resource(pf, env, resource_type, cand.id) then
            return next cand.id;
        end if;
    end loop;
end;
$$;

-- ----------------------------------------------------------------------------
-- Admin API: policies
-- ----------------------------------------------------------------------------

-- The nearest policy ids (_did_you_mean), for hints; or that the id is a
-- template's.
create function permissions._cedar_policy_hint(p_id text)
returns text
language sql stable
as $$
    select coalesce(case when exists (select 1 from permissions.cedar_templates t where t.template_id = p_id)
                         then format('%L is a template: delete it with select permissions.cedar_delete_template(template_id => %L).', p_id, p_id) end,
                    permissions._did_you_mean(coalesce(p_id, ''),
                                              array(select c.policy_id from permissions.cedar_policies c),
                                              'Policy ids'),
                    'No policy exists yet: put one with select permissions.cedar_put_policy(policy_id => ..., policy => ...).')
$$;

-- The nearest template ids, for hints; or that the id is a policy's.
create function permissions._cedar_template_hint(p_id text)
returns text
language sql stable
as $$
    select coalesce(case when exists (select 1 from permissions.cedar_policies c where c.policy_id = p_id)
                         then format('%L is a policy or a link, not a template: see select * from permissions.cedar_policies().', p_id) end,
                    permissions._did_you_mean(coalesce(p_id, ''),
                                              array(select t.template_id from permissions.cedar_templates t),
                                              'Template ids'),
                    'No template exists yet: put one with select permissions.cedar_put_template(template_id => ..., template => ...).')
$$;

-- Static policies, template links and templates share one set of ids, as in
-- a Cedar policy set. p_kind is what the caller puts: 'policy' (a static
-- policy), 'link' or 'template'. A put may replace an id of its own kind;
-- an id of another kind raises cedar:id_in_use.
create function permissions._cedar_check_id(p_id text, p_kind text)
returns void
language plpgsql stable
as $$
declare
    tid text;
    other text;
begin
    if p_kind <> 'template' and exists (select 1 from permissions.cedar_templates t where t.template_id = p_id) then
        other := 'a template';
    else
        select c.template_id into tid from permissions.cedar_policies c
        where c.policy_id = p_id and (p_kind = 'template' or (p_kind = 'policy') = (c.template_id is not null));
        if found then
            other := case when tid is null then 'a static policy' else format('a link of template %L', tid) end;
        end if;
    end if;
    if other is not null then
        perform permissions._cedar_error('id_in_use',
            format('%L is already %s, so it cannot be %s', p_id, other,
                   case p_kind when 'policy' then 'a static policy' when 'link' then 'a template link' else 'a template' end),
            hint => 'Static policies, template links and templates share one set of ids: choose another id, or first delete the existing one (cedar_delete_policy for a policy or a link, cedar_delete_template for a template).',
            p_detail => format('id=%L', p_id));
    end if;
end;
$$;

-- Insert or replace one row of cedar_policies: a static policy (p_template_id
-- null) or a link, and its rows of cedar_policy_scopes. c is
-- _cedar_compile_policy's result.
create function permissions._cedar_store_policy(p_id text, p_source text, p_est jsonb, c jsonb,
                                                p_template_id text, p_slots jsonb)
returns void
language sql
as $$
    insert into permissions.cedar_policies as x (policy_id, effect, source, est, ast, annotations,
                                                 principal_op, principal_type, principal_uid,
                                                 action_op, action_uids,
                                                 resource_op, resource_type, resource_uid,
                                                 template_id, slots)
    values (p_id, c ->> 'effect', p_source, p_est, nullif(c -> 'ast', 'null'), c -> 'annotations',
            c -> 'principal' ->> 'op', c -> 'principal' ->> 'type', c -> 'principal' ->> 'uid',
            c -> 'action' ->> 'op', array(select jsonb_array_elements_text(c -> 'action' -> 'uids')),
            c -> 'resource' ->> 'op', c -> 'resource' ->> 'type', c -> 'resource' ->> 'uid',
            p_template_id, p_slots)
    on conflict on constraint cedar_policies_pkey do update
        set effect = excluded.effect, source = excluded.source, est = excluded.est, ast = excluded.ast,
            annotations = excluded.annotations,
            principal_op = excluded.principal_op, principal_type = excluded.principal_type, principal_uid = excluded.principal_uid,
            action_op = excluded.action_op, action_uids = excluded.action_uids,
            resource_op = excluded.resource_op, resource_type = excluded.resource_type, resource_uid = excluded.resource_uid,
            template_id = excluded.template_id, slots = excluded.slots;
    -- the scope index: one row per action (none for action in [], which
    -- matches no request)
    delete from permissions.cedar_policy_scopes s where s.policy_id = p_id;
    insert into permissions.cedar_policy_scopes (policy_id, action_key, principal_key, resource_key)
    select p_id, a.k,
           case c -> 'principal' ->> 'op' when 'All' then '*' else coalesce(c -> 'principal' ->> 'uid', c -> 'principal' ->> 'type') end,
           case c -> 'resource' ->> 'op' when 'All' then '*' else coalesce(c -> 'resource' ->> 'uid', c -> 'resource' ->> 'type') end
    from (select '*' as k where c -> 'action' ->> 'op' = 'All'
          union
          select jsonb_array_elements_text(c -> 'action' -> 'uids')) a;
$$;

-- Put (insert or replace) one static policy. Give exactly one of policy
-- (Cedar text, one policy) and policy_json (Cedar's JSON policy format, the
-- EST, as `cedar translate-policy` prints it). Text is parsed to the EST
-- here and kept as source; the EST is checked and compiled; requests never
-- parse. Annotations are metadata. The policy_id argument names the policy:
-- an @id annotation in the text stays an annotation (e-cedar.md section 13).
create function permissions.cedar_put_policy(policy_id text, policy text default null, policy_json jsonb default null)
returns void
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set standard_conforming_strings = on
as $$
declare
    est jsonb;
    c jsonb;
begin
    if policy_id is null or (cedar_put_policy.policy is null and policy_json is null) then
        perform permissions._cedar_error('null_argument',
            case when policy_id is null then 'policy_id is required to put a policy'
                 else format('policy %L needs policy (Cedar text) or policy_json: both are null', policy_id) end,
            hint => 'select permissions.cedar_put_policy(policy_id => ''view-own'', policy => ''permit (principal, action == Action::"view", resource) when { resource.owner == principal };'');',
            p_detail => format('argument=%L', case when policy_id is null then 'policy_id' else 'policy' end));
    end if;
    if cedar_put_policy.policy is not null and policy_json is not null then
        perform permissions._cedar_error('invalid_argument', format('policy %L has both policy and policy_json', policy_id),
            hint => 'Pass exactly one: policy => Cedar text, or policy_json => the same policy in Cedar''s JSON format.',
            p_detail => 'argument=''policy''');
    end if;
    est := coalesce(permissions._cedar_parse_policy(cedar_put_policy.policy), policy_json);
    perform permissions._cedar_check_id(policy_id, 'policy');
    c := permissions._cedar_compile_policy(est, policy_id, p_text => cedar_put_policy.policy is not null);
    perform permissions._cedar_store_policy(policy_id, cedar_put_policy.policy, est, c, null, null);
end;
$$;

-- Delete a static policy or a template link.
create function permissions.cedar_delete_policy(policy_id text)
returns void
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set standard_conforming_strings = on
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

-- Every policy, static and linked, by id: its effect, Cedar text (null when
-- put as JSON, and for a link), EST (a link's has the slots filled in) and
-- annotations; for a link, its template and slot values
-- ({"?principal": {"type", "id"}, "?resource": ...}).
create function permissions.cedar_policies()
returns table (policy_id text, effect text, source text, est jsonb, annotations jsonb, template_id text, slots jsonb)
language sql stable security definer
set search_path = pg_catalog, pg_temp
set standard_conforming_strings = on
as $$
    select c.policy_id, c.effect, c.source, c.est, c.annotations, c.template_id, c.slots
    from permissions.cedar_policies c
    order by c.policy_id
$$;

-- ----------------------------------------------------------------------------
-- Admin API: templates and links (phase 4c)
-- ----------------------------------------------------------------------------
-- A template is a policy with the slot ?principal in its principal scope, the
-- slot ?resource in its resource scope, or both (Cedar allows slots nowhere
-- else). A link fills every slot with an entity and becomes a policy of its
-- own, a row of cedar_policies under its own policy_id. The slots are filled
-- at link time (_cedar_link): the link stores the filled EST, the template's
-- compiled conditions and the filled scope columns, so a request treats a
-- link exactly like a static policy and never sees a slot (e-cedar.md
-- section 13). Replacing a template re-links its links.

-- The slots of a template's EST: '{?principal}', '{?resource}' or both.
create function permissions._cedar_template_slots(p_est jsonb)
returns text[]
language sql immutable
as $$
    select array_remove(array[
        case when p_est -> 'principal' ? 'slot' or coalesce(p_est #> '{principal,in}' ? 'slot', false) then '?principal' end,
        case when p_est -> 'resource' ? 'slot' or coalesce(p_est #> '{resource,in}' ? 'slot', false) then '?resource' end], null)
$$;

-- Store the link p_id of a template: fill the slots of its EST with p_values
-- ({"?principal": {"type", "id"}, ...}, every slot present), compile the
-- filled scopes, and reuse the template's compiled conditions (p_ast) and
-- annotations.
create function permissions._cedar_link(p_id text, p_template_id text, p_est jsonb, p_ast jsonb, p_annotations jsonb, p_values jsonb)
returns void
language plpgsql
as $$
declare
    est jsonb := p_est;
    s text;
    sc jsonb;
begin
    foreach s in array array['principal', 'resource'] loop
        sc := est -> s;
        if sc ? 'slot' then
            est := jsonb_set(est, array[s], (sc - 'slot') || jsonb_build_object('entity', p_values -> (sc ->> 'slot')));
        elsif jsonb_typeof(sc -> 'in') = 'object' and sc -> 'in' ? 'slot' then
            est := jsonb_set(est, array[s, 'in'], jsonb_build_object('entity', p_values -> (sc -> 'in' ->> 'slot')));
        end if;
    end loop;
    perform permissions._cedar_store_policy(p_id, null, est,
        jsonb_build_object('effect', est ->> 'effect', 'ast', p_ast, 'annotations', p_annotations,
                           'principal', permissions._cedar_compile_scope(est -> 'principal', 'principal'),
                           'action', permissions._cedar_compile_scope(est -> 'action', 'action'),
                           'resource', permissions._cedar_compile_scope(est -> 'resource', 'resource')),
        p_template_id, p_values);
end;
$$;

-- Put (insert or replace) one template. Give exactly one of template (Cedar
-- text) and template_json (Cedar's JSON policy format, with slots). When the
-- template exists and has links, each link is filled again from the new
-- template; the new template must keep the slots its links fill.
create function permissions.cedar_put_template(template_id text, template text default null, template_json jsonb default null)
returns void
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set standard_conforming_strings = on
as $$
declare
    est jsonb;
    c jsonb;
    want text[];
    bad text;
    l record;
begin
    if template_id is null or (cedar_put_template.template is null and template_json is null) then
        perform permissions._cedar_error('null_argument',
            case when template_id is null then 'template_id is required to put a template'
                 else format('template %L needs template (Cedar text) or template_json: both are null', template_id) end,
            hint => 'select permissions.cedar_put_template(template_id => ''owner-access'', template => ''permit (principal == ?principal, action, resource in ?resource);'');',
            p_detail => format('argument=%L', case when template_id is null then 'template_id' else 'template' end));
    end if;
    if cedar_put_template.template is not null and template_json is not null then
        perform permissions._cedar_error('invalid_argument', format('template %L has both template and template_json', template_id),
            hint => 'Pass exactly one: template => Cedar text, or template_json => the same template in Cedar''s JSON format.',
            p_detail => 'argument=''template''');
    end if;
    est := coalesce(permissions._cedar_parse_policy(cedar_put_template.template), template_json);
    perform permissions._cedar_check_id(template_id, 'template');
    c := permissions._cedar_compile_policy(est, template_id, p_template => true, p_text => cedar_put_template.template is not null);
    want := permissions._cedar_template_slots(est);
    -- Take the template's write lock before inspecting links. Linkers also
    -- update this row, so we see their links at READ COMMITTED or reject a
    -- stale snapshot at REPEATABLE READ / SERIALIZABLE.
    insert into permissions.cedar_templates as x (template_id, source, est, ast, annotations)
    values (cedar_put_template.template_id, cedar_put_template.template, est, nullif(c -> 'ast', 'null'), c -> 'annotations')
    on conflict on constraint cedar_templates_pkey do update
        set source = excluded.source, est = excluded.est, ast = excluded.ast, annotations = excluded.annotations;
    select string_agg(format('%s (%s)', x.policy_id, (select string_agg(k, ', ' order by k) from jsonb_object_keys(x.slots) k)), ', ' order by x.policy_id)
    into bad
    from permissions.cedar_policies x
    where x.template_id = cedar_put_template.template_id
      and array(select k from jsonb_object_keys(x.slots) k order by k) <> want;
    if bad is not null then
        perform permissions._cedar_error('template_in_use',
            format('template %L has links that fill other slots than the new template''s %s: %s', template_id, array_to_string(want, ' and '), bad),
            hint => 'Keep the slots of the template, or first delete those links with select permissions.cedar_delete_policy(policy_id => ...).',
            p_detail => format('template_id=%L', template_id));
    end if;
    for l in select x.policy_id, x.slots from permissions.cedar_policies x where x.template_id = cedar_put_template.template_id loop
        perform permissions._cedar_link(l.policy_id, template_id, est, nullif(c -> 'ast', 'null'), c -> 'annotations', l.slots);
    end loop;
end;
$$;

-- Link a template: the policy policy_id is the template with its slots
-- filled, ?principal with principal and ?resource with resource (uids in
-- Cedar text, Type::"id"). Give a value for exactly the template's slots.
-- Linking an existing link's id again replaces that link.
create function permissions.cedar_link_template(policy_id text, template_id text, principal text default null, resource text default null)
returns void
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set standard_conforming_strings = on
as $$
declare
    t record;
    u record;
    s text;
    given text;
    vals jsonb := '{}';
    want text[];
begin
    if policy_id is null or template_id is null then
        perform permissions._cedar_error('null_argument',
            format('%s is required to link a template', case when policy_id is null then 'policy_id' else 'template_id' end),
            hint => 'select permissions.cedar_link_template(policy_id => ''alice-docs'', template_id => ''owner-access'', principal => ''User::"alice"'', resource => ''Folder::"docs"'');',
            p_detail => format('argument=%L', case when policy_id is null then 'policy_id' else 'template_id' end));
    end if;
    -- Serialize linking and replacement on this template. A lock alone is
    -- insufficient: a repeatable-read replacer could miss this new link.
    -- A no-op write makes that stale snapshot fail with 40001 instead.
    update permissions.cedar_templates x set source = x.source
    where x.template_id = cedar_link_template.template_id
    returning x.est, x.ast, x.annotations into t;
    if not found then
        perform permissions._cedar_error('unknown_template', format('unknown template %L', template_id),
            hint => permissions._cedar_template_hint(template_id),
            p_detail => format('template_id=%L', template_id));
    end if;
    perform permissions._cedar_check_id(policy_id, 'link');
    want := permissions._cedar_template_slots(t.est);
    foreach s in array array['principal', 'resource'] loop
        given := case s when 'principal' then cedar_link_template.principal else cedar_link_template.resource end;
        if (('?' || s) = any(want)) <> (given is not null) then
            perform permissions._cedar_error('invalid_link',
                case when given is null then format('template %L has the slot ?%s, and the link gives it no value', template_id, s)
                     else format('template %L has no slot ?%s, and the link gives it %s', template_id, s, given) end,
                hint => format('Template %L has the slots %s: pass a value for each and nothing else, for example %s.', template_id,
                               array_to_string(want, ' and '),
                               (select string_agg(case w when '?principal' then 'principal => ''User::"alice"''' else 'resource => ''Folder::"docs"''' end, ', ')
                                from unnest(want) w)),
                p_detail => format('slot=%L', '?' || s));
        end if;
        if given is not null then
            select * into u from permissions._cedar_uid(given, s);
            vals := vals || jsonb_build_object('?' || s, jsonb_build_object('type', u.type, 'id', u.id));
        end if;
    end loop;
    perform permissions._cedar_link(policy_id, template_id, t.est, t.ast, t.annotations, vals);
end;
$$;

-- Delete a template that has no links.
create function permissions.cedar_delete_template(template_id text)
returns void
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set standard_conforming_strings = on
as $$
declare
    n bigint;
    first_links text;
begin
    select count(*), string_agg(x.policy_id, ', ' order by x.policy_id) filter (where x.r <= 5)
    into n, first_links
    from (select c.policy_id, row_number() over (order by c.policy_id) as r
          from permissions.cedar_policies c where c.template_id = cedar_delete_template.template_id) x;
    if n > 0 then
        perform permissions._cedar_error('template_in_use', format('template %L has %s link%s', template_id, n, case when n = 1 then '' else 's' end),
            hint => format('Delete its links first, with select permissions.cedar_delete_policy(policy_id => ...) for each: %s%s.',
                           first_links, case when n > 5 then ', ...' else '' end),
            p_detail => format('template_id=%L', template_id));
    end if;
    delete from permissions.cedar_templates x where x.template_id = cedar_delete_template.template_id;
    if not found then
        perform permissions._cedar_error(case when template_id is null then 'null_argument' else 'unknown_template' end,
            case when template_id is null then 'template_id is required to delete a template' else format('unknown template %L', template_id) end,
            hint => permissions._cedar_template_hint(template_id),
            p_detail => case when template_id is null then 'argument=''template_id''' else format('template_id=%L', template_id) end);
    end if;
end;
$$;

-- Every template, by id: its Cedar text (null when put as JSON), EST and
-- annotations. cedar_policies() lists the links, with their template_id.
create function permissions.cedar_templates()
returns table (template_id text, source text, est jsonb, annotations jsonb)
language sql stable security definer
set search_path = pg_catalog, pg_temp
set standard_conforming_strings = on
as $$
    select t.template_id, t.source, t.est, t.annotations
    from permissions.cedar_templates t
    order by t.template_id
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
set search_path = pg_catalog, pg_temp
set standard_conforming_strings = on
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
    v := permissions._cedar_entities_in(entities, 'entities', 'put_entities');
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
    if cardinality(cts) > 0 then
        -- Only additions can create cycles. Batches with no parents do not
        -- need this guard. Hold it until the caller's transaction finishes.
        insert into permissions._cedar_hierarchy_guard as g (one) values (true)
        on conflict (one) do update set one = excluded.one;
    end if;
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
set search_path = pg_catalog, pg_temp
set standard_conforming_strings = on
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
set search_path = pg_catalog, pg_temp
set standard_conforming_strings = on
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

-- A uid as Cedar text, for resource arguments built from row ids:
--   resource => permissions.cedar_uid('Document', id::text)
-- It escapes " and \ and control characters, as uid() does in the JS client,
-- so an id never changes how the text parses. The type is not checked here;
-- a bad type gives cedar:invalid_uid when the uid is used. A null argument
-- gives null. Pure, so any role may call it (granted to PUBLIC below).
create function permissions.cedar_uid(type text, id text)
returns text
language sql immutable strict parallel safe security definer
set search_path = pg_catalog, pg_temp
set standard_conforming_strings = on
as $$
    select permissions._cedar_uid_text(cedar_uid.type, cedar_uid.id)
$$;

-- Newly created Cedar objects start owner-only, regardless of the
-- installer's global or schema-local default privileges. Revoking only
-- PUBLIC leaves named-role defaults intact, exposing admin APIs and the
-- cache secret. Existing RBAC/FGA grants are left alone on upgrades.
-- The final grant in each script exposes only the current-subject API.
do $$
declare
    a record;
begin
    for a in
        select distinct 'function' as kind, p.oid::regprocedure::text as obj, x.grantee
        from pg_catalog.pg_proc p
        cross join lateral pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) x
        where p.pronamespace = 'permissions'::regnamespace and p.proname ~ '^_?cedar_' and x.grantee <> p.proowner
        union all
        select distinct case c.relkind when 'S' then 'sequence' else 'table' end, c.oid::regclass::text, x.grantee
        from pg_catalog.pg_class c
        cross join lateral (select acl.grantee from pg_catalog.aclexplode(c.relacl) acl union select 0::oid) x
        where c.relnamespace = 'permissions'::regnamespace and c.relkind in ('r', 'S')
          and c.relname ~ '^_?cedar_' and x.grantee <> c.relowner
    loop
        execute format('revoke all on %s %s from %s', a.kind, a.obj,
            case when a.grantee = 0 then 'public' else quote_ident(pg_catalog.pg_get_userbyid(a.grantee)) end);
    end loop;
end;
$$;
-- <<< cedar section: end

-- ============================================================================
-- 3. delete_subject also forgets the subject's Cedar entity and links (phase 6)
-- ============================================================================
-- >>> cleanup section: begin
-- tools/sync-upgrade.sh copies this section into the upgrade script, where
-- it replaces 0.0.1's delete_subject; `or replace` keeps its privileges.
--
-- Forget a subject everywhere, and return the number of rows deleted:
--   rbac  its role assignments (user subjects only)
--   fga   every tuple naming it as user (any userset of it too) or as object
--   cedar the entity <subject_type>::"<subject_id>" (the principal type is
--         the subject type verbatim, e-cedar.md section 7.1); its parent
--         edges (its memberships) and the edges that name it as a parent
--         (the memberships in it), so nothing stays `in` a deleted entity;
--         and the template links whose ?principal or ?resource slot names
--         it, so a reused id gets none of their access. Static policies and
--         templates are the app's code and stay, as do references to the
--         entity in other entities' attrs and tags.
create or replace function permissions.delete_subject(subject_type text, subject_id text)
returns bigint
language plpgsql security definer
set search_path = pg_catalog, pg_temp
set standard_conforming_strings = on
as $$
declare
    u jsonb := jsonb_build_object('type', subject_type, 'id', subject_id);
    total bigint := 0;
    n bigint;
begin
    delete from permissions.rbac_assignments a
    where delete_subject.subject_type = 'user' and a.user_id = delete_subject.subject_id;
    get diagnostics n = row_count;
    total := total + n;
    delete from permissions.fga_tuples t
    where (t.user_type = delete_subject.subject_type and t.user_id = delete_subject.subject_id)
       or (t.object_type = delete_subject.subject_type and t.object_id = delete_subject.subject_id);
    get diagnostics n = row_count;
    total := total + n;
    -- a link's scope rows in cedar_policy_scopes go with it (on delete cascade)
    delete from permissions.cedar_policies p
    where p.template_id is not null and (p.slots -> '?principal' = u or p.slots -> '?resource' = u);
    get diagnostics n = row_count;
    total := total + n;
    delete from permissions.cedar_entity_parents e
    where (e.type = delete_subject.subject_type and e.id = delete_subject.subject_id)
       or (e.parent_type = delete_subject.subject_type and e.parent_id = delete_subject.subject_id);
    get diagnostics n = row_count;
    total := total + n;
    delete from permissions.cedar_entities e
    where e.type = delete_subject.subject_type and e.id = delete_subject.subject_id;
    get diagnostics n = row_count;
    return total + n;
end;
$$;
-- <<< cleanup section: end

-- ============================================================================
-- 4. Privileges: the Cedar current-subject helpers (phase 5)
-- ============================================================================
-- The cedar section revokes every cedar_* function from PUBLIC; these two
-- are client-facing, as in the Privileges section of pg_permissions--0.1.0.sql.

grant execute on function
    permissions.cedar_is_authorized_current(text, text, jsonb, boolean),
    permissions.cedar_list_resources_current(text, text),
    permissions.cedar_uid(text, text)
to public;

-- ============================================================================
-- 5. Security review (0.1.0): the hint helper and function settings
-- ============================================================================
-- 0.0.1 set search_path to '' in its functions. Postgres then searches
-- pg_temp first for type and table names, so a caller's temporary domain
-- named text or jsonb ran its check as the owner of a security definer
-- function. Each function that sets search_path now sets pg_catalog,
-- pg_temp, and each security definer function also sets
-- standard_conforming_strings, as in pg_permissions--0.1.0.sql. ALTER keeps
-- a setting's position and adds a new one last, which is where the install
-- file declares it. The functions above already have these settings.

-- The hint for an unknown name skips names of another length before it
-- computes an edit distance, whose time grows with the square of the
-- input's length: fga_check_current raises with this hint, so a client's
-- long input held a backend for minutes. Copied from
-- pg_permissions--0.1.0.sql; `or replace` keeps its privileges.
create or replace function permissions._did_you_mean(p_input text, p_names text[], p_what text)
returns text
language sql immutable
as $$
    select concat(
        (select format('Did you mean ''%s''? ', n) from unnest(p_names) n
         where case when abs(char_length(lower(p_input)) - char_length(lower(n))) <= greatest(1, least(3, char_length(p_input) / 3))
                    then permissions._edit_distance(lower(p_input), lower(n)) <= greatest(1, least(3, char_length(p_input) / 3)) end
         order by permissions._edit_distance(lower(p_input), lower(n)), n limit 1),
        p_what, ': ',
        (select string_agg(n, ', ' order by n) from (select n from unnest(p_names) n order by n limit 20) l),
        case when cardinality(p_names) > 20 then format(' and %s more', cardinality(p_names) - 20) end,
        '.')
    where cardinality(p_names) > 0
$$;

do $$
declare
    f regprocedure;
begin
    for f in select p.oid::regprocedure from pg_catalog.pg_proc p
             where p.pronamespace = 'permissions'::regnamespace and 'search_path=""' = any(p.proconfig) loop
        execute pg_catalog.format('alter function %s set search_path = pg_catalog, pg_temp', f);
    end loop;
    for f in select p.oid::regprocedure from pg_catalog.pg_proc p
             where p.pronamespace = 'permissions'::regnamespace and p.prosecdef
               and not 'standard_conforming_strings=on' = any(coalesce(p.proconfig, '{}')) loop
        execute pg_catalog.format('alter function %s set standard_conforming_strings = on', f);
    end loop;
end;
$$;

-- ============================================================================
-- 6. Performance pass (0.1.0): PL/pgSQL for three hot SQL functions
-- ============================================================================
-- A SQL function that Postgres does not inline (one with a setting, or a
-- subquery) is planned again in every statement before Postgres 18; a
-- PL/pgSQL function caches its plans. current_subject_id and
-- current_subject_type run in every client check, _fga_path_exists in every
-- OpenFGA check and list. Same bodies, same results. Copied from
-- pg_permissions--0.1.0.sql; `or replace` keeps their privileges.

create or replace function permissions.current_subject_id()
returns text
language plpgsql stable
set search_path = pg_catalog, pg_temp
as $$
begin
    return coalesce(
        nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', ''),
        nullif(current_setting('permissions.subject_id', true), '')
    );
end;
$$;

create or replace function permissions.current_subject_type()
returns text
language plpgsql stable
set search_path = pg_catalog, pg_temp
as $$
begin
    return coalesce(nullif(current_setting('permissions.subject_type', true), ''), 'user');
end;
$$;

create or replace function permissions._fga_path_exists(p_m text, p_type text, p_rel text, p_ut text, p_urel text)
returns boolean
language plpgsql stable
as $$
begin
    return exists (
        select 1 from permissions.fga_paths p
        where p.model_id = p_m and p.type = p_type and p.relation = p_rel
          and p.user_type = p_ut and p.user_relation = p_urel
          and (p_urel = '' or not p.wildcard));
end;
$$;
