-- Goal: the rbac preset enforces access through RLS policies (PLAN.md §4, §6 RBAC scenario step 2 and 3)
-- Runs as the non-superuser role `authenticated`, the way Supabase clients do.
\ir ../fixtures/ids.sql
\ir ../fixtures/rbac_roles.sql

-- app-wide roles: policies from PLAN.md §6
create table public.handbook (id serial primary key, title text not null);
insert into public.handbook (title) values ('welcome'), ('holidays'), ('expenses');
alter table public.handbook enable row level security;
grant select, update, delete on public.handbook to authenticated;
create policy handbook_select on public.handbook for select to authenticated using ((select permissions.has_permission('documents.read')));
create policy handbook_update on public.handbook for update to authenticated using ((select permissions.has_permission('documents.edit')));
create policy handbook_delete on public.handbook for delete to authenticated using ((select permissions.has_permission('documents.delete')));

-- tenant-scoped roles
create table public.documents (id uuid primary key, org_id uuid not null, title text not null);
insert into public.documents values
    (:'acme_plan',    :'acme',   'acme plan'),
    (:'acme_readme',  :'acme',   'acme readme'),
    (:'globex_notes', :'globex', 'globex notes');
alter table public.documents enable row level security;
grant select, update, delete on public.documents to authenticated;
create policy documents_select on public.documents for select to authenticated
    using (org_id = any (array(select unnest(permissions.scopes_with_permission('documents.read'))::uuid)));
create policy documents_update on public.documents for update to authenticated
    using (permissions.has_permission('documents.edit', org_id::text));

select permissions.assign_role(:'alice', 'admin');
select permissions.assign_role(:'carol', 'viewer');
select permissions.assign_role(:'bob',   'editor', :'acme');
select permissions.assign_role(:'bob',   'viewer', :'globex');

select tap.plan(12);

set role authenticated;

-- app-wide
select set_config('permissions.subject_id', :'carol', false);
select tap.is((select count(*)::int from public.handbook), 3, 'Carol (viewer) sees every handbook page');
update public.handbook set title = title || '!';
select tap.is((select count(*)::int from public.handbook where title like '%!'), 0, 'Carol''s update changes nothing');

select set_config('permissions.subject_id', :'alice', false);
delete from public.handbook where title = 'expenses';
select tap.is((select count(*)::int from public.handbook), 2, 'Alice (admin) can delete');

select set_config('permissions.subject_id', :'dave', false);
select tap.is((select count(*)::int from public.handbook), 0, 'Dave (no role) sees nothing');

select set_config('permissions.subject_id', '', false);
select tap.is((select count(*)::int from public.handbook), 0, 'no subject sees nothing');

-- tenant-scoped
select set_config('permissions.subject_id', :'bob', false);
select tap.is((select count(*)::int from public.documents), 3, 'Bob sees acme (editor) and globex (viewer) documents');
update public.documents set title = title || '!';
select tap.set_eq(array(select title from public.documents where title like '%!'), '{acme plan!,acme readme!}', 'Bob''s update only touches acme documents');

select set_config('permissions.subject_id', :'alice', false);
select tap.is((select count(*)::int from public.documents), 0, 'Alice''s app-wide admin role does not reach tenant documents');

select set_config('permissions.subject_id', :'carol', false);
select tap.is((select count(*)::int from public.documents), 0, 'neither does Carol''s app-wide viewer role');

-- the JWT path works under RLS too
select set_config('request.jwt.claims', json_build_object('sub', :'bob')::text, false);
select set_config('permissions.subject_id', '', false);
select tap.is((select count(*)::int from public.documents where org_id = :'globex'), 1, 'identity from the JWT works inside RLS');
select set_config('request.jwt.claims', '', false);

-- the fast path runs once per query, not once per row
create temp table plan_lines (line text);
reset role;
grant all on plan_lines to authenticated;
set role authenticated;
select set_config('permissions.subject_id', :'bob', false);
do $$
declare l text;
begin
    for l in execute 'explain select * from public.documents' loop
        insert into plan_lines values (l);
    end loop;
end $$;
select tap.ok(exists (select 1 from plan_lines where line like '%InitPlan%'), 'tenant select policy is evaluated as an InitPlan');
select tap.ok(not exists (select 1 from plan_lines where line ~* 'SubPlan'), 'and not as a per-row SubPlan');

reset role;
select * from tap.finish();
