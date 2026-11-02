-- Manual measurement, not a bench phase (bench/run.sh doesn't read this file):
-- what conditions cost Check, ListObjects and ListUsers, in the server, on a
-- database the D benchmark left behind after its conditions phase
-- (docker/run-matrix.sh bench ... --keep-running; seed_conditions.sql wrote
-- `cviewer`, the conditioned copy of `viewer`). research/benchmarks/D.md, "opt3",
-- candidate 6.
--
-- For viewer and cviewer: the time per call and the number of condition
-- evaluations per call (_fga_cond_eval, counted with track_functions) of
--   ListObjects  fga_list_object_ids_current('document', rel), users 1-30
--   Check        fga_check_current(rel, document), the nest_check fixture
--   ListUsers    fga_list_users(document, rel, '{user}'), a document of teams 1-30
-- three rounds each, warm cache. First with seed_conditions.sql's one shared
-- context, then (inside a transaction that is rolled back) with a distinct
-- context on every cteam tuple, so no two evaluations can be shared.
--
--   psql -X -d pgperm_bench -v teams=<teams> -v docs=<docs> -f bench/designs/d/conditions_cost.sql

\set ON_ERROR_STOP 1
set track_functions = 'pl';

create function pg_temp.time_calls(p_label text, p_teams int, p_docs int)
returns table (contexts text, call text, rel text, ms_per_call numeric, evals_per_call numeric, rows_per_call numeric)
language plpgsql as $$
declare
    ev oid := 'permissions._fga_cond_eval'::regproc;
    t0 timestamptz;
    e0 bigint;
    n bigint;
    c bigint;
    k int;
    d int;
begin
    foreach rel in array '{viewer,cviewer}'::text[] loop
        foreach call in array '{ListObjects,Check,ListUsers}'::text[] loop
            for warm in 0 .. 1 loop
                n := 0;
                t0 := clock_timestamp();
                e0 := coalesce(pg_stat_get_xact_function_calls(ev), 0);
                for r in 1 .. case when warm = 0 then 1 else 3 end loop
                    for k in 1 .. 30 loop
                        if call = 'ListObjects' then
                            perform set_config('permissions.subject_id', md5('user' || k)::uuid::text, true);
                            select count(*) into c from permissions.fga_list_object_ids_current('document', rel);
                        elsif call = 'Check' then
                            perform set_config('permissions.subject_id', md5('nest-user' || k)::uuid::text, true);
                            d := (p_teams::bigint * 9973 + (k % 5 + 1) * 7919) % p_docs + 1;
                            select permissions.fga_check_current(rel, 'document:' || md5('doc' || d)::uuid)::int into c;
                        else
                            d := (k::bigint * 9973 + 7919) % p_docs + 1;
                            select count(*) into c from permissions.fga_list_users('document:' || md5('doc' || d)::uuid, rel, '{user}');
                        end if;
                        n := n + c;
                    end loop;
                end loop;
            end loop;
            contexts := p_label;
            ms_per_call := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000 / 90, 3);
            evals_per_call := round((coalesce(pg_stat_get_xact_function_calls(ev), 0) - e0)::numeric / 90, 1);
            rows_per_call := round(n::numeric / 90, 1);
            return next;
        end loop;
    end loop;
end;
$$;

begin;
select * from pg_temp.time_calls('one shared context', :teams, :docs);
rollback;

begin;
update permissions.fga_tuples
set condition_context = jsonb_build_object('expires', to_char(timestamptz '2100-01-01 00:00:00+00' + seq * interval '1 second',
                                                             'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
where condition_name = 'active';
select * from pg_temp.time_calls('a distinct context per tuple', :teams, :docs);
rollback;
