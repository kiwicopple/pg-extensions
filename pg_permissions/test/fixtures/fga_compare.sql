-- Helpers for d/32_fga_set_based and d/33_fga_walk_pruning: compare
-- ListObjects and ListUsers with the answer Check gives for every object or
-- user in the store, one Check per candidate. For a monotone relation Check is
-- the bidirectional search (no pruning by target, no compiled walk steps);
-- for any other relation it is _fga_rec, the per-candidate path that
-- ListObjects and ListUsers used before the set-based difference. Each helper
-- returns 'ok' or what differed; an error counts as the answer
-- ('error openfga:<code>').
create schema if not exists fga_cmp;

-- The statement's single text result, or 'error <openfga code or sqlstate>'.
create function fga_cmp.try(p_sql text)
returns text
language plpgsql
as $$
declare
    r text;
    st text;
    det text;
begin
    execute p_sql into r;
    return r;
exception when others then
    get stacked diagnostics st = returned_sqlstate, det = pg_exception_detail;
    return 'error ' || case when det like 'openfga:%' then split_part(det, ' ', 1) else 'sqlstate:' || st end;
end;
$$;

-- Every id of p_type in the stored tuples (as object or as user) and in p_ctx.
create function fga_cmp.ids(p_type text, p_ctx jsonb)
returns setof text
language sql
as $$
    select t.object_id from permissions.fga_tuples t where t.object_type = p_type
    union
    select t.user_id from permissions.fga_tuples t where t.user_type = p_type and t.user_id <> '*'
    union
    select substr(e ->> k, strpos(e ->> k, ':') + 1)
    from jsonb_array_elements(coalesce(p_ctx, '[]')) e, unnest('{object,user}'::text[]) k
    where split_part(e ->> k, ':', 1) = p_type and e ->> k not like '%#%' and e ->> k not like '%:*'
$$;

create function fga_cmp.list_objects(p_user text, p_type text, p_relation text, p_ctx jsonb default null)
returns text
language plpgsql
as $$
declare
    got text := fga_cmp.try(format(
        'select coalesce(array_agg(x order by x), ''{}'')::text from permissions.fga_list_objects(%L, %L, %L, %L::jsonb) x',
        p_user, p_type, p_relation, p_ctx));
    want text := fga_cmp.try(format(
        'select coalesce(array_agg(o order by o), ''{}'')::text
         from (select %L || '':'' || i as o from fga_cmp.ids(%L, %L::jsonb) i) c
         where permissions.fga_check(%L, %L, o, %L::jsonb)',
        p_type, p_type, p_ctx, p_user, p_relation, p_ctx));
begin
    return case when got = want then 'ok' else format('got %s, want %s', got, want) end;
end;
$$;

-- p_filter 'type' (plain users and the type's wildcard) or 'type#relation'.
-- Like OpenFGA, ListUsers names the wildcard rather than every user it
-- covers, so: every listed user checks true, and every user that checks true
-- is listed, or is a plain user whose type's wildcard is listed.
create function fga_cmp.list_users(p_object text, p_relation text, p_filter text, p_ctx jsonb default null)
returns text
language plpgsql
as $$
declare
    ft text := split_part(p_filter, '#', 1);
    fr text := split_part(p_filter, '#', 2);
    got text := fga_cmp.try(format(
        'select coalesce(array_agg(x order by x), ''{}'')::text from permissions.fga_list_users(%L, %L, %L::text[], %L::jsonb) x',
        p_object, p_relation, array[p_filter], p_ctx));
    want text := fga_cmp.try(format(
        'select coalesce(array_agg(u order by u), ''{}'')::text
         from (select %L || '':'' || i || case when %L <> '''' then ''#'' || %L else '''' end as u
               from (select i from fga_cmp.ids(%L, %L::jsonb) i
                     union select ''*'' where %L = '''') c) c
         where permissions.fga_check(u, %L, %L, %L::jsonb)',
        ft, fr, fr, ft, p_ctx, fr, p_relation, p_object, p_ctx));
    missing text;
begin
    if got like 'error%' or want like 'error%' then
        return case when got = want then 'ok' else format('got %s, want %s', got, want) end;
    end if;
    if not got::text[] <@ want::text[] then
        return format('got %s, but only %s check true', got, want);
    end if;
    select string_agg(u, ',') into missing
    from unnest(want::text[]) u
    where u <> all (got::text[])
      and not (fr = '' and ft || ':*' = any (got::text[]));
    return case when missing is null then 'ok' else format('got %s, missing %s', got, missing) end;
end;
$$;
