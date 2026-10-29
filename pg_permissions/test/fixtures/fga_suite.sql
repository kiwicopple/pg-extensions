-- Helpers for the generated OpenFGA suite specs (test/spec/d/6x_fga_*.sql,
-- written by test/fga/generate.py). Each helper runs one upstream assertion
-- and returns 'ok', or a description of what differed, so a wrong answer or an
-- unexpected error fails that one TAP test and the file carries on.
--
-- Errors: Design D raises with DETAIL 'openfga:<code>' (designs/d-per-model.md,
-- "Errors"); fga_test.code_of() reads it back.
create schema if not exists fga_test;

-- 'ok' if the statement runs, else 'openfga:<code>' or 'sqlstate:<state>', then the message.
create function fga_test.code_of(p_sql text)
returns text
language plpgsql
as $$
declare
    st text; msg text; det text;
begin
    execute p_sql;
    return 'ok';
exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text, det = pg_exception_detail;
    if det like 'openfga:%' then
        return split_part(det, ' ', 1) || ' ' || msg;
    end if;
    return 'sqlstate:' || st || ' ' || msg;
end;
$$;

create function fga_test._want_code(p_got text, p_code int)
returns text
language sql
as $$
    select case when p_got like 'openfga:' || p_code || ' %' then 'ok'
                else 'expected openfga:' || p_code || ', got ' || p_got end
$$;

create function fga_test.check(p_user text, p_relation text, p_object text, p_ctx jsonb,
                               p_want boolean, p_code int, p_model text)
returns text
language plpgsql
as $$
declare
    got boolean;
    err text;
begin
    if p_code is not null then
        return fga_test._want_code(fga_test.code_of(format(
            'select permissions.fga_check(%L, %L, %L, %L::jsonb, %L)',
            p_user, p_relation, p_object, p_ctx, p_model)), p_code);
    end if;
    begin
        got := permissions.fga_check(p_user, p_relation, p_object, p_ctx, p_model);
    exception when others then
        get stacked diagnostics err = pg_exception_detail;
        return 'error ' || coalesce(err, '') || ' ' || sqlerrm;
    end;
    if got is distinct from p_want then
        return format('expected %s, got %s', p_want, got);
    end if;
    return 'ok';
end;
$$;

-- Like the upstream harness: the objects match as a set, and each returned
-- object checks true with the same contextual tuples.
create function fga_test.list_objects(p_user text, p_type text, p_relation text, p_ctx jsonb,
                                      p_want text[], p_code int, p_model text)
returns text
language plpgsql
as $$
declare
    got text[];
    bad text;
    err text;
begin
    if p_code is not null then
        return fga_test._want_code(fga_test.code_of(format(
            'select array(select permissions.fga_list_objects(%L, %L, %L, %L::jsonb, %L))',
            p_user, p_type, p_relation, p_ctx, p_model)), p_code);
    end if;
    begin
        got := array(select permissions.fga_list_objects(p_user, p_type, p_relation, p_ctx, p_model));
        select string_agg(o, ', ') into bad from unnest(got) o
        where not permissions.fga_check(p_user, p_relation, o, p_ctx, p_model);
    exception when others then
        get stacked diagnostics err = pg_exception_detail;
        return 'error ' || coalesce(err, '') || ' ' || sqlerrm;
    end;
    if cardinality(got) <> (select count(distinct x) from unnest(got) x) then
        return format('duplicates in %s', got);
    end if;
    if not (got <@ coalesce(p_want, '{}') and coalesce(p_want, '{}') <@ got) then
        return format('expected %s, got %s', coalesce(p_want, '{}'), got);
    end if;
    if bad is not null then
        return format('listed but check is false: %s', bad);
    end if;
    return 'ok';
end;
$$;

create function fga_test.list_users(p_object text, p_relation text, p_filters text[], p_ctx jsonb,
                                    p_want text[], p_code int, p_model text)
returns text
language plpgsql
as $$
declare
    got text[];
    bad text;
    err text;
begin
    if p_code is not null then
        return fga_test._want_code(fga_test.code_of(format(
            'select array(select permissions.fga_list_users(%L, %L, %L::text[], %L::jsonb, %L))',
            p_object, p_relation, p_filters, p_ctx, p_model)), p_code);
    end if;
    begin
        got := array(select permissions.fga_list_users(p_object, p_relation, p_filters, p_ctx, p_model));
        select string_agg(u, ', ') into bad from unnest(got) u
        where not permissions.fga_check(u, p_relation, p_object, p_ctx, p_model);
    exception when others then
        get stacked diagnostics err = pg_exception_detail;
        return 'error ' || coalesce(err, '') || ' ' || sqlerrm;
    end;
    if cardinality(got) <> (select count(distinct x) from unnest(got) x) then
        return format('duplicates in %s', got);
    end if;
    if not (got <@ coalesce(p_want, '{}') and coalesce(p_want, '{}') <@ got) then
        return format('expected %s, got %s', coalesce(p_want, '{}'), got);
    end if;
    if bad is not null then
        return format('listed but check is false: %s', bad);
    end if;
    return 'ok';
end;
$$;
