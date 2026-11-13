-- Goal: clients (anon, authenticated) can call every validator, format(),
-- list_formats(), json_schema_named() and list_schemas(), and read both
-- registries, but cannot register, unregister or write the registry tables.
-- Checked through the catalog and by calling as the client roles.
select tap.plan(14);

select tap.is(
    (select string_agg(p.oid::regprocedure::text, ', ')
     from pg_proc p
     where p.pronamespace = 'validate'::regnamespace
       and p.proname not in ('register_format', 'unregister_format', 'register_schema', 'unregister_schema', '_registry_guard')
       and not has_function_privilege('authenticated', p.oid, 'execute')),
    null, 'authenticated can execute every validator and helper');
select tap.ok(not has_function_privilege('anon', 'validate.register_format(text, regprocedure, text)', 'execute')
              and not has_function_privilege('anon', 'validate.unregister_format(text)', 'execute'),
              'anon cannot execute register_format or unregister_format');
select tap.ok(not has_table_privilege('anon', 'validate.formats', 'insert, update, delete, truncate, references, trigger'),
              'anon cannot write the registry');
select tap.ok(not has_function_privilege('anon', 'validate.register_schema(text, jsonb, text)', 'execute')
              and not has_function_privilege('anon', 'validate.unregister_schema(text)', 'execute'),
              'anon cannot execute register_schema or unregister_schema');
select tap.ok(not has_table_privilege('anon', 'validate.schemas', 'insert, update, delete, truncate, references, trigger')
              and has_table_privilege('anon', 'validate.schemas', 'select'),
              'anon can read but not write the schema registry');
select tap.ok(has_schema_privilege('anon', 'validate', 'usage') and not has_schema_privilege('anon', 'validate', 'create'),
              'PUBLIC has USAGE but not CREATE on schema validate');

set role authenticated;
select tap.is(validate.email('ada@example.com'), true, 'authenticated can call a validator');
select tap.is(validate.format('iban', 'GB82WEST12345698765432'), true, 'authenticated can call format()');
select tap.throws_ok($$ select validate.register_format('mine', 'validate.slug(text)') $$, '42501', 'authenticated cannot register');
select tap.throws_ok($$ delete from validate.formats $$, '42501', 'authenticated cannot delete from the registry');
reset role;
select validate.register_schema(name => 'sec-check', schema => '{"type": "object"}');
set role authenticated;
select tap.is(validate.json_schema_named('{}', 'sec-check'), true, 'authenticated can validate against a named schema');
select tap.throws_ok($$ select validate.register_schema('mine', '{}') $$, '42501', 'authenticated cannot register a schema');
reset role;

set role anon;
select tap.throws_ok($$ select validate.unregister_format('email') $$, '42501', 'anon cannot unregister');
select tap.throws_ok($$ create function validate.evil(text) returns boolean language sql as 'select true' $$, '42501',
                     'anon cannot create functions in schema validate');
reset role;

select * from tap.finish();
