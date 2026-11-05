# Named JSON schemas

Register a JSON Schema once under a name, then validate `jsonb` documents against the name: in queries, and in `CHECK` constraints that stay short and keep working when the schema changes.

Prerequisites: the extension is installed, and you run the registration steps as the extension owner or as a role allowed to register schemas (see [Who can register schemas](../registry.md#named-json-schemas)). Validating against a registered schema needs no privileges. The examples create a table `catalog_items`.

## Register a schema

```sql
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
```

`register_schema` checks the schema before it stores it, so that problems surface now rather than at the first insert. It raises an error for:

- a value that is not an object or a boolean where a schema belongs (`22023`);
- a `$ref` or `$dynamicRef` to another document (`0A000`), or to a location that does not exist in this one (`22023`), in any branch;
- a `pattern` or `patternProperties` key that Postgres cannot run (`2201B`, or `0A000` for `\p{...}`);
- a `format` that is not in the [format registry](../registry.md) (`42704`).

It does not check keyword values against the metaschema: `{"minLength": "two"}` registers, as it would run in [`json_schema`](../json-schema.md). The schema is stored with its evaluation context, so [`json_schema_named`](../json-schema.md#json_schema_named-and-json_schema_named_errors) skips the indexing that `json_schema` does on every call.

## Validate documents

```sql
select validate.json_schema_named(
  doc => '{"name": "Lamp", "price": 19.99}',
  name => 'product'
);
-- true

select keyword_location, keyword
from validate.json_schema_named_errors(
  doc => '{"name": "Lamp", "price": 0}',
  name => 'product'
);
-- /properties/price/$ref/exclusiveMinimum | exclusiveMinimum
```

A name that is not registered raises `42704`.

## Use the schema in a constraint

```sql
create table catalog_items (
  id bigint generated always as identity primary key,
  doc jsonb not null
);
```

Before you add the constraint, note how `pg_dump` orders a backup: it restores the rows of your tables before the rows of `validate.schemas`. A constraint created the usual way is part of the table, so during a restore it runs before the schema exists, and every row fails. Add the constraint `NOT VALID` instead. `pg_dump` then creates it after the data, and Postgres still checks every row that is inserted or updated:

```sql
alter table catalog_items
  add constraint catalog_items_doc_is_product
  check (validate.json_schema_named(doc, 'product'))
  not valid;
```

Do not run `alter table ... validate constraint` on it: a validated constraint is dumped as part of the table again. `NOT VALID` only means that rows which were in the table before the constraint was added have not been checked. To check them, query them:

```sql
select id
from catalog_items
where not validate.json_schema_named(doc, 'product');
```

New rows are checked:

```sql
insert into catalog_items (doc)
values ('{"name": "Lamp", "price": 19.99, "tags": ["home"]}');

insert into catalog_items (doc)
values ('{"name": "Lamp"}');
-- ERROR:  new row for relation "catalog_items" violates check constraint "catalog_items_doc_is_product"
```

The same restore order applies to [custom formats](../registry.md#formats-in-check-constraints) in constraints, and to a schema in an inline [`json_schema`](../json-schema.md) constraint that uses a custom format.

## Change a schema

Update the row in `validate.schemas`. A trigger checks the new schema as `register_schema` does and replaces the stored context in the same statement, so there is no moment when the name is missing:

```sql
update validate.schemas
set schema = jsonb_set(schema, '{properties,sku}', '{"type": "string"}')
where name = 'product';
```

Postgres checks a constraint only when a row is written. After the update, existing rows are not rechecked; new and updated rows follow the new schema. Run the query from the previous section to find rows that the new schema rejects.

To remove a schema, call `validate.unregister_schema(name => 'product')`. Constraints that use the name then fail on every insert and update with `42704`, so drop them first.

## Named or inline

| | `json_schema(doc, schema)` | `json_schema_named(doc, name)` |
| --- | --- | --- |
| Where the schema lives | In the constraint or query | In `validate.schemas` |
| When the schema is checked | When a document reaches each part | When it is registered or changed |
| Changing the schema | `alter table` to replace the constraint | `update validate.schemas`; existing rows are not rechecked |
| Cost per document | Indexes schemas with anchors or embedded `$id` resources on every call | Reads the stored context; see [Performance](../json-schema.md#performance) |
| Backups | Restores with the table | Needs the constraint `NOT VALID` (above) |

Both are `STABLE`, so neither can be used in an index or a generated column.
