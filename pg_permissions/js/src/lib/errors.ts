/** The RBAC codes of `DETAIL` (see docs/errors-and-limits.md#rbac-errors). Other strings are allowed for codes added later. */
export type RbacErrorCode =
  | 'role_exists'
  | 'name_overlap'
  | 'unknown_role'
  | 'role_in_use'
  | 'null_argument'
  | (string & {})

/** The OpenFGA error names of `DETAIL` (see docs/errors-and-limits.md#openfga-errors). */
export type FgaErrorName =
  | 'validation_error'
  | 'authorization_model_not_found'
  | 'authorization_model_resolution_too_complex'
  | 'invalid_write_input'
  | 'cannot_allow_duplicate_tuples_in_one_request'
  | 'invalid_continuation_token'
  | 'write_failed_due_to_invalid_input'
  | 'latest_authorization_model_not_found'
  | 'type_not_found'
  | 'relation_not_found'
  | 'invalid_tuple'
  | 'type_invalid_pattern'
  | 'relations_invalid_pattern'
  | 'exceeded_entity_limit'
  | 'invalid_authorization_model'
  | 'unsupported_schema_version'
  | (string & {})

/**
 * The Cedar codes of `DETAIL`. Each is one cause, for example `unknown_policy`
 * (no policy has the id) or `invalid_uid` (the text is not `Type::"id"`).
 * Other strings are allowed for codes added later.
 */
export type CedarErrorCode =
  | 'parse_error'
  | 'invalid_policy'
  | 'unknown_policy'
  | 'unknown_template'
  | 'template_in_use'
  | 'id_in_use'
  | 'invalid_link'
  | 'invalid_uid'
  | 'invalid_entity'
  | 'invalid_context'
  | 'invalid_argument'
  | 'unsupported'
  | 'null_argument'
  | 'limit_exceeded'
  | (string & {})

/** A parsed `rbac:<code>[ key='value' ...]` DETAIL. */
export interface RbacErrorReason {
  model: 'rbac'
  code: RbacErrorCode
  /** The `key=value` pairs after the code, with the values unquoted. */
  context: Record<string, string>
}

/** A parsed `openfga:<number> <name>` DETAIL. */
export interface FgaErrorReason {
  model: 'openfga'
  /** The OpenFGA error code, for example `2001`. */
  code: number
  /** The OpenFGA error name, for example `'authorization_model_not_found'`. */
  name: FgaErrorName
}

/**
 * A parsed `cedar:<code>[ key='value' ...]` DETAIL, for example
 * `cedar:unknown_policy policy_id='alice-edit'` or
 * `cedar:parse_error line=1 column=8`.
 */
export interface CedarErrorReason {
  model: 'cedar'
  code: CedarErrorCode
  /** The `key=value` pairs after the code, with the values unquoted. */
  context: Record<string, string>
}

export type PermissionsErrorReason = RbacErrorReason | FgaErrorReason | CedarErrorReason

/** The fields of a PostgREST error body, and of a Postgres error. */
export interface PermissionsErrorContext {
  message: string
  details?: string | null
  hint?: string | null
  code?: string | null
}

/**
 * An error from pg_permissions or Postgres. It has the fields of supabase-js'
 * `PostgrestError` (`message`, `details`, `hint`, `code`), and `reason`: the
 * `DETAIL` code parsed, or `null` for a plain Postgres error such as `42501`.
 */
export class PermissionsError extends Error {
  /** The `DETAIL` of the error, for example `rbac:unknown_role role='admn'`. */
  details: string | null
  /** How to fix the error. */
  hint: string | null
  /** The SQLSTATE, for example `22023`. Empty for errors that do not come from Postgres. */
  code: string
  /** The `DETAIL` code, parsed. `null` when `details` is not an `rbac:`, `openfga:` or `cedar:` code. */
  reason: PermissionsErrorReason | null

  constructor(context: PermissionsErrorContext) {
    super(context.message)
    this.name = 'PermissionsError'
    this.details = context.details ?? null
    this.hint = context.hint ?? null
    this.code = context.code ?? ''
    this.reason = parseDetail(this.details)
  }

  /** The PostgREST error fields, for `JSON.stringify` and logging. */
  toJSON(): { name: string; message: string; details: string | null; hint: string | null; code: string } {
    return { name: this.name, message: this.message, details: this.details, hint: this.hint, code: this.code }
  }
}

/** The request did not reach the server (a network error, or a database connection error). */
export class PermissionsFetchError extends PermissionsError {
  /** The error that the `fetch` call or the database driver threw. */
  override readonly cause: unknown

  constructor(message: string, cause: unknown) {
    super({ message, details: cause instanceof Error ? cause.message : cause == null ? null : String(cause) })
    this.name = 'PermissionsFetchError'
    this.cause = cause
  }
}

/** The server returned a non-2xx status without a PostgREST error body, or a body that is not JSON. */
export class PermissionsHttpError extends PermissionsError {
  /** The HTTP status. */
  readonly status: number
  /** The response body as text. */
  readonly body: string

  constructor(status: number, statusText: string, body: string) {
    super({ message: `HTTP ${status}${statusText ? ` ${statusText}` : ''}`, details: body || null })
    this.name = 'PermissionsHttpError'
    this.status = status
    this.body = body
  }
}

const RBAC_DETAIL = /^rbac:([A-Za-z0-9_]+)(?:\s+([\s\S]*))?$/
const CEDAR_DETAIL = /^cedar:([A-Za-z0-9_]+)(?:\s+([\s\S]*))?$/
const FGA_DETAIL = /^openfga:(\d+)\s+(\S+)\s*$/

/**
 * Parses a `DETAIL` string into a reason. Returns `null` when the string is not
 * an `rbac:`, `openfga:` or `cedar:` code.
 */
export function parseDetail(details: string | null | undefined): PermissionsErrorReason | null {
  if (typeof details !== 'string') return null
  const fga = FGA_DETAIL.exec(details)
  if (fga) return { model: 'openfga', code: Number(fga[1]), name: fga[2] as string }
  const rbac = RBAC_DETAIL.exec(details)
  if (rbac) {
    const context = rbac[2] === undefined ? {} : parseContext(rbac[2])
    if (context === null) return { model: 'rbac', code: rbac[1] as string, context: {} }
    return { model: 'rbac', code: rbac[1] as string, context }
  }
  const cedar = CEDAR_DETAIL.exec(details)
  if (cedar) {
    const context = cedar[2] === undefined ? {} : parseContext(cedar[2])
    return { model: 'cedar', code: cedar[1] as string, context: context ?? {} }
  }
  return null
}

/**
 * Parses `key=value key2='quoted value'` pairs. A quoted value is a SQL literal
 * from `format('%L')`: `''` is one quote, and an `E'...'` literal has backslash escapes.
 */
function parseContext(text: string): Record<string, string> | null {
  const context: Record<string, string> = {}
  let i = 0
  const n = text.length
  while (i < n) {
    while (i < n && /\s/.test(text[i] as string)) i++
    if (i >= n) break
    const eq = text.indexOf('=', i)
    if (eq < 0) return null
    const key = text.slice(i, eq)
    if (!/^[A-Za-z0-9_]+$/.test(key)) return null
    i = eq + 1
    let escapes = false
    if (text[i] === 'E' && text[i + 1] === "'") {
      escapes = true
      i++
    }
    if (text[i] === "'") {
      i++
      let value = ''
      let closed = false
      while (i < n) {
        const c = text[i] as string
        if (c === "'") {
          if (text[i + 1] === "'") {
            value += "'"
            i += 2
            continue
          }
          i++
          closed = true
          break
        }
        if (escapes && c === '\\' && i + 1 < n) {
          value += text[i + 1]
          i += 2
          continue
        }
        value += c
        i++
      }
      if (!closed) return null
      context[key] = value
    } else {
      let end = i
      while (end < n && !/\s/.test(text[end] as string)) end++
      context[key] = text.slice(i, end)
      i = end
    }
  }
  return context
}

/** True for a `PermissionsError`, including `PermissionsFetchError` and `PermissionsHttpError`. */
export function isPermissionsError(error: unknown): error is PermissionsError {
  return error instanceof PermissionsError
}

/** True for an error with an `rbac:` DETAIL code; with `code`, only for that code. */
export function isRbacError(
  error: unknown,
  code?: RbacErrorCode,
): error is PermissionsError & { reason: RbacErrorReason } {
  return (
    isPermissionsError(error) &&
    error.reason !== null &&
    error.reason.model === 'rbac' &&
    (code === undefined || error.reason.code === code)
  )
}

/** True for an error with an `openfga:` DETAIL code; with `code`, only for that code (number or name). */
export function isFgaError(
  error: unknown,
  code?: number | FgaErrorName,
): error is PermissionsError & { reason: FgaErrorReason } {
  if (!isPermissionsError(error) || error.reason === null || error.reason.model !== 'openfga') return false
  if (code === undefined) return true
  return typeof code === 'number' ? error.reason.code === code : error.reason.name === code
}

/** True for an error with a `cedar:` DETAIL code; with `code`, only for that code. */
export function isCedarError(
  error: unknown,
  code?: CedarErrorCode,
): error is PermissionsError & { reason: CedarErrorReason } {
  return (
    isPermissionsError(error) &&
    error.reason !== null &&
    error.reason.model === 'cedar' &&
    (code === undefined || error.reason.code === code)
  )
}
