-- Throwaway measurement for research/designs/e-cedar.md, "Evaluator" (tag:
-- cedar-eval-micro). Not a benchmark baseline and not part of the extension.
--
--   research/designs/e-cedar/measure.sh
--
-- One condition, typical of the corpus (scope All, one `when`):
--   principal.department == "Eng" && principal.level >= 3
--     && resource has owner && resource.owner == principal
-- evaluated for 100,000 rows; each row has its own principal and resource.
--
-- Variants (all PL/pgSQL tree walks unless noted):
--   inline       the same test written in SQL (the floor; no Cedar semantics)
--   est_comp     Cedar's JSON policy format as stored (EST); the node kind is
--                the object's only key (jsonb_object_keys); returns a composite
--                (value jsonb, error text)
--   ast_comp     a compiled tree: {"k": kind, ...} with literals pre-converted;
--                returns the composite
--   ast_null     the compiled tree; returns jsonb, SQL NULL for an error (the
--                message is recomputed only when a caller needs it)
--   ast_lookup   ast_null, but entity attributes come from an indexed table
--                (one lookup per attribute access), as in cedar_is_authorized
\set ON_ERROR_STOP on
create schema m;
set search_path = m, public;

create type m.r as (v jsonb, e text);

create table m.entities (type text collate "C", id text collate "C", attrs jsonb, primary key (type, id));
insert into m.entities
select 'User', 'u' || g, jsonb_build_object('department', case when g % 3 = 0 then 'Sales' else 'Eng' end, 'level', g % 5)
from generate_series(1, 100000) g;
insert into m.entities
select 'Doc', 'd' || g, case when g % 7 = 0 then '{}'::jsonb
       else jsonb_build_object('owner', jsonb_build_object('__entity', jsonb_build_object('type', 'User', 'id', 'u' || g))) end
from generate_series(1, 100000) g;
analyze m.entities;

-- env: the request, with the attributes of principal and resource inlined
-- (variants without lookup) under "attrs".
create table m.rows as
select g,
       jsonb_build_object(
         'principal', jsonb_build_object('__entity', jsonb_build_object('type', 'User', 'id', 'u' || g)),
         'resource',  jsonb_build_object('__entity', jsonb_build_object('type', 'Doc', 'id', 'd' || g)),
         'context', '{}'::jsonb,
         'attrs', jsonb_build_object('User::u' || g, u.attrs, 'Doc::d' || g, d.attrs)) as env,
       jsonb_build_object(
         'principal', jsonb_build_object('__entity', jsonb_build_object('type', 'User', 'id', 'u' || g)),
         'resource',  jsonb_build_object('__entity', jsonb_build_object('type', 'Doc', 'id', 'd' || g)),
         'context', '{}'::jsonb) as req
from generate_series(1, 100000) g
join m.entities u on u.type = 'User' and u.id = 'u' || g
join m.entities d on d.type = 'Doc' and d.id = 'd' || g;
analyze m.rows;

create function m.attrs_inline(p_env jsonb, p_uid jsonb) returns jsonb
language sql immutable as $$
    select p_env -> 'attrs' -> ((p_uid -> '__entity' ->> 'type') || '::' || (p_uid -> '__entity' ->> 'id'))
$$;

create function m.attrs_table(p_uid jsonb) returns jsonb
language sql stable as $$
    select attrs from m.entities
    where type = p_uid -> '__entity' ->> 'type' and id = p_uid -> '__entity' ->> 'id'
$$;

-- est_comp: Cedar's JSON policy format, walked as is.
create function m.est(n jsonb, env jsonb) returns m.r
language plpgsql stable as $$
declare
    op text;
    a jsonb;
    x m.r;
    y m.r;
    at jsonb;
begin
    select k into op from jsonb_object_keys(n) k;
    a := n -> op;
    case op
    when 'Value' then return row(a, null)::m.r;
    when 'Var' then return row(env -> (a #>> '{}'), null)::m.r;
    when '&&', '||' then
        x := m.est(a -> 'left', env);
        if x.e is not null then return x; end if;
        if jsonb_typeof(x.v) <> 'boolean' then return row(null, 'type error')::m.r; end if;
        if (op = '&&') <> (x.v = 'true') then return x; end if;
        y := m.est(a -> 'right', env);
        if y.e is not null then return y; end if;
        if jsonb_typeof(y.v) <> 'boolean' then return row(null, 'type error')::m.r; end if;
        return y;
    when '==' then
        x := m.est(a -> 'left', env);
        if x.e is not null then return x; end if;
        y := m.est(a -> 'right', env);
        if y.e is not null then return y; end if;
        return row(to_jsonb(x.v = y.v), null)::m.r;
    when '>=' then
        x := m.est(a -> 'left', env);
        if x.e is not null then return x; end if;
        y := m.est(a -> 'right', env);
        if y.e is not null then return y; end if;
        if jsonb_typeof(x.v) <> 'number' or jsonb_typeof(y.v) <> 'number' then return row(null, 'type error')::m.r; end if;
        return row(to_jsonb(x.v::numeric >= y.v::numeric), null)::m.r;
    when '.', 'has' then
        x := m.est(a -> 'left', env);
        if x.e is not null then return x; end if;
        at := case when x.v ? '__entity' then m.attrs_inline(env, x.v) else x.v end;
        if op = 'has' then return row(to_jsonb(coalesce(at ? (a ->> 'attr'), false)), null)::m.r; end if;
        if at is null or not at ? (a ->> 'attr') then return row(null, 'attribute not found')::m.r; end if;
        return row(at -> (a ->> 'attr'), null)::m.r;
    end case;
end $$;

-- ast_comp: compiled tree, composite result.
create function m.astc(n jsonb, env jsonb) returns m.r
language plpgsql stable as $$
declare
    k text := n ->> 'k';
    x m.r;
    y m.r;
    at jsonb;
begin
    case k
    when 'lit' then return row(n -> 'v', null)::m.r;
    when 'var' then return row(env -> (n ->> 'n'), null)::m.r;
    when 'and', 'or' then
        x := m.astc(n -> 'a', env);
        if x.e is not null then return x; end if;
        if jsonb_typeof(x.v) <> 'boolean' then return row(null, 'type error')::m.r; end if;
        if (k = 'and') <> (x.v = 'true') then return x; end if;
        y := m.astc(n -> 'b', env);
        if y.e is not null then return y; end if;
        if jsonb_typeof(y.v) <> 'boolean' then return row(null, 'type error')::m.r; end if;
        return y;
    when 'eq' then
        x := m.astc(n -> 'a', env);
        if x.e is not null then return x; end if;
        y := m.astc(n -> 'b', env);
        if y.e is not null then return y; end if;
        return row(to_jsonb(x.v = y.v), null)::m.r;
    when 'ge' then
        x := m.astc(n -> 'a', env);
        if x.e is not null then return x; end if;
        y := m.astc(n -> 'b', env);
        if y.e is not null then return y; end if;
        if jsonb_typeof(x.v) <> 'number' or jsonb_typeof(y.v) <> 'number' then return row(null, 'type error')::m.r; end if;
        return row(to_jsonb(x.v::numeric >= y.v::numeric), null)::m.r;
    when 'get', 'has' then
        x := m.astc(n -> 'a', env);
        if x.e is not null then return x; end if;
        at := case when x.v ? '__entity' then m.attrs_inline(env, x.v) else x.v end;
        if k = 'has' then return row(to_jsonb(coalesce(at ? (n ->> 'f'), false)), null)::m.r; end if;
        if at is null or not at ? (n ->> 'f') then return row(null, 'attribute not found')::m.r; end if;
        return row(at -> (n ->> 'f'), null)::m.r;
    end case;
end $$;

-- ast_null / ast_lookup: compiled tree, jsonb result, NULL is an error.
create function m.astn(n jsonb, env jsonb, lookup boolean) returns jsonb
language plpgsql stable as $$
declare
    k text := n ->> 'k';
    x jsonb;
    y jsonb;
    at jsonb;
begin
    case k
    when 'lit' then return n -> 'v';
    when 'var' then return env -> (n ->> 'n');
    when 'and', 'or' then
        x := m.astn(n -> 'a', env, lookup);
        if x is null or jsonb_typeof(x) <> 'boolean' then return null; end if;
        if (k = 'and') <> (x = 'true') then return x; end if;
        y := m.astn(n -> 'b', env, lookup);
        if y is null or jsonb_typeof(y) <> 'boolean' then return null; end if;
        return y;
    when 'eq' then
        x := m.astn(n -> 'a', env, lookup);
        if x is null then return null; end if;
        y := m.astn(n -> 'b', env, lookup);
        if y is null then return null; end if;
        return to_jsonb(x = y);
    when 'ge' then
        x := m.astn(n -> 'a', env, lookup);
        if x is null then return null; end if;
        y := m.astn(n -> 'b', env, lookup);
        if y is null then return null; end if;
        if jsonb_typeof(x) <> 'number' or jsonb_typeof(y) <> 'number' then return null; end if;
        return to_jsonb(x::numeric >= y::numeric);
    when 'get', 'has' then
        x := m.astn(n -> 'a', env, lookup);
        if x is null then return null; end if;
        at := case when not x ? '__entity' then x
                   when lookup then m.attrs_table(x)
                   else m.attrs_inline(env, x) end;
        if k = 'has' then return to_jsonb(coalesce(at ? (n ->> 'f'), false)); end if;
        return at -> (n ->> 'f');
    end case;
end $$;

create table m.results (variant text, ms numeric, n bigint);
create function m.time(p_variant text, p_where text) returns void
language plpgsql as $$
declare t0 timestamptz; n bigint; best numeric := null; dt numeric;
begin
    for k in 1..5 loop
        t0 := clock_timestamp();
        execute format('select count(*) from m.rows where %s', p_where) into n;
        dt := extract(epoch from clock_timestamp() - t0) * 1000;
        if best is null or dt < best then best := dt; end if;
    end loop;
    insert into m.results values (p_variant, round(best, 1), n);
end $$;

\set est '''{"&&":{"left":{"&&":{"left":{"&&":{"left":{"==":{"left":{".":{"left":{"Var":"principal"},"attr":"department"}},"right":{"Value":"Eng"}}},"right":{">=":{"left":{".":{"left":{"Var":"principal"},"attr":"level"}},"right":{"Value":3}}}}},"right":{"has":{"left":{"Var":"resource"},"attr":"owner"}}}},"right":{"==":{"left":{".":{"left":{"Var":"resource"},"attr":"owner"}},"right":{"Var":"principal"}}}}}''::jsonb'
\set ast '''{"k":"and","a":{"k":"and","a":{"k":"and","a":{"k":"eq","a":{"k":"get","a":{"k":"var","n":"principal"},"f":"department"},"b":{"k":"lit","v":"Eng"}},"b":{"k":"ge","a":{"k":"get","a":{"k":"var","n":"principal"},"f":"level"},"b":{"k":"lit","v":3}}},"b":{"k":"has","a":{"k":"var","n":"resource"},"f":"owner"}},"b":{"k":"eq","a":{"k":"get","a":{"k":"var","n":"resource"},"f":"owner"},"b":{"k":"var","n":"principal"}}}''::jsonb'

select m.time('none', 'true');
select m.time('inline', $$(env -> 'attrs' -> ('User::u' || g) ->> 'department') = 'Eng'
    and (env -> 'attrs' -> ('User::u' || g) -> 'level')::numeric >= 3
    and (env -> 'attrs' -> ('Doc::d' || g)) ? 'owner'
    and (env -> 'attrs' -> ('Doc::d' || g) -> 'owner') = env -> 'principal'$$);
select m.time('est_comp', format('(m.est(%L::jsonb, env)).v = ''true''', :est));
select m.time('ast_comp', format('(m.astc(%L::jsonb, env)).v = ''true''', :ast));
select m.time('ast_null', format('m.astn(%L::jsonb, env, false) = ''true''', :ast));
select m.time('ast_lookup', format('m.astn(%L::jsonb, req, true) = ''true''', :ast));

select variant, ms as "ms per 100k", round(ms * 1000 / 100000, 2) as "us per eval", n
from m.results order by ms;
