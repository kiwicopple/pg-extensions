-- Goal: pn_merge is a join-semilattice merge (architecture.md section 8.1).
-- Property tests over 1,000 random triples of states (fixed seed): commutative,
-- associative, idempotent, the empty counter is the identity, null is the
-- identity, the result equals an independent per-key max, and merging in an
-- increment of a state is the same as the increment.
\ir ../fixtures/gen.sql

select setseed(0.2026);
create temp table cases as
select i, spec.rand_pn() as a, spec.rand_pn() as b, spec.rand_pn() as c
from generate_series(1, 1000) i;

-- States whose entries the domain does not check (it checks the envelope):
-- strings, negatives, fractions, nulls, booleans, objects. Merge takes the
-- larger entry under jsonb's total order, so the laws still hold.
create function spec.rand_junk_map() returns jsonb language sql volatile as $$
    select coalesce(jsonb_object_agg('r' || i, (array['"x"', '-3', '1.5', 'null', 'true', '{"a": 1}', '[1]', '7', '2', '"7"'])[1 + floor(random() * 10)::int]::jsonb), '{}')
    from generate_series(1, 6) i where random() < 0.6
$$;
create temp table junk as
select i, jsonb_build_object('t', 'pn', 'v', 1, 'p', spec.rand_junk_map(), 'n', spec.rand_junk_map())::crdt.pn as a,
          jsonb_build_object('t', 'pn', 'v', 1, 'p', spec.rand_junk_map(), 'n', spec.rand_junk_map())::crdt.pn as b,
          jsonb_build_object('t', 'pn', 'v', 1, 'p', spec.rand_junk_map(), 'n', spec.rand_junk_map())::crdt.pn as c
from generate_series(1, 500) i;

select tap.plan(13);

-- The generator exercises the interesting cases.
select tap.ok((select count(*) from cases where (a -> 'p') ?| array(select jsonb_object_keys(b -> 'p'))) >= 300,
              'at least 300 of the pairs share a p key (the generator overlaps replicas)');
select tap.ok((select count(*) from cases where a::jsonb = crdt.pn_empty()::jsonb or b::jsonb = crdt.pn_empty()::jsonb
                                             or (a -> 'n') = '{}' or (b -> 'p') = '{}') >= 50,
              'at least 50 cases have an empty state or an empty map');

select tap.is((select count(*)::int from cases
               where crdt.pn_merge(a, b)::jsonb is distinct from crdt.pn_merge(b, a)::jsonb),
              0, 'commutative: merge(a, b) = merge(b, a), 1,000 cases');
select tap.is((select count(*)::int from cases
               where crdt.pn_merge(crdt.pn_merge(a, b), c)::jsonb is distinct from crdt.pn_merge(a, crdt.pn_merge(b, c))::jsonb),
              0, 'associative: merge(merge(a, b), c) = merge(a, merge(b, c)), 1,000 cases');
select tap.is((select count(*)::int from cases
               where crdt.pn_merge(a, a)::jsonb is distinct from a::jsonb),
              0, 'idempotent: merge(a, a) = a, 1,000 cases');
select tap.is((select count(*)::int from cases
               where crdt.pn_merge(crdt.pn_merge(a, b), b)::jsonb is distinct from crdt.pn_merge(a, b)::jsonb),
              0, 'idempotent on redelivery: merge(merge(a, b), b) = merge(a, b), 1,000 cases');
select tap.is((select count(*)::int from cases
               where crdt.pn_merge(a, crdt.pn_empty())::jsonb is distinct from a::jsonb
                  or crdt.pn_merge(crdt.pn_empty(), a)::jsonb is distinct from a::jsonb),
              0, 'identity: merge(a, empty) = merge(empty, a) = a, 1,000 cases');
select tap.is((select count(*)::int from cases
               where crdt.pn_merge(a, null)::jsonb is distinct from a::jsonb
                  or crdt.pn_merge(null, a)::jsonb is distinct from a::jsonb),
              0, 'null is the identity: merge(a, null) = merge(null, a) = a, 1,000 cases');
select tap.is(crdt.pn_merge(null, null), null::crdt.pn, 'merge(null, null) is null');
select tap.is((select count(*)::int from cases
               where crdt.pn_merge(a, b)::jsonb is distinct from spec.ref_merge(a, b)),
              0, 'merge equals an independent per-key max over a full join, 1,000 cases');
select tap.is((select count(*)::int from cases, lateral (select crdt.pn_increment(a, 'r' || (i % 13), i) as inc) x
               where crdt.pn_merge(a, x.inc)::jsonb is distinct from x.inc::jsonb
                  or crdt.pn_merge(x.inc, a)::jsonb is distinct from x.inc::jsonb),
              0, 'inflation: merge(a, increment(a)) = increment(a), 1,000 cases');
select tap.is((select count(*)::int from cases
               where crdt.pn_value(crdt.pn_merge(a, b)) < greatest(
                         crdt.pn_value(a) - (select coalesce(sum(value::bigint), 0) from jsonb_each(b -> 'n')),
                         crdt.pn_value(b) - (select coalesce(sum(value::bigint), 0) from jsonb_each(a -> 'n')))),
              0, 'the merged value is at least either side minus the other side''s decrements, 1,000 cases');

select tap.is((select count(*)::int from junk
               where crdt.pn_merge(a, b)::jsonb is distinct from crdt.pn_merge(b, a)::jsonb
                  or crdt.pn_merge(crdt.pn_merge(a, b), c)::jsonb is distinct from crdt.pn_merge(a, crdt.pn_merge(b, c))::jsonb
                  or crdt.pn_merge(a, a)::jsonb is distinct from a::jsonb),
              0, 'with unchecked entries (strings, negatives, nulls, objects, ...) merge is still commutative, associative and idempotent, 500 cases');

select * from tap.finish();
