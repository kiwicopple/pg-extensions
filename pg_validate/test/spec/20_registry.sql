-- Goal: the format registry: register, format, list, unregister; signature
-- and name checks at registration; built-ins can be neither replaced nor
-- removed (through the API or by direct DML); dispatch quotes identifiers and
-- passes the value as a parameter; a dropped validator gives a clear error.
-- Runs as the superuser; 21_registry_permissions covers other roles.
create schema app;
create function app.even_digits(value text)
returns boolean
language sql immutable
as $$ select value ~ '^([0-9][0-9])*$' $$;

create schema "My Schema";
create function "My Schema"."we""ird"(value text)
returns boolean
language sql stable
as $$ select value = 'odd' $$;

-- signatures register_format must refuse
create function app.two_args(a text, b text) returns boolean language sql immutable as $$ select true $$;
create function app.returns_text(value text) returns text language sql immutable as $$ select value $$;
create function app.returns_set(value text) returns setof boolean language sql immutable as $$ select true $$;
create function app.int_arg(value int) returns boolean language sql immutable as $$ select true $$;
create function app.varchar_arg(value varchar) returns boolean language sql immutable as $$ select true $$;
create function app.variadic_arg(variadic value text[]) returns boolean language sql immutable as $$ select true $$;
create function app.volatile_v(value text) returns boolean language sql volatile as $$ select true $$;
create procedure app.proc_v(value text) language sql as $$ select 1 $$;

select tap.plan(41);

-- register, use, list
select tap.lives_ok($$
    select validate.register_format(
      name => 'even-digits',
      validator => 'app.even_digits(text)',
      description => 'An even number of digits'
    )
$$, 'register a custom format');
select tap.is(validate.format(name => 'even-digits', value => '12'), true, 'format() calls the custom validator: valid');
select tap.is(validate.format(name => 'even-digits', value => '123'), false, 'format() calls the custom validator: invalid');
select tap.is(validate.format(name => 'even-digits', value => null), null, 'format() is strict: null value gives null');
select tap.is(
    (select row(l.builtin, l.validator, l.description, l.owner)::text from validate.list_formats() l where l.name = 'even-digits'),
    row(false, 'app.even_digits(text)'::regprocedure, 'An even number of digits', current_user::name)::text,
    'list_formats() shows the custom entry, its function, description and owner');
select tap.is(
    (select count(*)::int from validate.list_formats() l where l.builtin),
    54, 'list_formats() also lists the 54 built-in formats (44 validators, 10 JSON Schema aliases)');

-- built-ins dispatch through the same path
select tap.is(validate.format(name => 'email', value => 'joe@example.com'), true, 'format(email) calls validate.email');
select tap.is(validate.format(name => 'semver', value => '1.0.0-rc.1'), true, 'format(semver) calls validate.semver');
select tap.is(validate.format(name => 'uuid', value => 'not a uuid'), false, 'format(uuid) calls the one-argument validate.uuid');
select tap.is(
    (select count(*)::int from validate.list_formats() l
     where l.builtin and validate.format(l.name, '') is not null),
    54, 'every built-in format dispatches');

-- duplicates and built-ins
select tap.throws_ok($$ select validate.register_format(name => 'even-digits', validator => 'app.even_digits(text)') $$,
                     '42710', 'registering an existing name fails');
select tap.throws_ok($$ select validate.register_format(name => 'email', validator => 'app.even_digits(text)') $$,
                     '42710', 'a built-in format cannot be replaced');
select tap.throws_ok($$ select validate.unregister_format(name => 'email') $$,
                     '42501', 'a built-in format cannot be unregistered');
select tap.throws_ok($$ delete from validate.formats where name = 'email' $$,
                     '42501', 'a built-in row cannot be deleted directly, even by a superuser');
select tap.throws_ok($$ update validate.formats set validator_name = 'even_digits', validator_schema = 'app' where name = 'email' $$,
                     '42501', 'a built-in row cannot be updated directly');
select tap.throws_ok($$ insert into validate.formats (name, validator_schema, validator_name, builtin) values ('fake', 'app', 'even_digits', true) $$,
                     '42501', 'a row cannot be inserted as built-in');
select tap.throws_ok($$ truncate validate.formats $$,
                     '42501', 'the registry cannot be truncated');
select tap.is(validate.format(name => 'email', value => 'joe@example.com'), true, 'the built-in email format still works');

-- unknown names
select tap.throws_ok($$ select validate.format(name => 'no-such-format', value => 'x') $$,
                     '42704', 'format() with an unknown name fails');
select tap.throws_ok($$ select validate.unregister_format(name => 'no-such-format') $$,
                     '42704', 'unregistering an unknown name fails');

-- signature checks
select tap.throws_ok($$ select validate.register_format(name => 'f1', validator => 'app.two_args(text, text)') $$, '22023', 'two arguments are refused');
select tap.throws_ok($$ select validate.register_format(name => 'f2', validator => 'app.returns_text(text)') $$, '22023', 'a non-boolean result is refused');
select tap.throws_ok($$ select validate.register_format(name => 'f3', validator => 'app.returns_set(text)') $$, '22023', 'a set-returning function is refused');
select tap.throws_ok($$ select validate.register_format(name => 'f4', validator => 'app.int_arg(int)') $$, '22023', 'an int argument is refused');
select tap.throws_ok($$ select validate.register_format(name => 'f5', validator => 'app.varchar_arg(varchar)') $$, '22023', 'a varchar argument is refused');
select tap.throws_ok($$ select validate.register_format(name => 'f6', validator => 'app.variadic_arg(text[])') $$, '22023', 'a variadic function is refused');
select tap.throws_ok($$ select validate.register_format(name => 'f7', validator => 'app.volatile_v(text)') $$, '22023', 'a VOLATILE function is refused');
select tap.throws_ok($$ select validate.register_format(name => 'f8', validator => 'app.proc_v(text)') $$, '22023', 'a procedure is refused');
select tap.throws_ok($$ select validate.register_format(name => 'f9', validator => 'app.no_such(text)') $$, '42883', 'a missing function is refused');

-- names are data, never SQL
select tap.throws_ok($$ select validate.register_format(name => 'x''); drop table validate.formats; --', validator => 'app.even_digits(text)') $$,
                     '22023', 'a name with SQL in it is refused');
select tap.throws_ok($$ select validate.register_format(name => '1abc', validator => 'app.even_digits(text)') $$, '22023', 'a name must start with a letter');
select tap.throws_ok($$ select validate.register_format(name => 'a b', validator => 'app.even_digits(text)') $$, '22023', 'a name has no spaces');
select tap.throws_ok(format($$ select validate.register_format(name => %L, validator => 'app.even_digits(text)') $$, repeat('a', 64)),
                     '22023', 'a name has at most 63 characters');

-- identifiers that need quoting
select tap.lives_ok($$ select validate.register_format(name => 'weird', validator => '"My Schema"."we""ird"(text)') $$,
                    'a function whose schema and name need quoting registers');
select tap.ok(validate.format(name => 'weird', value => 'odd') and not validate.format(name => 'weird', value => 'even'),
              'and format() calls it');
select tap.is(validate.format(name => 'even-digits', value => $v$'); drop table validate.formats; --$v$), false,
              'a value with SQL in it is only a value');
select tap.ok(to_regclass('validate.formats') is not null, 'the registry table still exists');

-- a validator that was dropped
drop function app.even_digits(text);
select tap.throws_ok($$ select validate.format(name => 'even-digits', value => '12') $$,
                     '42883', 'format() reports a dropped validator');
select tap.is((select l.validator from validate.list_formats() l where l.name = 'even-digits'), null,
              'list_formats() shows a null validator for a dropped function');
select tap.lives_ok($$ select validate.unregister_format(name => 'even-digits') $$, 'a format whose function was dropped can be unregistered');
select tap.throws_ok($$ select validate.format(name => 'even-digits', value => '12') $$,
                     '42704', 'an unregistered format is unknown');

select * from tap.finish();
