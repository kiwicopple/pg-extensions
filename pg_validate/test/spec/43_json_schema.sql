-- Goal: validate.json_schema() behaviour beyond the official suite: format
-- dispatch through the registry (built-ins, aliases, registered formats with
-- the caller's privileges), unknown formats and remote references raise, the
-- depth guard stops reference cycles, pattern translation, the shape of
-- json_schema_errors(), and null handling.
create schema app;
create function app.product_sku(value text) returns boolean language sql immutable strict
as $$ select value ~ '^[A-Z]{3}-[0-9]{4}$' $$;

create table app.allowed (code text);
insert into app.allowed values ('ok');
revoke all on app.allowed from public;
create function app.allowed_code(value text) returns boolean language sql stable strict
as $$ select exists (select 1 from app.allowed where code = value) $$;
select validate.register_format(name => 'allowed-code', validator => 'app.allowed_code(text)');

select tap.plan(30);

-- format through the registry
select tap.is(validate.json_schema('"ada@example.com"', '{"format": "email"}'), true, 'format email: valid');
select tap.is(validate.json_schema('"ada@"', '{"format": "email"}'), false, 'format email: invalid');
select tap.is(validate.json_schema('"2026-02-29T00:00:00Z"', '{"format": "date-time"}'), false, 'format date-time is validate.rfc3339 (not a leap year)');
select tap.is(validate.json_schema('"/a~1b"', '{"format": "json-pointer"}'), true, 'format json-pointer alias');
select tap.is(validate.json_schema('"GB82WEST12345698765432"', '{"format": "iban"}'), true, 'any built-in registry name is a format');
select tap.is(validate.json_schema('12', '{"format": "no-such-format"}'), true, 'format ignores non-strings, even when unknown');
select tap.throws_ok($$ select validate.json_schema('"x"', '{"format": "no-such-format"}') $$, '42704',
                     'an unknown format raises when a string reaches it');
select tap.throws_ok($$ select validate.json_schema('"x"', '{"format": "idn-email"}') $$, '42704',
                     'a JSON Schema format without a validator raises');

select tap.lives_ok($$ select validate.register_format(name => 'product-sku', validator => 'app.product_sku(text)') $$,
                    'register product-sku');
select tap.is(validate.json_schema('{"sku": "ABC-1234"}', '{"properties": {"sku": {"format": "product-sku"}}}'), true,
              'a registered format works in a schema: valid');
select tap.is(validate.json_schema('{"sku": "abc"}', '{"properties": {"sku": {"format": "product-sku"}}}'), false,
              'a registered format works in a schema: invalid');
select tap.is(validate.json_schema('"ok"', '{"format": "allowed-code"}'), true, 'a custom validator that reads a table works for its owner');
set role authenticated;
select tap.throws_ok($$ select validate.json_schema('"ok"', '{"format": "allowed-code"}') $$, '42501',
                     'and runs with the caller''s privileges: a client cannot read the table');
reset role;

-- references
select tap.throws_ok($$ select validate.json_schema('1', '{"$ref": "https://example.com/other.json"}') $$, '0A000',
                     'a remote $ref raises');
select tap.throws_ok($$ select validate.json_schema('1', '{"$ref": "https://json-schema.org/draft/2020-12/schema"}') $$, '0A000',
                     'a $ref to the metaschema raises (not fetched)');
select tap.throws_ok($$ select validate.json_schema('1', '{"$ref": "#/$defs/missing"}') $$, '22023',
                     'a $ref to a missing location raises');
select tap.is(validate.json_schema('{"next": {"next": {"value": 1}}}',
    '{"$defs": {"node": {"type": "object", "properties": {"value": {"type": "integer"}, "next": {"$ref": "#/$defs/node"}}}}, "$ref": "#/$defs/node"}'),
    true, 'a recursive schema works');
select tap.throws_ok($$ select validate.json_schema('1', '{"$defs": {"a": {"$ref": "#/$defs/b"}, "b": {"$ref": "#/$defs/a"}}, "$ref": "#/$defs/a"}') $$,
                     '54001', 'a $ref cycle that never consumes the instance hits the depth guard');
select tap.is(validate.json_schema('"x"', '{"$id": "https://example.com/root", "$defs": {"s": {"$id": "str", "type": "string"}}, "$ref": "str"}'),
              true, 'a $ref to an embedded $id resource');

-- patterns
select tap.is(validate.json_schema('"১২"', '{"pattern": "^\\d+$"}'), false, 'pattern \d matches ASCII digits only (ECMA-262)');
select tap.is(validate.json_schema('"a b"', '{"pattern": "^[\\w\\s]+$"}'), true, 'pattern \w and \s inside brackets');
select tap.throws_ok($$ select validate.json_schema('"a"', '{"pattern": "\\p{L}"}') $$, '0A000', 'a \p{...} escape raises');

-- errors
select tap.is(
    (select array_agg(row(instance_location, keyword_location, keyword)::text order by instance_location)
     from validate.json_schema_errors(
       '{"name": "", "price": -1}',
       '{"type": "object", "required": ["name", "price"], "properties": {"name": {"type": "string", "minLength": 1}, "price": {"type": "number", "exclusiveMinimum": 0}}}')),
    array[row('/name', '/properties/name/minLength', 'minLength')::text,
          row('/price', '/properties/price/exclusiveMinimum', 'exclusiveMinimum')::text],
    'json_schema_errors reports every error with its locations');
select tap.is(
    (select count(*)::int from validate.json_schema_errors('{"a": 1}', '{"properties": {"a": {"type": "integer"}}}')),
    0, 'json_schema_errors returns no rows for a valid document');
select tap.is(
    (select keyword_location from validate.json_schema_errors('{"a": "x"}',
        '{"$defs": {"int": {"type": "integer"}}, "properties": {"a": {"$ref": "#/$defs/int"}}}')),
    '/properties/a/$ref/type', 'the keyword location follows $ref');
select tap.is(
    (select string_agg(keyword, ',' order by keyword_location) from validate.json_schema_errors('"x"', '{"anyOf": [{"type": "integer"}, {"minLength": 2}]}')),
    'anyOf,type,minLength', 'a failed anyOf reports the keyword and each branch');
select tap.is(
    (select keyword from validate.json_schema_errors('{"a": "x"}', '{"properties": {"a": {"format": "email"}}}')),
    'format', 'a failed format is reported as format');

-- nulls and JSON null
select tap.is(validate.json_schema(null, '{}'), null, 'a SQL null document gives null');
select tap.is(validate.json_schema('null', '{"type": "null"}'), true, 'JSON null is a document');
select tap.is(validate.json_schema('1', 'false'), false, 'the false schema rejects everything');

select * from tap.finish();
