-- Manual measurement, not a bench phase (bench/run.sh doesn't read this file):
-- what userset cycles cost ListObjects' leveled walk (_fga_forward), against
-- the same walk without levels (_fga_forward_ids, one row per node), on a
-- database the D benchmark left behind (docker/run-matrix.sh bench ...
-- --keep-running). bench/baselines/D.md, "opt3", candidate 5.
--
-- The leveled walk keeps one row per (node, level), so a node on a cycle of
-- length k is expanded again every k levels until level 25, and so is every
-- expandable node behind it; the walk without levels expands each node once.
-- Measured on the benchmark's team tree as it is (no cycles), then with a
-- 2-cycle at every inner team (inside a transaction that is rolled back):
--   team:<4p>#member member team:<p>      (exists: team 4p is nested in p)
--   team:<p>#member  member team:<4p>     (added: and p in 4p)
-- which also makes each team reach its first child's subtree. Prints, per
-- data set, the time per call of each walk for users 1-30 (document#viewer,
-- three rounds, warm cache) and the ids per call (equal for both walks).
--
--   psql -X -d pgperm_bench -v teams=<teams> -f bench/designs/d/cyclic_walk.sql

\set ON_ERROR_STOP 1

create function pg_temp.time_walks(p_label text)
returns table (data text, walk text, ms_per_call numeric, ids_per_call numeric)
language plpgsql as $$
declare
    m text := (select id from permissions.fga_models order by seq desc limit 1);
    t0 timestamptz;
    n bigint;
    c bigint;
    u int;
begin
    for w in 1 .. 2 loop
        perform count(*) from permissions._fga_forward(m, 'user', md5('user' || 1)::uuid::text, '', '{}', 'document', 'viewer');
        perform count(*) from permissions._fga_forward_ids(m, 'user', md5('user' || 1)::uuid::text, '', '{}', 'document', 'viewer');
        n := 0;
        t0 := clock_timestamp();
        for r in 1 .. 3 loop
            for u in 1 .. 30 loop
                if w = 1 then
                    select count(*) into c from permissions._fga_forward(m, 'user', md5('user' || u)::uuid::text, '', '{}', 'document', 'viewer');
                else
                    select count(*) into c from permissions._fga_forward_ids(m, 'user', md5('user' || u)::uuid::text, '', '{}', 'document', 'viewer');
                end if;
                n := n + c;
            end loop;
        end loop;
        data := p_label;
        walk := case when w = 1 then '_fga_forward (levels)' else '_fga_forward_ids (no levels)' end;
        ms_per_call := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000 / 90, 2);
        ids_per_call := round(n::numeric / 90, 1);
        return next;
    end loop;
end;
$$;

select * from pg_temp.time_walks('tree (no cycles)');

begin;
select permissions.fga_write(jsonb_build_object('tuple_keys', keys, 'on_duplicate', 'ignore'))
from (
    select jsonb_agg(jsonb_build_object('user', 'team:' || md5('team' || p)::uuid || '#member', 'relation', 'member',
                                        'object', 'team:' || md5('team' || (4 * p))::uuid)) as keys
    from (select p, (row_number() over () - 1) / 100 as chunk
          from generate_series(1, :teams / 4) p) x
    group by chunk
) w;
select * from pg_temp.time_walks('2-cycle at every inner team');
rollback;
