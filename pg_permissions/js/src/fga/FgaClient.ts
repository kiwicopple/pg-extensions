import { toResult } from '../lib/result'
import type { BaseClientOptions, Result, Transport, TransportKind } from '../lib/types'
import { postgrestTransport } from '../transport/postgrest'
import type { PostgrestTransportOptions } from '../transport/postgrest'
import { FgaAdmin } from './FgaAdmin'
import type { FgaAdminApi } from './FgaAdmin'
import type { CurrentCheckRequest, CurrentListObjectsRequest } from './types'

/** Options of `new FgaClient(restUrl, options)`: a PostgREST client. */
export interface FgaPostgrestClientOptions extends PostgrestTransportOptions, BaseClientOptions {}

/** Options of `new FgaClient({ transport })`. */
export interface FgaTransportClientOptions<T extends Transport = Transport> extends BaseClientOptions {
  /** The transport, for example `sqlTransport(pool)` or `postgrestTransport(restUrl)`. */
  transport: T
}

/** The client methods: they answer for the current subject, and work on every transport. */
export interface FgaClientMethods {
  /**
   * Checks if the current subject has `relation` to `object` (`fga_check_current`).
   * Without a subject or a model, the answer is `false`.
   *
   * @example
   * ```ts
   * const { data: canView } = await fga.check({
   *   relation: 'viewer',
   *   object: 'document:1',
   * })
   * ```
   */
  check(request: CurrentCheckRequest): Promise<Result<boolean>>

  /**
   * Lists the objects of `type` that the current subject has `relation` to
   * (`fga_list_objects_current`, or `fga_list_object_ids_current` with `idsOnly`).
   * There is no cap on the number of results.
   *
   * @example
   * ```ts
   * // { data: ['document:1'] }
   * await fga.listObjects({ type: 'document', relation: 'viewer' })
   *
   * // { data: ['1'] }
   * await fga.listObjects({
   *   type: 'document',
   *   relation: 'viewer',
   *   idsOnly: true,
   * })
   * ```
   */
  listObjects(request: CurrentListObjectsRequest): Promise<Result<string[]>>
}

/**
 * The type of an `FgaClient` on a transport of kind `K` (see {@link TransportKind}).
 *
 * `admin` is part of the type only when `K` is exactly `'sql'`:
 *
 * - `sqlTransport(pool)` gives `FgaClient<'sql'>`, with `admin`.
 * - `postgrestTransport(url)` and `new FgaClient(restUrl)` give `FgaClient<'postgrest'>`, without `admin`.
 * - `sqlTransport(pool).withSubject(...)` gives `FgaClient<'subject'>`, without `admin`:
 *   the calls run as the end user.
 *
 * A transport typed as the general `Transport` gives `K = TransportKind`: the type
 * then has no `admin`, even if the runtime object has one. Use `'admin' in client`
 * to narrow such a client.
 */
export type FgaClient<K extends TransportKind = TransportKind> = FgaClientMethods &
  ([K] extends ['sql'] ? { readonly admin: FgaAdminApi } : unknown)

/**
 * The constructor of `FgaClient`. It has two forms:
 *
 * - `new FgaClient(restUrl, options?)`: PostgREST. No `admin`.
 * - `new FgaClient({ transport, throwOnError? })`: the kind of the transport
 *   decides. With `sqlTransport(pool)` (kind `'sql'`), the client has `admin`.
 */
export interface FgaClientConstructor {
  /**
   * A client over PostgREST, for a browser or an edge function. It can call
   * only the client (current-subject) functions, and has no `admin`.
   *
   * @param restUrl The PostgREST URL, for example `https://<project>.supabase.co/rest/v1`.
   * @example
   * ```ts
   * const REST_URL = 'https://<project>.supabase.co/rest/v1'
   * const headers = {
   *   apikey: ANON_KEY,
   *   Authorization: `Bearer ${accessToken}`,
   * }
   * const fga = new FgaClient(REST_URL, { headers })
   * const { data } = await fga.check({
   *   relation: 'viewer',
   *   object: 'document:1',
   * })
   * ```
   */
  new (restUrl: string, options?: FgaPostgrestClientOptions): FgaClient<'postgrest'>

  /**
   * A client on a transport. With an SQL transport, it has `admin`.
   *
   * @example
   * ```ts
   * import { sqlTransport } from 'permissions/sql'
   *
   * const transport = sqlTransport(pool)
   * const fga = new FgaClient({ transport })
   * await fga.admin.writeTuple({
   *   user: 'user:anne',
   *   relation: 'viewer',
   *   object: 'document:1',
   * })
   *
   * // A subject-scoped transport: client methods only, no admin.
   * const anneTransport = transport.withSubject({ id: 'anne' })
   * const anne = new FgaClient({ transport: anneTransport })
   * // { data: true, error: null }
   * await anne.check({ relation: 'viewer', object: 'document:1' })
   * ```
   */
  new <K extends TransportKind>(options: FgaTransportClientOptions<Transport<K>>): FgaClient<K>

  readonly prototype: FgaClient
}

class FgaClientImpl implements FgaClientMethods {
  private readonly transport: Transport
  private readonly throwOnError: boolean
  declare readonly admin?: FgaAdminApi

  constructor(restUrlOrOptions: string | FgaTransportClientOptions, options: FgaPostgrestClientOptions = {}) {
    if (typeof restUrlOrOptions === 'string') {
      const { throwOnError, ...transportOptions } = options
      this.transport = postgrestTransport(restUrlOrOptions, transportOptions)
      this.throwOnError = throwOnError ?? false
    } else {
      if (!restUrlOrOptions || typeof restUrlOrOptions.transport?.rpc !== 'function') {
        throw new Error('permissions: new FgaClient() needs a PostgREST URL or { transport }')
      }
      this.transport = restUrlOrOptions.transport
      this.throwOnError = restUrlOrOptions.throwOnError ?? false
    }
    // Admin functions never go over HTTP: only an SQL transport gets the namespace.
    if (this.transport.kind === 'sql') {
      Object.defineProperty(this, 'admin', {
        value: new FgaAdmin(this.transport, this.throwOnError),
        enumerable: true,
      })
    }
  }

  check(request: CurrentCheckRequest): Promise<Result<boolean>> {
    return toResult(
      this.transport
        .rpc<boolean | null>('fga_check_current', { relation: request.relation, object: request.object }, 'scalar')
        .then((allowed) => allowed === true),
      this.throwOnError,
    )
  }

  listObjects(request: CurrentListObjectsRequest): Promise<Result<string[]>> {
    const fn = request.idsOnly ? 'fga_list_object_ids_current' : 'fga_list_objects_current'
    return toResult(
      this.transport.rpc<string[]>(fn, { type: request.type, relation: request.relation }, 'set'),
      this.throwOnError,
    )
  }
}

/**
 * The FGA client: OpenFGA checks in Postgres.
 *
 * Every method returns `{ data, error }`; with `throwOnError: true` it throws
 * the `PermissionsError` instead.
 *
 * The client methods (`check`, `listObjects`) answer for the current subject
 * and work on both transports. `admin` (an explicit subject, models and tuples)
 * exists only on an SQL client, at runtime and in the type: see {@link FgaClient}
 * (the type) and {@link FgaClientConstructor}.
 *
 * @example
 * ```ts
 * // Browser: PostgREST, current subject from the JWT.
 * const headers = { Authorization: `Bearer ${jwt}` }
 * const fga = new FgaClient(restUrl, { headers })
 * await fga.listObjects({ type: 'document', relation: 'viewer' })
 *
 * // Server: SQL, with admin.
 * const transport = sqlTransport(pool)
 * const server = new FgaClient({ transport })
 * await server.admin.check({
 *   user: 'user:anne',
 *   relation: 'viewer',
 *   object: 'document:1',
 * })
 * ```
 */
export const FgaClient: FgaClientConstructor = FgaClientImpl as unknown as FgaClientConstructor
