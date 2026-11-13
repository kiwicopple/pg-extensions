-- Random PN-Counter states for the property tests. Include with
-- \ir ../fixtures/gen.sql, then call setseed() before generating, so a run is
-- reproducible on one Postgres version.
--
-- Replica ids come from a small pool (r1..r12), so random states overlap on
-- many keys: the case where merge has to pick the larger entry. Some maps are
-- empty and some states are the empty counter.

create schema if not exists spec;

-- A map of `pool` candidate replicas, each present with probability `density`,
-- with a count from 1 to 1000.
create function spec.rand_map(pool int, density float8)
returns jsonb
language sql volatile
as $$
    select coalesce(jsonb_object_agg('r' || i, 1 + floor(random() * 1000)::bigint), '{}')
    from generate_series(1, pool) i
    where random() < density
$$;

create function spec.rand_pn()
returns crdt.pn
language plpgsql volatile
as $$
declare
    pool int := 1 + floor(random() * 12)::int;
begin
    return jsonb_build_object(
        't', 'pn', 'v', 1,
        'p', spec.rand_map(pool, random()),
        'n', spec.rand_map(pool, random() * 0.7));
end;
$$;

-- The reference merge: per-key max over a full join, written the obvious way.
-- crdt.pn_merge is written differently (overlay of the larger entries of b
-- onto a), so agreement is evidence, not tautology.
create function spec.ref_merge_map(a jsonb, b jsonb)
returns jsonb
language sql immutable
as $$
    select coalesce(jsonb_object_agg(coalesce(x.key, y.key),
                                     greatest(x.value::bigint, y.value::bigint)), '{}')
    from jsonb_each(a) x full join jsonb_each(b) y on x.key = y.key
$$;

create function spec.ref_merge(a crdt.pn, b crdt.pn)
returns jsonb
language sql immutable
as $$
    select jsonb_build_object('t', 'pn', 'v', 1,
                              'p', spec.ref_merge_map(a -> 'p', b -> 'p'),
                              'n', spec.ref_merge_map(a -> 'n', b -> 'n'))
$$;

-- Fold crdt.pn_merge over states in array order (the oracle for the aggregate).
create function spec.fold_merge(states crdt.pn[])
returns crdt.pn
language plpgsql immutable
as $$
declare
    acc crdt.pn;
    s crdt.pn;
begin
    foreach s in array states loop
        acc := crdt.pn_merge(acc, s);
    end loop;
    return acc;
end;
$$;
