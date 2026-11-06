-- Goal: the registry's security model. PUBLIC can read the registry and call
-- format(), but cannot register or unregister. A role granted EXECUTE on the
-- two functions plus INSERT and DELETE on validate.formats can, and owns its
-- entries: another such role cannot remove them, through the API or by direct
-- DML, unless it has the owner's privileges. format() is SECURITY INVOKER: a
-- validator that reads a table the caller cannot read fails for that caller.
-- Roles are cluster-wide: drop leftovers from an earlier run that died halfway.
drop role if exists app_admin2, app_admin, app_user;
create role app_admin nologin;
create role app_admin2 nologin;
create role app_user nologin;

grant execute on function
    validate.register_format(text, regprocedure, text),
    validate.unregister_format(text)
to app_admin, app_admin2;
grant insert, delete on validate.formats to app_admin, app_admin2;

create schema app;
grant usage on schema app to public;
create function app.v1(value text) returns boolean language sql immutable as $$ select value = 'ok' $$;
create function app.private_v(value text) returns boolean language sql immutable as $$ select true $$;
revoke execute on function app.private_v(text) from public;

-- A validator that reads a table only the superuser can read
create table app.secret (x text);
insert into app.secret values ('a');
revoke all on app.secret from public;
create function app.in_secret(value text)
returns boolean
language sql stable
as $$ select exists (select 1 from app.secret where x = value) $$;
select validate.register_format(name => 'secret-member', validator => 'app.in_secret(text)');

select tap.plan(23);

-- privileges as the catalog sees them
select tap.ok(not has_function_privilege('app_user', 'validate.register_format(text, regprocedure, text)', 'execute'),
              'PUBLIC cannot execute register_format');
select tap.ok(not has_function_privilege('authenticated', 'validate.unregister_format(text)', 'execute'),
              'PUBLIC cannot execute unregister_format');
select tap.ok(not has_table_privilege('authenticated', 'validate.formats', 'insert, update, delete, truncate'),
              'PUBLIC cannot write the registry table');
select tap.ok(has_table_privilege('authenticated', 'validate.formats', 'select'),
              'PUBLIC can read the registry table');

-- unprivileged roles
set role app_user;
select tap.throws_ok($$ select validate.register_format(name => 'v1', validator => 'app.v1(text)') $$,
                     '42501', 'an unprivileged role cannot register');
select tap.throws_ok($$ insert into validate.formats (name, validator_schema, validator_name) values ('v1', 'app', 'v1') $$,
                     '42501', 'an unprivileged role cannot insert into the registry');
select tap.throws_ok($$ select validate.unregister_format(name => 'secret-member') $$,
                     '42501', 'an unprivileged role cannot unregister');
select tap.is(validate.format(name => 'email', value => 'a@example.com'), true, 'an unprivileged role can call format()');
select tap.is((select count(*)::int from validate.list_formats()), 55, 'an unprivileged role can list formats');
reset role;

-- a granted role registers and owns its entry
set role app_admin;
select tap.lives_ok($$ select validate.register_format(name => 'v1', validator => 'app.v1(text)') $$,
                    'a granted role can register');
select tap.throws_ok($$ select validate.register_format(name => 'v2', validator => 'app.private_v(text)') $$,
                     '42501', 'it cannot register a function it cannot execute');
select tap.throws_ok($$ update validate.formats set description = 'x' where name = 'v1' $$,
                     '42501', 'it cannot update the registry directly (no UPDATE privilege)');
reset role;
select tap.is((select l.owner::text from validate.list_formats() l where l.name = 'v1'), 'app_admin',
              'the entry belongs to the registering role');

set role app_admin2;
select tap.throws_ok($$ select validate.unregister_format(name => 'v1') $$,
                     '42501', 'another granted role cannot unregister it');
select tap.throws_ok($$ delete from validate.formats where name = 'v1' $$,
                     '42501', 'nor delete it directly');
select tap.throws_ok($$ insert into validate.formats (name, validator_schema, validator_name, owner) values ('v3', 'app', 'v1', 'app_admin') $$,
                     '42501', 'nor insert an entry on behalf of another role');
reset role;

grant app_admin to app_admin2;
set role app_admin2;
select tap.lives_ok($$ select validate.unregister_format(name => 'v1') $$,
                    'a role with the owner''s privileges can unregister it');
reset role;

set role app_admin;
select validate.register_format(name => 'v1', validator => 'app.v1(text)');
select tap.lives_ok($$ select validate.unregister_format(name => 'v1') $$, 'the owner can unregister its own entry');
select validate.register_format(name => 'v1', validator => 'app.v1(text)');
reset role;
select tap.lives_ok($$ select validate.unregister_format(name => 'v1') $$,
                    'the extension owner (here a superuser) can unregister any custom entry');

-- SECURITY INVOKER dispatch
select tap.is(validate.format(name => 'secret-member', value => 'a'), true,
              'the superuser can use a validator that reads app.secret');
set role authenticated;
select tap.throws_ok($$ select validate.format(name => 'secret-member', value => 'a') $$,
                     '42501', 'a client cannot: the validator runs with the caller''s privileges');
reset role;
select tap.ok(not (select prosecdef from pg_proc where oid = 'validate.format(text, text)'::regprocedure),
              'format() is SECURITY INVOKER');
select tap.ok(not (select prosecdef from pg_proc where oid = 'validate.register_format(text, regprocedure, text)'::regprocedure),
              'register_format() is SECURITY INVOKER');

select * from tap.finish();

drop owned by app_admin, app_admin2, app_user;
drop role app_admin2, app_admin, app_user;
