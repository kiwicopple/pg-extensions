-- Goal: installs as a non-superuser that owns the database; no superuser-only
-- features, no C. If pg_tle is available, also installs through
-- pgtle.install_extension + create extension, where the registry table is
-- marked for pg_dump (pg_extension_config_dump, user rows only).
--
-- The runner's per-spec database already has the implementation installed as
-- superuser, so this file builds its own scratch databases owned by a
-- non-superuser role (`val_owner`), installs the implementation there with
-- `SET SESSION AUTHORIZATION val_owner`, and copies what it observes into
-- psql variables with \gset. Variables survive \connect; tap state lives in
-- a table in the original database, so all assertions run after reconnecting
-- there.
--
-- Needs :impl_path (the implementation file), which test/run.sh passes with
-- `-v impl_path=...`. Leftovers from a run that died halfway are dropped first.
\set ON_ERROR_STOP off

select current_database() as orig_db \gset
select exists (select 1 from pg_available_extensions where name = 'pg_tle')
       and current_setting('shared_preload_libraries') ~ '\mpg_tle\M' as tle_avail \gset

-- Defaults, so a failed step leaves a visible value instead of an unset variable.
\set own_super ''
\set schema_owner ''
\set funcs ''
\set unowned ''
\set c_funcs ''
\set smoke ''
\set smoke_reg ''
\set tle_name 'pg_validate'
\set tle_registered ''
\set tle_installed ''
\set tle_schema ''
\set tle_members ''
\set tle_config ''
\set tle_smoke ''
\set tle_dropped ''

drop database if exists pgval_tle_scratch with (force);
drop database if exists pgval_tle_scratch2 with (force);
drop role if exists val_owner;

create role val_owner nosuperuser createdb nologin;
create database pgval_tle_scratch owner val_owner;

-- 1. Plain install as the non-superuser
\connect pgval_tle_scratch
set session authorization val_owner;
select current_setting('is_superuser') as own_super \gset

\i :impl_path

select nspowner::regrole::text as schema_owner
from pg_namespace where nspname = 'validate' \gset

select (select count(*) from pg_proc p where p.pronamespace = 'validate'::regnamespace) as funcs,
       (select count(*) from pg_proc p
        where p.pronamespace = 'validate'::regnamespace and p.proowner <> 'val_owner'::regrole)
     + (select count(*) from pg_class c
        where c.relnamespace = 'validate'::regnamespace and c.relowner <> 'val_owner'::regrole) as unowned,
       (select count(*) from pg_proc p join pg_language l on l.oid = p.prolang
        where p.pronamespace = 'validate'::regnamespace and l.lanname in ('c', 'internal')) as c_funcs \gset

select (validate.email('ada@example.com') and validate.format('iban', 'GB82WEST12345698765432'))::text as smoke \gset
create function public.ticket(value text) returns boolean language sql immutable as $$ select value ~ '^T-[0-9]+$' $$;
select validate.register_format(name => 'ticket', validator => 'public.ticket(text)');
select validate.format('ticket', 'T-42')::text as smoke_reg \gset

-- 2. pg_tle (only if the server has it loaded)
\if :tle_avail
    \connect postgres
    create database pgval_tle_scratch2 owner val_owner;
    \connect pgval_tle_scratch2
    create extension pg_tle;
    grant pgtle_admin to val_owner;
    -- pg_tle refuses a name that also has a control file on disk
    -- (docker/run-matrix.sh installs one for 04_control_install).
    select case when exists (select 1 from pg_available_extensions where name = 'pg_validate')
                then 'pg_validate_tle' else 'pg_validate' end as tle_name \gset
    set session authorization val_owner;
    -- Backticks interpolate :name and :'name' (shell-quoted), not :"name".
    \set impl_body `cat :'impl_path'`
    select pgtle.install_extension(
        name => :'tle_name',
        version => '0.0.1',
        description => 'pg_validate test install',
        ext => :'impl_body',
        schema => 'validate'
    );
    select exists (select 1 from pgtle.available_extensions() where name = :'tle_name')::text as tle_registered \gset
    create extension :"tle_name";
    select count(*)::text as tle_installed from pg_extension where extname = :'tle_name' \gset
    select extnamespace::regnamespace::text as tle_schema from pg_extension where extname = :'tle_name' \gset
    select count(*)::text as tle_members
    from pg_depend d join pg_proc p on p.oid = d.objid and d.classid = 'pg_proc'::regclass
    where d.refclassid = 'pg_extension'::regclass and d.deptype = 'e'
      and d.refobjid = (select oid from pg_extension where extname = :'tle_name')
      and p.pronamespace = 'validate'::regnamespace \gset
    select (extconfig = array['validate.formats'::regclass::oid, 'validate.schemas'::regclass::oid]
            and extcondition = array['where not builtin', ''])::text as tle_config
    from pg_extension where extname = :'tle_name' \gset
    create function public.ticket(value text) returns boolean language sql immutable as $$ select value ~ '^T-[0-9]+$' $$;
    select validate.register_format(name => 'ticket', validator => 'public.ticket(text)');
    select (validate.format('ticket', 'T-42') and validate.cron('0 3 * * *'))::text as tle_smoke \gset
    drop extension :"tle_name";
    select (to_regprocedure('validate.email(text)') is null)::text as tle_dropped \gset
\endif

\connect :"orig_db"

select tap.plan(9);

select tap.is(:'own_super'::text, 'off', 'the install session is not a superuser');
select tap.is(:'schema_owner'::text, 'val_owner', 'the validate schema is owned by the installing non-superuser');
select tap.ok(:'funcs'::text ~ '^[1-9]' and :'unowned'::text = '0',
              'every function and table in the schema is owned by the installing role (funcs: '
              || :'funcs'::text || ', not owned: ' || :'unowned'::text || ')');
select tap.is(:'c_funcs'::text, '0', 'no function is written in C or internal');
select tap.is(:'smoke'::text, 'true', 'smoke: validators work after a non-superuser install');
select tap.is(:'smoke_reg'::text, 'true', 'smoke: the installing role can register and use a custom format');

\if :tle_avail
    select tap.ok(:'tle_registered'::text = 'true' and :'tle_installed'::text = '1'
                  and :'tle_schema'::text = 'validate' and :'tle_members'::text ~ '^[1-9]',
                  'pgtle.install_extension + create extension works as a non-superuser, in schema validate (extension: '
                  || :'tle_name'::text || ', functions: ' || :'tle_members'::text || ')');
    select tap.is(:'tle_config'::text, 'true',
                  'validate.formats (rows where not builtin) and validate.schemas (all rows) are extension config tables');
    select tap.ok(:'tle_smoke'::text = 'true' and :'tle_dropped'::text = 'true',
                  'a custom format works under pg_tle, and drop extension removes the functions');
\else
    \echo '# pg_tle is not available on this server; the pgtle.install_extension path was NOT tested'
    select tap.pass('SKIP pg_tle not available: install_extension');
    select tap.pass('SKIP pg_tle not available: config dump');
    select tap.pass('SKIP pg_tle not available: smoke and drop');
\endif

drop database if exists pgval_tle_scratch with (force);
drop database if exists pgval_tle_scratch2 with (force);
drop role if exists val_owner;

select * from tap.finish();
