import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type pg from 'pg'
import { CedarClient, createClient, createServerClient, isCedarError, uid } from '../../src'
import type {
  CedarEntity,
  CedarRecord,
  CurrentAuthorizationRequest,
  PermissionsServerClient,
  PolicyJson,
  Result,
} from '../../src'
import { sqlTransport } from '../../src/transport/sql'
import { REST_URL, anonToken, authenticatedPool, ownerPool, resetDatabase, servicePool, userToken } from './helpers'

// Cedar end to end: the server puts policies, templates, links and
// entities over SQL; the browser checks over PostgREST as the user of the
// token; as() gives the same answers over SQL. The principal of the
// current-subject helpers is user::"<sub>" (current_subject_type() is
// 'user' by default).

const ENTITIES: CedarEntity[] = [
  { uid: { type: 'user', id: 'alice' }, attrs: { level: 5 }, parents: [{ type: 'Team', id: 'eng' }] },
  { uid: { type: 'user', id: 'bob' }, attrs: { level: 1 } },
  { uid: { type: 'Team', id: 'eng' } },
  { uid: { type: 'Folder', id: 'reports' } },
  { uid: { type: 'Document', id: 'q3' }, parents: [{ type: 'Folder', id: 'reports' }] },
  { uid: { type: 'Document', id: 'q4' }, parents: [{ type: 'Folder', id: 'reports' }] },
  { uid: { type: 'Document', id: 'secret' }, attrs: { classified: true }, parents: [{ type: 'Folder', id: 'reports' }] },
  { uid: { type: 'Document', id: 'memo' } },
  { uid: { type: 'Document', id: 'say "hi"' } },
]

const POLICIES: Record<string, string> = {
  'team-reports': 'permit (principal in Team::"eng", action == Action::"view", resource in Folder::"reports");',
  'no-classified': 'forbid (principal, action, resource) when { resource has classified && resource.classified };',
  // alice has no clearance: this forbid errs on q4.
  'q4-clearance': 'forbid (principal, action, resource == Document::"q4") when { principal.clearance > 3 };',
  'owner-view': 'permit (principal, action == Action::"view", resource) when { resource has owner && resource.owner == principal };',
  'mfa-edit': 'permit (principal, action == Action::"edit", resource) when { context.mfa == true };',
  'quoted-id': 'permit (principal == user::"bob", action == Action::"view", resource == Document::"say \\"hi\\"");',
}

// permit (principal == user::"bob", action == Action::"view", resource == Document::"memo");
const MEMO_JSON: PolicyJson = {
  effect: 'permit',
  principal: { op: '==', entity: { type: 'user', id: 'bob' } },
  action: { op: '==', entity: { type: 'Action', id: 'view' } },
  resource: { op: '==', entity: { type: 'Document', id: 'memo' } },
  conditions: [],
}

const VIEWER_TEMPLATE = 'permit (principal == ?principal, action == Action::"view", resource == ?resource);'

const VIEW = 'Action::"view"'

let owner: pg.Pool
let service: pg.Pool
let server: PermissionsServerClient

function ok<T>(result: Result<T>): T {
  expect(result.error).toBeNull()
  return result.data as T
}

/** The browser client of `sub` over PostgREST: the anon key and the user's token. */
function browser(sub: string) {
  return createClient(REST_URL, anonToken(), { restUrl: REST_URL, accessToken: async () => userToken(sub) })
}

beforeAll(async () => {
  owner = ownerPool()
  service = servicePool()
  await resetDatabase(owner)
  server = createServerClient(service)
  ok(await server.cedar.admin.putEntities(ENTITIES))
  for (const [policyId, policy] of Object.entries(POLICIES)) {
    ok(await server.cedar.admin.putPolicy({ policyId, policy }))
  }
  ok(await server.cedar.admin.putPolicy({ policyId: 'memo-json', policyJson: MEMO_JSON }))
  ok(await server.cedar.admin.putTemplate({ templateId: 'viewer', template: VIEWER_TEMPLATE }))
  ok(
    await server.cedar.admin.linkTemplate({
      policyId: 'bob-q3',
      templateId: 'viewer',
      principal: { type: 'user', id: 'bob' },
      resource: 'Document::"q3"',
    }),
  )
})

afterAll(async () => {
  await service?.end()
  await owner?.end()
})

describe('cedar admin over SQL', () => {
  it('lists the policies: text, JSON and links', async () => {
    const policies = ok(await server.cedar.admin.policies())
    expect(policies.map((p) => p.policyId)).toEqual([
      'bob-q3',
      'memo-json',
      'mfa-edit',
      'no-classified',
      'owner-view',
      'q4-clearance',
      'quoted-id',
      'team-reports',
    ])
    const byId = Object.fromEntries(policies.map((p) => [p.policyId, p]))
    expect(byId['team-reports']).toMatchObject({
      effect: 'permit',
      source: POLICIES['team-reports'],
      templateId: null,
      slots: null,
      annotations: {},
    })
    expect(byId['team-reports']!.est.resource).toEqual({ op: 'in', entity: { type: 'Folder', id: 'reports' } })
    expect(byId['memo-json']).toMatchObject({ effect: 'permit', source: null, est: MEMO_JSON })
    expect(byId['no-classified']!.effect).toBe('forbid')
    expect(byId['bob-q3']).toMatchObject({
      templateId: 'viewer',
      slots: { '?principal': { type: 'user', id: 'bob' }, '?resource': { type: 'Document', id: 'q3' } },
    })
  })

  it('lists the templates', async () => {
    const templates = ok(await server.cedar.admin.templates())
    expect(templates).toHaveLength(1)
    expect(templates[0]).toMatchObject({ templateId: 'viewer', source: VIEWER_TEMPLATE, annotations: {} })
    expect(templates[0]!.est.principal).toEqual({ op: '==', slot: '?principal' })
  })

  it('reads entities: all, by type, and by ids', async () => {
    expect(ok(await server.cedar.admin.readEntities())).toHaveLength(ENTITIES.length)
    expect(ok(await server.cedar.admin.readEntities({ type: 'user', ids: ['alice'] }))).toEqual([
      { uid: { type: 'user', id: 'alice' }, attrs: { level: 5 }, parents: [{ type: 'Team', id: 'eng' }], tags: {} },
    ])
    const docs = ok(await server.cedar.admin.readEntities({ type: 'Document' }))
    expect(docs.map((e) => e.uid.id)).toEqual(['memo', 'q3', 'q4', 'say "hi"', 'secret'])
  })

  it('isAuthorized: allow with the reasons', async () => {
    const request = { principal: { type: 'user', id: 'alice' }, action: VIEW, resource: 'Document::"q3"' }
    expect(ok(await server.cedar.admin.isAuthorized(request))).toEqual({
      decision: 'allow',
      diagnostics: { reason: ['team-reports'], errors: [] },
    })
  })

  it('isAuthorized: a forbid that errs is skipped and reported', async () => {
    const request = { principal: 'user::"alice"', action: VIEW, resource: 'Document::"q4"' }
    const response = ok(await server.cedar.admin.isAuthorized(request))
    expect(response.decision).toBe('allow')
    expect(response.diagnostics.reason).toEqual(['team-reports'])
    expect(response.diagnostics.errors).toHaveLength(1)
    expect(response.diagnostics.errors[0]!.policyId).toBe('q4-clearance')
    expect(response.diagnostics.errors[0]!.error.message).toMatch(/^attribute_not_found: /)
  })

  it('isAuthorized: a forbid that holds denies, and names the forbid', async () => {
    const request = { principal: 'user::"alice"', action: VIEW, resource: 'Document::"secret"' }
    expect(ok(await server.cedar.admin.isAuthorized(request))).toEqual({
      decision: 'deny',
      diagnostics: { reason: ['no-classified'], errors: [] },
    })
  })

  it('isAuthorized: links, JSON policies and escaped ids', async () => {
    const bob = { type: 'user', id: 'bob' }
    for (const id of ['q3', 'memo', 'say "hi"']) {
      const request = { principal: bob, action: VIEW, resource: { type: 'Document', id } }
      expect(ok(await server.cedar.admin.isAuthorized(request)).decision).toBe('allow')
    }
    // The default deny: no policy holds, and none errs.
    const denied = { principal: 'user::"alice"', action: VIEW, resource: 'Document::"memo"' }
    expect(ok(await server.cedar.admin.isAuthorized(denied))).toEqual({
      decision: 'deny',
      diagnostics: { reason: [], errors: [] },
    })
  })

  it('isAuthorized: context, and an entity overlay', async () => {
    const edit = { principal: 'user::"bob"', action: 'Action::"edit"', resource: 'Document::"memo"' }
    const context = { mfa: true }
    expect(ok(await server.cedar.admin.isAuthorized({ ...edit, context })).decision).toBe('allow')
    // Without context.mfa the permit errs: deny, with the error.
    const noContext = ok(await server.cedar.admin.isAuthorized(edit))
    expect(noContext.decision).toBe('deny')
    expect(noContext.diagnostics.errors.map((e) => e.policyId)).toEqual(['mfa-edit'])

    // carol is not stored: the overlay puts her in the team for this request.
    const carol = { type: 'user', id: 'carol' }
    const entities: CedarEntity[] = [{ uid: carol, parents: [{ type: 'Team', id: 'eng' }] }]
    const request = { principal: carol, action: VIEW, resource: 'Document::"q3"' }
    expect(ok(await server.cedar.admin.isAuthorized(request)).decision).toBe('deny')
    expect(ok(await server.cedar.admin.isAuthorized({ ...request, entities })).decision).toBe('allow')
  })

  it('puts, deletes and counts entities', async () => {
    const temp: CedarEntity[] = [{ uid: { type: 'Temp', id: 'a' } }, { uid: { type: 'Temp', id: 'b' } }]
    ok(await server.cedar.admin.putEntities(temp))
    const uids = [{ type: 'Temp', id: 'a' }, 'Temp::"b"', 'Temp::"missing"']
    expect(ok(await server.cedar.admin.deleteEntities(uids))).toBe(2)
    expect(ok(await server.cedar.admin.readEntities({ type: 'Temp' }))).toEqual([])
  })

  it('replaces and deletes policies, links and templates', async () => {
    const policy = 'permit (principal, action == Action::"tmp", resource);'
    ok(await server.cedar.admin.putPolicy({ policyId: 'tmp', policy }))
    ok(await server.cedar.admin.putTemplate({ templateId: 'tmp-t', template: VIEWER_TEMPLATE }))
    ok(
      await server.cedar.admin.linkTemplate({
        policyId: 'tmp-link',
        templateId: 'tmp-t',
        principal: uid('user', 'x'),
        resource: uid('Document', 'y'),
      }),
    )
    ok(await server.cedar.admin.deletePolicy({ policyId: 'tmp-link' }))
    ok(await server.cedar.admin.deleteTemplate({ templateId: 'tmp-t' }))
    ok(await server.cedar.admin.deletePolicy({ policyId: 'tmp' }))
    const ids = ok(await server.cedar.admin.policies()).map((p) => p.policyId)
    expect(ids).not.toContain('tmp')
    expect(ok(await server.cedar.admin.templates()).map((t) => t.templateId)).toEqual(['viewer'])
  })

  it('the admin functions need a grant', async () => {
    const pool = authenticatedPool()
    try {
      const cedar = new CedarClient({ transport: sqlTransport(pool) })
      const { error } = await cedar.admin.policies()
      expect(error?.code).toBe('42501')
    } finally {
      await pool.end()
    }
  })
})

describe('cedar current subject: fails closed', () => {
  it('without a subject, every answer is false or empty', async () => {
    const request = { action: VIEW, resource: 'Document::"q3"' }
    expect(ok(await server.cedar.isAuthorized(request))).toBe(false)
    expect(ok(await server.cedar.listResources({ action: VIEW, resourceType: 'Document' }))).toEqual([])
    const anon = createClient(REST_URL, anonToken(), { restUrl: REST_URL })
    expect(ok(await anon.cedar.isAuthorized(request))).toBe(false)
  })

  it('a forbid that errs denies, where admin.isAuthorized allows', async () => {
    const alice = server.as({ id: 'alice' })
    expect(ok(await alice.cedar.isAuthorized({ action: VIEW, resource: 'Document::"q3"' }))).toBe(true)
    expect(ok(await alice.cedar.isAuthorized({ action: VIEW, resource: 'Document::"q4"' }))).toBe(false)
    const listed = ok(await alice.cedar.listResources({ action: VIEW, resourceType: 'Document' }))
    expect(listed).toEqual(['q3'])
  })
})

describe('cedar over PostgREST', () => {
  it('isAuthorized as the user of the token', async () => {
    const alice = browser('alice')
    expect(ok(await alice.cedar.isAuthorized({ action: VIEW, resource: 'Document::"q3"' }))).toBe(true)
    expect(ok(await alice.cedar.isAuthorized({ action: VIEW, resource: 'Document::"secret"' }))).toBe(false)
    expect(ok(await alice.cedar.isAuthorized({ action: VIEW, resource: 'Document::"memo"' }))).toBe(false)
    const bob = browser('bob')
    const quoted = { type: 'Document', id: 'say "hi"' }
    expect(ok(await bob.cedar.isAuthorized({ action: VIEW, resource: quoted }))).toBe(true)
  })

  it('isAuthorized with resourceAttrs, for a row that is not stored', async () => {
    const resourceAttrs: CedarRecord = { owner: { __entity: { type: 'user', id: 'alice' } } }
    const request = { action: VIEW, resource: uid('Document', 'row-9'), resourceAttrs }
    expect(ok(await browser('alice').cedar.isAuthorized(request))).toBe(true)
    expect(ok(await browser('bob').cedar.isAuthorized(request))).toBe(false)
  })

  it('listResources as the user of the token', async () => {
    const request = { action: VIEW, resourceType: 'Document' }
    expect(ok(await browser('alice').cedar.listResources(request))).toEqual(['q3'])
    expect(ok(await browser('bob').cedar.listResources(request)).sort()).toEqual(['memo', 'q3', 'say "hi"'])
    expect(ok(await browser('carol').cedar.listResources(request))).toEqual([])
  })
})

describe('cedar: as() parity with PostgREST', () => {
  const resourceAttrs: CedarRecord = { owner: { __entity: { type: 'user', id: 'bob' } } }
  const requests: CurrentAuthorizationRequest[] = [
    { action: VIEW, resource: 'Document::"q3"' },
    { action: VIEW, resource: 'Document::"q4"' },
    { action: VIEW, resource: 'Document::"secret"' },
    { action: VIEW, resource: 'Document::"memo"' },
    { action: VIEW, resource: { type: 'Document', id: 'say "hi"' } },
    { action: VIEW, resource: 'Document::"row-1"', resourceAttrs },
    { action: 'Action::"edit"', resource: 'Document::"memo"' },
  ]

  it.each(['alice', 'bob', 'carol'])('%s gets the same answers', async (sub) => {
    const sql = server.as({ id: sub, role: 'authenticated' })
    const rest = browser(sub)
    for (const request of requests) {
      expect(ok(await sql.cedar.isAuthorized(request))).toBe(ok(await rest.cedar.isAuthorized(request)))
    }
    const list = { action: VIEW, resourceType: 'Document' }
    const viaSql = ok(await sql.cedar.listResources(list)).sort()
    expect(viaSql).toEqual(ok(await rest.cedar.listResources(list)).sort())
  })
})

describe('cedar errors', () => {
  it('parse_error, with the position', async () => {
    const { error } = await server.cedar.admin.putPolicy({ policyId: 'bad', policy: 'permit (' })
    expect(isCedarError(error, 'parse_error')).toBe(true)
    expect(error?.code).toBe('42601')
    expect(error?.reason).toEqual({ model: 'cedar', code: 'parse_error', context: { line: '1', column: '9' } })
    expect(error?.hint).toBeTruthy()
  })

  it('invalid_policy for a bad policyJson', async () => {
    const policyJson = { ...MEMO_JSON, effect: 'allow' } as unknown as PolicyJson
    const { error } = await server.cedar.admin.putPolicy({ policyId: 'bad', policyJson })
    expect(isCedarError(error, 'invalid_policy')).toBe(true)
    expect(error?.reason).toMatchObject({ context: { path: '$.effect' } })
  })

  it('unknown_policy and unknown_template', async () => {
    const policy = await server.cedar.admin.deletePolicy({ policyId: 'nope' })
    expect(isCedarError(policy.error, 'unknown_policy')).toBe(true)
    expect(policy.error?.reason).toMatchObject({ context: { policy_id: 'nope' } })
    const template = await server.cedar.admin.deleteTemplate({ templateId: 'nope' })
    expect(isCedarError(template.error, 'unknown_template')).toBe(true)
  })

  it('template_in_use and id_in_use', async () => {
    const inUse = await server.cedar.admin.deleteTemplate({ templateId: 'viewer' })
    expect(isCedarError(inUse.error, 'template_in_use')).toBe(true)
    expect(inUse.error?.code).toBe('2BP01')
    const policy = 'permit (principal, action, resource);'
    const taken = await server.cedar.admin.putPolicy({ policyId: 'viewer', policy })
    expect(isCedarError(taken.error, 'id_in_use')).toBe(true)
    expect(taken.error?.reason).toMatchObject({ context: { id: 'viewer' } })
  })

  it('invalid_link for a missing slot value', async () => {
    const link = { policyId: 'half', templateId: 'viewer', principal: 'user::"bob"' }
    const { error } = await server.cedar.admin.linkTemplate(link)
    expect(isCedarError(error, 'invalid_link')).toBe(true)
    expect(error?.reason).toMatchObject({ context: { slot: '?resource' } })
  })

  it('invalid_uid over SQL and over PostgREST', async () => {
    const request = { action: VIEW, resource: 'Document::q3' }
    const viaRest = await browser('alice').cedar.isAuthorized(request)
    expect(isCedarError(viaRest.error, 'invalid_uid')).toBe(true)
    expect(viaRest.error?.reason).toMatchObject({ context: { value: 'Document::q3' } })
    const viaSql = await server.as({ id: 'alice' }).cedar.isAuthorized(request)
    expect(isCedarError(viaSql.error, 'invalid_uid')).toBe(true)
  })

  it('invalid_entity with the index', async () => {
    const entities = [{ uid: { type: 'T', id: 'a' } }, { uid: { type: 'T', id: 'a' } }]
    const { error } = await server.cedar.admin.putEntities(entities)
    expect(isCedarError(error, 'invalid_entity')).toBe(true)
    expect(error?.reason).toMatchObject({ context: { index: '1' } })
  })

  it('invalid_context and null_argument', async () => {
    const context = [1] as unknown as CedarRecord
    const request = { principal: 'user::"bob"', action: VIEW, resource: 'Document::"q3"', context }
    const bad = await server.cedar.admin.isAuthorized(request)
    expect(isCedarError(bad.error, 'invalid_context')).toBe(true)
    const missing = await server.cedar.admin.deletePolicy({ policyId: null as unknown as string })
    expect(isCedarError(missing.error, 'null_argument')).toBe(true)
    expect(missing.error?.reason).toMatchObject({ context: { argument: 'policy_id' } })
  })

  it('throws with throwOnError', async () => {
    const throwing = createServerClient(service, { throwOnError: true })
    const failed = throwing.cedar.admin.deletePolicy({ policyId: 'nope' })
    await expect(failed).rejects.toSatisfy((e: unknown) => isCedarError(e, 'unknown_policy'))
  })
})
