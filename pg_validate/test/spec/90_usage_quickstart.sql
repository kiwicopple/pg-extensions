-- Goal: docs/get-started/quickstart.md runs as written. Each block of the
-- page appears here in order, with an assertion for its documented result.
-- Keep the two in step.
select tap.plan(13);

-- 1. Check a value
select tap.is(validate.email(value => 'ada@example.com'), true, 'quickstart 1: email is valid');
select tap.is(validate.email(value => 'ada@example'), true, 'quickstart 1: single-label domain is valid syntax');
select tap.is(validate.email(value => 'ada@@example.com'), false, 'quickstart 1: double @ is invalid');
select tap.is(validate.semver(value => '1.4.0-rc.1'), true, 'quickstart 1: semver');

-- 2. Add CHECK constraints
select tap.lives_ok($$
create table customers (
  id bigint generated always as identity primary key,
  email text not null
    constraint customers_email_is_valid
    check (validate.email(email)),
  website text
    constraint customers_website_is_valid
    check (validate.url(website)),
  country text
    constraint customers_country_is_valid
    check (validate.country_code(country)),
  iban text
    constraint customers_iban_is_valid
    check (validate.iban(iban))
);
$$, 'quickstart 2: create the table');

select tap.lives_ok($$
insert into customers (email, website, country, iban)
values (
  'ada@example.com',
  'https://example.com',
  'GB',
  'GB82WEST12345698765432'
);
$$, 'quickstart 2: a valid row inserts');

select tap.lives_ok($$
insert into customers (email)
values ('grace@example.com');
$$, 'quickstart 2: nulls pass the checks');

-- 3. See a rejected row
select tap.throws_ok($$
insert into customers (email, country)
values ('alan@example.com', 'UK');
$$, '23514', 'quickstart 3: UK is rejected with check_violation');

create function pg_temp.constraint_name(sql text) returns text language plpgsql as $$
declare c text;
begin
    execute sql;
    return null;
exception when check_violation then
    get stacked diagnostics c = constraint_name;
    return c;
end $$;
select tap.is(
    pg_temp.constraint_name($$ insert into customers (email, country) values ('alan@example.com', 'UK') $$),
    'customers_country_is_valid', 'quickstart 3: the error names the constraint');

-- 4. Look up a format by name
select tap.is(validate.format(
  name => 'iban',
  value => 'GB82WEST12345698765432'
), true, 'quickstart 4: format(iban)');

-- 5. Register a custom format
create function public.order_number(value text)
returns boolean
language sql
immutable
as $$
  select value ~ '^ORD-[0-9]{8}$'
$$;

select tap.lives_ok($$
select validate.register_format(
  name => 'order-number',
  validator => 'public.order_number(text)',
  description => 'Order numbers such as ORD-00012345'
);
$$, 'quickstart 5: register order-number');

select tap.is(validate.format(
  name => 'order-number',
  value => 'ORD-00012345'
), true, 'quickstart 5: format(order-number)');

select tap.is(
    (select array_agg(row(name, builtin, validator::text)::text)
     from validate.list_formats()
     where not builtin),
    array[row('order-number', false, 'order_number(text)')::text],
    'quickstart 5: list_formats shows the custom format');

select * from tap.finish();
