import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import pg from 'pg';
import { validDelta } from './counter.mjs';
import { syncCounter } from './store.mjs';
import { databaseOptions } from './database.mjs';

const TTL = 24 * 60 * 60;
const MAX_BODY = 2048;
let pool;

function database(env) {
  if (!pool) {
    pool = new pg.Pool({
      ...databaseOptions(env),
      max: 2,
      idleTimeoutMillis: 10_000,
      connectionTimeoutMillis: 4_000,
      query_timeout: 6_000,
      allowExitOnIdle: true,
    });
    // Never log connection errors: they can contain host or credential details.
    pool.on('error', () => console.error('CRDT demo: idle database connection failed.'));
  }
  return pool;
}

const signature = (payload, secret) => createHmac('sha256', secret).update(payload).digest('base64url');

export function createSession(secret, now = Date.now()) {
  const payload = `${randomUUID()}.${Math.floor(now / 1000) + TTL}`;
  return `${payload}.${signature(payload, secret)}`;
}

export function readSession(token, secret, now = Date.now()) {
  if (typeof token !== 'string' || token.length > 160) return null;
  const [id, expiration, mac, extra] = token.split('.');
  if (extra !== undefined || !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(id)
    || !/^\d{10}$/.test(expiration) || !/^[\w-]{43}$/.test(mac)) return null;
  const expected = signature(`${id}.${expiration}`, secret);
  if (!timingSafeEqual(Buffer.from(expected), Buffer.from(mac))) return null;
  const expires = Number(expiration);
  return expires > Math.floor(now / 1000) ? { id, expires } : null;
}

function json(body, status = 200, extraHeaders = {}) {
  return Response.json(body, {
    status,
    headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...extraHeaders },
  });
}

async function readBody(request) {
  if (!request.headers.get('content-type')?.toLowerCase().startsWith('application/json')) {
    return { error: 'Send application/json.', status: 415 };
  }
  if (Number(request.headers.get('content-length')) > MAX_BODY) {
    return { error: 'Request is too large.', status: 413 };
  }
  const reader = request.body?.getReader();
  if (!reader) return { error: 'Missing request body.', status: 400 };
  const chunks = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > MAX_BODY) {
      await reader.cancel();
      return { error: 'Request is too large.', status: 413 };
    }
    chunks.push(Buffer.from(value));
  }
  try { return { body: JSON.parse(Buffer.concat(chunks).toString('utf8')) }; }
  catch { return { error: 'Invalid JSON.', status: 400 }; }
}

export async function handleCounter(request, { env = process.env, db } = {}) {
  if (!['GET', 'POST'].includes(request.method)) {
    return json({ error: 'Method not allowed.' }, 405, { Allow: 'GET, POST' });
  }
  const configured = env.CRDT_DEMO_DATABASE_URL && env.CRDT_DEMO_SECRET?.length >= 32;
  if (!configured) {
    // Only a completely unconfigured installation is a browser preview.
    if (!env.CRDT_DEMO_DATABASE_URL && !env.CRDT_DEMO_SECRET && request.method === 'GET') {
      return json({ mode: 'preview' });
    }
    return json({ error: 'The Postgres demo is not configured yet.' }, 503);
  }
  try {
    if (request.method === 'GET') {
      // Opening the docs or starting over must not open a database connection.
      // Connectivity is checked by the first explicit sync instead.
      return json({ mode: 'postgres', token: createSession(env.CRDT_DEMO_SECRET) });
    }
    const session = readSession(request.headers.get('authorization')?.replace(/^Bearer /, ''), env.CRDT_DEMO_SECRET);
    if (!session) return json({ error: 'This demo session expired. Start a new counter.' }, 401);
    const parsed = await readBody(request);
    if (parsed.error) return json({ error: parsed.error }, parsed.status);
    if (!validDelta(parsed.body?.delta)) return json({ error: 'Invalid counter totals.' }, 400);
    const result = await syncCounter(db ?? database(env), session, parsed.body.delta);
    return json(result);
  } catch {
    console.error('CRDT demo: database request failed. Check connectivity and the demo installation.');
    return json({ error: 'Postgres is unavailable. Your local edits are safe; try syncing again.' }, 503);
  }
}
