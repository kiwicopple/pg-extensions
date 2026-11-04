import pg from 'pg'
import { signJwt } from './jwt'

/** The ports and secret of test/docker-compose.yml. */
export const PG_URL = 'postgres://postgres:postgres@127.0.0.1:54420/postgres'
export const REST_URL = 'http://127.0.0.1:54421'
export const JWT_SECRET = 'permissions-js-test-secret-at-least-32-chars'

/**
 * A pool as the trusted backend role (`service_role`, which has the admin grants
 * from test/setup.sql). Close it in `afterAll` with `await pool.end()`.
 */
export function servicePool(): pg.Pool {
  return new pg.Pool({ connectionString: PG_URL, options: '-c role=service_role', max: 4 })
}

/**
 * A pool as `authenticated`, the role of a signed-in user: it has no admin grants.
 * Close it with `await pool.end()`.
 */
export function authenticatedPool(): pg.Pool {
  return new pg.Pool({ connectionString: PG_URL, options: '-c role=authenticated', max: 2 })
}

/** A pool as the superuser `postgres` (owner of the extension). For setup and reset only. */
export function ownerPool(): pg.Pool {
  return new pg.Pool({ connectionString: PG_URL, max: 2 })
}

/** A PostgREST token for `sub` with `role` (default `authenticated`). */
export function userToken(sub: string, role = 'authenticated'): string {
  return signJwt({ sub, role }, JWT_SECRET)
}

/** A PostgREST token for `anon`: what a Supabase anon key is. */
export function anonToken(): string {
  return signJwt({ role: 'anon' }, JWT_SECRET)
}

/** A PostgREST token for `service_role`, without a subject. */
export function serviceToken(): string {
  return signJwt({ role: 'service_role' }, JWT_SECRET)
}

/** `Authorization` headers for a PostgREST transport. */
export function authHeaders(token: string): Record<string, string> {
  return { Authorization: `Bearer ${token}` }
}

/**
 * Empties every table of the extension (roles, assignments, models, tuples), as
 * the owner. Call it in `beforeAll`/`beforeEach` of a test file that writes data.
 */
export async function resetDatabase(owner: pg.Pool): Promise<void> {
  await owner.query(`
    do $$
    declare t text;
    begin
      select string_agg(format('%I.%I', schemaname, tablename), ', ') into t
      from pg_tables where schemaname = 'permissions' and tablename <> '_cedar_secret';
      if t is not null then
        execute 'truncate ' || t || ' restart identity cascade';
      end if;
    end $$`)
}
