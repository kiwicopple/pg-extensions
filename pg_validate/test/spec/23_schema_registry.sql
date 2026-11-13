-- Goal: named JSON schemas: register, validate, list and unregister;
-- schemas are checked when registered (also through direct DML) and
-- recompiled when changed; json_schema_named agrees with json_schema; no
-- json_schema(jsonb, text) overload, so untyped literals keep resolving to
-- json_schema(jsonb, jsonb); a CHECK constraint is not rechecked when the
-- schema changes; the ownership and permission model of the format registry.
-- Roles are cluster-wide: drop leftovers from an earlier run that died halfway.
drop role if exists js_admin2, js_admin, js_user;
create role js_admin nologin;
create role js_admin2 nologin;
create role js_user nologin;
grant execute on function
    validate.register_schema(text, jsonb, text),
    validate.unregister_schema(text)
to js_admin, js_admin2;
grant insert, update, delete on validate.schemas to js_admin, js_admin2;

select tap.plan(48);

-- register, use, list
select tap.lives_ok($$
    select validate.register_schema(
        name => 'product',
        schema => '{
            "type": "object",
            "required": ["name", "price"],
            "properties": {
                "name": {"type": "string", "minLength": 1},
                "price": {"$ref": "#/$defs/money"},
                "email": {"format": "email"}
            },
            "$defs": {"money": {"type": "number", "exclusiveMinimum": 0}}
        }',
        description => 'A product'
    ) $$, 'register a schema');
select tap.is(validate.json_schema_named(doc => '{"name": "a", "price": 1}', name => 'product'), true, 'a valid document');
select tap.is(validate.json_schema_named(doc => '{"name": "a", "price": 0}', name => 'product'), false, 'an invalid document');
select tap.is(validate.json_schema_named(doc => '{"name": "a", "price": 1, "email": "x"}', name => 'product'), false,
              'format through the registry');
select tap.is(validate.json_schema_named(doc => null, name => 'product'), null, 'STRICT: null document');
select tap.is(validate.json_schema_named(doc => '{}', name => null), null, 'STRICT: null name');
select tap.is(
    (select array_agg(e::text order by e::text) from validate.json_schema_named_errors('{"name": "", "price": -1}', 'product') e),
    (select array_agg(e::text order by e::text)
     from validate.json_schema_errors('{"name": "", "price": -1}', (select schema from validate.schemas where name = 'product')) e),
    'json_schema_named_errors returns what json_schema_errors returns for the same schema');
select tap.is(
    (select row(l.description, l.owner, l.schema -> 'required')::text from validate.list_schemas() l where l.name = 'product'),
    row('A product', current_user::name, '["name", "price"]'::jsonb)::text,
    'list_schemas() shows the schema, its description and owner');
select tap.ok((select compiled -> 'root' = schema from validate.schemas where name = 'product'),
              'the compiled form holds the schema');

-- the named path agrees with json_schema on schemas with embedded resources and anchors
select validate.register_schema(name => 'tree', schema => '{
    "$id": "https://example.com/tree",
    "$dynamicAnchor": "node",
    "type": "object",
    "properties": {"data": true, "children": {"type": "array", "items": {"$dynamicRef": "#node"}}},
    "$defs": {"leaf": {"$id": "leaf", "$anchor": "leaf", "type": "integer"}}
}');
select tap.is(
    (select array_agg(validate.json_schema_named(d, 'tree') order by n)
     from unnest(array['{"children": [{"children": []}]}', '{"children": [1]}', '{"data": 1}']::jsonb[]) with ordinality u(d, n)),
    (select array_agg(validate.json_schema(d, (select schema from validate.schemas where name = 'tree')) order by n)
     from unnest(array['{"children": [{"children": []}]}', '{"children": [1]}', '{"data": 1}']::jsonb[]) with ordinality u(d, n)),
    'json_schema_named agrees with json_schema on $id, $anchor and $dynamicRef');

-- overload resolution: there is no json_schema(jsonb, text)
select tap.is(to_regprocedure('validate.json_schema(jsonb, text)'), null, 'no json_schema(jsonb, text) overload');
select tap.is(validate.json_schema('{"a": 1}', '{"type": "object"}'), true,
              'an untyped literal still resolves to json_schema(jsonb, jsonb)');
select tap.is(validate.json_schema_named('{"name": "a", "price": 2}', 'product'), true,
              'json_schema_named takes untyped literals');
select tap.throws_ok($$ select validate.json_schema('{}', 'product') $$, '22P02',
                     'json_schema(doc, ''name'') is a jsonb literal, not a name: invalid JSON');

-- errors
select tap.throws_ok($$ select validate.json_schema_named('{}', 'nope') $$, '42704', 'an unknown name raises');
select tap.throws_ok($$ select * from validate.json_schema_named_errors('{}', 'nope') $$, '42704', 'also for json_schema_named_errors');
select tap.throws_ok($$ select validate.register_schema('product', '{}') $$, '42710', 'a registered name raises');
select tap.throws_ok($$ select validate.register_schema('1abc', '{}') $$, '22023', 'an invalid name raises');
select tap.throws_ok($$ select validate.register_schema(null, '{}') $$, '22004', 'a null name raises');
select tap.throws_ok($$ select validate.unregister_schema('nope') $$, '42704', 'unregistering an unknown name raises');

-- schemas are checked when registered
select tap.throws_ok($$ select validate.register_schema('bad', '1') $$, '22023', 'a root that is not a schema');
select tap.throws_ok($$ select validate.register_schema('bad', '{"items": 5}') $$, '22023', 'a subschema that is not a schema');
select tap.throws_ok($$ select validate.register_schema('bad', '{"properties": {"a": {"$ref": "https://example.com/x"}}}') $$, '0A000',
                     'a remote $ref');
select tap.throws_ok($$ select validate.register_schema('bad', '{"$ref": "https://json-schema.org/draft/2020-12/schema"}') $$, '0A000',
                     'a $ref to the metaschema');
select tap.throws_ok($$ select validate.register_schema('bad', '{"anyOf": [{"$ref": "#/$defs/missing"}]}') $$, '22023',
                     'a $ref whose target is missing, even in a branch that a document may never reach');
select tap.throws_ok($$ select validate.register_schema('bad', '{"$dynamicRef": "#nope"}') $$, '22023', 'a $dynamicRef to a missing anchor');
select tap.throws_ok($$ select validate.register_schema('bad', '{"pattern": "(a"}') $$, '2201B', 'a pattern Postgres cannot compile');
select tap.throws_ok($$ select validate.register_schema('bad', '{"patternProperties": {"\\p{L}": true}}') $$, '0A000',
                     'a \p{...} escape in a patternProperties key');
select tap.throws_ok($$ select validate.register_schema('bad', '{"properties": {"a": {"format": "no-such-format"}}}') $$, '42704',
                     'an unknown format');
select tap.is((select count(*)::int from validate.schemas where name = 'bad'), 0, 'nothing bad was registered');

-- direct DML goes through the same checks, and changes recompile
select tap.throws_ok($$ insert into validate.schemas (name, schema) values ('bad', '{"$ref": "#/nope"}') $$, '22023',
                     'a direct insert is checked');
select tap.lives_ok($$ update validate.schemas set schema = '{"type": "string"}' where name = 'tree' $$,
                    'a direct update of the schema');
select tap.is(validate.json_schema_named('"s"', 'tree'), true, 'and the compiled form follows it');
select tap.throws_ok($$ truncate validate.schemas $$, '42501', 'the registry cannot be truncated');

-- a CHECK constraint is not rechecked when the schema changes
create table docs (body jsonb check (validate.json_schema_named(body, 'product')));
select tap.lives_ok($$ insert into docs values ('{"name": "a", "price": 1}') $$, 'a valid row');
select tap.throws_ok($$ insert into docs values ('{"name": "a"}') $$, '23514', 'an invalid row is rejected');
select validate.unregister_schema('product');
select validate.register_schema(name => 'product', schema => '{"required": ["sku"]}');
select tap.is((select count(*)::int from docs), 1, 'existing rows stay after the schema changes');
select tap.throws_ok($$ insert into docs values ('{"name": "a", "price": 1}') $$, '23514', 'new rows follow the new schema');
drop table docs;

-- permissions: clients read and validate, but cannot register
set role js_user;
select tap.is(validate.json_schema_named('{"sku": 1}', 'product'), true, 'an unprivileged role can validate');
select tap.ok((select count(*) from validate.list_schemas()) >= 1, 'an unprivileged role can list schemas');
select tap.throws_ok($$ select validate.register_schema('mine', '{}') $$, '42501', 'an unprivileged role cannot register');
select tap.throws_ok($$ insert into validate.schemas (name, schema) values ('mine', '{}') $$, '42501',
                     'an unprivileged role cannot insert into the registry');
reset role;

-- ownership: a granted role owns its entries
set role js_admin;
select tap.lives_ok($$ select validate.register_schema('admin-doc', '{"type": "object"}') $$, 'a granted role registers');
reset role;
select tap.is((select owner::text from validate.schemas where name = 'admin-doc'), 'js_admin', 'and owns the entry');
set role js_admin2;
select tap.throws_ok($$ select validate.unregister_schema('admin-doc') $$, '42501', 'another role cannot unregister it');
select tap.throws_ok($$ update validate.schemas set schema = 'true' where name = 'admin-doc' $$, '42501',
                     'or change it by direct DML');
select tap.throws_ok($$ insert into validate.schemas (name, schema, owner) values ('fake', '{}', 'js_admin') $$, '42501',
                     'or register on behalf of the owner');
reset role;
grant js_admin to js_admin2;
set role js_admin2;
select tap.lives_ok($$ select validate.unregister_schema('admin-doc') $$, 'a member of the owner role can unregister it');
reset role;

select * from tap.finish();

drop owned by js_admin, js_admin2, js_user;
drop role js_admin2, js_admin, js_user;
