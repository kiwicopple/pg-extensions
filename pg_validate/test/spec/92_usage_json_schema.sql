-- Goal: the examples in docs/json-schema.md run as written and give their
-- documented results. Keep them in step.
select tap.plan(9);

select tap.lives_ok($$
create table products (
  id bigint generated always as identity primary key,
  doc jsonb not null
    constraint products_doc_is_valid
    check (validate.json_schema(doc, '{
      "type": "object",
      "required": ["name", "price"],
      "properties": {
        "name": {"type": "string", "minLength": 1},
        "price": {"type": "number", "exclusiveMinimum": 0},
        "tags": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}
      },
      "additionalProperties": false
    }'))
);
$$, 'json-schema: create the products table');
select tap.lives_ok($$ insert into products (doc) values ('{"name": "Lamp", "price": 19.99, "tags": ["home"]}') $$,
                    'json-schema: a valid document inserts');
select tap.throws_ok($$ insert into products (doc) values ('{"name": "Lamp", "price": 0}') $$, '23514',
                     'json-schema: an invalid document fails the constraint');

select tap.is(
    (select array_agg(row(instance_location, keyword_location, keyword)::text order by instance_location)
     from validate.json_schema_errors(
  doc => '{"name": "", "price": -1}',
  schema => '{
    "type": "object",
    "required": ["name", "price"],
    "properties": {
      "name": {"type": "string", "minLength": 1},
      "price": {"type": "number", "exclusiveMinimum": 0}
    }
  }'
)),
    array[row('/name', '/properties/name/minLength', 'minLength')::text,
          row('/price', '/properties/price/exclusiveMinimum', 'exclusiveMinimum')::text],
    'json-schema: the json_schema_errors example');

select tap.lives_ok($$
create function public.product_sku(value text)
returns boolean
language sql
immutable
strict
as $f$
  select value ~ '^[A-Z]{3}-[0-9]{4}$'
$f$;
$$, 'json-schema: product_sku');
select tap.lives_ok($$
select validate.register_format(
  name => 'product-sku',
  validator => 'public.product_sku(text)',
  description => 'Product SKU such as ABC-1234'
);
$$, 'json-schema: register product-sku');
select tap.is(validate.json_schema(
  doc => '{"sku": "ABC-1234"}',
  schema => '{"properties": {"sku": {"format": "product-sku"}}}'
), true, 'json-schema: product-sku valid');
select tap.is(validate.json_schema(
  doc => '{"sku": "abc"}',
  schema => '{"properties": {"sku": {"format": "product-sku"}}}'
), false, 'json-schema: product-sku invalid');
select tap.is(validate.json_schema('0.30', '{"multipleOf": 0.01}'), true,
              'json-schema: multipleOf is exact on decimals');

select * from tap.finish();
