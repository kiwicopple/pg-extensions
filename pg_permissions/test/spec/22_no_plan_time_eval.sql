-- Goal: RLS policies don't run scopes_with_permission() at plan time (research/plan.md §4)
-- A STABLE function with constant arguments inside `array(select unnest(...))`
-- is evaluated by the planner (to estimate the unnest's row count) and then
-- again by the executor, so every query paid for two computations. Engines keep
-- the function STABLE and give it a trailing argument whose default is a
-- volatile function, so the call isn't constant. The `*_volatility` specs only
-- check the volatility labels; this one checks the behaviour.
-- The probe: with track_functions = 'all', EXPLAIN (no ANALYZE, so nothing is
-- executed) must leave the function's call count unchanged; running the query
-- must then raise it, which proves the probe counts calls.
-- Counts are read as differences, because pg_stat_get_xact_function_calls also
-- returns counts from earlier transactions of this session that haven't been
-- flushed to shared stats yet.
\ir ../fixtures/ids.sql
\ir ../fixtures/rbac_roles.sql

create table public.documents (id uuid primary key, org_id uuid not null, title text not null);
insert into public.documents values
    (:'acme_plan',    :'acme',   'acme plan'),
    (:'acme_readme',  :'acme',   'acme readme'),
    (:'globex_notes', :'globex', 'globex notes');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
-- research/plan.md §4: the documented form
create policy documents_select on public.documents for select to authenticated
    using (org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid)));

-- the other form: one InitPlan returning the whole array, cast once
create table public.projects (id uuid primary key, org_id uuid not null, title text not null);
insert into public.projects select id, org_id, title from public.documents;
alter table public.projects enable row level security;
grant select on public.projects to authenticated;
create policy projects_select on public.projects for select to authenticated
    using (org_id = any ((select permissions.scopes_with_permission('documents.read'))::uuid[]));

select permissions.assign_role(:'bob', 'editor', :'acme');
select permissions.assign_role(:'bob', 'viewer', :'globex');

select tap.plan(6);

-- documented form
begin;
set local track_functions = 'all';
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select coalesce(pg_stat_get_xact_function_calls('permissions.scopes_with_permission'::regproc), 0) as a0 \gset
do $$ declare l text; begin for l in execute 'explain (costs off) select * from public.documents' loop null; end loop; end $$;
select coalesce(pg_stat_get_xact_function_calls('permissions.scopes_with_permission'::regproc), 0) as a1 \gset
select count(*) from public.documents;
select coalesce(pg_stat_get_xact_function_calls('permissions.scopes_with_permission'::regproc), 0) as a2 \gset
commit;
select tap.is((:a1 - :a0)::bigint, 0::bigint, 'array(select unnest(scopes_with_permission(...))): not executed while planning');
select tap.ok((:a2 - :a1)::bigint > 0, 'and executed when the query runs (the probe counts calls)');

-- the (select f())::uuid[] form
begin;
set local track_functions = 'all';
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select coalesce(pg_stat_get_xact_function_calls('permissions.scopes_with_permission'::regproc), 0) as b0 \gset
do $$ declare l text; begin for l in execute 'explain (costs off) select * from public.projects' loop null; end loop; end $$;
select coalesce(pg_stat_get_xact_function_calls('permissions.scopes_with_permission'::regproc), 0) as b1 \gset
select count(*) from public.projects;
select coalesce(pg_stat_get_xact_function_calls('permissions.scopes_with_permission'::regproc), 0) as b2 \gset
commit;
select tap.is((:b1 - :b0)::bigint, 0::bigint, '(select scopes_with_permission(...))::uuid[]: not executed while planning');
select tap.ok((:b2 - :b1)::bigint > 0, 'and executed when the query runs');

-- the policies still return the right rows
set role authenticated;
select set_config('permissions.subject_id', :'bob', false);
select tap.is((select count(*)::int from public.documents), 3, 'documented form: Bob sees acme and globex documents');
select tap.is((select count(*)::int from public.projects), 3, 'cast form: Bob sees acme and globex projects');
reset role;

select * from tap.finish();
