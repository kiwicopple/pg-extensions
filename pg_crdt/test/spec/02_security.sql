-- Goal: the column-only extension has the expected API and privileges.
create temp table client_api (sig regprocedure);
insert into client_api values
    ('crdt.current_replica_id()'),
    ('crdt.pn_empty()'),
    ('crdt.pn_increment(crdt.pn, text, bigint)'),
    ('crdt.pn_decrement(crdt.pn, text, bigint)'),
    ('crdt.pn_value(crdt.pn)'),
    ('crdt.pn_merge(crdt.pn, crdt.pn)'),
    ('crdt.pn_merge_agg(crdt.pn)'),
    ('crdt.pn_is_valid(jsonb)'),
    ('crdt.pn_apply_delta(crdt.pn, crdt.pn, text)'),
    ('crdt.yseq_empty()'),
    ('crdt.yseq_new()'),
    ('crdt.yseq_value(crdt.yseq)'),
    ('crdt.yseq_length(crdt.yseq)'),
    ('crdt.yseq_version(crdt.yseq)'),
    ('crdt.yseq_insert(crdt.yseq, integer, text, text)'),
    ('crdt.yseq_delete(crdt.yseq, integer, integer, text)'),
    ('crdt.yseq_set(crdt.yseq, text, text, crdt.yseq)'),
    ('crdt.yseq_ops_since(crdt.yseq, jsonb)'),
    ('crdt.yseq_diff(crdt.yseq, crdt.yseq)'),
    ('crdt.yseq_merge(crdt.yseq, crdt.yseq)'),
    ('crdt.yseq_merge_agg(crdt.yseq)'),
    ('crdt.yseq_apply(crdt.yseq, jsonb, text)'),
    ('crdt.yseq_is_valid(jsonb)');

create temp table client_roles as
select rolname from pg_roles where rolname in ('anon', 'authenticated');

select tap.plan(22);

select tap.is((select count(*)::int from pg_proc where pronamespace = 'crdt'::regnamespace and proname !~ '^_'),
              (select count(*)::int from client_api),
              'the crdt schema has exactly the functions of the client API, besides internals (named _...)');
select tap.is((select string_agg(proname, ', ' order by proname) from pg_proc
               where pronamespace = 'crdt'::regnamespace and proname ~ '^_' and proname !~ '^_yseq_'), null,
              'every internal function is a yseq_ internal (_yseq_...)');

select tap.is(
    (select count(*)::int from client_roles r cross join client_api a
     where not has_function_privilege(r.rolname, a.sig, 'execute')),
    0, 'anon and authenticated (where they exist) can execute every client-facing function');
select tap.is(
    (select count(*)::int from client_roles r
     where not has_schema_privilege(r.rolname, 'crdt', 'usage')),
    0, 'anon and authenticated (where they exist) have usage on schema crdt');
select tap.is(
    (select count(*)::int from client_roles r
     where has_schema_privilege(r.rolname, 'crdt', 'create')),
    0, 'no client role can create objects in schema crdt');
select tap.is(
    (select count(*)::int from pg_proc p
     cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) x
     where p.pronamespace = 'crdt'::regnamespace and x.grantee = 0
       and p.oid not in (select sig from client_api) and p.proname !~ '^_yseq_'),
    0, 'public can execute nothing outside the client API and the yseq_ internals');
select tap.is(
    (select string_agg(p.proname, ', ' order by 1) from pg_proc p
     where p.pronamespace = 'crdt'::regnamespace and p.proname ~ '^_yseq_'
       and not has_function_privilege('public', p.oid, 'execute')),
    null, 'public can execute the yseq_ internals (pure functions the yseq_ API calls)');
select tap.is(
    (select string_agg(c.relname || ':' || coalesce(nullif(x.grantee, 0)::regrole::text, 'public'), ', ' order by 1)
     from pg_class c
     cross join lateral aclexplode(coalesce(c.relacl, acldefault(case c.relkind when 'S' then 's' else 'r' end::"char", c.relowner))) x
     where c.relnamespace = 'crdt'::regnamespace and c.relkind in ('r', 'S', 'p') and x.grantee <> c.relowner),
    null, 'no role but the owner has privileges on a table or sequence in schema crdt');
select tap.ok(has_type_privilege('public', 'crdt.pn', 'usage'),
              'public has usage on the crdt.pn domain (columns and casts)');
select tap.ok(has_type_privilege('public', 'crdt.yseq', 'usage'),
              'public has usage on the crdt.yseq domain (columns and casts)');

select tap.is(
    (select count(*)::int from pg_proc p join pg_language l on l.oid = p.prolang
     where p.pronamespace = 'crdt'::regnamespace and l.lanname not in ('sql', 'plpgsql', 'internal')),
    0, 'every function is LANGUAGE sql or plpgsql (the aggregate is internal by definition)');
select tap.is(
    (select count(*)::int from pg_proc p
     where p.pronamespace = 'crdt'::regnamespace and p.prokind = 'f'
       and p.prolang = (select oid from pg_language where lanname = 'internal')),
    0, 'no plain function is internal or C');

select tap.is(
    (select string_agg(p.oid::regprocedure::text, ', ' order by 1) from pg_proc p
     where p.oid in ('crdt.pn_empty()'::regprocedure, 'crdt.pn_increment(crdt.pn, text, bigint)'::regprocedure,
                     'crdt.pn_decrement(crdt.pn, text, bigint)'::regprocedure, 'crdt.pn_value(crdt.pn)'::regprocedure,
                     'crdt.pn_merge(crdt.pn, crdt.pn)'::regprocedure, 'crdt.pn_merge_agg(crdt.pn)'::regprocedure,
                     'crdt.pn_is_valid(jsonb)'::regprocedure, 'crdt.pn_apply_delta(crdt.pn, crdt.pn, text)'::regprocedure)
       and not (p.provolatile = 'i' and p.proparallel = 's')),
    null, 'pure functions, the aggregate and pn_apply_delta (pure given its replica argument) are IMMUTABLE PARALLEL SAFE');
select tap.is(
    (select string_agg(p.oid::regprocedure::text, ', ' order by 1) from pg_proc p
     where p.pronamespace = 'crdt'::regnamespace and p.proname ~ '^_?yseq_'
       and p.oid <> 'crdt.yseq_new()'::regprocedure
       and not (p.provolatile = 'i' and p.proparallel = 's')),
    null, 'every yseq_ function and internal but yseq_new is IMMUTABLE PARALLEL SAFE (yseq_value can back a generated column or an index)');
select tap.is(
    (select provolatile::text || proparallel::text from pg_proc where oid = 'crdt.yseq_new()'::regprocedure),
    'vs', 'yseq_new, which draws a random document id, is VOLATILE PARALLEL SAFE');
select tap.is(
    (select provolatile::text from pg_proc where oid = 'crdt.current_replica_id()'::regprocedure),
    's', 'current_replica_id, which reads settings, is STABLE');
select tap.is(
    (select string_agg(p.proname, ', ' order by 1) from pg_proc p
     where p.oid in ('crdt.current_replica_id()'::regprocedure, 'crdt.pn_apply_delta(crdt.pn, crdt.pn, text)'::regprocedure,
                     'crdt.yseq_apply(crdt.yseq, jsonb, text)'::regprocedure)
       and not exists (select 1 from unnest(p.proconfig) c where c = 'search_path=pg_catalog, pg_temp')),
    null, 'functions that decide on identity pin search_path to pg_catalog, pg_temp');
select tap.is(
    (select string_agg(p.proname, ', ' order by p.proname) from pg_proc p join pg_language l on l.oid = p.prolang
     where p.pronamespace = 'crdt'::regnamespace and p.proname ~ '^_?yseq_' and p.prokind = 'f'
       and not ((l.lanname = 'plpgsql' and coalesce(p.proconfig @> array['search_path=pg_catalog, pg_temp'], false))
                or (l.lanname = 'sql' and p.prosqlbody is not null))),
    null, 'every yseq_ PL/pgSQL function pins search_path; every yseq_ SQL function has a SQL-standard body');
select tap.is(
    (select string_agg(proname, ', ' order by proname) from pg_proc
     where pronamespace = 'crdt'::regnamespace and proname ~ '^_?yseq_' and prosrc ~* '\mexecute\M'), null,
    'no dynamic SQL (EXECUTE) in the yseq_ functions (format() only builds error messages)');
select tap.is(
    (select count(*)::int from pg_proc p
     where p.pronamespace = 'crdt'::regnamespace and p.prosecdef),
    0, 'the extension has no SECURITY DEFINER function (apps wrap pn_apply_delta, yseq_apply in their own)');

select tap.is((select count(*)::int from pg_class where relnamespace = 'crdt'::regnamespace and relkind in ('r', 'p', 'S')), 0,
              'the extension owns no document tables or sequences');
select tap.is((select count(*)::int from pg_proc where pronamespace = 'crdt'::regnamespace and proname ~ '^_?ydoc_'), 0,
              'table-backed document functions are research only');
select * from tap.finish();
