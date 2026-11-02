-- Throwaway measurement for research/designs/e-cedar.md, "Phase 2
-- measurements" (tag: cedar-ancestors). Not a benchmark baseline and not part
-- of the extension. Run it with phase2.sh, which installs the extension
-- first and then runs the concurrent-write part with pgbench.
--
-- The candidates for `in` (e-cedar.md section 4.5):
--   A  a closure table m.anc (entity, ancestor), maintained on every put
--   C  the extension: direct parents in cedar_entity_parents, a recursive walk
--      (_cedar_ancestors) once per request for principal, action and
--      resource, and per `in` for any other entity
--
-- Data, per depth d in 1, 10, 117: chains Group::"c<k>_<j>" (j = 1..d, j's
-- parent is j + 1) with User::"u<k>" under Group::"c<k>_1"; 1,000 chains for
-- d = 1 and 10, 100 for d = 117. Every user also has an attribute, and every
-- chain a Doc::"d<k>" under its top group.
\set ON_ERROR_STOP on
create schema m;

create table m.anc (type text collate "C", id text collate "C", anc_type text collate "C", anc_id text collate "C",
                    primary key (type, id, anc_type, anc_id));

create table m.results (depth int, what text, us numeric);

-- A's closure, rebuilt from cedar_entity_parents (the load step of A).
create function m.rebuild_closure() returns void language sql as $$
    truncate m.anc;
    insert into m.anc
    with recursive w(type, id, anc_type, anc_id) as (
        select type, id, parent_type, parent_id from permissions.cedar_entity_parents
        union
        select w.type, w.id, p.parent_type, p.parent_id from w
        join permissions.cedar_entity_parents p on p.type = w.anc_type and p.id = w.anc_id
    )
    select * from w;
$$;

-- A's write of one new leaf (an entity with parents, nothing below it): the
-- parents' closures plus the parents, under the global lock that keeps the
-- closure right when writes run concurrently (prototype B's fix).
create function m.put_leaf_a(p_type text, p_id text, p_parent_type text, p_parent_id text) returns void
language plpgsql as $$
begin
    perform pg_advisory_xact_lock(hashtext('cedar closure'));
    insert into permissions.cedar_entities (type, id) values (p_type, p_id) on conflict do nothing;
    insert into permissions.cedar_entity_parents values (p_type, p_id, p_parent_type, p_parent_id) on conflict do nothing;
    insert into m.anc
    select p_type, p_id, p_parent_type, p_parent_id
    union
    select p_type, p_id, a.anc_type, a.anc_id from m.anc a where a.type = p_parent_type and a.id = p_parent_id
    on conflict do nothing;
end $$;

-- A's re-parent of an interior group: every descendant's closure changes.
create function m.reparent_a(p_type text, p_id text, p_parent_type text, p_parent_id text) returns void
language plpgsql as $$
begin
    perform pg_advisory_xact_lock(hashtext('cedar closure'));
    insert into permissions.cedar_entity_parents values (p_type, p_id, p_parent_type, p_parent_id) on conflict do nothing;
    insert into m.anc
    with d as (select type, id from m.anc where anc_type = p_type and anc_id = p_id
               union select p_type, p_id),
         up as (select p_parent_type as t, p_parent_id as i
                union select a.anc_type, a.anc_id from m.anc a where a.type = p_parent_type and a.id = p_parent_id)
    select d.type, d.id, up.t, up.i from d cross join up
    on conflict do nothing;
end $$;

create function m.time(p_depth int, p_what text, p_n int, p_sql text) returns void
language plpgsql as $$
declare t0 timestamptz; best numeric; dt numeric;
begin
    for k in 1..5 loop
        t0 := clock_timestamp();
        execute p_sql;
        dt := extract(epoch from clock_timestamp() - t0) * 1e6 / p_n;
        if best is null or dt < best then best := dt; end if;
    end loop;
    insert into m.results values (p_depth, p_what, round(best, 1));
end $$;

create function m.load(p_depth int, p_chains int) returns void
language plpgsql as $$
declare t0 timestamptz; b int; ents jsonb;
begin
    delete from permissions.cedar_entities;
    delete from permissions.cedar_policies;
    t0 := clock_timestamp();
    -- top-down, 1,000 entities per call
    for b in 0 .. ((p_depth + 2) * p_chains - 1) / 1000 loop
        select jsonb_agg(e order by ord) into ents from (
            select ord, e from (
                select (k - 1) * (p_depth + 2) + (p_depth - j) as ord,
                       jsonb_build_object('uid', jsonb_build_object('type', 'Group', 'id', format('c%s_%s', k, j)),
                                          'attrs', '{}'::jsonb,
                                          'parents', case when j < p_depth then jsonb_build_array(jsonb_build_object('type', 'Group', 'id', format('c%s_%s', k, j + 1)))
                                                          else '[]'::jsonb end) as e
                from generate_series(1, p_chains) k, generate_series(1, p_depth) j
                union all
                select (k - 1) * (p_depth + 2) + p_depth,
                       jsonb_build_object('uid', jsonb_build_object('type', 'User', 'id', 'u' || k),
                                          'attrs', jsonb_build_object('level', k % 5, 'dept', 'Eng'),
                                          'parents', jsonb_build_array(jsonb_build_object('type', 'Group', 'id', format('c%s_1', k))))
                from generate_series(1, p_chains) k
                union all
                select (k - 1) * (p_depth + 2) + p_depth + 1,
                       jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'd' || k),
                                          'attrs', jsonb_build_object('owner', jsonb_build_object('__entity', jsonb_build_object('type', 'User', 'id', 'u' || k))),
                                          'parents', jsonb_build_array(jsonb_build_object('type', 'Group', 'id', format('c%s_%s', k, p_depth))))
                from generate_series(1, p_chains) k) x
            where ord >= b * 1000 and ord < (b + 1) * 1000) y;
        perform permissions.cedar_put_entities(entities => ents);
    end loop;
    insert into m.results values (p_depth, 'C load: cedar_put_entities, per entity', round(extract(epoch from clock_timestamp() - t0) * 1e6 / ((p_depth + 2) * p_chains), 1));
    t0 := clock_timestamp();
    perform m.rebuild_closure();
    insert into m.results values (p_depth, 'A load: closure rebuild, per entity (on top of C load)',
                                  round(extract(epoch from clock_timestamp() - t0) * 1e6 / ((p_depth + 2) * p_chains), 1));
    insert into m.results values (p_depth, 'A closure rows', (select count(*) from m.anc));
    insert into m.results values (p_depth, 'C parent rows', (select count(*) from permissions.cedar_entity_parents));
    analyze;
end $$;

create function m.run(p_depth int, p_chains int) returns void
language plpgsql as $$
declare n int := 2000;
begin
    perform m.load(p_depth, p_chains);
    -- all ancestors of a user (what the request start needs for the principal)
    perform m.time(p_depth, 'C ancestors of a user (recursive walk)', n, format(
        $q$select count(permissions._cedar_ancestors('User', 'u' || (1 + g %% %s), null)) from generate_series(1, %s) g$q$, p_chains, n));
    perform m.time(p_depth, 'A ancestors of a user (closure lookup)', n, format(
        $q$select count((select jsonb_agg(permissions._cedar_key(a.anc_type, a.anc_id)) from m.anc a where a.type = 'User' and a.id = 'u' || (1 + g %% %s)))
           from generate_series(1, %s) g$q$, p_chains, n));
    -- one `in` test against the top group (an `in` on an entity other than the request's)
    perform m.time(p_depth, 'A one in test (index probe)', n, format(
        $q$select count(*) filter (where exists (select 1 from m.anc a where a.type = 'User' and a.id = 'u' || (1 + g %% %s)
                                                and a.anc_type = 'Group' and a.anc_id = format('c%%s_%%s', 1 + g %% %s, %s)))
           from generate_series(1, %s) g$q$, p_chains, p_chains, p_depth, n));
    -- whole requests through the extension (C): scope `principal in` the top group
    perform permissions.cedar_put_policy(policy_id => 'top', policy_json => format(
        '{"effect": "permit", "principal": {"op": "in", "entity": {"type": "Group", "id": "c1_%s"}}, "action": {"op": "All"}, "resource": {"op": "All"}, "conditions": []}',
        p_depth)::jsonb);
    perform m.time(p_depth, 'C cedar_is_authorized, scope principal in the top group', n, format(
        $q$select count(*) from generate_series(1, %s) g
           where permissions.cedar_is_authorized(principal => 'User::"u' || (1 + g %% %s) || '"', action => 'Action::"view"',
                                                 resource => 'Doc::"d' || (1 + g %% %s) || '"') ->> 'decision' = 'allow'$q$, n, p_chains, p_chains));
    perform permissions.cedar_delete_policy(policy_id => 'top');
    -- a condition with attributes and an `in` on an attribute's entity (resource.owner in ...)
    perform permissions.cedar_put_policy(policy_id => 'owner', policy_json => format(
        '{"effect": "permit", "principal": {"op": "All"}, "action": {"op": "All"}, "resource": {"op": "is", "entity_type": "Doc"},
          "conditions": [{"kind": "when", "body": {"&&": {"left": {"==": {"left": {".": {"left": {"Var": "principal"}, "attr": "dept"}}, "right": {"Value": "Eng"}}},
                          "right": {"in": {"left": {".": {"left": {"Var": "resource"}, "attr": "owner"}}, "right": {"Value": {"__entity": {"type": "Group", "id": "c1_%s"}}}}}}}}]}',
        p_depth)::jsonb);
    perform m.time(p_depth, 'C cedar_is_authorized, resource.owner in the top group (walk per request)', n, format(
        $q$select count(*) from generate_series(1, %s) g
           where permissions.cedar_is_authorized(principal => 'User::"u' || (1 + g %% %s) || '"', action => 'Action::"view"',
                                                 resource => 'Doc::"d' || (1 + g %% %s) || '"') ->> 'decision' = 'allow'$q$, n, p_chains, p_chains));
    perform permissions.cedar_delete_policy(policy_id => 'owner');
    -- writes, one session: a new leaf under the bottom group of a chain; a re-parent of a chain's top
    perform m.time(p_depth, 'C write: a new leaf (cedar_put_entities)', 200, format(
        $q$select count(permissions.cedar_put_entities(entities => jsonb_build_array(jsonb_build_object(
               'uid', jsonb_build_object('type', 'User', 'id', 'n' || g || '_' || txid_current() || '_' || random()),
               'parents', jsonb_build_array(jsonb_build_object('type', 'Group', 'id', format('c%%s_1', 1 + g %% %s)))))))
           from generate_series(1, 200) g$q$, p_chains));
    perform m.time(p_depth, 'A write: a new leaf (closure rows, global lock)', 200, format(
        $q$select count(m.put_leaf_a('User', 'a' || g || '_' || random(), 'Group', format('c%%s_1', 1 + g %% %s)))
           from generate_series(1, 200) g$q$, p_chains));
    perform m.time(p_depth, 'A write: link a chain''s top group under a new root (every descendant''s closure)', 20, format(
        $q$select count(m.reparent_a('Group', format('c%%s_%s', g, %s), 'Group', 'root' || g || '_' || random()))
           from generate_series(1, 20) g$q$, p_depth, p_depth));
end $$;

select m.run(1, 1000);
select m.run(10, 1000);
select m.run(117, 100);

select depth, what, us as "us per op (rows: count)" from m.results order by depth, what;
