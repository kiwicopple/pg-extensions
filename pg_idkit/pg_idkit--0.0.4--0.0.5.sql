/**
 * Generate a ULID: 48-bit Unix milliseconds and 80 random bits, encoded in
 * 26 Crockford base32 characters. Use COLLATE "C" for byte-order sorting.
 * Calls within a millisecond are not monotonic; clock rollback is not hidden.
 * Specification: https://github.com/ulid/spec
 * Requires PostgreSQL 13+ (built-in gen_random_uuid, no pgcrypto dependency).
 */
create or replace function gen_random_ulid()
returns text
language plpgsql volatile
set search_path = pg_catalog
as $$
declare
    v_milliseconds bigint := floor(extract(epoch from clock_timestamp()) * 1000);
    v_uuid_hex text;
    v_bits bit(130);
    v_result text := '';
    c_alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
begin
    if v_milliseconds < 0 or v_milliseconds > 281474976710655 then
        raise exception 'ULID timestamp must fit in 48 unsigned bits'
            using errcode = '22008';
    end if;

    -- UUIDv4 uses pg_strong_random. Select 10 entirely random bytes:
    -- bytes 0..5 and 12..15 (zero-based), excluding version byte 6 and
    -- variant byte 8. Do not simply truncate a UUID to 80 bits.
    v_uuid_hex := replace(pg_catalog.gen_random_uuid()::text, '-', '');
    v_bits := B'00' || v_milliseconds::bit(48)
        || ('x' || substr(v_uuid_hex, 1, 12) || substr(v_uuid_hex, 25, 8))::bit(80);

    -- Two leading zero bits pad 128 bits to 26 groups of five. The first
    -- character is therefore 0..7; no signed bigint or numeric rounding.
    for i in 0..25 loop
        v_result := v_result || substr(c_alphabet,
            substring(v_bits from i * 5 + 1 for 5)::integer + 1, 1);
    end loop;
    return v_result;
end;
$$;
