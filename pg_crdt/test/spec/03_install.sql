-- Goal: the one file installs as a plain script and with CREATE EXTENSION
-- (pg_tle, or the control file in the extension directory), as a
-- non-superuser that owns the database, with no superuser-only features and
-- no C. The schema guard refuses a crdt schema that another role controls.
-- Dropping the extension is blocked while a column uses crdt.pn, and CASCADE
-- drops that column (the README warns about this).
--
-- Mirrors pg_permissions/test/spec/03_tle_install.sql: the runner's database
-- already has the file installed as superuser, so this spec builds scratch
-- databases owned by the non-superuser `crdt_owner`, installs there with SET
-- SESSION AUTHORIZATION, and copies what it observes into psql variables
-- (\gset). Variables survive \connect; the assertions run after reconnecting
-- to the original database, where the tap state lives. Installs that are
-- meant to fail run in a child psql (backticks) so their errors do not count
-- as errors of this file.
--
-- Needs :impl_path, which test/run.sh passes. The pg_tle branch runs only when
-- the server preloads pg_tle, the control-file branch only when pg_crdt is in
-- the extension directory (test/docker.sh installs both); otherwise they
-- pass with SKIP assertions.
\set ON_ERROR_STOP off

select current_database() as orig_db \gset
select exists (select 1 from pg_available_extensions where name = 'pg_tle')
       and current_setting('shared_preload_libraries') ~ '\mpg_tle\M' as tle_avail \gset
select exists (select 1 from pg_available_extensions where name = 'pg_crdt') as ctl_avail \gset

-- Defaults, so a failed step leaves a visible value instead of an unset variable.
\set own_super ''
\set schema_owner ''
\set funcs ''
\set unowned ''
\set c_funcs ''
\set smoke ''
\set guard_owner_out ''
\set guard_create_out ''
\set tle_installed ''
\set tle_schema ''
\set tle_members ''
\set tle_smoke ''
\set tle_drop_restrict ''
\set tle_drop_cascade ''
\set ctl_schema ''
\set ctl_reloc ''
\set ctl_smoke ''

-- Leftovers from an earlier run
drop database if exists pgcrdt_install_plain with (force);
drop database if exists pgcrdt_install_guard with (force);
drop database if exists pgcrdt_install_tle with (force);
drop database if exists pgcrdt_install_ctl with (force);
drop role if exists crdt_owner;
drop role if exists crdt_other;

create role crdt_owner nosuperuser createdb nologin;
create role crdt_other nosuperuser nologin;
create database pgcrdt_install_plain owner crdt_owner;
create database pgcrdt_install_guard owner crdt_owner;

-- 1. Plain install (psql -f) as the non-superuser
\connect pgcrdt_install_plain
set session authorization crdt_owner;
select current_setting('is_superuser') as own_super \gset

\i :impl_path

select nspowner::regrole::text as schema_owner from pg_namespace where nspname = 'crdt' \gset
select (select count(*) from pg_proc where pronamespace = 'crdt'::regnamespace) as funcs,
       (select count(*) from pg_proc where pronamespace = 'crdt'::regnamespace and proowner <> 'crdt_owner'::regrole)
     + (select count(*) from pg_type where typnamespace = 'crdt'::regnamespace and typowner <> 'crdt_owner'::regrole) as unowned,
       (select count(*) from pg_proc p join pg_language l on l.oid = p.prolang
        where p.pronamespace = 'crdt'::regnamespace and l.lanname = 'c') as c_funcs \gset

create table counters (id int primary key, s crdt.pn not null default crdt.pn_empty());
insert into counters values (1);
update counters set s = crdt.pn_increment(s, 'a', 5) where id = 1;
update counters set s = crdt.pn_merge(s, crdt.pn_decrement(crdt.pn_empty(), 'b', 2)) where id = 1;
select (crdt.pn_value(s) = 3 and crdt.pn_value((select crdt.pn_merge_agg(s) from counters)) = 3)::text as smoke
from counters where id = 1 \gset

-- 2. The schema guard: a crdt schema owned by another non-superuser, then one
-- where another role has CREATE. Each install must stop at the guard.
\connect pgcrdt_install_guard
create schema crdt authorization crdt_other;
\set guard_owner_out `psql -X -q -v ON_ERROR_STOP=1 -d pgcrdt_install_guard -c 'set session authorization crdt_owner' -f :'impl_path' 2>&1`
alter schema crdt owner to crdt_owner;
grant create on schema crdt to crdt_other;
\set guard_create_out `psql -X -q -v ON_ERROR_STOP=1 -d pgcrdt_install_guard -c 'set session authorization crdt_owner' -f :'impl_path' 2>&1`

-- 3. pg_tle (only if the server has it loaded)
\if :tle_avail
    \connect postgres
    create database pgcrdt_install_tle owner crdt_owner;
    \connect pgcrdt_install_tle
    create extension pg_tle;
    grant pgtle_admin to crdt_owner;
    set session authorization crdt_owner;
    -- pg_tle refuses a name that also has a control file on disk
    -- (test/docker.sh installs one for the control-file branch).
    select case when :'ctl_avail' then 'pg_crdt_tle' else 'pg_crdt' end as tle_name \gset
    -- Backticks interpolate :name and :'name' (shell-quoted), not :"name".
    \set impl_body `cat :'impl_path'`
    select pgtle.install_extension(
        name => :'tle_name',
        version => '0.0.1',
        description => 'pg_crdt test install',
        ext => :'impl_body',
        schema => 'crdt'
    );
    create extension :"tle_name";
    select count(*)::text as tle_installed from pg_extension where extname = :'tle_name' \gset
    select extnamespace::regnamespace::text as tle_schema from pg_extension where extname = :'tle_name' \gset
    select count(*)::text as tle_members
    from pg_depend d
    where d.refclassid = 'pg_extension'::regclass and d.deptype = 'e'
      and d.refobjid = (select oid from pg_extension where extname = :'tle_name')
      and ((d.classid = 'pg_proc'::regclass and d.objid in (select oid from pg_proc where pronamespace = 'crdt'::regnamespace))
        or (d.classid = 'pg_type'::regclass and d.objid = 'crdt.pn'::regtype)) \gset
    create table counters (id int primary key, s crdt.pn not null default crdt.pn_empty());
    insert into counters values (1);
    update counters set s = crdt.pn_increment(s, 'a', 2) where id = 1;
    select (crdt.pn_value(s) = 2)::text as tle_smoke from counters \gset
    -- restrict: blocked by the column; cascade: drops the column
    select set_config('crdt_test.tle_name', :'tle_name', false);
    do $$
    begin
        execute format('drop extension %I', current_setting('crdt_test.tle_name'));
        perform set_config('crdt_test.drop_restrict', 'dropped', false);
    exception when dependent_objects_still_exist then
        perform set_config('crdt_test.drop_restrict', 'blocked', false);
    end;
    $$;
    select current_setting('crdt_test.drop_restrict', true) as tle_drop_restrict \gset
    drop extension :"tle_name" cascade;
    select (not exists (select 1 from pg_attribute where attrelid = 'counters'::regclass and attname = 's' and not attisdropped)
            and to_regtype('crdt.pn') is null)::text as tle_drop_cascade \gset
\endif

-- 4. The control file in the extension directory (only if it is installed there)
\if :ctl_avail
    \connect postgres
    create database pgcrdt_install_ctl owner crdt_owner;
    \connect pgcrdt_install_ctl
    set session authorization crdt_owner;
    create extension pg_crdt;
    select extnamespace::regnamespace::text as ctl_schema, extrelocatable::text as ctl_reloc
    from pg_extension where extname = 'pg_crdt' \gset
    select (crdt.pn_value(crdt.pn_merge(crdt.pn_increment(null, 'a', 4), crdt.pn_decrement(null, 'b', 1))) = 3)::text as ctl_smoke \gset
\endif

-- Back to the spec database as the superuser for the assertions.
\connect :"orig_db"

select tap.plan(11);

select tap.is(:'own_super'::text, 'off', 'the install session is not a superuser');
select tap.is(:'schema_owner'::text, 'crdt_owner', 'schema crdt is owned by the installing non-superuser');
select tap.ok(:'funcs'::text ~ '^[1-9]' and :'unowned'::text = '0',
              'every function and type in schema crdt is owned by the installing role (funcs: '
              || :'funcs'::text || ', not owned: ' || :'unowned'::text || ')');
select tap.is(:'c_funcs'::text, '0', 'no function is written in C');
select tap.is(:'smoke'::text, 'true', 'smoke: a crdt.pn column, increment, merge and the aggregate work after a non-superuser install');
select tap.ok(:'guard_owner_out'::text like '%schema crdt is owned by role crdt_other%',
              'the install stops when schema crdt belongs to another non-superuser');
select tap.ok(:'guard_create_out'::text like '%another role has CREATE on schema crdt%',
              'the install stops when another role has CREATE on schema crdt');

\if :tle_avail
    select tap.ok(:'tle_installed'::text = '1' and :'tle_schema'::text = 'crdt' and :'tle_members'::text ~ '^[1-9]',
                  'pgtle.install_extension + create extension works as a non-superuser, in schema crdt (members: '
                  || :'tle_members'::text || ')');
    select tap.is(:'tle_smoke'::text, 'true', 'smoke: a crdt.pn column works under pg_tle');
    select tap.ok(:'tle_drop_restrict'::text = 'blocked' and :'tle_drop_cascade'::text = 'true',
                  'drop extension is blocked by a crdt.pn column, and drop extension ... cascade drops the column (restrict: '
                  || :'tle_drop_restrict'::text || ', cascade: ' || :'tle_drop_cascade'::text || ')');
\else
    \echo '# pg_tle is not available on this server; the pgtle.install_extension path was NOT tested'
    select tap.pass('SKIP pg_tle not available: install_extension');
    select tap.pass('SKIP pg_tle not available: smoke');
    select tap.pass('SKIP pg_tle not available: drop extension restrict and cascade');
\endif

\if :ctl_avail
    select tap.ok(:'ctl_schema'::text = 'crdt' and :'ctl_reloc'::text = 'false' and :'ctl_smoke'::text = 'true',
                  'create extension pg_crdt from the control file works as a non-superuser, in schema crdt, not relocatable');
\else
    \echo '# pg_crdt is not in this server''s extension directory; the control-file path was NOT tested'
    select tap.pass('SKIP control file not installed: create extension pg_crdt');
\endif

-- Cleanup
drop database if exists pgcrdt_install_plain with (force);
drop database if exists pgcrdt_install_guard with (force);
drop database if exists pgcrdt_install_tle with (force);
drop database if exists pgcrdt_install_ctl with (force);
drop role if exists crdt_owner;
drop role if exists crdt_other;

select * from tap.finish();
