-- Goal: yseq_merge is a join on documents (research/text.md, "Sync out"):
-- commutative, associative, idempotent, with empty and null as identities,
-- and yseq_merge_agg equals folding yseq_merge in any order. States are
-- compared in canonical form (crdt._yseq_normalize), since the chunk layout
-- may depend on the order of operations.
--   300 random triples: three replicas start from a shared random base
--   document, then each makes 1 to 8 concurrent edits (some exchange states
--   in between, so the triples share part of their history).

select setseed(0.7);

create function pg_temp.rnd_text(n int) returns text language sql volatile as $$
    select coalesce(string_agg((array['a','b','c',' ','é','日','😀','x'])[1 + floor(random() * 8)::int], ''), '')
    from generate_series(1, n)
$$;

create function pg_temp.edit(s crdt.yseq, r text) returns crdt.yseq language plpgsql volatile as $$
declare
    len int := crdt.yseq_length(s);
    pos int;
begin
    if len = 0 or random() < 0.6 then
        return crdt.yseq_insert(s, floor(random() * (len + 1))::int, pg_temp.rnd_text(1 + floor(random() * 3)::int), r);
    end if;
    pos := floor(random() * len)::int;
    return crdt.yseq_delete(s, pos, 1 + floor(random() * least(3, len - pos))::int, r);
end;
$$;

create table triples (id int, a crdt.yseq, b crdt.yseq, c crdt.yseq);

do $$
declare
    base crdt.yseq;
    x crdt.yseq[];
    keys text[] := array['alice', 'bob', 'carol:phone'];
begin
    for t in 1..300 loop
        base := crdt.yseq_empty();
        for i in 1..(floor(random() * 6))::int loop
            base := pg_temp.edit(base, (array['base', 'zed'])[1 + floor(random() * 2)::int]);
        end loop;
        x := array[base, base, base];
        for i in 1..(1 + floor(random() * 8))::int loop
            for r in 1..3 loop
                if random() < 0.6 then
                    x[r] := pg_temp.edit(x[r], keys[r]);
                end if;
            end loop;
            if random() < 0.15 then
                x[1] := crdt.yseq_merge(x[1], x[2]);
            end if;
        end loop;
        insert into triples values (t, x[1], x[2], x[3]);
    end loop;
end;
$$;

create function pg_temp.n(s crdt.yseq) returns jsonb language sql immutable as $$ select crdt._yseq_normalize(s)::jsonb $$;

select tap.plan(9);
select tap.ok(bool_and(pg_temp.n(crdt.yseq_merge(a, b)) = pg_temp.n(crdt.yseq_merge(b, a))), 'commutative: merge(a, b) = merge(b, a), 300 pairs') from triples;
select tap.ok(bool_and(pg_temp.n(crdt.yseq_merge(crdt.yseq_merge(a, b), c)) = pg_temp.n(crdt.yseq_merge(a, crdt.yseq_merge(b, c)))),
              'associative: merge(merge(a, b), c) = merge(a, merge(b, c)), 300 triples') from triples;
select tap.ok(bool_and(pg_temp.n(crdt.yseq_merge(a, a)) = pg_temp.n(a)), 'idempotent: merge(a, a) = a') from triples;
select tap.ok(bool_and(pg_temp.n(crdt.yseq_merge(crdt.yseq_merge(a, b), b)) = pg_temp.n(crdt.yseq_merge(a, b))), 'merge(merge(a, b), b) = merge(a, b)') from triples;
select tap.ok(bool_and(pg_temp.n(crdt.yseq_merge(a, crdt.yseq_empty())) = pg_temp.n(a) and pg_temp.n(crdt.yseq_merge(crdt.yseq_empty(), a)) = pg_temp.n(a)),
              'empty is an identity') from triples;
select tap.ok(bool_and(crdt.yseq_merge(a, null)::jsonb = a::jsonb and crdt.yseq_merge(null, a)::jsonb = a::jsonb), 'null is an identity') from triples;
select tap.ok(bool_and(crdt.yseq_is_valid(crdt.yseq_merge(crdt.yseq_merge(a, b), c))), 'every merge result is valid') from triples;
select tap.ok(bool_and(pg_temp.n(g.agg) = pg_temp.n(crdt.yseq_merge(crdt.yseq_merge(t.a, t.b), t.c))),
              'yseq_merge_agg (shuffled input) equals folding yseq_merge')
from triples t, lateral (select crdt.yseq_merge_agg(s order by random()) agg from unnest(array[t.a, t.b, t.c]) s) g;
select tap.ok(bool_and(crdt.yseq_version(crdt.yseq_merge(a, b)) = (
                  select jsonb_object_agg(k, greatest(coalesce((crdt.yseq_version(a) ->> k)::int, 0), coalesce((crdt.yseq_version(b) ->> k)::int, 0)))
                  from (select jsonb_object_keys(crdt.yseq_version(a)) union select jsonb_object_keys(crdt.yseq_version(b))) z(k))),
              'the version of a merge is the per-replica max') from triples where crdt.yseq_version(a) <> '{}' or crdt.yseq_version(b) <> '{}';
select * from tap.finish();
