import { toResult } from '../lib/result'
import type { BaseClientOptions, Result, Transport, TransportKind } from '../lib/types'
import { postgrestTransport } from '../transport/postgrest'
import type { PostgrestTransportOptions } from '../transport/postgrest'
import { CedarAdmin } from './CedarAdmin'
import type { CedarAdminApi } from './CedarAdmin'
import type { CurrentAuthorizationRequest, ListResourcesRequest } from './types'
import { uidText } from './uid'

/** Options of `new CedarClient(restUrl, options)`: a PostgREST client. */
export interface CedarPostgrestClientOptions extends PostgrestTransportOptions, BaseClientOptions {}

/** Options of `new CedarClient({ transport })`. */
export interface CedarTransportClientOptions<T extends Transport = Transport> extends BaseClientOptions {
  /** The transport, for example `sqlTransport(pool)` or `postgrestTransport(restUrl)`. */
  transport: T
}

/**
 * The client methods: they answer for the current subject, and work on
 * every transport. The principal is
 * `current_subject_type()::"current_subject_id()"`, for example
 * `user::"alice"`. Without a subject, every answer is `false` or empty.
 */
export interface CedarClientMethods {
  /**
   * Checks if the current subject may do `action` on `resource`
   * (`cedar_is_authorized_current`). It fails closed: the answer is
   * `true` only if the decision is allow and no forbid that applies erred.
   * The request has no context.
   *
   * @example
   * ```ts
   * const { data: canView } = await cedar.isAuthorized({
   *   action: 'Action::"view"',
   *   resource: { type: 'Document', id: 'q3' },
   * })
   *
   * // A row that is not a stored entity: pass its attributes.
   * const resourceAttrs = { owner: 'alice', level: 2 }
   * await cedar.isAuthorized({
   *   action: 'Action::"view"',
   *   resource: uid('Document', row.id),
   *   resourceAttrs,
   * })
   * ```
   */
  isAuthorized(request: CurrentAuthorizationRequest): Promise<Result<boolean>>

  /**
   * Lists the ids of the stored entities of `resourceType` that the
   * current subject may do `action` on (`cedar_list_resources_current`).
   * The ids have no type. There is no cap on the number of results.
   *
   * @example
   * ```ts
   * // { data: ['q3', 'q4'] }
   * await cedar.listResources({
   *   action: 'Action::"view"',
   *   resourceType: 'Document',
   * })
   * ```
   */
  listResources(request: ListResourcesRequest): Promise<Result<string[]>>
}

/**
 * The type of a `CedarClient` on a transport of kind `K` (see {@link TransportKind}).
 *
 * `admin` is part of the type only when `K` is exactly `'sql'`:
 *
 * - `sqlTransport(pool)` gives `CedarClient<'sql'>`, with `admin`.
 * - `postgrestTransport(url)` and `new CedarClient(restUrl)` give `CedarClient<'postgrest'>`, without `admin`.
 * - `sqlTransport(pool).withSubject(...)` gives `CedarClient<'subject'>`, without `admin`:
 *   the calls run as the end user.
 *
 * A transport typed as the general `Transport` gives `K = TransportKind`: the type
 * then has no `admin`, even if the runtime object has one. Use `'admin' in client`
 * to narrow such a client.
 */
export type CedarClient<K extends TransportKind = TransportKind> = CedarClientMethods &
  ([K] extends ['sql'] ? { readonly admin: CedarAdminApi } : unknown)

/**
 * The constructor of `CedarClient`. It has two forms:
 *
 * - `new CedarClient(restUrl, options?)`: PostgREST. No `admin`.
 * - `new CedarClient({ transport, throwOnError? })`: the kind of the transport
 *   decides. With `sqlTransport(pool)` (kind `'sql'`), the client has `admin`.
 */
export interface CedarClientConstructor {
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
   * const cedar = new CedarClient(REST_URL, { headers })
   * const { data } = await cedar.isAuthorized({
   *   action: 'Action::"view"',
   *   resource: 'Document::"q3"',
   * })
   * ```
   */
  new (restUrl: string, options?: CedarPostgrestClientOptions): CedarClient<'postgrest'>

  /**
   * A client on a transport. With an SQL transport, it has `admin`.
   *
   * @example
   * ```ts
   * import { sqlTransport } from 'permissions/sql'
   *
   * const transport = sqlTransport(pool)
   * const cedar = new CedarClient({ transport })
   * const policy = `permit (
   *   principal == user::"alice",
   *   action == Action::"view",
   *   resource
   * );`
   * await cedar.admin.putPolicy({ policyId: 'alice-view', policy })
   *
   * // A subject-scoped transport: client methods only, no admin.
   * const aliceTransport = transport.withSubject({ id: 'alice' })
   * const alice = new CedarClient({ transport: aliceTransport })
   * // { data: true, error: null }
   * await alice.isAuthorized({
   *   action: 'Action::"view"',
   *   resource: 'Document::"q3"',
   * })
   * ```
   */
  new <K extends TransportKind>(options: CedarTransportClientOptions<Transport<K>>): CedarClient<K>

  readonly prototype: CedarClient
}

class CedarClientImpl implements CedarClientMethods {
  private readonly transport: Transport
  private readonly throwOnError: boolean
  declare readonly admin?: CedarAdminApi

  constructor(restUrlOrOptions: string | CedarTransportClientOptions, options: CedarPostgrestClientOptions = {}) {
    if (typeof restUrlOrOptions === 'string') {
      const { throwOnError, ...transportOptions } = options
      this.transport = postgrestTransport(restUrlOrOptions, transportOptions)
      this.throwOnError = throwOnError ?? false
    } else {
      if (!restUrlOrOptions || typeof restUrlOrOptions.transport?.rpc !== 'function') {
        throw new Error('permissions: new CedarClient() needs a PostgREST URL or { transport }')
      }
      this.transport = restUrlOrOptions.transport
      this.throwOnError = restUrlOrOptions.throwOnError ?? false
    }
    // Admin functions never go over HTTP: only an SQL transport gets the namespace.
    if (this.transport.kind === 'sql') {
      Object.defineProperty(this, 'admin', {
        value: new CedarAdmin(this.transport, this.throwOnError),
        enumerable: true,
      })
    }
  }

  isAuthorized(request: CurrentAuthorizationRequest): Promise<Result<boolean>> {
    return toResult(
      this.transport
        .rpc<boolean | null>(
          'cedar_is_authorized_current',
          {
            action: uidText(request.action),
            resource: uidText(request.resource),
            resource_attrs: request.resourceAttrs,
          },
          'scalar',
        )
        .then((allowed) => allowed === true),
      this.throwOnError,
    )
  }

  listResources(request: ListResourcesRequest): Promise<Result<string[]>> {
    return toResult(
      this.transport.rpc<string[]>(
        'cedar_list_resources_current',
        { action: uidText(request.action), resource_type: request.resourceType },
        'set',
      ),
      this.throwOnError,
    )
  }
}

/**
 * The Cedar client: Cedar policies evaluated in Postgres.
 *
 * Every method returns `{ data, error }`; with `throwOnError: true` it throws
 * the `PermissionsError` instead.
 *
 * The client methods (`isAuthorized`, `listResources`) answer for the
 * current subject and work on both transports. `admin` (policies,
 * templates, entities, and requests for any principal) exists only on an
 * SQL client, at runtime and in the type: see {@link CedarClient} (the
 * type) and {@link CedarClientConstructor}.
 *
 * @example
 * ```ts
 * // Browser: PostgREST, current subject from the JWT.
 * const headers = { Authorization: `Bearer ${jwt}` }
 * const cedar = new CedarClient(restUrl, { headers })
 * await cedar.listResources({
 *   action: 'Action::"view"',
 *   resourceType: 'Document',
 * })
 *
 * // Server: SQL, with admin.
 * const transport = sqlTransport(pool)
 * const server = new CedarClient({ transport })
 * await server.admin.isAuthorized({
 *   principal: 'User::"alice"',
 *   action: 'Action::"view"',
 *   resource: 'Document::"q3"',
 * })
 * ```
 */
export const CedarClient: CedarClientConstructor = CedarClientImpl as unknown as CedarClientConstructor
