import { PermissionsError, PermissionsFetchError, PermissionsHttpError } from '../lib/errors'
import { resolveFetch } from '../lib/fetch'
import { definedArgs, getFunctionSpec } from '../lib/functions'
import type { Fetch, RpcArgs, Shape, Transport } from '../lib/types'

export interface PostgrestTransportOptions {
  /** The schema of the extension. It must be in PostgREST `db-schemas`. Default `'permissions'`. */
  schema?: string
  /** Headers to send with every request, for example `apikey` and `Authorization`. */
  headers?: Record<string, string>
  /** A custom `fetch`, for example `fetchWithAuth(...)`. Default: the global `fetch`. */
  fetch?: Fetch
}

/**
 * A transport that calls `POST {restUrl}/rpc/{fn}` on PostgREST. It can call
 * only the client functions, which pg_permissions grants to PUBLIC. It refuses
 * every admin function.
 *
 * @param restUrl The PostgREST URL, for example `https://<project>.supabase.co/rest/v1`.
 */
export function postgrestTransport(restUrl: string, options: PostgrestTransportOptions = {}): Transport {
  const base = restUrl.replace(/\/+$/, '')
  const schema = options.schema ?? 'permissions'
  const headers = options.headers ?? {}
  const fetchFn = resolveFetch(options.fetch)

  return {
    kind: 'postgrest',
    async rpc<T>(fn: string, args: RpcArgs, shape: Shape): Promise<T> {
      const spec = getFunctionSpec(fn, args, 'postgrest')
      if (!spec.public) {
        throw new Error(
          `permissions (postgrest): '${fn}' is an admin function. Admin functions are not callable over PostgREST; use the SQL transport on a server.`,
        )
      }

      let response: Response
      try {
        response = await fetchFn(`${base}/rpc/${fn}`, {
          method: 'POST',
          headers: {
            ...headers,
            'Content-Type': 'application/json',
            Accept: 'application/json',
            'Content-Profile': schema,
            'Accept-Profile': schema,
          },
          body: JSON.stringify(definedArgs(args)),
        })
      } catch (error) {
        throw new PermissionsFetchError(`Failed to send a request to PostgREST: ${errorMessage(error)}`, error)
      }

      let text: string
      try {
        text = await response.text()
      } catch (error) {
        throw new PermissionsFetchError(`Failed to read the PostgREST response: ${errorMessage(error)}`, error)
      }

      if (!response.ok) {
        const body = parseJson(text)
        if (isPostgrestErrorBody(body)) {
          throw new PermissionsError({ message: body.message, details: body.details, hint: body.hint, code: body.code })
        }
        throw new PermissionsHttpError(response.status, response.statusText, text)
      }

      if (shape === 'void') return null as T
      if (text.trim() === '') return (shape === 'set' || shape === 'rows' ? [] : null) as T
      const body = parseJson(text)
      if (body === undefined) throw new PermissionsHttpError(response.status, response.statusText, text)
      return decode(body, shape) as T
    },
  }
}

function decode(body: unknown, shape: Shape): unknown {
  switch (shape) {
    case 'set':
    case 'rows':
      return Array.isArray(body) ? body : body === null ? [] : [body]
    case 'record':
      return Array.isArray(body) ? (body[0] ?? null) : body
    default:
      return body
  }
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text) as unknown
  } catch {
    return undefined
  }
}

interface PostgrestErrorBody {
  message: string
  details?: string | null
  hint?: string | null
  code?: string | null
}

function isPostgrestErrorBody(body: unknown): body is PostgrestErrorBody {
  return (
    typeof body === 'object' &&
    body !== null &&
    typeof (body as { message?: unknown }).message === 'string' &&
    'code' in body
  )
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
