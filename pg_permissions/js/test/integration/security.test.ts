import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import type pg from 'pg'
import { REST_URL, authHeaders, ownerPool, resetDatabase, servicePool, userToken } from './helpers'

let owner: pg.Pool
let service: pg.Pool
const permit = 'permit (principal == ?principal, action, resource);'
const forbid = 'forbid (principal == ?principal, action, resource);'

beforeAll(() => {
  owner = ownerPool()
  service = servicePool()
})
beforeEach(async () => {
  await resetDatabase(owner)
  await service.query('select permissions.cedar_put_template($1, $2)', ['race', permit])
})
afterAll(async () => {
  await owner.end()
  await service.end()
})

// Wait for a real database lock, or for the competing query to finish. No
// fixed delay decides the interleaving: this fails if it neither blocks nor
// completes, and each query has a server-side timeout as a second bound.
async function waitForBlock(pid: number, settled: () => boolean): Promise<boolean> {
  const deadline = Date.now() + 5_000
  while (Date.now() < deadline) {
    if (settled()) return false
    const { rows } = await owner.query('select wait_event_type from pg_stat_activity where pid = $1', [pid])
    if (rows[0]?.wait_event_type === 'Lock') return true
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  throw new Error('The competing query neither blocked nor completed')
}

describe('concurrent Cedar template changes', () => {
  const interleavings = (['read committed', 'repeatable read', 'serializable'] as const).flatMap((isolation) =>
    (['update-first', 'link-first'] as const).map((order) => ({ isolation, order })),
  )
  it.each(interleavings)('$isolation, $order: a link cannot retain the replaced permit', async ({ isolation, order }) => {
    const a = await service.connect()
    const b = await service.connect()
    let pending: Promise<unknown> | undefined
    let settled = false
    try {
      await a.query('begin; set local statement_timeout = \'10s\'')
      await b.query(`begin isolation level ${isolation}; set local statement_timeout = '10s'`)
      const { rows: [backend] } = await b.query('select pg_backend_pid() as pid')
      const update = (c: pg.PoolClient) => c.query('select permissions.cedar_put_template($1, $2)', ['race', forbid])
      const link = (c: pg.PoolClient) => c.query('select permissions.cedar_link_template($1, $2, $3)', ['alice', 'race', 'user::"alice"'])
      await (order === 'update-first' ? update(a) : link(a))
      pending = (order === 'update-first' ? link(b) : update(b)).then(
        () => { settled = true; return null },
        (error: unknown) => { settled = true; return error },
      )
      const blocked = await waitForBlock(backend.pid, () => settled)
      await a.query('commit')
      const error = await pending
      expect(blocked).toBe(true)
      if (error === null) {
        await b.query('commit')
      } else {
        expect(isolation).not.toBe('read committed')
        expect(error).toMatchObject({ code: '40001' })
        await b.query('rollback')
        // A retry against a fresh snapshot must complete the intended change.
        await (order === 'update-first' ? link(b) : update(b))
      }
      const { rows: [result] } = await service.query(`
        select permissions.cedar_is_authorized('user::"alice"', 'Action::"view"', 'Doc::"secret"') as decision`)
      expect(result.decision.decision).toBe('deny')
      expect(result.decision.reasons).toEqual(['alice'])
    } finally {
      await a.query('rollback')
      await pending
      await b.query('rollback')
      a.release()
      b.release()
    }
  })

  it('validates replacement slots after waiting for an in-flight link', async () => {
    const a = await service.connect()
    const b = await service.connect()
    let pending: Promise<unknown> | undefined
    let settled = false
    try {
      await a.query('begin')
      await b.query('begin; set local statement_timeout = \'10s\'')
      const { rows: [backend] } = await b.query('select pg_backend_pid() as pid')
      await a.query('select permissions.cedar_link_template($1, $2, $3)', ['alice', 'race', 'user::"alice"'])
      pending = b.query('select permissions.cedar_put_template($1, $2)', [
        'race', 'permit (principal, action, resource == ?resource);',
      ]).then(
        () => { settled = true; return null },
        (error: unknown) => { settled = true; return error },
      )
      const blocked = await waitForBlock(backend.pid, () => settled)
      await a.query('commit')
      const error = await pending
      await b.query('rollback')
      expect(blocked).toBe(true)
      expect(error).toMatchObject({ detail: expect.stringContaining('cedar:template_in_use') })
      const { rows: [template] } = await service.query('select source from permissions.cedar_templates()')
      expect(template.source).toBe(permit)
    } finally {
      await a.query('rollback')
      await pending
      await b.query('rollback')
      a.release()
      b.release()
    }
  })
})

describe('PostgREST security boundary', () => {
  async function rpc(name: string, body: unknown) {
    return fetch(`${REST_URL}/rpc/${name}`, {
      method: 'POST',
      headers: { ...authHeaders(userToken('alice')), 'Content-Type': 'application/json', 'Content-Profile': 'permissions' },
      body: JSON.stringify(body),
    })
  }

  it('keeps a real cache secret through test resets', async () => {
    const { rows: [row] } = await owner.query('select count(*)::int as count from permissions._cedar_secret')
    expect(row.count).toBe(1)
  })

  it('rejects malformed entity references sent directly over HTTP', async () => {
    await service.query('select permissions.cedar_put_policy($1, $2)', [
      'typed', 'permit (principal, action, resource) when { resource.owner is Admin };',
    ])
    const response = await rpc('cedar_is_authorized_current', {
      action: 'Action::"view"', resource: 'Doc::"secret"', resource_attrs: { owner: { __entity: { type: 'Admin' } } },
    })
    expect(response.ok).toBe(true)
    expect(await response.json()).toBe(false)
  })

  it('enforces admin privileges even when the JavaScript client is bypassed', async () => {
    const response = await rpc('cedar_put_policy', { policy_id: 'intruder', policy: 'permit (principal, action, resource);' })
    expect(response.ok).toBe(false)
    const { rows } = await service.query('select policy_id from permissions.cedar_policies()')
    expect(rows).toEqual([])
  })
})

describe('concurrent Cedar hierarchy changes', () => {
  it.each(['read committed', 'repeatable read', 'serializable'] as const)('%s: two valid writes cannot commit a cycle', async (isolation) => {
    const a = await service.connect()
    const b = await service.connect()
    let pending: Promise<unknown> | undefined
    let settled = false
    try {
      await a.query('begin')
      await b.query(`begin isolation level ${isolation}; set local statement_timeout = '10s'`)
      // Establish B's snapshot before A commits, including at REPEATABLE READ.
      const { rows: [backend] } = await b.query('select pg_backend_pid() as pid')
      const entity = (id: string, parent: string) => JSON.stringify([
        { uid: { type: 'Group', id }, parents: [{ type: 'Group', id: parent }] },
      ])
      await a.query('select permissions.cedar_put_entities($1)', [entity('a', 'b')])
      pending = b.query('select permissions.cedar_put_entities($1)', [entity('b', 'a')]).then(
        () => { settled = true; return null },
        (error: unknown) => { settled = true; return error },
      )
      const blocked = await waitForBlock(backend.pid, () => settled)
      await a.query('commit')
      const error = await pending
      await b.query('rollback')
      expect(blocked).toBe(true)
      if (isolation === 'read committed') {
        expect(error).toMatchObject({ detail: expect.stringContaining('cedar:invalid_entity') })
      } else {
        expect(error).toMatchObject({ code: '40001' })
      }
      const { rows } = await service.query("select permissions.cedar_read_entities('Group') as entity")
      expect(rows[0].entity).toHaveLength(1)
      expect(rows[0].entity[0].uid.id).toBe('a')
    } finally {
      await a.query('rollback')
      await pending
      await b.query('rollback')
      a.release()
      b.release()
    }
  })
})
