-- Goal: the install creates schema validate with the documented API: 37
-- built-in validators, each registered under its own name with a
-- description, five JSON Schema format names as built-in aliases, the uuid
-- and nanoid overloads, the registry functions and json_schema. No C, no
-- other extension.
select tap.plan(9);

select tap.ok(to_regnamespace('validate') is not null, 'schema validate exists');

select tap.set_eq(
    array(select l.name from validate.list_formats() l where l.builtin),
    array['base64', 'base64url', 'card_number', 'country_code', 'country_code_alpha3', 'cron',
          'currency_code', 'domain', 'duration', 'e164', 'email', 'git_sha', 'hex', 'hostname',
          'iban', 'ipv4', 'ipv6', 'isbn', 'isbn10', 'isbn13', 'iso8601', 'json_pointer',
          'language_code', 'luhn', 'mac', 'nanoid', 'port', 'rfc3339', 'rfc3339_date',
          'rfc3339_time', 'semver', 'slug', 'ulid', 'uri', 'uri_reference', 'url', 'uuid',
          'date-time', 'date', 'time', 'uri-reference', 'json-pointer'],
    'the 37 built-in validators and 5 JSON Schema aliases are registered');

select tap.is(
    (select count(*)::int from validate.list_formats() l
     where l.builtin and l.name = any(validate._builtin_formats())
       and l.validator = format('validate.%I(text)', l.name)::regprocedure),
    37, 'each built-in validator''s format points at validate.<name>(text)');
select tap.set_eq(
    array(select l.name || '=' || l.validator::text from validate.list_formats() l
          where l.builtin and not l.name = any(validate._builtin_formats())),
    array['date-time=validate.rfc3339(text)', 'date=validate.rfc3339_date(text)', 'time=validate.rfc3339_time(text)',
          'uri-reference=validate.uri_reference(text)', 'json-pointer=validate.json_pointer(text)'],
    'the JSON Schema aliases point at the matching validators');

select tap.is(
    (select count(*)::int from validate.list_formats() l where l.builtin and l.description is not null),
    42, 'each built-in format has a description');

select tap.set_eq(
    array(select p.oid::regprocedure::text from pg_proc p
          where p.pronamespace = 'validate'::regnamespace and p.proname not like '\_%'
            and p.oid::regprocedure::text not in (select format('validate.%I(text)', b) from unnest(validate._builtin_formats()) b)),
    array['validate.uuid(text,integer)', 'validate.nanoid(text,integer,text)',
          'validate.format(text,text)', 'validate.list_formats()',
          'validate.register_format(text,regprocedure,text)', 'validate.unregister_format(text)',
          'validate.json_schema(jsonb,jsonb)', 'validate.json_schema_errors(jsonb,jsonb)'],
    'the other public functions are the two overloads, the registry API and json_schema');

select tap.is(
    (select count(*)::int from pg_proc p join pg_language l on l.oid = p.prolang
     where p.pronamespace = 'validate'::regnamespace and l.lanname not in ('sql', 'plpgsql')),
    0, 'every function is SQL or PL/pgSQL');

select tap.is(validate.format(name => 'email', value => 'ada@example.com'), true, 'smoke: format(email)');
select tap.is(validate.email(value => 'ada@example.com'), true, 'smoke: email()');

select * from tap.finish();
