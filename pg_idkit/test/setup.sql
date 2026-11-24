\set ON_ERROR_STOP on
set client_min_messages = warning;
create extension pgtap with schema public;
grant usage on schema public to idkit_owner;
\if :tle
    create extension pg_tle;
    \set new_sql `cat :'new_path'`
    \set old_sql `cat :'old_path'`
    \set update_sql `cat :'update_path'`
    select pgtle.install_extension(:'extension', :'old_version', 'ID kit test', :'old_sql');
    select pgtle.install_extension_version_sql(:'extension', :'version', :'new_sql');
    select pgtle.install_update_path(:'extension', :'old_version', :'version', :'update_sql');
\endif
set role idkit_owner;
create schema ids;
create schema idkit_test;
create table idkit_test.installation (mode text, version text, extension_name text, upgraded boolean);
insert into idkit_test.installation values (
    case when :plain then 'plain' when :tle then 'tle' else 'native' end,
    :'version', case when :plain then null else :'extension' end, :upgrade);
create table idkit_test.old_functions (name text, body text);
\if :plain
    set search_path = ids, pg_catalog;
    \i :new_path
    reset search_path;
\else
    \if :upgrade
        create extension :"extension" with schema ids version :'old_version';
        insert into idkit_test.old_functions
            select proname, prosrc from pg_proc where pronamespace = 'ids'::regnamespace;
        create table idkit_test.existing_rows (id uuid default ids.gen_random_uuid_v7());
        insert into idkit_test.existing_rows values (default);
        alter extension :"extension" update to :'version';
        insert into idkit_test.existing_rows values (default);
    \else
        create extension :"extension" with schema ids version :'version';
    \endif
\endif
reset role;
