-- Goal: the causal rules of the untrusted path (ydoc_apply), rules V0-V7 of
-- experiments/text-ref/README.md. Each rule rejects its case with 22023 and
-- a message naming it; the review's repro converges in both orders; an op
-- that names unseen ids waits and is decided when they arrive (accepted, or
-- rejected into ydoc_rejected without failing the caller); waiting ops are
-- bounded per writer (54000); a re-send under the same ids must be
-- identical (equivocation is refused on both paths); an op is applied
-- whole or not at all; honest local ops pass the rules in order and
-- shuffled; catch-up ops (ops_since, no "v") are for ydoc_merge only.

create function pg_temp.why(q text) returns text language plpgsql as $$
begin
    execute q;
    return 'accepted';
exception when others then
    return sqlstate || ' ' || coalesce(substring(sqlerrm from 'V[0-9]'), '');
end;
$$;
create function pg_temp.ap(d bigint, op text, w text) returns text language sql as $$
    select pg_temp.why(format('select crdt.ydoc_apply(%s, %L, %L)', d, op, w))
$$;

-- the repro, both orders
select crdt.ydoc_create() as a1, crdt.ydoc_create() as a2 \gset
select crdt.ydoc_apply(:a1, '{"v": {}, "i": [["alice", 1, null, null, "abc"]], "d": []}', 'alice') \g /dev/null
select crdt.ydoc_apply(:a1, '{"v": {}, "i": [["bob", 1, null, null, "Y"]], "d": []}', 'bob') \g /dev/null
select pg_temp.ap(:a1, '{"v": {"alice": 3}, "i": [["mal", 1, null, ["alice", 2], "X"]], "d": []}', 'mal') as rep1 \gset
select crdt.ydoc_apply(:a2, '{"v": {}, "i": [["alice", 1, null, null, "abc"]], "d": []}', 'alice') \g /dev/null
select pg_temp.ap(:a2, '{"v": {"alice": 3}, "i": [["mal", 1, null, ["alice", 2], "X"]], "d": []}', 'mal') as rep2 \gset
select crdt.ydoc_apply(:a2, '{"v": {}, "i": [["bob", 1, null, null, "Y"]], "d": []}', 'bob') \g /dev/null

-- one case per rule, on a1 ("abcY": alice 1-3, bob 1)
select pg_temp.ap(:a1, '{"i": [["m0", 1, null, null, "x"]]}', 'm0') as v0a,
       pg_temp.ap(:a1, '{"v": {"alice": 0}, "i": [["m0", 1, null, null, "x"]]}', 'm0') as v0b,
       pg_temp.ap(:a1, '{"v": {}, "i": [["m1", 1, ["alice", 1], null, "x"]]}', 'm1') as v1,
       pg_temp.ap(:a1, '{"v": {"m2": 3}, "i": [["m2", 1, null, null, "x"]]}', 'm2') as v2,
       pg_temp.ap(:a1, '{"v": {"alice": 3, "nobody": 9}, "d": [["alice", 2, 5]]}', 'm6') as v6 \gset
select crdt.ydoc_apply(:a1, '{"v": {"bob": 1}, "i": [["carol", 1, ["bob", 1], null, "c"]], "d": []}', 'carol') as carol \gset
select pg_temp.ap(:a1, '{"v": {"carol": 1}, "i": [["m3", 1, ["carol", 1], null, "z"]]}', 'm3') as v3,
       pg_temp.ap(:a1, '{"v": {"alice": 3}, "i": [["m4", 1, ["alice", 3], ["alice", 1], "z"]]}', 'm4') as v4,
       pg_temp.ap(:a1, '{"v": {"alice": 3, "bob": 1}, "i": [["m5", 1, ["alice", 3], null, "z"]]}', 'm5') as v5,
       pg_temp.ap(:a1, '{"v": {"alice": 3}, "i": [["at", 1, ["alice", 3], null, "ok"], ["at", 3, null, ["alice", 2], "bad"]]}', 'at') as atomic \gset
select crdt.ydoc_value(:a1) as text1, crdt.ydoc_version(:a1) as vv1 \gset

-- V7: waits, then accepted; waits, then rejected into ydoc_rejected
select crdt.ydoc_apply(:a1, '{"v": {"alice": 3, "zed": 2}, "i": [["m7", 1, null, ["alice", 1], "q"]], "d": []}', 'm7') as st7 \gset
select crdt.ydoc_apply(:a1, '{"v": {"alice": 3, "yan": 1, "zed": 2}, "i": [["m8", 1, null, ["alice", 2], "w"]], "d": []}', 'm8') as st8 \gset
select count(*) as waiting from crdt.ydoc_pending_ops where doc = :a1 \gset
select crdt.ydoc_apply(:a1, '{"v": {}, "i": [["zed", 1, null, null, "ZZ"]], "d": []}', 'zed') as stz \gset
select crdt.ydoc_apply(:a1, '{"v": {"zed": 2}, "i": [["yan", 1, ["zed", 2], null, "!"]], "d": []}', 'yan') as sty \gset

-- quota
select crdt.ydoc_create() as qd \gset
select set_config('ydoc.qd', :'qd', false) \g /dev/null
do $$
begin
    for k in 1 .. crdt._ydoc_pending_max_ops() loop
        perform crdt.ydoc_apply(current_setting('ydoc.qd')::bigint, '{"v": {"nobody": 1}, "i": [["q", 1, null, null, "x"]], "d": []}', 'q');
    end loop;
end $$ ;

-- equivocation
select pg_temp.ap(:a1, '{"v": {}, "i": [["alice", 1, null, null, "abd"]], "d": []}', 'alice') as equiv,
       pg_temp.ap(:a1, '{"v": {}, "i": [["alice", 1, null, null, "abc"]], "d": []}', 'alice') as resend,
       pg_temp.why(format('select crdt.ydoc_merge(%s, %L)', :a1, '{"i": [["alice", 1, null, null, "abd"]]}')) as equiv_trusted,
       pg_temp.why(format('select crdt.ydoc_merge(%s, %L)', :a1, '{"i": [["alice", 2, ["alice", 1], ["bob", 1], "bc"]]}')) as equiv_trusted_origin \gset

-- catch-up ops are for the trusted path
select crdt.ydoc_create() as cu \gset
select pg_temp.ap(:cu, crdt.ydoc_ops_since(:a1, '{}')::text, 'alice') as catchup,
       pg_temp.ap(:cu, (crdt.ydoc_ops_since(:a1, '{}') - 'i')::text, 'alice') as catchup_d \gset
select crdt.ydoc_merge(:cu, crdt.ydoc_ops_since(:a1, '{}')) \g /dev/null

-- honest local ops from three writers pass the rules, in order and shuffled
create temp table lops (n serial, op jsonb, w text);
select crdt.ydoc_create() as l \gset
select set_config('ydoc.l', :'l', false) \g /dev/null
select setseed(0.21);
do $$
declare
    d bigint := current_setting('ydoc.l')::bigint;
    w text; len int; pos int; op jsonb;
begin
    for k in 1 .. 150 loop
        w := (array['ann', 'bo', 'cy'])[1 + floor(random() * 3)::int];
        len := crdt.ydoc_length(d);
        if len > 3 and random() < 0.3 then
            pos := floor(random() * (len - 2))::int;
            op := crdt.ydoc_delete(d, pos, 1 + floor(random() * 2)::int, w);
        elsif k % 25 = 0 then
            op := crdt.ydoc_set(d, crdt.ydoc_value(d) || ' end' || k, w);
        else
            op := crdt.ydoc_insert(d, floor(random() * (len + 1))::int, substr('abcdefgh😀', 1 + floor(random() * 8)::int, 2), w);
        end if;
        insert into lops (op, w) values (op, w);
    end loop;
end $$;
select crdt.ydoc_create() as m1, crdt.ydoc_create() as m2 \gset
select count(*) filter (where s <> 'accepted') as inorder_bad from lops,
       lateral (select pg_temp.ap(:m1, op::text, w) s) x \gset
select count(*) filter (where s not in ('accepted', 'pending')) as shuffled_bad
from (select * from lops order by random()) o, lateral (select crdt.ydoc_apply(:m2, o.op, o.w) s) x \gset

select tap.plan(26);
select tap.is(:'rep1'::text, '22023 V5', 'repro, order 1: the op whose originRight skips a seen char is rejected (V5)');
select tap.is(:'rep2'::text, '22023 V5', 'repro, order 2: rejected too');
select tap.is(crdt.ydoc_value(:a2), 'abcY', 'repro: both orders end with abcY');
select tap.is(:'v0a'::text, '22023 V0', 'V0: no "v"');
select tap.is(:'v0b'::text, '22023 V0', 'V0: a count of 0 in "v"');
select tap.is(:'v1'::text, '22023 V1', 'V1: an origin "v" does not cover');
select tap.is(:'v2'::text, '22023 V2', 'V2: a run that does not start at v[replica] + 1');
select tap.is(:'v6'::text, '22023 V6', 'V6: deleting ids "v" does not cover (no pre-deleting future text), even when v names unseen ids');
select tap.is(:'carol'::text, 'accepted', 'an op whose origin is another writer''s char is accepted');
select tap.is(:'v3'::text, '22023 V3', 'V3: "v" not causally closed (carol:1 depends on bob:1)');
select tap.is(:'v4'::text, '22023 V4', 'V4: originLeft after originRight');
select tap.is(:'v5'::text, '22023 V5', 'V5: a seen char between the origins');
select tap.is(:'atomic'::text, '22023 V5', 'an op whose second run breaks a rule is rejected');
select tap.ok(not (:'vv1'::jsonb ? 'at'), 'and its first run is not applied (atomic)');
select tap.is(:'text1'::text, 'abcYc', 'only the honest ops changed the text');
select tap.is(:'st7'::text || ' ' || :'st8'::text || ' ' || :'waiting', 'pending pending 2', 'V7: ops naming unseen ids wait');
select tap.is(:'stz'::text || ' ' || :'sty'::text, 'accepted accepted', 'the ops that complete them are accepted');
select tap.is((select count(*)::int from crdt.ydoc_pending_ops where doc = :a1), 0, 'both waiting ops were decided');
select tap.is((select string_agg(writer || ' ' || substring(reason from 'V[0-9]'), ',') from crdt.ydoc_rejected where doc = :a1), 'm8 V5',
              'the one that breaks V5 is rejected later and logged in ydoc_rejected, without failing the caller');
select tap.is(left(crdt.ydoc_value(:a1), 1), 'q', 'the one that passes is applied');
select tap.throws_ok(format('select crdt.ydoc_apply(%s, %L, %L)', :qd, '{"v": {"nobody": 1}, "i": [["q", 1, null, null, "x"]], "d": []}', 'q'),
                     '54000', 'a writer with too many waiting ops is refused (54000)');
select tap.is(:'equiv'::text || ' | ' || :'resend'::text, '22023  | accepted', 'untrusted: the same ids with other content are refused; an identical re-send is accepted');
select tap.is(:'equiv_trusted'::text || ' | ' || :'equiv_trusted_origin'::text, '22023  | 22023 ', 'trusted: other content, or other origins, under the same ids are refused too');
select tap.is(:'catchup'::text || '|' || :'catchup_d'::text || '|' || crdt.ydoc_value(:cu), '42501 |22023 V0|' || crdt.ydoc_value(:a1),
              'ops_since output is refused by ydoc_apply (other writers'' ids: 42501; no "v": V0), accepted by ydoc_merge');
select tap.is(:inorder_bad + :shuffled_bad, 0, '150 honest local ops (three writers, inserts, deletes, set) pass the rules in order and shuffled');
select tap.is(crdt.ydoc_value(:m1) || '|' || crdt.ydoc_value(:m2), crdt.ydoc_value(:l) || '|' || crdt.ydoc_value(:l), 'and rebuild the text both ways');

select * from tap.finish();
