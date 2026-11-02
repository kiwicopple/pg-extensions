/*
 * Minimal TAP assertions for the pg_permissions test suite.
 *
 * Function names and arguments follow pgTAP (https://pgtap.org), so tests can
 * move to pgTAP later by swapping `tap.` for the pgTAP schema. This file exists
 * so the suite runs anywhere psql does, with no extensions installed.
 *
 * Every assertion returns one TAP line ("ok 3 - ..." or "not ok 3 - ...").
 * Failures add "# ..." diagnostic lines. test/run.sh parses the output.
 */

create schema tap;

create table tap.state (
    ran     int not null default 0,
    planned int
);
insert into tap.state default values;

create function tap.plan(p_count int)
returns text
language sql
as $$
    update tap.state set planned = p_count;
    select '1..' || p_count;
$$;

create function tap._emit(p_pass boolean, p_description text, p_diag text default null)
returns text
language plpgsql
as $$
declare
    n    int;
    line text;
begin
    update tap.state set ran = ran + 1 returning ran into n;
    line := case when p_pass then 'ok ' else 'not ok ' end || n || ' - ' || coalesce(p_description, '');
    if not p_pass and p_diag is not null then
        line := line || E'\n# ' || replace(p_diag, E'\n', E'\n# ');
    end if;
    return line;
end;
$$;

create function tap.pass(p_description text default null)
returns text language sql as $$ select tap._emit(true, p_description) $$;

create function tap.fail(p_description text default null)
returns text language sql as $$ select tap._emit(false, p_description) $$;

create function tap.ok(p_value boolean, p_description text default null)
returns text
language sql
as $$
    select tap._emit(coalesce(p_value, false), p_description, case when p_value is null then 'got: NULL' end)
$$;

create function tap.is(p_got anyelement, p_want anyelement, p_description text default null)
returns text
language sql
as $$
    select tap._emit(
        p_got is not distinct from p_want, p_description,
        format('got:  %s' || E'\n' || 'want: %s', coalesce(p_got::text, 'NULL'), coalesce(p_want::text, 'NULL')))
$$;

create function tap.isnt(p_got anyelement, p_want anyelement, p_description text default null)
returns text
language sql
as $$
    select tap._emit(
        p_got is distinct from p_want, p_description,
        format('got %s, expected anything else', coalesce(p_got::text, 'NULL')))
$$;

-- Compare two arrays as sets (order and duplicates ignored).
create function tap.set_eq(p_got anyarray, p_want anyarray, p_description text default null)
returns text
language sql
as $$
    with g as (select array(select distinct x::text from unnest(p_got) x order by 1) a),
         w as (select array(select distinct x::text from unnest(p_want) x order by 1) a)
    select tap._emit(
        p_got is not null and g.a = w.a, p_description,
        format('got:  %s' || E'\n' || 'want: %s', coalesce(g.a::text, 'NULL'), w.a::text))
    from g, w
$$;

-- Passes if p_sql raises. p_errcode is a 5-character SQLSTATE, or null for any error.
create function tap.throws_ok(p_sql text, p_errcode text default null, p_description text default null)
returns text
language plpgsql
as $$
begin
    execute p_sql;
    return tap._emit(false, p_description, 'no exception raised');
exception when others then
    if p_errcode is null or sqlstate = p_errcode then
        return tap._emit(true, p_description);
    end if;
    return tap._emit(false, p_description, format('got SQLSTATE %s (%s), want %s', sqlstate, sqlerrm, p_errcode));
end;
$$;

create function tap.lives_ok(p_sql text, p_description text default null)
returns text
language plpgsql
as $$
begin
    execute p_sql;
    return tap._emit(true, p_description);
exception when others then
    return tap._emit(false, p_description, format('raised SQLSTATE %s: %s', sqlstate, sqlerrm));
end;
$$;

-- Prints a diagnostic if the number of assertions run doesn't match the plan.
create function tap.finish()
returns setof text
language sql
as $$
    select format('# Looks like you planned %s tests but ran %s.', planned, ran)
    from tap.state where planned is distinct from ran
$$;

-- Tests switch roles (set role authenticated); they still need to record results.
grant usage on schema tap to public;
grant all on tap.state to public;
grant execute on all functions in schema tap to public;
