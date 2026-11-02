-- Goal: validators work as CHECK constraints and domain constraints: valid
-- rows insert, invalid rows fail with 23514, null passes. A CHECK that calls
-- validate.format() works too, but changing the registry later does not
-- recheck existing rows (docs/registry.md).
create table users (
    id      int generated always as identity primary key,
    email   text not null check (validate.email(email)),
    website text check (validate.url(website)),
    country text check (validate.country_code(country)),
    joined  text check (validate.rfc3339(joined))
);

create domain email_address as text
    check (validate.email(value));

create schema app;
create function app.two_digits(value text) returns boolean language sql immutable as $$ select value ~ '^[0-9]{2}$' $$;
create function app.four_digits(value text) returns boolean language sql immutable as $$ select value ~ '^[0-9]{4}$' $$;
select validate.register_format(name => 'code', validator => 'app.two_digits(text)');

create table codes (
    code text check (validate.format('code', code))
);

select tap.plan(13);

select tap.lives_ok($$
    insert into users (email, website, country, joined)
    values ('ada@example.com', 'https://example.com/ada', 'GB', '2026-11-02T09:30:00Z')
$$, 'a valid row inserts');
select tap.lives_ok($$ insert into users (email) values ('bob@example.com') $$,
                    'null in an optional column passes the check');
select tap.throws_ok($$ insert into users (email) values ('not an email') $$, '23514', 'an invalid email fails');
select tap.throws_ok($$ insert into users (email, website) values ('c@example.com', 'ftp://example.com') $$, '23514', 'a non-http URL fails');
select tap.throws_ok($$ insert into users (email, country) values ('c@example.com', 'UK') $$, '23514', 'an unassigned country code fails');
select tap.throws_ok($$ insert into users (email, joined) values ('c@example.com', '2026-02-29T00:00:00Z') $$, '23514', 'a non-existent date fails');
select tap.throws_ok($$ update users set email = 'x' where email = 'ada@example.com' $$, '23514', 'an update to an invalid value fails');

select tap.is('ada@example.com'::email_address::text, 'ada@example.com', 'a domain over validate.email accepts a valid address');
select tap.throws_ok($$ select 'nope'::email_address $$, '23514', 'and rejects an invalid one');

select tap.lives_ok($$ insert into codes values ('12') $$, 'a CHECK over validate.format() accepts a valid value');
select tap.throws_ok($$ insert into codes values ('123') $$, '23514', 'and rejects an invalid one');

-- Swap the format's validator: existing rows are not rechecked.
select validate.unregister_format(name => 'code');
select validate.register_format(name => 'code', validator => 'app.four_digits(text)');
select tap.is((select count(*)::int from codes where code = '12'), 1,
              'after the format changes, the existing row is still there (not rechecked)');
select tap.throws_ok($$ insert into codes values ('12') $$, '23514', 'but new rows use the new validator');

select * from tap.finish();
