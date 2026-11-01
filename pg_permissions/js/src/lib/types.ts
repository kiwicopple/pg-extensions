import type { PermissionsError } from './errors'

/** The `fetch` function that the PostgREST transport uses. */
export type Fetch = typeof fetch

/**
 * The result of every client method, in the supabase-js form.
 * Exactly one of `data` and `error` is `null`.
 */
export type Result<T> = { data: T; error: null } | { data: null; error: PermissionsError }

/**
 * How a transport reads the result of a function.
 *
 * - `scalar`: one value (`boolean`, `text`, `text[]`, `jsonb`, `bigint`, ...).
 * - `set`: a `setof <scalar>` function. The result is an array of values.
 * - `record`: one row of OUT columns (for example `fga_read`). The result is an object.
 * - `rows`: a `returns table (...)` function. The result is an array of row objects.
 * - `void`: the result is `null`.
 */
export type Shape = 'scalar' | 'set' | 'record' | 'rows' | 'void'

/** Named arguments of a function call. Keys are the SQL argument names. `undefined` values are omitted, so the SQL default applies. */
export type RpcArgs = Record<string, unknown>

/**
 * The kind of a transport. It decides which functions a client can call, and
 * whether the client has an `admin` namespace:
 *
 * - `'sql'`: a direct SQL connection, as the role of the connection (a trusted
 *   backend role). It can call every function. Clients on it have `admin`.
 * - `'postgrest'`: HTTP to PostgREST, as the end user of the JWT. It can call
 *   only the client (PUBLIC) functions. Clients on it have no `admin`.
 * - `'subject'`: SQL scoped to one subject (`sqlTransport(db).withSubject(...)`,
 *   or `as()`). The calls run as the end user, often with
 *   `set local role authenticated`, so clients on it have no `admin`.
 */
export type TransportKind = 'sql' | 'postgrest' | 'subject'

/**
 * A way to call a `permissions.*` function. The clients take a transport and never
 * build SQL or HTTP requests themselves.
 *
 * `rpc` resolves with the decoded result, or rejects with a `PermissionsError`
 * (or a subclass). A call that the transport refuses (an unknown function, an
 * admin function over PostgREST, an unknown argument name) rejects with a plain
 * `Error`: that is a programming error, not a result.
 *
 * `K` is the kind of the transport (see {@link TransportKind}). A client has
 * `admin` in its type only when `K` is exactly `'sql'`.
 */
export interface Transport<K extends TransportKind = TransportKind> {
  /** See {@link TransportKind}. */
  readonly kind: K
  rpc<T = unknown>(fn: string, args: RpcArgs, shape: Shape): Promise<T>
}

/** The subject of `withSubject()` / `as()`: the current subject for the calls of the returned transport. */
export interface Subject {
  /** The subject id. `permissions.current_subject_id()` returns it. */
  id: string
  /** The subject type. Default `'user'`. */
  type?: string
  /** A Postgres role to `set local role` to for each call, for example `'authenticated'`. Default: no change. */
  role?: string
}

/** Options shared by every client. */
export interface BaseClientOptions {
  /** Throw the error instead of returning it in `{ data, error }`. Default `false`. */
  throwOnError?: boolean
}

/** Options of the PostgREST (client-side) clients. The same shape as supabase-js. */
export interface PostgrestClientOptions extends BaseClientOptions {
  /** Returns the user's access token (a JWT). When it returns `null`, the key is sent as the bearer token. */
  accessToken?: () => Promise<string | null> | string | null
  global?: {
    /** A custom `fetch`. Default: the global `fetch`. */
    fetch?: Fetch
    /** Headers to send with every request. */
    headers?: Record<string, string>
  }
  db?: {
    /** The schema of the extension. Default `'permissions'`. */
    schema?: string
  }
  /** The PostgREST URL. Default: `<url>/rest/v1`. Set it to use plain PostgREST. */
  restUrl?: string
}

/** Options of the SQL (server-side) clients. */
export interface SqlClientOptions extends BaseClientOptions {
  /** The schema of the extension. Default `'permissions'`. */
  schema?: string
}
