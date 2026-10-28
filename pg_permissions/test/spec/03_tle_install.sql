-- Goal: installs as a non-superuser that owns the database; no superuser-only
-- features, no C. If pg_tle is available, also installs through
-- pgtle.install_extension (PLAN.md §10, G14).
--
-- The runner's per-spec database already has the implementation installed as
-- superuser, so this file builds its own scratch databases owned by a
-- non-superuser role (`tle_owner`), installs the implementation there with
-- `SET SESSION AUTHORIZATION tle_owner` (no login or password needed, and
-- privilege checks are the non-superuser's), and copies what it observes into
-- psql variables with \gset. Variables survive \connect; tap state doesn't
-- matter because it lives in a table in the original database, so all
-- assertions run after reconnecting there.
--
-- Needs :impl_path (the implementation file), which test/run.sh passes with
-- `-v impl_path=...`. Leftovers from a run that died halfway are dropped first.
\set ON_ERROR_STOP off
\ir ../fixtures/ids.sql

select current_database() as orig_db \gset
select exists (select 1 from pg_available_extensions where name = 'pg_tle')
       and current_setting('shared_preload_libraries') ~ '\mpg_tle\M' as tle_avail \gset

-- Defaults, so a failed step leaves a visible value instead of an unset variable.
\set own_super ''
\set role_super ''
\set schema_owner ''
\set funcs ''
\set unowned ''
\set c_funcs ''
\set smoke_subject ''
\set smoke_has ''
\set smoke_not ''
\set tle_installed ''
\set tle_has ''

-- Leftovers from an earlier run
drop database if exists pgperm_tle_scratch with (force);
drop database if exists pgperm_tle_scratch2 with (force);
drop role if exists tle_owner;

create role tle_owner nosuperuser createdb nologin;
create database pgperm_tle_scratch owner tle_owner;

-- 1. Plain install as the non-superuser
\connect pgperm_tle_scratch
set session authorization tle_owner;
select current_setting('is_superuser') as own_super,
       (select rolsuper::text from pg_roles where rolname = current_user) as role_super \gset

\i :impl_path

select nspowner::regrole::text as schema_owner
from pg_namespace where nspname = 'permissions' \gset

select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'permissions') as funcs,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'permissions' and p.proowner <> 'tle_owner'::regrole)
     + (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'permissions' and c.relowner <> 'tle_owner'::regrole) as unowned,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          join pg_language l on l.oid = p.prolang
        where n.nspname = 'permissions' and l.lanname in ('c', 'internal')) as c_funcs \gset

select set_config('permissions.subject_id', :'alice', false);
select permissions.current_subject_id()::text as smoke_subject \gset
select permissions.create_role('tle_reader', '{tle.read}');
select permissions.assign_role(:'alice', 'tle_reader');
select permissions.has_permission('tle.read')::text as smoke_has \gset
select permissions.has_permission('tle.write')::text as smoke_not \gset

-- 2. pg_tle (only if the server has it loaded)
\if :tle_avail
    \connect postgres
    create database pgperm_tle_scratch2 owner tle_owner;
    \connect pgperm_tle_scratch2
    create extension pg_tle;
    grant pgtle_admin to tle_owner;
    set session authorization tle_owner;
    \set impl_body `cat :"impl_path"`
    select pgtle.install_extension('pg_permissions', '0.0.1', 'pg_permissions test install', :'impl_body');
    create extension pg_permissions;
    select count(*)::text as tle_installed from pg_extension where extname = 'pg_permissions' \gset
    select set_config('permissions.subject_id', :'alice', false);
    select permissions.create_role('tle_reader', '{tle.read}');
    select permissions.assign_role(:'alice', 'tle_reader');
    select permissions.has_permission('tle.read')::text as tle_has \gset
\endif

-- Back to the spec database as the superuser for the assertions.
\connect :"orig_db"

select tap.plan(9);

select tap.is(:'own_super'::text, 'off', 'the install session is not a superuser');
select tap.is(:'role_super'::text, 'false', 'tle_owner is not a superuser role');
select tap.is(:'schema_owner'::text, 'tle_owner', 'the permissions schema is owned by the installing non-superuser');
select tap.ok(:'funcs'::text ~ '^[1-9]' and :'unowned'::text = '0',
              'every function and table in the schema is owned by the installing role (funcs: ' || :'funcs'::text || ', not owned: ' || :'unowned'::text || ')');
select tap.is(:'smoke_subject'::text, :'alice'::text, 'smoke: current_subject_id() reads the setting after a non-superuser install');
select tap.is(:'smoke_has'::text, 'true', 'smoke: create_role + assign_role + has_permission grants the permission');
select tap.is(:'smoke_not'::text, 'false', 'smoke: has_permission is false for a permission the role lacks');
select tap.is(:'c_funcs'::text, '0', 'no function in the schema is written in C or internal');

\if :tle_avail
    select tap.ok(:'tle_installed'::text = '1' and :'tle_has'::text = 'true',
                  'pgtle.install_extension + create extension works as a non-superuser and has_permission works');
\else
    \echo '# pg_tle is not available on this server (not in pg_available_extensions or shared_preload_libraries)'
    \echo '# only the non-superuser plain install was checked; the pgtle.install_extension path was NOT tested'
    select tap.pass('SKIP pg_tle not available: pgtle.install_extension path not tested');
\endif

-- Cleanup
drop database if exists pgperm_tle_scratch with (force);
drop database if exists pgperm_tle_scratch2 with (force);
drop role if exists tle_owner;

select * from tap.finish();
