import { FgaClient } from './fga/FgaClient'
import { fetchWithAuth } from './lib/fetch'
import { toResult } from './lib/result'
import type { PostgrestClientOptions, Result, SqlClientOptions, Subject, Transport } from './lib/types'
import { RbacClient } from './rbac/RbacClient'
import type { RbacNames } from './rbac/RbacClient'
import { postgrestTransport } from './transport/postgrest'
import { sqlTransport } from './transport/sql'
import type { Queryable, SqlTransport } from './transport/sql'

/** `current_subject_id`: a null from the driver or from PostgREST is `null`. */
function subjectId(transport: Transport, throwOnError: boolean): Promise<Result<string | null>> {
  return toResult(
    transport.rpc<string | null | undefined>('current_subject_id', {}, 'scalar').then((id) => id ?? null),
    throwOnError,
  )
}

/** `current_subject_type`: `'user'` when the subject has no type. */
function subjectType(transport: Transport, throwOnError: boolean): Promise<Result<string>> {
  return toResult(transport.rpc<string>('current_subject_type', {}, 'scalar'), throwOnError)
}

/**
 * The client of {@link createClient}: the RBAC and FGA checks for the user of
 * the access token, over PostgREST. It has no `admin` namespaces: admin calls
 * never go over HTTP.
 */
export class PermissionsClient<N extends RbacNames = RbacNames> {
  /** The RBAC checks for the current user. */
  readonly rbac: RbacClient<'postgrest', N>
  /** The FGA checks for the current user. */
  readonly fga: FgaClient<'postgrest'>
  private readonly transport: Transport<'postgrest'>
  private readonly throwOnError: boolean

  /** Use {@link createClient}. */
  constructor(transport: Transport<'postgrest'>, options: { throwOnError?: boolean } = {}) {
    const throwOnError = options.throwOnError ?? false
    this.transport = transport
    this.throwOnError = throwOnError
    this.rbac = new RbacClient<N>({ transport, throwOnError })
    this.fga = new FgaClient({ transport, throwOnError })
  }

  /**
   * Returns the id of the current subject (`current_subject_id()`): the `sub`
   * claim of the access token. The data is `null` when there is no subject, for
   * example with the anon key.
   *
   * @example
   * ```ts
   * const { data: id } = await permissions.currentSubjectId() // 'alice', or null
   * ```
   */
  currentSubjectId(): Promise<Result<string | null>> {
    return subjectId(this.transport, this.throwOnError)
  }

  /**
   * Returns the type of the current subject (`current_subject_type()`). The
   * default is `'user'`.
   *
   * @example
   * ```ts
   * const { data: type } = await permissions.currentSubjectType() // 'user'
   * ```
   */
  currentSubjectType(): Promise<Result<string>> {
    return subjectType(this.transport, this.throwOnError)
  }
}

/**
 * Creates a client for a browser or an edge function. It calls the client
 * functions of pg_permissions over PostgREST (`POST {restUrl}/rpc/{fn}`), as
 * the user of the access token. It has no `admin` namespaces.
 *
 * The arguments are the same as for supabase-js' `createClient`. Each request
 * has the headers `apikey: <key>` and `Authorization: Bearer <accessToken() ?? key>`.
 * A header in `global.headers` is not replaced.
 *
 * The `permissions` schema (or `db.schema`) must be exposed by PostgREST. In
 * Supabase, add it to "Exposed schemas" in the API settings.
 *
 * @param url The Supabase project URL. The PostgREST URL is `<url>/rest/v1`, unless `options.restUrl` is set.
 * @param key The Supabase anon (publishable) key, or another JWT that PostgREST accepts.
 * @param options See {@link PostgrestClientOptions}.
 * @typeParam N Narrows the permission and role names (see {@link RbacNames}).
 *
 * @example
 * ```ts
 * import { createClient } from 'permissions'
 *
 * const permissions = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
 *   accessToken: async () => (await supabase.auth.getSession()).data.session?.access_token ?? null,
 * })
 * const { data: canEdit } = await permissions.rbac.hasPermission({ permission: 'documents.edit', scope: 'acme' })
 * const { data: canView } = await permissions.fga.check({ relation: 'viewer', object: 'document:1' })
 * ```
 *
 * @example
 * ```ts
 * // Plain PostgREST (no /rest/v1 prefix)
 * const permissions = createClient(POSTGREST_URL, ANON_JWT, { restUrl: POSTGREST_URL })
 * ```
 */
export function createClient<N extends RbacNames = RbacNames>(
  url: string,
  key: string,
  options: PostgrestClientOptions = {},
): PermissionsClient<N> {
  if (!options.restUrl && (typeof url !== 'string' || url === '')) {
    throw new Error('permissions: createClient needs a URL (the Supabase project URL), or options.restUrl')
  }
  if (typeof key !== 'string' || key === '') {
    throw new Error('permissions: createClient needs a key (the Supabase anon or publishable key)')
  }
  const restUrl = options.restUrl ?? `${url.replace(/\/+$/, '')}/rest/v1`
  const transport = postgrestTransport(restUrl, {
    schema: options.db?.schema,
    headers: options.global?.headers,
    fetch: fetchWithAuth(key, options.accessToken, options.global?.fetch),
  })
  return new PermissionsClient<N>(transport, { throwOnError: options.throwOnError })
}

/** A subject for `admin.deleteSubject()` of {@link PermissionsServerClient}. */
export interface SubjectRef {
  /** The subject type, for example `'user'` or `'team'`. */
  type: string
  /** The subject id. */
  id: string
}

/** The admin calls that are not RBAC or FGA calls. Server side only. */
export interface PermissionsAdminApi {
  /**
   * Deletes everything about a subject (`delete_subject`): its RBAC assignments
   * (for type `'user'`) and every FGA tuple where it is the user or the object.
   * Call it when a user account is deleted.
   *
   * @returns The number of rows deleted.
   * @example
   * ```ts
   * const { data: deleted } = await permissions.admin.deleteSubject({ type: 'user', id: userId })
   * ```
   */
  deleteSubject(subject: SubjectRef): Promise<Result<number>>
}

/**
 * The clients of {@link PermissionsServerClient.as}: the current-subject checks,
 * run as one subject. They have no `admin` namespaces.
 */
export interface PermissionsSubjectClient<N extends RbacNames = RbacNames> {
  /** The RBAC checks for the subject. */
  readonly rbac: RbacClient<'subject', N>
  /** The FGA checks for the subject. */
  readonly fga: FgaClient<'subject'>
  /**
   * Returns the id of the subject (`current_subject_id()`): `subject.id`.
   *
   * @example
   * ```ts
   * const { data: id } = await permissions.as({ id: 'alice' }).currentSubjectId() // 'alice'
   * ```
   */
  currentSubjectId(): Promise<Result<string | null>>
  /**
   * Returns the type of the subject (`current_subject_type()`): `subject.type`,
   * or `'user'`.
   *
   * @example
   * ```ts
   * const { data: type } = await permissions.as({ id: 'eng', type: 'team' }).currentSubjectType() // 'team'
   * ```
   */
  currentSubjectType(): Promise<Result<string>>
}

/**
 * The client of {@link createServerClient}: every function over SQL, as the
 * role of the database connection. Use it on a server only.
 */
export class PermissionsServerClient<N extends RbacNames = RbacNames> {
  /** The RBAC client, with `admin`. */
  readonly rbac: RbacClient<'sql', N>
  /** The FGA client, with `admin`. */
  readonly fga: FgaClient<'sql'>
  /** The admin calls that are not RBAC or FGA calls. */
  readonly admin: PermissionsAdminApi
  private readonly transport: SqlTransport
  private readonly throwOnError: boolean

  /** Use {@link createServerClient}. */
  constructor(transport: SqlTransport, options: { throwOnError?: boolean } = {}) {
    const throwOnError = options.throwOnError ?? false
    this.transport = transport
    this.throwOnError = throwOnError
    this.rbac = new RbacClient<N>({ transport, throwOnError })
    this.fga = new FgaClient({ transport, throwOnError })
    this.admin = {
      deleteSubject: ({ type, id }) =>
        toResult(
          // bigint: a string from pg, a number from other drivers.
          transport
            .rpc<string | number | null>('delete_subject', { subject_type: type, subject_id: id }, 'scalar')
            .then((n) => (n == null ? 0 : Number(n))),
          throwOnError,
        ),
    }
  }

  /**
   * Returns the id of the subject of the database connection
   * (`current_subject_id()`). The data is `null` when the connection has no
   * subject, which is the usual case: use {@link PermissionsServerClient.as}
   * to set one.
   *
   * @example
   * ```ts
   * const { data: id } = await permissions.currentSubjectId() // null
   * ```
   */
  currentSubjectId(): Promise<Result<string | null>> {
    return subjectId(this.transport, this.throwOnError)
  }

  /**
   * Returns the type of the subject of the database connection
   * (`current_subject_type()`). The default is `'user'`.
   *
   * @example
   * ```ts
   * const { data: type } = await permissions.currentSubjectType() // 'user'
   * ```
   */
  currentSubjectType(): Promise<Result<string>> {
    return subjectType(this.transport, this.throwOnError)
  }

  /**
   * Returns clients that answer for `subject`. Each call runs in its own
   * transaction with `permissions.subject_id` set to `subject.id` (and
   * `set local role <subject.role>` when `role` is set). The clients have only
   * the current-subject checks: no `admin`, at type level or at runtime.
   *
   * @param subject The subject: `{ id, type?: 'user', role? }`. Pass `role: 'authenticated'`
   * to run the checks with the privileges of a signed-in user, as over PostgREST.
   * @example
   * ```ts
   * const alice = permissions.as({ id: 'alice', role: 'authenticated' })
   * await alice.rbac.hasPermission({ permission: 'documents.edit', scope: 'acme' }) // { data: true, error: null }
   * await alice.fga.check({ relation: 'viewer', object: 'document:1' })
   * ```
   */
  as(subject: Subject): PermissionsSubjectClient<N> {
    const transport = this.transport.withSubject(subject)
    return {
      rbac: new RbacClient<N>({ transport, throwOnError: this.throwOnError }),
      fga: new FgaClient({ transport, throwOnError: this.throwOnError }),
      currentSubjectId: () => subjectId(transport, this.throwOnError),
      currentSubjectType: () => subjectType(transport, this.throwOnError),
    }
  }
}

/**
 * Creates a client for a server. It calls every function of pg_permissions
 * with SQL, as the role of the database connection, and has the `admin`
 * namespaces. Never use it in a browser.
 *
 * `db` is any object with `query(text, values)`: a `pg` Pool or Client,
 * `@neondatabase/serverless`, PGlite. The role of the connection must have
 * `execute` on the admin functions (see the pg_permissions docs on privileges).
 *
 * @param db The database connection or pool.
 * @param options See {@link SqlClientOptions}.
 * @typeParam N Narrows the permission and role names (see {@link RbacNames}).
 *
 * @example
 * ```ts
 * import pg from 'pg'
 * import { createServerClient } from 'permissions'
 *
 * const permissions = createServerClient(new pg.Pool({ connectionString: process.env.DATABASE_URL }))
 * await permissions.rbac.admin.createRole({ role: 'editor', permissions: ['documents.edit'] })
 * await permissions.rbac.admin.assignRole({ userId: 'alice', role: 'editor', scope: 'acme' })
 * await permissions.as({ id: 'alice' }).rbac.hasPermission({ permission: 'documents.edit', scope: 'acme' })
 * ```
 */
export function createServerClient<N extends RbacNames = RbacNames>(
  db: Queryable,
  options: SqlClientOptions = {},
): PermissionsServerClient<N> {
  if (!db || typeof db.query !== 'function') {
    throw new Error('permissions: createServerClient needs a database object with query(text, values), such as a pg Pool')
  }
  return new PermissionsServerClient<N>(sqlTransport(db, { schema: options.schema }), {
    throwOnError: options.throwOnError,
  })
}
