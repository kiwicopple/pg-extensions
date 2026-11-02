-- Goal: an installed 0.0.1 upgrades to 0.1.0, and the result is the same
-- schema as a fresh 0.1.0 install (research/plan-cedar.md, "Versioning").
--
-- Builds three scratch databases as the superuser and compares their catalogs
-- with test/fixtures/d/catalog_fingerprint.sql (every function's signature,
-- definition, ACL and comment; every table, column, index, constraint,
-- policy, trigger and type):
--
--   pgperm_up_old    pg_permissions--0.0.1.sql, then pg_permissions--0.0.1--0.1.0.sql (psql -f)
--   pgperm_up_new    the implementation under test (:impl_path), a fresh 0.1.0
--   pgperm_up_tle    if pg_tle is loaded: pgtle.install_extension of 0.0.1,
--                    pgtle.install_update_path to 0.1.0, create extension
--                    version '0.0.1', alter extension update to '0.1.0'
--
-- The 0.0.1 file and the upgrade script are read from the directory of
-- :impl_path, which test/run.sh passes with `-v impl_path=...`. Without
-- pg_tle the last three assertions pass with a SKIP (docker/run-matrix.sh runs
-- them). Leftovers from a run that died halfway are dropped first.
\set ON_ERROR_STOP off

select current_database() as orig_db \gset
select exists (select 1 from pg_available_extensions where name = 'pg_tle')
       and current_setting('shared_preload_libraries') ~ '\mpg_tle\M' as tle_avail \gset
\set ext_dir `dirname :'impl_path'`
\set old_path :ext_dir '/pg_permissions--0.0.1.sql'
\set up_path :ext_dir '/pg_permissions--0.0.1--0.1.0.sql'

-- Defaults, so a failed step leaves a visible value instead of an unset variable.
\set up_funcs '{}'
\set up_rels '{}'
\set new_funcs '{}'
\set new_rels '{}'
\set tle_funcs '{}'
\set tle_rels '{}'
\set tle_version ''
\set tle_members ''
\set tle_nfuncs ''

drop database if exists pgperm_up_old with (force);
drop database if exists pgperm_up_new with (force);
drop database if exists pgperm_up_tle with (force);
create database pgperm_up_old;
create database pgperm_up_new;

-- 1. 0.0.1, then the upgrade script
\connect pgperm_up_old
\i :old_path
\i :up_path
\set fp_prefix up_
\ir ../../fixtures/d/catalog_fingerprint.sql

-- 2. A fresh install of the implementation under test
\connect pgperm_up_new
\i :impl_path
\set fp_prefix new_
\ir ../../fixtures/d/catalog_fingerprint.sql

-- 3. pg_tle: the update path (only if the server has it loaded)
\if :tle_avail
    \connect postgres
    create database pgperm_up_tle;
    \connect pgperm_up_tle
    create extension pg_tle;
    -- Backticks interpolate :name and :'name' (shell-quoted), not :"name".
    \set old_body `cat :'old_path'`
    \set up_body `cat :'up_path'`
    select pgtle.install_extension('pg_permissions', '0.0.1', 'pg_permissions test install', :'old_body');
    select pgtle.install_update_path('pg_permissions', '0.0.1', '0.1.0', :'up_body');
    create extension pg_permissions version '0.0.1';
    alter extension pg_permissions update to '0.1.0';
    select extversion as tle_version from pg_extension where extname = 'pg_permissions' \gset
    -- functions in schema permissions that belong to the extension, and all of them
    select (select count(*)
            from pg_depend d join pg_proc p on p.oid = d.objid and d.classid = 'pg_proc'::regclass
            where d.refclassid = 'pg_extension'::regclass and d.deptype = 'e'
              and d.refobjid = (select oid from pg_extension where extname = 'pg_permissions')
              and p.pronamespace = 'permissions'::regnamespace)::text as tle_members,
           (select count(*) from pg_proc p where p.pronamespace = 'permissions'::regnamespace)::text as tle_nfuncs \gset
    \set fp_prefix tle_
    \ir ../../fixtures/d/catalog_fingerprint.sql
\endif

-- Back to the spec database for the assertions.
\connect :"orig_db"

select tap.plan(8);

select tap.ok(cardinality(:'new_funcs'::text[]) > 0 and cardinality(:'up_funcs'::text[]) = cardinality(:'new_funcs'::text[]),
              format('0.0.1 + upgrade has as many functions as a fresh install (%s and %s)',
                     cardinality(:'up_funcs'::text[]), cardinality(:'new_funcs'::text[])));
select tap.is(array(select unnest(:'up_funcs'::text[]) except select unnest(:'new_funcs'::text[]) order by 1),
              '{}'::text[], 'upgrade: no function differs from a fresh install (entries only in the upgraded database)');
select tap.is(array(select unnest(:'new_funcs'::text[]) except select unnest(:'up_funcs'::text[]) order by 1),
              '{}'::text[], 'upgrade: no function of a fresh install is missing or different after the upgrade');
select tap.is(array(select unnest(:'up_rels'::text[]) except select unnest(:'new_rels'::text[]) order by 1),
              '{}'::text[], 'upgrade: tables, indexes, constraints, policies and types match a fresh install (only in the upgraded database)');
select tap.is(array(select unnest(:'new_rels'::text[]) except select unnest(:'up_rels'::text[]) order by 1),
              '{}'::text[], 'upgrade: tables, indexes, constraints, policies and types match a fresh install (missing after the upgrade)');

\if :tle_avail
    select tap.is(:'tle_version'::text, '0.1.0', 'pg_tle: alter extension pg_permissions update to ''0.1.0'' through install_update_path');
    select tap.is(array(select x from (select unnest(:'tle_funcs'::text[]) except select unnest(:'new_funcs'::text[])
                                       union all
                                       select unnest(:'new_funcs'::text[]) except select unnest(:'tle_funcs'::text[])) d(x) order by 1)
                  || array(select x from (select unnest(:'tle_rels'::text[]) except select unnest(:'new_rels'::text[])
                                          union all
                                          select unnest(:'new_rels'::text[]) except select unnest(:'tle_rels'::text[])) d(x) order by 1),
                  '{}'::text[], 'pg_tle: the updated extension matches a fresh install (entries that differ)');
    select tap.ok(:'tle_members'::text ~ '^[1-9]' and :'tle_members'::text = :'tle_nfuncs'::text,
                  'pg_tle: every function in the schema belongs to the extension after the update (members: '
                  || :'tle_members'::text || ', functions: ' || :'tle_nfuncs'::text || ')');
\else
    \echo '# pg_tle is not available on this server (not in pg_available_extensions or shared_preload_libraries)'
    \echo '# only the psql -f upgrade was checked; the pgtle.install_update_path path was NOT tested'
    select tap.pass('SKIP pg_tle not available: update path not tested (alter extension update)');
    select tap.pass('SKIP pg_tle not available: update path not tested (catalog)');
    select tap.pass('SKIP pg_tle not available: update path not tested (extension members)');
\endif

-- Cleanup
drop database if exists pgperm_up_old with (force);
drop database if exists pgperm_up_new with (force);
drop database if exists pgperm_up_tle with (force);

select * from tap.finish();
