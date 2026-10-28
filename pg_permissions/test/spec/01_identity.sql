-- Goal: identity (PLAN.md §3)
-- The current subject comes from the JWT `sub` claim, falling back to the
-- `permissions.subject_id` setting, with no dependency on Supabase's auth schema.
\ir ../fixtures/ids.sql
\ir ../fixtures/rbac_roles.sql
select permissions.assign_role(:'alice', 'viewer');

select tap.plan(11);

-- no subject
select tap.is(permissions.current_subject_id(), null, 'no JWT and no setting: no subject');
select tap.is(permissions.has_permission('documents.read'), false, 'no subject: has_permission is false');
select tap.set_eq(permissions.scopes_with_permission('documents.read'), '{}', 'no subject: scopes_with_permission is empty, not null');

-- session setting (plain Postgres)
select set_config('permissions.subject_id', :'alice', false);
select tap.is(permissions.current_subject_id()::text, :'alice', 'setting permissions.subject_id identifies the subject');
select tap.is(permissions.has_permission('documents.read'), true, 'subject from the setting gets its permissions');

-- JWT (PostgREST / Supabase)
select set_config('permissions.subject_id', '', false);
select set_config('request.jwt.claims', json_build_object('sub', :'alice', 'role', 'authenticated')::text, false);
select tap.is(permissions.current_subject_id()::text, :'alice', 'JWT sub claim identifies the subject');

select set_config('permissions.subject_id', :'bob', false);
select tap.is(permissions.current_subject_id()::text, :'alice', 'JWT sub wins over the session setting');

select set_config('request.jwt.claims', '', false);
select tap.is(permissions.current_subject_id()::text, :'bob', 'empty JWT claims fall back to the setting');

select set_config('request.jwt.claims', '{"role": "anon"}', false);
select set_config('permissions.subject_id', '', false);
select tap.is(permissions.current_subject_id(), null, 'JWT without sub (anon) and no setting: no subject');

select tap.is(permissions.current_subject_type(), 'user', 'subject type defaults to user');

-- no coupling to Supabase
select tap.is(
    (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'permissions' and p.prosrc ~* '\mauth\s*\.'),
    0, 'no function in the permissions schema references the auth schema');

select * from tap.finish();
