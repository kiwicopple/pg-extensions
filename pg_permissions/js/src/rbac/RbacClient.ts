import { toResult } from '../lib/result'
import type { Fetch, Result, Transport } from '../lib/types'
import { postgrestTransport } from '../transport/postgrest'

/**
 * The optional name types of a client. Pass them as the first type argument to
 * narrow the `permission` and `role` parameters to string literal unions:
 *
 * ```ts
 * type Names = { permissions: 'documents.read' | 'documents.edit'; roles: 'viewer' | 'editor' }
 * const rbac = new RbacClient<Names>(restUrl)
 * rbac.hasPermission({ permission: 'documents.edit' }) // ok
 * rbac.hasPermission({ permission: 'documents.write' }) // type error
 * ```
 *
 * Each key is optional. A missing key leaves that name as `string`.
 */
export interface RbacNames {
  permissions?: string
  roles?: string
}

/** The permission names of `N`: `string` unless `N` narrows them. */
export type PermissionName<N extends RbacNames> = N extends { permissions: infer P extends string } ? P : string
/** The role names of `N`: `string` unless `N` narrows them. */
export type RoleName<N extends RbacNames> = N extends { roles: infer R extends string } ? R : string

/**
 * A scope. `null` and `undefined` both mean app-wide: the assignment, or the
 * check, that has no scope.
 */
export type Scope = string | null | undefined

/** Options of a client that talks to PostgREST. */
export interface RbacPostgrestOptions {
  /** Headers to send with every request, for example `apikey` and `Authorization`. */
  headers?: Record<string, string>
  /** A custom `fetch`. Default: the global `fetch`. */
  fetch?: Fetch
  /** The schema of the extension. It must be in PostgREST `db-schemas`. Default `'permissions'`. */
  schema?: string
  /** Throw the error instead of returning it in `{ data, error }`. Default `false`. */
  throwOnError?: boolean
}

/** Options of a client that uses a given transport. */
export interface RbacTransportOptions<T extends Transport = Transport> {
  /** The transport, for example `sqlTransport(pool)` or `postgrestTransport(url)`. */
  transport: T
  /** Throw the error instead of returning it in `{ data, error }`. Default `false`. */
  throwOnError?: boolean
}

/** The transport type that gives a client an `admin` namespace: a transport with `kind: 'sql'`. */
export type SqlKindTransport = Transport & { readonly kind: 'sql' }

/**
 * The current-subject checks. They answer for the subject of the request (the
 * JWT `sub` over PostgREST, or the subject of `withSubject()` over SQL), and
 * they work over both transports.
 */
export interface RbacClient<N extends RbacNames = RbacNames> {
  /**
   * Checks whether the current subject has a permission, directly or through an inherited role.
   *
   * @example
   * const { data, error } = await rbac.hasPermission({ permission: 'documents.edit', scope: 'acme' })
   */
  hasPermission(args: { permission: PermissionName<N>; scope?: Scope }): Promise<Result<boolean>>

  /**
   * Checks whether the current subject has a role, directly or through a role that inherits it.
   *
   * @example
   * const { data, error } = await rbac.hasRole({ role: 'editor', scope: 'acme' })
   */
  hasRole(args: { role: RoleName<N>; scope?: Scope }): Promise<Result<boolean>>

  /**
   * Lists the scopes in which the current subject has a permission. App-wide assignments have no scope and do not count.
   *
   * @example
   * const { data: scopes } = await rbac.scopesWithPermission({ permission: 'documents.read' })
   */
  scopesWithPermission(args: { permission: PermissionName<N> }): Promise<Result<string[]>>
}

/**
 * The admin calls. They exist only on a client with an SQL transport, and they run
 * as the role of the database connection, so use them on a server only.
 */
export interface RbacAdminApi<N extends RbacNames = RbacNames> {
  /**
   * Creates a role with permissions and inherited roles. A role cannot change after creation.
   *
   * @example
   * await rbac.admin.createRole({ role: 'editor', permissions: ['documents.edit'], inherits: ['viewer'] })
   */
  createRole(args: {
    role: RoleName<N>
    permissions: PermissionName<N>[]
    inherits?: RoleName<N>[]
  }): Promise<Result<null>>

  /**
   * Drops a role and its assignments. It fails when another role inherits the role.
   *
   * @example
   * await rbac.admin.dropRole({ role: 'editor' })
   */
  dropRole(args: { role: RoleName<N> }): Promise<Result<null>>

  /**
   * Gives a user a role, in a scope or app-wide. It does nothing when the user already has the role there.
   *
   * @example
   * await rbac.admin.assignRole({ userId: 'alice', role: 'editor', scope: 'acme' })
   */
  assignRole(args: { userId: string; role: RoleName<N>; scope?: Scope }): Promise<Result<null>>

  /**
   * Removes a role from a user in a scope, or app-wide. It does nothing when the user does not have the role there.
   *
   * @example
   * await rbac.admin.unassignRole({ userId: 'alice', role: 'editor', scope: 'acme' })
   */
  unassignRole(args: { userId: string; role: RoleName<N>; scope?: Scope }): Promise<Result<null>>

  /**
   * Lists the permissions of a user in a scope, or app-wide, sorted by name. Inherited permissions are included.
   *
   * @example
   * const { data } = await rbac.admin.userPermissions({ userId: 'alice', scope: 'acme' })
   */
  userPermissions(args: { userId: string; scope?: Scope }): Promise<Result<string[]>>

  /**
   * Lists the users that have a role in a scope, or app-wide, directly or through a role that inherits it.
   *
   * @example
   * const { data } = await rbac.admin.usersWithRole({ role: 'editor', scope: 'acme' })
   */
  usersWithRole(args: { role: RoleName<N>; scope?: Scope }): Promise<Result<string[]>>
}

/** An RBAC client with an SQL transport: the checks of {@link RbacClient} and the `admin` namespace. */
export interface RbacSqlClient<N extends RbacNames = RbacNames> extends RbacClient<N> {
  /** The admin calls. Server side only. */
  readonly admin: RbacAdminApi<N>
}

/**
 * The constructor of {@link RbacClient}. Its overloads give the typing rule for `admin`:
 *
 * - `new RbacClient(restUrl, options?)` builds a PostgREST transport and returns an
 *   {@link RbacClient}. It has no `admin`, at type level or at runtime.
 * - `new RbacClient({ transport })` with a transport typed `kind: 'sql'` (for example
 *   `sqlTransport(pool)`) returns an {@link RbacSqlClient}, which has `admin`.
 * - `new RbacClient({ transport })` with any other `Transport` type returns an
 *   {@link RbacClient} without a typed `admin`. At runtime the client still has
 *   `admin` when `transport.kind` is `'sql'`.
 *
 * The first type argument narrows the names (see {@link RbacNames}).
 */
export interface RbacClientConstructor {
  new <N extends RbacNames = RbacNames>(restUrl: string, options?: RbacPostgrestOptions): RbacClient<N>
  new <N extends RbacNames = RbacNames>(options: RbacTransportOptions<SqlKindTransport>): RbacSqlClient<N>
  new <N extends RbacNames = RbacNames>(options: RbacTransportOptions): RbacClient<N>
  readonly prototype: RbacClient
}

class RbacClientImpl<N extends RbacNames> implements RbacClient<N> {
  private readonly transport: Transport
  private readonly throwOnError: boolean
  /** Only on a client with an SQL transport. */
  readonly admin?: RbacAdminApi<N>

  constructor(restUrlOrOptions: string | RbacTransportOptions, options: RbacPostgrestOptions = {}) {
    if (typeof restUrlOrOptions === 'string') {
      const { throwOnError, ...transportOptions } = options
      this.transport = postgrestTransport(restUrlOrOptions, transportOptions)
      this.throwOnError = throwOnError ?? false
    } else {
      if (!restUrlOrOptions || typeof restUrlOrOptions.transport?.rpc !== 'function') {
        throw new Error('permissions (rbac): pass a PostgREST URL, or { transport }')
      }
      this.transport = restUrlOrOptions.transport
      this.throwOnError = restUrlOrOptions.throwOnError ?? false
    }
    if (this.transport.kind === 'sql') {
      this.admin = createAdminApi<N>(this.transport, this.throwOnError)
    } else {
      // No `admin` property at all on a PostgREST client.
      delete (this as { admin?: unknown }).admin
    }
  }

  hasPermission({ permission, scope }: { permission: PermissionName<N>; scope?: Scope }): Promise<Result<boolean>> {
    return toResult(
      this.transport.rpc<boolean>('rbac_has_permission', { permission, scope: scope ?? undefined }, 'scalar'),
      this.throwOnError,
    )
  }

  hasRole({ role, scope }: { role: RoleName<N>; scope?: Scope }): Promise<Result<boolean>> {
    return toResult(
      this.transport.rpc<boolean>('rbac_has_role', { role, scope: scope ?? undefined }, 'scalar'),
      this.throwOnError,
    )
  }

  scopesWithPermission({ permission }: { permission: PermissionName<N> }): Promise<Result<string[]>> {
    // Never send plan_time_guard: the function spec does not list it.
    return toResult(this.transport.rpc<string[]>('rbac_scopes_with_permission', { permission }, 'scalar'), this.throwOnError)
  }
}

function createAdminApi<N extends RbacNames>(transport: Transport, throwOnError: boolean): RbacAdminApi<N> {
  const call = <T>(fn: string, args: Record<string, unknown>, shape: 'scalar' | 'set' | 'void') =>
    toResult(transport.rpc<T>(fn, args, shape), throwOnError)
  return {
    createRole: ({ role, permissions, inherits }) =>
      call<null>('rbac_create_role', { role, permissions, inherits }, 'void'),
    dropRole: ({ role }) => call<null>('rbac_drop_role', { role }, 'void'),
    assignRole: ({ userId, role, scope }) =>
      call<null>('rbac_assign_role', { user_id: userId, role, scope: scope ?? undefined }, 'void'),
    unassignRole: ({ userId, role, scope }) =>
      call<null>('rbac_unassign_role', { user_id: userId, role, scope: scope ?? undefined }, 'void'),
    userPermissions: ({ userId, scope }) =>
      call<string[]>('rbac_user_permissions', { user_id: userId, scope: scope ?? undefined }, 'scalar'),
    usersWithRole: ({ role, scope }) =>
      call<string[]>('rbac_users_with_role', { role, scope: scope ?? undefined }, 'set'),
  }
}

/**
 * The RBAC client.
 *
 * A client from `new RbacClient(restUrl, options)` talks to PostgREST and has only the
 * current-subject checks. A client from `new RbacClient({ transport: sqlTransport(pool) })`
 * also has `admin`. See {@link RbacClientConstructor} for the typing rule.
 *
 * @example
 * // Client side: PostgREST, with the user's JWT
 * const rbac = new RbacClient('https://project.supabase.co/rest/v1', {
 *   headers: { apikey: ANON_KEY, Authorization: `Bearer ${jwt}` },
 * })
 * await rbac.hasPermission({ permission: 'documents.edit', scope: 'acme' })
 *
 * @example
 * // Server side: SQL, with admin calls
 * const rbac = new RbacClient({ transport: sqlTransport(pool) })
 * await rbac.admin.assignRole({ userId: 'alice', role: 'editor', scope: 'acme' })
 */
export const RbacClient: RbacClientConstructor = RbacClientImpl as unknown as RbacClientConstructor
