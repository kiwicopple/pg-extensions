-- Throwaway measurement for research/designs/e-cedar.md, "Phase 5" (tag:
-- cedar-phase5): the policy index and the RLS helpers. Not a benchmark
-- baseline. Run it with phase5.sh, which runs it against the install file of
-- the working tree and, for the "before" column, of a given git revision.
--
-- Data, as in section 13.4: 1,000 users in 50 teams, 1,000 documents in 20
-- folders, the actions view and edit. Every request asks for a different
-- user and document.
\set ON_ERROR_STOP on
create schema r;
create table r.res (what text, us numeric);
create function r.time(p_what text, p_n int, p_sql text) returns void language plpgsql as $$
declare t0 timestamptz; best numeric; dt numeric;
begin
    for k in 1..5 loop
        t0 := clock_timestamp();
        execute p_sql;
        dt := extract(epoch from clock_timestamp() - t0) * 1e6 / p_n;
        if best is null or dt < best then best := dt; end if;
    end loop;
    insert into r.res values (p_what, round(best, 1));
end $$;

select permissions.cedar_put_entities(entities => (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'Team', 'id', 't' || g)))
                                                   from generate_series(1, 50) g));
select permissions.cedar_put_entities(entities => (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'user', 'id', 'u' || g),
    'attrs', jsonb_build_object('level', g % 5),
    'parents', jsonb_build_array(jsonb_build_object('type', 'Team', 'id', 't' || (g % 50 + 1))))) from generate_series(1, 1000) g));
select permissions.cedar_put_entities(entities => (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'Folder', 'id', 'f' || g)))
                                                   from generate_series(1, 20) g));
select permissions.cedar_put_entities(entities => (select jsonb_agg(jsonb_build_object('uid', jsonb_build_object('type', 'Doc', 'id', 'd' || g),
    'parents', jsonb_build_array(jsonb_build_object('type', 'Folder', 'id', 'f' || (g % 20 + 1))))) from generate_series(1, 1000) g));
vacuum analyze;

-- 1. the index: 2 links, then 1,001 links, then 1,000 static policies
select permissions.cedar_put_template(template_id => 'tf',
    template => 'permit (principal in ?principal, action == Action::"view", resource in ?resource) when { principal.level >= 0 };');
select permissions.cedar_link_template(policy_id => 'l' || g, template_id => 'tf', principal => 'Team::"t' || g || '"',
                                       resource => 'Folder::"f' || (g % 20 + 1) || '"')
from generate_series(1, 2) g;
vacuum analyze;
select r.time('cedar_is_authorized: 2 links', 2000,
    $q$select count(*) from generate_series(1, 2000) g where permissions.cedar_is_authorized(principal => 'user::"u' || (g % 1000 + 1) || '"',
       action => 'Action::"view"', resource => 'Doc::"d' || (g * 7 % 1000 + 1) || '"') ->> 'decision' = 'allow'$q$);
select permissions.cedar_link_template(policy_id => 'l' || t || '_' || f, template_id => 'tf', principal => 'Team::"t' || t || '"',
                                       resource => 'Folder::"f' || f || '"')
from generate_series(1, 50) t, generate_series(1, 20) f;
vacuum analyze;
select r.time('cedar_is_authorized: 1,002 links (one per team and folder)', 2000,
    $q$select count(*) from generate_series(1, 2000) g where permissions.cedar_is_authorized(principal => 'user::"u' || (g % 1000 + 1) || '"',
       action => 'Action::"view"', resource => 'Doc::"d' || (g * 7 % 1000 + 1) || '"') ->> 'decision' = 'allow'$q$);
select permissions.cedar_delete_policy(policy_id => p.policy_id) from permissions.cedar_policies() p;
select permissions.cedar_put_policy(policy_id => 'p' || t || '_' || f,
    policy => format('permit (principal in Team::"t%s", action == Action::"view", resource in Folder::"f%s") when { principal.level >= 0 };', t, f))
from generate_series(1, 50) t, generate_series(1, 20) f;
vacuum analyze;
select r.time('cedar_is_authorized: 1,000 static policies', 2000,
    $q$select count(*) from generate_series(1, 2000) g where permissions.cedar_is_authorized(principal => 'user::"u' || (g % 1000 + 1) || '"',
       action => 'Action::"view"', resource => 'Doc::"d' || (g * 7 % 1000 + 1) || '"') ->> 'decision' = 'allow'$q$);
-- ABAC-style: principal All, 1,000 policies over 50 actions and 20 types
select permissions.cedar_delete_policy(policy_id => p.policy_id) from permissions.cedar_policies() p;
select permissions.cedar_put_policy(policy_id => 'a' || a || '_' || t,
    policy => format('permit (principal, action == Action::"a%s", resource is T%s) when { principal.level >= 0 };', a, t))
from generate_series(1, 50) a, generate_series(1, 20) t;
select permissions.cedar_put_policy(policy_id => 'view_doc',
    policy => 'permit (principal, action == Action::"view", resource is Doc) when { principal.level >= 0 };');
vacuum analyze;
select r.time('cedar_is_authorized: 1,001 policies with principal All (50 actions x 20 types)', 2000,
    $q$select count(*) from generate_series(1, 2000) g where permissions.cedar_is_authorized(principal => 'user::"u' || (g % 1000 + 1) || '"',
       action => 'Action::"view"', resource => 'Doc::"d' || (g * 7 % 1000 + 1) || '"') ->> 'decision' = 'allow'$q$);

select exists (select 1 from pg_proc where proname = 'cedar_is_authorized_current') as has_current \gset
\if :has_current
-- 2. the RLS helpers, on the 1,002 links: user u1 is in team t2, which has a
-- link to every folder, so it can view every document
select permissions.cedar_delete_policy(policy_id => p.policy_id) from permissions.cedar_policies() p;
select permissions.cedar_link_template(policy_id => 'l' || t || '_' || f, template_id => 'tf', principal => 'Team::"t' || t || '"',
                                       resource => 'Folder::"f' || f || '"')
from generate_series(1, 50) t, generate_series(1, 20) f;
select permissions.cedar_put_template(template_id => 'share',
    template => 'permit (principal in ?principal, action == Action::"view", resource == ?resource);');
-- 5 shares per team, team t2 among them
select permissions.cedar_link_template(policy_id => 's' || t || '_' || i, template_id => 'share', principal => 'Team::"t' || t || '"',
                                       resource => 'Doc::"d' || ((t * 37 + i * 101) % 1000 + 1) || '"')
from generate_series(1, 50) t, generate_series(1, 5) i;
vacuum analyze;
create table r.docs as select 'd' || g as id, g % 5 as level from generate_series(1, 1000) g;
select set_config('permissions.subject_id', 'u1', false);
select r.time('cedar_is_authorized_current per row, every row allowed (folder links, a condition)', 1000,
    $q$select count(*) from r.docs where permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"' || id || '"')$q$);
select r.time('cedar_is_authorized per row, the same requests', 1000,
    $q$select count(*) from r.docs where permissions.cedar_is_authorized('user::"u1"', 'Action::"view"', 'Doc::"' || id || '"') ->> 'decision' = 'allow'$q$);
select r.time('cedar_list_resources_current(view, Doc): 20 folder links with a condition, 1,000 docs walked and evaluated', 20,
    $q$select sum((select count(*) from permissions.cedar_list_resources_current('Action::"view"', 'Doc' || left(g::text, 0)))) from generate_series(1, 20) g$q$);
-- only the shares: rows outside the 5 shared documents can't match
select permissions.cedar_delete_policy(policy_id => p.policy_id) from permissions.cedar_policies() p where p.template_id = 'tf';
vacuum analyze;
select r.time('cedar_is_authorized_current per row, 5 of 1,000 rows shared (the rest filtered)', 1000,
    $q$select count(*) from r.docs where permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"' || id || '"')$q$);
-- resource_attrs: a row attribute in a condition
select permissions.cedar_put_policy(policy_id => 'row_level',
    policy => 'permit (principal, action == Action::"view", resource is Doc) when { resource.level <= principal.level };');
vacuum analyze;
select set_config('permissions.subject_id', 'u3', false);
select r.time('cedar_is_authorized_current per row, resource_attrs from the row, a condition on every row', 1000,
    $q$select count(*) from r.docs where permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"' || id || '"',
                                                                                  jsonb_build_object('level', level))$q$);
select r.time('cedar_list_resources_current(view, Doc): 1,000 docs, a condition on every one', 10,
    $q$select sum((select count(*) from permissions.cedar_list_resources_current('Action::"view"', 'Doc' || left(g::text, 0)))) from generate_series(1, 10) g$q$);
select permissions.cedar_delete_policy(policy_id => 'row_level');
select r.time('cedar_list_resources_current(view, Doc): 5 shared docs, scope only', 200,
    $q$select sum((select count(*) from permissions.cedar_list_resources_current('Action::"view"', 'Doc' || left(g::text, 0)))) from generate_series(1, 200) g$q$);
-- 3. the statement-level work runs once: the plan of a per-row policy and
-- the call counts of one statement over 1,000 rows (shares only)
begin;
set local track_functions = 'all';
explain (analyze, costs off, timing off, summary off)
select count(*) from r.docs where permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"' || id || '"');
select p.proname, pg_stat_get_xact_function_calls(p.oid) as calls
from pg_proc p where p.pronamespace = 'permissions'::regnamespace
  and p.proname in ('cedar_is_authorized_current', '_cedar_current_filter', '_cedar_keys', '_cedar_decide', '_cedar_current_check')
order by p.proname;
commit;
\endif

select what, us as "us per request or row" from r.res;
