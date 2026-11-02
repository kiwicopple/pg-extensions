import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import type pg from 'pg'
import { FgaClient } from '../../src/fga'
import type { AuthorizationModel, TupleKey } from '../../src/fga'
import { PermissionsError, isFgaError } from '../../src/lib/errors'
import { sqlTransport } from '../../src/transport/sql'
import { REST_URL, authHeaders, authenticatedPool, ownerPool, servicePool, userToken } from './helpers'

// The model of docs/conditions.md, with a team for usersets.
const MODEL: AuthorizationModel = {
  schema_version: '1.1',
  type_definitions: [
    { type: 'user' },
    {
      type: 'team',
      relations: { member: { this: {} } },
      metadata: { relations: { member: { directly_related_user_types: [{ type: 'user' }] } } },
    },
    {
      type: 'document',
      relations: { viewer: { this: {} } },
      metadata: {
        relations: {
          viewer: {
            directly_related_user_types: [
              { type: 'user' },
              { type: 'team', relation: 'member' },
              { type: 'user', condition: 'non_expired_grant' },
              { type: 'user', condition: 'in_office_network' },
            ],
          },
        },
      },
    },
  ],
  conditions: {
    non_expired_grant: {
      name: 'non_expired_grant',
      expression: 'current_time < grant_time + grant_duration',
      parameters: {
        current_time: { type_name: 'TYPE_NAME_TIMESTAMP' },
        grant_time: { type_name: 'TYPE_NAME_TIMESTAMP' },
        grant_duration: { type_name: 'TYPE_NAME_DURATION' },
      },
    },
    in_office_network: {
      name: 'in_office_network',
      expression: 'user_ip.in_cidr(cidr)',
      parameters: {
        user_ip: { type_name: 'TYPE_NAME_IPADDRESS' },
        cidr: { type_name: 'TYPE_NAME_STRING' },
      },
    },
  },
}

const UNKNOWN_MODEL_ID = '01ARZ3NDEKTSV4RRFFQ69G5FAV'

const anneGrant: TupleKey = {
  user: 'user:anne',
  relation: 'viewer',
  object: 'document:roadmap',
  condition: { name: 'non_expired_grant', context: { grant_time: '2026-01-01T00:00:00Z', grant_duration: '720h' } },
}
const bobOffice: TupleKey = {
  user: 'user:bob',
  relation: 'viewer',
  object: 'document:roadmap',
  condition: { name: 'in_office_network', context: { cidr: '10.20.0.0/16' } },
}
const BASE_TUPLES: TupleKey[] = [
  anneGrant,
  bobOffice,
  { user: 'user:alice', relation: 'viewer', object: 'document:1' },
  { user: 'user:alice', relation: 'viewer', object: 'document:2' },
  { user: 'team:eng#member', relation: 'viewer', object: 'document:3' },
  { user: 'user:carl', relation: 'member', object: 'team:eng' },
]

let owner: pg.Pool
let service: pg.Pool
// The owner can call fga_delete_store(); service_role cannot (test/setup.sql).
let ownerFga: FgaClient<'sql'>
let fga: FgaClient<'sql'>
let modelId: string

/**
 * Resets only the FGA state (models and tuples) with fga_delete_store(), so
 * that RBAC tests on the same database are not affected. Then writes MODEL and
 * BASE_TUPLES.
 */
async function resetFga(): Promise<void> {
  const { error } = await ownerFga.admin.deleteStore()
  expect(error).toBeNull()
  const written = await fga.admin.writeAuthorizationModel(MODEL)
  expect(written.error).toBeNull()
  modelId = written.data!.authorizationModelId
  const { error: writeError } = await fga.admin.write({ writes: BASE_TUPLES })
  expect(writeError).toBeNull()
}

beforeAll(() => {
  owner = ownerPool()
  service = servicePool()
  ownerFga = new FgaClient({ transport: sqlTransport(owner) })
  fga = new FgaClient({ transport: sqlTransport(service) })
})

afterAll(async () => {
  await ownerFga?.admin.deleteStore()
  await service?.end()
  await owner?.end()
})

describe('FGA admin (sql, service_role)', () => {
  beforeEach(resetFga)

  it('writes and reads authorization models', async () => {
    expect(modelId).toMatch(/^[0-9A-Z]{26}$/)
    const latest = await fga.admin.readAuthorizationModel()
    expect(latest.error).toBeNull()
    expect(latest.data).toMatchObject({ id: modelId, schema_version: '1.1' })
    expect(latest.data!.type_definitions).toHaveLength(3)
    expect(latest.data!.conditions).toBeDefined()

    const second = await fga.admin.writeAuthorizationModel(JSON.stringify(MODEL))
    expect(second.error).toBeNull()
    const secondId = second.data!.authorizationModelId
    expect(secondId).not.toBe(modelId)

    const byId = await fga.admin.readAuthorizationModel({ authorizationModelId: modelId })
    expect(byId.data!.id).toBe(modelId)

    const models = await fga.admin.readAuthorizationModels()
    expect(models.error).toBeNull()
    expect(models.data!.map((m) => m.id)).toEqual([secondId, modelId])
    for (const m of models.data!) {
      expect(m.createdAt).toBeInstanceOf(Date)
      expect(Number.isNaN(m.createdAt.getTime())).toBe(false)
    }
  })

  it('reads tuples page by page, following the continuation token to ""', async () => {
    const seen: TupleKey[] = []
    let continuationToken = ''
    let pages = 0
    do {
      const { data, error } = await fga.admin.read({ pageSize: 1, continuationToken })
      expect(error).toBeNull()
      expect(data!.tuples).toHaveLength(1)
      const tuple = data!.tuples[0]!
      expect(typeof tuple.timestamp).toBe('string')
      seen.push(tuple.key)
      continuationToken = data!.continuationToken
      pages++
    } while (continuationToken !== '' && pages < 20)
    expect(pages).toBe(BASE_TUPLES.length)
    expect(seen).toEqual(BASE_TUPLES)

    const filtered = await fga.admin.read({ object: 'document:', user: 'user:alice' })
    expect(filtered.data!.tuples.map((t) => t.key.object)).toEqual(['document:1', 'document:2'])
    expect(filtered.data!.continuationToken).toBe('')

    const conditioned = await fga.admin.read({ object: 'document:roadmap', relation: 'viewer', user: 'user:anne' })
    expect(conditioned.data!.tuples[0]!.key.condition).toEqual(anneGrant.condition)
  })

  it('checks with context and contextual tuples', async () => {
    const check = (user: string, context?: Record<string, unknown>, contextualTuples?: TupleKey[]) =>
      fga.admin.check({ user, relation: 'viewer', object: 'document:roadmap', context, contextualTuples })

    expect(await check('user:anne', { current_time: '2026-01-15T00:00:00Z' })).toEqual({ data: true, error: null })
    expect(await check('user:anne', { current_time: '2026-03-01T00:00:00Z' })).toEqual({ data: false, error: null })
    expect((await check('user:bob', { user_ip: '10.20.3.4' })).data).toBe(true)
    expect((await check('user:bob', { user_ip: '192.168.1.9' })).data).toBe(false)

    const dana: TupleKey = {
      user: 'user:dana',
      relation: 'viewer',
      object: 'document:roadmap',
      condition: { name: 'in_office_network', context: { cidr: '10.20.0.0/16' } },
    }
    expect((await check('user:dana', { user_ip: '10.20.9.9' }, [dana])).data).toBe(true)
    expect((await check('user:dana', { user_ip: '10.20.9.9' })).data).toBe(false)

    // A userset through a contextual membership.
    const erin = await fga.admin.check({
      user: 'user:erin',
      relation: 'viewer',
      object: 'document:3',
      contextualTuples: [{ user: 'user:erin', relation: 'member', object: 'team:eng' }],
      authorizationModelId: modelId,
    })
    expect(erin).toEqual({ data: true, error: null })

    // A condition without its parameter is an error, not false.
    const missing = await check('user:anne')
    expect(missing.data).toBeNull()
    expect(isFgaError(missing.error, 2000)).toBe(true)
  })

  it('lists objects and users', async () => {
    const objects = await fga.admin.listObjects({ user: 'user:alice', type: 'document', relation: 'viewer' })
    expect(objects.error).toBeNull()
    expect([...objects.data!].sort()).toEqual(['document:1', 'document:2'])

    const carl = await fga.admin.listObjects({ user: 'user:carl', type: 'document', relation: 'viewer' })
    expect(carl.data).toEqual(['document:3'])

    const bob = await fga.admin.listObjects({
      user: 'user:bob',
      type: 'document',
      relation: 'viewer',
      context: { user_ip: '10.20.3.4' },
    })
    expect(bob.data).toEqual(['document:roadmap'])

    const users = await fga.admin.listUsers({
      object: 'document:roadmap',
      relation: 'viewer',
      userFilters: ['user'],
      context: { current_time: '2026-01-15T00:00:00Z', user_ip: '10.20.3.4' },
    })
    expect(users.error).toBeNull()
    expect([...users.data!].sort()).toEqual(['user:anne', 'user:bob'])

    const usersets = await fga.admin.listUsers({ object: 'document:3', relation: 'viewer', userFilters: ['team#member'] })
    expect(usersets.data).toEqual(['team:eng#member'])

    const both = await fga.admin.listUsers({
      object: 'document:3',
      relation: 'viewer',
      userFilters: ['user', 'team#member'],
      contextualTuples: [{ user: 'user:dana', relation: 'viewer', object: 'document:3' }],
    })
    expect([...both.data!].sort()).toEqual(['team:eng#member', 'user:carl', 'user:dana'])
  })

  it('writes and deletes single tuples, and writes with onDuplicate / onMissing', async () => {
    const key = { user: 'user:zed', relation: 'viewer', object: 'document:9' }
    const has = async () => (await fga.admin.check({ ...key })).data

    expect(await fga.admin.writeTuple(key)).toEqual({ data: null, error: null })
    expect(await fga.admin.writeTuple(key)).toEqual({ data: null, error: null }) // exists: not an error
    expect(await has()).toBe(true)
    expect(await fga.admin.deleteTuple(key)).toEqual({ data: null, error: null })
    expect(await fga.admin.deleteTuple(key)).toEqual({ data: null, error: null }) // missing: not an error
    expect(await has()).toBe(false)

    expect((await fga.admin.write({ writes: [key] })).error).toBeNull()
    const duplicate = await fga.admin.write({ writes: [key] })
    expect(isFgaError(duplicate.error, 2017)).toBe(true)
    expect((await fga.admin.write({ writes: [key], onDuplicate: 'ignore' })).error).toBeNull()

    expect((await fga.admin.write({ deletes: [key], authorizationModelId: modelId })).error).toBeNull()
    expect(await has()).toBe(false)
    const missing = await fga.admin.write({ deletes: [key] })
    expect(isFgaError(missing.error, 'write_failed_due_to_invalid_input')).toBe(true)
    expect((await fga.admin.write({ deletes: [key], onMissing: 'ignore' })).error).toBeNull()

    // A page of read can go back as deletes.
    const page = await fga.admin.read({ object: 'document:', user: 'user:alice' })
    const keys = page.data!.tuples.map((t) => t.key)
    expect((await fga.admin.write({ deletes: keys })).error).toBeNull()
    expect((await fga.admin.listObjects({ user: 'user:alice', type: 'document', relation: 'viewer' })).data).toEqual([])
  })

  it('maps the OpenFGA error codes', async () => {
    const unknownModel = await fga.admin.check({
      user: 'user:alice',
      relation: 'viewer',
      object: 'document:1',
      authorizationModelId: UNKNOWN_MODEL_ID,
    })
    expect(isFgaError(unknownModel.error, 2001)).toBe(true)
    expect(unknownModel.error!.reason).toEqual({ model: 'openfga', code: 2001, name: 'authorization_model_not_found' })
    expect(unknownModel.error!.code).toBe('22023')

    const readUnknown = await fga.admin.readAuthorizationModel({ authorizationModelId: UNKNOWN_MODEL_ID })
    expect(isFgaError(readUnknown.error, 'authorization_model_not_found')).toBe(true)

    const tooMany = Array.from({ length: 101 }, (_, i) => ({ user: `user:u${i}`, relation: 'viewer', object: 'document:big' }))
    const limit = await fga.admin.write({ writes: tooMany })
    expect(isFgaError(limit.error, 2053)).toBe(true)
    expect(limit.error!.hint).toBeTruthy()
    expect((await fga.admin.write({ writes: tooMany.slice(0, 100) })).error).toBeNull()

    const invalidTuple = await fga.admin.write({ writes: [{ user: 'team:eng', relation: 'viewer', object: 'document:1' }] })
    expect(isFgaError(invalidTuple.error, 2027)).toBe(true)
    const invalidSingle = await fga.admin.writeTuple({ user: 'user:alice', relation: 'owner', object: 'document:1' })
    expect(isFgaError(invalidSingle.error, 'invalid_tuple')).toBe(true)

    const key = { user: 'user:alice', relation: 'viewer', object: 'document:1' }
    const twice = await fga.admin.write({ writes: [key], deletes: [key] })
    expect(isFgaError(twice.error, 2004)).toBe(true)

    const nothing = await fga.admin.write({})
    expect(isFgaError(nothing.error, 2003)).toBe(true)

    const badPage = await fga.admin.read({ pageSize: 101 })
    expect(isFgaError(badPage.error, 2000)).toBe(true)
    const badToken = await fga.admin.read({ continuationToken: 'bm9wZQ' }) // base64url of 'nope'
    expect(isFgaError(badToken.error, 2007)).toBe(true)

    const typo = await fga.admin.listObjects({ user: 'user:alice', type: 'documnet', relation: 'viewer' })
    expect(isFgaError(typo.error, 2021)).toBe(true)
    expect(typo.error!.hint).toContain('document')
  })

  it('throws with throwOnError', async () => {
    const throwing = new FgaClient({ transport: sqlTransport(service), throwOnError: true })
    await expect(
      throwing.admin.check({ user: 'user:alice', relation: 'viewer', object: 'document:1', authorizationModelId: UNKNOWN_MODEL_ID }),
    ).rejects.toSatisfy((e) => isFgaError(e, 2001))
    expect((await throwing.admin.check({ user: 'user:alice', relation: 'viewer', object: 'document:1' })).data).toBe(true)
  })

  it('gives 42501 for an admin function without the grant', async () => {
    // An SQL transport whose connection role lacks the admin grants.
    const pool = authenticatedPool()
    try {
      const asAuthenticated = new FgaClient({ transport: sqlTransport(pool) })
      const denied = await asAuthenticated.admin.check({ user: 'user:alice', relation: 'viewer', object: 'document:1' })
      expect(denied.data).toBeNull()
      expect(denied.error).toBeInstanceOf(PermissionsError)
      expect(denied.error!.code).toBe('42501')
      expect(denied.error!.reason).toBeNull()
    } finally {
      await pool.end()
    }

    // A subject-scoped client has no admin at runtime.
    const alice = new FgaClient({ transport: sqlTransport(service).withSubject({ id: 'alice', role: 'authenticated' }) })
    expect('admin' in alice).toBe(false)

    // service_role has every admin grant but fga_delete_store().
    const store = await fga.admin.deleteStore()
    expect(store.error!.code).toBe('42501')
  })
})

describe('FGA client methods (current subject)', () => {
  beforeAll(resetFga)

  it('over SQL withSubject', async () => {
    const alice = new FgaClient({ transport: sqlTransport(service).withSubject({ id: 'alice' }) })
    expect(await alice.check({ relation: 'viewer', object: 'document:1' })).toEqual({ data: true, error: null })
    expect(await alice.check({ relation: 'viewer', object: 'document:3' })).toEqual({ data: false, error: null })
    expect([...(await alice.listObjects({ type: 'document', relation: 'viewer' })).data!].sort()).toEqual([
      'document:1',
      'document:2',
    ])
    expect([...(await alice.listObjects({ type: 'document', relation: 'viewer', idsOnly: true })).data!].sort()).toEqual([
      '1',
      '2',
    ])

    const carl = new FgaClient({ transport: sqlTransport(service).withSubject({ id: 'carl', role: 'authenticated' }) })
    expect((await carl.check({ relation: 'viewer', object: 'document:3' })).data).toBe(true)
    expect((await carl.listObjects({ type: 'document', relation: 'viewer', idsOnly: true })).data).toEqual(['3'])

    const typo = await alice.check({ relation: 'viewr', object: 'document:1' })
    expect(isFgaError(typo.error, 'validation_error')).toBe(true)
  })

  it('over PostgREST with a user token', async () => {
    const alice = new FgaClient(REST_URL, { headers: authHeaders(userToken('alice')) })
    expect('admin' in alice).toBe(false)
    expect(await alice.check({ relation: 'viewer', object: 'document:1' })).toEqual({ data: true, error: null })
    expect(await alice.check({ relation: 'viewer', object: 'document:3' })).toEqual({ data: false, error: null })
    expect([...(await alice.listObjects({ type: 'document', relation: 'viewer' })).data!].sort()).toEqual([
      'document:1',
      'document:2',
    ])
    expect([...(await alice.listObjects({ type: 'document', relation: 'viewer', idsOnly: true })).data!].sort()).toEqual([
      '1',
      '2',
    ])
    expect((await alice.listObjects({ type: 'team', relation: 'member' })).data).toEqual([])

    const typo = await alice.check({ relation: 'viewr', object: 'document:1' })
    expect(typo.data).toBeNull()
    expect(isFgaError(typo.error, 2000)).toBe(true)
    expect(typo.error!.hint).toContain('viewer')
  })

  it('over PostgREST without a token (anon) answers false', async () => {
    const anon = new FgaClient(REST_URL)
    expect(await anon.check({ relation: 'viewer', object: 'document:1' })).toEqual({ data: false, error: null })
    expect(await anon.listObjects({ type: 'document', relation: 'viewer' })).toEqual({ data: [], error: null })
  })
})
