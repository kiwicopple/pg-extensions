-- Goal: the conventions of the extension file, for the ydoc_ objects: no
-- SECURITY DEFINER, PL/pgSQL or SQL only, a pinned search_path on every
-- public function that writes or decides on identity, no privileges on the
-- tables for public, and labels (VOLATILE writers, STABLE readers).
select tap.plan(9);
select tap.is((select count(*)::int from pg_proc where pronamespace = 'crdt'::regnamespace and proname like '%ydoc%' and prosecdef), 0,
              'no SECURITY DEFINER function');
select tap.is((select array_agg(distinct l.lanname::text order by l.lanname::text) from pg_proc p join pg_language l on l.oid = p.prolang
               where p.pronamespace = 'crdt'::regnamespace and p.proname like '%ydoc%'), array['plpgsql', 'sql'], 'PL/pgSQL and SQL only');
select tap.is((select string_agg(proname, ', ' order by proname) from pg_proc
               where pronamespace = 'crdt'::regnamespace and proname like 'ydoc%' and provolatile = 'v'
                 and not coalesce(proconfig @> array['search_path=pg_catalog, pg_temp'], false)), null,
              'every public writer pins search_path');
select tap.is((select string_agg(proname, ', ' order by proname) from pg_proc
               where pronamespace = 'crdt'::regnamespace and proname in ('ydoc_create', 'ydoc_insert', 'ydoc_delete', 'ydoc_set',
                                                                          'ydoc_apply', 'ydoc_merge', 'ydoc_drop') and provolatile <> 'v'), null,
              'writers are VOLATILE');
select tap.is((select string_agg(proname, ', ' order by proname) from pg_proc
               where pronamespace = 'crdt'::regnamespace and proname in ('ydoc_value', 'ydoc_length', 'ydoc_version', 'ydoc_base', 'ydoc_ops_since')
                 and provolatile <> 's'), null, 'readers are STABLE');
select tap.is((select count(*)::int from pg_class c, aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
               where c.relnamespace = 'crdt'::regnamespace and c.relname like 'ydoc%' and a.grantee <> c.relowner), 0,
              'no table or sequence privileges for any role but the owner');
select tap.ok((select bool_and(has_function_privilege('public', p.oid, 'execute')) from pg_proc p
               where p.pronamespace = 'crdt'::regnamespace and p.proname like 'ydoc%'), 'execute on the API for public (table privileges gate it)');
select tap.is((select count(*)::int from pg_proc where pronamespace = 'crdt'::regnamespace and proname like '%ydoc%'
               and prosrc ~* '\m(execute|format)\M'), 0, 'no dynamic SQL');
-- PL/pgSQL bodies are parsed at run time with the caller's search_path, so
-- an operator in a schema the caller searches could replace ours: every
-- PL/pgSQL function pins search_path. SQL functions use SQL-standard bodies
-- (parsed once, at creation), which keeps them inlinable.
select tap.is((select string_agg(p.proname, ', ' order by p.proname) from pg_proc p join pg_language l on l.oid = p.prolang
               where p.pronamespace = 'crdt'::regnamespace and p.proname like '%ydoc%'
                 and not ((l.lanname = 'plpgsql' and coalesce(p.proconfig @> array['search_path=pg_catalog, pg_temp'], false))
                          or (l.lanname = 'sql' and p.prosqlbody is not null))), null,
              'every PL/pgSQL function pins search_path; every SQL function has a SQL-standard body');
select * from tap.finish();
