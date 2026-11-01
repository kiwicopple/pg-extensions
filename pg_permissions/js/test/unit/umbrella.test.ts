import { describe, expect, expectTypeOf, it } from 'vitest'
import {
  FgaClient,
  PermissionsClient,
  PermissionsError,
  PermissionsServerClient,
  RbacClient,
  createClient,
  createServerClient,
} from '../../src'
import type { FgaAdminApi, PermissionsSubjectClient, RbacAdminApi, Queryable } from '../../src'

type Seen = { url: string; headers: Headers; body: unknown }

/** A fetch that records each request and answers `true` (or `respond()`). */
function recordingFetch(respond: () => Response = () => new Response('true')) {
  const seen: Seen[] = []
  const fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    seen.push({ url: String(input), headers: new Headers(init?.headers), body: JSON.parse(String(init?.body)) })
    return respond()
  }) as typeof globalThis.fetch
  return { seen, fetch }
}

describe('createClient', () => {
  it('appends /rest/v1 to the URL, with or without a trailing slash', async () => {
    for (const url of ['https://p.supabase.co', 'https://p.supabase.co/', 'https://p.supabase.co//']) {
      const { seen, fetch } = recordingFetch()
      await createClient(url, 'anon', { global: { fetch } }).rbac.hasRole({ role: 'r' })
      expect(seen[0]!.url).toBe('https://p.supabase.co/rest/v1/rpc/rbac_has_role')
    }
  })

  it('uses restUrl instead of the URL', async () => {
    const { seen, fetch } = recordingFetch()
    await createClient('https://ignored', 'anon', { restUrl: 'http://localhost:3000/', global: { fetch } }).fga.check({
      relation: 'viewer',
      object: 'document:1',
    })
    expect(seen[0]!.url).toBe('http://localhost:3000/rpc/fga_check_current')
    expect(seen[0]!.body).toEqual({ relation: 'viewer', object: 'document:1' })
  })

  it('sends apikey, and the key as the bearer token without an access token', async () => {
    const { seen, fetch } = recordingFetch()
    await createClient('https://p.supabase.co', 'anon-key', { global: { fetch } }).rbac.hasPermission({ permission: 'p' })
    expect(seen[0]!.headers.get('apikey')).toBe('anon-key')
    expect(seen[0]!.headers.get('Authorization')).toBe('Bearer anon-key')
  })

  it('sends the access token as the bearer token, and falls back to the key when it is null', async () => {
    const { seen, fetch } = recordingFetch()
    let token: string | null = 'user-jwt'
    const permissions = createClient('https://p.supabase.co', 'anon-key', {
      global: { fetch },
      accessToken: async () => token,
    })
    await permissions.rbac.hasPermission({ permission: 'p' })
    token = null
    await permissions.fga.listObjects({ type: 'document', relation: 'viewer' })
    expect(seen[0]!.headers.get('apikey')).toBe('anon-key')
    expect(seen[0]!.headers.get('Authorization')).toBe('Bearer user-jwt')
    expect(seen[1]!.headers.get('Authorization')).toBe('Bearer anon-key')
  })

  it('sends global headers, and does not replace an Authorization header in them', async () => {
    const { seen, fetch } = recordingFetch()
    await createClient('https://p.supabase.co', 'anon-key', {
      global: { fetch, headers: { 'X-Custom': '1', Authorization: 'Bearer fixed' } },
      accessToken: () => 'user-jwt',
    }).rbac.hasRole({ role: 'r' })
    expect(seen[0]!.headers.get('X-Custom')).toBe('1')
    expect(seen[0]!.headers.get('Authorization')).toBe('Bearer fixed')
  })

  it('sends the schema profile headers (default permissions)', async () => {
    const a = recordingFetch()
    await createClient('https://p.supabase.co', 'k', { global: { fetch: a.fetch } }).rbac.hasRole({ role: 'r' })
    expect(a.seen[0]!.headers.get('Content-Profile')).toBe('permissions')
    expect(a.seen[0]!.headers.get('Accept-Profile')).toBe('permissions')
    const b = recordingFetch()
    await createClient('https://p.supabase.co', 'k', { global: { fetch: b.fetch }, db: { schema: 'perms' } }).rbac.hasRole({
      role: 'r',
    })
    expect(b.seen[0]!.headers.get('Content-Profile')).toBe('perms')
    expect(b.seen[0]!.headers.get('Accept-Profile')).toBe('perms')
  })

  it('returns errors in { data, error }, or throws them with throwOnError', async () => {
    const body = () =>
      new Response(JSON.stringify({ code: '22023', message: 'bad', details: 'openfga:2000 validation_error', hint: null }), {
        status: 400,
      })
    const soft = createClient('https://p', 'k', { global: { fetch: recordingFetch(body).fetch } })
    const { data, error } = await soft.fga.check({ relation: 'r', object: 'o:1' })
    expect(data).toBeNull()
    expect(error).toBeInstanceOf(PermissionsError)
    const strict = createClient('https://p', 'k', { global: { fetch: recordingFetch(body).fetch }, throwOnError: true })
    await expect(strict.rbac.hasRole({ role: 'r' })).rejects.toBeInstanceOf(PermissionsError)
  })

  it('has no admin namespaces', () => {
    const permissions = createClient('https://p', 'k', { global: { fetch: recordingFetch().fetch } })
    expect(permissions).toBeInstanceOf(PermissionsClient)
    expect('admin' in permissions).toBe(false)
    expect('admin' in permissions.rbac).toBe(false)
    expect('admin' in permissions.fga).toBe(false)
    expectTypeOf(permissions.rbac).toEqualTypeOf<RbacClient<'postgrest'>>()
    expectTypeOf(permissions.fga).toEqualTypeOf<FgaClient<'postgrest'>>()
    // @ts-expect-error no admin on the browser client
    void permissions.admin
    // @ts-expect-error no admin on a PostgREST RBAC client
    void permissions.rbac.admin
    // @ts-expect-error no admin on a PostgREST FGA client
    void permissions.fga.admin
  })

  it('narrows names with the generic', () => {
    const permissions = createClient<{ permissions: 'a.read'; roles: 'viewer' }>('https://p', 'k')
    void (() => {
      void permissions.rbac.hasPermission({ permission: 'a.read' })
      // @ts-expect-error not a permission of the names
      void permissions.rbac.hasPermission({ permission: 'b.read' })
    })
  })

  it('needs a URL (or restUrl) and a key', () => {
    expect(() => createClient('', 'k')).toThrow(/URL/)
    expect(() => createClient('', 'k', { restUrl: 'http://localhost:3000' })).not.toThrow()
    expect(() => createClient('https://p', '')).toThrow(/key/)
  })
})

/** A fake `query()` that records statements and answers from `respond`. */
function fakeDb(respond: (text: string) => { rows: any[] } = () => ({ rows: [] })) {
  const log: { text: string; values?: unknown[] }[] = []
  const db: Queryable = {
    async query(text: string, values?: unknown[]) {
      log.push({ text, values })
      return respond(text)
    },
  }
  return { log, db }
}

describe('createServerClient', () => {
  it('has rbac, fga and admin, all over SQL', async () => {
    const { log, db } = fakeDb(() => ({ rows: [{ value: true }] }))
    const permissions = createServerClient(db)
    expect(permissions).toBeInstanceOf(PermissionsServerClient)
    expect(permissions.rbac.admin).toBeDefined()
    expect(permissions.fga.admin).toBeDefined()
    expectTypeOf(permissions.rbac.admin).toEqualTypeOf<RbacAdminApi>()
    expectTypeOf(permissions.fga.admin).toEqualTypeOf<FgaAdminApi>()
    await permissions.rbac.admin.assignRole({ userId: 'alice', role: 'editor', scope: 'acme' })
    expect(log[0]!.text).toBe(
      'select "permissions".rbac_assign_role(user_id => $1::text, role => $2::text, scope => $3::text)',
    )
  })

  it('uses the schema option', async () => {
    const { log, db } = fakeDb()
    await createServerClient(db, { schema: 'perms' }).rbac.hasRole({ role: 'r' })
    expect(log[0]!.text).toContain('"perms".rbac_has_role(')
  })

  it('deleteSubject converts the bigint (a string from pg) to a number', async () => {
    const { log, db } = fakeDb(() => ({ rows: [{ value: '3' }] }))
    const permissions = createServerClient(db)
    expect(await permissions.admin.deleteSubject({ type: 'user', id: 'alice' })).toEqual({ data: 3, error: null })
    expect(log[0]).toEqual({
      text: 'select "permissions".delete_subject(subject_type => $1::text, subject_id => $2::text) as value',
      values: ['user', 'alice'],
    })
    const numeric = createServerClient(fakeDb(() => ({ rows: [{ value: 0 }] })).db)
    expect(await numeric.admin.deleteSubject({ type: 'team', id: 'eng' })).toEqual({ data: 0, error: null })
    expectTypeOf(numeric.admin.deleteSubject).returns.resolves.toHaveProperty('data').toEqualTypeOf<number | null>()
  })

  it('deleteSubject returns or throws a database error', async () => {
    const pgError = Object.assign(new Error('permission denied for function delete_subject'), { code: '42501' })
    const db: Queryable = {
      query: async () => {
        throw pgError
      },
    }
    const { data, error } = await createServerClient(db).admin.deleteSubject({ type: 'user', id: 'a' })
    expect(data).toBeNull()
    expect(error?.code).toBe('42501')
    await expect(
      createServerClient(db, { throwOnError: true }).admin.deleteSubject({ type: 'user', id: 'a' }),
    ).rejects.toBeInstanceOf(PermissionsError)
  })

  it('as() runs the checks as the subject, in a transaction', async () => {
    const { log, db } = fakeDb((text) => (text.includes('as value') ? { rows: [{ value: true }] } : { rows: [] }))
    const alice = createServerClient(db).as({ id: 'alice', role: 'authenticated' })
    expect(await alice.rbac.hasPermission({ permission: 'p', scope: 'acme' })).toEqual({ data: true, error: null })
    expect(await alice.fga.check({ relation: 'viewer', object: 'document:1' })).toEqual({ data: true, error: null })
    expect(log.map((q) => q.text.split('(')[0])).toEqual([
      'begin',
      'set local role "authenticated"',
      "select set_config",
      'select "permissions".rbac_has_permission',
      'commit',
      'begin',
      'set local role "authenticated"',
      "select set_config",
      'select "permissions".fga_check_current',
      'commit',
    ])
    expect(log[2]!.values).toEqual(['alice', 'user'])
  })

  it('as() clients have no admin, at runtime and in the type', () => {
    const alice = createServerClient(fakeDb().db).as({ id: 'alice' })
    expect('admin' in alice).toBe(false)
    expect('admin' in alice.rbac).toBe(false)
    expect('admin' in alice.fga).toBe(false)
    expectTypeOf(alice).toEqualTypeOf<PermissionsSubjectClient>()
    expectTypeOf(alice.rbac).toEqualTypeOf<RbacClient<'subject'>>()
    expectTypeOf(alice.fga).toEqualTypeOf<FgaClient<'subject'>>()
    // @ts-expect-error no admin on a subject RBAC client
    void alice.rbac.admin
    // @ts-expect-error no admin on a subject FGA client
    void alice.fga.admin
  })

  it('as() keeps throwOnError and the names', async () => {
    const pgError = Object.assign(new Error('boom'), { code: '57014' })
    let n = 0
    const db: Queryable = {
      query: async (text: string) => {
        n++
        if (text.includes('rbac_has_role')) throw pgError
        return { rows: [] }
      },
    }
    const server = createServerClient<{ roles: 'viewer' }>(db, { throwOnError: true })
    await expect(server.as({ id: 'a' }).rbac.hasRole({ role: 'viewer' })).rejects.toBeInstanceOf(PermissionsError)
    expect(n).toBeGreaterThan(0)
    void (() => {
      // @ts-expect-error not a role of the names
      void server.as({ id: 'a' }).rbac.hasRole({ role: 'editor' })
    })
  })

  it('validates the subject role at as()', () => {
    expect(() => createServerClient(fakeDb().db).as({ id: 'a', role: 'x; drop table y' })).toThrow(/invalid role/)
  })

  it('needs an object with query()', () => {
    expect(() => createServerClient({} as never)).toThrow(/query/)
  })
})
