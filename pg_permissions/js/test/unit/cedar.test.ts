import { describe, expect, expectTypeOf, it } from 'vitest'
import { CedarClient, uid } from '../../src/cedar'
import type { AuthorizationResponse, CedarAdminApi, CedarEntity, PolicyInfo, TemplateInfo } from '../../src/cedar'
import { PermissionsError, isCedarError, isFgaError, isRbacError, parseDetail } from '../../src/lib/errors'
import { FUNCTIONS } from '../../src/lib/functions'
import type { RpcArgs, Shape, Transport, TransportKind } from '../../src/lib/types'
import { postgrestTransport } from '../../src/transport/postgrest'
import { buildCall } from '../../src/transport/sql'
import type { SqlTransport } from '../../src/transport/sql'

type Call = { fn: string; args: RpcArgs; shape: Shape }

/** A fake transport: records each call and answers from `respond`. */
function fakeTransport<K extends TransportKind>(
  kind: K,
  respond: (call: Call) => unknown = () => null,
): Transport & { kind: K; calls: Call[] } {
  const calls: Call[] = []
  return {
    kind,
    calls,
    async rpc<T>(fn: string, args: RpcArgs, shape: Shape): Promise<T> {
      const call = { fn, args, shape }
      calls.push(call)
      const r = respond(call)
      if (r instanceof Error) throw r
      return r as T
    },
  }
}

const cedarError = (detail: string, code = '22023') =>
  new PermissionsError({ message: 'boom', details: detail, hint: 'fix it', code })

function sqlClient(respond?: (call: Call) => unknown, throwOnError?: boolean) {
  const transport = fakeTransport('sql', respond)
  return { transport, cedar: new CedarClient({ transport, throwOnError }) }
}

describe('CedarClient: client methods', () => {
  it('isAuthorized calls cedar_is_authorized_current with Cedar text', async () => {
    const transport = fakeTransport('postgrest', () => true)
    const cedar = new CedarClient({ transport })
    const resourceAttrs = { owner: 'alice', level: 2 }
    expect(await cedar.isAuthorized({ action: 'Action::"view"', resource: 'Doc::"1"' })).toEqual({
      data: true,
      error: null,
    })
    await cedar.isAuthorized({
      action: { type: 'Action', id: 'view' },
      resource: { type: 'Doc', id: 'say "hi"' },
      resourceAttrs,
    })
    expect(transport.calls).toEqual([
      {
        fn: 'cedar_is_authorized_current',
        args: { action: 'Action::"view"', resource: 'Doc::"1"', resource_attrs: undefined },
        shape: 'scalar',
      },
      {
        fn: 'cedar_is_authorized_current',
        args: { action: 'Action::"view"', resource: 'Doc::"say \\"hi\\""', resource_attrs: resourceAttrs },
        shape: 'scalar',
      },
    ])
  })

  it('isAuthorized treats null as false', async () => {
    const cedar = new CedarClient({ transport: fakeTransport('postgrest', () => null) })
    expect(await cedar.isAuthorized({ action: 'Action::"view"', resource: 'Doc::"1"' })).toEqual({
      data: false,
      error: null,
    })
  })

  it('listResources calls cedar_list_resources_current', async () => {
    const transport = fakeTransport('postgrest', () => ['1', '2'])
    const cedar = new CedarClient({ transport })
    expect(await cedar.listResources({ action: { type: 'Action', id: 'view' }, resourceType: 'Doc' })).toEqual({
      data: ['1', '2'],
      error: null,
    })
    expect(transport.calls).toEqual([
      { fn: 'cedar_list_resources_current', args: { action: 'Action::"view"', resource_type: 'Doc' }, shape: 'set' },
    ])
  })

  it('returns a PermissionsError as { data: null, error }', async () => {
    const transport = fakeTransport('postgrest', () => cedarError("cedar:invalid_uid value='Doc::1'"))
    const { data, error } = await new CedarClient({ transport }).isAuthorized({
      action: 'Action::"view"',
      resource: 'Doc::1',
    })
    expect(data).toBeNull()
    expect(isCedarError(error, 'invalid_uid')).toBe(true)
    expect(error?.reason).toEqual({ model: 'cedar', code: 'invalid_uid', context: { value: 'Doc::1' } })
  })

  it('throws with throwOnError', async () => {
    const transport = fakeTransport('postgrest', () => cedarError("cedar:invalid_uid value='x'"))
    const cedar = new CedarClient({ transport, throwOnError: true })
    await expect(cedar.listResources({ action: 'x', resourceType: 'Doc' })).rejects.toBeInstanceOf(PermissionsError)
  })

  it('always throws a programming error', async () => {
    const transport = fakeTransport('postgrest', () => new Error('refused'))
    const cedar = new CedarClient({ transport })
    await expect(cedar.isAuthorized({ action: 'a', resource: 'r' })).rejects.toThrow('refused')
  })

  it('needs a URL or a transport', () => {
    // @ts-expect-error not a valid argument
    expect(() => new CedarClient({})).toThrow(/CedarClient/)
  })
})

const makeSqlClient = (transport: SqlTransport) => new CedarClient({ transport })

describe('CedarClient: admin only on SQL', () => {
  it('a PostgREST client has no admin, at runtime and in the type', () => {
    const cedar = new CedarClient('http://localhost:3000', { fetch: (async () => new Response('true')) as typeof fetch })
    expect('admin' in cedar).toBe(false)
    // @ts-expect-error admin does not exist on a PostgREST client
    expect(cedar.admin).toBeUndefined()
    const viaTransport = new CedarClient({ transport: fakeTransport('postgrest') })
    expect('admin' in viaTransport).toBe(false)
    // @ts-expect-error admin does not exist on a postgrest-kind transport
    void viaTransport.admin
  })

  it('an SQL client has admin', () => {
    const { cedar } = sqlClient()
    expect(cedar.admin).toBeDefined()
    expectTypeOf(cedar.admin).toEqualTypeOf<CedarAdminApi>()
    expectTypeOf<ReturnType<typeof makeSqlClient>['admin']>().toEqualTypeOf<CedarAdminApi>()
  })

  it('a subject transport has no admin, at runtime and in the type', () => {
    const cedar = new CedarClient({ transport: fakeTransport('subject') })
    expect('admin' in cedar).toBe(false)
    // @ts-expect-error admin does not exist on a subject transport
    void cedar.admin
  })

  it('types the client by the kind of the transport', () => {
    expectTypeOf(new CedarClient({ transport: fakeTransport('sql') })).toEqualTypeOf<CedarClient<'sql'>>()
    expectTypeOf(new CedarClient({ transport: fakeTransport('postgrest') })).toEqualTypeOf<CedarClient<'postgrest'>>()
    expectTypeOf(new CedarClient({ transport: fakeTransport('subject') })).toEqualTypeOf<CedarClient<'subject'>>()
    expectTypeOf(new CedarClient('http://x')).toEqualTypeOf<CedarClient<'postgrest'>>()
    const general: Transport = fakeTransport('sql')
    expectTypeOf(new CedarClient({ transport: general })).toEqualTypeOf<CedarClient>()
    expectTypeOf<CedarClient<'subject'>>().not.toHaveProperty('admin')
    expectTypeOf<CedarClient<'postgrest'>>().not.toHaveProperty('admin')
    expectTypeOf<CedarClient>().not.toHaveProperty('admin')
  })

  it('types the arguments and results', () => {
    const { cedar } = sqlClient()
    void (() => {
      // @ts-expect-error policyId is required
      void cedar.admin.putPolicy({ policy: 'permit (principal, action, resource);' })
      // @ts-expect-error resourceType is required
      void cedar.listResources({ action: 'Action::"view"' })
      // @ts-expect-error a uid is text or { type, id }
      void cedar.isAuthorized({ action: 'Action::"view"', resource: { id: '1' } })
      // @ts-expect-error attrs are Cedar values
      void cedar.admin.putEntities([{ uid: { type: 'U', id: 'a' }, attrs: { at: new Date() } }])
    })
    expectTypeOf(cedar.admin.isAuthorized).returns.resolves.toHaveProperty('data').toEqualTypeOf<
      AuthorizationResponse | null
    >()
    expectTypeOf(cedar.admin.policies).returns.resolves.toHaveProperty('data').toEqualTypeOf<PolicyInfo[] | null>()
    expectTypeOf(cedar.admin.templates).returns.resolves.toHaveProperty('data').toEqualTypeOf<TemplateInfo[] | null>()
    expectTypeOf(cedar.admin.readEntities).returns.resolves.toHaveProperty('data').toEqualTypeOf<
      Required<CedarEntity>[] | null
    >()
    expectTypeOf(cedar.admin.deleteEntities).returns.resolves.toHaveProperty('data').toEqualTypeOf<number | null>()
  })
})

describe('CedarClient: admin methods', () => {
  const policyJson = {
    effect: 'permit' as const,
    principal: { op: 'All' },
    action: { op: 'All' },
    resource: { op: 'All' },
    conditions: [],
  }

  it('maps the policy and template calls to the SQL names', async () => {
    const { transport, cedar } = sqlClient()
    const admin = cedar.admin
    expect(await admin.putPolicy({ policyId: 'p', policy: 'permit (principal, action, resource);' })).toEqual({
      data: null,
      error: null,
    })
    await admin.putPolicy({ policyId: 'q', policyJson })
    await admin.deletePolicy({ policyId: 'p' })
    await admin.putTemplate({ templateId: 't', template: 'permit (principal == ?principal, action, resource);' })
    await admin.putTemplate({ templateId: 'u', templateJson: policyJson })
    await admin.linkTemplate({
      policyId: 'l',
      templateId: 't',
      principal: { type: 'User', id: 'a"b' },
      resource: 'Doc::"1"',
    })
    await admin.linkTemplate({ policyId: 'm', templateId: 't', principal: 'User::"c"' })
    await admin.deleteTemplate({ templateId: 't' })
    expect(transport.calls).toEqual([
      {
        fn: 'cedar_put_policy',
        args: { policy_id: 'p', policy: 'permit (principal, action, resource);', policy_json: undefined },
        shape: 'void',
      },
      { fn: 'cedar_put_policy', args: { policy_id: 'q', policy: undefined, policy_json: policyJson }, shape: 'void' },
      { fn: 'cedar_delete_policy', args: { policy_id: 'p' }, shape: 'void' },
      {
        fn: 'cedar_put_template',
        args: {
          template_id: 't',
          template: 'permit (principal == ?principal, action, resource);',
          template_json: undefined,
        },
        shape: 'void',
      },
      {
        fn: 'cedar_put_template',
        args: { template_id: 'u', template: undefined, template_json: policyJson },
        shape: 'void',
      },
      {
        fn: 'cedar_link_template',
        args: { policy_id: 'l', template_id: 't', principal: 'User::"a\\"b"', resource: 'Doc::"1"' },
        shape: 'void',
      },
      {
        fn: 'cedar_link_template',
        args: { policy_id: 'm', template_id: 't', principal: 'User::"c"', resource: undefined },
        shape: 'void',
      },
      { fn: 'cedar_delete_template', args: { template_id: 't' }, shape: 'void' },
    ])
  })

  it('maps the rows of cedar_policies and cedar_templates to camelCase', async () => {
    const { cedar } = sqlClient((c) =>
      c.fn === 'cedar_policies'
        ? [
            {
              policy_id: 'l',
              effect: 'permit',
              source: null,
              est: policyJson,
              annotations: {},
              template_id: 't',
              slots: { '?principal': { type: 'User', id: 'a' } },
            },
            {
              policy_id: 'p',
              effect: 'forbid',
              source: 'forbid (principal, action, resource);',
              est: policyJson,
              annotations: null,
              template_id: null,
              slots: null,
            },
          ]
        : [{ template_id: 't', source: 'permit (...);', est: policyJson, annotations: { id: 'x' } }],
    )
    expect((await cedar.admin.policies()).data).toEqual([
      {
        policyId: 'l',
        effect: 'permit',
        source: null,
        est: policyJson,
        annotations: {},
        templateId: 't',
        slots: { '?principal': { type: 'User', id: 'a' } },
      },
      {
        policyId: 'p',
        effect: 'forbid',
        source: 'forbid (principal, action, resource);',
        est: policyJson,
        annotations: {},
        templateId: null,
        slots: null,
      },
    ])
    expect((await cedar.admin.templates()).data).toEqual([
      { templateId: 't', source: 'permit (...);', est: policyJson, annotations: { id: 'x' } },
    ])
  })

  it('maps the entity calls', async () => {
    const stored = [{ uid: { type: 'User', id: 'a' }, attrs: {}, parents: [], tags: {} }]
    const { transport, cedar } = sqlClient((c) => {
      if (c.fn === 'cedar_delete_entities') return '2'
      if (c.fn === 'cedar_read_entities') return c.args.type === 'None' ? null : stored
      return null
    })
    const entities: CedarEntity[] = [
      { uid: { type: 'User', id: 'a' }, attrs: { level: 5 }, parents: [{ type: 'Team', id: 'eng' }] },
    ]
    const uids = [{ type: 'User', id: 'a' }, 'Team::"eng"']
    await cedar.admin.putEntities(entities)
    expect(await cedar.admin.deleteEntities(uids)).toEqual({ data: 2, error: null })
    expect((await cedar.admin.readEntities()).data).toEqual(stored)
    expect((await cedar.admin.readEntities({ type: 'User', ids: ['a'] })).data).toEqual(stored)
    expect((await cedar.admin.readEntities({ type: 'None' })).data).toEqual([])
    expect(transport.calls).toEqual([
      { fn: 'cedar_put_entities', args: { entities }, shape: 'void' },
      { fn: 'cedar_delete_entities', args: { uids }, shape: 'scalar' },
      { fn: 'cedar_read_entities', args: { type: undefined, ids: undefined }, shape: 'scalar' },
      { fn: 'cedar_read_entities', args: { type: 'User', ids: ['a'] }, shape: 'scalar' },
      { fn: 'cedar_read_entities', args: { type: 'None', ids: undefined }, shape: 'scalar' },
    ])
  })

  it('deleteEntities accepts a number and a null', async () => {
    let answer: unknown = 3
    const { cedar } = sqlClient(() => answer)
    expect((await cedar.admin.deleteEntities(['User::"a"'])).data).toBe(3)
    answer = null
    expect((await cedar.admin.deleteEntities(['User::"a"'])).data).toBe(0)
  })

  it('isAuthorized maps the request, and the response to the shape of Cedar', async () => {
    const { transport, cedar } = sqlClient(() => ({
      decision: 'allow',
      reasons: ['p1'],
      errors: [{ policy_id: 'p2', message: 'attribute_not_found: x' }],
    }))
    const context = { mfa: true }
    const entities: CedarEntity[] = [{ uid: { type: 'User', id: 'a' } }]
    const { data } = await cedar.admin.isAuthorized({
      principal: { type: 'User', id: 'a' },
      action: 'Action::"view"',
      resource: { type: 'Doc', id: 'back\\slash' },
      context,
      entities,
    })
    expect(data).toEqual({
      decision: 'allow',
      diagnostics: {
        reason: ['p1'],
        errors: [{ policyId: 'p2', error: { message: 'attribute_not_found: x' } }],
      },
    })
    expect(transport.calls).toEqual([
      {
        fn: 'cedar_is_authorized',
        args: {
          principal: 'User::"a"',
          action: 'Action::"view"',
          resource: 'Doc::"back\\\\slash"',
          context,
          entities,
        },
        shape: 'scalar',
      },
    ])
  })

  it('isAuthorized defaults missing arrays to empty', async () => {
    const { cedar } = sqlClient(() => ({ decision: 'deny', reasons: null, errors: null }))
    const { data } = await cedar.admin.isAuthorized({ principal: 'U::"a"', action: 'A::"v"', resource: 'R::"r"' })
    expect(data).toEqual({ decision: 'deny', diagnostics: { reason: [], errors: [] } })
  })

  it('returns or throws admin errors', async () => {
    const err = () => cedarError("cedar:unknown_policy policy_id='nope'")
    const { cedar } = sqlClient(err)
    const { data, error } = await cedar.admin.deletePolicy({ policyId: 'nope' })
    expect(data).toBeNull()
    expect(isCedarError(error, 'unknown_policy')).toBe(true)
    expect(isCedarError(error, 'unknown_template')).toBe(false)
    const throwing = sqlClient(err, true).cedar
    await expect(throwing.admin.deletePolicy({ policyId: 'nope' })).rejects.toBeInstanceOf(PermissionsError)
    await expect(throwing.admin.policies()).rejects.toBeInstanceOf(PermissionsError)
  })
})

describe('uid', () => {
  it.each([
    ['User', 'alice', 'User::"alice"'],
    ['App::User', 'alice', 'App::User::"alice"'],
    ['Doc', 'say "hi"', 'Doc::"say \\"hi\\""'],
    ['Doc', 'a\\b', 'Doc::"a\\\\b"'],
    ['Doc', 'line\nbreak\ttab\rcr', 'Doc::"line\\nbreak\\ttab\\rcr"'],
    ['Doc', 'bell\u0007del\u007f', 'Doc::"bell\\u{7}del\\u{7f}"'],
    ['Doc', "it's é 😀", 'Doc::"it\'s é 😀"'],
    ['Doc', '', 'Doc::""'],
  ])('uid(%j, %j) is %s', (type, id, text) => {
    expect(uid(type, id)).toBe(text)
  })
})

describe('the Cedar functions in the allow-list', () => {
  it('only the two current-subject functions are public', () => {
    const cedar = Object.entries(FUNCTIONS).filter(([name]) => name.startsWith('cedar_'))
    expect(cedar.filter(([, spec]) => spec.public).map(([name]) => name)).toEqual([
      'cedar_is_authorized_current',
      'cedar_list_resources_current',
    ])
    expect(cedar).toHaveLength(13)
  })

  it('never sends plan_time_guard', () => {
    expect(() =>
      buildCall('"permissions"', 'cedar_is_authorized_current', { action: 'a', plan_time_guard: true }, 'scalar'),
    ).toThrow(/no argument 'plan_time_guard'/)
    expect(
      buildCall(
        '"permissions"',
        'cedar_is_authorized_current',
        { action: 'A::"v"', resource: 'R::"r"', resource_attrs: { a: 1 } },
        'scalar',
      ),
    ).toEqual({
      text: 'select "permissions".cedar_is_authorized_current(action => $1::text, resource => $2::text, resource_attrs => $3::jsonb) as value',
      values: ['A::"v"', 'R::"r"', '{"a":1}'],
    })
  })

  it('builds the SQL of the table and jsonb functions', () => {
    expect(buildCall('"permissions"', 'cedar_policies', {}, 'rows').text).toBe(
      'select * from "permissions".cedar_policies()',
    )
    expect(buildCall('"permissions"', 'cedar_read_entities', { type: 'U', ids: ['a'] }, 'scalar')).toEqual({
      text: 'select "permissions".cedar_read_entities(type => $1::text, ids => $2::text[]) as value',
      values: ['U', ['a']],
    })
    expect(buildCall('"permissions"', 'cedar_list_resources_current', { action: 'a', resource_type: 'D' }, 'set'))
      .toEqual({
        text: 'select value from "permissions".cedar_list_resources_current(action => $1::text, resource_type => $2::text) as t(value)',
        values: ['a', 'D'],
      })
  })

  it('PostgREST refuses the admin functions', async () => {
    const transport = postgrestTransport('http://x', { fetch: (async () => new Response('true')) as typeof fetch })
    await expect(transport.rpc('cedar_put_policy', { policy_id: 'p' }, 'void')).rejects.toThrow(/admin function/)
    await expect(transport.rpc('cedar_is_authorized', { principal: 'p' }, 'scalar')).rejects.toThrow(/admin function/)
    await expect(
      transport.rpc('cedar_is_authorized_current', { action: 'a', resource: 'r' }, 'scalar'),
    ).resolves.toBe(true)
  })
})

// DETAIL strings as the extension raises them (test/spec/d/51_cedar_errors.sql).
const CEDAR_FIXTURES: Array<[string, string, Record<string, string>]> = [
  ['cedar:parse_error line=1 column=9', 'parse_error', { line: '1', column: '9' }],
  ["cedar:invalid_policy path='$.conditions[0].body.\"==\".Slot'", 'invalid_policy', {
    path: '$.conditions[0].body."==".Slot',
  }],
  ["cedar:unknown_policy policy_id='zzz'", 'unknown_policy', { policy_id: 'zzz' }],
  ["cedar:unknown_template template_id='viewer'", 'unknown_template', { template_id: 'viewer' }],
  ["cedar:template_in_use template_id='viewer'", 'template_in_use', { template_id: 'viewer' }],
  ["cedar:id_in_use id='alice-edit'", 'id_in_use', { id: 'alice-edit' }],
  ["cedar:invalid_link slot='?resource'", 'invalid_link', { slot: '?resource' }],
  ["cedar:invalid_uid value='User::\"a\"b\"'", 'invalid_uid', { value: 'User::"a"b"' }],
  ["cedar:invalid_uid value=E'Doc::\"a\\\\\\\\b\"'", 'invalid_uid', { value: 'Doc::"a\\\\b"' }],
  ["cedar:invalid_uid value='it''s'", 'invalid_uid', { value: "it's" }],
  ['cedar:invalid_entity index=2', 'invalid_entity', { index: '2' }],
  ["cedar:invalid_entity uid='G::\"a\"'", 'invalid_entity', { uid: 'G::"a"' }],
  ['cedar:invalid_context', 'invalid_context', {}],
  ["cedar:invalid_argument value='bad type'", 'invalid_argument', { value: 'bad type' }],
  ["cedar:unsupported feature='nul'", 'unsupported', { feature: 'nul' }],
  ["cedar:null_argument argument='policy_id'", 'null_argument', { argument: 'policy_id' }],
  ["cedar:limit_exceeded limit='policy_bytes'", 'limit_exceeded', { limit: 'policy_bytes' }],
  ["cedar:limit_exceeded limit='value_depth' index=0", 'limit_exceeded', { limit: 'value_depth', index: '0' }],
]

describe('parseDetail: cedar', () => {
  it.each(CEDAR_FIXTURES)('parses %s', (detail, code, context) => {
    expect(parseDetail(detail)).toEqual({ model: 'cedar', code, context })
  })

  it('keeps the code when the context does not parse', () => {
    expect(parseDetail("cedar:invalid_uid value='unclosed")).toEqual({
      model: 'cedar',
      code: 'invalid_uid',
      context: {},
    })
  })

  it('does not parse other prefixes as cedar', () => {
    expect(parseDetail('cedarx:parse_error')).toBeNull()
    expect(parseDetail('cedar:')).toBeNull()
    expect(parseDetail(' cedar:parse_error')).toBeNull()
  })

  it('isCedarError narrows, and the other guards do not match', () => {
    const error: unknown = cedarError("cedar:template_in_use template_id='viewer'", '2BP01')
    expect(isCedarError(error)).toBe(true)
    expect(isCedarError(error, 'template_in_use')).toBe(true)
    expect(isCedarError(error, 'unknown_template')).toBe(false)
    expect(isRbacError(error)).toBe(false)
    expect(isFgaError(error)).toBe(false)
    expect(isCedarError(new Error('x'))).toBe(false)
    expect(isCedarError(cedarError("rbac:unknown_role role='a'"))).toBe(false)
    if (isCedarError(error)) {
      expectTypeOf(error.reason.model).toEqualTypeOf<'cedar'>()
      expect(error.reason.context.template_id).toBe('viewer')
    }
  })
})
