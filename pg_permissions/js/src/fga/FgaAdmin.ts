import { toResult } from '../lib/result'
import type { Result, Transport } from '../lib/types'
import type {
  AuthorizationModelInfo,
  CheckRequest,
  ListObjectsRequest,
  ListUsersRequest,
  ReadAuthorizationModelRequest,
  ReadRequest,
  ReadResponse,
  StoredAuthorizationModel,
  Tuple,
  TupleKeyWithoutCondition,
  WriteAuthorizationModelRequest,
  WriteAuthorizationModelResponse,
  WriteRequest,
} from './types'

/**
 * The FGA admin functions: an explicit subject (`user`), models and tuples.
 * Only an SQL client has it (`client.admin`), because these functions are not
 * granted to clients and never go over HTTP.
 *
 * The names follow the OpenFGA JS SDK. The client maps them to the SQL
 * arguments: `user` to `subject`, `authorizationModelId` to `model_id`,
 * `contextualTuples` to `contextual_tuples`, `continuationToken` to
 * `continuation_token`, `pageSize` to `page_size`, `userFilters` to
 * `user_filters`, and `onDuplicate`/`onMissing` to the
 * `{"tuple_keys": [...], "on_duplicate"|"on_missing": ...}` form of `fga_write`.
 *
 * The SQL role of the transport must have `execute` on the functions (see
 * docs/fga.md#privileges). Otherwise each call gives a `42501` error.
 */
export interface FgaAdminApi {
  /**
   * Writes a new authorization model (`fga_write_authorization_model`). It becomes the latest model.
   *
   * @param model The body of the OpenFGA WriteAuthorizationModel request, as an object (or JSON text).
   * @example
   * ```ts
   * const { data } = await fga.admin.writeAuthorizationModel({
   *   schema_version: '1.1',
   *   type_definitions: [
   *     { type: 'user' },
   *     { type: 'document', relations: { viewer: { this: {} } },
   *       metadata: { relations: { viewer: { directly_related_user_types: [{ type: 'user' }] } } } },
   *   ],
   * })
   * data?.authorizationModelId // '01J...'
   * ```
   */
  writeAuthorizationModel(
    model: WriteAuthorizationModelRequest | string,
  ): Promise<Result<WriteAuthorizationModelResponse>>

  /**
   * Reads one authorization model, with its `id` (`fga_read_authorization_model`).
   * Without an id, it reads the latest model.
   *
   * @example
   * ```ts
   * const { data: latest } = await fga.admin.readAuthorizationModel()
   * const { data: model } = await fga.admin.readAuthorizationModel({ authorizationModelId: id })
   * ```
   */
  readAuthorizationModel(request?: ReadAuthorizationModelRequest): Promise<Result<StoredAuthorizationModel>>

  /**
   * Lists the authorization models, newest first (`fga_read_authorization_models`).
   * `createdAt` is a `Date` on every transport.
   *
   * @example
   * ```ts
   * const { data } = await fga.admin.readAuthorizationModels()
   * // [{ id: '01J...', createdAt: Date }, ...]
   * ```
   */
  readAuthorizationModels(): Promise<Result<AuthorizationModelInfo[]>>

  /**
   * Writes and deletes tuples in one transaction (`fga_write`). At most 100
   * tuple keys, `writes` and `deletes` together (`openfga:2053` otherwise).
   *
   * @example
   * ```ts
   * await fga.admin.write({
   *   writes: [{ user: 'user:anne', relation: 'viewer', object: 'document:1' }],
   *   deletes: [{ user: 'user:bob', relation: 'viewer', object: 'document:1' }],
   *   onDuplicate: 'ignore',
   *   onMissing: 'ignore',
   * })
   * ```
   */
  write(request: WriteRequest): Promise<Result<null>>

  /**
   * Writes one tuple without a condition (`fga_write_tuple`). A tuple that exists is not an error.
   *
   * @example
   * ```ts
   * await fga.admin.writeTuple({ user: 'user:anne', relation: 'viewer', object: 'document:1' })
   * ```
   */
  writeTuple(tuple: TupleKeyWithoutCondition): Promise<Result<null>>

  /**
   * Deletes one tuple (`fga_delete_tuple`). A tuple that does not exist is not an error.
   *
   * @example
   * ```ts
   * await fga.admin.deleteTuple({ user: 'user:anne', relation: 'viewer', object: 'document:1' })
   * ```
   */
  deleteTuple(tuple: TupleKeyWithoutCondition): Promise<Result<null>>

  /**
   * Reads one page of stored tuples that match a partial key (`fga_read`).
   * It does not evaluate the model. `continuationToken` is `''` on the last page.
   *
   * @example
   * ```ts
   * let continuationToken = ''
   * do {
   *   const { data, error } = await fga.admin.read({ object: 'document:', pageSize: 100, continuationToken })
   *   if (error) throw error
   *   for (const tuple of data.tuples) console.log(tuple.key)
   *   continuationToken = data.continuationToken
   * } while (continuationToken !== '')
   * ```
   */
  read(request?: ReadRequest): Promise<Result<ReadResponse>>

  /**
   * Checks if `user` has `relation` to `object` (`fga_check`).
   *
   * @example
   * ```ts
   * const { data: allowed } = await fga.admin.check({
   *   user: 'user:anne',
   *   relation: 'viewer',
   *   object: 'document:roadmap',
   *   context: { current_time: new Date().toISOString() },
   * })
   * ```
   */
  check(request: CheckRequest): Promise<Result<boolean>>

  /**
   * Lists the objects of `type` that `user` has `relation` to (`fga_list_objects`),
   * as `type:id` strings. At most 1,000 results; the order is not defined.
   *
   * @example
   * ```ts
   * const { data } = await fga.admin.listObjects({ user: 'user:anne', type: 'document', relation: 'viewer' })
   * // ['document:1', 'document:2']
   * ```
   */
  listObjects(request: ListObjectsRequest): Promise<Result<string[]>>

  /**
   * Lists the subjects that have `relation` to `object` (`fga_list_users`), as
   * strings: `type:id`, `type:*` or `type:id#relation`. At most 1,000 results.
   *
   * @example
   * ```ts
   * const { data } = await fga.admin.listUsers({
   *   object: 'document:1',
   *   relation: 'viewer',
   *   userFilters: ['user', 'team#member'],
   * })
   * // ['user:anne', 'team:eng#member']
   * ```
   */
  listUsers(request: ListUsersRequest): Promise<Result<string[]>>

  /**
   * Deletes every model and every tuple (`fga_delete_store`). By default only
   * the owner of the extension may call it.
   *
   * @example
   * ```ts
   * await fga.admin.deleteStore()
   * ```
   */
  deleteStore(): Promise<Result<null>>
}

/** The implementation of `FgaAdminApi` on a transport. @internal */
export class FgaAdmin implements FgaAdminApi {
  constructor(
    private readonly transport: Transport,
    private readonly throwOnError: boolean,
  ) {}

  private run<T>(call: Promise<T>): Promise<Result<T>> {
    return toResult(call, this.throwOnError)
  }

  writeAuthorizationModel(model: WriteAuthorizationModelRequest | string): Promise<Result<WriteAuthorizationModelResponse>> {
    return this.run(
      // The transport sends jsonb as JSON text; parse a string so it is not sent as a JSON string literal.
      // Parsing inside the async chain turns a bad JSON string into a rejected promise, not a sync throw.
      Promise.resolve()
        .then(() => (typeof model === 'string' ? (JSON.parse(model) as unknown) : model))
        .then((value) => this.transport.rpc<string>('fga_write_authorization_model', { model: value }, 'scalar'))
        .then((authorizationModelId) => ({ authorizationModelId })),
    )
  }

  readAuthorizationModel(request: ReadAuthorizationModelRequest = {}): Promise<Result<StoredAuthorizationModel>> {
    return this.run(
      this.transport.rpc<StoredAuthorizationModel>(
        'fga_read_authorization_model',
        { model_id: request.authorizationModelId },
        'scalar',
      ),
    )
  }

  readAuthorizationModels(): Promise<Result<AuthorizationModelInfo[]>> {
    return this.run(
      this.transport
        .rpc<Array<{ id: string; created_at: Date | string }>>('fga_read_authorization_models', {}, 'rows')
        .then((rows) => rows.map((row) => ({ id: row.id, createdAt: toDate(row.created_at) }))),
    )
  }

  write(request: WriteRequest): Promise<Result<null>> {
    const { writes, deletes, onDuplicate, onMissing, authorizationModelId } = request
    return this.run(
      this.transport.rpc<null>(
        'fga_write',
        {
          writes:
            writes === undefined
              ? undefined
              : onDuplicate === undefined
                ? writes
                : { tuple_keys: writes, on_duplicate: onDuplicate },
          deletes:
            deletes === undefined
              ? undefined
              : onMissing === undefined
                ? deletes
                : { tuple_keys: deletes, on_missing: onMissing },
          model_id: authorizationModelId,
        },
        'void',
      ),
    )
  }

  writeTuple(tuple: TupleKeyWithoutCondition): Promise<Result<null>> {
    return this.run(
      this.transport.rpc<null>(
        'fga_write_tuple',
        { subject: tuple.user, relation: tuple.relation, object: tuple.object },
        'void',
      ),
    )
  }

  deleteTuple(tuple: TupleKeyWithoutCondition): Promise<Result<null>> {
    return this.run(
      this.transport.rpc<null>(
        'fga_delete_tuple',
        { subject: tuple.user, relation: tuple.relation, object: tuple.object },
        'void',
      ),
    )
  }

  read(request: ReadRequest = {}): Promise<Result<ReadResponse>> {
    return this.run(
      this.transport
        .rpc<{ tuples: Tuple[] | null; continuation_token: string | null } | null>(
          'fga_read',
          {
            object: request.object,
            relation: request.relation,
            subject: request.user,
            page_size: request.pageSize,
            continuation_token: request.continuationToken,
          },
          'record',
        )
        .then((page) => ({ tuples: page?.tuples ?? [], continuationToken: page?.continuation_token ?? '' })),
    )
  }

  check(request: CheckRequest): Promise<Result<boolean>> {
    return this.run(
      this.transport
        .rpc<boolean | null>(
          'fga_check',
          {
            subject: request.user,
            relation: request.relation,
            object: request.object,
            ...evaluationArgs(request),
          },
          'scalar',
        )
        .then((allowed) => allowed === true),
    )
  }

  listObjects(request: ListObjectsRequest): Promise<Result<string[]>> {
    return this.run(
      this.transport.rpc<string[]>(
        'fga_list_objects',
        { subject: request.user, type: request.type, relation: request.relation, ...evaluationArgs(request) },
        'set',
      ),
    )
  }

  listUsers(request: ListUsersRequest): Promise<Result<string[]>> {
    return this.run(
      this.transport.rpc<string[]>(
        'fga_list_users',
        {
          object: request.object,
          relation: request.relation,
          user_filters: request.userFilters,
          ...evaluationArgs(request),
        },
        'set',
      ),
    )
  }

  deleteStore(): Promise<Result<null>> {
    return this.run(this.transport.rpc<null>('fga_delete_store', {}, 'void'))
  }
}

function evaluationArgs(request: {
  contextualTuples?: unknown
  context?: unknown
  authorizationModelId?: string
}): Record<string, unknown> {
  return {
    contextual_tuples: request.contextualTuples,
    model_id: request.authorizationModelId,
    context: request.context,
  }
}

/** `pg` returns `timestamptz` as a `Date`; PostgREST returns an ISO string. */
function toDate(value: Date | string): Date {
  return value instanceof Date ? value : new Date(value)
}
