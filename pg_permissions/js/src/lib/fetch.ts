import type { Fetch } from './types'

/**
 * Returns `customFetch`, or the global `fetch`. The global is read at call time,
 * so a polyfill that loads later still works.
 */
export function resolveFetch(customFetch?: Fetch): Fetch {
  if (customFetch) return (...args) => customFetch(...args)
  return (...args) => {
    if (typeof fetch !== 'function') {
      throw new Error('permissions: no global fetch. Pass one in the options: { global: { fetch } }.')
    }
    return fetch(...args)
  }
}

/**
 * Wraps `fetch` to add the Supabase auth headers, as supabase-js does:
 * `apikey: <key>` and `Authorization: Bearer <accessToken() ?? key>`.
 * A header that the request already has is not replaced. With no key and no
 * token, the request has no auth headers (plain PostgREST as `anon`).
 */
export function fetchWithAuth(
  key: string | null | undefined,
  accessToken?: () => Promise<string | null> | string | null,
  customFetch?: Fetch,
): Fetch {
  const f = resolveFetch(customFetch)
  return async (input, init) => {
    const token = (accessToken ? await accessToken() : null) ?? key ?? null
    const headers = new Headers(init?.headers)
    if (key && !headers.has('apikey')) headers.set('apikey', key)
    if (token && !headers.has('Authorization')) headers.set('Authorization', `Bearer ${token}`)
    return f(input, { ...init, headers })
  }
}
