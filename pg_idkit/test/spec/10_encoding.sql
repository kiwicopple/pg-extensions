-- Implementation-specific boundary tests; public contracts live separately.
begin;
set local role idkit_owner;
select plan(9);
\ir ../lib/decode.sql
\ir ../lib/fixed-inputs.sql
select is(pg_temp.ulid_fixture('epoch', '00000000-0000-4000-8000-000000000000'),
    '00000000000000000000000000', 'zero fields exclude UUID version and variant bits');
select is(pg_temp.ulid_fixture('2016-07-30 23:54:10.259+00', 'd6764c61-efb9-4000-8000-00009302bd5b'),
    '01ARZ3NDEKTSV4RRFFQ69G5FAV', 'published ULID example');
select is(pg_temp.ulid_fixture('10889-08-02 05:31:50.655+00', 'ffffffff-ffff-4fff-bfff-ffffffffffff'),
    '7ZZZZZZZZZZZZZZZZZZZZZZZZZ', 'maximum 128-bit value');
select ok(bool_and(div(pg_temp.decode_ulid(pg_temp.ulid_fixture(t, '00000000-0000-4000-8000-000000000000')),
    power(2::numeric, 80)) = expected), 'floor milliseconds around second boundaries')
from (values ('2024-01-01 00:00:00.499999+00'::timestamptz, 1704067200499::bigint),
             ('2024-01-01 00:00:00.500000+00', 1704067200500),
             ('2024-01-01 00:00:00.999999+00', 1704067200999),
             ('2024-01-01 00:00:01.000000+00', 1704067201000)) as times(t, expected);
select throws_ok($query$select pg_temp.ulid_fixture('1969-12-31 23:59:59.999999+00',
    '00000000-0000-4000-8000-000000000000')$query$, '22008',
    'ULID timestamp must fit in 48 unsigned bits', 'reject negative timestamps');
select throws_ok($query$select pg_temp.ulid_fixture('10889-08-02 05:31:50.656+00',
    '00000000-0000-4000-8000-000000000000')$query$, '22008',
    'ULID timestamp must fit in 48 unsigned bits', 'reject timestamp overflow');
select ok(
    (pg_temp.ulid_fixture('epoch', 'ffffffff-ffff-4fff-bfff-ffffffffffff') collate "C")
    < pg_temp.ulid_fixture('1970-01-01 00:00:00.001+00', '00000000-0000-4000-8000-000000000000'),
    'timestamp order takes precedence over payload order');
set local timezone = 'Pacific/Auckland';
select is(div(pg_temp.decode_ulid(pg_temp.ulid_fixture('2016-07-30 23:54:10.259+00',
    '00000000-0000-4000-8000-000000000000')), power(2::numeric, 80)), 1469922850259::numeric,
    'timestamp does not depend on session timezone');
select is(pg_temp.ulid_fixture('2016-07-30 23:54:10.259+00', 'd6764c61-efb9-4fff-bfff-ffff9302bd5b'),
    '01ARZ3NDEKTSV4RRFFQ69G5FAV', 'discarded UUID bytes do not affect the payload');
select * from finish();
rollback;
