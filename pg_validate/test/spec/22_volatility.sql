-- Goal: volatility markings are true. Every built-in validator (and
-- overload) is IMMUTABLE STRICT PARALLEL SAFE and none reads a catalog or a
-- setting; format() and json_schema() are STABLE (the registry changes) and
-- PARALLEL UNSAFE (a registered validator may be); nothing is SECURITY
-- DEFINER; every function pins search_path. Results do not change with
-- TimeZone, DateStyle, standard_conforming_strings or a Turkish collation.
select tap.plan(19);

with b as (
    select p.*
    from validate.list_formats() l
    join pg_proc p on p.oid = l.validator
    where l.builtin
)
select tap.is(
    (select count(distinct oid)::int from b where provolatile = 'i' and proisstrict and proparallel = 's'),
    37, 'all 37 built-in validators are IMMUTABLE STRICT PARALLEL SAFE');

select tap.is(
    (select string_agg(p.oid::regprocedure::text, ', ')
     from pg_proc p
     where p.pronamespace = 'validate'::regnamespace
       and p.proname not like '\_%'
       and p.proname not in ('format', 'list_formats', 'register_format', 'unregister_format',
                             'json_schema', 'json_schema_errors')
       and not (p.provolatile = 'i' and p.proisstrict and p.proparallel = 's')),
    null, 'every public validator, overloads included, is IMMUTABLE STRICT PARALLEL SAFE');

select tap.is(
    (select string_agg(p.oid::regprocedure::text, ', ')
     from pg_proc p
     where p.pronamespace = 'validate'::regnamespace
       and p.proname like '\_%'
       -- the registry trigger, and the JSON Schema evaluator (it calls format())
       and p.proname not in ('_can_manage', '_formats_guard', '_js_eval', '_js_target', '_js_pct_decode')
       and not (p.provolatile = 'i' and p.proparallel = 's')),
    null, 'every other internal helper is IMMUTABLE PARALLEL SAFE');
select tap.is(
    (select string_agg(p.oid::regprocedure::text, ', ' order by 1)
     from pg_proc p
     where p.oid in ('validate.json_schema(jsonb, jsonb)'::regprocedure, 'validate.json_schema_errors(jsonb, jsonb)'::regprocedure)
       and p.provolatile = 's' and p.proisstrict and p.proparallel = 'u' and not p.prosecdef),
    'validate.json_schema(jsonb,jsonb), validate.json_schema_errors(jsonb,jsonb)',
    'json_schema() and json_schema_errors() are STABLE STRICT PARALLEL UNSAFE SECURITY INVOKER');

select tap.ok(
    (select provolatile = 's' and proparallel = 'u' and proisstrict and not prosecdef
     from pg_proc where oid = 'validate.format(text, text)'::regprocedure),
    'format() is STABLE, PARALLEL UNSAFE, STRICT and SECURITY INVOKER (not IMMUTABLE)');
select tap.isnt(
    (select provolatile from pg_proc where oid = 'validate.format(text, text)'::regprocedure),
    'i'::"char", 'format() is not IMMUTABLE');
select tap.is(
    (select provolatile from pg_proc where oid = 'validate.list_formats()'::regprocedure),
    's'::"char", 'list_formats() is STABLE');
select tap.is(
    (select count(*)::int from pg_proc where pronamespace = 'validate'::regnamespace and prosecdef),
    0, 'no function in the schema is SECURITY DEFINER');
select tap.is(
    (select string_agg(p.oid::regprocedure::text, ', ')
     from pg_proc p
     where p.pronamespace = 'validate'::regnamespace
       and not exists (select 1 from unnest(p.proconfig) c where c = 'search_path=""')),
    null, 'every function sets search_path to empty');

-- Immutable validators may be used in index expressions and generated
-- columns; format() may not.
create table t (v text);
select tap.lives_ok($$ create index on t ((validate.email(v))) $$, 'an immutable validator can be indexed');
select tap.lives_ok($$ alter table t add column ok boolean generated always as (validate.iso8601(v)) stored $$,
                    'an immutable validator can define a generated column');
select tap.throws_ok($$ create index on t ((validate.format('email', v))) $$, '42P17',
                     'format() cannot be indexed: it is not immutable');
create table tj (doc jsonb);
select tap.throws_ok($$ create index on tj ((validate.json_schema(doc, '{"type": "object"}'))) $$, '42P17',
                     'json_schema() cannot be indexed: it is not immutable');
select tap.lives_ok($$ alter table tj add constraint tj_doc check (validate.json_schema(doc, '{"type": "object"}')) $$,
                    'json_schema() can be used in a CHECK constraint');

-- Session settings do not change results
set timezone = 'Asia/Kathmandu';
set datestyle = 'German, DMY';
select tap.ok(validate.rfc3339('1990-12-31T15:59:60-08:00') and validate.iso8601('2026-W53-4')
              and not validate.rfc3339('2019-02-29T00:00:00Z'),
              'date validators ignore TimeZone and DateStyle');
reset timezone;
reset datestyle;

-- A new connection compiles the PL/pgSQL bodies again, under the new setting.
\connect
set standard_conforming_strings = off;
select tap.ok(validate.email('"a\\"b"@example.com') and validate.json_pointer('/a~1b')
              and validate.semver('1.0.0+build.1') and validate.base64('Zm9vYg=='),
              'results do not depend on standard_conforming_strings');
reset standard_conforming_strings;

select exists (select 1 from pg_collation where collname = 'tr-TR-x-icu') as has_tr \gset
\if :has_tr
select tap.ok(validate.cron('0 0 * jan-mar mon' collate "tr-TR-x-icu")
              and validate.country_code('TR' collate "tr-TR-x-icu")
              and validate.url('HTTPS://EXAMPLE.COM/I' collate "tr-TR-x-icu")
              and validate.email('IIi@example.com' collate "tr-TR-x-icu"),
              'results do not depend on the collation (Turkish dotted and dotless i)');
\else
select tap.pass('SKIP no tr-TR-x-icu collation on this server');
\endif

-- Validators that are pure functions of their argument return the same
-- result inside and outside a transaction that changed the registry.
begin;
select validate.register_format(name => 'temp-fmt', validator => 'validate.slug(text)');
select tap.is(validate.format('temp-fmt', 'a-b'), true, 'format() sees a format registered in the same transaction');
rollback;
select tap.throws_ok($$ select validate.format('temp-fmt', 'a-b') $$, '42704', 'and not after rollback');

select * from tap.finish();
