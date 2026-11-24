-- Exercise the actual function body with fixed clock/entropy inputs. Only the
-- two external inputs are substituted; no production test hooks or duplicated
-- encoder. Assert the substitutions so a source refactor cannot silently skip
-- deterministic boundary coverage.
do $$
declare body text;
begin
    select prosrc into body from pg_proc where oid = 'ids.gen_random_ulid()'::regprocedure;
    if body is null or strpos(body, 'clock_timestamp()') = 0 or strpos(body, 'pg_catalog.gen_random_uuid()') = 0 then
        raise exception 'Update fixture input substitution for new implementation';
    end if;
    body := replace(replace(body, 'clock_timestamp()', 'fixture_time'),
                    'pg_catalog.gen_random_uuid()', 'fixture_uuid');
    execute format('create function pg_temp.ulid_fixture(fixture_time timestamptz, fixture_uuid uuid)
        returns text language plpgsql set search_path = pg_catalog as %L', body);
end $$;
