-- Goal: with pg_validate.control and the SQL file in the server's extension
-- directory, a non-superuser runs `create extension pg_validate`: the extension
-- lands in schema validate, is not relocatable, and marks the registry for
-- pg_dump. A dump keeps registered formats but not the built-in rows, and
-- restores into a new database with the owner of each entry intact.
--
-- docker/run-matrix.sh copies the two files into each server before the run.
-- A local throwaway cluster has neither, so the file then passes with SKIP
-- assertions. Needs pg_dump and psql on PATH (test/run.sh adds PGBIN).
\set ON_ERROR_STOP off

select current_database() as orig_db \gset
select exists (select 1 from pg_available_extensions where name = 'pg_validate') as ctl_avail \gset

\set ext_schema ''
\set ext_reloc ''
\set ext_config ''
\set dump_ext ''
\set dump_custom ''
\set dump_builtin ''
\set restore_builtins ''
\set restore_custom ''
\set restore_owner ''

drop database if exists pgval_ctl_scratch with (force);
drop database if exists pgval_ctl_restore with (force);
drop role if exists val_ctl_owner;

\if :ctl_avail
    create role val_ctl_owner nosuperuser createdb nologin;
    create database pgval_ctl_scratch owner val_ctl_owner;
    \connect pgval_ctl_scratch
    set session authorization val_ctl_owner;
    create extension pg_validate;
    select extnamespace::regnamespace::text as ext_schema,
           extrelocatable::text as ext_reloc,
           (extconfig = array['validate.formats'::regclass::oid] and extcondition = array['where not builtin'])::text as ext_config
    from pg_extension where extname = 'pg_validate' \gset
    create function public.ticket(value text) returns boolean language sql immutable as $$ select value ~ '^T-[0-9]+$' $$;
    select validate.register_format(name => 'ticket', validator => 'public.ticket(text)', description => 'Ticket id');
    reset session authorization;

    \set dump `pg_dump -d pgval_ctl_scratch`
    select (strpos(:'dump', 'CREATE EXTENSION IF NOT EXISTS pg_validate WITH SCHEMA validate') > 0)::text as dump_ext,
           (:'dump' ~ ('(^|\n)ticket\tpublic\tticket\tf\tTicket id\tval_ctl_owner\t'))::text as dump_custom,
           (:'dump' ~ ('(^|\n)email\tvalidate\temail\t'))::text as dump_builtin \gset

    \connect postgres
    create database pgval_ctl_restore;
    \set restore_out `pg_dump -d pgval_ctl_scratch | psql -X -q -o /dev/null -d pgval_ctl_restore 2>&1`
    \connect pgval_ctl_restore
    select count(*)::text as restore_builtins from validate.formats where builtin \gset
    select validate.format('ticket', 'T-7')::text as restore_custom \gset
    select owner::text as restore_owner from validate.formats where name = 'ticket' \gset
\endif

\connect :"orig_db"

select tap.plan(6);

\if :ctl_avail
    select tap.ok(:'ext_schema'::text = 'validate' and :'ext_reloc'::text = 'false',
                  'a non-superuser can create extension pg_validate; it is in schema validate and not relocatable');
    select tap.is(:'ext_config'::text, 'true', 'validate.formats is a config table dumping rows where not builtin');
    select tap.is(:'dump_ext'::text, 'true', 'pg_dump emits create extension pg_validate');
    select tap.ok(:'dump_custom'::text = 'true' and :'dump_builtin'::text = 'false',
                  'pg_dump keeps the registered format and leaves out the built-in rows');
    select tap.is(:'restore_builtins'::text, '42', 'after restore, the built-in rows exist once');
    select tap.ok(:'restore_custom'::text = 'true' and :'restore_owner'::text = 'val_ctl_owner',
                  'after restore, the registered format works and keeps its owner (restore output: '
                  || coalesce(nullif(:'restore_out'::text, ''), 'none') || ')');
\else
    \echo '# pg_validate.control is not installed on this server; create extension was NOT tested'
    select tap.pass('SKIP control file not installed: create extension');
    select tap.pass('SKIP control file not installed: config table');
    select tap.pass('SKIP control file not installed: pg_dump');
    select tap.pass('SKIP control file not installed: dump contents');
    select tap.pass('SKIP control file not installed: restore');
    select tap.pass('SKIP control file not installed: restored format');
\endif

drop database if exists pgval_ctl_scratch with (force);
drop database if exists pgval_ctl_restore with (force);
drop role if exists val_ctl_owner;

select * from tap.finish();
