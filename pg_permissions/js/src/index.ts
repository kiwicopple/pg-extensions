// The umbrella entry: createClient, createServerClient and every public export.
// The subpaths (permissions/rbac, /fga, /cedar, /sql, /postgrest) export the same
// clients and transports one by one.

export { PermissionsClient, PermissionsServerClient, createClient, createServerClient } from './PermissionsClient'
export type { PermissionsAdminApi, PermissionsSubjectClient, SubjectRef } from './PermissionsClient'

// RBAC
export { RbacClient } from './rbac/RbacClient'
export type {
  PermissionName,
  RbacAdminApi,
  RbacClientConstructor,
  RbacClientMethods,
  RbacNames,
  RbacPostgrestOptions,
  RbacTransportOptions,
  RoleName,
  Scope,
} from './rbac/RbacClient'

// FGA
export { FgaClient } from './fga/FgaClient'
export type {
  FgaClientConstructor,
  FgaClientMethods,
  FgaPostgrestClientOptions,
  FgaTransportClientOptions,
} from './fga/FgaClient'
export type { FgaAdminApi } from './fga/FgaAdmin'
export type {
  AuthorizationModel,
  AuthorizationModelInfo,
  CheckRequest,
  CurrentCheckRequest,
  CurrentListObjectsRequest,
  EvaluationOptions,
  ListObjectsRequest,
  ListUsersRequest,
  OnDuplicateWrites,
  OnMissingDeletes,
  ReadAuthorizationModelRequest,
  ReadRequest,
  ReadResponse,
  RelationshipCondition,
  StoredAuthorizationModel,
  Tuple,
  TupleKey,
  TupleKeyWithoutCondition,
  WriteAuthorizationModelRequest,
  WriteAuthorizationModelResponse,
  WriteRequest,
} from './fga/types'

// Cedar
export { CedarClient } from './cedar/CedarClient'
export type {
  CedarClientConstructor,
  CedarClientMethods,
  CedarPostgrestClientOptions,
  CedarTransportClientOptions,
} from './cedar/CedarClient'
export type { CedarAdminApi } from './cedar/CedarAdmin'
export { uid } from './cedar/uid'
export type {
  AuthorizationError,
  AuthorizationRequest,
  AuthorizationResponse,
  CedarEntity,
  CedarRecord,
  CedarValue,
  CurrentAuthorizationRequest,
  Decision,
  DeletePolicyRequest,
  DeleteTemplateRequest,
  Diagnostics,
  EntityRef,
  EntityUid,
  LinkTemplateRequest,
  ListResourcesRequest,
  PolicyInfo,
  PolicyJson,
  PutPolicyRequest,
  PutTemplateRequest,
  ReadEntitiesRequest,
  TemplateInfo,
} from './cedar/types'

// Transports
export { postgrestTransport } from './transport/postgrest'
export type { PostgrestTransportOptions } from './transport/postgrest'
export { sqlTransport } from './transport/sql'
export type { PoolClientLike, PoolLike, Queryable, SqlTransport, SqlTransportOptions } from './transport/sql'
export { fetchWithAuth, resolveFetch } from './lib/fetch'

// Errors
export {
  PermissionsError,
  PermissionsFetchError,
  PermissionsHttpError,
  isCedarError,
  isFgaError,
  isPermissionsError,
  isRbacError,
  parseDetail,
} from './lib/errors'
export type {
  CedarErrorCode,
  CedarErrorReason,
  FgaErrorName,
  FgaErrorReason,
  PermissionsErrorContext,
  PermissionsErrorReason,
  RbacErrorCode,
  RbacErrorReason,
} from './lib/errors'

// Shared types
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
  TransportKind,
} from './lib/types'
