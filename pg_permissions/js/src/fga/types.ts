/**
 * The FGA data types. The names and shapes follow the OpenFGA JS SDK
 * (`@openfga/sdk`), in camelCase. The client maps them to the SQL argument
 * names of pg_permissions (see docs/fga.md#how-the-functions-map-to-openfga).
 */

/** A condition on a tuple: the name of a condition of the model, and the parameter values that the tuple stores. */
export interface RelationshipCondition {
  /** The name of a condition in the `conditions` of the model. */
  name: string
  /** Parameter values. A value in the tuple wins over a value in the request `context`. */
  context?: Record<string, unknown>
}

/**
 * A tuple key: `user` has `relation` to `object`.
 *
 * `user` is `type:id`, `type:*` (every subject of the type) or `type:id#relation`
 * (a userset). `object` is `type:id`. The SQL functions call `user` `subject`.
 */
export interface TupleKey {
  user: string
  relation: string
  object: string
  /** An optional condition. It is not part of the key: a delete does not need it. */
  condition?: RelationshipCondition
}

/** A tuple key without a condition, for `writeTuple`, `deleteTuple` and the deletes of `write`. */
export interface TupleKeyWithoutCondition {
  user: string
  relation: string
  object: string
}

/** A stored tuple, as `read` returns it (the OpenFGA `Tuple`). */
export interface Tuple {
  /** The tuple key. You can pass it back to `write` as a delete. */
  key: TupleKey
  /** When the tuple was written: an ISO 8601 string, as in the OpenFGA ReadResponse. */
  timestamp: string
}

/**
 * An authorization model, as the body of the OpenFGA WriteAuthorizationModel
 * request (the JSON form of the DSL, from `fga model transform`). The keys are
 * snake_case, as in OpenFGA's JSON.
 */
export interface AuthorizationModel {
  schema_version: string
  type_definitions: Array<Record<string, unknown>>
  conditions?: Record<string, unknown>
  [key: string]: unknown
}

/** A stored authorization model: the model with its `id`. */
export interface StoredAuthorizationModel extends AuthorizationModel {
  id: string
}

/** One entry of `readAuthorizationModels()`. */
export interface AuthorizationModelInfo {
  /** The model id. */
  id: string
  /** When the model was written. */
  createdAt: Date
}

/** What to do when a write names a tuple that exists. `'error'` (the default) raises `openfga:2017`. */
export type OnDuplicateWrites = 'error' | 'ignore'

/** What to do when a delete names a tuple that does not exist. `'error'` (the default) raises `openfga:2017`. */
export type OnMissingDeletes = 'error' | 'ignore'

/** Arguments of `admin.writeAuthorizationModel`: the model. */
export type WriteAuthorizationModelRequest = AuthorizationModel

/** The result of `admin.writeAuthorizationModel`. */
export interface WriteAuthorizationModelResponse {
  /** The id of the new model. It is now the latest model. */
  authorizationModelId: string
}

/** Arguments of `admin.readAuthorizationModel`. */
export interface ReadAuthorizationModelRequest {
  /** The model id. Default: the latest model. */
  authorizationModelId?: string
}

/** Arguments of `admin.write`. Give `writes`, `deletes` or both. */
export interface WriteRequest {
  /** The tuples to write. At most 100 keys, `writes` and `deletes` together. */
  writes?: TupleKey[]
  /** The tuples to delete. A condition is not needed. */
  deletes?: TupleKeyWithoutCondition[]
  /** `'ignore'` skips a write of a tuple that exists. Default `'error'`. */
  onDuplicate?: OnDuplicateWrites
  /** `'ignore'` skips a delete of a tuple that does not exist. Default `'error'`. */
  onMissing?: OnMissingDeletes
  /** Validate the writes against this model. Default: the latest model. */
  authorizationModelId?: string
}

/** Arguments of `admin.read`: a partial tuple key, and the page. */
export interface ReadRequest {
  /** `type:id`, or `type:` for every object of the type. */
  object?: string
  relation?: string
  /** `type:id`, `type:*` or `type:id#relation`. */
  user?: string
  /** Tuples in one page: 1 to 100. Default 50. */
  pageSize?: number
  /** The `continuationToken` of the previous page. Omit it, or pass `''`, for the first page. */
  continuationToken?: string
}

/** One page of `admin.read`. */
export interface ReadResponse {
  /** The tuples of the page, in the order of the writes. */
  tuples: Tuple[]
  /**
   * The token of the next page. `''` means that this is the last page (as in
   * OpenFGA). Pass a non-empty token back to `read` without change.
   */
  continuationToken: string
}

/** Options that Check, ListObjects and ListUsers share. */
export interface EvaluationOptions {
  /** Tuples that count for this call only. They are validated against the model, but never written. */
  contextualTuples?: TupleKey[]
  /** Parameter values for the conditions. A value in a tuple wins over a value here. */
  context?: Record<string, unknown>
  /** The model to use. Default: the latest model. */
  authorizationModelId?: string
}

/** Arguments of `admin.check`. */
export interface CheckRequest extends EvaluationOptions {
  user: string
  relation: string
  object: string
}

/** Arguments of `admin.listObjects`. */
export interface ListObjectsRequest extends EvaluationOptions {
  user: string
  /** The object type, for example `'document'`. */
  type: string
  relation: string
}

/** Arguments of `admin.listUsers`. */
export interface ListUsersRequest extends EvaluationOptions {
  /** `type:id`. */
  object: string
  relation: string
  /** The kinds of subject to return: types (`'user'`) or usersets (`'team#member'`). At least one. */
  userFilters: string[]
}

/** Arguments of the client `check`: the current subject is the user. */
export interface CurrentCheckRequest {
  relation: string
  object: string
}

/** Arguments of the client `listObjects`: the current subject is the user. */
export interface CurrentListObjectsRequest {
  /** The object type, for example `'document'`. */
  type: string
  relation: string
  /** Return bare ids (`'1'`) instead of `type:id` strings (`'document:1'`). Default `false`. */
  idsOnly?: boolean
}
