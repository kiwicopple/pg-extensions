import { PermissionsError, PermissionsFetchError } from '../lib/errors'
import { definedArgs, getFunctionSpec } from '../lib/functions'
import type { RpcArgs, Shape, Subject, Transport } from '../lib/types'

/**
 * Anything with `query(text, values)`, such as a `pg` Pool or Client,
 * `@neondatabase/serverless` or PGlite. Rows must be objects keyed by column name.
 */
export interface Queryable {
  query(text: string, values?: unknown[]): Promise<{ rows: any[] }>
}

/** A dedicated connection from a pool, as `pg` `pool.connect()` returns it. */
export interface PoolClientLike extends Queryable {
  release(error?: unknown): void
}

/** A pool: `connect()` returns a dedicated client that the caller releases. */
export interface PoolLike extends Queryable {
  connect(): Promise<PoolClientLike>
}

export interface SqlTransportOptions {
  /** The schema of the extension. Default `'permissions'`. */
  schema?: string
}

/** The SQL transport. It can call every function, and it can run calls as a subject. */
export interface SqlTransport extends Transport<'sql'> {
  /**
   * Returns a transport that runs each call in its own transaction, as `subject`:
   * `begin; [set local role <role>;] select set_config('permissions.subject_id', ...,
   * true), ...; <call>; commit`. The settings end with the transaction.
   *
   * The returned transport has kind `'subject'`: the calls run as the end user,
   * so a client on it has no `admin` namespace, at type level or at runtime.
   */
  withSubject(subject: Subject): Transport<'subject'>
}

/**
 * A transport that calls the functions with SQL:
 * `select ... from permissions.<fn>(arg => $1::type, ...)`, with named arguments only.
 *
 * With a pool (an object with `connect()` that is not itself a `pg` Client), each
 * subject transaction takes a dedicated client and releases it. With a single
 * connection, the transport runs one call at a time, so a transaction never
 * interleaves with another call. The queue belongs to the connection, so every
 * transport over the same client shares it.
 *
 * With a single `Client`, other code must not use that client while subject calls
 * run: its queries would run inside the subject's transaction, as the subject. Use a
 * Pool for concurrent use. If a rollback fails on a single connection, the session may
 * still be inside the subject's transaction, so the transport rejects every later call
 * on that connection; replace the connection.
 */
export function sqlTransport(db: Queryable, options: SqlTransportOptions = {}): SqlTransport {
  const schema = quoteIdent(options.schema ?? 'permissions')
  const pool = isPool(db) ? db : null
  const state = pool ? null : connectionState(db)

  const run = <T>(task: (conn: Queryable) => Promise<T>): Promise<T> =>
    state
      ? state.enqueue(() => {
          if (state.poisoned !== undefined) throw poisonedError(state.poisoned)
          return task(db)
        })
      : task(db)

  async function call<T>(conn: Queryable, fn: string, args: RpcArgs, shape: Shape): Promise<T> {
    const { text, values } = buildCall(schema, fn, args, shape)
    let result: { rows: any[] }
    try {
      result = await conn.query(text, values)
    } catch (error) {
      throw toPermissionsError(error)
    }
    return readRows(result.rows, shape) as T
  }

  async function inTransaction<T>(subject: Subject, task: (conn: Queryable) => Promise<T>): Promise<T> {
    const role = subject.role === undefined ? null : quoteRole(subject.role)
    // Set when the rollback fails: the connection is then in an unknown state.
    let broken: unknown = undefined
    const body = async (conn: Queryable): Promise<T> => {
      await exec(conn, 'begin')
      try {
        if (role) await exec(conn, `set local role ${role}`)
        await exec(
          conn,
          "select set_config('permissions.subject_id', $1, true), set_config('permissions.subject_type', $2, true), set_config('request.jwt.claims', '', true)",
          [subject.id, subject.type ?? 'user'],
        )
        const value = await task(conn)
        await exec(conn, 'commit')
        return value
      } catch (error) {
        try {
          await conn.query('rollback')
        } catch (rollbackError) {
          // The original error matters more than a failed rollback in pool mode,
          // where the client is destroyed. On a single connection nothing destroys
          // it, so the session may still be in the subject transaction: poison it.
          broken = rollbackError
          if (state) {
            state.poisoned = rollbackError
            throw poisonedError(rollbackError, error)
          }
        }
        throw error
      }
    }

    if (!pool) return run(body)
    let client: PoolClientLike
    try {
      client = await pool.connect()
    } catch (error) {
      throw toPermissionsError(error)
    }
    try {
      return await body(client)
    } catch (error) {
      if (broken === undefined && error instanceof PermissionsFetchError) broken = error
      throw error
    } finally {
      // Passing an error to release() makes pg destroy the client instead of reusing it.
      if (broken === undefined) client.release()
      else client.release(broken)
    }
  }

  return {
    kind: 'sql',
    async rpc<T>(fn: string, args: RpcArgs, shape: Shape): Promise<T> {
      return run((conn) => call<T>(conn, fn, args, shape))
    },
    withSubject(subject: Subject): Transport<'subject'> {
      // Capture the identity once. A reused request object must not change
      // the subject of queued or future calls on this transport.
      const identity: Subject = { id: subject.id, type: subject.type, role: subject.role }
      // Validate now, so a bad id or role fails at `withSubject()` and not at the first call.
      if (typeof identity.id !== 'string' || identity.id === '') {
        throw new Error('permissions (sql): withSubject needs a non-empty subject id')
      }
      if (identity.role !== undefined) quoteRole(identity.role)
      return {
        kind: 'subject',
        async rpc<T>(fn: string, args: RpcArgs, shape: Shape): Promise<T> {
          if (!getFunctionSpec(fn, args, 'subject').public) {
            throw new Error(`permissions (subject): '${fn}' is an admin function. Use the server's SQL transport.`)
          }
          // Build first: an unknown function fails before the transaction starts.
          buildCall(schema, fn, args, shape)
          return inTransaction(identity, (conn) => call<T>(conn, fn, args, shape))
        },
      }
    },
  }
}

const CASTS = { text: 'text', 'text[]': 'text[]', jsonb: 'jsonb', int: 'int' } as const

/** Builds the statement for one call. Exported for tests. */
export function buildCall(
  schema: string,
  fn: string,
  args: RpcArgs,
  shape: Shape,
): { text: string; values: unknown[] } {
  const spec = getFunctionSpec(fn, args, 'sql')
  const given = definedArgs(args)
  const values: unknown[] = []
  const parts: string[] = []
  // Iterate the spec, not the input: every identifier in the SQL comes from FUNCTIONS.
  for (const name of Object.keys(spec.args)) {
    if (!Object.prototype.hasOwnProperty.call(given, name)) continue
    const type = spec.args[name] as keyof typeof CASTS
    const value = given[name]
    values.push(type === 'jsonb' && value !== null ? JSON.stringify(value) : value)
    parts.push(`${name} => $${values.length}::${CASTS[type]}`)
  }
  const target = `${schema}.${fn}(${parts.join(', ')})`
  switch (shape) {
    case 'scalar':
      return { text: `select ${target} as value`, values }
    case 'set':
      return { text: `select value from ${target} as t(value)`, values }
    case 'record':
    case 'rows':
      return { text: `select * from ${target}`, values }
    case 'void':
      return { text: `select ${target}`, values }
    default:
      throw new Error(`permissions (sql): unknown shape '${String(shape)}'`)
  }
}

function readRows(rows: any[], shape: Shape): unknown {
  switch (shape) {
    case 'scalar':
      return rows.length ? (rows[0].value ?? null) : null
    case 'set':
      return rows.map((row) => row.value)
    case 'record':
      return rows[0] ?? null
    case 'rows':
      return rows
    default:
      return null
  }
}

async function exec(conn: Queryable, text: string, values?: unknown[]): Promise<void> {
  try {
    await (values ? conn.query(text, values) : conn.query(text))
  } catch (error) {
    throw toPermissionsError(error)
  }
}

/**
 * Maps a driver error: a Postgres error to `PermissionsError`, anything else to
 * `PermissionsFetchError`. A Postgres error has a 5-character SQLSTATE `code` and a
 * string `severity` (node-postgres sets both on every server error). Node errno
 * codes such as `EPIPE`, `EPERM` and `EBADF` also have 5 characters, so the code
 * alone does not tell them apart.
 */
export function toPermissionsError(error: unknown): PermissionsError {
  if (error instanceof PermissionsError) return error
  const e = error as {
    message?: unknown
    code?: unknown
    severity?: unknown
    detail?: unknown
    details?: unknown
    hint?: unknown
  } | null
  if (e && typeof e.code === 'string' && /^[0-9A-Z]{5}$/.test(e.code) && typeof e.severity === 'string') {
    return new PermissionsError({
      message: typeof e.message === 'string' ? e.message : String(error),
      details: typeof e.detail === 'string' ? e.detail : typeof e.details === 'string' ? e.details : null,
      hint: typeof e.hint === 'string' ? e.hint : null,
      code: e.code,
    })
  }
  const message = error instanceof Error ? error.message : String(error)
  return new PermissionsFetchError(`Failed to query the database: ${message}`, error)
}

const IDENT = /^[A-Za-z_][A-Za-z0-9_$]*$/

function quoteIdent(name: string): string {
  if (typeof name !== 'string' || !IDENT.test(name)) {
    throw new Error(`permissions (sql): invalid schema name '${String(name)}'`)
  }
  return `"${name}"`
}

function quoteRole(role: string): string {
  if (typeof role !== 'string' || !IDENT.test(role)) {
    throw new Error(`permissions (sql): invalid role name '${String(role)}'. Use a plain identifier, such as 'authenticated'.`)
  }
  return `"${role}"`
}

function isPool(db: Queryable): db is PoolLike {
  const d = db as unknown as Record<string, unknown>
  // pg.Client and neon's Client also have connect(), which opens the connection
  // itself; they carry connectionParameters. A pool client has release().
  return typeof d.connect === 'function' && typeof d.release !== 'function' && !('connectionParameters' in d)
}

interface ConnectionState {
  enqueue<T>(task: () => Promise<T>): Promise<T>
  /** Set when a rollback failed: the session may still be inside a subject transaction. */
  poisoned: unknown
}

// One state per connection object, so every transport over the same single
// connection shares one queue (and one poisoned flag).
const connections = new WeakMap<object, ConnectionState>()

function connectionState(db: Queryable): ConnectionState {
  let state = connections.get(db)
  if (!state) {
    let tail: Promise<unknown> = Promise.resolve()
    state = {
      poisoned: undefined,
      enqueue<T>(task: () => Promise<T>): Promise<T> {
        const result = tail.then(task, task)
        tail = result.then(
          () => undefined,
          () => undefined,
        )
        return result
      },
    }
    connections.set(db, state)
  }
  return state
}

function poisonedError(rollbackError: unknown, original?: unknown): PermissionsFetchError {
  const reason = rollbackError instanceof Error ? rollbackError.message : String(rollbackError)
  const first = original === undefined ? '' : ` The call failed first: ${original instanceof Error ? original.message : String(original)}.`
  return new PermissionsFetchError(
    `The database connection is unusable: a rollback failed (${reason}), so the session may still be inside a subject transaction. Replace the connection.${first}`,
    rollbackError,
  )
}
