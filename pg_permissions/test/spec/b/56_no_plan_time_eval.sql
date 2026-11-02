-- Goal: RLS policy shapes don't run the permission functions at plan time
-- Design B: a STABLE function with constant arguments inside
-- `array(select unnest(...))` is evaluated by the planner (to estimate the
-- unnest's row count) and then again by the executor, so every query paid for
-- two computations. ids(), denied_ids() and scopes_with_permission() take a
-- trailing argument whose default is a volatile function, which keeps the call
-- from being folded (55_volatility.sql only checks the volatility labels, not
-- that the argument is still there).
-- The probe: with track_functions = 'all', EXPLAIN (no ANALYZE, so nothing is
-- executed) must leave the function's call count at zero for the transaction;
-- running the query must then count calls, which proves the probe works.
-- Policies: the bench form (hand-written ids()), and the generated ones from
-- apply_rls, including a resource condition and a forbid, whose arguments
-- rls_expression writes out as constants.
\ir ../../fixtures/ids.sql

select permissions.define_role('document', 'viewer');
select permissions.define_role('document', 'editor', '{viewer}');
select permissions.define_role('org', 'member');
select permissions.permit('doc viewers view', '{select}', 'document', roles => '{viewer}');
select permissions.permit('org members view published docs', '{select}', 'document', roles => '{member}', via => 'org',
                          condition => '{"op": "==", "left": {"var": "resource.status"}, "right": "published"}');
select permissions.forbid('no viewing secrets', '{select}', 'document', roles => '{viewer}',
                          condition => '{"op": "==", "left": {"var": "resource.status"}, "right": "secret"}');
select permissions.grant_role('user', :'bob', 'viewer', 'document', :'acme_readme');
select permissions.grant_role('user', :'bob', 'member', 'org', :'acme');

-- hand-written, as in bench/designs/b/seed_sharing.sql
create table public.documents (id uuid primary key, org_id uuid not null, status text not null, title text not null);
insert into public.documents values
    (:'acme_readme', :'acme', 'published', 'readme'),
    (:'acme_plan',   :'acme', 'secret',    'plan');
alter table public.documents enable row level security;
grant select on public.documents to authenticated;
create policy documents_select on public.documents for select to authenticated using (
    id = any (array(select unnest(permissions.ids('select', 'document'))::uuid))
);

-- generated, with a conditioned permit and forbid
create table public.pages (id uuid primary key, org_id uuid not null, status text not null, title text not null);
insert into public.pages select id, org_id, status, title from public.documents;
alter table public.pages enable row level security;
grant select on public.pages to authenticated;
select permissions.apply_rls('public.pages', 'select', 'document', 'id', '{"org": "org_id"}');

select tap.plan(8);

-- The call counts are read as differences: pg_stat_get_xact_function_calls
-- also returns counts from earlier transactions of this session that haven't
-- been flushed to shared stats yet.

-- hand-written policy: ids()
begin;
set local track_functions = 'all';
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select coalesce(pg_stat_get_xact_function_calls('permissions.ids'::regproc), 0) as c0 \gset
do $$ declare l text; begin for l in execute 'explain (costs off) select * from public.documents' loop null; end loop; end $$;
select coalesce(pg_stat_get_xact_function_calls('permissions.ids'::regproc), 0) as c1 \gset
select count(*) from public.documents;
select coalesce(pg_stat_get_xact_function_calls('permissions.ids'::regproc), 0) as c2 \gset
commit;
select tap.is((:c1 - :c0)::bigint, 0::bigint, 'ids() is not executed while planning the bench policy');
select tap.ok((:c2 - :c1)::bigint > 0, 'ids() is executed when the query runs (the probe counts calls)');

-- generated policy: ids(), denied_ids() with resource-condition arguments
begin;
set local track_functions = 'all';
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select coalesce(pg_stat_get_xact_function_calls('permissions.ids'::regproc), 0) as i0,
       coalesce(pg_stat_get_xact_function_calls('permissions.denied_ids'::regproc), 0) as d0 \gset
do $$ declare l text; begin for l in execute 'explain (costs off) select * from public.pages' loop null; end loop; end $$;
select coalesce(pg_stat_get_xact_function_calls('permissions.ids'::regproc), 0) as i1,
       coalesce(pg_stat_get_xact_function_calls('permissions.denied_ids'::regproc), 0) as d1 \gset
select count(*) from public.pages;
select coalesce(pg_stat_get_xact_function_calls('permissions.ids'::regproc), 0) as i2,
       coalesce(pg_stat_get_xact_function_calls('permissions.denied_ids'::regproc), 0) as d2 \gset
commit;
select tap.is((:i1 - :i0)::bigint, 0::bigint, 'ids() in an apply_rls policy (with a resource condition) is not executed while planning');
select tap.is((:d1 - :d0)::bigint, 0::bigint, 'denied_ids() in an apply_rls policy is not executed while planning');
select tap.ok((:i2 - :i1)::bigint > 0, 'ids() is executed when the generated policy runs');
select tap.ok((:d2 - :d1)::bigint > 0, 'denied_ids() is executed when the generated policy runs');

-- scopes_with_permission(), documented form; the one-argument call still works
create table public.tenants (id uuid primary key, name text not null);
insert into public.tenants values (:'acme', 'acme'), (:'globex', 'globex');
alter table public.tenants enable row level security;
grant select on public.tenants to authenticated;
create policy tenants_select on public.tenants for select to authenticated
    using (id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid)));

begin;
set local track_functions = 'all';
set local role authenticated;
select set_config('permissions.subject_id', :'bob', true);
select coalesce(pg_stat_get_xact_function_calls('permissions.scopes_with_permission'::regproc), 0) as s0 \gset
do $$ declare l text; begin for l in execute 'explain (costs off) select * from public.tenants' loop null; end loop; end $$;
select coalesce(pg_stat_get_xact_function_calls('permissions.scopes_with_permission'::regproc), 0) as s1 \gset
select count(*) from public.tenants;
select coalesce(pg_stat_get_xact_function_calls('permissions.scopes_with_permission'::regproc), 0) as s2 \gset
commit;
select tap.is((:s1 - :s0)::bigint, 0::bigint, 'scopes_with_permission() is not executed while planning');
select tap.ok((:s2 - :s1)::bigint > 0, 'scopes_with_permission() is executed when the query runs');

select * from tap.finish();
