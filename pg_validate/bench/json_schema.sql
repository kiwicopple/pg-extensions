-- JSON Schema benchmark: per-document cost of validate.json_schema() for
-- four representative schemas. Run with bench/run.sh, which installs the
-- extension into a scratch database first.
--
--   psql -v n=20000 -f bench/json_schema.sql
--
-- Each case validates :n generated documents (about one in ten invalid)
-- three times and reports the best run in microseconds per document. With
-- named schemas available, it also times validate.json_schema(doc, name)
-- against the same schema registered by name.
\set ON_ERROR_STOP 1
\if :{?n}
\else
\set n 20000
\endif

create temp table bench_case (
    name   text primary key,
    ord    int,
    schema jsonb
);

insert into bench_case values
('trivial', 1, '{"type": "object", "required": ["id"]}'),
('nested', 2, '{
  "type": "object",
  "required": ["id", "email", "name", "address"],
  "properties": {
    "id": {"type": "integer", "minimum": 1},
    "email": {"type": "string", "format": "email"},
    "name": {"type": "string", "minLength": 1, "maxLength": 100},
    "sku": {"type": "string", "pattern": "^[A-Z]{3}-[0-9]{4}$"},
    "address": {
      "type": "object",
      "required": ["street", "city"],
      "properties": {
        "street": {"type": "string"},
        "city": {"type": "string"},
        "zip": {"type": "string", "pattern": "^[0-9]{5}$"}
      },
      "additionalProperties": false
    },
    "tags": {"type": "array", "items": {"type": "string"}, "uniqueItems": true, "maxItems": 10}
  },
  "additionalProperties": false
}'),
('refs', 3, '{
  "$id": "https://example.com/order.json",
  "type": "object",
  "required": ["customer", "lines"],
  "properties": {
    "customer": {"$ref": "#/$defs/person"},
    "shipTo": {"$ref": "#/$defs/address"},
    "lines": {"type": "array", "minItems": 1, "items": {"$ref": "#/$defs/line"}}
  },
  "$defs": {
    "person": {
      "type": "object",
      "required": ["name", "address"],
      "properties": {"name": {"type": "string"}, "address": {"$ref": "#/$defs/address"}}
    },
    "address": {
      "type": "object",
      "required": ["street", "city"],
      "properties": {"street": {"type": "string"}, "city": {"type": "string"}}
    },
    "line": {
      "type": "object",
      "required": ["sku", "qty"],
      "properties": {"sku": {"type": "string"}, "qty": {"$ref": "#/$defs/qty"}}
    },
    "qty": {"type": "integer", "minimum": 1}
  }
}'),
('anchors', 4, '{
  "type": "object",
  "required": ["customer", "lines"],
  "properties": {
    "customer": {"$ref": "#person"},
    "lines": {"type": "array", "items": {"$ref": "#line"}}
  },
  "$defs": {
    "person": {"$anchor": "person", "type": "object", "required": ["name"],
               "properties": {"name": {"type": "string"}, "address": {"$ref": "#address"}}},
    "address": {"$anchor": "address", "type": "object", "required": ["city"],
                "properties": {"city": {"type": "string"}}},
    "line": {"$anchor": "line", "type": "object", "required": ["qty"],
             "properties": {"qty": {"type": "integer", "minimum": 1}}}
  }
}'),
('unevaluated', 5, '{
  "type": "object",
  "allOf": [
    {"properties": {"id": {"type": "integer"}, "kind": {"enum": ["a", "b"]}}, "required": ["id"]},
    {"if": {"properties": {"kind": {"const": "a"}}},
     "then": {"properties": {"a": {"type": "string"}}},
     "else": {"properties": {"b": {"type": "number"}}}}
  ],
  "properties": {"note": {"type": "string"}},
  "unevaluatedProperties": false
}');

create temp table bench_doc (name text, i int, doc jsonb);

insert into bench_doc
select 'trivial', i, case when i % 10 = 0 then jsonb_build_object('x', i) else jsonb_build_object('id', i) end
from generate_series(1, :n) i;

insert into bench_doc
select 'nested', i, jsonb_build_object(
    'id', i,
    'email', case when i % 10 = 0 then 'not an email' else 'user' || i || '@example.com' end,
    'name', 'User ' || i,
    'sku', 'ABC-' || lpad((i % 10000)::text, 4, '0'),
    'address', jsonb_build_object('street', i || ' Main St', 'city', 'Springfield', 'zip', '12345'),
    'tags', jsonb_build_array('a', 'b', 'c' || (i % 7)))
from generate_series(1, :n) i;

insert into bench_doc
select 'refs', i, jsonb_build_object(
    'customer', jsonb_build_object('name', 'C' || i, 'address', jsonb_build_object('street', 's', 'city', 'c')),
    'shipTo', jsonb_build_object('street', 's', 'city', 'c'),
    'lines', jsonb_build_array(
        jsonb_build_object('sku', 'A', 'qty', 1),
        jsonb_build_object('sku', 'B', 'qty', case when i % 10 = 0 then 0 else 2 end),
        jsonb_build_object('sku', 'C', 'qty', 3)))
from generate_series(1, :n) i;

insert into bench_doc
select 'anchors', i, jsonb_build_object(
    'customer', jsonb_build_object('name', 'C' || i, 'address', jsonb_build_object('city', 'c')),
    'lines', jsonb_build_array(
        jsonb_build_object('qty', 1),
        jsonb_build_object('qty', case when i % 10 = 0 then 0 else 2 end)))
from generate_series(1, :n) i;

insert into bench_doc
select 'unevaluated', i, jsonb_build_object('id', i, 'kind', case when i % 2 = 0 then 'a' else 'b' end, 'note', 'n')
       || case when i % 2 = 0 then jsonb_build_object('a', 'x') else jsonb_build_object('b', 1) end
       || case when i % 10 = 0 then jsonb_build_object('extra', true) else '{}' end
from generate_series(1, :n) i;

analyze bench_doc;

-- Best of three runs, microseconds per document.
create function pg_temp.bench(stmt text, rows int)
returns numeric
language plpgsql
as $$
declare
    t0   timestamptz;
    best numeric;
    el   numeric;
begin
    for k in 1 .. 3 loop
        t0 := clock_timestamp();
        execute stmt;
        el := extract(epoch from clock_timestamp() - t0) * 1e6 / rows;
        best := least(best, el);
    end loop;
    return round(best, 1);
end;
$$;

select exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
               where s.nspname = 'validate' and p.proname = 'register_schema') as has_named
\gset

\if :has_named
select validate.register_schema(name => 'bench_' || name, schema => schema) from bench_case;
\endif

create temp table bench_result (ord int, schema text, valid_docs int, adhoc_us numeric, named_us numeric);

-- One statement per case, so each case runs in its own query.
select format($q$insert into bench_result select %s, %L,
    (select count(*) filter (where validate.json_schema(d.doc, %L::jsonb)) from bench_doc d where d.name = %L),
    pg_temp.bench(%L, %s),
    %s$q$,
    c.ord, c.name, c.schema, c.name,
    format('select count(*) filter (where validate.json_schema(d.doc, %L::jsonb)) from bench_doc d where d.name = %L', c.schema, c.name),
    :n,
    case when :'has_named' then format('pg_temp.bench(%L, %s)',
        format('select count(*) filter (where validate.json_schema_named(d.doc, %L)) from bench_doc d where d.name = %L', 'bench_' || c.name, c.name),
        :n) else 'null' end)
from bench_case c
order by c.ord
\gexec

select schema, valid_docs, adhoc_us, named_us
from bench_result
order by ord;
