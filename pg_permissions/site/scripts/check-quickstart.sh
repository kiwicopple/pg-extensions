#!/usr/bin/env bash
# Execute both paths through the published quickstart in separate test databases.
set -euo pipefail
DOCS_DIR=$(cd "$(dirname "$0")/.." && pwd)
EXT_DIR=$(cd "$DOCS_DIR/.." && pwd)
. "$EXT_DIR/test/lib/cluster.sh"
EXTERNAL=0
start_cluster
psql_admin -f "$EXT_DIR/pg_permissions--0.1.0.sql" >/dev/null
psql_admin -c 'create database quickstart_js template postgres' >/dev/null
cd "$EXT_DIR/js"
npm run build >/dev/null
node --input-type=module - "$EXT_DIR/docs/get-started/quickstart.md" "$PGBIN/psql" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
const [doc, psql] = process.argv.slice(2);
const parts = fs.readFileSync(doc, 'utf8').split('## Optional: enforce access on a table');
assert.equal(parts.length, 2, 'Quickstart must separate checks from optional RLS');
const blocks = (text, language) => [...text.matchAll(/^```(\w+)(?: [^\n]*)?\n([\s\S]*?)^```/gm)]
  .filter((match) => match[1] === language).map((match) => match[2]).join('\n');
const database = new URL('postgresql://postgres@localhost/quickstart_js');
database.searchParams.set('host', process.env.PGHOST);
database.port = process.env.PGPORT;
const js = spawnSync(process.execPath, ['--input-type=module'], {
  input: blocks(parts[0], 'js'), encoding: 'utf8',
  env: { ...process.env, DATABASE_URL: database.href },
});
assert.equal(js.status, 0, js.stderr);
assert.deepEqual(js.stdout.trim().split('\n'), ['true', 'false'], 'JavaScript allows Alice and denies Bob');
const run = (sql) => {
  const result = spawnSync(psql, ['-X', '-q', '-tA', '-v', 'ON_ERROR_STOP=1', '-d', 'postgres'], {
    input: sql, encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim().split('\n').filter(Boolean);
};
assert.deepEqual(run(blocks(parts[0], 'sql') + `
select permissions.current_subject_id() is null;
select to_regclass('public.documents') is null;
`), ['alice', 't', 'bob', 'f', 't', 't'],
  'Direct checks allow Alice and deny Bob without an application table; identity is cleared');
assert.deepEqual(run(blocks(parts[1], 'sql') + '\nselect permissions.current_subject_id() is null;\n'), [
  'alice', 'roadmap|Acme roadmap', 'bob', '0', 't',
], 'Optional RLS filters Alice and Bob correctly and clears identity');
console.log('check-quickstart: JavaScript, SQL and optional RLS examples returned the expected decisions');
JS
