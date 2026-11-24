-- An independent base32 decoder for the public output, using exact numeric
-- arithmetic rather than the generator's bit-slicing implementation.
create function pg_temp.decode_ulid(value text) returns numeric
language plpgsql as $$
declare n numeric := 0; digit integer;
begin
    if length(value) <> 26 then raise exception 'bad length'; end if;
    for i in 1..26 loop
        digit := strpos('0123456789ABCDEFGHJKMNPQRSTVWXYZ', substr(value, i, 1)) - 1;
        if digit < 0 then raise exception 'bad alphabet'; end if;
        n := n * 32 + digit;
    end loop;
    if n >= power(2::numeric, 128) then raise exception 'overflow'; end if;
    return n;
end $$;
