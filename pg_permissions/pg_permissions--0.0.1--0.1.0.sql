/*
 * pg_permissions: upgrade 0.0.1 to 0.1.0
 *
 * Copyright (c) 2026 Paul Copplestone: https://github.com/kiwicopple/pg-extensions/
 *
 * Run on a database that has pg_permissions--0.0.1.sql installed. Afterwards
 * the schema matches a fresh install of pg_permissions--0.1.0.sql:
 * test/spec/d/05_upgrade.sql compares every function (signature, body,
 * settings, privileges) and every table, column and index.
 *
 *   pg_tle:   select pgtle.install_update_path('pg_permissions', '0.0.1', '0.1.0', <this file>);
 *             alter extension pg_permissions update to '0.1.0';
 *   plain:    psql -v ON_ERROR_STOP=1 -1 -f pg_permissions--0.0.1--0.1.0.sql
 *
 * No psql meta-commands: pg_tle runs this file as an extension script.
 * Changes are listed in the order of the 0.1.0 work (research/plan-cedar.md).
 */

-- Nothing yet: the 0.1.0 changes are added here as they land.
select 1 where false;
