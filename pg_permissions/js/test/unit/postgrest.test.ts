import { describe, expect, it, vi } from 'vitest'
import { postgrestTransport } from '../../src/transport/postgrest'
import { PermissionsError, PermissionsFetchError, PermissionsHttpError } from '../../src/lib/errors'

type Call = { url: string; init: RequestInit }

function mockFetch(respond: () => Response | Promise<Response>) {
  const calls: Call[] = []
  const fetch = vi.fn(async (url: unknown, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} })
    return respond()
  }) as unknown as typeof globalThis.fetch
  return { calls, fetch }
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

describe('postgrestTransport', () => {
  it('posts named arguments to /rpc/{fn} with the profile headers', async () => {
    const { calls, fetch } = mockFetch(() => json(true))
    const t = postgrestTransport('http://localhost:3000/', { fetch, headers: { apikey: 'k' } })
    expect(t.kind).toBe('postgrest')
    const data = await t.rpc('rbac_has_permission', { permission: 'documents.edit', scope: undefined }, 'scalar')
    expect(data).toBe(true)
    expect(calls).toHaveLength(1)
    const call = calls[0] as Call
    expect(call.url).toBe('http://localhost:3000/rpc/rbac_has_permission')
    expect(call.init.method).toBe('POST')
    expect(JSON.parse(call.init.body as string)).toEqual({ permission: 'documents.edit' })
    const h = new Headers(call.init.headers)
    expect(h.get('Content-Profile')).toBe('permissions')
    expect(h.get('Accept-Profile')).toBe('permissions')
    expect(h.get('Content-Type')).toBe('application/json')
    expect(h.get('apikey')).toBe('k')
  })

  it('uses the schema option', async () => {
    const { calls, fetch } = mockFetch(() => json('alice'))
    await postgrestTransport('http://x', { fetch, schema: 'authz' }).rpc('current_subject_id', {}, 'scalar')
    expect(new Headers(calls[0]?.init.headers).get('Content-Profile')).toBe('authz')
  })

  it('decodes each shape', async () => {
    const t = (body: string | null, status = 200) =>
      postgrestTransport('http://x', { fetch: mockFetch(() => new Response(body, { status })).fetch })
    expect(await t('["document:1","document:2"]').rpc('fga_list_objects_current', { type: 'document', relation: 'viewer' }, 'set')).toEqual([
      'document:1',
      'document:2',
    ])
    expect(await t('[]').rpc('fga_list_objects_current', { type: 'd', relation: 'r' }, 'set')).toEqual([])
    expect(await t('["acme"]').rpc('rbac_scopes_with_permission', { permission: 'p' }, 'scalar')).toEqual(['acme'])
    expect(await t('null').rpc('current_subject_id', {}, 'scalar')).toBeNull()
    expect(await t(null, 204).rpc('current_subject_id', {}, 'void')).toBeNull()
    expect(await t(null, 204).rpc('fga_list_objects_current', { type: 'd', relation: 'r' }, 'set')).toEqual([])
  })

  it('refuses admin functions without a request', async () => {
    const { calls, fetch } = mockFetch(() => json(null))
    const t = postgrestTransport('http://x', { fetch })
    await expect(t.rpc('rbac_assign_role', { user_id: 'u', role: 'r' }, 'void')).rejects.toThrow(/admin function/)
    await expect(t.rpc('fga_check', { subject: 'user:a', relation: 'r', object: 'o:1' }, 'scalar')).rejects.toThrow(
      /admin function/,
    )
    await expect(t.rpc('_unfolded_null', {}, 'scalar')).rejects.toThrow(/unknown function/)
    await expect(t.rpc('rbac_has_permission', { permission: 'p', plan_time_guard: true }, 'scalar')).rejects.toThrow(
      /no argument 'plan_time_guard'/,
    )
    expect(calls).toHaveLength(0)
  })

  it('maps a PostgREST error body to PermissionsError', async () => {
    const { fetch } = mockFetch(() =>
      json(
        {
          code: '22023',
          details: 'openfga:2000 validation_error',
          hint: "Did you mean 'viewer'?",
          message: "relation 'document#viewr' not found",
        },
        400,
      ),
    )
    const err = await postgrestTransport('http://x', { fetch })
      .rpc('fga_check_current', { relation: 'viewr', object: 'document:1' }, 'scalar')
      .catch((e: unknown) => e)
    expect(err).toBeInstanceOf(PermissionsError)
    expect(err).not.toBeInstanceOf(PermissionsHttpError)
    const e = err as PermissionsError
    expect(e.code).toBe('22023')
    expect(e.details).toBe('openfga:2000 validation_error')
    expect(e.hint).toBe("Did you mean 'viewer'?")
    expect(e.reason).toEqual({ model: 'openfga', code: 2000, name: 'validation_error' })
  })

  it('maps a PostgREST error with null fields', async () => {
    const { fetch } = mockFetch(() =>
      json({ code: 'PGRST202', details: null, hint: null, message: 'Could not find the function' }, 404),
    )
    const e = (await postgrestTransport('http://x', { fetch })
      .rpc('current_subject_id', {}, 'scalar')
      .catch((x: unknown) => x)) as PermissionsError
    expect(e).toBeInstanceOf(PermissionsError)
    expect(e.code).toBe('PGRST202')
    expect(e.details).toBeNull()
    expect(e.reason).toBeNull()
  })

  it('maps a non-JSON error to PermissionsHttpError', async () => {
    const { fetch } = mockFetch(() => new Response('<html>bad gateway</html>', { status: 502, statusText: 'Bad Gateway' }))
    const e = (await postgrestTransport('http://x', { fetch })
      .rpc('current_subject_id', {}, 'scalar')
      .catch((x: unknown) => x)) as PermissionsHttpError
    expect(e).toBeInstanceOf(PermissionsHttpError)
    expect(e.status).toBe(502)
    expect(e.body).toBe('<html>bad gateway</html>')
  })

  it('maps a non-JSON 200 to PermissionsHttpError', async () => {
    const { fetch } = mockFetch(() => new Response('not json', { status: 200 }))
    await expect(postgrestTransport('http://x', { fetch }).rpc('current_subject_id', {}, 'scalar')).rejects.toBeInstanceOf(
      PermissionsHttpError,
    )
  })

  it('maps a fetch failure to PermissionsFetchError', async () => {
    const cause = new TypeError('fetch failed')
    const { fetch } = mockFetch(() => {
      throw cause
    })
    const e = (await postgrestTransport('http://x', { fetch })
      .rpc('current_subject_id', {}, 'scalar')
      .catch((x: unknown) => x)) as PermissionsFetchError
    expect(e).toBeInstanceOf(PermissionsFetchError)
    expect(e.cause).toBe(cause)
  })
})
