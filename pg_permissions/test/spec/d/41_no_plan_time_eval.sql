-- Goal: the FGA list functions RLS policies call are STABLE and are not run
-- at plan time (PLAN.md §4; d/22_no_plan_time_eval covers
-- rbac_scopes_with_permission).
-- fga_list_object_ids_current and fga_list_objects_current return `setof
-- text`, not an array: the planner takes a set-returning function's row
-- estimate from `rows` and never evaluates it, so they need no
-- _unfolded_null() argument. This file pins that. The probe, as in 22: with
-- track_functions = 'all', EXPLAIN (no ANALYZE) must leave the call count
-- unchanged and running the query must raise it.
\ir ../../fixtures/ids.sql

select permissions.fga_write_authorization_model($m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "document", "relations": {"viewer": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]}$m$::jsonb);
select permissions.fga_write_tuple('user:' || :'bob', 'viewer', 'document:' || :'acme_readme');

create table public.documents (id uuid primary key, title text not null);
insert into public.documents values (:'acme_plan', 'plan'), (:'acme_readme', 'readme');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
create policy documents_select on public.documents for select to authenticated
    using (id = any (array(select permissions.fga_list_object_ids_current('document', 'viewer')::uuid)));

create table public.notes (id uuid primary key, title text not null);
insert into public.notes select * from public.documents;
alter table public.notes enable row level security;
grant select on public.notes to authenticated;
create policy notes_select on public.notes for select to authenticated
    using ('document:' || id = any (array(select permissions.fga_list_objects_current('document', 'viewer'))));

select tap.plan(9);

-- volatility: provolatile 's' is STABLE
select tap.is(
    (select array_agg(p.proname::text order by p.proname) from pg_proc p
      where p.pronamespace = 'permissions'::regnamespace and p.provolatile <> 's'
        and p.proname in ('fga_check_current', 'fga_list_objects_current', 'fga_list_object_ids_current',
                          'fga_check', 'fga_list_objects', 'fga_list_users')),
    null::text[], 'every FGA check and list function is STABLE');
select tap.is(
    (select count(*)::int from pg_proc p
      where p.pronamespace = 'permissions'::regnamespace and p.proretset
        and p.proname in ('fga_list_objects_current', 'fga_list_object_ids_current')),
    2, 'the RLS list functions return sets');

begin;
set local track_functions = 'all';
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select coalesce(pg_stat_get_xact_function_calls('permissions.fga_list_object_ids_current'::regproc), 0) as c0 \gset
do $$ declare l text; begin for l in execute 'explain (costs off) select * from public.documents' loop null; end loop; end $$;
select coalesce(pg_stat_get_xact_function_calls('permissions.fga_list_object_ids_current'::regproc), 0) as c1 \gset
select count(*) from public.documents;
select coalesce(pg_stat_get_xact_function_calls('permissions.fga_list_object_ids_current'::regproc), 0) as c2 \gset
commit;
select tap.is((:c1 - :c0)::bigint, 0::bigint, 'array(select fga_list_object_ids_current(...)::uuid): not executed while planning');
select tap.ok((:c2 - :c1)::bigint > 0, 'and executed when the query runs (the probe counts calls)');
select tap.is((:c2 - :c1)::bigint, 1::bigint, 'once per query, not per row');

begin;
set local track_functions = 'all';
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select coalesce(pg_stat_get_xact_function_calls('permissions.fga_list_objects_current'::regproc), 0) as d0 \gset
do $$ declare l text; begin for l in execute 'explain (costs off) select * from public.notes' loop null; end loop; end $$;
select coalesce(pg_stat_get_xact_function_calls('permissions.fga_list_objects_current'::regproc), 0) as d1 \gset
select count(*) from public.notes;
select coalesce(pg_stat_get_xact_function_calls('permissions.fga_list_objects_current'::regproc), 0) as d2 \gset
commit;
select tap.is((:d1 - :d0)::bigint, 0::bigint, 'array(select fga_list_objects_current(...)): not executed while planning');
select tap.ok((:d2 - :d1)::bigint > 0, 'and executed when the query runs');

set role authenticated;
select set_config('permissions.subject_id', :'bob', false);
select tap.set_eq(array(select title from public.documents), '{readme}', 'the ids policy returns the shared document');
select tap.set_eq(array(select title from public.notes), '{readme}', 'the type:id policy too');
reset role;

select * from tap.finish();
