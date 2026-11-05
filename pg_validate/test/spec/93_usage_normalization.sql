-- Goal: the examples and the table of docs/guides/normalization.md run as
-- written and give their documented results. Keep them in step.
select tap.plan(77);

-- Accepted forms and how to normalize them: for each row of the table, the
-- canonical form passes, the rejected variants fail, and the normalization
-- expression turns each variant into a passing value.
select tap.is(validate.country_code('US'), true, 'table: country_code US');
select tap.is(validate.country_code('us'), false, 'table: country_code us rejected');
select tap.is(validate.country_code('Us'), false, 'table: country_code Us rejected');
select tap.is(validate.country_code(' US'), false, 'table: country_code leading space rejected');
select tap.is(validate.country_code('US '), false, 'table: country_code trailing space rejected');
select tap.is(validate.country_code(upper(btrim(' us '))), true, 'table: country_code normalized');
select tap.is(validate.country_code_alpha3(upper(btrim(' usa '))), true, 'table: country_code_alpha3 normalized');
select tap.is(validate.country_code_alpha3('USA'), true, 'table: country_code_alpha3 USA');
select tap.is(validate.currency_code('EUR'), true, 'table: currency_code EUR');
select tap.is(validate.currency_code('eur'), false, 'table: currency_code eur rejected');
select tap.is(validate.currency_code(upper(btrim('eur '))), true, 'table: currency_code normalized');

select tap.is(validate.language_code('en'), true, 'table: language_code en');
select tap.is(validate.language_code('EN'), false, 'table: language_code EN rejected');
select tap.is(validate.language_code('En'), false, 'table: language_code En rejected');
select tap.is(validate.language_code(' en'), false, 'table: language_code leading space rejected');
select tap.is(validate.language_code(lower(btrim(' EN'))), true, 'table: language_code normalized');

select tap.is(validate.iban('DE89370400440532013000'), true, 'table: iban canonical');
select tap.is(validate.iban('de89370400440532013000'), false, 'table: iban lowercase rejected');
select tap.is(validate.iban('DE89 3704 0044 0532 0130 00'), false, 'table: iban print format rejected');
select tap.is(
    validate.iban(upper(regexp_replace('de89 3704 0044 0532 0130 00', '\s', '', 'g'))),
    true, 'table: iban normalized');

select tap.is(validate.isbn('0306406152'), true, 'table: isbn10 canonical');
select tap.is(validate.isbn('9780306406157'), true, 'table: isbn13 canonical');
select tap.is(validate.isbn('978-0-306-40615-7'), false, 'table: isbn hyphens rejected');
select tap.is(validate.isbn('0 306 40615 2'), false, 'table: isbn spaces rejected');
select tap.is(validate.isbn('080442957x'), false, 'table: isbn lowercase x rejected');
select tap.is(validate.isbn10('080442957X'), true, 'table: isbn10 uppercase X');
select tap.is(
    validate.isbn(upper(regexp_replace('978-0-306-40615-7', '[\s-]', '', 'g'))),
    true, 'table: isbn13 normalized');
select tap.is(
    validate.isbn(upper(regexp_replace('0 306 40615 2', '[\s-]', '', 'g'))),
    true, 'table: isbn10 normalized');
select tap.is(
    validate.isbn10(upper(regexp_replace('080442957x', '[\s-]', '', 'g'))),
    true, 'table: isbn10 x normalized');

select tap.is(validate.card_number('4111111111111111'), true, 'table: card_number canonical');
select tap.is(validate.card_number('4111 1111 1111 1111'), false, 'table: card_number spaces rejected');
select tap.is(validate.card_number('4111-1111-1111-1111'), false, 'table: card_number hyphens rejected');
select tap.is(
    validate.card_number(regexp_replace('4111 1111 1111 1111', '[\s-]', '', 'g')),
    true, 'table: card_number normalized (spaces)');
select tap.is(
    validate.card_number(regexp_replace('4111-1111-1111-1111', '[\s-]', '', 'g')),
    true, 'table: card_number normalized (hyphens)');
select tap.is(validate.luhn(regexp_replace('4111 1111 1111 1111', '[\s-]', '', 'g')), true, 'table: luhn normalized');

select tap.is(validate.e164('+14155552671'), true, 'table: e164 canonical');
select tap.is(validate.e164('+1 415 555 2671'), false, 'table: e164 spaces rejected');
select tap.is(validate.e164('+1 (415) 555-2671'), false, 'table: e164 punctuation rejected');
select tap.is(validate.e164('+1-415-555-2671'), false, 'table: e164 hyphens rejected');
select tap.is(validate.e164('14155552671'), false, 'table: e164 without plus rejected');
select tap.is(validate.e164(regexp_replace('+1 415 555 2671', '[\s().-]', '', 'g')), true, 'table: e164 normalized (spaces)');
select tap.is(validate.e164(regexp_replace('+1 (415) 555-2671', '[\s().-]', '', 'g')), true, 'table: e164 normalized (punctuation)');
select tap.is(validate.e164(regexp_replace('+1-415-555-2671', '[\s().-]', '', 'g')), true, 'table: e164 normalized (hyphens)');
select tap.is(validate.e164(regexp_replace('(415) 555-2671', '[\s().-]', '', 'g')), false, 'table: e164 normalization cannot supply the country code');

select tap.is(validate.email('Ada@Example.com'), true, 'table: email keeps case');
select tap.is(validate.email('ada@example.com'), true, 'table: email lowercase');
select tap.is(validate.email(' ada@example.com'), false, 'table: email leading space rejected');
select tap.is(validate.email('ada@example.com '), false, 'table: email trailing space rejected');
select tap.is(validate.email(btrim(' ada@example.com ')), true, 'table: email normalized');

select tap.is(validate.uuid('017F22E2-79B0-7CC3-98C4-DC0C0C07398F'), true, 'table: uuid uppercase accepted');
select tap.is(validate.uuid('017f22e2-79b0-7cc3-98c4-dc0c0c07398f'), true, 'table: uuid lowercase accepted');
select tap.is(validate.uuid('{017f22e2-79b0-7cc3-98c4-dc0c0c07398f}'), false, 'table: uuid braces rejected');
select tap.is(validate.uuid('017f22e279b07cc398c4dc0c0c07398f'), false, 'table: uuid without hyphens rejected');
select tap.is(validate.uuid(' 017f22e2-79b0-7cc3-98c4-dc0c0c07398f'), false, 'table: uuid leading space rejected');
select tap.is(validate.uuid(lower(btrim(' 017F22E2-79B0-7CC3-98C4-DC0C0C07398F '))), true, 'table: uuid normalized');

select tap.is(validate.hex('0AFF'), true, 'table: hex uppercase accepted');
select tap.is(validate.hex('0aff'), true, 'table: hex lowercase accepted');
select tap.is(validate.hex('0a ff'), false, 'table: hex spaces rejected');
select tap.is(validate.hex('0x0aff'), false, 'table: hex prefix rejected');
select tap.is(validate.hex(lower(regexp_replace('0A FF', '\s', '', 'g'))), true, 'table: hex normalized');

select tap.is(validate.git_sha('e83c5163316f89bfbde7d9ab23ca2e25604af290'), true, 'table: git_sha lowercase');
select tap.is(validate.git_sha('E83C5163316F89BFBDE7D9AB23CA2E25604AF290'), false, 'table: git_sha uppercase rejected');
select tap.is(validate.git_sha(lower(btrim(' E83C5163316F89BFBDE7D9AB23CA2E25604AF290'))), true, 'table: git_sha normalized');

select tap.is(validate.ulid('01arz3ndektsv4rrffq69g5fav'), true, 'notes: ulid accepts lowercase');
select tap.is(validate.mac('00:1A:2b:3c:4d:5E'), true, 'notes: mac accepts either case');

-- Pattern 1: validate a normalized expression
select tap.is(validate.iban(
  value => upper(regexp_replace(
    'de89 3704 0044 0532 0130 00', '\s', '', 'g'))
), true, 'pattern 1: normalized expression passes');
select tap.is(validate.iban(value => 'de89 3704 0044 0532 0130 00'), false, 'pattern 1: raw value fails');

create table imported_payees (id int, iban text);
insert into imported_payees values
  (1, 'de89 3704 0044 0532 0130 00'),
  (2, 'DE89370400440532013000'),
  (3, 'not an iban');
select tap.is((
select array_agg(id)
from imported_payees
where not validate.iban(iban)
  and validate.iban(
    upper(regexp_replace(iban, '\s', '', 'g'))
  )
), array[1], 'pattern 1: finds rows that pass after normalization');

-- Pattern 2: trigger and strict check
create table payees (
  id bigint generated always as identity primary key,
  name text not null,
  country text
    constraint payees_country_is_valid
    check (validate.country_code(country)),
  iban text
    constraint payees_iban_is_valid
    check (validate.iban(iban))
);

select tap.throws_ok($$
insert into payees (name, country, iban)
values ('Ada', ' de', 'de89 3704 0044 0532 0130 00');
$$, '23514', 'pattern 2: raw input fails the strict check');

create function public.normalize_payee()
returns trigger
language plpgsql
as $$
begin
  new.country := upper(btrim(new.country));
  new.iban := upper(regexp_replace(new.iban, '\s', '', 'g'));
  return new;
end;
$$;

create trigger payees_normalize
before insert or update on payees
for each row execute function public.normalize_payee();

select tap.lives_ok($$
insert into payees (name, country, iban)
values ('Ada', ' de', 'de89 3704 0044 0532 0130 00')
returning country, iban;
$$, 'pattern 2: the raw input inserts with the trigger');

select tap.is(
  (select row(country, iban)::text from payees),
  '(DE,DE89370400440532013000)',
  'pattern 2: the trigger stores the canonical form');

select tap.throws_ok($$
insert into payees (name, country, iban)
values ('Bob', 'de', 'de89 3704 0044 0532 0130 01');
$$, '23514', 'pattern 2: a wrong value still fails after normalization');

-- Pattern 3: domain with normalization at insert time
create domain iban_code as text
  check (validate.iban(value));

create function public.normalize_iban(value text)
returns text
language sql
immutable
strict
as $$
  select upper(regexp_replace(value, '\s', '', 'g'))
$$;

create table accounts (
  id bigint generated always as identity primary key,
  iban iban_code not null
);

select tap.lives_ok($$
insert into accounts (iban)
values (public.normalize_iban('de89 3704 0044 0532 0130 00'));
$$, 'pattern 3: a normalized value inserts');

select tap.throws_ok($$
insert into accounts (iban)
values ('de89 3704 0044 0532 0130 00');
$$, '23514', 'pattern 3: a raw value fails the domain');

-- Generated column
create table payouts (
  id bigint generated always as identity primary key,
  iban_raw text not null,
  iban text generated always as (
    upper(regexp_replace(iban_raw, '\s', '', 'g'))
  ) stored
    constraint payouts_iban_is_valid
    check (validate.iban(iban))
);

select tap.lives_ok($$
insert into payouts (iban_raw)
values ('de89 3704 0044 0532 0130 00')
returning iban;
$$, 'generated column: the raw input inserts');

select tap.is(
  (select iban from payouts),
  'DE89370400440532013000',
  'generated column: holds the normalized form');

select tap.throws_ok($$
insert into payouts (iban_raw) values ('nope');
$$, '23514', 'generated column: an invalid value still fails');

select * from tap.finish();
