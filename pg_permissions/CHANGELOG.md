# Changelog

## Extension 0.1.0

Cedar joins RBAC and OpenFGA in the `permissions` schema. You can store Cedar policies, templates and entities, check a request, or list resources a subject can access. JavaScript client 0.3.0 adds the corresponding `cedar` methods and the `uid()` helper. See the [client changelog](js/CHANGELOG.md) for package changes.

The [correctness review](research/security/2026-11-04-CORRECTNESS.md) records changes to OpenFGA exclusions, Cedar template refreshes and CEL evaluation during 0.1.0 development. Earlier builds passed `matches` patterns directly to Postgres. If you used Postgres-specific regex syntax, check those conditions against the [supported CEL patterns](docs/reference/cel.md#cel-subset).

### Upgrade from 0.0.1

Upgrade even if your application uses only RBAC or OpenFGA. In 0.0.1 a database role with temporary-object privileges could create a type that an extension function resolved through the caller's temporary schema and execute code as the extension owner. Version 0.1.0 fixes the search path, pins string parsing in owner-executed functions, and checks ownership and write access before installing into an existing schema.

Run the [upgrade script](pg_permissions--0.0.1--0.1.0.sql) once as the role that owns the extension. It preserves existing roles, models and tuples. For a plain SQL install, run this from the extension directory:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -1 \
  -f pg_permissions--0.0.1--0.1.0.sql
```

For a pg_tle install, run the following commands in psql as the extension owner with `pgtle_admin`. They register the update path, apply it to this database and set the default for future installs.

```sql
\set body `cat pg_permissions--0.0.1--0.1.0.sql`
select pgtle.install_update_path(
  'pg_permissions',
  '0.0.1',
  '0.1.0',
  :'body'
);
alter extension pg_permissions update to '0.1.0';
select pgtle.set_default_version(
  'pg_permissions',
  '0.1.0'
);
```

`set_default_version` makes a later `create extension pg_permissions` without a version, for example in a restore, install 0.1.0 instead of 0.0.1. The update itself does not need it.

## Extension 0.0.1

Introduced application and tenant roles with RBAC, and object relationships with the OpenFGA model.
