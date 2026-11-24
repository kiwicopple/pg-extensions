-- Run this unchanged after every supported installation mode.
begin;
set local role idkit_owner;
select plan(13);
\ir ../lib/decode.sql
select is((select count(*) from pg_proc where pronamespace = 'ids'::regnamespace),
    6::bigint, 'all six ID kit functions are installed');
select ok((select provolatile = 'v' and not prosecdef and prorettype = 'text'::regtype
    and proconfig @> array['search_path=pg_catalog'] from pg_proc
    where oid = to_regprocedure('ids.gen_random_ulid()')),
    'ULID returns text, is volatile, uses invoker rights, and pins its search path');
select ok(not exists(select from pg_extension where extname = 'pgcrypto'), 'no pgcrypto dependency');
select is(current_user::text, 'idkit_owner', 'contracts run as an ordinary role');
select is(current_setting('is_superuser'), 'off', 'caller is not a superuser');
create temp table samples (id text collate "C" primary key default ids.gen_random_ulid());
select floor(extract(epoch from clock_timestamp()) * 1000)::bigint as before_ms \gset
insert into samples select ids.gen_random_ulid() from generate_series(1, 10000);
insert into samples values (default), (default);
select floor(extract(epoch from clock_timestamp()) * 1000)::bigint as after_ms \gset
select is((select count(*) from samples), 10002::bigint, 'distinct generated IDs, including column defaults');
select ok((select bool_and(id ~ '^[0-7][0-9A-HJKMNP-TV-Z]{25}$') from samples), 'canonical 26-character ULIDs');
select ok((select bool_and(div(pg_temp.decode_ulid(id), power(2::numeric, 80))
    between :before_ms and :after_ms) from samples), 'timestamps are bounded by the wall clock');
select is(substr(ids.gen_random_uuid_v6()::text, 15, 1), '6', 'UUIDv6 remains callable');
select is(substr(ids.gen_random_uuid_v7()::text, 15, 1), '7', 'UUIDv7 remains callable');
select is(length(ids.gen_random_ksuid_second()), 27, 'KSUID seconds remains callable');
select is(length(ids.gen_random_ksuid_microsecond()), 27, 'KSUID microseconds remains callable');
select is(ids.timestamp_from_uuid_v7('00000000-03e8-7000-8000-000000000000'),
    timestamp '1970-01-01 00:00:01', 'UUIDv7 timestamp extraction remains callable');
select * from finish();
rollback;
