-- Goal: RLS policy shapes don't run list_objects() at plan time
-- Design A: policies call list_objects inside `array(select unnest(...))`.
-- A STABLE function with constant arguments inside the policy is evaluated by
-- the planner when it needs to estimate the row count of the unnest, and then
-- again by the executor, so every query paid for two computations.
-- list_objects() takes a trailing argument whose default is a volatile function, which
-- keeps the call from being folded. a/57_volatility.sql only checks the
-- volatility labels, not that the argument is still there.
-- The probe: with track_functions = 'all', EXPLAIN (no ANALYZE, so nothing is
-- executed) must leave the function's call count unchanged; running the query
-- must then raise it, which proves the probe counts calls. Counts are read as
-- differences, because pg_stat_get_xact_function_calls also returns counts from
-- earlier transactions of this session that haven't been flushed to shared
-- stats yet.
\ir ../../fixtures/ids.sql

select permissions.define_type('user');
select permissions.define_type('document');
select permissions.define_relation('document', 'editor');
select permissions.define_relation('document', 'viewer', '{editor}');
select permissions.grant('document', :'acme_readme', 'editor', 'user', :'bob');

create table public.documents (id uuid primary key, title text not null);
insert into public.documents values
    (:'acme_plan',   'plan'),
    (:'acme_readme', 'readme');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
-- as in bench/designs/a/seed_sharing.sql
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.list_objects('document', 'viewer'))::uuid))
);

select tap.plan(3);

begin;
set local track_functions = 'all';
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select coalesce(pg_stat_get_xact_function_calls('permissions.list_objects'::regproc), 0) as c0 \gset
do $$ declare l text; begin for l in execute 'explain (costs off) select * from public.documents' loop null; end loop; end $$;
select coalesce(pg_stat_get_xact_function_calls('permissions.list_objects'::regproc), 0) as c1 \gset
select count(*) from public.documents;
select coalesce(pg_stat_get_xact_function_calls('permissions.list_objects'::regproc), 0) as c2 \gset
commit;
select tap.is((:c1 - :c0)::bigint, 0::bigint, 'list_objects() is not executed while planning');
select tap.ok((:c2 - :c1)::bigint > 0, 'list_objects() is executed when the query runs (the probe counts calls)');

set role authenticated;
select set_config('permissions.subject_id', :'bob', false);
select tap.is((select count(*)::int from public.documents), 1, 'the policy still returns the shared document');
reset role;

select * from tap.finish();
