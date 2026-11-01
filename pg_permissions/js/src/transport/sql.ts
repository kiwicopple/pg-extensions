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
export interface SqlTransport extends Transport {
  readonly kind: 'sql'
  /**
   * Returns a transport that runs each call in its own transaction, as `subject`:
   * `begin; [set local role <role>;] select set_config('permissions.subject_id', ...,
   * true), ...; <call>; commit`. The settings end with the transaction.
   */
  withSubject(subject: Subject): Transport
}

/**
 * A transport that calls the functions with SQL:
 * `select ... from permissions.<fn>(arg => $1::type, ...)`, with named arguments only.
 *
 * With a pool (an object with `connect()` that is not itself a `pg` Client), each
 * subject transaction takes a dedicated client and releases it. With a single
 * connection, the transport runs one call at a time, so a transaction never
 * interleaves with another call.
 */
export function sqlTransport(db: Queryable, options: SqlTransportOptions = {}): SqlTransport {
  const schema = quoteIdent(options.schema ?? 'permissions')
  const pool = isPool(db) ? db : null
  const serial = pool ? null : serialQueue()

  const run = <T>(task: (conn: Queryable) => Promise<T>): Promise<T> =>
    serial ? serial(() => task(db)) : task(db)

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
    if (typeof subject.id !== 'string' || subject.id === '') {
      throw new Error('permissions (sql): withSubject needs a non-empty subject id')
    }
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
          // The original error matters more than a failed rollback.
          broken = rollbackError
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
    withSubject(subject: Subject): Transport {
      // Validate now, so a bad role fails at `as()` and not at the first call.
      if (subject.role !== undefined) quoteRole(subject.role)
      return {
        kind: 'sql',
        async rpc<T>(fn: string, args: RpcArgs, shape: Shape): Promise<T> {
          // Build first: an unknown function fails before the transaction starts.
          buildCall(schema, fn, args, shape)
          return inTransaction(subject, (conn) => call<T>(conn, fn, args, shape))
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

/** Maps a driver error: a Postgres error (with a SQLSTATE) to `PermissionsError`, anything else to `PermissionsFetchError`. */
export function toPermissionsError(error: unknown): PermissionsError {
  if (error instanceof PermissionsError) return error
  const e = error as { message?: unknown; code?: unknown; detail?: unknown; details?: unknown; hint?: unknown } | null
  if (e && typeof e.code === 'string' && /^[0-9A-Z]{5}$/.test(e.code)) {
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

function serialQueue(): <T>(task: () => Promise<T>) => Promise<T> {
  let tail: Promise<unknown> = Promise.resolve()
  return <T>(task: () => Promise<T>): Promise<T> => {
    const result = tail.then(task, task)
    tail = result.then(
      () => undefined,
      () => undefined,
    )
    return result
  }
}
