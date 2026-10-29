-- Helpers for the generated OpenFGA ABAC suite specs (test/fga_abac/spec/ or,
-- with --suite, test/spec/d/6[34]_fga_abac_*.sql, written by
-- test/fga_abac/generate.py). Load after fga_suite.sql. Like its helpers, each
-- runs one upstream assertion and returns 'ok' or what differed; these also
-- pass the request's condition context as the check functions' `context`
-- argument (designs/d-conditions.md, API). The argument does not exist before
-- phase 4's evaluator: until then every assertion here fails.

create function fga_test.check_c(p_user text, p_relation text, p_object text, p_ctx jsonb, p_context jsonb,
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
            'select permissions.fga_check(%L, %L, %L, %L::jsonb, %L, context => %L::jsonb)',
            p_user, p_relation, p_object, p_ctx, p_model, p_context)), p_code);
    end if;
    begin
        execute format('select permissions.fga_check(%L, %L, %L, %L::jsonb, %L, context => %L::jsonb)',
                       p_user, p_relation, p_object, p_ctx, p_model, p_context) into got;
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

-- The objects match as a set, and each returned object checks true with the
-- same contextual tuples and context (upstream's harness does the same).
create function fga_test.list_objects_c(p_user text, p_type text, p_relation text, p_ctx jsonb, p_context jsonb,
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
            'select array(select permissions.fga_list_objects(%L, %L, %L, %L::jsonb, %L, context => %L::jsonb))',
            p_user, p_type, p_relation, p_ctx, p_model, p_context)), p_code);
    end if;
    begin
        execute format('select array(select permissions.fga_list_objects(%L, %L, %L, %L::jsonb, %L, context => %L::jsonb))',
                       p_user, p_type, p_relation, p_ctx, p_model, p_context) into got;
        select string_agg(o, ', ') into bad from unnest(got) o
        where not fga_test.check_c(p_user, p_relation, o, p_ctx, p_context, true, null, p_model) = 'ok';
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
        return format('listed but check is not true: %s', bad);
    end if;
    return 'ok';
end;
$$;

create function fga_test.list_users_c(p_object text, p_relation text, p_filters text[], p_ctx jsonb, p_context jsonb,
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
            'select array(select permissions.fga_list_users(%L, %L, %L::text[], %L::jsonb, %L, context => %L::jsonb))',
            p_object, p_relation, p_filters, p_ctx, p_model, p_context)), p_code);
    end if;
    begin
        execute format('select array(select permissions.fga_list_users(%L, %L, %L::text[], %L::jsonb, %L, context => %L::jsonb))',
                       p_object, p_relation, p_filters, p_ctx, p_model, p_context) into got;
        select string_agg(u, ', ') into bad from unnest(got) u
        where not fga_test.check_c(u, p_relation, p_object, p_ctx, p_context, true, null, p_model) = 'ok';
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
        return format('listed but check is not true: %s', bad);
    end if;
    return 'ok';
end;
$$;
