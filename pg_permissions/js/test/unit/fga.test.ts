import { describe, expect, expectTypeOf, it } from 'vitest'
import { FgaClient } from '../../src/fga'
import type { FgaAdminApi } from '../../src/fga'
import { PermissionsError, isFgaError } from '../../src/lib/errors'
import type { RpcArgs, Shape, Transport, TransportKind } from '../../src/lib/types'
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

const fgaError = (code: number, name: string) =>
  new PermissionsError({ message: 'boom', details: `openfga:${code} ${name}`, hint: 'fix it', code: '22023' })

function sqlClient(respond?: (call: Call) => unknown, throwOnError?: boolean) {
  const transport = fakeTransport('sql', respond)
  return { transport, fga: new FgaClient({ transport, throwOnError }) }
}

describe('FgaClient: client methods', () => {
  it('check calls fga_check_current', async () => {
    const transport = fakeTransport('postgrest', () => true)
    const fga = new FgaClient({ transport })
    expect(await fga.check({ relation: 'viewer', object: 'document:1' })).toEqual({ data: true, error: null })
    expect(transport.calls).toEqual([
      { fn: 'fga_check_current', args: { relation: 'viewer', object: 'document:1' }, shape: 'scalar' },
    ])
  })

  it('listObjects uses the ids function with idsOnly', async () => {
    const transport = fakeTransport('postgrest', (c) => (c.fn === 'fga_list_object_ids_current' ? ['1'] : ['document:1']))
    const fga = new FgaClient({ transport })
    expect((await fga.listObjects({ type: 'document', relation: 'viewer' })).data).toEqual(['document:1'])
    expect((await fga.listObjects({ type: 'document', relation: 'viewer', idsOnly: true })).data).toEqual(['1'])
    expect(transport.calls.map((c) => [c.fn, c.args, c.shape])).toEqual([
      ['fga_list_objects_current', { type: 'document', relation: 'viewer' }, 'set'],
      ['fga_list_object_ids_current', { type: 'document', relation: 'viewer' }, 'set'],
    ])
  })

  it('returns a PermissionsError as { data: null, error }', async () => {
    const transport = fakeTransport('postgrest', () => fgaError(2000, 'validation_error'))
    const { data, error } = await new FgaClient({ transport }).check({ relation: 'viewr', object: 'document:1' })
    expect(data).toBeNull()
    expect(isFgaError(error, 2000)).toBe(true)
  })

  it('throws with throwOnError', async () => {
    const transport = fakeTransport('postgrest', () => fgaError(2000, 'validation_error'))
    const fga = new FgaClient({ transport, throwOnError: true })
    await expect(fga.check({ relation: 'viewr', object: 'document:1' })).rejects.toBeInstanceOf(PermissionsError)
  })

  it('always throws a programming error', async () => {
    const transport = fakeTransport('postgrest', () => new Error('refused'))
    await expect(new FgaClient({ transport }).check({ relation: 'r', object: 'o:1' })).rejects.toThrow('refused')
  })
})

const makeSqlClient = (transport: SqlTransport) => new FgaClient({ transport })

describe('FgaClient: admin only on SQL', () => {
  it('a PostgREST client has no admin, at runtime and in the type', () => {
    const fga = new FgaClient('http://localhost:3000', { fetch: (async () => new Response('true')) as typeof fetch })
    expect('admin' in fga).toBe(false)
    // @ts-expect-error admin does not exist on a PostgREST client
    expect(fga.admin).toBeUndefined()
    const viaTransport = new FgaClient({ transport: fakeTransport('postgrest') })
    expect('admin' in viaTransport).toBe(false)
    // @ts-expect-error admin does not exist on a postgrest-kind transport
    void viaTransport.admin
  })

  it('an SQL client has admin', () => {
    const { fga } = sqlClient()
    expect(fga.admin).toBeDefined()
    expectTypeOf(fga.admin).toEqualTypeOf<FgaAdminApi>()
    // A transport typed as SqlTransport (what sqlTransport() returns) gives an admin client.
    expectTypeOf<ReturnType<typeof makeSqlClient>['admin']>().toEqualTypeOf<FgaAdminApi>()
  })

  it('a subject transport has no admin, at runtime and in the type', () => {
    const fga = new FgaClient({ transport: fakeTransport('subject') })
    expect('admin' in fga).toBe(false)
    // @ts-expect-error admin does not exist on a subject transport
    void fga.admin
  })

  it('types the client by the kind of the transport', () => {
    expectTypeOf(new FgaClient({ transport: fakeTransport('sql') })).toEqualTypeOf<FgaClient<'sql'>>()
    expectTypeOf(new FgaClient({ transport: fakeTransport('postgrest') })).toEqualTypeOf<FgaClient<'postgrest'>>()
    expectTypeOf(new FgaClient({ transport: fakeTransport('subject') })).toEqualTypeOf<FgaClient<'subject'>>()
    expectTypeOf(new FgaClient('http://x')).toEqualTypeOf<FgaClient<'postgrest'>>()
    const general: Transport = fakeTransport('sql')
    expectTypeOf(new FgaClient({ transport: general })).toEqualTypeOf<FgaClient>()
    expectTypeOf<FgaClient<'sql'>['admin']>().toEqualTypeOf<FgaAdminApi>()
    expectTypeOf<FgaClient<'subject'>>().not.toHaveProperty('admin')
    expectTypeOf<FgaClient<'postgrest'>>().not.toHaveProperty('admin')
    expectTypeOf<FgaClient>().not.toHaveProperty('admin')
  })

  it('a general Transport has no admin in the type', () => {
    const general: Transport = fakeTransport('sql')
    const fga = new FgaClient({ transport: general })
    // @ts-expect-error the kind is not known to be 'sql'
    void fga.admin
    // Runtime follows the actual kind.
    expect('admin' in fga).toBe(true)
  })

  it('PostgREST client sends to the rpc endpoint', async () => {
    const requests: Array<{ url: string; body: string }> = []
    const fga = new FgaClient('http://localhost:3000/', {
      schema: 'perm',
      headers: { apikey: 'k' },
      fetch: (async (url: string, init: RequestInit) => {
        requests.push({ url, body: String(init.body) })
        return new Response('["1"]', { status: 200 })
      }) as unknown as typeof fetch,
    })
    expect(await fga.listObjects({ type: 'document', relation: 'viewer', idsOnly: true })).toEqual({
      data: ['1'],
      error: null,
    })
    expect(requests).toEqual([
      { url: 'http://localhost:3000/rpc/fga_list_object_ids_current', body: '{"type":"document","relation":"viewer"}' },
    ])
  })

  it('needs a URL or a transport', () => {
    expect(() => new FgaClient({} as never)).toThrow('needs a PostgREST URL')
  })
})

describe('FgaAdminApi: name mapping', () => {
  it('writeAuthorizationModel sends the model and wraps the id', async () => {
    const model = { schema_version: '1.1', type_definitions: [{ type: 'user' }] }
    const { transport, fga } = sqlClient(() => '01ABC')
    expect(await fga.admin.writeAuthorizationModel(model)).toEqual({ data: { authorizationModelId: '01ABC' }, error: null })
    await fga.admin.writeAuthorizationModel(JSON.stringify(model))
    expect(transport.calls).toEqual([
      { fn: 'fga_write_authorization_model', args: { model }, shape: 'scalar' },
      { fn: 'fga_write_authorization_model', args: { model }, shape: 'scalar' },
    ])
  })

  it('readAuthorizationModel maps authorizationModelId', async () => {
    const { transport, fga } = sqlClient(() => ({ id: 'm1', schema_version: '1.1', type_definitions: [] }))
    expect((await fga.admin.readAuthorizationModel()).data?.id).toBe('m1')
    await fga.admin.readAuthorizationModel({ authorizationModelId: 'm1' })
    expect(transport.calls).toEqual([
      { fn: 'fga_read_authorization_model', args: { model_id: undefined }, shape: 'scalar' },
      { fn: 'fga_read_authorization_model', args: { model_id: 'm1' }, shape: 'scalar' },
    ])
  })

  it('readAuthorizationModels gives createdAt as a Date from a Date or a string', async () => {
    const d = new Date('2026-11-01T05:48:04.631Z')
    const { transport, fga } = sqlClient(() => [
      { id: 'b', created_at: d },
      { id: 'a', created_at: '2026-11-01T05:48:04.631493+00:00' },
    ])
    const { data } = await fga.admin.readAuthorizationModels()
    expect(data).toEqual([
      { id: 'b', createdAt: d },
      { id: 'a', createdAt: new Date('2026-11-01T05:48:04.631Z') },
    ])
    expect(data?.[1]?.createdAt).toBeInstanceOf(Date)
    expect(transport.calls[0]).toEqual({ fn: 'fga_read_authorization_models', args: {}, shape: 'rows' })
  })

  it('write sends arrays, or the object form with onDuplicate / onMissing', async () => {
    const t1 = { user: 'user:a', relation: 'viewer', object: 'document:1' }
    const t2 = { user: 'user:b', relation: 'viewer', object: 'document:1' }
    const { transport, fga } = sqlClient()
    expect(await fga.admin.write({ writes: [t1], deletes: [t2], authorizationModelId: 'm1' })).toEqual({
      data: null,
      error: null,
    })
    await fga.admin.write({ writes: [t1], deletes: [t2], onDuplicate: 'ignore', onMissing: 'error' })
    await fga.admin.write({ deletes: [t2], onDuplicate: 'ignore' })
    expect(transport.calls).toEqual([
      { fn: 'fga_write', args: { writes: [t1], deletes: [t2], model_id: 'm1' }, shape: 'void' },
      {
        fn: 'fga_write',
        args: {
          writes: { tuple_keys: [t1], on_duplicate: 'ignore' },
          deletes: { tuple_keys: [t2], on_missing: 'error' },
          model_id: undefined,
        },
        shape: 'void',
      },
      { fn: 'fga_write', args: { writes: undefined, deletes: [t2], model_id: undefined }, shape: 'void' },
    ])
  })

  it('writeTuple and deleteTuple map user to subject', async () => {
    const { transport, fga } = sqlClient()
    await fga.admin.writeTuple({ user: 'user:a', relation: 'viewer', object: 'document:1' })
    await fga.admin.deleteTuple({ user: 'user:a', relation: 'viewer', object: 'document:1' })
    expect(transport.calls).toEqual([
      { fn: 'fga_write_tuple', args: { subject: 'user:a', relation: 'viewer', object: 'document:1' }, shape: 'void' },
      { fn: 'fga_delete_tuple', args: { subject: 'user:a', relation: 'viewer', object: 'document:1' }, shape: 'void' },
    ])
  })

  it('read maps the request and the continuation token', async () => {
    const tuple = { key: { user: 'user:a', relation: 'viewer', object: 'document:1' }, timestamp: '2026-11-01T00:00:00Z' }
    const { transport, fga } = sqlClient(() => ({ tuples: [tuple], continuation_token: 'MTIz' }))
    expect(
      await fga.admin.read({ object: 'document:', relation: 'viewer', user: 'user:a', pageSize: 1, continuationToken: 'abc' }),
    ).toEqual({ data: { tuples: [tuple], continuationToken: 'MTIz' }, error: null })
    expect(transport.calls[0]).toEqual({
      fn: 'fga_read',
      args: { object: 'document:', relation: 'viewer', subject: 'user:a', page_size: 1, continuation_token: 'abc' },
      shape: 'record',
    })
  })

  it('read with no arguments, and a null token normalized to ""', async () => {
    const { transport, fga } = sqlClient(() => ({ tuples: [], continuation_token: null }))
    expect((await fga.admin.read()).data).toEqual({ tuples: [], continuationToken: '' })
    expect(transport.calls[0]?.args).toEqual({
      object: undefined,
      relation: undefined,
      subject: undefined,
      page_size: undefined,
      continuation_token: undefined,
    })
  })

  it('check, listObjects and listUsers map the evaluation options', async () => {
    const ct = [{ user: 'user:a', relation: 'member', object: 'team:eng' }]
    const ctx = { current_time: '2026-01-15T00:00:00Z' }
    const { transport, fga } = sqlClient((c) => (c.fn === 'fga_check' ? false : ['x']))
    expect(
      await fga.admin.check({
        user: 'user:a',
        relation: 'viewer',
        object: 'document:1',
        contextualTuples: ct,
        context: ctx,
        authorizationModelId: 'm1',
      }),
    ).toEqual({ data: false, error: null })
    await fga.admin.listObjects({ user: 'user:a', type: 'document', relation: 'viewer', context: ctx })
    await fga.admin.listUsers({ object: 'document:1', relation: 'viewer', userFilters: ['user', 'team#member'] })
    expect(transport.calls).toEqual([
      {
        fn: 'fga_check',
        args: {
          subject: 'user:a',
          relation: 'viewer',
          object: 'document:1',
          contextual_tuples: ct,
          model_id: 'm1',
          context: ctx,
        },
        shape: 'scalar',
      },
      {
        fn: 'fga_list_objects',
        args: {
          subject: 'user:a',
          type: 'document',
          relation: 'viewer',
          contextual_tuples: undefined,
          model_id: undefined,
          context: ctx,
        },
        shape: 'set',
      },
      {
        fn: 'fga_list_users',
        args: {
          object: 'document:1',
          relation: 'viewer',
          user_filters: ['user', 'team#member'],
          contextual_tuples: undefined,
          model_id: undefined,
          context: undefined,
        },
        shape: 'set',
      },
    ])
  })

  it('deleteStore', async () => {
    const { transport, fga } = sqlClient()
    expect(await fga.admin.deleteStore()).toEqual({ data: null, error: null })
    expect(transport.calls[0]).toEqual({ fn: 'fga_delete_store', args: {}, shape: 'void' })
  })

  it('admin wraps errors, and throws with throwOnError', async () => {
    const { fga } = sqlClient(() => fgaError(2001, 'authorization_model_not_found'))
    const { data, error } = await fga.admin.check({
      user: 'user:a',
      relation: 'viewer',
      object: 'document:1',
      authorizationModelId: 'nope',
    })
    expect(data).toBeNull()
    expect(isFgaError(error, 'authorization_model_not_found')).toBe(true)
    const throwing = sqlClient(() => fgaError(2053, 'exceeded_entity_limit'), true).fga
    await expect(throwing.admin.write({ writes: [] })).rejects.toSatisfy((e) => isFgaError(e, 2053))
  })
})
