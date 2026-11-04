import { describe, expect, expectTypeOf, it } from 'vitest'
import { RbacClient } from '../../src/rbac'
import type { RbacAdminApi } from '../../src/rbac'
import { PermissionsError } from '../../src/lib/errors'
import type { RpcArgs, Shape, Transport, TransportKind } from '../../src/lib/types'
import type { SqlTransport } from '../../src/transport/sql'

type Call = { fn: string; args: RpcArgs; shape: Shape }

/** A mock transport: records each call, answers from `respond`. */
function mockTransport(kind: TransportKind, respond: (fn: string) => unknown = () => null) {
  const calls: Call[] = []
  const transport: Transport = {
    kind,
    async rpc<T>(fn: string, args: RpcArgs, shape: Shape): Promise<T> {
      calls.push({ fn, args, shape })
      const r = respond(fn)
      if (r instanceof Error) throw r
      return r as T
    },
  }
  return { calls, transport }
}

const sqlKind = (m: { transport: Transport }) => m.transport as SqlTransport

describe('RbacClient client methods', () => {
  it.each([false, null, undefined, 'false', 'true', 0, 1, {}, []].map((value) => [value]))('denies any response other than boolean true: %j', async (value) => {
    const rbac = new RbacClient({ transport: mockTransport('sql', () => value).transport })
    expect(await rbac.hasPermission({ permission: 'documents.read' })).toEqual({ data: false, error: null })
    expect(await rbac.hasRole({ role: 'admin' })).toEqual({ data: false, error: null })
  })

  it('maps hasPermission, hasRole and scopesWithPermission to the right function, shape and arguments', async () => {
    const m = mockTransport('postgrest', (fn) => (fn === 'rbac_scopes_with_permission' ? ['acme'] : true))
    const rbac = new RbacClient({ transport: m.transport })
    expect(await rbac.hasPermission({ permission: 'documents.edit', scope: 'acme' })).toEqual({ data: true, error: null })
    expect(await rbac.hasRole({ role: 'editor' })).toEqual({ data: true, error: null })
    expect(await rbac.scopesWithPermission({ permission: 'documents.read' })).toEqual({ data: ['acme'], error: null })
    expect(m.calls).toEqual([
      { fn: 'rbac_has_permission', args: { permission: 'documents.edit', scope: 'acme' }, shape: 'scalar' },
      { fn: 'rbac_has_role', args: { role: 'editor', scope: undefined }, shape: 'scalar' },
      { fn: 'rbac_scopes_with_permission', args: { permission: 'documents.read' }, shape: 'scalar' },
    ])
  })

  it('never sends plan_time_guard', async () => {
    const m = mockTransport('postgrest', () => [])
    await new RbacClient({ transport: m.transport }).scopesWithPermission({ permission: 'p' })
    expect(Object.keys(m.calls[0]!.args)).toEqual(['permission'])
  })

  it('treats scope null and undefined as app-wide (the argument is omitted)', async () => {
    const m = mockTransport('postgrest', () => false)
    const rbac = new RbacClient({ transport: m.transport })
    await rbac.hasPermission({ permission: 'p', scope: null })
    await rbac.hasPermission({ permission: 'p' })
    await rbac.hasRole({ role: 'r', scope: null })
    for (const c of m.calls) expect(c.args.scope).toBeUndefined()
  })

  it('returns a PermissionsError in { data, error }', async () => {
    const error = new PermissionsError({ message: 'boom', code: '57014' })
    const rbac = new RbacClient({ transport: mockTransport('postgrest', () => error).transport })
    expect(await rbac.hasRole({ role: 'r' })).toEqual({ data: null, error })
  })

  it('throws the error with throwOnError', async () => {
    const error = new PermissionsError({ message: 'boom', code: '57014' })
    const rbac = new RbacClient({ transport: mockTransport('postgrest', () => error).transport, throwOnError: true })
    await expect(rbac.hasPermission({ permission: 'p' })).rejects.toBe(error)
  })

  it('always throws an error that is not a PermissionsError', async () => {
    const rbac = new RbacClient({ transport: mockTransport('postgrest', () => new Error('refused')).transport })
    await expect(rbac.hasPermission({ permission: 'p' })).rejects.toThrow('refused')
  })
})

describe('RbacClient admin', () => {
  it('maps every admin method to the SQL names and shapes', async () => {
    const m = mockTransport('sql', (fn) => (fn === 'rbac_user_permissions' || fn === 'rbac_users_with_role' ? ['x'] : null))
    const rbac = new RbacClient({ transport: sqlKind(m) })
    expect(await rbac.admin.createRole({ role: 'editor', permissions: ['a'], inherits: ['viewer'] })).toEqual({ data: null, error: null })
    await rbac.admin.createRole({ role: 'viewer', permissions: [] })
    await rbac.admin.dropRole({ role: 'editor' })
    await rbac.admin.assignRole({ userId: 'alice', role: 'editor', scope: 'acme' })
    await rbac.admin.assignRole({ userId: 'alice', role: 'editor', scope: null })
    await rbac.admin.unassignRole({ userId: 'alice', role: 'editor' })
    expect(await rbac.admin.userPermissions({ userId: 'alice', scope: 'acme' })).toEqual({ data: ['x'], error: null })
    expect(await rbac.admin.usersWithRole({ role: 'editor' })).toEqual({ data: ['x'], error: null })
    expect(m.calls).toEqual([
      { fn: 'rbac_create_role', args: { role: 'editor', permissions: ['a'], inherits: ['viewer'] }, shape: 'void' },
      { fn: 'rbac_create_role', args: { role: 'viewer', permissions: [], inherits: undefined }, shape: 'void' },
      { fn: 'rbac_drop_role', args: { role: 'editor' }, shape: 'void' },
      { fn: 'rbac_assign_role', args: { user_id: 'alice', role: 'editor', scope: 'acme' }, shape: 'void' },
      { fn: 'rbac_assign_role', args: { user_id: 'alice', role: 'editor', scope: undefined }, shape: 'void' },
      { fn: 'rbac_unassign_role', args: { user_id: 'alice', role: 'editor', scope: undefined }, shape: 'void' },
      { fn: 'rbac_user_permissions', args: { user_id: 'alice', scope: 'acme' }, shape: 'scalar' },
      { fn: 'rbac_users_with_role', args: { role: 'editor', scope: undefined }, shape: 'set' },
    ])
  })

  it('wraps admin errors, and throws them with throwOnError', async () => {
    const error = new PermissionsError({ message: 'unknown role', code: '22023', details: "rbac:unknown_role role='x'" })
    const m = mockTransport('sql', () => error)
    expect(await new RbacClient({ transport: sqlKind(m) }).admin.dropRole({ role: 'x' })).toEqual({ data: null, error })
    const strict = new RbacClient({ transport: sqlKind(m), throwOnError: true })
    await expect(strict.admin.dropRole({ role: 'x' })).rejects.toBe(error)
  })

  it('has admin when a plain Transport has kind sql (runtime), without a typed admin', () => {
    const m = mockTransport('sql')
    const rbac = new RbacClient({ transport: m.transport })
    expect((rbac as unknown as { admin?: RbacAdminApi }).admin).toBeDefined()
  })

  it('has no admin property on a subject transport', () => {
    expect('admin' in new RbacClient({ transport: mockTransport('subject').transport })).toBe(false)
  })

  it('has no admin property on a PostgREST client', async () => {
    const rbac = new RbacClient('http://localhost:3000', { fetch: (async () => new Response('true')) as typeof fetch })
    expect('admin' in rbac).toBe(false)
    expect('admin' in new RbacClient({ transport: mockTransport('postgrest').transport })).toBe(false)
    expect(await rbac.hasRole({ role: 'r' })).toEqual({ data: true, error: null })
  })

  it('builds a PostgREST transport from the URL and options', async () => {
    const seen: { url: string; init: RequestInit }[] = []
    const rbac = new RbacClient('http://localhost:3000/', {
      headers: { Authorization: 'Bearer t' },
      schema: 'perms',
      fetch: (async (url: string, init: RequestInit) => {
        seen.push({ url, init })
        return new Response('false')
      }) as unknown as typeof fetch,
    })
    await rbac.hasPermission({ permission: 'p', scope: 'acme' })
    expect(seen[0]!.url).toBe('http://localhost:3000/rpc/rbac_has_permission')
    const headers = new Headers(seen[0]!.init.headers)
    expect(headers.get('Authorization')).toBe('Bearer t')
    expect(headers.get('Content-Profile')).toBe('perms')
    expect(JSON.parse(seen[0]!.init.body as string)).toEqual({ permission: 'p', scope: 'acme' })
  })

  it('throws for a bad constructor argument', () => {
    expect(() => new RbacClient({} as never)).toThrow(/PostgREST URL/)
  })
})

describe('RbacClient types', () => {
  type Names = { permissions: 'documents.read' | 'documents.edit'; roles: 'viewer' | 'editor' }
  const sql = mockTransport('sql').transport as SqlTransport
  const pgrst = mockTransport('postgrest').transport as Transport<'postgrest'>
  const subject = mockTransport('subject').transport as Transport<'subject'>
  const general: Transport = mockTransport('sql').transport

  it('types admin only on an SQL-kind transport', () => {
    expectTypeOf(new RbacClient({ transport: sql })).toEqualTypeOf<RbacClient<'sql'>>()
    expectTypeOf(new RbacClient({ transport: sql }).admin).toEqualTypeOf<RbacAdminApi>()
    expectTypeOf(new RbacClient({ transport: pgrst })).toEqualTypeOf<RbacClient<'postgrest'>>()
    expectTypeOf(new RbacClient({ transport: subject })).toEqualTypeOf<RbacClient<'subject'>>()
    expectTypeOf(new RbacClient('http://x')).toEqualTypeOf<RbacClient<'postgrest'>>()
    expectTypeOf(new RbacClient({ transport: general })).toEqualTypeOf<RbacClient>()
    const rest = new RbacClient('http://x')
    // @ts-expect-error a PostgREST client has no admin
    void rest.admin
    // @ts-expect-error a PostgREST transport has no admin
    void new RbacClient({ transport: pgrst }).admin
    // @ts-expect-error a subject transport has no admin
    void new RbacClient({ transport: subject }).admin
    // @ts-expect-error a general Transport has no typed admin
    void new RbacClient({ transport: general }).admin
  })

  it('keeps the kind with an explicit names argument', () => {
    expectTypeOf(new RbacClient<Names>({ transport: sql })).toEqualTypeOf<RbacClient<'sql', Names>>()
    expectTypeOf(new RbacClient<Names>({ transport: subject })).toEqualTypeOf<RbacClient<'subject', Names>>()
    expectTypeOf(new RbacClient<Names>('http://x')).toEqualTypeOf<RbacClient<'postgrest', Names>>()
  })

  it('narrows permission and role names with the generic', () => {
    const rbac = new RbacClient<Names>('http://x')
    void (() => {
      void rbac.hasPermission({ permission: 'documents.edit' })
      // @ts-expect-error not a permission of Names
      void rbac.hasPermission({ permission: 'documents.write' })
      void rbac.hasRole({ role: 'viewer' })
      // @ts-expect-error not a role of Names
      void rbac.hasRole({ role: 'admin' })
      const admin = new RbacClient<Names>({ transport: sql }).admin
      void admin.createRole({ role: 'editor', permissions: ['documents.edit'], inherits: ['viewer'] })
      // @ts-expect-error unknown inherited role
      void admin.createRole({ role: 'editor', permissions: [], inherits: ['nobody'] })
      // @ts-expect-error unknown role
      void admin.assignRole({ userId: 'u', role: 'nobody' })
    })
    // One key narrows, the other stays string.
    const partial = new RbacClient<{ roles: 'a' | 'b' }>('http://x')
    void (() => partial.hasPermission({ permission: 'anything' }))
  })
})
