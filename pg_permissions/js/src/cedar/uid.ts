import type { EntityRef } from './types'

/**
 * Builds a uid in Cedar text, `Type::"id"`, with Cedar's string escapes:
 * `"` and `\` are escaped, and so are control characters. Use it for ids
 * that come from users or rows. A raw `'Document::"' + id + '"'` breaks
 * on an id with `"` and gives a `cedar:invalid_uid` error.
 *
 * The type is not checked here. A bad type, such as `'my type'`, gives
 * `cedar:invalid_uid` from the server.
 *
 * @example
 * ```ts
 * uid('User', 'alice') // 'User::"alice"'
 * uid('Doc', 'say "hi"') // 'Doc::"say \\"hi\\""'
 * ```
 */
export function uid(type: string, id: string): string {
  let out = ''
  for (const c of id) {
    const code = c.codePointAt(0) as number
    if (c === '"' || c === '\\') out += `\\${c}`
    else if (c === '\n') out += '\\n'
    else if (c === '\r') out += '\\r'
    else if (c === '\t') out += '\\t'
    else if (code < 32 || code === 127) out += `\\u{${code.toString(16)}}`
    else out += c
  }
  return `${type}::"${out}"`
}

/**
 * Cedar text for a uid argument. `null` and `undefined` pass through, so
 * the SQL default or the `cedar:null_argument` error applies.
 */
export function uidText(ref: EntityRef | null | undefined): string | null | undefined {
  if (ref === null || ref === undefined || typeof ref === 'string') return ref
  return uid(ref.type, ref.id)
}
