import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { PGlite } from '@electric-sql/pglite';
import { empty, merge, value, validDelta, deltaFromCopies } from './counter.mjs';
import { createSession, readSession, handleCounter } from './server.mjs';
import { readCounterResponse } from './response.mjs';

const env = { CRDT_DEMO_DATABASE_URL: 'postgres://unused-in-test', CRDT_DEMO_SECRET: 'test-only-signing-secret-32-characters-long' };
const request = (token, delta, options = {}) => new Request('https://example.test/api/counter', {
  method: 'POST',
  headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ delta }),
  ...options,
});
const delta = (p = {}, n = {}) => ({ t: 'pn', v: 1, p, n });

test('independent copies converge, replay is idempotent, and in-flight edits survive', () => {
  const copies = { 'demo:alice': delta({ 'demo:alice': 3 }), 'demo:bob': delta({}, { 'demo:bob': 1 }) };
  const sent = deltaFromCopies(copies);
  copies['demo:alice'].p['demo:alice'] += 1;
  const stored = merge(empty(), sent);
  assert.equal(value(stored), 2);
  assert.deepEqual(merge(stored, sent), stored);
  assert.equal(value(merge(copies['demo:alice'], stored)), 3);
  assert.deepEqual(merge(copies['demo:alice'], copies['demo:bob']), merge(copies['demo:bob'], copies['demo:alice']));
});

test('only bounded, whole totals from the two demo replicas are accepted', () => {
  for (const input of [null, [], {}, delta({ intruder: 1 }), delta({ 'demo:alice': -1 }),
    delta({ 'demo:alice': 1.1 }), delta({ 'demo:alice': 10_001 }), delta({ 'demo:alice': '2' }),
    { ...empty(), extra: true }, { ...empty(), p: [] }]) {
    assert.equal(validDelta(input), false, JSON.stringify(input));
  }
  assert.equal(validDelta(delta({ 'demo:alice': 10_000 }, { 'demo:bob': 2 })), true);
});

test('sessions are signed, expire, and cannot be renamed', () => {
  const now = 1_800_000_000_000;
  const token = createSession(env.CRDT_DEMO_SECRET, now);
  assert.ok(readSession(token, env.CRDT_DEMO_SECRET, now));
  assert.equal(readSession(token, 'wrong-secret', now), null);
  assert.equal(readSession(`00000000-0000-4000-8000-000000000000.${token.split('.').slice(1).join('.')}`, env.CRDT_DEMO_SECRET, now), null);
  assert.equal(readSession(token, env.CRDT_DEMO_SECRET, now + 86_400_000), null);
  for (const bad of [null, '', 'broken', `${token}.extra`, 'x'.repeat(500)]) assert.equal(readSession(bad, env.CRDT_DEMO_SECRET), null);
});

test('preview is explicit, partial configuration and database errors never simulate success', async () => {
  const get = () => new Request('https://example.test/api/counter');
  assert.deepEqual(await (await handleCounter(get(), { env: {} })).json(), { mode: 'preview' });
  assert.equal((await handleCounter(get(), { env: { CRDT_DEMO_SECRET: env.CRDT_DEMO_SECRET } })).status, 503);
  const failure = await handleCounter(request(createSession(env.CRDT_DEMO_SECRET), empty()), { env, db: { query() { throw new Error('private database details'); } } });
  assert.equal(failure.status, 503);
  assert.ok(!(await failure.text()).includes('private database details'));
  const unsupported = await handleCounter(new Request('https://example.test/api/counter', { method: 'DELETE' }));
  assert.equal(unsupported.status, 405);
  assert.equal(unsupported.headers.get('allow'), 'GET, POST');
});

test('page loads and resets create sessions without any database queries', async () => {
  const db = { query() { assert.fail('A page load reached Postgres'); } };
  const tokens = new Set();
  for (let i = 0; i < 50; i++) {
    const response = await handleCounter(new Request('https://example.test/api/counter'), { env, db });
    assert.equal(response.status, 200);
    const session = await response.json();
    assert.equal(session.mode, 'postgres');
    assert.ok(readSession(session.token, env.CRDT_DEMO_SECRET));
    tokens.add(session.token);
  }
  assert.equal(tokens.size, 50);
});

test('the client explains firewall limits even when the response is not JSON', async () => {
  for (const body of ['<html>Too Many Requests</html>', 'Too Many Requests', '{"error":"rate limited"}']) {
    await assert.rejects(readCounterResponse(new Response(body, { status: 429 })), /Wait a minute.*local edits are safe/);
  }
  await assert.rejects(readCounterResponse(Response.json({ error: 'Postgres is unavailable.' }, { status: 503 })), /Postgres is unavailable/);
  const result = { state: empty(), value: '0' };
  assert.deepEqual(await readCounterResponse(Response.json(result)), result);
});

test('bad sessions and payloads are rejected before querying Postgres', async () => {
  const db = { query() { assert.fail('Invalid input reached Postgres'); } };
  const token = createSession(env.CRDT_DEMO_SECRET);
  assert.equal((await handleCounter(request('invalid', empty()), { env, db })).status, 401);
  assert.equal((await handleCounter(request(token, delta({ intruder: 1 })), { env, db })).status, 400);
  assert.equal((await handleCounter(request(token, empty(), { body: '{' }), { env, db })).status, 400);
  assert.equal((await handleCounter(request(token, empty(), { body: ' '.repeat(2049) }), { env, db })).status, 413);
  assert.equal((await handleCounter(request(token, empty(), { headers: { Authorization: `Bearer ${token}` } }), { env, db })).status, 415);
});

test('the API uses the real pg_crdt SQL under the restricted runtime role', async (t) => {
  const db = new PGlite();
  try {
    await db.exec(await readFile(new URL('../pg_crdt--0.0.1.sql', import.meta.url), 'utf8'));
    await db.exec(await readFile(new URL('./setup.sql', import.meta.url), 'utf8'));
    await db.exec('create table public.owner_only (id int); set role crdt_demo_app;');
    const response = await handleCounter(new Request('https://example.test/api/counter'), { env, db });
    assert.equal(response.headers.get('cache-control'), 'no-store');
    const session = await response.json();
    assert.equal(session.mode, 'postgres');
    const send = async (state, token = session.token) => {
      const result = await handleCounter(request(token, state), { env, db });
      assert.equal(result.status, 200);
      return result.json();
    };

    await t.test('independent edits, duplicate delivery, stale delivery and decrements', async () => {
      const first = delta({ 'demo:alice': 3 }, { 'demo:bob': 1 });
      assert.equal((await send(first)).value, '2');
      assert.equal((await send(first)).value, '2');
      assert.equal((await send(delta({ 'demo:alice': 1 }))).value, '2');
      assert.equal((await send(delta({}, { 'demo:bob': 5 }))).value, '-2');
    });

    await t.test('separate visitors cannot change each other’s counters', async () => {
      const other = createSession(env.CRDT_DEMO_SECRET);
      assert.equal((await send(delta({ 'demo:alice': 100 }), other)).value, '100');
      assert.equal((await send(empty())).value, '-2');
    });

    await t.test('partial deliveries preserve the other device’s totals', async () => {
      await Promise.all([send(delta({ 'demo:alice': 6 })), send(delta({ 'demo:bob': 3 }))]);
      assert.equal((await send(empty())).value, '4');
    });

    await t.test('expired rows are removed on the next write', async () => {
      await db.query("insert into crdt_demo.counters (id, expires_at) values ('00000000-0000-4000-8000-000000000000', now() - interval '1 day')");
      await send(empty());
      assert.equal((await db.query("select id from crdt_demo.counters where id = '00000000-0000-4000-8000-000000000000'")).rows.length, 0);
    });

    await t.test('the runtime role cannot read unrelated tables or create objects', async () => {
      await assert.rejects(db.query('select * from public.owner_only'), { code: '42501' });
      await assert.rejects(db.query('create table crdt_demo.forbidden (id int)'), { code: '42501' });
    });
  } finally { await db.close(); }
});
