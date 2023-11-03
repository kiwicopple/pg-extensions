/*
 * MIT License
 *
 * Copyright (c) 2023 Fabio Lima: 
 *		https://gist.github.com/fabiolimace/515a0440e3e40efeb234e12644a6a346
 * 		https://gist.github.com/fabiolimace/5e7923803566beefaf3c716d1343ae27
 *
 * Copyright (c) 2023 Paul Copplestone: 
 *  	https://github.com/kiwicopple/pg-extensions/
 * 
 *  Permission is hereby granted, free of charge, to any person obtaining a copy
 *  of this software and associated documentation files (the "Software"), to deal
 *  in the Software without restriction, including without limitation the rights
 *  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 *  copies of the Software, and to permit persons to whom the Software is
 *  furnished to do so, subject to the following conditions:
 * 
 *  The above copyright notice and this permission notice shall be included in
 *  all copies or substantial portions of the Software.
 * 
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 *  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 *  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 *  THE SOFTWARE.
 */


/**
 * Returns a time-ordered UUID (UUIDv6).
 *
 * References:
 * - https://github.com/uuid6/uuid6-ietf-draft
 * - https://github.com/ietf-wg-uuidrev/rfc4122bis
 *
 * MIT License.
 *
 * Tags: uuid guid uuid-generator guid-generator generator time order rfc4122 rfc-4122
 */
create or replace function gen_random_uuid_v6()
returns uuid 
language plpgsql
as $$
declare
	v_time timestamp with time zone:= null;
	v_secs bigint := null;
	v_usec bigint := null;

	v_timestamp bigint := null;
	v_timestamp_hex varchar := null;

	v_clkseq_and_nodeid bigint := null;
	v_clkseq_and_nodeid_hex varchar := null;

	v_bytes bytea;

	c_epoch bigint := -12219292800; -- RFC-4122 epoch: '1582-10-15 00:00:00'
	c_variant bit(64):= x'8000000000000000'; -- RFC-4122 variant: b'10xx...'
begin

	-- Get seconds and micros
	v_time := clock_timestamp();
	v_secs := EXTRACT(EPOCH FROM v_time);
	v_usec := mod(EXTRACT(MICROSECONDS FROM v_time)::numeric, 10^6::numeric);

	-- Generate timestamp hexadecimal (and set version 6)
	v_timestamp := (((v_secs - c_epoch) * 10^6) + v_usec) * 10;
	v_timestamp_hex := lpad(to_hex(v_timestamp), 16, '0');
	v_timestamp_hex := substr(v_timestamp_hex, 2, 12) || '6' || substr(v_timestamp_hex, 14, 3);

	-- Generate clock sequence and node identifier hexadecimal (and set variant b'10xx')
	v_clkseq_and_nodeid := ((random()::numeric * 2^62::numeric)::bigint::bit(64) | c_variant)::bigint;
	v_clkseq_and_nodeid_hex := lpad(to_hex(v_clkseq_and_nodeid), 16, '0');

	-- Concat timestemp, clock sequence and node identifier hexadecimal
	v_bytes := decode(v_timestamp_hex || v_clkseq_and_nodeid_hex, 'hex');

	return encode(v_bytes, 'hex')::uuid;
end $$;


/**
 * Returns a time-ordered with Unix Epoch UUID (UUIDv7).
 * 
 * References:
 * - https://github.com/uuid6/uuid6-ietf-draft
 * - https://github.com/ietf-wg-uuidrev/rfc4122bis
 *
 * MIT License.
 *
 * Tags: uuid guid uuid-generator guid-generator generator time order rfc4122 rfc-4122
 */
create or replace function gen_random_uuid_v7()
returns uuid 
language plpgsql
as $$
declare
	v_time timestamp with time zone:= null;
	v_secs bigint := null;
	v_msec bigint := null;
	v_usec bigint := null;

	v_timestamp bigint := null;
	v_timestamp_hex varchar := null;

	v_random bigint := null;
	v_random_hex varchar := null;

	v_bytes bytea;

	c_variant bit(64):= x'8000000000000000'; -- RFC-4122 variant: b'10xx...'
begin

	-- Get seconds and micros
	v_time := clock_timestamp();
	v_secs := EXTRACT(EPOCH FROM v_time);
	v_msec := mod(EXTRACT(MILLISECONDS FROM v_time)::numeric, 10^3::numeric);
	v_usec := mod(EXTRACT(MICROSECONDS FROM v_time)::numeric, 10^3::numeric);

	-- Generate timestamp hexadecimal (and set version 7)
	v_timestamp := (((v_secs * 10^3) + v_msec)::bigint << 12) | (v_usec << 2);
	v_timestamp_hex := lpad(to_hex(v_timestamp), 16, '0');
	v_timestamp_hex := substr(v_timestamp_hex, 2, 12) || '7' || substr(v_timestamp_hex, 14, 3);

	-- Generate the random hexadecimal (and set variant b'10xx')
	v_random := ((random()::numeric * 2^62::numeric)::bigint::bit(64) | c_variant)::bigint;
	v_random_hex := lpad(to_hex(v_random), 16, '0');

	-- Concat timestemp and random hexadecimal
	v_bytes := decode(v_timestamp_hex || v_random_hex, 'hex');

	return encode(v_bytes, 'hex')::uuid;
	
end $$;


/**
 * Returns a Segment's KSUID.
 *
 * ------------------------------
 * Structure
 * ------------------------------
 *  2HiFB j6X9oGTDYLDVn8qqfjfE9C
 *    ^      ^
 *    |      |
 *    |      +----- random (128b)
 *    +----------- seconds  (32b)
 * ------------------------------
 *
 * Use COLLATE "C" or COLLATE "POSIX" on column to sort by ASCII order.
 * "The C and POSIX collations both specify “traditional C” behavior, in
 * which only the ASCII letters “A” through “Z” are treated as letters, 
 * and sorting is done strictly by character code byte values."
 * Source: https://www.postgresql.org/docs/current/collation.html
 *
 * Reference implementation: https://github.com/segmentio/ksuid
 * Also read: https://segment.com/blog/a-brief-history-of-the-uuid/
 *
 * MIT License.
 */
create or replace function gen_random_ksuid_second() returns text as $$
declare
	v_time timestamp with time zone := null;
	v_seconds numeric(50) := null;
	v_numeric numeric(50) := null;
	v_epoch numeric(50) = 1400000000; -- 2014-05-13T16:53:20Z
	v_base62 text := '';
	v_alphabet char array[62] := array[
		'0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
		'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J',
		'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 
		'U', 'V', 'W', 'X', 'Y', 'Z', 
		'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 
		'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't',
		'u', 'v', 'w', 'x', 'y', 'z'];
	i integer := 0;
begin

	-- Get the current time
	v_time := clock_timestamp();

	-- Extract epoch seconds
	v_seconds := EXTRACT(EPOCH FROM v_time) - v_epoch;

	-- Generate a KSUID in a numeric variable
	v_numeric := v_seconds * pow(2::numeric(50), 128) -- 32 bits for seconds and 128 bits for randomness
		+ ((random()::numeric(70,20) * pow(2::numeric(70,20), 48))::numeric(50) * pow(2::numeric(50), 80)::numeric(50))
		+ ((random()::numeric(70,20) * pow(2::numeric(70,20), 40))::numeric(50) * pow(2::numeric(50), 40)::numeric(50))
		+  (random()::numeric(70,20) * pow(2::numeric(70,20), 40))::numeric(50);

	-- Encode it to base-62
	while v_numeric <> 0 loop
		v_base62 := v_base62 || v_alphabet[mod(v_numeric, 62) + 1];
		v_numeric := div(v_numeric, 62);
	end loop;
	v_base62 := reverse(v_base62);
	v_base62 := lpad(v_base62, 27, '0');

	return v_base62;
	
end $$ language plpgsql;


/**
 * Returns a Segment's KSUID with microsecond precision.
 * 
 * -------------------------------
 * Structure
 * -------------------------------
 *  2HiFJ Omk JQ0tyawHfJwUJO9IomG
 *    ^    ^    ^
 *    |    |    |
 *    |    |    +-- random (108b)
 *    |    +------- micros  (20b)
 *    +----------- seconds  (32b)
 * -------------------------------
 * 
 * Use COLLATE "C" or COLLATE "POSIX" on column to sort by ASCII order.
 * "The C and POSIX collations both specify “traditional C” behavior, in
 * which only the ASCII letters “A” through “Z” are treated as letters, 
 * and sorting is done strictly by character code byte values."
 * Source: https://www.postgresql.org/docs/current/collation.html
 *
 * Reference implementation: https://github.com/segmentio/ksuid
 * Also read: https://segment.com/blog/a-brief-history-of-the-uuid/
 *
 * MIT License.
 */
create or replace function gen_random_ksuid_microsecond() returns text as $$
declare
	v_time timestamp with time zone := null;
	v_seconds numeric(50) := null;
	v_micros numeric(50)  := null;
	v_numeric numeric(50) := null;
	v_epoch numeric(50) = 1400000000; -- 2014-05-13T16:53:20Z
	v_base62 text := '';
	v_alphabet char array[62] := array[
		'0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
		'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J',
		'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 
		'U', 'V', 'W', 'X', 'Y', 'Z', 
		'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 
		'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't',
		'u', 'v', 'w', 'x', 'y', 'z'];
	i integer := 0;
begin

	-- Get the current time
	v_time := clock_timestamp();

	-- Extract the epoch seconds and microseconds
	v_seconds := EXTRACT(EPOCH FROM v_time) - v_epoch;
	v_micros  := MOD((EXTRACT(microseconds FROM v_time)::numeric(50)), 1e6::numeric(50));

	-- Generate a KSUID in a numeric variable
	v_numeric := (v_seconds * pow(2::numeric(50), 128))  -- 32 bits for seconds
		+ (v_micros * pow(2::numeric(50), 108))          -- 20 bits for microseconds and 108 bits for randomness
		+ ((random()::numeric(70,20) * pow(2::numeric(70,20), 54))::numeric(50) * pow(2::numeric(50), 54)::numeric(50))
		+  (random()::numeric(70,20) * pow(2::numeric(70,20), 54))::numeric(50);

	-- Encode it to base-62
	while v_numeric <> 0 loop
		v_base62 := v_base62 || v_alphabet[mod(v_numeric, 62) + 1];
		v_numeric := div(v_numeric, 62);
	end loop;
	v_base62 := reverse(v_base62);
	v_base62 := lpad(v_base62, 27, '0');

	return v_base62;
	
end $$ language plpgsql;



/**
 * Converts a KSUID into a timestamp (UTC).
 */
CREATE OR REPLACE FUNCTION ksuid_to_timestamp(ksuid text) 
RETURNS timestamp with time zone 
AS $$
DECLARE
  v_epoch CONSTANT numeric := 1400000000; -- Custom epoch timestamp
  v_base62 text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  v_numeric numeric := 0;
  v_timestamp timestamp with time zone;
  i integer;
BEGIN
  -- Convert base-62 part of the KSUID to numeric
  FOR i IN 1..length(ksuid) LOOP
    v_numeric := v_numeric * 62 + strpos(v_base62, substring(ksuid FROM i FOR 1)) - 1;
  END LOOP;

  -- Calculate the timestamp
  -- Divide by 2^128 to get the seconds part, as the first 32 bits are for the timestamp
  v_numeric := v_numeric / pow(2::numeric, 128);
  -- Convert the seconds since custom epoch to the timestamp
  v_timestamp := to_timestamp(v_epoch + v_numeric);

  RETURN v_timestamp;
END $$ LANGUAGE plpgsql;

