-- Goal: the examples in docs/guides/named-schemas.md run as written and give
-- their documented results. Keep them in step.
select tap.plan(11);

select tap.lives_ok($$
select validate.register_schema(
  name => 'product',
  schema => '{
    "type": "object",
    "required": ["name", "price"],
    "properties": {
      "name": {"type": "string", "minLength": 1},
      "price": {"$ref": "#/$defs/money"},
      "tags": {"type": "array", "items": {"type": "string"}}
    },
    "$defs": {
      "money": {"type": "number", "exclusiveMinimum": 0}
    }
  }',
  description => 'A product in the catalog'
);
$$, 'named-schemas: register product');
select tap.lives_ok($$ select validate.register_schema(name => 'loose', schema => '{"minLength": "two"}') $$,
                    'named-schemas: keyword values are not checked against the metaschema');

select tap.is(validate.json_schema_named(
  doc => '{"name": "Lamp", "price": 19.99}',
  name => 'product'
), true, 'named-schemas: a valid document');
select tap.is(
    (select array_agg(row(keyword_location, keyword)::text)
     from validate.json_schema_named_errors(
  doc => '{"name": "Lamp", "price": 0}',
  name => 'product'
)),
    array[row('/properties/price/$ref/exclusiveMinimum', 'exclusiveMinimum')::text],
    'named-schemas: the json_schema_named_errors example');

select tap.lives_ok($$
create table catalog_items (
  id bigint generated always as identity primary key,
  doc jsonb not null
);
$$, 'named-schemas: create catalog_items');
select tap.lives_ok($$
alter table catalog_items
  add constraint catalog_items_doc_is_product
  check (validate.json_schema_named(doc, 'product'))
  not valid;
$$, 'named-schemas: add the constraint not valid');
select tap.lives_ok($$
insert into catalog_items (doc)
values ('{"name": "Lamp", "price": 19.99, "tags": ["home"]}');
$$, 'named-schemas: a valid row');
select tap.throws_ok($$
insert into catalog_items (doc)
values ('{"name": "Lamp"}');
$$, '23514', 'named-schemas: an invalid row fails the constraint');
select tap.is(
    (select count(*)::int
from catalog_items
where not validate.json_schema_named(doc, 'product')),
    0, 'named-schemas: the query for unchecked rows');

select tap.lives_ok($$
update validate.schemas
set schema = jsonb_set(schema, '{properties,sku}', '{"type": "string"}')
where name = 'product';
$$, 'named-schemas: change the schema');
select tap.is(validate.json_schema_named('{"name": "Lamp", "price": 1, "sku": 1}', 'product'), false,
              'named-schemas: the changed schema applies at once');

select * from tap.finish();
