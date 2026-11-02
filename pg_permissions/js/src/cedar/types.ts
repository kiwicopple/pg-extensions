/**
 * The Cedar data types. The names and shapes follow Cedar's own JS API
 * (`@cedar-policy/cedar-wasm`): entity JSON, `EntityUid`, `Decision` and
 * the `Response` of `isAuthorized`. The client maps them to the SQL argument
 * names of pg_permissions.
 */

/**
 * An entity uid in Cedar's JSON form: `{ type: 'User', id: 'alice' }`.
 * Cedar text for the same uid is `User::"alice"` (see {@link uid}).
 */
export interface EntityUid {
  /** The entity type, for example `'User'` or `'App::User'`. */
  type: string
  /** The entity id. Any string. */
  id: string
}

/**
 * A uid argument: Cedar text (`'User::"alice"'`) or an {@link EntityUid}.
 * The client turns an `EntityUid` into Cedar text with {@link uid}, so
 * an id with `"` or `\` needs no escaping by hand.
 */
export type EntityRef = string | EntityUid

/**
 * A value in Cedar's JSON form: a string, a Long (an integer), a Bool, a set
 * (an array) or a record (an object). An entity reference is
 * `{ __entity: { type, id } }` and an extension value is
 * `{ __extn: { fn: 'decimal', arg: '12.34' } }` (`decimal`, `ip`,
 * `datetime` and `duration`).
 */
export type CedarValue = string | number | boolean | CedarValue[] | { [key: string]: CedarValue }

/** A record of Cedar values: the `attrs`, `tags` and `context` of a request. */
export type CedarRecord = Record<string, CedarValue>

/**
 * An entity in Cedar's entity JSON format, as `cedar_put_entities` takes it
 * and `cedar_read_entities` returns it.
 */
export interface CedarEntity {
  /** The uid of the entity. */
  uid: EntityUid
  /** The attributes. Default `{}`. */
  attrs?: CedarRecord
  /** The parents, for `in`. Default `[]`. Cycles are refused. */
  parents?: EntityUid[]
  /** The tags, for `hasTag` and `getTag`. Default `{}`. */
  tags?: CedarRecord
}

/**
 * A policy or template in Cedar's JSON policy format (the EST), as the
 * Cedar CLI writes it (`cedar translate-policy`). A template has a slot,
 * `{ slot: '?principal' }` or `{ slot: '?resource' }`, in its scope.
 */
export interface PolicyJson {
  effect: 'permit' | 'forbid'
  principal: Record<string, unknown>
  action: Record<string, unknown>
  resource: Record<string, unknown>
  conditions: Array<Record<string, unknown>>
  annotations?: Record<string, string | null>
  [key: string]: unknown
}

/** The decision of a request, as in Cedar. */
export type Decision = 'allow' | 'deny'

/**
 * An error in one policy during a request, as in Cedar's
 * `AuthorizationError`. The policy was skipped: it neither permits nor
 * forbids.
 */
export interface AuthorizationError {
  /** The id of the policy that erred. */
  policyId: string
  error: {
    /**
     * The message: a code that follows Cedar's evaluation error kinds,
     * a colon, and a detail, for example
     * `attribute_not_found: "level" on User::"alice"`.
     */
    message: string
  }
}

/** How the decision was reached, as in Cedar's `Diagnostics`. */
export interface Diagnostics {
  /**
   * The ids of the policies that decided: the forbids that hold for a
   * deny, else the permits that hold. Sorted. Empty for the default deny.
   */
  reason: string[]
  /** The policies that erred, sorted by id. */
  errors: AuthorizationError[]
}

/**
 * The answer of `admin.isAuthorized`. It has the shape of the `response`
 * of Cedar's `isAuthorized` (`@cedar-policy/cedar-wasm`), so code that
 * reads `answer.response` of Cedar reads this the same way. The SQL
 * function returns `{ decision, reasons, errors: [{ policy_id, message }] }`.
 */
export interface AuthorizationResponse {
  decision: Decision
  diagnostics: Diagnostics
}

/** A static policy or a template link, as `admin.policies()` returns it. */
export interface PolicyInfo {
  /** The id given to `putPolicy` or `linkTemplate`. */
  policyId: string
  effect: 'permit' | 'forbid'
  /** The Cedar text of a text put. `null` for a JSON put or a link. */
  source: string | null
  /** The policy in Cedar's JSON format. A link has its slots filled. */
  est: PolicyJson
  /** The annotations, for example `{ id: 'x' }` from `@id("x")`. */
  annotations: Record<string, string | null>
  /** The template of a link. `null` for a static policy. */
  templateId: string | null
  /**
   * The slot values of a link, for example
   * `{ '?principal': { type: 'User', id: 'alice' } }`. `null` for a
   * static policy.
   */
  slots: Partial<Record<'?principal' | '?resource', EntityUid>> | null
}

/** A template, as `admin.templates()` returns it. */
export interface TemplateInfo {
  /** The id given to `putTemplate`. */
  templateId: string
  /** The Cedar text of a text put. `null` for a JSON put. */
  source: string | null
  /** The template in Cedar's JSON format, with its slots. */
  est: PolicyJson
  /** The annotations. */
  annotations: Record<string, string | null>
}

/** Arguments of `admin.putPolicy`. Give `policy` or `policyJson`. */
export interface PutPolicyRequest {
  /** The id. A put with an existing id replaces that policy. */
  policyId: string
  /** One policy in Cedar text. */
  policy?: string
  /** One policy in Cedar's JSON format. */
  policyJson?: PolicyJson
}

/** Arguments of `admin.deletePolicy`. */
export interface DeletePolicyRequest {
  /** The id of a static policy or a link. */
  policyId: string
}

/** Arguments of `admin.putTemplate`. Give `template` or `templateJson`. */
export interface PutTemplateRequest {
  /** The id. A put with an existing id replaces it and refills its links. */
  templateId: string
  /** One template in Cedar text. */
  template?: string
  /** One template in Cedar's JSON format. */
  templateJson?: PolicyJson
}

/**
 * Arguments of `admin.linkTemplate`. Give a value for each slot of the
 * template, and no other.
 */
export interface LinkTemplateRequest {
  /** The id of the link. Linking an existing link id replaces the link. */
  policyId: string
  templateId: string
  /** The value of `?principal`. */
  principal?: EntityRef
  /** The value of `?resource`. */
  resource?: EntityRef
}

/** Arguments of `admin.deleteTemplate`. */
export interface DeleteTemplateRequest {
  templateId: string
}

/** Arguments of `admin.readEntities`. */
export interface ReadEntitiesRequest {
  /** Only the entities of this type. Default: every type. */
  type?: string
  /** Only these ids of `type`. Needs `type`. */
  ids?: string[]
}

/** Arguments of `admin.isAuthorized`: a full Cedar request. */
export interface AuthorizationRequest {
  principal: EntityRef
  action: EntityRef
  resource: EntityRef
  /** The context record. Default `{}`. */
  context?: CedarRecord
  /**
   * Entities for this request only. Each one replaces the stored entity
   * with the same uid. At most 1,000.
   */
  entities?: CedarEntity[]
}

/** Arguments of the client `isAuthorized`: the current subject is the principal. */
export interface CurrentAuthorizationRequest {
  action: EntityRef
  resource: EntityRef
  /**
   * Attributes that replace the `attrs` of the resource, for example the
   * columns of a row. Its parents and tags still come from storage.
   */
  resourceAttrs?: CedarRecord
}

/** Arguments of the client `listResources`. */
export interface ListResourcesRequest {
  action: EntityRef
  /** The resource type, for example `'Document'`. */
  resourceType: string
}
