-- Goal: Design C's incremental membership maintenance (research/designs/c-compiled-model.md
-- §5, "Optimizations (session 3)"). Inserts apply a delta (members of the
-- subject x the sets above the object, least depth wins); deletes recompute
-- the affected principals. These cases target the delta: a shorter path
-- lowering a stored depth, several new tuples chained in one statement,
-- cycles, implied usersets, the depth limit reached through a delta, and a
-- long random sequence of writes, each checked against verify(), which
-- recomputes everything with an independent per-principal walk.
-- White-box: reads permissions.* tables directly.
\ir ../../fixtures/ids.sql
\set qa      '00000000-0000-0000-0004-000000000003'
\set allteam '00000000-0000-0000-0004-000000000004'
\set frank   '00000000-0000-0000-0001-000000000006'

\set model '{"types": {"team": {"relations": {"member": ["user", "team#member"]}}, "org": {"relations": {"admin": ["user"], "member": ["user", "team#member"]}, "implies": {"admin": ["member"]}}, "document": {"relations": {"viewer": ["user", "team#member", "org#member"]}}}}'
select count(*) from permissions.apply_model(:'model');

create function pg_temp.depth(p uuid, s uuid) returns int language sql as $$
    select depth::int from permissions.memberships where principal_id = p and set_id = s $$;
create function pg_temp.member_rel() returns smallint language sql as $$
    select r.id from permissions.relations r join permissions.types t on t.id = r.type_id
    where t.name = 'team' and r.name = 'member' $$;
create function pg_temp.team_type() returns smallint language sql as $$
    select id from permissions.types where name = 'team' $$;
create function pg_temp.user_type() returns smallint language sql as $$
    select id from permissions.types where name = 'user' $$;

select tap.plan(13);

-- ---- a shorter path lowers the stored depth ---------------------------------
select permissions.grant('team', :'eng', 'member', 'user', :'carol');
select permissions.grant('team', :'platform', 'member', 'team', :'eng', 'member');
select permissions.grant('team', :'allteam', 'member', 'team', :'platform', 'member');
select tap.is(pg_temp.depth(:'carol', :'allteam'), 3, 'carol reaches allteam at depth 3 through platform');
select permissions.grant('team', :'allteam', 'member', 'team', :'eng', 'member');
select tap.is(pg_temp.depth(:'carol', :'allteam'), 2, 'a new shortcut from eng lowers the stored depth to 2');

-- ---- cycles ------------------------------------------------------------------
select permissions.grant('team', :'eng', 'member', 'team', :'allteam', 'member');
select tap.ok(pg_temp.depth(:'carol', :'eng') = 1 and pg_temp.depth(:'carol', :'allteam') = 2
              and (select count(*) = 0 from permissions.verify()),
              'closing a cycle (allteam into eng) keeps the shortest depths and verify() clean');

-- ---- several new tuples chained in one statement (owner inserts directly) ---
insert into permissions.tuples (object_type, object_id, relation, subject_type, subject_id, subject_relation)
values (pg_temp.team_type(), md5('s1')::uuid, pg_temp.member_rel(), pg_temp.user_type(), :'dave', null),
       (pg_temp.team_type(), md5('s2')::uuid, pg_temp.member_rel(), pg_temp.team_type(), md5('s1')::uuid, pg_temp.member_rel()),
       (pg_temp.team_type(), md5('s3')::uuid, pg_temp.member_rel(), pg_temp.team_type(), md5('s2')::uuid, pg_temp.member_rel()),
       (pg_temp.team_type(), :'qa',           pg_temp.member_rel(), pg_temp.team_type(), md5('s3')::uuid, pg_temp.member_rel()),
       (pg_temp.team_type(), md5('s2')::uuid, pg_temp.member_rel(), pg_temp.team_type(), :'eng', pg_temp.member_rel());
select tap.ok(pg_temp.depth(:'dave', :'qa') = 4 and pg_temp.depth(:'carol', :'qa') = 4
              and (select count(*) = 0 from permissions.verify()),
              'one statement inserting a whole chain (user -> s1 -> s2 -> s3 -> qa, plus eng -> s2) derives every membership');

-- ---- implied usersets: org admin implies org#member ---------------------------
select permissions.grant('org', :'acme', 'admin', 'user', :'alice');
select permissions.grant('org', :'acme', 'member', 'team', :'qa', 'member');
select tap.ok(pg_temp.depth(:'alice', :'acme') = 1 and pg_temp.depth(:'dave', :'acme') = 5
              and (select count(*) = 0 from permissions.verify()),
              'an admin grant feeds org#member, and nesting qa into the org reaches qa''s members');

-- ---- the depth limit, reached through a delta ----------------------------------
select permissions.grant('team', md5('c1')::uuid, 'member', 'user', :'erin');
select permissions.grant('team', md5('c' || k)::uuid, 'member', 'team', md5('c' || (k - 1))::uuid, 'member')
from generate_series(2, 9) k;
select permissions.grant('team', md5('d1')::uuid, 'member', 'team', md5('d0')::uuid, 'member');
select permissions.grant('team', md5('d2')::uuid, 'member', 'team', md5('d1')::uuid, 'member');
select tap.throws_ok(format($$ select permissions.grant('team', %L, 'member', 'team', %L, 'member') $$, md5('d0')::uuid, md5('c9')::uuid),
                     '54001', 'joining a 9-deep chain onto a 3-deep one (depth 12 for erin) is rejected');
select tap.lives_ok(format($$ select permissions.grant('team', %L, 'member', 'team', %L, 'member') $$, md5('c10')::uuid, md5('c9')::uuid),
                    'a tenth level is still accepted');
select tap.ok(pg_temp.depth(:'erin', md5('c10')::uuid) = 10 and pg_temp.depth(:'erin', md5('d0')::uuid) is null
              and (select count(*) = 0 from permissions.verify()),
              'the rejected write left nothing behind');

-- ---- bulk load: grant_many, one statement per call ----------------------------
select permissions.grant_many('team', 'member', 'team',
    array[md5('b2'), md5('b3'), md5('b4')]::uuid[], array[md5('b1'), md5('b2'), md5('b3')]::uuid[], 'member');
create temp table bulk as select permissions.grant_many('team', 'member', 'user',
    array[md5('b1'), md5('b1'), md5('b3')]::uuid[], array[:'bob', :'frank', :'frank']::uuid[]) as n;
select tap.ok((select n from bulk) = 3 and pg_temp.depth(:'bob', md5('b4')::uuid) = 4
              and pg_temp.depth(:'frank', md5('b4')::uuid) = 2 and (select count(*) = 0 from permissions.verify()),
              'grant_many loads members and nestings in bulk, with the same memberships as one grant at a time');
select tap.is(permissions.grant_many('team', 'member', 'user', array[md5('b1')]::uuid[], array[:'bob']::uuid[]), 0::bigint,
              'grant_many skips pairs that already exist');
select tap.throws_ok(format($$ select permissions.grant_many('team', 'member', 'user', array[%L]::uuid[], '{}') $$, md5('b1')::uuid),
                     '22004', 'grant_many rejects arrays of different lengths');

-- ---- random writes: every step is checked against verify() --------------------
-- 400 grants and revokes over 10 teams and 12 users (nesting, membership,
-- cycles, re-grants, multi-row inserts and deletes), seeded so the run is
-- repeatable. Writes rejected by the depth limit roll back on their own.
create temp table rnd_log (step int, op text, drift bigint);
do $$
declare
    t smallint := pg_temp.team_type();
    u smallint := pg_temp.user_type();
    m smallint := pg_temp.member_rel();
    i int;
    a int; b int; k int;
    drift bigint;
begin
    perform setseed(0.33);
    for i in 1 .. 400 loop
        a := 1 + floor(random() * 10)::int;
        b := 1 + floor(random() * 10)::int;
        k := floor(random() * 6)::int;
        begin
            if k = 0 then        -- nest team b into team a
                perform permissions.grant('team', md5('r' || a)::uuid, 'member', 'team', md5('r' || b)::uuid, 'member');
            elsif k = 1 then     -- add a user
                perform permissions.grant('team', md5('r' || a)::uuid, 'member', 'user', md5('ru' || (b + a % 3))::uuid);
            elsif k = 2 then     -- un-nest
                perform permissions.revoke('team', md5('r' || a)::uuid, 'member', 'team', md5('r' || b)::uuid, 'member');
            elsif k = 3 then     -- remove a user
                perform permissions.revoke('team', md5('r' || a)::uuid, 'member', 'user', md5('ru' || (b + a % 3))::uuid);
            elsif k = 4 then     -- several nestings and members in one statement
                insert into permissions.tuples (object_type, object_id, relation, subject_type, subject_id, subject_relation)
                select t, md5('r' || x)::uuid, m, t, md5('r' || ((x * 7 + b) % 10 + 1))::uuid, m
                from generate_series(a, least(a + 2, 10)) x
                union all
                select t, md5('r' || x)::uuid, m, u, md5('ru' || (x + b))::uuid, null
                from generate_series(a, least(a + 1, 10)) x
                on conflict do nothing;
            else                 -- several revokes in one statement
                delete from permissions.tuples
                where object_type = t and object_id in (md5('r' || a)::uuid, md5('r' || b)::uuid)
                  and subject_relation is not null and subject_id = md5('r' || ((a + b) % 10 + 1))::uuid;
            end if;
        exception when sqlstate '54001' then
            null;
        end;
        select count(*) into drift from permissions.verify();
        if drift > 0 then
            insert into rnd_log values (i, k::text, drift);
        end if;
    end loop;
end $$;
select tap.is((select count(*)::int from rnd_log), 0, '400 random writes, verify() is clean after every one of them');
select tap.ok((select count(*) > 100 and max(depth) >= 3 from permissions.memberships
               where set_id in (select md5('r' || x)::uuid from generate_series(1, 10) x)),
              '(and the random writes left a non-trivial graph: over 100 memberships, nested at least 3 deep)');

select * from tap.finish();
