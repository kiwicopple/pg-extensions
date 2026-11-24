# ID kit tests

This suite is independent of the other extensions. It owns its Docker image, installation setup, fixtures, and SQL tests. Production ID kit does not depend on pgTAP or pg_tle; they are test dependencies.

## Run the suite

From `pg_idkit/`, with Docker running:

```bash
npm test
```

This builds cached `pg-idkit-test` images and runs Postgres 16, 17, and 18. Postgres base-image versions, pg_tle v1.5.3, and pgTAP v1.3.4 are specified in `test/docker.sh` and `test/docker/Dockerfile`. Development headers are pinned to the base image's exact Postgres package version using the PGDG archive. The image installs the distribution's `pg_prove` package, and `versions.log` records the runtime versions. Builds require network access on the first run and are not fully hermetic: base-image tags and distribution package repositories can change.

Narrow a run while developing:

```bash
# All installation modes on one Postgres version.
./test/docker.sh 18

# Only the public API contracts after a native extension upgrade.
./test/docker.sh 18 -- --mode upgrade --filter contract

# Test the test runner's failure handling.
./test/docker.sh 18 -- --self-test

# Include ID kit's oldest supported Postgres version.
./test/docker.sh 13
```

Unknown modes, unmatched filters, missing dependencies, SQL failures, and unexpected skips fail the run. The Docker matrix continues to the remaining versions after a failure and exits unsuccessfully if any version failed.

## Installation modes

Every selected SQL spec runs against each selected mode:

| Mode | Setup |
| --- | --- |
| `plain` | Load the current SQL file as an ordinary role |
| `native` | Install the current version with `create extension` |
| `upgrade` | Install 0.0.4, create existing data and a column default, and upgrade to the current version |
| `tle` | Register and install the current version through pg_tle |
| `tle-upgrade` | Register both versions and the update path, install 0.0.4, and upgrade through pg_tle |

The current version comes from `pg_idkit.control`. The upgrade baseline is explicitly 0.0.4. When releasing another version, update the baseline or provide the corresponding upgrade script deliberately.

All five modes install into `ids`, owned by a non-superuser. TLE registration is performed by the test administrator, while extension installation and upgrades run as the ordinary owner. TLE uses the name `pg_idkit_tle` because pg_tle cannot register an extension with the same name as a control file already on disk.

## Isolation and diagnostics

`run.sh` starts a new temporary cluster with a Unix socket and no TCP listener. It ignores inherited connection settings and never connects to an existing database. Each mode gets its own installation database, each spec gets a fresh clone, and each SQL spec rolls back its changes. Roles remain cluster-wide, so tests that alter shared roles or server settings need additional isolation before they can run concurrently. The current runner is sequential.

The cluster and containers are removed after execution. Build output, server logs, installation logs, per-spec TAP reports, and runner self-test diagnostics remain under `test/.results/`, which is ignored by Git. The runner prints their location. Interruptions stop the local cluster; an externally killed Docker process may prevent copying container logs back to the host.

## Layout

```text
test/
  docker/Dockerfile       ID kit's own Postgres, pg_tle, and pgTAP image
  docker.sh               version matrix and container lifecycle
  run.sh                  disposable cluster, install modes, and spec selection
  setup.sql               installation and upgrade fixtures
  self-test.sh            intentional failures checked by the actual runner
  lib/IDKit/Harness.pm    standard TAP::Harness with a no-skips policy
  lib/decode.sql         independent numeric ULID decoder
  lib/fixed-inputs.sql   fixed clock and entropy adapter for this implementation
  spec/10_encoding.sql   known vectors, boundaries, rounding, and timezone tests
  spec/20_contract.sql   real generators, defaults, metadata, and existing APIs
  spec/30_installation.sql  ownership, membership, version, and upgrade preservation
```

Tests use pgTAP's assertions and `pg_prove`'s standard TAP parsing and process-status handling. The small harness subclass only rejects SKIP, TODO, and empty files. Self-tests verify a passing control and rejection of failed assertions, missing assertions, extra assertions, SQL errors, backend termination, skipped assertions, skipped files, TODOs, malformed TAP, and empty output. These checks run before the extension suite.

Encoding boundary tests still use an explicitly implementation-specific adapter: it copies the installed function body and substitutes fixed clock and UUID inputs. The public API contracts call the real installed function and never use this adapter. This preserves deterministic boundary coverage without adding a production API solely for testing. A different implementation would need its own adapter, while keeping the contract tests unchanged.

The 10,002-ID uniqueness check detects regressions; it is not proof of collision freedom or a statistical test of cryptographic randomness. Existing UUID and KSUID functions receive compatibility smoke tests, not a comprehensive new conformance suite.

## Run without Docker

Install Postgres, pgTAP, `pg_prove`, and (for the TLE modes) pg_tle. Copy ID kit's control and version files into that Postgres installation's extension directory, then run:

```bash
PGBIN=/path/to/postgres/bin ./test/run.sh

# No pg_tle required when explicitly selecting direct SQL mode.
PGBIN=/path/to/postgres/bin ./test/run.sh --mode plain
```

Run as a user allowed to initialize Postgres, not root. Local runs use the same isolation, assertions, and strict failure policy as Docker runs. Missing TLE support fails a selected TLE mode; it is never silently skipped.

Documentation validation remains separate:

```bash
npm run docs:install
npm run docs:build
```
