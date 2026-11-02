import { toResult } from '../lib/result'
import type { Result, Transport } from '../lib/types'
import type {
  AuthorizationRequest,
  AuthorizationResponse,
  CedarEntity,
  DeletePolicyRequest,
  DeleteTemplateRequest,
  EntityRef,
  LinkTemplateRequest,
  PolicyInfo,
  PutPolicyRequest,
  PutTemplateRequest,
  ReadEntitiesRequest,
  TemplateInfo,
} from './types'
import { uidText } from './uid'

/**
 * The Cedar admin functions: policies, templates and links, entities, and
 * requests for any principal. Only an SQL client has it (`client.admin`),
 * because these functions are not granted to clients and never go over
 * HTTP.
 *
 * The names are the SQL names in camelCase, without `cedar_`:
 * `putPolicy` calls `cedar_put_policy`, `policyJson` is `policy_json`.
 * A uid argument is Cedar text (`'User::"alice"'`) or `{ type, id }`.
 *
 * The SQL role of the transport must have `execute` on the functions.
 * Otherwise each call gives a `42501` error.
 */
export interface CedarAdminApi {
  /**
   * Puts one static policy (`cedar_put_policy`), from Cedar text or from
   * Cedar's JSON format. A put with an existing id replaces the policy.
   * `policyId` names the policy; an `@id` annotation does not.
   *
   * @example
   * ```ts
   * const policy = `permit (
   *   principal == User::"alice",
   *   action == Action::"view",
   *   resource in Folder::"reports"
   * );`
   * await cedar.admin.putPolicy({ policyId: 'alice-reports', policy })
   * ```
   */
  putPolicy(request: PutPolicyRequest): Promise<Result<null>>

  /**
   * Deletes a static policy or a link (`cedar_delete_policy`). An unknown
   * id gives `cedar:unknown_policy`.
   *
   * @example
   * ```ts
   * await cedar.admin.deletePolicy({ policyId: 'alice-reports' })
   * ```
   */
  deletePolicy(request: DeletePolicyRequest): Promise<Result<null>>

  /**
   * Lists the static policies and the links, by id (`cedar_policies`).
   *
   * @example
   * ```ts
   * const { data: policies } = await cedar.admin.policies()
   * // [{ policyId: 'alice-reports', effect: 'permit', ... }]
   * ```
   */
  policies(): Promise<Result<PolicyInfo[]>>

  /**
   * Puts one template (`cedar_put_template`), with `?principal`,
   * `?resource` or both in its scope. A put with an existing id replaces
   * the template and refills its links in the same transaction.
   *
   * @example
   * ```ts
   * const template = `permit (
   *   principal == ?principal,
   *   action == Action::"view",
   *   resource in ?resource
   * );`
   * await cedar.admin.putTemplate({ templateId: 'viewer', template })
   * ```
   */
  putTemplate(request: PutTemplateRequest): Promise<Result<null>>

  /**
   * Links a template (`cedar_link_template`): a policy with the slots
   * filled. Give a value for each slot of the template, and no other
   * (`cedar:invalid_link` otherwise).
   *
   * @example
   * ```ts
   * await cedar.admin.linkTemplate({
   *   policyId: 'bob-reports',
   *   templateId: 'viewer',
   *   principal: { type: 'User', id: 'bob' },
   *   resource: 'Folder::"reports"',
   * })
   * ```
   */
  linkTemplate(request: LinkTemplateRequest): Promise<Result<null>>

  /**
   * Deletes a template (`cedar_delete_template`). While links exist, it
   * gives `cedar:template_in_use`: delete the links first.
   *
   * @example
   * ```ts
   * await cedar.admin.deleteTemplate({ templateId: 'viewer' })
   * ```
   */
  deleteTemplate(request: DeleteTemplateRequest): Promise<Result<null>>

  /**
   * Lists the templates, by id (`cedar_templates`).
   *
   * @example
   * ```ts
   * const { data: templates } = await cedar.admin.templates()
   * // [{ templateId: 'viewer', source: 'permit (...);', ... }]
   * ```
   */
  templates(): Promise<Result<TemplateInfo[]>>

  /**
   * Puts entities in Cedar's entity JSON format (`cedar_put_entities`).
   * Each one replaces the stored entity with the same uid, with its
   * attributes, parents and tags. At most 10,000 in one call.
   *
   * @example
   * ```ts
   * const entities = [
   *   {
   *     uid: { type: 'User', id: 'alice' },
   *     attrs: { level: 5 },
   *     parents: [{ type: 'Team', id: 'eng' }],
   *   },
   *   { uid: { type: 'Team', id: 'eng' } },
   * ]
   * await cedar.admin.putEntities(entities)
   * ```
   */
  putEntities(entities: CedarEntity[]): Promise<Result<null>>

  /**
   * Deletes entities (`cedar_delete_entities`). An unknown uid is not an
   * error.
   *
   * @returns The number of entities deleted.
   * @example
   * ```ts
   * const uids = [{ type: 'User', id: 'alice' }, 'Team::"eng"']
   * const { data: deleted } = await cedar.admin.deleteEntities(uids)
   * ```
   */
  deleteEntities(uids: EntityRef[]): Promise<Result<number>>

  /**
   * Reads stored entities in Cedar's entity JSON format, by type and id
   * (`cedar_read_entities`): all of them, those of one type, or some ids
   * of one type. Each entity has `attrs`, `parents` and `tags`.
   *
   * @example
   * ```ts
   * const { data: all } = await cedar.admin.readEntities()
   * const { data: some } = await cedar.admin.readEntities({
   *   type: 'User',
   *   ids: ['alice', 'bob'],
   * })
   * ```
   */
  readEntities(request?: ReadEntitiesRequest): Promise<Result<Required<CedarEntity>[]>>

  /**
   * Answers a full Cedar request for any principal
   * (`cedar_is_authorized`). A forbid that holds denies; else a permit
   * that holds allows; else the answer is deny. A policy that errs is
   * skipped and reported in `diagnostics.errors`. The response has the
   * shape of Cedar's own `isAuthorized` response.
   *
   * @example
   * ```ts
   * const request = {
   *   principal: { type: 'User', id: 'alice' },
   *   action: 'Action::"view"',
   *   resource: 'Document::"q3"',
   *   context: { mfa: true },
   * }
   * const { data } = await cedar.admin.isAuthorized(request)
   * data?.decision // 'allow'
   * data?.diagnostics.reason // ['alice-reports']
   * ```
   */
  isAuthorized(request: AuthorizationRequest): Promise<Result<AuthorizationResponse>>
}

/** The row of `cedar_policies()`. */
interface PolicyRow {
  policy_id: string
  effect: PolicyInfo['effect']
  source: string | null
  est: PolicyInfo['est']
  annotations: PolicyInfo['annotations'] | null
  template_id: string | null
  slots: PolicyInfo['slots']
}

/** The row of `cedar_templates()`. */
interface TemplateRow {
  template_id: string
  source: string | null
  est: TemplateInfo['est']
  annotations: TemplateInfo['annotations'] | null
}

/** The result of `cedar_is_authorized()`. */
interface AuthorizationRow {
  decision: AuthorizationResponse['decision']
  reasons: string[] | null
  errors: Array<{ policy_id: string; message: string }> | null
}

/** The implementation of {@link CedarAdminApi}. */
export class CedarAdmin implements CedarAdminApi {
  constructor(
    private readonly transport: Transport,
    private readonly throwOnError: boolean,
  ) {}

  private run<T>(call: Promise<T>): Promise<Result<T>> {
    return toResult(call, this.throwOnError)
  }

  private void(fn: string, args: Record<string, unknown>): Promise<Result<null>> {
    return this.run(this.transport.rpc<null>(fn, args, 'void'))
  }

  putPolicy(request: PutPolicyRequest): Promise<Result<null>> {
    return this.void('cedar_put_policy', {
      policy_id: request.policyId,
      policy: request.policy,
      policy_json: request.policyJson,
    })
  }

  deletePolicy(request: DeletePolicyRequest): Promise<Result<null>> {
    return this.void('cedar_delete_policy', { policy_id: request.policyId })
  }

  policies(): Promise<Result<PolicyInfo[]>> {
    return this.run(
      this.transport.rpc<PolicyRow[]>('cedar_policies', {}, 'rows').then((rows) =>
        rows.map((row) => ({
          policyId: row.policy_id,
          effect: row.effect,
          source: row.source,
          est: row.est,
          annotations: row.annotations ?? {},
          templateId: row.template_id,
          slots: row.slots,
        })),
      ),
    )
  }

  putTemplate(request: PutTemplateRequest): Promise<Result<null>> {
    return this.void('cedar_put_template', {
      template_id: request.templateId,
      template: request.template,
      template_json: request.templateJson,
    })
  }

  linkTemplate(request: LinkTemplateRequest): Promise<Result<null>> {
    return this.void('cedar_link_template', {
      policy_id: request.policyId,
      template_id: request.templateId,
      principal: uidText(request.principal),
      resource: uidText(request.resource),
    })
  }

  deleteTemplate(request: DeleteTemplateRequest): Promise<Result<null>> {
    return this.void('cedar_delete_template', { template_id: request.templateId })
  }

  templates(): Promise<Result<TemplateInfo[]>> {
    return this.run(
      this.transport.rpc<TemplateRow[]>('cedar_templates', {}, 'rows').then((rows) =>
        rows.map((row) => ({
          templateId: row.template_id,
          source: row.source,
          est: row.est,
          annotations: row.annotations ?? {},
        })),
      ),
    )
  }

  putEntities(entities: CedarEntity[]): Promise<Result<null>> {
    return this.void('cedar_put_entities', { entities })
  }

  deleteEntities(uids: EntityRef[]): Promise<Result<number>> {
    return this.run(
      // bigint: a string from pg, a number from other drivers.
      this.transport
        .rpc<string | number | null>('cedar_delete_entities', { uids }, 'scalar')
        .then((n) => (n == null ? 0 : Number(n))),
    )
  }

  readEntities(request: ReadEntitiesRequest = {}): Promise<Result<Required<CedarEntity>[]>> {
    return this.run(
      this.transport
        .rpc<Required<CedarEntity>[] | null>('cedar_read_entities', { type: request.type, ids: request.ids }, 'scalar')
        .then((entities) => entities ?? []),
    )
  }

  isAuthorized(request: AuthorizationRequest): Promise<Result<AuthorizationResponse>> {
    return this.run(
      this.transport
        .rpc<AuthorizationRow>(
          'cedar_is_authorized',
          {
            principal: uidText(request.principal),
            action: uidText(request.action),
            resource: uidText(request.resource),
            context: request.context,
            entities: request.entities,
          },
          'scalar',
        )
        .then(toResponse),
    )
  }
}

/** Maps the SQL result to the shape of Cedar's `Response`. */
function toResponse(row: AuthorizationRow): AuthorizationResponse {
  return {
    decision: row.decision,
    diagnostics: {
      reason: row.reasons ?? [],
      errors: (row.errors ?? []).map((e) => ({ policyId: e.policy_id, error: { message: e.message } })),
    },
  }
}
