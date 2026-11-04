-- Goal: e164 checks the international number structure; country_code,
-- country_code_alpha3, currency_code and language_code accept exactly the
-- embedded ISO snapshots (249, 249, 178 and 183 codes, data/README.md) in
-- their canonical case.
\ir ../fixtures/cases.sql

insert into cases (fn, input, want, note) values
    ('e164', '+14155552671', true, null),
    ('e164', '+442071838750', true, null),
    ('e164', '+819012345678', true, null),
    ('e164', '+123456789012345', true, '15 digits'),
    ('e164', '+1234567890123456', false, '16 digits'),
    ('e164', '14155552671', false, 'no +'),
    ('e164', '+0123456789', false, 'country code starts with 0'),
    ('e164', '+1 415 555 2671', false, 'spaces'),
    ('e164', '+1-415-555-2671', false, 'hyphens'),
    ('e164', '+', false, null),
    ('e164', '++14155552671', false, null),
    ('e164', '+1', false, 'one digit'),

    ('country_code', 'US', true, null),
    ('country_code', 'GB', true, null),
    ('country_code', 'NZ', true, null),
    ('country_code', 'AX', true, 'Åland Islands'),
    ('country_code', 'BQ', true, null),
    ('country_code', 'SS', true, 'South Sudan'),
    ('country_code', 'TR', true, null),
    ('country_code', 'us', false, 'lowercase'),
    ('country_code', 'UK', false, 'exceptionally reserved'),
    ('country_code', 'EU', false, 'exceptionally reserved'),
    ('country_code', 'XK', false, 'user-assigned (Kosovo)'),
    ('country_code', 'AN', false, 'withdrawn (Netherlands Antilles)'),
    ('country_code', 'YU', false, 'withdrawn'),
    ('country_code', 'ZZ', false, 'user-assigned'),
    ('country_code', 'USA', false, 'alpha-3'),
    ('country_code', 'U', false, null),
    ('country_code', 'U S', false, null),

    ('country_code_alpha3', 'USA', true, null),
    ('country_code_alpha3', 'GBR', true, null),
    ('country_code_alpha3', 'ALA', true, null),
    ('country_code_alpha3', 'TUR', true, null),
    ('country_code_alpha3', 'usa', false, 'lowercase'),
    ('country_code_alpha3', 'US', false, 'alpha-2'),
    ('country_code_alpha3', 'XKX', false, 'user-assigned'),
    ('country_code_alpha3', 'ANT', false, 'withdrawn'),
    ('country_code_alpha3', 'EUR', false, 'currency, not a country'),

    ('currency_code', 'USD', true, null),
    ('currency_code', 'EUR', true, null),
    ('currency_code', 'JPY', true, null),
    ('currency_code', 'XAU', true, 'gold'),
    ('currency_code', 'XTS', true, 'testing code'),
    ('currency_code', 'XCG', true, 'Caribbean guilder (2025)'),
    ('currency_code', 'SLE', true, 'Sierra Leone leone (2022), replaced SLL'),
    ('currency_code', 'XAD', true, 'Arab Accounting Dinar (Arab Monetary Fund), a fund code'),
    ('currency_code', 'XDR', true, 'IMF special drawing right'),
    ('currency_code', 'XXX', true, 'no currency'),
    ('currency_code', 'ZWG', true, null),
    ('currency_code', 'usd', false, 'lowercase'),
    ('currency_code', 'HRK', false, 'historic (Croatia adopted the euro)'),
    ('currency_code', 'CUC', false, 'historic'),
    ('currency_code', 'ZWL', false, 'historic'),
    ('currency_code', 'ANG', false, 'historic (replaced by XCG, withdrawn 2025-03)'),
    ('currency_code', 'BGN', false, 'historic (Bulgaria adopted the euro, withdrawn 2026-01)'),
    ('currency_code', 'SLL', false, 'historic (replaced by SLE, withdrawn 2023-12)'),
    ('currency_code', 'BTC', false, 'not ISO 4217'),
    ('currency_code', 'US', false, null),
    ('currency_code', 'USDT', false, null),

    ('language_code', 'en', true, null),
    ('language_code', 'fr', true, null),
    ('language_code', 'zh', true, null),
    ('language_code', 'he', true, null),
    ('language_code', 'yi', true, null),
    ('language_code', 'id', true, null),
    ('language_code', 'EN', false, 'uppercase'),
    ('language_code', 'eng', false, 'ISO 639-2/3'),
    ('language_code', 'bh', false, 'deprecated 2021'),
    ('language_code', 'iw', false, 'withdrawn (now he)'),
    ('language_code', 'in', false, 'withdrawn (now id)'),
    ('language_code', 'ji', false, 'withdrawn (now yi)'),
    ('language_code', 'en-US', false, 'BCP 47 tag'),
    ('language_code', 'xx', false, null);

select tap.plan((select count(*)::int from cases) + 4);
\ir ../fixtures/run_cases.sql

-- The size of each embedded list, by trying every candidate code.
select tap.is(
    (select count(*)::int from generate_series(65, 90) a, generate_series(65, 90) b
     where validate.country_code(chr(a) || chr(b))),
    249, 'country_code accepts exactly the 249 assigned alpha-2 codes');
select tap.is(
    (select count(*)::int from generate_series(65, 90) a, generate_series(65, 90) b, generate_series(65, 90) c
     where validate.country_code_alpha3(chr(a) || chr(b) || chr(c))),
    249, 'country_code_alpha3 accepts exactly the 249 assigned alpha-3 codes');
select tap.is(
    (select count(*)::int from generate_series(65, 90) a, generate_series(65, 90) b, generate_series(65, 90) c
     where validate.currency_code(chr(a) || chr(b) || chr(c))),
    178, 'currency_code accepts the 178 List One codes of the snapshot');
select tap.is(
    (select count(*)::int from generate_series(97, 122) a, generate_series(97, 122) b
     where validate.language_code(chr(a) || chr(b))),
    183, 'language_code accepts the 183 ISO 639-1 codes');

select * from tap.finish();
