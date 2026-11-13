# pg_idkit

UUID and KSUID generators and timestamp utilities for Postgres, written in SQL and PL/pgSQL. No pgcrypto or compiled extension is required. This is a PL/pgSQL port inspired by the [Rust pg_idkit project](https://github.com/VADOSWARE/pg_idkit).

## Get started

Read the [overview](docs/overview.md), [install](docs/install.md), then follow the [quickstart](docs/get-started/quickstart.md). The [documentation map](docs/README.md) lists every guide and reference page.

```sql
-- After installing into the extensions schema:
select extensions.gen_random_uuid_v7();
```

Version 0.0.4 exposes four generators and one timestamp extractor. IDs use Postgres `random()` and are not secrets. Keep a primary key or unique constraint, and use an explicit creation timestamp when exact time matters. See [errors and limits](docs/errors-and-limits.md).

## Documentation site

The documentation site is configured for [id.postgres.tools](https://id.postgres.tools). It follows the same Astro + Starlight pattern as the other extensions. From this directory:

```bash
npm run docs:install
npm run docs:dev
npm run docs:build
```

See [site maintenance](site/README.md) for navigation, exports and build checks.

## Credits

Most of the generator implementation comes from Fabio Lima's work, credited in the [SQL source](pg_idkit--0.0.4.sql). The original package listing is [kiwicopple/pg_idkit on database.dev](https://database.dev/kiwicopple/pg_idkit).
