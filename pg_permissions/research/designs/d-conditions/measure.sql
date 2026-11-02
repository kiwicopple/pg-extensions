-- Throwaway measurement for research/designs/d-conditions.md, section 9 (tag:
-- cond-eval-micro). Not a benchmark baseline and not part of the extension:
-- it compares ways to evaluate one condition per row, the way a walk would
-- call it for each conditioned tuple it reads.
--
--   research/designs/d-conditions/measure.sh      # throwaway cluster, prints ms per variant
--
-- Expressions (from abac_tests.yaml): x < 100; ts < timestamp("2023-10-11T10:00:00.000Z");
-- x < 100 || y < 50. Each variant evaluates it for 100,000 rows with the
-- request context {"x": 10, "y": 60, "ts": "2023-10-11T09:00:00.000Z"}; a row
-- counts when the condition is true.
--
-- Variants:
--   none       no condition (the floor: the loop over rows)
--   inline     the predicate written in SQL in the query (what compiling to a
--              SQL expression and splicing it into the walk would give)
--   sqlfn      a generated LANGUAGE sql function per condition
--   plpgsql    a generated PL/pgSQL function per condition
--   execute    the generated SQL text run with EXECUTE ... USING per row
--   tree_jsonb a PL/pgSQL tree-walking interpreter over a jsonb AST
--   tree_array the same interpreter over the AST as parallel arrays (one row
--              per condition, loaded once per call)
\set ON_ERROR_STOP on
create schema m;
set search_path = m, public;

create type m.v as (t "char", b boolean, i bigint, d float8, s text, ts timestamptz);

-- Parameters: the context value converted to the parameter's type.
create function m.param(p_ctx jsonb, p_name text, p_type text) returns m.v
language plpgsql immutable as $$
declare j jsonb := p_ctx -> p_name;
begin
    if j is null then return row('E', null, null, null, 'missing ' || p_name, null)::m.v; end if;
    case p_type
      when 'int' then return row('i', null, (j #>> '{}')::numeric::bigint, null, null, null)::m.v;
      when 'timestamp' then return row('t', null, null, null, null, (j #>> '{}')::timestamptz)::m.v;
    end case;
end $$;

-- tree_jsonb: {"op": "<", "a": node, "b": node} | {"id": "x", "type": "int"} | {"int": 100}
--             | {"call": "timestamp", "arg": node} | {"str": "..."} | {"op": "||", ...}
create function m.ev(n jsonb, p_ctx jsonb) returns m.v
language plpgsql immutable as $$
declare a m.v; b m.v; op text := n ->> 'op';
begin
    if op is null then
        if n ? 'id' then return m.param(p_ctx, n ->> 'id', n ->> 'type'); end if;
        if n ? 'int' then return row('i', null, (n ->> 'int')::bigint, null, null, null)::m.v; end if;
        if n ? 'str' then return row('s', null, null, null, n ->> 'str', null)::m.v; end if;
        if n ? 'call' then
            a := m.ev(n -> 'arg', p_ctx);
            if a.t = 'E' then return a; end if;
            return row('t', null, null, null, null, a.s::timestamptz)::m.v;
        end if;
    end if;
    a := m.ev(n -> 'a', p_ctx);
    if op = '||' then
        if a.t = 'b' and a.b then return a; end if;
        b := m.ev(n -> 'b', p_ctx);
        if b.t = 'b' and b.b then return b; end if;
        if a.t = 'E' then return a; end if;
        return b;
    end if;
    b := m.ev(n -> 'b', p_ctx);
    if a.t = 'E' then return a; end if;
    if b.t = 'E' then return b; end if;
    if op = '<' then
        return row('b', case a.t when 'i' then a.i < b.i when 't' then a.ts < b.ts end, null, null, null, null)::m.v;
    end if;
    raise exception 'op %', op;
end $$;

create function m.eval_tree_jsonb(p_ast jsonb, p_ctx jsonb) returns boolean
language plpgsql immutable as $$
declare r m.v := m.ev(p_ast, p_ctx);
begin
    if r.t = 'E' then raise exception 'condition error: %', r.s; end if;
    return r.b;
end $$;

-- tree_array: the same tree, preorder, as arrays: op, left child, right child, literal, type.
create table m.cond_nodes (name text primary key, op text[], l int[], r int[], lit text[], typ text[]);
create function m.eva(op text[], l int[], r int[], lit text[], typ text[], k int, p_ctx jsonb) returns m.v
language plpgsql immutable as $$
declare a m.v; b m.v;
begin
    case op[k]
      when 'id' then return m.param(p_ctx, lit[k], typ[k]);
      when 'int' then return row('i', null, lit[k]::bigint, null, null, null)::m.v;
      when 'str' then return row('s', null, null, null, lit[k], null)::m.v;
      when 'timestamp' then
        a := m.eva(op, l, r, lit, typ, l[k], p_ctx);
        if a.t = 'E' then return a; end if;
        return row('t', null, null, null, null, a.s::timestamptz)::m.v;
      when '||' then
        a := m.eva(op, l, r, lit, typ, l[k], p_ctx);
        if a.t = 'b' and a.b then return a; end if;
        b := m.eva(op, l, r, lit, typ, r[k], p_ctx);
        if b.t = 'b' and b.b then return b; end if;
        if a.t = 'E' then return a; end if;
        return b;
      else
        a := m.eva(op, l, r, lit, typ, l[k], p_ctx);
        b := m.eva(op, l, r, lit, typ, r[k], p_ctx);
        if a.t = 'E' then return a; end if;
        if b.t = 'E' then return b; end if;
        return row('b', case a.t when 'i' then a.i < b.i when 't' then a.ts < b.ts end, null, null, null, null)::m.v;
    end case;
end $$;
create function m.eval_tree_array(p_name text, p_ctx jsonb) returns boolean
language plpgsql stable as $$
declare c m.cond_nodes; res m.v;
begin
    select * into c from m.cond_nodes where name = p_name;
    res := m.eva(c.op, c.l, c.r, c.lit, c.typ, 1, p_ctx);
    if res.t = 'E' then raise exception 'condition error: %', res.s; end if;
    return res.b;
end $$;

insert into m.cond_nodes values
  ('xlt', '{<,id,int}', '{2,0,0}', '{3,0,0}', '{null,x,100}', '{null,int,null}'),
  ('tslt', '{<,id,timestamp,str}', '{2,0,4,0}', '{3,0,0,0}', '{null,ts,null,2023-10-11T10:00:00.000Z}', '{null,timestamp,null,null}'),
  ('xory', '{||,<,id,int,<,id,int}', '{2,3,0,0,6,0,0}', '{5,4,0,0,7,0,0}', '{null,null,x,100,null,y,50}', '{null,null,int,null,null,int,null}');

-- Generated per condition (what a compile-to-SQL design would emit).
create function m.c_xlt_sql(p_ctx jsonb) returns boolean language sql immutable
as $$ select (p_ctx ->> 'x')::numeric::bigint < 100 $$;
create function m.c_tslt_sql(p_ctx jsonb) returns boolean language sql immutable
as $$ select (p_ctx ->> 'ts')::timestamptz < '2023-10-11T10:00:00.000Z'::timestamptz $$;
create function m.c_xory_sql(p_ctx jsonb) returns boolean language sql immutable
as $$ select (p_ctx ->> 'x')::numeric::bigint < 100 or (p_ctx ->> 'y')::numeric::bigint < 50 $$;
create function m.c_xlt_pl(p_ctx jsonb) returns boolean language plpgsql immutable
as $$ begin return (p_ctx ->> 'x')::numeric::bigint < 100; end $$;
create function m.c_tslt_pl(p_ctx jsonb) returns boolean language plpgsql immutable
as $$ begin return (p_ctx ->> 'ts')::timestamptz < '2023-10-11T10:00:00.000Z'::timestamptz; end $$;
create function m.c_xory_pl(p_ctx jsonb) returns boolean language plpgsql immutable
as $$ begin return (p_ctx ->> 'x')::numeric::bigint < 100 or (p_ctx ->> 'y')::numeric::bigint < 50; end $$;
create function m.exec(p_sql text, p_ctx jsonb) returns boolean language plpgsql stable
as $$ declare r boolean; begin execute p_sql into r using p_ctx; return r; end $$;

-- Rows: each carries its own (empty) tuple context merged with the request's,
-- so nothing is constant-folded.
create table m.rows as select g, '{}'::jsonb as tctx from generate_series(1, 100000) g;
analyze m.rows;

create table m.results (expr text, variant text, ms numeric, n bigint);
create function m.time(p_expr text, p_variant text, p_where text) returns void
language plpgsql as $$
declare t0 timestamptz; n bigint; best numeric := null; dt numeric;
begin
    for k in 1..5 loop
        t0 := clock_timestamp();
        execute format('select count(*) from m.rows where %s', p_where) into n;
        dt := extract(epoch from clock_timestamp() - t0) * 1000;
        if best is null or dt < best then best := dt; end if;
    end loop;
    insert into m.results values (p_expr, p_variant, round(best, 1), n);
end $$;

\set req '''{"x": 10, "y": 60, "ts": "2023-10-11T09:00:00.000Z"}''::jsonb'
select m.time('-', 'none', 'true');
select m.time('x<100', 'inline', format('((%L::jsonb || tctx) ->> ''x'')::numeric::bigint < 100', :req));
select m.time('x<100', 'sqlfn', format('m.c_xlt_sql(%L::jsonb || tctx)', :req));
select m.time('x<100', 'plpgsql', format('m.c_xlt_pl(%L::jsonb || tctx)', :req));
select m.time('x<100', 'execute', format('m.exec(''select ($1 ->> ''''x'''')::numeric::bigint < 100'', %L::jsonb || tctx)', :req));
select m.time('x<100', 'tree_jsonb', format('m.eval_tree_jsonb(''{"op":"<","a":{"id":"x","type":"int"},"b":{"int":100}}'', %L::jsonb || tctx)', :req));
select m.time('x<100', 'tree_array', format('m.eval_tree_array(''xlt'', %L::jsonb || tctx)', :req));
select m.time('ts<timestamp(..)', 'inline', format('((%L::jsonb || tctx) ->> ''ts'')::timestamptz < ''2023-10-11T10:00:00.000Z''::timestamptz', :req));
select m.time('ts<timestamp(..)', 'sqlfn', format('m.c_tslt_sql(%L::jsonb || tctx)', :req));
select m.time('ts<timestamp(..)', 'plpgsql', format('m.c_tslt_pl(%L::jsonb || tctx)', :req));
select m.time('ts<timestamp(..)', 'tree_jsonb', format('m.eval_tree_jsonb(''{"op":"<","a":{"id":"ts","type":"timestamp"},"b":{"call":"timestamp","arg":{"str":"2023-10-11T10:00:00.000Z"}}}'', %L::jsonb || tctx)', :req));
select m.time('ts<timestamp(..)', 'tree_array', format('m.eval_tree_array(''tslt'', %L::jsonb || tctx)', :req));
select m.time('x<100||y<50', 'sqlfn', format('m.c_xory_sql(%L::jsonb || tctx)', :req));
select m.time('x<100||y<50', 'plpgsql', format('m.c_xory_pl(%L::jsonb || tctx)', :req));
select m.time('x<100||y<50', 'tree_jsonb', format('m.eval_tree_jsonb(''{"op":"||","a":{"op":"<","a":{"id":"x","type":"int"},"b":{"int":100}},"b":{"op":"<","a":{"id":"y","type":"int"},"b":{"int":50}}}'', %L::jsonb || tctx)', :req));
select m.time('x<100||y<50', 'tree_array', format('m.eval_tree_array(''xory'', %L::jsonb || tctx)', :req));

select expr, variant, ms as "ms per 100k", round(ms * 1000 / 100000, 2) as "us per eval", n
from m.results order by expr, ms;
