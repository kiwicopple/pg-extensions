-- Goal: privileges and function hygiene (architecture.md sections 5 and 6).
-- Every role can use the client-facing API and nothing else; every function
-- is SQL or PL/pgSQL; pure functions are IMMUTABLE PARALLEL SAFE; functions
-- that decide on identity pin search_path. Role checks use the PostgREST
-- convention roles anon and authenticated, only where they exist (test/run.sh
-- creates them; another server may not have them).

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
    ('crdt.pn_apply_delta(crdt.pn, crdt.pn, text)');

create temp table client_roles as
select rolname from pg_roles where rolname in ('anon', 'authenticated');

select tap.plan(12);

select tap.is((select count(*)::int from pg_proc where pronamespace = 'crdt'::regnamespace),
              (select count(*)::int from client_api),
              'the crdt schema has exactly the functions of the client API (internals would start with _)');

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
       and p.oid not in (select sig from client_api)),
    0, 'public can execute nothing outside the client API');
select tap.ok(has_type_privilege('public', 'crdt.pn', 'usage'),
              'public has usage on the crdt.pn domain (columns and casts)');

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
    (select provolatile::text from pg_proc where oid = 'crdt.current_replica_id()'::regprocedure),
    's', 'current_replica_id, which reads settings, is STABLE');
select tap.is(
    (select string_agg(p.proname, ', ' order by 1) from pg_proc p
     where p.oid in ('crdt.current_replica_id()'::regprocedure, 'crdt.pn_apply_delta(crdt.pn, crdt.pn, text)'::regprocedure)
       and not exists (select 1 from unnest(p.proconfig) c where c = 'search_path=pg_catalog, pg_temp')),
    null, 'functions that decide on identity pin search_path to pg_catalog, pg_temp');
select tap.is(
    (select count(*)::int from pg_proc p
     where p.pronamespace = 'crdt'::regnamespace and p.prosecdef),
    0, 'the extension has no SECURITY DEFINER function (apps wrap pn_apply_delta in their own)');

select * from tap.finish();
