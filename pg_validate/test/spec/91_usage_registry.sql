-- Goal: the examples in docs/registry.md and docs/guides/constraints.md run
-- as written and give their documented results. Keep them in step.
drop role if exists app_admin2, app_admin;
create role app_admin nologin;
create role app_admin2 nologin;

select tap.plan(16);

-- docs/registry.md: Write a validator
select tap.lives_ok($$
create function public.uuid_v7(value text)
returns boolean
language sql
immutable
strict
parallel safe
as $f$
  select validate.uuid(value, 7)
$f$;
$$, 'registry: uuid_v7');
select tap.lives_ok($$
create function public.work_email(value text)
returns boolean
language sql
immutable
strict
parallel safe
as $f$
  select validate.email(value)
    and split_part(lower(value), '@', 2)
        not in ('gmail.com', 'outlook.com', 'yahoo.com')
$f$;
$$, 'registry: work_email');
select tap.ok(public.work_email('ada@example.com') and not public.work_email('ada@gmail.com'),
              'registry: work_email rejects free mail domains');

-- Register, use and remove a format
select tap.lives_ok($$
select validate.register_format(
  name => 'uuid-v7',
  validator => 'public.uuid_v7(text)',
  description => 'RFC 9562 version 7 UUID'
);
$$, 'registry: register uuid-v7');
select tap.is(validate.format(
  name => 'uuid-v7',
  value => '017f22e2-79b0-7cc3-98c4-dc0c0c07398f'
), true, 'registry: format(uuid-v7)');
select tap.lives_ok($$ select validate.unregister_format(name => 'uuid-v7'); $$, 'registry: unregister uuid-v7');

-- Allow a role to register formats
select tap.lives_ok($$
grant execute on function
  validate.register_format(text, regprocedure, text),
  validate.unregister_format(text)
to app_admin;

grant insert, delete
on validate.formats
to app_admin;
$$, 'registry: grant registration to app_admin');
set role app_admin;
select tap.lives_ok($$ select validate.register_format(name => 'work-email', validator => 'public.work_email(text)') $$,
                    'registry: app_admin can register');
reset role;
select tap.lives_ok($$ grant app_admin to app_admin2; $$, 'registry: grant membership');
set role app_admin2;
select tap.lives_ok($$ select validate.unregister_format(name => 'work-email') $$,
                    'registry: a member of app_admin can remove app_admin''s format');
reset role;

-- docs/guides/constraints.md
create table customers (
  id bigint generated always as identity primary key,
  email text not null check (validate.email(email)),
  website text,
  country text check (validate.country_code(country)),
  iban text check (validate.iban(iban))
);
insert into customers (email, website) values ('ada@example.com', 'not a url');

select tap.lives_ok($$
create domain email_address as text
  check (validate.email(value));

create domain country_code as text
  check (validate.country_code(value));

create table suppliers (
  id bigint generated always as identity primary key,
  contact email_address not null,
  country country_code
);
$$, 'constraints: domains');
select tap.throws_ok($$ select 'nope'::email_address $$, '23514', 'constraints: a cast to the domain fails');

select tap.lives_ok($$
alter table customers
  add constraint customers_website_is_url
  check (validate.url(website))
  not valid;
$$, 'constraints: add a constraint not valid over bad data');
select tap.throws_ok($$ alter table customers validate constraint customers_website_is_url $$, '23514',
                     'constraints: validate fails while a bad row remains');
update customers set website = 'https://example.com' where not validate.url(website);
select tap.lives_ok($$ alter table customers validate constraint customers_website_is_url $$,
                    'constraints: validate succeeds after the fix');

select tap.lives_ok($$
create function public.normalize_customer()
returns trigger
language plpgsql
as $f$
begin
  new.country := upper(new.country);
  new.iban := replace(upper(new.iban), ' ', '');
  return new;
end;
$f$;

create trigger customers_normalize
before insert or update on customers
for each row execute function public.normalize_customer();

insert into customers (email, country, iban)
values ('grace@example.com', 'gb', 'gb82 west 1234 5698 7654 32');
$$, 'constraints: normalize, then validate');

select * from tap.finish();

drop owned by app_admin, app_admin2;
drop role app_admin2, app_admin;
