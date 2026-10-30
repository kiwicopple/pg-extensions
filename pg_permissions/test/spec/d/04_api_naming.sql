-- Goal: the public API's names follow one rule (DECISION.md, "API naming
-- (session 5)"). A model-specific function carries its model's prefix
-- (rbac_ or fga_); no prefix means shared across models (current_subject_id,
-- current_subject_type, delete_subject); a leading _ is internal. Parameters
-- have names, no p_ prefix, and every name can be written unquoted in named
-- notation (`name => value`): no reserved, type_func_name or col_name keyword
-- (`user` is reserved, so OpenFGA's user is `subject`).
-- The last assertions call every public function with all its arguments
-- named, which proves the names parse; a coverage assertion makes sure a new
-- public function gets a call here too.
\ir ../../fixtures/ids.sql

create temp table api_fn as
select p.oid, p.proname::text as name
from pg_proc p
where p.pronamespace = 'permissions'::regnamespace and p.proname !~ '^_';

-- input arguments: modes i (in), b (inout), v (variadic); null modes: all in
create temp table api_arg as
select f.name, a.n, coalesce(p.proargnames[a.n], '') as arg
from api_fn f
join pg_proc p on p.oid = f.oid
cross join lateral generate_series(1, coalesce(cardinality(p.proallargtypes), p.pronargs)) a(n)
where coalesce(p.proargmodes[a.n], 'i') in ('i', 'b', 'v');

-- every public function, prepared (parsed and analyzed, not run) with each
-- input argument passed by name, unquoted, as null
create temp table api_unparsed (name text, err text);
do $$
declare
    f record;
begin
    for f in select n.name, string_agg(a.arg || ' => null', ', ' order by a.n) as args
             from api_fn n left join api_arg a on a.name = n.name group by n.name loop
        begin
            execute format('prepare api_naming_probe as select permissions.%s(%s)', f.name, coalesce(f.args, ''));
            deallocate api_naming_probe;
        exception when others then
            insert into api_unparsed values (f.name, sqlerrm);
        end;
    end loop;
end $$;

select tap.plan(34);

select tap.is(
    (select array_agg(name order by name) from api_fn
     where name !~ '^(rbac|fga)_' and name not in ('current_subject_id', 'current_subject_type', 'delete_subject')),
    null, 'every public function is rbac_*, fga_* or one of the shared three');
select tap.is(
    (select array_agg(name || '(' || arg || ')' order by name, n) from api_arg where arg like 'p\_%'),
    null, 'no public parameter starts with p_');
select tap.is(
    (select array_agg(name || ' #' || n order by name, n) from api_arg where arg = ''),
    null, 'every input parameter of a public function has a name');
select tap.is(
    (select array_agg(a.name || '(' || a.arg || ': ' || k.catdesc || ')' order by a.name, a.n)
     from api_arg a join pg_get_keywords() k on k.word = a.arg where k.catcode in ('R', 'T', 'C')),
    null, 'no public parameter is a reserved, type_func_name or col_name keyword');
select tap.is(
    (select array_agg(name || ': ' || err order by name) from api_unparsed),
    null, 'every public function parses with all its arguments named, unquoted');
select tap.set_eq(
    (select array_agg(name) from api_fn),
    array['current_subject_id', 'current_subject_type', 'delete_subject',
          'rbac_create_role', 'rbac_drop_role', 'rbac_assign_role', 'rbac_unassign_role',
          'rbac_has_role', 'rbac_has_permission', 'rbac_user_permissions', 'rbac_users_with_role',
          'rbac_scopes_with_permission',
          'fga_write_authorization_model', 'fga_read_authorization_model', 'fga_read_authorization_models',
          'fga_delete_store', 'fga_write', 'fga_write_tuple', 'fga_delete_tuple', 'fga_read',
          'fga_check', 'fga_list_objects', 'fga_list_users',
          'fga_check_current', 'fga_list_objects_current', 'fga_list_object_ids_current'],
    'the public functions are the 26 called below');

-- one call per public function, every argument named

-- shared
select tap.is(permissions.current_subject_id(), null, 'current_subject_id()');
select tap.is(permissions.current_subject_type(), 'user', 'current_subject_type()');

-- RBAC
select tap.lives_ok($$ select permissions.rbac_create_role(role => 'viewer', permissions => '{documents.read}', inherits => '{}') $$,
    'rbac_create_role(role, permissions, inherits)');
select tap.lives_ok($$ select permissions.rbac_create_role(role => 'tmp', permissions => '{tmp.use}') $$,
    'rbac_create_role(role, permissions) for rbac_drop_role');
select tap.lives_ok(format($$ select permissions.rbac_assign_role(user_id => %L, role => 'viewer', scope => %L) $$, :'bob', :'acme'),
    'rbac_assign_role(user_id, role, scope)');
select tap.lives_ok(format($$ select permissions.rbac_assign_role(user_id => %L, role => 'viewer', scope => %L) $$, :'bob', :'globex'),
    'rbac_assign_role(user_id, role, scope) for rbac_unassign_role');
select set_config('permissions.subject_id', :'bob', false);
select tap.is(permissions.rbac_has_role(role => 'viewer', scope => :'acme'), true, 'rbac_has_role(role, scope)');
select tap.is(permissions.rbac_has_permission(permission => 'documents.read', scope => :'acme'), true,
    'rbac_has_permission(permission, scope)');
select tap.set_eq(permissions.rbac_scopes_with_permission(permission => 'documents.read', plan_time_guard => null),
    array[:'acme', :'globex'], 'rbac_scopes_with_permission(permission, plan_time_guard)');
select set_config('permissions.subject_id', '', false);
select tap.is(permissions.rbac_user_permissions(user_id => :'bob', scope => :'acme'), '{documents.read}',
    'rbac_user_permissions(user_id, scope)');
select tap.set_eq(array(select permissions.rbac_users_with_role(role => 'viewer', scope => :'acme')), array[:'bob'],
    'rbac_users_with_role(role, scope)');
select tap.lives_ok(format($$ select permissions.rbac_unassign_role(user_id => %L, role => 'viewer', scope => %L) $$, :'bob', :'globex'),
    'rbac_unassign_role(user_id, role, scope)');
select tap.lives_ok($$ select permissions.rbac_drop_role(role => 'tmp') $$, 'rbac_drop_role(role)');

-- OpenFGA
select permissions.fga_write_authorization_model(model => $m${
  "schema_version": "1.1",
  "type_definitions": [
    {"type": "user"},
    {"type": "document", "relations": {"viewer": {"this": {}}},
     "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}}
  ]}$m$::jsonb) as model_id \gset
select tap.ok(:'model_id' ~ '^[0-9A-HJKMNP-TV-Z]{26}$', 'fga_write_authorization_model(model) returns a ULID');
select tap.is((select array_agg(id) from permissions.fga_read_authorization_models()), array[:'model_id'],
    'fga_read_authorization_models()');
select tap.is(permissions.fga_read_authorization_model(model_id => :'model_id') ->> 'id', :'model_id',
    'fga_read_authorization_model(model_id)');
select tap.lives_ok(format($$ select permissions.fga_write_tuple(subject => %L, relation => 'viewer', object => %L) $$,
                           'user:' || :'bob', 'document:' || :'acme_plan'),
    'fga_write_tuple(subject, relation, object)');
select tap.lives_ok(format($$ select permissions.fga_write(writes => %L, deletes => null, model_id => %L) $$,
                           jsonb_build_array(jsonb_build_object('user', 'user:' || :'bob', 'relation', 'viewer',
                                                                'object', 'document:' || :'acme_readme')), :'model_id'),
    'fga_write(writes, deletes, model_id)');
select tap.is(
    (select jsonb_array_length(r.tuples) from permissions.fga_read(object => 'document:', relation => 'viewer',
        subject => 'user:' || :'bob', page_size => 10, continuation_token => '') r),
    2, 'fga_read(object, relation, subject, page_size, continuation_token)');
select tap.is(permissions.fga_check(subject => 'user:' || :'bob', relation => 'viewer', object => 'document:' || :'acme_plan',
        contextual_tuples => null, model_id => :'model_id', context => null),
    true, 'fga_check(subject, relation, object, contextual_tuples, model_id, context)');
select tap.set_eq(array(select permissions.fga_list_objects(subject => 'user:' || :'bob', type => 'document', relation => 'viewer',
        contextual_tuples => null, model_id => :'model_id', context => null)),
    array['document:' || :'acme_plan', 'document:' || :'acme_readme'],
    'fga_list_objects(subject, type, relation, contextual_tuples, model_id, context)');
select tap.set_eq(array(select permissions.fga_list_users(object => 'document:' || :'acme_plan', relation => 'viewer',
        user_filters => '{user}', contextual_tuples => null, model_id => :'model_id', context => null)),
    array['user:' || :'bob'],
    'fga_list_users(object, relation, user_filters, contextual_tuples, model_id, context)');
select set_config('permissions.subject_id', :'bob', false);
select tap.is(permissions.fga_check_current(relation => 'viewer', object => 'document:' || :'acme_plan'), true,
    'fga_check_current(relation, object)');
select tap.set_eq(array(select permissions.fga_list_objects_current(type => 'document', relation => 'viewer')),
    array['document:' || :'acme_plan', 'document:' || :'acme_readme'], 'fga_list_objects_current(type, relation)');
select tap.set_eq(array(select permissions.fga_list_object_ids_current(type => 'document', relation => 'viewer')),
    array[:'acme_plan', :'acme_readme'], 'fga_list_object_ids_current(type, relation)');
select set_config('permissions.subject_id', '', false);
select tap.lives_ok(format($$ select permissions.fga_delete_tuple(subject => %L, relation => 'viewer', object => %L) $$,
                           'user:' || :'bob', 'document:' || :'acme_readme'),
    'fga_delete_tuple(subject, relation, object)');

-- shared cleanup: Bob's assignment in acme and his remaining tuple
select tap.is(permissions.delete_subject(subject_type => 'user', subject_id => :'bob'), 2::bigint,
    'delete_subject(subject_type, subject_id)');
select tap.lives_ok($$ select permissions.fga_delete_store() $$, 'fga_delete_store()');

select * from tap.finish();
