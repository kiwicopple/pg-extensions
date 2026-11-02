import { isPermissionsError } from './errors'
import type { Result } from './types'

/**
 * Turns a transport call into `{ data, error }`. A `PermissionsError` becomes
 * the `error`, or is thrown when `throwOnError` is set. Any other error (a
 * programming error, such as a refused function) is always thrown.
 */
export async function toResult<T>(call: Promise<T>, throwOnError = false): Promise<Result<T>> {
  try {
    return { data: await call, error: null }
  } catch (error) {
    if (!throwOnError && isPermissionsError(error)) return { data: null, error }
    throw error
  }
}
