#!/usr/bin/env bash
# Execute the actual quickstart SQL in an isolated, temporary Postgres cluster.
set -euo pipefail
DOCS_DIR=$(cd "$(dirname "$0")/.." && pwd)
EXT_DIR=$(cd "$DOCS_DIR/.." && pwd)
. "$EXT_DIR/test/lib/cluster.sh"
EXTERNAL=0
start_cluster
psql_admin -f "$EXT_DIR/pg_permissions--0.1.0.sql" >/dev/null
node --input-type=module - "$EXT_DIR/docs/get-started/quickstart.md" "$PGBIN/psql" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
const [doc, psql] = process.argv.slice(2);
const parts = fs.readFileSync(doc, 'utf8').split('## Optional: enforce access on a table');
assert.equal(parts.length, 2, 'Quickstart must separate checks from optional RLS');
const sqlBlocks = (text) => [...text.matchAll(/^```sql\n([\s\S]*?)^```/gm)]
  .map((match) => match[1]).join('\n');
const run = (sql) => {
  const result = spawnSync(psql, ['-X', '-q', '-tA', '-v', 'ON_ERROR_STOP=1', '-d', 'postgres'], {
    input: sql, encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim().split('\n').filter(Boolean);
};
assert.deepEqual(run(sqlBlocks(parts[0]) + `
select permissions.current_subject_id() is null;
select to_regclass('public.documents') is null;
`), ['alice', 't', 'bob', 'f', 't', 't'],
  'Direct checks allow Alice and deny Bob without an application table; identity is cleared');
assert.deepEqual(run(sqlBlocks(parts[1]) + '\nselect permissions.current_subject_id() is null;\n'), [
  'alice', 'roadmap|Acme roadmap', 'bob', '0', 't',
], 'Optional RLS filters Alice and Bob correctly and clears identity');
console.log('check-quickstart: direct checks work without a table; optional RLS and identity results match');
JS
