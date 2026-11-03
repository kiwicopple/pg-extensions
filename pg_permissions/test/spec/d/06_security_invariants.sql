-- Goal: the security invariants of the extension hold for every object it
-- has, including objects added later (docs/integrations/privileges.md,
-- "Security properties").
--
-- The catalog checks read pg_proc, pg_class and pg_depend: the functions and
-- relations in schema permissions, plus the members of extension
-- pg_permissions when it is installed with create extension. A new function
-- without a pinned search_path, a new grant to PUBLIC, a new table that a
-- client can write, or dynamic SQL fails this file. The behavior checks run
-- as the client roles anon and authenticated:
--
--   1. catalog invariants (search_path, settings, grants, owners, no execute)
--   2. clients cannot write any table, sequence, role, model or policy
--   3. a client's temporary types do not reach a security definer function
--      (regression: search_path '' searched pg_temp first, and a temporary
--      domain named text ran its check as the owner)
--   4. a client's standard_conforming_strings does not change the checks
--      (regression: with it off, cedar_is_authorized_current did not parse)
--   5. null, malformed and missing input denies or raises, never allows
--   6. injection payloads are data, and a long one costs linear time
--      (regression: the hint of an unknown relation took minutes)
--   7. install refuses a schema that another role owns or can create in
--      (regression: create schema if not exists accepted any schema)
\set ON_ERROR_STOP off
\ir ../../fixtures/ids.sql
\ir ../../fixtures/d/rbac_roles.sql

select current_database() as orig_db \gset

-- The objects of the extension, and the functions clients may execute.
create schema sec_t;
grant usage on schema sec_t to public;
create view sec_t.procs as
    select p.oid from pg_proc p where p.pronamespace = 'permissions'::regnamespace
    union
    select d.objid from pg_depend d
    where d.classid = 'pg_proc'::regclass and d.refclassid = 'pg_extension'::regclass and d.deptype = 'e'
      and d.refobjid = (select e.oid from pg_extension e where e.extname = 'pg_permissions');
create view sec_t.rels as
    select c.oid from pg_class c where c.relnamespace = 'permissions'::regnamespace
    union
    select d.objid from pg_depend d
    where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_extension'::regclass and d.deptype = 'e'
      and d.refobjid = (select e.oid from pg_extension e where e.extname = 'pg_permissions');
grant select on sec_t.procs, sec_t.rels to public;
-- The client functions: granted to PUBLIC on purpose (docs/integrations/privileges.md).
create table sec_t.client_fns (sig text primary key);
insert into sec_t.client_fns values
    ('permissions.current_subject_id()'), ('permissions.current_subject_type()'), ('permissions._unfolded_null()'),
    ('permissions.rbac_has_permission(text,text)'), ('permissions.rbac_has_role(text,text)'),
    ('permissions.rbac_scopes_with_permission(text,boolean)'),
    ('permissions.fga_check_current(text,text)'), ('permissions.fga_list_objects_current(text,text)'),
    ('permissions.fga_list_object_ids_current(text,text)'),
    ('permissions.cedar_is_authorized_current(text,text,jsonb,boolean)'), ('permissions.cedar_list_resources_current(text,text)'),
    ('permissions.cedar_uid(text,text)');
grant select on sec_t.client_fns to public;

-- A canary that injection payloads must leave alone.
create table public.sec_canary (n int);
insert into public.sec_canary values (1), (2), (3);
grant select on public.sec_canary to public;

-- Data for the behavior checks: alice is a viewer; a model where alice views
-- document:1; Cedar permits view on any Doc, forbids Doc::"secret", and has
-- a forbid that errors on Doc::"err".
select permissions.rbac_assign_role(:'alice', 'viewer', 'org1');
select permissions.fga_write_authorization_model(model => '{
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "document",
     "relations": {"viewer": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]}') is not null as model \gset
select permissions.fga_write_tuple(subject => 'user:' || :'alice', relation => 'viewer', object => 'document:1');
select permissions.cedar_put_policy(policy_id => 'view_docs', policy => 'permit (principal, action == Action::"view", resource is Doc);');
select permissions.cedar_put_policy(policy_id => 'no_secret', policy => 'forbid (principal, action == Action::"view", resource == Doc::"secret");');
select permissions.cedar_put_policy(policy_id => 'err_forbid',
    policy => 'forbid (principal, action == Action::"view", resource == Doc::"err") when { resource.missing_attr == 1 };');

select tap.plan(49);

-- ============================================================================
-- 1. Catalog invariants
-- ============================================================================

select tap.ok((select count(*) from sec_t.procs) > 100 and (select count(*) from sec_t.rels) > 10,
              'the checks below see the extension''s functions and relations');

select tap.is(
    (select array_agg(p.oid::regprocedure::text order by 1) from pg_proc p join sec_t.procs x on x.oid = p.oid
     where p.prosecdef and not 'search_path=pg_catalog, pg_temp' = any(coalesce(p.proconfig, '{}'))),
    null, 'every security definer function sets search_path = pg_catalog, pg_temp');

select tap.is(
    (select array_agg(p.oid::regprocedure::text order by 1) from pg_proc p join sec_t.procs x on x.oid = p.oid
     where exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%' and c !~ '^search_path=(.*, )?pg_temp$')),
    null, 'every function that sets search_path names pg_temp last (an empty search_path searches pg_temp first)');

select tap.is(
    (select array_agg(p.oid::regprocedure::text order by 1) from pg_proc p join sec_t.procs x on x.oid = p.oid
     where p.prosecdef and not 'standard_conforming_strings=on' = any(coalesce(p.proconfig, '{}'))),
    null, 'every security definer function sets standard_conforming_strings = on');

select tap.set_eq(
    (select array_agg(p.oid::regprocedure::text) from pg_proc p join sec_t.procs x on x.oid = p.oid
     where p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')),
    (select array_agg(sig) from sec_t.client_fns),
    'PUBLIC can execute exactly the client functions');

select tap.is(
    (select array_agg(r || ' ' || p.oid::regprocedure::text order by 1)
     from pg_proc p join sec_t.procs x on x.oid = p.oid
     cross join unnest(array['anon', 'authenticated', 'service_role']) r
     where has_function_privilege(r, p.oid, 'execute')
       and p.oid::regprocedure::text not in (select sig from sec_t.client_fns)),
    null, 'anon, authenticated and service_role can execute no other function (service_role needs an explicit grant)');

select tap.is(
    (select array_agg(p.oid::regprocedure::text order by 1) from pg_proc p join sec_t.procs x on x.oid = p.oid
     where p.oid::regprocedure::text in (select sig from sec_t.client_fns)
       and p.oid <> 'permissions._unfolded_null()'::regprocedure
       and not 'search_path=pg_catalog, pg_temp' = any(coalesce(p.proconfig, '{}'))),
    null, 'every client function pins its search_path');

select tap.ok(
    (select p.prosrc ~ '^\s*begin\s+return null;\s+end;\s*$' and not p.prosecdef
     from pg_proc p where p.oid = 'permissions._unfolded_null()'::regprocedure),
    '_unfolded_null, the one client function without settings, names nothing and is not security definer');

select tap.is(
    (select array_agg(p.oid::regprocedure::text order by 1) from pg_proc p join sec_t.procs x on x.oid = p.oid
     where p.prosrc ~* '\mexecute\M'),
    null, 'no function runs dynamic SQL (EXECUTE): review any new one for injection before allowing it here');

select tap.is(
    (select array_agg(distinct p.oid::regprocedure::text || ' -> ' || c.relname)
     from pg_proc p join sec_t.procs x on x.oid = p.oid
     cross join pg_class c join sec_t.rels y on y.oid = c.oid
     where c.relkind in ('r', 'v', 'm', 'p', 'f', 'S')
       and p.prosrc ~* ('\m(from|join|into|update|table|only)\s+' || c.relname || '\M')),
    null, 'no function names a table of the extension without its schema (pg_temp would resolve it)');

select tap.is(
    (select array_agg(c.oid::regclass::text || ' ' || r order by 1)
     from pg_class c join sec_t.rels x on x.oid = c.oid
     cross join unnest(array['public', 'anon', 'authenticated', 'service_role']) r
     where c.relkind in ('r', 'v', 'm', 'p', 'f')
       and (case when r = 'public'
                 then exists (select 1 from aclexplode(c.relacl) a where a.grantee = 0)
                 else has_table_privilege(r, c.oid, 'select, insert, update, delete, truncate, references, trigger')
                      or has_any_column_privilege(r, c.oid, 'select, insert, update, references') end)),
    null, 'PUBLIC, anon, authenticated and service_role have no privilege on any table or view, nor on a column');

select tap.is(
    (select array_agg(c.oid::regclass::text || ' ' || r order by 1)
     from pg_class c join sec_t.rels x on x.oid = c.oid
     cross join unnest(array['public', 'anon', 'authenticated', 'service_role']) r
     where c.relkind = 'S'
       and (case when r = 'public' then exists (select 1 from aclexplode(c.relacl) a where a.grantee = 0)
                 else has_sequence_privilege(r, c.oid, 'usage, select, update') end)),
    null, 'nor on any sequence');

select tap.ok(
    has_schema_privilege('anon', 'permissions', 'usage')
    and not exists (select 1 from aclexplode((select n.nspacl from pg_namespace n where n.nspname = 'permissions')) a
                    where a.privilege_type = 'CREATE' and a.grantee <> (select n.nspowner from pg_namespace n where n.nspname = 'permissions'))
    and not has_schema_privilege('anon', 'permissions', 'create')
    and not has_schema_privilege('authenticated', 'permissions', 'create'),
    'clients have usage on schema permissions, and only its owner can create in it');

select tap.is(
    (select array_agg(o order by o) from (
        select p.oid::regprocedure::text as o from pg_proc p join sec_t.procs x on x.oid = p.oid
        where p.proowner <> (select n.nspowner from pg_namespace n where n.nspname = 'permissions')
        union all
        select c.oid::regclass::text from pg_class c join sec_t.rels x on x.oid = c.oid
        where c.relowner <> (select n.nspowner from pg_namespace n where n.nspname = 'permissions')
        union all
        select t.oid::regtype::text from pg_type t
        where t.typnamespace = 'permissions'::regnamespace
          and t.typowner <> (select n.nspowner from pg_namespace n where n.nspname = 'permissions')) o),
    null, 'the schema''s owner owns every function, relation and type in it');

select tap.is(
    (select array_agg(p.oid::regprocedure::text order by 1) from pg_proc p join sec_t.procs x on x.oid = p.oid
     join pg_language l on l.oid = p.prolang
     where p.proleakproof or l.lanname not in ('sql', 'plpgsql')),
    null, 'no function is leakproof, and every function is SQL or PL/pgSQL');

-- ============================================================================
-- 2. Clients cannot write
-- ============================================================================
-- Every table: insert, update, delete and truncate; every sequence: nextval
-- and setval. Returns what did not raise insufficient_privilege.
create function sec_t.writes_allowed()
returns text[]
language plpgsql
as $$
declare
    t regclass;
    col name;
    op text;
    ok text[] := '{}';
begin
    for t in select c.oid::regclass from pg_class c join sec_t.rels x on x.oid = c.oid where c.relkind in ('r', 'p') order by 1 loop
        select a.attname into col from pg_attribute a where a.attrelid = t and a.attnum > 0 and not a.attisdropped order by a.attnum limit 1;
        foreach op in array array[format('insert into %s default values', t), format('update %s set %I = %I', t, col, col),
                                  format('delete from %s', t), format('truncate %s', t)] loop
            begin
                execute op;
                ok := ok || op;
            exception when insufficient_privilege then
                null;
            when others then
                ok := ok || (op || ': ' || sqlerrm);
            end;
        end loop;
    end loop;
    for t in select c.oid::regclass from pg_class c join sec_t.rels x on x.oid = c.oid where c.relkind = 'S' order by 1 loop
        foreach op in array array[format('select nextval(%L)', t), format('select setval(%L, 1)', t)] loop
            begin
                execute op;
                ok := ok || op;
            exception when insufficient_privilege then
                null;
            end;
        end loop;
    end loop;
    return ok;
end;
$$;
grant execute on function sec_t.writes_allowed() to public;

set role authenticated;
select tap.is(sec_t.writes_allowed(), '{}', 'authenticated cannot insert, update, delete or truncate any table, nor use any sequence');
reset role;
set role anon;
select tap.is(sec_t.writes_allowed(), '{}', 'anon cannot either');
reset role;

set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.throws_ok(format($$ select permissions.rbac_assign_role(user_id => %L, role => 'admin') $$, :'alice'), '42501',
                     'a client cannot assign itself a role');
select tap.throws_ok($$ select permissions.rbac_create_role(role => 'sec_x', permissions => '{documents.delete}') $$, '42501',
                     'a client cannot create a role');
select tap.throws_ok(format($$ select permissions.fga_write_tuple(subject => %L, relation => 'viewer', object => 'document:2') $$, 'user:' || :'alice'),
                     '42501', 'a client cannot write a tuple');
select tap.throws_ok($$ select permissions.fga_write_authorization_model(model => '{"schema_version": "1.1", "type_definitions": [{"type": "user"}]}') $$,
                     '42501', 'a client cannot write an authorization model');
select tap.throws_ok($$ select permissions.cedar_put_policy(policy_id => 'mine', policy => 'permit (principal, action, resource);') $$,
                     '42501', 'a client cannot put a Cedar policy');
select tap.throws_ok($$ select permissions.cedar_put_entities(entities => '[{"uid": {"type": "user", "id": "x"}, "parents": [{"type": "Team", "id": "admins"}]}]') $$,
                     '42501', 'a client cannot put Cedar entities');
select tap.throws_ok(format($$ select permissions.delete_subject(subject_type => 'user', subject_id => %L) $$, :'bob'),
                     '42501', 'a client cannot delete a subject');
reset role;

-- ============================================================================
-- 3. A client's temporary types do not reach a security definer function
-- ============================================================================
-- As the calling role: a temporary domain over every base type of pg_catalog,
-- under the same name, with a check that raises when it runs as any other
-- role (inside a security definer function: the owner). Then every client
-- function. Returns the errors. Before 0.1.0's fix, search_path '' made
-- Postgres resolve text, jsonb and bytea in the function bodies to these
-- domains, and the check ran as the owner.
create function sec_t.shadow_probe(p_role text)
returns text[]
language plpgsql
as $fn$
declare
    t text;
    q text;
    errs text[] := '{}';
    n int := 0;
begin
    execute format($f$create function pg_temp.sec_probe() returns boolean language plpgsql as $b$
        begin
            if current_user <> %L then
                raise exception 'shadow: a temporary type''s check ran as %%', current_user;
            end if;
            return true;
        end $b$ $f$, p_role);
    for t in select y.typname from pg_type y
             where y.typnamespace = 'pg_catalog'::regnamespace and y.typtype = 'b' and y.typname !~ '^_' loop
        begin
            execute format('create domain pg_temp.%I as pg_catalog.%I check (pg_temp.sec_probe())', t, t);
            n := n + 1;
        exception when others then
            null;                               -- a type that cannot be a domain's base
        end;
    end loop;
    if n < 40 then
        errs := errs || format('only %s domains created', n);
    end if;
    foreach q in array array[
        'select permissions.current_subject_id()',
        'select permissions.current_subject_type()',
        'select permissions.rbac_has_permission(permission => ''documents.read'', scope => ''org1'')',
        'select permissions.rbac_has_role(role => ''viewer'', scope => ''org1'')',
        'select permissions.rbac_scopes_with_permission(permission => ''documents.read'')',
        'select permissions.fga_check_current(relation => ''viewer'', object => ''document:1'')',
        'select count(*) from permissions.fga_list_objects_current(type => ''document'', relation => ''viewer'')',
        'select count(*) from permissions.fga_list_object_ids_current(type => ''document'', relation => ''viewer'')',
        'select permissions.cedar_is_authorized_current(action => ''Action::"view"'', resource => ''Doc::"d1"'')',
        'select permissions.cedar_is_authorized_current(action => ''Action::"view"'', resource => ''Doc::"d1"'', resource_attrs => ''{"level": 1, "tags": ["a"]}'')',
        'select count(*) from permissions.cedar_list_resources_current(action => ''Action::"view"'', resource_type => ''Doc'')',
        'select permissions.cedar_uid(type => ''Doc'', id => ''a"b'')'] loop
        begin
            execute q;
        exception when others then
            errs := errs || (q || ': ' || sqlerrm);
        end;
    end loop;
    for t in select y.typname from pg_type y where y.typnamespace = pg_my_temp_schema() and y.typtype = 'd' loop
        execute format('drop domain pg_temp.%I', t);
    end loop;
    drop function pg_temp.sec_probe();
    return errs;
end;
$fn$;
grant execute on function sec_t.shadow_probe(text) to public;

set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.is(sec_t.shadow_probe('authenticated'), '{}',
              'temporary domains named like pg_catalog types (text, jsonb, bytea, ...) never run inside a client function');
reset role;
set role anon;
select set_config('permissions.subject_id', '', false);
select tap.is(sec_t.shadow_probe('anon'), '{}', 'not for anon either, without a subject');
reset role;

-- ============================================================================
-- 4. standard_conforming_strings does not change the checks
-- ============================================================================
-- A new session, so that no function is compiled yet: PL/pgSQL compiles a
-- body in the settings of its first call.
\connect :"orig_db"
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
set escape_string_warning = off;
set standard_conforming_strings = off;
select permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"d1"') as scs_d1,
       permissions.cedar_is_authorized_current(action => 'Action::"view"', resource => 'Doc::"secret"') as scs_secret,
       (select count(*) from permissions.cedar_list_resources_current(action => 'Action::"view"', resource_type => 'Doc')) as scs_list,
       permissions.fga_check_current(relation => 'viewer', object => 'document:1') as scs_fga,
       permissions.rbac_has_permission(permission => 'documents.read', scope => 'org1') as scs_rbac \gset
set standard_conforming_strings = on;
select tap.is(array[:'scs_d1', :'scs_secret', :'scs_list', :'scs_fga', :'scs_rbac'], array['t', 'f', '0', 't', 't'],
              'with standard_conforming_strings off, the client functions parse and give the same answers');
reset role;

-- ============================================================================
-- 5. Null, malformed and missing input denies or raises
-- ============================================================================
set role authenticated;
select set_config('permissions.subject_id', :'alice', false);
select tap.is(array[permissions.rbac_has_permission(null), permissions.rbac_has_permission(null, null),
                    permissions.rbac_has_role(null), permissions.rbac_has_role(null, 'org1')],
              array[false, false, false, false], 'RBAC: null permission or role is false, not null');
select tap.is(permissions.rbac_scopes_with_permission(null), '{}', 'RBAC: null permission has no scopes');
select tap.is(array[permissions.cedar_is_authorized_current(null, null),
                    permissions.cedar_is_authorized_current('Action::"view"', null),
                    permissions.cedar_is_authorized_current(null, 'Doc::"d1"')],
              array[false, false, false], 'Cedar: a null action or resource is false, not null');
select tap.is((select count(*)::int from permissions.cedar_list_resources_current(null, null)), 0, 'Cedar: null arguments list nothing');
select tap.throws_ok($$ select permissions.fga_check_current(null, null) $$, '22023', 'OpenFGA: a null object raises (openfga:2000), it does not allow');
select tap.throws_ok($$ select permissions.fga_check_current('no_such_relation', 'document:1') $$, '22023',
                     'OpenFGA: an unknown relation raises, it does not allow');
select tap.is(array[permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"d1"', '"text"'),
                    permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"d1"', '[1]'),
                    permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"d1"', '{"a": 1.5}'),
                    permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"d1"', '{"__entity": {"type": "x", "id": "y"}}'),
                    permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"d1"',
                        ('{"a": ' || repeat('[', 5000) || repeat(']', 5000) || '}')::jsonb)],
              array[false, false, false, false, false], 'Cedar: resource_attrs that are not a record of Cedar values, or nest 5,000 deep, deny');
select tap.is(array[permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"d1"'),
                    permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"secret"'),
                    permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"err"'),
                    permissions.cedar_is_authorized_current('Action::"edit"', 'Doc::"d1"')],
              array[true, false, false, false], 'Cedar: a forbid overrides a permit, a forbid that errs denies, no permit denies');
select tap.is(permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"secret\"'), false,
              'Cedar: a resource id that is not a Cedar string denies');
-- no subject: every check is false or empty, even where a policy permits any principal
select set_config('permissions.subject_id', '', false);
select tap.is(array[permissions.rbac_has_permission('documents.read', 'org1'),
                    permissions.fga_check_current('viewer', 'document:1'),
                    permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"d1"'),
                    (select count(*) from permissions.cedar_list_resources_current('Action::"view"', 'Doc')) > 0,
                    (select count(*) from permissions.fga_list_object_ids_current('document', 'viewer')) > 0],
              array[false, false, false, false, false], 'no subject: every check is false and every list is empty');
-- a subject type or id that no model has
select set_config('permissions.subject_id', :'alice', false);
select set_config('permissions.subject_type', 'no such type''; --', false);
select tap.is(array[permissions.rbac_has_permission('documents.read', 'org1'), permissions.fga_check_current('viewer', 'document:1'),
                    permissions.cedar_is_authorized_current('Action::"view"', 'Doc::"d1"')],
              array[false, false, false], 'a subject type that is not a name: false everywhere');
select set_config('permissions.subject_type', '', false);
select set_config('permissions.subject_id', '*', false);
select tap.is(permissions.fga_check_current('viewer', 'document:1'), false, 'OpenFGA: the subject id * is not a wildcard');
-- malformed JWT claims raise; the JWT's sub wins over the setting
select set_config('permissions.subject_id', :'alice', false);
select set_config('request.jwt.claims', 'not json', false);
select tap.throws_ok($$ select permissions.rbac_has_permission('documents.read', 'org1') $$, '22P02',
                     'claims that are not JSON raise, they do not fall back to the setting');
select set_config('request.jwt.claims', json_build_object('sub', :'bob', 'role', 'authenticated')::text, false);
select tap.is(permissions.rbac_has_permission('documents.read', 'org1'), false,
              'a JWT for bob with the setting naming alice: bob, who has no role (the setting cannot override the JWT)');
select set_config('request.jwt.claims', '', false);
reset role;

-- ============================================================================
-- 6. Injection payloads are data
-- ============================================================================
-- No function runs dynamic SQL (section 1); these payloads go through every
-- text argument of the client functions and of a few admin functions. Each
-- call returns false or nothing, or raises; the canary keeps its rows.
create function sec_t.inject(p_payloads text[])
returns text[]
language plpgsql
as $$
declare
    x text;
    q text;
    r text;
    allowed text[] := '{}';
begin
    foreach x in array p_payloads loop
        foreach q in array array[
            format('select permissions.rbac_has_permission(%L, %L)::text', x, x),
            format('select permissions.rbac_has_role(%L, %L)::text', x, x),
            format('select cardinality(permissions.rbac_scopes_with_permission(%L))::text', x),
            format('select permissions.fga_check_current(%L, %L)::text', x, 'document:' || x),
            format('select permissions.fga_check_current(%L, %L)::text', 'viewer', x),
            format('select count(*)::text from permissions.fga_list_object_ids_current(%L, %L)', x, 'viewer'),
            format('select permissions.cedar_is_authorized_current(%L, %L)::text', x, x),
            format('select permissions.cedar_is_authorized_current(%L, %L)::text', 'Action::"edit"', 'Doc::"' || x || '"'),
            format('select permissions.cedar_is_authorized_current(%L, %L)::text', 'Action::"edit"', permissions.cedar_uid('Doc', x)),
            format('select count(*)::text from permissions.cedar_list_resources_current(%L, %L)', 'Action::"edit"', x)] loop
            begin
                execute q into r;
                if r is distinct from 'false' and r is distinct from '0' then
                    allowed := allowed || (q || ' -> ' || r);
                end if;
            exception when others then
                null;                           -- an error denies
            end;
        end loop;
    end loop;
    return allowed;
end;
$$;
grant execute on function sec_t.inject(text[]) to public;

select array['''); delete from public.sec_canary; --', '$$; delete from public.sec_canary; $$', 'x'' or ''1''=''1',
             'viewer'' or true or ''', '"); delete from public.sec_canary; --', '*', '%', '\', '"',
             'document:*', 'user:*#member', 'Doc::"x" || true', 'x" || principal == principal || "', repeat('a', 100000),
             E'\u0001\u001c\u001d\u001e\u001f', 'viewer#viewer']::text as payloads \gset
set role authenticated;
select set_config('permissions.subject_id', 'nobody', false);
set statement_timeout = '60s';
select tap.is(sec_t.inject(:'payloads'::text[]), '{}', 'as a subject with no access: every payload gives false, nothing or an error');
-- An unknown relation or type raises with a hint that names the nearest
-- one. Its edit distance took time in the square of the input's length:
-- 100,000 characters held the backend for minutes.
select clock_timestamp() as t0 \gset
select tap.throws_ok(format($$ select permissions.fga_check_current(%L, 'document:1') $$, repeat('v', 100000)), '22023',
                     'a relation of 100,000 characters raises');
select tap.throws_ok(format($$ select count(*) from permissions.fga_list_object_ids_current(%L, 'viewer') $$, repeat('d', 100000)), '22023',
                     'a type of 100,000 characters raises');
select tap.ok(clock_timestamp() - :'t0'::timestamptz < interval '2 s', 'both in linear time (minutes before 0.1.0''s fix)');
reset statement_timeout;
reset role;
-- admin functions store the payloads as data
select permissions.rbac_create_role(role => '''); delete from public.sec_canary; --', permissions => '{"x'' or true"}');
select permissions.rbac_assign_role(user_id => '$$; delete from public.sec_canary; $$', role => '''); delete from public.sec_canary; --');
select permissions.cedar_put_policy(policy_id => 'inj', policy => 'permit (principal == user::"''); delete from public.sec_canary; --", action, resource);');
select tap.is(permissions.rbac_user_permissions(user_id => '$$; delete from public.sec_canary; $$'), '{"x'' or true"}',
              'admin functions keep payloads as role, permission and user names');
select tap.is((select count(*)::int from public.sec_canary), 3, 'the canary keeps its rows');

-- ============================================================================
-- 7. Install refuses a schema another role controls
-- ============================================================================
-- Scratch databases. An install raises; its output is captured, not
-- printed, so this file's output holds no ERROR line.
drop database if exists pgperm_sec_scratch with (force);
drop database if exists pgperm_sec_scratch2 with (force);
drop role if exists sec_squatter;
create role sec_squatter nologin;
create database pgperm_sec_scratch;
create database pgperm_sec_scratch2;
\connect pgperm_sec_scratch
create schema permissions authorization sec_squatter;
\connect pgperm_sec_scratch2
create schema permissions;
grant create on schema permissions to sec_squatter;
\connect :"orig_db"
\set squat_out `"${PGBIN:+$PGBIN/}psql" -X -q -v ON_ERROR_STOP=1 -d pgperm_sec_scratch -f :'impl_path' 2>&1 | head -5`
\set create_out `"${PGBIN:+$PGBIN/}psql" -X -q -v ON_ERROR_STOP=1 -d pgperm_sec_scratch2 -f :'impl_path' 2>&1 | head -5`
\connect pgperm_sec_scratch
select count(*)::text as squat_funcs from pg_proc where pronamespace = 'permissions'::regnamespace \gset
\connect :"orig_db"
select tap.ok(:'squat_out' ~ 'schema permissions is owned by role sec_squatter' and :'squat_funcs' = '0',
              'install into a schema that another role owns raises and creates nothing');
select tap.ok(:'create_out' ~ 'another role has CREATE on schema permissions',
              'install into a schema where another role can create objects raises');
drop database if exists pgperm_sec_scratch with (force);
drop database if exists pgperm_sec_scratch2 with (force);
drop role if exists sec_squatter;

select * from tap.finish();
