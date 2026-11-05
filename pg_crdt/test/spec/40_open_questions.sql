-- Goal: settle the open questions about the crdt.pn domain from
-- architecture.md (decision 4) and journal.md session 1. The answers are
-- recorded in the README ("How the domain behaves") and the journal.
--
-- Q1. Does a plain jsonb value (not a literal) need an explicit cast to be
--     passed to a function that takes crdt.pn?
-- Q2. Does the domain CHECK run on every function return?
-- Q3. Can crdt.pn be used in a generated column, and can crdt.pn_value(...)
--     back an expression index?
--
-- For Q2 a second, volatile CHECK constraint on crdt.pn counts how often the
-- domain's checks run (this throwaway database only).

create schema q;
create sequence q.checks;
create function q.spy(value jsonb) returns boolean language sql volatile as $$
    select nextval('q.checks') > 0
$$;
-- Number of check runs while evaluating `sql` (excluding the count itself).
create function q.checks_during(sql text) returns int language plpgsql volatile as $$
declare
    before bigint;
begin
    perform setval('q.checks', 1, false);
    before := nextval('q.checks');
    execute sql;
    return nextval('q.checks') - before - 1;
end;
$$;

create table q.src (id int primary key, j jsonb, s crdt.pn);
insert into q.src values
    (1, '{"t": "pn", "v": 1, "p": {"a": 2}, "n": {}}', '{"t": "pn", "v": 1, "p": {"a": 2}, "n": {}}'),
    (2, '{"t": "pn", "v": 1, "p": {"b": 5}, "n": {"a": 1}}', '{"t": "pn", "v": 1, "p": {"b": 5}, "n": {"a": 1}}'),
    (3, '{"t": "pn", "v": 1, "p": {"c": 1}, "n": {}}', '{"t": "pn", "v": 1, "p": {"c": 1}, "n": {}}');
create table q.bad (j jsonb);
insert into q.bad values ('{"t": "pn", "v": 1, "p": {"a": 1}}');

-- Functions declared to return crdt.pn whose bodies produce invalid jsonb.
create function q.bad_plpgsql() returns crdt.pn language plpgsql as $$
begin
    return '{"t": "nope"}'::jsonb;
end;
$$;
create function q.bad_sql_inlinable(j jsonb) returns crdt.pn language sql immutable as $$
    select j
$$;
create function q.bad_sql_atomic(j jsonb) returns crdt.pn language sql immutable
return j;

alter domain crdt.pn add constraint spy check (q.spy(value));

select tap.plan(25);

-- Q1: no explicit cast is needed; the implicit coercion runs the CHECK.
select tap.is((select sum(crdt.pn_value(j))::bigint from q.src), 7::bigint,
              'Q1: a jsonb column passes to pn_value(crdt.pn) without a cast');
select tap.is((select crdt.pn_value(crdt.pn_merge(a.j, b.j)) from q.src a, q.src b where a.id = 1 and b.id = 2), 6::bigint,
              'Q1: two jsonb columns pass to pn_merge(crdt.pn, crdt.pn) without a cast');
create function q.from_variable() returns bigint language plpgsql as $$
declare
    j jsonb := '{"t": "pn", "v": 1, "p": {"a": 4}, "n": {}}';
begin
    return crdt.pn_value(crdt.pn_increment(j, 'a', 1));
end;
$$;
select tap.is(q.from_variable(), 5::bigint, 'Q1: a jsonb PL/pgSQL variable passes without a cast');
select tap.is(crdt.pn_value('{"t": "pn", "v": 1, "p": {"a": 4}, "n": {}}'), 4::bigint,
              'Q1: an untyped literal passes without a cast');
select tap.throws_ok($$ select crdt.pn_value(j) from q.bad $$, '23514',
                     'Q1: the implicit jsonb -> crdt.pn coercion runs the domain CHECK (an invalid jsonb column raises)');
select tap.is(q.checks_during($$ select crdt.pn_value(j) from q.src $$), 3,
              'Q1: passing a jsonb column runs the CHECK once per row');
select tap.is(q.checks_during($$ select crdt.pn_value(s) from q.src $$), 0,
              'Q1: passing a crdt.pn column runs no CHECK (the value already has the type)');

-- Q2: the CHECK runs whenever a function produces a crdt.pn from jsonb, and
-- never for a crdt.pn passed through unchanged.
select tap.throws_ok($$ select q.bad_plpgsql() $$, '23514', 'Q2: a PL/pgSQL function cannot return an invalid crdt.pn');
select tap.throws_ok($$ select q.bad_sql_inlinable('{"t": "nope"}') $$, '23514',
                     'Q2: an inlinable LANGUAGE sql function cannot return an invalid crdt.pn');
select tap.throws_ok($$ select q.bad_sql_atomic('{"t": "nope"}') $$, '23514',
                     'Q2: a SQL-standard (RETURN) function cannot return an invalid crdt.pn');
select tap.is(q.checks_during($$ select crdt.pn_merge(a.s, b.s) from q.src a, q.src b where a.id = 1 and b.id = 2 $$), 1,
              'Q2: pn_merge checks its result once');
select tap.is(q.checks_during($$ select crdt.pn_merge(a.s, b.s) from q.src a left join q.src b on false where a.id = 1 $$), 0,
              'Q2: pn_merge(x, null) returns x without a check');
select tap.is(q.checks_during($$ select crdt.pn_merge(a.s, null) from q.src a where a.id = 1 $$), 1,
              'Q2: the CHECK also runs on a null literal passed as crdt.pn (so the CHECK must be null-safe)');
select tap.is(q.checks_during($$ select crdt.pn_increment(s, 'a', 1) from q.src where id = 1 $$), 1,
              'Q2: pn_increment (PL/pgSQL) checks its result once');
select tap.is(q.checks_during($$ select crdt.pn_empty() from q.src where id = 1 $$), 1,
              'Q2: pn_empty() checks its constant once per call');
select tap.is(q.checks_during($$ select crdt.pn_merge_agg(s) from q.src $$), 2,
              'Q2: pn_merge_agg checks once per merge (3 rows: the first is taken as is, then 2 merges)');
select tap.is(q.checks_during($$ select crdt.pn_value(s) from q.src $$), 0,
              'Q2: pn_value (returns bigint) runs no check');

alter domain crdt.pn drop constraint spy;

-- Q3: generated column, expression index, CHECK constraint
select tap.lives_ok($$
    create table q.counters (
        id int primary key,
        s crdt.pn not null default crdt.pn_empty(),
        total bigint generated always as (crdt.pn_value(s)) stored
    ) $$, 'Q3: a stored generated column can use crdt.pn_value(crdt.pn)');
insert into q.counters (id) select g from generate_series(1, 2000) g;
update q.counters set s = crdt.pn_increment(s, 'a', id % 50) where id % 7 = 0;
update q.counters set s = crdt.pn_merge(s, '{"t": "pn", "v": 1, "p": {}, "n": {"b": 3}}') where id = 14;
select tap.is((select total from q.counters where id = 14), 11::bigint,
              'Q3: the generated column follows increments and merges (14: +14 -3)');

-- Postgres 18 adds virtual generated columns, which may not call user-defined
-- functions (yet), so the value has to be a stored column.
select current_setting('server_version_num')::int >= 180000 as pg18 \gset
\if :pg18
select tap.throws_ok($$ create table q.virt (s crdt.pn, total bigint generated always as (crdt.pn_value(s)) virtual) $$,
                     '0A000', 'Q3: a virtual generated column cannot use crdt.pn_value (Postgres 18: user-defined function)');
\else
select tap.pass('SKIP before Postgres 18: no virtual generated columns');
\endif

select tap.lives_ok($$ create index counters_value on q.counters (crdt.pn_value(s)) $$,
                    'Q3: crdt.pn_value(s) can back an expression index');
analyze q.counters;
set enable_seqscan = off;
create function q.plan_text(sql text) returns text language plpgsql as $$
declare
    r record;
    out text := '';
begin
    for r in execute 'explain ' || sql loop
        out := out || r."QUERY PLAN" || E'\n';
    end loop;
    return out;
end;
$$;
select tap.ok(q.plan_text('select id from q.counters where crdt.pn_value(s) = 49') like '%counters_value%',
              'Q3: the planner uses the expression index for where crdt.pn_value(s) = ...');
select tap.is((select array_agg(id order by id) from q.counters where crdt.pn_value(s) = 49),
              (select array_agg(id order by id) from q.counters where total = 49),
              'Q3: the index scan and the generated column find the same rows');
reset enable_seqscan;

select tap.lives_ok($$ alter table q.counters add constraint not_negative check (crdt.pn_value(s) >= -1000) $$,
                    'Q3: crdt.pn_value(s) works in a CHECK constraint');
-- Maintenance commands run with search_path = pg_catalog, pg_temp on 17+;
-- function bodies must name everything they use.
set search_path = pg_catalog, pg_temp;
select tap.lives_ok($$ reindex table q.counters $$,
                    'Q3: reindex works with search_path = pg_catalog, pg_temp');
vacuum analyze q.counters;
reset search_path;

select * from tap.finish();
