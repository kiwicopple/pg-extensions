import { describe, expect, expectTypeOf, it } from 'vitest'
import {
  CedarClient,
  FgaClient,
  PermissionsClient,
  PermissionsError,
  PermissionsServerClient,
  RbacClient,
  createClient,
  createServerClient,
} from '../../src'
import type { CedarAdminApi, FgaAdminApi, PermissionsSubjectClient, RbacAdminApi, Queryable } from '../../src'

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

  it('cedar: POST /rpc/cedar_is_authorized_current and /rpc/cedar_list_resources_current', async () => {
    const { seen, fetch } = recordingFetch(() => new Response('["1"]'))
    const permissions = createClient('https://p', 'anon', { global: { fetch } })
    await permissions.cedar.isAuthorized({ action: 'Action::"view"', resource: { type: 'Doc', id: '1' } })
    expect((await permissions.cedar.listResources({ action: 'Action::"view"', resourceType: 'Doc' })).data).toEqual([
      '1',
    ])
    expect(seen.map((r) => [r.url, r.body])).toEqual([
      ['https://p/rest/v1/rpc/cedar_is_authorized_current', { action: 'Action::"view"', resource: 'Doc::"1"' }],
      ['https://p/rest/v1/rpc/cedar_list_resources_current', { action: 'Action::"view"', resource_type: 'Doc' }],
    ])
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
    expect('admin' in permissions.cedar).toBe(false)
    expectTypeOf(permissions.rbac).toEqualTypeOf<RbacClient<'postgrest'>>()
    expectTypeOf(permissions.fga).toEqualTypeOf<FgaClient<'postgrest'>>()
    expectTypeOf(permissions.cedar).toEqualTypeOf<CedarClient<'postgrest'>>()
    // @ts-expect-error no admin on the browser client
    void permissions.admin
    // @ts-expect-error no admin on a PostgREST RBAC client
    void permissions.rbac.admin
    // @ts-expect-error no admin on a PostgREST FGA client
    void permissions.fga.admin
    // @ts-expect-error no admin on a PostgREST Cedar client
    void permissions.cedar.admin
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
    expect(permissions.cedar.admin).toBeDefined()
    expectTypeOf(permissions.cedar.admin).toEqualTypeOf<CedarAdminApi>()
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
    const pgError = Object.assign(new Error('permission denied for function delete_subject'), { code: '42501', severity: 'ERROR' })
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
    expect('admin' in alice.cedar).toBe(false)
    expectTypeOf(alice).toEqualTypeOf<PermissionsSubjectClient>()
    expectTypeOf(alice.cedar).toEqualTypeOf<CedarClient<'subject'>>()
    // @ts-expect-error no admin on a subject Cedar client
    void alice.cedar.admin
    expectTypeOf(alice.rbac).toEqualTypeOf<RbacClient<'subject'>>()
    expectTypeOf(alice.fga).toEqualTypeOf<FgaClient<'subject'>>()
    // @ts-expect-error no admin on a subject RBAC client
    void alice.rbac.admin
    // @ts-expect-error no admin on a subject FGA client
    void alice.fga.admin
  })

  it('as() keeps throwOnError and the names', async () => {
    const pgError = Object.assign(new Error('boom'), { code: '57014', severity: 'ERROR' })
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

  it('cedar: admin over SQL, and as() checks in a transaction', async () => {
    const { log, db } = fakeDb((text) => (text.includes('as value') ? { rows: [{ value: true }] } : { rows: [] }))
    const permissions = createServerClient(db)
    await permissions.cedar.admin.putPolicy({ policyId: 'p', policy: 'permit (principal, action, resource);' })
    expect(log[0]!.text).toBe(
      'select "permissions".cedar_put_policy(policy_id => $1::text, policy => $2::text)',
    )
    const alice = permissions.as({ id: 'alice' })
    const request = { action: 'Action::"view"', resource: 'Doc::"1"' }
    expect(await alice.cedar.isAuthorized(request)).toEqual({ data: true, error: null })
    expect(log.slice(1).map((q) => q.text.split('(')[0])).toEqual([
      'begin',
      'select set_config',
      'select "permissions".cedar_is_authorized_current',
      'commit',
    ])
  })

  it('validates the subject role at as()', () => {
    expect(() => createServerClient(fakeDb().db).as({ id: 'a', role: 'x; drop table y' })).toThrow(/invalid role/)
  })

  it('needs an object with query()', () => {
    expect(() => createServerClient({} as never)).toThrow(/query/)
  })
})

describe('currentSubjectId and currentSubjectType', () => {
  it('createClient: POST /rpc/current_subject_id and /rpc/current_subject_type, with no arguments', async () => {
    const { seen, fetch } = recordingFetch(() => new Response('"alice"'))
    const permissions = createClient('https://p.supabase.co', 'anon', { global: { fetch } })
    expect(await permissions.currentSubjectId()).toEqual({ data: 'alice', error: null })
    expect(await permissions.currentSubjectType()).toEqual({ data: 'alice', error: null })
    expect(seen.map((r) => r.url)).toEqual([
      'https://p.supabase.co/rest/v1/rpc/current_subject_id',
      'https://p.supabase.co/rest/v1/rpc/current_subject_type',
    ])
    expect(seen.map((r) => r.body)).toEqual([{}, {}])
    expectTypeOf(permissions.currentSubjectId).returns.resolves.toHaveProperty('data').toEqualTypeOf<string | null>()
    expectTypeOf(permissions.currentSubjectType).returns.resolves.toHaveProperty('data').toEqualTypeOf<string | null>()
  })

  it('createClient: a null, an empty body and a type of user', async () => {
    for (const body of ['null', '']) {
      const permissions = createClient('https://p', 'k', { global: { fetch: recordingFetch(() => new Response(body)).fetch } })
      expect(await permissions.currentSubjectId()).toEqual({ data: null, error: null })
    }
    const permissions = createClient('https://p', 'k', { global: { fetch: recordingFetch(() => new Response('"user"')).fetch } })
    expect(await permissions.currentSubjectType()).toEqual({ data: 'user', error: null })
  })

  it('createClient: returns errors in { data, error }, or throws them with throwOnError', async () => {
    const body = () => new Response(JSON.stringify({ code: '42501', message: 'denied', details: null, hint: null }), { status: 403 })
    const soft = createClient('https://p', 'k', { global: { fetch: recordingFetch(body).fetch } })
    for (const result of [await soft.currentSubjectId(), await soft.currentSubjectType()]) {
      expect(result.data).toBeNull()
      expect(result.error).toBeInstanceOf(PermissionsError)
    }
    const strict = createClient('https://p', 'k', { global: { fetch: recordingFetch(body).fetch }, throwOnError: true })
    await expect(strict.currentSubjectId()).rejects.toBeInstanceOf(PermissionsError)
    await expect(strict.currentSubjectType()).rejects.toBeInstanceOf(PermissionsError)
  })

  it('createServerClient: select permissions.current_subject_*() as value', async () => {
    const { log, db } = fakeDb(() => ({ rows: [{ value: null }] }))
    const permissions = createServerClient(db)
    expect(await permissions.currentSubjectId()).toEqual({ data: null, error: null })
    expect(await permissions.currentSubjectType()).toEqual({ data: null, error: null })
    expect(log).toEqual([
      { text: 'select "permissions".current_subject_id() as value', values: [] },
      { text: 'select "permissions".current_subject_type() as value', values: [] },
    ])
    expect(await createServerClient(fakeDb(() => ({ rows: [{ value: 'user' }] })).db).currentSubjectType()).toEqual({
      data: 'user',
      error: null,
    })
    expect(await createServerClient(fakeDb(() => ({ rows: [] })).db).currentSubjectId()).toEqual({ data: null, error: null })
    expectTypeOf(permissions.currentSubjectId).returns.resolves.toHaveProperty('data').toEqualTypeOf<string | null>()
  })

  it('createServerClient: uses the schema option, and returns or throws errors', async () => {
    const { log, db } = fakeDb()
    await createServerClient(db, { schema: 'perms' }).currentSubjectId()
    expect(log[0]!.text).toContain('"perms".current_subject_id(')
    const pgError = Object.assign(new Error('boom'), { code: '57014', severity: 'ERROR' })
    const failing: Queryable = {
      query: async () => {
        throw pgError
      },
    }
    expect((await createServerClient(failing).currentSubjectType()).error?.code).toBe('57014')
    await expect(createServerClient(failing, { throwOnError: true }).currentSubjectId()).rejects.toBeInstanceOf(PermissionsError)
    await expect(createServerClient(failing, { throwOnError: true }).currentSubjectType()).rejects.toBeInstanceOf(PermissionsError)
  })

  it('as(): runs in a transaction with the subject set, and returns the answer', async () => {
    const { log, db } = fakeDb((text) => (text.includes('as value') ? { rows: [{ value: 'team' }] } : { rows: [] }))
    const eng = createServerClient(db).as({ id: 'eng', type: 'team', role: 'authenticated' })
    expect(await eng.currentSubjectType()).toEqual({ data: 'team', error: null })
    expect(await eng.currentSubjectId()).toEqual({ data: 'team', error: null })
    expect(log.map((q) => q.text.split('(')[0])).toEqual([
      'begin',
      'set local role "authenticated"',
      'select set_config',
      'select "permissions".current_subject_type',
      'commit',
      'begin',
      'set local role "authenticated"',
      'select set_config',
      'select "permissions".current_subject_id',
      'commit',
    ])
    expect(log[2]!.values).toEqual(['eng', 'team'])
    expectTypeOf(eng.currentSubjectId).returns.resolves.toHaveProperty('data').toEqualTypeOf<string | null>()
  })

  it('as(): keeps throwOnError', async () => {
    const pgError = Object.assign(new Error('boom'), { code: '57014', severity: 'ERROR' })
    const db: Queryable = {
      query: async (text: string) => {
        if (text.includes('current_subject_id')) throw pgError
        return { rows: [] }
      },
    }
    const soft = createServerClient(db).as({ id: 'a' })
    expect((await soft.currentSubjectId()).error?.code).toBe('57014')
    await expect(createServerClient(db, { throwOnError: true }).as({ id: 'a' }).currentSubjectId()).rejects.toBeInstanceOf(
      PermissionsError,
    )
  })
})
