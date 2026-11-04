-- Security regression: default privileges must not expose newly installed
-- admin functions, tables, or sequences. Check both global and schema-local
-- defaults, fresh installs and upgrades, and preserve explicit old grants.
\set ON_ERROR_STOP off
select current_database() as orig_db \gset
\set ext_dir `dirname :'impl_path'`
\set old_path :ext_dir '/pg_permissions--0.0.1.sql'
\set up_path :ext_dir '/pg_permissions--0.0.1--0.1.0.sql'

drop database if exists pgperm_acl_fresh with (force);
drop database if exists pgperm_acl_upgrade with (force);
create database pgperm_acl_fresh;
create database pgperm_acl_upgrade;

\connect pgperm_acl_fresh
create schema permissions;
alter default privileges grant execute on functions to authenticated;
alter default privileges in schema permissions grant execute on functions to anon;
alter default privileges grant all on tables to authenticated;
alter default privileges in schema permissions grant select on tables to anon;
alter default privileges grant all on sequences to public;
alter default privileges in schema permissions grant all on sequences to authenticated;
begin;
\i :impl_path
commit;
select count(*)::int as exposed_admins from pg_proc p
where p.pronamespace = 'permissions'::regnamespace
  and p.proname in ('rbac_assign_role', 'fga_write', 'cedar_put_policy', '_cedar_mac', '_fga_cel_regex')
  and (has_function_privilege('authenticated', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute')) \gset
select count(*)::int as exposed_tables from pg_class c
where c.relnamespace = 'permissions'::regnamespace and c.relkind = 'r'
  and (has_table_privilege('authenticated', c.oid, 'select,insert,update,delete,truncate,references,trigger')
       or has_table_privilege('anon', c.oid, 'select')) \gset
select count(*)::int as exposed_sequences from pg_class c
where c.relnamespace = 'permissions'::regnamespace and c.relkind = 'S'
  and (has_sequence_privilege('authenticated', c.oid, 'select,usage,update')
       or has_sequence_privilege('anon', c.oid, 'select,usage,update')) \gset
select has_function_privilege('authenticated', 'permissions.cedar_is_authorized_current(text,text,jsonb,boolean)', 'execute')
  and has_function_privilege('anon', 'permissions.rbac_has_permission(text,text)', 'execute') as clients_work \gset

-- Unrelated future objects should still get the installer's chosen defaults.
create table public.acl_unrelated (id int);
select has_table_privilege('authenticated', 'public.acl_unrelated', 'select') as defaults_kept \gset

\connect pgperm_acl_upgrade
\i :old_path
grant execute on function permissions.rbac_assign_role(text,text,text) to service_role;
alter default privileges grant execute on functions to authenticated;
alter default privileges in schema permissions grant execute on functions to anon;
alter default privileges grant all on tables to authenticated;
alter default privileges grant all on sequences to public;
begin;
\i :up_path
commit;
select count(*)::int as upgraded_admins from pg_proc p
where p.pronamespace = 'permissions'::regnamespace
  and (p.proname ~ '^_?cedar_' or p.proname in ('_ip_canon', '_ts_canon', '_duration_ns', '_fga_cel_regex'))
  and p.proname not in ('cedar_is_authorized_current', 'cedar_list_resources_current', 'cedar_uid')
  and (has_function_privilege('authenticated', p.oid, 'execute')
       or has_function_privilege('anon', p.oid, 'execute')) \gset
select has_table_privilege('authenticated', 'permissions._cedar_secret', 'select') as secret_exposed \gset
select has_sequence_privilege('anon', 'permissions._cedar_write_seq', 'usage,select,update') as gen_exposed \gset
select has_function_privilege('service_role', 'permissions.rbac_assign_role(text,text,text)', 'execute') as explicit_grant_kept \gset

\connect :"orig_db"
select tap.plan(9);
select tap.is(:'exposed_admins'::int, 0, 'fresh install removes named-role default grants on admin functions');
select tap.is(:'exposed_tables'::int, 0, 'fresh install removes global and schema-local default table grants');
select tap.is(:'exposed_sequences'::int, 0, 'fresh install removes PUBLIC and named-role default sequence grants');
select tap.ok(:'clients_work'::boolean, 'the intended current-subject functions stay public');
select tap.ok(:'defaults_kept'::boolean, 'installation does not alter defaults for other objects');
select tap.is(:'upgraded_admins'::int, 0, 'upgrade removes default grants on new Cedar and shared functions');
select tap.is(:'secret_exposed'::boolean, false, 'upgrade keeps the cache secret private');
select tap.is(:'gen_exposed'::boolean, false, 'upgrade keeps the cache generation sequence private');
select tap.ok(:'explicit_grant_kept'::boolean, 'upgrade preserves an explicit grant on an existing admin function');
drop database pgperm_acl_fresh with (force);
drop database pgperm_acl_upgrade with (force);
select * from tap.finish();
