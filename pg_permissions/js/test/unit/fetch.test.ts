import { describe, expect, it, vi } from 'vitest'
import { fetchWithAuth, resolveFetch } from '../../src/lib/fetch'
import { toResult } from '../../src/lib/result'
import { PermissionsError } from '../../src/lib/errors'

function recorder() {
  const calls: Array<{ input: unknown; init: RequestInit | undefined }> = []
  const fetch = vi.fn(async (input: unknown, init?: RequestInit) => {
    calls.push({ input, init })
    return new Response('true', { status: 200 })
  }) as unknown as typeof globalThis.fetch
  return { calls, fetch }
}

const headersOf = (init: RequestInit | undefined) => new Headers(init?.headers)

describe('fetchWithAuth', () => {
  it('sends apikey and the key as bearer when there is no token', async () => {
    const { calls, fetch } = recorder()
    await fetchWithAuth('anon-key', async () => null, fetch)('http://x/rpc/f', { method: 'POST' })
    const h = headersOf(calls[0]?.init)
    expect(h.get('apikey')).toBe('anon-key')
    expect(h.get('Authorization')).toBe('Bearer anon-key')
    expect(calls[0]?.init?.method).toBe('POST')
  })

  it('sends the access token as bearer', async () => {
    const { calls, fetch } = recorder()
    await fetchWithAuth('anon-key', () => 'jwt', fetch)('http://x', {})
    const h = headersOf(calls[0]?.init)
    expect(h.get('apikey')).toBe('anon-key')
    expect(h.get('Authorization')).toBe('Bearer jwt')
  })

  it('calls accessToken on every request', async () => {
    const { calls, fetch } = recorder()
    let n = 0
    const f = fetchWithAuth('k', async () => `t${++n}`, fetch)
    await f('http://x')
    await f('http://x')
    expect(headersOf(calls[1]?.init).get('Authorization')).toBe('Bearer t2')
  })

  it('does not replace headers the request has', async () => {
    const { calls, fetch } = recorder()
    await fetchWithAuth('k', () => 't', fetch)('http://x', {
      headers: { apikey: 'other', Authorization: 'Bearer mine', 'X-Extra': '1' },
    })
    const h = headersOf(calls[0]?.init)
    expect(h.get('apikey')).toBe('other')
    expect(h.get('Authorization')).toBe('Bearer mine')
    expect(h.get('X-Extra')).toBe('1')
  })

  it('sends no auth headers without a key or a token', async () => {
    const { calls, fetch } = recorder()
    await fetchWithAuth(undefined, undefined, fetch)('http://x')
    const h = headersOf(calls[0]?.init)
    expect(h.has('apikey')).toBe(false)
    expect(h.has('Authorization')).toBe(false)
  })
})

describe('resolveFetch', () => {
  it('uses the custom fetch', async () => {
    const { calls, fetch } = recorder()
    await resolveFetch(fetch)('http://x')
    expect(calls).toHaveLength(1)
  })

  it('reads the global fetch at call time', async () => {
    const { calls, fetch } = recorder()
    const f = resolveFetch()
    vi.stubGlobal('fetch', fetch)
    try {
      await f('http://x')
    } finally {
      vi.unstubAllGlobals()
    }
    expect(calls).toHaveLength(1)
  })
})

describe('toResult', () => {
  it('wraps data', async () => {
    expect(await toResult(Promise.resolve(1))).toEqual({ data: 1, error: null })
  })

  it('returns a PermissionsError as error, or throws it with throwOnError', async () => {
    const e = new PermissionsError({ message: 'm', code: '42501' })
    expect(await toResult(Promise.reject(e))).toEqual({ data: null, error: e })
    await expect(toResult(Promise.reject(e), true)).rejects.toBe(e)
  })

  it('always throws other errors', async () => {
    const e = new Error('programming error')
    await expect(toResult(Promise.reject(e))).rejects.toBe(e)
  })
})
