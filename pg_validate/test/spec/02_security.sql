-- Goal: clients (anon, authenticated) can call every validator, format()
-- and list_formats(), and read the registry, but cannot register,
-- unregister or write the registry table. Checked through the catalog and by
-- calling as the client roles.
select tap.plan(10);

select tap.is(
    (select string_agg(p.oid::regprocedure::text, ', ')
     from pg_proc p
     where p.pronamespace = 'validate'::regnamespace
       and p.proname not in ('register_format', 'unregister_format', '_formats_guard')
       and not has_function_privilege('authenticated', p.oid, 'execute')),
    null, 'authenticated can execute every validator and helper');
select tap.ok(not has_function_privilege('anon', 'validate.register_format(text, regprocedure, text)', 'execute')
              and not has_function_privilege('anon', 'validate.unregister_format(text)', 'execute'),
              'anon cannot execute register_format or unregister_format');
select tap.ok(not has_table_privilege('anon', 'validate.formats', 'insert, update, delete, truncate, references, trigger'),
              'anon cannot write the registry');
select tap.ok(has_schema_privilege('anon', 'validate', 'usage') and not has_schema_privilege('anon', 'validate', 'create'),
              'PUBLIC has USAGE but not CREATE on schema validate');

set role authenticated;
select tap.is(validate.email('ada@example.com'), true, 'authenticated can call a validator');
select tap.is(validate.format('iban', 'GB82WEST12345698765432'), true, 'authenticated can call format()');
select tap.throws_ok($$ select validate.register_format('mine', 'validate.slug(text)') $$, '42501', 'authenticated cannot register');
select tap.throws_ok($$ delete from validate.formats $$, '42501', 'authenticated cannot delete from the registry');
reset role;

set role anon;
select tap.throws_ok($$ select validate.unregister_format('email') $$, '42501', 'anon cannot unregister');
select tap.throws_ok($$ create function validate.evil(text) returns boolean language sql as 'select true' $$, '42501',
                     'anon cannot create functions in schema validate');
reset role;

select * from tap.finish();
