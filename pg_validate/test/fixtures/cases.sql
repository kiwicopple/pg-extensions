-- Table-driven validator cases. A spec inserts (fn, input, want, note) rows,
-- plans, then runs them all with one select:
--
--   \ir ../fixtures/cases.sql
--   insert into cases (fn, input, want, note) values
--       ('slug', 'hello-world', true, null);
--   select tap.plan((select count(*)::int from cases) + 2);
--   \ir ../fixtures/run_cases.sql
--
-- pg_temp.call(fn, input) calls validate.<fn>(input) directly, not through
-- the registry, so these specs test the functions themselves.
create temp table cases (
    id    serial,
    fn    text not null,
    input text,
    want  boolean,
    note  text
);

create function pg_temp.call(fn text, input text)
returns boolean
language plpgsql
as $$
declare
    r boolean;
begin
    execute format('select validate.%I($1)', fn) into r using input;
    return r;
end;
$$;
