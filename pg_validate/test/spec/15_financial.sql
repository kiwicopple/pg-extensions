-- Goal: financial identifiers: iban (registry lengths, check digits 02-98,
-- MOD 97-10; examples from the SWIFT IBAN registry), isbn / isbn10 / isbn13
-- (ISO 2108 check digits, 978/979 prefix, ISMN excluded), luhn and
-- card_number (published test card numbers).
\ir ../fixtures/cases.sql

insert into cases (fn, input, want, note) values
    -- SWIFT IBAN registry examples
    ('iban', 'GB82WEST12345698765432', true, 'GB'),
    ('iban', 'GB33BUKB20201555555555', true, 'GB'),
    ('iban', 'DE89370400440532013000', true, 'DE'),
    ('iban', 'FR1420041010050500013M02606', true, 'FR'),
    ('iban', 'NL91ABNA0417164300', true, 'NL'),
    ('iban', 'BE68539007547034', true, 'BE, 16 characters'),
    ('iban', 'NO9386011117947', true, 'NO, 15 characters (shortest)'),
    ('iban', 'CH9300762011623852957', true, 'CH'),
    ('iban', 'IT60X0542811101000000123456', true, 'IT'),
    ('iban', 'ES9121000418450200051332', true, 'ES'),
    ('iban', 'MT84MALT011000012345MTLCAST001S', true, 'MT, 31 characters'),
    ('iban', 'LC55HEMM000100010012001200023015', true, 'LC, 32 characters'),
    ('iban', 'RU0204452560040702810412345678901', true, 'RU, 33 characters (longest)'),
    ('iban', 'BR1800360305000010009795493C1', true, 'BR'),
    ('iban', 'SC18SSCB11010000000000001497USD', true, 'SC'),
    ('iban', 'XK051212012345678906', true, 'XK'),
    ('iban', 'YE15CBYE0001018861234567891234', true, 'YE'),
    ('iban', 'GB02WEST12345698760082', true, 'check digits 02'),
    ('iban', 'GB99WEST12345698760082', false, 'check digits 99 pass MOD 97 but are not allowed'),
    ('iban', 'GB82WEST12345698765433', false, 'wrong check'),
    ('iban', 'GB82WEST1234569876543', false, 'wrong length for GB'),
    ('iban', 'DE89370400440532013000X', false, 'wrong length for DE'),
    ('iban', 'gb82west12345698765432', false, 'lowercase'),
    ('iban', 'GB82 WEST 1234 5698 7654 32', false, 'print format with spaces'),
    ('iban', 'US64SVBKUS6S3300958879', false, 'country without IBAN'),
    ('iban', 'GB00WEST12345698765432', false, 'check digits 00'),
    ('iban', '', false, null),

    ('isbn', '0306406152', true, 'ISBN-10'),
    ('isbn', '080442957X', true, 'ISBN-10 with X'),
    ('isbn', '0198526636', true, 'ISBN-10'),
    ('isbn', '9780306406157', true, 'ISBN-13'),
    ('isbn', '9781861972712', true, 'ISBN-13'),
    ('isbn', '9791032305690', true, 'ISBN-13, 979-10'),
    ('isbn', '0306406153', false, 'wrong check'),
    ('isbn', '080442957x', false, 'lowercase x'),
    ('isbn', 'X306406152', false, 'X not last'),
    ('isbn', '9780306406158', false, 'wrong check'),
    ('isbn', '9790123456785', false, 'ISMN (979-0) with a valid EAN check'),
    ('isbn', '1234567890128', false, 'EAN-13 that is not Bookland'),
    ('isbn', '978-0-306-40615-7', false, 'hyphens'),
    ('isbn', '97803064061', false, '11 digits'),
    ('isbn10', '0306406152', true, null),
    ('isbn10', '9780306406157', false, 'ISBN-13'),
    ('isbn13', '9780306406157', true, null),
    ('isbn13', '0306406152', false, 'ISBN-10'),

    ('luhn', '79927398713', true, 'Wikipedia example'),
    ('luhn', '4111111111111111', true, null),
    ('luhn', '0000000000', true, null),
    ('luhn', '79927398710', false, 'wrong check digit'),
    ('luhn', '7992739871a', false, null),
    ('luhn', '7', false, 'one digit'),
    ('luhn', '', false, null),

    -- Published test card numbers
    ('card_number', '4111111111111111', true, 'Visa test'),
    ('card_number', '4012888888881881', true, 'Visa test'),
    ('card_number', '4222222222222', true, 'Visa test, 13 digits'),
    ('card_number', '5555555555554444', true, 'Mastercard test'),
    ('card_number', '378282246310005', true, 'Amex test, 15 digits'),
    ('card_number', '6011111111111117', true, 'Discover test'),
    ('card_number', '30569309025904', true, 'Diners test, 14 digits'),
    ('card_number', '4111111111111112', false, 'wrong check digit'),
    ('card_number', '4111 1111 1111 1111', false, 'spaces'),
    ('card_number', '4111-1111-1111-1111', false, 'hyphens'),
    ('card_number', '79927398713', false, 'valid Luhn, 11 digits'),
    ('card_number', '41111111111111111113', false, '20 digits');

select tap.plan((select count(*)::int from cases));
\ir ../fixtures/run_cases.sql

select * from tap.finish();
