-- Goal: replicas converge (architecture.md section 8.1). In each trial, N
-- replicas apply random increments and decrements to their own entries, each
-- keeping a history of its states. Then two delivery phases, each in shuffled
-- order and with duplicates:
--   1. gossip: random pairs exchange their current (partly merged) states,
--      mixed with stale snapshots from the histories;
--   2. every replica receives every other replica's state as of the end of
--      phase 1, two or three times each.
-- At the end every replica must hold the same state, and its value must equal
-- the sum of the operations. 60 trials, 2 to 12 replicas, 1 to 80 operations.
\ir ../fixtures/gen.sql

create function spec.converge_trial(n_replicas int, n_ops int)
returns table (expected bigint, distinct_states int, final_value bigint, agg_equal boolean, messages int)
language plpgsql volatile
as $$
declare
    st crdt.pn[];          -- each replica's own state
    r int;
    amt bigint;
    sent int := 0;
    m record;
begin
    expected := 0;
    st := array_fill(null::crdt.pn, array[n_replicas]);
    create temp table if not exists hist (replica int, step int, state crdt.pn);
    create temp table if not exists msg (ord float8, target int, state crdt.pn);
    truncate hist, msg;

    -- local operations: each replica writes only its own entry
    for i in 1..n_ops loop
        r := 1 + floor(random() * n_replicas)::int;
        amt := 1 + floor(random() * 100)::bigint;
        if random() < 0.65 then
            st[r] := crdt.pn_increment(st[r], 'replica-' || r, amt);
            expected := expected + amt;
        else
            st[r] := crdt.pn_decrement(st[r], 'replica-' || r, amt);
            expected := expected - amt;
        end if;
        insert into hist values (r, i, st[r]);
    end loop;

    -- phase 1: gossip of current states and stale snapshots, shuffled
    for i in 1..(n_replicas * 4) loop
        r := 1 + floor(random() * n_replicas)::int;
        if random() < 0.5 then
            -- a current state from a random replica
            st[r] := crdt.pn_merge(st[r], st[1 + floor(random() * n_replicas)::int]);
        else
            -- a stale snapshot, possibly of r itself
            st[r] := crdt.pn_merge(st[r], (select h.state from hist h order by random() limit 1));
        end if;
        sent := sent + 1;
    end loop;

    -- phase 2: every state to every other replica, 2 or 3 copies, shuffled
    insert into msg
    select random(), t, st[s]
    from generate_series(1, n_replicas) s, generate_series(1, n_replicas) t,
         lateral generate_series(1, 2 + floor(random() * 2)::int) copies
    where s <> t;
    for m in select * from msg order by ord loop
        st[m.target] := crdt.pn_merge(st[m.target], m.state);
        sent := sent + 1;
    end loop;
    messages := sent;

    select count(distinct coalesce(x, crdt.pn_empty())::jsonb)::int into distinct_states from unnest(st) x;
    final_value := coalesce(crdt.pn_value(st[1]), 0);
    -- the aggregate over every snapshot ever taken, in shuffled order, gives the same state
    select coalesce(crdt.pn_merge_agg(h.state order by random()), crdt.pn_empty())::jsonb
           = coalesce(st[1], crdt.pn_empty())::jsonb
    into agg_equal from hist h;
    return next;
end;
$$;

select setseed(0.77);
create temp table trials as
select t, spec_n, spec_ops, x.*
from generate_series(1, 60) t,
     lateral (select 2 + floor(random() * 11)::int as spec_n, 1 + floor(random() * 80)::int as spec_ops) p,
     lateral spec.converge_trial(p.spec_n, p.spec_ops) x;

select tap.plan(5);

select tap.is((select count(*)::int from trials), 60, '60 trials ran');
select tap.ok((select sum(messages) from trials) >= 3000,
              'the trials delivered at least 3,000 messages in total (' || (select sum(messages) from trials) || ')');
select tap.is((select count(*)::int from trials where distinct_states <> 1), 0,
              'convergence: in every trial all replicas end with the same state');
select tap.is((select count(*)::int from trials where final_value <> expected), 0,
              'in every trial the converged value equals the sum of the operations');
select tap.is((select count(*)::int from trials where not agg_equal), 0,
              'pn_merge_agg over every snapshot, in shuffled order, equals the converged state');

select * from tap.finish();
