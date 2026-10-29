-- Goal: fga_write_authorization_model rejects what OpenFGA's server rejects
-- and accepts what it accepts (designs/d-per-model.md sections 7 and 8), with
-- the same error code. The graph checks are OpenFGA v1.22.1's
-- typesystem.NewAndValidate (pkg/typesystem/typesystem.go): every relation
-- needs an entrypoint (hasEntrypoints) and computed relations on a type must
-- not form a cycle (HasCycle). Every NewAndValidate error is
-- invalid_authorization_model (2056, pkg/server/commands/write_authzmodel.go:84-86);
-- the request's own validation (openfga/api, openfga_service.proto) comes first:
-- a schema version outside 1.0, 1.1 and 1.2 is 2000, a type or relation name
-- that doesn't match its pattern 2047 or 2050. Each expectation below was
-- checked against the openfga/openfga:v1.22.1 image (memory datastore). The
-- vendored openfga/language cases (62_fga_lang_oracle) cover the same checks
-- from the DSL side.
\ir ../../fixtures/fga_suite.sql

create function pg_temp.write(p_types text, p_schema text default '"schema_version": "1.1", ')
returns text
language sql
as $$
    select fga_test.code_of(format('select permissions.fga_write_authorization_model(%L::jsonb)',
                                   '{' || p_schema || '"type_definitions": ' || p_types || '}'))
$$;

select tap.plan(30);

-- entrypoints: every relation can reach a concrete user type ([user], [user:*])
-- type doc
--   relations
--     define a: b
--     define b: a
select tap.ok(pg_temp.write($$[{"type": "user"}, {"type": "doc", "relations": {
    "a": {"computedUserset": {"relation": "b"}}, "b": {"computedUserset": {"relation": "a"}}}}]$$)
    ~ '^openfga:2056 the definition of relation ''a'' in object type ''doc'' is invalid: no entrypoints defined',
    'relations that only refer to each other have no entrypoint (2056)');
-- define viewer: [doc#viewer]
select tap.ok(pg_temp.write($$[{"type": "user"}, {"type": "doc", "relations": {"viewer": {"this": {}}},
    "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "doc", "relation": "viewer"}]}}}}]$$)
    ~ '^openfga:2056 .*relation ''viewer'' in object type ''doc''.*no entrypoints',
    'a relation whose only type restriction is a userset of itself has no entrypoint');
-- define parent: [doc]
-- define viewer: viewer from parent
select tap.ok(pg_temp.write($$[{"type": "user"}, {"type": "doc", "relations": {"parent": {"this": {}},
    "viewer": {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}},
    "metadata": {"relations": {"parent": {"directly_related_user_types": [{"type": "doc"}]}}}}]$$)
    ~ '^openfga:2056 .*relation ''viewer''.*no entrypoints',
    'a tuple-to-userset that only leads back to itself has no entrypoint');
-- define viewer: [user] and viewer from parent
select tap.ok(pg_temp.write($$[{"type": "user"}, {"type": "doc", "relations": {"parent": {"this": {}},
    "viewer": {"intersection": {"child": [{"this": {}},
        {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}}},
    "metadata": {"relations": {"parent": {"directly_related_user_types": [{"type": "doc"}]},
                               "viewer": {"directly_related_user_types": [{"type": "user"}]}}}}]$$)
    ~ '^openfga:2056 .*relation ''viewer''.*no entrypoints',
    'an intersection needs an entrypoint in every operand');
-- define blocked: [user]
-- define viewer: viewer from parent but not blocked
select tap.ok(pg_temp.write($$[{"type": "user"}, {"type": "doc", "relations": {"parent": {"this": {}}, "blocked": {"this": {}},
    "viewer": {"difference": {"base": {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}},
                              "subtract": {"computedUserset": {"relation": "blocked"}}}}},
    "metadata": {"relations": {"parent": {"directly_related_user_types": [{"type": "doc"}]},
                               "blocked": {"directly_related_user_types": [{"type": "user"}]}}}}]$$)
    ~ '^openfga:2056 .*relation ''viewer''.*no entrypoints',
    'a difference needs an entrypoint in its base');
-- accepted: the same shapes with a way in
select tap.is(pg_temp.write($$[{"type": "user"}, {"type": "doc", "relations": {"parent": {"this": {}},
    "viewer": {"union": {"child": [{"this": {}},
        {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}}},
    "metadata": {"relations": {"parent": {"directly_related_user_types": [{"type": "doc"}]},
                               "viewer": {"directly_related_user_types": [{"type": "user"}]}}}}]$$),
    'ok', 'a union needs an entrypoint in one operand: [user] or viewer from parent is accepted');
select tap.is(pg_temp.write($$[{"type": "user"}, {"type": "doc", "relations": {"editor": {"this": {}},
    "viewer": {"union": {"child": [{"this": {}}, {"computedUserset": {"relation": "editor"}}]}}},
    "metadata": {"relations": {"editor": {"directly_related_user_types": [{"type": "user"}]},
                               "viewer": {"directly_related_user_types": [{"type": "doc", "relation": "viewer"}]}}}}]$$),
    'ok', '[doc#viewer] or editor is accepted: the userset of itself is fine once editor is a way in');
select tap.is(pg_temp.write($$[{"type": "user"}, {"type": "group", "relations": {"member": {"this": {}}},
    "metadata": {"relations": {"member": {"directly_related_user_types": [{"type": "user", "wildcard": {}}]}}}},
    {"type": "doc", "relations": {"viewer": {"this": {}}},
    "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "group", "relation": "member"}]}}}}]$$),
    'ok', 'an entrypoint through another type''s userset counts, and a wildcard is an entrypoint');
select tap.is(pg_temp.write($$[{"type": "user"}, {"type": "folder", "relations": {"viewer": {"this": {}}},
    "metadata": {"relations": {"viewer": {"directly_related_user_types": [{"type": "user"}]}}}},
    {"type": "doc", "relations": {"parent": {"this": {}},
    "viewer": {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}},
    "metadata": {"relations": {"parent": {"directly_related_user_types": [{"type": "folder"}, {"type": "doc"}]}}}}]$$),
    'ok', 'viewer from parent has an entrypoint when one of the parent types gives one');

-- cycles of computed relations, even when every relation has an entrypoint
-- define x: [user] or y
-- define y: [user] or x
select tap.ok(pg_temp.write($$[{"type": "user"}, {"type": "doc", "relations": {
    "x": {"union": {"child": [{"this": {}}, {"computedUserset": {"relation": "y"}}]}},
    "y": {"union": {"child": [{"this": {}}, {"computedUserset": {"relation": "x"}}]}}},
    "metadata": {"relations": {"x": {"directly_related_user_types": [{"type": "user"}]},
                               "y": {"directly_related_user_types": [{"type": "user"}]}}}}]$$)
    ~ '^openfga:2056 the definition of relation ''x'' in object type ''doc'' is invalid: an authorization model cannot contain a cycle',
    'computed relations that refer to each other are a cycle (2056), entrypoints or not');
-- define v: [user]
-- define a: v but not b
-- define b: [user] or a
select tap.ok(pg_temp.write($$[{"type": "user"}, {"type": "doc", "relations": {"v": {"this": {}},
    "a": {"difference": {"base": {"computedUserset": {"relation": "v"}}, "subtract": {"computedUserset": {"relation": "b"}}}},
    "b": {"union": {"child": [{"this": {}}, {"computedUserset": {"relation": "a"}}]}}},
    "metadata": {"relations": {"v": {"directly_related_user_types": [{"type": "user"}]},
                               "b": {"directly_related_user_types": [{"type": "user"}]}}}}]$$)
    ~ '^openfga:2056 .*relation ''a''.*cycle',
    'a cycle through a subtract is a cycle');
-- define a: [user] or a
select tap.ok(pg_temp.write($$[{"type": "user"}, {"type": "doc", "relations": {
    "a": {"union": {"child": [{"this": {}}, {"computedUserset": {"relation": "a"}}]}}},
    "metadata": {"relations": {"a": {"directly_related_user_types": [{"type": "user"}]}}}}]$$)
    ~ '^openfga:2056 .*relation ''a''.*cycle',
    'a relation computed from itself is a cycle');
select tap.is(pg_temp.write($$[{"type": "user"}, {"type": "doc", "relations": {"owner": {"this": {}},
    "editor": {"union": {"child": [{"this": {}}, {"computedUserset": {"relation": "owner"}}]}},
    "viewer": {"union": {"child": [{"computedUserset": {"relation": "editor"}}, {"computedUserset": {"relation": "owner"}}]}}},
    "metadata": {"relations": {"owner": {"directly_related_user_types": [{"type": "user"}]},
                               "editor": {"directly_related_user_types": [{"type": "user"}]}}}}]$$),
    'ok', 'two paths to the same relation are not a cycle');

-- codes from the request's validation and NewAndValidate
select tap.ok(pg_temp.write('[{"type": "user"}]', '"schema_version": "0.9", ') ~ '^openfga:2000 ', 'schema version 0.9 is 2000 (not in 1.0, 1.1, 1.2)');
select tap.ok(pg_temp.write('[{"type": "user"}]', '') ~ '^openfga:2000 ', 'no schema version is 2000');
select tap.ok(pg_temp.write('[{"type": "user"}]', '"schema_version": "1.0", ') ~ '^openfga:2056 ', 'schema version 1.0 is 2056 (invalid schema version)');
select tap.ok(pg_temp.write('[{"type": "user"}]', '"schema_version": "1.2", ') ~ '^openfga:2057 ', 'schema version 1.2 (modular models) is not supported here: 2057');
select tap.ok(pg_temp.write('[{"type": "user"}, {"type": "user"}]') ~ '^openfga:2056 the type ''user'' is defined more than once', 'a type defined twice is 2056');
select tap.ok(pg_temp.write('[{"type": "self"}]') ~ '^openfga:2056 ', 'a type named self is 2056');
select tap.ok(pg_temp.write('[{"type": "this"}]') ~ '^openfga:2056 ', 'a type named this is 2056');
select tap.ok(pg_temp.write('[{"type": "a:b"}]') ~ '^openfga:2047 ', 'a type name with a colon is 2047 (type_invalid_pattern)');
select tap.ok(pg_temp.write('[{"type": "a b"}]') ~ '^openfga:2047 ', 'a type name with a space is 2047');
select tap.ok(pg_temp.write($$[{"type": "user"}, {"type": "doc", "relations": {"a b": {"this": {}}},
    "metadata": {"relations": {"a b": {"directly_related_user_types": [{"type": "user"}]}}}}]$$) ~ '^openfga:2050 ',
    'a relation name with a space is 2050 (relations_invalid_pattern)');
select tap.ok(pg_temp.write($$[{"type": "user"}, {"type": "doc", "relations": {"self": {"this": {}}},
    "metadata": {"relations": {"self": {"directly_related_user_types": [{"type": "user"}]}}}}]$$) ~ '^openfga:2056 ',
    'a relation named self is 2056');

-- refused models never become the latest; an accepted one evaluates
select permissions.fga_write_authorization_model($m${"schema_version": "1.1", "type_definitions": [
  {"type": "user"},
  {"type": "doc", "relations": {"parent": {"this": {}},
     "viewer": {"union": {"child": [{"this": {}},
         {"tupleToUserset": {"tupleset": {"relation": "parent"}, "computedUserset": {"relation": "viewer"}}}]}}},
   "metadata": {"relations": {"parent": {"directly_related_user_types": [{"type": "doc"}]},
                              "viewer": {"directly_related_user_types": [{"type": "user"}]}}}}]}$m$::jsonb) as ok_model \gset
select tap.is(pg_temp.write($$[{"type": "user"}, {"type": "doc", "relations": {
    "a": {"computedUserset": {"relation": "b"}}, "b": {"computedUserset": {"relation": "a"}}}}]$$) like 'openfga:2056 %', true,
    'refused again');
select tap.is(permissions.fga_read_authorization_model() ->> 'id', :'ok_model', 'a refused model does not become the latest');
select permissions.fga_write('[{"user": "user:anne", "relation": "viewer", "object": "doc:root"},
                               {"user": "doc:root", "relation": "parent", "object": "doc:a"},
                               {"user": "doc:a", "relation": "parent", "object": "doc:b"}]');
select tap.is(permissions.fga_check('user:anne', 'viewer', 'doc:b'), true, 'the accepted recursive model evaluates');
select tap.set_eq(array(select permissions.fga_list_objects('user:anne', 'doc', 'viewer')), '{doc:root,doc:a,doc:b}',
                  'and lists');

-- the messages say what to fix
select tap.ok((fga_test.error_of($$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "doc", "relations": {"a": {"computedUserset": {"relation": "b"}}, "b": {"computedUserset": {"relation": "a"}}}}]}') $$)).hint
              ~ '\[user\]', 'the entrypoint hint shows a direct type restriction');
select tap.ok((fga_test.error_of($$ select permissions.fga_write_authorization_model('{"schema_version": "1.1", "type_definitions": [{"type": "user"}, {"type": "doc", "relations": {"x": {"union": {"child": [{"this": {}}, {"computedUserset": {"relation": "y"}}]}}, "y": {"union": {"child": [{"this": {}}, {"computedUserset": {"relation": "x"}}]}}}, "metadata": {"relations": {"x": {"directly_related_user_types": [{"type": "user"}]}, "y": {"directly_related_user_types": [{"type": "user"}]}}}}]}') $$)).hint
              ~ 'doc#x, doc#y', 'the cycle hint names the relations on the cycle');

select * from tap.finish();
