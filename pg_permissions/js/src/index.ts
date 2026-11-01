// Umbrella entry. createClient and createServerClient come in phase 5 (see ../PLAN.md).
export { RbacClient } from './rbac/RbacClient'
export { FgaClient } from './fga/FgaClient'
export { postgrestTransport } from './transport/postgrest'
export type { PostgrestTransportOptions } from './transport/postgrest'
export { sqlTransport } from './transport/sql'
export type { PoolClientLike, PoolLike, Queryable, SqlTransport, SqlTransportOptions } from './transport/sql'
export {
  PermissionsError,
  PermissionsFetchError,
  PermissionsHttpError,
  isFgaError,
  isPermissionsError,
  isRbacError,
  parseDetail,
} from './lib/errors'
export type {
  FgaErrorName,
  FgaErrorReason,
  PermissionsErrorContext,
  PermissionsErrorReason,
  RbacErrorCode,
  RbacErrorReason,
} from './lib/errors'
export { fetchWithAuth, resolveFetch } from './lib/fetch'
export type {
  BaseClientOptions,
  Fetch,
  PostgrestClientOptions,
  Result,
  RpcArgs,
  Shape,
  SqlClientOptions,
  Subject,
  Transport,
} from './lib/types'
