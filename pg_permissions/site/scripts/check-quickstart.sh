#!/usr/bin/env bash
# Execute the actual quickstart SQL in an isolated, temporary Postgres cluster.
set -euo pipefail
DOCS_DIR=$(cd "$(dirname "$0")/.." && pwd)
EXT_DIR=$(cd "$DOCS_DIR/.." && pwd)
. "$EXT_DIR/test/lib/cluster.sh"
EXTERNAL=0
start_cluster
psql_admin -f "$EXT_DIR/pg_permissions--0.0.1.sql" >/dev/null
node --input-type=module - "$EXT_DIR/docs/get-started/quickstart.md" "$PGBIN/psql" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
const [doc, psql] = process.argv.slice(2);
const sql = [...fs.readFileSync(doc, 'utf8').matchAll(/^```sql\n([\s\S]*?)^```/gm)]
  .map((match) => match[1]).join('\n');
assert.ok(sql.includes('create policy'), 'Quickstart must include an RLS policy');
const result = spawnSync(psql, ['-X', '-q', '-tA', '-v', 'ON_ERROR_STOP=1', '-d', 'postgres'], {
  input: sql + '\nselect permissions.current_subject_id() is null;\n', encoding: 'utf8',
});
assert.equal(result.status, 0, result.stderr);
assert.deepEqual(result.stdout.trim().split('\n').filter(Boolean), [
  'alice', 'roadmap|Acme roadmap', 'bob', '0', 't',
], 'Alice sees only Acme, Bob sees nothing, and identity is cleared after commit');
console.log('check-quickstart: SQL copied from the docs runs; access and identity results match');
JS
