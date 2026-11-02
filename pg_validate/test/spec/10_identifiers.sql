-- Goal: identifier validators accept their specification's forms and reject
-- near misses: uuid (RFC 9562), ulid, nanoid, slug, semver (semver.org's own
-- valid and invalid lists), git_sha.
\ir ../fixtures/cases.sql

insert into cases (fn, input, want, note) values
    -- RFC 9562 string form; samples from Appendix A
    ('uuid', '919108f7-52d1-4320-9bac-f847db4148a8', true,  'RFC 9562 A.3 (v4)'),
    ('uuid', '017F22E2-79B0-7CC3-98C4-DC0C0C07398F', true,  'RFC 9562 A.6 (v7), uppercase'),
    ('uuid', 'C232AB00-9414-11EC-B3C8-9F6BDECED846', true,  'RFC 9562 A.1 (v1)'),
    ('uuid', '00000000-0000-0000-0000-000000000000', true,  'Nil UUID'),
    ('uuid', 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF', true,  'Max UUID'),
    ('uuid', '{919108f7-52d1-4320-9bac-f847db4148a8}', false, 'braces (the uuid type accepts them)'),
    ('uuid', '919108f752d143209bacf847db4148a8', false, 'no hyphens (the uuid type accepts it)'),
    ('uuid', '919108f7-52d1-4320-9bac-f847db4148a', false, 'one digit short'),
    ('uuid', '919108f7-52d1-4320-9bac-f847db4148a8 ', false, 'trailing space'),
    ('uuid', 'g19108f7-52d1-4320-9bac-f847db4148a8', false, 'non-hex digit'),
    ('uuid', '919108f-752d1-4320-9bac-f847db4148a8', false, 'wrong grouping'),
    ('uuid', '', false, null),

    -- ULID spec
    ('ulid', '01ARZ3NDEKTSV4RRFFQ69G5FAV', true,  'spec example'),
    ('ulid', '01arz3ndektsv4rrffq69g5fav', true,  'lowercase'),
    ('ulid', '7ZZZZZZZZZZZZZZZZZZZZZZZZZ', true,  'largest ULID'),
    ('ulid', '00000000000000000000000000', true,  null),
    ('ulid', '8ZZZZZZZZZZZZZZZZZZZZZZZZZ', false, 'overflows 128 bits'),
    ('ulid', '01ARZ3NDEKTSV4RRFFQ69G5FAI', false, 'I is not Crockford base32'),
    ('ulid', '01ARZ3NDEKTSV4RRFFQ69G5FAL', false, 'L is not Crockford base32'),
    ('ulid', '01ARZ3NDEKTSV4RRFFQ69G5FAO', false, 'O is not Crockford base32'),
    ('ulid', '01ARZ3NDEKTSV4RRFFQ69G5FAU', false, 'U is not Crockford base32'),
    ('ulid', '01ARZ3NDEKTSV4RRFFQ69G5FA', false, '25 characters'),
    ('ulid', '01ARZ3NDEKTSV4RRFFQ69G5FAVV', false, '27 characters'),

    -- Nano ID defaults
    ('nanoid', 'V1StGXR8_Z5jdHi6B-myT', true,  'README example'),
    ('nanoid', '_____________________', true,  null),
    ('nanoid', 'V1StGXR8_Z5jdHi6B-my', false, '20 characters'),
    ('nanoid', 'V1StGXR8_Z5jdHi6B-myTx', false, '22 characters'),
    ('nanoid', 'V1StGXR8_Z5jdHi6B+myT', false, '+ is not URL-safe'),

    ('slug', 'hello-world', true,  null),
    ('slug', 'a', true,  null),
    ('slug', '2026-roadmap', true,  null),
    ('slug', 'Hello-World', false, 'uppercase'),
    ('slug', 'hello--world', false, 'double hyphen'),
    ('slug', '-hello', false, 'leading hyphen'),
    ('slug', 'hello-', false, 'trailing hyphen'),
    ('slug', 'hello_world', false, 'underscore'),
    ('slug', 'héllo', false, 'non-ASCII'),
    ('slug', 'hello world', false, 'space'),
    ('slug', '', false, null),

    -- semver.org: "Is there a suggested regular expression" valid list
    ('semver', '0.0.4', true, null),
    ('semver', '1.2.3', true, null),
    ('semver', '10.20.30', true, null),
    ('semver', '1.1.2-prerelease+meta', true, null),
    ('semver', '1.1.2+meta', true, null),
    ('semver', '1.1.2+meta-valid', true, null),
    ('semver', '1.0.0-alpha', true, null),
    ('semver', '1.0.0-beta', true, null),
    ('semver', '1.0.0-alpha.beta', true, null),
    ('semver', '1.0.0-alpha.beta.1', true, null),
    ('semver', '1.0.0-alpha.1', true, null),
    ('semver', '1.0.0-alpha0.valid', true, null),
    ('semver', '1.0.0-alpha.0valid', true, null),
    ('semver', '1.0.0-alpha-a.b-c-somethinglong+build.1-aef.1-its-okay', true, null),
    ('semver', '1.0.0-rc.1+build.1', true, null),
    ('semver', '2.0.0-rc.1+build.123', true, null),
    ('semver', '1.2.3-beta', true, null),
    ('semver', '10.2.3-DEV-SNAPSHOT', true, null),
    ('semver', '1.2.3-SNAPSHOT-123', true, null),
    ('semver', '1.0.0', true, null),
    ('semver', '2.0.0', true, null),
    ('semver', '1.1.7', true, null),
    ('semver', '2.0.0+build.1848', true, null),
    ('semver', '2.0.1-alpha.1227', true, null),
    ('semver', '1.0.0-alpha+beta', true, null),
    ('semver', '1.2.3----RC-SNAPSHOT.12.9.1--.12+788', true, null),
    ('semver', '1.2.3----R-S.12.9.1--.12+meta', true, null),
    ('semver', '1.2.3----RC-SNAPSHOT.12.9.1--.12', true, null),
    ('semver', '1.0.0+0.build.1-rc.10000aaa-kk-0.1', true, null),
    ('semver', '99999999999999999999999.999999999999999999.99999999999999999', true, null),
    ('semver', '1.0.0-0A.is.legal', true, null),
    -- semver.org invalid list
    ('semver', '1', false, null),
    ('semver', '1.2', false, null),
    ('semver', '1.2.3-0123', false, null),
    ('semver', '1.2.3-0123.0123', false, null),
    ('semver', '1.1.2+.123', false, null),
    ('semver', '+invalid', false, null),
    ('semver', '-invalid', false, null),
    ('semver', '-invalid+invalid', false, null),
    ('semver', '-invalid.01', false, null),
    ('semver', 'alpha', false, null),
    ('semver', 'alpha.beta', false, null),
    ('semver', 'alpha.beta.1', false, null),
    ('semver', 'alpha.1', false, null),
    ('semver', 'alpha+beta', false, null),
    ('semver', 'alpha_beta', false, null),
    ('semver', 'alpha.', false, null),
    ('semver', 'alpha..', false, null),
    ('semver', 'beta', false, null),
    ('semver', '1.0.0-alpha_beta', false, null),
    ('semver', '-alpha.', false, null),
    ('semver', '1.0.0-alpha..', false, null),
    ('semver', '1.0.0-alpha..1', false, null),
    ('semver', '1.0.0-alpha...1', false, null),
    ('semver', '1.0.0-alpha....1', false, null),
    ('semver', '1.0.0-alpha.....1', false, null),
    ('semver', '1.0.0-alpha......1', false, null),
    ('semver', '1.0.0-alpha.......1', false, null),
    ('semver', '01.1.1', false, null),
    ('semver', '1.01.1', false, null),
    ('semver', '1.1.01', false, null),
    ('semver', '1.2.3.DEV', false, null),
    ('semver', '1.2-SNAPSHOT', false, null),
    ('semver', '1.2.31.2.3----RC-SNAPSHOT.12.09.1--..12+788', false, null),
    ('semver', '1.2-RC-SNAPSHOT', false, null),
    ('semver', '-1.0.3-gamma+b7718', false, null),
    ('semver', '+justmeta', false, null),
    ('semver', '9.8.7+meta+meta', false, null),
    ('semver', '9.8.7-whatever+meta+meta', false, null),
    ('semver', '99999999999999999999999.999999999999999999.99999999999999999----RC-SNAPSHOT.12.09.1--------------------------------..12', false, null),
    ('semver', 'v1.2.3', false, 'a v prefix is not part of the version'),

    ('git_sha', 'e83c5163316f89bfbde7d9ab23ca2e25604af290', true, 'SHA-1'),
    ('git_sha', repeat('0123456789abcdef', 4), true, 'SHA-256'),
    ('git_sha', 'E83C5163316F89BFBDE7D9AB23CA2E25604AF290', false, 'uppercase'),
    ('git_sha', 'e83c516', false, 'abbreviated'),
    ('git_sha', 'e83c5163316f89bfbde7d9ab23ca2e25604af29', false, '39 digits'),
    ('git_sha', 'e83c5163316f89bfbde7d9ab23ca2e25604af2901', false, '41 digits'),
    ('git_sha', 'g83c5163316f89bfbde7d9ab23ca2e25604af290', false, 'non-hex');

select tap.plan((select count(*)::int from cases) + 16);
\ir ../fixtures/run_cases.sql

-- uuid(value, version): RFC 9562 variant and version nibble
select tap.is(validate.uuid(value => '017F22E2-79B0-7CC3-98C4-DC0C0C07398F', version => 7), true, 'uuid v7 sample is version 7');
select tap.is(validate.uuid(value => '017F22E2-79B0-7CC3-98C4-DC0C0C07398F', version => 4), false, 'uuid v7 sample is not version 4');
select tap.is(validate.uuid(value => 'C232AB00-9414-11EC-B3C8-9F6BDECED846', version => 1), true, 'RFC 9562 A.1 is version 1');
select tap.is(validate.uuid(value => '5df41881-3aed-3515-88a7-2f4a814cf09e', version => 3), true, 'RFC 9562 A.2 is version 3');
select tap.is(validate.uuid(value => '919108f7-52d1-4320-9bac-f847db4148a8', version => 4), true, 'RFC 9562 A.3 is version 4');
select tap.is(validate.uuid(value => '2ed6657d-e927-568b-95e1-2665a8aea6a2', version => 5), true, 'RFC 9562 A.4 is version 5');
select tap.is(validate.uuid(value => '1EC9414C-232A-6B00-B3C8-9F6BDECED846', version => 6), true, 'RFC 9562 A.5 is version 6');
select tap.is(validate.uuid(value => '2489E9AD-2EE2-8E00-8EC9-32D5F69181C0', version => 8), true, 'RFC 9562 B.1 is version 8');
select tap.is(validate.uuid(value => '919108f7-52d1-4320-cbac-f847db4148a8', version => 4), false, 'variant 110x (Microsoft) is not the RFC variant');
select tap.is(validate.uuid(value => '00000000-0000-0000-0000-000000000000', version => 4), false, 'the Nil UUID has no version');
select tap.throws_ok($$ select validate.uuid(value => '919108f7-52d1-4320-9bac-f847db4148a8', version => 9) $$, '22023', 'version 9 is an error');

-- nanoid(value, size, alphabet)
select tap.is(validate.nanoid(value => '4f90d13a42', size => 10, alphabet => '0123456789abcdef'), true, 'custom alphabet and size');
select tap.is(validate.nanoid(value => '4f90d13a4g', size => 10, alphabet => '0123456789abcdef'), false, 'character outside the custom alphabet');
select tap.is(validate.nanoid(value => '4f90d13a4', size => 10, alphabet => '0123456789abcdef'), false, 'wrong size');
select tap.is(validate.nanoid(value => 'abc_-12345', size => 10), true, 'custom size, default alphabet');
select tap.throws_ok($$ select validate.nanoid(value => 'x', size => 0) $$, '22023', 'size 0 is an error');

select * from tap.finish();
